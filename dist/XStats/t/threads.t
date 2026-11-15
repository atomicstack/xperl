use strict;
use warnings;
use Config;
use Test::More;
BEGIN { plan skip_all => 'Perl has no ithreads' unless $Config{useithreads}; }
use threads;
use XStats;
use XStats::Incremental;
my $s = XStats->new( [ 1 .. 10 ] );
my $i = XStats::Incremental->new->add( [ 1 .. 10 ] );
my $t = threads->create(
    sub {
        $s->add( [11] );
        $i->add( [11] );
        return [
            $s->count,          $i->count,     $s->mean,
            $i->mean,           $s->max_index, $i->max_index,
            $s->sum_of_squares, $i->sum_of_squares
        ];
    }
);
is_deeply( $t->join, [ 11, 11, 6, 6, 10, 10, 506, 506 ], 'cloned objects work' );
is( $s->count, 10, 'parent stored object unchanged' );
is( $i->count, 10, 'parent incremental object unchanged' );
my $cleared = threads->create(
    sub {
        $s->clear;
        $i->clear;
        return [ $s->values, $s->count, $i->count ];
    }
);
is_deeply( $cleared->join, [ [], 0, 0 ], 'cloned objects can be cleared' );
is( $s->max_index,      9, 'clearing a clone preserves parent stored positions' );
is( $i->max_index,      9, 'clearing a clone preserves parent incremental positions' );
is( $s->sum_of_squares, 385, 'parent stored squares preserved' );
is( $i->sum_of_squares, 385, 'parent incremental squares preserved' );
my $snapshots = threads->create(
    sub {
        return [
            $s->histogram( bins => 2 )->{counts}, $s->summary->{median},
            $i->summary->{sum_of_squares}
        ];
    }
);
is_deeply(
    $snapshots->join,
    [ [ 5, 5 ], 5.5, 385 ],
    'cloned objects produce histograms and summaries'
);
my $queries = sub {
    return {
        harmonic  => $s->harmonic_mean,
        geometric => $s->geometric_mean,
        skewness  => $s->skewness,
        kurtosis  => $s->excess_kurtosis,
        trend     => $s->linear_trend,
        smoothing => $s->exponential_smoothing( alpha => 0.25, weights => [ 1 .. 10 ] ),
        outlier   => $s->filter_outlier( sub { $_[1] < $_[0]->mean } ),
        iqr       => $s->interquartile_range,
        mad       => $s->median_absolute_deviation,
    };
};

my $expected    = $queries->();
my $descriptive = threads->create($queries);
is_deeply( $descriptive->join, $expected,
    'cloned objects retain descriptive queries and safe callback snapshots' );

done_testing;
