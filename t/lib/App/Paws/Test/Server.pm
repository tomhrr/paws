package App::Paws::Test::Server;

use warnings;
use strict;

use HTTP::Daemon;
use JSON::XS qw(encode_json decode_json);

my $true = bless( do{\(my $o = 1)}, 'JSON::PP::Boolean' );
my $false = bless( do{\(my $o = 0)}, 'JSON::PP::Boolean' );

my $counter = 1;

my %channel_template = (
    'is_im' => $false,
    'is_channel' => $false,
    'is_private' => $false,
    'pending_connected_team_ids' => [],
    'num_members' => 97,
    'is_shared' => $false,
    'is_pending_ext_shared' => $false,
    'is_org_shared' => $false,
    'name_normalized' => 'general',
    'creator' => 'U00000001',
    'is_group' => $false,
    'parent_conversation' => undef,
    'is_archived' => $false,
    'is_mpim' => $false,
    'is_ext_shared' => $false,
    'pending_shared' => [],
    'is_general' => $true,
    'unlinked' => 0,
    'is_member' => $true
);

my $channel_id = 1;
my @channels = ({
    %channel_template,
    'is_channel' => $true,
    'name' => 'general',
    'id' => 'C0000000'.$channel_id++,
    'created' => 1458566704,
}, {
    %channel_template,
    'is_channel' => $true,
    'name' => 'work',
    'id' => 'C0000000'.$channel_id++,
    'created' => 1458566704,
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
      real_name => 'Slack Bot',
        id => 'USLACKBOT' },
    { id => 'U00000003',
      real_name => 'User 3',
        name => 'user3' },
);
my @users2 = (
    { id => 'U00000002',
      real_name => 'User 2',
        name => 'user2' },
    { id => 'U00000001',
      real_name => 'User 1',
        name => 'user1' },
);

our $ts_base    = time();
our $ts_base_p1 = $ts_base - 1;
our $ts_base_p2 = $ts_base - 2;
our $ts_base_p3 = $ts_base - 3;
our $ts_base_p4 = $ts_base - 4;
our $ts_base_p5 = $ts_base - 5;

my %channel_id_to_history = (
    C00000001 => [
        { 
            ts => "$ts_base.0",
            text => '<@U00000001> testing',
            type => 'message'
        },
        { 
            ts => "$ts_base_p1.0",
            text => 'ding2',
            user => 'U00000005',
            type => 'message'
        },
    ],
    C00000002 => [
        { 
            ts => "$ts_base.0",
            text => 'ding',
            user => 'U00000001',
            type => 'message'
        },
        { 
            ts => "$ts_base_p1.0",
            text => 'ding2',
            user => 'U00000002',
            type => 'message'
        },
        {
            ts => "$ts_base_p2.0",
            text => 'thread!',
            user => 'U00000002',
            type => 'message',
            thread_ts => "$ts_base_p3.0",
        },
    ],
    D00000001 => [
        { 
            ts => "$ts_base.0",
            text => 'ding',
            user => 'U00000001',
            type => 'message'
        },
        { 
            ts => "$ts_base_p1.0",
            text => 'ding2',
            user => 'U00000002',
            type => 'message'
        },
    ],
    D00000002 => [
        { 
            ts => "$ts_base.0",
            text => 'ding',
            user => 'U00000001',
            type => 'message'
        },
        { 
            ts => "$ts_base_p1.0",
            text => 'ding2',
            user => 'U00000002',
            type => 'message'
        },
    ],
);

