use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Vector;

my $vector = Vector->initialize(2, [ 1, 2 ] );

subtest 'neg method - negation operation' => sub {
    my $v = Vector->initialize(3, [ 1, 2, 3 ] );
    my $negated = $v->neg;

    isa_ok( $negated, 'Vector', 'neg returns a Vector' );
    is( $negated->size, 3, 'result has correct size' );
    is( $negated->at(0), -1, 'first element negated' );
    is( $negated->at(1), -2, 'second element negated' );
    is( $negated->at(2), -3, 'third element negated' );

    # Test with negative numbers
    my $v2 = Vector->initialize(3, [ -1, -2, -3 ] );
    my $negated2 = $v2->neg;
    is( $negated2->at(0), 1, 'negating negative gives positive' );
    is( $negated2->at(1), 2, 'negating negative gives positive' );
    is( $negated2->at(2), 3, 'negating negative gives positive' );

    # Test with mixed signs
    my $v3 = Vector->initialize(3, [ -1, 2, -3 ] );
    my $negated3 = $v3->neg;
    is( $negated3->at(0), 1, 'negating -1 gives 1' );
    is( $negated3->at(1), -2, 'negating 2 gives -2' );
    is( $negated3->at(2), 3, 'negating -3 gives 3' );
};

subtest 'neg method - with floating point numbers' => sub {
    my $v = Vector->initialize(3, [ 1.5, -2.5, 3.14 ] );
    my $negated = $v->neg;

    is( $negated->at(0), -1.5, 'negating 1.5 gives -1.5' );
    is( $negated->at(1), 2.5, 'negating -2.5 gives 2.5' );
    is( $negated->at(2), -3.14, 'negating 3.14 gives -3.14' );
};

subtest 'add method - with scalar values' => sub {
    my $v = Vector->initialize(3, [ 1, 2, 3 ] );

    # Test addition with scalar
    my $added = $v->add(5);
    isa_ok( $added, 'Vector', 'add returns a Vector' );
    is( $added->size, 3, 'result has correct size' );
    is( $added->at(0), 6, 'first element + 5 = 6' );
    is( $added->at(1), 7, 'second element + 5 = 7' );
    is( $added->at(2), 8, 'third element + 5 = 8' );

    # Test with negative scalar
    my $added_neg = $v->add(-2);
    is( $added_neg->at(0), -1, 'first element + (-2) = -1' );
    is( $added_neg->at(1), 0, 'second element + (-2) = 0' );
    is( $added_neg->at(2), 1, 'third element + (-2) = 1' );

    # Test with zero
    my $added_zero = $v->add(0);
    is( $added_zero->at(0), 1, 'adding zero preserves original' );
    is( $added_zero->at(1), 2, 'adding zero preserves original' );
    is( $added_zero->at(2), 3, 'adding zero preserves original' );
};

subtest 'add method - with another vector' => sub {
    my $v1 = Vector->initialize(3, [ 1, 2, 3 ] );
    my $v2 = Vector->initialize(3, [ 4, 5, 6 ] );

    my $added = $v1->add($v2);
    isa_ok( $added, 'Vector', 'add returns a Vector' );
    is( $added->size, 3, 'result has correct size' );
    is( $added->at(0), 5, 'first elements: 1 + 4 = 5' );
    is( $added->at(1), 7, 'second elements: 2 + 5 = 7' );
    is( $added->at(2), 9, 'third elements: 3 + 6 = 9' );

    # Test with negative numbers
    my $v3 = Vector->initialize(3, [ -1, -2, -3 ] );
    my $added_neg = $v1->add($v3);
    is( $added_neg->at(0), 0, 'first elements: 1 + (-1) = 0' );
    is( $added_neg->at(1), 0, 'second elements: 2 + (-2) = 0' );
    is( $added_neg->at(2), 0, 'third elements: 3 + (-3) = 0' );
};

subtest 'sub method - with scalar values' => sub {
    my $v = Vector->initialize(3, [ 5, 10, 15 ] );

    # Test subtraction with scalar
    my $subtracted = $v->sub(2);
    isa_ok( $subtracted, 'Vector', 'sub returns a Vector' );
    is( $subtracted->size, 3, 'result has correct size' );
    is( $subtracted->at(0), 3, 'first element - 2 = 3' );
    is( $subtracted->at(1), 8, 'second element - 2 = 8' );
    is( $subtracted->at(2), 13, 'third element - 2 = 13' );

    # Test with negative scalar (should add)
    my $subtracted_neg = $v->sub(-3);
    is( $subtracted_neg->at(0), 8, 'first element - (-3) = 8' );
    is( $subtracted_neg->at(1), 13, 'second element - (-3) = 13' );
    is( $subtracted_neg->at(2), 18, 'third element - (-3) = 18' );
};

