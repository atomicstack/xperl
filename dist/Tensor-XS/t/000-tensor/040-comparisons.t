use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Tensor;

subtest 'eq method - tensor equality with scalar' => sub {
    my $t = Tensor->initialize([3], [1, 2, 3]);
    my $result = $t->eq(2);

    isa_ok( $result, 'Tensor', 'eq returns a Tensor' );
    is( $result->at(0), 0, 'element at 0 is 0 (1 == 2 is false)' );
    is( $result->at(1), 1, 'element at 1 is 1 (2 == 2 is true)' );
    is( $result->at(2), 0, 'element at 2 is 0 (3 == 2 is false)' );
};

subtest 'eq method - element-wise tensor equality' => sub {
    my $t1 = Tensor->initialize([3], [1, 2, 3]);
    my $t2 = Tensor->initialize([3], [1, 5, 3]);
    my $result = $t1->eq($t2);

    isa_ok( $result, 'Tensor', 'eq returns a Tensor' );
    is( $result->at(0), 1, 'element at 0 is 1 (1 == 1 is true)' );
    is( $result->at(1), 0, 'element at 1 is 0 (2 == 5 is false)' );
    is( $result->at(2), 1, 'element at 2 is 1 (3 == 3 is true)' );
};

subtest 'eq method - using overloaded == operator' => sub {
    my $t1 = Tensor->initialize([3], [1, 2, 3]);
    my $t2 = Tensor->initialize([3], [1, 5, 3]);
    my $result = $t1 == $t2;

    isa_ok( $result, 'Tensor', '== operator returns a Tensor' );
    is( $result->at(0), 1, 'element at 0 is 1' );
    is( $result->at(1), 0, 'element at 1 is 0' );
    is( $result->at(2), 1, 'element at 2 is 1' );
};

subtest 'ne method - tensor inequality with scalar' => sub {
    my $t = Tensor->initialize([3], [1, 2, 3]);
    my $result = $t->ne(2);

    isa_ok( $result, 'Tensor', 'ne returns a Tensor' );
    is( $result->at(0), 1, 'element at 0 is 1 (1 != 2 is true)' );
    is( $result->at(1), 0, 'element at 1 is 0 (2 != 2 is false)' );
    is( $result->at(2), 1, 'element at 2 is 1 (3 != 2 is true)' );
};

subtest 'ne method - element-wise tensor inequality' => sub {
    my $t1 = Tensor->initialize([3], [1, 2, 3]);
    my $t2 = Tensor->initialize([3], [1, 5, 3]);
    my $result = $t1->ne($t2);

    isa_ok( $result, 'Tensor', 'ne returns a Tensor' );
    is( $result->at(0), 0, 'element at 0 is 0 (1 != 1 is false)' );
    is( $result->at(1), 1, 'element at 1 is 1 (2 != 5 is true)' );
    is( $result->at(2), 0, 'element at 2 is 0 (3 != 3 is false)' );
};

subtest 'ne method - using overloaded != operator' => sub {
    my $t1 = Tensor->initialize([3], [1, 2, 3]);
    my $t2 = Tensor->initialize([3], [1, 5, 3]);
    my $result = $t1 != $t2;

    isa_ok( $result, 'Tensor', '!= operator returns a Tensor' );
    is( $result->at(0), 0, 'element at 0 is 0' );
    is( $result->at(1), 1, 'element at 1 is 1' );
    is( $result->at(2), 0, 'element at 2 is 0' );
};

subtest 'lt method - tensor less than with scalar' => sub {
    my $t = Tensor->initialize([3], [1, 2, 3]);
    my $result = $t->lt(2);

    isa_ok( $result, 'Tensor', 'lt returns a Tensor' );
    is( $result->at(0), 1, 'element at 0 is 1 (1 < 2 is true)' );
    is( $result->at(1), 0, 'element at 1 is 0 (2 < 2 is false)' );
    is( $result->at(2), 0, 'element at 2 is 0 (3 < 2 is false)' );
};

subtest 'lt method - element-wise tensor less than' => sub {
    my $t1 = Tensor->initialize([3], [1, 5, 3]);
    my $t2 = Tensor->initialize([3], [2, 4, 3]);
    my $result = $t1->lt($t2);

    isa_ok( $result, 'Tensor', 'lt returns a Tensor' );
    is( $result->at(0), 1, 'element at 0 is 1 (1 < 2 is true)' );
    is( $result->at(1), 0, 'element at 1 is 0 (5 < 4 is false)' );
    is( $result->at(2), 0, 'element at 2 is 0 (3 < 3 is false)' );
};

