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
    my $self = { %args, tags => {} };
    bless $self, $class;
    return $self;
}

sub _init_tag
{
    my ($self, $tag) = @_;

    my $async = $self->{'asyncs'}->{$tag};
    if ($async) {
        return 1;
    }

    $async = HTTP::Async->new();
    $self->{'asyncs'}->{$tag} = $async;
    $self->{'id'}->{$tag} = 1;
    $self->{'pending'}->{$tag} = [];
    $self->{'incomplete'}->{$tag} = {};
    $self->{'id_to_fn'}->{$tag} = {};
    $self->{'completed'}->{$tag} = {};
    $self->{'tags'}->{$tag} = 1;

    return 1;
}

sub process_tmr
{
    my ($self, $tag, $res) = @_;

    warn "Received 429 response, reducing query rate.\n";

    my $async = $self->{'asyncs'}->{$tag};
    $async->remove_all();
    my $pending = $self->{'pending'}->{$tag};
    my $c = scalar(values %{$self->{'incomplete'}->{$tag}});
    unshift @{$pending}, values %{$self->{'incomplete'}->{$tag}};
    $self->{'incomplete'}->{$tag} = {};

    my $ra = $res->header('Retry-After');
    sleep($ra);

    $self->{'rates'}->{$tag} /= ($self->{'backoff'} || 5);

    return 1;
}

sub poke
{
    my ($self, $tag) = @_;

    my @tags = $tag ? ($tag) : (keys %{$self->{'tags'}});
    start_again:
    my $finished = 1;
    for my $tag (@tags) {
        my $async = $self->{'asyncs'}->{$tag};
        my $pending = $self->{'pending'}->{$tag};
        my $last_added = $self->{'last_added'}->{$tag} || 0;
        my $interval = (60 / ($self->{'rates'}->{$tag} || 60));
        my $time = time();
        if (@{$pending} and ($time > ($last_added + $interval))) {
            my $p = shift @{$pending};
	    my ($req, $fn, $id) = @{$p};
            my $iid = $async->add($req);
            $self->{'incomplete'}->{$tag}->{$iid} = $p;
            $self->{'last_added'}->{$tag} = $time;
            $async->poke();
            $self->{'id_to_iid'}->{$tag}->{$id} = $iid;
            $self->{'iid_to_id'}->{$tag}->{$iid} = $id;
            $self->{'iid_to_fn'}->{$tag}->{$iid} = $fn;
        }
        while (my ($res, $iid) = $async->next_response()) {
            if ($res->code() == 429) {
                $self->process_tmr($tag, $res);
                goto start_again;
            }

            my $fn = $self->{'iid_to_fn'}->{$tag}->{$iid};
            my $res2 = $fn->(
                $self,
                $res,
                $fn
            );
            delete $self->{'incomplete'}->{$tag}->{$iid};
            $self->{'completed'}->{$tag}->{
                $self->{'iid_to_id'}->{$tag}->{$iid}
            } = $res2;
            goto start_again;
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

    my $id = $self->{'id'}->{$tag};
    $self->{'id'}->{$tag}++;
    push @{$self->{'pending'}->{$tag}},
        [ $request, $fn, $id ];
    $self->poke();

    return $id;
}

sub get_result
{
    my ($self, $tag, $id) = @_;

    if (exists $self->{'completed'}->{$tag}->{$id}) {
        return $self->{'completed'}->{$tag}->{$id};
    }

    return;
}

1;
