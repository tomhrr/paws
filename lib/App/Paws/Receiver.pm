package App::Paws::Receiver;

use warnings;
use strict;

use File::Slurp qw(read_file write_file);
use JSON::XS qw(decode_json encode_json);
use List::MoreUtils qw(uniq);
use Time::HiRes qw(sleep);

use App::Paws::ConversationStorage;
use App::Paws::Lock;
use App::Paws::Message;

sub new
{
    my $class = shift;
    my %args = @_;
    my $self = \%args;
    bless $self, $class;
    return $self;
}

sub _process_conversations
{
    my ($context, $ws, $runner, $since_ts, $db,
        $write_cb, $conversation_map, $method_name,
        $conversations) = @_;

    my @conversation_objs;
    for my $conversation (@{$conversations}) {
        my $data = $db->{'conversations'}->{$conversation} || {};
        my $conversation_obj = App::Paws::ConversationStorage->new(
            context   => $context,
            workspace => $ws,
            write_cb  => $write_cb,
            name      => $conversation,
            id        => $conversation_map->{$conversation},
            data      => $data,
        );
        $conversation_obj->$method_name($since_ts);
        push @conversation_objs, $conversation_obj;
    }
    while (not $runner->poke()) {
        sleep(0.01);
    }
    for my $conversation_obj (@conversation_objs) {
        my $name = $conversation_obj->{'name'};
        $db->{'conversations'}->{$name} =
            $conversation_obj->to_data();
    }

    return 1;
}

sub _run_internal
{
    my ($self, $since_ts) = @_;

    my $context = $self->{'context'};
    my $ws      = $self->{'workspace'};
    my $to      = $context->user_email();
    my $name    = $self->{'name'};
    my $runner  = $self->{'context'}->runner();

    my $path = $context->db_directory().'/'.$name.'-receiver-db';
    if (not -e $path) {
        write_file($path, encode_json({
            'conversation-map' => {},
            'conversations'    => {},
        }));
    }

    my $db = decode_json(read_file($path));
    my $conversation_map = $db->{'conversation-map'};
    my %previous_map = %{$conversation_map};
    my $has_cached = (keys %previous_map > 0) ? 1 : 0;

    my $used_cached = 0;
    if ($has_cached) {
        $used_cached = 1;
    } else {
        $ws->conversations()->retrieve();
        for my $conversation (@{$ws->conversations()->get_list()}) {
            if (($conversation->{'type'} eq 'im')
                    or ($conversation->{'is_member'})) {
                my $name = $conversation->{'name'};
                $conversation_map->{$name} = $conversation->{'id'};
            }
        }
    }

    my @conversation_names = keys %{$conversation_map};

    my @actual_conversations =
        uniq
        map { ($_ eq '*')           ? @conversation_names
            : ($_ =~ /^(.*?)\/\*$/) ? (grep { /^$1\// }
                                            @conversation_names)
                                    : $_ }
            @{$ws->configured_conversations() || []};

    my %conversation_to_last_ts =
        map { $_ => $db->{'conversations'}->{$_}->{'last_ts'} || 1 }
            @actual_conversations;

    my @sorted_conversations =
        sort { $conversation_to_last_ts{$b} <=>
               $conversation_to_last_ts{$a} }
            @actual_conversations;

    _process_conversations($context, $ws, $runner, $since_ts, $db,
                           $self->{'write_cb'}, $conversation_map,
                           'receive_messages',
                           \@sorted_conversations);

    my @new_conversations;
    if ($has_cached) {
        $ws->conversations()->retrieve();
        for my $conversation (@{$ws->conversations()->get_list()}) {
            if (($conversation->{'type'} eq 'im')
                    or ($conversation->{'is_member'})) {
                my $name = $conversation->{'name'};
                $conversation_map->{$name} = $conversation->{'id'};
            }
        }
        for my $name (keys %{$conversation_map}) {
            if (not $previous_map{$name}) {
                push @new_conversations, $name;
            }
        }
        _process_conversations($context, $ws, $runner, $since_ts, $db,
                               $self->{'write_cb'}, $conversation_map,
                               'receive_messages',
                               \@new_conversations);
    }

    _process_conversations($context, $ws, $runner, $since_ts, $db,
                           $self->{'write_cb'}, $conversation_map,
                           'receive_threads',
                           [@sorted_conversations,
                            @new_conversations]);

    $db->{'conversation-map'} = $conversation_map;

    write_file($path, encode_json($db));
}

sub run
{
    my ($self, $since_ts) = @_;

    my $db_dir = $self->{'context'}->db_directory();
    my $lock_path = $db_dir.'/'.$self->{'name'}.'-lock';
    my $lock = App::Paws::Lock->new(path => $lock_path);
    eval { $self->_run_internal($since_ts); };
    my $error = $@;
    $lock->unlock();
    if ($error) {
        print STDERR "Unable to receive messages: $error\n";
        return;
    }
    return 1;
}

1;

__END__

=head1 NAME

App::Paws::Receiver

=head1 DESCRIPTION

Iterates over the conversations for a workspace, retrieving new
messages, as well as accounting for any edits/deletions that have
occurred.

=head1 CONSTRUCTOR

=over 4

=item B<new>

Arguments (hash):

=over 8

=item context

The current L<App::Paws::Context> object.

=item workspace

The L<App::Paws::Workspace> object for the
workspace.

=item name

The name of this receiver, as a string.  This is
used to uniquely identify this receiver instance.

=item write_cb

A coderef that takes a L<MIME::Entity> object and
writes it to storage.

=back

Returns a new instance of L<App::Paws::Receiver>.

=back

=head1 PUBLIC METHODS

=over 4

=item B<run>

Takes a lower-bound timestamp as its single argument (optional).
Iterates over the conversations for the current workspace, retrieving
new messages, and writing them to disk per the C<write_cb> coderef.
The lower-bound timestamp is used to skip messages in the history.

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
