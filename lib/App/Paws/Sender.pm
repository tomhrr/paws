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
    my ($self, $local, $message_id) = @_;

    my $bounce_dir = $self->{'bounce_dir'};
    my $context = $self->{'context'};

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

Unable to find conversation ID for '$local' (message ID: $message_id).
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
    my ($self, $path) = @_;

    my $context = $self->{'context'};
    my $ua = $context->ua();

    open my $fh, '<', $path or die $!;

    my $parser = MIME::Parser->new();
    my $parser_dir = tempdir();
    $parser->output_under($parser_dir);
    my $entity = $parser->parse($fh);

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

    my $ws = $context->{'workspaces'}->{$ws_name};
    my $token = $ws->{'token'};

    my $data = $ws->get_conversations();
    my $conversations = $data->{'channels'};
    my %conversation_map =
        map { $ws->conversation_to_name($_) => $_->{'id'} }
            @{$conversations};
    my $conversation_id = $conversation_map{$local};

    if (not $conversation_id) {
        my $message_id = $entity->head()->decode()->get('Message-ID');
        $self->_write_bounce($local, $message_id);
        unlink $path;
        close $fh;
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
            my $ft = File::Temp->new();
            print $ft $subentity->bodyhandle()->as_string();
            $ft->flush();
            push @fts, $ft;
            my $uri = URI->new($context->{'slack_base_url'}.'/files.upload');
            my $fn = $subentity->head()->get('Content-Disposition');
            my $r = ($fn =~ s/.*filename=(.*?)[;\b ]/$1/);
            my $sreq = POST($uri,
                            Content_Type => 'form-data',
                            Content      => [
                                file => [$ft->filename()],
                                ($r) ? (filename => $fn) : (),
                                token => $token,
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

    my $req = HTTP::Request->new();
    $req->header('Content-Type'  => 'application/json');
    $req->header('Authorization' => 'Bearer '.$token);
    $req->uri($context->slack_base_url().'/chat.postMessage');
    $req->method('POST');
    $req->content(encode_json(\%post_data));
    for my $r ($req, @sreqs) {
        my $res = $ua->request($r);
        if (not $res->is_success()) {
            die Dumper($res);
        }
    }

    unlink $path;
    close $fh;

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

    eval {
        my $dh;
        opendir $dh, $queue_dir or die $!;
        while (my $entry = readdir($dh)) {
            if ($entry eq 'lock') {
                next;
            }
            $entry = $queue_dir.'/'.$entry;
            if (-f $entry) {
                $self->_send_queued_single($entry);
            }
        }
    };
    my $error = $@;
    $self->_unlock_queue();
    if ($error) {
        die $error;
    }
}

1;
