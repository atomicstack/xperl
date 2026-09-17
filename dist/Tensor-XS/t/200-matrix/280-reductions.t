use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Matrix;

subtest 'sum method - basic summation' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $sum = $m->sum;

    is( $sum, 10, 'sum of [1,2,3,4] is 10' );

    # Test with different values
    my $m2 = Matrix->new( shape => [3, 3], data => [1, 2, 3, 4, 5, 6, 7, 8, 9] );
    my $sum2 = $m2->sum;
    is( $sum2, 45, 'sum of [1..9] is 45' );

    # Test with negative numbers
    my $m3 = Matrix->new( shape => [2, 2], data => [-1, -2, -3, -4] );
    my $sum3 = $m3->sum;
    is( $sum3, -10, 'sum of negative numbers is correct' );

    # Test with mixed signs
    my $m4 = Matrix->new( shape => [2, 2], data => [1, -2, 3, -4] );
    my $sum4 = $m4->sum;
    is( $sum4, -2, 'sum of mixed signs is correct' );
};

subtest 'sum method - with floating point numbers' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1.5, 2.5, 3.5, 4.5] );
    my $sum = $m->sum;

    is( $sum, 12.0, 'sum of floating point numbers is correct' );

    # Test with more precision
    my $m2 = Matrix->new( shape => [2, 2], data => [0.1, 0.2, 0.3, 0.4] );
    my $sum2 = $m2->sum;
    is( $sum2, 1.0, 'sum of small floating point numbers is correct' );
};

subtest 'sum method - edge cases' => sub {
    # Test with zero matrix
    my $zeros = Matrix->new( shape => [2, 2], data => [0, 0, 0, 0] );
    my $sum_zeros = $zeros->sum;
    is( $sum_zeros, 0, 'sum of zero matrix is 0' );

    # Test with single element
    my $single = Matrix->new( shape => [1, 1], data => [42] );
    my $sum_single = $single->sum;
    is( $sum_single, 42, 'sum of single element is the element itself' );

    # Test with larger matrix
    my @data = (1..100);  # 10x10 matrix
    my $large = Matrix->new( shape => [10, 10], data => \@data );
    my $sum_large = $large->sum;
    is( $sum_large, 5050, 'sum of 1..100 is 5050' );
};

subtest 'min_value method - finding minimum value' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [5, 2, 8, 1] );
    my $min = $m->min_value;

    is( $min, 1, 'min_value of [5,2,8,1] is 1' );

    # Test with different values
    my $m2 = Matrix->new( shape => [3, 3], data => [9, 8, 7, 6, 5, 4, 3, 2, 1] );
    my $min2 = $m2->min_value;
    is( $min2, 1, 'min_value of [9..1] is 1' );

    # Test with negative numbers
    my $m3 = Matrix->new( shape => [2, 2], data => [-1, -5, -3, -2] );
    my $min3 = $m3->min_value;
    is( $min3, -5, 'min_value of negative numbers is correct' );

    # Test with mixed signs
    my $m4 = Matrix->new( shape => [2, 2], data => [1, -2, 3, -4] );
    my $min4 = $m4->min_value;
    is( $min4, -4, 'min_value of mixed signs is correct' );
};

subtest 'min_value method - with floating point numbers' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1.5, 2.5, 0.5, 3.5] );
    my $min = $m->min_value;

    is( $min, 0.5, 'min_value of floating point numbers is correct' );

    # Test with negative floating point
    my $m2 = Matrix->new( shape => [2, 2], data => [-1.5, -2.5, -0.5, -3.5] );
    my $min2 = $m2->min_value;
    is( $min2, -3.5, 'min_value of negative floating point numbers is correct' );
};

subtest 'min_value method - edge cases' => sub {
    # Test with all same values
    my $same = Matrix->new( shape => [2, 2], data => [5, 5, 5, 5] );
    my $min_same = $same->min_value;
    is( $min_same, 5, 'min_value of all same values is that value' );

    # Test with single element
    my $single = Matrix->new( shape => [1, 1], data => [42] );
    my $min_single = $single->min_value;
    is( $min_single, 42, 'min_value of single element is the element itself' );

    # Test with zero matrix
    my $zeros = Matrix->new( shape => [2, 2], data => [0, 0, 0, 0] );
    my $min_zeros = $zeros->min_value;
    is( $min_zeros, 0, 'min_value of zero matrix is 0' );
};

subtest 'max_value method - finding maximum value' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [5, 2, 8, 1] );
    my $max = $m->max_value;

    is( $max, 8, 'max_value of [5,2,8,1] is 8' );

    # Test with different values
    my $m2 = Matrix->new( shape => [3, 3], data => [1, 2, 3, 4, 5, 6, 7, 8, 9] );
    my $max2 = $m2->max_value;
    is( $max2, 9, 'max_value of [1..9] is 9' );

    # Test with negative numbers
    my $m3 = Matrix->new( shape => [2, 2], data => [-1, -5, -3, -2] );
    my $max3 = $m3->max_value;
    is( $max3, -1, 'max_value of negative numbers is correct' );

    # Test with mixed signs
    my $m4 = Matrix->new( shape => [2, 2], data => [1, -2, 3, -4] );
    my $max4 = $m4->max_value;
    is( $max4, 3, 'max_value of mixed signs is correct' );
};

subtest 'max_value method - with floating point numbers' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1.5, 2.5, 0.5, 3.5] );
    my $max = $m->max_value;

    is( $max, 3.5, 'max_value of floating point numbers is correct' );

    # Test with negative floating point
    my $m2 = Matrix->new( shape => [2, 2], data => [-1.5, -2.5, -0.5, -3.5] );
    my $max2 = $m2->max_value;
    is( $max2, -0.5, 'max_value of negative floating point numbers is correct' );
};

subtest 'max_value method - edge cases' => sub {
    # Test with all same values
    my $same = Matrix->new( shape => [2, 2], data => [5, 5, 5, 5] );
    my $max_same = $same->max_value;
    is( $max_same, 5, 'max_value of all same values is that value' );

    # Test with single element
    my $single = Matrix->new( shape => [1, 1], data => [42] );
    my $max_single = $single->max_value;
    is( $max_single, 42, 'max_value of single element is the element itself' );

    # Test with zero matrix
    my $zeros = Matrix->new( shape => [2, 2], data => [0, 0, 0, 0] );
    my $max_zeros = $zeros->max_value;
    is( $max_zeros, 0, 'max_value of zero matrix is 0' );
};


done_testing;

__END__
