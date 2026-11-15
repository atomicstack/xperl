use strict;
use warnings;
use Test::More;
use XStats;
use XStats::Functions qw(bootstrap_interval median_absolute_deviation);
my $s = XStats->new( [ 1 .. 9 ] );
is( median_absolute_deviation( [ 1 .. 9 ] ), 2, 'raw MAD' );
my $a = $s->resample( seed => 42 );
is( scalar @$a, 9, 'same resample size' );
ok( !grep( { $_ < 1 || $_ > 9 } @$a ), 'resamples are cases' );
is_deeply( $a, $s->resample( seed => 42 ), 'seed reproducibility' );
srand 123;
my $expected = rand();
srand 123;
$s->resample( seed => 42 );
is( rand(), $expected, 'unrelated RNG unchanged' );
my $constant = XStats->new( [ (7) x 5 ] );

for my $statistic (qw(mean median)) {
    my $d = $constant->bootstrap_distribution(
        statistic => $statistic,
        resamples => 20,
        seed      => 1
    );
    is_deeply( $d, [ (7) x 20 ], "constant bootstrap $statistic" );
    my $ci = $constant->bootstrap_interval( statistic => $statistic, resamples => 20 );
    is( $ci->{lower},          7, 'lower' );
    is( $ci->{upper},          7, 'upper' );
    is( $ci->{standard_error}, 0, 'constant standard error' );
}
my $ci = bootstrap_interval( [ 1 .. 9 ], resamples => 50, seed => 1 );
is( $ci->{estimate}, 5, 'estimate' );
ok( $ci->{lower} <= $ci->{upper}, 'ordered bounds' );
for my $options ( [ resamples => 0 ], [ statistic => 'wrong' ], [ seed => -1 ] ) {
    eval { $s->bootstrap_distribution(@$options) };
    ok( $@, 'bad option rejected' );
}
eval { XStats->new( [] )->resample };
like( $@, qr/requires observations/, 'empty resampling' );
for my $statistic (qw(mean median)) {
    my $data = XStats->new( [ 1, 3, 8, 12 ] );
    for my $seed ( 1 .. 10 ) {
        my $draw         = XStats->new( $data->resample( seed => $seed ) );
        my $distribution = $data->bootstrap_distribution(
            statistic => $statistic,
            resamples => 1,
            seed      => $seed
        );
        cmp_ok( abs( $distribution->[0] - $draw->$statistic ),
            '<', 1e-12, "same cases for bootstrap $statistic" );
    }
}
my $data = XStats->new( [ 1, 2, 3 ] );
eval { $data->bootstrap_distribution( statistic => 'cases' ) };
like(
    $@,
    qr/statistic must be mean or median/,
    'raw cases cannot be a bootstrap statistic'
);
for my $method (qw(mean_stddev resample bootstrap_distribution bootstrap_interval)) {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    eval { my @result = $data->$method('seed') };
    if ( $method eq 'mean_stddev' ) {
        like( $@, qr/key\/value pairs/, "$method rejects an incomplete option" );
    }
    else {
        ok( ref($@) && $@->has_diagnostic('XStats::INVALID_OPTION_LIST'),
            "$method rejects an incomplete option" );
    }
    is_deeply( \@warnings, [], 'option validation does not emit a Perl warning' );
}

done_testing;
