#!/usr/bin/perl

BEGIN {
    @INC = -f "./TestInit.pm" ? (".") : ("..");
}
use TestInit qw(T);
use strict;
use warnings;
use Storable qw(dclone);
require "./t/test.pl";
require "./regen/diag_plural.pm";

my $data = Diag::Plural::load_data();
my $model = Diag::Plural::compile($data);
my $c = Diag::Plural::render($model);
plan(tests => 27);

is($data->{version}{package}, '49.0.0', 'CLDR source package version');
is(scalar keys %{$data->{cardinal}{locales}}, 225,
    'all explicit cardinal locales are retained');
is(scalar keys %{$data->{ordinal}{locales}}, 109,
    'all explicit ordinal locales are retained');
my $cs_rule = $data->{cardinal}{rules}
    {$data->{cardinal}{locales}{cs}}{many};
is($cs_rule->{condition}, 'v != 0',
    'decimal-only cardinal condition is retained verbatim');
is(Diag::Plural::render_condition(
        Diag::Plural::parse_condition($cs_rule->{condition})),
    '0', 'decimal-only cardinal condition is false for integers');
is(scalar @{$model->{locales}}, 236,
    'compiled table includes plural regional overrides');
ok(@{$model->{rules}} < 70,
    'equivalent integer rules are deduplicated across rule sets');

my %locales = map { $_->{name} => $_ } @{$model->{locales}};
is($locales{'pt-ao'}{cardinal}, $locales{'pt-pt'}{cardinal},
    'pt-AO cardinal rules inherit the CLDR plural parent pt-PT');
is($locales{'pt-ao'}{ordinal}, $locales{pt}{ordinal},
    'pt-AO ordinal rules use ordinary language fallback');
ok(!exists $locales{'pt-br'},
    'ordinary region fallback is left to the runtime lookup');
ok(!(grep { !$_->{ordinal} || !$_->{cardinal} } @{$model->{locales}}),
    'every known locale has cardinal and ordinal rule IDs');

my @ascii_sorted = sort {
    Diag::Plural::_ascii_sort_key($a) cmp Diag::Plural::_ascii_sort_key($b)
} keys %locales;
is(join(',', map { $_->{name} } @{$model->{locales}}), join(',', @ascii_sorted),
    'locale table uses ASCII code point ordering');
ok(index($c, "static U8\nPerl_diag_plural_evaluate(U16 rule, UV n)") >= 0,
    'C output defines the integer rule evaluator');
ok(index($c, 'static const perl_diag_plural_locale perl_diag_plural_locales[]') >= 0,
    'C output defines the locale table');
ok(index($c, 'perl_diag_selector_plural_other') >= 0,
    'C output returns the existing plural category constants');
ok(index($c, 'return 0;') >= 0,
    'unknown rule IDs return the invalid selector');
ok(index($c, 'n >= 0U') < 0,
    'C output omits tautological unsigned lower bounds');

is(Diag::Plural::render_condition(
        Diag::Plural::parse_condition('n = 1 or n = 2 and n = 3')),
    '((n == 1U) || ((n == 2U) && (n == 3U)))',
    'and binds more tightly than or');
is(Diag::Plural::render_condition(
        Diag::Plural::parse_condition('i = 0..1')),
    '(n <= 1U)', 'integer operands reduce to the unsigned input');
is(Diag::Plural::render_condition(
        Diag::Plural::parse_condition('v != 0')),
    '0', 'fraction-only conditions are false for integer input');
is(Diag::Plural::render_condition(
        Diag::Plural::parse_condition(
            'e = 0 and i != 0 and i % 1000000 = 0 and v = 0 or e != 0..5')),
    '((n != 0U) && (n % 1000000U == 0U))',
    'integer constants fold and exponent operands reduce to zero');
is(Diag::Plural::render_condition(
        Diag::Plural::parse_condition('n % 10 = 1..3,3..5')),
    '(n % 10U >= 1U && n % 10U <= 5U)',
    'overlapping and adjacent ranges are merged');

sub dies_like {
    my ($code, $pattern, $name) = @_;
    my $ok = eval { $code->(); 1 };
    my $error = $@;
    ok(!$ok && $error =~ $pattern, $name) or diag($error);
}

dies_like(sub { Diag::Plural::parse_condition('n = 1; system') },
    qr/Invalid token/, 'rejects unexpected tokens');
dies_like(sub { Diag::Plural::parse_condition('n = 3..1') },
    qr/Descending plural rule range/, 'rejects descending ranges');
dies_like(sub { Diag::Plural::parse_condition('n = 4294967296') },
    qr/exceeds 32-bit unsigned range/, 'rejects literals beyond UV32');
my $bad = dclone($data);
$bad->{cardinal}{locales}{'pt-AO'} = 'missing';
dies_like(sub { Diag::Plural::compile($bad) }, qr/Unknown cardinal rule/,
    'rejects locale references to missing rules');
$bad = dclone($data);
$bad->{plural_parents}{cardinal}{'pt-AO'} = 'missing';
dies_like(sub { Diag::Plural::compile($bad) }, qr/no explicit rule/,
    'rejects plural parents without explicit target rules');