subtest 'lt method - using overloaded < operator' => sub {
    my $t1 = Tensor->initialize([3], [1, 5, 3]);
    my $t2 = Tensor->initialize([3], [2, 4, 3]);
    my $result = $t1 < $t2;

    isa_ok( $result, 'Tensor', '< operator returns a Tensor' );
    is( $result->at(0), 1, 'element at 0 is 1' );
    is( $result->at(1), 0, 'element at 1 is 0' );
    is( $result->at(2), 0, 'element at 2 is 0' );
};

subtest 'le method - tensor less than or equal with scalar' => sub {
    my $t = Tensor->initialize([3], [1, 2, 3]);
    my $result = $t->le(2);

    isa_ok( $result, 'Tensor', 'le returns a Tensor' );
    is( $result->at(0), 1, 'element at 0 is 1 (1 <= 2 is true)' );
    is( $result->at(1), 1, 'element at 1 is 1 (2 <= 2 is true)' );
    is( $result->at(2), 0, 'element at 2 is 0 (3 <= 2 is false)' );
};

subtest 'le method - element-wise tensor less than or equal' => sub {
    my $t1 = Tensor->initialize([3], [1, 5, 3]);
    my $t2 = Tensor->initialize([3], [2, 4, 3]);
    my $result = $t1->le($t2);

    isa_ok( $result, 'Tensor', 'le returns a Tensor' );
    is( $result->at(0), 1, 'element at 0 is 1 (1 <= 2 is true)' );
    is( $result->at(1), 0, 'element at 1 is 0 (5 <= 4 is false)' );
    is( $result->at(2), 1, 'element at 2 is 1 (3 <= 3 is true)' );
};

subtest 'le method - using overloaded <= operator' => sub {
    my $t1 = Tensor->initialize([3], [1, 5, 3]);
    my $t2 = Tensor->initialize([3], [2, 4, 3]);
    my $result = $t1 <= $t2;

    isa_ok( $result, 'Tensor', '<= operator returns a Tensor' );
    is( $result->at(0), 1, 'element at 0 is 1' );
    is( $result->at(1), 0, 'element at 1 is 0' );
    is( $result->at(2), 1, 'element at 2 is 1' );
};

subtest 'gt method - tensor greater than with scalar' => sub {
    my $t = Tensor->initialize([3], [1, 2, 3]);
    my $result = $t->gt(2);

    isa_ok( $result, 'Tensor', 'gt returns a Tensor' );
    is( $result->at(0), 0, 'element at 0 is 0 (1 > 2 is false)' );
    is( $result->at(1), 0, 'element at 1 is 0 (2 > 2 is false)' );
    is( $result->at(2), 1, 'element at 2 is 1 (3 > 2 is true)' );
};

subtest 'gt method - element-wise tensor greater than' => sub {
    my $t1 = Tensor->initialize([3], [1, 5, 3]);
    my $t2 = Tensor->initialize([3], [2, 4, 3]);
    my $result = $t1->gt($t2);

    isa_ok( $result, 'Tensor', 'gt returns a Tensor' );
    is( $result->at(0), 0, 'element at 0 is 0 (1 > 2 is false)' );
    is( $result->at(1), 1, 'element at 1 is 1 (5 > 4 is true)' );
    is( $result->at(2), 0, 'element at 2 is 0 (3 > 3 is false)' );
};

subtest 'gt method - using overloaded > operator' => sub {
    my $t1 = Tensor->initialize([3], [1, 5, 3]);
    my $t2 = Tensor->initialize([3], [2, 4, 3]);
    my $result = $t1 > $t2;

    isa_ok( $result, 'Tensor', '> operator returns a Tensor' );
    is( $result->at(0), 0, 'element at 0 is 0' );
    is( $result->at(1), 1, 'element at 1 is 1' );
    is( $result->at(2), 0, 'element at 2 is 0' );
};

subtest 'ge method - tensor greater than or equal with scalar' => sub {
    my $t = Tensor->initialize([3], [1, 2, 3]);
    my $result = $t->ge(2);

    isa_ok( $result, 'Tensor', 'ge returns a Tensor' );
    is( $result->at(0), 0, 'element at 0 is 0 (1 >= 2 is false)' );
    is( $result->at(1), 1, 'element at 1 is 1 (2 >= 2 is true)' );
    is( $result->at(2), 1, 'element at 2 is 1 (3 >= 2 is true)' );
};

subtest 'ge method - element-wise tensor greater than or equal' => sub {
    my $t1 = Tensor->initialize([3], [1, 5, 3]);
    my $t2 = Tensor->initialize([3], [2, 4, 3]);
    my $result = $t1->ge($t2);

    isa_ok( $result, 'Tensor', 'ge returns a Tensor' );
    is( $result->at(0), 0, 'element at 0 is 0 (1 >= 2 is false)' );
    is( $result->at(1), 1, 'element at 1 is 1 (5 >= 4 is true)' );
    is( $result->at(2), 1, 'element at 2 is 1 (3 >= 3 is true)' );
};

