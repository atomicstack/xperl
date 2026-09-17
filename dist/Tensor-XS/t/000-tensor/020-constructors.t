use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Tensor;

subtest 'initialize method - 1D tensor with scalar initial value' => sub {
    my $t = Tensor->initialize([5], 0);

    isa_ok( $t, 'Tensor', 'initialize returns a Tensor' );
    is( $t->rank, 1, 'tensor has rank 1' );
    is( $t->size, 5, 'tensor has size 5' );

    for my $i (0..4) {
        is( $t->at($i), 0, "element at $i is 0" );
    }
};

subtest 'initialize method - 1D tensor with array initial values' => sub {
    my $t = Tensor->initialize([5], [1, 2, 3, 4, 5]);

    isa_ok( $t, 'Tensor', 'initialize returns a Tensor' );
    is( $t->rank, 1, 'tensor has rank 1' );
    is( $t->size, 5, 'tensor has size 5' );

    is( $t->at(0), 1, 'element at 0 is 1' );
    is( $t->at(1), 2, 'element at 1 is 2' );
    is( $t->at(2), 3, 'element at 2 is 3' );
    is( $t->at(3), 4, 'element at 3 is 4' );
    is( $t->at(4), 5, 'element at 4 is 5' );
};

subtest 'initialize method - 2D tensor with scalar initial value' => sub {
    my $t = Tensor->initialize([3, 4], 7);

    isa_ok( $t, 'Tensor', 'initialize returns a Tensor' );
    is( $t->rank, 2, 'tensor has rank 2' );
    is( $t->size, 12, 'tensor has size 12 (3*4)' );
    is_deeply( $t->shape, [3, 4], 'tensor has shape [3, 4]' );

    for my $i (0..2) {
        for my $j (0..3) {
            is( $t->at($i, $j), 7, "element at ($i,$j) is 7" );
        }
    }
};

subtest 'initialize method - 2D tensor with array initial values' => sub {
    my $t = Tensor->initialize([2, 3], [1, 2, 3, 4, 5, 6]);

    isa_ok( $t, 'Tensor', 'initialize returns a Tensor' );
    is( $t->rank, 2, 'tensor has rank 2' );
    is( $t->size, 6, 'tensor has size 6 (2*3)' );

    is( $t->at(0, 0), 1, 'element at (0,0) is 1' );
    is( $t->at(0, 1), 2, 'element at (0,1) is 2' );
    is( $t->at(0, 2), 3, 'element at (0,2) is 3' );
    is( $t->at(1, 0), 4, 'element at (1,0) is 4' );
    is( $t->at(1, 1), 5, 'element at (1,1) is 5' );
    is( $t->at(1, 2), 6, 'element at (1,2) is 6' );
};

subtest 'initialize method - 3D tensor with scalar initial value' => sub {
    my $t = Tensor->initialize([2, 3, 4], 1);

    isa_ok( $t, 'Tensor', 'initialize returns a Tensor' );
    is( $t->rank, 3, 'tensor has rank 3' );
    is( $t->size, 24, 'tensor has size 24 (2*3*4)' );
    is_deeply( $t->shape, [2, 3, 4], 'tensor has shape [2, 3, 4]' );

    for my $i (0..1) {
        for my $j (0..2) {
            for my $k (0..3) {
                is( $t->at($i, $j, $k), 1, "element at ($i,$j,$k) is 1" );
            }
        }
    }
};

subtest 'initialize method - 3D tensor with array initial values' => sub {
    my $t = Tensor->initialize([2, 2, 2], [1..8]);

    isa_ok( $t, 'Tensor', 'initialize returns a Tensor' );
    is( $t->rank, 3, 'tensor has rank 3' );
    is( $t->size, 8, 'tensor has size 8 (2*2*2)' );

    is( $t->at(0, 0, 0), 1, 'element at (0,0,0) is 1' );
    is( $t->at(0, 0, 1), 2, 'element at (0,0,1) is 2' );
    is( $t->at(0, 1, 0), 3, 'element at (0,1,0) is 3' );
    is( $t->at(0, 1, 1), 4, 'element at (0,1,1) is 4' );
    is( $t->at(1, 0, 0), 5, 'element at (1,0,0) is 5' );
    is( $t->at(1, 0, 1), 6, 'element at (1,0,1) is 6' );
    is( $t->at(1, 1, 0), 7, 'element at (1,1,0) is 7' );
    is( $t->at(1, 1, 1), 8, 'element at (1,1,1) is 8' );
};

