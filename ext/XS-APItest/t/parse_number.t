#!perl
use strict;
use warnings;
use Test::More;
use Config;
use XS::APItest;

my @types = parse_number_types();
my $specials = $Config{d_double_has_inf} && $Config{d_double_has_nan}
               && !($^O eq 'aix' && $Config{uselongdouble});
ok(grep($_ eq 'NV', @types), 'native parser is always available');

my @cases = (
    ['', 0, 0], [' ', 0, 0], ['junk', 0, 0], ['-junk', 0, 0],
    ['.', 0, 0], ['+', 0, 0], ['- 1', 0, 0],
    ['0', 0, IS_NUMBER_IN_UV], ['-0', 0, IS_NUMBER_IN_UV | IS_NUMBER_NEG],
    [" \t+12\r\n", 12, IS_NUMBER_IN_UV],
    ['-1.25', -1.25, IS_NUMBER_IN_UV | IS_NUMBER_NOT_INT | IS_NUMBER_NEG],
    ['.5', .5, IS_NUMBER_IN_UV | IS_NUMBER_NOT_INT],
    ['1.', 1, IS_NUMBER_IN_UV | IS_NUMBER_NOT_INT],
    ['2e3', 2000, IS_NUMBER_NOT_INT],
    ['2E-3', .002, IS_NUMBER_NOT_INT],
    ['12e+', 12, IS_NUMBER_IN_UV | IS_NUMBER_TRAILING],
    ['12e-', 12, IS_NUMBER_IN_UV | IS_NUMBER_TRAILING],
    ['12e', 12, IS_NUMBER_IN_UV | IS_NUMBER_TRAILING],
    ['1inf', 1, IS_NUMBER_IN_UV | IS_NUMBER_TRAILING],
    ['23nan', 23, IS_NUMBER_IN_UV | IS_NUMBER_TRAILING],
    ['1.#junk', 1, IS_NUMBER_IN_UV | IS_NUMBER_NOT_INT | IS_NUMBER_TRAILING],
    ['0x10', 0, IS_NUMBER_IN_UV | IS_NUMBER_TRAILING],
    ['0b11', 0, IS_NUMBER_IN_UV | IS_NUMBER_TRAILING],
    ['0 but true', 0, IS_NUMBER_IN_UV],
    ['0 but true ', 0, IS_NUMBER_IN_UV | IS_NUMBER_TRAILING],
    ["12\0", 12, IS_NUMBER_IN_UV | IS_NUMBER_TRAILING],
    ["\0", 0, 0],
    ["12 \0 34", 12, IS_NUMBER_IN_UV | IS_NUMBER_TRAILING],
);

for my $type (@types) {
    no strict 'refs';
    my $parse = \&{"parse_number_$type"};
    subtest $type => sub {
        for my $case (@cases) {
            my ($input, $want, $want_flags) = @$case;
            my ($value, $flags, $text, $errno, $optional) = $parse->($input);
            my $label = unpack('H*', $input);
            cmp_ok(abs($value - $want), '<=', abs($want) * 1e-7,
                   "value for hex $label");
            is($flags, $want_flags, "flags for hex $label");
            ok($errno, 'caller errno preserved');
            ok($optional, 'flags pointer may be NULL');
        }
        is(($parse->('12345', 3))[0], 123, 'bounded numeric prefix');
        is(($parse->('12345', 3))[1], IS_NUMBER_IN_UV,
           'bytes outside the supplied length do not count as trailing');
        is_deeply([($parse->('12345', 0))[0, 1]], [0, 0],
                  'zero length means empty input');
        SKIP: {
            skip 'Inf/NaN unsupported for this type', 35
                unless $specials && !($type eq 'LD' && $^O eq 'aix');
            for my $input ('Inf', '-Infinity', '1.#INF', '+infinity junk') {
                my ($value, $flags, undef, $errno) = $parse->($input);
                ok($flags & IS_NUMBER_INFINITY, "$input is literal infinity");
                ok(!($flags & PERL_PARSE_OVERFLOW), 'literal infinity is not overflow');
                ok($errno, 'errno preserved for infinity');
                ok($value != 0 && $value == $value * 2, 'returned value is infinite');
                ok($input =~ /^-/ ? $value < 0 : $value > 0, 'infinity has the input sign');
            }
            for my $input ('NaN', '-nan', '1.#IND', 'nan(123)', 'qnan') {
                my ($value, $flags) = $parse->($input);
                ok($flags & IS_NUMBER_NAN, "$input is NaN");
                ok($value != $value, 'value is NaN');
                ok(!($flags & (PERL_PARSE_OVERFLOW | PERL_PARSE_UNDERFLOW)),
                   'NaN has no range error');
            }
        }
        my (undef, $flags, undef, $errno) = $parse->('1e999999');
        ok($flags & PERL_PARSE_OVERFLOW, 'finite decimal overflow reported');
        ok(!($flags & IS_NUMBER_INFINITY), 'overflow is not a literal infinity');
        ok($errno, 'errno preserved on overflow');
        my ($tiny, $tiny_flags) = $parse->('-1e-999999');
        is($tiny, 0, 'tiny input rounds to zero');
        ok($tiny_flags & PERL_PARSE_UNDERFLOW, 'nonzero to zero is underflow');
        ok(!($tiny_flags & PERL_PARSE_SUBNORMAL), 'zero is not subnormal');
        is(($parse->('0e-999999'))[1], IS_NUMBER_NOT_INT,
           'zero significand is not underflow');
        SKIP: {
            skip 'signed zero unsupported', 1 unless $Config{d_double_has_negative_zero};
            like(($parse->('-0'))[2], qr/^-/, 'preserve negative zero');
        }
        unlike(($parse->('-0x1'))[2], qr/^-/, 'Perl hex-prefix rejection returns positive zero');
    };
}

