
=head1 NAME

Tensor - Tensor helper class

=cut

use v5.40;
use experimental qw[ class ];

our $VERSION = '0.01';

use List::Util;
use Scalar::Util qw[ refaddr ];

class Tensor {
    # --------------------------------------------------------------------------
    # Overloads
    # --------------------------------------------------------------------------
    # NOTE: these might get annoying, might wanna remove the,
    # --------------------------------------------------------------------------
    use overload (
        '+'   => sub ($a, $b, @) { $a->add($b) },
        '-'   => sub ($a, $b, $swap) { $swap ? $a->neg : $a->sub($b) },
        '*'   => sub ($a, $b, @) { $a->mul($b) },
        '/'   => sub ($a, $b, @) { $a->div($b) },
        '%'   => sub ($a, $b, @) { $a->mod($b) },
        '**'  => sub ($a, $b, @) { $a->pow($b) },

        '!'   => sub ($n, @)     { $n->not },
        '=='  => sub ($n, $m, @) { $n->eq($m) },
        '!='  => sub ($n, $m, @) { $n->ne($m) },
        '<'   => sub ($n, $m, @) { $n->lt($m) },
        '<='  => sub ($n, $m, @) { $n->le($m) },
        '>'   => sub ($n, $m, @) { $n->gt($m) },
        '>='  => sub ($n, $m, @) { $n->ge($m) },

        '<=>' => sub ($n, $m, @) { $n->cmp($m) },

        # TODO:
        # - also atan2 cos sin exp abs log sqrt int
        # - consider <> to do some kind of iteration hmmm, 🤔

        # to be clear ...
        'neg' => sub ($a, @) { $a->neg },

        # to be visible 👀
        '""' => 'to_string',
    );

    # --------------------------------------------------------------------------
    # useful lexical subs
    # --------------------------------------------------------------------------

    my sub calculate_size ($shape) {
        return $shape unless ref $shape;
        return List::Util::reduce { $a * $b } 1, @$shape
    }

    my sub calculate_strides ($shape) {
        return $shape unless ref $shape;

        my @strides;
        my $stride = 1;
        for (my $i = @$shape - 1; $i >= 0; $i-- ) {
            $strides[$i] = $stride;
            $stride *= $shape->[$i];
        }
        return @strides;
    }

    my sub allocate_data_array ($shape, $initial) {
        # we want to own this, always
        return [ @$initial ] if ref $initial eq 'ARRAY';
        return [ ($initial) x calculate_size($shape) ]
    }

    my sub indicies_to_flat ($indicies, $strides) {
        my $dim = 0;
        List::Util::reduce { $a + $b * $strides->[ $dim++ ] } 0, @$indicies;
    }

    # --------------------------------------------------------------------------
    # Internal ND Array
    # --------------------------------------------------------------------------

    field $data  :param = undef;
    field $shape :param = undef;
    field $native :param :reader = undef;

    ADJUST {
        return if defined $native;
        $data    = $data->get if $data isa Scalar;
        $shape   = [ map { $_ isa Scalar ? $_->get : $_ } @$shape ];
        $data    = allocate_data_array($shape, $data); # unless ref $data eq 'ARRAY';
        my $expected_size = calculate_size($shape);
        Carp::confess "Bad data size, expected ${expected_size} got (".(scalar @$data).")"
            if scalar @$data != $expected_size;

        require Tensor::XS;
        $native = Tensor::XS->new($shape, $data, 'F64');
        $data = undef;
    }

    method data { $native->data }
    method shape { $native->shape }
    method strides {
        wantarray ? $native->strides->@* : $native->strides
    }

    method DUMP {
        return +{
            data    => $self->data,
            shape   => $self->shape,
            strides => $self->strides,
        }
    }

    sub from_native ($class, $native) {
        return $class->new(native => $native);
    }

    method _native { $native }

    my sub native_operand ($other) {
        return $other->get if $other isa Scalar;
        return $other->_native if $other isa Tensor;
        return $other;
    }

