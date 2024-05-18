package App::Paws::Message;

use warnings;
use strict;

use Encode;
use HTML::Entities qw(decode_entities);
use HTTP::Request;
use MIME::Entity;

use App::Paws::Utils qw(get_mail_date);

sub new
{
    my ($class, $context, $workspace, $conversation, $message_data) = @_;

    my $self = {
        context           => $context,
        workspace         => $workspace,
        conversation_name => $conversation,
        edited_ts         => $message_data->{'edited'}->{'ts'},
        (map { $_ => $message_data->{$_} }
            qw(ts thread_ts user text files)),
    };
    bless $self, $class;
    return $self;
}

sub _user
{
    return $_[0]->{'user'};
}

sub _text
{
    return $_[0]->{'text'};
}

sub _files
{
    return $_[0]->{'files'};
}

sub ts
{
    return $_[0]->{'ts'};
}

sub thread_ts
{
    return $_[0]->{'thread_ts'};
}

sub edited_ts
{
    return $_[0]->{'edited_ts'};
}

sub _substitute_user_mentions
{
    my ($self, $content) = @_;

    my $ws = $self->{'workspace'};
    my @ats = ($content =~ /<\@(U.*?)>/g);
    my %at_map = map { $_ => $ws->users()->id_to_name($_) } @ats;
    for my $at (keys %at_map) {
        if (my $name = $at_map{$at}) {
            $content =~ s/<\@$at>/<\@$name>/g;
        }
    }

    return $content;
}

sub _add_attachment
{
    my ($self, $entity, $file) = @_;

    my $context = $self->{'context'};
    my $token = $self->{'workspace'}->token();

    my $req = HTTP::Request->new();
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');
    $req->header('Authorization' => 'Bearer '.$token);
    my $url_private = $file->{'url_private'};
    if ($url_private =~ /^\//) {
        $url_private = $context->slack_base_url().$url_private;
    }
    $req->uri($url_private);
    $req->method('GET');
    my $filename = $file->{'url_private'};
    $filename =~ s/.*\///;
    # File retrieval via the runner does not work, for some reason, so
    # this just makes the call directly.
    my $ua = $context->ua();
    my $res = $ua->request($req);
    if (not $res->is_success()) {
        warn "Unable to download attachment ($url_private)";
    }

    $entity->attach(Type     => $file->{'mimetype'},
                    Data     => $res->content(),
                    Filename => $filename);

    return 1;
}

sub id
{
    my ($self, $ignore_edited) = @_;

    my $context = $self->{'context'};
    my $ws_name = $self->{'workspace'}->name();
    my $conversation = $self->{'conversation_name'};

    my $ts = $self->ts();
    my $local_part = "$ts.$conversation";
    my $edited_ts = $self->edited_ts();
    if ((not $ignore_edited) and $edited_ts) {
        $local_part = "$edited_ts.$local_part";
    }

    my $domain_name = $context->domain_name();
    return "<$local_part\@$ws_name.$domain_name>";
}

