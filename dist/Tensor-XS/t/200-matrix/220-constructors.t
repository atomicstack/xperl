use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Matrix;
use Vector;

my $matrix = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

subtest 'initialize method - basic initialization' => sub {
    my $m = Matrix->initialize([2, 3], 0);

    isa_ok( $m, 'Matrix', 'initialize returns a Matrix' );
    is( $m->rows, 2, 'matrix has correct number of rows' );
    is( $m->cols, 3, 'matrix has correct number of columns' );
    is( $m->size, 6, 'matrix has correct total size' );

    # Check all elements are initialized to 0
    for my $i (0..1) {
        for my $j (0..2) {
            is( $m->at($i, $j), 0, "element at ($i,$j) is 0" );
        }
    }
};

subtest 'initialize method - with different initial values' => sub {
    my $m1 = Matrix->initialize([3, 2], 5);

    isa_ok( $m1, 'Matrix', 'initialize returns a Matrix' );
    is( $m1->rows, 3, 'matrix has correct number of rows' );
    is( $m1->cols, 2, 'matrix has correct number of columns' );

    # Check all elements are initialized to 5
    for my $i (0..2) {
        for my $j (0..1) {
            is( $m1->at($i, $j), 5, "element at ($i,$j) is 5" );
        }
    }

    my $m2 = Matrix->initialize([2, 2], -1);

    # Check all elements are initialized to -1
    for my $i (0..1) {
        for my $j (0..1) {
            is( $m2->at($i, $j), -1, "element at ($i,$j) is -1" );
        }
    }
};

subtest 'initialize method - with floating point initial values' => sub {
    my $m = Matrix->initialize([2, 3], 3.14);

    isa_ok( $m, 'Matrix', 'initialize returns a Matrix' );

    # Check all elements are initialized to 3.14
    for my $i (0..1) {
        for my $j (0..2) {
            is( $m->at($i, $j), 3.14, "element at ($i,$j) is 3.14" );
        }
    }
};

subtest 'construct method - basic construction with function' => sub {
    my $m = Matrix->construct([2, 2], sub { $_[0] + $_[1] });

    isa_ok( $m, 'Matrix', 'construct returns a Matrix' );
    is( $m->rows, 2, 'matrix has correct number of rows' );
    is( $m->cols, 2, 'matrix has correct number of columns' );

    # Check elements: (0,0)=0, (0,1)=1, (1,0)=1, (1,1)=2
    is( $m->at(0, 0), 0, 'element at (0,0) is 0' );
    is( $m->at(0, 1), 1, 'element at (0,1) is 1' );
    is( $m->at(1, 0), 1, 'element at (1,0) is 1' );
    is( $m->at(1, 1), 2, 'element at (1,1) is 2' );
};

subtest 'construct method - with multiplication function' => sub {
    my $m = Matrix->construct([3, 3], sub { $_[0] * $_[1] });

    isa_ok( $m, 'Matrix', 'construct returns a Matrix' );
    is( $m->rows, 3, 'matrix has correct number of rows' );
    is( $m->cols, 3, 'matrix has correct number of columns' );

    # Check elements: (i,j) = i * j
    is( $m->at(0, 0), 0, 'element at (0,0) is 0' );
    is( $m->at(0, 1), 0, 'element at (0,1) is 0' );
    is( $m->at(0, 2), 0, 'element at (0,2) is 0' );
    is( $m->at(1, 0), 0, 'element at (1,0) is 0' );
    is( $m->at(1, 1), 1, 'element at (1,1) is 1' );
    is( $m->at(1, 2), 2, 'element at (1,2) is 2' );
    is( $m->at(2, 0), 0, 'element at (2,0) is 0' );
    is( $m->at(2, 1), 2, 'element at (2,1) is 2' );
    is( $m->at(2, 2), 4, 'element at (2,2) is 4' );
};

subtest 'eye method - identity matrix construction' => sub {
    my $eye2 = Matrix->eye(2);

    isa_ok( $eye2, 'Matrix', 'eye returns a Matrix' );
    is( $eye2->rows, 2, '2x2 identity matrix has 2 rows' );
    is( $eye2->cols, 2, '2x2 identity matrix has 2 columns' );

    # Check identity matrix properties
    is( $eye2->at(0, 0), 1, 'element at (0,0) is 1' );
    is( $eye2->at(0, 1), 0, 'element at (0,1) is 0' );
    is( $eye2->at(1, 0), 0, 'element at (1,0) is 0' );
    is( $eye2->at(1, 1), 1, 'element at (1,1) is 1' );
};

subtest 'eye method - larger identity matrices' => sub {
    my $eye3 = Matrix->eye(3);

    isa_ok( $eye3, 'Matrix', 'eye returns a Matrix' );
    is( $eye3->rows, 3, '3x3 identity matrix has 3 rows' );
    is( $eye3->cols, 3, '3x3 identity matrix has 3 columns' );

    # Check diagonal elements are 1, off-diagonal are 0
    for my $i (0..2) {
        for my $j (0..2) {
            if ($i == $j) {
                is( $eye3->at($i, $j), 1, "diagonal element at ($i,$j) is 1" );
            } else {
                is( $eye3->at($i, $j), 0, "off-diagonal element at ($i,$j) is 0" );
            }
        }
    }

    my $eye4 = Matrix->eye(4);

    isa_ok( $eye4, 'Matrix', 'eye returns a Matrix' );
    is( $eye4->rows, 4, '4x4 identity matrix has 4 rows' );
    is( $eye4->cols, 4, '4x4 identity matrix has 4 columns' );

    # Check diagonal elements are 1, off-diagonal are 0
    for my $i (0..3) {
        for my $j (0..3) {
            if ($i == $j) {
                is( $eye4->at($i, $j), 1, "diagonal element at ($i,$j) is 1" );
            } else {
                is( $eye4->at($i, $j), 0, "off-diagonal element at ($i,$j) is 0" );
            }
        }
    }
};

