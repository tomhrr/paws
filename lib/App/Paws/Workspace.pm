package App::Paws::Workspace;

use warnings;
use strict;

use File::Slurp qw(read_file write_file);
use HTTP::Request;
use JSON::XS qw(decode_json encode_json);
use Time::HiRes qw(sleep);

use App::Paws::Workspace::Conversations;
use App::Paws::Workspace::Users;
use App::Paws::Utils qw(standard_get_request);

our $LIMIT = 100;

sub new
{
    my $class = shift;
    my %args = @_;

    my $self = {
        (map { $_ => $args{$_} }
            qw(context name token conversations
               modification_window thread_expiry)),
    };

    bless $self, $class;

    $self->{'users'} =
        App::Paws::Workspace::Users->new(
            context   => $args{'context'},
            workspace => $self
        );
    $self->{'conversations_obj'} =
        App::Paws::Workspace::Conversations->new(
            context   => $args{'context'},
            workspace => $self,
            users     => $self->{'users'},
        );

    return $self;
}

sub name
{
    return $_[0]->{'name'};
}

sub token
{
    return $_[0]->{'token'};
}

sub modification_window
{
    return ($_[0]->{'modification_window'} || 0);
}

sub thread_expiry
{
    return ($_[0]->{'thread_expiry'} || (60 * 60 * 24 * 7));
}

sub users
{
    return $_[0]->{'users'};
}

sub conversations_obj
{
    return $_[0]->{'conversations_obj'};
}

sub conversations
{
    return $_[0]->{'conversations'};
}

sub get_conversations_request
{
    my ($self) = @_;

    return standard_get_request(
        $self->{'context'},
        $self,
        '/conversations.list',
        { types => 'public_channel,private_channel,mpim,im' }
    );
}

sub get_replies_request
{
    my ($self, $conversation_id, $thread_ts, $last_ts, $latest_ts,
        $cursor) = @_;

    return standard_get_request(
        $self->{'context'},
        $self,
        '/conversations.replies',
        { channel => $conversation_id,
          ts      => $thread_ts,
          limit   => $LIMIT,
          oldest  => $last_ts,
          ($latest_ts ? (latest => $latest_ts, inclusive => 1) : ()),
          ($cursor    ? (cursor => $cursor) : ()) }
    );
}

sub get_history_request
{
    my ($self, $conversation_id, $last_ts, $latest_ts, $cursor) = @_;

    return standard_get_request(
        $self->{'context'},
        $self,
        '/conversations.history',
        { channel => $conversation_id,
          limit   => $LIMIT,
          oldest  => $last_ts,
          ($latest_ts ? (latest => $latest_ts, inclusive => 1) : ()),
          ($cursor    ? (cursor => $cursor) : ()) }
    );
}

sub reset
{
    my ($self) = @_;

    $self->conversations_obj()->reset();
    $self->users()->reset();
}

1;

__END__

=head1 NAME

App::Paws::Workspace

=head1 DESCRIPTION

Configuration settings and helper methods/objects for working with a
Slack workspace.

=head1 CONSTRUCTOR

=over 4

=item B<new>

Arguments (hash):

=over 8

=item context

The current L<App::Paws::Context> object.

=item name

The workspace name.

=item token

The API token for the workspace.

=item conversations

The conversation names that should be fetched for
this workspace, per the result value of
<App::Paws::Workspace::Conversations::get_list>.
'*' is a specially-handled name that is treated as
the full set of conversation names.

=back

Returns a new instance of L<App::Paws::Workspace>.

=back

=head1 PUBLIC METHODS

=over 4

=item B<name>

Returns the workspace name.

=item B<token>

Returns the API token for the workspace.

=item B<modification_window>

Returns the modification window for the workspace.

=item B<thread_expiry>

Returns the thread expiry period for the workspace.

=item B<users>

Returns the L<App::Paws::Workspace::Users> object for this workspace.

=item B<conversations_obj>

Returns the L<App::Paws::Workspace::Conversations> object for this
workspace.

=item B<conversations>

Returns the list of conversation names that should be fetched for this
workspace.

=item B<get_conversations_request>

Returns an L<HTTP::Request> object for getting the conversations for
this workspace.

=item B<get_replies_request>

Takes a conversation ID, a thread timestamp, a lower-bound message
timestamp, an optional upper-bound message timestamp, and an optional
request cursor as its arguments.  Returns an L<HTTP::Request> object
for getting the replies for the specified thread.

=item B<get_history_request>

Takes a conversation ID, a lower-bound message timestamp, an optional
upper-bound message timestamp, and an optional request cursor as its
arguments.  Returns an L<HTTP::Request> object for getting the
messages for the specified conversation.

=item B<reset>

Resets the internal object state.  This allows for re-fetching
conversations and users from Slack.

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
