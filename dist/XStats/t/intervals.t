use strict;
use warnings;
use Test::More;
use Config;
use POSIX qw(frexp ldexp nextafter HUGE_VAL isfinite);
use Math::BigInt;
use Math::BigRat;
use XStats::Full;
use XStats::Functions qw(interval_from_distribution);

sub rational {
    my ($value) = @_;
    return Math::BigRat->new(0) unless $value;

    my ( $fraction, $exponent ) = frexp($value);
    my $precision = $Config{nvmantbits} + 1;
    my $answer = Math::BigRat->new( sprintf( '%.0f', ldexp( $fraction, $precision ) ) );
    my $power  = Math::BigInt->new(2)->bpow( abs( $exponent - $precision ) );

    return $exponent < $precision ? $answer / $power : $answer * $power;
}

sub nearest {
    my ( $got, $exact, $name ) = @_;
    my $distance = abs( rational($got) - $exact );

    for my $direction ( -HUGE_VAL(), HUGE_VAL() ) {
        my $neighbor = nextafter( $got, $direction );
        next unless isfinite($neighbor) && $neighbor != $got;
        cmp_ok( $distance->bcmp( abs( rational($neighbor) - $exact ) ), '<=', 0,
            $name );
    }
}

sub quantile {
    my ( $values, $probability ) = @_;
    my $position = $probability * $#$values;
    my $rank     = $position->copy->bfloor->numify;
    my $fraction = $position - $rank;

    return rational( $values->[$rank] ) unless $fraction;
    return ( 1 - $fraction ) * rational( $values->[$rank] ) +
      $fraction * rational( $values->[ $rank + 1 ] );
}

my $fixture = interval_from_distribution(
    [ 0 .. 4 ],
    estimate   => 1,
    confidence => 0.5,
    method     => 'basic'
);
is_deeply(
    [ @$fixture{qw(lower estimate upper)} ],
    [ -1, 1, 1 ],
    'basic intervals reflect the two correct tails'
);
is( $fixture->{standard_error}, sqrt(2.5), 'standard error is sample SD' );
ok(
    !defined( $fixture->{seed} ) && !defined( $fixture->{statistic} ),
    'supplied distributions have no invented generation metadata'
);

my $values = [ -7, -2, 4, 20, 31 ];
my $full   = XStats::Full->new($values);
for my $confidence ( 0.1, 0.5, 0.95, nextafter( 1, 0 ), nextafter( 0, 1 ) ) {
    my $c          = rational($confidence);
    my $percentile = $full->interval_from_distribution(
        estimate   => 3,
        confidence => $confidence
    );

    nearest(
        $percentile->{lower},
        quantile( $values, ( 1 - $c ) / 2 ),
        'lower tail retains exact converted confidence'
    );
    nearest(
        $percentile->{upper},
        quantile( $values, ( 1 + $c ) / 2 ),
        'upper tail retains exact converted confidence'
    );

    my $basic = $full->interval_from_distribution(
        estimate   => 3,
        confidence => $confidence,
        method     => 'basic'
    );
    nearest(
        $basic->{lower},
        6 - rational( $percentile->{upper} ),
        'lower reflection rounds once after the quantile'
    );
    nearest(
        $basic->{upper},
        6 - rational( $percentile->{lower} ),
        'upper reflection rounds once after the quantile'
    );
}
is_deeply( $full->values, $values, 'supplied statistics preserve insertion order' );

my $large    = nextafter( HUGE_VAL(), 0 );
my $constant = XStats::Full->new( [ ($large) x 4 ] );
for my $method (qw(percentile basic)) {
    my $ci = $constant->bootstrap_interval( method => $method, resamples => 8 );
    is( $ci->{lower}, $large,
        'large constant lower bound avoids intermediate overflow' );
    is( $ci->{upper}, $large,
        'large constant upper bound avoids intermediate overflow' );
    is( $ci->{standard_error}, 0, 'large constant bootstrap error is zero' );
}

