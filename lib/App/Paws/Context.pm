package App::Paws::Context;

use warnings;
use strict;

use LWP::UserAgent;

use App::Paws::Runner;
use App::Paws::Workspace;

our $SLACK_BASE_URL = 'https://slack.com/api';
our $DEFAULT_DOMAIN_NAME = 'slack.alt';

sub new
{
    my $class = shift;
    my %args = @_;

    my $config = $args{'config'};
    my $rate_limiting = $config->{'rate_limiting'};
    my $multiplier = $rate_limiting->{'initial'} || 5;

    my $self = {
        config          => $config,
        queue_directory => $args{'queue_directory'},
        db_directory    => $args{'db_directory'},
        slack_base_url  => $SLACK_BASE_URL,
        ua              => LWP::UserAgent->new(),
        runner          => App::Paws::Runner->new(
            rates => {
                'users.list'            => 20 * $multiplier,
                'conversations.list'    => 20 * $multiplier,
                'conversations.replies' => 50 * $multiplier,
                'conversations.history' => 50 * $multiplier,
            },
            backoff => ($rate_limiting->{'backoff'} || 5)
        ),
    };

    bless $self, $class;

    my %workspaces =
        map { my $ws_name = $_;
              my $ws_spec = $config->{'workspaces'}->{$ws_name};
              my $ws = App::Paws::Workspace->new(
                  context => $self,
                  name    => $ws_name,
                  conversations => $ws_spec->{'conversations'},
                  (map { $_ => $ws_spec->{$_} }
                      qw(token modification_window
                         thread_expiry))
              );
              $ws_name => $ws }
            keys %{$config->{'workspaces'}};

    $self->{'workspaces'} = \%workspaces;

    return $self;
}

sub ua
{
    return $_[0]->{'ua'};
}

sub runner
{
    return $_[0]->{'runner'};
}

sub domain_name
{
    return $_[0]->{'config'}->{'domain_name'} || 'slack.alt';
}

sub user_email
{
    return $_[0]->{'config'}->{'user_email'};
}

sub slack_base_url
{
    return $_[0]->{'slack_base_url'};
}

sub queue_directory
{
    return $_[0]->{'queue_directory'};
}

sub db_directory
{
    return $_[0]->{'db_directory'};
}

sub workspaces
{
    return $_[0]->{'workspaces'};
}

1;

__END__

=head1 NAME

App::Paws::Context

=head1 DESCRIPTION

Context object for use throughout the project.  Provides configuration
details, workspace objects, etc.

=head1 CONSTRUCTOR

=over 4

=item B<new>

Arguments (hash):

=over 8

=item config

A hashref of configuration details, per
L<README.md>.

=item queue_directory

The directory in which queued messages should be
stored.

=item db_directory

The directory in which the various databases
should be stored.

=back

Returns a new instance of L<App::Paws::Context>.

=back

=head1 PUBLIC METHODS

=over 4

=item B<ua>

Returns an instance of L<LWP::UserAgent>, for use when making HTTP
requests.

=item B<runner>

Returns an instance of L<App::Paws::Runner>, for use when making
asynchronous HTTP requests.

=item B<domain_name>

Returns the domain name used for Slack messages.

=item B<user_email>

Returns the email address used as the recipient ('To') address when
writing messages received from Slack.

=item B<slack_base_url>

Returns the base URL for the Slack API.

=item B<queue_directory>

Returns the directory in which queued messages should be stored.

=item B<db_directory>

Returns the directory in which databases should be stored.

=item B<workspaces>

Returns a hashref mapping from workspace name to workspace object.

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
