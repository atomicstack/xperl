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

{
    # accessors returning new containers must not keep an extra reference
    require Scalar::Util;
    my $t = Tensor::XS->new([2, 3], [1 .. 6], 'F64');
    for my $method (qw(shape strides data)) {
        my $result = $t->$method;
        is Internals::SvREFCNT(@$result), 1,
            "$method returns an array with a single reference";
        Scalar::Util::weaken(my $weak = $result);
        undef $result;
        ok !defined $weak, "$method result is freed when released";
    }
}

{
    # Converting an argument can run Perl code (overloading, ties) that
    # replaces the payload.  No pointer into the old payload may be used
    # afterwards. Each case checks its child's output and exit status.
    my $prelude = q{
        use strict; use warnings; use Tensor::XS;
        my $t = Tensor::XS->new([2, 3], [1 .. 6], 'F64');
        my $calls = 0;
        # undef frees the old buffer rather than reusing it for the new payload
        my $shrink = sub { $calls++; undef $$t;
                           $$t = ${ Tensor::XS->new([1], [0], 'F64') }; 5 };
        { package Evil; use overload '0+' => sub { $_[0][0]->() },
              '""' => sub { $_[0][0]->(); $_[0][1] }, fallback => 1; }
        my $evil = bless [$shrink, 'add'], 'Evil';
        { package EvilArray; require Tie::Array; our @ISA = ('Tie::StdArray');
          sub FETCH { $shrink->() if $_[1] == 3; $_[0][$_[1]] } }
        sub report { print defined $_[0] ? $_[0] : "ok\n" }
    };
    my $probe = sub {
        my ($code) = @_;
        open my $fh, '-|', $^X, (map "-I$_", @INC), '-e', $prelude . $code
            or die "cannot run $^X: $!";
        my $out = do { local $/; <$fh> };
        close $fh;
        is $?, 0, 'callback probe exits normally';
        return $out // '';
    };

    like $probe->(q{eval { $t->set_index(5, $evil) }; print $@}),
        qr/\Atensor index out of bounds/,
        'set_index checks the index against the payload it writes';
    like $probe->(q{eval { $t->set_at(1, 2, $evil) }; print $@}),
        qr/\Acoordinate count does not match tensor rank/,
        'set_at uses the payload present after converting the value';
    like $probe->(q{eval { $t->set_at(1, $evil, 7) }; print $@}),
        qr/\Acoordinate count does not match tensor rank/,
        'set_at uses the payload present after converting coordinates';
    like $probe->(q{eval { $t->at(1, $evil) }; print $@}),
        qr/\Acoordinate count does not match tensor rank/,
        'at uses the payload present after converting coordinates';
    like $probe->(q{eval { $t->index(1, $evil) }; print $@}),
        qr/\Acoordinate count does not match tensor rank/,
        'index uses the payload present after converting coordinates';
    like $probe->(q{{ package EvilScalar; sub TIESCALAR { bless [] }
                      sub FETCH { $shrink->() } }
                    my @data = (1 .. 6); tie $data[2], 'EvilScalar';
                    eval { $t->set_data(\@data) }; print $@}),
        qr/\Atensor changed while its data was being loaded/,
        'set_data notices a payload replaced by a tied element';
    like $probe->(q{tie my @data, 'EvilArray'; @data = (1 .. 6);
                    eval { $t->set_data(\@data) }; print $@}),
        qr/\Atensor changed while its data was being loaded/,
        'set_data notices a payload replaced by a tied array';
    is $probe->(q{$t->inplace($evil, 'add');
                  print "$calls ", join(',', @{ $t->data }), "\n"}),
        "1 5\n", 'inplace converts a scalar operand once, before the tensor';
    is $probe->(q{my $r = $t->binary($evil, 'add');
                  print "$calls ", join(',', @{ $r->data }), "\n"}),
        "1 5\n", 'binary converts a scalar operand once, before the tensor';
    is $probe->(q{$t->inplace(2, $evil);
                  print join(',', @{ $t->data }), "\n"}),
        "2\n", 'inplace reads the operation name before the tensor';
    is $probe->(q{$evil->[1] = 'neg'; my $r = $t->unary($evil);
                  print scalar(@{ $r->data }), "\n"}),
        "1\n", 'unary reads the operation name before the tensor';
    is $probe->(q{$evil->[1] = 'sum';
                  print $t->reduce($evil), "\n"}),
        "0\n", 'reduce reads the operation name before the tensor';
}

