package App::Paws::Sender;

use warnings;
use strict;

use Digest::MD5 qw(md5_hex);
use Fcntl qw(O_CREAT O_EXCL);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use HTTP::Request;
use HTTP::Request::Common qw(POST);
use JSON::XS qw(decode_json encode_json);
use List::Util qw(first);
use List::MoreUtils qw(uniq);
use LWP::UserAgent;
use MIME::Entity;
use MIME::Parser;
use POSIX qw(strftime);
use Sys::Hostname;
use URI;

use App::Paws::Lock;
use App::Paws::Utils qw(get_mail_date);

my $MAX_FAILURE_COUNT = 5;

sub new
{
    my $class = shift;
    my %args = @_;
    my $self = \%args;
    bless $self, $class;
    return $self;
}

sub _write_bounce
{
    my ($self, $message_id, $error_message) = @_;

    my $bounce_dir = $self->{'bounce_dir'};
    my $context = $self->{'context'};
    $error_message ||= 'no additional error detail provided';

    my $fn = time().'.'.$$.'.'.int(rand(1000000));
    my $date = get_mail_date(time());
    my $domain = $context->domain_name();
    my $to = $context->user_email();
    write_file($bounce_dir.'/tmp/'.$fn, <<EOF);
Date: $date
From: admin\@$domain
To: $to
Subject: Bounce message
Content-Type: text/plain

Unable to deliver message (message ID '$message_id'): $error_message
EOF
    rename($bounce_dir.'/tmp/'.$fn, $bounce_dir.'/new/'.$fn);

    return 1;
}

sub _get_conversation_map
{
    my ($runner, $ws) = @_;

    my $req = $ws->get_conversations_request();
    my @channels;
    $runner->add('conversations.list', $req, sub {
        my ($self, $res, $fn) = @_;

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

        push @channels, @{$data->{'channels'}};

        if (my $cursor = $data->{'response_metadata'}->{'next_cursor'}) {
            my $req = $ws->standard_get_request_only(
                '/conversations.list',
                { cursor => $cursor,
                  types  => 'public_channel,private_channel,mpim,im' }
            );
            $runner->add('conversations.list', $req, $fn);
        }
    });
    while (not $runner->poke()) {
        sleep(0.01);
    }

    my %conversation_map =
        map { $ws->conversation_to_name($_) => $_->{'id'} }
            @channels;

    return \%conversation_map;
}

sub _create_conversation
{
    my ($self, $ws, $message_id, $user_ids) = @_;

    my $context = $self->{'context'};
    my %post_data = (
        users => (join ',', @{$user_ids})
    );

    my $req = HTTP::Request->new();
    $req->header('Content-Type'  => 'application/json; charset=UTF-8');
    $req->header('Authorization' => 'Bearer '.$ws->token());
    $req->uri($context->slack_base_url().'/conversations.open');
    $req->method('POST');
    $req->content(encode_json(\%post_data));

    my $ua = $context->ua();
    my $res = $ua->request($req);
    if (not $res->is_success()) {
        $self->_write_bounce($message_id,
                             "Unable to create new conversation: ".
                             $res->as_string());
        return;
    }
    my $data = decode_json($res->decoded_content());
    if (not $data->{'ok'}) {
        $self->_write_bounce($message_id,
                             "Unable to create new conversation: ".
                             $res->as_string().": ".
                             encode_json(\%post_data));
        return;
    }
    my $conversation_id = $data->{'channel'}->{'id'};
    return $conversation_id;
}

sub _get_conversation_for_single_recipient
{
    my ($self, $to, $message_id) = @_;

    my $context = $self->{'context'};
    my ($local, $domain) = split /@/, $to;
    my ($type, $name) = split /\s*\/\s*/, $local;
    my $thread_ts;
    if ($name =~ /\+/) {
        ($thread_ts) = ($name =~ /.*\+(.*)/);
        $name =~ s/\+.*//;
    }

    my $base = $context->domain_name();
    if ($domain !~ /^(.*)\.$base$/) {
        $self->_write_bounce($message_id,
                             "Message has non-Slack recipient: $to");
        return;
    }
    my $ws_name = $1;
    my $ws = $context->workspaces()->{$ws_name};
    if (not $ws) {
        $self->_write_bounce($message_id,
                             "Workspace '$ws_name' does not exist");
        return;
    }

    my $runner = $context->runner();
    my %conversation_map = %{_get_conversation_map($runner, $ws)};
    my $conversation_id =
        $conversation_map{"$type/$name"}
            || $conversation_map{"im/$name"};

    return ($ws, $conversation_id, $thread_ts);
}

