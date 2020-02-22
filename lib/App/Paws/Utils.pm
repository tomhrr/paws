package App::Paws::Utils;

use warnings;
use strict;

use POSIX qw(strftime);
use base 'Exporter';
our @EXPORT_OK = qw(get_mail_date
                    standard_get_request);

sub get_mail_date
{
    return strftime("%a, %d %b %Y %H:%M:%S %z", localtime($_[0]));
}

sub standard_get_request
{
    my ($context, $ws, $path, $query_form) = @_;

    my $token = $ws->token();
    my $req = HTTP::Request->new();
    $req->header('Content-Type' => 'application/x-www-form-urlencoded');
    $req->header('Authorization' => 'Bearer '.$token);
    my $uri = URI->new($context->slack_base_url().$path);
    $uri->query_form(%{$query_form});
    $req->uri($uri);
    $req->method('GET');
    return $req;
}

1;
