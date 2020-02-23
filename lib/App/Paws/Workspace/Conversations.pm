package App::Paws::Workspace::Conversations;

use warnings;
use strict;

use File::Slurp qw(read_file write_file);
use HTTP::Request;
use JSON::XS qw(decode_json encode_json);
use Time::HiRes qw(sleep);

use App::Paws::Utils qw(standard_get_request);

our $LIMIT = 100;

sub new
{
    my $class = shift;
    my %args = @_;

    my $self = {
        (map { $_ => $args{$_} }
            qw(context workspace users)),
        retrieving => 0,
        retrieved  => 0,
    };

    bless $self, $class;
    $self->_init_conversations();
    return $self;
}

sub users
{
    return $_[0]->{'users'};
}

sub _conversation_to_name
{
    my ($self, $conversation) = @_;

    my ($name, $type) = @{$conversation}{qw(name type)};
    if (($type eq 'im') and not $name) {
        my $user_id = $conversation->{'user'};
        $name = $self->users()->id_to_name($user_id);
        if (not $name) {
            warn "Unable to find name for user '$user_id'";
            $name = 'unknown';
        }
    }

    return "$type/$name";
}

sub _init_conversations
{
    my ($self, $force_retrieve) = @_;

    my $context = $self->{'context'};
    my $runner = $context->runner();
    my $ws = $self->{'workspace'};
    my $db_dir = $context->db_directory();
    my $path = $db_dir.'/'.$ws->name().'-workspace-conversations-db';
    if (not -e $path) {
        write_file($path, '{}');
    }
    my $db = decode_json(read_file($path));
    if ($db->{'conversations'}) {
        $self->{'conversations'} = $db->{'conversations'};
    }
    if (not $force_retrieve) {
        return 1;
    }
    if ($self->{'retrieving'} or $self->{'retrieved'}) {
        return 1;
    }

    my $req = standard_get_request(
        $context, $ws,
        '/conversations.list',
        { limit => $LIMIT }
    );

    $self->{'retrieving'} = 1;
    my @conversations;
    $runner->add('conversations.list', $req, sub {
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

        for my $conversation (@{$data->{'channels'}}) {
            my $type = ($conversation->{'is_im'}    ? 'im'
                     :  $conversation->{'is_mpim'}  ? 'mpim'
                     :  $conversation->{'is_group'} ? 'group'
                                                    : 'channel');
            $conversation->{'type'} = $type;
            $conversation->{'name'} =
                $self->_conversation_to_name($conversation);
            push @conversations,
                 { map { $_ => $conversation->{$_} }
                     qw(id name is_member user type) };
        }

        if (my $cursor = $data->{'response_metadata'}->{'next_cursor'}) {
            my $req = standard_get_request(
                $context, $ws,
                '/conversations.list',
                { cursor => $cursor,
                  types  => 'public_channel,private_channel,mpim,im' }
            );
            $runner->add('conversations.list', $req, $fn);
        } else {
            $self->{'conversations'} = \@conversations;
            $db->{'conversations'} = $self->{'conversations'};
            write_file($path, encode_json($db));
            $self->{'retrieving'} = 0;
            $self->{'retrieved'}  = 1;
            delete $self->{'conversation_map'};
        }
    });
}

sub retrieve_nb
{
    my ($self) = @_;

    if ($self->{'retrieving'} or $self->{'retrieved'}) {
        return 1;
    }

    my $context = $self->{'context'};
    my $runner  = $context->runner();
    $self->_init_conversations(1);

    return 1;
}

sub retrieve
{
    my ($self) = @_;

    if ($self->{'retrieved'}) {
        return 1;
    }

    $self->retrieve_nb();
    my $context = $self->{'context'};
    my $runner  = $context->runner();
    while (not $runner->poke('conversations.list')) {
        sleep(0.01);
    }

    return 1;
}

sub _get_conversation_map
{
    my ($self) = @_;

    if ($self->{'conversation_map'}) {
        return $self->{'conversation_map'};
    }

    my %conversation_map =
        map { $_->{'name'} => $_->{'id'} }
            @{$self->{'conversations'}};

    $self->{'conversation_map'} = \%conversation_map;

    return \%conversation_map;
}

sub name_to_id
{
    my ($self, $name) = @_;

    my $conversation_map = $self->_get_conversation_map();
    if (exists $conversation_map->{$name}) {
        return $conversation_map->{$name};
    }
    if ($name !~ /\//) {
        if (exists $conversation_map->{"im/$name"}) {
            return $conversation_map->{"im/$name"};
        }
    }
    if (not $self->{'retrieved'}) {
        $self->retrieve();
        return $self->name_to_id($name);
    }

    return;
}

sub get_list
{
    my ($self) = @_;

    return $self->{'conversations'};
}

1;
