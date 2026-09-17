use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Matrix;

subtest 'eq method - equality comparison with scalar' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

    # Test equality with scalar
    my $eq_result = $m->eq(2);
    isa_ok( $eq_result, 'Matrix', 'eq returns a Matrix' );
    is( $eq_result->rows, 2, 'result has correct rows' );
    is( $eq_result->cols, 2, 'result has correct columns' );
    is( $eq_result->at(0, 0), 0, 'element at (0,0): 1 == 2 is false (empty string)' );
    is( $eq_result->at(0, 1), 1, 'element at (0,1): 2 == 2 is true (1)' );
    is( $eq_result->at(1, 0), 0, 'element at (1,0): 3 == 2 is false (empty string)' );
    is( $eq_result->at(1, 1), 0, 'element at (1,1): 4 == 2 is false (empty string)' );

    # Test with different scalar
    my $eq_result2 = $m->eq(3);
    is( $eq_result2->at(1, 0), 1, 'element at (1,0): 3 == 3 is true (1)' );
    is( $eq_result2->at(0, 0), 0, 'element at (0,0): 1 == 3 is false (empty string)' );
};

subtest 'eq method - equality comparison with matrix' => sub {
    my $m1 = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $m2 = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $m3 = Matrix->new( shape => [2, 2], data => [1, 2, 3, 5] );

    # Test equality with identical matrix
    my $eq_result = $m1->eq($m2);
    isa_ok( $eq_result, 'Matrix', 'eq returns a Matrix' );
    is( $eq_result->at(0, 0), 1, 'identical matrices: element at (0,0) is equal' );
    is( $eq_result->at(0, 1), 1, 'identical matrices: element at (0,1) is equal' );
    is( $eq_result->at(1, 0), 1, 'identical matrices: element at (1,0) is equal' );
    is( $eq_result->at(1, 1), 1, 'identical matrices: element at (1,1) is equal' );

    # Test equality with different matrix
    my $eq_result2 = $m1->eq($m3);
    is( $eq_result2->at(0, 0), 1, 'different matrices: element at (0,0) is equal' );
    is( $eq_result2->at(0, 1), 1, 'different matrices: element at (0,1) is equal' );
    is( $eq_result2->at(1, 0), 1, 'different matrices: element at (1,0) is equal' );
    is( $eq_result2->at(1, 1), 0, 'different matrices: element at (1,1) is not equal' );
};

subtest 'ne method - inequality comparison with scalar' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

    # Test inequality with scalar
    my $ne_result = $m->ne(2);
    isa_ok( $ne_result, 'Matrix', 'ne returns a Matrix' );
    is( $ne_result->at(0, 0), 1, 'element at (0,0): 1 != 2 is true (1)' );
    is( $ne_result->at(0, 1), 0, 'element at (0,1): 2 != 2 is false (empty string)' );
    is( $ne_result->at(1, 0), 1, 'element at (1,0): 3 != 2 is true (1)' );
    is( $ne_result->at(1, 1), 1, 'element at (1,1): 4 != 2 is true (1)' );
};

subtest 'ne method - inequality comparison with matrix' => sub {
    my $m1 = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $m2 = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $m3 = Matrix->new( shape => [2, 2], data => [1, 2, 3, 5] );

    # Test inequality with identical matrix
    my $ne_result = $m1->ne($m2);
    is( $ne_result->at(0, 0), 0, 'identical matrices: element at (0,0) is not unequal' );
    is( $ne_result->at(0, 1), 0, 'identical matrices: element at (0,1) is not unequal' );
    is( $ne_result->at(1, 0), 0, 'identical matrices: element at (1,0) is not unequal' );
    is( $ne_result->at(1, 1), 0, 'identical matrices: element at (1,1) is not unequal' );

    # Test inequality with different matrix
    my $ne_result2 = $m1->ne($m3);
    is( $ne_result2->at(0, 0), 0, 'different matrices: element at (0,0) is not unequal' );
    is( $ne_result2->at(0, 1), 0, 'different matrices: element at (0,1) is not unequal' );
    is( $ne_result2->at(1, 0), 0, 'different matrices: element at (1,0) is not unequal' );
    is( $ne_result2->at(1, 1), 1, 'different matrices: element at (1,1) is unequal' );
};

