use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Tensor;

subtest 'trunc method - truncate to integer part' => sub {
    my $t = Tensor->initialize([5], [1.2, 1.7, -2.3, -2.9, 0.5]);
    my $result = $t->trunc;

    isa_ok( $result, 'Tensor', 'trunc returns a Tensor' );
    is( $result->at(0), 1, 'trunc(1.2) is 1' );
    is( $result->at(1), 1, 'trunc(1.7) is 1' );
    is( $result->at(2), -2, 'trunc(-2.3) is -2' );
    is( $result->at(3), -2, 'trunc(-2.9) is -2' );
    is( $result->at(4), 0, 'trunc(0.5) is 0' );
};

subtest 'trunc method - with integer values' => sub {
    my $t = Tensor->initialize([3], [1, 2, 3]);
    my $result = $t->trunc;

    is( $result->at(0), 1, 'trunc(1) is 1' );
    is( $result->at(1), 2, 'trunc(2) is 2' );
    is( $result->at(2), 3, 'trunc(3) is 3' );
};

subtest 'fract method - fractional part' => sub {
    my $t = Tensor->initialize([5], [1.2, 1.7, -2.3, -2.9, 0.5]);
    my $result = $t->fract;

    isa_ok( $result, 'Tensor', 'fract returns a Tensor' );

    # Note: fract is defined as int($n) - $n, so results are negative for positive numbers
    # fract(1.2) = int(1.2) - 1.2 = 1 - 1.2 = -0.2
    ok( abs($result->at(0) - (-0.2)) < 0.0001, 'fract(1.2) is approximately -0.2' );
    ok( abs($result->at(1) - (-0.7)) < 0.0001, 'fract(1.7) is approximately -0.7' );
    ok( abs($result->at(2) - (0.3)) < 0.0001, 'fract(-2.3) is approximately 0.3' );
    ok( abs($result->at(3) - (0.9)) < 0.0001, 'fract(-2.9) is approximately 0.9' );
    ok( abs($result->at(4) - (-0.5)) < 0.0001, 'fract(0.5) is approximately -0.5' );
};

subtest 'fract method - with integer values' => sub {
    my $t = Tensor->initialize([3], [1, 2, 3]);
    my $result = $t->fract;

    is( $result->at(0), 0, 'fract(1) is 0' );
    is( $result->at(1), 0, 'fract(2) is 0' );
    is( $result->at(2), 0, 'fract(3) is 0' );
};

subtest 'round_down method - floor function' => sub {
    my $t = Tensor->initialize([5], [1.2, 1.7, -2.3, -2.9, 0.5]);
    my $result = $t->round_down;

    isa_ok( $result, 'Tensor', 'round_down returns a Tensor' );
    is( $result->at(0), 1, 'round_down(1.2) is 1' );
    is( $result->at(1), 1, 'round_down(1.7) is 1' );
    is( $result->at(2), -3, 'round_down(-2.3) is -3' );
    is( $result->at(3), -3, 'round_down(-2.9) is -3' );
    is( $result->at(4), 0, 'round_down(0.5) is 0' );
};

subtest 'round_down method - with integer values' => sub {
    my $t = Tensor->initialize([3], [1, 2, 3]);
    my $result = $t->round_down;

    is( $result->at(0), 1, 'round_down(1) is 1' );
    is( $result->at(1), 2, 'round_down(2) is 2' );
    is( $result->at(2), 3, 'round_down(3) is 3' );
};

subtest 'round_up method - ceiling function' => sub {
    my $t = Tensor->initialize([5], [1.2, 1.7, -2.3, -2.9, 0.5]);
    my $result = $t->round_up;

    isa_ok( $result, 'Tensor', 'round_up returns a Tensor' );
    is( $result->at(0), 2, 'round_up(1.2) is 2' );
    is( $result->at(1), 2, 'round_up(1.7) is 2' );
    is( $result->at(2), -2, 'round_up(-2.3) is -2' );
    is( $result->at(3), -2, 'round_up(-2.9) is -2' );
    is( $result->at(4), 1, 'round_up(0.5) is 1' );
};

subtest 'round_up method - with integer values' => sub {
    my $t = Tensor->initialize([3], [1, 2, 3]);
    my $result = $t->round_up;

    is( $result->at(0), 1, 'round_up(1) is 1' );
    is( $result->at(1), 2, 'round_up(2) is 2' );
    is( $result->at(2), 3, 'round_up(3) is 3' );
};

