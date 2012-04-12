package Pogo::Scheduler::Classic;
use strict;
use Log::Log4perl qw(:easy);
use Template;
use Template::Parser;
use Template::Stash;
use YAML::Syck qw(Load LoadFile);
use Pogo::Util qw( array_intersection struct_traverse );
use Pogo::Scheduler::Thread;
use Pogo::Scheduler::Slot;
use Pogo::Scheduler::Task;
use base qw( Pogo::Scheduler );

###########################################
sub new {
###########################################
    my( $class, %options ) = @_;

    my $self = {
        thread_by_id => {},
        threads      => [],
        config       => {},
        %options,
    };

    bless $self, $class;

    $self->reg_cb( "task_finished", sub {
      my( $c, @params ) = @_;
      $self->task_finished( @params );
    } );

    return $self;
}

###########################################
sub config {
###########################################
    my( $self ) = @_;

    return $self->{ config };
}

###########################################
sub config_load {
###########################################
    my( $self, $yaml ) = @_;

    if( ref $yaml eq "SCALAR" ) {
        $self->{ config } = Load( $$yaml );
    } else {
        $self->{ config } = LoadFile( $yaml );
    }

    for my $field ( qw( sequence tag ) ) {
        if( !exists $self->{ config }->{ $field } ) {
            ERROR "Improper config file: No $field";
            return undef;
        }
    }

    $self->{ slots } = [];

      # The full path to every leaf node in the 'sequence' definition, 
      # separated by dots, constitutes a slot.
    Pogo::Util::struct_traverse( $self->{ config }->{ sequence }, { 
        leaf => sub {
            my( $node, $path ) = @_; 

            my $slot = Pogo::Scheduler::Slot->new(
                id => join(".", @$path, $node),
            );
            push @{ $self->{ slots } }, $slot;
        } 
    } );

      # Traverse the configuration's "tag" structure and map hosts
      # to slots (host slots constitute of the full path to the leaf nodes
      # in the "tag" configuration).
    Pogo::Util::struct_traverse( $self->{ config }->{ tag }, {
        leaf => sub {
            my( $node, $path ) = @_; 

            my $host = $node;
            my $slot = join '.', @$path;
            push @{ $self->{ host_slots }->{ $slot } }, $host;
        }
    } );

    $self->slot_setup();
    $self->thread_setup();

    return 1;
}

###########################################
sub slot_setup {
###########################################
    my( $self ) = @_;

    my $all_hosts = $self->config_hosts_hash();

    for my $slot ( @{ $self->{ slots } } ) {
        my @parts = ();

        my $slot_id = $slot->id();

        while( $slot_id =~ /(\$[^\$]*)/g ) {
            my $part = $1;
            $part =~ s/^\$//;
            $part =~ s/\.$//;
            push @parts, $part;
        }

        my $found = $self->{ host_slots }->{ shift @parts };
        my @hosts = ();
        @hosts = @$found if defined $found;

        for my $part ( @parts ) {
            @hosts = array_intersection( \@hosts, 
                       $self->{ host_slots }->{ $part } );
        }

        for my $host ( @hosts ) {
            delete $all_hosts->{ $host };
        }

        $self->{ hosts_by_slot }->{ $slot->id() } = \@hosts;
    }

      # what's left over is unconstrained
    $self->{ hosts_by_slot }->{ unconstrained } = [ keys %{ $all_hosts } ];
}

###########################################
sub thread_setup {
###########################################
    my( $self ) = @_;

    $self->{ threads } = [];

    Pogo::Util::struct_traverse( $self->{ config }->{ sequence }, {
      array => sub {
          my( $sequence, $path ) = @_;

          my $thread = Pogo::Scheduler::Thread->new();

            # for quick lookup later when tasks come back
          $self->{ thread_by_id }->{ $thread->id() } = $thread;

          for my $seq ( @$sequence ) {
              my $slot = Pogo::Scheduler::Slot->new(
                  id => join('.', @$path, $seq),
              );
              $thread->slot_add( $slot );
          }

          push @{ $self->{ threads } }, $thread;
      } 
    } );

    my $slot = Pogo::Scheduler::Slot->new(
        id => "unconstrained",
    );

    my $thread = Pogo::Scheduler::Thread->new();
    $thread->slot_add( $slot );

    push @{ $self->{ threads } }, $thread;
}