subtest 'sub method - with another vector' => sub {
    my $v1 = Vector->initialize(3, [ 10, 20, 30 ] );
    my $v2 = Vector->initialize(3, [ 3, 7, 12 ] );

    my $subtracted = $v1->sub($v2);
    isa_ok( $subtracted, 'Vector', 'sub returns a Vector' );
    is( $subtracted->size, 3, 'result has correct size' );
    is( $subtracted->at(0), 7, 'first elements: 10 - 3 = 7' );
    is( $subtracted->at(1), 13, 'second elements: 20 - 7 = 13' );
    is( $subtracted->at(2), 18, 'third elements: 30 - 12 = 18' );

    # Test with negative result
    my $v3 = Vector->initialize(3, [ 1, 2, 3 ] );
    my $v4 = Vector->initialize(3, [ 5, 10, 15 ] );
    my $subtracted_neg = $v3->sub($v4);
    is( $subtracted_neg->at(0), -4, 'first elements: 1 - 5 = -4' );
    is( $subtracted_neg->at(1), -8, 'second elements: 2 - 10 = -8' );
    is( $subtracted_neg->at(2), -12, 'third elements: 3 - 15 = -12' );
};

subtest 'mul method - with scalar values' => sub {
    my $v = Vector->initialize(3, [ 2, 3, 4 ] );

    # Test multiplication with scalar
    my $multiplied = $v->mul(3);
    isa_ok( $multiplied, 'Vector', 'mul returns a Vector' );
    is( $multiplied->size, 3, 'result has correct size' );
    is( $multiplied->at(0), 6, 'first element * 3 = 6' );
    is( $multiplied->at(1), 9, 'second element * 3 = 9' );
    is( $multiplied->at(2), 12, 'third element * 3 = 12' );

    # Test with negative scalar
    my $multiplied_neg = $v->mul(-2);
    is( $multiplied_neg->at(0), -4, 'first element * (-2) = -4' );
    is( $multiplied_neg->at(1), -6, 'second element * (-2) = -6' );
    is( $multiplied_neg->at(2), -8, 'third element * (-2) = -8' );

    # Test with zero
    my $multiplied_zero = $v->mul(0);
    is( $multiplied_zero->at(0), 0, 'multiplying by zero gives zero' );
    is( $multiplied_zero->at(1), 0, 'multiplying by zero gives zero' );
    is( $multiplied_zero->at(2), 0, 'multiplying by zero gives zero' );
};

subtest 'mul method - with another vector' => sub {
    my $v1 = Vector->initialize(3, [ 2, 3, 4 ] );
    my $v2 = Vector->initialize(3, [ 5, 6, 7 ] );

    my $multiplied = $v1->mul($v2);
    isa_ok( $multiplied, 'Vector', 'mul returns a Vector' );
    is( $multiplied->size, 3, 'result has correct size' );
    is( $multiplied->at(0), 10, 'first elements: 2 * 5 = 10' );
    is( $multiplied->at(1), 18, 'second elements: 3 * 6 = 18' );
    is( $multiplied->at(2), 28, 'third elements: 4 * 7 = 28' );

    # Test with negative numbers
    my $v3 = Vector->initialize(3, [ -1, 2, -3 ] );
    my $v4 = Vector->initialize(3, [ 4, -5, 6 ] );
    my $multiplied_neg = $v3->mul($v4);
    is( $multiplied_neg->at(0), -4, 'first elements: -1 * 4 = -4' );
    is( $multiplied_neg->at(1), -10, 'second elements: 2 * (-5) = -10' );
    is( $multiplied_neg->at(2), -18, 'third elements: -3 * 6 = -18' );
};

subtest 'div method - with scalar values' => sub {
    my $v = Vector->initialize(3, [ 6, 9, 12 ] );

    # Test division with scalar
    my $divided = $v->div(3);
    isa_ok( $divided, 'Vector', 'div returns a Vector' );
    is( $divided->size, 3, 'result has correct size' );
    is( $divided->at(0), 2, 'first element / 3 = 2' );
    is( $divided->at(1), 3, 'second element / 3 = 3' );
    is( $divided->at(2), 4, 'third element / 3 = 4' );

    # Test with negative scalar
    my $divided_neg = $v->div(-2);
    is( $divided_neg->at(0), -3, 'first element / (-2) = -3' );
    is( $divided_neg->at(1), -4.5, 'second element / (-2) = -4.5' );
    is( $divided_neg->at(2), -6, 'third element / (-2) = -6' );
};

