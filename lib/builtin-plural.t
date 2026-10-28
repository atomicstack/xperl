#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use strict;
use warnings;
use builtin qw(cardinal_plural_form ordinal_plural_form);
no warnings 'experimental::builtin';

my @n        = ( 0 .. 5, 10 .. 14, 20 .. 23, 100, 101, 111, 112, 113, 999999, 1000000, 1000001, 2000000 );
my %cardinal = (
    ar => [
        qw(zero one two few few few few many many many many many many many many other other many many many many other other other)
    ],
    en => [
        qw(other one other other other other other other other other other other other other other other other other other other other other other other)
    ],
    fr => [
        qw(one one other other other other other other other other other other other other other other other other other other other many other many)
    ],
    es => [
        qw(other one other other other other other other other other other other other other other other other other other other other many other many)
    ],
);
$cardinal{he} = [
    qw(other one two other other other other other other other other other other other other other other other other other other other other other)
];
$cardinal{fa} = [
    qw(one one other other other other other other other other other other other other other other other other other other other other other other)
];
$cardinal{de} = $cardinal{fi} = $cardinal{hu} = $cardinal{nl} = $cardinal{tr} = $cardinal{en};
$cardinal{pt} = $cardinal{fr};
$cardinal{it} = $cardinal{es};
$cardinal{ru} = $cardinal{uk} =
  [qw(many one few few few many many many many many many many one few few many one many many many many many one many)];
$cardinal{cy} = [
    qw(zero one two few other other other other other other other other other other other other other other other other other other other other)
];

for my $language ( sort keys %cardinal ) {
    is( scalar @{ $cardinal{$language} }, scalar @n, "$language fixture covers every count" );
    for my $i ( 0 .. $#n ) {
        is( cardinal_plural_form( $language, $n[$i] ), $cardinal{$language}[$i], "$language cardinal $n[$i]" );
    }
}

my @ordinal_n = ( 0 .. 5, 8, 10 .. 14, 20 .. 23, 80, 100, 101, 111, 112, 113, 800 );
my %ordinal   = (
    en => [
        qw(other one two few other other other other other other other other other one two few other other one other other other other)
    ],
    fr => [
        qw(other one other other other other other other other other other other other other other other other other other other other other other)
    ],
    it => [
        qw(other other other other other other many other many other other other other other other other many other other other other other many)
    ],
);
$ordinal{hu} = [
    qw(other one other other other one other other other other other other other other other other other other other other other other other)
];
$ordinal{$_} = [ ('other') x @ordinal_n ] for qw(ar de fa fi he nl pt tr ru);
$ordinal{es} = [ map {
    ($_ % 10 == 1 || $_ % 10 == 3) && $_ % 100 != 11 ? 'one' : 'other'
} @ordinal_n ];
$ordinal{uk} = [ map {
    $_ % 10 == 3 && $_ % 100 != 13 ? 'few' : 'other'
} @ordinal_n ];
$ordinal{cy} = [
    qw(zero one two few few many zero other other other other other other other other other other other other other other other other)
];
for my $language ( sort keys %ordinal ) {
    is( scalar @{ $ordinal{$language} }, scalar @ordinal_n, "$language ordinal fixture covers every position" );
    for my $i ( 0 .. $#ordinal_n ) {
        is(
            ordinal_plural_form( $language, $ordinal_n[$i] ),
            $ordinal{$language}[$i],
            "$language ordinal $ordinal_n[$i]"
        );
    }
}

for my $function ( \&cardinal_plural_form, \&ordinal_plural_form ) {
    for my $language ( undef, '', 'zz', 'en--US', 'en_', '../en', [],
                      "en\0fr", "en\x{100}" ) {
        is( $function->( $language, 1 ), undef, 'unsupported language returns undef' );
    }
    for my $language ( 'EN', 'en_US', 'En-US.UTF-8', 'en_US.UTF-8@euro',
                      'en-US-u-nu-latn', 'C', 'C.UTF-8', 'POSIX',
                      'en-US-x-' . join('-', ('abcdefgh') x 30) ) {
        is( $function->( $language, 21 ), $function->('en', 21),
            "$language resolves to English" );
    }
    for my $n ( '0001', '1' ) {
        is( $function->( 'en', $n ), 'one', 'decimal strings are accepted' );
    }
    for my $n ( undef, -1, 1.5, '1.5', '1e2', [], 'NaN', "1\0", '' ) {
        eval { $function->( 'en', $n ) };
        like( $@, qr/unsigned integer n/, 'invalid unsigned integer is rejected' );
    }
    eval { $function->('en') };
    like( $@, qr/language, n/, 'arity is checked' );
}

