use strict;
use warnings;
use Test::More;
use Config;
use POSIX qw(frexp ldexp nextafter HUGE_VAL isfinite);
use Math::BigInt;
use Math::BigRat;
use XStats::Full;
use XStats::Functions qw(exponential_smoothing);

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

sub nearest {
    my ( $got, $exact, $name ) = @_;
    my $distance = abs( rational($got) - $exact );

    for my $direction ( -HUGE_VAL(), HUGE_VAL() ) {
        my $neighbor = nextafter( $got, $direction );
        next if !isfinite($neighbor) || $neighbor == $got;

        cmp_ok( $distance->bcmp( abs( rational($neighbor) - $exact ) ), '<=', 0,
            $name );
    }
}

is_deeply(
    exponential_smoothing( [ 0, 10, 20 ], alpha => 0.5 ),
    [ 0, 5, 12.5 ],
    'ordinary recurrence'
);

my $weighted = exponential_smoothing(
    [ 0, 10, 20 ],
    alpha   => 0.5,
    weights => [ 1, 3, 1 ]
);
is_deeply(
    [ @$weighted[ 0, 1 ] ],
    [ 0, 7.5 ],
    'weighted recurrence starts at the first value'
);
nearest(
    $weighted->[2],
    Math::BigRat->new('155/14'),
    'weighted result is nearest to the exact rational answer'
);

for my $values ( [], [7], [ 3, -4, 8, 2 ] ) {
    my $full = XStats::Full->new($values);

    is_deeply( $full->exponential_smoothing( alpha => 1 ),
        $values, 'alpha one copies the input' );
    is_deeply(
        $full->exponential_smoothing( alpha => 0 ),
        [ map { $values->[0] } @$values ],
        'alpha zero repeats the first value'
    );
    is_deeply( $full->values, $values, 'smoothing preserves stored observations' );
}

my $values   = [ 3, -4, 8, 2, -7 ];
my $ordinary = exponential_smoothing( $values, alpha => 0.25 );
is_deeply( exponential_smoothing( $values, alpha => 0.25, weights => [ (3) x 5 ] ),
    $ordinary, 'equal weights reproduce ordinary smoothing exactly' );

my $weights = [ 1, 3, 2, 4, 1 ];
my $base    = exponential_smoothing( $values, alpha => 0.25, weights => $weights );
for my $exponent ( -900, 900 ) {
    is_deeply(
        exponential_smoothing(
            $values,
            alpha   => 0.25,
            weights => [ map { ldexp( $_, $exponent ) } @$weights ]
        ),
        $base,
        'binary weight scaling does not change the smoothed values'
    );
}

my $large = nextafter( HUGE_VAL(), 0 );
my $tiny  = nextafter( 0,          1 );

for my $weights ( undef, [ $large, $large ], [ $large / 2, $large ] ) {
    my @options = defined($weights) ? ( weights => $weights ) : ();
    my $result  = exponential_smoothing( [ -$large, $large ], alpha => 0.5, @options );
    my $exact   = defined($weights)
      && $weights->[0] != $weights->[1] ? rational($large) / 3 : Math::BigRat->new(0);

    nearest( $result->[1], $exact,
        'large products and cancellation retain the answer' );
}

is_deeply(
    exponential_smoothing( [ $tiny, 3 * $tiny ], alpha => 0.5 ),
    [ $tiny, 2 * $tiny ],
    'ordinary smoothing preserves subnormals'
);
is_deeply(
    exponential_smoothing(
        [ $tiny, 3 * $tiny ],
        alpha   => 0.5,
        weights => [ $tiny, 3 * $tiny ]
    ),
    [ $tiny, 2 * $tiny ],
    'weighted smoothing rounds a subnormal tie to even'
);

my $full = XStats::Full->new( [ 1, 2, 3 ] );
for my $case (
    [ [],                          'INVALID_PROBABILITY' ],
    [ [ alpha => -0.1 ],           'INVALID_PROBABILITY' ],
    [ [ alpha => 1.1 ],            'INVALID_PROBABILITY' ],
    [ [ alpha => undef ],          'INVALID_PROBABILITY' ],
    [ [ alpha => HUGE_VAL() ],     'INVALID_PROBABILITY' ],
    [ [ alpha => 0.5, 'weights' ], 'INVALID_OPTION_LIST' ],
    [ [ alpha => 0.5, extra   => 1 ],                    'UNKNOWN_OPTION' ],
    [ [ alpha => 0.5, weights => [ 1, 2 ] ],             'INVALID_SMOOTHING_WEIGHTS' ],
    [ [ alpha => 1,   weights => [ 1, 0, 1 ] ],          'INVALID_SMOOTHING_WEIGHTS' ],
    [ [ alpha => 0,   weights => [ 1, -1, 1 ] ],         'INVALID_SMOOTHING_WEIGHTS' ],
    [ [ alpha => 0.5, weights => undef ],                'INVALID_NUMERIC_ARRAY' ],
    [ [ alpha => 0.5, weights => [ 1, HUGE_VAL(), 1 ] ], 'INVALID_NUMERIC_ARRAY' ],
  )
{
    my ( $options, $code ) = @$case;
    eval { $full->exponential_smoothing(@$options) };
    ok(
        ref($@) && $@->has_diagnostic("XStats::$code"),
        "invalid smoothing arguments: $code"
    );
}

my $reference = eval { require Statistics::Descriptive::Smoother; 1 };
SKIP: {
    skip 'optional Statistics::Descriptive smoother unavailable', 12 unless $reference;

    for my $method (qw(exponential weightedexponential)) {
        for my $alpha ( 0.25, 0.5 ) {
            my $ref = Statistics::Descriptive::Smoother->instantiate(
                {
                    method  => $method,
                    coeff   => 1 - $alpha,
                    data    => [ 0, 10, 20 ],
                    samples => [ 1, 3,  1 ],
                }
            );
            my @expected = $ref->get_smoothed_data;
            my @options =
              $method eq 'weightedexponential' ? ( weights => [ 1, 3, 1 ] ) : ();
            my $actual =
              exponential_smoothing( [ 0, 10, 20 ], alpha => $alpha, @options );

            for my $i ( 0 .. 2 ) {
                cmp_ok( abs( $actual->[$i] - $expected[$i] ),
                    '<', 1e-13, "Descriptive $method fixture" );
            }
        }
    }
}

done_testing;
