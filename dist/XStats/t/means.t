use strict;
use warnings;
use Test::More;
use POSIX qw(nextafter HUGE_VAL ldexp);
use XStats::Full;
use XStats::Functions qw(harmonic_mean geometric_mean);

sub near {
    my ( $got, $want, $name ) = @_;
    cmp_ok( abs( ( $got - $want ) / $want ), '<', 2e-14, $name );
}
near( harmonic_mean( [ 1,  2,  4 ] ),  12 / 7, 'harmonic independent rational answer' );
near( harmonic_mean( [ -1, -2, -4 ] ), -12 / 7, 'negative harmonic answer' );
is( harmonic_mean( [ 1, -2 ] ), 4, 'signed harmonic mean may exceed the data extrema' );
is( geometric_mean( [ 1, 4, 16 ] ), 4, 'geometric mean of binary powers' );
near( geometric_mean( [ 2, 3, 8 ] ), 48**( 1 / 3 ), 'geometric independent answer' );
is( geometric_mean( [ 0, 3, 5 ] ), 0, 'geometric mean permits zero' );
is( geometric_mean( [ ldexp( 1, 900 ), ldexp( 1, -900 ) ] ),
    1, 'geometric exponents cancel before conversion' );
near( harmonic_mean( [ 1e300, 1 ] ), 2, 'scaled reciprocal avoids magnitude problems' );
my $large = nextafter( HUGE_VAL(), 0 );
my $tiny  = nextafter( 0,          1 );

for my $method (qw(harmonic_mean geometric_mean)) {
    is( XStats::Full->new( [ ($large) x 4 ] )->$method,
        $large, "$method returns a large constant exactly" );
    is( XStats::Full->new( [ ($tiny) x 4 ] )->$method,
        $tiny, "$method returns a subnormal constant exactly" );
    eval { XStats::Full->new( [] )->$method };
    ok(
        $@->has_diagnostic( 'XStats::INSUFFICIENT_OBSERVATIONS', operation => $method ),
        "$method has an empty-input condition"
    );
}
is( geometric_mean( [ $tiny, 4 * $tiny ] ),
    2 * $tiny, 'geometric mean retains a representable subnormal' );
for my $case (
    [ 'harmonic_mean',  [ 1, 0 ],        'NONZERO_OBSERVATIONS_REQUIRED' ],
    [ 'harmonic_mean',  [ 1, -1 ],       'NUMERICAL_RESOLUTION' ],
    [ 'harmonic_mean',  [ 1, -3, -1.5 ], 'NUMERICAL_RESOLUTION' ],
    [ 'harmonic_mean',  [ -1, 3, 1.5 ],  'NUMERICAL_RESOLUTION' ],
    [ 'geometric_mean', [ 0, -1 ],       'NONNEGATIVE_OBSERVATIONS_REQUIRED' ],
    [ 'geometric_mean', [ -1, 0 ],       'NONNEGATIVE_OBSERVATIONS_REQUIRED' ],
  )
{
    my ( $method, $values, $code ) = @$case;
    eval { XStats::Full->new($values)->$method };
    ok( $@->has_diagnostic( "XStats::$code", operation => $method ),
        "$method domain condition" );
}
SKIP: {
    my $original = eval { POSIX::fegetround() };
    skip 'hardware rounding modes unavailable', 4 unless defined $original;

    for my $name (qw(FE_TONEAREST FE_DOWNWARD FE_TOWARDZERO FE_UPWARD)) {
      SKIP: {
            my $mode = eval { no strict 'refs'; &{"POSIX::$name"}() };
            unless ( defined($mode) && POSIX::fesetround($mode) == 0 ) {
                POSIX::fesetround($original);
                skip "$name unavailable", 1;
            }

            eval { harmonic_mean( [ 1, -3, -1.5 ] ) };
            my $failure = $@;
            POSIX::fesetround($original);
            ok(
                ref($failure) && $failure->has_diagnostic(
                    'XStats::NUMERICAL_RESOLUTION',
                    operation => 'harmonic_mean'
                ),
                "signed harmonic cancellation is rejected under $name"
            );
        }
    }
}

my $reference = eval { require Statistics::Descriptive; 1 };
SKIP: {
    skip 'optional Statistics::Descriptive unavailable', 6 unless $reference;
    for my $values ( [ 1, 2, 4 ], [ 2, 3, 8 ], [ 1 .. 10 ] ) {
        my $ref = Statistics::Descriptive::Full->new;
        $ref->add_data($values);
        my $full = XStats::Full->new($values);
        near( $full->harmonic_mean, $ref->harmonic_mean,
            'Descriptive harmonic fixture' );
        near( $full->geometric_mean, $ref->geometric_mean,
            'Descriptive geometric fixture' );
    }
}
done_testing;