    # --------------------------------------------------------------------------
    # Access to the internal data array
    # --------------------------------------------------------------------------

    method to_list { return @{ $self->data } }

    method index_data_array ($index) {
        ($index >= 0 && $index < $self->size)
            || Carp::confess "Index out of bounds (${index})";
        return $self->data->[ $index ];
    }

    method slice_data_array (@indices) {
        ($_ >= 0 && $_ < $self->size)
            || Carp::confess "Index out of bounds (${_})"
                foreach @indices;
        return $self->data->@[ @indices ]
    }

    method map_data_array ($f) {
        [ map { $f->($_) } @{ $self->data } ]
    }

    method zip_data_arrays ($f, $other) {
        $other = $other->get if $other isa Scalar;

        return [
            map { $f->( $self->data->[$_], $other ) } 0 .. ($self->size - 1)
        ] if !blessed $other;

        return [
            map { $f->( $self->data->[$_], $other->data->[$_] ) } 0 .. ($self->size - 1)
        ]
    }

    method reduce_data_array ($f, $initial=undef) {
        return scalar List::Util::reduce { $f->($a, $b) } ($initial // ()), @{ $self->data }
    }

    # --------------------------------------------------------------------------
    # Rank, Total size and index <-> coords conversions
    # --------------------------------------------------------------------------

    method rank { $native->rank }
    method size { $native->size }

    method index  (@indicies) {
        Carp::confess "The number of indicies must match the rank got(".(scalar @indicies).") expected(".$self->rank.")"
            if $self->rank != scalar @indicies;
        return $native->index(@indicies)
    }

    method dim_index (@indicies) {
        Carp::confess "The number of indicies must be less than the rank got(".(scalar @indicies).") expected(".$self->rank.")"
            if $self->rank < scalar @indicies;

        my $dim   = $#indicies;
        my $shape = $self->shape;
        my $strides = $self->strides;
        my $start = 0;
        for my $i (0 .. $dim) {
            Carp::confess "Index out of bounds ($indicies[$i])"
                if $indicies[$i] < 0 || $indicies[$i] >= $shape->[$i];
            $start += $indicies[$i] * $strides->[$i];
        }
        my $end   = $start + $strides->[$dim] - 1;

        return ($start .. $end)
    }

    # --------------------------------------------------------------------------
    # Abstract Constructors & Methods
    # --------------------------------------------------------------------------

    sub initialize ($class, $shape, $initial) {
        return $class->new( shape => [ ref $shape ? @$shape : $shape ], data => $initial )
    }

    sub construct ($class, $shape, $f) {
        my $rank = scalar @$shape;
        my $size = calculate_size($shape);

        my @new = (0) x $size;
        if ($rank == 1) {
            $new[$_] = $f->( $_ ) foreach 0 .. $#new;
        }
        elsif ($rank == 2) {
            my ($rows, $cols) = @$shape;
            my $i = 0;
            for (my $x = 0; $x < $rows; $x++) {
                for (my $y = 0; $y < $cols; $y++) {
                    $new[$i++] = $f->( $x, $y )
                }
            }
        }
        else {
            my @strides = reverse calculate_strides($shape);
            foreach my $i ( 0 .. ($size - 1) ) {
                $new[$i] = $f->( map { int($i / $_) } @strides );
            }
        }

        return $class->initialize( $shape, \@new );
    }

    # --------------------------------------------------------------------------
    # Static Constructors
    # --------------------------------------------------------------------------

    sub ones  ($class, $shape) { $class->initialize($shape, 1) }
    sub zeros ($class, $shape) { $class->initialize($shape, 0) }

    sub sequence ($class, $shape, $start) {
        my $size = calculate_size($shape);
        $class->initialize([ @$shape ], [ $start .. ($start + ($size - 1)) ]);
    }

    sub random ($class, $shape, $min=0, $max=1) {
        my $size = calculate_size($shape);
        my $range = $max - $min;
        $class->initialize([ ref $shape ? @$shape : $shape ], [ map { $min + rand($range) } 1 .. $size ]);
    }

    sub randn ($class, $shape, $mean=0, $stddev=1) {
        # Box-Muller transform for normal distribution
        my $size = calculate_size($shape);
        my @values;
        for (my $i = 0; $i < $size; $i += 2) {
            my $u1 = rand();
            my $u2 = rand();
            my $r = sqrt(-2 * log($u1));
            my $theta = 2 * 3.14159265358979 * $u2;
            push @values, $mean + $stddev * $r * cos($theta);
            push @values, $mean + $stddev * $r * sin($theta) if $i + 1 < $size;
        }
        $class->initialize([ ref $shape ? @$shape : $shape ], [ @values[0 .. $size - 1] ]);
    }

    # --------------------------------------------------------------------------
    # Element Access
    # --------------------------------------------------------------------------

    method at (@coords) { $self->index_data_array( $self->index(@coords) ) }

    method dim_at (@coords) { $self->slice_data_array( $self->dim_index(@coords) ) }

    # --------------------------------------------------------------------------
    # Scalar Values
    # --------------------------------------------------------------------------

    method sum  { $native->reduce('sum') }
    method mean { $self->sum / $self->size }

    method min_value { $native->reduce('min') }
    method max_value { $native->reduce('max') }

    # --------------------------------------------------------------------------
    # Operations
    # --------------------------------------------------------------------------

    method unary_op ($operation) {
        if (ref $operation eq 'CODE') {
            state %operation_name = (
                refaddr(\&Tensor::Ops::neg)   => 'neg',
                refaddr(\&Tensor::Ops::abs)   => 'abs',
                refaddr(\&Tensor::Ops::exp)   => 'exp',
                refaddr(\&Tensor::Ops::log)   => 'log',
                refaddr(\&Tensor::Ops::sqrt)  => 'sqrt',
                refaddr(\&Tensor::Ops::trunc) => 'trunc',
                refaddr(\&Tensor::Ops::fract) => 'fract',
            );
            my $name = $operation_name{refaddr($operation)};
            return __CLASS__->initialize($self->shape,
                $self->map_data_array($operation)) unless defined $name;
            $operation = $name;
        }
        __CLASS__->from_native($native->unary($operation))
    }

    method binary_op ($operation, $other) {
        if (ref $operation eq 'CODE') {
            state %operation_name = (
                refaddr(\&Tensor::Ops::add) => 'add',
                refaddr(\&Tensor::Ops::sub) => 'sub',
                refaddr(\&Tensor::Ops::mul) => 'mul',
                refaddr(\&Tensor::Ops::div) => 'div',
                refaddr(\&Tensor::Ops::mod) => 'mod',
                refaddr(\&Tensor::Ops::pow) => 'pow',
                refaddr(\&Tensor::Ops::eq)  => 'eq',
                refaddr(\&Tensor::Ops::ne)  => 'ne',
                refaddr(\&Tensor::Ops::lt)  => 'lt',
                refaddr(\&Tensor::Ops::le)  => 'le',
                refaddr(\&Tensor::Ops::gt)  => 'gt',
                refaddr(\&Tensor::Ops::ge)  => 'ge',
                refaddr(\&Tensor::Ops::cmp) => 'cmp',
                refaddr(\&Tensor::Ops::and) => 'and',
                refaddr(\&Tensor::Ops::or)  => 'or',
                refaddr(\&Tensor::Ops::min) => 'min',
                refaddr(\&Tensor::Ops::max) => 'max',
            );
            my $name = $operation_name{refaddr($operation)};
            return __CLASS__->initialize($self->shape,
                $self->zip_data_arrays($operation, $other)) unless defined $name;
            $operation = $name;
        }
        __CLASS__->from_native($native->binary(
            native_operand($other), $operation))
    }

    # --------------------------------------------------------------------------
    # In-Place Operations (FAST - no object creation)
    # --------------------------------------------------------------------------

    method add_inplace ($other) {
        # $self += $other (modifies $self in place)
        $native->inplace(native_operand($other), 'add');
        return $self;
    }

    method sub_inplace ($other) {
        # $self -= $other (modifies $self in place)
        $native->inplace(native_operand($other), 'sub');
        return $self;
    }

    method mul_inplace ($other) {
        # $self *= $other (modifies $self in place)
        $native->inplace(native_operand($other), 'mul');
        return $self;
    }

    method div_inplace ($other) {
        # $self /= $other (modifies $self in place)
        $native->inplace(native_operand($other), 'div');
        return $self;
    }

    ## -------------------------------------------------------------------------
    ## Math operations
    ## -------------------------------------------------------------------------

    # unary
    method neg  { __CLASS__->from_native($native->unary('neg')) }
    method abs  { __CLASS__->from_native($native->unary('abs')) }
    method exp  { __CLASS__->from_native($native->unary('exp')) }
    method log  { __CLASS__->from_native($native->unary('log')) }
    method sqrt { __CLASS__->from_native($native->unary('sqrt')) }

    # binary
    method add ($other) { __CLASS__->from_native($native->binary(native_operand($other), 'add')) }
    method sub ($other) { __CLASS__->from_native($native->binary(native_operand($other), 'sub')) }
    method mul ($other) { __CLASS__->from_native($native->binary(native_operand($other), 'mul')) }
    method div ($other) { __CLASS__->from_native($native->binary(native_operand($other), 'div')) }
    method mod ($other) { __CLASS__->from_native($native->binary(native_operand($other), 'mod')) }
    method pow ($other) { __CLASS__->from_native($native->binary(native_operand($other), 'pow')) }

    ## -------------------------------------------------------------------------
    ## Comparison Operations
    ## -------------------------------------------------------------------------

    # binary
    method eq  ($other) { __CLASS__->from_native($native->binary(native_operand($other), 'eq')) }
    method ne  ($other) { __CLASS__->from_native($native->binary(native_operand($other), 'ne')) }
    method lt  ($other) { __CLASS__->from_native($native->binary(native_operand($other), 'lt')) }
    method le  ($other) { __CLASS__->from_native($native->binary(native_operand($other), 'le')) }
    method gt  ($other) { __CLASS__->from_native($native->binary(native_operand($other), 'gt')) }
    method ge  ($other) { __CLASS__->from_native($native->binary(native_operand($other), 'ge')) }
    method cmp ($other) { __CLASS__->from_native($native->binary(native_operand($other), 'cmp')) }

    ## -------------------------------------------------------------------------
    ## Logical Operations
    ## -------------------------------------------------------------------------

    method not { __CLASS__->from_native($native->unary('not')) }
    method and ($other) { __CLASS__->from_native($native->binary(native_operand($other), 'and')) }
    method or  ($other) { __CLASS__->from_native($native->binary(native_operand($other), 'or')) }

    ## -------------------------------------------------------------------------
    ## Numerical Operations
    ## -------------------------------------------------------------------------

    # unary
    method trunc { __CLASS__->from_native($native->unary('trunc')) }
    method fract { __CLASS__->from_native($native->unary('fract')) }

    method round_down { __CLASS__->from_native($native->unary('floor')) }
    method round_up   { __CLASS__->from_native($native->unary('ceil')) }

    method clamp ($min, $max) {
        $self->max($min)->min($max)
    }

    # binary
    method min ($other) { __CLASS__->from_native($native->binary(native_operand($other), 'min')) }
    method max ($other) { __CLASS__->from_native($native->binary(native_operand($other), 'max')) }

    ## -------------------------------------------------------------------------
    ## Activation Functions
    ## -------------------------------------------------------------------------

    method sigmoid {
        # sigmoid(x) = 1 / (1 + exp(-x))
        my $one = __CLASS__->ones($self->shape);
        return $one->div($one->add($self->neg->exp));
    }

    method relu {
        # ReLU(x) = max(0, x)
        return $self->max(0);
    }

    method tanh {
        # tanh(x) = (exp(x) - exp(-x)) / (exp(x) + exp(-x))
        my $exp_pos = $self->exp;
        my $exp_neg = $self->neg->exp;
        return $exp_pos->sub($exp_neg)->div($exp_pos->add($exp_neg));
    }

    method softmax {
        # softmax(x) = exp(x) / sum(exp(x))
        # Subtract max for numerical stability
        my $x_shifted = $self->sub($self->max_value);
        my $exp_x = $x_shifted->exp;
        return $exp_x->div($exp_x->sum);
    }

    ## -------------------------------------------------------------------------

    method to_string {
        my $data = $self->data;
        my @strides = $self->strides;
        my @to_draw = @strides;
        my $stride  = pop @to_draw;
        my $step    = pop @to_draw;

        unshift @to_draw => scalar @$data;

        say "rank    : ", $self->rank;
        say "shape   : ", join ', ' => @{ $self->shape };
        say "strides : ", join ', ' => @strides;
        say "to_draw : ", join ', ' => @to_draw;
        say "stride  : ${stride}";
        say "step    : ${step}";

        my @out;
        for (my $i = 0; $i < scalar @$data; $i += $step ) {
            push @out => join '' =>
                (map {
                    ($i == 0)
                        ? '╭─'
                    : (($i + $step) >= scalar @$data)
                        ? '╰─'
                    : ($i % $_) == 0
                        ? '╭─'
                    : (($i + $step) % $_)
                        ? '│ '
                        : '╰─';
                } @to_draw),
                '[ '.(join ' ' => map { sprintf('%3s', $_) } $data->@[ $i .. ($i + ($step - 1)) ]).' ]'
                #' = ('.(join ', ' => $i .. ($i + $stride)).') : step='.$to_draw[-1];
        }

        return join "\n" => @out;
    }
}


package Tensor::Ops {
    use v5.40;

    ## -------------------------------------------------------------------------
    ## Math operations
    ## -------------------------------------------------------------------------

    # unary
    sub neg ($n)     { -$n }
    sub abs ($n)     { abs($n) }
    sub exp ($n)     { CORE::exp($n) }
    sub log ($n)     { CORE::log($n) }
    sub sqrt ($n)    { CORE::sqrt($n) }

    # binary
    sub add ($n, $m) { $n + $m }
    sub sub ($n, $m) { $n - $m }
    sub mul ($n, $m) { $n * $m }
    sub div ($n, $m) { $n / $m }
    sub mod ($n, $m) { $n % $m }
    sub pow ($n, $m) { $n ** $m }

    ## -------------------------------------------------------------------------
    ## Comparison Operations
    ## -------------------------------------------------------------------------

    # binary
    sub eq  ($n, $m) { $n == $m ? 1 : 0 }
    sub ne  ($n, $m) { $n != $m ? 1 : 0 }
    sub lt  ($n, $m) { $n <  $m ? 1 : 0 }
    sub le  ($n, $m) { $n <= $m ? 1 : 0 }
    sub gt  ($n, $m) { $n >  $m ? 1 : 0 }
    sub ge  ($n, $m) { $n >= $m ? 1 : 0 }

    # binary
    sub cmp ($n, $m) { $n <=> $m }

    ## -------------------------------------------------------------------------
    ## Logical Operations
    ## -------------------------------------------------------------------------

    sub not ($n) { !$n ? 1 : 0 }
    sub and ($n, $m) { $n && $m ? 1 : 0 }
    sub or  ($n, $m) { $n || $m ? 1 : 0 }

    ## -------------------------------------------------------------------------
    ## Numerical Operations
    ## -------------------------------------------------------------------------

    # unary
    sub trunc ($n) { int($n) }
    sub fract ($n) { int($n) - $n }

    sub round_down ($n) { floor($n) }
    sub round_up   ($n) { ceil($n) }

    # binary
    sub min ($n, $m) { $n < $m ? $n : $m }
    sub max ($n, $m) { $n > $m ? $n : $m }

    # ternary
    sub clamp ($min, $max, $n) { max($min, min($n, $max)) }

}
