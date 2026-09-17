
=head1 NAME

Matrix - Matrix helper class

=cut

use v5.40;
use experimental qw[ class ];

our $VERSION = '0.01';

use Carp;

use Tensor;
use Vector;

class Matrix :isa(Tensor) {
    # --------------------------------------------------------------------------
    # Accessors
    # --------------------------------------------------------------------------

    method rows { $self->shape->[0] }
    method cols { $self->shape->[1] }

    method height { $self->rows - 1 }
    method width  { $self->cols - 1 }

    # --------------------------------------------------------------------------
    # Static Constructors
    # --------------------------------------------------------------------------

    # Building from others _____________________________________________________

    sub concat ($class, $a, $b) {
        Carp::confess "Rows must be equal to concat (".($a->rows).") != (".($a->rows).")"
            unless $a->rows == $b->rows;
        my @shape = ($a->rows, $a->cols + $b->cols);
        return $class->construct(
            \@shape,
            sub ($x, $y) {
                ($y < $a->cols) ? $a->at($x, $y) : $b->at($x, ($y - $a->cols));
            }
        )
    }

    sub stack ($class, $a, $b) {
        Carp::confess "Cols must be equal to stack (".($a->cols).") != (".($a->cols).")"
            unless $a->cols == $b->cols;
        my @shape = ($a->rows + $b->rows, $a->cols);
        return $class->construct(
            \@shape,
            sub ($x, $y) {
                ($x < $a->rows) ? $a->at($x, $y) : $b->at(($x - $a->rows), $y);
            }
        )
    }

    # Misc. Matrix Types _______________________________________________________

    sub square ($class, $size, $initial=0) {
        $class->initialize([ $size, $size ], $initial)
    }

    sub eye ($class, $size) {
        return $class->initialize(
            [ $size, $size ],
            [ map { (0) x ($_ - 1), 1, (0) x ($size - $_) } 1 .. $size ]
        )
    }

    sub diagonal ($class, $vector) {
        my $size = $vector->size;

        my @new = (0) x ($size * $size);
        for (my $x = 0; $x < $size; $x++) {
            $new[$x * $size + $x] = $vector->at($x);
        }

        return $class->initialize( [ $size, $size ], \@new );
    }

    # --------------------------------------------------------------------------
    # Index calculators
    # --------------------------------------------------------------------------

    method row_indices ($x) {
        Carp::confess "Coord out of bounds x(${x})" if $x > $self->height;
        return $self->index( $x, 0 ) .. $self->index( $x, $self->width )
    }

    method col_indices ($y) {
        Carp::confess "Coord out of bounds x(${y})" if $y > $self->width;
        return map { $self->index( $_, $y ) } 0 .. $self->height;
    }

    # --------------------------------------------------------------------------
    # Accessing Elements & Groups of Elements
    # --------------------------------------------------------------------------

    method row_at ($x) { $self->slice_data_array( $self->row_indices($x) ) }
    method col_at ($y) { $self->slice_data_array( $self->col_indices($y) ) }

    # TODO:
    # - some way of accessing the main diagonal
    #   - or with an offset
    # - getting a random rectangle
    # - getting a quadrant

    # --------------------------------------------------------------------------
    # Accessing Row/Col as Vectors
    # --------------------------------------------------------------------------

    method row_vector_at ($x) {
        return Vector->initialize($self->cols, [ $self->row_at($x) ]);
    }

    method col_vector_at ($y) {
        return Vector->initialize($self->rows, [ $self->col_at($y) ]);
    }

    # --------------------------------------------------------------------------
    # Moving elements
    # --------------------------------------------------------------------------

    # API IDEA:
    # The $wrap arg default is false, but if true, the
    # - shift_cols( $by, $wrap ) where $by is + (go right), and - (go left)
    # - shift_rows( $by, $wrap ) where $by is + (go down), and - (go up)
    # - shift( $by, $direction ) where $dir = N,S,E,W along with NE, NW, etc.

    # rename to shift_cols
    method shift_horz ($by) {
        $by = -$by;

        return __CLASS__->construct(
            [ $self->shape->@* ],
            sub ($x, $y) {
                return $self->slice_data_array( $x * $self->cols + ($y + $by) )
                    if ($y + $by) >= 0 && $y < ($self->cols - $by);
                return 0;
            }
        )
    }

    # TODO:
    # - add shift_vert
    # - or add shift( $dir, $by ) where $dir = N,S,E,W along with NE, NW, etc.
    #      - could represent the entire shift with a 3x3

    # FIXME: this is a poor name, fix it ...
    method copy_row ($from, $to) {
        return __CLASS__->construct(
            [ $self->shape->@* ],
            sub ($x, $y) {
                return $self->at($from, $y) if $x == $to;
                return $self->at($x, $y);
            }
        )
    }

    # TODO:
    # - copy_column
    # - probably some others, can't think of any specific ones atm.

    # --------------------------------------------------------------------------
    # Matrix Transpose
    # --------------------------------------------------------------------------

    method transpose {
        __CLASS__->from_native($self->_native->transpose)
    }

    # --------------------------------------------------------------------------
    # Matrix Multiplication
    # --------------------------------------------------------------------------

    method matrix_multiply ($other) {
        my $result = $self->_native->matrix_multiply($other->_native);
        return Vector->from_native($result) if $other isa Vector;
        return Matrix->from_native($result);
    }

    method binary_op ($operation, $other) {
        return Tensor::binary_op($self, $operation, $other)
            unless ref $operation eq 'CODE' && $other isa Vector;
        return __CLASS__->construct(
            [ $self->shape->@* ],
            sub ($x, $y) { $operation->($self->at($x, $y), $other->at($y)) }
        );
    }

    # --------------------------------------------------------------------------
    # Specialized version of Tensor's binary_op to handle the edge case
    # --------------------------------------------------------------------------

    # --------------------------------------------------------------------------

    method to_string (@) {
        my @out;
        for (my $x = 0; $x < $self->rows; $x++) {
            push @out =>
                join ' ' =>
                    map { sprintf('%3s', $_) }
                        $self->slice_data_array( $self->row_indices( $x ) );
        }
        return join "\n" => @out;
    }
}
