package App::Paws::ConversationStorage;

use warnings;
use strict;

use JSON::XS qw(decode_json);
use List::Util qw(min minstr first);

use App::Paws::Debug qw(debug);

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
    $self->{'not_found'}  ||= 0;

    $self->{'threads_retrieved'} = {};

    bless $self, $class;
    return $self;
}

sub to_data
{
    my ($self) = @_;

    return { map { $_ => $self->{$_} }
        qw(first_ts last_ts threads
           deliveries deletions edits
           not_found)
    };
}

sub _get_response_str
{
    my ($res) = @_;

    my $req_str = $res->request()->as_string();
    my $res_str = $res->as_string();
    $req_str =~ s/(\r?\n)+$//g;
    $res_str =~ s/(\r?\n)+$//g;

    return $req_str."; ".$res_str;
}

sub _process_response
{
    my ($res) = @_;

    if (not $res->is_success()) {
        print STDERR "Unable to process response: ".
                     _get_response_str($res)."\n";
        return;
    }
    my $data = decode_json($res->content());
    return $data;
}

sub _process_error_response
{
    my ($res) = @_;

    print STDERR "Error in response: ".
                 _get_response_str($res)."\n";

    return;
}

sub _check_for_new_threads
{
    my ($messages, $threads) = @_;

    for my $message (@{$messages}) {
        my $thread_ts = $message->thread_ts();
        if ($thread_ts and not $threads->{$thread_ts}) {
            debug("Adding thread ($thread_ts)");
            $threads->{$thread_ts} = {
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
            debug("Adding edit ($edited_ts)");
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
        grep { $_ > $begin_ts and $_ <= $last_ts }
            keys %{$deliveries};
    for my $ts (@deliveries_list) {
        if ($seen_messages->{$ts}) {
            next;
        }
        if ($deletions->{$ts}) {
            next;
        }
        debug("Adding deletion message ($ts)");
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
    my $ws_name    = $ws->{'name'};
    my $begin_ts   =
        ($last_ts != 1)
            ? $last_ts - $ws->modification_window()
            : $last_ts;

    if ($since_ts and ($last_ts < $since_ts)) {
        debug("$ws_name/$name: since_ts ($since_ts) overwriting ".
              "last_ts ($last_ts)");
        $last_ts = $since_ts;
        $self->{'last_ts'} = $last_ts;
    }

    my %seen_messages;
    my $history_req = $ws->get_history_request($id, $begin_ts);
    $runner->add('conversations.history', $history_req, sub {
        my ($runner, $res, $fn) = @_;
        eval {
            debug("$ws_name/$name: receiving messages");
            my $data = _process_response($res);
            if (not $data) {
                return;
            }
            if (my $error = $data->{'error'}) {
                if ($error eq 'channel_not_found') {
                    if ($self->{'not_found'}) {
                        return;
                    } else {
                        $self->{'not_found'} = 1;
                        _process_error_response($res);
                        return;
                    }
                } else {
                    _process_error_response($res);
                    return;
                }
            }
            $self->{'not_found'} = 0;

            $first_ts ||= minstr map { $_->{'ts'} } @{$data->{'messages'}};
            $self->{'first_ts'} = $first_ts;

            my @messages =
                map { App::Paws::Message->new($context, $ws,
                                              $name, $_) }
                    @{$data->{'messages'}};
            _check_for_new_threads(\@messages, $threads);
            my @old_messages =
                grep { $_->ts() <= $last_ts }
                    @messages;
            my @new_messages =
                grep { $_->ts() >  $last_ts }
                    @messages;
            for my $message (@new_messages) {
                my $ts = $message->ts();
                debug("Adding new message ($ts)");
                my $entity = $message->to_entity($first_ts, $first_ts);
                $write_cb->($entity);
                $deliveries->{$ts} = 1;
                $seen_messages{$ts} = 1;
                if ($ts > $last_ts) {
                    $last_ts = $ts;
                }
            }
            _write_new_edits(\@old_messages, $first_ts, $first_ts,
                             $edits, $deliveries, $write_cb);
            for my $message (@old_messages) {
                my $ts = $message->ts();
                $deliveries->{$ts} = 1;
                $seen_messages{$ts} = 1;
            }

            if (my $cursor =
                    $data->{'response_metadata'}->{'next_cursor'}) {
                debug("Response includes next_cursor, fetching");
                $history_req =
                    $ws->get_history_request($id, $begin_ts,
                                             undef, $cursor);
                $runner->add('conversations.history', $history_req, $fn);
            } else {
                _delete_absent_messages($deliveries, $context, $ws, $name,
                                        $begin_ts, $last_ts,
                                        \%seen_messages,
                                        $deletions, $write_cb);

                my @unneeded_deliveries =
                    grep { $_ < ($last_ts
                                    - $ws->modification_window()
                                    - UNNEEDED_BUFFER()) }
                        keys %{$deliveries};
                delete @{$deliveries}{@unneeded_deliveries};
            }
        };
        if (my $error = $@) {
            print STDERR $error."\n";
        }
        $self->{'last_ts'} = $last_ts;
    });

    return 1;
}

sub receive_threads
{
    my ($self, $since_ts, $thread_ts) = @_;

    my $context    = $self->{'context'};
    my $ws         = $self->{'workspace'};
    my $id         = $self->{'id'};
    my $name       = $self->{'name'};
    my $write_cb   = $self->{'write_cb'};
    my $first_ts   = $self->{'first_ts'};
    my $last_ts    = $self->{'last_ts'};
    my $threads    = $self->{'threads'};
    my $runner     = $context->runner();
    my $ws_name    = $ws->{'name'};

    if ($since_ts and ($last_ts < $since_ts)) {
        debug("$ws_name/$name: since_ts ($since_ts) overwriting ".
              "last_ts ($last_ts) in receive_threads");
        $last_ts = $since_ts;
        $self->{'last_ts'} = $last_ts;
    }

    my @thread_tss = ($thread_ts) ? ($thread_ts) : (keys %{$threads});
    for my $thread_ts (@thread_tss) {
        if ($self->{'threads_retrieved'}->{$thread_ts}) {
            debug("$ws_name/$name: $thread_ts has been retrieved, skipping");
            next;
        }
        my $thread_data = $threads->{$thread_ts};
        if (exists $thread_data->{'expired'}
                and $thread_data->{'expired'} eq '1') {
            debug("$ws_name/$name: $thread_ts is expired, skipping");
            next;
        }
        my $last_ts     = $thread_data->{'last_ts'} || 1;
        my $deliveries  = $thread_data->{'deliveries'};
        my $deletions   = $thread_data->{'deletions'};
        my $edits       = $thread_data->{'edits'};
        my $begin_ts    =
            ($last_ts != 1)
                ? $last_ts - $ws->modification_window()
                : $last_ts;

        if ($since_ts and ($last_ts < $since_ts)) {
            debug("$ws_name/$name: since_ts ($since_ts) overwriting ".
                  "last_ts ($last_ts) for thread ($thread_ts)");
            $last_ts = $since_ts;
            $thread_data->{'last_ts'} = $last_ts;
        }
        if (($last_ts != 1)
                and ($last_ts < (time() - $ws->thread_expiry()))) {
            debug("$ws_name/$name: thread ($thread_ts) is expired, skipping");
            next;
        }

        my %seen_messages;
        my $replies_req =
            $ws->get_replies_request($id, $thread_ts, $begin_ts);
        $runner->add('conversations.replies', $replies_req, sub {
            my ($runner, $res, $fn) = @_;
            eval {
                debug("$ws_name/$name: receiving threads");
                my $data = _process_response($res);
                if (not $data) {
                    return;
                }
                if (my $error = $data->{'error'}) {
                    if ($error eq 'thread_not_found') {
                        if ($thread_data->{'not_found'}) {
                            return;
                        } else {
                            $thread_data->{'not_found'} = 1;
                            _process_error_response($res);
                            return;
                        }
                    } else {
                        _process_error_response($res);
                        return;
                    }
                }
                $thread_data->{'not_found'} = 0;

                my @messages =
                    map { App::Paws::Message->new($context, $ws,
                                                  $name, $_) }
                        @{$data->{'messages'}};
                my @old_messages =
                    grep { $_->ts() <= $last_ts }
                        @messages;
                my @new_messages =
                    grep { $_->ts() >  $last_ts }
                        @messages;
                for my $message (@new_messages) {
                    my $ts = $message->ts();
                    if ($ts eq $thread_ts) {
                        next;
                    }
                    debug("Adding new message ($ts)");
                    my $entity = $message->to_entity($first_ts, $thread_ts);
                    $write_cb->($entity);
                    $deliveries->{$ts} = 1;
                    $seen_messages{$ts} = 1;
                    if ($ts > $last_ts) {
                        $last_ts = $ts;
                    }
                }
                _write_new_edits(\@old_messages, $first_ts, $thread_ts,
                                 $edits, $deliveries, $write_cb);
                for my $message (@old_messages) {
                    my $ts = $message->ts();
                    $deliveries->{$ts} = 1;
                    $seen_messages{$ts} = 1;
                }

                if (my $cursor =
                        $data->{'response_metadata'}->{'next_cursor'}) {
                    debug("Response includes next_cursor, fetching");
                    $replies_req =
                        $ws->get_replies_request($id, $thread_ts, $begin_ts,
                                                 undef, $cursor);
                    $runner->add('conversations.replies', $replies_req, $fn);
                } else {
                    _delete_absent_messages($deliveries, $context, $ws, $name,
                                            $begin_ts, $last_ts,
                                            \%seen_messages,
                                            $deletions, $write_cb);
                    $self->{'threads_retrieved'}->{$thread_ts} = 1;

                    my @unneeded_deliveries =
                        grep { $_ < ($last_ts
                                        - $ws->modification_window()
                                        - UNNEEDED_BUFFER()) }
                            keys %{$deliveries};
                    delete @{$deliveries}{@unneeded_deliveries};

                    if (($last_ts != 1)
                            and ($last_ts < (time() - $ws->thread_expiry()
                                                    - UNNEEDED_BUFFER()))) {
                        debug("Thread ($thread_ts) is unneeded, deleting");
                        $threads->{$thread_ts}->{'expired'} = 1;
                    }
                }
            };
            if (my $error = $@) {
                print STDERR $error,"\n";
            }
            $thread_data->{'last_ts'} = $last_ts;
        });
    }

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

A coderef that takes a L<MIME::Entity> object and
writes it to storage.

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
