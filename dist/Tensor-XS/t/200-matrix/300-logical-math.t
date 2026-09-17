use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Matrix;

subtest 'not method - logical not operation' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 0, 2, 0] );
    my $not_result = $m->not;

    isa_ok( $not_result, 'Matrix', 'not returns a Matrix' );
    is( $not_result->rows, 2, 'result has correct rows' );
    is( $not_result->cols, 2, 'result has correct columns' );
    is( $not_result->at(0, 0), 0, 'element at (0,0): !1 is 0' );
    is( $not_result->at(0, 1), 1, 'element at (0,1): !0 is 1' );
    is( $not_result->at(1, 0), 0, 'element at (1,0): !2 is 0' );
    is( $not_result->at(1, 1), 1, 'element at (1,1): !0 is 1' );

    # Test with different values
    my $m2 = Matrix->new( shape => [2, 2], data => [0, 1, 0, 1] );
    my $not_result2 = $m2->not;
    is( $not_result2->at(0, 0), 1, 'element at (0,0): !0 is 1' );
    is( $not_result2->at(0, 1), 0, 'element at (0,1): !1 is 0' );
    is( $not_result2->at(1, 0), 1, 'element at (1,0): !0 is 1' );
    is( $not_result2->at(1, 1), 0, 'element at (1,1): !1 is 0' );
};

subtest 'not method - with floating point numbers' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [0.0, 1.5, 0.0, 2.5] );
    my $not_result = $m->not;

    is( $not_result->at(0, 0), 1, 'floating point: !0.0 is 1' );
    is( $not_result->at(0, 1), 0, 'floating point: !1.5 is 0' );
    is( $not_result->at(1, 0), 1, 'floating point: !0.0 is 1' );
    is( $not_result->at(1, 1), 0, 'floating point: !2.5 is 0' );
};

subtest 'not method - with negative numbers' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [0, -1, 0, -2] );
    my $not_result = $m->not;

    is( $not_result->at(0, 0), 1, 'negative: !0 is 1' );
    is( $not_result->at(0, 1), 0, 'negative: !(-1) is 0' );
    is( $not_result->at(1, 0), 1, 'negative: !0 is 1' );
    is( $not_result->at(1, 1), 0, 'negative: !(-2) is 0' );
};

subtest 'min method - minimum with scalar' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [5, 2, 8, 1] );
    my $min_result = $m->min(3);

    isa_ok( $min_result, 'Matrix', 'min returns a Matrix' );
    is( $min_result->rows, 2, 'result has correct rows' );
    is( $min_result->cols, 2, 'result has correct columns' );
    is( $min_result->at(0, 0), 3, 'element at (0,0): min(5, 3) is 3' );
    is( $min_result->at(0, 1), 2, 'element at (0,1): min(2, 3) is 2' );
    is( $min_result->at(1, 0), 3, 'element at (1,0): min(8, 3) is 3' );
    is( $min_result->at(1, 1), 1, 'element at (1,1): min(1, 3) is 1' );
};

subtest 'min method - minimum with matrix' => sub {
    my $m1 = Matrix->new( shape => [2, 2], data => [5, 2, 8, 1] );
    my $m2 = Matrix->new( shape => [2, 2], data => [3, 4, 2, 6] );
    my $min_result = $m1->min($m2);

    isa_ok( $min_result, 'Matrix', 'min returns a Matrix' );
    is( $min_result->at(0, 0), 3, 'element at (0,0): min(5, 3) is 3' );
    is( $min_result->at(0, 1), 2, 'element at (0,1): min(2, 4) is 2' );
    is( $min_result->at(1, 0), 2, 'element at (1,0): min(8, 2) is 2' );
    is( $min_result->at(1, 1), 1, 'element at (1,1): min(1, 6) is 1' );
};

subtest 'max method - maximum with scalar' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [5, 2, 8, 1] );
    my $max_result = $m->max(3);

    isa_ok( $max_result, 'Matrix', 'max returns a Matrix' );
    is( $max_result->rows, 2, 'result has correct rows' );
    is( $max_result->cols, 2, 'result has correct columns' );
    is( $max_result->at(0, 0), 5, 'element at (0,0): max(5, 3) is 5' );
    is( $max_result->at(0, 1), 3, 'element at (0,1): max(2, 3) is 3' );
    is( $max_result->at(1, 0), 8, 'element at (1,0): max(8, 3) is 8' );
    is( $max_result->at(1, 1), 3, 'element at (1,1): max(1, 3) is 3' );
};

