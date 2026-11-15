use strict;
use warnings;
BEGIN {
    warnings->unimport('experimental::builtin') if $] >= 5.036;
}
use Test::More;

use lib 'lib';
use RNG;
use RNG::Seed;
use RNG::Drand48;
use RNG::PCG;
use RNG::PCG::RXS_M_XS_64_64;
use RNG::PCG::XSL_RR_128_64_MCG;
use RNG::PCG::XSL_RR_128_64_LCG;
use RNG::Wyrand;
use RNG::Xoshiro;
use RNG::HMAC_DRBG;

# Mix floating-point and byte requests to check replay of the complete
# sequence, including partial-word requests.  Secure initialization returns
# a redacted seed and is tested separately in hmac_drbg.t.
sub sequence {
    my ($provider) = @_;
    my @values;

    for my $length (0, 1, 3, 8, 17, 64) {
        push @values, $provider ? $provider->rand : rand();
        my $bytes = $provider ? $provider->rand_bytes($length)
                              : builtin::rand_bytes($length);
        push @values, unpack('H*', $bytes);
        push @values, $provider ? $provider->rand(10) : rand(10);
    }
    return \@values;
}

my @providers = (
    [ 'built-in Drand48',                 undef,                              4 ],
    [ 'Drand48',                         'RNG::Drand48',                      6 ],
    [ 'PCG extended',                    'RNG::PCG',                         16 ],
    [ 'PCG RXS-M-XS 64/64',              'RNG::PCG::RXS_M_XS_64_64',          8 ],
    [ 'PCG XSL-RR 128/64 MCG',           'RNG::PCG::XSL_RR_128_64_MCG',      16 ],
    [ 'PCG XSL-RR 128/64 LCG',           'RNG::PCG::XSL_RR_128_64_LCG',      32 ],
    [ 'Wyrand',                          'RNG::Wyrand',                       8 ],
    [ 'Xoshiro',                         'RNG::Xoshiro',                     32 ],
    [ 'HMAC_DRBG deterministic',         'RNG::HMAC_DRBG',                   64 ],
);

for my $entry (@providers) {
    my ($name, $class, $width) = @$entry;
    my @cases = (
        [ 'zero',            0 ],
        [ 'historical zero', '0 but true' ],
        [ 'integer',         42 ],
        [ 'fraction',        '-123.5' ],
        [ 'exponent',        '1e6' ],
        [ 'empty string',    '' ],
        [ 'text',            'replay this seed' ],
        [ 'octets',          "\0\xff\x80" ],
        [ 'Unicode',         "snowman \x{2603}" ],
        [ 'raw zero',        RNG::Seed->from_bytes("\0" x $width) ],
        [ 'raw high bits',   RNG::Seed->from_bytes("\xff" x $width) ],
        [ 'raw even bits',   RNG::Seed->from_bytes("\xfe" x $width) ],
        [ 'absent' ],
        [ 'undefined',       undef ],
    );

    my @modes = $class ? ('direct', 'core') : ('core');
    for my $mode (@modes) {
        subtest "$name via $mode" => sub {
            for my $case (@cases) {
                my ($label, @input) = @$case;
                my $provider = $class ? $class->new(42) : undef;
                local ${^RNG} = $mode eq 'core' ? $provider : undef;
                my $returned = $mode eq 'direct'
                    ? $provider->srand(@input)
                    : @input ? srand($input[0]) : srand();
                ok(defined($returned), "$label return is defined");
                ok($returned, "$label return is true");
                if ($class && $class ne 'RNG::Drand48'
                    && ($label eq 'zero' || $label eq 'empty string')) {
                    isa_ok($returned, 'RNG::Seed');
                    is("$returned", "$input[0]",
                       "$label return stringifies to the original seed");
                    ok(!$returned->isa('RNG::SeedBase'),
                       "$label return is string seed material, not raw state");
                }
                my $direct = $mode eq 'direct' ? $provider : undef;
                my $expected = sequence($direct);

                if ($mode eq 'direct') {
                    $provider->srand($returned);
                }
                else {
                    srand($returned);
                }
                is_deeply(sequence($direct), $expected,
                          "$label return replays on the original generator");

                if ($class) {
                    my $fresh = $class->new(123);
                    if ($mode eq 'direct') {
                        $fresh->srand($returned);
                    }
                    else {
                        ${^RNG} = $fresh;
                        srand($returned);
                    }
                    is_deeply(sequence($mode eq 'direct' ? $fresh : undef),
                              $expected,
                              "$label return replays on a fresh generator");
                }
            }
            if ($class && $class ne 'RNG::Drand48') {
                my $zero = $class->new(0);
                my $text = $class->new('0 but true');
                isnt($zero->rand_bytes(32), $text->rand_bytes(32),
                     'historical Drand48 zero is ordinary string seed material');
            }
            done_testing;
        };
    }
}

# Byte counts and object state are checked before anything is allocated
# or dereferenced.  Each probe runs in a child perl so that a crash shows
# up as a failure rather than ending this test file.
{
    my $probe = sub {
        my ($code) = @_;
        my $script = 'use strict; use warnings; use RNG; ' . $code
                   . '; print "survived\n"';
        open my $fh, '-|', $^X, (map "-I$_", @INC), '-e',
            "eval { $script; 1 } or print \$\@"
            or die "cannot run $^X: $!";
        my $out = do { local $/; <$fh> };
        close $fh;
        return $out;
    };
    for my $class (qw(RNG::Drand48 RNG::PCG RNG::PCG::RXS_M_XS_64_64
                      RNG::PCG::XSL_RR_128_64_MCG
                      RNG::PCG::XSL_RR_128_64_LCG RNG::Wyrand
                      RNG::Xoshiro RNG::HMAC_DRBG)) {
        my $provider = $class->new(42);
        is(length $provider->rand_bytes(0), 0, "$class rand_bytes(0)");
        is(length $provider->rand_bytes(17), 17, "$class rand_bytes(17)");
        for my $count ('-1', '-4096', '~0') {
            like($probe->("require $class; $class->new(1)->rand_bytes($count)"),
                 qr/^rand_bytes\(\) count must be a non-negative integer/,
                 "$class rand_bytes($count) is rejected");
        }
        for my $self ('"not a ref"', '\\"short"', '[]') {
            like($probe->("require $class; "
                          . "${class}::get_rand_U01_XS_state_addr($self)"),
                 qr/object does not contain a valid state/,
                 "$class state address rejects $self");
        }
        ok(${class}->can('get_rand_U01_XS_state_addr')->($provider),
           "$class state address of a valid object");
    }
    # the providers above have loaded the XS, which defines the shim
    like($probe->('require RNG::PCG; RNG::_legacy_rand_bytes(-1)'),
         qr/^rand_bytes\(\) count must be a non-negative integer/,
         'legacy rand_bytes(-1) is rejected');
}

done_testing;
