package App::Paws::Utils;

use warnings;
use strict;

use POSIX qw(strftime);
use base 'Exporter';
our @EXPORT_OK = qw(get_mail_date
                    standard_get_request);

sub get_mail_date
{
    return strftime("%a, %d %b %Y %H:%M:%S %z", localtime($_[0]));
}

sub standard_get_request
{
    my ($context, $ws, $path, $query_form) = @_;

    my $token = $ws->token();
    my $req = HTTP::Request->new();
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');
    $req->header('Authorization' => 'Bearer '.$token);
    my $uri = URI->new($context->slack_base_url().$path);
    $uri->query_form(%{$query_form});
    $req->uri($uri);
    $req->method('GET');
    return $req;
}

1;

__END__

=head1 NAME

App::Paws::Utils

=head1 DESCRIPTION

Utility functions.

=head1 PUBLIC FUNCTIONS

=over 4

=item B<get_mail_date>

Returns the current local time as a string, suitable for use as the
value of a 'Date' header in an email message.

=item B<standard_get_request>

Takes an L<App::Paws::Context> object, an L<App::Paws::Workspace>
object, a URL path, and a URL query form as its arguments.  Constructs
and returns a new L<HTTP::Request> object for a Slack API call using
the provided details.

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
