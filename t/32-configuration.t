#!/usr/bin/perl

use warnings;
use strict;

use File::Temp qw(tempdir);

use App::Paws;

use Test::More tests => 8;

sub test_vc
{
    my ($name, $config, $exp_errors, $exp_warnings) = @_;
    $exp_warnings ||= [];

    my ($errors, $warnings) = App::Paws::_validate_config($config);
    my $res = is_deeply($errors, $exp_errors, "$name: got expected errors");
    if (not $res) {
        print STDERR "Expected errors: ".(join ", ", @{$exp_errors})."\n";
        print STDERR "Actual errors:   ".(join ", ", @{$errors})."\n";
    }
    if ($exp_warnings) {
        $res = is_deeply($warnings, $exp_warnings,
                         "$name: got expected warnings");
        if (not $res) {
            print STDERR "Expected warnings: ".
                         (join ", ", @{$exp_warnings})."\n";
            print STDERR "Actual warnings:   ".
                         (join ", ", @{$warnings})."\n";
        }
    }
}

test_vc('Empty configuration',
        {},
        ['user_email must be configured.',
         'At least one workspace must be configured.']);

test_vc('Minimal configuration (warning)',
        { user_email => 'test@example.com',
          workspaces => {
              test => {
                  token => 'asdf'
              }
          } },
        [],
        ['workspaces:test:token does not appear to be '.
         'a Slack user token.']);

test_vc('Minimal configuration (no warnings)',
        { user_email => 'test@example.com',
          workspaces => {
              test => {
                  token => 'xoxp-aaaaaaaaaaaa'
              }
          } },
        []);

my $maildir = tempdir();
for my $subdir (qw(cur new tmp)) {
    mkdir "$maildir/$subdir" or die $!;
}
my $bouncedir = tempdir();
for my $subdir (qw(cur new tmp)) {
    mkdir "$bouncedir/$subdir" or die $!;
}

test_vc('Usable configuration',
        { user_email => 'test@example.com',
          workspaces => {
              test => {
                  token => 'xoxp-aaaaaaaaaaaa'
              }
          },
          receivers => [
              { type      => 'maildir',
                name      => 'test',
                workspace => 'test',
                path      => $maildir }
          ],
          sender => {
              fallback_sendmail => '/bin/true',
              bounce_dir        => $bouncedir
          } },
        []);

1;
