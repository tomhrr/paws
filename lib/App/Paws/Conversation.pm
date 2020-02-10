package App::Paws::Conversation;

use warnings;
use strict;

use JSON::XS qw(decode_json);
use List::Util qw(min minstr first);

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
    }

    return 1;
}

1;
