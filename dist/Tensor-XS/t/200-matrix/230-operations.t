use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Matrix;
use Vector;

my $matrix = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

subtest 'matrix_multiply method - basic matrix-matrix multiplication' => sub {
    # Create two 2x2 matrices
    my $m1 = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $m2 = Matrix->new( shape => [2, 2], data => [5, 6, 7, 8] );

    # Matrix multiplication: [[1,2],[3,4]] * [[5,6],[7,8]]
    # Result should be [[1*5+2*7, 1*6+2*8], [3*5+4*7, 3*6+4*8]] = [[19,22],[43,50]]
    my $result = $m1->matrix_multiply($m2);

    isa_ok( $result, 'Matrix', 'matrix_multiply returns a Matrix' );
    is( $result->rows, 2, 'result matrix has 2 rows' );
    is( $result->cols, 2, 'result matrix has 2 columns' );
    is( $result->at(0, 0), 19, 'element at (0,0) is 19' );
    is( $result->at(0, 1), 22, 'element at (0,1) is 22' );
    is( $result->at(1, 0), 43, 'element at (1,0) is 43' );
    is( $result->at(1, 1), 50, 'element at (1,1) is 50' );
};

subtest 'matrix_multiply method - with different matrix sizes' => sub {
    # 2x3 matrix * 3x2 matrix = 2x2 matrix
    my $m1 = Matrix->new( shape => [2, 3], data => [1, 2, 3, 4, 5, 6] );
    my $m2 = Matrix->new( shape => [3, 2], data => [7, 8, 9, 10, 11, 12] );

    # [[1,2,3],[4,5,6]] * [[7,8],[9,10],[11,12]]
    # Result: [[1*7+2*9+3*11, 1*8+2*10+3*12], [4*7+5*9+6*11, 4*8+5*10+6*12]]
    # = [[58,64],[139,154]]
    my $result = $m1->matrix_multiply($m2);

    isa_ok( $result, 'Matrix', 'matrix_multiply returns a Matrix' );
    is( $result->rows, 2, 'result matrix has 2 rows' );
    is( $result->cols, 2, 'result matrix has 2 columns' );
    is( $result->at(0, 0), 58, 'element at (0,0) is 58' );
    is( $result->at(0, 1), 64, 'element at (0,1) is 64' );
    is( $result->at(1, 0), 139, 'element at (1,0) is 139' );
    is( $result->at(1, 1), 154, 'element at (1,1) is 154' );

    # 3x2 matrix * 2x4 matrix = 3x4 matrix
    my $m3 = Matrix->new( shape => [3, 2], data => [1, 2, 3, 4, 5, 6] );
    my $m4 = Matrix->new( shape => [2, 4], data => [1, 2, 3, 4, 5, 6, 7, 8] );

    my $result2 = $m3->matrix_multiply($m4);

    isa_ok( $result2, 'Matrix', 'matrix_multiply returns a Matrix' );
    is( $result2->rows, 3, 'result matrix has 3 rows' );
    is( $result2->cols, 4, 'result matrix has 4 columns' );

    # Check first row: [1,2] * [[1,2,3,4],[5,6,7,8]] = [11,14,17,20]
    is( $result2->at(0, 0), 11, 'element at (0,0) is 11' );
    is( $result2->at(0, 1), 14, 'element at (0,1) is 14' );
    is( $result2->at(0, 2), 17, 'element at (0,2) is 17' );
    is( $result2->at(0, 3), 20, 'element at (0,3) is 20' );
};

subtest 'matrix_multiply method - with identity matrix' => sub {
    my $m = Matrix->new( shape => [3, 3], data => [1, 2, 3, 4, 5, 6, 7, 8, 9] );
    my $identity = Matrix->eye(3);

    # Matrix * Identity = Matrix
    my $result = $m->matrix_multiply($identity);

    isa_ok( $result, 'Matrix', 'matrix_multiply returns a Matrix' );
    is( $result->rows, 3, 'result matrix has 3 rows' );
    is( $result->cols, 3, 'result matrix has 3 columns' );

    # Check that result equals original matrix
    for my $i (0..2) {
        for my $j (0..2) {
            is( $result->at($i, $j), $m->at($i, $j), "element at ($i,$j) unchanged" );
        }
    }

    # Identity * Matrix = Matrix
    my $result2 = $identity->matrix_multiply($m);

    isa_ok( $result2, 'Matrix', 'matrix_multiply returns a Matrix' );

    # Check that result equals original matrix
    for my $i (0..2) {
        for my $j (0..2) {
            is( $result2->at($i, $j), $m->at($i, $j), "element at ($i,$j) unchanged" );
        }
    }
};

