use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Vector;

my $vector = Vector->initialize( 2, [ 1, 2 ] );

subtest 'at method - accessing elements by index' => sub {
    my $v = Vector->initialize( 3, [ 10, 20, 30 ] );

    is( $v->at(0), 10, 'at(0) returns first element' );
    is( $v->at(1), 20, 'at(1) returns second element' );
    is( $v->at(2), 30, 'at(2) returns third element' );

    # Test with different data types
    my $v2 = Vector->initialize( 2, [ 3.14, -5.2 ] );
    is( $v2->at(0), 3.14, 'at(0) works with floating point numbers' );
    is( $v2->at(1), -5.2, 'at(1) works with negative numbers' );

    # Test with single element vector
    my $v3 = Vector->initialize( 1, [ 42 ] );
    is( $v3->at(0), 42, 'at(0) works with single element vector' );
};

subtest 'at method - edge cases and error conditions' => sub {
    my $v = Vector->initialize( 2, [ 1, 2 ] );

    # Test accessing out of bounds (should return undef or cause error)
    my $error;
    { local $@; eval { $v->at(2) }; $error = $@ }
    ok length $error, 'at(2) on size-2 vector should cause error';
    { local $@; eval { $v->at(-1) }; $error = $@ }
    ok length $error, 'at(-1) should cause error';
};

subtest 'index_of method - finding element positions' => sub {
    my $v = Vector->initialize( 5, [ 1, 3, 5, 3, 7 ] );

    is( $v->index_of(1), 0, 'index_of(1) returns 0 for first occurrence' );
    is( $v->index_of(3), 1, 'index_of(3) returns 1 for first occurrence' );
    is( $v->index_of(5), 2, 'index_of(5) returns 2' );
    is( $v->index_of(7), 4, 'index_of(7) returns 4' );

    # Test with floating point numbers
    my $v2 = Vector->initialize( 3, [ 1.5, 2.5, 3.5 ] );
    is( $v2->index_of(2.5), 1, 'index_of works with floating point numbers' );

    # Test with negative numbers
    my $v3 = Vector->initialize( 3, [ -1, 0, 1 ] );
    is( $v3->index_of(-1), 0, 'index_of works with negative numbers' );
    is( $v3->index_of(0), 1, 'index_of works with zero' );
};

subtest 'index_of method - not found cases' => sub {
    my $v = Vector->initialize( 3, [ 1, 2, 3 ] );

    is( $v->index_of(4), -1, 'index_of(4) returns -1 when not found' );
    is( $v->index_of(0), -1, 'index_of(0) returns -1 when not found' );
    is( $v->index_of(-1), -1, 'index_of(-1) returns -1 when not found' );

    # Test with empty vector
    my $empty = Vector->initialize( 0, [] );
    is( $empty->index_of(1), -1, 'index_of on empty vector returns -1' );
};

subtest 'index_of method - precision and comparison' => sub {
    my $v = Vector->initialize( 3, [ 1.0, 2.0, 3.0 ] );

    # Test that it uses == comparison (should work with 1.0 == 1)
    is( $v->index_of(1), 0, 'index_of uses == comparison (1.0 == 1)' );
    is( $v->index_of(2), 1, 'index_of uses == comparison (2.0 == 2)' );
    is( $v->index_of(3), 2, 'index_of uses == comparison (3.0 == 3)' );
};

done_testing;

__END__
