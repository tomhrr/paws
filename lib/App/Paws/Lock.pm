package App::Paws::Lock;

use warnings;
use strict;

use Fcntl qw(O_CREAT O_EXCL);
use constant ATTEMPTS => 10;

sub new
{
    my $class = shift;
    my %args = @_;
    my $path = $args{'path'};

    my ($res, $fh);
    my $original_count = ATTEMPTS();
    my $count = $original_count;;
    while ($count-- > 0) {
        $res = sysopen($fh, $path, O_CREAT | O_EXCL);
        if ($res) {
            last;
        }
        sleep(1);
    }
    if (not $res) {
        print STDERR "Unable to secure lock for '$path' after ".
                     "$original_count seconds.\n";
        die();
    }

    my $self = { path => $path, fh => $fh };
    bless $self, $class;

    return $self;
}

sub unlock
{
    my ($self) = @_;

    if ($self->{'unlocked'}) {
        return;
    }

    my $path = $self->{'path'};
    my $res = unlink($path);
    if (not $res) {
        print STDERR "Unable to unlink lock for '$path'.\n";
    }

    $self->{'unlocked'} = 1;
    return 1;
}

sub DESTROY
{
    my ($self) = @_;

    return $self->unlock();
}

1;

__END__

=head1 NAME

App::Paws::Lock

=head1 DESCRIPTION

Lock object, for guaranteeing exclusivity based on a path name.

=head1 CONSTRUCTOR

=over 4

=item B<new>

Arguments (hash):

=over 8

=item path

The path to use for the lock.

=back

Attempts to secure a lock using the given path, and returns a new
instance of L<App::Paws::Lock>.  Dies if the lock cannot be secured
within ten seconds.  The lock will remain in place until L<unlock> is
called or the object is destroyed.

=back

=head1 PUBLIC METHODS

=over 4

=item B<unlock>

Unlocks the lock.  The lock cannot be relocked using this object after
being unlocked.

=back

=head1 DESTRUCTOR

=over 4

=item B<DESTROY>

Unlocks the lock, if it still exists and was locked by this object.

=back

=head1 AUTHOR

Tom Harrison (C<tomh5908@gmail.com>)

=head1 COPYRIGHT & LICENCE

Copyright (c) 2020, Tom Harrison
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.
  * Neither the name of the copyright holder nor the
    names of its contributors may be used to endorse or promote products
    derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut
