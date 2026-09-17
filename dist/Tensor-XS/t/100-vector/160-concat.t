use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Vector;

my $vector = Vector->initialize(2, [ 1, 2 ] );

subtest 'concat method - basic concatenation' => sub {
    my $v1 = Vector->initialize(2, [ 1, 2 ] );
    my $v2 = Vector->initialize(3, [ 3, 4, 5 ] );

    my $result = Vector->concat($v1, $v2);

    isa_ok( $result, 'Vector', 'concat returns a Vector' );
    is( $result->size, 5, 'result vector has correct size (2+3=5)' );
    is( $result->at(0), 1, 'first element is 1' );
    is( $result->at(1), 2, 'second element is 2' );
    is( $result->at(2), 3, 'third element is 3' );
    is( $result->at(3), 4, 'fourth element is 4' );
    is( $result->at(4), 5, 'fifth element is 5' );
};

subtest 'concat method - with single element vectors' => sub {
    my $v1 = Vector->initialize(1, [ 10 ] );
    my $v2 = Vector->initialize(1, [ 20 ] );

    my $result = Vector->concat($v1, $v2);

    isa_ok( $result, 'Vector', 'concat returns a Vector' );
    is( $result->size, 2, 'result vector has correct size (1+1=2)' );
    is( $result->at(0), 10, 'first element is 10' );
    is( $result->at(1), 20, 'second element is 20' );
};

subtest 'concat method - with empty vectors' => sub {
    my $v1 = Vector->initialize(0, [] );
    my $v2 = Vector->initialize(3, [ 1, 2, 3 ] );

    my $result = Vector->concat($v1, $v2);

    isa_ok( $result, 'Vector', 'concat returns a Vector' );
    is( $result->size, 3, 'result vector has correct size (0+3=3)' );
    is( $result->at(0), 1, 'first element is 1' );
    is( $result->at(1), 2, 'second element is 2' );
    is( $result->at(2), 3, 'third element is 3' );

    # Test concat with empty vector as second argument
    my $v3 = Vector->initialize(2, [ 4, 5 ] );
    my $v4 = Vector->initialize(0, [] );

    my $result2 = Vector->concat($v3, $v4);

    isa_ok( $result2, 'Vector', 'concat returns a Vector' );
    is( $result2->size, 2, 'result vector has correct size (2+0=2)' );
    is( $result2->at(0), 4, 'first element is 4' );
    is( $result2->at(1), 5, 'second element is 5' );

    # Test concat with both empty vectors
    my $v5 = Vector->initialize(0, [] );
    my $v6 = Vector->initialize(0, [] );

    my $result3 = Vector->concat($v5, $v6);

    isa_ok( $result3, 'Vector', 'concat returns a Vector' );
    is( $result3->size, 0, 'result vector has correct size (0+0=0)' );
};

subtest 'concat method - with floating point numbers' => sub {
    my $v1 = Vector->initialize(2, [ 1.5, 2.5 ] );
    my $v2 = Vector->initialize(2, [ 3.14, 4.2 ] );

    my $result = Vector->concat($v1, $v2);

    isa_ok( $result, 'Vector', 'concat returns a Vector' );
    is( $result->size, 4, 'result vector has correct size (2+2=4)' );
    is( $result->at(0), 1.5, 'first element is 1.5' );
    is( $result->at(1), 2.5, 'second element is 2.5' );
    is( $result->at(2), 3.14, 'third element is 3.14' );
    is( $result->at(3), 4.2, 'fourth element is 4.2' );
};

subtest 'concat method - with negative numbers' => sub {
    my $v1 = Vector->initialize(2, [ -1, -2 ] );
    my $v2 = Vector->initialize(3, [ -3, 0, 3 ] );

    my $result = Vector->concat($v1, $v2);

    isa_ok( $result, 'Vector', 'concat returns a Vector' );
    is( $result->size, 5, 'result vector has correct size (2+3=5)' );
    is( $result->at(0), -1, 'first element is -1' );
    is( $result->at(1), -2, 'second element is -2' );
    is( $result->at(2), -3, 'third element is -3' );
    is( $result->at(3), 0, 'fourth element is 0' );
    is( $result->at(4), 3, 'fifth element is 3' );
};

