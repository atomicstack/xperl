use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Tensor;

subtest 'not method - logical NOT on tensor' => sub {
    my $t = Tensor->initialize([3], [0, 1, 2]);
    my $result = $t->not;

    isa_ok( $result, 'Tensor', 'not returns a Tensor' );
    is( $result->at(0), 1, 'element at 0 is 1 (!0 is true)' );
    is( $result->at(1), 0, 'element at 1 is 0 (!1 is false)' );
    is( $result->at(2), 0, 'element at 2 is 0 (!2 is false)' );
};

subtest 'not method - using overloaded ! operator' => sub {
    my $t = Tensor->initialize([3], [0, 5, 0]);
    my $result = !$t;

    isa_ok( $result, 'Tensor', '! operator returns a Tensor' );
    is( $result->at(0), 1, 'element at 0 is 1' );
    is( $result->at(1), 0, 'element at 1 is 0' );
    is( $result->at(2), 1, 'element at 2 is 1' );
};

subtest 'and method - logical AND with scalar' => sub {
    my $t = Tensor->initialize([3], [0, 1, 2]);
    my $result = $t->and(1);

    isa_ok( $result, 'Tensor', 'and returns a Tensor' );
    is( $result->at(0), 0, 'element at 0 is 0 (0 && 1 is false)' );
    is( $result->at(1), 1, 'element at 1 is 1 (1 && 1 is true)' );
    is( $result->at(2), 1, 'element at 2 is 1 (2 && 1 is true)' );
};

subtest 'and method - logical AND with scalar zero' => sub {
    my $t = Tensor->initialize([3], [0, 1, 2]);
    my $result = $t->and(0);

    isa_ok( $result, 'Tensor', 'and returns a Tensor' );
    is( $result->at(0), 0, 'element at 0 is 0 (0 && 0 is false)' );
    is( $result->at(1), 0, 'element at 1 is 0 (1 && 0 is false)' );
    is( $result->at(2), 0, 'element at 2 is 0 (2 && 0 is false)' );
};

subtest 'and method - element-wise logical AND' => sub {
    my $t1 = Tensor->initialize([4], [0, 0, 1, 2]);
    my $t2 = Tensor->initialize([4], [0, 1, 0, 3]);
    my $result = $t1->and($t2);

    isa_ok( $result, 'Tensor', 'and returns a Tensor' );
    is( $result->at(0), 0, 'element at 0 is 0 (0 && 0 is false)' );
    is( $result->at(1), 0, 'element at 1 is 0 (0 && 1 is false)' );
    is( $result->at(2), 0, 'element at 2 is 0 (1 && 0 is false)' );
    is( $result->at(3), 1, 'element at 3 is 1 (2 && 3 is true)' );
};

subtest 'or method - logical OR with scalar' => sub {
    my $t = Tensor->initialize([3], [0, 1, 2]);
    my $result = $t->or(0);

    isa_ok( $result, 'Tensor', 'or returns a Tensor' );
    is( $result->at(0), 0, 'element at 0 is 0 (0 || 0 is false)' );
    is( $result->at(1), 1, 'element at 1 is 1 (1 || 0 is true)' );
    is( $result->at(2), 1, 'element at 2 is 1 (2 || 0 is true)' );
};

subtest 'or method - logical OR with scalar non-zero' => sub {
    my $t = Tensor->initialize([3], [0, 1, 2]);
    my $result = $t->or(1);

    isa_ok( $result, 'Tensor', 'or returns a Tensor' );
    is( $result->at(0), 1, 'element at 0 is 1 (0 || 1 is true)' );
    is( $result->at(1), 1, 'element at 1 is 1 (1 || 1 is true)' );
    is( $result->at(2), 1, 'element at 2 is 1 (2 || 1 is true)' );
};

subtest 'or method - element-wise logical OR' => sub {
    my $t1 = Tensor->initialize([4], [0, 0, 1, 2]);
    my $t2 = Tensor->initialize([4], [0, 1, 0, 3]);
    my $result = $t1->or($t2);

    isa_ok( $result, 'Tensor', 'or returns a Tensor' );
    is( $result->at(0), 0, 'element at 0 is 0 (0 || 0 is false)' );
    is( $result->at(1), 1, 'element at 1 is 1 (0 || 1 is true)' );
    is( $result->at(2), 1, 'element at 2 is 1 (1 || 0 is true)' );
    is( $result->at(3), 1, 'element at 3 is 1 (2 || 3 is true)' );
};