subtest 'eye method - single element identity matrix' => sub {
    my $eye1 = Matrix->eye(1);

    isa_ok( $eye1, 'Matrix', 'eye returns a Matrix' );
    is( $eye1->rows, 1, '1x1 identity matrix has 1 row' );
    is( $eye1->cols, 1, '1x1 identity matrix has 1 column' );
    is( $eye1->at(0, 0), 1, 'single element is 1' );
};

subtest 'diagonal method - basic diagonal matrix construction' => sub {
    my $v = Vector->initialize(3, [2, 3, 4] );
    my $diag = Matrix->diagonal($v);

    isa_ok( $diag, 'Matrix', 'diagonal returns a Matrix' );
    is( $diag->rows, 3, 'diagonal matrix has 3 rows' );
    is( $diag->cols, 3, 'diagonal matrix has 3 columns' );

    # Check diagonal elements
    is( $diag->at(0, 0), 2, 'diagonal element at (0,0) is 2' );
    is( $diag->at(1, 1), 3, 'diagonal element at (1,1) is 3' );
    is( $diag->at(2, 2), 4, 'diagonal element at (2,2) is 4' );

    # Check off-diagonal elements are 0
    is( $diag->at(0, 1), 0, 'off-diagonal element at (0,1) is 0' );
    is( $diag->at(0, 2), 0, 'off-diagonal element at (0,2) is 0' );
    is( $diag->at(1, 0), 0, 'off-diagonal element at (1,0) is 0' );
    is( $diag->at(1, 2), 0, 'off-diagonal element at (1,2) is 0' );
    is( $diag->at(2, 0), 0, 'off-diagonal element at (2,0) is 0' );
    is( $diag->at(2, 1), 0, 'off-diagonal element at (2,1) is 0' );
};

subtest 'diagonal method - with different vector sizes' => sub {
    my $v2 = Vector->initialize(2, [5, 10] );
    my $diag2 = Matrix->diagonal($v2);

    isa_ok( $diag2, 'Matrix', 'diagonal returns a Matrix' );
    is( $diag2->rows, 2, '2x2 diagonal matrix has 2 rows' );
    is( $diag2->cols, 2, '2x2 diagonal matrix has 2 columns' );

    is( $diag2->at(0, 0), 5, 'diagonal element at (0,0) is 5' );
    is( $diag2->at(1, 1), 10, 'diagonal element at (1,1) is 10' );
    is( $diag2->at(0, 1), 0, 'off-diagonal element at (0,1) is 0' );
    is( $diag2->at(1, 0), 0, 'off-diagonal element at (1,0) is 0' );

    my $v4 = Vector->initialize(4, [1, 2, 3, 4] );
    my $diag4 = Matrix->diagonal($v4);

    isa_ok( $diag4, 'Matrix', 'diagonal returns a Matrix' );
    is( $diag4->rows, 4, '4x4 diagonal matrix has 4 rows' );
    is( $diag4->cols, 4, '4x4 diagonal matrix has 4 columns' );

    for my $i (0..3) {
        is( $diag4->at($i, $i), $i + 1, "diagonal element at ($i,$i) is " . ($i + 1) );
    }
};

subtest 'diagonal method - with floating point numbers' => sub {
    my $v = Vector->initialize(2, [1.5, 2.5] );
    my $diag = Matrix->diagonal($v);

    isa_ok( $diag, 'Matrix', 'diagonal returns a Matrix' );

    is( $diag->at(0, 0), 1.5, 'diagonal element at (0,0) is 1.5' );
    is( $diag->at(1, 1), 2.5, 'diagonal element at (1,1) is 2.5' );
    is( $diag->at(0, 1), 0, 'off-diagonal element at (0,1) is 0' );
    is( $diag->at(1, 0), 0, 'off-diagonal element at (1,0) is 0' );
};

subtest 'diagonal method - with negative numbers' => sub {
    my $v = Vector->initialize(3, [ -1, 2, -3] );
    my $diag = Matrix->diagonal($v);

    isa_ok( $diag, 'Matrix', 'diagonal returns a Matrix' );

    is( $diag->at(0, 0), -1, 'diagonal element at (0,0) is -1' );
    is( $diag->at(1, 1), 2, 'diagonal element at (1,1) is 2' );
    is( $diag->at(2, 2), -3, 'diagonal element at (2,2) is -3' );

    # Check off-diagonal elements are still 0
    is( $diag->at(0, 1), 0, 'off-diagonal element at (0,1) is 0' );
    is( $diag->at(1, 0), 0, 'off-diagonal element at (1,0) is 0' );
};

subtest 'constructor methods - edge cases' => sub {
    # Test with zero-sized matrix (should this be allowed?)
    # Note: This might cause issues, but let's test the behavior

    # Test with single element
    my $single = Matrix->initialize([1, 1], 42);
    is( $single->at(0, 0), 42, 'single element matrix initialization' );

    my $single_eye = Matrix->eye(1);
    is( $single_eye->at(0, 0), 1, 'single element identity matrix' );

    my $single_vec = Vector->initialize(1, [99] );
    my $single_diag = Matrix->diagonal($single_vec);
    is( $single_diag->at(0, 0), 99, 'single element diagonal matrix' );
};

done_testing;

__END__
