#!/usr/bin/perl

use warnings;
use strict;

use App::Paws;
use App::Paws::Context;

use lib './t/lib';
use App::Paws::Test::Server;
use App::Paws::Test::Utils qw(test_setup
                              get_files_in_directory);

use Test::More tests => 2;

my $server = App::Paws::Test::Server->new();
$server->run();
my $url = 'http://localhost:'.$server->{'port'};

my ($mail_dir, $bounce_dir, $config, $config_path) =
    test_setup($url);

my $paws = App::Paws->new();
$paws->receive(1);
my @files = get_files_in_directory($mail_dir);
is(@files, 11, 'Got 11 mails');

$paws->receive(10);
@files = get_files_in_directory($mail_dir);
is(@files, 11, 'Still have 11 mails');

$server->shutdown();

1;