###########################################
sub schedule {
###########################################
    my( $self, $hosts ) = @_;

    $hosts = [] if !defined $hosts;

    DEBUG "Scheduling hosts ",
      join( ", ", @$hosts );

    my %host_lookup = map { $_ => 1 } @$hosts; # for faster lookups

    $self->reg_cb( "task_mark_done", sub {
        my( $c, $task ) = @_;

        DEBUG "Scheduler received task_mark_done for task $task";

        DEBUG "Forwarding 'task_mark_done' to thread ", $task->thread_id();
        if( exists $self->{ thread_by_id }->{ $task->thread_id() } ) {
            $self->{ thread_by_id }->{ $task->thread_id() }->event(
                "task_mark_done", $task );
        } else {
            ERROR "Received task with unknown thread id: $task";
        }
    } );

    for my $thread ( @{ $self->{ threads } } ) {

        next if $thread->is_done();

        $thread->reg_cb( "task_run", sub {
            my( $c, $task ) = @_;

            DEBUG "Classic running task $task";
            $self->event( "task_run", $task );
        } );

        for my $slot ( @{ $thread->{ slots } } ) {
            for my $host ( 
                @{ $self->{ hosts_by_slot }->{ $slot->id() } } ) {
    
                if( exists $host_lookup{ $host } ) {
                    my $task = Pogo::Scheduler::Task->new( 
                        id        => $host,
                        slot_id   => $slot,
                        thread_id => $thread,
                        host      => $host,
                    );
                    $slot->task_add( $task );
                }
            }
        }

          # start thread in parallel with other threads
        $thread->start();
    }
}

###########################################
sub slot_run {
###########################################
    my( $self, $slot, $hosts ) = @_;

      # schedule all the hosts in the slot (will change later 
      # with constraints)
    for my $host ( @{ $self->{ hosts_by_slot }->{ $slot } } ) {

        next if !exists $hosts->{ $host };

        my $task = {
            slot => $slot,
            host => $host,
        };

        $self->task_run( $task );
    }

    #job123:thread1:frontend.colo.north_america:host1
}

###########################################
sub config_hosts_hash {
###########################################
    my( $self ) = @_;

    # extract all the hosts defined in the config file (might include
    # custom tag resolvers).
    my $hosts = {};

    for my $key ( qw( tag sequence ) ) {
        my $root =  $self->{ config }->{ $key };
        Pogo::Util::struct_traverse( $root, {
            leaf => sub {
                my( $node, $path ) = @_;

                $hosts->{ $node } = 1 if $node !~ /^\$/;
            }
        } );
    }

    return $hosts;
}

###########################################
sub config_hosts {
###########################################
    my( $self ) = @_;

    return keys %{ $self->config_hosts_hash() };
}

###########################################
sub task_run {
###########################################
    my( $self, $task ) = @_;

    $self->event( "task_run", $task );
}

###########################################
sub task_finished {
###########################################
    my( $self, $task ) = @_;

      # when all is done
    $self->event( "job_done" );
}

1;

__END__

=head1 NAME

Pogo::Scheduler::Classic - Pogo Scheduler supporting Sequences and Constraints

=head1 SYNOPSIS

    use Pogo::Scheduler::Classic;

=head1 DESCRIPTION

Pogo can be configured to apply predefined rules during deployments. Features
include 

=over 4

=item B<Tags>

Hosts can be tagged with labels and assigned a value.  Example:

    tag:
      colo:
        north_america:
          - host1
          - host2
        south_east_asia:
          - host3
          - host4

This defines that host1 carries a tag C<colo> that has the value 
C<north_america>.

All hosts carrying a specific tag value can be referred to later on with
the following notation:

    $tagname.colo.tag_value

For example, to refer to all hosts carrying the tag C<colo> with a value
C<north_america>, use C<$colo.north_america>.