if (grep $_ eq 'Float32', @types) {
    is((parse_number_Float32(
        '1.0000000596046447753906250000000000000000000000000000000001'))[2],
       '1.00000012', 'Float32 converts directly rather than through double');
    my ($value, $flags) = parse_number_Float32('1e-40');
    ok($value > 0, 'Float32 retains subnormal value');
    ok($flags & PERL_PARSE_SUBNORMAL, 'Float32 subnormal classified');
}
if (grep $_ eq 'Float64', @types) {
    my ($value, $flags) = parse_number_Float64('1e-310');
    ok($value > 0, 'Float64 retains subnormal value');
    ok($flags & PERL_PARSE_SUBNORMAL, 'Float64 subnormal classified');
}
if (grep $_ eq 'LD', @types) {
    # The C wrapper prints the wide result before converting it to Perl NV.
    my $wide = (parse_number_LD('9007199254740993'))[2];
    if ($Config{d_PRIgldbl} && ($Config{longdblmantbits} || 0) > 53) {
        is($wide, '9007199254740993', 'long double input does not pass through NV');
    }
}
if (grep $_ eq 'Float128', @types) {
    is((parse_number_Float128('9007199254740993'))[2], '9007199254740993',
       'binary128 input does not pass through double');
}


subtest 'directed rounding' => sub {
    require POSIX;
    my $saved = eval { POSIX::fegetround() };
    plan skip_all => 'rounding mode controls unavailable'
        if $@ || !defined($saved) || $saved < 0;
    my @rounds = eval { (POSIX::FE_DOWNWARD(), POSIX::FE_UPWARD()) };
    plan skip_all => 'directed rounding unavailable' if $@;
    # The system converter may return infinity or a finite limit.  Both
    # results must carry the overflow flag, including under directed rounding.
    my @results;
    for my $round (@rounds) {
        next unless POSIX::fesetround($round) == 0;
        for my $type (@types) {
            # The native fallback cannot promise finite saturation reporting.
            next if $type eq 'NV' && $Config{d_strtod} ne 'define'
                    && $Config{usequadmath} ne 'define'
                    && !($Config{uselongdouble} eq 'define'
                         && $Config{d_strtold} eq 'define');
            no strict 'refs';
            my $parse = \&{"parse_number_$type"};
            my $negative = $round == POSIX::FE_UPWARD() ? '-' : '';
            push @results, [$type, $round,
                           [$parse->("${negative}1e999999")]];
        }
    }
    POSIX::fesetround($saved);
    plan skip_all => 'directed rounding could not be enabled' unless @results;
    for my $row (@results) {
        my ($type, $round, $result) = @$row;
        my (undef, $flags, $text, $errno) = @$result;
        ok($flags & PERL_PARSE_OVERFLOW, "$type reports directed overflow ($round)");
        ok(!($flags & IS_NUMBER_INFINITY), 'finite source is not literal infinity');
        ok(!($flags & PERL_PARSE_UNDERFLOW), 'overflow is not underflow');
        ok($errno, 'errno preserved after directed overflow');
    }
};

subtest 'locale radices' => sub {
    require POSIX;
    require '../../t/loc_tools.pl';
    my $saved = POSIX::setlocale(POSIX::LC_NUMERIC());
    my ($chosen, $radix);
    {
        use locale;
        for my $locale (find_locales('LC_NUMERIC')) {
            next unless POSIX::setlocale(POSIX::LC_NUMERIC(), $locale);
            my $formatted = sprintf('%g', 1.5);
            if ($formatted =~ /^1(.+)5$/ && $1 ne '.') {
                ($chosen, $radix) = ($locale, $1);
                last;
            }
        }
    }
    unless ($chosen) {
        POSIX::setlocale(POSIX::LC_NUMERIC(), $saved);
        plan skip_all => 'no locale with a non-dot radix available';
    }
    for my $type (@types) {
        no strict 'refs';
        my $parse = \&{"parse_number_$type"};
        {
            use locale;
            is(($parse->("1${radix}5"))[0], 1.5, "$type accepts locale radix");
            is(($parse->('1.5'))[0], 1.5, "$type accepts dot in locale");
            is(($parse->("1${radix}5.7"))[0], 1.5,
               "$type uses the first accepted radix");
            ok(($parse->("1${radix}5.7"))[1] & IS_NUMBER_TRAILING,
               "$type flags second radix as trailing");
            is(($parse->("1.5${radix}7"))[0], 1.5,
               "$type accepts dot before the locale radix");
            is(sprintf('%g', 1.5), "1${radix}5", "$type restores locale");
        }
        is(($parse->("1${radix}5"))[0], 1, "$type ignores locale outside its scope");
        ok(($parse->("1${radix}5"))[1] & IS_NUMBER_TRAILING,
           "$type flags unrecognized locale radix");
        is(($parse->('1.5'))[0], 1.5, "$type accepts dot outside locale");
    }
    POSIX::setlocale(POSIX::LC_NUMERIC(), $saved);
};

done_testing;
