use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Matrix;

subtest 'height method - matrix height calculation' => sub {
    my $m1 = Matrix->new( shape => [2, 3], data => [1, 2, 3, 4, 5, 6] );
    is( $m1->height, 1, '2x3 matrix has height 1 (rows - 1)' );

    my $m2 = Matrix->new( shape => [3, 2], data => [1, 2, 3, 4, 5, 6] );
    is( $m2->height, 2, '3x2 matrix has height 2 (rows - 1)' );

    my $m3 = Matrix->new( shape => [1, 5], data => [1, 2, 3, 4, 5] );
    is( $m3->height, 0, '1x5 matrix has height 0 (rows - 1)' );

    my $m4 = Matrix->new( shape => [4, 4], data => [1..16] );
    is( $m4->height, 3, '4x4 matrix has height 3 (rows - 1)' );
};

subtest 'width method - matrix width calculation' => sub {
    my $m1 = Matrix->new( shape => [2, 3], data => [1, 2, 3, 4, 5, 6] );
    is( $m1->width, 2, '2x3 matrix has width 2 (cols - 1)' );

    my $m2 = Matrix->new( shape => [3, 2], data => [1, 2, 3, 4, 5, 6] );
    is( $m2->width, 1, '3x2 matrix has width 1 (cols - 1)' );

    my $m3 = Matrix->new( shape => [5, 1], data => [1, 2, 3, 4, 5] );
    is( $m3->width, 0, '5x1 matrix has width 0 (cols - 1)' );

    my $m4 = Matrix->new( shape => [4, 4], data => [1..16] );
    is( $m4->width, 3, '4x4 matrix has width 3 (cols - 1)' );
};

subtest 'row_at method - row access' => sub {
    my $m = Matrix->new( shape => [3, 3], data => [1, 2, 3, 4, 5, 6, 7, 8, 9] );

    # Test first row [1, 2, 3]
    my @row0 = $m->row_at(0);
    is( scalar @row0, 3, 'row_at returns correct number of elements' );
    is( $row0[0], 1, 'first element of row 0' );
    is( $row0[1], 2, 'second element of row 0' );
    is( $row0[2], 3, 'third element of row 0' );

    # Test second row [4, 5, 6]
    my @row1 = $m->row_at(1);
    is( $row1[0], 4, 'first element of row 1' );
    is( $row1[1], 5, 'second element of row 1' );
    is( $row1[2], 6, 'third element of row 1' );

    # Test third row [7, 8, 9]
    my @row2 = $m->row_at(2);
    is( $row2[0], 7, 'first element of row 2' );
    is( $row2[1], 8, 'second element of row 2' );
    is( $row2[2], 9, 'third element of row 2' );
};

subtest 'row_at method - with different matrix sizes' => sub {
    # Test with 2x4 matrix
    my $m1 = Matrix->new( shape => [2, 4], data => [1, 2, 3, 4, 5, 6, 7, 8] );

    my @row0 = $m1->row_at(0);
    is( scalar @row0, 4, '2x4 matrix row has 4 elements' );
    is( $row0[0], 1, 'first element' );
    is( $row0[3], 4, 'last element' );

    my @row1 = $m1->row_at(1);
    is( $row1[0], 5, 'first element of second row' );
    is( $row1[3], 8, 'last element of second row' );

    # Test with 4x2 matrix
    my $m2 = Matrix->new( shape => [4, 2], data => [1, 2, 3, 4, 5, 6, 7, 8] );

    my @row0_2 = $m2->row_at(0);
    is( scalar @row0_2, 2, '4x2 matrix row has 2 elements' );
    is( $row0_2[0], 1, 'first element' );
    is( $row0_2[1], 2, 'second element' );
};

subtest 'row_at method - with floating point numbers' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1.5, 2.5, 3.5, 4.5] );

    my @row0 = $m->row_at(0);
    is( $row0[0], 1.5, 'first element of row 0 with floating point' );
    is( $row0[1], 2.5, 'second element of row 0 with floating point' );

    my @row1 = $m->row_at(1);
    is( $row1[0], 3.5, 'first element of row 1 with floating point' );
    is( $row1[1], 4.5, 'second element of row 1 with floating point' );
};

