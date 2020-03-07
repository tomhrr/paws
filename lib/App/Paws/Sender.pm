package App::Paws::Sender;

use warnings;
use strict;

use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use HTTP::Request;
use HTTP::Request::Common qw(POST);
use JSON::XS qw(decode_json encode_json);
use List::MoreUtils qw(uniq);
use MIME::Parser;
use URI;

use App::Paws::Debug qw(debug);
use App::Paws::Lock;
use App::Paws::Utils qw(get_mail_date);

my $MAX_FAILURE_COUNT = 5;

sub new
{
    my $class = shift;
    my %args = @_;
    my $self = \%args;
    bless $self, $class;
    return $self;
}

sub _write_bounce
{
    my ($self, $message_id, $error_message) = @_;

    my $bounce_dir = $self->{'bounce_dir'};
    my $context = $self->{'context'};
    $error_message ||= 'no additional error detail provided';

    my $fn = time().'.'.$$.'.'.int(rand(1000000));
    my $date = get_mail_date(time());
    my $domain = $context->domain_name();
    my $to = $context->user_email();
    my $tmp_path = "$bounce_dir/tmp/$fn";
    my $new_path = "$bounce_dir/new/$fn";
    write_file($tmp_path, <<EOF);
Date: $date
From: admin\@$domain
To: $to
Subject: Bounce message
Content-Type: text/plain

Unable to deliver message (message ID '$message_id'): $error_message
EOF
    rename($tmp_path, $new_path);
    debug("Wrote bounce message ($message_id) to '$new_path'");

    return 1;
}

sub _create_conversation
{
    my ($self, $ws, $message_id, $user_ids) = @_;

    my $context = $self->{'context'};
    my %post_data = (
        users => (join ',', @{$user_ids})
    );

    my $req = HTTP::Request->new();
    $req->header('Content-Type'  => 'application/json; charset=UTF-8');
    $req->header('Authorization' => 'Bearer '.$ws->token());
    $req->uri($context->slack_base_url().'/conversations.open');
    $req->method('POST');
    $req->content(encode_json(\%post_data));

    my $ua = $context->ua();
    my $res = $ua->request($req);
    if (not $res->is_success()) {
        $self->_write_bounce($message_id,
                             "Unable to create new conversation: ".
                             $res->as_string());
        return;
    }
    my $data = decode_json($res->decoded_content());
    if (not $data->{'ok'}) {
        $self->_write_bounce($message_id,
                             "Unable to create new conversation: ".
                             $res->as_string().": ".
                             encode_json(\%post_data));
        return;
    }
    my $conversation_id = $data->{'channel'}->{'id'};
    return $conversation_id;
}

sub _get_conversation_for_single_recipient
{
    my ($self, $to, $message_id) = @_;

    my $context = $self->{'context'};
    my ($local, $domain) = split /@/, $to;
    my ($type, $name) = split /\s*\/\s*/, $local;
    my $thread_ts;
    if ($name =~ /\+/) {
        ($thread_ts) = ($name =~ /.*\+(.*)/);
        $name =~ s/\+.*//;
    }

    my $base = $context->domain_name();
    if ($domain !~ /^(.*)\.$base$/) {
        $self->_write_bounce($message_id,
                             "Message has non-Slack recipient: $to");
        return;
    }
    my $ws_name = $1;
    my $ws = $context->workspaces()->{$ws_name};
    if (not $ws) {
        $self->_write_bounce($message_id,
                             "Workspace '$ws_name' does not exist");
        return;
    }

    my $conversation_id =
        $ws->conversations_obj()->name_to_id("$type/$name");

    return ($ws, $conversation_id, $thread_ts);
}

sub _process_emails
{
    my ($entity, $header) = @_;

    my @emails =
        map { s/.*<(.*)>.*/$1/g; chomp; $_ }
            split /\s*,\s*/, ($entity->head()->decode()->get($header) || '');

    return \@emails;
}

