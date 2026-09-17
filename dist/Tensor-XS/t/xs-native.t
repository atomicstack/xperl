#!./perl
use strict;
use warnings;
use Test::More;

my @lib = -d '../dist/Tensor-XS/blib/arch'
    ? ('../dist/Tensor-XS/blib/lib', '../dist/Tensor-XS/blib/arch')
    : ('dist/Tensor-XS/blib/lib', 'dist/Tensor-XS/blib/arch');
unshift @INC, @lib;

eval { require Tensor::XS; 1 }
    or plan skip_all => "Tensor::XS is not built: $@";

my $tensor = Tensor::XS->new([2, 3], [1, 2, 3, 4, 5, 6]);
is $tensor->rank, 2, 'native rank is stored';
is $tensor->size, 6, 'native size is stored';
is $tensor->dtype, 'BF16', 'default native dtype is BF16';
is $tensor->element_size, 2, 'default native element size is two bytes';
is_deeply $tensor->shape, [2, 3], 'native shape metadata is returned';
is_deeply $tensor->strides, [3, 1],
    'native strides use one conventional stride per dimension';
is $tensor->index(1, 1), 4, 'native coordinate indexing returns flat index';
is $tensor->at(1, 1), 5, 'native coordinate access works';
$tensor->set_at(1, 1, 9);
is $tensor->at(1, 1), 9, 'native coordinate mutation works';
$tensor->set_data([6, 5, 4, 3, 2, 1]);
is_deeply $tensor->data, [6, 5, 4, 3, 2, 1],
    'native data is returned in row-major order';

my $nested = Tensor::XS->new([2, 2], [[1, 2], [3, 4]]);
is_deeply $nested->data, [1, 2, 3, 4],
    'nested constructor data is flattened row-major';
$nested->set_data([[4, 3], [2, 1]]);
is_deeply $nested->data, [4, 3, 2, 1],
    'nested mutation data is flattened row-major';

eval { Tensor::XS->new([2, 2], [[1], [2, 3]]) };
like $@, qr/nested tensor data does not match tensor shape/,
    'ragged nested data is rejected';

my $stable = Tensor::XS->new([2, 2], [1, 2, 3, 4]);
eval { $stable->set_data([[9], [8, 7]]) };
like $@, qr/nested tensor data does not match tensor shape/,
    'ragged bulk mutation is rejected';
is_deeply $stable->data, [1, 2, 3, 4],
    'rejected bulk mutation leaves native data unchanged';

my $payload = ${$stable};
substr($payload, 0, 1) = 'X';
my $corrupt = bless \$payload, 'Tensor::XS';
eval { $corrupt->size };
like $@, qr/invalid Tensor::XS object/,
    'corrupt native blob magic is rejected';

my $three_d = Tensor::XS->new([2, 3, 4], [0 .. 23]);
is_deeply $three_d->strides, [12, 4, 1],
    'rank-three strides are backend-compatible';
is $three_d->at(1, 2, 3), 23,
    'rank-three coordinate access follows conventional strides';

for my $dtype (qw(U8 U16 U32 U64 I8 I16 I32 I64 F16 BF16 F32 F64 NV)) {
    my $typed = Tensor::XS->new([2], [1, 2], $dtype);
    is $typed->dtype, $dtype, "$dtype dtype is retained";
    is $typed->at(1), 2, "$dtype values round-trip";
}

my $u64 = Tensor::XS->new([1], [18446744073709551615], 'U64');
is $u64->at(0), '18446744073709551615',
    'U64 values round-trip without NV precision loss';

done_testing;
