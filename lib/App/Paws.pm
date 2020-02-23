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
        $receiver->workspace()->conversations()->retrieve_nb();
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
        for my $module (qw(conversations users)) {
            $ws->{$module}->{'retrieving'} = 0;
            $ws->{$module}->{'retrieved'}  = 0;
        };
    }

    return 1;
}

1;
