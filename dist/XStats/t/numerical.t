use strict;
use warnings;
use Test::More;
use Config;
use Math::BigRat;
use XStats;
use XStats::Incremental;

my $tolerance = 128 * 2**( -$Config{nvmantbits} );

sub near {
    my ( $actual, $expected, $name ) = @_;
    if ( !$expected ) { is( $actual, 0, $name ); return; }
    cmp_ok( abs( ( $actual - $expected ) / $expected ), '<', $tolerance, $name );
}

sub exact_summary {
    my ($strings) = @_;
    my $sum = Math::BigRat->new(0);
    $sum->badd($_) for @$strings;
    my $mean = $sum->copy->bdiv( scalar @$strings );
    my $m2   = Math::BigRat->new(0);
    for my $x (@$strings) {
        my $delta = Math::BigRat->new($x)->bsub($mean);
        $m2->badd( $delta->bmul($delta) );
    }
    return ( $mean->numify, $m2->bdiv( @$strings - 1 )->numify );
}

for my $strings (
    [qw(10000000000000000 1 -10000000000000000)],
    [qw(10000000000000000 10000000000000002)],
    [qw(10000000000000002 10000000000000000)],
    [qw(10000000000000000 10000000000000002 10000000000000004)],
    [qw(-10000000000000000 -10000000000000002 -10000000000000004)],
    [qw(0 1 8 -4 2 19)],
  )
{
    my ( $mean, $variance ) = exact_summary($strings);
    my @values = map { 0 + $_ } @$strings;
    for my $values ( \@values, [ reverse @values ] ) {
        my $stored      = XStats->new($values);
        my $incremental = XStats::Incremental->new;
        $incremental->add( [$_] ) for @$values;
        for my $object ( $stored, $incremental ) {
            near( $object->mean, $mean, 'mean agrees with rational arithmetic' );
            near( $object->variance, $variance,
                'variance agrees with rational arithmetic' );
            my ( $m, $sd ) = $object->mean_stddev;
            near( $m,  $mean,           'tuple mean' );
            near( $sd, sqrt($variance), 'tuple standard deviation' );
        }
        for my $cut ( 1 .. $#$values ) {
            my $left = XStats::Incremental->new->add( [ @$values[ 0 .. $cut - 1 ] ] );
            my $right =
              XStats::Incremental->new->add( [ @$values[ $cut .. $#$values ] ] );
            $left->merge($right);
            near( $left->mean,     $mean,     'partitioned mean' );
            near( $left->variance, $variance, 'partitioned variance' );
        }
    }
}

my $tiny = XStats->new( [ 1e-200, -1e-200 ] );
near( $tiny->standard_deviation, sqrt(2) * 1e-200, 'SD survives squared underflow' );
near( $tiny->population_standard_deviation,
    1e-200, 'population SD survives squared underflow' );
my $tiny_merge = XStats::Incremental->new->add( [1e-200] );
$tiny_merge->merge( XStats::Incremental->new->add( [-1e-200] ) );
near(
    $tiny_merge->standard_deviation,
    sqrt(2) * 1e-200,
    'merged SD survives squared underflow'
);

for my $x ( [ 1e16, 1e16 + 2 ], [ 1e16 + 2, 1e16 ] ) {
    my $y    = $x->[0] < $x->[1] ? [ 0, 2 ] : [ 2, 0 ];
    my $data = XStats->new($x);
    near( $data->correlation($y), 1, 'correlation with adjacent large values' );
    near( $data->covariance($y),  2, 'covariance with adjacent large values' );
    near( $data->linear_regression($y)->{slope},
        1, 'regression with adjacent large values' );
}
near( $tiny->correlation( [ 2e-200, -2e-200 ] ),
    1, 'correlation survives squared underflow' );
near( $tiny->linear_regression( [ 2e-200, -2e-200 ] )->{slope},
    2, 'regression survives squared underflow' );
my $cancellation = XStats->new( [ 1e16, 1, -1e16, -1, 1e-20 ] );
near( $cancellation->sum,  1e-20, 'renormalized sum retains a tiny remainder' );
near( $cancellation->mean, 2e-21, 'mean retains a tiny remainder' );
my $line = XStats->new( [ 1e16, 1e16 + 4 ] )->linear_regression( [ 3e16, 3e16 + 12 ] );
near( $line->{slope}, 3, 'slope of an exact large line' );
is( $line->{intercept}, 0, 'intercept retains the product rounding residual' );

SKIP: {
    skip 'requires IEEE binary64 NVs', 2197
      unless $Config{nvtype} eq 'double' && $Config{nvsize} == 8;
    my $smallest = 5e-324;
    my $constant = XStats->new( [ $smallest, $smallest ] );
    is( $constant->median,         $smallest, 'constant subnormal median' );
    is( $constant->quantile(0.25), $smallest, 'constant subnormal quantile' );
    is(
        $constant->bootstrap_distribution( statistic => 'median', resamples => 1 )->[0],
        $smallest,
        'constant subnormal bootstrap median'
    );
    is( $constant->median_absolute_deviation, 0, 'constant subnormal MAD' );
    is(
        XStats->new( [ $smallest, 2 * $smallest ] )->median,
        2 * $smallest,
        'subnormal midpoint rounds after addition'
    );
    is( XStats->new( [ -$smallest, 2 * $smallest ] )->median,
        0, 'opposite subnormal midpoint rounds once' );
    is(
        XStats->new( [ $smallest, 3 * $smallest ] )->quantile(0.25),
        2 * $smallest,
        'subnormal quartile rounds after interpolation'
    );
    my $pair = XStats->new( [ 0, $smallest ] );
    near( $pair->correlation( [ 0, 2 * $smallest ] ), 1, 'subnormal correlation' );
    near( $pair->linear_regression( [ 0, 2 * $smallest ] )->{slope},
        2, 'subnormal slope' );
    is( $pair->linear_regression( [ 0, 2 * $smallest ] )->{intercept},
        0, 'subnormal intercept' );

    for my $a ( -4 .. 4 ) {
        for my $b ( -4 .. 4 ) {
            for my $c ( -4 .. 4 ) {
                my @v = map { $_ * $smallest } ( $a, $b, $c );
                my $variance =
                  ( 3 * ( $a * $a + $b * $b + $c * $c ) - ( $a + $b + $c )**2 ) / 6;
                my $expected = $smallest * sqrt($variance);
                my $data     = XStats->new( \@v );
                is( $data->standard_deviation, $expected, "subnormal SD for $a,$b,$c" );
                for my $cut ( 1, 2 ) {
                    my $left = XStats::Incremental->new->add( [ @v[ 0 .. $cut - 1 ] ] );
                    my $right = XStats::Incremental->new->add( [ @v[ $cut .. 2 ] ] );
                    $left->merge($right);
                    is( $left->standard_deviation, $expected,
                        "subnormal merged SD for $a,$b,$c at $cut" );
                }
            }
        }
    }
}

SKIP: {
    skip 'requires normalization to underflow', 3 if 1e-200 / 1e200;
    my $wide = XStats->new( [ 1e200, -1e200, 1e-200, -1e-200 ] );
    near( $wide->covariance( [ 1e200, 1e200, 1e200, -1e200 ] ),
        2 / 3, 'exact covariance retains products across extreme exponents' );
    is( $wide->correlation( [ 1e200, 1e200, 1e200, -1e200 ] ),
        0, 'exact correlation rounds a tiny result to zero' );
    my $regression = $wide->linear_regression( [ 1e200, 1e200, 1e200, -1e200 ] );
    is_deeply(
        [ $regression->{slope}, $regression->{intercept} ],
        [ 0,                    5e199 ],
        'exact regression permits a rounded zero slope'
    );
}

SKIP: {
    my $zero  = ${ XStats->new( [ 0, 0 ] ) };
    my $one   = ${ XStats->new( [ 1, 1 ] ) };
    my $width = length pack( 'i', 0 );
    my @positions;
    for ( my $offset = 0 ; $offset + $width <= length($one) ; $offset += $width ) {
        push @positions, $offset
          if substr( $zero, $offset, $width ) eq pack( 'i', 0 )
          && substr( $one,  $offset, $width ) eq pack( 'i', 1 );
    }
    skip 'cannot isolate the native exponent field', 2 unless @positions == 1;
    for my $bad ( -( 2**( $width * 8 - 1 ) ), 2**( $width * 8 - 1 ) - 1 ) {
        my $bytes = $one;
        substr( $bytes, $positions[0], $width ) = pack( 'i', $bad );
        my $forged = bless \$bytes, 'XStats';
        eval { $forged->standard_deviation };
        like(
            $@,
            qr/invalid object exponent/,
            'reject a forged exponent before arithmetic'
        );
    }
}

done_testing;
