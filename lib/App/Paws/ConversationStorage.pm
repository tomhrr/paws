package App::Paws::ConversationStorage;

use warnings;
use strict;

use JSON::XS qw(decode_json);
use List::Util qw(min minstr first);

use constant UNNEEDED_BUFFER => 3600;

sub new
{
    my $class = shift;
    my %args = @_;

    my $self = {
        context   => $args{'context'},
        workspace => $args{'workspace'},
        id        => $args{'id'},
        name      => $args{'name'},
        write_cb  => $args{'write_cb'},
        %{$args{'data'}},
    };

    $self->{'first_ts'}   ||= 0;
    $self->{'last_ts'}    ||= 1;
    $self->{'threads'}    ||= {};
    $self->{'deliveries'} ||= {};
    $self->{'deletions'}  ||= {};
    $self->{'edits'}      ||= {};

    bless $self, $class;
    return $self;
}

sub to_data
{
    my ($self) = @_;

    return { map { $_ => $self->{$_} }
        qw(first_ts last_ts threads
           deliveries deletions edits)
    };
}

sub _process_response
{
    my ($res) = @_;

    if (not $res->is_success()) {
        my $res_str = $res->as_string();
        chomp $res_str;
        print STDERR "Unable to process response: $res_str\n";
        return;
    }
    my $data = decode_json($res->content());
    if ($data->{'error'}) {
        my $res_str = $res->as_string();
        chomp $res_str;
        print STDERR "Error in response: $res_str\n";
        return;
    }

    return $data;
}

sub _check_for_new_threads
{
    my ($messages, $threads) = @_;

    for my $message (@{$messages}) {
        my $thread_ts = $message->thread_ts();
        if ($thread_ts) {
            $threads->{$thread_ts} ||= {
                last_ts    => 1,
                deliveries => {},
                edits      => {},
                deletions  => {},
            };
        }
    }

    return 1;
}

sub _write_new_edits
{
    my ($messages, $first_ts, $thread_ts,
        $edits, $deliveries, $write_cb) = @_;

    for my $message (@{$messages}) {
        my $ts = $message->ts();
        my $edited_ts = $message->edited_ts();
        if ($edited_ts and not $edits->{$edited_ts}) {
            my $parent_id = $message->id(1);
            my $entity = $message->to_entity($first_ts, $thread_ts,
                                             $parent_id);
            $write_cb->($entity);
            $deliveries->{$ts} = 1;
            $edits->{$edited_ts} = 1;
        }
    }

    return 1;
}

sub _delete_absent_messages
{
    my ($deliveries, $context, $ws, $name, $begin_ts, $last_ts,
        $seen_messages, $deletions, $write_cb) = @_;

    my @deliveries_list =
        grep { $_ ge $begin_ts and $_ le $last_ts }
            keys %{$deliveries};
    for my $ts (@deliveries_list) {
        if ($seen_messages->{$ts}) {
            next;
        }
        if ($deletions->{$ts}) {
            next;
        }
        $seen_messages->{$ts} = 1;
        $deletions->{$ts} = 1;
        my $message = App::Paws::Message->new(
            $context, $ws, $name, { ts => $ts }
        );
        my $entity = $message->to_delete_entity();
        $write_cb->($entity);
    }

    return 1;
}

sub _receive_modifications
{
    my ($self) = @_;

    my $context    = $self->{'context'};
    my $ws         = $self->{'workspace'};
    my $id         = $self->{'id'};
    my $name       = $self->{'name'};
    my $write_cb   = $self->{'write_cb'};
    my $first_ts   = $self->{'first_ts'};
    my $last_ts    = $self->{'last_ts'};
    my $threads    = $self->{'threads'};
    my $deliveries = $self->{'deliveries'};
    my $deletions  = $self->{'deletions'};
    my $edits      = $self->{'edits'};
    my $runner     = $context->runner();
    my $begin_ts   = $last_ts - $ws->modification_window();

    my %seen_messages;
    my $history_req = $ws->get_history_request($id, $begin_ts, $last_ts);
    $runner->add('conversations.history', $history_req, sub {
        eval {
            my ($runner, $res, $fn) = @_;
            my $data = _process_response($res);
            if (not $data) {
                return;
            }

            my @messages =
                map { App::Paws::Message->new($context, $ws, $name, $_) }
                    @{$data->{'messages'}};
            _check_for_new_threads(\@messages, $threads);
            _write_new_edits(\@messages, $first_ts, $first_ts,
                             $edits, $deliveries, $write_cb);
            for my $message (@messages) {
                $seen_messages{$message->ts()} = 1;
            }

            if (my $cursor =
                    $data->{'response_metadata'}->{'next_cursor'}) {
                $history_req =
                    $ws->get_history_request($id, $begin_ts,
                                             $last_ts, $cursor);
                $runner->add('conversations.history', $history_req, $fn);
            } else {
                _delete_absent_messages($deliveries, $context, $ws, $name,
                                        $begin_ts, $last_ts,
                                        \%seen_messages,
                                        $deletions, $write_cb);
            }
        };
        if (my $error = $@) {
            print STDERR $error."\n";
        }
    });
}

