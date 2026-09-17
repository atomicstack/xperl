use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Vector;

subtest 'eq method - equality comparison with scalar' => sub {
    my $v = Vector->initialize(4, [1, 2, 3, 4] );

    # Test equality with scalar
    my $eq_result = $v->eq(2);
    isa_ok( $eq_result, 'Vector', 'eq returns a Vector' );
    is( $eq_result->size, 4, 'result has correct size' );
    is( $eq_result->at(0), 0, 'element at 0: 1 == 2 is false (empty string)' );
    is( $eq_result->at(1), 1, 'element at 1: 2 == 2 is true (1)' );
    is( $eq_result->at(2), 0, 'element at 2: 3 == 2 is false (empty string)' );
    is( $eq_result->at(3), 0, 'element at 3: 4 == 2 is false (empty string)' );

    # Test with different scalar
    my $eq_result2 = $v->eq(3);
    is( $eq_result2->at(2), 1, 'element at 2: 3 == 3 is true (1)' );
    is( $eq_result2->at(0), 0, 'element at 0: 1 == 3 is false (empty string)' );
};

subtest 'eq method - equality comparison with vector' => sub {
    my $v1 = Vector->initialize(4, [1, 2, 3, 4] );
    my $v2 = Vector->initialize(4, [1, 2, 3, 4] );
    my $v3 = Vector->initialize(4, [1, 2, 3, 5] );

    # Test equality with identical vector
    my $eq_result = $v1->eq($v2);
    isa_ok( $eq_result, 'Vector', 'eq returns a Vector' );
    is( $eq_result->at(0), 1, 'identical vectors: element at 0 is equal' );
    is( $eq_result->at(1), 1, 'identical vectors: element at 1 is equal' );
    is( $eq_result->at(2), 1, 'identical vectors: element at 2 is equal' );
    is( $eq_result->at(3), 1, 'identical vectors: element at 3 is equal' );

    # Test equality with different vector
    my $eq_result2 = $v1->eq($v3);
    is( $eq_result2->at(0), 1, 'different vectors: element at 0 is equal' );
    is( $eq_result2->at(1), 1, 'different vectors: element at 1 is equal' );
    is( $eq_result2->at(2), 1, 'different vectors: element at 2 is equal' );
    is( $eq_result2->at(3), 0, 'different vectors: element at 3 is not equal' );
};

subtest 'ne method - inequality comparison with scalar' => sub {
    my $v = Vector->initialize(4, [1, 2, 3, 4] );

    # Test inequality with scalar
    my $ne_result = $v->ne(2);
    isa_ok( $ne_result, 'Vector', 'ne returns a Vector' );
    is( $ne_result->at(0), 1, 'element at 0: 1 != 2 is true (1)' );
    is( $ne_result->at(1), 0, 'element at 1: 2 != 2 is false (empty string)' );
    is( $ne_result->at(2), 1, 'element at 2: 3 != 2 is true (1)' );
    is( $ne_result->at(3), 1, 'element at 3: 4 != 2 is true (1)' );
};

subtest 'ne method - inequality comparison with vector' => sub {
    my $v1 = Vector->initialize(4, [1, 2, 3, 4] );
    my $v2 = Vector->initialize(4, [1, 2, 3, 4] );
    my $v3 = Vector->initialize(4, [1, 2, 3, 5] );

    # Test inequality with identical vector
    my $ne_result = $v1->ne($v2);
    is( $ne_result->at(0), 0, 'identical vectors: element at 0 is not unequal' );
    is( $ne_result->at(1), 0, 'identical vectors: element at 1 is not unequal' );
    is( $ne_result->at(2), 0, 'identical vectors: element at 2 is not unequal' );
    is( $ne_result->at(3), 0, 'identical vectors: element at 3 is not unequal' );

    # Test inequality with different vector
    my $ne_result2 = $v1->ne($v3);
    is( $ne_result2->at(0), 0, 'different vectors: element at 0 is not unequal' );
    is( $ne_result2->at(1), 0, 'different vectors: element at 1 is not unequal' );
    is( $ne_result2->at(2), 0, 'different vectors: element at 2 is not unequal' );
    is( $ne_result2->at(3), 1, 'different vectors: element at 3 is unequal' );
};

