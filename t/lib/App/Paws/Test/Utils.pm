package App::Paws::Test::Utils;

use warnings;
use strict;

use Fcntl qw(SEEK_SET);
use File::Find;
use File::Spec::Functions qw(catfile);
use File::Temp qw(tempdir);

use base qw(Exporter);
our @EXPORT_OK = qw(get_default_config
                    make_maildir
                    test_setup
                    get_files_in_directory
                    write_message);

sub make_maildir
{
    my $mail_dir = tempdir();
    for my $dir (qw(cur new tmp)) {
        mkdir(catfile($mail_dir, $dir)) or die $!;
    }
    return $mail_dir;
}

sub get_default_config
{
    my ($mail_dir, $bounce_dir) = @_;

    return {
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
	    },
	    test2 => {
		token => 'xoxp-asdf',
		conversations => [
		    'channel/general',
		    'channel/work',
		    'im/slackbot',
		    'im/user3',
		],
	    },
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
}

sub test_setup
{
    my ($url) = @_;

    my $mail_dir   = make_maildir();
    my $bounce_dir = make_maildir();

    my $config = get_default_config($mail_dir, $bounce_dir);

    my $config_path = File::Temp->new();
    print $config_path YAML::Dump($config);
    $config_path->flush();
    $App::Paws::CONFIG_PATH = $config_path->filename();

    my $queue_dir = tempdir();
    $App::Paws::QUEUE_DIR = $queue_dir;

    my $db_dir = tempdir();
    $App::Paws::DB_DIR = $db_dir;

    $App::Paws::Context::SLACK_BASE_URL = $url;

    return ($mail_dir, $bounce_dir, $config, $config_path);
}

sub get_files_in_directory
{
    my ($dir) = @_;

    my @files;
    find(sub {
        my $path = $File::Find::name;
        if (-d $path) {
            return;
        }
        push @files, $path;
    }, $dir);

    return @files;
}

sub write_message
{
    my ($from, $to, $content) = @_;

    if ($from !~ /\@/) {
        $from .= '@test.slack.alt';
    }
    if ($to !~ /\@/) {
        $to .= '@test.slack.alt';
    }

    my $msg_ts = time();
    my $mail = File::Temp->new();
    print $mail <<EOF;
Content-Type: text/plain; charset="UTF-8"
Content-Disposition: inline
Content-Transfer-Encoding: quoted-printable
MIME-Version: 1.0
Date: Thu, 16 May 2019 15:39:47 +1000
From: $from
To: $to
Subject: Message from im/slackbot
Message-ID: <$msg_ts.000100.im/slackbot\@test.slack.alt>
Reply-To: $to

$content
EOF
    $mail->flush();
    $mail->seek(0, SEEK_SET);

    return $mail;
}

1;
