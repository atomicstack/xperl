use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Tensor;

subtest 'add method - tensor addition with scalar' => sub {
    my $t = Tensor->initialize([3], [1, 2, 3]);
    my $result = $t->add(10);

    isa_ok( $result, 'Tensor', 'add returns a Tensor' );
    is( $result->size, 3, 'result has same size as input' );
    is( $result->at(0), 11, 'element at 0 is 11 (1+10)' );
    is( $result->at(1), 12, 'element at 1 is 12 (2+10)' );
    is( $result->at(2), 13, 'element at 2 is 13 (3+10)' );
};

subtest 'add method - tensor addition with tensor' => sub {
    my $t1 = Tensor->initialize([3], [1, 2, 3]);
    my $t2 = Tensor->initialize([3], [4, 5, 6]);
    my $result = $t1->add($t2);

    isa_ok( $result, 'Tensor', 'add returns a Tensor' );
    is( $result->size, 3, 'result has same size as inputs' );
    is( $result->at(0), 5, 'element at 0 is 5 (1+4)' );
    is( $result->at(1), 7, 'element at 1 is 7 (2+5)' );
    is( $result->at(2), 9, 'element at 2 is 9 (3+6)' );
};

subtest 'add method - 2D tensor addition' => sub {
    my $t1 = Tensor->initialize([2, 2], [1, 2, 3, 4]);
    my $t2 = Tensor->initialize([2, 2], [5, 6, 7, 8]);
    my $result = $t1->add($t2);

    is( $result->at(0, 0), 6, 'element at (0,0) is 6 (1+5)' );
    is( $result->at(0, 1), 8, 'element at (0,1) is 8 (2+6)' );
    is( $result->at(1, 0), 10, 'element at (1,0) is 10 (3+7)' );
    is( $result->at(1, 1), 12, 'element at (1,1) is 12 (4+8)' );
};

subtest 'add method - using overloaded + operator' => sub {
    my $t1 = Tensor->initialize([3], [1, 2, 3]);
    my $t2 = Tensor->initialize([3], [4, 5, 6]);
    my $result = $t1 + $t2;

    isa_ok( $result, 'Tensor', '+ operator returns a Tensor' );
    is( $result->at(0), 5, 'element at 0 is 5' );
    is( $result->at(1), 7, 'element at 1 is 7' );
    is( $result->at(2), 9, 'element at 2 is 9' );
};

subtest 'sub method - tensor subtraction with scalar' => sub {
    my $t = Tensor->initialize([3], [10, 20, 30]);
    my $result = $t->sub(5);

    isa_ok( $result, 'Tensor', 'sub returns a Tensor' );
    is( $result->at(0), 5, 'element at 0 is 5 (10-5)' );
    is( $result->at(1), 15, 'element at 1 is 15 (20-5)' );
    is( $result->at(2), 25, 'element at 2 is 25 (30-5)' );
};

subtest 'sub method - tensor subtraction with tensor' => sub {
    my $t1 = Tensor->initialize([3], [10, 20, 30]);
    my $t2 = Tensor->initialize([3], [1, 2, 3]);
    my $result = $t1->sub($t2);

    isa_ok( $result, 'Tensor', 'sub returns a Tensor' );
    is( $result->at(0), 9, 'element at 0 is 9 (10-1)' );
    is( $result->at(1), 18, 'element at 1 is 18 (20-2)' );
    is( $result->at(2), 27, 'element at 2 is 27 (30-3)' );
};

subtest 'sub method - using overloaded - operator' => sub {
    my $t1 = Tensor->initialize([3], [10, 20, 30]);
    my $t2 = Tensor->initialize([3], [1, 2, 3]);
    my $result = $t1 - $t2;

    isa_ok( $result, 'Tensor', '- operator returns a Tensor' );
    is( $result->at(0), 9, 'element at 0 is 9' );
    is( $result->at(1), 18, 'element at 1 is 18' );
    is( $result->at(2), 27, 'element at 2 is 27' );
};

subtest 'mul method - tensor multiplication with scalar' => sub {
    my $t = Tensor->initialize([3], [1, 2, 3]);
    my $result = $t->mul(5);

    isa_ok( $result, 'Tensor', 'mul returns a Tensor' );
    is( $result->at(0), 5, 'element at 0 is 5 (1*5)' );
    is( $result->at(1), 10, 'element at 1 is 10 (2*5)' );
    is( $result->at(2), 15, 'element at 2 is 15 (3*5)' );
};

subtest 'mul method - element-wise tensor multiplication' => sub {
    my $t1 = Tensor->initialize([3], [1, 2, 3]);
    my $t2 = Tensor->initialize([3], [2, 3, 4]);
    my $result = $t1->mul($t2);

    isa_ok( $result, 'Tensor', 'mul returns a Tensor' );
    is( $result->at(0), 2, 'element at 0 is 2 (1*2)' );
    is( $result->at(1), 6, 'element at 1 is 6 (2*3)' );
    is( $result->at(2), 12, 'element at 2 is 12 (3*4)' );
};