subtest 'div method - with another vector' => sub {
    my $v1 = Vector->initialize(3, [ 12, 15, 18 ] );
    my $v2 = Vector->initialize(3, [ 3, 5, 6 ] );

    my $divided = $v1->div($v2);
    isa_ok( $divided, 'Vector', 'div returns a Vector' );
    is( $divided->size, 3, 'result has correct size' );
    is( $divided->at(0), 4, 'first elements: 12 / 3 = 4' );
    is( $divided->at(1), 3, 'second elements: 15 / 5 = 3' );
    is( $divided->at(2), 3, 'third elements: 18 / 6 = 3' );

    # Test with floating point result
    my $v3 = Vector->initialize(3, [ 7, 8, 9 ] );
    my $v4 = Vector->initialize(3, [ 2, 3, 4 ] );
    my $divided_float = $v3->div($v4);
    is( $divided_float->at(0), 3.5, 'first elements: 7 / 2 = 3.5' );
    is( $divided_float->at(1), 2.66666666666667, 'second elements: 8 / 3 ≈ 2.667' );
    is( $divided_float->at(2), 2.25, 'third elements: 9 / 4 = 2.25' );
};

subtest 'mod method - with scalar values' => sub {
    my $v = Vector->initialize(3, [ 7, 10, 15 ] );

    # Test modulo with scalar
    my $modded = $v->mod(3);
    isa_ok( $modded, 'Vector', 'mod returns a Vector' );
    is( $modded->size, 3, 'result has correct size' );
    is( $modded->at(0), 1, 'first element % 3 = 1' );
    is( $modded->at(1), 1, 'second element % 3 = 1' );
    is( $modded->at(2), 0, 'third element % 3 = 0' );

    # Test with different modulus
    my $modded2 = $v->mod(4);
    is( $modded2->at(0), 3, 'first element % 4 = 3' );
    is( $modded2->at(1), 2, 'second element % 4 = 2' );
    is( $modded2->at(2), 3, 'third element % 4 = 3' );
};

subtest 'mod method - with another vector' => sub {
    my $v1 = Vector->initialize(3, [ 10, 15, 20 ] );
    my $v2 = Vector->initialize(3, [ 3, 4, 6 ] );

    my $modded = $v1->mod($v2);
    isa_ok( $modded, 'Vector', 'mod returns a Vector' );
    is( $modded->size, 3, 'result has correct size' );
    is( $modded->at(0), 1, 'first elements: 10 % 3 = 1' );
    is( $modded->at(1), 3, 'second elements: 15 % 4 = 3' );
    is( $modded->at(2), 2, 'third elements: 20 % 6 = 2' );

    # Test with exact division (remainder 0)
    my $v3 = Vector->initialize(3, [ 12, 15, 18 ] );
    my $v4 = Vector->initialize(3, [ 3, 5, 6 ] );
    my $modded_zero = $v3->mod($v4);
    is( $modded_zero->at(0), 0, 'first elements: 12 % 3 = 0' );
    is( $modded_zero->at(1), 0, 'second elements: 15 % 5 = 0' );
    is( $modded_zero->at(2), 0, 'third elements: 18 % 6 = 0' );
};

subtest 'math operations - with floating point numbers' => sub {
    my $v1 = Vector->initialize(2, [ 1.5, 2.5 ] );
    my $v2 = Vector->initialize(2, [ 0.5, 1.5 ] );

    # Test addition with floating point
    my $added = $v1->add($v2);
    is( $added->at(0), 2.0, 'floating point addition: 1.5 + 0.5 = 2.0' );
    is( $added->at(1), 4.0, 'floating point addition: 2.5 + 1.5 = 4.0' );

    # Test multiplication with floating point
    my $multiplied = $v1->mul(2.0);
    is( $multiplied->at(0), 3.0, 'floating point multiplication: 1.5 * 2.0 = 3.0' );
    is( $multiplied->at(1), 5.0, 'floating point multiplication: 2.5 * 2.0 = 5.0' );

    # Test division with floating point
    my $divided = $v1->div(0.5);
    is( $divided->at(0), 3.0, 'floating point division: 1.5 / 0.5 = 3.0' );
    is( $divided->at(1), 5.0, 'floating point division: 2.5 / 0.5 = 5.0' );
};

