use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Vector;
use Matrix;

## Vector

subtest 'reduce_data_array method - basic reduction operations' => sub {
    my $v = Vector->initialize(4, [ 1, 2, 3, 4 ] );

    # Test sum reduction
    my $sum = $v->reduce_data_array(sub { $_[0] + $_[1] }, 0);
    is( $sum, 10, 'reduce_data_array with addition gives sum (10)' );

    # Test product reduction
    my $product = $v->reduce_data_array(sub { $_[0] * $_[1] }, 1);
    is( $product, 24, 'reduce_data_array with multiplication gives product (24)' );

    # Test max reduction
    my $max = $v->reduce_data_array(sub { $_[0] > $_[1] ? $_[0] : $_[1] }, 0);
    is( $max, 4, 'reduce_data_array with max gives maximum (4)' );

    # Test min reduction
    my $min = $v->reduce_data_array(sub { $_[0] < $_[1] ? $_[0] : $_[1] }, 999);
    is( $min, 1, 'reduce_data_array with min gives minimum (1)' );
};

subtest 'reduce_data_array method - with different initial values' => sub {
    my $v = Vector->initialize(3, [ 2, 3, 4 ] );

    # Test with different initial values for sum
    is( $v->reduce_data_array(sub { $_[0] + $_[1] }, 0), 9, 'reduce_data_array with initial 0' );
    is( $v->reduce_data_array(sub { $_[0] + $_[1] }, 10), 19, 'reduce_data_array with initial 10' );
    is( $v->reduce_data_array(sub { $_[0] + $_[1] }, -5), 4, 'reduce_data_array with initial -5' );

    # Test with different initial values for product
    is( $v->reduce_data_array(sub { $_[0] * $_[1] }, 1), 24, 'reduce_data_array product with initial 1' );
    is( $v->reduce_data_array(sub { $_[0] * $_[1] }, 2), 48, 'reduce_data_array product with initial 2' );
};

subtest 'reduce_data_array method - with floating point numbers' => sub {
    my $v = Vector->initialize(3, [ 1.5, 2.5, 3.5 ] );

    my $sum = $v->reduce_data_array(sub { $_[0] + $_[1] }, 0.0);
    is( $sum, 7.5, 'reduce_data_array with floating point numbers' );

    my $product = $v->reduce_data_array(sub { $_[0] * $_[1] }, 1.0);
    is( $product, 13.125, 'reduce_data_array product with floating point numbers' );
};

subtest 'reduce_data_array method - edge cases' => sub {
    # Test with single element
    my $single = Vector->initialize(1, [ 42 ] );
    is( $single->reduce_data_array(sub { $_[0] + $_[1] }, 0), 42, 'reduce_data_array single element' );

    # Test with empty vector
    my $empty = Vector->initialize(0, [] );
    is( $empty->reduce_data_array(sub { $_[0] + $_[1] }, 100), 100, 'reduce_data_array empty vector returns initial' );

    # Test with zeros
    my $zeros = Vector->initialize(3, [ 0, 0, 0 ] );
    is( $zeros->reduce_data_array(sub { $_[0] + $_[1] }, 0), 0, 'reduce_data_array zeros gives 0' );
};

subtest 'reduce_data_array method - custom reduction operations' => sub {
    my $v = Vector->initialize(4, [1, 2, 3, 4] );

    # Test multiplication reduction
    my $product = $v->reduce_data_array(sub { $_[0] * $_[1] }, 1);
    is( $product, 24, 'reduce_data_array with multiplication gives 1*2*3*4 = 24' );

    # Test string concatenation
    my $concat = $v->reduce_data_array(sub { $_[0] . $_[1] }, '');
    is( $concat, '1234', 'reduce_data_array with concatenation gives "1234"' );

    # Test finding maximum with reduce_data_array
    my $max_reduce_data_array = $v->reduce_data_array(sub { $_[0] > $_[1] ? $_[0] : $_[1] }, 0);
    is( $max_reduce_data_array, 4, 'reduce_data_array to find maximum gives 4' );

    # Test finding minimum with reduce_data_array
    my $min_reduce_data_array = $v->reduce_data_array(sub { $_[0] < $_[1] ? $_[0] : $_[1] }, 999);
    is( $min_reduce_data_array, 1, 'reduce_data_array to find minimum gives 1' );
};

