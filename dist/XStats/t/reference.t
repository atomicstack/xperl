use strict;
use warnings;
use Test::More;
use XStats;
my $descriptive = eval { require Statistics::Descriptive;    1 };
my $resampling  = eval { require Statistics::CaseResampling; 1 };
plan skip_all => 'Optional reference modules are not installed'
  unless $descriptive || $resampling;
diag("Statistics::Descriptive $Statistics::Descriptive::VERSION")       if $descriptive;
diag("Statistics::CaseResampling $Statistics::CaseResampling::VERSION") if $resampling;

for my $values ( [ 1 .. 9 ], [ 2, 4, 4, 4, 5, 5, 7, 9 ], [ -10, 0, 2, 8, 50 ],
    [ (5) x 8 ] )
{
    my $x = XStats->new($values);
    if ($descriptive) {
        my $ref = Statistics::Descriptive::Full->new;
        $ref->add_data($values);
        is_deeply( $x->values, [ $ref->get_data ], 'Descriptive observation copy' );
        is( $x->min_index, $ref->mindex, 'Descriptive first minimum before sorting' );
        is( $x->max_index, $ref->maxdex, 'Descriptive first maximum before sorting' );
        is( $x->range,     $ref->sample_range, 'Descriptive range' );
        for my $method (qw(mean variance standard_deviation median min max sum)) {
            cmp_ok( abs( $x->$method - $ref->$method ),
                '<', 1e-10, "Descriptive $method" );
        }
        is( $x->sum_of_squares, $ref->sumsq, 'Descriptive sum of squares' );
        cmp_ok(
            abs(
                $x->trimmed_mean( lower => 0.25, upper => 0.25 ) -
                  $ref->trimmed_mean( 0.25, 0.25 )
            ),
            '<', 1e-10,
            'Descriptive symmetric trimmed mean'
        );
        for my $q ( 0 .. 4 ) {
            cmp_ok( abs( $x->quantile( $q / 4 ) - $ref->quantile($q) ),
                '<', 1e-10, 'quartile mapping' );
        }
        if ( $x->min < $x->max ) {
            my @edges =
              ( $x->min, map { $x->min + ( $x->max - $x->min ) * $_ / 3 } 1 .. 3 );
            my @upper     = @edges[ 1 .. 3 ];
            my $reference = $ref->frequency_distribution_ref( \@upper );
            is_deeply(
                $x->histogram( edges => \@edges, closed => 'right' )->{counts},
                [ map { $reference->{$_} } @upper ],
                'Descriptive right-closed histogram counts'
            );
        }
        $ref->sort_data;
        is_deeply(
            $x->sorted_values,
            [ $ref->get_data ],
            'Descriptive sorted observation copy'
        );
        is_deeply( $x->values, $values,
            'XStats order statistics preserve insertion order' );
        $ref->clear;
        $x->clear;
        is( $x->count, $ref->count, 'Descriptive clear count' );
        is_deeply( $x->values, [ $ref->get_data ], 'Descriptive clear observations' );
        $x->add($values);
    }
    if ($resampling) {
        cmp_ok( abs( $x->mean - Statistics::CaseResampling::mean($values) ),
            '<', 1e-10, 'CaseResampling mean' );
        my @sorted = sort { $a <=> $b } @$values;
        is(
            Statistics::CaseResampling::median($values),
            $sorted[ int( ($#sorted) / 2 ) ],
            'CaseResampling uses lower median'
        );
        cmp_ok(
            abs(
                $x->standard_deviation -
                  Statistics::CaseResampling::sample_standard_deviation(
                    $x->mean, $values
                  )
            ),
            '<', 1e-10,
            'CaseResampling sd'
        );
    }
}
if ($resampling) {
    my $constant = [ (3) x 8 ];
    is_deeply(
        Statistics::CaseResampling::resample_means( $constant, 10 ),
        XStats->new($constant)->bootstrap_distribution( resamples => 10 ),
        'constant bootstrap distributions'
    );
}
done_testing;
