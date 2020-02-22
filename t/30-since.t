#!/usr/bin/perl

use warnings;
use strict;

use App::Paws;
use App::Paws::Context;

use lib './t/lib';
use App::Paws::Test::Server;

use File::Temp qw(tempdir);
use Fcntl qw(SEEK_SET);
use JSON::XS qw(encode_json);
use List::Util qw(first);
use MIME::Parser;
use Time::Local;
use YAML;

use Test::More tests => 6;

my $server = App::Paws::Test::Server->new();
$server->run();
my $url = 'http://localhost:'.$server->{'port'};

my $mail_dir = tempdir();
my $bounce_dir = tempdir();
for my $dir (qw(cur new tmp)) {
    system("mkdir $mail_dir/$dir");
    system("mkdir $bounce_dir/$dir");
}

my $config = {
    domain_name => 'slack.alt',
    user_email => 'test@example.com',
    workspaces => {
        test => {
            token => 'xoxp-asdf',
            conversations => [
                'channel/general',
                'channel/work',
                'im/slackbot',
                'im/user3',
            ],
            modification_window => 3600,
        },
    },
    sender => {
        bounce_dir => $bounce_dir,
        fallback_sendmail => '/bin/true',
    },
    receivers => [ {
        type      => 'maildir',
        name      => 'initial',
        workspace => 'test',
        path      => $mail_dir,
    } ],
    rate_limiting => {
        initial => 1000,
    },
};

my $config_path = File::Temp->new();
print $config_path YAML::Dump($config);
$config_path->flush();
$App::Paws::CONFIG_PATH = $config_path->filename();

my $queue_dir = tempdir();
$App::Paws::QUEUE_DIR = $queue_dir;

my $db_dir = tempdir();
$App::Paws::DB_DIR = $db_dir;

$App::Paws::Context::SLACK_BASE_URL = $url;

sleep(10);
my $paws = App::Paws->new();
$paws->receive(1, undef, time());
my @files = `find $mail_dir -type f`;
is(@files, 0, 'Got no mail (all messages are too old)');

sleep(1);
my $msg_ts = time();
my $mail = File::Temp->new();
print $mail <<EOF;
Content-Type: text/plain; charset="UTF-8"
Content-Disposition: inline
Content-Transfer-Encoding: quoted-printable
MIME-Version: 1.0
Date: Thu, 16 May 2019 15:39:47 +1000
From: slackbot\@test.slack.alt
To: im/slackbot\@test.slack.alt
Subject: Message from im/slackbot
Message-ID: <$msg_ts.000100.im/slackbot\@test.slack.alt>
Reply-To: im/slackbot\@test.slack.alt

If you're not sure how to do something in Slack, *just type your question below*.

Or press these buttons to learn about the following topics:
EOF
$mail->flush();
$mail->seek(0, SEEK_SET);

$paws->send([], $mail);
$paws->send_queued();
$paws->receive(20);
@files = `find $mail_dir -type f`;
is(@files, 1, 'Received mail previously sent (only)');
my ($ts) = `grep X-Paws-Thread-TS $files[0]`;
chomp $ts;
$ts =~ s/.*: //;

my $ua = LWP::UserAgent->new();
my $req = HTTP::Request->new();
$req->method('POST');
$req->uri($url.'/paws.thread.make');
$req->content(encode_json({ channel => 'D00000002',
                            ts      => $ts }));
my $res = $ua->request($req);
ok($res->is_success(), 'Created new thread successfully');

$paws->receive(30);
@files = `find $mail_dir -type f`;
@files = sort @files;
is(@files, 2, 'Got thread message');
my ($thread_ts) = `grep X-Paws-Thread-TS $files[1]`;
chomp $thread_ts;
$thread_ts =~ s/.*: //;

$req = HTTP::Request->new();
$req->uri($url.'/chat.postMessage');
$req->method('POST');
$req->content(encode_json({ channel   => 'D00000002',
                            text      => 'asdf',
                            thread_ts => $thread_ts }));
$res = $ua->request($req);
ok($res->is_success(), 'Replied to thread successfully');

$paws->receive(40, undef, timelocal(0, 0, 0, 1, 1, 3000));
@files = `find $mail_dir -type f`;
is(@files, 2, 'No new mail received');

$server->shutdown();

1;