subtest 'lt method - less than comparison with scalar' => sub {
    my $v = Vector->initialize(4, [1, 2, 3, 4] );

    # Test less than with scalar
    my $lt_result = $v->lt(3);
    isa_ok( $lt_result, 'Vector', 'lt returns a Vector' );
    is( $lt_result->at(0), 1, 'element at 0: 1 < 3 is true (1)' );
    is( $lt_result->at(1), 1, 'element at 1: 2 < 3 is true (1)' );
    is( $lt_result->at(2), 0, 'element at 2: 3 < 3 is false (empty string)' );
    is( $lt_result->at(3), 0, 'element at 3: 4 < 3 is false (empty string)' );
};

subtest 'lt method - less than comparison with vector' => sub {
    my $v1 = Vector->initialize(4, [1, 2, 3, 4] );
    my $v2 = Vector->initialize(4, [2, 3, 4, 5] );

    # Test less than with vector
    my $lt_result = $v1->lt($v2);
    isa_ok( $lt_result, 'Vector', 'lt returns a Vector' );
    is( $lt_result->at(0), 1, 'element at 0: 1 < 2 is true (1)' );
    is( $lt_result->at(1), 1, 'element at 1: 2 < 3 is true (1)' );
    is( $lt_result->at(2), 1, 'element at 2: 3 < 4 is true (1)' );
    is( $lt_result->at(3), 1, 'element at 3: 4 < 5 is true (1)' );
};

subtest 'le method - less than or equal comparison with scalar' => sub {
    my $v = Vector->initialize(4, [1, 2, 3, 4] );

    # Test less than or equal with scalar
    my $le_result = $v->le(3);
    isa_ok( $le_result, 'Vector', 'le returns a Vector' );
    is( $le_result->at(0), 1, 'element at 0: 1 <= 3 is true (1)' );
    is( $le_result->at(1), 1, 'element at 1: 2 <= 3 is true (1)' );
    is( $le_result->at(2), 1, 'element at 2: 3 <= 3 is true (1)' );
    is( $le_result->at(3), 0, 'element at 3: 4 <= 3 is false (empty string)' );
};

subtest 'gt method - greater than comparison with scalar' => sub {
    my $v = Vector->initialize(4, [1, 2, 3, 4] );

    # Test greater than with scalar
    my $gt_result = $v->gt(2);
    isa_ok( $gt_result, 'Vector', 'gt returns a Vector' );
    is( $gt_result->at(0), 0, 'element at 0: 1 > 2 is false (empty string)' );
    is( $gt_result->at(1), 0, 'element at 1: 2 > 2 is false (empty string)' );
    is( $gt_result->at(2), 1, 'element at 2: 3 > 2 is true (1)' );
    is( $gt_result->at(3), 1, 'element at 3: 4 > 2 is true (1)' );
};

subtest 'ge method - greater than or equal comparison with scalar' => sub {
    my $v = Vector->initialize(4, [1, 2, 3, 4] );

    # Test greater than or equal with scalar
    my $ge_result = $v->ge(2);
    isa_ok( $ge_result, 'Vector', 'ge returns a Vector' );
    is( $ge_result->at(0), 0, 'element at 0: 1 >= 2 is false (empty string)' );
    is( $ge_result->at(1), 1, 'element at 1: 2 >= 2 is true (1)' );
    is( $ge_result->at(2), 1, 'element at 2: 3 >= 2 is true (1)' );
    is( $ge_result->at(3), 1, 'element at 3: 4 >= 2 is true (1)' );
};

subtest 'cmp method - comparison with scalar' => sub {
    my $v = Vector->initialize(4, [1, 2, 3, 4] );

    # Test comparison with scalar
    my $cmp_result = $v->cmp(2);
    isa_ok( $cmp_result, 'Vector', 'cmp returns a Vector' );
    is( $cmp_result->at(0), -1, 'element at 0: 1 <=> 2 is -1' );
    is( $cmp_result->at(1), 0, 'element at 1: 2 <=> 2 is 0' );
    is( $cmp_result->at(2), 1, 'element at 2: 3 <=> 2 is 1' );
    is( $cmp_result->at(3), 1, 'element at 3: 4 <=> 2 is 1' );
};