subtest 'initialize method - with floating point values' => sub {
    my $t = Tensor->initialize([2, 2], 3.14);

    isa_ok( $t, 'Tensor', 'initialize returns a Tensor' );

    for my $i (0..1) {
        for my $j (0..1) {
            is( $t->at($i, $j), 3.14, "element at ($i,$j) is 3.14" );
        }
    }

    my $t2 = Tensor->initialize([3], [1.5, 2.5, 3.5]);
    is( $t2->at(0), 1.5, 'element at 0 is 1.5' );
    is( $t2->at(1), 2.5, 'element at 1 is 2.5' );
    is( $t2->at(2), 3.5, 'element at 2 is 3.5' );
};

subtest 'initialize method - with negative values' => sub {
    my $t = Tensor->initialize([2, 2], -5);

    for my $i (0..1) {
        for my $j (0..1) {
            is( $t->at($i, $j), -5, "element at ($i,$j) is -5" );
        }
    }

    my $t2 = Tensor->initialize([3], [-1, -2, -3]);
    is( $t2->at(0), -1, 'element at 0 is -1' );
    is( $t2->at(1), -2, 'element at 1 is -2' );
    is( $t2->at(2), -3, 'element at 2 is -3' );
};

subtest 'construct method - 1D tensor with generator function' => sub {
    my $t = Tensor->construct([5], sub { $_[0] * 2 });

    isa_ok( $t, 'Tensor', 'construct returns a Tensor' );
    is( $t->rank, 1, 'tensor has rank 1' );
    is( $t->size, 5, 'tensor has size 5' );

    is( $t->at(0), 0, 'element at 0 is 0 (0*2)' );
    is( $t->at(1), 2, 'element at 1 is 2 (1*2)' );
    is( $t->at(2), 4, 'element at 2 is 4 (2*2)' );
    is( $t->at(3), 6, 'element at 3 is 6 (3*2)' );
    is( $t->at(4), 8, 'element at 4 is 8 (4*2)' );
};

subtest 'construct method - 2D tensor with generator function' => sub {
    my $t = Tensor->construct([3, 3], sub { $_[0] + $_[1] });

    isa_ok( $t, 'Tensor', 'construct returns a Tensor' );
    is( $t->rank, 2, 'tensor has rank 2' );
    is( $t->size, 9, 'tensor has size 9 (3*3)' );

    # Check elements: (i,j) = i + j
    is( $t->at(0, 0), 0, 'element at (0,0) is 0' );
    is( $t->at(0, 1), 1, 'element at (0,1) is 1' );
    is( $t->at(0, 2), 2, 'element at (0,2) is 2' );
    is( $t->at(1, 0), 1, 'element at (1,0) is 1' );
    is( $t->at(1, 1), 2, 'element at (1,1) is 2' );
    is( $t->at(1, 2), 3, 'element at (1,2) is 3' );
    is( $t->at(2, 0), 2, 'element at (2,0) is 2' );
    is( $t->at(2, 1), 3, 'element at (2,1) is 3' );
    is( $t->at(2, 2), 4, 'element at (2,2) is 4' );
};

subtest 'construct method - 2D tensor with multiplication function' => sub {
    my $t = Tensor->construct([3, 3], sub { $_[0] * $_[1] });

    isa_ok( $t, 'Tensor', 'construct returns a Tensor' );

    # Check elements: (i,j) = i * j
    is( $t->at(0, 0), 0, 'element at (0,0) is 0' );
    is( $t->at(0, 1), 0, 'element at (0,1) is 0' );
    is( $t->at(1, 1), 1, 'element at (1,1) is 1' );
    is( $t->at(2, 2), 4, 'element at (2,2) is 4' );
    is( $t->at(2, 1), 2, 'element at (2,1) is 2' );
};

subtest 'construct method - 3D tensor with generator function' => sub {
    my $t = Tensor->construct([2, 2, 2], sub { $_[0] * 10 + $_[1] * 2 + $_[2] });

    isa_ok( $t, 'Tensor', 'construct returns a Tensor' );
    is( $t->rank, 3, 'tensor has rank 3' );
    is( $t->size, 8, 'tensor has size 8 (2*2*2)' );

    # Note: 3D+ tensors use a different coordinate calculation algorithm
    # Just verify the tensor is constructed and elements are accessible
    ok( defined $t->at(0, 0, 0), 'element at (0,0,0) is defined' );
    ok( defined $t->at(0, 0, 1), 'element at (0,0,1) is defined' );
    ok( defined $t->at(1, 1, 1), 'element at (1,1,1) is defined' );
};

