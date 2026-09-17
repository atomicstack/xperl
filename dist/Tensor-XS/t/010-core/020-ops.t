use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Vector;

subtest 'unary_op method - basic unary operations' => sub {
    my $v = Vector->initialize(3, [ 1, 2, 3 ] );

    # Test negation
    my $negated = $v->unary_op(sub { -$_[0] });
    isa_ok( $negated, 'Vector', 'unary_op returns a Vector' );
    is( $negated->size, 3, 'result has correct size' );
    is( $negated->at(0), -1, 'first element negated' );
    is( $negated->at(1), -2, 'second element negated' );
    is( $negated->at(2), -3, 'third element negated' );

    # Test squaring
    my $squared = $v->unary_op(sub { $_[0] * $_[0] });
    isa_ok( $squared, 'Vector', 'unary_op returns a Vector' );
    is( $squared->at(0), 1, 'first element squared (1)' );
    is( $squared->at(1), 4, 'second element squared (4)' );
    is( $squared->at(2), 9, 'third element squared (9)' );

    # Test absolute value
    my $v2 = Vector->initialize(3, [ -1, 2, -3 ] );
    my $abs = $v2->unary_op(sub { abs($_[0]) });
    is( $abs->at(0), 1, 'absolute value of -1 is 1' );
    is( $abs->at(1), 2, 'absolute value of 2 is 2' );
    is( $abs->at(2), 3, 'absolute value of -3 is 3' );
};

subtest 'unary_op method - with floating point operations' => sub {
    my $v = Vector->initialize(3, [ 1.5, 2.5, 3.5 ] );

    # Test doubling
    my $doubled = $v->unary_op(sub { $_[0] * 2 });
    is( $doubled->at(0), 3.0, 'doubled first element' );
    is( $doubled->at(1), 5.0, 'doubled second element' );
    is( $doubled->at(2), 7.0, 'doubled third element' );

    # Test square root (approximate)
    my $v2 = Vector->initialize(3, [ 4, 9, 16 ] );
    my $sqrt = $v2->unary_op(sub { sqrt($_[0]) });
    is( $sqrt->at(0), 2, 'square root of 4 is 2' );
    is( $sqrt->at(1), 3, 'square root of 9 is 3' );
    is( $sqrt->at(2), 4, 'square root of 16 is 4' );
};

subtest 'binary_op method - with scalar values' => sub {
    my $v = Vector->initialize(3, [ 1, 2, 3 ] );

    # Test addition with scalar
    my $added = $v->binary_op(sub { $_[0] + $_[1] }, 5);
    isa_ok( $added, 'Vector', 'binary_op returns a Vector' );
    is( $added->size, 3, 'result has correct size' );
    is( $added->at(0), 6, 'first element + 5 = 6' );
    is( $added->at(1), 7, 'second element + 5 = 7' );
    is( $added->at(2), 8, 'third element + 5 = 8' );

    # Test multiplication with scalar
    my $multiplied = $v->binary_op(sub { $_[0] * $_[1] }, 2);
    is( $multiplied->at(0), 2, 'first element * 2 = 2' );
    is( $multiplied->at(1), 4, 'second element * 2 = 4' );
    is( $multiplied->at(2), 6, 'third element * 2 = 6' );

    # Test division with scalar
    my $divided = $v->binary_op(sub { $_[0] / $_[1] }, 2);
    is( $divided->at(0), 0.5, 'first element / 2 = 0.5' );
    is( $divided->at(1), 1, 'second element / 2 = 1' );
    is( $divided->at(2), 1.5, 'third element / 2 = 1.5' );
};

