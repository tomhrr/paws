package App::Paws::Workspace::Users;

use warnings;
use strict;

use File::Slurp qw(read_file write_file);
use HTTP::Request;
use JSON::XS qw(decode_json encode_json);
use Time::HiRes qw(sleep);

use App::Paws::Utils qw(standard_get_request_only);

our $LIMIT = 100;

sub new
{
    my $class = shift;
    my %args = @_;

    my $self = {
        (map { $_ => $args{$_} }
            qw(context workspace)),
        retrieved => 0,
    };

    bless $self, $class;
    $self->_init_users();
    return $self;
}

sub _init_users
{
    my ($self, $force_retrieve) = @_;

    my $context = $self->{'context'};
    my $runner = $context->{'runner'};
    my $ws = $self->{'workspace'};
    my $db_dir = $context->db_directory();
    my $path = $db_dir.'/'.$ws->name().'-workspace-users-db';
    if (not -e $path) {
        write_file($path, '{}');
    }
    my $db = decode_json(read_file($path));

    if ((not $force_retrieve) and $db->{'users'}) {
        $self->{'users'} = $db->{'users'};
        return 1;
    }
    if ($self->{'retrieved'}) {
        return 1;
    }

    my $req = standard_get_request_only(
        $context, $ws,
        '/users.list',
        { limit => $LIMIT }
    );

    $self->{'users'} = [];
    $runner->add(
        'users.list', $req, sub {
            my ($runner, $res, $fn) = @_;
            if (not $res->is_success()) {
                my $res_str = $res->as_string();
                chomp $res_str;
                print STDERR "Unable to process response: $res_str\n";
                return;
            }
            my $data = decode_json($res->content());
            if ($data->{'error'}) {
                my $res_str = $res->as_string();
                chomp $res_str;
                print STDERR "Error in response: $res_str\n";
                return;
            }
            my @users = @{$data->{'members'}};
            push @{$self->{'users'}}, @users;

            if ($data->{'response_metadata'}->{'next_cursor'}) {
                my $req = standard_get_request_only(
                    $context, $ws,
                    '/users.list',
                    { limit  => $LIMIT,
                      cursor => $data->{'response_metadata'}
                                     ->{'next_cursor'} }
                );
                $runner->add('users.list', $req, $fn);
            } else {
                $db->{'users'} =
                    [ map { +{ id        => $_->{'id'},
                               name      => $_->{'name'},
                               real_name => $_->{'real_name'},
                               deleted   => $_->{'deleted'} } }
                        @{$self->{'users'}} ];
                write_file($path, encode_json($db));
                $self->{'retrieved'} = 1;
            }
        }
    );
}

sub _get_user_map
{
    my ($self) = @_;

    if ($self->{'user_map'}) {
        return $self->{'user_map'};
    }

    my %user_map =
        map { $_->{'name'} => $_->{'id'} }
            @{$self->{'users'}};

    $self->{'user_map'} = \%user_map;

    return \%user_map;
}

sub retrieve
{
    my ($self) = @_;

    if ($self->{'retrieved'}) {
        return 1;
    }

    my $context = $self->{'context'};
    my $runner  = $context->runner();
    $self->_init_users(1);
    while (not $runner->poke('users.list')) {
        sleep(0.01);
    }
    delete @{$self}{qw(user_map user_list)};

    return 1;
}

sub user_id_to_name
{
    my ($self, $user_id) = @_;

    my $user_map = $self->_get_user_map();
    my %rev = reverse %{$user_map};
    if (not exists $rev{$user_id} and not $self->{'retrieved'}) {
        $self->retrieve();
        return $self->user_id_to_name($user_id);
    }
    return $rev{$user_id};
}

sub name_to_user_id
{
    my ($self, $name) = @_;

    my $user_map = $self->_get_user_map();
    if (not exists $user_map->{$name} and not $self->{'retrieved'}) {
        $self->retrieve();
        return $self->name_to_user_id($name);
    }
    return $user_map->{$name};
}

sub get_user_list
{
    my ($self) = @_;

    if ($self->{'user_list'}) {
        return $self->{'user_list'};
    }

    my @user_list =
        map { [ $_->{'real_name'}, $_->{'name'} ] }
            @{$self->{'users'}};

    $self->{'user_list'} = \@user_list;

    return \@user_list;
}

1;
