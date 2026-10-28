package XPerl::DiagPack;

use strict;
use warnings;

our $VERSION = '0.01';

# Find language modules installed anywhere on the active module search path.
sub _installed_languages {
    my %languages;

    for my $inc (@INC) {
        next if ref $inc;
        my $directory = "$inc/XPerl/DiagPack";
        opendir my $entries, $directory or next;
        while ( defined( my $entry = readdir $entries ) ) {
            $languages{ lc $1 } = 1 if $entry =~ /\A([A-Z]{2})\.pm\z/;
        }
        closedir $entries;
    }

    return sort keys %languages;
}

# Require one language module and let its XS boot register the capability.
sub _load_language {
    my ($language) = @_;
    XPerl::DiagPack::_validate_language($language);

    my $module = 'XPerl::DiagPack::' . uc($language);
    ( my $file = "$module.pm" ) =~ s{::}{/}g;
    require $file;
}

sub import {
    my ( $class, @requested ) = @_;
    return unless @requested;
    my @selected = @requested == 1 && $requested[0] eq 'all' ? _installed_languages() : @requested;
    _load_language($_) for @selected;
}

1;

=head1 NAME

XPerl::DiagPack - load optional diagnostic language packs

=head1 SYNOPSIS

    use XPerl::DiagPack qw(all);

=head1 DESCRIPTION

Loading this module registers the requested diagnostic language packs as
available capabilities. It does not select a language for rendering.

C<all> loads every language pack shipped with this Perl installation.

=cut
