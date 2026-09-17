use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Matrix;

my $matrix = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

subtest 'concat method - basic horizontal concatenation' => sub {
    # Create two 2x2 matrices
    my $m1 = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $m2 = Matrix->new( shape => [2, 2], data => [5, 6, 7, 8] );

    # Concatenate horizontally: [[1,2],[3,4]] concat [[5,6],[7,8]]
    # Result should be [[1,2,5,6],[3,4,7,8]]
    my $result = Matrix->concat($m1, $m2);

    isa_ok( $result, 'Matrix', 'concat returns a Matrix' );
    is( $result->rows, 2, 'result matrix has 2 rows' );
    is( $result->cols, 4, 'result matrix has 4 columns' );
    is( $result->at(0, 0), 1, 'element at (0,0) is 1' );
    is( $result->at(0, 1), 2, 'element at (0,1) is 2' );
    is( $result->at(0, 2), 5, 'element at (0,2) is 5' );
    is( $result->at(0, 3), 6, 'element at (0,3) is 6' );
    is( $result->at(1, 0), 3, 'element at (1,0) is 3' );
    is( $result->at(1, 1), 4, 'element at (1,1) is 4' );
    is( $result->at(1, 2), 7, 'element at (1,2) is 7' );
    is( $result->at(1, 3), 8, 'element at (1,3) is 8' );
};

subtest 'concat method - with different matrix sizes' => sub {
    # 2x3 matrix concat 2x2 matrix = 2x5 matrix
    my $m1 = Matrix->new( shape => [2, 3], data => [1, 2, 3, 4, 5, 6] );
    my $m2 = Matrix->new( shape => [2, 2], data => [7, 8, 9, 10] );

    # [[1,2,3],[4,5,6]] concat [[7,8],[9,10]]
    # Result: [[1,2,3,7,8],[4,5,6,9,10]]
    my $result = Matrix->concat($m1, $m2);

    isa_ok( $result, 'Matrix', 'concat returns a Matrix' );
    is( $result->rows, 2, 'result matrix has 2 rows' );
    is( $result->cols, 5, 'result matrix has 5 columns' );
    is( $result->at(0, 0), 1, 'element at (0,0) is 1' );
    is( $result->at(0, 1), 2, 'element at (0,1) is 2' );
    is( $result->at(0, 2), 3, 'element at (0,2) is 3' );
    is( $result->at(0, 3), 7, 'element at (0,3) is 7' );
    is( $result->at(0, 4), 8, 'element at (0,4) is 8' );
    is( $result->at(1, 0), 4, 'element at (1,0) is 4' );
    is( $result->at(1, 1), 5, 'element at (1,1) is 5' );
    is( $result->at(1, 2), 6, 'element at (1,2) is 6' );
    is( $result->at(1, 3), 9, 'element at (1,3) is 9' );
    is( $result->at(1, 4), 10, 'element at (1,4) is 10' );

    # 3x2 matrix concat 3x1 matrix = 3x3 matrix
    my $m3 = Matrix->new( shape => [3, 2], data => [1, 2, 3, 4, 5, 6] );
    my $m4 = Matrix->new( shape => [3, 1], data => [7, 8, 9] );

    my $result2 = Matrix->concat($m3, $m4);

    isa_ok( $result2, 'Matrix', 'concat returns a Matrix' );
    is( $result2->rows, 3, 'result matrix has 3 rows' );
    is( $result2->cols, 3, 'result matrix has 3 columns' );
    is( $result2->at(0, 0), 1, 'element at (0,0) is 1' );
    is( $result2->at(0, 1), 2, 'element at (0,1) is 2' );
    is( $result2->at(0, 2), 7, 'element at (0,2) is 7' );
    is( $result2->at(1, 0), 3, 'element at (1,0) is 3' );
    is( $result2->at(1, 1), 4, 'element at (1,1) is 4' );
    is( $result2->at(1, 2), 8, 'element at (1,2) is 8' );
    is( $result2->at(2, 0), 5, 'element at (2,0) is 5' );
    is( $result2->at(2, 1), 6, 'element at (2,1) is 6' );
    is( $result2->at(2, 2), 9, 'element at (2,2) is 9' );
};

subtest 'concat method - with single column matrices' => sub {
    # 2x1 matrix concat 2x1 matrix = 2x2 matrix
    my $m1 = Matrix->new( shape => [2, 1], data => [1, 2] );
    my $m2 = Matrix->new( shape => [2, 1], data => [3, 4] );

    my $result = Matrix->concat($m1, $m2);

    isa_ok( $result, 'Matrix', 'concat returns a Matrix' );
    is( $result->rows, 2, 'result matrix has 2 rows' );
    is( $result->cols, 2, 'result matrix has 2 columns' );
    is( $result->at(0, 0), 1, 'element at (0,0) is 1' );
    is( $result->at(0, 1), 3, 'element at (0,1) is 3' );
    is( $result->at(1, 0), 2, 'element at (1,0) is 2' );
    is( $result->at(1, 1), 4, 'element at (1,1) is 4' );
};

