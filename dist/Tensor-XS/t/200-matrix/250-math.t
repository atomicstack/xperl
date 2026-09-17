use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Matrix;
use Vector;

my $matrix = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

subtest 'neg method - negation operation' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $negated = $m->neg;

    isa_ok( $negated, 'Matrix', 'neg returns a Matrix' );
    is( $negated->rows, 2, 'result has correct number of rows' );
    is( $negated->cols, 2, 'result has correct number of columns' );
    is( $negated->at(0, 0), -1, 'element at (0,0) negated' );
    is( $negated->at(0, 1), -2, 'element at (0,1) negated' );
    is( $negated->at(1, 0), -3, 'element at (1,0) negated' );
    is( $negated->at(1, 1), -4, 'element at (1,1) negated' );

    # Test with negative numbers
    my $m2 = Matrix->new( shape => [2, 2], data => [-1, -2, -3, -4] );
    my $negated2 = $m2->neg;
    is( $negated2->at(0, 0), 1, 'negating negative gives positive' );
    is( $negated2->at(0, 1), 2, 'negating negative gives positive' );
    is( $negated2->at(1, 0), 3, 'negating negative gives positive' );
    is( $negated2->at(1, 1), 4, 'negating negative gives positive' );

    # Test with mixed signs
    my $m3 = Matrix->new( shape => [2, 2], data => [-1, 2, -3, 4] );
    my $negated3 = $m3->neg;
    is( $negated3->at(0, 0), 1, 'negating -1 gives 1' );
    is( $negated3->at(0, 1), -2, 'negating 2 gives -2' );
    is( $negated3->at(1, 0), 3, 'negating -3 gives 3' );
    is( $negated3->at(1, 1), -4, 'negating 4 gives -4' );
};

subtest 'neg method - with floating point numbers' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1.5, -2.5, 3.14, -4.2] );
    my $negated = $m->neg;

    is( $negated->at(0, 0), -1.5, 'negating 1.5 gives -1.5' );
    is( $negated->at(0, 1), 2.5, 'negating -2.5 gives 2.5' );
    is( $negated->at(1, 0), -3.14, 'negating 3.14 gives -3.14' );
    is( $negated->at(1, 1), 4.2, 'negating -4.2 gives 4.2' );
};

subtest 'add method - with scalar values' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

    # Test addition with scalar
    my $added = $m->add(5);
    isa_ok( $added, 'Matrix', 'add returns a Matrix' );
    is( $added->rows, 2, 'result has correct number of rows' );
    is( $added->cols, 2, 'result has correct number of columns' );
    is( $added->at(0, 0), 6, 'element at (0,0) + 5 = 6' );
    is( $added->at(0, 1), 7, 'element at (0,1) + 5 = 7' );
    is( $added->at(1, 0), 8, 'element at (1,0) + 5 = 8' );
    is( $added->at(1, 1), 9, 'element at (1,1) + 5 = 9' );

    # Test with negative scalar
    my $added_neg = $m->add(-2);
    is( $added_neg->at(0, 0), -1, 'element at (0,0) + (-2) = -1' );
    is( $added_neg->at(0, 1), 0, 'element at (0,1) + (-2) = 0' );
    is( $added_neg->at(1, 0), 1, 'element at (1,0) + (-2) = 1' );
    is( $added_neg->at(1, 1), 2, 'element at (1,1) + (-2) = 2' );

    # Test with zero
    my $added_zero = $m->add(0);
    is( $added_zero->at(0, 0), 1, 'adding zero preserves original' );
    is( $added_zero->at(0, 1), 2, 'adding zero preserves original' );
    is( $added_zero->at(1, 0), 3, 'adding zero preserves original' );
    is( $added_zero->at(1, 1), 4, 'adding zero preserves original' );
};

