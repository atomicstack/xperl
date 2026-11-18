use strict;
use warnings;
use Test::More;
use Config;
use POSIX qw(frexp ldexp nextafter isfinite copysign HUGE_VAL);
use Math::BigRat;
use Math::BigInt;
use XStats::Full;

my $precision = $Config{nvmantbits} + 1;
my %cache;

sub rational {
    my ($x) = @_;
    return Math::BigRat->new(0) unless $x;
    my $key = sprintf( '%.*g', 3 + int( $precision * 0.30103 ), $x );
    return $cache{$key}->copy if exists $cache{$key};
    my ( $fraction, $exponent ) = frexp($x);
    my $answer = Math::BigRat->new( sprintf( '%.0f', ldexp( $fraction, $precision ) ) );
    my $power  = Math::BigInt->new(2)->bpow( abs( $exponent - $precision ) );
    if   ( $exponent < $precision ) { $answer->bdiv($power); }
    else                            { $answer->bmul($power); }
    $cache{$key} = $answer->copy;
    return $answer;
}

sub nearest {
    my ( $value, $exact, $name ) = @_;
    my $distance = rational($value)->bsub($exact)->babs;
    for my $direction ( -HUGE_VAL(), HUGE_VAL() ) {
        my $neighbor = nextafter( $value, $direction );
        next unless isfinite($neighbor);
        my $alternative = rational($neighbor)->bsub($exact)->babs;
        cmp_ok( $distance->bcmp($alternative), '<=', 0, $name );
    }
    if ( !$value && !$exact->is_zero ) {
        is(
            copysign( 1, $value ),
            $exact->is_neg ? -1 : 1,
            'underflow retains the exact result sign'
        );
    }
}

sub nearest_correlation {
    my ( $value, $squared, $sign ) = @_;
    is(
        copysign( 1, $value ),
        $sign < 0 ? -1 : 1,
        'correlation retains its exact sign'
    );
    my $magnitude = abs($value);
    cmp_ok( $magnitude, '<=', 1, 'correlation lies in its mathematical range' );
    for my $direction ( 0, HUGE_VAL() ) {
        my $neighbor = nextafter( $magnitude, $direction );
        next if $neighbor == $magnitude;
        my $midpoint = rational($magnitude)->badd( rational($neighbor) )->bdiv(2);
        my $boundary = $midpoint->copy->bmul($midpoint);
        cmp_ok(
            $squared->bcmp($boundary),
            $neighbor > $magnitude ? '<=' : '>=',
            0, 'correlation lies within exact squared rounding boundaries'
        );
    }
}

sub check_pair {
    my ( $x, $y ) = @_;
    my ( $sx, $sy, $xx, $xy, $yy ) = map { Math::BigRat->new(0) } 1 .. 5;
    for my $i ( 0 .. $#$x ) {
        my ( $a, $b ) = ( rational( $x->[$i] ), rational( $y->[$i] ) );
        $sx->badd($a);
        $sy->badd($b);
        $xx->badd( $a->copy->bmul($a) );
        $xy->badd( $a->copy->bmul($b) );
        $yy->badd( $b->copy->bmul($b) );
    }
    my $n          = @$x;
    my $c          = $xy->copy->bmul($n)->bsub( $sx->copy->bmul($sy) );
    my $vx         = $xx->copy->bmul($n)->bsub( $sx->copy->bmul($sx) );
    my $vy         = $yy->copy->bmul($n)->bsub( $sy->copy->bmul($sy) );
    my $covariance = $c->copy->bdiv( $n * ( $n - 1 ) );
    my $slope      = $c->copy->bdiv($vx);
    my $intercept  = $xx->copy->bmul($sy)->bsub( $sx->copy->bmul($xy) )->bdiv($vx);
    my $data       = XStats::Full->new($x);
    my $before     = $$data;
    my @original_y = @$y;
    nearest( $data->covariance($y),
        $covariance, 'covariance is a nearest NV to the exact rational' );
    my $fit = $data->linear_regression($y);
    nearest( $fit->{slope}, $slope, 'slope is a nearest NV to the exact rational' );
    nearest( $fit->{intercept}, $intercept,
        'intercept is a nearest NV to the exact rational' );

    if ( $vy->is_zero ) {
        eval { $data->correlation($y) };
        ok(
            ref($@) && $@->has_diagnostic(
                'XStats::UNDEFINED_STATISTIC', operation => 'correlation'
            ),
            'constant response has no correlation'
        );
    }
    else {
        my $squared = $c->copy->bmul($c)->bdiv( $vx->copy->bmul($vy) );
        nearest_correlation( $data->correlation($y), $squared, $c->is_neg ? -1 : 1 );
    }
    is( $$data, $before,
        'exact paired queries preserve native observations and caches' );
    is_deeply( $y, \@original_y, 'exact paired queries preserve response input' );
    my @reverse_x = reverse @$x;
    my @reverse_y = reverse @$y;
    my $reversed  = XStats::Full->new( \@reverse_x );
    is(
        $reversed->covariance( \@reverse_y ),
        $data->covariance($y),
        'exact covariance is independent of pair order'
    );
    is_deeply( $reversed->linear_regression( \@reverse_y ),
        $fit, 'exact regression is independent of pair order' );
    is(
        $reversed->correlation( \@reverse_y ),
        $data->correlation($y),
        'exact correlation is independent of pair order'
    ) unless $vy->is_zero;
}

