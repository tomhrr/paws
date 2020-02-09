package App::Paws::Message;

use warnings;
use strict;

use Encode;
use HTML::Entities qw(decode_entities);
use HTTP::Request;
use MIME::Entity;

use App::Paws::Utils qw(get_mail_date);

sub new
{
    my ($class, $context, $workspace, $conversation, $message_data) = @_;

    my $self = {
        context      => $context,
        workspace    => $workspace,
        conversation => $conversation,
        edited_ts    => $message_data->{'edited'}->{'ts'},
        (map { $_ => $message_data->{$_} }
            qw(ts thread_ts user text files)),
    };
    bless $self, $class;
    return $self;
}

sub ts
{
    return $_[0]->{'ts'};
}

sub thread_ts
{
    return $_[0]->{'thread_ts'};
}

sub user
{
    return $_[0]->{'user'};
}

sub text
{
    return $_[0]->{'text'};
}

sub edited_ts
{
    return $_[0]->{'edited_ts'};
}

sub files
{
    return $_[0]->{'files'};
}

sub id
{
    my ($self, $ignore_edited) = @_;

    my $context = $self->{'context'};
    my $ws_name = $self->{'workspace'}->name();
    my $conversation = $self->{'conversation'};

    my $ts = $self->ts();
    my $local_part = "$ts.$conversation";
    my $edited_ts = $self->edited_ts();
    if ((not $ignore_edited) and $edited_ts) {
        $local_part = "$edited_ts.$local_part";
    }

    my $domain_name = $context->domain_name();
    return "<$local_part\@$ws_name.$domain_name>";
}

sub _substitute_user_mentions
{
    my ($self, $content) = @_;

    my $ws = $self->{'workspace'};
    my @ats = ($content =~ /<\@(U.*?)>/g);
    my %at_map = map { $_ => $ws->user_id_to_name($_) } @ats;
    for my $at (keys %at_map) {
        if (my $name = $at_map{$at}) {
            $content =~ s/<\@$at>/<\@$name>/g;
        }
    }

    return $content;
}

sub _add_attachment
{
    my ($self, $entity, $file) = @_;

    my $context = $self->{'context'};
    my $token = $self->{'workspace'}->token();

    my $req = HTTP::Request->new();
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');
    $req->header('Authorization' => 'Bearer '.$token);
    my $url_private = $file->{'url_private'};
    if ($url_private =~ /^\//) {
        $url_private = $context->slack_base_url().$url_private;
    }
    $req->uri($url_private);
    $req->method('GET');
    my $filename = $file->{'url_private'};
    $filename =~ s/.*\///;
    my $res;
    my $runner = $context->{'runner'};
    $runner->add('conversations.replies', $req,
                 sub { my ($runner, $internal_res) = @_;
                       $res = $internal_res; });
    while (not $res) {
        $runner->poke('conversations.replies');
    }
    $entity->attach(Type     => $file->{'mimetype'},
                    Data     => $res->content(),
                    Filename => $filename);

    return 1;
}

sub to_entity
{
    my ($self, $first_ts, $thread_ts, $reply_to_id) = @_;

    my $context = $self->{'context'};
    my $ws = $self->{'workspace'};
    my $ws_name = $ws->name();
    my $conversation = $self->{'conversation'};

    my $token = $ws->token();
    my $reply_to_thread = ($thread_ts ne $first_ts);

    my $ts = $self->ts();
    $ts =~ s/\..*//;

    my $from_user = 'unknown';
    my $user = $self->user();
    if ($user) {
        my $name = $ws->user_id_to_name($user);
        if ($name) {
            $from_user = $name;
        }
    }

    my $content = $self->_substitute_user_mentions($self->text());

    my $domain_name = $context->domain_name();
    my $ws_domain_name = "$ws_name.$domain_name";
    my $message_id = $self->id();

    my $entity = MIME::Entity->build(
        Date         => get_mail_date($ts),
        From         => "$from_user\@$ws_domain_name",
        To           => $context->user_email(),
        Subject      => "Message from $conversation".
                        ($self->edited_ts() ? ' (edited)' : ''),
        'Message-ID' => $message_id,
        Charset      => 'UTF-8',
        Encoding     => 'base64',
        Data         => Encode::encode('UTF-8', decode_entities($content),
                                       Encode::FB_CROAK)
    );

    for my $file (@{$self->files() || []}) {
        $self->_add_attachment($entity, $file);
    }

    my $parent_message = App::Paws::Message->new(
        $context, $ws, $conversation, { ts => $thread_ts }
    );
    my $parent_id = $parent_message->id();
    if (($parent_id ne $message_id) or $reply_to_id) {
        $entity->head()->add('In-Reply-To', ($reply_to_id || $parent_id));
        if ($reply_to_thread) {
            my $first_message = App::Paws::Message->new(
                $context, $ws, $conversation, { ts => $first_ts }
            );
            my $first_id = $first_message->id();
            $entity->head()->add('References', "$first_id $parent_id");
        } else {
            $entity->head()->add('References', "$parent_id");
        }
    }

    my $reply_to =
        ($reply_to_thread)
            ? "$conversation+$thread_ts\@$ws_domain_name\n"
            : "$conversation\@$ws_domain_name\n";
    $entity->head()->add('Reply-To', $reply_to);
    $entity->head()->add('X-Paws-Thread-TS', $thread_ts);
    $entity->head()->delete('X-Mailer');

    return $entity;
}

sub to_delete_entity
{
    my ($self) = @_;

    my $context = $self->{'context'};
    my $ws_name = $self->{'workspace'}->name();
    my $conversation = $self->{'conversation'};

    my $message_id = $self->id();
    my $del_message_id = $message_id;
    $del_message_id =~ s/@/.deleted@/;

    my $domain_name = $context->domain_name();
    my $ws_domain_name = "$ws_name.$domain_name";

    my $time = time();
    my $entity = MIME::Entity->build(
        Date          => get_mail_date($time),
        From          => "paws-admin\@$ws_domain_name",
        To            => $context->user_email(),
        Subject       => "Message from $conversation (deleted)",
        'Message-ID'  => $del_message_id,
        'References'  => $message_id,
        Charset       => 'UTF-8',
        Encoding      => 'base64',
        Data          => 'Message deleted.',
    );
    $entity->head()->add('In-Reply-To', $message_id);

    return $entity;
}

1;
