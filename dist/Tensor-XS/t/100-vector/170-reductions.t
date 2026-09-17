use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Vector;

subtest 'sum method - basic summation' => sub {
    my $v = Vector->initialize(4, [1, 2, 3, 4] );
    my $sum = $v->sum;

    is( $sum, 10, 'sum of [1,2,3,4] is 10' );

    # Test with different values
    my $v2 = Vector->initialize(5, [1, 2, 3, 4, 5] );
    my $sum2 = $v2->sum;
    is( $sum2, 15, 'sum of [1..5] is 15' );

    # Test with negative numbers
    my $v3 = Vector->initialize(4, [-1, -2, -3, -4] );
    my $sum3 = $v3->sum;
    is( $sum3, -10, 'sum of negative numbers is correct' );

    # Test with mixed signs
    my $v4 = Vector->initialize(4, [1, -2, 3, -4] );
    my $sum4 = $v4->sum;
    is( $sum4, -2, 'sum of mixed signs is correct' );
};

subtest 'sum method - with floating point numbers' => sub {
    my $v = Vector->initialize(4, [1.5, 2.5, 3.5, 4.5] );
    my $sum = $v->sum;

    is( $sum, 12.0, 'sum of floating point numbers is correct' );

    # Test with more precision
    my $v2 = Vector->initialize(4, [0.1, 0.2, 0.3, 0.4] );
    my $sum2 = $v2->sum;
    is( $sum2, 1.0, 'sum of small floating point numbers is correct' );
};

subtest 'sum method - edge cases' => sub {
    # Test with zero vector
    my $zeros = Vector->initialize(4, [0, 0, 0, 0] );
    my $sum_zeros = $zeros->sum;
    is( $sum_zeros, 0, 'sum of zero vector is 0' );

    # Test with single element
    my $single = Vector->initialize(1, [42] );
    my $sum_single = $single->sum;
    is( $sum_single, 42, 'sum of single element is the element itself' );

    # Test with larger vector
    my @data = (1..100);
    my $large = Vector->initialize(100, \@data );
    my $sum_large = $large->sum;
    is( $sum_large, 5050, 'sum of 1..100 is 5050' );
};

subtest 'min_value method - finding minimum value' => sub {
    my $v = Vector->initialize(4, [5, 2, 8, 1] );
    my $min = $v->min_value;

    is( $min, 1, 'min_value of [5,2,8,1] is 1' );

    # Test with different values
    my $v2 = Vector->initialize(5, [9, 8, 7, 6, 5] );
    my $min2 = $v2->min_value;
    is( $min2, 5, 'min_value of [9..5] is 5' );

    # Test with negative numbers
    my $v3 = Vector->initialize(4, [-1, -5, -3, -2] );
    my $min3 = $v3->min_value;
    is( $min3, -5, 'min_value of negative numbers is correct' );

    # Test with mixed signs
    my $v4 = Vector->initialize(4, [1, -2, 3, -4] );
    my $min4 = $v4->min_value;
    is( $min4, -4, 'min_value of mixed signs is correct' );
};

subtest 'min_value method - with floating point numbers' => sub {
    my $v = Vector->initialize(4, [1.5, 2.5, 0.5, 3.5] );
    my $min = $v->min_value;

    is( $min, 0.5, 'min_value of floating point numbers is correct' );

    # Test with negative floating point
    my $v2 = Vector->initialize(4, [-1.5, -2.5, -0.5, -3.5] );
    my $min2 = $v2->min_value;
    is( $min2, -3.5, 'min_value of negative floating point numbers is correct' );
};

subtest 'min_value method - edge cases' => sub {
    # Test with all same values
    my $same = Vector->initialize(4, [5, 5, 5, 5] );
    my $min_same = $same->min_value;
    is( $min_same, 5, 'min_value of all same values is that value' );

    # Test with single element
    my $single = Vector->initialize(1, [42] );
    my $min_single = $single->min_value;
    is( $min_single, 42, 'min_value of single element is the element itself' );

    # Test with zero vector
    my $zeros = Vector->initialize(4, [0, 0, 0, 0] );
    my $min_zeros = $zeros->min_value;
    is( $min_zeros, 0, 'min_value of zero vector is 0' );
};

subtest 'max_value method - finding maximum value' => sub {
    my $v = Vector->initialize(4, [5, 2, 8, 1] );
    my $max = $v->max_value;

    is( $max, 8, 'max_value of [5,2,8,1] is 8' );

    # Test with different values
    my $v2 = Vector->initialize(5, [1, 2, 3, 4, 5] );
    my $max2 = $v2->max_value;
    is( $max2, 5, 'max_value of [1..5] is 5' );

    # Test with negative numbers
    my $v3 = Vector->initialize(4, [-1, -5, -3, -2] );
    my $max3 = $v3->max_value;
    is( $max3, -1, 'max_value of negative numbers is correct' );

    # Test with mixed signs
    my $v4 = Vector->initialize(4, [1, -2, 3, -4] );
    my $max4 = $v4->max_value;
    is( $max4, 3, 'max_value of mixed signs is correct' );
};

subtest 'max_value method - with floating point numbers' => sub {
    my $v = Vector->initialize(4, [1.5, 2.5, 0.5, 3.5] );
    my $max = $v->max_value;

    is( $max, 3.5, 'max_value of floating point numbers is correct' );

    # Test with negative floating point
    my $v2 = Vector->initialize(4, [-1.5, -2.5, -0.5, -3.5] );
    my $max2 = $v2->max_value;
    is( $max2, -0.5, 'max_value of negative floating point numbers is correct' );
};

subtest 'max_value method - edge cases' => sub {
    # Test with all same values
    my $same = Vector->initialize(4, [5, 5, 5, 5] );
    my $max_same = $same->max_value;
    is( $max_same, 5, 'max_value of all same values is that value' );

    # Test with single element
    my $single = Vector->initialize(1, [42] );
    my $max_single = $single->max_value;
    is( $max_single, 42, 'max_value of single element is the element itself' );

    # Test with zero vector
    my $zeros = Vector->initialize(4, [0, 0, 0, 0] );
    my $max_zeros = $zeros->max_value;
    is( $max_zeros, 0, 'max_value of zero vector is 0' );
};


done_testing;

__END__
