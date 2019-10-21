package App::Paws::Runner;

use warnings;
use strict;

use HTTP::Async;
use HTTP::Async::Polite;

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

    $async = HTTP::Async::Polite->new(
        send_interval => (60 / ($self->{'rates'}->{$tag} || 60))
    );
    $self->{'asyncs'}->{$tag} = $async;

    $self->{'id'}->{$tag} = 1;
    $self->{'pending'}->{$tag} = [];
    $self->{'id_to_fn'}->{$tag} = {};
    $self->{'completed'}->{$tag} = {};
    $self->{'tags'}->{$tag} = 1;

    return 1;
}

sub poke
{
    my ($self, $tag) = @_;

    my @tags = $tag ? ($tag) : (keys %{$self->{'tags'}});
    my $finished = 1;
    for my $tag (@tags) {
        my $async = $self->{'asyncs'}->{$tag};
        my $pending = $self->{'pending'}->{$tag};
        my @still_pending;
        for my $p (@{$pending}) {
            my ($req, $deps, $fn, $id) = @{$p};
            my $met = 1;
            for my $d (@{$deps}) {
                my ($tag, $id) = @{$d};
                if (not $self->{'completed'}->{$tag}->{$id}) {
                    $met = 0;
                    last;
                }
            }
            if ($met == 0) {
                push @still_pending, $p;
                next;
            }
            my $iid = $async->add($req);
            $self->{'id_to_iid'}->{$tag}->{$id} = $iid;
            $self->{'iid_to_id'}->{$tag}->{$iid} = $id;
            $self->{'iid_to_fn'}->{$tag}->{$iid} = $fn;
        }
        $self->{'pending'}->{$tag} = \@still_pending;
        while (my ($res, $iid) = $async->next_response()) {
            my $fn = $self->{'iid_to_fn'}->{$tag}->{$iid};
            my $res2 = $fn->(
                $self,
                $res,
                $fn
            );
            $self->{'completed'}->{$tag}->{
                $self->{'iid_to_id'}->{$tag}->{$iid}
            } = $res2;
        }
        if (@{$pending} or $async->not_empty()) {
            $finished = 0;
        }
    }

    return $finished;
}

sub add
{
    my ($self, $tag, $request, $dependencies, $fn) = @_;

    $self->_init_tag($tag);

    my $id = $self->{'id'}->{$tag};
    $self->{'id'}->{$tag}++;
    push @{$self->{'pending'}->{$tag}},
        [ $request, $dependencies, $fn, $id ];
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