subtest 'matrix_multiply method - with diagonal matrix' => sub {
    my $v = Vector->initialize(3, [2, 3, 4] );
    my $diagonal = Matrix->diagonal($v);
    my $m = Matrix->new( shape => [3, 3], data => [1, 2, 3, 4, 5, 6, 7, 8, 9] );

    # Matrix * Diagonal = scaled rows
    my $result = $m->matrix_multiply($diagonal);

    isa_ok( $result, 'Matrix', 'matrix_multiply returns a Matrix' );
    is( $result->rows, 3, 'result matrix has 3 rows' );
    is( $result->cols, 3, 'result matrix has 3 columns' );

    # Check matrix multiplication with diagonal matrix
    # Row 0: [1,2,3] * [[2,0,0],[0,3,0],[0,0,4]] = [2,6,12]
    is( $result->at(0, 0), 2, 'element at (0,0) is 2' );
    is( $result->at(0, 1), 6, 'element at (0,1) is 6' );
    is( $result->at(0, 2), 12, 'element at (0,2) is 12' );

    # Row 1: [4,5,6] * [[2,0,0],[0,3,0],[0,0,4]] = [8,15,24]
    is( $result->at(1, 0), 8, 'element at (1,0) is 8' );
    is( $result->at(1, 1), 15, 'element at (1,1) is 15' );
    is( $result->at(1, 2), 24, 'element at (1,2) is 24' );

    # Row 2: [7,8,9] * [[2,0,0],[0,3,0],[0,0,4]] = [14,24,36]
    is( $result->at(2, 0), 14, 'element at (2,0) is 14' );
    is( $result->at(2, 1), 24, 'element at (2,1) is 24' );
    is( $result->at(2, 2), 36, 'element at (2,2) is 36' );
};

subtest 'matrix_multiply method - with zero matrix' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $zeros = Matrix->new( shape => [2, 2], data => [0, 0, 0, 0] );

    # Matrix * Zero = Zero
    my $result = $m->matrix_multiply($zeros);

    isa_ok( $result, 'Matrix', 'matrix_multiply returns a Matrix' );
    is( $result->rows, 2, 'result matrix has 2 rows' );
    is( $result->cols, 2, 'result matrix has 2 columns' );

    for my $i (0..1) {
        for my $j (0..1) {
            is( $result->at($i, $j), 0, "element at ($i,$j) is 0" );
        }
    }

    # Zero * Matrix = Zero
    my $result2 = $zeros->matrix_multiply($m);

    isa_ok( $result2, 'Matrix', 'matrix_multiply returns a Matrix' );

    for my $i (0..1) {
        for my $j (0..1) {
            is( $result2->at($i, $j), 0, "element at ($i,$j) is 0" );
        }
    }
};

subtest 'matrix_multiply method - with floating point numbers' => sub {
    my $m1 = Matrix->new( shape => [2, 2], data => [1.5, 2.5, 3.5, 4.5] );
    my $m2 = Matrix->new( shape => [2, 2], data => [2.0, 3.0, 4.0, 5.0] );

    my $result = $m1->matrix_multiply($m2);

    isa_ok( $result, 'Matrix', 'matrix_multiply returns a Matrix' );
    is( $result->rows, 2, 'result matrix has 2 rows' );
    is( $result->cols, 2, 'result matrix has 2 columns' );

    # Check elements with floating point precision
    is( $result->at(0, 0), 13.0, 'element at (0,0) is 13.0' );
    is( $result->at(0, 1), 17.0, 'element at (0,1) is 17.0' );
    is( $result->at(1, 0), 25.0, 'element at (1,0) is 25.0' );
    is( $result->at(1, 1), 33.0, 'element at (1,1) is 33.0' );
};

subtest 'matrix_multiply method - with vector (delegates to vector)' => sub {
    my $m = Matrix->new( shape => [2, 3], data => [1, 2, 3, 4, 5, 6] );
    my $v = Vector->initialize(3, [2, 3, 4] );

    # Matrix * Vector should delegate to vector's matrix_multiply method
    my $result = $m->matrix_multiply($v);

    isa_ok( $result, 'Vector', 'matrix_multiply with vector returns a Vector' );
    is( $result->size, 2, 'result vector has size 2' );

    # Check elements: [1,2,3]·[2,3,4] = 20, [4,5,6]·[2,3,4] = 47
    is( $result->at(0), 20, 'first element is 20' );
    is( $result->at(1), 47, 'second element is 47' );
};