subtest 'add method - with another matrix' => sub {
    my $m1 = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $m2 = Matrix->new( shape => [2, 2], data => [5, 6, 7, 8] );

    my $added = $m1->add($m2);
    isa_ok( $added, 'Matrix', 'add returns a Matrix' );
    is( $added->rows, 2, 'result has correct number of rows' );
    is( $added->cols, 2, 'result has correct number of columns' );
    is( $added->at(0, 0), 6, 'element at (0,0): 1 + 5 = 6' );
    is( $added->at(0, 1), 8, 'element at (0,1): 2 + 6 = 8' );
    is( $added->at(1, 0), 10, 'element at (1,0): 3 + 7 = 10' );
    is( $added->at(1, 1), 12, 'element at (1,1): 4 + 8 = 12' );

    # Test with negative numbers
    my $m3 = Matrix->new( shape => [2, 2], data => [-1, -2, -3, -4] );
    my $added_neg = $m1->add($m3);
    is( $added_neg->at(0, 0), 0, 'element at (0,0): 1 + (-1) = 0' );
    is( $added_neg->at(0, 1), 0, 'element at (0,1): 2 + (-2) = 0' );
    is( $added_neg->at(1, 0), 0, 'element at (1,0): 3 + (-3) = 0' );
    is( $added_neg->at(1, 1), 0, 'element at (1,1): 4 + (-4) = 0' );
};

subtest 'add method - with vector' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $v = Vector->initialize(2, [5, 6] );

    my $added = $m->add($v);
    isa_ok( $added, 'Matrix', 'add returns a Matrix' );
    is( $added->rows, 2, 'result has correct number of rows' );
    is( $added->cols, 2, 'result has correct number of columns' );
    is( $added->at(0, 0), 6, 'element at (0,0): 1 + 5 = 6' );
    is( $added->at(0, 1), 8, 'element at (0,1): 2 + 6 = 8' );
    is( $added->at(1, 0), 8, 'element at (1,0): 3 + 5 = 8' );
    is( $added->at(1, 1), 10, 'element at (1,1): 4 + 6 = 10' );
};

subtest 'sub method - with scalar values' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [5, 10, 15, 20] );

    # Test subtraction with scalar
    my $subtracted = $m->sub(2);
    isa_ok( $subtracted, 'Matrix', 'sub returns a Matrix' );
    is( $subtracted->rows, 2, 'result has correct number of rows' );
    is( $subtracted->cols, 2, 'result has correct number of columns' );
    is( $subtracted->at(0, 0), 3, 'element at (0,0) - 2 = 3' );
    is( $subtracted->at(0, 1), 8, 'element at (0,1) - 2 = 8' );
    is( $subtracted->at(1, 0), 13, 'element at (1,0) - 2 = 13' );
    is( $subtracted->at(1, 1), 18, 'element at (1,1) - 2 = 18' );

    # Test with negative scalar (should add)
    my $subtracted_neg = $m->sub(-3);
    is( $subtracted_neg->at(0, 0), 8, 'element at (0,0) - (-3) = 8' );
    is( $subtracted_neg->at(0, 1), 13, 'element at (0,1) - (-3) = 13' );
    is( $subtracted_neg->at(1, 0), 18, 'element at (1,0) - (-3) = 18' );
    is( $subtracted_neg->at(1, 1), 23, 'element at (1,1) - (-3) = 23' );
};

subtest 'sub method - with another matrix' => sub {
    my $m1 = Matrix->new( shape => [2, 2], data => [10, 20, 30, 40] );
    my $m2 = Matrix->new( shape => [2, 2], data => [3, 7, 12, 18] );

    my $subtracted = $m1->sub($m2);
    isa_ok( $subtracted, 'Matrix', 'sub returns a Matrix' );
    is( $subtracted->rows, 2, 'result has correct number of rows' );
    is( $subtracted->cols, 2, 'result has correct number of columns' );
    is( $subtracted->at(0, 0), 7, 'element at (0,0): 10 - 3 = 7' );
    is( $subtracted->at(0, 1), 13, 'element at (0,1): 20 - 7 = 13' );
    is( $subtracted->at(1, 0), 18, 'element at (1,0): 30 - 12 = 18' );
    is( $subtracted->at(1, 1), 22, 'element at (1,1): 40 - 18 = 22' );

    # Test with negative result
    my $m3 = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $m4 = Matrix->new( shape => [2, 2], data => [5, 10, 15, 20] );
    my $subtracted_neg = $m3->sub($m4);
    is( $subtracted_neg->at(0, 0), -4, 'element at (0,0): 1 - 5 = -4' );
    is( $subtracted_neg->at(0, 1), -8, 'element at (0,1): 2 - 10 = -8' );
    is( $subtracted_neg->at(1, 0), -12, 'element at (1,0): 3 - 15 = -12' );
    is( $subtracted_neg->at(1, 1), -16, 'element at (1,1): 4 - 20 = -16' );
};