subtest 'max method - maximum with matrix' => sub {
    my $m1 = Matrix->new( shape => [2, 2], data => [5, 2, 8, 1] );
    my $m2 = Matrix->new( shape => [2, 2], data => [3, 4, 2, 6] );
    my $max_result = $m1->max($m2);

    isa_ok( $max_result, 'Matrix', 'max returns a Matrix' );
    is( $max_result->at(0, 0), 5, 'element at (0,0): max(5, 3) is 5' );
    is( $max_result->at(0, 1), 4, 'element at (0,1): max(2, 4) is 4' );
    is( $max_result->at(1, 0), 8, 'element at (1,0): max(8, 2) is 8' );
    is( $max_result->at(1, 1), 6, 'element at (1,1): max(1, 6) is 6' );
};

subtest 'trunc method - truncation operation' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1.7, 2.3, 3.9, 4.1] );
    my $trunc_result = $m->trunc;

    isa_ok( $trunc_result, 'Matrix', 'trunc returns a Matrix' );
    is( $trunc_result->rows, 2, 'result has correct rows' );
    is( $trunc_result->cols, 2, 'result has correct columns' );
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

subtest 'abs method - absolute value operation' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [-1, 2, -3, 4] );
    my $abs_result = $m->abs;

    isa_ok( $abs_result, 'Matrix', 'abs returns a Matrix' );
    is( $abs_result->rows, 2, 'result has correct rows' );
    is( $abs_result->cols, 2, 'result has correct columns' );
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

subtest 'logical and math methods - edge cases' => sub {
    # Test with zero matrix
    my $zeros = Matrix->new( shape => [2, 2], data => [0, 0, 0, 0] );
    my $not_zeros = $zeros->not;
    is( $not_zeros->at(0, 0), 1, 'zero matrix: !0 is 1' );
    is( $not_zeros->at(1, 1), 1, 'zero matrix: !0 is 1' );

    my $abs_zeros = $zeros->abs;
    is( $abs_zeros->at(0, 0), 0, 'zero matrix: abs(0) is 0' );

    my $trunc_zeros = $zeros->trunc;
    is( $trunc_zeros->at(0, 0), 0, 'zero matrix: trunc(0) is 0' );

    # Test with single element
    my $single = Matrix->new( shape => [1, 1], data => [42] );
    my $not_single = $single->not;
    is( $not_single->at(0, 0), 0, 'single element: !42 is 0' );

    my $abs_single = $single->abs;
    is( $abs_single->at(0, 0), 42, 'single element: abs(42) is 42' );

    my $trunc_single = $single->trunc;
    is( $trunc_single->at(0, 0), 42, 'single element: trunc(42) is 42' );

    # Test min/max with single element
    my $min_single = $single->min(50);
    is( $min_single->at(0, 0), 42, 'single element: min(42, 50) is 42' );

    my $max_single = $single->max(30);
    is( $max_single->at(0, 0), 42, 'single element: max(42, 30) is 42' );
};

subtest 'logical and math methods - with larger matrices' => sub {
    my $m = Matrix->new( shape => [3, 3], data => [1, 0, 2, 0, 3, 0, 4, 0, 5] );

    # Test not with larger matrix
    my $not_result = $m->not;
    is( $not_result->at(0, 0), 0, 'larger matrix: !1 is 0' );
    is( $not_result->at(0, 1), 1, 'larger matrix: !0 is 1' );
    is( $not_result->at(1, 1), 0, 'larger matrix: !3 is 0' );
    is( $not_result->at(2, 2), 0, 'larger matrix: !5 is 0' );

    # Test min with larger matrix
    my $min_result = $m->min(2);
    is( $min_result->at(0, 0), 1, 'larger matrix: min(1, 2) is 1' );
    is( $min_result->at(0, 1), 0, 'larger matrix: min(0, 2) is 0' );
    is( $min_result->at(1, 1), 2, 'larger matrix: min(3, 2) is 2' );
    is( $min_result->at(2, 2), 2, 'larger matrix: min(5, 2) is 2' );

    # Test max with larger matrix
    my $max_result = $m->max(2);
    is( $max_result->at(0, 0), 2, 'larger matrix: max(1, 2) is 2' );
    is( $max_result->at(0, 1), 2, 'larger matrix: max(0, 2) is 2' );
    is( $max_result->at(1, 1), 3, 'larger matrix: max(3, 2) is 3' );
    is( $max_result->at(2, 2), 5, 'larger matrix: max(5, 2) is 5' );
};

done_testing;

__END__
