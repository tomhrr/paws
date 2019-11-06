package App::Paws::Receiver::MDA;

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
use IPC::Run3;

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
    my ($self, $counter) = @_;

    $counter ||= 1;

    my $ws = $self->{'workspace'};
    my $context = $self->{'context'};
    my $name = $self->{'name'};

    my $ft = File::Temp->new();
    my $fn = $ft->filename();

    my $receiver = App::Paws::Receiver->new(
        workspace => $self->{'workspace'},
        context   => $self->{'context'},
        name      => $self->{'name'},
        write_callback => sub {
            my ($entity) = @_;

            my $cmd = $self->{'path'};
            my @args = @{$self->{'args'} || []};
            my $data = $entity->as_string();
            my $stderr;
            eval { run3([$cmd, @args], \$data, \undef, \$stderr); };
            if (my $error = $@) {
                $stderr ||= "(no stderr output)"; 
                die "MDA execution failed: $stderr";
            }
            my $res = $?;
            if ($? != 0) {
                $stderr ||= "(no stderr output)"; 
                die "MDA execution failed: $stderr";
            }
            if ($stderr) {
                die "MDA execution failed: $stderr";
            }
        }
    );

    $receiver->run();
    return 1;
}

1;