subtest 'sub method - with vector' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [10, 20, 30, 40] );
    my $v = Vector->initialize(2, [3, 7] );

    my $subtracted = $m->sub($v);
    isa_ok( $subtracted, 'Matrix', 'sub returns a Matrix' );
    is( $subtracted->rows, 2, 'result has correct number of rows' );
    is( $subtracted->cols, 2, 'result has correct number of columns' );
    is( $subtracted->at(0, 0), 7, 'element at (0,0): 10 - 3 = 7' );
    is( $subtracted->at(0, 1), 13, 'element at (0,1): 20 - 7 = 13' );
    is( $subtracted->at(1, 0), 27, 'element at (1,0): 30 - 3 = 27' );
    is( $subtracted->at(1, 1), 33, 'element at (1,1): 40 - 7 = 33' );
};

subtest 'mul method - with scalar values' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [2, 3, 4, 5] );

    # Test multiplication with scalar
    my $multiplied = $m->mul(3);
    isa_ok( $multiplied, 'Matrix', 'mul returns a Matrix' );
    is( $multiplied->rows, 2, 'result has correct number of rows' );
    is( $multiplied->cols, 2, 'result has correct number of columns' );
    is( $multiplied->at(0, 0), 6, 'element at (0,0) * 3 = 6' );
    is( $multiplied->at(0, 1), 9, 'element at (0,1) * 3 = 9' );
    is( $multiplied->at(1, 0), 12, 'element at (1,0) * 3 = 12' );
    is( $multiplied->at(1, 1), 15, 'element at (1,1) * 3 = 15' );

    # Test with negative scalar
    my $multiplied_neg = $m->mul(-2);
    is( $multiplied_neg->at(0, 0), -4, 'element at (0,0) * (-2) = -4' );
    is( $multiplied_neg->at(0, 1), -6, 'element at (0,1) * (-2) = -6' );
    is( $multiplied_neg->at(1, 0), -8, 'element at (1,0) * (-2) = -8' );
    is( $multiplied_neg->at(1, 1), -10, 'element at (1,1) * (-2) = -10' );

    # Test with zero
    my $multiplied_zero = $m->mul(0);
    is( $multiplied_zero->at(0, 0), 0, 'multiplying by zero gives zero' );
    is( $multiplied_zero->at(0, 1), 0, 'multiplying by zero gives zero' );
    is( $multiplied_zero->at(1, 0), 0, 'multiplying by zero gives zero' );
    is( $multiplied_zero->at(1, 1), 0, 'multiplying by zero gives zero' );
};

