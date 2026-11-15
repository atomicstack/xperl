use strict;
use warnings;
use Test::More;
use Config;
use POSIX             qw(ldexp frexp nextafter HUGE_VAL isfinite);
use XStats::Functions qw(erf erfc erf_inv erfc_inv normal_cdf normal_survival
  normal_quantile normal_inverse_survival sigma_to_alpha alpha_to_sigma);

my $available = eval { erf(0.5); erfc(0.5); 1 };
unless ($available) {
    my $failure = $@;
    die $failure
      unless ref($failure)
      && $failure->has_diagnostic('XStats::UNSUPPORTED_MATH');

    plan tests => 1;
    pass('missing native NV math raises UNSUPPORTED_MATH; numerical checks skipped');
    exit 0;
}

my $epsilon   = ldexp( 1, -$Config{nvmantbits} );
my $tolerance = 128 * $epsilon;

sub near {
    my ( $got, $want, $name ) = @_;
    ok( isfinite($got), "$name is finite" );
    cmp_ok( abs( ( $got - $want ) / $want ), '<', $tolerance, $name );
}

# Independent 100-digit series/bisection fixtures, rounded to configured NV.
near( erf(0.5),
    0 + '0.520499877813046537682746653891964528736451575757963700058805725647',
    'erf half' );
near( erf(1),
    0 + '0.842700792949714869341220635082609259296066997966302908459937897835',
    'erf one' );
near(
    erf_inv(0.5),
    0 + '0.476936276204469873381418353643130559808969749059470644703882695919',
    'inverse erf half'
);
near(
    erf_inv(0.9),
    0 + '1.16308715367667408672625426056294759347793255000208165119272013611',
    'inverse erf nine tenths'
);
near(
    normal_cdf(1),
    0 + '0.841344746068542948585232545632037922477912966726604390987394450243',
    'normal CDF one'
);
near(
    normal_quantile(0.975),
    0 + '1.95996398454005423552459443052055152795555007786954839847695264636',
    'normal quantile fixture'
);

my $infinity = HUGE_VAL();
my $tiny     = nextafter( 0, 1 );
is( erf(0),                     0,          'erf zero' );
is( erfc(0),                    1,          'erfc zero' );
is( erf($infinity),             1,          'erf positive infinity' );
is( erf( -$infinity ),          -1,         'erf negative infinity' );
is( erfc($infinity),            0,          'erfc positive infinity' );
is( erfc( -$infinity ),         2,          'erfc negative infinity' );
is( erf_inv(0),                 0,          'inverse erf zero' );
is( erf_inv(1),                 $infinity,  'inverse erf upper endpoint' );
is( erf_inv(-1),                -$infinity, 'inverse erf lower endpoint' );
is( erfc_inv(0),                $infinity,  'inverse erfc zero' );
is( erfc_inv(2),                -$infinity, 'inverse erfc two' );
is( erfc_inv(1),                0,          'inverse erfc one' );
is( normal_cdf( -$infinity ),   0,          'CDF lower endpoint' );
is( normal_cdf($infinity),      1,          'CDF upper endpoint' );
is( normal_survival($infinity), 0,          'survival upper endpoint' );
is( normal_quantile(0),         -$infinity, 'quantile zero' );
is( normal_quantile(1),         $infinity,  'quantile one' );
is( normal_quantile(0.5),       0,          'normal median' );
is( normal_inverse_survival(0), $infinity,  'inverse survival zero' );
is( normal_inverse_survival(1), -$infinity, 'inverse survival one' );
is( sigma_to_alpha(0),          1,          'two-sided zero-sigma tail is one' );
is( sigma_to_alpha($infinity),  0,          'infinite-sigma tail is zero' );
is( alpha_to_sigma(0), $infinity, 'zero two-sided tail requires infinite sigma' );
is( alpha_to_sigma(1), 0,         'two-sided tail one is zero sigma' );
is( erf($tiny),        $tiny,     'erf preserves a minimum subnormal input' );
is( erf_inv($tiny),    $tiny,     'inverse erf preserves a minimum subnormal input' );

is( erf_inv( 13 * $tiny ),
    12 * $tiny, 'tiny inverse avoids quantized forward plateaus' );

my $previous = normal_quantile(0);
for my $i ( 1 .. 100 ) {
    my $current = normal_quantile( $i / 100 );
    cmp_ok( $current, '>=', $previous, 'normal quantiles are monotone' );
    $previous = $current;
}

