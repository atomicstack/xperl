use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Matrix;
use Vector;

my $matrix = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

subtest 'unary_op method - basic unary operations' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

    # Test negation
    my $negated = $m->unary_op(sub { -$_[0] });
    isa_ok( $negated, 'Matrix', 'unary_op returns a Matrix' );
    is( $negated->rows, 2, 'result has correct number of rows' );
    is( $negated->cols, 2, 'result has correct number of columns' );
    is( $negated->at(0, 0), -1, 'element at (0,0) negated' );
    is( $negated->at(0, 1), -2, 'element at (0,1) negated' );
    is( $negated->at(1, 0), -3, 'element at (1,0) negated' );
    is( $negated->at(1, 1), -4, 'element at (1,1) negated' );

    # Test squaring
    my $squared = $m->unary_op(sub { $_[0] * $_[0] });
    isa_ok( $squared, 'Matrix', 'unary_op returns a Matrix' );
    is( $squared->at(0, 0), 1, 'element at (0,0) squared (1)' );
    is( $squared->at(0, 1), 4, 'element at (0,1) squared (4)' );
    is( $squared->at(1, 0), 9, 'element at (1,0) squared (9)' );
    is( $squared->at(1, 1), 16, 'element at (1,1) squared (16)' );

    # Test absolute value
    my $m2 = Matrix->new( shape => [2, 2], data => [-1, 2, -3, 4] );
    my $abs = $m2->unary_op(sub { abs($_[0]) });
    is( $abs->at(0, 0), 1, 'absolute value of -1 is 1' );
    is( $abs->at(0, 1), 2, 'absolute value of 2 is 2' );
    is( $abs->at(1, 0), 3, 'absolute value of -3 is 3' );
    is( $abs->at(1, 1), 4, 'absolute value of 4 is 4' );
};

subtest 'unary_op method - with floating point operations' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1.5, 2.5, 3.5, 4.5] );

    # Test doubling
    my $doubled = $m->unary_op(sub { $_[0] * 2 });
    is( $doubled->at(0, 0), 3.0, 'doubled element at (0,0)' );
    is( $doubled->at(0, 1), 5.0, 'doubled element at (0,1)' );
    is( $doubled->at(1, 0), 7.0, 'doubled element at (1,0)' );
    is( $doubled->at(1, 1), 9.0, 'doubled element at (1,1)' );

    # Test square root (approximate)
    my $m2 = Matrix->new( shape => [2, 2], data => [4, 9, 16, 25] );
    my $sqrt = $m2->unary_op(sub { sqrt($_[0]) });
    is( $sqrt->at(0, 0), 2, 'square root of 4 is 2' );
    is( $sqrt->at(0, 1), 3, 'square root of 9 is 3' );
    is( $sqrt->at(1, 0), 4, 'square root of 16 is 4' );
    is( $sqrt->at(1, 1), 5, 'square root of 25 is 5' );
};

subtest 'unary_op method - with larger matrices' => sub {
    my $m = Matrix->new( shape => [3, 3], data => [1, 2, 3, 4, 5, 6, 7, 8, 9] );

    # Test negation
    my $negated = $m->unary_op(sub { -$_[0] });
    isa_ok( $negated, 'Matrix', 'unary_op returns a Matrix' );
    is( $negated->rows, 3, 'result has correct number of rows' );
    is( $negated->cols, 3, 'result has correct number of columns' );

    for my $i (0..2) {
        for my $j (0..2) {
            is( $negated->at($i, $j), -$m->at($i, $j), "element at ($i,$j) negated" );
        }
    }

    # Test squaring
    my $squared = $m->unary_op(sub { $_[0] * $_[0] });

    for my $i (0..2) {
        for my $j (0..2) {
            my $expected = $m->at($i, $j) * $m->at($i, $j);
            is( $squared->at($i, $j), $expected, "element at ($i,$j) squared" );
        }
    }
};