subtest 'mul method - with another matrix' => sub {
    my $m1 = Matrix->new( shape => [2, 2], data => [2, 3, 4, 5] );
    my $m2 = Matrix->new( shape => [2, 2], data => [6, 7, 8, 9] );

    my $multiplied = $m1->mul($m2);
    isa_ok( $multiplied, 'Matrix', 'mul returns a Matrix' );
    is( $multiplied->rows, 2, 'result has correct number of rows' );
    is( $multiplied->cols, 2, 'result has correct number of columns' );
    is( $multiplied->at(0, 0), 12, 'element at (0,0): 2 * 6 = 12' );
    is( $multiplied->at(0, 1), 21, 'element at (0,1): 3 * 7 = 21' );
    is( $multiplied->at(1, 0), 32, 'element at (1,0): 4 * 8 = 32' );
    is( $multiplied->at(1, 1), 45, 'element at (1,1): 5 * 9 = 45' );

    # Test with negative numbers
    my $m3 = Matrix->new( shape => [2, 2], data => [-1, 2, -3, 4] );
    my $m4 = Matrix->new( shape => [2, 2], data => [3, -4, 5, -6] );
    my $multiplied_neg = $m3->mul($m4);
    is( $multiplied_neg->at(0, 0), -3, 'element at (0,0): -1 * 3 = -3' );
    is( $multiplied_neg->at(0, 1), -8, 'element at (0,1): 2 * (-4) = -8' );
    is( $multiplied_neg->at(1, 0), -15, 'element at (1,0): -3 * 5 = -15' );
    is( $multiplied_neg->at(1, 1), -24, 'element at (1,1): 4 * (-6) = -24' );
};

subtest 'mul method - with vector' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [2, 3, 4, 5] );
    my $v = Vector->initialize(2, [6, 7] );

    my $multiplied = $m->mul($v);
    isa_ok( $multiplied, 'Matrix', 'mul returns a Matrix' );
    is( $multiplied->rows, 2, 'result has correct number of rows' );
    is( $multiplied->cols, 2, 'result has correct number of columns' );
    is( $multiplied->at(0, 0), 12, 'element at (0,0): 2 * 6 = 12' );
    is( $multiplied->at(0, 1), 21, 'element at (0,1): 3 * 7 = 21' );
    is( $multiplied->at(1, 0), 24, 'element at (1,0): 4 * 6 = 24' );
    is( $multiplied->at(1, 1), 35, 'element at (1,1): 5 * 7 = 35' );
};

subtest 'div method - with scalar values' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [6, 9, 12, 15] );

    # Test division with scalar
    my $divided = $m->div(3);
    isa_ok( $divided, 'Matrix', 'div returns a Matrix' );
    is( $divided->rows, 2, 'result has correct number of rows' );
    is( $divided->cols, 2, 'result has correct number of columns' );
    is( $divided->at(0, 0), 2, 'element at (0,0) / 3 = 2' );
    is( $divided->at(0, 1), 3, 'element at (0,1) / 3 = 3' );
    is( $divided->at(1, 0), 4, 'element at (1,0) / 3 = 4' );
    is( $divided->at(1, 1), 5, 'element at (1,1) / 3 = 5' );

    # Test with negative scalar
    my $divided_neg = $m->div(-2);
    is( $divided_neg->at(0, 0), -3, 'element at (0,0) / (-2) = -3' );
    is( $divided_neg->at(0, 1), -4.5, 'element at (0,1) / (-2) = -4.5' );
    is( $divided_neg->at(1, 0), -6, 'element at (1,0) / (-2) = -6' );
    is( $divided_neg->at(1, 1), -7.5, 'element at (1,1) / (-2) = -7.5' );
};

subtest 'div method - with another matrix' => sub {
    my $m1 = Matrix->new( shape => [2, 2], data => [12, 15, 18, 21] );
    my $m2 = Matrix->new( shape => [2, 2], data => [3, 5, 6, 7] );

    my $divided = $m1->div($m2);
    isa_ok( $divided, 'Matrix', 'div returns a Matrix' );
    is( $divided->rows, 2, 'result has correct number of rows' );
    is( $divided->cols, 2, 'result has correct number of columns' );
    is( $divided->at(0, 0), 4, 'element at (0,0): 12 / 3 = 4' );
    is( $divided->at(0, 1), 3, 'element at (0,1): 15 / 5 = 3' );
    is( $divided->at(1, 0), 3, 'element at (1,0): 18 / 6 = 3' );
    is( $divided->at(1, 1), 3, 'element at (1,1): 21 / 7 = 3' );

    # Test with floating point result
    my $m3 = Matrix->new( shape => [2, 2], data => [7, 8, 9, 10] );
    my $m4 = Matrix->new( shape => [2, 2], data => [2, 3, 4, 5] );
    my $divided_float = $m3->div($m4);
    is( $divided_float->at(0, 0), 3.5, 'element at (0,0): 7 / 2 = 3.5' );
    is( $divided_float->at(0, 1), 2.66666666666667, 'element at (0,1): 8 / 3 ≈ 2.667' );
    is( $divided_float->at(1, 0), 2.25, 'element at (1,0): 9 / 4 = 2.25' );
    is( $divided_float->at(1, 1), 2, 'element at (1,1): 10 / 5 = 2' );
};

