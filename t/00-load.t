#!perl

use 5.006;
use strict;
use warnings FATAL => 'all';
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'App::Paws' ) || print "Bail out!\n";
}

diag( "Testing App::Paws $App::Paws::VERSION, Perl $], $^X" );
