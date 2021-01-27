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

use Test::More tests => 6;

my $server = App::Paws::Test::Server->new();
$server->run();
my $url = 'http://localhost:'.$server->{'port'};

my ($mail_dir, $bounce_dir, $config, $config_path) =
    test_setup($url);

my $paws = App::Paws->new();
$paws->receive(1);
my @files = get_files_in_directory($mail_dir);
is(@files, 11, 'Got 11 mails');

my $mail = write_message('slackbot', 'channel/work', 'asdf');
$paws->send([], $mail);
$paws->send_queued();

my $ua = LWP::UserAgent->new();
my $req = HTTP::Request->new();
$req->method('POST');
$req->uri($url.'/paws.channel.leave');
my $channel_id = 'C00000002';
$req->content(encode_json({ channel => $channel_id }));
my $res = $ua->request($req);
ok($res->is_success(), 'Left channel');

$paws = App::Paws->new();
$paws->receive(20);
@files = get_files_in_directory($mail_dir);
is(@files, 12, 'Channel leave does not take effect immediately');

$mail = write_message('slackbot', 'channel/work', 'asdf');
$paws->send([], $mail);
$paws->send_queued();

$paws = App::Paws->new();
$paws->receive(30);
@files = get_files_in_directory($mail_dir);
is(@files, 12, 'Channel leave takes effect on second retrieval');

$req = HTTP::Request->new();
$req->method('POST');
$req->uri($url.'/paws.channel.join');
$req->content(encode_json({ channel => $channel_id }));
$res = $ua->request($req);
ok($res->is_success(), 'Joined channel');

$paws = App::Paws->new();
$paws->receive(30);
@files = get_files_in_directory($mail_dir);
is(@files, 13, 'Channel join takes effect immediately');

$server->shutdown();

1;
