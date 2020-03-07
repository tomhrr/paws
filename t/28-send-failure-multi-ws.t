#!/usr/bin/perl

use warnings;
use strict;

use File::Slurp qw(read_file);
use IO::Capture::Stderr;

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


my $mail = write_message('slackbot', 'im/slackbot@test.slack.alt, '.
                         'im/slackbot@test2.slack.alt',
                         'Testing');
$paws->send([], $mail);
$paws->reset();

my $cap = IO::Capture::Stderr->new();
$cap->start();
$paws->send_queued();
$cap->stop();
$paws->receive(20);
@files = get_files_in_directory($mail_dir);
is(@files, 11, 'Unable to send mail');
my @bounces = get_files_in_directory($bounce_dir);
is(@bounces, 1, 'Got bounce');
chomp $bounces[0];
my $content = read_file($bounces[0]);
like($content, qr/Unable to send message to multiple workspaces/,
    'Got correct message in bounce');

$server->shutdown();

1;
