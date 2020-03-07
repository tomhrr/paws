#!/usr/bin/perl

use warnings;
use strict;

use Fcntl qw(SEEK_SET);
use JSON::XS qw(encode_json);
use Time::Local;

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

$config->{'workspaces'}->{'test'}->{'modification_window'} = 3600;
print $config_path YAML::Dump($config);
$config_path->flush();

my $paws = App::Paws->new();
$paws->receive(1, undef, time());
my @files = get_files_in_directory($mail_dir);
is(@files, 0, 'Got no mail (all messages are too old)');

my $mail = write_message('slackbot', 'im/slackbot', 'asdfasdf');
$paws->send([], $mail);
$paws->send_queued();
$paws->receive(20);
@files = get_files_in_directory($mail_dir);
is(@files, 1, 'Received mail previously sent (only)');
my ($ts) = `grep X-Paws-Thread-TS $files[0]`;
chomp $ts;
$ts =~ s/.*: //;

my $ua = LWP::UserAgent->new();
my $req = HTTP::Request->new();
$req->method('POST');
$req->uri($url.'/paws.thread.make');
$req->content(encode_json({ channel => 'D00000002',
                            ts      => $ts }));
my $res = $ua->request($req);
ok($res->is_success(), 'Created new thread successfully');

$paws->receive(30);
@files = sort { $a cmp $b } get_files_in_directory($mail_dir);
is(@files, 2, 'Got thread message');
my ($thread_ts) = `grep X-Paws-Thread-TS $files[1]`;
chomp $thread_ts;
$thread_ts =~ s/.*: //;

$req = HTTP::Request->new();
$req->uri($url.'/chat.postMessage');
$req->method('POST');
$req->content(encode_json({ channel   => 'D00000002',
                            text      => 'asdf',
                            thread_ts => $thread_ts }));
$res = $ua->request($req);
ok($res->is_success(), 'Replied to thread successfully');

$paws->receive(40, undef, timelocal(0, 0, 0, 1, 1, 3000));
@files = get_files_in_directory($mail_dir);
is(@files, 2, 'No new mail received');

$server->shutdown();

1;