subtest 'binary_op method - with scalar values' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

    # Test addition with scalar
    my $added = $m->binary_op(sub { $_[0] + $_[1] }, 5);
    isa_ok( $added, 'Matrix', 'binary_op returns a Matrix' );
    is( $added->rows, 2, 'result has correct number of rows' );
    is( $added->cols, 2, 'result has correct number of columns' );
    is( $added->at(0, 0), 6, 'element at (0,0) + 5 = 6' );
    is( $added->at(0, 1), 7, 'element at (0,1) + 5 = 7' );
    is( $added->at(1, 0), 8, 'element at (1,0) + 5 = 8' );
    is( $added->at(1, 1), 9, 'element at (1,1) + 5 = 9' );

    # Test multiplication with scalar
    my $multiplied = $m->binary_op(sub { $_[0] * $_[1] }, 2);
    is( $multiplied->at(0, 0), 2, 'element at (0,0) * 2 = 2' );
    is( $multiplied->at(0, 1), 4, 'element at (0,1) * 2 = 4' );
    is( $multiplied->at(1, 0), 6, 'element at (1,0) * 2 = 6' );
    is( $multiplied->at(1, 1), 8, 'element at (1,1) * 2 = 8' );

    # Test division with scalar
    my $divided = $m->binary_op(sub { $_[0] / $_[1] }, 2);
    is( $divided->at(0, 0), 0.5, 'element at (0,0) / 2 = 0.5' );
    is( $divided->at(0, 1), 1, 'element at (0,1) / 2 = 1' );
    is( $divided->at(1, 0), 1.5, 'element at (1,0) / 2 = 1.5' );
    is( $divided->at(1, 1), 2, 'element at (1,1) / 2 = 2' );
};

subtest 'binary_op method - with vector' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $v = Vector->initialize(2, [5, 6] );

    # Test addition with vector (applies to each row)
    my $added = $m->binary_op(sub { $_[0] + $_[1] }, $v);
    isa_ok( $added, 'Matrix', 'binary_op returns a Matrix' );
    is( $added->rows, 2, 'result has correct number of rows' );
    is( $added->cols, 2, 'result has correct number of columns' );
    is( $added->at(0, 0), 6, 'element at (0,0) + vector[0] = 6' );
    is( $added->at(0, 1), 8, 'element at (0,1) + vector[1] = 8' );
    is( $added->at(1, 0), 8, 'element at (1,0) + vector[0] = 8' );
    is( $added->at(1, 1), 10, 'element at (1,1) + vector[1] = 10' );

    # Test multiplication with vector
    my $multiplied = $m->binary_op(sub { $_[0] * $_[1] }, $v);
    is( $multiplied->at(0, 0), 5, 'element at (0,0) * vector[0] = 5' );
    is( $multiplied->at(0, 1), 12, 'element at (0,1) * vector[1] = 12' );
    is( $multiplied->at(1, 0), 15, 'element at (1,0) * vector[0] = 15' );
    is( $multiplied->at(1, 1), 24, 'element at (1,1) * vector[1] = 24' );

    # Test subtraction with vector
    my $subtracted = $m->binary_op(sub { $_[0] - $_[1] }, $v);
    is( $subtracted->at(0, 0), -4, 'element at (0,0) - vector[0] = -4' );
    is( $subtracted->at(0, 1), -4, 'element at (0,1) - vector[1] = -4' );
    is( $subtracted->at(1, 0), -2, 'element at (1,0) - vector[0] = -2' );
    is( $subtracted->at(1, 1), -2, 'element at (1,1) - vector[1] = -2' );
};

