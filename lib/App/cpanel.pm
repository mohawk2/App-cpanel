package App::cpanel;

use Exporter 'import';

our $VERSION = '0.002';
our @EXPORT_OK = qw(dispatch_cmd_print dispatch_cmd_raw);

=head1 NAME

App::cpanel - CLI for cPanel UAPI and API 2

=begin markdown

# PROJECT STATUS

[![CPAN version](https://badge.fury.io/pl/App-cpanel.svg)](https://metacpan.org/pod/App::cpanel)

=end markdown

=head1 SYNOPSIS

  $ cpanel uapi Notifications get_notifications_count
  $ cpanel uapi ResourceUsage get_usages
  $ cpanel uapi Fileman list_files dir=public_html
  $ cpanel uapi Fileman get_file_content dir=public_html file=index.html
  $ cpanel download public_html/index.html
  $ cpanel api2 Fileman fileop op=chmod metadata=0755 sourcefiles=public_html/cgi-bin/hello-world
  $ cpanel api2 Fileman fileop op=unlink sourcefiles=public_html/cgi-bin/hello-world
  $ cpanel api2 Fileman mkdir path= name=new-dir-at-top

  # this one is one at a time but can overwrite files
  $ cpanel api2 Fileman savefile dir=public_html/cgi-bin filename=hello-world content="$(cat public_html/cgi-bin/hello-world)"
  # this is multiple files but refuses to overwrite
  $ cpanel upload public_html/cgi-bin hello-world

=head1 DESCRIPTION

CLI for cPanel UAPI and also API 2, due to missing functionality in UAPI.

Stores session token in F<~/.cpanel-token>, a two-line file. First line
is the URL component that goes after C<cpsess>. Second is the C<cpsession>
cookie, which you can get from your browser's DevTools.

Stores relevant domain name in F<~/.cpanel-domain>.

=head1 FUNCTIONS

Exportable:

=head2 dispatch_cmd_print

Will print the return value, using L<Mojo::Util/dumper> except for
C<download>.

=head2 dispatch_cmd_raw

Just returns the decoded JSON value or C<download>ed content.

=head1 SEE ALSO

L<https://documentation.cpanel.net/display/DD/Guide+to+UAPI>

L<https://documentation.cpanel.net/display/DD/Guide+to+cPanel+API+2>

=head1 AUTHOR

Ed J

=head1 COPYRIGHT AND LICENSE

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

use strict;
use warnings;
use Mojo::URL;
use Mojo::UserAgent;
use Mojo::File qw(path);
use Mojo::Util qw(dumper);

my %cmd2func = (
  uapi => [ \&uapi, 1 ],
  download => [ \&download, 0 ],
  upload => [ \&upload, 1 ],
  api2 => [ \&api2, 1 ],
);
my $token_file = "$ENV{HOME}/.cpanel-token";
my $domain_file = "$ENV{HOME}/.cpanel-domain";

sub dispatch_cmd_print {
  my $cmd = shift;
  die "No command\n" unless $cmd;
  die "Unknown command '$cmd'\n" unless my $info = $cmd2func{$cmd};
  my $retval = $info->[0]->(@_);
  print $info->[1] ? dumper($retval) : $retval;
}

sub dispatch_cmd_raw {
  my $cmd = shift;
  die "No command\n" unless $cmd;
  die "Unknown command '$cmd'\n" unless my $info = $cmd2func{$cmd};
  goto &{$info->[0]};
}

sub api_request {
  my ($method, $domain, $token, $parts, $args, @extra_args) = @_;
  my ($url_token, $cookie_token) = split /\s+/, $token;
  my $url = Mojo::URL->new("https://$domain:2083");
  $url->path(join '/', '', "cpsess$url_token", @$parts);
  $url->query(%$args) if $args;
  my $ua = Mojo::UserAgent->new;
  $ua->$method(
    $url->to_abs . "",
    { Cookie => "cpsession=$cookie_token" },
    @extra_args,
  );
}

sub read_file {
  my ($file) = @_;
  die "$file: $!\n" unless -f $file;
  die "$file: too readable\n" if (stat $file)[2] & 0044;
  local $/;
  open my $fh, $file or die "$file: $!\n";
  my $content = <$fh>;
  die "No content in '$file'\n" unless $content;
  $content =~ s/^\s*(.*?)\s*$/$1/g;
  $content;
}

sub read_token { read_file($token_file) }
sub read_domain { read_file($domain_file) }

sub uapi {
  my ($module, $function, @args) = @_;
  die "No module\n" unless $module;
  die "No function\n" unless $function;
  my ($token, $domain) = (read_token(), read_domain());
  my $args_hash = { map split('=', $_, 2), @args } if @args;
  my $tx = api_request 'get', $domain, $token,
    [ 'execute', $module, $function ],
    $args_hash;
  $tx->res->json;
}

sub download {
  my ($file) = @_;
  die "No file\n" unless $file;
  my ($token, $domain) = (read_token(), read_domain());
  my $tx = api_request 'get', $domain, $token,
    [ 'download' ],
    { skipencode => 1, file => $file };
  $tx->res->body;
}

sub make_upload_form {
  my $dir = shift;
  my $counter = 0;
  +{
    dir => $dir,
    map {
      my $p = path $_;
      ('file-' . ++$counter => {
        filename => $p->basename,
        content => $p->slurp,
      });
    } @_,
  };
}

sub upload {
  my ($dir, @files) = @_;
  die "No dir\n" unless $dir;
  die "No files\n" unless @files;
  my ($token, $domain) = (read_token(), read_domain());
  my $tx = api_request 'post', $domain, $token,
    [ 'execute', 'Fileman', 'upload_files' ],
    undef,
    form => make_upload_form($dir, @files),
    ;
  $tx->res->json;
}

sub api2 {
  my ($module, $function, @args) = @_;
  die "No module\n" unless $module;
  die "No function\n" unless $function;
  my ($token, $domain) = (read_token(), read_domain());
  my $args_hash = { map split('=', $_, 2), @args } if @args;
  my $tx = api_request 'post', $domain, $token,
    [ qw(json-api cpanel) ],
    {
      cpanel_jsonapi_module => $module,
      cpanel_jsonapi_func => $function,
      cpanel_jsonapi_apiversion => 2,
      %{ $args_hash || {} },
    };
  $tx->res->json;
}

1;
