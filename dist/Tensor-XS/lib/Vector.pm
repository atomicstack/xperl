
=head1 NAME

Vector - Vector helper class

=cut

use v5.40;
use experimental qw[ class ];

our $VERSION = '0.01';

use Carp;

use Tensor;

class Vector :isa(Tensor) {
    # --------------------------------------------------------------------------
    # Vector specific methods
    # --------------------------------------------------------------------------

    method index_of ($value) {
        my $i = 0;
        while ($i < $self->size) {
            return $i if $self->at( $i ) == $value;
            $i++;
        }
        return -1;
    }

    # --------------------------------------------------------------------------
    # Static Constructors
    # --------------------------------------------------------------------------

    sub concat ($class, $a, $b) {
        return $class->initialize(($a->size + $b->size), [ $a->to_list, $b->to_list ])
    }

    # --------------------------------------------------------------------------
    # Matrix multiplication
    # --------------------------------------------------------------------------

    method matrix_multiply ($other) {
        my $result = $self->_native->matrix_multiply($other->_native);
        return __CLASS__->from_native($result);
    }

    # --------------------------------------------------------------------------
    # Reductions (scalar results)
    # --------------------------------------------------------------------------

    method min_value { $self->reduce_data_array(\&Tensor::Ops::min) }
    method max_value { $self->reduce_data_array(\&Tensor::Ops::max) }

    method dot_product ($other) {
        return $self->_native->dot_product($other->_native)
    }

    # --------------------------------------------------------------------------

    method to_string (@) { return '<' . (join ' ' => $self->to_list) . '>' }
}