my $uv_max = ~0;
for my $n ( $uv_max, $uv_max - 1, $uv_max - 2, $uv_max - 20 ) {
    is( cardinal_plural_form( 'en', $n ), 'other', 'UV boundary stays an integer' );
    is( cardinal_plural_form( 'fi', $n ), 'other', 'Finnish cardinal stays exact near UV_MAX' );
    is( ordinal_plural_form( 'fi', $n ),  'other', 'Finnish ordinal stays other near UV_MAX' );
    is( cardinal_plural_form( 'hu', $n ), 'other', 'Hungarian cardinal stays exact near UV_MAX' );
    is( ordinal_plural_form( 'hu', $n ),  'other', 'Hungarian ordinal stays other near UV_MAX' );
    is( cardinal_plural_form( 'tr', $n ), 'other', 'Turkish cardinal stays exact near UV_MAX' );
    is( ordinal_plural_form( 'tr', $n ),  'other', 'Turkish ordinal stays other near UV_MAX' );
    is( cardinal_plural_form( 'he', $n ), 'other', 'Hebrew cardinal stays exact near UV_MAX' );
    is( ordinal_plural_form( 'he', $n ),  'other', 'Hebrew ordinal stays other near UV_MAX' );
    is( cardinal_plural_form( 'fa', $n ), 'other', 'Persian cardinal stays exact near UV_MAX' );
    is( ordinal_plural_form( 'fa', $n ),  'other', 'Persian ordinal stays other near UV_MAX' );
    my $english =
        $n % 100 == 11 || $n % 100 == 12 || $n % 100 == 13 ? 'other'
      : $n % 10 == 1                                       ? 'one'
      : $n % 10 == 2                                       ? 'two'
      : $n % 10 == 3                                       ? 'few'
      :                                                      'other';
    is( ordinal_plural_form( 'en', $n ), $english, 'ordinal modulo works near UV_MAX' );

    for my $language (qw(fr pt es it)) {
        is(
            cardinal_plural_form( $language, $n ),
            $n % 1000000 == 0 ? 'many' : 'other',
            "$language modulo works near UV_MAX"
        );
    }
    my $slavic =
        $n % 10 == 1 && $n % 100 != 11 ? 'one'
      : $n % 10 >= 2 && $n % 10 <= 4 && ( $n % 100 < 12 || $n % 100 > 14 ) ? 'few'
      :                                                                      'many';
    for my $language (qw(ru uk)) {
        is( cardinal_plural_form( $language, $n ), $slavic, "$language cardinal modulo stays exact near UV_MAX" );
        my $ordinal = $language eq 'uk' && $n % 10 == 3 && $n % 100 != 13
            ? 'few' : 'other';
        is( ordinal_plural_form( $language, $n ), $ordinal,
            "$language ordinal modulo stays exact near UV_MAX" );
    }
    is( cardinal_plural_form( 'cy', $n ), 'other', 'Welsh cardinal large counts use other' );
    is( ordinal_plural_form( 'cy', $n ),  'other', 'Welsh ordinal large counts use other' );
    my $arabic =
        $n % 100 >= 3 && $n % 100 <= 10 ? 'few'
      : $n % 100 >= 11                  ? 'many'
      :                                   'other';
    is( cardinal_plural_form( 'ar', $n ), $arabic, 'Arabic cardinal modulo stays exact near UV_MAX' );
    is( ordinal_plural_form( 'ar', $n ),  'other', 'Arabic ordinal large counts use other' );
}

