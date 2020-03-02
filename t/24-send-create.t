#!/usr/bin/perl

use warnings;
use strict;

use IO::Capture::Stderr;

use App::Paws;
use App::Paws::Context;

use lib './t/lib';
use App::Paws::Test::Server;
use App::Paws::Test::Utils qw(test_setup
                              get_files_in_directory
                              write_message);

use Test::More tests => 3;

my $server = App::Paws::Test::Server->new();
$server->run();
my $url = 'http://localhost:'.$server->{'port'};

my ($mail_dir, $bounce_dir, $config, $config_path) =
    test_setup($url);

my $paws = App::Paws->new();
$paws->receive(1);
my @files = get_files_in_directory($mail_dir);
is(@files, 11, 'Got 11 mails');

my $mail = write_message('slackbot', 'slackbot@test.slack.alt, '.
                         'user3@test.slack.alt',
                         'To multiple');
$paws->send([], $mail);
$paws->reset();

my $cap = IO::Capture::Stderr->new();
$cap->start();
$paws->send_queued();
$cap->stop();

$paws->receive(20);
@files = get_files_in_directory($mail_dir);
is(@files, 12, 'Created new conversation, multiple recipients');
my @bounces = get_files_in_directory($bounce_dir);
is(@bounces, 0, 'No bounces');

$server->shutdown();

1;
