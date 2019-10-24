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
use List::Util qw(uniq min minstr first);
use MIME::Entity;
use POSIX qw(strftime);
use Sys::Hostname;
use Time::HiRes qw(sleep);

sub new
{
    my $class = shift;
    my %args = @_;
    my $self = \%args;
    bless $self, $class;
    return $self;
}

sub _lock
{
    my ($self) = @_;

    my $db_dir = $self->{'context'}->db_directory();
    my $lock = $db_dir.'/lock';
    my $fh;
    my $count = 10;
    for (;;) {
        my $res = sysopen $fh, $lock, O_CREAT | O_EXCL;
        if ($fh) {
            last;
        }
        $count--;
        sleep(1);
    }
    if (not $fh) {
        die "Unable to secure lock $lock after 10 seconds.";
    }

    return 1;
}

sub _unlock
{
    my ($self) = @_;

    my $db_dir = $self->{'context'}->db_directory();
    my $lock = $db_dir.'/lock';
    unlink $lock;
}

sub _get_mail_date
{
    return strftime("%a, %d %b %Y %H:%M:%S %z", localtime($_[0]));
}

sub _message_to_id
{
    my ($self, $conversation, $message) = @_;

    my $context = $self->{'context'};
    my $ws_name = $self->{'workspace'}->name();

    my $orig_ts = $message->{'ts'};
    my $domain_name = $context->domain_name();
    my $local_part = "$orig_ts.$conversation";
    if ($message->{'edited'}) {
        $local_part = $message->{'edited'}->{'ts'}.'.'.$local_part;
    }
    return "<$local_part\@$ws_name.$domain_name>";
}