for my $statistic (qw(mean median)) {
    for my $method (qw(percentile basic)) {
        my $source       = XStats::Full->new( [ 1, 2, 5, 19 ] );
        my $distribution = $source->bootstrap_distribution(
            statistic => $statistic,
            seed      => 42,
            resamples => 101
        );
        my $generated = $source->bootstrap_interval(
            statistic  => $statistic,
            seed       => 42,
            resamples  => 101,
            method     => $method,
            confidence => 0.9
        );
        my $supplied = interval_from_distribution(
            $distribution,
            estimate   => $source->$statistic,
            method     => $method,
            confidence => 0.9
        );

        for my $field (
            qw(lower upper estimate standard_error confidence method resamples))
        {
            is( $generated->{$field}, $supplied->{$field},
                "$statistic $method native/supplied agreement: $field" );
        }
        is( $generated->{seed}, 42, 'generated intervals retain seed metadata' );
        is( $generated->{statistic},
            $statistic, 'generated intervals name the statistic' );
    }
}

for my $case (
    [ [],                                     'INVALID_NUMERIC_VALUE' ],
    [ [ estimate => 1, confidence => 0 ],     'INVALID_CONFIDENCE' ],
    [ [ estimate => 1, confidence => 1 ],     'INVALID_CONFIDENCE' ],
    [ [ estimate => 1, confidence => undef ], 'INVALID_PROBABILITY' ],
    [ [ estimate => HUGE_VAL() ],             'INVALID_NUMERIC_VALUE' ],
    [ [ estimate => 1, method => 'wrong' ],   'INVALID_INTERVAL_METHOD' ],
    [ [ estimate => 1, extra => 1 ],          'UNKNOWN_OPTION' ],
    [ [ estimate => 1, 'confidence' ],        'INVALID_OPTION_LIST' ],
  )
{
    my ( $options, $code ) = @$case;
    eval { $full->interval_from_distribution(@$options) };
    ok( ref($@) && $@->has_diagnostic("XStats::$code"), "interval validation: $code" );
}

eval { interval_from_distribution( [], estimate => 1 ) };
ok(
    ref($@) && $@->has_diagnostic( 'XStats::INSUFFICIENT_OBSERVATIONS', required => 2 ),
    'an empty supplied interval reports the required two statistics'
);
eval { $full->bootstrap_interval( resamples => 1 ) };
ok(
    ref($@) && $@->has_diagnostic( 'XStats::INSUFFICIENT_OBSERVATIONS', required => 2 ),
    'a generated interval needs two resamples'
);
eval {
    interval_from_distribution(
        [ -$large, -$large ],
        estimate => $large,
        method   => 'basic'
    );
};
ok(
    ref($@) && $@->has_diagnostic('XStats::RESULT_OVERFLOW'),
    'unrepresentable reflected bounds have a structured condition'
);

my $reference = eval { require Statistics::CaseResampling; 1 };
SKIP: {
    skip 'optional CaseResampling unavailable', 3 unless $reference;
    my @reference =
      Statistics::CaseResampling::simple_confidence_limits_from_samples( 7,
        [ (7) x 20 ], 0.95 );
    my $ci =
      interval_from_distribution( [ (7) x 20 ], estimate => 7, method => 'basic' );
    is_deeply( [ @$ci{qw(lower estimate upper)} ],
        \@reference, 'constant reflected interval agrees with CaseResampling' );
    is(
        $ci->{standard_error},
        Statistics::CaseResampling::sample_standard_deviation( 7, [ (7) x 20 ] ),
        'bootstrap sample SD agrees with CaseResampling'
    );
    my @median =
      Statistics::CaseResampling::median_simple_confidence_limits( [ (7) x 5 ],
        0.95, 20 );
    is_deeply( [ @$ci{qw(lower estimate upper)} ],
        \@median, 'constant median interval agrees with CaseResampling' );
}

done_testing;
