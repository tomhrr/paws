package App::Paws::Workspace;

use warnings;
use strict;

use File::Slurp qw(read_file write_file);
use HTTP::Request;
use JSON::XS qw(decode_json encode_json);
use Time::HiRes qw(sleep);

use App::Paws::Workspace::Users;

our $LIMIT = 100;

sub new
{
    my $class = shift;
    my %args = @_;

    my $self = {
        (map { $_ => $args{$_} }
            qw(context name token conversations modification_window
               thread_expiry)),
        users_loaded    => 0,
        users_retrieved => 0,
    };

    bless $self, $class;

    $self->{'users'} =
        App::Paws::Workspace::Users->new(
            context   => $args{'context'},
            workspace => $self
        );

    return $self;
}

sub name
{
    return $_[0]->{'name'};
}

sub token
{
    return $_[0]->{'token'};
}

sub modification_window
{
    return ($_[0]->{'modification_window'} || 0);
}

sub thread_expiry
{
    return ($_[0]->{'thread_expiry'} || (60 * 60 * 24 * 7));
}

sub users
{
    return $_[0]->{'users'};
}

sub conversations
{
    return $_[0]->{'conversations'};
}

sub conversation_to_name
{
    my ($self, $conversation) = @_;

    my $type = $conversation->{'is_im'}    ? 'im'
             : $conversation->{'is_mpim'}  ? 'mpim'
             : $conversation->{'is_group'} ? 'group'
                                           : 'channel';
    my $name = $conversation->{'name'};
    if (($type eq 'im') and not $name) {
        my $user_id = $conversation->{'user'};
        $name = $self->users()->user_id_to_name($user_id);
        if (not $name) {
            warn "Unable to find name for user '$user_id'";
            $name = 'unknown';
        }
    }

    return "$type/$name";
}

sub standard_get_request_only
{
    my ($self, $path, $query_form) = @_;

    my $context = $self->{'context'};
    my $token = $self->{'token'};
    my $req = HTTP::Request->new();
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');
    $req->header('Authorization' => 'Bearer '.$token);
    my $uri = URI->new($context->slack_base_url().$path);
    $uri->query_form(%{$query_form});
    $req->uri($uri);
    $req->method('GET');
    return $req;
}

sub get_conversations_request
{
    my ($self) = @_;

    return $self->standard_get_request_only(
        '/conversations.list',
        { types => 'public_channel,private_channel,mpim,im' }
    );
}

sub get_replies_request
{
    my ($self, $conversation_id, $thread_ts, $last_ts, $latest_ts,
        $cursor) = @_;

    return $self->standard_get_request_only(
        '/conversations.replies',
        { channel => $conversation_id,
          ts      => $thread_ts,
          limit   => $LIMIT,
          oldest  => $last_ts,
          ($latest_ts ? (latest => $latest_ts, inclusive => 1) : ()),
          ($cursor    ? (cursor => $cursor) : ()) }
    );
}

sub get_history_request
{
    my ($self, $conversation_id, $last_ts, $latest_ts, $cursor) = @_;

    return $self->standard_get_request_only(
        '/conversations.history',
        { channel => $conversation_id,
          limit   => $LIMIT,
          oldest  => $last_ts,
          ($latest_ts ? (latest => $latest_ts, inclusive => 1) : ()),
          ($cursor    ? (cursor => $cursor) : ()) }
    );
}

1;