subtest 'mul method - using overloaded * operator' => sub {
    my $t1 = Tensor->initialize([3], [1, 2, 3]);
    my $t2 = Tensor->initialize([3], [2, 3, 4]);
    my $result = $t1 * $t2;

    isa_ok( $result, 'Tensor', '* operator returns a Tensor' );
    is( $result->at(0), 2, 'element at 0 is 2' );
    is( $result->at(1), 6, 'element at 1 is 6' );
    is( $result->at(2), 12, 'element at 2 is 12' );
};

subtest 'div method - tensor division with scalar' => sub {
    my $t = Tensor->initialize([3], [10, 20, 30]);
    my $result = $t->div(10);

    isa_ok( $result, 'Tensor', 'div returns a Tensor' );
    is( $result->at(0), 1, 'element at 0 is 1 (10/10)' );
    is( $result->at(1), 2, 'element at 1 is 2 (20/10)' );
    is( $result->at(2), 3, 'element at 2 is 3 (30/10)' );
};

subtest 'div method - element-wise tensor division' => sub {
    my $t1 = Tensor->initialize([3], [10, 20, 30]);
    my $t2 = Tensor->initialize([3], [2, 4, 5]);
    my $result = $t1->div($t2);

    isa_ok( $result, 'Tensor', 'div returns a Tensor' );
    is( $result->at(0), 5, 'element at 0 is 5 (10/2)' );
    is( $result->at(1), 5, 'element at 1 is 5 (20/4)' );
    is( $result->at(2), 6, 'element at 2 is 6 (30/5)' );
};

subtest 'div method - using overloaded / operator' => sub {
    my $t1 = Tensor->initialize([3], [10, 20, 30]);
    my $t2 = Tensor->initialize([3], [2, 4, 5]);
    my $result = $t1 / $t2;

    isa_ok( $result, 'Tensor', '/ operator returns a Tensor' );
    is( $result->at(0), 5, 'element at 0 is 5' );
    is( $result->at(1), 5, 'element at 1 is 5' );
    is( $result->at(2), 6, 'element at 2 is 6' );
};

subtest 'mod method - tensor modulo with scalar' => sub {
    my $t = Tensor->initialize([3], [10, 11, 12]);
    my $result = $t->mod(3);

    isa_ok( $result, 'Tensor', 'mod returns a Tensor' );
    is( $result->at(0), 1, 'element at 0 is 1 (10%3)' );
    is( $result->at(1), 2, 'element at 1 is 2 (11%3)' );
    is( $result->at(2), 0, 'element at 2 is 0 (12%3)' );
};

subtest 'mod method - element-wise tensor modulo' => sub {
    my $t1 = Tensor->initialize([3], [10, 11, 12]);
    my $t2 = Tensor->initialize([3], [3, 4, 5]);
    my $result = $t1->mod($t2);

    isa_ok( $result, 'Tensor', 'mod returns a Tensor' );
    is( $result->at(0), 1, 'element at 0 is 1 (10%3)' );
    is( $result->at(1), 3, 'element at 1 is 3 (11%4)' );
    is( $result->at(2), 2, 'element at 2 is 2 (12%5)' );
};

subtest 'mod method - using overloaded % operator' => sub {
    my $t1 = Tensor->initialize([3], [10, 11, 12]);
    my $t2 = Tensor->initialize([3], [3, 4, 5]);
    my $result = $t1 % $t2;

    isa_ok( $result, 'Tensor', '% operator returns a Tensor' );
    is( $result->at(0), 1, 'element at 0 is 1' );
    is( $result->at(1), 3, 'element at 1 is 3' );
    is( $result->at(2), 2, 'element at 2 is 2' );
};

subtest 'pow method - tensor power with scalar' => sub {
    my $t = Tensor->initialize([3], [2, 3, 4]);
    my $result = $t->pow(2);

    isa_ok( $result, 'Tensor', 'pow returns a Tensor' );
    is( $result->at(0), 4, 'element at 0 is 4 (2**2)' );
    is( $result->at(1), 9, 'element at 1 is 9 (3**2)' );
    is( $result->at(2), 16, 'element at 2 is 16 (4**2)' );
};

subtest 'pow method - element-wise tensor power' => sub {
    my $t1 = Tensor->initialize([3], [2, 3, 4]);
    my $t2 = Tensor->initialize([3], [3, 2, 1]);
    my $result = $t1->pow($t2);

    isa_ok( $result, 'Tensor', 'pow returns a Tensor' );
    is( $result->at(0), 8, 'element at 0 is 8 (2**3)' );
    is( $result->at(1), 9, 'element at 1 is 9 (3**2)' );
    is( $result->at(2), 4, 'element at 2 is 4 (4**1)' );
};

