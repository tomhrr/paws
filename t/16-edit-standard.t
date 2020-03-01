#!/usr/bin/perl

use warnings;
use strict;

use JSON::XS qw(encode_json);
use YAML;

use App::Paws;
use App::Paws::Context;

use lib './t/lib';
use App::Paws::Test::Server;
use App::Paws::Test::Utils qw(test_setup
                              get_files_in_directory
                              write_message);

use Test::More tests => 5;

my $server = App::Paws::Test::Server->new();
$server->run();
my $url = 'http://localhost:'.$server->{'port'};

my ($mail_dir, $bounce_dir, $config, $config_path) =
    test_setup($url);

my $paws = App::Paws->new();
$paws->receive(1);
my @files = get_files_in_directory($mail_dir);
is(@files, 11, 'Got 11 mails');

my $edit_ts = $App::Paws::Test::Server::ts_base.'.0';
my $ua = LWP::UserAgent->new();
my $req = HTTP::Request->new();
$req->method('POST');
$req->uri($url.'/chat.update');
$req->content(encode_json({ channel => 'C00000001',
                            ts      => $edit_ts,
                            text    => 'edited', }));
my $res = $ua->request($req);
ok($res->is_success(), 'Updated message successfully');

$paws->receive(20);
@files = get_files_in_directory($mail_dir);
is(@files, 11, 'Edited message not retrieved (no modification window)');

$config->{'workspaces'}->{'test'}->{'modification_window'} = 3600;
print $config_path YAML::Dump($config);
$config_path->flush();

$paws = App::Paws->new();
$paws->receive(40);
@files = get_files_in_directory($mail_dir);
is(@files, 12, 'Edited message retrieved');

$paws->receive(60);
@files = get_files_in_directory($mail_dir);
is(@files, 12, 'Edited message not retrieved again');

$server->shutdown();

1;