sub _send_queued_single
{
    my ($self, $entity) = @_;

    debug("Sending queued message (subject: ".
          $entity->head()->decode()->get('Subject').")");

    my $context = $self->{'context'};
    my $ua      = $context->ua();
    my $runner  = $context->runner();

    my @tos = @{_process_emails($entity, 'To')};
    my @ccs = @{_process_emails($entity, 'Cc')};

    my $message_id = $entity->head()->decode()->get('Message-ID');

    my $ws;
    my $thread_ts;
    my $base = $context->domain_name();
    my $conversation_id;

    if ((@tos == 1) and not @ccs) {
        ($ws, $conversation_id, $thread_ts) =
            $self->_get_conversation_for_single_recipient(
                $tos[0], $message_id
            );
        if (not $ws) {
            debug("No workspace found for message, returning");
            return 1;
        }
    }

    if (not $conversation_id) {
        debug("Conversation not found, creating new one");
        my @recipients = (@tos, @ccs);
        my @usernames;
        my @ws_names;
        for my $recipient (@recipients) {
            my ($username, $domain) = split /@/, $recipient;
            if ($domain !~ /^(.*)\.$base$/) {
                $self->_write_bounce($message_id,
                                     "Message has non-Slack recipient: ".
                                     $recipient);
                return 1;
            }
            my $ws_name = $1;
            if (not $context->workspaces()->{$ws_name}) {
                $self->_write_bounce($message_id,
                                     "Workspace '$ws_name' does ".
                                     "not exist");
                return 1;
            }
            push @usernames, $username;
            push @ws_names, $ws_name;
        }
        @ws_names = uniq @ws_names;
        if (@ws_names > 1) {
            $self->_write_bounce($message_id,
                                 "Unable to send message to multiple ".
                                 "workspaces");
            return 1;
        }
        $ws = $context->workspaces()->{$ws_names[0]};
        my @user_ids;
        for my $username (@usernames) {
            my $user_id = $ws->users()->name_to_id($username);
            if (not $user_id) {
                $self->_write_bounce($message_id,
                                     "Invalid username: '$username'");
                return 1;
            }
            push @user_ids, $user_id;
        }
        @user_ids = uniq @user_ids;
        $conversation_id = $self->_create_conversation($ws, $message_id,
                                                       \@user_ids);
    }

    if (not $conversation_id) {
        debug("Unable to find/create conversation, returning");
        $self->_write_bounce($message_id,
                             "Unable to find conversation ID");
        return 1;
    }

    my $text_data;
    my @attachment_reqs;
    my @temp_files;
    if ($entity->parts() > 0) {
        for (my $i = 0; $i < $entity->parts(); $i++) {
            my $part = $entity->parts($i);
            if (($part->head()->get('Content-Type') =~ /^text\/plain;?/)
                    and not $text_data) {
                $text_data = $part->bodyhandle()->as_string();
                next;
            }

            my $filename = $part->head()->recommended_filename();
            $filename =~ s/\?.*//;
            my $temp_file = File::Temp->new();
            print $temp_file $part->bodyhandle()->as_string();
            $temp_file->flush();
            push @temp_files, $temp_file;
            my $uri = URI->new($context->slack_base_url().'/files.upload');
            my $attachment_req =
                POST($uri,
                     Content_Type => 'form-data',
                     Content      => [
                         file     => [$temp_file->filename()],
                         filename => $filename,
                         title    => $filename,
                         token    => $ws->token(),
                         channels => $conversation_id
                     ]);
            push @attachment_reqs, $attachment_req;
        }
    } else {
        $text_data = $entity->bodyhandle()->as_string();
    }

    my %post_data = (
        channel => $conversation_id,
        text    => $text_data,
        as_user => 1,
        ($thread_ts ? (thread_ts => $thread_ts) : ())
    );

    my $req = HTTP::Request->new();
    $req->header('Content-Type'  => 'application/json');
    $req->header('Authorization' => 'Bearer '.$ws->token());
    $req->uri($context->slack_base_url().'/chat.postMessage');
    $req->method('POST');
    $req->content(encode_json(\%post_data));
    debug("Sending message to Slack");

    my $res = $ua->request($req);
    if (not $res->is_success()) {
        my $client_warning =
            $res->headers()->header('Client-Warning');
        if ($client_warning eq 'Internal response') {
            print STDERR "Unable to send message, will retry later: ".
                         $res->status_line()."\n";
            return;
        } else {
            $self->_write_bounce($message_id,
                                 $res->as_string());
            return 1;
        }
    }
    my $data = decode_json($res->decoded_content());
    if (not $data->{'ok'}) {
        $self->_write_bounce($message_id,
                             $res->as_string());
        return 1;
    }

    for my $attachment_req (@attachment_reqs) {
        my $res = $ua->request($attachment_req);
        if (not $res->is_success()) {
            print STDERR "Unable to send attachment, bouncing: ".
                         $res->as_string()."\n";
            $self->_write_bounce($message_id,
                                 $res->as_string());
            return 1;
        }
        my $data = decode_json($res->decoded_content());
        if (not $data->{'ok'}) {
            $self->_write_bounce($message_id,
                                 $res->as_string());
            return 1;
        }
    }
    debug("Message sent successfully");

    return 1;
}

