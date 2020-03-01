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

my $thread_ts     = $App::Paws::Test::Server::ts_base_p3.'.0';
my $thread_msg_ts = $App::Paws::Test::Server::ts_base_p4.'.0';

my $paws = App::Paws->new();
$paws->receive(1);
my @files = get_files_in_directory($mail_dir);
is(@files, 11, 'Got 11 mails');

my $ua = LWP::UserAgent->new();
my $req = HTTP::Request->new();
$req->method('POST');
$req->uri($url.'/chat.delete');
$req->content(encode_json({ channel   => 'C00000002',
                            ts        => $thread_msg_ts,
                            thread_ts => $thread_ts }));
my $res = $ua->request($req);
ok($res->is_success(), 'Deleted thread message successfully');

$config->{'workspaces'}->{'test'}->{'thread_expiry'} =
    (60 * 60 * 24 * 7 * 52 * 100);
$config->{'workspaces'}->{'test'}->{'modification_window'} = 3600;
print $config_path YAML::Dump($config);
$config_path->flush();

$paws = App::Paws->new();
$paws->receive(20);
@files = `find $mail_dir -type f`;
is(@files, 12, 'Deletion message added');

$paws->receive(40);
@files = `find $mail_dir -type f`;
is(@files, 12, 'Deletion message not added again');

$paws->receive(60);
@files = `find $mail_dir -type f`;
is(@files, 12, 'Deletion message not added again');

$server->shutdown();

1;