subtest 'div method - with vector' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [12, 15, 18, 21] );
    my $v = Vector->initialize(2, [3, 5] );

    my $divided = $m->div($v);
    isa_ok( $divided, 'Matrix', 'div returns a Matrix' );
    is( $divided->rows, 2, 'result has correct number of rows' );
    is( $divided->cols, 2, 'result has correct number of columns' );
    is( $divided->at(0, 0), 4, 'element at (0,0): 12 / 3 = 4' );
    is( $divided->at(0, 1), 3, 'element at (0,1): 15 / 5 = 3' );
    is( $divided->at(1, 0), 6, 'element at (1,0): 18 / 3 = 6' );
    is( $divided->at(1, 1), 4.2, 'element at (1,1): 21 / 5 = 4.2' );
};

subtest 'mod method - with scalar values' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [7, 10, 15, 20] );

    # Test modulo with scalar
    my $modded = $m->mod(3);
    isa_ok( $modded, 'Matrix', 'mod returns a Matrix' );
    is( $modded->rows, 2, 'result has correct number of rows' );
    is( $modded->cols, 2, 'result has correct number of columns' );
    is( $modded->at(0, 0), 1, 'element at (0,0) % 3 = 1' );
    is( $modded->at(0, 1), 1, 'element at (0,1) % 3 = 1' );
    is( $modded->at(1, 0), 0, 'element at (1,0) % 3 = 0' );
    is( $modded->at(1, 1), 2, 'element at (1,1) % 3 = 2' );

    # Test with different modulus
    my $modded2 = $m->mod(4);
    is( $modded2->at(0, 0), 3, 'element at (0,0) % 4 = 3' );
    is( $modded2->at(0, 1), 2, 'element at (0,1) % 4 = 2' );
    is( $modded2->at(1, 0), 3, 'element at (1,0) % 4 = 3' );
    is( $modded2->at(1, 1), 0, 'element at (1,1) % 4 = 0' );
};

subtest 'mod method - with another matrix' => sub {
    my $m1 = Matrix->new( shape => [2, 2], data => [10, 15, 20, 25] );
    my $m2 = Matrix->new( shape => [2, 2], data => [3, 4, 6, 7] );

    my $modded = $m1->mod($m2);
    isa_ok( $modded, 'Matrix', 'mod returns a Matrix' );
    is( $modded->rows, 2, 'result has correct number of rows' );
    is( $modded->cols, 2, 'result has correct number of columns' );
    is( $modded->at(0, 0), 1, 'element at (0,0): 10 % 3 = 1' );
    is( $modded->at(0, 1), 3, 'element at (0,1): 15 % 4 = 3' );
    is( $modded->at(1, 0), 2, 'element at (1,0): 20 % 6 = 2' );
    is( $modded->at(1, 1), 4, 'element at (1,1): 25 % 7 = 4' );

    # Test with exact division (remainder 0)
    my $m3 = Matrix->new( shape => [2, 2], data => [12, 15, 18, 21] );
    my $m4 = Matrix->new( shape => [2, 2], data => [3, 5, 6, 7] );
    my $modded_zero = $m3->mod($m4);
    is( $modded_zero->at(0, 0), 0, 'element at (0,0): 12 % 3 = 0' );
    is( $modded_zero->at(0, 1), 0, 'element at (0,1): 15 % 5 = 0' );
    is( $modded_zero->at(1, 0), 0, 'element at (1,0): 18 % 6 = 0' );
    is( $modded_zero->at(1, 1), 0, 'element at (1,1): 21 % 7 = 0' );
};