subtest 'binary_op method - with another matrix' => sub {
    my $m1 = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $m2 = Matrix->new( shape => [2, 2], data => [5, 6, 7, 8] );

    # Test addition with matrix
    my $added = $m1->binary_op(sub { $_[0] + $_[1] }, $m2);
    isa_ok( $added, 'Matrix', 'binary_op returns a Matrix' );
    is( $added->rows, 2, 'result has correct number of rows' );
    is( $added->cols, 2, 'result has correct number of columns' );
    is( $added->at(0, 0), 6, 'element at (0,0): 1 + 5 = 6' );
    is( $added->at(0, 1), 8, 'element at (0,1): 2 + 6 = 8' );
    is( $added->at(1, 0), 10, 'element at (1,0): 3 + 7 = 10' );
    is( $added->at(1, 1), 12, 'element at (1,1): 4 + 8 = 12' );

    # Test multiplication with matrix
    my $multiplied = $m1->binary_op(sub { $_[0] * $_[1] }, $m2);
    is( $multiplied->at(0, 0), 5, 'element at (0,0): 1 * 5 = 5' );
    is( $multiplied->at(0, 1), 12, 'element at (0,1): 2 * 6 = 12' );
    is( $multiplied->at(1, 0), 21, 'element at (1,0): 3 * 7 = 21' );
    is( $multiplied->at(1, 1), 32, 'element at (1,1): 4 * 8 = 32' );

    # Test subtraction with matrix
    my $subtracted = $m1->binary_op(sub { $_[0] - $_[1] }, $m2);
    is( $subtracted->at(0, 0), -4, 'element at (0,0): 1 - 5 = -4' );
    is( $subtracted->at(0, 1), -4, 'element at (0,1): 2 - 6 = -4' );
    is( $subtracted->at(1, 0), -4, 'element at (1,0): 3 - 7 = -4' );
    is( $subtracted->at(1, 1), -4, 'element at (1,1): 4 - 8 = -4' );
};

subtest 'binary_op method - with negative numbers' => sub {
    my $m1 = Matrix->new( shape => [2, 2], data => [-1, 2, -3, 4] );
    my $m2 = Matrix->new( shape => [2, 2], data => [3, -4, 5, -6] );

    # Test addition with negative numbers
    my $added = $m1->binary_op(sub { $_[0] + $_[1] }, $m2);
    is( $added->at(0, 0), 2, 'element at (0,0): -1 + 3 = 2' );
    is( $added->at(0, 1), -2, 'element at (0,1): 2 + (-4) = -2' );
    is( $added->at(1, 0), 2, 'element at (1,0): -3 + 5 = 2' );
    is( $added->at(1, 1), -2, 'element at (1,1): 4 + (-6) = -2' );

    # Test multiplication with negative numbers
    my $multiplied = $m1->binary_op(sub { $_[0] * $_[1] }, $m2);
    is( $multiplied->at(0, 0), -3, 'element at (0,0): -1 * 3 = -3' );
    is( $multiplied->at(0, 1), -8, 'element at (0,1): 2 * (-4) = -8' );
    is( $multiplied->at(1, 0), -15, 'element at (1,0): -3 * 5 = -15' );
    is( $multiplied->at(1, 1), -24, 'element at (1,1): 4 * (-6) = -24' );
};

subtest 'binary_op method - with floating point numbers' => sub {
    my $m1 = Matrix->new( shape => [2, 2], data => [1.5, 2.5, 3.5, 4.5] );
    my $m2 = Matrix->new( shape => [2, 2], data => [2.0, 3.0, 4.0, 5.0] );

    # Test addition with floating point
    my $added = $m1->binary_op(sub { $_[0] + $_[1] }, $m2);
    is( $added->at(0, 0), 3.5, 'element at (0,0): 1.5 + 2.0 = 3.5' );
    is( $added->at(0, 1), 5.5, 'element at (0,1): 2.5 + 3.0 = 5.5' );
    is( $added->at(1, 0), 7.5, 'element at (1,0): 3.5 + 4.0 = 7.5' );
    is( $added->at(1, 1), 9.5, 'element at (1,1): 4.5 + 5.0 = 9.5' );

    # Test division with floating point
    my $divided = $m1->binary_op(sub { $_[0] / $_[1] }, $m2);
    is( $divided->at(0, 0), 0.75, 'element at (0,0): 1.5 / 2.0 = 0.75' );
    is( $divided->at(0, 1), 0.833333333333333, 'element at (0,1): 2.5 / 3.0 ≈ 0.833' );
    is( $divided->at(1, 0), 0.875, 'element at (1,0): 3.5 / 4.0 = 0.875' );
    is( $divided->at(1, 1), 0.9, 'element at (1,1): 4.5 / 5.0 = 0.9' );
};

