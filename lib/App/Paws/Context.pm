package App::Paws::Context;

use warnings;
use strict;

use App::Paws::Workspace;
use App::Paws::Runner;

our $SLACK_BASE_URL = 'https://slack.com/api';

sub new
{
    my $class = shift;
    my %args = @_;

    my $mul = $args{'config'}->{'rate_limiting'}->{'initial'} || 5;

    my $self = {
        config          => $args{'config'},
        queue_directory => $args{'queue_directory'},
        db_directory    => $args{'db_directory'},
        slack_base_url  => $SLACK_BASE_URL,
        ua              => LWP::UserAgent->new(),
        runner          => App::Paws::Runner->new(
	    rates => {
		'users.list'            => 20 * $mul,
		'conversations.list'    => 20 * $mul,
		'conversations.replies' => 50 * $mul,
		'conversations.history' => 50 * $mul,
	    },
            backoff => ($args{'config'}->{'rate_limiting'}->{'backoff'} || 5)
        ),
    };

    bless $self, $class;

    my %workspaces =
        map { my $ws_name = $_;
              my $ws_spec = $args{'config'}->{'workspaces'}->{$ws_name};
              my $ws = App::Paws::Workspace->new(
                  context => $self,
                  name    => $ws_name,
                  %{$ws_spec}
              );
              $ws->_init_users();
              $ws_name => $ws }
            keys %{$args{'config'}->{'workspaces'}};

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
    return $_[0]->{'config'}->{'domain_name'};
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

1;
