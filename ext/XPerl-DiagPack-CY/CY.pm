package XPerl::DiagPack::CY;

=head1 NAME

XPerl::DiagPack::CY - diagnostic language pack for cy

=head1 DESCRIPTION

Loads the diagnostic catalog for language C<cy> and registers it as
an available capability. Loading the module does not change the selected
diagnostic language.

=head1 METHODS

=over 4

=item metadata

Returns the language and descriptor ABI metadata.

=item render($diagnostic)

Returns the message body rendered with this pack's catalog, or C<undef> when
the pack has no complete rendering. It does not select a language, apply a
fallback, add locations or grouping, invoke hooks, or deliver a diagnostic.

The catalog uses the core diagnostic's retained semantic parameters.
Registration checks the schema of each supplied diagnostic. Missing rows
or a missing complete translation return C<undef>.

=back

=cut

use strict;
use warnings;

our $VERSION = '0.01';
require XSLoader;
XSLoader::load(__PACKAGE__, $VERSION);

1;