subtest 'clamp method - restricting values to range' => sub {
    my $t = Tensor->initialize([5], [-5, 0, 5, 10, 15]);
    my $result = $t->clamp(0, 10);

    isa_ok( $result, 'Tensor', 'clamp returns a Tensor' );
    is( $result->at(0), 0, 'clamp(-5, 0, 10) is 0' );
    is( $result->at(1), 0, 'clamp(0, 0, 10) is 0' );
    is( $result->at(2), 5, 'clamp(5, 0, 10) is 5' );
    is( $result->at(3), 10, 'clamp(10, 0, 10) is 10' );
    is( $result->at(4), 10, 'clamp(15, 0, 10) is 10' );
};

subtest 'clamp method - with floating point bounds' => sub {
    my $t = Tensor->initialize([5], [-1.5, 0.5, 2.5, 4.5, 6.5]);
    my $result = $t->clamp(1.0, 5.0);

    is( $result->at(0), 1.0, 'clamp(-1.5, 1.0, 5.0) is 1.0' );
    is( $result->at(1), 1.0, 'clamp(0.5, 1.0, 5.0) is 1.0' );
    is( $result->at(2), 2.5, 'clamp(2.5, 1.0, 5.0) is 2.5' );
    is( $result->at(3), 4.5, 'clamp(4.5, 1.0, 5.0) is 4.5' );
    is( $result->at(4), 5.0, 'clamp(6.5, 1.0, 5.0) is 5.0' );
};

subtest 'clamp method - negative range' => sub {
    my $t = Tensor->initialize([5], [-10, -5, 0, 5, 10]);
    my $result = $t->clamp(-5, 5);

    is( $result->at(0), -5, 'clamp(-10, -5, 5) is -5' );
    is( $result->at(1), -5, 'clamp(-5, -5, 5) is -5' );
    is( $result->at(2), 0, 'clamp(0, -5, 5) is 0' );
    is( $result->at(3), 5, 'clamp(5, -5, 5) is 5' );
    is( $result->at(4), 5, 'clamp(10, -5, 5) is 5' );
};

subtest 'min method - element-wise minimum with scalar' => sub {
    my $t = Tensor->initialize([5], [1, 2, 3, 4, 5]);
    my $result = $t->min(3);

    isa_ok( $result, 'Tensor', 'min returns a Tensor' );
    is( $result->at(0), 1, 'min(1, 3) is 1' );
    is( $result->at(1), 2, 'min(2, 3) is 2' );
    is( $result->at(2), 3, 'min(3, 3) is 3' );
    is( $result->at(3), 3, 'min(4, 3) is 3' );
    is( $result->at(4), 3, 'min(5, 3) is 3' );
};

subtest 'min method - element-wise minimum with tensor' => sub {
    my $t1 = Tensor->initialize([5], [1, 5, 3, 7, 2]);
    my $t2 = Tensor->initialize([5], [3, 2, 4, 6, 8]);
    my $result = $t1->min($t2);

    isa_ok( $result, 'Tensor', 'min returns a Tensor' );
    is( $result->at(0), 1, 'min(1, 3) is 1' );
    is( $result->at(1), 2, 'min(5, 2) is 2' );
    is( $result->at(2), 3, 'min(3, 4) is 3' );
    is( $result->at(3), 6, 'min(7, 6) is 6' );
    is( $result->at(4), 2, 'min(2, 8) is 2' );
};

subtest 'min method - with negative numbers' => sub {
    my $t1 = Tensor->initialize([5], [-5, -2, 0, 2, 5]);
    my $t2 = Tensor->initialize([5], [-3, -4, 1, 3, 4]);
    my $result = $t1->min($t2);

    is( $result->at(0), -5, 'min(-5, -3) is -5' );
    is( $result->at(1), -4, 'min(-2, -4) is -4' );
    is( $result->at(2), 0, 'min(0, 1) is 0' );
    is( $result->at(3), 2, 'min(2, 3) is 2' );
    is( $result->at(4), 4, 'min(5, 4) is 4' );
};

subtest 'max method - element-wise maximum with scalar' => sub {
    my $t = Tensor->initialize([5], [1, 2, 3, 4, 5]);
    my $result = $t->max(3);

    isa_ok( $result, 'Tensor', 'max returns a Tensor' );
    is( $result->at(0), 3, 'max(1, 3) is 3' );
    is( $result->at(1), 3, 'max(2, 3) is 3' );
    is( $result->at(2), 3, 'max(3, 3) is 3' );
    is( $result->at(3), 4, 'max(4, 3) is 4' );
    is( $result->at(4), 5, 'max(5, 3) is 5' );
};

