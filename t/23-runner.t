#!/usr/bin/perl

use warnings;
use strict;

use App::Paws;
use App::Paws::Context;
use App::Paws::Utils qw(standard_get_request);

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
my $runner = $paws->{'context'}->{'runner'};

my $ws = $paws->{'context'}->{'workspaces'}->{'test'};
my $req = standard_get_request(
    $paws->{'context'},
    $ws,
    '/conversations.list',
    { types => 'public_channel,private_channel,mpim,im' }
);
my $id = $runner->add(
    'conversations.list', $req, sub {
        my ($runner, $res) = @_;
        my $id = $runner->add('conversations.list', $req,
                              sub { return 'done' });
        return $id;
    }
);
my $count = 0;
for (1..10) {
    $runner->add('conversations.list', $req, sub { $count++ });
}

while (not $runner->poke()) {
    sleep(0.1);
}
is($count, 10, 'Finished 10 additional jobs');

$server->shutdown();

1;