To refer to all hosts carrying a specific tag, regardless of its value,
use the

    $tagname

notation. For example, to refer to all hosts carrying a C<colo> tag, 
regardless of its value, use C<$colo>.

=item B<Sequences>

If one host or hostgroup must be finished before the next one in 
a sequence can be started, this dependency can be defined in a sequence:

    sequence:
      - [ $colo.north_america, $colo.south_east_asia ]

The statement above defines that all hosts carrying the tag C<colo> will be
processed in an order that makes sure that those carrying the tag value
C<north_america> will be finished before any of the hosts carrying the C<colo>
tag value C<south_east_asia> will be started.

With the configuration shown at the start of this section, and no other
constraints, this will cause the scheduler to process the hosts in the
following order:

    - host1 host2 (wait until both are finished)
    - host3 host4

=item B<Constraints>

To limit the number of hosts handled in parallel, constraints can be put in
place. For example, 

    constraint:
      $colo.north_america: 3
      $colo.south_east_asia: 15%

limits the number of hosts processed in parallel in the C<north_america> 
colocation to 3, and in the C<south_east_asia> colo to 15%. To apply a 
constraint evenly on all hosts carrying a specific tag, grouped by tag value,
use

    constraint:
      $colo: 3

This will allow Pogo to process up to 3 hosts of both the C<north_america> and
C<south_korea> colos in parallel.

=back 

=head2 Example

Let's take a look at the following configuration and how pogo will handle it:

    tag:
      colo:
        north_america:
          - host1
          - host2
          - host3
        south_east_asia:
          - host4
          - host5
          - host6

    sequence:
      - [ $colo.north_america, $colo.south_east_asia ] 

    constraint:
      $colo: 2

Now if you ask Pogo to process all hosts carrying the C<colo> tag (or
specify C<host[1-6]>), the following will happen ("|" indicates that the
following line starts in parallel):

    host1 start 
    | host2 start
    host1 end
    | host3 start
    host2 end
    host3 end

    host4 start
    | host5 start
    host4 end
    | host6 start
    host5 end
    host6 end

Since the constraint says that we can process up to two hosts per colo
in parallel, Pogo starts with host1 and host2 in parallel. It won't throw
in any hosts from colo C<south_east_asia> yet, because of the sequence 
definition
that says that colo C<north_america> has to be completed first. As soon as
either host1 or host2 are done, 
Pogo starts host3, maximizing the resource constraint
of 2 hosts per colo. While there are still hosts remaining in colo 
C<north_america>, however, it cannot proceed with any in
colo C<south_east_asia> yet, because of the earlier sequence requirement.
Only when host1, host2, and host3 are all completed, it starts both 
host4 and host5 in parallel, again maximizing the per-colo resource 
constraint of 2.

=head2 Combining Tags

Tags can be combined (boolean AND) by nesting them. If an entry
doesn't refer to a value but an underlying key-value structure, the
Pogo configuration will apply the setting to all targets matching the
chain of tags that leads to an eventual value.

For example, if a constraint applies to all hosts tagged C<frontend> 
(regardless of value) in colo C<north_america>, use

    constraint:
      frontend:
         $colo.north_america: 2

=head2 External Tag Resolvers

In your organization, you might have custom rules on how to 'tag' hosts or
combine them into groups. This is why the Pogo configuration format supports
I<custom tag resolvers>, a plugin system that allows you to add customized 
logic.

If a tag cannot be resolved into a list of targets, the configurator will
try to load a Plugin with the tag's name.

For example, with

    constraint:
      $_MyRules[my_db_server]: 2

and no tag C<_MyRules> defined anywhere in the configuration file, the
scheduler will look for C<MyRules.pm> in

    lib/Pogo/Scheduler/Config/Plugin

and call its C<targets()> method with a parameter of C<my_db_server> 
to obtain all targets in the 'my_db_server' group.

=head2 Sequences on subsets

For example to define a sequence only applicable to hosts
tagged C<frontend>, use

    sequence:
      frontend:
        - $colo.north_america
        - $colo.south_east_asia

