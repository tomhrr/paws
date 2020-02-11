package App::Paws::Receiver::MDA;

use warnings;
use strict;

use IPC::Run3;

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

    my $ft = File::Temp->new();
    my $fn = $ft->filename();

    my $receiver = App::Paws::Receiver->new(
        workspace => $self->{'workspace'},
        context   => $self->{'context'},
        name      => $self->{'name'},
        write_cb => sub {
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

    $receiver->run($since_ts);
    return 1;
}

1;
