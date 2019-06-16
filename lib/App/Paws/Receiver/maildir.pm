package App::Paws::Receiver::maildir;

use warnings;
use strict;

use Encode;
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use HTML::Entities qw(decode_entities);
use HTTP::Request;
use JSON::XS qw(decode_json encode_json);
use List::Util qw(uniq minstr);
use MIME::Entity;
use MIME::Parser;
use POSIX qw(strftime);
use Sys::Hostname;

sub new
{
    my $class = shift;
    my %args = @_;
    my $self = \%args;
    $self->{'workspace'} =
        $self->{'context'}->{'workspaces'}->{$self->{'workspace'}};
    bless $self, $class;
    return $self;
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
    my %data;
    if (@local_parts == 3) {
        %data = (
            ts           => $local_parts[0].'.'.$local_parts[1],
            conversation => $local_parts[2],
        );
    } elsif (@local_parts == 5) {
        %data = (
            edited_ts    => $local_parts[0].'.'.$local_parts[1],
            ts           => $local_parts[2].'.'.$local_parts[3],
            conversation => $local_parts[4],
        );
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
    my $ua = $context->ua();
    my $res = $ua->request($req);
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

sub _get_maildir
{
    my ($self, $conversation) = @_;

    my $maildir_map = $self->{'conversation_to_maildir'};
    my $maildir = $maildir_map->{$conversation}
               || $maildir_map->{'*'};
    return $maildir;
}

sub _write_message
{
    my ($self, $conversation, $message, $first_ts, $thread_ts, $counter,
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

    $entity->head()->delete('X-Mailer');

    my $maildir = $self->_get_maildir($conversation);
    my $fn = $ts.'.'.$$.'_'.$counter++.'.'.hostname();

    write_file($maildir.'/tmp/'.$fn,
               $entity->as_string());
    rename($maildir.'/tmp/'.$fn, $maildir.'/new/'.$fn);

    return 1;
}

sub _get_parser
{
    my ($self) = @_;

    if ($self->{'parser'}) {
        return $self->{'parser'};
    }

    my $parser = MIME::Parser->new();
    my $parser_dir = tempdir();
    $parser->output_under($parser_dir);

    $self->{'parser'} = $parser;
    $self->{'parser_dir'} = $parser_dir;

    return $parser;
}

sub _find_message
{
    my ($self, $conversation, $ts) = @_;

    my $maildir = $self->_get_maildir($conversation);
    if (not $maildir) {
        return;
    }
    my $path_ts = $ts;
    $path_ts =~ s/\..*//;
    my @message_paths = map { chomp; $_ } `find $maildir -iname '$path_ts.*'`;
    if (not @message_paths) {
        return;
    }
    my $parser = $self->_get_parser();
    my @messages;
    for my $message_path (@message_paths) {
        my $entity = $parser->parse_open($message_path);
        my $id = $entity->head()->get('Message-ID');
        chomp $id;
        my $data = $self->_parse_message_id($id);
        if ($data->{'conversation'} ne $conversation) {
            next;
        }
        if ($data->{'ts'} ne $ts) {
            next;
        }
        push @messages, [$message_path, $entity, $data];
    }
    @messages =
        sort { ($a->[2]->{'edited_ts'} || 0) <=>
               ($b->[2]->{'edited_ts'} || 0) }
            @messages;
    my $latest_message = pop @messages;
    return $latest_message;
}

sub _receive_conversation
{
    my ($self, $db, $counter, $conversation_map, $conversation) = @_;

    my $context = $self->{'context'};
    my $ws = $self->{'workspace'};
    my $ws_name = $ws->name();
    my $token = $ws->token();

    my $db_conversation = $db->{$ws_name}->{$conversation} || {};
    my @thread_tss = @{$db_conversation->{'thread_tss'} || []};
    my $stored_last_ts = $db_conversation->{'last_ts'} || 1;
    my $new_last_ts = $stored_last_ts;
    my $conversation_id = $conversation_map->{$conversation};
    if (not $conversation_id) {
        warn "Unable to find conversation '$conversation'";
        return;
    }

    my $modification_window = $ws->modification_window();
    my $first_ts = $db_conversation->{'first_msg_ts'};
    if ($modification_window and $first_ts) {
        eval {
            my $data = $ws->get_history($conversation_id,
                                        ($stored_last_ts -
                                        $modification_window),
                                        $stored_last_ts);
            while (@{$data->{'messages'}}) {
                for my $message (@{$data->{'messages'}}) {
                    if ($message->{'edited'}) {
                        my $message_data =
                            $self->_find_message($conversation,
                                                 $message->{'ts'});
                        if (not $message_data) {
                            next;
                        }
                        if (($message_data->[2]->{'edited_ts'} || 0)
                                eq $message->{'edited'}->{'ts'}) {
                            next;
                        }
                        my $parent_id =
                            $self->_message_to_id($conversation,
                                                  { ts => $message->{'ts'} });
                        $self->_write_message($conversation, $message,
                                              $first_ts, $first_ts,
                                              $$counter++,
                                              $parent_id);
                    }
                }
                if ($data->{'response_metadata'}->{'next_cursor'}) {
                    $data = $ws->get_history($conversation_id,
                                             ($stored_last_ts -
                                             $modification_window),
                                             $stored_last_ts,
                                             $data->{'response_metadata'}
                                                  ->{'next_cursor'});
                } else {
                    last;
                }
            }
        };
        if (my $error = $@) {
            warn $error;
        }
    }

    eval {
        my $data = $ws->get_history($conversation_id, $stored_last_ts);
        while (@{$data->{'messages'}}) {
            $db_conversation->{'first_msg_ts'}
                ||= minstr map { $_->{'ts'} } @{$data->{'messages'}};
            my $first_ts = $db_conversation->{'first_msg_ts'};
            for my $message (@{$data->{'messages'}}) {
                $self->_write_message($conversation, $message,
                              $first_ts, $first_ts, $$counter++);
                if ($message->{'ts'} >= $new_last_ts) {
                    $new_last_ts = $message->{'ts'};
                }
                if ($message->{'thread_ts'}) {
                    push @thread_tss, $message->{'thread_ts'};
                }
            }
            if ($data->{'has_more'}) {
                $data = $ws->get_history($conversation_id, $new_last_ts);
            } else {
                last;
            }
        }
    };
    if (my $error = $@) {
        warn $error;
    }

    $db_conversation->{'last_ts'} = $new_last_ts;
    @thread_tss = uniq @thread_tss;
    $db_conversation->{'thread_tss'} = \@thread_tss;
    my $db_thread_ts = $db_conversation->{'thread_ts'} || {};

    if ($modification_window and $first_ts) {
        eval {
            for my $thread_ts (@thread_tss) {
                my $last_ts = $db_thread_ts->{$thread_ts}->{'last_ts'} || 1;
                eval {
                    my $replies = $ws->get_replies($conversation_id,
                                            $thread_ts,
                                            ($last_ts -
                                            $modification_window),
                                            $last_ts);
                    while (@{$replies->{'messages'}}) {
                        for my $sub_message (@{$replies->{'messages'}}) {
                            if ($sub_message->{'edited'}) {
                                my $message_data =
                                    $self->_find_message($conversation,
                                                        $sub_message->{'ts'});
                                if (not $message_data) {
                                    next;
                                }
                                if (($message_data->[2]->{'edited_ts'} || 0)
                                        eq $sub_message->{'edited'}->{'ts'}) {
                                    next;
                                }
                                my $parent_id =
                                    $self->_message_to_id($conversation,
                                                        { ts => $sub_message->{'ts'} });
                                my $first_ts = $db_conversation->{'first_msg_ts'};
                                $self->_write_message($conversation,
                                                    $sub_message,
                                                    $first_ts, $thread_ts,
                                                    $$counter++,
                                                    $parent_id);
                            }
                        }
                        if ($replies->{'response_metadata'}
                                    ->{'next_cursor'}) {
                            $replies = $ws->get_replies($conversation_id,
                                                $thread_ts,
                                                ($last_ts -
                                                $modification_window),
                                                $last_ts,
                                                $replies->{'response_metadata'}
                                                     ->{'next_cursor'});
                        } else {
                            last;
                        }
                    }
                };
                if (my $error = $@) {
                    warn $error;
                }
            }
        };
        if (my $error = $@) {
            warn $error;
        }
    }

    for my $thread_ts (@thread_tss) {
        my $last_ts = $db_thread_ts->{$thread_ts}->{'last_ts'} || 1;
        eval {
            my $replies = $ws->get_replies($conversation_id,
                                      $thread_ts, $last_ts);
            while (@{$replies->{'messages'}}) {
                for my $sub_message (@{$replies->{'messages'}}) {
                    if ($sub_message->{'ts'} eq $thread_ts) {
                        next;
                    }
                    my $first_ts = $db_conversation->{'first_msg_ts'};
                    $self->_write_message($conversation, $sub_message,
                                          $first_ts, $thread_ts,
                                          $$counter++);
                    if ($sub_message->{'ts'} >= $last_ts) {
                        $last_ts = $sub_message->{'ts'};
                    }
                }
                if ($replies->{'has_more'}) {
                    $replies = $self->_get_replies($conversation_id,
                                                   $thread_ts, $last_ts);
                } else {
                    last;
                }
            }
        };
        if (my $error = $@) {
            warn $error;
        }
        $db_thread_ts->{$thread_ts}->{'last_ts'} = $last_ts;
    }

    $db_conversation->{'thread_ts'} = $db_thread_ts;
    $db->{$ws_name}->{$conversation} = $db_conversation;

    return 1;
}

sub run
{
    my ($self, $counter) = @_;

    $counter ||= 1;

    my $ws = $self->{'workspace'};

    my $context = $self->{'context'};
    my $ua = $context->ua();
    my $domain_name = $context->domain_name();
    my $to = $context->user_email();
    my $name = $self->{'name'};

    my $path = $context->db_directory().'/'.$name.'-receiver-maildir-db';
    if (not -e $path) {
        write_file($path, '{}');
    }
    my $db = decode_json(read_file($path));

    my $data = $ws->get_conversations();
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

    for my $conversation (@actual_conversations) {
        $self->_receive_conversation($db, \$counter,
                                     \%conversation_map,
                                     $conversation);
    }
    write_file($path, encode_json($db));
}

1;
