use strict;
use warnings;
use Test::More;
use Config;
use POSIX qw(ldexp frexp nextafter HUGE_VAL);
use Math::BigRat;
use Math::BigInt;
use XStats;
use XStats::Incremental;
use XStats::Functions qw(sum_of_squares);

is( sum_of_squares( [ 1, 2, 3, 5 ] ), 39, 'functional sum of squares' );
for my $class (qw(XStats XStats::Incremental)) {
    my $data = $class eq 'XStats' ? $class->new( [] ) : $class->new;
    is( $data->sum_of_squares, 0, "$class empty sum of squares" );
    $data->add( [ 1, 2, 3, 5 ] );
    is( $data->sum_of_squares, 39, "$class known sum of squares" );
    is( $data->sum_of_squares, 39, "$class cached sum of squares" );
    my $before = $$data;
    eval { $data->add( [ 4, undef ] ) };
    like( $@, qr/not a plain number/, 'invalid batch rejected' );
    is( $$data, $before, 'failed addition preserves square state' );
    my $copy = bless \( my $storage = $$data ), $class;
    $copy->add( [-4] );
    is( $copy->sum_of_squares, 55, 'copied scalar has independent square state' );
    is( $data->sum_of_squares, 39, 'copy update preserves original' );
    $data->add( [4] );
    is( $data->sum_of_squares, 55, 'addition refreshes square result' );
    $data->clear;
    is( $data->sum_of_squares, 0, 'clear resets squares' );
    $data->add( [ -3, 4 ] );
    is( $data->sum_of_squares, 25, 'reuse after clear' );
}
my $readonly = XStats->new( [ 3, 4 ] );
Internals::SvREADONLY( $$readonly, 1 );
my $before = $$readonly;
is( $readonly->sum_of_squares, 25,      'read-only object supports uncached query' );
is( $$readonly,                $before, 'read-only query preserves bytes' );

my $truncated = XStats::Incremental->new->add( [3] );
chop $$truncated;
eval { $truncated->sum_of_squares };
like(
    $@,
    qr/invalid incremental storage/,
    'truncated square tail rejected before access'
);

my $smallest = nextafter( 0, 1 );
my ( undef, $smallest_exp ) = frexp($smallest);
my $origin = $smallest_exp - 1;
my $power  = int( ( $origin - 2 ) / 2 );
--$power if 2 * $power > $origin - 2;
my $tiny        = ldexp( 1, $power );
my $denominator = 2**( $origin - 2 * $power );
for my $n (
    1,
    $denominator / 2,
    $denominator - 1,
    $denominator,
    3 * $denominator / 2,
    5 * $denominator / 2
  )
{
    my $integer  = int( $n / $denominator );
    my $fraction = $n / $denominator - $integer;
    ++$integer if $fraction > 0.5 || ( $fraction == 0.5 && $integer % 2 );
    my $expected = $smallest * $integer;
    my @values   = ($tiny) x $n;
    is( XStats->new( \@values )->sum_of_squares,
        $expected, 'stored subnormal squares round once to nearest-even' );
    my $data = XStats::Incremental->new;
    $data->add( [$tiny] ) for @values;
    is( $data->sum_of_squares, $expected, 'incremental additions retain tiny squares' );
    my $merged = XStats::Incremental->new;
    $merged->merge( XStats::Incremental->new->add( [$tiny] ) ) for @values;
    is( $merged->sum_of_squares, $expected, 'merges retain tiny squares' );
}
my $largest = nextafter( HUGE_VAL(), 0 );
for my $data ( XStats->new( [$largest] ), XStats::Incremental->new->add( [$largest] ) )
{
    for ( 1 .. 2 ) {
        eval { $data->sum_of_squares };
        ok(
            $@ && $@->has_diagnostic(
                'XStats::RESULT_OVERFLOW', statistic => 'sum_of_squares'
            ),
            'square overflow is a typed query-specific error'
        );
    }
    is( $data->mean, $largest, 'square overflow preserves finite mean' );
    is( $data->population_standard_deviation, 0,
        'square overflow preserves finite SD' );
    $data->clear->add( [2] );
    is( $data->sum_of_squares, 4, 'clear recovers from square overflow' );
}

my $all        = XStats::Incremental->new;
my $power_data = XStats::Incremental->new->add( [3] );
for my $bit ( 0 .. 31 ) {
    $all->merge($power_data);
    $power_data->merge($power_data) if $bit < 31;
}
is( $all->count, 2**32 - 1, 'squares at the maximum count' );
is( $all->sum_of_squares, 9 * ( 2**32 - 1 ),
    'exact square carries across self-merges' );
$before = $$all;
eval { $all->add( [3] ) };
like( $@, qr/too many observations/, 'count overflow rejected' );
is( $$all, $before, 'count failure preserves square accumulator' );

my $precision = $Config{nvmantbits} + 1;