sub receive_messages
{
    my ($self, $since_ts) = @_;

    my $context    = $self->{'context'};
    my $ws         = $self->{'workspace'};
    my $id         = $self->{'id'};
    my $name       = $self->{'name'};
    my $write_cb   = $self->{'write_cb'};
    my $first_ts   = $self->{'first_ts'};
    my $last_ts    = $self->{'last_ts'};
    my $deliveries = $self->{'deliveries'};
    my $deletions  = $self->{'deletions'};
    my $threads    = $self->{'threads'};
    my $edits      = $self->{'edits'};
    my $runner     = $context->runner();

    if ($since_ts and ($last_ts < $since_ts)) {
        $last_ts = $since_ts;
        $self->{'last_ts'} = $last_ts;
    }

    if ($ws->modification_window() and $first_ts) {
        eval {
            $self->_receive_modifications();
        };
        if (my $error = $@) {
            print STDERR $error."\n";
        }
    }

    my $history_req = $ws->get_history_request($id, $last_ts);
    $runner->add('conversations.history', $history_req, sub {
        my ($runner, $res, $fn) = @_;
        eval {
            my $data = _process_response($res);
            if (not $data) {
                return;
            }

            $first_ts ||= minstr map { $_->{'ts'} } @{$data->{'messages'}};
            $self->{'first_ts'} = $first_ts;

            my @messages =
                map { App::Paws::Message->new($context, $ws,
                                              $name, $_) }
                    @{$data->{'messages'}};
            _check_for_new_threads(\@messages, $threads);
            for my $message (@messages) {
                my $ts = $message->ts();
                my $entity = $message->to_entity($first_ts, $first_ts);
                $write_cb->($entity);
                $deliveries->{$ts} = 1;
                if ($ts > $last_ts) {
                    $last_ts = $ts;
                }
            }

            if ($data->{'has_more'}) {
                $history_req =
                    $ws->get_history_request($id, $self->{'last_ts'});
                $runner->add('conversations.history', $history_req, $fn);
            }
        };
        if (my $error = $@) {
            print STDERR $error."\n";
        }
        $self->{'last_ts'} = $last_ts;
    });

    my @unneeded_deliveries =
        grep { $_ < ($last_ts
                        - $ws->modification_window()
                        - UNNEEDED_BUFFER()) }
            keys %{$deliveries};
    delete @{$deliveries}{@unneeded_deliveries};

    return 1;
}

sub _receive_thread_modifications
{
    my ($self, $since_ts) = @_;

    my $context    = $self->{'context'};
    my $ws         = $self->{'workspace'};
    my $id         = $self->{'id'};
    my $name       = $self->{'name'};
    my $write_cb   = $self->{'write_cb'};
    my $first_ts   = $self->{'first_ts'};
    my $last_ts    = $self->{'last_ts'};
    my $threads    = $self->{'threads'};
    my $runner     = $context->runner();
    my $begin_ts   = $last_ts - $ws->modification_window();

    my $modification_window = $ws->modification_window();

    for my $thread_ts (keys %{$threads}) {
        my $thread_data = $threads->{$thread_ts};
        my $last_ts     = $thread_data->{'last_ts'} || 1;
        my $deliveries  = $thread_data->{'deliveries'};
        my $deletions   = $thread_data->{'deletions'};
        my $edits       = $thread_data->{'edits'};

        if ($since_ts and ($last_ts < $since_ts)) {
            $last_ts = $since_ts;
            $thread_data->{'last_ts'} = $last_ts;
        }
        if (($last_ts != 1)
                and ($last_ts < (time() - $ws->thread_expiry()))) {
            next;
        }

        my %seen_messages;
        my $replies_req =
            $ws->get_replies_request($id, $thread_ts, $begin_ts, $last_ts);
        $runner->add('conversations.replies', $replies_req, sub {
            my ($runner, $res, $fn) = @_;
            eval {
                my $data = _process_response($res);
                if (not $data) {
                    return;
                }

                my @messages =
                    map { App::Paws::Message->new($context, $ws, $name, $_) }
                        @{$data->{'messages'}};
                _write_new_edits(\@messages, $first_ts, $thread_ts,
                                 $edits, $deliveries, $write_cb);
                for my $message (@messages) {
                    $seen_messages{$message->ts()} = 1;
                }

                if (my $cursor =
                        $data->{'response_metadata'}->{'next_cursor'}) {
                    $replies_req =
                        $ws->get_replies_request($id, $thread_ts, $begin_ts,
                                                 $last_ts, $cursor);
                    $runner->add('conversations.replies', $replies_req, $fn);
                } else {
                    _delete_absent_messages($deliveries, $context, $ws, $name,
                                            $begin_ts, $last_ts,
                                            \%seen_messages,
                                            $deletions, $write_cb);
                }
            };
            if (my $error = $@) {
                print STDERR $error."\n";
            }
        });
    }

    return 1;
}