my %thread_to_history = (
    C00000002 => {
        "$ts_base_p3.0" => [
            { 
                ts => "$ts_base_p4.0",
                text => 'thread-reply-1!',
                user => 'U00000001',
                type => 'message'
            },
            { 
                ts => "$ts_base_p5.0",
                text => 'thread-reply-2!',
                user => 'U00000002',
                type => 'message',
                files => [
                    {
                        url_private => '/file/1',
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
        } elsif ($path =~ /^\/file\/(.*)$/) {
            my %args = $r->uri()->query_form();
            my $id = $1;
            $res->code(200);
            $res->content($files{$id});
        }
    } elsif ($method eq 'POST') {
        if ($path eq '/chat.postMessage') {
            my $data = decode_json($r->content());
            my $channel_id = $data->{'channel'};
            my $text = $data->{'text'};
            if ($text =~ /Internal response/) {
                $res->headers()->header('Client-Warning',
                                        'Internal response');
                $res->code(500);
            } elsif ($text =~ /Status: (\d\d\d)/) {
                $res->code($1);
            } else {
                my $thread_ts = $data->{'thread_ts'};
                my $ref =
                    ($thread_ts)
                        ? $thread_to_history{$channel_id}->{$thread_ts}
                        : $channel_id_to_history{$channel_id};
                if (not $ref) {
                    die "Unable to post message";
                }
                push @{$ref},
                    { 
                        ts => time().'.'.sprintf("%06d", $counter++),
                        text => $text,
                        user => 'U00000001',
                        type => 'message'
                    };
                $res->code(200);
            }
        } elsif ($path eq '/conversations.open') {
            my $data = decode_json($r->content());
            my @user_ids = split /,/, $data->{'users'};

            my $id = 'C0000000'.$channel_id++;
            push @channels, {
                %channel_template,
                'is_channel' => $true,
                'name' => $data->{'users'},
                'id' => $id,
                'created' => time(),
            };
            $channel_id_to_history{$id} = [];
            my $response_data = {
                ok => $true,
                channel => { id => $id }
            };
            $res->content(encode_json($response_data));
            $res->code(200);
        } elsif ($path eq '/chat.update') {
            my $data = decode_json($r->content());
            my $channel_id = $data->{'channel'};
            my $text = $data->{'text'};
            my $thread_ts = $data->{'thread_ts'};
            my $ref =
                ($thread_ts)
                    ? $thread_to_history{$channel_id}->{$thread_ts}
                    : $channel_id_to_history{$channel_id};
            if (not $ref) {
                $res->code(404);
            } else {
                my $ts = $data->{'ts'};
                my $found = 0;
                for (my $i = 0; $i < @{$ref}; $i++) {
                    my $message = $ref->[$i];
                    if ($message->{'ts'} eq $ts) {
                        $message->{'text'} = $text;
                        $message->{'edited'} = {
                            ts => time().'.'.sprintf("%06d", $counter++),
                        };
                        $found = 1;
                        last;
                    }
                }
                if ($found) {
                    $res->code(200);
                } else {
                    $res->code(404);
                }
            }
        } elsif ($path eq '/chat.delete') {
            my $data = decode_json($r->content());
            my $channel_id = $data->{'channel'};
            my $text = $data->{'text'};
            my $thread_ts = $data->{'thread_ts'};
            my $ref =
                ($thread_ts)
                    ? $thread_to_history{$channel_id}->{$thread_ts}
                    : $channel_id_to_history{$channel_id};
            my $ts = $data->{'ts'};
            my $found = 0;
            for (my $i = 0; $i < @{$ref}; $i++) {
                my $message = $ref->[$i];
                if ($message->{'ts'} eq $ts) {
                    $found = 1;
                    splice(@{$ref}, $i, 1);
                    last;
                }
            }
            if ($found) {
                $res->code(200);
            } else {
                $res->code(404);
            }
        } elsif ($path eq '/files.upload') {
            my $content = $r->content();
            my ($separator) = ($content =~ /^(.*?\r\n)/);
            my @parts = grep { $_ } split /$separator/, $content;
            chomp $separator;
            $parts[$#parts] =~ s/--.*--\r\n//;
            my %data;
            for my $part (@parts) {
                my ($headers, $content) = ($part =~ /^(.*?)\r\n\r\n(.*)/s);
                my ($name) = ($headers =~ /name="(.*?)"/);
                $content =~ s/\r?\n$//;
                $data{$name} = $content;
            }
            if ($data{'file'} =~ /Status: (\d\d\d)/) {
                $res->code($1);
            } else {
                my $channel_id = $data{'channels'};
                my $ref = $channel_id_to_history{$channel_id};
                $ref->[$#{$ref}]->{'files'} ||= [];
                push @{$ref->[$#{$ref}]->{'files'}},
                    { url_private => '/file/'.$data{'filename'},
                    mimetype => 'text/plain' };
                $files{$data{'filename'}} = $data{'file'};

                $res->code(200);
            }
        } elsif ($path eq '/paws.thread.make') {
            my $data = decode_json($r->content());
            my $channel_id = $data->{'channel'};
            my $ts = $data->{'ts'};
            my $ref = $channel_id_to_history{$channel_id};
            my $thread_ts     = time().'.'.sprintf("%06d", $counter++);
            my $thread_msg_ts = time().'.'.sprintf("%06d", $counter++);
            my $found = 0;
            for my $msg (@{$ref}) {
                if ($msg->{'ts'} eq $ts) {
                    $msg->{'thread_ts'} = $thread_ts;
                    $thread_to_history{$channel_id}->{$thread_ts} = [
                        {
                            ts   => $thread_msg_ts,
                            text => 'thread starts here',
                            user => 'U00000001',
                            type => 'message'
                        }
                    ];
                    $found = 1;
                    last;
                }
            }
            if ($found) {
                $res->code(200);
            } else {
                $res->code(404);
            }
        }
    }

    if ($res->code()) {
        if (not $res->content()) {
            $res->content('{"ok":true}');
        }
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

sub shutdown
{
    my ($self) = @_;

    my $pid = $self->{'pid'};
    if ($pid) {
        kill 'TERM', $pid;
    }
}

1;
