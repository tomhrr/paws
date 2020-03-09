package App::Paws;

use warnings;
use strict;

use Cwd;
use DateTime;
use File::Slurp qw(read_file write_file);
use IO::Async::Channel;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use IO::Async::Routine;
use JSON::XS qw(decode_json);
use List::Util qw(first max);
use Net::Async::WebSocket::Client;
use YAML;

use App::Paws::Context;
use App::Paws::Debug qw(debug);
use App::Paws::Receiver::maildir;
use App::Paws::Receiver::MDA;
use App::Paws::Sender;
use App::Paws::Utils qw(standard_get_request);

our $CONFIG_DIR  = $ENV{'HOME'}.'/.paws';
our $CONFIG_PATH = $CONFIG_DIR.'/config';
our $QUEUE_DIR   = $CONFIG_DIR.'/queue';
our $DB_DIR      = $CONFIG_DIR.'/db';

our $PING_TIMEOUT = 30;

our $VERSION = '0.1';

sub new
{
    my $class = shift;

    my $config = YAML::LoadFile($CONFIG_PATH);
    for my $dir ($QUEUE_DIR, $DB_DIR) {
        if (not -e $dir) {
            mkdir $dir or die $!;
        }
    }

    my $context =
        App::Paws::Context->new(config          => $config,
                                queue_directory => $QUEUE_DIR,
                                db_directory    => $DB_DIR);

    my $sender_config = $context->{'config'}->{'sender'};
    my $sender = App::Paws::Sender->new(
        context           => $context,
        fallback_sendmail => $sender_config->{'fallback_sendmail'},
        bounce_dir        => $sender_config->{'bounce_dir'},
    );

    my $self = {
        context => $context,
        sender  => $sender,
    };

    bless $self, $class;
    return $self;
}

sub send
{
    my ($self, $args, $fh) = @_;

    $self->{'sender'}->submit($args, $fh);
}

sub send_queued
{
    my ($self) = @_;

    return $self->{'sender'}->send_queued();
}

