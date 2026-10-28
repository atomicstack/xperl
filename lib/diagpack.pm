package diagpack;

use strict;
use warnings;
use XPerl::DiagPack ();

our $VERSION = '0.01';

sub import {
    my ( $class, @languages ) = @_;
    XPerl::DiagPack::_validate_language(@languages);
    my $language = $languages[0];
    XPerl::DiagPack::_load_language($language) unless $language eq 'en';
    XPerl::DiagPack::_set_lexical_hint($language);
}

1;

=head1 NAME

diagpack - select a diagnostic language lexically

=head1 SYNOPSIS

    use diagpack 'de';

=head1 DESCRIPTION

This pragma loads the named diagnostic language pack and selects its engine
for diagnostics compiled in the current lexical scope. Leaving the scope
restores the previous selection.

Diagnostics retain their originating scope's language choice even when they
are rendered later. Without an explicit pragma choice, rendering follows
C<${^DIAG_RENDER}>. That variable still controls the presentation style and
JSON or Dumper envelope inside a pragma scope.

An explicit language passed to C<render_as_legacy>, C<render_as_annotated>,
or C<render> overrides the captured choices throughout the rendered tree.
Loading a replacement pack changes later language lookups; diagnostics
already captured in a pragma scope keep their original engine.

English is available without loading the optional C<XPerl::DiagPack::EN>
extension. Requiring a pack directly registers a rendering capability and
does not select it lexically.

=cut