sub _send_queued_single
{
    my ($self, $entity) = @_;

    my $context = $self->{'context'};
    my $ua      = $context->ua();
    my $runner  = $context->runner();

    my @tos =
        map { s/.*<(.*)>.*/$1/g; chomp; $_ }
            split /\s*,\s*/, ($entity->head()->decode()->get('To') || '');

    my @ccs =
        map { s/.*<(.*)>.*/$1/g; chomp; $_ }
            split /\s*,\s*/, ($entity->head()->decode()->get('Cc') || '');

    my $message_id = $entity->head()->decode()->get('Message-ID');

    my $ws;
    my $thread_ts;
    my $base = $context->domain_name();
    my $conversation_id;

    if ((@tos == 1) and not @ccs) {
        ($ws, $conversation_id, $thread_ts) =
            $self->_get_conversation_for_single_recipient(
                $tos[0], $message_id
            );
        if (not $ws) {
            return 1;
        }
    }

    if (not $conversation_id) {
        my @recipients = (@tos, @ccs);
        my @usernames;
        my @ws_names;
        for my $recipient (@recipients) {
            my ($username, $domain) = split /@/, $recipient;
            if ($domain !~ /^(.*)\.$base$/) {
                $self->_write_bounce($message_id,
                                     "Message has non-Slack recipient: ".
                                     $recipient);
                return 1;
            }
            my $ws_name = $1;
            if (not $context->workspaces()->{$ws_name}) {
                $self->_write_bounce($message_id,
                                     "Workspace '$ws_name' does ".
                                     "not exist");
                return 1;
            }
            push @usernames, $username;
            push @ws_names, $ws_name;
        }
        @ws_names = uniq @ws_names;
        if (@ws_names > 1) {
            $self->_write_bounce($message_id,
                                 "Unable to send message to multiple ".
                                 "workspaces");
            return 1;
        }
        $ws = $context->workspaces()->{$ws_names[0]};
        my @user_ids;
        for my $username (@usernames) {
            my $user_id = $ws->name_to_user_id($username);
            if (not $user_id) {
                $self->_write_bounce($message_id,
                                     "Invalid username: '$username'");
                return 1;
            }
            push @user_ids, $user_id;
        }
        @user_ids = uniq @user_ids;
        $conversation_id = $self->_create_conversation($ws, $message_id,
                                                       \@user_ids);
        if (not $conversation_id) {
            return 1;
        }
    }

    if (not $conversation_id) {
        $self->_write_bounce($message_id,
                             "Unable to find conversation ID");
        return 1;
    }

    my $text_data;
    my @attachment_reqs;
    my @temp_files;
    if ($entity->parts() > 0) {
        for (my $i = 0; $i < $entity->parts(); $i++) {
            my $part = $entity->parts($i);
            if (($part->head()->get('Content-Type') =~ /^text\/plain;?/)
                    and not $text_data) {
                $text_data = $part->bodyhandle()->as_string();
                next;
            }

            my $filename = $part->head()->recommended_filename();
            $filename =~ s/\?.*//;
            my $temp_file = File::Temp->new();
            print $temp_file $part->bodyhandle()->as_string();
            $temp_file->flush();
            push @temp_files, $temp_file;
            my $uri = URI->new($context->slack_base_url().'/files.upload');
            my $attachment_req =
                POST($uri,
                     Content_Type => 'form-data',
                     Content      => [
                         file     => [$temp_file->filename()],
                         filename => $filename,
                         title    => $filename,
                         token    => $ws->token(),
                         channels => $conversation_id
                     ]);
            push @attachment_reqs, $attachment_req;
        }
    } else {
        $text_data = $entity->bodyhandle()->as_string();
    }

    my %post_data = (
        channel => $conversation_id,
        text    => $text_data,
        as_user => 1,
        ($thread_ts ? (thread_ts => $thread_ts) : ())
    );

    my $req = HTTP::Request->new();
    $req->header('Content-Type'  => 'application/json');
    $req->header('Authorization' => 'Bearer '.$ws->token());
    $req->uri($context->slack_base_url().'/chat.postMessage');
    $req->method('POST');
    $req->content(encode_json(\%post_data));

    my $res = $ua->request($req);
    if (not $res->is_success()) {
        my $client_warning =
            $res->headers()->header('Client-Warning');
        if ($client_warning eq 'Internal response') {
            print STDERR "Unable to send message, will retry later: ".
                         $res->status_line()."\n";
            return;
        } else {
            $self->_write_bounce($message_id,
                                 $res->as_string());
            return 1;
        }
    }
    my $data = decode_json($res->decoded_content());
    if (not $data->{'ok'}) {
        $self->_write_bounce($message_id,
                             $res->as_string());
        return 1;
    }

    for my $attachment_req (@attachment_reqs) {
        my $res = $ua->request($attachment_req);
        if (not $res->is_success()) {
            print STDERR "Unable to send attachment, bouncing: ".
                         $res->as_string()."\n";
            $self->_write_bounce($message_id,
                                 $res->as_string());
            return 1;
        }
        my $data = decode_json($res->decoded_content());
        if (not $data->{'ok'}) {
            $self->_write_bounce($message_id,
                                 $res->as_string());
            return 1;
        }
    }

    return 1;
}