subtest 'shift_horz method - basic horizontal shifting' => sub {
    my $m = Matrix->new( shape => [3, 3], data => [1, 2, 3, 4, 5, 6, 7, 8, 9] );

    # Shift right by 1
    my $shifted_right = $m->shift_horz(1);

    isa_ok( $shifted_right, 'Matrix', 'shift_horz returns a Matrix' );
    is( $shifted_right->rows, 3, 'result matrix has 3 rows' );
    is( $shifted_right->cols, 3, 'result matrix has 3 columns' );

    # Check that elements shifted right, with zeros filling from left
    # Original: [[1,2,3],[4,5,6],[7,8,9]]
    # Shifted:  [[0,1,2],[0,4,5],[0,7,8]]
    is( $shifted_right->at(0, 0), 0, 'element at (0,0) is 0' );
    is( $shifted_right->at(0, 1), 1, 'element at (0,1) is 1' );
    is( $shifted_right->at(0, 2), 2, 'element at (0,2) is 2' );
    is( $shifted_right->at(1, 0), 0, 'element at (1,0) is 0' );
    is( $shifted_right->at(1, 1), 4, 'element at (1,1) is 4' );
    is( $shifted_right->at(1, 2), 5, 'element at (1,2) is 5' );
    is( $shifted_right->at(2, 0), 0, 'element at (2,0) is 0' );
    is( $shifted_right->at(2, 1), 7, 'element at (2,1) is 7' );
    is( $shifted_right->at(2, 2), 8, 'element at (2,2) is 8' );
};

subtest 'shift_horz method - shift left (negative shift)' => sub {
    my $m = Matrix->new( shape => [3, 3], data => [1, 2, 3, 4, 5, 6, 7, 8, 9] );

    # Shift left by 1
    my $shifted_left = $m->shift_horz(-1);

    isa_ok( $shifted_left, 'Matrix', 'shift_horz returns a Matrix' );
    is( $shifted_left->rows, 3, 'result matrix has 3 rows' );
    is( $shifted_left->cols, 3, 'result matrix has 3 columns' );

    # Check that elements shifted left, with zeros filling from right
    # Original: [[1,2,3],[4,5,6],[7,8,9]]
    # Shifted:  [[2,3,0],[5,6,0],[8,9,0]]
    is( $shifted_left->at(0, 0), 2, 'element at (0,0) is 2' );
    is( $shifted_left->at(0, 1), 3, 'element at (0,1) is 3' );
    is( $shifted_left->at(0, 2), 0, 'element at (0,2) is 0' );
    is( $shifted_left->at(1, 0), 5, 'element at (1,0) is 5' );
    is( $shifted_left->at(1, 1), 6, 'element at (1,1) is 6' );
    is( $shifted_left->at(1, 2), 0, 'element at (1,2) is 0' );
    is( $shifted_left->at(2, 0), 8, 'element at (2,0) is 8' );
    is( $shifted_left->at(2, 1), 9, 'element at (2,1) is 9' );
    is( $shifted_left->at(2, 2), 0, 'element at (2,2) is 0' );
};

subtest 'shift_horz method - larger shifts' => sub {
    my $m = Matrix->new( shape => [3, 3], data => [1, 2, 3, 4, 5, 6, 7, 8, 9] );

    # Shift right by 2
    my $shifted_right2 = $m->shift_horz(2);

    isa_ok( $shifted_right2, 'Matrix', 'shift_horz returns a Matrix' );

    # Check that elements shifted right by 2, with zeros filling from left
    # Original: [[1,2,3],[4,5,6],[7,8,9]]
    # Shifted:  [[0,0,1],[0,0,4],[0,0,7]]
    is( $shifted_right2->at(0, 0), 0, 'element at (0,0) is 0' );
    is( $shifted_right2->at(0, 1), 0, 'element at (0,1) is 0' );
    is( $shifted_right2->at(0, 2), 1, 'element at (0,2) is 1' );
    is( $shifted_right2->at(1, 0), 0, 'element at (1,0) is 0' );
    is( $shifted_right2->at(1, 1), 0, 'element at (1,1) is 0' );
    is( $shifted_right2->at(1, 2), 4, 'element at (1,2) is 4' );
    is( $shifted_right2->at(2, 0), 0, 'element at (2,0) is 0' );
    is( $shifted_right2->at(2, 1), 0, 'element at (2,1) is 0' );
    is( $shifted_right2->at(2, 2), 7, 'element at (2,2) is 7' );

    # Shift left by 2
    my $shifted_left2 = $m->shift_horz(-2);

    isa_ok( $shifted_left2, 'Matrix', 'shift_horz returns a Matrix' );

    # Check that elements shifted left by 2, with zeros filling from right
    # Original: [[1,2,3],[4,5,6],[7,8,9]]
    # Shifted:  [[3,0,0],[6,0,0],[9,0,0]]
    is( $shifted_left2->at(0, 0), 3, 'element at (0,0) is 3' );
    is( $shifted_left2->at(0, 1), 0, 'element at (0,1) is 0' );
    is( $shifted_left2->at(0, 2), 0, 'element at (0,2) is 0' );
    is( $shifted_left2->at(1, 0), 6, 'element at (1,0) is 6' );
    is( $shifted_left2->at(1, 1), 0, 'element at (1,1) is 0' );
    is( $shifted_left2->at(1, 2), 0, 'element at (1,2) is 0' );
    is( $shifted_left2->at(2, 0), 9, 'element at (2,0) is 9' );
    is( $shifted_left2->at(2, 1), 0, 'element at (2,1) is 0' );
    is( $shifted_left2->at(2, 2), 0, 'element at (2,2) is 0' );
};