subtest 'max method - element-wise maximum with tensor' => sub {
    my $t1 = Tensor->initialize([5], [1, 5, 3, 7, 2]);
    my $t2 = Tensor->initialize([5], [3, 2, 4, 6, 8]);
    my $result = $t1->max($t2);

    isa_ok( $result, 'Tensor', 'max returns a Tensor' );
    is( $result->at(0), 3, 'max(1, 3) is 3' );
    is( $result->at(1), 5, 'max(5, 2) is 5' );
    is( $result->at(2), 4, 'max(3, 4) is 4' );
    is( $result->at(3), 7, 'max(7, 6) is 7' );
    is( $result->at(4), 8, 'max(2, 8) is 8' );
};

subtest 'max method - with negative numbers' => sub {
    my $t1 = Tensor->initialize([5], [-5, -2, 0, 2, 5]);
    my $t2 = Tensor->initialize([5], [-3, -4, 1, 3, 4]);
    my $result = $t1->max($t2);

    is( $result->at(0), -3, 'max(-5, -3) is -3' );
    is( $result->at(1), -2, 'max(-2, -4) is -2' );
    is( $result->at(2), 1, 'max(0, 1) is 1' );
    is( $result->at(3), 3, 'max(2, 3) is 3' );
    is( $result->at(4), 5, 'max(5, 4) is 5' );
};

subtest 'numerical operations - 2D tensors' => sub {
    my $t = Tensor->initialize([2, 2], [1.7, -2.3, 3.9, -4.1]);

    my $trunc_result = $t->trunc;
    is( $trunc_result->at(0, 0), 1, 'trunc at (0,0)' );
    is( $trunc_result->at(0, 1), -2, 'trunc at (0,1)' );
    is( $trunc_result->at(1, 0), 3, 'trunc at (1,0)' );
    is( $trunc_result->at(1, 1), -4, 'trunc at (1,1)' );

    my $round_up_result = $t->round_up;
    is( $round_up_result->at(0, 0), 2, 'round_up at (0,0)' );
    is( $round_up_result->at(0, 1), -2, 'round_up at (0,1)' );
    is( $round_up_result->at(1, 0), 4, 'round_up at (1,0)' );
    is( $round_up_result->at(1, 1), -4, 'round_up at (1,1)' );

    my $clamp_result = $t->clamp(0, 3);
    is( $clamp_result->at(0, 0), 1.7, 'clamp at (0,0)' );
    is( $clamp_result->at(0, 1), 0, 'clamp at (0,1)' );
    is( $clamp_result->at(1, 0), 3, 'clamp at (1,0)' );
    is( $clamp_result->at(1, 1), 0, 'clamp at (1,1)' );
};

subtest 'numerical operations - 3D tensors' => sub {
    my $t = Tensor->initialize([2, 2, 2], [1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5]);

    my $trunc_result = $t->trunc;
    is( $trunc_result->at(0, 0, 0), 1, 'trunc at (0,0,0)' );
    is( $trunc_result->at(1, 1, 1), 8, 'trunc at (1,1,1)' );

    my $round_down_result = $t->round_down;
    is( $round_down_result->at(0, 0, 0), 1, 'round_down at (0,0,0)' );
    is( $round_down_result->at(1, 1, 1), 8, 'round_down at (1,1,1)' );

    my $clamp_result = $t->clamp(3, 7);
    is( $clamp_result->at(0, 0, 0), 3, 'clamp at (0,0,0)' );
    is( $clamp_result->at(0, 1, 1), 4.5, 'clamp at (0,1,1)' );
    is( $clamp_result->at(1, 1, 1), 7, 'clamp at (1,1,1)' );
};

subtest 'combining min and max operations' => sub {
    my $t = Tensor->initialize([5], [-10, -5, 0, 5, 10]);

    # Using max to set lower bound
    my $lower_bounded = $t->max(-3);
    is( $lower_bounded->at(0), -3, 'max(-10, -3) is -3' );
    is( $lower_bounded->at(1), -3, 'max(-5, -3) is -3' );
    is( $lower_bounded->at(2), 0, 'max(0, -3) is 0' );

    # Using min to set upper bound
    my $upper_bounded = $t->min(3);
    is( $upper_bounded->at(2), 0, 'min(0, 3) is 0' );
    is( $upper_bounded->at(3), 3, 'min(5, 3) is 3' );
    is( $upper_bounded->at(4), 3, 'min(10, 3) is 3' );

    # Combining both (like clamp)
    my $bounded = $t->max(-3)->min(3);
    is( $bounded->at(0), -3, 'bounded value at 0' );
    is( $bounded->at(2), 0, 'bounded value at 2' );
    is( $bounded->at(4), 3, 'bounded value at 4' );
};

done_testing;

__END__