sub receive_threads
{
    my ($self, $since_ts) = @_;

    my $context    = $self->{'context'};
    my $ws         = $self->{'workspace'};
    my $id         = $self->{'id'};
    my $name       = $self->{'name'};
    my $write_cb   = $self->{'write_cb'};
    my $first_ts   = $self->{'first_ts'};
    my $last_ts    = $self->{'last_ts'};
    my $threads    = $self->{'threads'};
    my $runner     = $context->runner();
    my $begin_ts   = $last_ts - $ws->modification_window();

    if ($since_ts and ($last_ts < $since_ts)) {
        $last_ts = $since_ts;
        $self->{'last_ts'} = $last_ts;
    }

    if ($ws->modification_window() and $first_ts) {
        eval {
            $self->_receive_thread_modifications($since_ts);
        };
        if (my $error = $@) {
            print STDERR $error."\n";
        }
    }

    for my $thread_ts (keys %{$threads}) {
        my $thread_data = $threads->{$thread_ts};
        my $last_ts     = $thread_data->{'last_ts'};
        my $deliveries  = $thread_data->{'deliveries'};
        my $deletions   = $thread_data->{'deletions'};
        my $edits       = $thread_data->{'edits'};

        if ($since_ts and ($last_ts < $since_ts)) {
            $last_ts = $since_ts;
            $thread_data->{'last_ts'} = $last_ts;
        }
        if (($last_ts != 1)
                and ($last_ts < (time() - $ws->thread_expiry()))) {
            next;
        }

        my $replies_req =
            $ws->get_replies_request($id, $thread_ts, $last_ts);
        $runner->add('conversations.replies', $replies_req, sub {
            my ($runner, $res, $fn) = @_;
            eval {
                my $data = _process_response($res);
                if (not $data) {
                    return;
                }

                my @messages =
                    map { App::Paws::Message->new($context, $ws,
                                                  $name, $_) }
                        @{$data->{'messages'}};
                for my $message (@messages) {
                    my $ts = $message->ts();
                    if ($ts eq $thread_ts) {
                        next;
                    }
                    my $entity = $message->to_entity($first_ts, $thread_ts);
                    $write_cb->($entity);
                    $deliveries->{$ts} = 1;
                    if ($ts > $last_ts) {
                        $last_ts = $ts;
                    }
                }

                if ($data->{'has_more'}) {
                    $replies_req =
                        $ws->get_replies_request($id, $thread_ts, $last_ts);
                    $runner->add('conversations.replies', $replies_req, $fn);
                }
            };
            if (my $error = $@) {
                print STDERR $error,"\n";
            }
            $thread_data->{'last_ts'} = $last_ts;
        });

        my @unneeded_deliveries =
            grep { $_ < ($last_ts
                            - $ws->modification_window()
                            - UNNEEDED_BUFFER()) }
                keys %{$deliveries};
        delete @{$deliveries}{@unneeded_deliveries};
    }

    my @unneeded_threads =
        grep { my $last_ts = $threads->{$_}->{'last_ts'};
               ($last_ts != 1)
                    and ($last_ts < (time() - $ws->thread_expiry()
                                            - UNNEEDED_BUFFER())) }
            keys %{$threads};
    delete @{$threads}{@unneeded_threads};

    return 1;
}

1;

__END__

=head1 NAME

App::Paws::ConversationStorage

=head1 DESCRIPTION

Keep a local copy of a Slack conversation up to date.

=head1 CONSTRUCTOR

=over 4

=item B<new>

Arguments (hash):

=over 8

=item context

The current L<App::Paws::Context> object.

=item workspace

The L<App::Paws::Workspace> object for the
workspace of this conversation.

=item id

The unique identifier for the conversation
(e.g. 'C00000001').  Typically a letter followed
by a series of numbers.

=item name

The name of the conversation.  Typically the type
of the conversation (e.g. 'im', 'channel'),
followed by a forward slash, followed by a string
description of the conversation (e.g. a username
for an IM conversation, a channel name for a
channel conversation).

=item write_cb

A coderef that takes a L<MIME::Entity> and writes
it to storage.

=item data

For a conversation that has already been processed
at least once: the hashref of data returned by
calling L<to_data> once that previous processing
had completed.

=back

Returns a new instance of L<App::Paws::ConversationStorage>.

=back

=head1 PUBLIC METHODS

=over 4

=item B<to_data>

Returns a hashref of data that must be passed as the C<data> argument
on a subsequent call to L<new> in order to resynchronise the
conversation.

=item B<receive_messages>

Receive new messages for this conversation, writing them to disk by
way of the C<write_cb> callback.

=item B<receive_threads>

Receive new threads and thread replies in this conversation, writing
them to disk by way of the C<write_cb> callback.

=back

=head1 AUTHOR

Tom Harrison (C<tomh5908@gmail.com>)

=head1 COPYRIGHT & LICENCE

Copyright (c) 2020, Tom Harrison
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.
  * Neither the name of the copyright holder nor the
    names of its contributors may be used to endorse or promote products
    derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut