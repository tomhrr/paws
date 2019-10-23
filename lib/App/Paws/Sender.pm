package App::Paws::Sender;

use warnings;
use strict;

use Data::Dumper;
use Fcntl qw(O_CREAT O_EXCL);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use HTTP::Request;
use HTTP::Request::Common qw(POST);
use JSON::XS qw(decode_json encode_json);
use List::Util qw(first);
use LWP::UserAgent;
use MIME::Entity;
use MIME::Parser;
use POSIX qw(strftime);
use Sys::Hostname;
use URI;

my $MAX_FAILURE_COUNT = 5;

sub new
{
    my $class = shift;
    my %args = @_;
    my $self = \%args;
    bless $self, $class;
    return $self;
}

sub _get_mail_date
{
    return strftime("%a, %d %b %Y %H:%M:%S %z", localtime($_[0]));
}

sub _write_bounce
{
    my ($self, $message_id, $error_message) = @_;

    my $bounce_dir = $self->{'bounce_dir'};
    my $context = $self->{'context'};
    $error_message ||= 'no additional error detail provided';

    my $fn = time().'.'.$$.'.'.int(rand(1000000));
    my $date = _get_mail_date(time());
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

sub _lock_queue
{
    my ($self) = @_;

    my $queue_dir = $self->{'context'}->queue_directory();
    my $queue_lock = $queue_dir.'/lock';
    my $fh;
    my $count = 10;
    for (;;) {
        my $res = sysopen $fh, $queue_lock, O_CREAT | O_EXCL;
        if ($fh) {
            last;
        }
        $count--;
        sleep(1);
    }
    if (not $fh) {
        die "Unable to secure lock $queue_lock after 10 seconds.";
    }

    return 1;
}

sub _unlock_queue
{
    my ($self) = @_;

    my $queue_dir = $self->{'context'}->queue_directory();
    my $queue_lock = $queue_dir.'/lock';
    unlink $queue_lock;
}

sub _send_queued_single
{
    my ($self, $entity) = @_;

    my $context = $self->{'context'};
    my $ua = $context->ua();

    my $to = $entity->head()->decode()->get('To');
    if ($to =~ /</) {
        $to =~ s/.*<(.*)>.*/$1/;
    }
    chomp $to;
    my ($local, $domain) = split /@/, $to;
    my ($type, $name) = split /\s*\/\s*/, $local;
    my ($ws_name) = ($domain =~ /(.*?)\./);
    my $thread_ts;
    if ($name =~ /\+/) {
        ($thread_ts) = ($name =~ /.*\+(.*)/);
        $name =~ s/\+.*//;
    }
    my $message_id = $entity->head()->decode()->get('Message-ID');

    my $ws = $context->{'workspaces'}->{$ws_name};
    my $token = $ws->{'token'};

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
        sleep(0.1);
    }

    my $conversations = $data->{'channels'};
    my %conversation_map =
        map { $ws->conversation_to_name($_) => $_->{'id'} }
            @{$conversations};
    my $conversation_id = $conversation_map{$local};

    if (not $conversation_id) {
        my $message_id = $entity->head()->decode()->get('Message-ID');
        $self->_write_bounce($message_id,
                             "unable to find conversation ID for ".
                             "'$local'");
        return 1;
    }

    my $text_data;
    my @sreqs;
    my @fts;
    if ($entity->parts() > 0) {
        for (my $i = 0; $i < $entity->parts(); $i++) {
            my $subentity = $entity->parts($i);
            if (($subentity->head()->get('Content-Type') =~ /^text\/plain;?/)
                    and not $text_data) {
                $text_data = $subentity->bodyhandle()->as_string();
                next;
            }
            my $fn = $subentity->head()->recommended_filename();
            $fn =~ s/\?.*//;
            my $ft = File::Temp->new();
            print $ft $subentity->bodyhandle()->as_string();
            $ft->flush();
            push @fts, $ft;
            my $uri = URI->new($context->{'slack_base_url'}.'/files.upload');
            my $sreq = POST($uri,
                            Content_Type => 'form-data',
                            Content      => [
                                file     => [$ft->filename()],
                                filename => $fn,
                                title    => $fn,
                                token    => $token,
                                channels => $conversation_id
                            ]);
            push @sreqs, $sreq;
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

    $req = HTTP::Request->new();
    $req->header('Content-Type'  => 'application/json');
    $req->header('Authorization' => 'Bearer '.$token);
    $req->uri($context->slack_base_url().'/chat.postMessage');
    $req->method('POST');
    $req->content(encode_json(\%post_data));

    my $res = $ua->request($req);
    if (not $res->is_success()) {
        my $client_warning =
            $res->headers()->header('Client-Warning');
        if ($client_warning eq 'Internal response') {
            warn "Unable to send message, will retry later: ".
                 $res->status_line();
            return;
        } else {
            $self->_write_bounce($message_id,
                                 $res->status_line());
            return 1;
        }
    }

    for my $r (@sreqs) {
        my $res = $ua->request($r);
        if (not $res->is_success()) {
            warn "Unable to send attachment, bouncing: ".
                 $res->status_line();
            $self->_write_bounce($message_id,
                                 $res->status_line());
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

    if (not first { /$domain_name$/ } @{$args}) {
        my $ft = File::Temp->new(UNLINK => 0);
        print $ft @lines;
        $ft->flush();
        my $fallback_sendmail = $self->{'fallback_sendmail'};
        my $res = system("$fallback_sendmail ".
                         (join ' ', @{$args})." < ".$ft->filename());
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
    my $ua = $context->ua();
    my $domain_name = $context->domain_name();
    my $to = $context->user_email();

    $self->_lock_queue();
    my $queue_dir = $context->queue_directory();

    my $path = $context->db_directory().'/sender';
    if (not -e $path) {
        write_file($path, '{}');
    }
    my $db = decode_json(read_file($path));

    eval {
        my $dh;
        opendir $dh, $queue_dir or die $!;
        while (my $entry = readdir($dh)) {
            if ($entry eq 'lock') {
                next;
            }
            $entry = $queue_dir.'/'.$entry;
            if (-f $entry) {
                my $parser = MIME::Parser->new();
                my $parser_dir = tempdir();
                $parser->output_under($parser_dir);
                open my $fh, '<', $entry or die $!;
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
                            'failed to deliver message '.
                            $db->{'failures'}->{$path}.' times, '.
                            'giving up'
                        );
                        unlink $entry;
                    }
                } else {
                    unlink $entry;
                }
            }
        }
    };

    my $error = $@;
    $self->_unlock_queue();
    if ($error) {
        die $error;
    }

    write_file($path, encode_json($db));
}

1;
