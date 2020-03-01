#!/usr/bin/perl

use warnings;
use strict;

use File::Temp qw(tempdir);
use Fcntl qw(SEEK_SET);

use App::Paws;
use App::Paws::Context;

use lib './t/lib';
use App::Paws::Test::Server;
use App::Paws::Test::Utils qw(test_setup
                              get_files_in_directory
                              write_message);

use Test::More tests => 4;

my $server = App::Paws::Test::Server->new();
$server->run();
my $url = 'http://localhost:'.$server->{'port'};

my ($mail_dir, $bounce_dir, $config, $config_path) =
    test_setup($url);

my $paws = App::Paws->new();
$paws->receive(1);
my @files = get_files_in_directory($mail_dir);
is(@files, 11, 'Got 11 mails');
my %files_by_name = map { $_ => 1 } @files;

my $mail = File::Temp->new();
print $mail q(MIME-Version: 1.0
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
$mail->flush();
$mail->seek(0, SEEK_SET);

$paws->send([], $mail);
$paws->send_queued();

$paws->receive(20);
@files = get_files_in_directory($mail_dir);
is(@files, 12, 'Got extra mail (with attachment)');

my $parser = MIME::Parser->new();
my $parser_tempdir = tempdir();
$parser->output_under($parser_tempdir);
my ($new_file) = grep { not $files_by_name{$_} } @files;
my $entity = $parser->parse_open($new_file);
my @parts = $entity->parts();
is(@parts, 2, 'Mail has two parts');
is($parts[1]->head()->recommended_filename(), 'file',
    'Attachment has correct filename');

$server->shutdown();

1;