subtest 'lt method - less than comparison with scalar' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

    # Test less than with scalar
    my $lt_result = $m->lt(3);
    isa_ok( $lt_result, 'Matrix', 'lt returns a Matrix' );
    is( $lt_result->at(0, 0), 1, 'element at (0,0): 1 < 3 is true (1)' );
    is( $lt_result->at(0, 1), 1, 'element at (0,1): 2 < 3 is true (1)' );
    is( $lt_result->at(1, 0), 0, 'element at (1,0): 3 < 3 is false (empty string)' );
    is( $lt_result->at(1, 1), 0, 'element at (1,1): 4 < 3 is false (empty string)' );
};

subtest 'lt method - less than comparison with matrix' => sub {
    my $m1 = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $m2 = Matrix->new( shape => [2, 2], data => [2, 3, 4, 5] );

    # Test less than with matrix
    my $lt_result = $m1->lt($m2);
    isa_ok( $lt_result, 'Matrix', 'lt returns a Matrix' );
    is( $lt_result->at(0, 0), 1, 'element at (0,0): 1 < 2 is true (1)' );
    is( $lt_result->at(0, 1), 1, 'element at (0,1): 2 < 3 is true (1)' );
    is( $lt_result->at(1, 0), 1, 'element at (1,0): 3 < 4 is true (1)' );
    is( $lt_result->at(1, 1), 1, 'element at (1,1): 4 < 5 is true (1)' );
};

subtest 'le method - less than or equal comparison with scalar' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

    # Test less than or equal with scalar
    my $le_result = $m->le(3);
    isa_ok( $le_result, 'Matrix', 'le returns a Matrix' );
    is( $le_result->at(0, 0), 1, 'element at (0,0): 1 <= 3 is true (1)' );
    is( $le_result->at(0, 1), 1, 'element at (0,1): 2 <= 3 is true (1)' );
    is( $le_result->at(1, 0), 1, 'element at (1,0): 3 <= 3 is true (1)' );
    is( $le_result->at(1, 1), 0, 'element at (1,1): 4 <= 3 is false (empty string)' );
};

subtest 'gt method - greater than comparison with scalar' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

    # Test greater than with scalar
    my $gt_result = $m->gt(2);
    isa_ok( $gt_result, 'Matrix', 'gt returns a Matrix' );
    is( $gt_result->at(0, 0), 0, 'element at (0,0): 1 > 2 is false (empty string)' );
    is( $gt_result->at(0, 1), 0, 'element at (0,1): 2 > 2 is false (empty string)' );
    is( $gt_result->at(1, 0), 1, 'element at (1,0): 3 > 2 is true (1)' );
    is( $gt_result->at(1, 1), 1, 'element at (1,1): 4 > 2 is true (1)' );
};

subtest 'ge method - greater than or equal comparison with scalar' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

    # Test greater than or equal with scalar
    my $ge_result = $m->ge(2);
    isa_ok( $ge_result, 'Matrix', 'ge returns a Matrix' );
    is( $ge_result->at(0, 0), 0, 'element at (0,0): 1 >= 2 is false (empty string)' );
    is( $ge_result->at(0, 1), 1, 'element at (0,1): 2 >= 2 is true (1)' );
    is( $ge_result->at(1, 0), 1, 'element at (1,0): 3 >= 2 is true (1)' );
    is( $ge_result->at(1, 1), 1, 'element at (1,1): 4 >= 2 is true (1)' );
};

subtest 'cmp method - comparison with scalar' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

    # Test comparison with scalar
    my $cmp_result = $m->cmp(2);
    isa_ok( $cmp_result, 'Matrix', 'cmp returns a Matrix' );
    is( $cmp_result->at(0, 0), -1, 'element at (0,0): 1 <=> 2 is -1' );
    is( $cmp_result->at(0, 1), 0, 'element at (0,1): 2 <=> 2 is 0' );
    is( $cmp_result->at(1, 0), 1, 'element at (1,0): 3 <=> 2 is 1' );
    is( $cmp_result->at(1, 1), 1, 'element at (1,1): 4 <=> 2 is 1' );
};

