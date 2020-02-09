package App::Paws::Utils;

use warnings;
use strict;

use POSIX qw(strftime);
use base 'Exporter';
our @EXPORT_OK = qw(get_mail_date);

sub get_mail_date
{
    return strftime("%a, %d %b %Y %H:%M:%S %z", localtime($_[0]));
}

1;
