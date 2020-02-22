#!/usr/bin/perl

use warnings;
use strict;

use File::Temp;
use constant::override substitute => { ATTEMPTS => 1 };

use App::Paws::Lock;

use Test::More tests => 7;

my $file_temp = File::Temp->new();
my $temp_path = $file_temp->filename();
unlink $temp_path;

{
    my $lock = App::Paws::Lock->new(path => $temp_path);
    ok($lock, 'Secured lock over path');

    my $lock2 = eval { App::Paws::Lock->new(path => $temp_path); };
    ok($@, 'Unable to get additional lock over path');

    my $res = $lock->unlock();
    ok($res, 'Unlocked lock');

    my $lock3 = eval { App::Paws::Lock->new(path => $temp_path); };
    ok($lock3, 'Able to get lock now that original lock unlocked');
}

{
    {
        my $lock = App::Paws::Lock->new(path => $temp_path);
        ok($lock, 'Secured lock over path');

        my $lock2 = eval { App::Paws::Lock->new(path => $temp_path); };
        ok($@, 'Unable to get additional lock over path');
    }

    my $lock3 = eval { App::Paws::Lock->new(path => $temp_path); };
    ok($lock3, 'Able to get lock now that original lock destroyed');
}

1;
