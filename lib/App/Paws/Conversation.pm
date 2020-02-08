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
        context        => $args{'context'},
        workspace      => $args{'workspace'},
        write_callback => $args{'write_callback'},
        name           => $args{'name'},
        id             => $args{'id'},
        # edits, deletions, first_msg_ts, last_ts, thread_tss,
        # thread_ts, deliveries.
        %{$args{'data'}},
    };
    $self->{'thread_tss'} ||= [];
    $self->{'thread_ts'} ||= {};
    $self->{'first_msg_ts'} ||= 0;
    $self->{'last_ts'} ||= 1;
    $self->{'deliveries'} ||= {};
    $self->{'deletions'} ||= {};
    $self->{'edits'} ||= {};

    bless $self, $class;
    return $self;
}

sub to_data
{
    my ($self) = @_;

    return { map { $_ => $self->{$_} }
        qw(thread_tss thread_ts first_msg_ts
           last_ts deliveries deletions edits)
    };
}

sub id
{
    return $_[0]->{'id'};
}

sub receive_messages
{
    my ($self, $since_ts) = @_;

    my $context = $self->{'context'};
    my $ws = $self->{'workspace'};
    my $ws_name = $ws->name();
    my $token = $ws->token();

    my $thread_tss = $self->{'thread_tss'};

    my $stored_last_ts = $self->{'last_ts'};
    if ($since_ts and ($stored_last_ts < $since_ts)) {
        $stored_last_ts = $since_ts;
        $self->{'last_ts'} = $stored_last_ts;
    }
    my $new_last_ts = $stored_last_ts;
    my $id = $self->id();

    my $modification_window = $ws->modification_window();
    my $first_ts = $self->{'first_msg_ts'};
    my $deliveries = $self->{'deliveries'};
    my $deletions = $self->{'deletions'};
    my $edits = $self->{'edits'};

    if ($modification_window and $first_ts) {
        eval {
            my $history_req =
                $ws->get_history_request($id,
                                        ($stored_last_ts -
                                        $modification_window),
                                        $stored_last_ts);
            my $runner = $context->runner();
            my $id = $runner->add('conversations.history',
                        $history_req, sub {
                my ($runner, $res, $fn) = @_;
                eval {
                    if (not $res->is_success()) {
                        die Dumper($res);
                    }
                    my $data = decode_json($res->content());
                    if ($data->{'error'}) {
                        die Dumper($data);
                    }
                    $data->{'messages'} = [
                        map { App::Paws::Message->new($context, $ws,
                                                      $self->{'name'}, $_) }
                            @{$data->{'messages'}}
                    ];
                    for my $message (@{$data->{'messages'} || []}) {
                        my $thread_ts = $message->thread_ts();
                        if ($thread_ts) {
                            if (not first { $_ eq $thread_ts } @{$thread_tss}) {
                                push @{$thread_tss}, $thread_ts;
                            }
                        }
                    }

                    my %seen_messages;
                    for my $message (@{$data->{'messages'} || []}) {
                        my $ts = $message->ts();
                        my $edited_ts = $message->edited_ts();
                        if ($edited_ts and not $edits->{$edited_ts}) {
                            if ($edits->{$edited_ts}) {
                                next;
                            }
                            my $parent_id = $message->id(1);
                            my $entity = $message->to_entity(
                                $first_ts, $first_ts, $parent_id
                            );
                            $self->{'write_callback'}->($entity);
                            $deliveries->{$ts} = 1;
                            $edits->{$edited_ts} = 1;
                        }
                        $seen_messages{$ts} = 1;
                    }
                    if ($data->{'response_metadata'}->{'next_cursor'}) {
                        $history_req = $ws->get_history_request(
                                                $id,
                                                ($stored_last_ts -
                                                $modification_window),
                                                $stored_last_ts,
                                                $data->{'response_metadata'}
                                                    ->{'next_cursor'});
                        $runner->add('conversations.history',
                            $history_req, $fn);
                    } else {
                        my @deliveries_list =
                            grep { $_ ge ($stored_last_ts - $modification_window)
                                    and $_ le $stored_last_ts }
                                keys %{$deliveries};
                        for my $ts (@deliveries_list) {
                            if ($deletions->{$ts}) {
                                next;
                            }
                            if ($seen_messages{$ts}) {
                                next;
                            }
                            $seen_messages{$ts} = 1;
                            $deletions->{$ts} = 1;
                            my $del_message = App::Paws::Message->new(
                                $context, $ws, $self->{'name'},
                                { ts => $ts }
                            );
                            my $entity = $del_message->to_delete_entity();
                            $self->{'write_callback'}->($entity);
                        }
                    }
                };
                if (my $error = $@) {
                    warn $error;
                }
            });
        };
        if (my $error = $@) {
            warn $error;
        }
    }

    eval {
        my $history_req =
            $ws->get_history_request($id, $stored_last_ts);
        my $runner = $context->runner();
        my $id = $runner->add('conversations.history',
                    $history_req, sub {
            my ($runner, $res, $fn) = @_;
            eval {
                if (not $res->is_success()) {
                    die Dumper($res);
                }
                my $data = decode_json($res->content());
                if ($data->{'error'}) {
                    die Dumper($data);
                }
                $self->{'first_msg_ts'}
                    ||= minstr map { $_->{'ts'} } @{$data->{'messages'}};
                my $first_ts = $self->{'first_msg_ts'};
                $data->{'messages'} = [
                    map { App::Paws::Message->new($context, $ws,
                                                    $self->{'name'}, $_) }
                        @{$data->{'messages'}}
                ];
                for my $message (@{$data->{'messages'}}) {
                    my $ts = $message->ts();
                    my $thread_ts = $message->thread_ts();
                    my $entity = $message->to_entity($first_ts, $first_ts);
                    $self->{'write_callback'}->($entity);
                    $deliveries->{$ts} = 1;
                    if ($ts >= $self->{'last_ts'}) {
                        $self->{'last_ts'} = $ts;
                    }
                    if ($thread_ts) {
                        if (not first { $_ eq $thread_ts } @{$thread_tss}) {
                            push @{$thread_tss}, $thread_ts;
                        }
                    }
                }
                if ($data->{'has_more'}) {
                    $history_req =
                        $ws->get_history_request(
                            $id,
                            $self->{'last_ts'});
                    $runner->add('conversations.history',
                        $history_req, $fn);
                }
            };
            if (my $error = $@) {
                warn $error;
            }
        });
    };
    if (my $error = $@) {
        warn $error;
    }

    return 1;
}

