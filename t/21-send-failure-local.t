#!/usr/bin/perl

use warnings;
use strict;

use Fcntl qw(SEEK_SET);
use IO::Capture::Stderr;

use App::Paws;
use App::Paws::Context;

use lib './t/lib';
use App::Paws::Test::Server;
use App::Paws::Test::Utils qw(test_setup
                              get_files_in_directory
                              write_message);

use Test::More tests => 11;

my $server = App::Paws::Test::Server->new();
$server->run();
my $url = 'http://localhost:'.$server->{'port'};

my ($mail_dir, $bounce_dir, $config, $config_path) =
    test_setup($url);

my $paws = App::Paws->new();
$paws->receive(1);
my @files = get_files_in_directory($mail_dir);
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
To: im/slackbot\@test.slack.alt
Subject: Message from im/slackbot
Message-ID: <$ts.000100.im/slackbot\@test.slack.alt>
Reply-To: im/slackbot\@test.slack.alt

$text);

    $mail->flush();
    $mail->seek(0, SEEK_SET);
    return $mail;
};

my $mail = write_message('slackbot', 'im/slackbot', 'Internal response');
$paws->send([], $mail);

my $cap = IO::Capture::Stderr->new();
$cap->start();
$paws->send_queued();
$cap->stop();

$paws->receive(20);
@files = get_files_in_directory($mail_dir);
is(@files, 11, 'Unable to send mail');
my @bounces = get_files_in_directory($bounce_dir);
is(@bounces, 0, 'No bounces yet');

for (1..3) {
    $cap->start();
    $paws->send_queued();
    $cap->stop();
}

$paws->receive(40);
@files = get_files_in_directory($mail_dir);
is(@files, 11, 'Still unable to send mail');
@bounces = get_files_in_directory($bounce_dir);
is(@bounces, 0, 'No bounces yet');

$cap->start();
$paws->send_queued();
$cap->stop();

$paws->receive(60);
@files = get_files_in_directory($mail_dir);
is(@files, 11, 'Still unable to send mail');
@bounces = get_files_in_directory($bounce_dir);
is(@bounces, 1, 'Got bounce after five attempts');

my $mail2 = write_message('slackbot', 'im/slackbot', 'Status: 404');
$paws->send([], $mail2);

$cap->start();
$paws->send_queued();
$cap->stop();

$paws->receive(80);
@files = get_files_in_directory($mail_dir);
is(@files, 11, 'Unable to send mail');
@bounces = get_files_in_directory($bounce_dir);
is(@bounces, 2, 'Got immediate bounce for remote problem');

my $mail3 = File::Temp->new();
print $mail3 q(MIME-Version: 1.0
Date: Thu, 01 Jan 1970 10:00:03 +1000
From: user1@test.slack.alt
To: im/user3@test.slack.alt
Subject: Message to im/user3
Message-ID: <3.channel/work@test.slack.alt>
Content-Type: multipart/mixed; boundary="----------=_1559971933-10629-0"
In-Reply-To: <5.channel/work@test.slack.alt>
References: <2.channel/work@test.slack.alt> <5.channel/work@test.slack.alt>
Reply-To: channel/work+5@test.slack.alt

This is a multi-part message in MIME format...

------------=_1559971933-10629-0
Content-Type: text/plain; charset="UTF-8"
Content-Disposition: inline
Content-Transfer-Encoding: base64

dGhyZWFkLXJlcGx5LTIh

------------=_1559971933-10629-0
Content-Type: text/plain; name="file?id=1"
Content-Disposition: inline; filename="file?id=1"
Content-Transfer-Encoding: 8bit

Status: 404
------------=_1559971933-10629-0--);
$mail3->flush();
$mail3->seek(0, SEEK_SET);

$paws->send([], $mail3);

$cap->start();
$paws->send_queued();
$cap->stop();

$paws->receive(100);
@files = get_files_in_directory($mail_dir);
is(@files, 12, 'Sent one message successfully');
@bounces = get_files_in_directory($bounce_dir);
is(@bounces, 3, 'But got a bounce for the problematic attachment');

$server->shutdown();

1;
