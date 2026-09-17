use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Vector;

subtest 'not method - logical not operation' => sub {
    my $v = Vector->initialize(4, [1, 0, 2, 0] );
    my $not_result = $v->not;

    isa_ok( $not_result, 'Vector', 'not returns a Vector' );
    is( $not_result->size, 4, 'result has correct size' );
    is( $not_result->at(0), 0, 'element at 0: !1 is 0' );
    is( $not_result->at(1), 1, 'element at 1: !0 is 1' );
    is( $not_result->at(2), 0, 'element at 2: !2 is 0' );
    is( $not_result->at(3), 1, 'element at 3: !0 is 1' );

    # Test with different values
    my $v2 = Vector->initialize(4, [0, 1, 0, 1] );
    my $not_result2 = $v2->not;
    is( $not_result2->at(0), 1, 'element at 0: !0 is 1' );
    is( $not_result2->at(1), 0, 'element at 1: !1 is 0' );
    is( $not_result2->at(2), 1, 'element at 2: !0 is 1' );
    is( $not_result2->at(3), 0, 'element at 3: !1 is 0' );
};

subtest 'not method - with floating point numbers' => sub {
    my $v = Vector->initialize(4, [0.0, 1.5, 0.0, 2.5] );
    my $not_result = $v->not;

    is( $not_result->at(0), 1, 'floating point: !0.0 is 1' );
    is( $not_result->at(1), 0, 'floating point: !1.5 is 0' );
    is( $not_result->at(2), 1, 'floating point: !0.0 is 1' );
    is( $not_result->at(3), 0, 'floating point: !2.5 is 0' );
};

subtest 'not method - with negative numbers' => sub {
    my $v = Vector->initialize(4, [0, -1, 0, -2] );
    my $not_result = $v->not;

    is( $not_result->at(0), 1, 'negative: !0 is 1' );
    is( $not_result->at(1), 0, 'negative: !(-1) is 0' );
    is( $not_result->at(2), 1, 'negative: !0 is 1' );
    is( $not_result->at(3), 0, 'negative: !(-2) is 0' );
};

subtest 'min method - minimum with scalar' => sub {
    my $v = Vector->initialize(4, [5, 2, 8, 1] );
    my $min_result = $v->min(3);

    isa_ok( $min_result, 'Vector', 'min returns a Vector' );
    is( $min_result->size, 4, 'result has correct size' );
    is( $min_result->at(0), 3, 'element at 0: min(5, 3) is 3' );
    is( $min_result->at(1), 2, 'element at 1: min(2, 3) is 2' );
    is( $min_result->at(2), 3, 'element at 2: min(8, 3) is 3' );
    is( $min_result->at(3), 1, 'element at 3: min(1, 3) is 1' );
};

subtest 'min method - minimum with vector' => sub {
    my $v1 = Vector->initialize(4, [5, 2, 8, 1] );
    my $v2 = Vector->initialize(4, [3, 4, 2, 6] );
    my $min_result = $v1->min($v2);

    isa_ok( $min_result, 'Vector', 'min returns a Vector' );
    is( $min_result->at(0), 3, 'element at 0: min(5, 3) is 3' );
    is( $min_result->at(1), 2, 'element at 1: min(2, 4) is 2' );
    is( $min_result->at(2), 2, 'element at 2: min(8, 2) is 2' );
    is( $min_result->at(3), 1, 'element at 3: min(1, 6) is 1' );
};

subtest 'max method - maximum with scalar' => sub {
    my $v = Vector->initialize(4, [5, 2, 8, 1] );
    my $max_result = $v->max(3);

    isa_ok( $max_result, 'Vector', 'max returns a Vector' );
    is( $max_result->size, 4, 'result has correct size' );
    is( $max_result->at(0), 5, 'element at 0: max(5, 3) is 5' );
    is( $max_result->at(1), 3, 'element at 1: max(2, 3) is 3' );
    is( $max_result->at(2), 8, 'element at 2: max(8, 3) is 8' );
    is( $max_result->at(3), 3, 'element at 3: max(1, 3) is 3' );
};

