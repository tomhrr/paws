package App::Paws;

use warnings;
use strict;

use App::Paws::Context;
use App::Paws::Sender;
use App::Paws::Receiver::maildir;
use App::Paws::Receiver::MDA;

use Cwd;
use File::Slurp qw(read_file write_file);
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
    my ($self, $counter) = @_;

    my $context = $self->{'context'};
    my $receiver_specs = $context->{'config'}->{'receivers'};
    for my $receiver_spec (@{$receiver_specs}) {
        my $type = $receiver_spec->{'type'};
        my $module_name = "App::Paws::Receiver::$type";
        my $receiver = $module_name->new(
            context => $context,
            %{$receiver_spec}
        );
        $receiver->run($counter);
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
        my $user_list = $ws->get_user_list();
        for my $user (@{$user_list}) {
            my ($real_name, $username) = @{$user};
            push @aliases,
                 "alias slack-$ws_name-$username $real_name ".
                 "<im/$username\@$ws_name.$domain>";
        }
    }
    return \@aliases;
}

1;