sub submit
{
    my ($self, $args, $fh) = @_;

    my $context = $self->{'context'};
    my $domain_name = $context->domain_name();
    my @lines = <$fh>;

    my $temp_file = File::Temp->new(UNLINK => 0);
    print $temp_file @lines;
    $temp_file->flush();
    $temp_file->seek(0, 0);

    my $parser = MIME::Parser->new();
    my $parser_dir = tempdir();
    $parser->output_under($parser_dir);
    my $entity = $parser->parse($temp_file);

    my $to = $entity->head()->get('To');
    if ($to !~ /$domain_name/) {
        my $fallback_sendmail = $self->{'fallback_sendmail'};
        my $res = system("$fallback_sendmail ".
                         (join ' ', @{$args})." < ".$temp_file->filename());
        return (not $res);
    }

    my $queue_dir = $context->queue_directory();
    write_file($queue_dir.'/'.$$.'-'.time().'-'.(int(rand(10000))), @lines);

    return 1;
}

sub send_queued
{
    my ($self) = @_;

    my $context = $self->{'context'};
    my $ua      = $context->ua();
    my $to      = $context->user_email();

    my $queue_dir  = $context->queue_directory();
    my $queue_lock = $queue_dir.'/lock';
    my $lock       = App::Paws::Lock->new(path => $queue_lock);

    my $path = $context->db_directory().'/sender';
    if (not -e $path) {
        write_file($path, encode_json({ failures => {} }));
    }
    my $db = decode_json(read_file($path));

    eval {
        my $dh;
        opendir $dh, $queue_dir or die $!;
        while (my $entry = readdir($dh)) {
            if (($entry eq '.') or ($entry eq '..') or ($entry eq 'lock')) {
                next;
            }
            my $entry_path = $queue_dir.'/'.$entry;
            if (-f $entry_path) {
                my $parser = MIME::Parser->new();
                my $parser_dir = tempdir();
                $parser->output_under($parser_dir);
                open my $fh, '<', $entry_path or die $!;
                my $entity = $parser->parse($fh);
                close $fh;

                my $res = $self->_send_queued_single($entity);
                if (not $res) {
                    my $message_id =
                        $entity->head()->decode->get('Message-ID');
                    $db->{'failures'}->{$message_id}++;
                    if ($db->{'failures'}->{$message_id} >= $MAX_FAILURE_COUNT) {
                        $self->_write_bounce(
                            $message_id,
                            'Failed to deliver message '.
                            $db->{'failures'}->{$path}.' times, '.
                            'giving up (message: '.
                            $entity->as_string().')'
                        );
                        unlink $entry_path;
                    }
                } else {
                    unlink $entry_path;
                }
            }
        }
    };

    my $error = $@;
    $lock->unlock();
    if ($error) {
        print STDERR "Unable to process queue: $error\n";
        return;
    }

    write_file($path, encode_json($db));
}

1;

__END__

=head1 NAME

App::Paws::Sender

=head1 DESCRIPTION

Handles sending mail, either to Slack directly via the API, or to a
fallback sendmail command.

=head1 CONSTRUCTOR

=over 4

=item B<new>

Arguments (hash):

=over 8

=item bounce_dir

The path to the maildir into which bounce messages
should be written.

=item context

The current L<App::Paws::Context> object.

=item fallback_sendmail

The path to the sendmail command that should be
used for all non-Slack messages.

=back

Returns a new instance of L<App::Paws::Sender>.

=back

=head1 PUBLIC METHODS

=over 4

=item B<submit>

Takes an arrayref of sendmail arguments and a message input filehandle
as its arguments.  If the message is for Slack, then it is submitted
to the message queue.  Otherwise, the C<fallback_sendmail> command is
executed with the sendmail arguments, with the message input data
passed in as its standard input.

=item B<send_queued>

Sends all queued messages to Slack.  If a transient error is
encountered during message sending, then the message is requeued.  If
a permanent error is encountered, then a bounce message is written to
the maildir at C<bounce_dir>.  If a transient error is seen five times
for a given message, then a bounce message is written to the maildir
at C<bounce_dir>, and the message is not requeued.

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
