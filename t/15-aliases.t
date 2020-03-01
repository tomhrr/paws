#!/usr/bin/perl

use warnings;
use strict;

use List::Util qw(first);

use App::Paws;
use App::Paws::Context;

use lib './t/lib';
use App::Paws::Test::Server;
use App::Paws::Test::Utils qw(test_setup
                              get_files_in_directory
                              write_message);

use Test::More tests => 1;

my $server = App::Paws::Test::Server->new();
$server->run();
my $url = 'http://localhost:'.$server->{'port'};

my ($mail_dir, $bounce_dir, $config, $config_path) =
    test_setup($url);

my $paws = App::Paws->new();

my @aliases = @{$paws->aliases()};
my $found =
    first { $_ eq 'alias slack-test-slackbot Slack Bot '.
                  '<im/slackbot@test.slack.alt>' }
        @aliases;
ok($found, 'Found slackbot alias in alias list');

$server->shutdown();

1;