{
    # ordinary overloading and ties keep working
    {
        package Tensor::XS::Test::Number;
        use overload '0+' => sub { ${ $_[0] } }, fallback => 1;
    }
    my $seven = bless \(my $n = 7), 'Tensor::XS::Test::Number';
    my $t = Tensor::XS->new([2, 2], [1 .. 4], 'F64');
    $t->set_index(0, $seven);
    $t->set_at(1, 1, $seven);
    is_deeply $t->data, [7, 2, 3, 7], 'overloaded values are stored';
    $t->inplace($seven, 'add');
    is_deeply $t->data, [14, 9, 10, 14], 'an overloaded operand is applied';
    require Tie::Array;
    tie my @tied, 'Tie::StdArray';
    @tied = (5 .. 8);
    $t->set_data(\@tied);
    is_deeply $t->data, [5 .. 8], 'set_data reads a tied array';
    is $t->at($seven - 6, $seven - 7), 7, 'computed coordinates work';
}

{
    # writes must not reach a copy that shares the payload buffer, and must
    # respect a read-only payload
    # a payload that has been copied once has room for the copy-on-write
    # count, so a further copy shares its buffer
    my $pad = sub {
        my $payload = ${ Tensor::XS->new([2, 2], [1 .. 4], 'F64') };
        return bless \$payload, 'Tensor::XS';
    };
    for my $write (
        [ set_index => sub { $_[0]->set_index(0, 9) } ],
        [ set_at    => sub { $_[0]->set_at(0, 0, 9) } ],
        [ set_data  => sub { $_[0]->set_data([9, 9, 9, 9]) } ],
        [ inplace   => sub { $_[0]->inplace(8, 'add') } ],
    ) {
        my ($name, $code) = @$write;
        my $t = $pad->();
        my $copy = $$t;
        my $snapshot = bless \$copy, 'Tensor::XS';
        $code->($t);
        is $t->at(0, 0), 9, "$name writes the tensor";
        is_deeply $snapshot->data, [1 .. 4],
            "$name leaves a copy of the payload alone";

        my $locked = $pad->();
        Internals::SvREADONLY($$locked, 1);
        ok !eval { $code->($locked); 1 }, "$name refuses a read-only payload";
        like $@, qr/read-only/, "$name reports the read-only payload";
        is_deeply $locked->data, [1 .. 4],
            "$name leaves a read-only payload unchanged";
    }
}