subtest 'pow method - using overloaded ** operator' => sub {
    my $t1 = Tensor->initialize([3], [2, 3, 4]);
    my $t2 = Tensor->initialize([3], [3, 2, 1]);
    my $result = $t1 ** $t2;

    isa_ok( $result, 'Tensor', '** operator returns a Tensor' );
    is( $result->at(0), 8, 'element at 0 is 8' );
    is( $result->at(1), 9, 'element at 1 is 9' );
    is( $result->at(2), 4, 'element at 2 is 4' );
};

subtest 'neg method - tensor negation' => sub {
    my $t = Tensor->initialize([3], [1, -2, 3]);
    my $result = $t->neg;

    isa_ok( $result, 'Tensor', 'neg returns a Tensor' );
    is( $result->at(0), -1, 'element at 0 is -1' );
    is( $result->at(1), 2, 'element at 1 is 2' );
    is( $result->at(2), -3, 'element at 2 is -3' );
};

subtest 'neg method - using overloaded - operator (unary)' => sub {
    my $t = Tensor->initialize([3], [1, -2, 3]);
    my $result = -$t;

    isa_ok( $result, 'Tensor', 'unary - operator returns a Tensor' );
    is( $result->at(0), -1, 'element at 0 is -1' );
    is( $result->at(1), 2, 'element at 1 is 2' );
    is( $result->at(2), -3, 'element at 2 is -3' );
};

subtest 'abs method - tensor absolute value' => sub {
    my $t = Tensor->initialize([3], [-5, 0, 5]);
    my $result = $t->abs;

    isa_ok( $result, 'Tensor', 'abs returns a Tensor' );
    is( $result->at(0), 5, 'element at 0 is 5' );
    is( $result->at(1), 0, 'element at 1 is 0' );
    is( $result->at(2), 5, 'element at 2 is 5' );
};

subtest 'math operations - 2D tensors' => sub {
    my $t1 = Tensor->initialize([2, 2], [1, 2, 3, 4]);
    my $t2 = Tensor->initialize([2, 2], [2, 2, 2, 2]);

    my $add_result = $t1 + $t2;
    is( $add_result->at(0, 0), 3, 'addition (0,0)' );
    is( $add_result->at(1, 1), 6, 'addition (1,1)' );

    my $mul_result = $t1 * $t2;
    is( $mul_result->at(0, 0), 2, 'multiplication (0,0)' );
    is( $mul_result->at(1, 1), 8, 'multiplication (1,1)' );

    my $sub_result = $t1 - $t2;
    is( $sub_result->at(0, 0), -1, 'subtraction (0,0)' );
    is( $sub_result->at(1, 1), 2, 'subtraction (1,1)' );
};

subtest 'math operations - 3D tensors' => sub {
    my $t1 = Tensor->initialize([2, 2, 2], [1..8]);
    my $t2 = Tensor->initialize([2, 2, 2], [1..8]);

    my $add_result = $t1 + $t2;
    is( $add_result->at(0, 0, 0), 2, 'addition (0,0,0) is 2' );
    is( $add_result->at(1, 1, 1), 16, 'addition (1,1,1) is 16' );

    my $mul_result = $t1 * $t2;
    is( $mul_result->at(0, 0, 0), 1, 'multiplication (0,0,0) is 1' );
    is( $mul_result->at(1, 1, 1), 64, 'multiplication (1,1,1) is 64' );
};

subtest 'math operations - with floating point numbers' => sub {
    my $t1 = Tensor->initialize([3], [1.5, 2.5, 3.5]);
    my $t2 = Tensor->initialize([3], [0.5, 0.5, 0.5]);

    my $add_result = $t1 + $t2;
    is( $add_result->at(0), 2.0, 'addition with floats' );
    is( $add_result->at(1), 3.0, 'addition with floats' );

    my $sub_result = $t1 - $t2;
    is( $sub_result->at(0), 1.0, 'subtraction with floats' );
    is( $sub_result->at(1), 2.0, 'subtraction with floats' );

    my $mul_result = $t1 * 2;
    is( $mul_result->at(0), 3.0, 'multiplication with floats' );
    is( $mul_result->at(1), 5.0, 'multiplication with floats' );
};

subtest 'chained operations' => sub {
    my $t = Tensor->initialize([3], [1, 2, 3]);

    # (t + 5) * 2
    my $result = ($t + 5) * 2;
    is( $result->at(0), 12, 'chained operation result at 0 is 12 ((1+5)*2)' );
    is( $result->at(1), 14, 'chained operation result at 1 is 14 ((2+5)*2)' );
    is( $result->at(2), 16, 'chained operation result at 2 is 16 ((3+5)*2)' );
};

done_testing;

__END__
