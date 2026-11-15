use strict;
use warnings;
use Test::More;
use POSIX qw(nextafter HUGE_VAL);
use XStats;
use XStats::Incremental;
use XStats::Functions qw(range min_index max_index sorted_values);

my @values = ( 4, -2, 9, -2, 9, 3 );
my $stored = XStats->new( \@values );
is_deeply( $stored->values, \@values, 'values preserve insertion order' );
is_deeply(
    $stored->sorted_values,
    [ -2, -2, 3, 4, 9, 9 ],
    'sorted values are a separate copy'
);
my $copy = $stored->values;
$copy->[0] = 1000;
push @$copy, 2000;
is_deeply( $stored->values, \@values, 'returned values do not alias native storage' );
is_deeply(
    sorted_values( \@values ),
    [ -2, -2, 3, 4, 9, 9 ],
    'functional sorted values'
);
is( range( \@values ),     11, 'functional range' );
is( min_index( \@values ), 1,  'functional minimum position' );
is( max_index( \@values ), 2,  'functional maximum position' );

for my $object ( $stored, XStats::Incremental->new->add( \@values ) ) {
    is( $object->range,     11, 'range' );
    is( $object->min_index, 1,  'minimum ties select the first position' );
    is( $object->max_index, 2,  'maximum ties select the first position' );
    $object->add( [ -4, 12, -4 ] );
    is( $object->min_index, 6, 'minimum positions include later batches' );
    is( $object->max_index, 7, 'maximum positions include later batches' );
    my $native_copy = $$object;
    is( $object->clear, $object, 'clear returns the receiver' );
    is( $object->count, 0,       'clear resets count' );
    is( $object->sum,   0,       'clear resets the exact total' );
    isnt( $$object, $native_copy, 'clear separates copied native storage' );

    for my $method (qw(min_index max_index range mean)) {
        eval { $object->$method };
        ok(
            $@->has_diagnostic(
                'XStats::INSUFFICIENT_OBSERVATIONS',
                operation => $method
            ),
            "empty $method reports a structured count requirement"
        );
    }
    $object->add( [ 5, 3, 8 ] );
    is( $object->min_index, 1,  'minimum position resets on reuse' );
    is( $object->max_index, 2,  'maximum position resets on reuse' );
    is( $object->sum,       16, 'exact total works after reuse' );
    my $before = $$object;
    Internals::SvREADONLY( $$object, 1 );
    eval { $object->clear };
    like( $@, qr/read-only object/, 'clear rejects a read-only object' );
    is( $$object, $before, 'rejected clear preserves native storage' );
    Internals::SvREADONLY( $$object, 0 );
}

for my $cut ( 0 .. @values ) {
    my $left  = XStats::Incremental->new->add( [ @values[ 0 .. $cut - 1 ] ] );
    my $right = XStats::Incremental->new->add( [ @values[ $cut .. $#values ] ] );
    $left->merge($right);
    is( $left->min_index, 1, "merged minimum position at cut $cut" );
    is( $left->max_index, 2, "merged maximum position at cut $cut" );
    $left->merge($left);
    is( $left->min_index, 1, 'self-merge retains the first minimum' );
    is( $left->max_index, 2, 'self-merge retains the first maximum' );
}

my $empty = XStats->new( [] );
is_deeply( $empty->values,        [], 'empty observation copy' );
is_deeply( $empty->sorted_values, [], 'empty sorted copy' );
my $largest = nextafter( HUGE_VAL(), 0 );
my $wide    = XStats->new( [ -$largest, $largest ] );
eval { $wide->range };
ok(
    $@->has_diagnostic( 'XStats::RESULT_OVERFLOW', statistic => 'range' ),
    'unrepresentable range has a typed result-overflow condition'
);
is( $wide->sum, 0, 'range overflow preserves other results' );

done_testing;