for my $x ( 0.125, 0.5, 1, 2, 3, 6 ) {
    is( erf( -$x ), -erf($x), 'erf is odd' );
    near( normal_cdf( -$x ), normal_survival($x),   'CDF/survival symmetry' );
    near( alpha_to_sigma( sigma_to_alpha($x) ), $x, 'two-sided tail round trip' );
    near( normal_inverse_survival( normal_survival($x) ), $x, 'survival round trip' );
}

for my $p ( 1e-200, 1e-20, 0.001, 0.1, 0.25, 0.75, 0.9, nextafter( 1, 0 ) ) {
    my $quantile = normal_quantile($p);
    my $survival = normal_inverse_survival($p);
    is( $survival, -$quantile, 'inverse survival retains the supplied tail' );
    my $actual   = $p < 0.5 ? normal_cdf($quantile) : normal_survival($quantile);
    my $expected = $p < 0.5 ? $p                    : 1 - $p;

    # Tail sensitivity multiplies input-coordinate error by roughly z squared.
    cmp_ok(
        abs( ( $actual - $expected ) / $expected ),
        '<',
        $tolerance * ( 1 + $quantile * $quantile ),
        'normal tail round trip'
    );
}

my ( undef, $tiny_exponent ) = frexp($tiny);
my %tiny_fixtures = (
    -1074 => [
        '27.213293210812948815313823864674589232728155139499652255548317652520',
        '38.485408335567342218371564568494182295844465707987391541772973303088',
    ],
    -16445 => [
        '106.74063225216337168489841467769793771930085416116115879587476348730',
        '150.95404978728844547567413118369270253556078038670221368841065045389',
    ],
    -16494 => [
        '106.89960382223887605366530052494750159108830548873263462214499151614',
        '151.17886953772096862366991174666763085146310731809501577963447908039',
    ],
);
SKIP: {
    my $expected = $tiny_fixtures{ $tiny_exponent - 1 };
    skip 'no minimum-tail fixture for this NV format', 4 unless $expected;
    near( erfc_inv($tiny),       0 + $expected->[0], 'minimum erfc tail inverse' );
    near( alpha_to_sigma($tiny), 0 + $expected->[1], 'minimum two-sided tail inverse' );
}

for my $case (
    [ sub { erf(undef) },                   'INVALID_NUMERIC_VALUE' ],
    [ sub { erf('NaN') },                   'INVALID_NUMERIC_VALUE' ],
    [ sub { erf( [] ) },                    'INVALID_NUMERIC_VALUE' ],
    [ sub { erf( 1, 2 ) },                  'INVALID_ARITY' ],
    [ sub { erf_inv(1.01) },                'INVALID_MATH_DOMAIN' ],
    [ sub { erf_inv(-1.01) },               'INVALID_MATH_DOMAIN' ],
    [ sub { erfc_inv(2.01) },               'INVALID_MATH_DOMAIN' ],
    [ sub { erfc_inv(-0.01) },              'INVALID_MATH_DOMAIN' ],
    [ sub { sigma_to_alpha(-1) },           'INVALID_MATH_DOMAIN' ],
    [ sub { alpha_to_sigma(1.01) },         'INVALID_PROBABILITY' ],
    [ sub { normal_quantile(-0.1) },        'INVALID_PROBABILITY' ],
    [ sub { normal_inverse_survival(1.1) }, 'INVALID_PROBABILITY' ],
  )
{
    my ( $call, $code ) = @$case;
    eval { $call->() };
    ok( ref($@) && $@->has_diagnostic("XStats::$code"),
        "probability validation: $code" );
}

my $reference = eval { require Statistics::CaseResampling; 1 };
SKIP: {
    skip 'optional CaseResampling unavailable', 12 unless $reference;
    for my $x ( 0.25, 0.5, 1, 2 ) {
        cmp_ok( abs( erf($x) - Statistics::CaseResampling::approx_erf($x) ),
            '<', 5e-4, 'CaseResampling erf approximation' );
        cmp_ok(
            abs( sigma_to_alpha($x) - Statistics::CaseResampling::nsigma_to_alpha($x) ),
            '<', 5e-4, 'CaseResampling two-sided tail convention'
        );
    }
    for my $p ( 0.1, 0.5 ) {
        cmp_ok( abs( erf_inv($p) - Statistics::CaseResampling::approx_erf_inv($p) ),
            '<', 0.005, 'CaseResampling inverse approximation' );
        cmp_ok(
            abs( alpha_to_sigma($p) - Statistics::CaseResampling::alpha_to_nsigma($p) ),
            '<', 0.005, 'CaseResampling inverse two-sided convention'
        );
    }
}

done_testing;
