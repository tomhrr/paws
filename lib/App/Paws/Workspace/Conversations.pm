package App::Paws::Workspace::Conversations;

use warnings;
use strict;

use File::Slurp qw(read_file write_file);
use HTTP::Request;
use JSON::XS qw(decode_json encode_json);
use Time::HiRes qw(sleep);

use App::Paws::Utils qw(standard_get_request);

our $LIMIT = 100;

sub new
{
    my $class = shift;
    my %args = @_;

    my $self = {
        (map { $_ => $args{$_} }
            qw(context workspace users)),
        retrieving => 0,
        retrieved  => 0,
    };

    bless $self, $class;
    $self->_init_conversations();
    return $self;
}

sub _users
{
    return $_[0]->{'users'};
}

sub _conversation_to_name
{
    my ($self, $conversation) = @_;

    my ($name, $type) = @{$conversation}{qw(name type)};
    if (($type eq 'im') and not $name) {
        my $user_id = $conversation->{'user'};
        $name = $self->_users()->id_to_name($user_id);
        if (not $name) {
            warn "Unable to find name for user '$user_id'";
            $name = 'unknown';
        }
    }

    return "$type/$name";
}

sub _init_conversations
{
    my ($self, $force_retrieve) = @_;

    my $context = $self->{'context'};
    my $runner = $context->runner();
    my $ws = $self->{'workspace'};
    my $db_dir = $context->db_directory();
    my $path = $db_dir.'/'.$ws->name().'-workspace-conversations-db';
    if (not -e $path) {
        write_file($path, '{}');
    }
    my $db = decode_json(read_file($path));
    if ($db->{'conversations'}) {
        $self->{'conversations'} = $db->{'conversations'};
    }
    if (not $force_retrieve) {
        return 1;
    }
    if ($self->{'retrieving'} or $self->{'retrieved'}) {
        return 1;
    }

    my $req = standard_get_request(
        $context, $ws,
        '/conversations.list',
        { types  => 'public_channel,private_channel,mpim,im' }
    );

    $self->{'retrieving'} = 1;
    my @conversations;
    $runner->add('conversations.list', $req, sub {
        my ($runner, $res, $fn) = @_;

        if (not $res->is_success()) {
            my $res_str = $res->as_string();
            $res_str =~ s/(\r?\n)+$//g;
            print STDERR "Unable to process response: $res_str\n";
            return;
        }
        my $data = decode_json($res->content());
        if ($data->{'error'}) {
            my $res_str = $res->as_string();
            $res_str =~ s/(\r?\n)+$//g;
            print STDERR "Error in response: $res_str\n";
            return;
        }

        for my $conversation (@{$data->{'channels'}}) {
            my $type = ($conversation->{'is_im'}    ? 'im'
                     :  $conversation->{'is_mpim'}  ? 'mpim'
                     :  $conversation->{'is_group'} ? 'group'
                                                    : 'channel');
            $conversation->{'type'} = $type;
            $conversation->{'name'} =
                $self->_conversation_to_name($conversation);
            push @conversations,
                 { map { $_ => $conversation->{$_} }
                     qw(id name is_member user type) };
        }

        if (my $cursor = $data->{'response_metadata'}->{'next_cursor'}) {
            my $req = standard_get_request(
                $context, $ws,
                '/conversations.list',
                { cursor => $cursor,
                  types  => 'public_channel,private_channel,mpim,im' }
            );
            $runner->add('conversations.list', $req, $fn);
        } else {
            $self->{'conversations'} = \@conversations;
            $db->{'conversations'} = $self->{'conversations'};
            write_file($path, encode_json($db));
            $self->{'retrieving'} = 0;
            $self->{'retrieved'}  = 1;
            delete $self->{'conversation_map'};
        }
    });
}

sub get_list
{
    my ($self) = @_;

    return $self->{'conversations'};
}

sub retrieve_nb
{
    my ($self) = @_;

    if ($self->{'retrieving'} or $self->{'retrieved'}) {
        return 1;
    }

    my $context = $self->{'context'};
    my $runner  = $context->runner();
    $self->_init_conversations(1);

    return 1;
}