{
    require Tie::Array;
    tie my @shape, 'Tie::StdArray';
    @shape = (2, 2);
    tie my @rows, 'Tie::StdArray';
    @rows = ([1, 2], [3, 4]);
    my $t = Tensor::XS->new(\@shape, \@rows, 'F64');
    is_deeply $t->data, [1 .. 4], 'constructor accepts tied shape and row arrays';

    my $calls = 0;
    {
        package Tensor::XS::Test::Dimension;
        use overload '0+' => sub { $_[0]->() }, fallback => 1;
    }
    my $shape;
    $shape = [bless(sub { ++$calls; $shape = undef; 2 },
                      'Tensor::XS::Test::Dimension')];
    $t = Tensor::XS->new($shape, 1, 'F64');
    is $calls, 1, 'constructor converts an overloaded dimension once';
    is_deeply $t->data, [1, 1], 'shape survives a callback dropping its last reference';

    my $class = 'Tensor::XS';
    my $dimension = bless sub { $class = 'Other::Tensor'; 2 },
        'Tensor::XS::Test::Dimension';
    $t = $class->new([$dimension], 1, 'F64');
    isa_ok $t, 'Tensor::XS', 'constructor retains its original class name';

    {
        package Tensor::XS::Test::StringNumber;
        use overload '0+' => sub { 7 }, fallback => 1;
    }
    my $number = bless \(my $text = 'seven'), 'Tensor::XS::Test::StringNumber';
    is_deeply $t->binary($number, 'add')->data, [8, 8],
        'a string-backed numeric object is a scalar operand';

    require Scalar::Util;
    my $weak = $t;
    Scalar::Util::weaken($weak);
    is_deeply $weak->data, [1, 1], 'weak references do not invalidate native payloads';

    {
        package Tensor::XS::Test::Payload;
        sub TIESCALAR { bless { value => $_[1], calls => $_[2] }, $_[0] }
        sub FETCH { ++${ $_[0]{calls} }; $_[0]{value} }
    }
    my $payload_calls = 0;
    my $payload = $$t;
    tie $$t, 'Tensor::XS::Test::Payload', $payload, \$payload_calls;
    eval { $t->data };
    like $@, qr/payload does not support scalar magic/,
        'native payloads reject callback magic';
    is $payload_calls, 0, 'native payload validation does not invoke magic';
}

{
    my $current = Tensor::XS->new([1], 4, 'F64');
    my $original = $current;
    my $replacement = Tensor::XS->new([1], 99, 'F64');
    my $index = bless sub { $current = $replacement; 0 },
        'Tensor::XS::Test::Dimension';
    is $current->at_index($index), 4,
        'indexed read retains its invocant before converting the index';
    $current = $original;
    $current->set_index($index, 7);
    is_deeply $original->data, [7],
        'indexed write retains its invocant before converting the index';
    is_deeply $replacement->data, [99],
        'indexed write leaves a replacement invocant alone';
}

{
    my @arguments;
    my $released = 0;
    my $released_during_conversion;
    {
        package Tensor::XS::Test::OwnedValue;
        use overload '0+' => sub { 7 }, fallback => 1;
        sub DESTROY { ++${ $_[0][0] } }
    }
    my $index = bless sub {
        @arguments = ();
        $released_during_conversion = $released;
        return 0;
    }, 'Tensor::XS::Test::Dimension';
    my $t = Tensor::XS->new([1], 4, 'F64');
    @arguments = ($t, $index, bless([\$released], 'Tensor::XS::Test::OwnedValue'));
    Tensor::XS::set_index(@arguments);
    is $released_during_conversion, 0,
        'an index callback cannot release a later argument';
    is_deeply $t->data, [7], 'an array-owned value survives argument-array clearing';
    is $released, 1, 'the retained value is released after the method returns';
}

{
    my @arguments;
    {
        package Tensor::XS::Test::ClassName;
        use overload '""' => sub { $_[0]->() }, fallback => 1;
    }
    my $class = bless sub { @arguments = (); 'Tensor::XS' },
        'Tensor::XS::Test::ClassName';
    @arguments = ($class, [2], 3, 'F64');
    my $t = Tensor::XS::new_with_dtype(@arguments);
    is_deeply $t->data, [3, 3],
        'constructor arguments survive class-name conversion clearing their array';
}

SKIP: {
    require Config;
    skip 'requires 64-bit integers', 1 unless $Config::Config{ivsize} >= 8;
    my $large = 9007199254740993;
    my $dimension = bless sub { $large }, 'Tensor::XS::Test::Dimension';
    my $t = Tensor::XS->new([$dimension, 0], 0, 'F64');
    is_deeply $t->shape, [$large, 0],
        'overloaded integer dimensions retain precision in an empty tensor';
}

SKIP: {
    require Config;
    skip 'debug builds deliberately cycle immortal reference counts', 1
        if Config::DEBUGGING();
    my $before = Internals::SvREFCNT(undef);
    Tensor::XS->new_with_dtype([0], undef, 'F64') for 1 .. 10;
    is Internals::SvREFCNT(undef), $before,
        'argument retention leaves immortal reference counts unchanged';
}

done_testing;
