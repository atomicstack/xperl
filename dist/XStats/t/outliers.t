use strict;
use warnings;
use Test::More;
use Config;
use POSIX        qw(ldexp nextafter HUGE_VAL);
use Scalar::Util qw(refaddr);
use XStats::Full;
use XStats::Functions qw(filter_outlier);

my $values = [ 2, 1, 30, 3 ];
my $full   = XStats::Full->new($values);
my $calls  = 0;
my $result = $full->filter_outlier(
    sub {
        my ( $snapshot, $candidate, $index ) = @_;
        ++$calls;

        isa_ok( $snapshot, 'XStats::Full' );
        isnt( refaddr($snapshot), refaddr($full),
            'predicate receives a separate object' );
        is_deeply( $snapshot->values, $values, 'snapshot preserves insertion order' );
        is( $candidate, 30, 'predicate receives the extreme value' );
        is( $index,     2,  'predicate receives its zero-based position' );

        return $candidate > $snapshot->mean + $snapshot->standard_deviation;
    }
);

is( $calls, 1, 'predicate is called once' );
is_deeply(
    $result,
    { values => [ 2, 1, 3 ], removed_index => 2, removed_value => 30 },
    'remove only the accepted candidate and preserve order'
);
is_deeply( $full->values, $values, 'filtering preserves the source object' );

$result = $full->filter_outlier( sub { 0 } );
is_deeply(
    $result,
    { values => $values, removed_index => undef, removed_value => undef },
    'a false decision retains all observations'
);

for my $small ( [], [1], [ 1, 2, 3 ] ) {
    my $called = 0;
    $result = filter_outlier( $small, sub { ++$called; 1 } );

    is( $called, 0, 'the default minimum skips the predicate' );
    is_deeply( $result->{values}, $small, 'small inputs return an unchanged copy' );
    ok( !defined( $result->{removed_index} ), 'no removal below the minimum' );
}

is_deeply(
    filter_outlier( [7], sub { 1 }, min_count => 1 ),
    { values => [], removed_index => 0, removed_value => 7 },
    'the caller can choose a lower minimum'
);

for my $case (
    [ [ 3,   1,  1,  3 ],  0 ],
    [ [ 1,   3,  3,  1 ],  0 ],
    [ [ 2,   1,  3,  2 ],  1 ],
    [ [ 2,   2,  2,  2 ],  0 ],
    [ [ -30, -1, -2, -3 ], 0 ],
  )
{
    my ( $input, $index ) = @$case;
    $result = filter_outlier( $input, sub { 1 } );
    is( $result->{removed_index},
        $index, 'ties and negative extremes use the first eligible position' );
}

my $base = ldexp( 1, $Config{nvmantbits} + 1 );
$result = filter_outlier( [ $base, $base + 2, $base + 4, $base ], sub { 1 } );
is( $result->{removed_index},
    2, 'candidate selection uses the exact mean rather than its rounded NV result' );

my $large = nextafter( HUGE_VAL(), 0 );
$result = filter_outlier( [ $large, $large, $large / 2, $large ], sub { 1 } );
is( $result->{removed_index},
    2, 'overflowing sums and endpoint sums remain comparable' );
$result = filter_outlier( [ -$large, $large, -$large, $large ], sub { 1 } );
is( $result->{removed_index}, 0, 'extreme opposite endpoints retain exact ties' );

my $retained;
$result = $full->filter_outlier(
    sub {
        $retained = $_[0];
        $_[0]->clear->add( [99] );
        $full->clear->add( [88] );
        $_[1] = -100;
        $_[2] = 0;
        return 1;
    }
);

is_deeply(
    $result,
    { values => [ 2, 1, 3 ], removed_index => 2, removed_value => 30 },
    'callback mutations and argument aliases cannot change the result copy'
);
is_deeply( $retained->values, [99], 'a retained snapshot remains usable' );
is_deeply( $full->values, [88],
    'explicit callback changes to the source are preserved' );

$full = XStats::Full->new($values);
eval { XStats::Full->new( [] )->mean };
my $exception = $@;
eval {
    $full->filter_outlier( sub { die $exception } );
};
is( refaddr($@), refaddr($exception), 'callback exceptions propagate by identity' );
is_deeply( $full->values, $values, 'callback failure leaves source data intact' );

for my $case (
    [ [],                         'INVALID_ARITY' ],
    [ [undef],                    'INVALID_FILTER' ],
    [ [ {} ],                     'INVALID_FILTER' ],
    [ [ sub { 1 }, 'min_count' ], 'INVALID_OPTION_LIST' ],
    [ [ sub { 1 }, other     => 1 ],          'UNKNOWN_OPTION' ],
    [ [ sub { 1 }, min_count => 0 ],          'INVALID_MINIMUM_COUNT' ],
    [ [ sub { 1 }, min_count => -1 ],         'INVALID_MINIMUM_COUNT' ],
    [ [ sub { 1 }, min_count => 1.5 ],        'INVALID_MINIMUM_COUNT' ],
    [ [ sub { 1 }, min_count => 4294967296 ], 'INVALID_MINIMUM_COUNT' ],
    [ [ sub { 1 }, min_count => undef ],      'INVALID_MINIMUM_COUNT' ],
    [ [ sub { 1 }, min_count => HUGE_VAL() ], 'INVALID_MINIMUM_COUNT' ],
  )
{
    my ( $args, $code ) = @$case;
    eval { $full->filter_outlier(@$args) };
    ok(
        ref($@) && $@->has_diagnostic("XStats::$code"),
        "invalid filtering arguments: $code"
    );
}

my $reference = eval { require Statistics::Descriptive; 1 };
SKIP: {
    skip 'optional Statistics::Descriptive unavailable', 6 unless $reference;

    for my $input ( [ 2, 1, 30, 3 ], [ -30, -1, -2, -3 ], [ 1, 3, 3, 1 ] ) {
        my $ref = Statistics::Descriptive::Full->new;
        $ref->add_data($input);

        for my $accept ( 0, 1 ) {
            $ref->set_outlier_filter( sub { $accept } );
            my @expected = $ref->get_data_without_outliers;
            my $actual   = filter_outlier( $input, sub { $accept } );

            is_deeply( $actual->{values}, \@expected, 'Descriptive outlier fixture' );
        }
    }
}

done_testing;