sub retrieve
{
    my ($self) = @_;

    if ($self->{'retrieved'}) {
        return 1;
    }

    $self->retrieve_nb();
    my $context = $self->{'context'};
    my $runner  = $context->runner();
    while (not $runner->poke('conversations.list')) {
        sleep(0.01);
    }

    return 1;
}

sub _get_conversation_map
{
    my ($self) = @_;

    if ($self->{'conversation_map'}) {
        return $self->{'conversation_map'};
    }

    my %conversation_map =
        map { $_->{'name'} => $_->{'id'} }
            @{$self->{'conversations'}};

    $self->{'conversation_map'} = \%conversation_map;

    return \%conversation_map;
}

sub name_to_id
{
    my ($self, $name) = @_;

    my $conversation_map = $self->_get_conversation_map();
    if (exists $conversation_map->{$name}) {
        return $conversation_map->{$name};
    }
    if ($name !~ /\//) {
        if (exists $conversation_map->{"im/$name"}) {
            return $conversation_map->{"im/$name"};
        }
    }
    if (not $self->{'retrieved'}) {
        $self->retrieve();
        return $self->name_to_id($name);
    }

    return;
}

sub id_to_name
{
    my ($self, $id) = @_;

    my $conversation_map = $self->_get_conversation_map();
    my %conversation_map_by_id = reverse %{$conversation_map};
    if (exists $conversation_map_by_id{$id}) {
        return $conversation_map_by_id{$id};
    }
    if (not $self->{'retrieved'}) {
        $self->retrieve();
        return $self->id_to_name($id);
    }

    return;
}

1;

__END__

=head1 NAME

App::Paws::Workspace::Conversations

=head1 DESCRIPTION

Provides for retrieving the available conversations from Slack.
Actually receiving messages from those conversations is handled by
L<App::Paws::Receiver>.

=head1 CONSTRUCTOR

=over 4

=item B<new>

Arguments (hash):

=item context

The current L<App::Paws::Context> object.

=item workspace

The L<App::Paws::Workspace> object for the
workspace.

=item users

The L<App::Paws::Workspace::Users> object for the
workspace.

=back

Returns a new instance of L<App::Paws::Workspace::Conversations>.  The
object is also initialised with conversations at this point.  If this
workspace has been loaded and persisted to local storage before, then
conversations are loaded into the object from that storage.
Otherwise, the list of conversations for the workspace is retrieved
from Slack.

=back

=head1 PUBLIC METHODS

=over 4

=item B<get_list>

Returns the current conversation list, as an arrayref.  Each entry is
a hashref containing the following members:

=over 8

=item id

The conversation ID from Slack.

=item name

The conversation name, which is the concatenation
of the conversation type and either its name from
Slack (for non-DM conversations), or the name of
the Slack user (for DM conversations).

=item is_member

A boolean indicating whether the current user is a
member of the conversation.

=item user

For DM conversations, the user ID of the other
user in the conversation.

=item type

The conversation type.  One of 'im', 'mpim',
'group', or 'channel'.

=back

=item B<retrieve_nb>

Retrieve the list of conversations for this workspace from Slack,
without blocking.  If this object has already been used to retrieve
that list, then do nothing.

=item B<retrieve>

Retrieve the list of conversations for this workspace from Slack,
blocking until that is finished.  If this object has already been used
to retrieve that list, then do nothing.

=item B<name_to_id>

Takes a conversation name (per the return value of C<get_list>) and
returns a conversation ID.  If the conversation name cannot be found,
and this object has not already been used to retrieve the list of
conversations for this workspace from Slack, then retrieve that list
(blocking) and re-check.

=item B<id_to_name>

Takes a conversation ID (per the Slack API) and returns a conversation
name.  If the conversation ID cannot be found, and this object has not
already been used to retrieve the list of conversations for this
workspace from Slack, then retrieve that list (blocking) and re-check.

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