sub to_entity
{
    my ($self, $first_ts, $thread_ts, $reply_to_id) = @_;

    my $context = $self->{'context'};
    my $ws = $self->{'workspace'};
    my $ws_name = $ws->name();
    my $conversation = $self->{'conversation_name'};

    my $token = $ws->token();
    my $reply_to_thread = ($thread_ts ne $first_ts);

    my $ts = $self->ts();
    $ts =~ s/\..*//;

    my $from_user = 'unknown';
    my $user = $self->_user();
    if ($user) {
        my $name = $ws->users()->id_to_name($user);
        if ($name) {
            $from_user = $name;
        }
    }

    my $content = $self->_substitute_user_mentions($self->_text());

    my $domain_name = $context->domain_name();
    my $ws_domain_name = "$ws_name.$domain_name";
    my $message_id = $self->id();

    my $entity = MIME::Entity->build(
        Date         => get_mail_date($ts),
        From         => "$from_user\@$ws_domain_name",
        To           => $context->user_email(),
        Subject      => "Message from $conversation".
                        ($self->edited_ts() ? ' (edited)' : ''),
        'Message-ID' => $message_id,
        Charset      => 'UTF-8',
        Encoding     => 'base64',
        Data         => Encode::encode('UTF-8', decode_entities($content),
                                       Encode::FB_CROAK)
    );

    for my $file (@{$self->_files() || []}) {
        $self->_add_attachment($entity, $file);
    }

    my $parent_message = App::Paws::Message->new(
        $context, $ws, $conversation, { ts => $thread_ts }
    );
    my $parent_id = $parent_message->id();
    if (($parent_id ne $message_id) or $reply_to_id) {
        $entity->head()->add('In-Reply-To', ($reply_to_id || $parent_id));
        if ($reply_to_thread) {
            my $first_message = App::Paws::Message->new(
                $context, $ws, $conversation, { ts => $first_ts }
            );
            my $first_id = $first_message->id();
            $entity->head()->add('References', "$first_id $parent_id");
        } else {
            $entity->head()->add('References', "$parent_id");
        }
    }

    my $reply_to =
        ($reply_to_thread)
            ? "$conversation+$thread_ts\@$ws_domain_name\n"
            : "$conversation\@$ws_domain_name\n";
    $entity->head()->add('Reply-To', $reply_to);
    $entity->head()->add('X-Paws-Thread-TS', $thread_ts);
    $entity->head()->delete('X-Mailer');

    return $entity;
}

sub to_delete_entity
{
    my ($self) = @_;

    my $context = $self->{'context'};
    my $ws_name = $self->{'workspace'}->name();
    my $conversation = $self->{'conversation_name'};

    my $message_id = $self->id();
    my $del_message_id = $message_id;
    $del_message_id =~ s/@/.deleted@/;

    my $domain_name = $context->domain_name();
    my $ws_domain_name = "$ws_name.$domain_name";

    my $time = time();
    my $entity = MIME::Entity->build(
        Date          => get_mail_date($time),
        From          => "paws-admin\@$ws_domain_name",
        To            => $context->user_email(),
        Subject       => "Message from $conversation (deleted)",
        'Message-ID'  => $del_message_id,
        'References'  => $message_id,
        Charset       => 'UTF-8',
        Encoding      => 'base64',
        Data          => 'Message deleted.',
    );
    $entity->head()->add('In-Reply-To', $message_id);
    $entity->head()->delete('X-Mailer');

    return $entity;
}

1;

__END__

=head1 NAME

App::Paws::Message

=head1 DESCRIPTION

Convert a Slack message into a L<MIME::Entity>, for further
processing.

=head1 CONSTRUCTOR

=over 4

=item B<new>

Arguments (list):

=over 8

=item context

The current L<App::Paws::Context> object.

=item workspace

The L<App::Paws::Workspace> object for the
workspace of this conversation.

=item conversation_name

The name of the conversation for this message, per
the conversation data from
L<App::Paws::Workspace::Conversations>.

=item message_data

The message's data, as returned by the Slack API.

=back

Returns a new instance of L<App::Paws::Message>.

=back

=head1 PUBLIC METHODS

=over 4

=item B<ts>

Returns the timestamp of the message.

=item B<thread_ts>

If the message is the beginning of a thread, returns the thread
timestamp.

=item B<edited_ts>

Returns the timestamp of when the message was last edited, if
applicable.

=item B<id>

Takes a single boolean argument, indicating whether the edited
timestamp should be ignored, if it is set, for the purposes of ID
generation.  Returns the value to be used as the 'Message-ID' header
value for this message.  The edited timestamp can be ignored in order
to find the ID for the original message, which can then be used to
fill in headers like 'In-Reply-To' and 'References'.

=item B<to_entity>

Takes the timestamp of the first message for the conversation, the
thread timestamp for this message, and the message ID of the message
to which this message is a reply as its arguments.  Returns a
L<MIME::Entity> representing the message.  If the message is not in a
thread, then the timestamp of the first message for the conversation
should be passed in as the second argument.

=item B<to_delete_entity>

Returns a L<MIME::Entity> representing a message indicating that the
current message has been deleted.

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
