use strict;
use warnings;
use Test::More;
use XStats::Full;
use XStats::Sparse;
use XStats::Incremental;
use XStats::Functions qw(mean);

my $full   = XStats::Full->new( [ 1, 2, 3, 4 ] );
my $sparse = XStats::Sparse->new->add( [ 1, 2 ] )->add( [ 3, 4 ] );
isa_ok( $full,   'XStats::Full' );
isa_ok( $sparse, 'XStats::Sparse' );
is_deeply( $full->values, [ 1, 2, 3, 4 ], 'Full retains observations' );
is( $full->median, 2.5, 'Full supports order statistics' );
for my $method (qw(count sum mean min max variance standard_deviation)) {
    is( $sparse->$method, $full->$method, "$method agrees across storage modes" );
}
ok( !$sparse->can('values'), 'Sparse exposes the summary operations' );
my $copy = XStats::Sparse->new->add( [ 5, 6 ] );
is( $sparse->merge($copy), $sparse, 'Sparse merge returns its receiver' );
is( $sparse->count,        6,       'Sparse merge combines counts' );
is( $sparse->sum,          21,      'Sparse merge combines values' );
is( $sparse->clear,        $sparse, 'Sparse clear returns its receiver' );
is( $sparse->count,        0,       'Sparse clear resets count' );
my $old = XStats::Incremental->new->add( [ 7, 8 ] );
isa_ok( $old, 'XStats::Sparse' );
$sparse->merge($old);
is( $sparse->sum, 15,       'the original incremental name interoperates with Sparse' );
is( mean( [ 1, 2, 3 ] ), 2, 'functions use the full implementation' );

done_testing;
