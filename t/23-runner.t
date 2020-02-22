#!/usr/bin/perl

use warnings;
use strict;

use App::Paws;
use App::Paws::Context;
use App::Paws::Runner;
use App::Paws::Utils qw(standard_get_request);

use lib './t/lib';
use App::Paws::Test::Server;

use File::Temp qw(tempdir);
use Fcntl qw(SEEK_SET);
use JSON::XS qw(encode_json);
use List::Util qw(first);
use MIME::Parser;
use Time::HiRes qw(sleep);
use YAML;

use Test::More tests => 1;

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
my $runner = $paws->{'context'}->{'runner'};

my $ws = $paws->{'context'}->{'workspaces'}->{'test'};
my $req = standard_get_request(
    $paws->{'context'},
    $ws,
    '/conversations.list',
    { types => 'public_channel,private_channel,mpim,im' }
);
my $id = 
    $runner->add('conversations.list',
             $req,
             sub {
                my ($runner, $res) = @_;
                my $id = $runner->add('conversations.list',
                             $req,
                             sub { return 'done' });
                return $id;
             });
my $count = 0;
for (1..10) {
    $runner->add('conversations.list',
             $req,
             sub { $count++ });
}

while (not $runner->poke()) {
    sleep(0.1);
}
is($count, 10, 'Finished 10 additional jobs');

$server->shutdown();

1;
