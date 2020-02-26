package App::Paws;

use warnings;
use strict;

use App::Paws::Context;
use App::Paws::Sender;
use App::Paws::Receiver::maildir;
use App::Paws::Receiver::MDA;

use Cwd;
use File::Slurp qw(read_file write_file);
use List::Util qw(first);
use YAML;

our $CONFIG_DIR  = $ENV{'HOME'}.'/.paws';
our $CONFIG_PATH = $CONFIG_DIR.'/config';
our $QUEUE_DIR   = $CONFIG_DIR.'/queue';
our $DB_DIR      = $CONFIG_DIR.'/db';

our $VERSION = '0.1';

sub new
{
    my $class = shift;
  
    my $config = YAML::LoadFile($CONFIG_PATH);
    for my $dir ($QUEUE_DIR, $DB_DIR) {
        if (not -e $dir) {
            mkdir $dir or die $!;
        }
    }
    
    my $context =
        App::Paws::Context->new(config          => $config,
                                queue_directory => $QUEUE_DIR,
                                db_directory    => $DB_DIR);

    my $sender_config = $context->{'config'}->{'sender'};
    my $sender = App::Paws::Sender->new(
        context           => $context,
        fallback_sendmail => $sender_config->{'fallback_sendmail'},
        bounce_dir        => $sender_config->{'bounce_dir'},
    );

    my $self = {
        context => $context,
        sender  => $sender,
    };

    bless $self, $class;
    return $self;
}

sub send
{
    my ($self, $args, $fh) = @_;

    $self->{'sender'}->submit($args, $fh);
}

sub send_queued
{
    my ($self) = @_;

    return $self->{'sender'}->send_queued();
}

sub receive
{
    my ($self, $counter, $name, $since_ts) = @_;

    my $context = $self->{'context'};
    my $receiver_specs = $context->{'config'}->{'receivers'};
    my @receiver_specs_to_process = @{$receiver_specs};
    if ($name) {
        my $receiver_spec =
            first { $_->{'name'} eq $name }
                @{$receiver_specs};
        if (not $receiver_spec) {
            die "Unable to find named receiver";
        }
        @receiver_specs_to_process = $receiver_spec;
    }
    my @receivers =
        map { my %args = %{$_};
              my $type = $args{'type'};
              my $module_name = "App::Paws::Receiver::$type";
              my $ws_name = delete $args{'workspace'};
              my $ws = $context->{'workspaces'}->{$ws_name};
              $module_name->new(context   => $context,
                                workspace => $ws,
                                %args) }
            @receiver_specs_to_process;
    for my $receiver (@receivers) {
        $receiver->workspace()->conversations_obj()->retrieve_nb();
    }
    for my $receiver (@receivers) {
        $receiver->run($counter, $since_ts);
    }

    return 1;
}

sub aliases
{
    my ($self) = @_;

    my $context = $self->{'context'};
    my $domain = $context->domain_name();
    my @aliases;
    for my $ws_name (keys %{$context->{'workspaces'}}) {
        my $ws = $context->{'workspaces'}->{$ws_name};
        $ws->users()->retrieve();
        my $user_list = $ws->users()->get_list();
        for my $user (@{$user_list}) {
            my ($real_name, $username) = @{$user};
            push @aliases,
                 "alias slack-$ws_name-$username $real_name ".
                 "<im/$username\@$ws_name.$domain>";
        }
    }
    return \@aliases;
}

sub reset
{
    my ($self) = @_;

    my $context = $self->{'context'};
    for my $ws (values %{$context->{'workspaces'}}) {
        for my $module (qw(conversations_obj users)) {
            $ws->{$module}->{'retrieving'} = 0;
            $ws->{$module}->{'retrieved'}  = 0;
        };
    }

    return 1;
}

1;

__END__

=head1 NAME

App::Paws

=head1 DESCRIPTION

Provides for sending messages, receiving messages for a set of
workspaces, and generating aliases for a set of workspaces.

=head1 CONSTRUCTOR

=over 4

=item B<new>

Loads configuration from the '.paws' directory in the user's home
directory, instantiates helper objects accordingly, and returns a new
instance of L<App::Paws>.

=back

=head1 PUBLIC METHODS

=over 4

=item B<send>

See L<App::Paws::Sender::submit>.

=item B<send_queued>

See L<App::Paws::Sender::send_queued>.

=item B<receive>

Takes a message counter, a receiver name, and a lower-bound timestamp
as its arguments (each is optional).  Receives messages for the
specified receiver, if a name was provided, or all receivers
otherwise.  If the lower-bound timestamp is provided, then only
messages with a timestamp from that point onwards are received.

=item B<aliases>

Returns an arrayref comprising alias directives for each user in each
workspace, for use in a Mutt aliases file.

=item B<reset>

Resets the current workspace state, so that they can be used to
re-retrieve conversation and user lists from Slack.

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
