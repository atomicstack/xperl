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

{
    # forged payloads: header fields are UVs (magic, version, rank, size,
    # dtype) followed by rank shape values and rank stride values
    require Config;
    my $uv = $Config::Config{uvsize} == 8 ? 'Q' : 'L';
    my $uvsize = $Config::Config{uvsize};
    my $forge = sub {
        my (%field) = @_;
        my $payload = ${ Tensor::XS->new([2, 3], [1 .. 6], 'F64') };
        for my $slot (keys %field) {
            substr($payload, $slot * $uvsize, $uvsize) = pack($uv, $field{$slot});
        }
        return bless \$payload, 'Tensor::XS';
    };
    my %forgeries = (
        'shape larger than size'        => { 5 => 1000, 6 => 1000 },
        'shape smaller than size'       => { 5 => 1 },
        'size inconsistent with shape'  => { 3 => 1 },
        'non-row-major strides'         => { 7 => 1000 },
        'transposed shape, old strides' => { 5 => 3, 6 => 2 },
        'zero inner stride'             => { 8 => 0 },
        'unknown dtype'                 => { 4 => 99 },
        'zero dtype'                    => { 4 => 0 },
        'huge rank'                     => { 2 => 1 << 30 },
        'shape product overflows'       => { 5 => 1 << 32, 6 => 1 << 32 },
    );
    for my $name (sort keys %forgeries) {
        my $forged = $forge->(%{ $forgeries{$name} });
        for my $call (
            [ at        => sub { $forged->at(1, 2) } ],
            [ set_at    => sub { $forged->set_at(1, 2, 1) } ],
            [ transpose => sub { $forged->transpose } ],
            [ data      => sub { $forged->data } ],
        ) {
            my ($method, $code) = @$call;
            ok !eval { $code->(); 1 }, "forged $name: $method dies";
            like $@, qr/invalid Tensor::XS object/,
                "forged $name: $method reports an invalid object";
        }
    }
    my $unforged = $forge->();
    is $unforged->at(1, 2), 6, 'an untouched payload copy still works';
}

{
    # nested data loading is bounded by a maximum rank
    my $data = 7;
    $data = [$data] for 1 .. 65;
    ok !eval { Tensor::XS->new([ (1) x 65 ], $data, 'F64'); 1 },
        'rank above the maximum is rejected';
    like $@, qr/tensor rank 65 exceeds the maximum of 64/,
        'rank limit error names the limit';
    $data = 7;
    $data = [$data] for 1 .. 64;
    my $deep = Tensor::XS->new([ (1) x 64 ], $data, 'F64');
    is $deep->rank, 64, 'maximum rank is accepted';
    is $deep->at((0) x 64), 7, 'maximum-rank nested data loads';

    my $script = q{
        use Tensor::XS;
        my $data = 7; $data = [$data] for 1 .. 200_000;
        eval { Tensor::XS->new([ (1) x 200_000 ], $data, 'F64') };
        print $@ =~ /exceeds the maximum/ ? "rejected\n" : "accepted: $@\n";
    };
    open my $fh, '-|', $^X, (map "-I$_", @INC), '-e', $script
        or die "cannot run $^X: $!";
    my $out = do { local $/; <$fh> };
    close $fh;
    is $out, "rejected\n", 'very deep nested data is rejected without recursion';
}

{
    # nonexistent elements load like undef instead of dereferencing NULL
    no warnings 'uninitialized';
    my @sparse;
    $#sparse = 3;
    $sparse[2] = 5;
    is_deeply(Tensor::XS->new([4], \@sparse, 'F64')->data, [0, 0, 5, 0],
        'sparse flat data loads missing elements as undef');
    my @deleted = (1, 2, 3, 4);
    delete $deleted[1];
    is_deeply(Tensor::XS->new([4], \@deleted, 'F64')->data, [1, 0, 3, 4],
        'deleted elements load as undef');
    my $t = Tensor::XS->new([2, 2], 0, 'F64');
    my @holes;
    $#holes = 3;
    $t->set_data(\@holes);
    is_deeply $t->data, [0, 0, 0, 0], 'set_data accepts sparse arrays';
    my @inner;
    $#inner = 1;
    is_deeply(Tensor::XS->new([2, 2], [\@inner, [1, 2]], 'F64')->data,
        [0, 0, 1, 2], 'sparse nested rows load as undef');
    my @rows;
    $#rows = 1;
    $rows[1] = [1, 2];
    ok !eval { Tensor::XS->new([2, 2], \@rows, 'F64'); 1 },
        'a missing nested row is rejected';
    like $@, qr/nested tensor data has too few dimensions/,
        'missing nested row reports too few dimensions';
    is_deeply(Tensor::XS->new([2, 0], 0, 'F64')->shape, [2, 0],
        'zero-length dimensions are accepted');
}

done_testing;