subtest 'reduce_data_array method - with different initial values' => sub {
    my $v = Vector->initialize(4, [2, 3, 4, 5] );

    # Test addition with different initial values
    my $sum_0 = $v->reduce_data_array(sub { $_[0] + $_[1] }, 0);
    is( $sum_0, 14, 'reduce_data_array with initial 0 gives sum 14' );

    my $sum_10 = $v->reduce_data_array(sub { $_[0] + $_[1] }, 10);
    is( $sum_10, 24, 'reduce_data_array with initial 10 gives sum 24' );

    # Test multiplication with different initial values
    my $prod_1 = $v->reduce_data_array(sub { $_[0] * $_[1] }, 1);
    is( $prod_1, 120, 'reduce_data_array with initial 1 gives product 120' );

    my $prod_2 = $v->reduce_data_array(sub { $_[0] * $_[1] }, 2);
    is( $prod_2, 240, 'reduce_data_array with initial 2 gives product 240' );
};

subtest 'reduce_data_array method - edge cases' => sub {
    # Test with single element
    my $single = Vector->initialize(1, [42] );
    my $result = $single->reduce_data_array(sub { $_[0] + $_[1] }, 0);
    is( $result, 42, 'reduce_data_array on single element works correctly' );

    # Test with zero vector
    my $zeros = Vector->initialize(4, [0, 0, 0, 0] );
    my $sum_zeros = $zeros->reduce_data_array(sub { $_[0] + $_[1] }, 0);
    is( $sum_zeros, 0, 'reduce_data_array on zero vector works correctly' );

    # Test with floating point
    my $float = Vector->initialize(4, [1.5, 2.5, 3.5, 4.5] );
    my $sum_float = $float->reduce_data_array(sub { $_[0] + $_[1] }, 0);
    is( $sum_float, 12.0, 'reduce_data_array with floating point works correctly' );
};

## Matrix

subtest 'reduce method - custom reduction operations' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

    # Test multiplication reduction
    my $product = $m->reduce_data_array(sub { $_[0] * $_[1] }, 1);
    is( $product, 24, 'reduce with multiplication gives 1*2*3*4 = 24' );

    # Test string concatenation
    my $concat = $m->reduce_data_array(sub { $_[0] . $_[1] }, '');
    is( $concat, '1234', 'reduce with concatenation gives "1234"' );

    # Test finding maximum with reduce
    my $max_reduce = $m->reduce_data_array(sub { $_[0] > $_[1] ? $_[0] : $_[1] }, 0);
    is( $max_reduce, 4, 'reduce to find maximum gives 4' );

    # Test finding minimum with reduce
    my $min_reduce = $m->reduce_data_array(sub { $_[0] < $_[1] ? $_[0] : $_[1] }, 999);
    is( $min_reduce, 1, 'reduce to find minimum gives 1' );
};

subtest 'reduce method - with different initial values' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [2, 3, 4, 5] );

    # Test addition with different initial values
    my $sum_0 = $m->reduce_data_array(sub { $_[0] + $_[1] }, 0);
    is( $sum_0, 14, 'reduce with initial 0 gives sum 14' );

    my $sum_10 = $m->reduce_data_array(sub { $_[0] + $_[1] }, 10);
    is( $sum_10, 24, 'reduce with initial 10 gives sum 24' );

    # Test multiplication with different initial values
    my $prod_1 = $m->reduce_data_array(sub { $_[0] * $_[1] }, 1);
    is( $prod_1, 120, 'reduce with initial 1 gives product 120' );

    my $prod_2 = $m->reduce_data_array(sub { $_[0] * $_[1] }, 2);
    is( $prod_2, 240, 'reduce with initial 2 gives product 240' );
};

subtest 'reduce method - edge cases' => sub {
    # Test with single element
    my $single = Matrix->new( shape => [1, 1], data => [42] );
    my $result = $single->reduce_data_array(sub { $_[0] + $_[1] }, 0);
    is( $result, 42, 'reduce on single element works correctly' );

    # Test with zero matrix
    my $zeros = Matrix->new( shape => [2, 2], data => [0, 0, 0, 0] );
    my $sum_zeros = $zeros->reduce_data_array(sub { $_[0] + $_[1] }, 0);
    is( $sum_zeros, 0, 'reduce on zero matrix works correctly' );

    # Test with floating point
    my $float = Matrix->new( shape => [2, 2], data => [1.5, 2.5, 3.5, 4.5] );
    my $sum_float = $float->reduce_data_array(sub { $_[0] + $_[1] }, 0);
    is( $sum_float, 12.0, 'reduce with floating point works correctly' );
};

done_testing;

__END__