subtest 'cmp method - comparison with vector' => sub {
    my $v1 = Vector->initialize(4, [1, 2, 3, 4] );
    my $v2 = Vector->initialize(4, [2, 2, 2, 5] );

    # Test comparison with vector
    my $cmp_result = $v1->cmp($v2);
    isa_ok( $cmp_result, 'Vector', 'cmp returns a Vector' );
    is( $cmp_result->at(0), -1, 'element at 0: 1 <=> 2 is -1' );
    is( $cmp_result->at(1), 0, 'element at 1: 2 <=> 2 is 0' );
    is( $cmp_result->at(2), 1, 'element at 2: 3 <=> 2 is 1' );
    is( $cmp_result->at(3), -1, 'element at 3: 4 <=> 5 is -1' );
};

subtest 'comparison methods - with floating point numbers' => sub {
    my $v = Vector->initialize(4, [1.5, 2.5, 3.5, 4.5] );

    # Test equality with floating point
    my $eq_result = $v->eq(2.5);
    is( $eq_result->at(0), 0, 'floating point equality: 1.5 == 2.5 is false' );
    is( $eq_result->at(1), 1, 'floating point equality: 2.5 == 2.5 is true' );

    # Test less than with floating point
    my $lt_result = $v->lt(3.0);
    is( $lt_result->at(0), 1, 'floating point less than: 1.5 < 3.0 is true' );
    is( $lt_result->at(2), 0, 'floating point less than: 3.5 < 3.0 is false' );

    # Test greater than with floating point
    my $gt_result = $v->gt(2.0);
    is( $gt_result->at(0), 0, 'floating point greater than: 1.5 > 2.0 is false' );
    is( $gt_result->at(1), 1, 'floating point greater than: 2.5 > 2.0 is true' );
};

subtest 'comparison methods - with negative numbers' => sub {
    my $v = Vector->initialize(4, [-1, -2, -3, -4] );

    # Test less than with negative numbers
    my $lt_result = $v->lt(-2);
    is( $lt_result->at(0), 0, 'negative less than: -1 < -2 is false' );
    is( $lt_result->at(1), 0, 'negative less than: -2 < -2 is false' );
    is( $lt_result->at(2), 1, 'negative less than: -3 < -2 is true' );
    is( $lt_result->at(3), 1, 'negative less than: -4 < -2 is true' );

    # Test greater than with negative numbers
    my $gt_result = $v->gt(-3);
    is( $gt_result->at(0), 1, 'negative greater than: -1 > -3 is true' );
    is( $gt_result->at(1), 1, 'negative greater than: -2 > -3 is true' );
    is( $gt_result->at(2), 0, 'negative greater than: -3 > -3 is false' );
    is( $gt_result->at(3), 0, 'negative greater than: -4 > -3 is false' );
};

subtest 'comparison methods - edge cases' => sub {
    # Test with zero vector
    my $zeros = Vector->initialize(4, [0, 0, 0, 0] );
    my $eq_zero = $zeros->eq(0);
    is( $eq_zero->at(0), 1, 'zero vector equality with 0 is true' );
    is( $eq_zero->at(3), 1, 'zero vector equality with 0 is true' );

    # Test with single element
    my $single = Vector->initialize(1, [42] );
    my $eq_single = $single->eq(42);
    is( $eq_single->at(0), 1, 'single element equality is true' );

    my $lt_single = $single->lt(50);
    is( $lt_single->at(0), 1, 'single element less than is true' );

    # Test with larger vector
    my $large = Vector->initialize(5, [1, 2, 3, 4, 5] );
    my $gt_large = $large->gt(3);
    is( $gt_large->at(2), 0, 'large vector: 3 > 3 is false' );
    is( $gt_large->at(4), 1, 'large vector: 5 > 3 is true' );
};

done_testing;

__END__
