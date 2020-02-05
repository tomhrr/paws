package App::Paws::Receiver::maildir;

use warnings;
use strict;

use Encode;
use File::Basename qw(basename);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use HTML::Entities qw(decode_entities);
use HTTP::Request;
use JSON::XS qw(decode_json encode_json);
use List::Util qw(min minstr first);
use MIME::Entity;
use POSIX qw(strftime);
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
        write_callback => sub {
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
