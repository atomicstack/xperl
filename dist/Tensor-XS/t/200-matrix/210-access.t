use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Matrix;

my $matrix = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

subtest 'at method - accessing elements by coordinates' => sub {
    my $m = Matrix->new( shape => [3, 3], data => [1, 2, 3, 4, 5, 6, 7, 8, 9] );

    # Test accessing elements
    is( $m->at(0, 0), 1, 'at(0,0) returns first element' );
    is( $m->at(0, 1), 2, 'at(0,1) returns second element' );
    is( $m->at(0, 2), 3, 'at(0,2) returns third element' );
    is( $m->at(1, 0), 4, 'at(1,0) returns fourth element' );
    is( $m->at(1, 1), 5, 'at(1,1) returns fifth element' );
    is( $m->at(1, 2), 6, 'at(1,2) returns sixth element' );
    is( $m->at(2, 0), 7, 'at(2,0) returns seventh element' );
    is( $m->at(2, 1), 8, 'at(2,1) returns eighth element' );
    is( $m->at(2, 2), 9, 'at(2,2) returns ninth element' );

    # Test with different data types
    my $m2 = Matrix->new( shape => [2, 2], data => [3.14, -5.2, 0.5, 1.7] );
    is( $m2->at(0, 0), 3.14, 'at(0,0) works with floating point numbers' );
    is( $m2->at(0, 1), -5.2, 'at(0,1) works with negative numbers' );
    is( $m2->at(1, 0), 0.5, 'at(1,0) works with decimal numbers' );
    is( $m2->at(1, 1), 1.7, 'at(1,1) works with floating point numbers' );
};

subtest 'at method - edge cases and error conditions' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

    # Test accessing out of bounds (should return undef or cause error)
    my $error;
    { local $@; eval { $m->at(2, 0) }; $error = $@ }
    ok length $error, 'at(2,0) on 2x2 matrix should cause error';
    { local $@; eval { $m->at(0, 2) }; $error = $@ }
    ok length $error, 'at(0,2) on 2x2 matrix should cause error';
    { local $@; eval { $m->at(-1, 0) }; $error = $@ }
    ok length $error, 'at(-1,0) should cause error';
    { local $@; eval { $m->at(0, -1) }; $error = $@ }
    ok length $error, 'at(0,-1) should cause error';
};

subtest 'row_vector_at method - extracting row vectors' => sub {
    my $m = Matrix->new( shape => [3, 3], data => [1, 2, 3, 4, 5, 6, 7, 8, 9] );

    # Test extracting first row [1, 2, 3]
    my $row0 = $m->row_vector_at(0);
    isa_ok( $row0, 'Vector', 'row_vector_at returns a Vector' );
    is( $row0->size, 3, 'row vector has correct size' );
    is( $row0->at(0), 1, 'first element of row 0' );
    is( $row0->at(1), 2, 'second element of row 0' );
    is( $row0->at(2), 3, 'third element of row 0' );

    # Test extracting second row [4, 5, 6]
    my $row1 = $m->row_vector_at(1);
    isa_ok( $row1, 'Vector', 'row_vector_at returns a Vector' );
    is( $row1->size, 3, 'row vector has correct size' );
    is( $row1->at(0), 4, 'first element of row 1' );
    is( $row1->at(1), 5, 'second element of row 1' );
    is( $row1->at(2), 6, 'third element of row 1' );

    # Test extracting third row [7, 8, 9]
    my $row2 = $m->row_vector_at(2);
    isa_ok( $row2, 'Vector', 'row_vector_at returns a Vector' );
    is( $row2->size, 3, 'row vector has correct size' );
    is( $row2->at(0), 7, 'first element of row 2' );
    is( $row2->at(1), 8, 'second element of row 2' );
    is( $row2->at(2), 9, 'third element of row 2' );
};

subtest 'row_vector_at method - with different matrix sizes' => sub {
    # Test with 2x3 matrix
    my $m1 = Matrix->new( shape => [2, 3], data => [1, 2, 3, 4, 5, 6] );

    my $row0 = $m1->row_vector_at(0);
    is( $row0->size, 3, 'row vector from 2x3 matrix has size 3' );
    is( $row0->at(0), 1, 'first element of row 0' );
    is( $row0->at(1), 2, 'second element of row 0' );
    is( $row0->at(2), 3, 'third element of row 0' );

    my $row1 = $m1->row_vector_at(1);
    is( $row1->size, 3, 'row vector from 2x3 matrix has size 3' );
    is( $row1->at(0), 4, 'first element of row 1' );
    is( $row1->at(1), 5, 'second element of row 1' );
    is( $row1->at(2), 6, 'third element of row 1' );

    # Test with 3x2 matrix
    my $m2 = Matrix->new( shape => [3, 2], data => [1, 2, 3, 4, 5, 6] );

    my $row0_2 = $m2->row_vector_at(0);
    is( $row0_2->size, 2, 'row vector from 3x2 matrix has size 2' );
    is( $row0_2->at(0), 1, 'first element of row 0' );
    is( $row0_2->at(1), 2, 'second element of row 0' );
};