subtest 'mod method - with vector' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [10, 15, 20, 25] );
    my $v = Vector->initialize(2, [3, 4] );

    my $modded = $m->mod($v);
    isa_ok( $modded, 'Matrix', 'mod returns a Matrix' );
    is( $modded->rows, 2, 'result has correct number of rows' );
    is( $modded->cols, 2, 'result has correct number of columns' );
    is( $modded->at(0, 0), 1, 'element at (0,0): 10 % 3 = 1' );
    is( $modded->at(0, 1), 3, 'element at (0,1): 15 % 4 = 3' );
    is( $modded->at(1, 0), 2, 'element at (1,0): 20 % 3 = 2' );
    is( $modded->at(1, 1), 1, 'element at (1,1): 25 % 4 = 1' );
};

subtest 'math operations - with floating point numbers' => sub {
    my $m1 = Matrix->new( shape => [2, 2], data => [1.5, 2.5, 3.5, 4.5] );
    my $m2 = Matrix->new( shape => [2, 2], data => [2.0, 3.0, 4.0, 5.0] );

    # Test addition with floating point
    my $added = $m1->add($m2);
    is( $added->at(0, 0), 3.5, 'floating point addition: 1.5 + 2.0 = 3.5' );
    is( $added->at(0, 1), 5.5, 'floating point addition: 2.5 + 3.0 = 5.5' );
    is( $added->at(1, 0), 7.5, 'floating point addition: 3.5 + 4.0 = 7.5' );
    is( $added->at(1, 1), 9.5, 'floating point addition: 4.5 + 5.0 = 9.5' );

    # Test multiplication with floating point
    my $multiplied = $m1->mul(2.0);
    is( $multiplied->at(0, 0), 3.0, 'floating point multiplication: 1.5 * 2.0 = 3.0' );
    is( $multiplied->at(0, 1), 5.0, 'floating point multiplication: 2.5 * 2.0 = 5.0' );
    is( $multiplied->at(1, 0), 7.0, 'floating point multiplication: 3.5 * 2.0 = 7.0' );
    is( $multiplied->at(1, 1), 9.0, 'floating point multiplication: 4.5 * 2.0 = 9.0' );

    # Test division with floating point
    my $divided = $m1->div(0.5);
    is( $divided->at(0, 0), 3.0, 'floating point division: 1.5 / 0.5 = 3.0' );
    is( $divided->at(0, 1), 5.0, 'floating point division: 2.5 / 0.5 = 5.0' );
    is( $divided->at(1, 0), 7.0, 'floating point division: 3.5 / 0.5 = 7.0' );
    is( $divided->at(1, 1), 9.0, 'floating point division: 4.5 / 0.5 = 9.0' );
};

subtest 'math operations - edge cases' => sub {
    # Test with zero matrix
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $zeros = Matrix->new( shape => [2, 2], data => [0, 0, 0, 0] );

    my $added = $m->add($zeros);
    for my $i (0..1) {
        for my $j (0..1) {
            is( $added->at($i, $j), $m->at($i, $j), "adding zero matrix preserves original at ($i,$j)" );
        }
    }

    my $multiplied = $m->mul($zeros);
    for my $i (0..1) {
        for my $j (0..1) {
            is( $multiplied->at($i, $j), 0, "multiplying by zero matrix gives 0 at ($i,$j)" );
        }
    }

    # Test with single element matrix
    my $single = Matrix->new( shape => [1, 1], data => [42] );
    my $negated = $single->neg;
    is( $negated->at(0, 0), -42, 'negating single element works' );

    my $doubled = $single->mul(2);
    is( $doubled->at(0, 0), 84, 'multiplying single element works' );

    # Test with larger matrices
    my $large = Matrix->new( shape => [3, 3], data => [1, 2, 3, 4, 5, 6, 7, 8, 9] );
    my $negated_large = $large->neg;

    for my $i (0..2) {
        for my $j (0..2) {
            is( $negated_large->at($i, $j), -$large->at($i, $j), "negating large matrix at ($i,$j)" );
        }
    }
};

