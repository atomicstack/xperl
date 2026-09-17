use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Tensor;

subtest 'sum method - 1D tensor sum' => sub {
    my $t = Tensor->initialize([5], [1, 2, 3, 4, 5]);
    my $sum = $t->sum;

    is( $sum, 15, 'sum of [1,2,3,4,5] is 15' );
};

subtest 'sum method - 1D tensor with zeros' => sub {
    my $t = Tensor->zeros([5]);
    my $sum = $t->sum;

    is( $sum, 0, 'sum of zeros is 0' );
};

subtest 'sum method - 1D tensor with negative numbers' => sub {
    my $t = Tensor->initialize([5], [-2, -1, 0, 1, 2]);
    my $sum = $t->sum;

    is( $sum, 0, 'sum of [-2,-1,0,1,2] is 0' );
};

subtest 'sum method - 1D tensor with floating point numbers' => sub {
    my $t = Tensor->initialize([4], [1.5, 2.5, 3.5, 4.5]);
    my $sum = $t->sum;

    is( $sum, 12.0, 'sum of [1.5,2.5,3.5,4.5] is 12.0' );
};

subtest 'sum method - 2D tensor sum' => sub {
    my $t = Tensor->initialize([2, 3], [1, 2, 3, 4, 5, 6]);
    my $sum = $t->sum;

    is( $sum, 21, 'sum of 2x3 tensor is 21' );
};

subtest 'sum method - 2D tensor with negatives' => sub {
    my $t = Tensor->initialize([2, 2], [1, -2, 3, -4]);
    my $sum = $t->sum;

    is( $sum, -2, 'sum of [1,-2,3,-4] is -2' );
};

subtest 'sum method - 3D tensor sum' => sub {
    my $t = Tensor->initialize([2, 2, 2], [1..8]);
    my $sum = $t->sum;

    is( $sum, 36, 'sum of 2x2x2 tensor [1..8] is 36' );
};

subtest 'sum method - large tensor' => sub {
    my $t = Tensor->ones([10, 10]);
    my $sum = $t->sum;

    is( $sum, 100, 'sum of 10x10 ones tensor is 100' );
};

subtest 'min_value method - 1D tensor minimum' => sub {
    my $t = Tensor->initialize([5], [5, 2, 8, 1, 6]);
    my $min = $t->min_value;

    is( $min, 1, 'minimum of [5,2,8,1,6] is 1' );
};

subtest 'min_value method - 1D tensor with negative numbers' => sub {
    my $t = Tensor->initialize([5], [5, -2, 8, -10, 6]);
    my $min = $t->min_value;

    is( $min, -10, 'minimum of [5,-2,8,-10,6] is -10' );
};

subtest 'min_value method - 1D tensor with all same values' => sub {
    my $t = Tensor->initialize([5], [7, 7, 7, 7, 7]);
    my $min = $t->min_value;

    is( $min, 7, 'minimum of all 7s is 7' );
};

subtest 'min_value method - 1D tensor with floating point numbers' => sub {
    my $t = Tensor->initialize([5], [1.5, 2.3, 0.9, 3.7, 2.1]);
    my $min = $t->min_value;

    is( $min, 0.9, 'minimum of floating point values is 0.9' );
};

subtest 'min_value method - 2D tensor minimum' => sub {
    my $t = Tensor->initialize([2, 3], [9, 2, 7, 4, 1, 8]);
    my $min = $t->min_value;

    is( $min, 1, 'minimum of 2x3 tensor is 1' );
};

subtest 'min_value method - 2D tensor with negatives' => sub {
    my $t = Tensor->initialize([2, 2], [5, -3, 2, -7]);
    my $min = $t->min_value;

    is( $min, -7, 'minimum of [5,-3,2,-7] is -7' );
};

subtest 'min_value method - 3D tensor minimum' => sub {
    my $t = Tensor->initialize([2, 2, 2], [8, 3, 6, 1, 9, 2, 7, 4]);
    my $min = $t->min_value;

    is( $min, 1, 'minimum of 3D tensor is 1' );
};

subtest 'max_value method - 1D tensor maximum' => sub {
    my $t = Tensor->initialize([5], [5, 2, 8, 1, 6]);
    my $max = $t->max_value;

    is( $max, 8, 'maximum of [5,2,8,1,6] is 8' );
};

subtest 'max_value method - 1D tensor with negative numbers' => sub {
    my $t = Tensor->initialize([5], [-5, -2, -8, -1, -6]);
    my $max = $t->max_value;

    is( $max, -1, 'maximum of all negatives is -1' );
};