subtest 'logical operations - 2D tensors' => sub {
    my $t1 = Tensor->initialize([2, 2], [0, 1, 1, 0]);
    my $t2 = Tensor->initialize([2, 2], [0, 0, 1, 1]);

    my $and_result = $t1->and($t2);
    is( $and_result->at(0, 0), 0, 'AND (0,0) is 0 (0 && 0)' );
    is( $and_result->at(0, 1), 0, 'AND (0,1) is 0 (1 && 0)' );
    is( $and_result->at(1, 0), 1, 'AND (1,0) is 1 (1 && 1)' );
    is( $and_result->at(1, 1), 0, 'AND (1,1) is 0 (0 && 1)' );

    my $or_result = $t1->or($t2);
    is( $or_result->at(0, 0), 0, 'OR (0,0) is 0 (0 || 0)' );
    is( $or_result->at(0, 1), 1, 'OR (0,1) is 1 (1 || 0)' );
    is( $or_result->at(1, 0), 1, 'OR (1,0) is 1 (1 || 1)' );
    is( $or_result->at(1, 1), 1, 'OR (1,1) is 1 (0 || 1)' );

    my $not_result = !$t1;
    is( $not_result->at(0, 0), 1, 'NOT (0,0) is 1 (!0)' );
    is( $not_result->at(0, 1), 0, 'NOT (0,1) is 0 (!1)' );
    is( $not_result->at(1, 0), 0, 'NOT (1,0) is 0 (!1)' );
    is( $not_result->at(1, 1), 1, 'NOT (1,1) is 1 (!0)' );
};

subtest 'logical operations - with negative numbers' => sub {
    my $t = Tensor->initialize([3], [-1, 0, 1]);

    my $not_result = !$t;
    is( $not_result->at(0), 0, '!(-1) is 0 (false)' );
    is( $not_result->at(1), 1, '!(0) is 1 (true)' );
    is( $not_result->at(2), 0, '!(1) is 0 (false)' );

    my $and_result = $t->and(1);
    is( $and_result->at(0), 1, '-1 && 1 is 1 (true)' );
    is( $and_result->at(1), 0, '0 && 1 is 0 (false)' );
    is( $and_result->at(2), 1, '1 && 1 is 1 (true)' );

    my $or_result = $t->or(0);
    is( $or_result->at(0), 1, '-1 || 0 is 1 (true)' );
    is( $or_result->at(1), 0, '0 || 0 is 0 (false)' );
    is( $or_result->at(2), 1, '1 || 0 is 1 (true)' );
};

subtest 'combining logical operations' => sub {
    my $t = Tensor->initialize([3], [0, 1, 2]);

    # !(!t) should be like a boolean conversion
    my $double_not = !(!$t);
    is( $double_not->at(0), 0, '!!0 is 0' );
    is( $double_not->at(1), 1, '!!1 is 1' );
    is( $double_not->at(2), 1, '!!2 is 1' );
};

subtest 'logical operations with comparison results' => sub {
    my $t1 = Tensor->initialize([4], [1, 2, 3, 4]);
    my $t2 = Tensor->initialize([4], [2, 2, 4, 3]);

    # Create boolean tensors from comparisons
    my $gt_result = $t1 > $t2;  # [0, 0, 0, 1]
    my $eq_result = $t1 == $t2; # [0, 1, 0, 0]

    # Combine with OR
    my $or_result = $gt_result->or($eq_result);
    is( $or_result->at(0), 0, 'element at 0: 0 || 0 = 0' );
    is( $or_result->at(1), 1, 'element at 1: 0 || 1 = 1' );
    is( $or_result->at(2), 0, 'element at 2: 0 || 0 = 0' );
    is( $or_result->at(3), 1, 'element at 3: 1 || 0 = 1' );

    # NOT the result
    my $not_result = !$or_result;
    is( $not_result->at(0), 1, 'element at 0: !0 = 1' );
    is( $not_result->at(1), 0, 'element at 1: !1 = 0' );
    is( $not_result->at(2), 1, 'element at 2: !0 = 1' );
    is( $not_result->at(3), 0, 'element at 3: !1 = 0' );
};

subtest 'logical operations - 3D tensors' => sub {
    my $t1 = Tensor->initialize([2, 2, 2], [0, 1, 0, 1, 1, 0, 1, 0]);
    my $t2 = Tensor->initialize([2, 2, 2], [0, 0, 1, 1, 0, 1, 1, 1]);

    my $and_result = $t1->and($t2);
    is( $and_result->at(0, 0, 0), 0, 'AND at (0,0,0)' );
    is( $and_result->at(0, 0, 1), 0, 'AND at (0,0,1)' );
    is( $and_result->at(0, 1, 1), 1, 'AND at (0,1,1)' );

    my $or_result = $t1->or($t2);
    is( $or_result->at(0, 0, 0), 0, 'OR at (0,0,0)' );
    is( $or_result->at(0, 0, 1), 1, 'OR at (0,0,1)' );
    is( $or_result->at(0, 1, 0), 1, 'OR at (0,1,0)' );
};

done_testing;

__END__
