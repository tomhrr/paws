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
my %files_by_name = map { $_ => 1 } @files;

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
Content-Transfer-Encoding: binary

asdfasdf
------------=_1559971933-10629-0--);
$mail3->flush();
$mail3->seek(0, SEEK_SET);

$paws->send(['slack.alt'], $mail3);
$paws->send_queued();

$paws->receive(40);
@files = `find $mail_dir -type f`;
is(@files, 12, 'Got extra mail (with attachment)');

my $parser = MIME::Parser->new();
my $tempdir = tempdir();
$parser->output_under($tempdir);
my ($new_file) = grep { not $files_by_name{$_} } @files;
my $entity = $parser->parse_open($new_file);
my @parts = $entity->parts();
is(@parts, 2, 'Mail has two parts');
is($parts[1]->head()->recommended_filename(), 'file',
    'Attachment has correct filename');

1;
