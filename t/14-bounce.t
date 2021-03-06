#!/usr/bin/perl

use warnings;
use strict;

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

my $mail = write_message('asdf@example.org', 'im/user4', 'asdf');
$paws->send([], $mail);
$paws->send_queued();

$paws->receive(20);
@files = get_files_in_directory($mail_dir);
is(@files, 11, 'Still only 11 mails');

$paws->receive(40);
@files = get_files_in_directory($bounce_dir);
is(@files, 1, 'Message correctly recorded as bounce');

$server->shutdown();

1;