sub rational {
    my ($x) = @_;
    return Math::BigRat->new(0) unless $x;
    my ( $fraction, $exponent ) = frexp($x);
    my $result = Math::BigRat->new( sprintf( '%.0f', ldexp( $fraction, $precision ) ) );
    my $factor = Math::BigInt->new(2)->bpow( abs( $exponent - $precision ) );
    if   ( $exponent < $precision ) { $result->bdiv($factor); }
    else                            { $result->bmul($factor); }
    return $result;
}
my @rational_cases;
for my $iteration ( 1 .. 24 ) {
    push @rational_cases, [
        map {
            ldexp( ( 17 + ( 13 * $iteration + 7 * $_ ) % 47 ) / 64,
                ( 0, $precision, -$precision, 200 )[ ( $_ + $iteration ) % 4 ] )
        } 0 .. 7
    ];
}
my $below_one = nextafter( 1, 0 );
my $above_one = nextafter( 1, 2 );
my $mixed     = 1;
$mixed += ldexp( 1, -$_ ) for grep { $_ % 3 == 1 } 1 .. $precision - 1;
for my $exponent ( -100, 0, 100 ) {
    push @rational_cases,
      [ map { ldexp( $_, $exponent ) }
          ( $below_one, $above_one, $mixed, -$mixed, $above_one ) ];
}
my $boundary_scale = int( ( $origin + $precision - 1 ) / 2 );
push @rational_cases,
  [ ldexp( $below_one, $boundary_scale ), ldexp( $mixed, $boundary_scale ), 0, 0 ];
for my $case (@rational_cases) {
    my @values = @$case;
    my $exact  = Math::BigRat->new(0);
    $exact->badd( rational($_)->bpow(2) ) for @values;
    my $data     = XStats->new( \@values );
    my $result   = $data->sum_of_squares;
    my $distance = rational($result)->bsub($exact)->babs;
    for my $direction ( 0, HUGE_VAL() ) {
        my $neighbor    = nextafter( $result, $direction );
        my $alternative = rational($neighbor)->bsub($exact)->babs;
        cmp_ok( $distance->bcmp($alternative),
            '<=', 0, 'sum of squares is a nearest NV to the exact rational' );
    }
    my $incremental = XStats::Incremental->new->add( [ @values[ 0 .. 2 ] ] );
    $incremental->merge(
        XStats::Incremental->new->add( [ @values[ 3 .. $#values ] ] ) );
    is( $incremental->sum_of_squares, $result, 'partition-independent squares' );
    is( XStats->new( [ reverse @values ] )->sum_of_squares,
        $result, 'order-independent squares' );
}

my $large_count = XStats::Incremental->new;
my $large_power = XStats::Incremental->new->add( [$largest] );
for my $bit ( 0 .. 31 ) {
    $large_count->merge($large_power);
    $large_power->merge($large_power) if $bit < 31;
}
is( $large_count->count, 2**32 - 1, 'largest observations reach maximum count' );
is( $large_count->mean,  $largest,  'largest square totals preserve a finite mean' );
eval { $large_count->sum_of_squares };
ok(
    $@
      && $@->has_diagnostic( 'XStats::RESULT_OVERFLOW', statistic => 'sum_of_squares' ),
    'maximum square capacity reports only final overflow'
);

my ( undef, $max_exponent ) = frexp($largest);
my $upper_root        = ldexp( 1, $max_exponent / 2 );
my $lower_root        = nextafter( $upper_root, 0 );
my $edge_step         = ldexp( 1, int( ( $max_exponent - $precision - 1 ) / 2 ) );
my $overflow_boundary = rational($largest)
  ->badd( rational($largest)->bsub( rational( nextafter( $largest, 0 ) ) )->bdiv(2) );
for my $extra ( 0, $edge_step, 2 * $edge_step, 3 * $edge_step ) {
    my $exact  = rational($lower_root)->bpow(2)->badd( rational($extra)->bpow(2) );
    my $data   = XStats->new( [ $lower_root, $extra ] );
    my $result = eval { $data->sum_of_squares };
    my $error  = $@;
    if ( $exact->bcmp($overflow_boundary) >= 0 ) {
        ok(
            $error && $error->has_diagnostic(
                'XStats::RESULT_OVERFLOW', statistic => 'sum_of_squares'
            ),
            'exact overflow boundary rejects an unrepresentable result'
        );
    }
    else {
        ok( !$error, 'exact overflow boundary retains a finite result' );
        my $distance    = rational($result)->bsub($exact)->babs;
        my $alternative = rational( nextafter( $result, 0 ) )->bsub($exact)->babs;
        cmp_ok( $distance->bcmp($alternative),
            '<=', 0, 'finite boundary result rounds correctly' );
    }
}

SKIP: {
    my $original = eval { POSIX::fegetround() };
    skip 'hardware rounding modes unavailable', 12 unless defined $original;
    for my $name (qw(FE_TONEAREST FE_DOWNWARD FE_TOWARDZERO FE_UPWARD)) {
      SKIP: {
            my $mode = eval { no strict 'refs'; &{"POSIX::$name"}() };
            unless ( defined($mode) && POSIX::fesetround($mode) == 0 ) {
                POSIX::fesetround($original);
                skip "$name unavailable", 3;
            }
            my ( $result, $error, $ending );
            eval {
                $result = sum_of_squares( [ ($tiny) x ( $denominator - 1 ) ] );
                eval { sum_of_squares( [$largest] ) };
                $error  = $@;
                $ending = POSIX::fegetround();
            };
            my $unexpected = $@;
            POSIX::fesetround($original);
            is( $result, $smallest, "nearest-even squares under $name" );
            ok(
                $error && $error->has_diagnostic(
                    'XStats::RESULT_OVERFLOW', statistic => 'sum_of_squares'
                ),
                "square overflow under $name"
            );
            is( $ending, $mode, 'square arithmetic preserves hardware rounding mode' );
            diag($unexpected) if $unexpected;
        }
    }
}

done_testing;