subtest 'ge method - using overloaded >= operator' => sub {
    my $t1 = Tensor->initialize([3], [1, 5, 3]);
    my $t2 = Tensor->initialize([3], [2, 4, 3]);
    my $result = $t1 >= $t2;

    isa_ok( $result, 'Tensor', '>= operator returns a Tensor' );
    is( $result->at(0), 0, 'element at 0 is 0' );
    is( $result->at(1), 1, 'element at 1 is 1' );
    is( $result->at(2), 1, 'element at 2 is 1' );
};

subtest 'cmp method - tensor three-way comparison with scalar' => sub {
    my $t = Tensor->initialize([3], [1, 2, 3]);
    my $result = $t->cmp(2);

    isa_ok( $result, 'Tensor', 'cmp returns a Tensor' );
    is( $result->at(0), -1, 'element at 0 is -1 (1 <=> 2)' );
    is( $result->at(1), 0, 'element at 1 is 0 (2 <=> 2)' );
    is( $result->at(2), 1, 'element at 2 is 1 (3 <=> 2)' );
};

subtest 'cmp method - element-wise tensor three-way comparison' => sub {
    my $t1 = Tensor->initialize([3], [1, 5, 3]);
    my $t2 = Tensor->initialize([3], [2, 4, 3]);
    my $result = $t1->cmp($t2);

    isa_ok( $result, 'Tensor', 'cmp returns a Tensor' );
    is( $result->at(0), -1, 'element at 0 is -1 (1 <=> 2)' );
    is( $result->at(1), 1, 'element at 1 is 1 (5 <=> 4)' );
    is( $result->at(2), 0, 'element at 2 is 0 (3 <=> 3)' );
};

subtest 'cmp method - using overloaded <=> operator' => sub {
    my $t1 = Tensor->initialize([3], [1, 5, 3]);
    my $t2 = Tensor->initialize([3], [2, 4, 3]);
    my $result = $t1 <=> $t2;

    isa_ok( $result, 'Tensor', '<=> operator returns a Tensor' );
    is( $result->at(0), -1, 'element at 0 is -1' );
    is( $result->at(1), 1, 'element at 1 is 1' );
    is( $result->at(2), 0, 'element at 2 is 0' );
};

subtest 'comparison operations - 2D tensors' => sub {
    my $t1 = Tensor->initialize([2, 2], [1, 5, 3, 4]);
    my $t2 = Tensor->initialize([2, 2], [2, 4, 3, 5]);

    my $eq_result = $t1 == $t2;
    is( $eq_result->at(0, 0), 0, 'equality (0,0) is 0' );
    is( $eq_result->at(1, 0), 1, 'equality (1,0) is 1' );

    my $lt_result = $t1 < $t2;
    is( $lt_result->at(0, 0), 1, 'less than (0,0) is 1' );
    is( $lt_result->at(0, 1), 0, 'less than (0,1) is 0' );

    my $gt_result = $t1 > $t2;
    is( $gt_result->at(0, 1), 1, 'greater than (0,1) is 1' );
    is( $gt_result->at(1, 1), 0, 'greater than (1,1) is 0' );
};

subtest 'comparison operations - with floating point numbers' => sub {
    my $t1 = Tensor->initialize([3], [1.5, 2.5, 3.5]);
    my $t2 = Tensor->initialize([3], [1.5, 2.0, 4.0]);

    my $eq_result = $t1 == $t2;
    is( $eq_result->at(0), 1, 'equality with floats at 0' );
    is( $eq_result->at(1), 0, 'equality with floats at 1' );

    my $gt_result = $t1 > $t2;
    is( $gt_result->at(0), 0, 'greater than with floats at 0' );
    is( $gt_result->at(1), 1, 'greater than with floats at 1' );
    is( $gt_result->at(2), 0, 'greater than with floats at 2' );
};

subtest 'comparison operations - with negative numbers' => sub {
    my $t1 = Tensor->initialize([3], [-2, 0, 2]);
    my $t2 = Tensor->initialize([3], [-1, 0, 1]);

    my $lt_result = $t1 < $t2;
    is( $lt_result->at(0), 1, 'less than with negatives at 0 (-2 < -1)' );
    is( $lt_result->at(1), 0, 'less than with negatives at 1 (0 < 0)' );
    is( $lt_result->at(2), 0, 'less than with negatives at 2 (2 < 1)' );

    my $ge_result = $t1 >= $t2;
    is( $ge_result->at(0), 0, 'greater or equal with negatives at 0' );
    is( $ge_result->at(1), 1, 'greater or equal with negatives at 1' );
    is( $ge_result->at(2), 1, 'greater or equal with negatives at 2' );
};

done_testing;

__END__
