use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Vector;

my $vector = Vector->initialize(2, [ 1, 2 ] );

subtest 'sum method - basic summation' => sub {
    my $v = Vector->initialize(3, [ 1, 2, 3 ] );
    is( $v->sum, 6, 'sum of [1,2,3] is 6' );

    my $v2 = Vector->initialize(4, [ 10, 20, 30, 40 ] );
    is( $v2->sum, 100, 'sum of [10,20,30,40] is 100' );

    my $v3 = Vector->initialize(1, [ 42 ] );
    is( $v3->sum, 42, 'sum of single element [42] is 42' );
};

subtest 'sum method - with negative numbers' => sub {
    my $v = Vector->initialize(3, [ -1, 2, -3 ] );
    is( $v->sum, -2, 'sum of [-1,2,-3] is -2' );

    my $v2 = Vector->initialize(2, [ -10, -20 ] );
    is( $v2->sum, -30, 'sum of [-10,-20] is -30' );

    my $v3 = Vector->initialize(4, [ 1, -1, 1, -1 ] );
    is( $v3->sum, 0, 'sum of [1,-1,1,-1] is 0' );
};

subtest 'sum method - with floating point numbers' => sub {
    my $v = Vector->initialize(3, [ 1.5, 2.5, 3.0 ] );
    is( $v->sum, 7.0, 'sum of [1.5,2.5,3.0] is 7.0' );

    my $v2 = Vector->initialize(2, [ 0.1, 0.2 ] );
    is( $v2->sum, 0.3, 'sum of [0.1,0.2] is 0.3' );
};

subtest 'sum method - edge cases' => sub {
    my $empty = Vector->initialize(0, [] );
    is( $empty->sum, 0, 'sum of empty vector is 0' );

    my $zeros = Vector->initialize(3, [ 0, 0, 0 ] );
    is( $zeros->sum, 0, 'sum of all zeros is 0' );
};

subtest 'dot_product method - basic dot product' => sub {
    my $v1 = Vector->initialize(3, [ 1, 2, 3 ] );
    my $v2 = Vector->initialize(3, [ 4, 5, 6 ] );

    # 1*4 + 2*5 + 3*6 = 4 + 10 + 18 = 32
    is( $v1->dot_product($v2), 32, 'dot product of [1,2,3] and [4,5,6] is 32' );

    my $v3 = Vector->initialize(2, [ 2, 3 ] );
    my $v4 = Vector->initialize(2, [ 1, 4 ] );

    # 2*1 + 3*4 = 2 + 12 = 14
    is( $v3->dot_product($v4), 14, 'dot product of [2,3] and [1,4] is 14' );
};

subtest 'dot_product method - with negative numbers' => sub {
    my $v1 = Vector->initialize(3, [ -1, 2, -3 ] );
    my $v2 = Vector->initialize(3, [ 4, -5, 6 ] );

    # (-1)*4 + 2*(-5) + (-3)*6 = -4 + (-10) + (-18) = -32
    is( $v1->dot_product($v2), -32, 'dot product with negative numbers' );

    my $v3 = Vector->initialize(2, [ -2, -3 ] );
    my $v4 = Vector->initialize(2, [ -1, -4 ] );

    # (-2)*(-1) + (-3)*(-4) = 2 + 12 = 14
    is( $v3->dot_product($v4), 14, 'dot product of two negative vectors' );
};

subtest 'dot_product method - with floating point numbers' => sub {
    my $v1 = Vector->initialize(2, [ 1.5, 2.5 ] );
    my $v2 = Vector->initialize(2, [ 2.0, 3.0 ] );

    # 1.5*2.0 + 2.5*3.0 = 3.0 + 7.5 = 10.5
    is( $v1->dot_product($v2), 10.5, 'dot product with floating point numbers' );
};

subtest 'dot_product method - orthogonal vectors' => sub {
    my $v1 = Vector->initialize(2, [ 1, 0 ] );
    my $v2 = Vector->initialize(2, [ 0, 1 ] );

    # 1*0 + 0*1 = 0
    is( $v1->dot_product($v2), 0, 'dot product of orthogonal vectors is 0' );

    my $v3 = Vector->initialize(3, [ 1, 1, 0 ] );
    my $v4 = Vector->initialize(3, [ 0, 0, 1 ] );

    # 1*0 + 1*0 + 0*1 = 0
    is( $v3->dot_product($v4), 0, 'dot product of 3D orthogonal vectors is 0' );
};

subtest 'dot_product method - same vector' => sub {
    my $v = Vector->initialize(3, [ 2, 3, 4 ] );

    # 2*2 + 3*3 + 4*4 = 4 + 9 + 16 = 29
    is( $v->dot_product($v), 29, 'dot product of vector with itself' );

    my $v2 = Vector->initialize(2, [ 1, 1 ] );
    is( $v2->dot_product($v2), 2, 'dot product of [1,1] with itself is 2' );
};

subtest 'dot_product method - edge cases' => sub {
    my $zeros1 = Vector->initialize(3, [ 0, 0, 0 ] );
    my $zeros2 = Vector->initialize(3, [ 0, 0, 0 ] );

    is( $zeros1->dot_product($zeros2), 0, 'dot product of zero vectors is 0' );

    my $v = Vector->initialize(2, [ 1, 2 ] );
    my $zeros = Vector->initialize(2, [ 0, 0 ] );

    is( $v->dot_product($zeros), 0, 'dot product with zero vector is 0' );
};

done_testing;

__END__
