#!/usr/bin/perl

use warnings;
use strict;

use App::Paws;
use App::Paws::Context;

use lib './t/lib';
use App::Paws::Test::Server;

use IO::Capture::Stderr;
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use Fcntl qw(SEEK_SET);
use JSON::XS qw(encode_json);
use List::Util qw(first);
use MIME::Parser;
use YAML;

use Test::More tests => 4;

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
        },
        test2 => {
            token => 'xoxp-asdf',
            conversations => [
                'channel/general',
                'channel/work',
                'im/slackbot',
                'im/user3',
            ],
        }
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

my $paws = App::Paws->new();
$paws->receive(1);
my @files = `find $mail_dir -type f`;
is(@files, 11, 'Got 11 mails');

my $make_msg = sub {
    my ($ts, $text) = @_;
    my $mail = File::Temp->new();
    print $mail qq(Content-Type: text/plain; charset="UTF-8"
Content-Disposition: inline
Content-Transfer-Encoding: quoted-printable
MIME-Version: 1.0
Date: Thu, 16 May 2019 15:39:47 +1000
From: slackbot\@test.slack.alt
To: im/slackbot\@test2.slack.alt, im/slackbot\@test.slack.alt
Subject: Message from im/slackbot
Message-ID: <$ts.000100.im/slackbot\@test.slack.alt>
Reply-To: im/slackbot\@test.slack.alt

$text);

    $mail->flush();
    $mail->seek(0, SEEK_SET);
    return $mail;
};

my $mail1 = $make_msg->(time().'.01', 'Testing');
$paws->send([], $mail1);

my $cap = IO::Capture::Stderr->new();
$cap->start();
$paws->send_queued();
$cap->stop();
$paws->receive(20);
@files = `find $mail_dir -type f`;
is(@files, 11, 'Unable to send mail');
my @bounces = `find $bounce_dir -type f`;
is(@bounces, 1, 'Got bounce');
chomp $bounces[0];
my $content = read_file($bounces[0]);
like($content, qr/Unable to send message to multiple workspaces/,
    'Got correct message in bounce');

$server->shutdown();

1;