subtest 'math operations - edge cases' => sub {
    # Test with zero vector
    my $v = Vector->initialize(3, [ 1, 2, 3 ] );
    my $zeros = Vector->initialize(3, [ 0, 0, 0 ] );

    my $added = $v->add($zeros);
    is( $added->at(0), 1, 'adding zero vector preserves original' );
    is( $added->at(1), 2, 'adding zero vector preserves original' );
    is( $added->at(2), 3, 'adding zero vector preserves original' );

    my $multiplied = $v->mul($zeros);
    is( $multiplied->at(0), 0, 'multiplying by zero vector gives zero' );
    is( $multiplied->at(1), 0, 'multiplying by zero vector gives zero' );
    is( $multiplied->at(2), 0, 'multiplying by zero vector gives zero' );

    # Test with single element vector
    my $single = Vector->initialize(1, [ 42 ] );
    my $negated = $single->neg;
    is( $negated->at(0), -42, 'negating single element works' );

    my $doubled = $single->mul(2);
    is( $doubled->at(0), 84, 'multiplying single element works' );
};

subtest 'abs method - absolute value operation' => sub {
    my $v = Vector->initialize(4, [-1, 2, -3, 4] );
    my $abs_result = $v->abs;

    isa_ok( $abs_result, 'Vector', 'abs returns a Vector' );
    is( $abs_result->size, 4, 'result has correct size' );
    is( $abs_result->at(0), 1, 'element at 0: abs(-1) is 1' );
    is( $abs_result->at(1), 2, 'element at 1: abs(2) is 2' );
    is( $abs_result->at(2), 3, 'element at 2: abs(-3) is 3' );
    is( $abs_result->at(3), 4, 'element at 3: abs(4) is 4' );

    # Test with all negative numbers
    my $v2 = Vector->initialize(4, [-1, -2, -3, -4] );
    my $abs_result2 = $v2->abs;
    is( $abs_result2->at(0), 1, 'all negative: abs(-1) is 1' );
    is( $abs_result2->at(1), 2, 'all negative: abs(-2) is 2' );
    is( $abs_result2->at(2), 3, 'all negative: abs(-3) is 3' );
    is( $abs_result2->at(3), 4, 'all negative: abs(-4) is 4' );
};

subtest 'abs method - with floating point numbers' => sub {
    my $v = Vector->initialize(4, [-1.5, 2.5, -3.5, 4.5] );
    my $abs_result = $v->abs;

    is( $abs_result->at(0), 1.5, 'floating point: abs(-1.5) is 1.5' );
    is( $abs_result->at(1), 2.5, 'floating point: abs(2.5) is 2.5' );
    is( $abs_result->at(2), 3.5, 'floating point: abs(-3.5) is 3.5' );
    is( $abs_result->at(3), 4.5, 'floating point: abs(4.5) is 4.5' );
};

subtest 'trunc method - truncation operation' => sub {
    my $v = Vector->initialize(4, [1.7, 2.3, 3.9, 4.1] );
    my $trunc_result = $v->trunc;

    isa_ok( $trunc_result, 'Vector', 'trunc returns a Vector' );
    is( $trunc_result->size, 4, 'result has correct size' );
    is( $trunc_result->at(0), 1, 'element at 0: trunc(1.7) is 1' );
    is( $trunc_result->at(1), 2, 'element at 1: trunc(2.3) is 2' );
    is( $trunc_result->at(2), 3, 'element at 2: trunc(3.9) is 3' );
    is( $trunc_result->at(3), 4, 'element at 3: trunc(4.1) is 4' );

    # Test with negative numbers
    my $v2 = Vector->initialize(4, [-1.7, -2.3, -3.9, -4.1] );
    my $trunc_result2 = $v2->trunc;
    is( $trunc_result2->at(0), -1, 'negative: trunc(-1.7) is -1' );
    is( $trunc_result2->at(1), -2, 'negative: trunc(-2.3) is -2' );
    is( $trunc_result2->at(2), -3, 'negative: trunc(-3.9) is -3' );
    is( $trunc_result2->at(3), -4, 'negative: trunc(-4.1) is -4' );
};

subtest 'trunc method - with integers' => sub {
    my $v = Vector->initialize(4, [1, 2, 3, 4] );
    my $trunc_result = $v->trunc;

    is( $trunc_result->at(0), 1, 'integer: trunc(1) is 1' );
    is( $trunc_result->at(1), 2, 'integer: trunc(2) is 2' );
    is( $trunc_result->at(2), 3, 'integer: trunc(3) is 3' );
    is( $trunc_result->at(3), 4, 'integer: trunc(4) is 4' );
};

done_testing;

__END__