subtest 'binary_op method - with scalar zero' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

    # Test addition with zero
    my $added = $m->binary_op(sub { $_[0] + $_[1] }, 0);
    for my $i (0..1) {
        for my $j (0..1) {
            is( $added->at($i, $j), $m->at($i, $j), "adding zero preserves original at ($i,$j)" );
        }
    }

    # Test multiplication with zero
    my $multiplied = $m->binary_op(sub { $_[0] * $_[1] }, 0);
    for my $i (0..1) {
        for my $j (0..1) {
            is( $multiplied->at($i, $j), 0, "multiplying by zero gives 0 at ($i,$j)" );
        }
    }
};

subtest 'binary_op method - with zero matrix' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $zeros = Matrix->new( shape => [2, 2], data => [0, 0, 0, 0] );

    # Test addition with zero matrix
    my $added = $m->binary_op(sub { $_[0] + $_[1] }, $zeros);
    for my $i (0..1) {
        for my $j (0..1) {
            is( $added->at($i, $j), $m->at($i, $j), "adding zero matrix preserves original at ($i,$j)" );
        }
    }

    # Test multiplication with zero matrix
    my $multiplied = $m->binary_op(sub { $_[0] * $_[1] }, $zeros);
    for my $i (0..1) {
        for my $j (0..1) {
            is( $multiplied->at($i, $j), 0, "multiplying by zero matrix gives 0 at ($i,$j)" );
        }
    }
};

subtest 'binary_op method - with larger matrices' => sub {
    my $m1 = Matrix->new( shape => [3, 3], data => [1, 2, 3, 4, 5, 6, 7, 8, 9] );
    my $m2 = Matrix->new( shape => [3, 3], data => [2, 3, 4, 5, 6, 7, 8, 9, 10] );

    # Test addition with larger matrices
    my $added = $m1->binary_op(sub { $_[0] + $_[1] }, $m2);
    isa_ok( $added, 'Matrix', 'binary_op returns a Matrix' );
    is( $added->rows, 3, 'result has correct number of rows' );
    is( $added->cols, 3, 'result has correct number of columns' );

    for my $i (0..2) {
        for my $j (0..2) {
            my $expected = $m1->at($i, $j) + $m2->at($i, $j);
            is( $added->at($i, $j), $expected, "element at ($i,$j) added correctly" );
        }
    }

    # Test multiplication with larger matrices
    my $multiplied = $m1->binary_op(sub { $_[0] * $_[1] }, $m2);

    for my $i (0..2) {
        for my $j (0..2) {
            my $expected = $m1->at($i, $j) * $m2->at($i, $j);
            is( $multiplied->at($i, $j), $expected, "element at ($i,$j) multiplied correctly" );
        }
    }
};

subtest 'binary_op method - edge cases' => sub {
    # Test with single element matrix
    my $single1 = Matrix->new( shape => [1, 1], data => [42] );
    my $single2 = Matrix->new( shape => [1, 1], data => [2] );

    my $added = $single1->binary_op(sub { $_[0] + $_[1] }, $single2);
    is( $added->at(0, 0), 44, 'single element matrix addition works' );

    my $multiplied = $single1->binary_op(sub { $_[0] * $_[1] }, 3);
    is( $multiplied->at(0, 0), 126, 'single element matrix scalar multiplication works' );

    # Test with vector of different size (should this work?)
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $v = Vector->initialize(3, [1, 2, 3] );

    # This might cause issues, but let's test the behavior
    # The behavior depends on implementation - might work or might error
    my $error;
    { local $@; eval { $m->binary_op(sub { $_[0] + $_[1] }, $v) }; $error = $@ }
    is $error, '', 'binary_op with mismatched vector size should not die';
};

done_testing;

__END__