subtest 'col_at method - column access' => sub {
    my $m = Matrix->new( shape => [3, 3], data => [1, 2, 3, 4, 5, 6, 7, 8, 9] );

    # Test first column [1, 4, 7]
    my @col0 = $m->col_at(0);
    is( scalar @col0, 3, 'col_at returns correct number of elements' );
    is( $col0[0], 1, 'first element of column 0' );
    is( $col0[1], 4, 'second element of column 0' );
    is( $col0[2], 7, 'third element of column 0' );

    # Test second column [2, 5, 8]
    my @col1 = $m->col_at(1);
    is( $col1[0], 2, 'first element of column 1' );
    is( $col1[1], 5, 'second element of column 1' );
    is( $col1[2], 8, 'third element of column 1' );

    # Test third column [3, 6, 9]
    my @col2 = $m->col_at(2);
    is( $col2[0], 3, 'first element of column 2' );
    is( $col2[1], 6, 'second element of column 2' );
    is( $col2[2], 9, 'third element of column 2' );
};

subtest 'col_at method - with different matrix sizes' => sub {
    # Test with 2x4 matrix
    my $m1 = Matrix->new( shape => [2, 4], data => [1, 2, 3, 4, 5, 6, 7, 8] );

    my @col0 = $m1->col_at(0);
    is( scalar @col0, 2, '2x4 matrix column has 2 elements' );
    is( $col0[0], 1, 'first element' );
    is( $col0[1], 5, 'second element' );

    my @col3 = $m1->col_at(3);
    is( $col3[0], 4, 'first element of last column' );
    is( $col3[1], 8, 'second element of last column' );

    # Test with 4x2 matrix
    my $m2 = Matrix->new( shape => [4, 2], data => [1, 2, 3, 4, 5, 6, 7, 8] );

    my @col0_2 = $m2->col_at(0);
    is( scalar @col0_2, 4, '4x2 matrix column has 4 elements' );
    is( $col0_2[0], 1, 'first element' );
    is( $col0_2[3], 7, 'last element' );
};

subtest 'col_at method - with floating point numbers' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1.5, 2.5, 3.5, 4.5] );

    my @col0 = $m->col_at(0);
    is( $col0[0], 1.5, 'first element of column 0 with floating point' );
    is( $col0[1], 3.5, 'second element of column 0 with floating point' );

    my @col1 = $m->col_at(1);
    is( $col1[0], 2.5, 'first element of column 1 with floating point' );
    is( $col1[1], 4.5, 'second element of column 1 with floating point' );
};

subtest 'accessor methods - edge cases' => sub {
    # Test with single element matrix
    my $single = Matrix->new( shape => [1, 1], data => [42] );
    is( $single->height, 0, 'single element matrix has height 0' );
    is( $single->width, 0, 'single element matrix has width 0' );

    my @row = $single->row_at(0);
    is( scalar @row, 1, 'single element matrix row has 1 element' );
    is( $row[0], 42, 'single element matrix row element is correct' );

    my @col = $single->col_at(0);
    is( scalar @col, 1, 'single element matrix column has 1 element' );
    is( $col[0], 42, 'single element matrix column element is correct' );

    # Test with zero matrix
    my $zeros = Matrix->new( shape => [2, 2], data => [0, 0, 0, 0] );
    is( $zeros->height, 1, 'zero matrix has correct height' );
    is( $zeros->width, 1, 'zero matrix has correct width' );

    my @zero_row = $zeros->row_at(0);
    is( $zero_row[0], 0, 'zero matrix row element is 0' );
    is( $zero_row[1], 0, 'zero matrix row element is 0' );

    my @zero_col = $zeros->col_at(0);
    is( $zero_col[0], 0, 'zero matrix column element is 0' );
    is( $zero_col[1], 0, 'zero matrix column element is 0' );
};

subtest 'accessor methods - error conditions' => sub {
    my $m = Matrix->new( shape => [2, 2], data => [1, 2, 3, 4] );

    # Test accessing out of bounds rows
    my $error;
    { local $@; eval { $m->row_at(2) }; $error = $@ }
    ok length $error, 'row_at(2) on 2x2 matrix should cause error';
    { local $@; eval { $m->row_at(-1) }; $error = $@ }
    ok length $error, 'row_at(-1) should cause error';

    # Test accessing out of bounds columns
    { local $@; eval { $m->col_at(2) }; $error = $@ }
    ok length $error, 'col_at(2) on 2x2 matrix should cause error';
    { local $@; eval { $m->col_at(-1) }; $error = $@ }
    ok length $error, 'col_at(-1) should cause error';
};

done_testing;

__END__