sub _parse_message_id
{
    my ($self, $message_id) = @_;

    $message_id =~ s/^<//;
    $message_id =~ s/\@.*>$//;
    my @local_parts = split /\./, $message_id;
    my $deleted = 0;
    if ($local_parts[$#local_parts] eq 'deleted') {
        pop @local_parts;
        $deleted = 1;
    }
    my %data;
    if (@local_parts == 3) {
        %data = (
            ts           => $local_parts[0].'.'.$local_parts[1],
            conversation => $local_parts[2],
            deleted      => $deleted,
        );
    } elsif (@local_parts == 5) {
        %data = (
            edited_ts    => $local_parts[0].'.'.$local_parts[1],
            ts           => $local_parts[2].'.'.$local_parts[3],
            conversation => $local_parts[4],
            deleted      => $deleted,
        );
    } else {
        die "Unexpected local part count: ".(scalar @local_parts);
    }
    return \%data;
}

sub _add_attachment
{
    my ($self, $entity, $file) = @_;

    my $context = $self->{'context'};
    my $token = $self->{'workspace'}->token();

    my $req = HTTP::Request->new();
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');
    $req->header('Authorization' => 'Bearer '.$token);
    my $url_private = $file->{'url_private'};
    if ($url_private =~ /^\//) {
        $url_private = $context->slack_base_url().$url_private;
    }
    $req->uri($url_private);
    $req->method('GET');
    my $filename = $file->{'url_private'};
    $filename =~ s/.*\///;
    my $res;
    my $runner = $context->{'runner'};
    $runner->add('conversations.replies', $req, [],
                 sub { my ($runner, $internal_res) = @_;
                       $res = $internal_res; });
    while (not $res) {
        $runner->poke();
    }
    $entity->attach(Type     => $file->{'mimetype'},
                    Data     => $res->content(),
                    Filename => $filename);
}

sub _substitute_user_mentions
{
    my ($self, $content) = @_;

    my $ws = $self->{'workspace'};
    my @ats = ($content =~ /<\@(U.*?)>/g);
    my %at_map = map { $_ => $ws->user_id_to_name($_) } @ats;
    for my $at (keys %at_map) {
        if (my $name = $at_map{$at}) {
            $content =~ s/<\@$at>/<\@$name>/g;
        }
    }

    return $content;
}

sub _write_message
{
    my ($self, $conversation, $message, $first_ts, $thread_ts,
        $reply_to_id) = @_;

    my $context = $self->{'context'};
    my $ws = $self->{'workspace'};
    my $ws_name = $ws->name();

    my $token = $ws->token();
    my $reply_to_thread = ($thread_ts ne $first_ts);

    my $ts = $message->{'ts'};
    $ts =~ s/\..*//;

    my $from_user = 'unknown';
    if ($message->{'user'}) {
        my $name = $ws->user_id_to_name($message->{'user'});
        if ($name) {
            $from_user = $name;
        }
    }

    my $content = $self->_substitute_user_mentions($message->{'text'});

    my $domain_name = $context->domain_name();
    my $ws_domain_name = "$ws_name.$domain_name";
    my $message_id = $self->_message_to_id($conversation, $message);

    my $entity = MIME::Entity->build(
        Date         => _get_mail_date($ts),
        From         => "$from_user\@$ws_domain_name",
        To           => $context->user_email(),
        Subject      => "Message from $conversation".
                        ($message->{'edited'} ? ' (edited)' : ''),
        'Message-ID' => $message_id,
        Charset      => 'UTF-8',
        Encoding     => 'base64',
        Data         => Encode::encode('UTF-8', decode_entities($content),
                                       Encode::FB_CROAK)
    );

    for my $file (@{$message->{'files'} || []}) {
        $self->_add_attachment($entity, $file);
    }

    my $parent_id =
        $self->_message_to_id($conversation, { ts => $thread_ts });
    if (($parent_id ne $message_id) or $reply_to_id) {
        $entity->head()->add('In-Reply-To', ($reply_to_id || $parent_id));
        if ($reply_to_thread) {
            my $first_id =
                $self->_message_to_id($conversation, { ts => $first_ts });
            $entity->head()->add('References', "$first_id $parent_id");
        } else {
            $entity->head()->add('References', "$parent_id");
        }
    }

    my $reply_to =
        ($reply_to_thread)
            ? "$conversation+$thread_ts\@$ws_domain_name\n"
            : "$conversation\@$ws_domain_name\n";
    $entity->head()->add('Reply-To', $reply_to);
    $entity->head()->add('X-Paws-Thread-TS', $thread_ts);
    $entity->head()->delete('X-Mailer');

    $self->{'write_callback'}->($entity);

    return 1;
}

sub _write_delete_message
{
    my ($self, $ws_name, $conversation, $ts) = @_;

    my $context = $self->{'context'};

    my $message_id = $self->_message_to_id($conversation, { ts => $ts });
    my $del_message_id = $message_id;
    $del_message_id =~ s/@/.deleted@/;

    my $domain_name = $context->domain_name();
    my $ws_domain_name = "$ws_name.$domain_name";

    my $time = time();
    my $entity = MIME::Entity->build(
        Date          => _get_mail_date($time),
        From          => "paws-admin\@$ws_domain_name",
        To            => $context->user_email(),
        Subject       => "Message from $conversation (deleted)",
        'Message-ID'  => $del_message_id,
        'References'  => $message_id,
        Charset       => 'UTF-8',
        Encoding      => 'base64',
        Data          => 'Message deleted.',
    );
    $entity->head()->add('In-Reply-To', $message_id);

    $self->{'write_callback'}->($entity);

    return 1;
}

sub _receive_conversation
{
    my ($self, $db_conversation, $conversation_map, $conversation) = @_;

    my $context = $self->{'context'};
    my $ws = $self->{'workspace'};
    my $ws_name = $ws->name();
    my $token = $ws->token();

    my $thread_tss = $db_conversation->{'thread_tss'} || [];
    $db_conversation->{'thread_tss'} = $thread_tss;
    my $stored_last_ts = $db_conversation->{'last_ts'} || 1;
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
                        $history_req, [], sub {
                my ($runner, $res, $fn) = @_;
                eval {
                    if (not $res->is_success()) {
                        die Dumper($res);
                    }
                    my $data = decode_json($res->content());
                    if ($data->{'error'}) {
                        die Dumper($data);
                    }
                    my %seen_messages;
                    for my $message (@{$data->{'messages'} || []}) {
                        $seen_messages{$message->{'ts'}} = 1;
                        if ($message->{'edited'}) {
                            if ($edits->{$message->{'edited'}->{'ts'}}) {
                                next;
                            }
                            my $parent_id =
                                $self->_message_to_id(
                                    $conversation,
                                    { ts => $message->{'ts'} });
                            $self->_write_message($conversation, $message,
                                                $first_ts, $first_ts,
                                                $parent_id);
                            $deliveries->{$message->{'ts'}} = 1;
                            $edits->{$message->{'edited'}->{'ts'}} = 1;
                        }
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
                            $history_req, [], $fn);
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
                            $self->_write_delete_message($ws_name, $conversation, $ts,
                                                            );
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
                    $history_req, [], sub {
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
                for my $message (@{$data->{'messages'}}) {
                    $self->_write_message($conversation, $message,
                                $first_ts, $first_ts);
                    $deliveries->{$message->{'ts'}} = 1;
                    if ($message->{'ts'} >=
                            ($db_conversation->{'last_ts'} || 1)) {
                        $db_conversation->{'last_ts'} = $message->{'ts'};
                    }
                    if ($message->{'thread_ts'}) {
                        if (not grep { $_ eq $message->{'thread_ts'} }
                                @{$thread_tss}) {
                            push @{$thread_tss}, $message->{'thread_ts'};
                        }
                    }
                }
                if ($data->{'has_more'}) {
                    $history_req =
                        $ws->get_history_request(
                            $conversation_id,
                            $db_conversation->{'last_ts'});
                    $runner->add('conversations.history',
                        $history_req, [], $fn);
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
    my ($self, $db_conversation, $conversation_map, $conversation) = @_;

    my $context = $self->{'context'};
    my $ws = $self->{'workspace'};
    my $ws_name = $ws->name();
    my $token = $ws->token();

    my @thread_tss = @{$db_conversation->{'thread_tss'} || []};
    my $stored_last_ts = $db_conversation->{'last_ts'} || 1;
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
                if ($last_ts < (time() - (60 * 60 * 24 * 7))) {
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
                            $replies_req, [], sub {
                    my ($runner, $res, $fn) = @_;
                    eval {
                        if (not $res->is_success()) {
                            die Dumper($res);
                        }
                        my $replies = decode_json($res->content());
                        if ($replies->{'error'}) {
                            die Dumper($replies);
                        }
                        my %seen_messages;
                        for my $sub_message (@{$replies->{'messages'}}) {
                            $seen_messages{$sub_message->{'ts'}} = 1;
                            if ($sub_message->{'edited'}) {
                                if ($edits->{$sub_message->{'edited'}->{'ts'}}) {
                                    next;
                                }
                                my $parent_id =
                                    $self->_message_to_id(
                                        $conversation,
                                        { ts => $sub_message->{'ts'} });
                                $self->_write_message($conversation,
                                                    $sub_message,
                                                    $first_ts, $thread_ts,
                                                    $parent_id);
                                $deliveries->{$sub_message->{'ts'}} = 1;
                                $edits->{$sub_message->{'edited'}->{'ts'}} = 1;
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
                                $replies_req, [], $fn);
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
                                $self->_write_delete_message($ws_name,
                                                            $conversation, $ts,
                                                            );
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
        if ($last_ts < (time() - (60 * 60 * 24 * 7))) {
            next;
        }
        my $deliveries = $db_thread_ts->{$thread_ts}->{'deliveries'} || {};
        my $deletions = $db_thread_ts->{$thread_ts}->{'deletions'} || {};
        my $edits = $db_thread_ts->{$thread_ts}->{'edits'} || {};

        my $replies_req = $ws->get_replies_request($conversation_id,
                                           $thread_ts, $last_ts);
        my $runner = $self->{'context'}->runner();
        my $id = $runner->add('conversations.replies',
                     $replies_req, [], sub {
                        my ($runner, $res, $fn) = @_;
                        eval {
			if (not $res->is_success()) {
			    die Dumper($res);
			}
			my $replies = decode_json($res->content());
			if ($replies->{'error'}) {
			    die Dumper($replies);
			}
                        for my $sub_message (@{$replies->{'messages'}}) {
                            if ($sub_message->{'ts'} eq $thread_ts) {
                                next;
                            }
                            my $first_ts = $db_conversation->{'first_msg_ts'};
                            $self->_write_message($conversation, $sub_message,
                                                $first_ts, $thread_ts,
                                                );
                            $deliveries->{$sub_message->{'ts'}} = 1;
                            if ($sub_message->{'ts'} >= $last_ts) {
                                $last_ts = $sub_message->{'ts'};
                            }
                        }
                        if ($replies->{'has_more'}) {
                            $replies_req = $ws->get_replies_request($conversation_id,
                                                        $thread_ts, $last_ts);
                            my $new_id = $runner->add('conversations.replies',
                                            $replies_req, [],
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
    my ($self) = @_;

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

    my $req = $ws->get_conversations_request();
    my $data;
    my $runner = $self->{'context'}->runner();
    $runner->add('conversations.list',
                 $req, [], sub {
                    my ($self, $res) = @_;
                    if (not $res->is_success()) {
                        die Dumper($res);
                    }
                    $data = decode_json($res->content());
                    if ($data->{'error'}) {
                        die Dumper($data);
                    } });
    while (not $runner->poke()) {
        sleep(0.01);
    }

    my @conversations =
        grep { $_->{'is_im'} or $_->{'is_member'} }
            @{$data->{'channels'}};
    my %conversation_map =
        map { $ws->conversation_to_name($_) => $_->{'id'} }
            @conversations;
    my @conversation_names = keys %conversation_map;

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

    my @sorted_conversations;
    my $res = tie @sorted_conversations, 'IPC::Shareable', 'pws1',
                  { create => 1 };
    if (not $res) {
        die "Unable to tie sorted conversations";
    }
    my $finished_dir = tempdir();

    @sorted_conversations =
        sort { $conversation_to_last_ts{$b} <=>
               $conversation_to_last_ts{$a} }
            @actual_conversations;

    for my $conversation (@sorted_conversations) {
        my $db_conversation = $db->{$ws_name}->{$conversation} || {};
        $db->{$ws_name}->{$conversation} = $db_conversation;
        $self->_receive_conversation($db_conversation,
                                        \%conversation_map,
                                        $conversation);
    }
    while (not $runner->poke()) {
        sleep(0.01);
    }

    for my $conversation (@sorted_conversations) {
        my $db_conversation = $db->{$ws_name}->{$conversation} || {};
        $db->{$ws_name}->{$conversation} = $db_conversation;
        $self->_receive_conversation_threads($db_conversation,
                                             \%conversation_map,
                                             $conversation);
    }
    while (not $runner->poke()) {
        sleep(0.01);
    }

    write_file($path, encode_json($db));
}

sub run
{
    my ($self) = @_;

    $self->_lock();
    eval { $self->_run_internal(); };
    my $error = $@;
    $self->_unlock();
    if ($error) {
        die $error;
    }
    return 1;
}

1;
