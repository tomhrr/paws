#!/usr/bin/perl

use warnings;
use strict;

use JSON::XS qw(encode_json);

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
my $msg_ts = $App::Paws::Test::Server::ts_base_p1.'.0';

my ($mail_dir, $bounce_dir, $config, $config_path) =
    test_setup($url);

my $paws = App::Paws->new();
$paws->receive(1);
my @files = get_files_in_directory($mail_dir);
is(@files, 11, 'Got 11 mails');

$config->{'workspaces'}->{'test'}->{'modification_window'} = 3600;
print $config_path YAML::Dump($config);
$config_path->flush();

my $ua = LWP::UserAgent->new();
my $req = HTTP::Request->new();
$req->method('POST');
$req->uri($url.'/paws.thread.make');
$req->content(encode_json({ channel => 'C00000002',
                            ts      => $msg_ts }));
my $res = $ua->request($req);
ok($res->is_success(), 'Created new thread successfully');

$paws = App::Paws->new();
$paws->receive(20);
@files = get_files_in_directory($mail_dir);
is(@files, 12, 'New thread reply retrieved');

$server->shutdown();

1;