subtest 'concat method - with mixed data types' => sub {
    my $v1 = Vector->initialize(2, [ 1, 2.5 ] );
    my $v2 = Vector->initialize(2, [ -3, 0 ] );

    my $result = Vector->concat($v1, $v2);

    isa_ok( $result, 'Vector', 'concat returns a Vector' );
    is( $result->size, 4, 'result vector has correct size (2+2=4)' );
    is( $result->at(0), 1, 'first element is 1' );
    is( $result->at(1), 2.5, 'second element is 2.5' );
    is( $result->at(2), -3, 'third element is -3' );
    is( $result->at(3), 0, 'fourth element is 0' );
};

subtest 'concat method - order preservation' => sub {
    my $v1 = Vector->initialize(3, [ 10, 20, 30 ] );
    my $v2 = Vector->initialize(3, [ 40, 50, 60 ] );

    my $result = Vector->concat($v1, $v2);

    isa_ok( $result, 'Vector', 'concat returns a Vector' );
    is( $result->size, 6, 'result vector has correct size (3+3=6)' );

    # Verify order is preserved: first vector elements, then second vector elements
    is( $result->at(0), 10, 'first element from first vector' );
    is( $result->at(1), 20, 'second element from first vector' );
    is( $result->at(2), 30, 'third element from first vector' );
    is( $result->at(3), 40, 'first element from second vector' );
    is( $result->at(4), 50, 'second element from second vector' );
    is( $result->at(5), 60, 'third element from second vector' );
};

subtest 'concat method - with large vectors' => sub {
    my $v1 = Vector->initialize(5, [ 1, 2, 3, 4, 5 ] );
    my $v2 = Vector->initialize(5, [ 6, 7, 8, 9, 10 ] );

    my $result = Vector->concat($v1, $v2);

    isa_ok( $result, 'Vector', 'concat returns a Vector' );
    is( $result->size, 10, 'result vector has correct size (5+5=10)' );

    # Verify all elements are in correct order
    for my $i (0..9) {
        is( $result->at($i), $i + 1, "element at index $i is " . ($i + 1) );
    }
};

subtest 'concat method - with zero vectors' => sub {
    my $v1 = Vector->initialize(3, [ 0, 0, 0 ] );
    my $v2 = Vector->initialize(2, [ 0, 0 ] );

    my $result = Vector->concat($v1, $v2);

    isa_ok( $result, 'Vector', 'concat returns a Vector' );
    is( $result->size, 5, 'result vector has correct size (3+2=5)' );

    # Verify all elements are zero
    for my $i (0..4) {
        is( $result->at($i), 0, "element at index $i is 0" );
    }
};

subtest 'concat method - immutability of input vectors' => sub {
    my $v1 = Vector->initialize(2, [ 1, 2 ] );
    my $v2 = Vector->initialize(2, [ 3, 4 ] );

    # Store original values
    my $v1_orig_0 = $v1->at(0);
    my $v1_orig_1 = $v1->at(1);
    my $v2_orig_0 = $v2->at(0);
    my $v2_orig_1 = $v2->at(1);

    # Perform concatenation
    my $result = Vector->concat($v1, $v2);

    # Verify original vectors are unchanged
    is( $v1->at(0), $v1_orig_0, 'first vector first element unchanged' );
    is( $v1->at(1), $v1_orig_1, 'first vector second element unchanged' );
    is( $v2->at(0), $v2_orig_0, 'second vector first element unchanged' );
    is( $v2->at(1), $v2_orig_1, 'second vector second element unchanged' );

    # Verify result is correct
    is( $result->size, 4, 'result vector has correct size' );
    is( $result->at(0), 1, 'result first element is 1' );
    is( $result->at(1), 2, 'result second element is 2' );
    is( $result->at(2), 3, 'result third element is 3' );
    is( $result->at(3), 4, 'result fourth element is 4' );
};

done_testing;

__END__