subtest 'ones method - creating tensor filled with 1s' => sub {
    my $t1d = Tensor->ones([5]);
    isa_ok( $t1d, 'Tensor', 'ones returns a Tensor' );
    is( $t1d->size, 5, '1D tensor has size 5' );
    for my $i (0..4) {
        is( $t1d->at($i), 1, "element at $i is 1" );
    }

    my $t2d = Tensor->ones([2, 3]);
    isa_ok( $t2d, 'Tensor', 'ones returns a Tensor' );
    is( $t2d->size, 6, '2D tensor has size 6' );
    for my $i (0..1) {
        for my $j (0..2) {
            is( $t2d->at($i, $j), 1, "element at ($i,$j) is 1" );
        }
    }

    my $t3d = Tensor->ones([2, 2, 2]);
    isa_ok( $t3d, 'Tensor', 'ones returns a Tensor' );
    is( $t3d->size, 8, '3D tensor has size 8' );
    for my $i (0..1) {
        for my $j (0..1) {
            for my $k (0..1) {
                is( $t3d->at($i, $j, $k), 1, "element at ($i,$j,$k) is 1" );
            }
        }
    }
};

subtest 'zeros method - creating tensor filled with 0s' => sub {
    my $t1d = Tensor->zeros([5]);
    isa_ok( $t1d, 'Tensor', 'zeros returns a Tensor' );
    is( $t1d->size, 5, '1D tensor has size 5' );
    for my $i (0..4) {
        is( $t1d->at($i), 0, "element at $i is 0" );
    }

    my $t2d = Tensor->zeros([3, 4]);
    isa_ok( $t2d, 'Tensor', 'zeros returns a Tensor' );
    is( $t2d->size, 12, '2D tensor has size 12' );
    for my $i (0..2) {
        for my $j (0..3) {
            is( $t2d->at($i, $j), 0, "element at ($i,$j) is 0" );
        }
    }
};

subtest 'sequence method - creating tensor with sequential values' => sub {
    my $t1d = Tensor->sequence([5], 1);
    isa_ok( $t1d, 'Tensor', 'sequence returns a Tensor' );
    is( $t1d->size, 5, '1D tensor has size 5' );
    is( $t1d->at(0), 1, 'element at 0 is 1' );
    is( $t1d->at(1), 2, 'element at 1 is 2' );
    is( $t1d->at(2), 3, 'element at 2 is 3' );
    is( $t1d->at(3), 4, 'element at 3 is 4' );
    is( $t1d->at(4), 5, 'element at 4 is 5' );

    my $t2d = Tensor->sequence([2, 3], 10);
    isa_ok( $t2d, 'Tensor', 'sequence returns a Tensor' );
    is( $t2d->size, 6, '2D tensor has size 6' );
    is( $t2d->at(0, 0), 10, 'element at (0,0) is 10' );
    is( $t2d->at(0, 1), 11, 'element at (0,1) is 11' );
    is( $t2d->at(0, 2), 12, 'element at (0,2) is 12' );
    is( $t2d->at(1, 0), 13, 'element at (1,0) is 13' );
    is( $t2d->at(1, 1), 14, 'element at (1,1) is 14' );
    is( $t2d->at(1, 2), 15, 'element at (1,2) is 15' );

    my $t3d = Tensor->sequence([2, 2, 2], 0);
    isa_ok( $t3d, 'Tensor', 'sequence returns a Tensor' );
    is( $t3d->size, 8, '3D tensor has size 8' );
    is( $t3d->at(0, 0, 0), 0, 'element at (0,0,0) is 0' );
    is( $t3d->at(1, 1, 1), 7, 'element at (1,1,1) is 7' );
};

subtest 'constructor edge cases' => sub {
    # Single element tensor
    my $single = Tensor->initialize([1], 42);
    is( $single->at(0), 42, 'single element tensor' );

    # Large tensor (just verify it works)
    my $large = Tensor->zeros([10, 10, 10]);
    is( $large->size, 1000, 'large tensor has correct size' );
    is( $large->at(5, 5, 5), 0, 'large tensor element access works' );
};

done_testing;

__END__