sub receive
{
    my ($self, $counter, $name, $since_ts, $persist, $persist_time) = @_;

    my $context = $self->{'context'};
    my $receiver_specs = $context->{'config'}->{'receivers'};
    my @receiver_specs_to_process = @{$receiver_specs};
    if ($name) {
        my $receiver_spec =
            first { $_->{'name'} eq $name }
                @{$receiver_specs};
        if (not $receiver_spec) {
            die "Unable to find named receiver";
        }
        @receiver_specs_to_process = $receiver_spec;
    }
    my @receivers =
        map { my %args = %{$_};
              my $type = $args{'type'};
              my $module_name = "App::Paws::Receiver::$type";
              my $ws_name = delete $args{'workspace'};
              my $ws = $context->{'workspaces'}->{$ws_name};
              $module_name->new(context   => $context,
                                workspace => $ws,
                                %args) }
            @receiver_specs_to_process;
    if (not $persist) {
        for my $receiver (@receivers) {
            $receiver->workspace()->conversations_obj()->retrieve_nb();
        }
        for my $receiver (@receivers) {
            $receiver->run($counter, $since_ts);
        }
        return 1;
    }

    my $start = DateTime->now(time_zone => 'local');
    debug("Beginning persist process at ".$start->strftime('%F %T'));

    my %ws_to_receiver =
        map { $_->{'workspace'}->name() => $_ }
            @receivers;

    my %ws_to_conversation;
    my %ws_to_conversation_to_thread;
    my %ws_to_current_client;
    my %ws_to_old_clients;
    my %client_to_details;
    my %id_to_client;
    my $id = 1;
    my $first_pass = 1;

    my $loop = IO::Async::Loop->new();

    my $init_in_ch  = IO::Async::Channel->new();
    my $init_out_ch = IO::Async::Channel->new();
    my $init_done   = 0;
    my $init_routine = IO::Async::Routine->new(
        channels_in  => [ $init_in_ch ],
        channels_out => [ $init_out_ch ],
        code => sub {
            my $data = $init_in_ch->recv();
            eval {
                debug("Running initial fetch operations");
                for my $receiver (@receivers) {
                    $receiver->workspace()->conversations_obj()->retrieve_nb();
                }
                for my $receiver (@receivers) {
                    $receiver->run($counter, $since_ts);
                }
                $init_out_ch->send({});
                debug("Finished running initial fetch operations");
            };
            if (my $error = $@) {
                print STDERR "Initialisation failed\n";
                exit(1);
            }
            return 0;
        },
    );
    $loop->add($init_routine);
    $init_out_ch->recv(
        on_recv => sub {
            debug("Initialisation completed, setting init_done");
            $init_done = 1;
        }
    );

    my $client_timer = IO::Async::Timer::Periodic->new(
        first_interval => 0,
        interval       => 120,
        on_tick        => sub {
            for my $receiver (@receivers) {
                my $ws = $receiver->{'workspace'};
                my $ws_name = $ws->name();
                debug("Starting new client for $ws_name");
                my $rtm_request =
                    standard_get_request($context, $ws, '/rtm.connect');
                my $ua = $context->ua();
                my $rtm_res = $ua->request($rtm_request);
                if (not $rtm_res->is_success()) {
                    print STDERR "Unable to connect to RTM for workspace ".
                                "'$ws_name': ".
                                $rtm_res->as_string();
                    next;
                }
                my $data = decode_json($rtm_res->decoded_content());
                if (not $data->{'ok'}) {
                    print STDERR "Unable to connect to RTM for workspace ".
                                "'$ws_name': ".
                                $rtm_res->as_string();
                    next;
                }
                my $ws_url = $data->{'url'};

                my $new_id = $id++;
                my $client = Net::Async::WebSocket::Client->new(
                    on_text_frame => sub {
                        my ($self, $frame) = @_;
                        debug("Got text frame for $ws_name ($new_id): $frame");
                        my $data = eval { decode_json($frame) };
                        if (my $error = $@) {
                            print STDERR "Unable to parse RTM message\n";
                        } elsif ($data->{'type'} eq 'message') {
                            $ws_to_conversation{$ws_name}
                                ->{$data->{'channel'}} = 1;
                            if ($data->{'thread_ts'}) {
                                $ws_to_conversation_to_thread{$ws_name}
                                    ->{$data->{'channel'}}
                                    ->{$data->{'thread_ts'}} = 1;
                            }
                        }
                    },
                    on_pong_frame => sub {
                        my $now = time();
                        my $client = $id_to_client{$new_id};
                        $client_to_details{$client}->{'pong'} = $now;
                        debug("Got ping response for $ws_name ".
                              "($new_id) at $now");
                    },
                );
                $id_to_client{$new_id} = $client;
                $loop->add($client);
                $client->connect(url => $ws_url)->then(
                    sub {
                        my $now = time();
                        $client_to_details{$client}->{'start'} = $now;
                        debug("Sending ping frame to client at $now");
                        $client_to_details{$client}->{'ping'} = $now;
                        $client->send_ping_frame();
                    }
                )->get();

                if ($ws_to_current_client{$ws_name}) {
                    push @{$ws_to_old_clients{$ws_name}},
                         $ws_to_current_client{$ws_name};
                }
                $ws_to_current_client{$ws_name} = $client;
                debug("Started new client for $ws_name ($new_id)");
            }
            if ($first_pass) {
                $init_in_ch->send({});
                $first_pass = 0;
            }
        }
    );

    my $runtime = $start->clone();
    my $minutes = $runtime->minute();
    my $extra = $persist_time - ($minutes % $persist_time);
    $runtime->add(minutes => $extra);
    $runtime->set(second => 0);
    my ($d, $m, $s) =
        $runtime->subtract_datetime($start)->in_units(
            'days', 'minutes', 'seconds'
        );
    $m += $d * 24 * 60;
    $s += $m * 60;
    my $first_interval = $s;

    my $ping_timer = IO::Async::Timer::Periodic->new(
        first_interval => 2,
        interval       => 5,
        on_tick        => sub {
            my @current_clients = values %ws_to_current_client;
            my @old_clients = map { @{$_} } values %ws_to_old_clients;

            for my $client (@current_clients, @old_clients) {
                my $now = time();
                debug("Sending ping frame to client at $now");
                $client->send_ping_frame();
                $client_to_details{$client}->{'ping'} = $now;
            }
        }
    );

    my $pong_timer = IO::Async::Timer::Periodic->new(
        first_interval => 30,
        interval       => 30,
        on_tick        => sub {
            # Find dead current clients.
            my @current_clients = values %ws_to_current_client;
            my @pong_timestamps =
                sort
                map { $client_to_details{$_}->{'pong'} }
                    @current_clients;
            if ($pong_timestamps[0] < (time() - $PING_TIMEOUT)) {
                my $now = time();
                print STDERR "No ping response within ".
                             "${PING_TIMEOUT}s, exiting at $now.\n";
                my $diff = $now - $start->epoch();
                print STDERR "Persistent connection stayed open for ${diff}s.\n";
                exit(1);
            } else {
                debug("All clients still alive");
            }

            # Confirm that each old client survived past the new
            # client start time, for new clients that are at least 60s
            # old.
            for my $ws_name (keys %ws_to_old_clients) {
                my $current_client = $ws_to_current_client{$ws_name};
                my $current_start =
                    $client_to_details{$current_client}->{'start'};
                my $now = time();
                if (($now - $current_start) > 60) {
                    debug("Checking old client ".
                          "(current start is $current_start)");
                    my @old_clients = @{$ws_to_old_clients{$ws_name}};
                    for my $client (@old_clients) {
                        my %client_to_id = reverse %id_to_client;
                        debug("Old client is $client (".
                              $client_to_id{$client}.")");
                        my $latest_pong = $client_to_details{$client}->{'pong'};
                        debug("Old ping response is $latest_pong");

                        if ($latest_pong < $current_start) {
                            print STDERR "No ping response for old ".
                                         "client after new client ".
                                         "initialised, exiting at $now\n";
                            my $diff = $now - $start->epoch();
                            print STDERR "Persistent connection stayed ".
                                         "open for ${diff}s.\n";
                            exit(1);
                        }
                        debug("Removing old client for $ws_name at $now");
                        $loop->remove($client);
                        delete $client_to_details{$client};
                    }
                    $ws_to_old_clients{$ws_name} = [];
                }
            }
        }
    );

    my $timer = IO::Async::Timer::Periodic->new(
        first_interval => $first_interval,
        interval       => ($persist_time * 60),
        on_tick        => sub {
            eval {
                if (not $init_done) {
                    debug("Initialisation not yet complete, skipping fetches");
                    return;
                }
                for my $ws_name (keys %ws_to_conversation) {
                    my $conversation_to_threads =
                        $ws_to_conversation_to_thread{$ws_name};
                    my $receiver = $ws_to_receiver{$ws_name};
                    my $ws = $receiver->{'workspace'};
                    $ws->reset();
                    my @conversation_ids = keys %{$ws_to_conversation{$ws_name}};
                    my %conversation_name_to_threads;
                    for my $conversation_id (@conversation_ids) {
                        my $conversation_name =
                            $ws->conversations_obj()->id_to_name($conversation_id);
                        debug("Fetching new messages for ".
                              "$ws_name/$conversation_name");
                        my @threads = keys
                            %{$conversation_to_threads->{$conversation_id} || {}};
                        $conversation_name_to_threads{$conversation_name} =
                            \@threads;
                    }
                    $receiver->run(undef, undef, \%conversation_name_to_threads);
                }
                %ws_to_conversation = ();
                %ws_to_conversation_to_thread = ();
            };
            if (my $error = $@) {
                print STDERR "Unable to process messages: $error";
            }
        }
    );

    $client_timer->start();
    $loop->add($client_timer);
    $ping_timer->start();
    $loop->add($ping_timer);
    $pong_timer->start();
    $loop->add($pong_timer);
    $timer->start();
    $loop->add($timer);

    $loop->run();
}

