package App::Paws::Test::Server;

use warnings;
use strict;

use HTTP::Daemon;
use JSON::XS qw(encode_json decode_json);

my $true = bless( do{\(my $o = 1)}, 'JSON::PP::Boolean' );
my $false = bless( do{\(my $o = 0)}, 'JSON::PP::Boolean' );

my $counter = 0;

my @channels = ({
    'is_im' => $false,
    'is_channel' => $true,
    'is_private' => $false,
    'pending_connected_team_ids' => [],
    'num_members' => 97,
    'name' => 'general',
    'is_shared' => $false,
    'is_pending_ext_shared' => $false,
    'is_org_shared' => $false,
    'id' => 'C00000001',
    'name_normalized' => 'general',
    'creator' => 'U00000001',
    'is_group' => $false,
    'parent_conversation' => undef,
    'is_archived' => $false,
    'is_mpim' => $false,
    'created' => 1458566704,
    'is_ext_shared' => $false,
    'pending_shared' => [],
    'is_general' => $true,
    'unlinked' => 0,
    'is_member' => $true
}, {
    'is_im' => $false,
    'is_channel' => $true,
    'is_private' => $false,
    'pending_connected_team_ids' => [],
    'num_members' => 297,
    'name' => 'work',
    'is_shared' => $false,
    'is_pending_ext_shared' => $false,
    'is_org_shared' => $false,
    'id' => 'C00000002',
    'name_normalized' => 'work',
    'creator' => 'U00000002',
    'is_group' => $false,
    'parent_conversation' => undef,
    'is_archived' => $false,
    'is_mpim' => $false,
    'created' => 1458566704,
    'is_ext_shared' => $false,
    'pending_shared' => [],
    'is_general' => $true,
    'unlinked' => 0,
    'is_member' => $true
});

my @ims = ({
    'is_org_shared' => $false,
    'created' => 1537922598,
    'id' => 'D00000001',
    'priority' => '0.018709981367191',
    'user' => 'U00000003',
    'is_im' => $true,
    'is_user_deleted' => $false
}, {
    'is_user_deleted' => $false,
    'is_im' => $true,
    'user' => 'USLACKBOT',
    'priority' => 0,
    'id' => 'D00000002',
    'created' => 1537922598,
    'is_org_shared' => $false
});

my @users = (
    { name => 'slackbot',
        id => 'USLACKBOT' },
    { id => 'U00000003',
        name => 'user3' },
);
my @users2 = (
    { id => 'U00000002',
        name => 'user2' },
    { id => 'U00000001',
        name => 'user1' },
);

my %channel_id_to_history = (
    C00000001 => [
        { 
            ts => 2,
            text => '<@U00000001> testing',
            type => 'message'
        },
        { 
            ts => 3,
            text => 'ding2',
            user => 'U00000005',
            type => 'message'
        },
    ],
    C00000002 => [
        { 
            ts => 2,
            text => 'ding',
            user => 'U00000001',
            type => 'message'
        },
        { 
            ts => 3,
            text => 'ding2',
            user => 'U00000002',
            type => 'message'
        },
        {
            ts => 4,
            text => 'thread!',
            user => 'U00000002',
            type => 'message',
            thread_ts => '5'
        },
    ],
    D00000001 => [
        { 
            ts => 2,
            text => 'ding',
            user => 'U00000001',
            type => 'message'
        },
        { 
            ts => 3,
            text => 'ding2',
            user => 'U00000002',
            type => 'message'
        },
    ],
    D00000002 => [
        { 
            ts => 2,
            text => 'ding',
            user => 'U00000001',
            type => 'message'
        },
        { 
            ts => 3,
            text => 'ding2',
            user => 'U00000002',
            type => 'message'
        },
    ],
);

