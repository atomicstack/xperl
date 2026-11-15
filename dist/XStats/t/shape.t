use strict;
use warnings;
use Test::More;
use Math::BigRat;
use POSIX qw(ldexp);
use XStats::Full;
use XStats::Functions qw(skewness excess_kurtosis);

sub near {
    my ( $got, $want, $name ) = @_;

    cmp_ok( abs( $got - $want ), '<', 2e-13 * ( 1 + abs($want) ), $name );
}

sub exact_shape {
    my ( $values, $adjusted ) = @_;
    my $n     = @$values;
    my @exact = map { Math::BigRat->new( sprintf( '%.0f', $_ ) ) } @$values;
    my $mean  = Math::BigRat->new(0);

    $mean += $_ for @exact;
    $mean /= $n;

    my ( $m2, $m3, $m4 ) = map { Math::BigRat->new(0) } 1 .. 3;
    for my $value (@exact) {
        my $d = $value - $mean;

        $m2 += $d**2;
        $m3 += $d**3;
        $m4 += $d**4;
    }

    my $skew_square = $n * $m3**2 / $m2**3;
    my $skew        = sqrt( $skew_square->numify ) * ( $m3 < 0 ? -1 : 1 );
    my $excess      = $n * $m4 / $m2**2 - 3;

    if ($adjusted) {
        $skew *= sqrt( $n * ( $n - 1 ) ) / ( $n - 2 );
        $excess =
          ( $n - 1 ) * ( ( $n + 1 ) * $excess + 6 ) / ( ( $n - 2 ) * ( $n - 3 ) );
    }

    return ( $skew, $excess->numify );
}

near( skewness( [ 0, 0, 1 ] ), sqrt(3), 'adjusted skew has an independent answer' );
near( excess_kurtosis( [ 1, 2, 3, 4 ] ), -6 / 5, 'adjusted excess kurtosis' );
near( excess_kurtosis( [ 1, 2, 3, 4 ], adjusted => 0 ),
    -34 / 25, 'unadjusted excess kurtosis' );
is( skewness( [ 1, 2 ], adjusted => 0 ),        0,  'two observations have zero skew' );
is( excess_kurtosis( [ 1, 2 ], adjusted => 0 ), -2, 'two observations have excess -2' );

for my $values (
    [ 1 .. 10 ],
    [ 2,    4,        4,        4, 5, 5, 7, 9 ],
    [ -10,  0,        2,        8, 50 ],
    [ 1e16, 1e16 + 2, 1e16 + 2, 1e16 + 4 ],
    [ 1,    2,        2,        2, 9 ]
  )
{
    my $full    = XStats::Full->new($values);
    my $reverse = XStats::Full->new( [ reverse @$values ] );

    for my $adjusted ( 0, 1 ) {
        my ( $want_skew, $want_excess ) = exact_shape( $values, $adjusted );

        near( $full->skewness( adjusted => $adjusted ),
            $want_skew, 'skew agrees with exact rational moments' );
        near( $full->excess_kurtosis( adjusted => $adjusted ),
            $want_excess, 'kurtosis agrees with exact rational moments' );

        is(
            $full->skewness( adjusted => $adjusted ),
            $reverse->skewness( adjusted => $adjusted ),
            'skew is order independent'
        );
        is(
            $full->excess_kurtosis( adjusted => $adjusted ),
            $reverse->excess_kurtosis( adjusted => $adjusted ),
            'kurtosis is order independent'
        );
    }
}

my $base    = XStats::Full->new( [ 0,    2, 2, 4 ] );
my $shifted = XStats::Full->new( [ 1e16, 1e16 + 2, 1e16 + 2, 1e16 + 4 ] );
my $scaled  = XStats::Full->new( [ map { ldexp( $_, 900 ) } 0, 2, 2, 4 ] );
for my $method (qw(skewness excess_kurtosis)) {
    near( $shifted->$method, $base->$method, "$method survives a large offset" );
    near( $scaled->$method,  $base->$method, "$method survives a large binary scale" );

    eval { XStats::Full->new( [ 1, 1, 1, 1 ] )->$method };
    ok( $@->has_diagnostic( 'XStats::UNDEFINED_STATISTIC', operation => $method ),
        "$method rejects constant data" );

    eval { XStats::Full->new( [ 1, 2 ] )->$method };
    ok(
        $@->has_diagnostic('XStats::INSUFFICIENT_OBSERVATIONS'),
        "$method enforces its adjusted minimum count"
    );
}

my $reference = eval { require Statistics::Descriptive; 1 };
SKIP: {
    skip 'optional Statistics::Descriptive unavailable', 6 unless $reference;

    for my $values ( [ 1 .. 10 ], [ 2, 4, 4, 4, 5, 5, 7, 9 ], [ -10, 0, 2, 8, 50 ] ) {
        my $ref = Statistics::Descriptive::Full->new;
        $ref->add_data($values);

        my $full = XStats::Full->new($values);
        near( $full->skewness,        $ref->skewness, 'Descriptive skew fixture' );
        near( $full->excess_kurtosis, $ref->kurtosis, 'Descriptive kurtosis fixture' );
    }
}

done_testing;