subtest 'abs method - absolute value operation' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [-1, 2, -3, 4] );
    my $abs_result = $m->abs;

    isa_ok( $abs_result, 'Matrix', 'abs returns a Matrix' );
    is( $abs_result->rows, 2, 'result has correct number of rows' );
    is( $abs_result->cols, 2, 'result has correct number of columns' );
    is( $abs_result->at(0, 0), 1, 'element at (0,0): abs(-1) is 1' );
    is( $abs_result->at(0, 1), 2, 'element at (0,1): abs(2) is 2' );
    is( $abs_result->at(1, 0), 3, 'element at (1,0): abs(-3) is 3' );
    is( $abs_result->at(1, 1), 4, 'element at (1,1): abs(4) is 4' );

    # Test with all negative numbers
    my $m2 = Matrix->new( shape => [2, 2], data => [-1, -2, -3, -4] );
    my $abs_result2 = $m2->abs;
    is( $abs_result2->at(0, 0), 1, 'all negative: abs(-1) is 1' );
    is( $abs_result2->at(0, 1), 2, 'all negative: abs(-2) is 2' );
    is( $abs_result2->at(1, 0), 3, 'all negative: abs(-3) is 3' );
    is( $abs_result2->at(1, 1), 4, 'all negative: abs(-4) is 4' );
};

subtest 'abs method - with floating point numbers' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [-1.5, 2.5, -3.5, 4.5] );
    my $abs_result = $m->abs;

    is( $abs_result->at(0, 0), 1.5, 'floating point: abs(-1.5) is 1.5' );
    is( $abs_result->at(0, 1), 2.5, 'floating point: abs(2.5) is 2.5' );
    is( $abs_result->at(1, 0), 3.5, 'floating point: abs(-3.5) is 3.5' );
    is( $abs_result->at(1, 1), 4.5, 'floating point: abs(4.5) is 4.5' );
};

subtest 'trunc method - truncation operation' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1.7, 2.3, 3.9, 4.1] );
    my $trunc_result = $m->trunc;

    isa_ok( $trunc_result, 'Matrix', 'trunc returns a Matrix' );
    is( $trunc_result->rows, 2, 'result has correct number of rows' );
    is( $trunc_result->cols, 2, 'result has correct number of columns' );
    is( $trunc_result->at(0, 0), 1, 'element at (0,0): trunc(1.7) is 1' );
    is( $trunc_result->at(0, 1), 2, 'element at (0,1): trunc(2.3) is 2' );
    is( $trunc_result->at(1, 0), 3, 'element at (1,0): trunc(3.9) is 3' );
    is( $trunc_result->at(1, 1), 4, 'element at (1,1): trunc(4.1) is 4' );

    # Test with negative numbers
    my $m2 = Matrix->new( shape => [2, 2], data => [-1.7, -2.3, -3.9, -4.1] );
    my $trunc_result2 = $m2->trunc;
    is( $trunc_result2->at(0, 0), -1, 'negative: trunc(-1.7) is -1' );
    is( $trunc_result2->at(0, 1), -2, 'negative: trunc(-2.3) is -2' );
    is( $trunc_result2->at(1, 0), -3, 'negative: trunc(-3.9) is -3' );
    is( $trunc_result2->at(1, 1), -4, 'negative: trunc(-4.1) is -4' );
};

subtest 'trunc method - with integers' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $trunc_result = $m->trunc;

    is( $trunc_result->at(0, 0), 1, 'integer: trunc(1) is 1' );
    is( $trunc_result->at(0, 1), 2, 'integer: trunc(2) is 2' );
    is( $trunc_result->at(1, 0), 3, 'integer: trunc(3) is 3' );
    is( $trunc_result->at(1, 1), 4, 'integer: trunc(4) is 4' );
};

done_testing;

__END__