my %thread_to_history = (
    C00000002 => {
        5 => [
            { 
                ts => 2,
                text => 'thread-reply-1!',
                user => 'U00000001',
                type => 'message'
            },
            { 
                ts => 3,
                text => 'thread-reply-2!',
                user => 'U00000002',
                type => 'message',
                files => [
                    {
                        url_private => '/file?id=1',
                        mimetype => 'text/plain'
                    }
                ],
            },
        ],
    }
);

my %files = (
    1 => 'asdfasdf'
);

my $pid;
sub new
{
    my $class = shift;
    my $self = {};
    bless $self, $class;
    return $self;
}

sub _handle_request
{
    my ($c, $r) = @_;

    my $method = $r->method();
    my $path = $r->uri()->path();

    my $res = HTTP::Response->new();
    if ($method eq 'GET') {
        if ($path eq '/conversations.list') {
            $res->code(200);
            $res->content(encode_json({
                channels => [ @channels, @ims ]
            }));
        } elsif ($path eq '/users.list') {
            my %args = $r->uri()->query_form();
            $res->code(200);
            my @users_ret;
            my @extra_ret;
            if (($args{'cursor'} || '') eq 'next') {
                @users_ret = @users2;
            } else {
                @users_ret = @users;
                @extra_ret = (
                    response_metadata => {
                        next_cursor => 'next'
                    }
                );
            }
                
            $res->content(encode_json({
                ok => $true,
                members => \@users_ret,
                @extra_ret,

            }));
        } elsif ($path eq '/conversations.history') {
            my %args = $r->uri()->query_form();
            my $channel_id = $args{'channel'};
            my $history = $channel_id_to_history{$channel_id};
            if ($args{'oldest'} and not $args{'latest'}) {
                $history = [
                    grep { $_->{'ts'} > $args{'oldest'} }
                        @{$history}
                ];
            }

            $res->code(200);
            $res->content(encode_json({
                ok => $true,
                messages => $history
            }));
        } elsif ($path eq '/conversations.replies') {
            my %args = $r->uri()->query_form();
            my $channel_id = $args{'channel'};
            my $thread_ts = $args{'ts'};
            my $history = $thread_to_history{$channel_id}->{$thread_ts};
            if ($args{'oldest'} and not $args{'latest'}) {
                $history = [
                    grep { $_->{'ts'} > $args{'oldest'} }
                        @{$history}
                ];
            }

            $res->code(200);
            $res->content(encode_json({
                ok => $true,
                messages => $history
            }));
        } elsif ($path eq '/file') {
            my %args = $r->uri()->query_form();
            my $id = $args{'id'};
            $res->code(200);
            $res->content($files{$id});
        }
    } elsif ($method eq 'POST') {
        if ($path eq '/chat.postMessage') {
            my $data = decode_json($r->content());
            my $channel_id = $data->{'channel'};
            my $text = $data->{'text'};
            my $thread_ts = $data->{'thread_ts'};
            my $ref =
                ($thread_ts)
                    ? $thread_to_history{$channel_id}->{$thread_ts}
                    : $channel_id_to_history{$channel_id};
            push @{$ref},
                { 
                    ts => time().'.'.sprintf("%06d", $counter++),
                    text => $text,
                    user => 'U00000001',
                    type => 'message'
                };
            $res->code(200);
        } elsif ($path eq '/files.upload') {
            $res->code(200);
        }
    }

    if ($res->code()) {
        $c->send_response($res);
    } else {
        $res->code(404);
        $c->send_response($res);
    }

    return 1;
}

sub run
{
    my ($self) = @_;

    my $d = HTTP::Daemon->new();
    $self->{'port'} = $d->sockport();
    if ($pid = fork()) {
        $self->{'pid'} = $pid;
        return 1;
    } else {
        while (my $c = $d->accept()) {
            while (my $r = $c->get_request()) {
                _handle_request($c, $r);
            }
        }
    }
}

sub DESTROY
{
    my ($self) = @_;
    kill 'TERM', $pid;
}

1;