subtest 'max_value method - 1D tensor with all same values' => sub {
    my $t = Tensor->initialize([5], [7, 7, 7, 7, 7]);
    my $max = $t->max_value;

    is( $max, 7, 'maximum of all 7s is 7' );
};

subtest 'max_value method - 1D tensor with floating point numbers' => sub {
    my $t = Tensor->initialize([5], [1.5, 2.3, 0.9, 3.7, 2.1]);
    my $max = $t->max_value;

    is( $max, 3.7, 'maximum of floating point values is 3.7' );
};

subtest 'max_value method - 2D tensor maximum' => sub {
    my $t = Tensor->initialize([2, 3], [9, 2, 7, 4, 1, 8]);
    my $max = $t->max_value;

    is( $max, 9, 'maximum of 2x3 tensor is 9' );
};

subtest 'max_value method - 2D tensor with negatives and positives' => sub {
    my $t = Tensor->initialize([2, 2], [5, -3, 2, -7]);
    my $max = $t->max_value;

    is( $max, 5, 'maximum of [5,-3,2,-7] is 5' );
};

subtest 'max_value method - 3D tensor maximum' => sub {
    my $t = Tensor->initialize([2, 2, 2], [8, 3, 6, 1, 9, 2, 7, 4]);
    my $max = $t->max_value;

    is( $max, 9, 'maximum of 3D tensor is 9' );
};

subtest 'reductions after operations' => sub {
    my $t = Tensor->initialize([5], [1, 2, 3, 4, 5]);

    # Sum after multiplication
    my $doubled = $t * 2;
    is( $doubled->sum, 30, 'sum after doubling is 30' );

    # Min/max after addition
    my $shifted = $t + 10;
    is( $shifted->min_value, 11, 'min after adding 10 is 11' );
    is( $shifted->max_value, 15, 'max after adding 10 is 15' );
};

subtest 'reductions on constructed tensors' => sub {
    my $t = Tensor->construct([5], sub { $_[0] * $_[0] });

    is( $t->sum, 30, 'sum of [0,1,4,9,16] is 30' );
    is( $t->min_value, 0, 'min of squares is 0' );
    is( $t->max_value, 16, 'max of squares is 16' );
};

subtest 'reductions on sequence tensors' => sub {
    my $t = Tensor->sequence([10], 1);

    is( $t->sum, 55, 'sum of sequence [1..10] is 55' );
    is( $t->min_value, 1, 'min of sequence is 1' );
    is( $t->max_value, 10, 'max of sequence is 10' );
};

subtest 'combined reductions and operations' => sub {
    my $t1 = Tensor->initialize([5], [1, 2, 3, 4, 5]);
    my $t2 = Tensor->initialize([5], [5, 4, 3, 2, 1]);

    my $added = $t1 + $t2;
    is( $added->sum, 30, 'sum of element-wise addition' );
    is( $added->min_value, 6, 'min after adding is 6' );
    is( $added->max_value, 6, 'max after adding is 6 (all same)' );

    my $multiplied = $t1 * $t2;
    is( $multiplied->sum, 35, 'sum of element-wise multiplication' );
    is( $multiplied->min_value, 5, 'min after multiplying is 5 ([5,8,9,8,5])' );
    is( $multiplied->max_value, 9, 'max after multiplying' );
};

subtest 'reductions on single element tensor' => sub {
    my $t = Tensor->initialize([1], [42]);

    is( $t->sum, 42, 'sum of single element is 42' );
    is( $t->min_value, 42, 'min of single element is 42' );
    is( $t->max_value, 42, 'max of single element is 42' );
};

subtest 'reductions on large tensors' => sub {
    my $large = Tensor->sequence([100], 1);

    is( $large->sum, 5050, 'sum of [1..100] is 5050' );
    is( $large->min_value, 1, 'min of [1..100] is 1' );
    is( $large->max_value, 100, 'max of [1..100] is 100' );
};

subtest 'reductions with mixed operations' => sub {
    my $t = Tensor->initialize([5], [1, 2, 3, 4, 5]);

    # (t * 2) + 5
    my $result = ($t * 2) + 5;
    is( $result->sum, 55, 'sum of (t*2)+5 is 55' );
    is( $result->min_value, 7, 'min is 7' );
    is( $result->max_value, 15, 'max is 15' );

    # t ** 2
    my $squared = $t ** 2;
    is( $squared->sum, 55, 'sum of squares is 55' );
    is( $squared->min_value, 1, 'min of squares is 1' );
    is( $squared->max_value, 25, 'max of squares is 25' );
};

done_testing;

__END__