sub submit
{
    my ($self, $args, $fh) = @_;

    my $context = $self->{'context'};
    my $domain_name = $context->domain_name();
    my @lines = <$fh>;

    my $temp_file = File::Temp->new(UNLINK => 0);
    print $temp_file @lines;
    $temp_file->flush();
    $temp_file->seek(0, 0);

    my $parser = MIME::Parser->new();
    my $parser_dir = tempdir();
    $parser->output_under($parser_dir);
    my $entity = $parser->parse($temp_file);

    my $to = $entity->head()->get('To');
    if ($to !~ /$domain_name/) {
        my $fallback_sendmail = $self->{'fallback_sendmail'};
        my $res = system("$fallback_sendmail ".
                         (join ' ', @{$args})." < ".$temp_file->filename());
        return (not $res);
    }

    my $queue_dir = $context->queue_directory();
    write_file($queue_dir.'/'.$$.'-'.time().'-'.(int(rand(10000))), @lines);

    return 1;
}

sub send_queued
{
    my ($self) = @_;

    my $context = $self->{'context'};
    my $ua      = $context->ua();
    my $to      = $context->user_email();

    my $queue_dir  = $context->queue_directory();
    my $queue_lock = $queue_dir.'/lock';
    my $lock       = App::Paws::Lock->new($queue_lock);

    my $path = $context->db_directory().'/sender';
    if (not -e $path) {
        write_file($path, encode_json({ failures => {} }));
    }
    my $db = decode_json(read_file($path));

    eval {
        my $dh;
        opendir $dh, $queue_dir or die $!;
        while (my $entry = readdir($dh)) {
            if (($entry eq '.') or ($entry eq '..') or ($entry eq 'lock')) {
                next;
            }
            my $entry_path = $queue_dir.'/'.$entry;
            if (-f $entry_path) {
                my $parser = MIME::Parser->new();
                my $parser_dir = tempdir();
                $parser->output_under($parser_dir);
                open my $fh, '<', $entry_path or die $!;
                my $entity = $parser->parse($fh);
                close $fh;

                my $res = $self->_send_queued_single($entity);
                if (not $res) {
                    my $message_id =
                        $entity->head()->decode->get('Message-ID');
                    $db->{'failures'}->{$message_id}++;
                    if ($db->{'failures'}->{$message_id} >= $MAX_FAILURE_COUNT) {
                        $self->_write_bounce(
                            $message_id,
                            'Failed to deliver message '.
                            $db->{'failures'}->{$path}.' times, '.
                            'giving up (message: '.
                            $entity->as_string().')'
                        );
                        unlink $entry_path;
                    }
                } else {
                    unlink $entry_path;
                }
            }
        }
    };

    my $error = $@;
    $lock->unlock();
    if ($error) {
        print STDERR "Unable to process queue: $error\n";
        return;
    }

    write_file($path, encode_json($db));
}

1;
