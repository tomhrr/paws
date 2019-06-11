use strict;
use warnings;

use ExtUtils::MakeMaker;
use ExtUtils::MakeMaker::Config;

my $output = WriteMakefile(
    NAME          => 'App::Paws',
    AUTHOR        => 'Tom Harrison <tomh5908@gmail.com>',
    VERSION_FROM  => 'lib/App/Paws.pm',
    ABSTRACT      => 'Send/receive Slack message via email',
    LICENSE       => 'perl_5',
    PL_FILES      => {},
    EXE_FILES     => ['bin/paws-send',
                      'bin/paws-send-queued',
                      'bin/paws-receive',
                      'bin/paws-aliases'],
    MIN_PERL_VERSION => 5.006,
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => 0,
    },
    BUILD_REQUIRES => {
        'Test::More' => 0,
    },
    PREREQ_PM => {
        'File::Slurp'    => 0,
        'HTML::Entities' => 0,
        'JSON::XS'       => 0,
        'List::Util'     => 0,
        'LWP::UserAgent' => 0,
        'MIME::Entity'   => 0,
        'MIME::Parser'   => 0,
        'YAML'           => 0,
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES => 'App-Paws-*' },
    META_MERGE     => {
        resources => {
            repository => 'https://github.com/tomhrr/paws'
        }
    },
);

1;