subtest 'max method - maximum with vector' => sub {
    my $v1 = Vector->initialize(4, [5, 2, 8, 1] );
    my $v2 = Vector->initialize(4, [3, 4, 2, 6] );
    my $max_result = $v1->max($v2);

    isa_ok( $max_result, 'Vector', 'max returns a Vector' );
    is( $max_result->at(0), 5, 'element at 0: max(5, 3) is 5' );
    is( $max_result->at(1), 4, 'element at 1: max(2, 4) is 4' );
    is( $max_result->at(2), 8, 'element at 2: max(8, 2) is 8' );
    is( $max_result->at(3), 6, 'element at 3: max(1, 6) is 6' );
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

subtest 'logical and math methods - edge cases' => sub {
    # Test with zero vector
    my $zeros = Vector->initialize(4, [0, 0, 0, 0] );
    my $not_zeros = $zeros->not;
    is( $not_zeros->at(0), 1, 'zero vector: !0 is 1' );
    is( $not_zeros->at(3), 1, 'zero vector: !0 is 1' );

    my $abs_zeros = $zeros->abs;
    is( $abs_zeros->at(0), 0, 'zero vector: abs(0) is 0' );

    my $trunc_zeros = $zeros->trunc;
    is( $trunc_zeros->at(0), 0, 'zero vector: trunc(0) is 0' );

    # Test with single element
    my $single = Vector->initialize(1, [42] );
    my $not_single = $single->not;
    is( $not_single->at(0), 0, 'single element: !42 is 0' );

    my $abs_single = $single->abs;
    is( $abs_single->at(0), 42, 'single element: abs(42) is 42' );

    my $trunc_single = $single->trunc;
    is( $trunc_single->at(0), 42, 'single element: trunc(42) is 42' );

    # Test min/max with single element
    my $min_single = $single->min(50);
    is( $min_single->at(0), 42, 'single element: min(42, 50) is 42' );

    my $max_single = $single->max(30);
    is( $max_single->at(0), 42, 'single element: max(42, 30) is 42' );
};

subtest 'logical and math methods - with larger vectors' => sub {
    my $v = Vector->initialize(5, [1, 0, 2, 0, 3] );

    # Test not with larger vector
    my $not_result = $v->not;
    is( $not_result->at(0), 0, 'larger vector: !1 is 0' );
    is( $not_result->at(1), 1, 'larger vector: !0 is 1' );
    is( $not_result->at(2), 0, 'larger vector: !2 is 0' );
    is( $not_result->at(3), 1, 'larger vector: !0 is 1' );
    is( $not_result->at(4), 0, 'larger vector: !3 is 0' );

    # Test min with larger vector
    my $min_result = $v->min(2);
    is( $min_result->at(0), 1, 'larger vector: min(1, 2) is 1' );
    is( $min_result->at(1), 0, 'larger vector: min(0, 2) is 0' );
    is( $min_result->at(2), 2, 'larger vector: min(2, 2) is 2' );
    is( $min_result->at(3), 0, 'larger vector: min(0, 2) is 0' );
    is( $min_result->at(4), 2, 'larger vector: min(3, 2) is 2' );

    # Test max with larger vector
    my $max_result = $v->max(2);
    is( $max_result->at(0), 2, 'larger vector: max(1, 2) is 2' );
    is( $max_result->at(1), 2, 'larger vector: max(0, 2) is 2' );
    is( $max_result->at(2), 2, 'larger vector: max(2, 2) is 2' );
    is( $max_result->at(3), 2, 'larger vector: max(0, 2) is 2' );
    is( $max_result->at(4), 3, 'larger vector: max(3, 2) is 3' );
};

done_testing;

__END__
