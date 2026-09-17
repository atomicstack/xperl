use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Tensor;

subtest 'at method - accessing 1D tensor elements' => sub {
    my $t = Tensor->initialize([5], [1, 2, 3, 4, 5]);

    is( $t->at(0), 1, 'at(0) returns first element' );
    is( $t->at(1), 2, 'at(1) returns second element' );
    is( $t->at(2), 3, 'at(2) returns third element' );
    is( $t->at(3), 4, 'at(3) returns fourth element' );
    is( $t->at(4), 5, 'at(4) returns fifth element' );
};

subtest 'at method - accessing 2D tensor elements' => sub {
    my $t = Tensor->initialize([2, 3], [1, 2, 3, 4, 5, 6]);

    is( $t->at(0, 0), 1, 'at(0,0) returns first element' );
    is( $t->at(0, 1), 2, 'at(0,1) returns second element' );
    is( $t->at(0, 2), 3, 'at(0,2) returns third element' );
    is( $t->at(1, 0), 4, 'at(1,0) returns fourth element' );
    is( $t->at(1, 1), 5, 'at(1,1) returns fifth element' );
    is( $t->at(1, 2), 6, 'at(1,2) returns sixth element' );
};

subtest 'at method - accessing 3D tensor elements' => sub {
    my $t = Tensor->initialize([2, 2, 2], [1, 2, 3, 4, 5, 6, 7, 8]);

    is( $t->at(0, 0, 0), 1, 'at(0,0,0) returns first element' );
    is( $t->at(0, 0, 1), 2, 'at(0,0,1) returns second element' );
    is( $t->at(0, 1, 0), 3, 'at(0,1,0) returns third element' );
    is( $t->at(0, 1, 1), 4, 'at(0,1,1) returns fourth element' );
    is( $t->at(1, 0, 0), 5, 'at(1,0,0) returns fifth element' );
    is( $t->at(1, 0, 1), 6, 'at(1,0,1) returns sixth element' );
    is( $t->at(1, 1, 0), 7, 'at(1,1,0) returns seventh element' );
    is( $t->at(1, 1, 1), 8, 'at(1,1,1) returns eighth element' );
};

subtest 'at method - accessing 4D tensor elements' => sub {
    my $t = Tensor->initialize([2, 2, 2, 2], [1..16]);

    is( $t->at(0, 0, 0, 0), 1, 'at(0,0,0,0) returns first element' );
    is( $t->at(0, 0, 0, 1), 2, 'at(0,0,0,1) returns second element' );
    is( $t->at(1, 1, 1, 1), 16, 'at(1,1,1,1) returns last element' );
    is( $t->at(1, 0, 1, 0), 11, 'at(1,0,1,0) returns expected element' );
};

subtest 'at method - with floating point numbers' => sub {
    my $t = Tensor->initialize([2, 2], [1.5, 2.5, 3.5, 4.5]);

    is( $t->at(0, 0), 1.5, 'at(0,0) works with floating point' );
    is( $t->at(0, 1), 2.5, 'at(0,1) works with floating point' );
    is( $t->at(1, 0), 3.5, 'at(1,0) works with floating point' );
    is( $t->at(1, 1), 4.5, 'at(1,1) works with floating point' );
};

subtest 'at method - edge cases and error conditions' => sub {
    my $t = Tensor->initialize([3], [1, 2, 3]);

    my $error;
    { local $@; eval { $t->at(3) }; $error = $@ }
    like $error, qr/Index out of bounds/, 'at(3) on size-3 tensor should cause error';
    { local $@; eval { $t->at(-1) }; $error = $@ }
    like $error, qr/Index out of bounds/, 'at(-1) should cause error';

    my $t2d = Tensor->initialize([2, 2], [1, 2, 3, 4]);
    { local $@; eval { $t2d->at(2, 0) }; $error = $@ }
    ok length $error, 'at(2,0) on 2x2 tensor should cause error';
    { local $@; eval { $t2d->at(0, 2) }; $error = $@ }
    ok length $error, 'at(0,2) on 2x2 tensor should cause error';
};

subtest 'dim_at method - accessing 1D tensor elements' => sub {
    my $t = Tensor->initialize([5], [1, 2, 3, 4, 5]);

    # For 1D tensors, dim_at with full coordinates returns single element
    my @val0 = $t->dim_at(0);
    is_deeply( \@val0, [1], 'dim_at(0) returns element at index 0' );

    my @val2 = $t->dim_at(2);
    is_deeply( \@val2, [3], 'dim_at(2) returns element at index 2' );
};

subtest 'dim_at method - accessing 2D tensor slices' => sub {
    my $t = Tensor->initialize([2, 3], [1, 2, 3, 4, 5, 6]);

    # Get first row
    my @row0 = $t->dim_at(0);
    is_deeply( \@row0, [1, 2, 3], 'dim_at(0) returns first row' );

    # Get second row
    my @row1 = $t->dim_at(1);
    is_deeply( \@row1, [4, 5, 6], 'dim_at(1) returns second row' );
};

