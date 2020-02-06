package App::Paws::Lock;

use warnings;
use strict;

use Fcntl qw(O_CREAT O_EXCL);

sub new
{
    my ($class, $path) = @_;

    my $fh;
    my $count = 10;
    for (;;) {
        my $res = sysopen($fh, $path, O_CREAT | O_EXCL);
        if ($fh) {
            last;
        }
        $count--;
        sleep(1);
    }
    if (not $fh) {
        print STDERR "Unable to secure lock for '$path' after 10 seconds.\n";
        exit(1);
    }

    my $self = { path => $path };
    bless $self, $class;

    return $self;
}

sub unlock
{
    my ($self) = @_;

    my $path = $self->{'path'};
    my $res = unlink($path);
    if (not $res) {
        print STDERR "Unable to unlink lock for '$path'.\n";
    }
}

sub DESTROY
{
    my ($self) = @_;

    my $path = $self->{'path'};
    if (-e $path) {
        $self->unlock();
    }
}

1;
