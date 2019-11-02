package App::Paws::Workspace;

use warnings;
use strict;

use Data::Dumper;
use File::Slurp qw(read_file write_file);
use HTTP::Request;
use JSON::XS qw(decode_json encode_json);
use LWP::UserAgent;
use Time::HiRes qw(sleep);

our $LIMIT = 100;

sub new
{
    my $class = shift;
    my %args = @_;
    my $self = \%args;
    $self->{'users_loaded'} = 0;
    $self->{'users_retrieved'} = 0;
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
    return ($_[0]->{'modification_window'} || 0);
}

sub thread_expiry
{
    return ($_[0]->{'thread_expiry'} || (60 * 60 * 24 * 7));
}

sub user_id_to_name
{
    my ($self, $user_id) = @_;

    my $user_map = $self->_get_user_map();
    my %rev = reverse %{$user_map};
    if (not exists $rev{$user_id} and not $self->{'users_retrieved'}) {
        $self->_get_users(1);
        return $self->user_id_to_name($user_id);
    }
    return $rev{$user_id};
}

sub name_to_user_id
{
    my ($self, $name) = @_;

    my $user_map = $self->_get_user_map();
    if (not exists $user_map->{$name} and not $self->{'users_retrieved'}) {
        $self->_get_users(1);
        return $self->name_to_user_id($name);
    }
    return $user_map->{$name};
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

sub _init_users
{
    my ($self, $force_retrieve) = @_;

    my $db_dir = $self->{'context'}->db_directory();
    my $path = $db_dir.'/'.$self->{'name'}.'-workspace-db';
    if (not -e $path) {
        write_file($path, '{}');
    }
    my $db = decode_json(read_file($path));

    if ((not $force_retrieve) and $db->{'users'}) {
        $self->{'users'} = $db->{'users'};
        my $extras = $self->{'override_users'} || [];
        push @{$self->{'users'}}, @{$extras};
        $self->{'users_loaded'} = 1;
        $self->{'users_loading'} = 0;
        return 1;
    }
    if ($self->{'users_retrieved'}) {
        return 1;
    }

    my $context = $self->{'context'};
    my $runner = $context->{'runner'};

    my $req = $self->standard_get_request_only(
        '/users.list',
        { limit => $LIMIT }
    );

    $self->{'users_loading'} = 1;
    $self->{'users_loaded'} = 0;
    $self->{'users'} = [];
    $runner->add(
        'users.list', $req, sub {
            my ($runner, $res, $fn) = @_;
            if (not $res->is_success()) {
                die Dumper($res);
            }
            my $data = decode_json($res->content());
            if ($data->{'error'}) {
                die Dumper($data);
            }
            my @users =
                grep { not $_->{'deleted'} }
                    @{$data->{'members'}};
            push @{$self->{'users'}}, @users;

            if ($data->{'response_metadata'}->{'next_cursor'}) {
                my $req = $self->standard_get_request_only(
                    '/users.list',
                    { limit  => $LIMIT,
                      cursor => $data->{'response_metadata'}
                                     ->{'next_cursor'} }
                );
                $runner->add('users.list', $req, $fn);
            } else {
                $db->{'users'} =
                    [ map { +{ id => $_->{'id'},
                             name => $_->{'name'},
                             real_name => $_->{'real_name'} } }
                        @{$self->{'users'}} ];
                my $extras = $self->{'override_users'} || [];
                push @{$self->{'users'}}, @{$extras};
                write_file($path, encode_json($db));
                $self->{'users_loading'} = 0;
                $self->{'users_loaded'} = 1;
                $self->{'users_retrieved'} = 1;
            }
        }
    );
}

sub _get_users
{
    my ($self, $force_retrieve) = @_;

    my $context = $self->{'context'};
    my $runner = $context->{'runner'};

    if ($force_retrieve and not $self->{'users_retrieved'}) {
        $self->_init_users($force_retrieve);
        while (not $runner->poke('users.list')) {
            sleep(0.01);
        }
    }
    if ($self->{'users_loaded'}) {
        return $self->{'users'};
    }
    if (not $self->{'users_loading'}) {
        $self->_init_users($force_retrieve);
    }

    while (not $runner->poke('users.list')) {
        sleep(0.01);
    }

    return $self->{'users'};
}

sub _get_user_map
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

sub retrieve_users
{
    my ($self) = @_;

    $self->_get_users(1);
    return 1;
}

1;