# Welsh's six categories describe different sets for quantities and positions.
# Keep every small exact boundary explicit rather than deriving one from the other.
my @welsh_cardinal = qw(zero one two few other other many other other other other other);
my @welsh_ordinal  = qw(zero one two few few many many zero zero zero other other);
for my $n ( 0 .. $#welsh_cardinal ) {
    is( cardinal_plural_form( 'cy', $n ), $welsh_cardinal[$n], "Welsh cardinal boundary $n" );
    is( ordinal_plural_form( 'cy', $n ),  $welsh_ordinal[$n],  "Welsh ordinal boundary $n" );
}
for my $n ( 6, 15, 25, 51, 105 ) {
    is( ordinal_plural_form( 'hu', $n ), 'other', 'Hungarian ordinal exceptions are exact numbers, not final digits' );
}
my $too_large = "$uv_max";
$too_large .= '0';
eval { cardinal_plural_form( 'en', $too_large ) };
like( $@, qr/unsigned integer n/, 'overflowing decimal input is rejected' );

{

    package PluralArgument;
    sub TIESCALAR { bless { value => $_[1], fetches => 0 }, $_[0] }
    sub FETCH     { $_[0]{fetches}++; $_[0]{value} }
    sub STORE     { die 'plural builtin must not change its arguments' }
}
tie my $language, 'PluralArgument', 'en';
tie my $number,   'PluralArgument', 21;
is( ordinal_plural_form( $language, $number ), 'one', 'magical arguments work' );
is( tied($language)->{fetches},                1,     'language FETCH occurs once' );
is( tied($number)->{fetches},                  1,     'number FETCH occurs once' );

is( cardinal_plural_form( 'en', 0 ), 'other', 'other is a category, never a wildcard' );
is( cardinal_plural_form( 'fr', 0 ), 'one',   'zero need not have category zero' );

our $CLDR_DATA;
do '../lib/unicore/cldr/plural.pl' or die $@ || $!;
for my $kind (qw(cardinal ordinal)) {
    my $function = $kind eq 'cardinal'
        ? \&cardinal_plural_form : \&ordinal_plural_form;
    for my $locale (sort keys %{$CLDR_DATA->{$kind}{locales}}) {
        my $rules = $CLDR_DATA->{$kind}{rules}
            {$CLDR_DATA->{$kind}{locales}{$locale}};
        for my $category (@{$CLDR_DATA->{categories}}) {
            next unless exists $rules->{$category};
            for my $sample (@{$rules->{$category}{integer_samples}{values}}) {
                my ($first, $last) = split /~/, $sample;
                $last = $first unless defined $last;
                my @values = $last - $first <= 100
                    ? ($first .. $last) : ($first, $last);
                for my $value (@values) {
                    is($function->($locale, $value), $category,
                        "CLDR $kind $locale integer sample $value");
                }
            }
        }
    }
}

for my $locale (sort keys %{$CLDR_DATA->{cardinal}{locales}}) {
    next if exists $CLDR_DATA->{ordinal}{locales}{$locale};
    for my $n (0, 1, 2, 3, 11, 21, 1000000, $uv_max) {
        is(ordinal_plural_form($locale, $n), 'other',
            "$locale has the default ordinal rule without a pack");
    }
}

for my $kind (qw(cardinal ordinal)) {
    my $function = $kind eq 'cardinal'
        ? \&cardinal_plural_form : \&ordinal_plural_form;
    for my $locale (sort keys %{$CLDR_DATA->{plural_parents}{$kind}}) {
        my $target = $CLDR_DATA->{plural_parents}{$kind}{$locale};
        for my $n (0, 1, 2, 21, 1000000, $uv_max) {
            is($function->($locale, $n), $function->($target, $n),
                "$kind $locale follows its plural parent $target for $n");
        }
    }
}
is(cardinal_plural_form('pt_AO.UTF-8', 0), 'other',
    'POSIX regional lookup keeps the Portuguese cardinal override');
for my $locale ('pt-Latn-AO', 'pt_Latn_AO.UTF-8', 'pt_AO.UTF-8@latin',
                'pt-Latn-AO-u-nu-latn') {
    is(cardinal_plural_form($locale, 0), 'other',
        "$locale keeps its regional override alongside the script");
}
is(cardinal_plural_form('pt-BR', 0), 'one',
    'Brazilian Portuguese uses the generic Portuguese cardinal rule');
for my $locale ('sr_RS.UTF-8@latin', 'sr-Latn-RS', 'sr_Latn_RS',
                'sr-Cyrl-RS@latin') {
    is(cardinal_plural_form($locale, 2), 'few',
        "$locale resolves Serbian script and region subtags");
}

done_testing;
