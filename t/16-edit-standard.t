#!/usr/bin/perl

use warnings;
use strict;

use App::Paws;
use App::Paws::Context;

use lib './t/lib';
use App::Paws::Test::Server;
my $edit_ts = $App::Paws::Test::Server::ts_base.'.0';

use File::Temp qw(tempdir);
use Fcntl qw(SEEK_SET);
use JSON::XS qw(encode_json);
use List::Util qw(first);
use MIME::Parser;
use YAML;

use Test::More tests => 5;

my $server = App::Paws::Test::Server->new();
$server->run();
my $url = 'http://localhost:'.$server->{'port'};

my $mail_dir = tempdir();
my $bounce_dir = tempdir();
for my $dir (qw(cur new tmp)) {
    system("mkdir $mail_dir/$dir");
    system("mkdir $bounce_dir/$dir");
}

my $config = {
    domain_name => 'slack.alt',
    user_email => 'test@example.com',
    workspaces => {
        test => {
            token => 'xoxp-asdf',
            conversations => [
                'channel/general',
                'channel/work',
                'im/slackbot',
                'im/user3',
            ],
        }
    },
    sender => { 
        bounce_dir => $bounce_dir,
        fallback_sendmail => '/bin/true',
    },
    receivers => [ {
        type      => 'maildir',
        name      => 'initial',
        workspace => 'test',
        path      => $mail_dir,
    } ],
    rate_limiting => {
        initial => 1000,
    },
};

my $config_path = File::Temp->new();
print $config_path YAML::Dump($config);
$config_path->flush();
$App::Paws::CONFIG_PATH = $config_path->filename();

my $queue_dir = tempdir();
$App::Paws::QUEUE_DIR = $queue_dir;

my $db_dir = tempdir();
$App::Paws::DB_DIR = $db_dir;

$App::Paws::Context::SLACK_BASE_URL = $url;

my $paws = App::Paws->new();
$paws->receive(1);
my @files = `find $mail_dir -type f`;
is(@files, 11, 'Got 11 mails');

my $ua = LWP::UserAgent->new();
my $req = HTTP::Request->new();
$req->method('POST');
$req->uri($url.'/chat.update');
$req->content(encode_json({ channel => 'C00000001',
                            ts      => $edit_ts,
                            text    => 'edited', }));
my $res = $ua->request($req);
ok($res->is_success(), 'Updated message successfully');

$paws->receive(70);
@files = `find $mail_dir -type f`;
is(@files, 11, 'Edited message not retrieved (no modification window)');

$config->{'workspaces'}->{'test'}->{'modification_window'} = 3600;
print $config_path YAML::Dump($config);
$config_path->flush();
$paws = App::Paws->new();
$paws->receive(80);
@files = `find $mail_dir -type f`;
is(@files, 12, 'Edited message retrieved');

$paws->receive(90);
@files = `find $mail_dir -type f`;
is(@files, 12, 'Edited message not retrieved again');

$server->shutdown();

1;
