=head1 NAME

Tensor::XS - Tensor XS helper module

=cut

package Tensor::XS;

use v5.40;
use XSLoader;

our $VERSION = '0.01';

XSLoader::load(__PACKAGE__, $VERSION);

sub new {
    my ($class, $shape, $data, $dtype) = @_;
    $class->new_with_dtype($shape, $data, defined $dtype ? $dtype : 'BF16');
}

1;

=head1 NAME

Tensor::XS - native storage prototype for Tensor-XS

=head1 DESCRIPTION

This module is the first step of the Tensor-XS XS migration.  It
provides a compact native Tensor storage object; the higher-level Tensor,
Vector, and Matrix APIs will be moved onto it incrementally.

=cut
