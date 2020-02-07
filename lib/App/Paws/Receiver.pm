package App::Paws::Receiver;

use warnings;
use strict;

use Data::Dumper;
use Digest::MD5 qw(md5_hex);
use Encode;
use Fcntl qw(O_CREAT O_EXCL);
use File::Basename qw(basename);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use HTML::Entities qw(decode_entities);
use HTTP::Request;
use IPC::Shareable qw(:lock);
use JSON::XS qw(decode_json encode_json);
use List::Util qw(min minstr first);
use List::MoreUtils qw(uniq);
use MIME::Entity;
use POSIX qw(strftime);
use Sys::Hostname;
use Time::HiRes qw(sleep);

use App::Paws::Lock;
use App::Paws::Message;

sub new
{
    my $class = shift;
    my %args = @_;
    my $self = \%args;
    bless $self, $class;
    return $self;
}

sub _receive_conversation
{
    my ($self, $db_conversation, $conversation_map, $conversation,
        $since_ts) = @_;

    my $context = $self->{'context'};
    my $ws = $self->{'workspace'};
    my $ws_name = $ws->name();
    my $token = $ws->token();

    my $thread_tss = $db_conversation->{'thread_tss'} || [];
    $db_conversation->{'thread_tss'} = $thread_tss;

    my $stored_last_ts = $db_conversation->{'last_ts'} || 1;
    if ($since_ts and ($stored_last_ts < $since_ts)) {
        $stored_last_ts = $since_ts;
        $db_conversation->{'last_ts'} = $stored_last_ts;
    }
    my $new_last_ts = $stored_last_ts;
    my $conversation_id = $conversation_map->{$conversation};
    if (not $conversation_id) {
        warn "Unable to find conversation";
        return;
    }

    my $modification_window = $ws->modification_window();
    my $first_ts = $db_conversation->{'first_msg_ts'};
    my $deliveries = $db_conversation->{'deliveries'} || {};
    $db_conversation->{'deliveries'} = $deliveries;
    my $deletions = $db_conversation->{'deletions'} || {};
    $db_conversation->{'deletions'} = $deletions;
    my $edits = $db_conversation->{'edits'} || {};
    $db_conversation->{'edits'} = $edits;
    if ($modification_window and $first_ts) {
        eval {
            my $history_req =
                $ws->get_history_request($conversation_id,
                                        ($stored_last_ts -
                                        $modification_window),
                                        $stored_last_ts);
            my $runner = $self->{'context'}->runner();
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
                                                      $conversation, $_) }
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
                                                $conversation_id,
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
                                $context, $ws, $conversation,
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
            $ws->get_history_request($conversation_id, $stored_last_ts);
        my $runner = $self->{'context'}->runner();
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
                $db_conversation->{'first_msg_ts'}
                    ||= minstr map { $_->{'ts'} } @{$data->{'messages'}};
                my $first_ts = $db_conversation->{'first_msg_ts'};
                $data->{'messages'} = [
                    map { App::Paws::Message->new($context, $ws,
                                                    $conversation, $_) }
                        @{$data->{'messages'}}
                ];
                for my $message (@{$data->{'messages'}}) {
                    my $ts = $message->ts();
                    my $thread_ts = $message->thread_ts();
                    my $entity = $message->to_entity($first_ts, $first_ts);
                    $self->{'write_callback'}->($entity);
                    $deliveries->{$ts} = 1;
                    if ($ts >= ($db_conversation->{'last_ts'} || 1)) {
                        $db_conversation->{'last_ts'} = $ts;
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
                            $conversation_id,
                            $db_conversation->{'last_ts'});
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

sub _receive_conversation_threads
{
    my ($self, $db_conversation, $conversation_map, $conversation,
        $since_ts) = @_;

    my $context = $self->{'context'};
    my $ws = $self->{'workspace'};
    my $ws_name = $ws->name();
    my $token = $ws->token();

    my @thread_tss = @{$db_conversation->{'thread_tss'} || []};
    my $stored_last_ts = $db_conversation->{'last_ts'} || 1;
    if ($since_ts and ($stored_last_ts < $since_ts)) {
        $stored_last_ts = $since_ts;
        $db_conversation->{'last_ts'} = $stored_last_ts;
    }
    my $new_last_ts = $stored_last_ts;
    my $conversation_id = $conversation_map->{$conversation};
    if (not $conversation_id) {
        warn "Unable to find conversation";
        return;
    }

    my $modification_window = $ws->modification_window();
    my $first_ts = $db_conversation->{'first_msg_ts'};
    my $db_thread_ts = $db_conversation->{'thread_ts'} || {};
    $db_conversation->{'thread_ts'} = $db_thread_ts;

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
                    $ws->get_replies_request($conversation_id,
                                            $thread_ts,
                                            ($last_ts -
                                            $modification_window),
                                            $last_ts);
                my $runner = $self->{'context'}->runner();
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
                                                          $conversation, $_) }
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
                                                $conversation_id,
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
                                    $context, $ws, $conversation,
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

        my $replies_req = $ws->get_replies_request($conversation_id,
                                           $thread_ts, $last_ts);
        my $runner = $self->{'context'}->runner();
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
                                                          $conversation, $_) }
                                @{$replies->{'messages'}}
                        ];
                        for my $sub_message (@{$replies->{'messages'}}) {
                            if ($sub_message->ts() eq $thread_ts) {
                                next;
                            }
                            my $first_ts = $db_conversation->{'first_msg_ts'};
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
                            $replies_req = $ws->get_replies_request($conversation_id,
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

sub _run_internal
{
    my ($self, $since_ts) = @_;

    my $ws = $self->{'workspace'};
    my $context = $self->{'context'};
    my $domain_name = $context->domain_name();
    my $to = $context->user_email();
    my $name = $self->{'name'};

    my $path = $context->db_directory().'/'.$name.'-receiver-maildir-db';
    if (not -e $path) {
        write_file($path, '{}');
    }
    my $db = decode_json(read_file($path));
    my $conversation_map = $db->{'conversation-map'} || {};
    my %previous_map = %{$conversation_map};
    my $has_cached = (keys %previous_map > 0) ? 1 : 0;

    my $req = $ws->get_conversations_request();
    my $data;
    my $runner = $self->{'context'}->runner();
    $runner->add('conversations.list',
                 $req, sub {
                    my ($self, $res, $fn) = @_;
                    if (not $res->is_success()) {
                        die Dumper($res);
                    }
                    $data = decode_json($res->content());
                    if ($data->{'error'}) {
                        die Dumper($data);
                    }
                    my @conversations =
                        grep { $_->{'is_im'} or $_->{'is_member'} }
                            @{$data->{'channels'}};
                    my %conversation_map =
                        map { $ws->conversation_to_name($_) => $_->{'id'} }
                            @conversations;
                    $db->{'conversation-map'} =
                        { %{$db->{'conversation-map'} || {}},
                          %conversation_map };
                    $conversation_map = $db->{'conversation-map'};

		    if ($data->{'response_metadata'}->{'next_cursor'}) {
			my $req = $ws->standard_get_request_only(
			    '/conversations.list',
			    { cursor => $data->{'response_metadata'}
					    ->{'next_cursor'},
                              types => 'public_channel,private_channel,mpim,im' }
			);
			$runner->add('conversations.list', $req, $fn);
                    }
                 });
    my $used_cached = 0;
    if ($has_cached) {
        $used_cached = 1;
    } else {
        while (not $runner->poke('conversations.list')) {
            sleep(0.01);
        }
    }

    my @conversation_names = keys %{$conversation_map};

    my @actual_conversations =
        uniq
        map { ($_ eq '*')           ? @conversation_names
            : ($_ =~ /^(.*?)\/\*$/) ? (grep { /^$1\// }
                                            @conversation_names)
                                    : $_ }
            @{$ws->{'conversations'}};

    my $ws_name = $self->{'workspace'}->name();
    my %conversation_to_last_ts =
        map { $_ => $db->{$ws_name}->{$_}->{'last_ts'} || 1 }
            @actual_conversations;

    my @sorted_conversations =
        sort { $conversation_to_last_ts{$b} <=>
               $conversation_to_last_ts{$a} }
            @actual_conversations;

    for my $conversation (@sorted_conversations) {
        my $db_conversation = $db->{$ws_name}->{$conversation} || {};
        $db->{$ws_name}->{$conversation} = $db_conversation;
        $self->_receive_conversation($db_conversation,
                                        $conversation_map,
                                        $conversation,
                                        $since_ts);
    }
    while (not $runner->poke()) {
        sleep(0.01);
    }
    my @new_conversations;
    if ($has_cached) {
        for my $name (keys %{$conversation_map}) {
            if (not $previous_map{$name}) {
                push @new_conversations, $name;
            }
        }
        for my $conversation (@new_conversations) {
            my $db_conversation = $db->{$ws_name}->{$conversation} || {};
            $db->{$ws_name}->{$conversation} = $db_conversation;
            $self->_receive_conversation($db_conversation,
                                            $conversation_map,
                                            $conversation,
                                            $since_ts);
        }
        while (not $runner->poke()) {
            sleep(0.01);
        }
    }

    for my $conversation (@sorted_conversations,
                          @new_conversations) {
        my $db_conversation = $db->{$ws_name}->{$conversation} || {};
        $db->{$ws_name}->{$conversation} = $db_conversation;
        $self->_receive_conversation_threads($db_conversation,
                                             $conversation_map,
                                             $conversation,
                                             $since_ts);
    }
    while (not $runner->poke()) {
        sleep(0.01);
    }

    write_file($path, encode_json($db));
}

sub run
{
    my ($self, $since_ts) = @_;

    my $db_dir = $self->{'context'}->db_directory();
    my $lock_path = $db_dir.'/'.$self->{'name'}.'-lock';
    my $lock = App::Paws::Lock->new($lock_path);
    eval { $self->_run_internal($since_ts); };
    my $error = $@;
    $lock->unlock();
    if ($error) {
        die $error;
    }
    return 1;
}

1;