with hosts grouped into

    tag:
      colo:
        north_america:
          - host1
          - host2
          - host3
        south_east_asia:
          - host4
          - host5
          - host6
      frontend:
        - host1 
        - host4
      backend:
        - host2 
        - host5

this will run in the following order:

    host1
    | host2 | host3 | host5 | host6 start
    host4

Since the sequence requirement only applies to C<frontend> hosts C<host1> and
C<host4>. The remaining hosts in colo C<south_east_asia> are not affected
and can now run unconstrained. C<host4>, on the other hand, needs to wait 
until C<host1> is done.

=head2 Slot Algorithm

If sequence definitions are independent of each other, they can be run
in parallel as long as individual sequence rules aren't violated. 
For example, with

    sequence:
      frontend:
        - $colo.north_america
        - $colo.south_east_asia
      backend:
        - $colo.south_east_asia
        - $colo.north_america

and with hosts grouped into

    tag:
      colo:
        north_america:
          - host1
          - host2
          - host3
        south_east_asia:
          - host4
          - host5
          - host6
      frontend:
        - host1 
        - host4
      backend:
        - host2 
        - host5

we can run the following threads concurrently:

    thread1: host1 -> host4
    thread2: host5 -> host2
    thread3: host3+host6

For this to happen, the following "slots" are created for a job by 
walking through the C<sequence> definitions and creating a slot for
every entry found, followed by the hosts covered (or left empty
if the slot contains no hosts):

    job123:
      slots:
        frontend.colo.north_america:
          - host1
        frontend.colo.south_east_asia:
          - host4
        backend.colo.north_america:
          - host2
        backend.colo.south_east_asia:
          - host5
        unconstrained:
          - host3
          - host6

The last slot, C<unconstrained>, holds all the hosts that are not bound
by sequence constraints.

Pulling in the sequence definitions from the configuration, and performing
a topological sort on the dependencies, we can now write the 
following schedule (with multiple threads enumerated sequentially,
to be all executed in parallel independently of each other):

    job123:
      schedule:
        thread1:
          frontend.colo.north_america:
            host1
          frontend.colo.south_east_asia:
            host4
        thread2:
          backend.colo.south_east_asia:
            - host5
          backend.colo.north_america:
            - host2
        thread3:
          unconstrained:
            - host3
            - host6

Since a job typically does not run all the hosts in the configuration,
but only a subset, hosts that aren't part of the job are removed from
the schedule. The schedule is the written to persistent/shared storage
(e.g. ZooKeeper).

TODO

Then, the algorithm starts like this, getting the first batches of 
each thread rolling:

    for my $thread ( job_threads() ) {
        push @run_queue, $thread->slots()[0]->hosts();
    }

The run queue now contains the following information:

    job123:thread1:frontend.colo.north_america:host1
    job123:thread2:backend.colo.north_america:host5
    job123:thread3:unconstrained:host3
    job123:thread3:unconstrained:host6

The dispatcher then assigns each job in the run queue to a worker. As
results are trickling in, (e.g. 
"job123:thread1:frontend.colo.north_america:host1"), it goes back to the job
schedule data, looks up the job ("job123"), the thread ("thread1"), the
slot ("frontend.colo.north_america"), finds the host ("host1") and deletes
it. If this makes the corresponding slot empty, it is deleted and the
next slot's hosts are all put into the run queue. 

If there are no more slots in the thread, the thread gets deleted. 

If there are no more threads in the job, the job is finished.

=head1 LICENSE

Copyright (c) 2010-2012 Yahoo! Inc. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
imitations under the License.

=head1 AUTHORS

Mike Schilli <m@perlmeister.com>
Ian Bettinger <ibettinger@yahoo.com>

Many thanks to the following folks for implementing the
original version of Pogo: 

Andrew Sloane <andy@a1k0n.net>, 
Michael Fischer <michael+pogo@dynamine.net>,
Nicholas Harteau <nrh@hep.cat>,
Nick Purvis <nep@noisetu.be>,
Robert Phan <robert.phan@gmail.com>,
Srini Singanallur <ssingan@yahoo.com>,
Yogesh Natarajan <yogesh_ny@yahoo.co.in>