my $h   = ldexp( 1, 500 );
my $fit = XStats::Full->new( [ 3 * $h, 6 * $h ] )->linear_regression( [ $h, 2 * $h ] );
is( $fit->{slope},     1 / 3, 'slope rounds independently' );
is( $fit->{intercept}, 0,     'intercept does not use a rounded slope' );
check_pair( [ 3 * $h, 6 * $h ], [ $h, 2 * $h ] );
$h = ldexp( 1, 600 );
my $tiny = ldexp( 1, -600 );
check_pair( [ $h, -$h, $tiny, -$tiny ], [ $h, $h, $h, -$h ] );
my $smallest = nextafter( 0, 1 );
check_pair( [ 0, $smallest ], [ 0, 3 * $smallest ] );
check_pair( [ 0, $smallest ], [ 0, -$smallest ] );

for my $iteration ( 1 .. 16 ) {
    my ( @x, @y );
    for my $i ( 0 .. 4 ) {
        my $exponent =
          ( -2 * $precision, 0, 2 * $precision )[ ( $i + $iteration ) % 3 ];
        push @x, ldexp( ( ( $i * 13 + $iteration * 7 ) % 31 ) - 15,  $exponent );
        push @y, ldexp( ( ( $i * 17 + $iteration * 11 ) % 37 ) - 18, -$exponent );
    }
    check_pair( \@x, \@y );
}
for my $iteration ( 1 .. 8 ) {
    my $base = ldexp( 1, 3 * $precision );
    my $step = ldexp( 1, 2 * $precision + 1 );
    my @x    = map { $base + $_ * $step } 0 .. 4;
    my @y    = map { ( $_ * $iteration ) % 7 - 3 } 0 .. 4;
    check_pair( \@x, \@y );
}

my $largest = nextafter( HUGE_VAL(), 0 );
my ( undef, $max_exponent ) = frexp($largest);
$h = ldexp( 1, $max_exponent - 1 );
my $next  = nextafter( $h, HUGE_VAL() );
my $large = XStats::Full->new( [ $h, $next ] );
is(
    $large->covariance( [ 0, 1 ] ),
    ldexp( 1, $max_exponent - $precision - 1 ),
    'large adjacent predictors retain finite covariance'
);
$fit = $large->linear_regression( [ 0, 1 ] );
is(
    $fit->{slope},
    ldexp( 1, -( $max_exponent - $precision ) ),
    'large adjacent predictor slope'
);
is(
    $fit->{intercept},
    -ldexp( 1, $precision - 1 ),
    'large adjacent predictor intercept'
);
is( $large->correlation( [ 0, 1 ] ),
    1, 'large adjacent predictors retain exact correlation' );
is( XStats::Full->new( [ $largest, $largest ] )->covariance( [ $largest, $largest ] ),
    0, 'constant covariance is zero despite overflowing raw sums' );

my $wide = XStats::Full->new( [ -$h, $h ] );
eval { $wide->covariance( [ -$h, $h ] ) };
ok( $@->has_diagnostic( 'XStats::RESULT_OVERFLOW', statistic => 'covariance' ),
    'only final covariance overflow is reported' );
is( $wide->sum, 0, 'failed covariance query preserves other results' );
eval { XStats::Full->new( [ 0, $smallest ] )->linear_regression( [ 0, $h ] ) };
ok( $@->has_diagnostic( 'XStats::RESULT_OVERFLOW', statistic => 'regression_slope' ),
    'final slope overflow is reported' );
eval { XStats::Full->new( [ -$h, -$next ] )->linear_regression( [ $h, -$h ] ) };
ok(
    $@->has_diagnostic(
        'XStats::RESULT_OVERFLOW', statistic => 'regression_intercept'
    ),
    'final intercept overflow is reported independently'
);

SKIP: {
    my $original_mode = eval { POSIX::fegetround() };
    skip 'hardware rounding modes are unavailable', 16 unless defined $original_mode;
    my $factor = $precision == 64 ? 13 : ( $precision + 1 ) / 2;
    my $a      = 2**$factor - 1;
    my $b      = 0;
    $b += 2**( $_ * $factor ) for 0 .. ( $precision + 1 ) / $factor - 1;
    my $left_exponent = int( ( $max_exponent - $precision ) / 2 );
    my $overflow_x    = XStats::Full->new( [ 0, ldexp( $a, $left_exponent ) ] );
    my $overflow_y    = [ 0, ldexp( $b, $max_exponent - $precision - $left_exponent ) ];
    my $base          = ldexp( 1, 500 );
    my $data          = XStats::Full->new( [ 3 * $base, 6 * $base ] );
    my $response      = [ $base, 2 * $base ];
    my $third         = 1 / 3;

    for my $name (qw(FE_TONEAREST FE_DOWNWARD FE_TOWARDZERO FE_UPWARD)) {
      SKIP: {
            my $mode = eval { no strict 'refs'; &{"POSIX::$name"}() };
            unless ( defined($mode) && POSIX::fesetround($mode) == 0 ) {
                POSIX::fesetround($original_mode);
                skip "$name is unavailable", 4;
            }
            my ( $fit, $overflow_error, $ending_mode );
            my $succeeded = eval {
                $fit = $data->linear_regression($response);
                eval { $overflow_x->covariance($overflow_y) };
                $overflow_error = $@;
                $ending_mode    = POSIX::fegetround();
                1;
            };
            my $unexpected = $@;
            POSIX::fesetround($original_mode);
            ok(
                $succeeded && $fit->{slope} == $third,
                "regression rounds nearest-even under $name"
            );
            is( $fit && $fit->{intercept}, 0, "exact zero intercept under $name" );
            ok(
                $overflow_error && $overflow_error->has_diagnostic(
                    'XStats::RESULT_OVERFLOW', statistic => 'covariance'
                ),
                "nearest-even overflow is independent of $name"
            );
            is( $ending_mode, $mode,
                'paired arithmetic preserves the caller hardware mode' );
            diag($unexpected) if !$succeeded;
        }
    }
}

done_testing;
