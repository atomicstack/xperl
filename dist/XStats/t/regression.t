use strict;
use warnings;
use Test::More;
use Config;
use POSIX qw(frexp ldexp nextafter HUGE_VAL isfinite);
use Math::BigInt;
use Math::BigRat;
use XStats::Full;
use XStats::Functions qw(linear_trend);

my $precision = $Config{nvmantbits} + 1;

sub rational {
    my ($value) = @_;
    return Math::BigRat->new(0) unless $value;

    my ( $fraction, $exponent ) = frexp($value);
    my $integer = sprintf( '%.0f', ldexp( $fraction, $precision ) );
    my $answer  = Math::BigRat->new($integer);
    my $power   = Math::BigInt->new(2)->bpow( abs( $exponent - $precision ) );

    return $exponent < $precision ? $answer / $power : $answer * $power;
}

sub nearest_root {
    my ( $value, $square, $name ) = @_;

    for my $direction ( 0, HUGE_VAL() ) {
        my $neighbor = nextafter( $value, $direction );
        next if $neighbor == $value || !isfinite($neighbor);

        my $midpoint = ( rational($value) + rational($neighbor) ) / 2;
        my $boundary = $midpoint**2;

        cmp_ok( $square->bcmp($boundary), $neighbor > $value ? '<=' : '>=', 0, $name );
    }
}

sub check_fit {
    my ( $x, $y ) = @_;
    my $fit = XStats::Full->new($x)->linear_regression($y);
    my ( $sx, $sy, $xx, $xy, $yy ) = map { Math::BigRat->new(0) } 1 .. 5;

    for my $i ( 0 .. $#$x ) {
        my ( $a, $b ) = ( rational( $x->[$i] ), rational( $y->[$i] ) );

        $sx += $a;
        $sy += $b;
        $xx += $a * $a;
        $xy += $a * $b;
        $yy += $b * $b;
    }

    my $n          = @$x;
    my $vx         = $n * $xx - $sx * $sx;
    my $vy         = $n * $yy - $sy * $sy;
    my $c          = $n * $xy - $sx * $sy;
    my $rms_square = ( $vx * $vy - $c * $c ) / ( $n * $n * $vx );

    nearest_root( $fit->{residual_rms}, $rms_square,
        'RMS lies within exact squared rounding boundaries' );

    if ($vy) {
        my $r_squared = $c * $c / ( $vx * $vy );
        my $distance  = abs( rational( $fit->{r_squared} ) - $r_squared );

        for my $direction ( 0, HUGE_VAL() ) {
            my $neighbor = nextafter( $fit->{r_squared}, $direction );
            next if !isfinite($neighbor) || $neighbor == $fit->{r_squared};

            cmp_ok( $distance->bcmp( abs( rational($neighbor) - $r_squared ) ),
                '<=', 0, 'R squared is nearest to the rational answer' );
        }
    }
    else {
        ok( !defined( $fit->{correlation} ), 'constant responses have no correlation' );
        ok( !defined( $fit->{r_squared} ),   'constant responses have no R squared' );
        is( $fit->{unavailable}{correlation},
            'constant_response', 'unavailability explains the constant response' );
        is( $fit->{residual_rms}, 0, 'constant response has zero residual RMS' );
    }

    return $fit;
}

my $fit = check_fit( [ 1, 2, 3 ], [ 1, 2, 4 ] );
cmp_ok( abs( $fit->{residual_rms} - sqrt( 1 / 18 ) ),
    '<', 1e-15, 'independent RMS fixture' );
cmp_ok( abs( $fit->{r_squared} - 27 / 28 ),
    '<', 1e-15, 'independent R squared fixture' );
cmp_ok( abs( $fit->{correlation} - sqrt( 27 / 28 ) ),
    '<', 1e-15, 'independent correlation fixture' );

$fit = check_fit( [ 1 .. 5 ], [ 5, 7, 9, 11, 13 ] );
is( $fit->{residual_rms}, 0, 'an exact line has exactly zero RMS' );
is( $fit->{correlation},  1, 'positive exact line has correlation one' );

$fit = check_fit( [ 1 .. 5 ], [ 13, 11, 9, 7, 5 ] );
is( $fit->{correlation}, -1, 'negative exact line retains its sign' );

check_fit( [ 1 .. 4 ], [ (7) x 4 ] );

for my $scale ( ldexp( 1, 900 ), nextafter( 0, 1 ) ) {
    check_fit( [ -1, 0, 1 ], [ $scale, -$scale, $scale ] );
}

my $trend = linear_trend( [ 5, 7, 9, 11, 13 ] );
is( $trend->{slope},        2, 'implicit indices have the expected slope' );
is( $trend->{intercept},    3, 'implicit indices start at one' );
is( $trend->{residual_rms}, 0, 'implicit predictors preserve an exact line' );

eval { XStats::Full->new( [1] )->linear_trend };
ok(
    $@->has_diagnostic(
        'XStats::INSUFFICIENT_OBSERVATIONS',
        operation => 'linear_trend'
    ),
    'linear trend validates its minimum count'
);

my $reference = eval { require Statistics::Descriptive; 1 };
SKIP: {
    skip 'optional Statistics::Descriptive unavailable', 4 unless $reference;

    my $ref = Statistics::Descriptive::Full->new;
    $ref->add_data( [ 1, 2, 4 ] );
    my ( $intercept, $slope, $r, $rms ) = $ref->least_squares_fit( 1, 2, 3 );
    my $actual = XStats::Full->new( [ 1, 2, 3 ] )->linear_regression( [ 1, 2, 4 ] );

    for my $pair (
        [ intercept    => $intercept ],
        [ slope        => $slope ],
        [ correlation  => $r ],
        [ residual_rms => $rms ]
      )
    {
        cmp_ok( abs( $actual->{ $pair->[0] } - $pair->[1] ),
            '<', 1e-14, "Descriptive regression $pair->[0]" );
    }
}

done_testing;