subtest 'concat method - with floating point numbers' => sub {
    my $m1 = Matrix->new( shape => [2, 2], data => [1.5, 2.5, 3.5, 4.5] );
    my $m2 = Matrix->new( shape => [2, 2], data => [5.5, 6.5, 7.5, 8.5] );

    my $result = Matrix->concat($m1, $m2);

    isa_ok( $result, 'Matrix', 'concat returns a Matrix' );
    is( $result->rows, 2, 'result matrix has 2 rows' );
    is( $result->cols, 4, 'result matrix has 4 columns' );
    is( $result->at(0, 0), 1.5, 'element at (0,0) is 1.5' );
    is( $result->at(0, 1), 2.5, 'element at (0,1) is 2.5' );
    is( $result->at(0, 2), 5.5, 'element at (0,2) is 5.5' );
    is( $result->at(0, 3), 6.5, 'element at (0,3) is 6.5' );
    is( $result->at(1, 0), 3.5, 'element at (1,0) is 3.5' );
    is( $result->at(1, 1), 4.5, 'element at (1,1) is 4.5' );
    is( $result->at(1, 2), 7.5, 'element at (1,2) is 7.5' );
    is( $result->at(1, 3), 8.5, 'element at (1,3) is 8.5' );
};

subtest 'concat method - error conditions' => sub {
    # Test with matrices having different number of rows
    my $m1 = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $m2 = Matrix->new( shape => [3, 2], data => [5, 6, 7, 8, 9, 10] );

    my $error;
    { local $@; eval { Matrix->concat($m1, $m2) }; $error = $@ }
    like $error, qr/Rows must be equal to concat/, 'concat with different row counts should cause error';

    # Test with matrices having different number of rows (reverse order)
    { local $@; eval { Matrix->concat($m2, $m1) }; $error = $@ }
    like $error, qr/Rows must be equal to concat/, 'concat with different row counts should cause error (reverse order)';
};

subtest 'concat method - edge cases' => sub {
    # Test with single element matrices
    my $m1 = Matrix->new( shape => [1, 1], data => [42] );
    my $m2 = Matrix->new( shape => [1, 1], data => [99] );

    my $result = Matrix->concat($m1, $m2);

    isa_ok( $result, 'Matrix', 'concat returns a Matrix' );
    is( $result->rows, 1, 'result matrix has 1 row' );
    is( $result->cols, 2, 'result matrix has 2 columns' );
    is( $result->at(0, 0), 42, 'element at (0,0) is 42' );
    is( $result->at(0, 1), 99, 'element at (0,1) is 99' );

    # Test with zero matrices
    my $zeros1 = Matrix->new( shape => [2, 2], data => [0, 0, 0, 0] );
    my $zeros2 = Matrix->new( shape => [2, 2], data => [0, 0, 0, 0] );

    my $result_zeros = Matrix->concat($zeros1, $zeros2);

    isa_ok( $result_zeros, 'Matrix', 'concat returns a Matrix' );
    is( $result_zeros->rows, 2, 'result matrix has 2 rows' );
    is( $result_zeros->cols, 4, 'result matrix has 4 columns' );

    for my $i (0..1) {
        for my $j (0..3) {
            is( $result_zeros->at($i, $j), 0, "element at ($i,$j) is 0" );
        }
    }
};

subtest 'stack method - basic vertical stacking' => sub {
    # Create two 2x2 matrices
    my $m1 = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $m2 = Matrix->new( shape => [2, 2], data => [5, 6, 7, 8] );

    # Stack vertically: [[1,2],[3,4]] stack [[5,6],[7,8]]
    # Result should be [[1,2],[3,4],[5,6],[7,8]]
    my $result = Matrix->stack($m1, $m2);

    isa_ok( $result, 'Matrix', 'stack returns a Matrix' );
    is( $result->rows, 4, 'result matrix has 4 rows' );
    is( $result->cols, 2, 'result matrix has 2 columns' );
    is( $result->at(0, 0), 1, 'element at (0,0) is 1' );
    is( $result->at(0, 1), 2, 'element at (0,1) is 2' );
    is( $result->at(1, 0), 3, 'element at (1,0) is 3' );
    is( $result->at(1, 1), 4, 'element at (1,1) is 4' );
    is( $result->at(2, 0), 5, 'element at (2,0) is 5' );
    is( $result->at(2, 1), 6, 'element at (2,1) is 6' );
    is( $result->at(3, 0), 7, 'element at (3,0) is 7' );
    is( $result->at(3, 1), 8, 'element at (3,1) is 8' );
};