subtest 'row_vector_at method - with floating point numbers' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1.5, 2.5, 3.5, 4.5] );

    my $row0 = $m->row_vector_at(0);
    is( $row0->at(0), 1.5, 'first element of row 0 with floating point' );
    is( $row0->at(1), 2.5, 'second element of row 0 with floating point' );

    my $row1 = $m->row_vector_at(1);
    is( $row1->at(0), 3.5, 'first element of row 1 with floating point' );
    is( $row1->at(1), 4.5, 'second element of row 1 with floating point' );
};

subtest 'col_vector_at method - extracting column vectors' => sub {
    my $m = Matrix->new( shape => [3, 3], data => [1, 2, 3, 4, 5, 6, 7, 8, 9] );

    # Test extracting first column [1, 4, 7]
    my $col0 = $m->col_vector_at(0);
    isa_ok( $col0, 'Vector', 'col_vector_at returns a Vector' );
    is( $col0->size, 3, 'column vector has correct size' );
    is( $col0->at(0), 1, 'first element of column 0' );
    is( $col0->at(1), 4, 'second element of column 0' );
    is( $col0->at(2), 7, 'third element of column 0' );

    # Test extracting second column [2, 5, 8]
    my $col1 = $m->col_vector_at(1);
    isa_ok( $col1, 'Vector', 'col_vector_at returns a Vector' );
    is( $col1->size, 3, 'column vector has correct size' );
    is( $col1->at(0), 2, 'first element of column 1' );
    is( $col1->at(1), 5, 'second element of column 1' );
    is( $col1->at(2), 8, 'third element of column 1' );

    # Test extracting third column [3, 6, 9]
    my $col2 = $m->col_vector_at(2);
    isa_ok( $col2, 'Vector', 'col_vector_at returns a Vector' );
    is( $col2->size, 3, 'column vector has correct size' );
    is( $col2->at(0), 3, 'first element of column 2' );
    is( $col2->at(1), 6, 'second element of column 2' );
    is( $col2->at(2), 9, 'third element of column 2' );
};

subtest 'col_vector_at method - with different matrix sizes' => sub {
    # Test with 2x3 matrix
    my $m1 = Matrix->new( shape => [2, 3], data => [1, 2, 3, 4, 5, 6] );

    my $col0 = $m1->col_vector_at(0);
    is( $col0->size, 2, 'column vector from 2x3 matrix has size 2' );
    is( $col0->at(0), 1, 'first element of column 0' );
    is( $col0->at(1), 4, 'second element of column 0' );

    my $col1 = $m1->col_vector_at(1);
    is( $col1->size, 2, 'column vector from 2x3 matrix has size 2' );
    is( $col1->at(0), 2, 'first element of column 1' );
    is( $col1->at(1), 5, 'second element of column 1' );

    my $col2 = $m1->col_vector_at(2);
    is( $col2->size, 2, 'column vector from 2x3 matrix has size 2' );
    is( $col2->at(0), 3, 'first element of column 2' );
    is( $col2->at(1), 6, 'second element of column 2' );

    # Test with 3x2 matrix
    my $m2 = Matrix->new( shape => [3, 2], data => [1, 2, 3, 4, 5, 6] );

    my $col0_2 = $m2->col_vector_at(0);
    is( $col0_2->size, 3, 'column vector from 3x2 matrix has size 3' );
    is( $col0_2->at(0), 1, 'first element of column 0' );
    is( $col0_2->at(1), 3, 'second element of column 0' );
    is( $col0_2->at(2), 5, 'third element of column 0' );
};

subtest 'col_vector_at method - with floating point numbers' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1.5, 2.5, 3.5, 4.5] );

    my $col0 = $m->col_vector_at(0);
    is( $col0->at(0), 1.5, 'first element of column 0 with floating point' );
    is( $col0->at(1), 3.5, 'second element of column 0 with floating point' );

    my $col1 = $m->col_vector_at(1);
    is( $col1->at(0), 2.5, 'first element of column 1 with floating point' );
    is( $col1->at(1), 4.5, 'second element of column 1 with floating point' );
};

subtest 'access methods - edge cases' => sub {
    # Test with single element matrix
    my $single = Matrix->new( shape => [1, 1], data => [42] );
    is( $single->at(0, 0), 42, 'single element matrix access' );

    my $row = $single->row_vector_at(0);
    is( $row->size, 1, 'row vector from single element matrix has size 1' );
    is( $row->at(0), 42, 'row vector element is correct' );

    my $col = $single->col_vector_at(0);
    is( $col->size, 1, 'column vector from single element matrix has size 1' );
    is( $col->at(0), 42, 'column vector element is correct' );

    # Test with zero matrix
    my $zeros = Matrix->new( shape => [2, 2], data => [0, 0, 0, 0] );
    is( $zeros->at(0, 0), 0, 'zero matrix element access' );

    my $zero_row = $zeros->row_vector_at(0);
    is( $zero_row->at(0), 0, 'zero matrix row vector element' );
    is( $zero_row->at(1), 0, 'zero matrix row vector element' );

    my $zero_col = $zeros->col_vector_at(0);
    is( $zero_col->at(0), 0, 'zero matrix column vector element' );
    is( $zero_col->at(1), 0, 'zero matrix column vector element' );
};

done_testing;

__END__
