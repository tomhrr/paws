package App::Paws::Debug;

use warnings;
use strict;

use base qw(Exporter);
our @EXPORT_OK = qw(debug);

my $DEBUG = 0;

sub debug
{
    my (@messages) = @_;

    if (not $ENV{'PAWS_DEBUG'}) {
        return;
    }

    for my $message (@messages) {
        $message =~ s/(\r?\n)+$//g;
        print STDERR "$message\n";
    }

    return 1;
}

1;

__END__

=head1 NAME

App::Paws::Debug

=head1 DESCRIPTION

Provides a function for printing debug messages.

=head1 PUBLIC FUNCTIONS

=over 4

=item B<debug>

Takes a list of messages as its arguments.  Prints each message to
standard error, if debug is currently enabled.  Debug is enabled by
setting the C<PAWS_DEBUG> environment variable to a true value.

=back

=head1 AUTHOR

Tom Harrison (C<tomhrr@tomhrr.org>)

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