subtest 'stack method - with different matrix sizes' => sub {
    # 2x3 matrix stack 1x3 matrix = 3x3 matrix
    my $m1 = Matrix->new( shape => [2, 3], data => [1, 2, 3, 4, 5, 6] );
    my $m2 = Matrix->new( shape => [1, 3], data => [7, 8, 9] );

    # [[1,2,3],[4,5,6]] stack [[7,8,9]]
    # Result: [[1,2,3],[4,5,6],[7,8,9]]
    my $result = Matrix->stack($m1, $m2);

    isa_ok( $result, 'Matrix', 'stack returns a Matrix' );
    is( $result->rows, 3, 'result matrix has 3 rows' );
    is( $result->cols, 3, 'result matrix has 3 columns' );
    is( $result->at(0, 0), 1, 'element at (0,0) is 1' );
    is( $result->at(0, 1), 2, 'element at (0,1) is 2' );
    is( $result->at(0, 2), 3, 'element at (0,2) is 3' );
    is( $result->at(1, 0), 4, 'element at (1,0) is 4' );
    is( $result->at(1, 1), 5, 'element at (1,1) is 5' );
    is( $result->at(1, 2), 6, 'element at (1,2) is 6' );
    is( $result->at(2, 0), 7, 'element at (2,0) is 7' );
    is( $result->at(2, 1), 8, 'element at (2,1) is 8' );
    is( $result->at(2, 2), 9, 'element at (2,2) is 9' );

    # 1x2 matrix stack 2x2 matrix = 3x2 matrix
    my $m3 = Matrix->new( shape => [1, 2], data => [1, 2] );
    my $m4 = Matrix->new( shape => [2, 2], data => [3, 4, 5, 6] );

    my $result2 = Matrix->stack($m3, $m4);

    isa_ok( $result2, 'Matrix', 'stack returns a Matrix' );
    is( $result2->rows, 3, 'result matrix has 3 rows' );
    is( $result2->cols, 2, 'result matrix has 2 columns' );
    is( $result2->at(0, 0), 1, 'element at (0,0) is 1' );
    is( $result2->at(0, 1), 2, 'element at (0,1) is 2' );
    is( $result2->at(1, 0), 3, 'element at (1,0) is 3' );
    is( $result2->at(1, 1), 4, 'element at (1,1) is 4' );
    is( $result2->at(2, 0), 5, 'element at (2,0) is 5' );
    is( $result2->at(2, 1), 6, 'element at (2,1) is 6' );
};

subtest 'stack method - with single row matrices' => sub {
    # 1x2 matrix stack 1x2 matrix = 2x2 matrix
    my $m1 = Matrix->new( shape => [1, 2], data => [1, 2] );
    my $m2 = Matrix->new( shape => [1, 2], data => [3, 4] );

    my $result = Matrix->stack($m1, $m2);

    isa_ok( $result, 'Matrix', 'stack returns a Matrix' );
    is( $result->rows, 2, 'result matrix has 2 rows' );
    is( $result->cols, 2, 'result matrix has 2 columns' );
    is( $result->at(0, 0), 1, 'element at (0,0) is 1' );
    is( $result->at(0, 1), 2, 'element at (0,1) is 2' );
    is( $result->at(1, 0), 3, 'element at (1,0) is 3' );
    is( $result->at(1, 1), 4, 'element at (1,1) is 4' );
};

subtest 'stack method - with floating point numbers' => sub {
    my $m1 = Matrix->new( shape => [2, 2], data => [1.5, 2.5, 3.5, 4.5] );
    my $m2 = Matrix->new( shape => [2, 2], data => [5.5, 6.5, 7.5, 8.5] );

    my $result = Matrix->stack($m1, $m2);

    isa_ok( $result, 'Matrix', 'stack returns a Matrix' );
    is( $result->rows, 4, 'result matrix has 4 rows' );
    is( $result->cols, 2, 'result matrix has 2 columns' );
    is( $result->at(0, 0), 1.5, 'element at (0,0) is 1.5' );
    is( $result->at(0, 1), 2.5, 'element at (0,1) is 2.5' );
    is( $result->at(1, 0), 3.5, 'element at (1,0) is 3.5' );
    is( $result->at(1, 1), 4.5, 'element at (1,1) is 4.5' );
    is( $result->at(2, 0), 5.5, 'element at (2,0) is 5.5' );
    is( $result->at(2, 1), 6.5, 'element at (2,1) is 6.5' );
    is( $result->at(3, 0), 7.5, 'element at (3,0) is 7.5' );
    is( $result->at(3, 1), 8.5, 'element at (3,1) is 8.5' );
};

