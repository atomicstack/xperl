use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Vector;
use Matrix;

my $vector = Vector->initialize( 2, [ 1, 2 ] );

subtest 'matrix_multiply method - basic vector-matrix multiplication' => sub {
    # Create a 2x2 matrix: [[1, 2], [3, 4]]
    my $matrix = Matrix->new(
        shape => [2, 2],
        data => [1, 2, 3, 4]
    );

    # Vector [1, 2] * Matrix [[1,2], [3,4]]
    # Result should be [1*1+2*3, 1*2+2*4] = [7, 10]
    my $vector = Vector->initialize( 2, [ 1, 2 ] );
    my $result = $vector->matrix_multiply($matrix);

    isa_ok( $result, 'Vector', 'matrix_multiply returns a Vector' );
    is( $result->size, 2, 'result vector has correct size' );
    is( $result->at(0), 7, 'first element of result is 7' );
    is( $result->at(1), 10, 'second element of result is 10' );
};

subtest 'matrix_multiply method - with 3x3 matrix' => sub {
    # Create a 3x3 matrix: [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
    my $matrix = Matrix->new(
        shape => [3, 3],
        data => [1, 2, 3, 4, 5, 6, 7, 8, 9]
    );

    # Vector [1, 2, 3] * Matrix [[1,2,3], [4,5,6], [7,8,9]]
    # Result should be [1*1+2*4+3*7, 1*2+2*5+3*8, 1*3+2*6+3*9] = [30, 36, 42]
    my $vector = Vector->initialize( 3, [ 1, 2, 3 ] );
    my $result = $vector->matrix_multiply($matrix);

    isa_ok( $result, 'Vector', 'matrix_multiply returns a Vector' );
    is( $result->size, 3, 'result vector has correct size' );
    is( $result->at(0), 30, 'first element of result is 30' );
    is( $result->at(1), 36, 'second element of result is 36' );
    is( $result->at(2), 42, 'third element of result is 42' );
};

subtest 'matrix_multiply method - with identity matrix' => sub {
    # Create a 3x3 identity matrix
    my $identity = Matrix->eye(3);

    # Vector [5, 10, 15] * Identity matrix should return the same vector
    my $vector = Vector->initialize( 3, [ 5, 10, 15 ] );
    my $result = $vector->matrix_multiply($identity);

    isa_ok( $result, 'Vector', 'matrix_multiply returns a Vector' );
    is( $result->size, 3, 'result vector has correct size' );
    is( $result->at(0), 5, 'first element unchanged (5)' );
    is( $result->at(1), 10, 'second element unchanged (10)' );
    is( $result->at(2), 15, 'third element unchanged (15)' );
};

subtest 'matrix_multiply method - with diagonal matrix' => sub {
    # Create a diagonal matrix from vector [2, 3, 4]
    my $diag_vector = Vector->initialize( 3, [ 2, 3, 4 ] );
    my $diagonal = Matrix->diagonal($diag_vector);

    # Vector [1, 1, 1] * Diagonal matrix [[2,0,0], [0,3,0], [0,0,4]]
    # Result should be [1*2+1*0+1*0, 1*0+1*3+1*0, 1*0+1*0+1*4] = [2, 3, 4]
    my $vector = Vector->initialize( 3, [ 1, 1, 1 ] );
    my $result = $vector->matrix_multiply($diagonal);

    isa_ok( $result, 'Vector', 'matrix_multiply returns a Vector' );
    is( $result->size, 3, 'result vector has correct size' );
    is( $result->at(0), 2, 'first element is 2' );
    is( $result->at(1), 3, 'second element is 3' );
    is( $result->at(2), 4, 'third element is 4' );
};

subtest 'matrix_multiply method - with floating point numbers' => sub {
    # Create a 2x2 matrix with floating point numbers: [[1.5, 2.5], [3.5, 4.5]]
    my $matrix = Matrix->new(
        shape => [2, 2],
        data => [1.5, 2.5, 3.5, 4.5]
    );

    # Vector [2.0, 3.0] * Matrix [[1.5,2.5], [3.5,4.5]]
    # Result should be [2.0*1.5+3.0*3.5, 2.0*2.5+3.0*4.5] = [13.5, 18.5]
    my $vector = Vector->initialize( 2, [ 2.0, 3.0 ] );
    my $result = $vector->matrix_multiply($matrix);

    isa_ok( $result, 'Vector', 'matrix_multiply returns a Vector' );
    is( $result->size, 2, 'result vector has correct size' );
    is( $result->at(0), 13.5, 'first element of result is 13.5' );
    is( $result->at(1), 18.5, 'second element of result is 18.5' );
};

subtest 'matrix_multiply method - with negative numbers' => sub {
    # Create a 2x2 matrix with negative numbers: [[-1, -2], [-3, -4]]
    my $matrix = Matrix->new(
        shape => [2, 2],
        data => [-1, -2, -3, -4]
    );

    # Vector [1, 2] * Matrix [[-1,-2], [-3,-4]]
    # Result should be [1*(-1)+2*(-3), 1*(-2)+2*(-4)] = [-7, -10]
    my $vector = Vector->initialize( 2, [ 1, 2 ] );
    my $result = $vector->matrix_multiply($matrix);

    isa_ok( $result, 'Vector', 'matrix_multiply returns a Vector' );
    is( $result->size, 2, 'result vector has correct size' );
    is( $result->at(0), -7, 'first element of result is -7' );
    is( $result->at(1), -10, 'second element of result is -10' );
};

subtest 'matrix_multiply method - with zero matrix' => sub {
    # Create a 2x2 zero matrix: [[0, 0], [0, 0]]
    my $matrix = Matrix->new(
        shape => [2, 2],
        data => [0, 0, 0, 0]
    );

    # Vector [1, 2] * Zero matrix should return zero vector
    my $vector = Vector->initialize( 2, [ 1, 2 ] );
    my $result = $vector->matrix_multiply($matrix);

    isa_ok( $result, 'Vector', 'matrix_multiply returns a Vector' );
    is( $result->size, 2, 'result vector has correct size' );
    is( $result->at(0), 0, 'first element is 0' );
    is( $result->at(1), 0, 'second element is 0' );
};

subtest 'matrix_multiply method - with zero vector' => sub {
    # Create a 2x2 matrix: [[1, 2], [3, 4]]
    my $matrix = Matrix->new(
        shape => [2, 2],
        data => [1, 2, 3, 4]
    );

    # Zero vector [0, 0] * Matrix should return zero vector
    my $vector = Vector->initialize( 2, [ 0, 0 ] );
    my $result = $vector->matrix_multiply($matrix);

    isa_ok( $result, 'Vector', 'matrix_multiply returns a Vector' );
    is( $result->size, 2, 'result vector has correct size' );
    is( $result->at(0), 0, 'first element is 0' );
    is( $result->at(1), 0, 'second element is 0' );
};

subtest 'matrix_multiply method - size validation' => sub {
    # Test that vector size must match matrix rows
    my $matrix = Matrix->new(
        shape => [3, 2],
        data => [1, 2, 3, 4, 5, 6]
    );

    # Vector of size 2 trying to multiply with a 3x2 matrix is invalid.
    my $vector = Vector->initialize( 2, [ 1, 2 ] );
    my $error;
    {
        local $@;
        eval { $vector->matrix_multiply($matrix) };
        $error = $@;
    }
    like( $error, qr/matrix multiplication dimensions do not agree/,
        'matrix_multiply rejects incompatible vector and matrix sizes' );
};

done_testing;

__END__
