use strict;
use warnings;
use Test::More;
use XStats;
use XStats::Functions qw(mean_stddev median);

sub near {
    my ( $got, $want, $name ) = @_;
    cmp_ok( abs( $got - $want ), '<', 1e-9, $name );
}
my @values = ( 1, 2, 3, 4, 5 );
my $s      = XStats->new( \@values );
is( $s->count, 5,  'count' );
is( $s->sum,   15, 'sum' );
is( $s->min,   1,  'min' );
is( $s->max,   5,  'max' );
is( $s->mean,  3,  'mean' );
near( $s->variance,            2.5, 'sample variance' );
near( $s->population_variance, 2,   'population variance' );
my ( $mean, $sd ) = mean_stddev( \@values );
is( $mean, 3, 'functional mean' );
near( $sd, sqrt(2.5), 'functional sd' );
is( median( [ 4, 1, 3, 2 ] ), 2.5, 'even median' );
is( $s->quantile(0.25),       2,   'type 7 quartile' );
$values[0] = 100;
is( $s->sum, 15, 'owned copy' );
my $copy = $$s;
$s->add( [ 6, 7, 8, 9 ] );
is( $s->count, 9, 'grown count' );
is( $s->mean,  5, 'updated summary' );
isnt( $$s, $copy, 'COW copy preserved' );
my $old = $$s;
eval { $s->add( [ 10, undef ] ) };
like( $@, qr/plain number/, 'reject invalid batch' );
is( $$s, $old, 'failed addition atomic' );
my $empty = XStats->new( [] );
is( $empty->count, 0, 'empty count' );
is( $empty->sum,   0, 'empty sum' );
eval { $empty->mean };
like( $@, qr/requires observations/, 'empty mean fails' );
eval { XStats->new( [1] )->variance };
like( $@, qr/two observations/, 'singleton sample variance fails' );
is( XStats->new( [1] )->population_variance, 0, 'singleton population variance' );
eval { my $x = $s->mean_stddev };
like( $@, qr/list context/, 'tuple requires list context' );

for my $input ( [undef], [ {} ], [ 1, 'bad' ] ) {
    eval { XStats->new($input) };
    like( $@, qr/plain number/, 'invalid observation' );
}
my $broken = bless \( my $bytes = 'bad' ), 'XStats';
eval { $broken->mean };
like( $@, qr/invalid object/, 'malformed object rejected' );
is( XStats->new( [ '1', '2' ] )->mean, 1.5, 'numeric strings' );
near( XStats->new( [ 1e12 + 1, 1e12 + 2, 1e12 + 3 ] )->variance,
    1, 'large offset variance' );
is( XStats->new( [ 1e16, 1, -1e16 ] )->sum, 1, 'compensated sum' );
my @sparse;
$sparse[1] = 2;
eval { XStats->new( \@sparse ) };
like( $@, qr/plain number/, 'sparse input rejected' );
{

    package XStatsTestTie;
    sub TIESCALAR { bless {}, shift }
    sub FETCH     { die 'unexpected fetch' }
}
tie my $magic, 'XStatsTestTie';
eval { XStats->new( [ \$magic ] ) };
like( $@, qr/plain number/, 'references rejected without coercion' );
my $frozen = XStats->new( [ 1, 2 ] );
Internals::SvREADONLY( $$frozen, 1 );
eval { $frozen->add( [3] ) };
like( $@, qr/read-only/, 'read-only object rejected' );
my $original = XStats->new( [ 1, 2 ] );
my $clone    = bless \( my $storage = $$original ), 'XStats';
$clone->add( [3] );
is( $original->count, 2, 'distinct object sharing scalar bytes is unchanged' );
is( $clone->count,    3, 'copied object can grow' );
done_testing;