subtest 'stack method - error conditions' => sub {
    # Test with matrices having different number of columns
    my $m1 = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );
    my $m2 = Matrix->new( shape => [2, 3], data => [5, 6, 7, 8, 9, 10] );

    my $error;
    { local $@; eval { Matrix->stack($m1, $m2) }; $error = $@ }
    like $error, qr/Cols must be equal to stack/, 'stack with different column counts should cause error';

    # Test with matrices having different number of columns (reverse order)
    { local $@; eval { Matrix->stack($m2, $m1) }; $error = $@ }
    like $error, qr/Cols must be equal to stack/, 'stack with different column counts should cause error (reverse order)';
};

subtest 'stack method - edge cases' => sub {
    # Test with single element matrices
    my $m1 = Matrix->new( shape => [1, 1], data => [42] );
    my $m2 = Matrix->new( shape => [1, 1], data => [99] );

    my $result = Matrix->stack($m1, $m2);

    isa_ok( $result, 'Matrix', 'stack returns a Matrix' );
    is( $result->rows, 2, 'result matrix has 2 rows' );
    is( $result->cols, 1, 'result matrix has 1 column' );
    is( $result->at(0, 0), 42, 'element at (0,0) is 42' );
    is( $result->at(1, 0), 99, 'element at (1,0) is 99' );

    # Test with zero matrices
    my $zeros1 = Matrix->new( shape => [2, 2], data => [0, 0, 0, 0] );
    my $zeros2 = Matrix->new( shape => [2, 2], data => [0, 0, 0, 0] );

    my $result_zeros = Matrix->stack($zeros1, $zeros2);

    isa_ok( $result_zeros, 'Matrix', 'stack returns a Matrix' );
    is( $result_zeros->rows, 4, 'result matrix has 4 rows' );
    is( $result_zeros->cols, 2, 'result matrix has 2 columns' );

    for my $i (0..3) {
        for my $j (0..1) {
            is( $result_zeros->at($i, $j), 0, "element at ($i,$j) is 0" );
        }
    }
};

subtest 'concat and stack methods - with identity matrices' => sub {
    my $eye2 = Matrix->eye(2);
    my $eye2_copy = Matrix->eye(2);

    # Test concat with identity matrices
    my $concat_result = Matrix->concat($eye2, $eye2_copy);

    isa_ok( $concat_result, 'Matrix', 'concat returns a Matrix' );
    is( $concat_result->rows, 2, 'result matrix has 2 rows' );
    is( $concat_result->cols, 4, 'result matrix has 4 columns' );
    is( $concat_result->at(0, 0), 1, 'element at (0,0) is 1' );
    is( $concat_result->at(0, 1), 0, 'element at (0,1) is 0' );
    is( $concat_result->at(0, 2), 1, 'element at (0,2) is 1' );
    is( $concat_result->at(0, 3), 0, 'element at (0,3) is 0' );
    is( $concat_result->at(1, 0), 0, 'element at (1,0) is 0' );
    is( $concat_result->at(1, 1), 1, 'element at (1,1) is 1' );
    is( $concat_result->at(1, 2), 0, 'element at (1,2) is 0' );
    is( $concat_result->at(1, 3), 1, 'element at (1,3) is 1' );

    # Test stack with identity matrices
    my $stack_result = Matrix->stack($eye2, $eye2_copy);

    isa_ok( $stack_result, 'Matrix', 'stack returns a Matrix' );
    is( $stack_result->rows, 4, 'result matrix has 4 rows' );
    is( $stack_result->cols, 2, 'result matrix has 2 columns' );
    is( $stack_result->at(0, 0), 1, 'element at (0,0) is 1' );
    is( $stack_result->at(0, 1), 0, 'element at (0,1) is 0' );
    is( $stack_result->at(1, 0), 0, 'element at (1,0) is 0' );
    is( $stack_result->at(1, 1), 1, 'element at (1,1) is 1' );
    is( $stack_result->at(2, 0), 1, 'element at (2,0) is 1' );
    is( $stack_result->at(2, 1), 0, 'element at (2,1) is 0' );
    is( $stack_result->at(3, 0), 0, 'element at (3,0) is 0' );
    is( $stack_result->at(3, 1), 1, 'element at (3,1) is 1' );
};

done_testing;

__END__
