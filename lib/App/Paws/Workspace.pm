package App::Paws::Workspace;

use warnings;
use strict;

use Data::Dumper;
use HTTP::Request;
use JSON::XS qw(decode_json);
use LWP::UserAgent;

our $LIMIT = 100;

sub new
{
    my $class = shift;
    my %args = @_;
    my $self = \%args;
    bless $self, $class;
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
    return $_[0]->{'modification_window'};
}

sub user_id_to_name
{
    my ($self, $user_id) = @_;

    my $user_map = $self->get_user_map();
    my %rev = reverse %{$user_map};
    return $rev{$user_id};
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
        $name = $self->user_id_to_name($user_id);
        if (not $name) {
            warn "Unable to find name for user '$user_id'";
            $name = 'unknown';
        }
    }

    return "$type/$name";
}

sub standard_get_request
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
    my $ua = LWP::UserAgent->new();
    my $res = $ua->request($req);
    if (not $res->is_success()) {
        die Dumper($res);
    }
    my $data = decode_json($res->content());
    if ($data->{'error'}) {
        die Dumper($data);
    }
    return $data;
}

sub get_conversations
{
    my ($self) = @_;

    return $self->standard_get_request(
        '/conversations.list',
        { types => 'public_channel,private_channel,mpim,im' }
    );
}

sub get_replies
{
    my ($self, $conversation_id, $thread_ts, $last_ts, $latest_ts,
        $cursor) = @_;

    return $self->standard_get_request(
        '/conversations.replies',
        { channel => $conversation_id,
          ts      => $thread_ts,
          limit   => $LIMIT,
          oldest  => $last_ts,
          ($latest_ts ? (latest => $latest_ts, inclusive => 1) : ()),
          ($cursor    ? (cursor => $cursor) : ()) }
    );
}

sub get_history
{
    my ($self, $conversation_id, $last_ts, $latest_ts, $cursor) = @_;

    return $self->standard_get_request(
        '/conversations.history',
        { channel => $conversation_id,
          limit   => $LIMIT,
          oldest  => $last_ts,
          ($latest_ts ? (latest => $latest_ts, inclusive => 1) : ()),
          ($cursor    ? (cursor => $cursor) : ()) }
    );
}

sub _get_users
{
    my ($self) = @_;

    if ($self->{'users'}) {
        return $self->{'users'};
    }

    my $data = $self->standard_get_request(
        '/users.list',
        { limit => $LIMIT }
    );

    my @data_list;
    push @data_list, $data;

    while ($data->{'response_metadata'}->{'next_cursor'}) {
        $data = $self->standard_get_request(
            '/users.list',
            { limit  => $LIMIT,
              cursor => $data->{'response_metadata'}->{'next_cursor'} }
        );
        push @data_list, $data;
    }

    my @users =
        grep { not $_->{'deleted'} }
        map  { @{$_->{'members'}} }
            @data_list;

    $self->{'users'} = \@users;

    return \@users;
}

sub get_user_map
{
    my ($self) = @_;

    if ($self->{'user_map'}) {
        return $self->{'user_map'};
    }

    my %user_map =
        map { $_->{'name'} => $_->{'id'} }
            @{$self->_get_users()};

    $self->{'user_map'} = \%user_map;

    return \%user_map;
}

sub get_user_list
{
    my ($self) = @_;

    if ($self->{'user_list'}) {
        return $self->{'user_list'};
    }

    my @user_list =
        map { [ $_->{'real_name'}, $_->{'name'} ] }
            @{$self->_get_users()};

    $self->{'user_list'} = \@user_list;

    return \@user_list;
}

1;
