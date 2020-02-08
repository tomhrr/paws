package App::Paws::Receiver;

use warnings;
use strict;

use Data::Dumper;
use File::Slurp qw(read_file write_file);
use JSON::XS qw(decode_json encode_json);
use List::MoreUtils qw(uniq);
use Time::HiRes qw(sleep);

use App::Paws::Conversation;
use App::Paws::Lock;
use App::Paws::Message;

sub new
{
    my $class = shift;
    my %args = @_;
    my $self = \%args;
    bless $self, $class;
    return $self;
}

sub _run_internal
{
    my ($self, $since_ts) = @_;

    my $ws = $self->{'workspace'};
    my $context = $self->{'context'};
    my $domain_name = $context->domain_name();
    my $to = $context->user_email();
    my $name = $self->{'name'};

    my $path = $context->db_directory().'/'.$name.'-receiver-maildir-db';
    if (not -e $path) {
        write_file($path, '{}');
    }

    my $db = decode_json(read_file($path));
    use Data::Dumper;
#    print Dumper($db);

    my $conversation_map = $db->{'conversation-map'} || {};
    my %previous_map = %{$conversation_map};
    my $has_cached = (keys %previous_map > 0) ? 1 : 0;

    my $req = $ws->get_conversations_request();
    my $data;
    my $runner = $self->{'context'}->runner();
    $runner->add('conversations.list',
                 $req, sub {
                    my ($self, $res, $fn) = @_;
                    if (not $res->is_success()) {
                        die Dumper($res);
                    }
                    $data = decode_json($res->content());
                    if ($data->{'error'}) {
                        die Dumper($data);
                    }
                    my @conversations =
                        grep { $_->{'is_im'} or $_->{'is_member'} }
                            @{$data->{'channels'}};
                    my %conversation_map =
                        map { $ws->conversation_to_name($_) => $_->{'id'} }
                            @conversations;
                    $db->{'conversation-map'} =
                        { %{$db->{'conversation-map'} || {}},
                          %conversation_map };
                    $conversation_map = $db->{'conversation-map'};

		    if ($data->{'response_metadata'}->{'next_cursor'}) {
			my $req = $ws->standard_get_request_only(
			    '/conversations.list',
			    { cursor => $data->{'response_metadata'}
					    ->{'next_cursor'},
                              types => 'public_channel,private_channel,mpim,im' }
			);
			$runner->add('conversations.list', $req, $fn);
                    }
                 });
    my $used_cached = 0;
    if ($has_cached) {
        $used_cached = 1;
    } else {
        while (not $runner->poke('conversations.list')) {
            sleep(0.01);
        }
    }

    my @conversation_names = keys %{$conversation_map};

    my @actual_conversations =
        uniq
        map { ($_ eq '*')           ? @conversation_names
            : ($_ =~ /^(.*?)\/\*$/) ? (grep { /^$1\// }
                                            @conversation_names)
                                    : $_ }
            @{$ws->{'conversations'}};

    my $ws_name = $self->{'workspace'}->name();
    my %conversation_to_last_ts =
        map { $_ => $db->{$ws_name}->{$_}->{'last_ts'} || 1 }
            @actual_conversations;

    my @sorted_conversations =
        sort { $conversation_to_last_ts{$b} <=>
               $conversation_to_last_ts{$a} }
            @actual_conversations;

    my @conversation_objs;
    for my $conversation (@sorted_conversations) {
        my $data = $db->{$ws_name}->{$conversation} || {};
        my $conversation_obj = App::Paws::Conversation->new(
            context => $context,
            workspace => $ws,
            write_callback => $self->{'write_callback'},
            name => $conversation,
            id => $conversation_map->{$conversation},
            data => $data,
        );
        $conversation_obj->receive_messages($since_ts);
        push @conversation_objs, $conversation_obj;
    }
    while (not $runner->poke()) {
        sleep(0.01);
    }
    for my $conversation_obj (@conversation_objs) {
        my $name = $conversation_obj->{'name'};
        $db->{$ws_name}->{$name} =
            $conversation_obj->to_data();
    }

    my @new_conversations;
    if ($has_cached) {
        for my $name (keys %{$conversation_map}) {
            if (not $previous_map{$name}) {
                push @new_conversations, $name;
            }
        }
        my @conversation_objs;
        for my $conversation (@new_conversations) {
            my $data = $db->{$ws_name}->{$conversation} || {};
            my $conversation_obj = App::Paws::Conversation->new(
                context => $context,
                workspace => $ws,
                write_callback => $self->{'write_callback'},
                name => $conversation,
                id => $conversation_map->{$conversation},
                data => $data,
            );
            $conversation_obj->receive_messages($since_ts);
            push @conversation_objs, $conversation_obj;
        }
        while (not $runner->poke()) {
            sleep(0.01);
        }
        for my $conversation_obj (@conversation_objs) {
            my $name = $conversation_obj->{'name'};
            $db->{$ws_name}->{$name} =
                $conversation_obj->to_data();
        }
    }

    @conversation_objs = ();
    for my $conversation (@sorted_conversations,
                          @new_conversations) {
        my $data = $db->{$ws_name}->{$conversation} || {};
        my $conversation_obj = App::Paws::Conversation->new(
            context => $context,
            workspace => $ws,
            write_callback => $self->{'write_callback'},
            name => $conversation,
            id => $conversation_map->{$conversation},
            data => $data
        );
        $conversation_obj->receive_threads($since_ts);
        push @conversation_objs, $conversation_obj;
    }
    while (not $runner->poke()) {
        sleep(0.01);
    }
    for my $conversation_obj (@conversation_objs) {
        my $name = $conversation_obj->{'name'};
        $db->{$ws_name}->{$name} =
            $conversation_obj->to_data();
    }

    use Data::Dumper;
    #print Dumper($db);

    write_file($path, encode_json($db));
}

sub run
{
    my ($self, $since_ts) = @_;

    my $db_dir = $self->{'context'}->db_directory();
    my $lock_path = $db_dir.'/'.$self->{'name'}.'-lock';
    my $lock = App::Paws::Lock->new($lock_path);
    eval { $self->_run_internal($since_ts); };
    my $error = $@;
    $lock->unlock();
    if ($error) {
        die $error;
    }
    return 1;
}

1;