subtest 'binary_op method - with another vector' => sub {
    my $v1 = Vector->initialize(3, [ 1, 2, 3 ] );
    my $v2 = Vector->initialize(3, [ 4, 5, 6 ] );

    # Test addition with vector
    my $added = $v1->binary_op(sub { $_[0] + $_[1] }, $v2);
    isa_ok( $added, 'Vector', 'binary_op returns a Vector' );
    is( $added->size, 3, 'result has correct size' );
    is( $added->at(0), 5, 'first elements: 1 + 4 = 5' );
    is( $added->at(1), 7, 'second elements: 2 + 5 = 7' );
    is( $added->at(2), 9, 'third elements: 3 + 6 = 9' );

    # Test multiplication with vector
    my $multiplied = $v1->binary_op(sub { $_[0] * $_[1] }, $v2);
    is( $multiplied->at(0), 4, 'first elements: 1 * 4 = 4' );
    is( $multiplied->at(1), 10, 'second elements: 2 * 5 = 10' );
    is( $multiplied->at(2), 18, 'third elements: 3 * 6 = 18' );

    # Test subtraction with vector
    my $subtracted = $v2->binary_op(sub { $_[0] - $_[1] }, $v1);
    is( $subtracted->at(0), 3, 'first elements: 4 - 1 = 3' );
    is( $subtracted->at(1), 3, 'second elements: 5 - 2 = 3' );
    is( $subtracted->at(2), 3, 'third elements: 6 - 3 = 3' );
};

subtest 'binary_op method - with negative numbers' => sub {
    my $v1 = Vector->initialize(3, [ -1, 2, -3 ] );
    my $v2 = Vector->initialize(3, [ 4, -5, 6 ] );

    # Test addition with negative numbers
    my $added = $v1->binary_op(sub { $_[0] + $_[1] }, $v2);
    is( $added->at(0), 3, 'first elements: -1 + 4 = 3' );
    is( $added->at(1), -3, 'second elements: 2 + (-5) = -3' );
    is( $added->at(2), 3, 'third elements: -3 + 6 = 3' );

    # Test multiplication with negative numbers
    my $multiplied = $v1->binary_op(sub { $_[0] * $_[1] }, $v2);
    is( $multiplied->at(0), -4, 'first elements: -1 * 4 = -4' );
    is( $multiplied->at(1), -10, 'second elements: 2 * (-5) = -10' );
    is( $multiplied->at(2), -18, 'third elements: -3 * 6 = -18' );
};

subtest 'binary_op method - with floating point numbers' => sub {
    my $v1 = Vector->initialize(2, [ 1.5, 2.5 ] );
    my $v2 = Vector->initialize(2, [ 2.0, 3.0 ] );

    # Test addition with floating point
    my $added = $v1->binary_op(sub { $_[0] + $_[1] }, $v2);
    is( $added->at(0), 3.5, 'first elements: 1.5 + 2.0 = 3.5' );
    is( $added->at(1), 5.5, 'second elements: 2.5 + 3.0 = 5.5' );

    # Test division with floating point
    my $divided = $v1->binary_op(sub { $_[0] / $_[1] }, $v2);
    is( $divided->at(0), 0.75, 'first elements: 1.5 / 2.0 = 0.75' );
    is( $divided->at(1), 0.833333333333333, 'second elements: 2.5 / 3.0 ≈ 0.833' );
};

subtest 'binary_op method - edge cases' => sub {
    # Test with zero vector
    my $v = Vector->initialize(3, [ 1, 2, 3 ] );
    my $zeros = Vector->initialize(3, [ 0, 0, 0 ] );

    my $added = $v->binary_op(sub { $_[0] + $_[1] }, $zeros);
    is( $added->at(0), 1, 'adding zero vector preserves original' );
    is( $added->at(1), 2, 'adding zero vector preserves original' );
    is( $added->at(2), 3, 'adding zero vector preserves original' );

    # Test with scalar 0
    my $multiplied = $v->binary_op(sub { $_[0] * $_[1] }, 0);
    is( $multiplied->at(0), 0, 'multiplying by 0 gives 0' );
    is( $multiplied->at(1), 0, 'multiplying by 0 gives 0' );
    is( $multiplied->at(2), 0, 'multiplying by 0 gives 0' );
};

done_testing;

__END__
