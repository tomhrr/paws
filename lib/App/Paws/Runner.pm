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

sub _process_429
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
                $self->_process_429($tag, $res);
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

__END__

=head1 NAME

App::Paws::Runner

=head1 DESCRIPTION

A wrapper around L<HTTP::Async>, that supports calling coderefs with
request results, tagging requests, resolving requests by tag, and
reducing query rates when HTTP 429 responses are received.

=head1 CONSTRUCTOR

=over 4

=item B<new>

Arguments (hash):

=over 8

=item rates

A hashref mapping from tag name to the number of
requests that should be processed per minute for
that tag name.

=item backoff

If a HTTP 429 is received for a tag, then the
request rate for that tag will be divided by this
number, and the result will be the new request
rate for that tag.

=back

Returns a new instance of L<App::Paws::Runner>.

=back

=head1 PUBLIC METHODS

=over 4

=item B<add>

Takes a tag name, a L<HTTP::Request> object, and a coderef as its
arguments.  Adds the request to the list of pending requests for the
tag.  When the request is processed, the coderef will be called with
the runner object, the L<HTTP::Response> object, and the coderef as
its arguments.

=item B<poke>

Takes an optional tag name as its single argument.  For all tags, or
for the specified tag (if an argument was provided), adds a pending
request to the wrapped L<HTTP::Async> object, if that won't cause the
request rate for the tag to be exceeded.  Then, this processes all
completed requests for the tag.  If any completed requests were
processed, this repeats the process again from the beginning.
Finally, a boolean is returned indicating whether any requests remain
to be processed.

=back

=head1 AUTHOR

Tom Harrison (C<tomh5908@gmail.com>)

=head1 COPYRIGHT & LICENCE

Copyright (c) 2020, Tom Harrison
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.
  * Neither the name of the copyright holder nor the
    names of its contributors may be used to endorse or promote products
    derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut
