package App::Paws::Receiver::MDA;

use warnings;
use strict;

use IPC::Run3;

use App::Paws::Receiver;

sub new
{
    my $class = shift;
    my %args = @_;
    my $self = {
        context   => $args{'context'},
        workspace => $args{'workspace'},
        name      => $args{'name'},
        path      => $args{'path'},
        args      => $args{'args'},
    };
    bless $self, $class;
    return $self;
}

sub workspace
{
    return $_[0]->{'workspace'};
}

sub run
{
    my ($self, $counter, $since_ts, $conversation_data) = @_;

    my $receiver = App::Paws::Receiver->new(
        workspace => $self->{'workspace'},
        context   => $self->{'context'},
        name      => $self->{'name'},
        write_cb => sub {
            my ($entity) = @_;

            my $cmd = $self->{'path'};
            my @args = @{$self->{'args'} || []};
            my $data = $entity->as_string();
            my $stderr;
            eval { run3([$cmd, @args], \$data, \undef, \$stderr); };
            if (my $error = $@) {
                $stderr ||= "(no stderr output)";
                $stderr =~ s/(\r?\n)+$//g;
                print STDERR "MDA execution failed: $stderr\n";
            }
            my $res = $?;
            if ($? != 0) {
                $stderr ||= "(no stderr output)";
                $stderr =~ s/(\r?\n)+$//g;
                print STDERR "MDA execution failed: $stderr\n";
            }
            if ($stderr) {
                $stderr =~ s/(\r?\n)+$//g;
                print STDERR "MDA execution failed: $stderr\n";
            }
        }
    );

    if ($conversation_data) {
        $receiver->run_for_subset($conversation_data);
    } else {
        $receiver->run($since_ts);
    }

    return 1;
}

1;

__END__

=head1 NAME

App::Paws::Receiver::maildir

=head1 DESCRIPTION

A receiver that writes messages to a maildir.

=head1 CONSTRUCTOR

=over 4

=item B<new>

Arguments (hash):

=over 8

=item context

The current L<App::Paws::Context> object.

=item workspace

The L<App::Paws::Workspace> object for the
workspace of this conversation.

=item name

The name of this receiver, as a string.  This is
used to uniquely identify this receiver instance.

=item path

The path of the MDA executable.

=item args

An arrayref of arguments to be passed to the MDA
executable.

=back

Returns a new instance of
L<App::Paws::Receiver::MDA>.

=back

=head1 PUBLIC METHODS

=over 4

=item B<workspace>

Returns the L<App::Paws::Workspace> object for the workspace of this
conversation.

=item B<run>

Takes a message counter and a lower-bound timestamp (both optional) as
its arguments.  Receives messages for this workspace and passes them
to the specified MDA for delivery.  The message counter is only
present for consistency with the C<run> interface in the C<maildir>
module, and has no effect here.  The lower-bound timestamp is used to
skip messages in the history.

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