subtest 'dim_at method - accessing 3D tensor slices' => sub {
    my $t = Tensor->initialize([2, 2, 2], [1, 2, 3, 4, 5, 6, 7, 8]);

    # Get first plane
    my @plane0 = $t->dim_at(0);
    is_deeply( \@plane0, [1, 2, 3, 4], 'dim_at(0) returns first plane' );

    # Get second plane
    my @plane1 = $t->dim_at(1);
    is_deeply( \@plane1, [5, 6, 7, 8], 'dim_at(1) returns second plane' );

    # Get first row of first plane
    my @row00 = $t->dim_at(0, 0);
    is_deeply( \@row00, [1, 2], 'dim_at(0,0) returns first row of first plane' );
};

subtest 'to_list method - converting tensor to flat list' => sub {
    my $t1d = Tensor->initialize([3], [1, 2, 3]);
    my @list1d = $t1d->to_list;
    is_deeply( \@list1d, [1, 2, 3], 'to_list on 1D tensor' );

    my $t2d = Tensor->initialize([2, 2], [1, 2, 3, 4]);
    my @list2d = $t2d->to_list;
    is_deeply( \@list2d, [1, 2, 3, 4], 'to_list on 2D tensor' );

    my $t3d = Tensor->initialize([2, 2, 2], [1..8]);
    my @list3d = $t3d->to_list;
    is_deeply( \@list3d, [1, 2, 3, 4, 5, 6, 7, 8], 'to_list on 3D tensor' );
};

subtest 'index method - coordinate to flat index conversion' => sub {
    my $t2d = Tensor->initialize([3, 4], [1..12]);

    # Test row-major ordering
    is( $t2d->index(0, 0), 0, 'index(0,0) returns 0' );
    is( $t2d->index(0, 1), 1, 'index(0,1) returns 1' );
    is( $t2d->index(0, 2), 2, 'index(0,2) returns 2' );
    is( $t2d->index(1, 0), 4, 'index(1,0) returns 4' );
    is( $t2d->index(2, 3), 11, 'index(2,3) returns 11' );

    my $t3d = Tensor->initialize([2, 3, 4], [1..24]);
    is( $t3d->index(0, 0, 0), 0, 'index(0,0,0) returns 0' );
    is( $t3d->index(0, 0, 1), 1, 'index(0,0,1) returns 1' );
    is( $t3d->index(0, 1, 0), 4, 'index(0,1,0) returns 4' );
    is( $t3d->index(1, 0, 0), 12, 'index(1,0,0) returns 12' );
};

subtest 'index method - error conditions' => sub {
    my $t = Tensor->initialize([2, 3], [1..6]);

    my $error;
    { local $@; eval { $t->index(0) }; $error = $@ }
    like $error, qr/number of indicies must match the rank/,
        'index with wrong number of coordinates should error';
    { local $@; eval { $t->index(0, 0, 0) }; $error = $@ }
    like $error, qr/number of indicies must match the rank/,
        'index with too many coordinates should error';
};

subtest 'rank method - tensor dimensionality' => sub {
    my $t1d = Tensor->initialize([5], [1..5]);
    is( $t1d->rank, 1, '1D tensor has rank 1' );

    my $t2d = Tensor->initialize([3, 4], [1..12]);
    is( $t2d->rank, 2, '2D tensor has rank 2' );

    my $t3d = Tensor->initialize([2, 3, 4], [1..24]);
    is( $t3d->rank, 3, '3D tensor has rank 3' );

    my $t4d = Tensor->initialize([2, 2, 2, 2], [1..16]);
    is( $t4d->rank, 4, '4D tensor has rank 4' );
};

subtest 'size method - total element count' => sub {
    my $t1 = Tensor->initialize([5], 0);
    is( $t1->size, 5, '1D tensor size is 5' );

    my $t2 = Tensor->initialize([3, 4], 0);
    is( $t2->size, 12, '2D tensor size is 12 (3*4)' );

    my $t3 = Tensor->initialize([2, 3, 4], 0);
    is( $t3->size, 24, '3D tensor size is 24 (2*3*4)' );

    my $t4 = Tensor->initialize([2, 2, 2, 2], 0);
    is( $t4->size, 16, '4D tensor size is 16 (2*2*2*2)' );
};

subtest 'shape method - dimension sizes' => sub {
    my $t1d = Tensor->initialize([5], [1..5]);
    is_deeply( $t1d->shape, [5], '1D tensor shape is [5]' );

    my $t2d = Tensor->initialize([3, 4], [1..12]);
    is_deeply( $t2d->shape, [3, 4], '2D tensor shape is [3, 4]' );

    my $t3d = Tensor->initialize([2, 3, 4], [1..24]);
    is_deeply( $t3d->shape, [2, 3, 4], '3D tensor shape is [2, 3, 4]' );
};

subtest 'strides method - stride values' => sub {
    my $t2d = Tensor->initialize([3, 4], [1..12]);
    is_deeply( [$t2d->strides], [4, 1], '2D tensor strides are [4, 1]' );

    my $t3d = Tensor->initialize([2, 3, 4], [1..24]);
    is_deeply( [$t3d->strides], [12, 4, 1], '3D tensor strides are [12, 4, 1]' );
};

done_testing;

__END__
