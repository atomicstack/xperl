use strict;
use warnings;
use Test::More;
use Config;
use POSIX qw(frexp ldexp nextafter isfinite copysign HUGE_VAL);
use Math::BigRat;
use Math::BigInt;
use XStats::Full;
use XStats::Sparse;

my $precision = $Config{nvmantbits} + 1;
my $largest   = nextafter( HUGE_VAL(), 0 );
my ( undef, $max_exponent ) = frexp($largest);
my $h = ldexp( 0.75, $max_exponent );

for
  my $object ( XStats::Full->new( [ $h, $h ] ), XStats::Sparse->new->add( [ $h, $h ] ) )
{
    is( $object->mean,               $h, 'finite mean despite an overflowing sum' );
    is( $object->standard_deviation, 0,  'constant values have zero SD' );
    eval { $object->sum };
    like( $@, qr/numerical overflow/, 'overflow is reported when sum is requested' );
    is( $object->count, 2, 'a failed query preserves the object' );
    $object->add( [ -$h, -$h, 1 ] );
    is( $object->sum,  1,   'later cancellation restores a finite sum' );
    is( $object->mean, 0.2, 'mean after overflowing intermediate sums' );
}
my $merged = XStats::Sparse->new->add( [ $h, $h ] );
$merged->merge( XStats::Sparse->new->add( [ -$h, -$h, 1 ] ) );
is( $merged->sum,  1,   'merge cancels an overflowing partial sum' );
is( $merged->mean, 0.2, 'mean divides the exact total before rounding' );

my $half_ulp = ldexp( 1, -$precision );
my $one_up   = nextafter( 1,       2 );
my $two_up   = nextafter( $one_up, 2 );
is( XStats::Full->new( [ 1, $half_ulp ] )->sum, 1, 'nearest-even tie rounds down' );
is( XStats::Full->new( [ $one_up, $half_ulp ] )->sum, $two_up, 'nearest-even tie rounds up' );
is( XStats::Full->new( [ -1, -$half_ulp ] )->sum, -1, 'negative nearest-even tie rounds up' );
is( XStats::Full->new( [ -$one_up, -$half_ulp ] )->sum, -$two_up,
    'negative tie rounds down' );

my $smallest = nextafter( 0, 1 );
is( XStats::Full->new( [ $smallest, 0 ] )->mean, 0, 'half-subnormal mean rounds to zero' );
is( copysign( 1, XStats::Full->new( [ -$smallest, 0 ] )->mean ),
    -1, 'negative underflow retains its sign' );
is( XStats::Full->new( [ $smallest, $smallest, $smallest ] )->mean,
    $smallest, 'subnormal mean' );
my $extreme = XStats::Full->new( [ $h, $h, -$h, -$h, $smallest ] );
is( $extreme->sum, $smallest,
    'exact cancellation reveals a minimum-subnormal remainder' );
is( $extreme->median, $smallest,      'median is independent of summary overflow' );
is( $extreme->standard_deviation, $h, 'finite SD despite unrepresentable variance' );
eval { $extreme->variance };
like( $@, qr/numerical overflow/, 'variance overflows independently' );
is( $extreme->sum, $smallest, 'variance failure preserves an exact sum' );

my $counts = XStats::Sparse->new->add( [1] );
$counts->merge($counts) for 1 .. 31;
is( $counts->count, 2**31, 'self-merge reaches a large count without allocating data' );
is( $counts->sum,   2**31, 'carry propagation across count growth' );
is( $counts->mean,  1,     'exact division by a large U32' );
my $before = $$counts;
eval { $counts->merge($counts) };
like( $@, qr/too many observations/, 'U32 count overflow is rejected' );
is( $$counts, $before, 'rejected merge is atomic' );

my $all_counts = XStats::Sparse->new;
my $power      = XStats::Sparse->new->add( [1] );
for my $bit ( 0 .. 31 ) {
    $all_counts->merge($power);
    $power->merge($power) if $bit < 31;
}
is( $all_counts->count, 2**32 - 1, 'merge reaches the U32 count limit' );
is( $all_counts->mean,  1,         'exact division by U32_MAX' );
is( $all_counts->sum,   2**32 - 1, 'sum at the U32 count limit' );

my %rational_cache;

sub as_rational {
    my ($x) = @_;
    return Math::BigRat->new(0) unless $x;
    my $key = sprintf( '%.*g', 3 + int( $precision * 0.30103 ), $x );
    return $rational_cache{$key}->copy if exists $rational_cache{$key};
    my ( $fraction, $exponent ) = frexp($x);
    my $integer = sprintf( '%.0f', ldexp( $fraction, $precision ) );
    my $answer  = Math::BigRat->new($integer);
    my $power   = Math::BigInt->new(2)->bpow( abs( $exponent - $precision ) );
    if   ( $exponent < $precision ) { $answer->bdiv($power); }
    else                            { $answer->bmul($power); }
    $rational_cache{$key} = $answer->copy;
    return $answer;
}

sub nearest {
    my ( $value, $exact, $name ) = @_;
    my $distance = as_rational($value)->bsub($exact)->babs;
    for my $direction ( -HUGE_VAL(), HUGE_VAL() ) {
        my $neighbor = nextafter( $value, $direction );
        next unless isfinite($neighbor);
        my $alternative = as_rational($neighbor)->bsub($exact)->babs;
        cmp_ok( $distance->bcmp($alternative), '<=', 0, $name );
    }
}

for my $iteration ( 1 .. 24 ) {
    my @values;
    for my $i ( 0 .. 7 ) {
        my $exponent =
          ( 0, $precision, -$precision, $max_exponent - 8 )[ ( $i + $iteration ) % 4 ];
        my $mantissa = ( 17 + ( ( $iteration * 13 + $i * 7 ) % 47 ) ) / 64;
        push @values, ldexp( $i % 2 ? -$mantissa : $mantissa, $exponent );
    }
    my $exact = Math::BigRat->new(0);
    $exact->badd( as_rational($_) ) for @values;
    for my $values ( \@values, [ reverse @values ] ) {
        my $stored = XStats::Full->new($values);
        nearest( $stored->sum, $exact, 'sum is a nearest representable NV' );
        nearest(
            $stored->mean,
            $exact->copy->bdiv( scalar @$values ),
            'mean is a nearest representable NV'
        );
        my $left = XStats::Sparse->new->add( [ @$values[ 0 .. 2 ] ] );
        $left->merge( XStats::Sparse->new->add( [ @$values[ 3 .. 7 ] ] ) );
        is( $left->sum,  $stored->sum,  'exact sum is independent of partitioning' );
        is( $left->mean, $stored->mean, 'rounded mean is independent of partitioning' );
    }
}

done_testing;