sub aliases
{
    my ($self) = @_;

    my $context = $self->{'context'};
    my $domain = $context->domain_name();
    my @aliases;
    for my $ws_name (keys %{$context->{'workspaces'}}) {
        my $ws = $context->{'workspaces'}->{$ws_name};
        $ws->users()->retrieve();
        my $user_list = $ws->users()->get_list();
        for my $user (@{$user_list}) {
            my ($real_name, $username) = @{$user};
            push @aliases,
                 "alias slack-$ws_name-$username $real_name ".
                 "<im/$username\@$ws_name.$domain>";
        }
    }
    return \@aliases;
}

sub reset
{
    my ($self) = @_;

    my $context = $self->{'context'};
    for my $ws (values %{$context->{'workspaces'}}) {
        for my $module (qw(conversations_obj users)) {
            $ws->{$module}->reset();
        };
    }

    return 1;
}

1;

__END__

=head1 NAME

App::Paws

=head1 DESCRIPTION

Provides for sending messages, receiving messages for a set of
workspaces, and generating aliases for a set of workspaces.

=head1 CONSTRUCTOR

=over 4

=item B<new>

Loads configuration from the '.paws' directory in the user's home
directory, instantiates helper objects accordingly, and returns a new
instance of L<App::Paws>.

=back

=head1 PUBLIC METHODS

=over 4

=item B<send>

See L<App::Paws::Sender::submit>.

=item B<send_queued>

See L<App::Paws::Sender::send_queued>.

=item B<receive>

Takes a message counter, a receiver name, and a lower-bound timestamp
as its arguments (each is optional).  Receives messages for the
specified receiver, if a name was provided, or all receivers
otherwise.  If the lower-bound timestamp is provided, then only
messages with a timestamp from that point onwards are received.

=item B<aliases>

Returns an arrayref comprising alias directives for each user in each
workspace, for use in a Mutt aliases file.

=item B<reset>

Resets the current workspace state, so that they can be used to
re-retrieve conversation and user lists from Slack.

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
