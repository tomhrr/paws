package App::Paws::Receiver::maildir;

use warnings;
use strict;

use File::Slurp qw(write_file);
use Sys::Hostname;

use App::Paws::Receiver;

sub new
{
    my $class = shift;
    my %args = @_;
    my $self = \%args;
    $self->{'workspace'} =
        $self->{'context'}->{'workspaces'}->{$self->{'workspace'}};
    bless $self, $class;
    return $self;
}

sub run
{
    my ($self, $counter, $since_ts) = @_;

    $counter ||= 1;

    my $ws = $self->{'workspace'};
    my $context = $self->{'context'};
    my $name = $self->{'name'};

    my $receiver = App::Paws::Receiver->new(
        workspace => $self->{'workspace'},
        context   => $self->{'context'},
        name      => $self->{'name'},
        write_cb => sub {
            my ($entity) = @_;

            my $maildir = $self->{'path'};
            my $ts = $entity->head()->get('Message-ID');
            $ts =~ s/^<//;
            $ts =~ s/\..*//;
            chomp $ts;

            my $fn = $ts.'.'.$$.'_'.$counter++.'.'.hostname();

            write_file($maildir.'/tmp/'.$fn, $entity->as_string());
            rename($maildir.'/tmp/'.$fn, $maildir.'/new/'.$fn);
        }
    );

    $receiver->run($since_ts);
    return 1;
}

1;