subtest 'cmp method - comparison with matrix' => sub {
    my $m1 = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $m2 = Matrix->new( shape => [2, 2], data => [2, 2, 2, 5] );

    # Test comparison with matrix
    my $cmp_result = $m1->cmp($m2);
    isa_ok( $cmp_result, 'Matrix', 'cmp returns a Matrix' );
    is( $cmp_result->at(0, 0), -1, 'element at (0,0): 1 <=> 2 is -1' );
    is( $cmp_result->at(0, 1), 0, 'element at (0,1): 2 <=> 2 is 0' );
    is( $cmp_result->at(1, 0), 1, 'element at (1,0): 3 <=> 2 is 1' );
    is( $cmp_result->at(1, 1), -1, 'element at (1,1): 4 <=> 5 is -1' );
};

subtest 'comparison methods - with floating point numbers' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1.5, 2.5, 3.5, 4.5] );

    # Test equality with floating point
    my $eq_result = $m->eq(2.5);
    is( $eq_result->at(0, 0), 0, 'floating point equality: 1.5 == 2.5 is false' );
    is( $eq_result->at(0, 1), 1, 'floating point equality: 2.5 == 2.5 is true' );

    # Test less than with floating point
    my $lt_result = $m->lt(3.0);
    is( $lt_result->at(0, 0), 1, 'floating point less than: 1.5 < 3.0 is true' );
    is( $lt_result->at(1, 0), 0, 'floating point less than: 3.5 < 3.0 is false' );

    # Test greater than with floating point
    my $gt_result = $m->gt(2.0);
    is( $gt_result->at(0, 0), 0, 'floating point greater than: 1.5 > 2.0 is false' );
    is( $gt_result->at(0, 1), 1, 'floating point greater than: 2.5 > 2.0 is true' );
};

subtest 'comparison methods - with negative numbers' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [-1, -2, -3, -4] );

    # Test less than with negative numbers
    my $lt_result = $m->lt(-2);
    is( $lt_result->at(0, 0), 0, 'negative less than: -1 < -2 is false' );
    is( $lt_result->at(0, 1), 0, 'negative less than: -2 < -2 is false' );
    is( $lt_result->at(1, 0), 1, 'negative less than: -3 < -2 is true' );
    is( $lt_result->at(1, 1), 1, 'negative less than: -4 < -2 is true' );

    # Test greater than with negative numbers
    my $gt_result = $m->gt(-3);
    is( $gt_result->at(0, 0), 1, 'negative greater than: -1 > -3 is true' );
    is( $gt_result->at(0, 1), 1, 'negative greater than: -2 > -3 is true' );
    is( $gt_result->at(1, 0), 0, 'negative greater than: -3 > -3 is false' );
    is( $gt_result->at(1, 1), 0, 'negative greater than: -4 > -3 is false' );
};

subtest 'comparison methods - edge cases' => sub {
    # Test with zero matrix
    my $zeros = Matrix->new( shape => [2, 2], data => [0, 0, 0, 0] );
    my $eq_zero = $zeros->eq(0);
    is( $eq_zero->at(0, 0), 1, 'zero matrix equality with 0 is true' );
    is( $eq_zero->at(1, 1), 1, 'zero matrix equality with 0 is true' );

    # Test with single element
    my $single = Matrix->new( shape => [1, 1], data => [42] );
    my $eq_single = $single->eq(42);
    is( $eq_single->at(0, 0), 1, 'single element equality is true' );

    my $lt_single = $single->lt(50);
    is( $lt_single->at(0, 0), 1, 'single element less than is true' );

    # Test with larger matrix
    my $large = Matrix->new( shape => [3, 3], data => [1, 2, 3, 4, 5, 6, 7, 8, 9] );
    my $gt_large = $large->gt(5);
    is( $gt_large->at(1, 1), 0, 'large matrix: 5 > 5 is false' );
    is( $gt_large->at(2, 2), 1, 'large matrix: 9 > 5 is true' );
};

done_testing;

__END__
