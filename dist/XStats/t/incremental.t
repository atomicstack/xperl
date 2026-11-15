use strict;
use warnings;
use Test::More;
use XStats;
use XStats::Incremental;
my $full = XStats->new( [ 1 .. 100 ] );
my $one  = XStats::Incremental->new;
$one->add( [$_] ) for 1 .. 100;
my $left  = XStats::Incremental->new->add( [ 1 .. 40 ] );
my $right = XStats::Incremental->new->add( [ 41 .. 100 ] );
$left->merge($right);

for my $method (qw(count sum min max mean variance standard_deviation)) {
    for my $object ( $one, $left ) {
        cmp_ok( abs( $object->$method - $full->$method ),
            '<', 1e-9, "partitioned $method" );
    }
}
my $size = length $$one;
$one->add( [ 101 .. 1000 ] );
is( length($$one), $size, 'fixed storage' );
my $before = $$one;
eval { $one->add( [undef] ) };
like( $@, qr/plain number/, 'invalid update' );
is( $$one, $before, 'failed update atomic' );
my $double = XStats::Incremental->new->add( [ 1, 2 ] );
$double->merge($double);
is( $double->count, 4,   'self merge count' );
is( $double->mean,  1.5, 'self merge mean' );
my $empty = XStats::Incremental->new;
$double->merge($empty);
is( $double->count, 4, 'empty merge' );
$empty->merge($double);
is( $empty->count, 4, 'merge into empty' );
my $copy = $$empty;
$empty->add( [5] );
isnt( $$empty, $copy, 'incremental COW' );
done_testing;