subtest 'shift_horz method - edge cases' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

    # Shift by 0 (no change)
    my $shifted_zero = $m->shift_horz(0);

    isa_ok( $shifted_zero, 'Matrix', 'shift_horz returns a Matrix' );

    # Check that matrix is unchanged
    for my $i (0..1) {
        for my $j (0..1) {
            is( $shifted_zero->at($i, $j), $m->at($i, $j), "element at ($i,$j) unchanged" );
        }
    }

    # Shift by more than matrix width (should result in all zeros)
    my $shifted_all = $m->shift_horz(3);

    isa_ok( $shifted_all, 'Matrix', 'shift_horz returns a Matrix' );

    for my $i (0..1) {
        for my $j (0..1) {
            is( $shifted_all->at($i, $j), 0, "element at ($i,$j) is 0" );
        }
    }

    # Shift left by more than matrix width (should result in all zeros)
    my $shifted_all_left = $m->shift_horz(-3);

    isa_ok( $shifted_all_left, 'Matrix', 'shift_horz returns a Matrix' );

    for my $i (0..1) {
        for my $j (0..1) {
            is( $shifted_all_left->at($i, $j), 0, "element at ($i,$j) is 0" );
        }
    }
};

subtest 'shift_horz method - with different matrix sizes' => sub {
    # Test with 2x3 matrix
    my $m1 = Matrix->new( shape => [2, 3], data => [1, 2, 3, 4, 5, 6] );

    my $shifted1 = $m1->shift_horz(1);

    isa_ok( $shifted1, 'Matrix', 'shift_horz returns a Matrix' );
    is( $shifted1->rows, 2, 'result matrix has 2 rows' );
    is( $shifted1->cols, 3, 'result matrix has 3 columns' );

    # Check shifted elements
    is( $shifted1->at(0, 0), 0, 'element at (0,0) is 0' );
    is( $shifted1->at(0, 1), 1, 'element at (0,1) is 1' );
    is( $shifted1->at(0, 2), 2, 'element at (0,2) is 2' );
    is( $shifted1->at(1, 0), 0, 'element at (1,0) is 0' );
    is( $shifted1->at(1, 1), 4, 'element at (1,1) is 4' );
    is( $shifted1->at(1, 2), 5, 'element at (1,2) is 5' );

    # Test with 3x2 matrix
    my $m2 = Matrix->new( shape => [3, 2], data => [1, 2, 3, 4, 5, 6] );

    my $shifted2 = $m2->shift_horz(-1);

    isa_ok( $shifted2, 'Matrix', 'shift_horz returns a Matrix' );
    is( $shifted2->rows, 3, 'result matrix has 3 rows' );
    is( $shifted2->cols, 2, 'result matrix has 2 columns' );

    # Check shifted elements
    is( $shifted2->at(0, 0), 2, 'element at (0,0) is 2' );
    is( $shifted2->at(0, 1), 0, 'element at (0,1) is 0' );
    is( $shifted2->at(1, 0), 4, 'element at (1,0) is 4' );
    is( $shifted2->at(1, 1), 0, 'element at (1,1) is 0' );
    is( $shifted2->at(2, 0), 6, 'element at (2,0) is 6' );
    is( $shifted2->at(2, 1), 0, 'element at (2,1) is 0' );
};

done_testing;

__END__
