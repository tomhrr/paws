package App::Paws::Runner;

use warnings;
use strict;

use HTTP::Async;
use HTTP::Async::Polite;
use Time::HiRes qw(time);

sub new
{
    my $class = shift;
    my %args = @_;
    my $self = {
        rates   => $args{'rates'},
        backoff => $args{'backoff'},
        tags    => {}
    };
    bless $self, $class;
    return $self;
}

sub _init_tag
{
    my ($self, $tag) = @_;

    my $async = $self->{'tags'}->{$tag};
    if ($async) {
        return 1;
    }

    $self->{'tags'}->{$tag} = {
        async      => HTTP::Async->new(),
        pending    => [],
        incomplete => {},
        last_added => 0,
    };

    return 1;
}

sub process_429
{
    my ($self, $tag, $res) = @_;

    print STDERR "Received 429 response, reducing query rate.\n";

    my $tag_data = $self->{'tags'}->{$tag};
    my $async = $tag_data->{'async'};
    $async->remove_all();
    my $pending = $tag_data->{'pending'};
    unshift @{$pending}, values %{$tag_data->{'incomplete'}};
    $tag_data->{'incomplete'} = {};

    my $retry_after = $res->header('Retry-After');
    sleep($retry_after);

    $self->{'rates'}->{$tag} /= ($self->{'backoff'} || 5);

    return 1;
}

sub poke
{
    my ($self, $tag) = @_;

    my @tags = $tag ? ($tag) : (keys %{$self->{'tags'}});

    my $finished = 1;
    for my $tag (@tags) {
        my $tag_data = $self->{'tags'}->{$tag};
        my ($async, $pending, $incomplete, $last_added) =
            @{$tag_data}{qw(async pending incomplete last_added)};
        my $interval = (60 / ($self->{'rates'}->{$tag} || 60));
        my $time = time();
        if (@{$pending} and ($time > ($last_added + $interval))) {
            my $next_pending = shift @{$pending};
	    my ($req, $fn) = @{$next_pending};
            my $task_id = $async->add($req);
            $incomplete->{$task_id} = $next_pending;
            $tag_data->{'last_added'} = $time;
            $async->poke();
        }
        while (my ($res, $task_id) = $async->next_response()) {
            if ($res->code() == 429) {
                $self->process_429($tag, $res);
                goto &poke;
            }

            my $fn = $incomplete->{$task_id}->[1];
            $fn->($self, $res, $fn);
            delete $incomplete->{$task_id};
            goto &poke;
        }
        if (@{$pending} or $async->not_empty()) {
            $finished = 0;
        }
    }

    return $finished;
}

sub add
{
    my ($self, $tag, $request, $fn) = @_;

    $self->_init_tag($tag);
    my $tag_data = $self->{'tags'}->{$tag};
    push @{$tag_data->{'pending'}}, [ $request, $fn ];
    $self->poke();

    return 1;
}

1;