sub receive_threads
{
    my ($self, $since_ts) = @_;

    my $id = $self->id();
    my $context = $self->{'context'};
    my $ws = $self->{'workspace'};
    my $ws_name = $ws->name();
    my $token = $ws->token();

    my @thread_tss = @{$self->{'thread_tss'}};
    my $stored_last_ts = $self->{'last_ts'};
    if ($since_ts and ($stored_last_ts < $since_ts)) {
        $stored_last_ts = $since_ts;
        $self->{'last_ts'} = $stored_last_ts;
    }
    my $new_last_ts = $stored_last_ts;

    my $modification_window = $ws->modification_window();
    my $first_ts = $self->{'first_msg_ts'};
    my $db_thread_ts = $self->{'thread_ts'};

    if ($modification_window and $first_ts) {
        eval {
            for my $thread_ts (@thread_tss) {
                my $last_ts = $db_thread_ts->{$thread_ts}->{'last_ts'} || 1;
                if ($since_ts and ($last_ts < $since_ts)) {
                    $last_ts = $since_ts;
                    $db_thread_ts->{$thread_ts}->{'last_ts'} = $last_ts;
                }
                if (($last_ts != 1)
                        and ($last_ts < (time() - $ws->thread_expiry()))) {
                    next;
                }
                my $deliveries = $db_thread_ts->{$thread_ts}->{'deliveries'};
                my $deletions = $db_thread_ts->{$thread_ts}->{'deletions'};
                my $edits = $db_thread_ts->{$thread_ts}->{'edits'};

                my $replies_req =
                    $ws->get_replies_request($id,
                                            $thread_ts,
                                            ($last_ts -
                                            $modification_window),
                                            $last_ts);
                my $runner = $context->runner();
                my $id = $runner->add('conversations.replies',
                            $replies_req, sub {
                    my ($runner, $res, $fn) = @_;
                    eval {
                        if (not $res->is_success()) {
                            die Dumper($res);
                        }
                        my $replies = decode_json($res->content());
                        if ($replies->{'error'}) {
                            die Dumper($replies);
                        }
                        $replies->{'messages'} = [
                            map { App::Paws::Message->new($context, $ws,
                                                          $self->{'name'}, $_) }
                                @{$replies->{'messages'}}
                        ];
                        my %seen_messages;
                        for my $sub_message (@{$replies->{'messages'}}) {
                            $seen_messages{$sub_message->ts()} = 1;
                            if ($sub_message->edited_ts()) {
                                if ($edits->{$sub_message->edited_ts()}) {
                                    next;
                                }
                                my $parent_id = $sub_message->id(1);
                                my $entity = $sub_message->to_entity(
                                    $first_ts, $thread_ts, $parent_id
                                );

                                $self->{'write_callback'}->($entity);
                                $deliveries->{$sub_message->ts()} = 1;
                                $edits->{$sub_message->edited_ts()} = 1;
                            }
                        }
                        if ($replies->{'response_metadata'}
                                    ->{'next_cursor'}) {
                            $replies_req = $ws->get_replies_request(
                                                $id,
                                                $thread_ts,
                                                ($last_ts -
                                                $modification_window),
                                                $last_ts,
                                                $replies->{'response_metadata'}
                                                        ->{'next_cursor'});
                            $runner->add('conversations.replies',
                                $replies_req, $fn);
                        } else {
                            my @deliveries_list =
                                grep { $_ ge ($last_ts - $modification_window)
                                        and $_ le $last_ts }
                                    keys %{$deliveries};
                            for my $ts (@deliveries_list) {
                                if ($seen_messages{$ts}) {
                                    next;
                                }
                                if ($deletions->{$ts}) {
                                    next;
                                }
                                $seen_messages{$ts} = 1;
                                $deletions->{$ts} = 1;
                                my $del_message = App::Paws::Message->new(
                                    $context, $ws, $self->{'name'},
                                    { ts => $ts }
                                );
                                my $entity = $del_message->to_delete_entity();
                                $self->{'write_callback'}->($entity);
                            }
                        }
                    };
                    if (my $error = $@) {
                        warn $error;
                    }
                });
            }
        };
        if (my $error = $@) {
            warn $error;
        }
    }

    for my $thread_ts (@thread_tss) {
        my $last_ts = $db_thread_ts->{$thread_ts}->{'last_ts'} || 1;
        if ($since_ts and ($last_ts < $since_ts)) {
            $last_ts = $since_ts;
            $db_thread_ts->{$thread_ts}->{'last_ts'} = $last_ts;
        }
        if (($last_ts != 1)
                and ($last_ts < (time() - $ws->thread_expiry()))) {
            next;
        }
        my $deliveries = $db_thread_ts->{$thread_ts}->{'deliveries'} || {};
        my $deletions = $db_thread_ts->{$thread_ts}->{'deletions'} || {};
        my $edits = $db_thread_ts->{$thread_ts}->{'edits'} || {};

        my $replies_req = $ws->get_replies_request($id,
                                           $thread_ts, $last_ts);
        my $runner = $context->runner();
        my $id = $runner->add('conversations.replies',
                     $replies_req, sub {
                        my ($runner, $res, $fn) = @_;
                        eval {
			if (not $res->is_success()) {
			    die Dumper($res);
			}
			my $replies = decode_json($res->content());
			if ($replies->{'error'}) {
			    die Dumper($replies);
			}
                        $replies->{'messages'} = [
                            map { App::Paws::Message->new($context, $ws,
                                                          $self->{'name'}, $_) }
                                @{$replies->{'messages'}}
                        ];
                        for my $sub_message (@{$replies->{'messages'}}) {
                            if ($sub_message->ts() eq $thread_ts) {
                                next;
                            }
                            my $first_ts = $self->{'first_msg_ts'};
                            my $entity = $sub_message->to_entity(
                                $first_ts, $thread_ts
                            );
                            $self->{'write_callback'}->($entity);
                            $deliveries->{$sub_message->ts()} = 1;
                            if ($sub_message->ts() >= $last_ts) {
                                $last_ts = $sub_message->ts();
                            }
                        }
                        if ($replies->{'has_more'}) {
                            $replies_req = $ws->get_replies_request($id,
                                                        $thread_ts, $last_ts);
                            my $new_id = $runner->add('conversations.replies',
                                            $replies_req,
                                            $fn);
                        }
                    };
                    if (my $error = $@) {
                        warn $error;
                    }
                    $db_thread_ts->{$thread_ts}->{'last_ts'} = $last_ts;
                    $db_thread_ts->{$thread_ts}->{'deliveries'} = $deliveries;
                    $db_thread_ts->{$thread_ts}->{'deletions'} = $deletions;
                    $db_thread_ts->{$thread_ts}->{'edits'} = $edits;
        });
    }

    return 1;
}

1;
