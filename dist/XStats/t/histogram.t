use strict;
use warnings;
use Test::More;
use Config;
use POSIX qw(nextafter HUGE_VAL frexp ldexp isfinite);
use Math::BigInt;
use Math::BigRat;
use XStats::Full;
use XStats::Functions qw(histogram);

my $data   = XStats::Full->new( [ -1, 0, 0.5, 1, 1.5, 2, 3 ] );
my $before = $$data;
my @edges  = ( 0, 1, 2 );
my $left   = $data->histogram( edges => \@edges );
is_deeply(
    $left,
    {
        edges     => [ 0, 1, 2 ],
        counts    => [ 2, 3 ],
        underflow => 1,
        overflow  => 1,
        count     => 7,
        closed    => 'left'
    },
    'left-closed bins include both outer endpoints'
);
is_deeply(
    $data->histogram( edges => \@edges, closed => 'right' )->{counts},
    [ 3, 2 ],
    'right-closed bins assign interior boundaries to the lower bin'
);
is_deeply(
    histogram( [ 0, 1, 2 ], bins => 2 ),
    {
        edges          => [ 0, 1, 2 ],
        counts         => [ 1, 2 ],
        underflow      => 0,
        overflow       => 0,
        count          => 3,
        closed         => 'left',
        requested_bins => 2
    },
    'functional equal-width histogram'
);
is_deeply(
    XStats::Full->new( [] )->histogram( edges => \@edges )->{counts},
    [ 0, 0 ],
    'empty explicit histogram'
);
is_deeply(
    XStats::Full->new( [] )->histogram( bins => 2, range => [ 0, 2 ] )->{counts},
    [ 0, 0 ],
    'empty generated histogram with explicit range'
);

for my $closed (qw(left right)) {
    is_deeply(
        XStats::Full->new( [ 7, 7, 7 ] )->histogram( closed => $closed ),
        {
            edges          => [ 7, 7 ],
            counts         => [3],
            underflow      => 0,
            overflow       => 0,
            count          => 3,
            closed         => $closed,
            requested_bins => 10
        },
        'constant data produces one point bin'
    );
    is_deeply(
        XStats::Full->new( [ 0, 1, 2 ] )
          ->histogram( bins => 2**32 - 1, range => [ 1, 1 ], closed => $closed ),
        {
            edges          => [ 1, 1 ],
            counts         => [1],
            underflow      => 1,
            overflow       => 1,
            count          => 3,
            closed         => $closed,
            requested_bins => 2**32 - 1
        },
        'constant range retains U32 maximum request without count overflow'
    );
}
is( $$data, $before, 'histogram preserves native observations and summary' );
is_deeply( \@edges, [ 0, 1, 2 ], 'input edges are copied' );
$left->{edges}[0]  = -100;
$left->{counts}[0] = 100;
is( $data->histogram( edges => \@edges )->{counts}[0],
    2, 'returned arrays are independent' );
Internals::SvREADONLY( $$data, 1 );
is_deeply(
    $data->histogram( edges => \@edges )->{counts},
    [ 2, 3 ],
    'read-only object supports histogram'
);
is( $$data, $before, 'read-only histogram preserves native storage' );

my $smallest = nextafter( 0,          1 );
my $largest  = nextafter( HUGE_VAL(), 0 );
my $one_up   = nextafter( 1,          2 );
for my $case (
    [ 'INVALID_BIN_COUNT',       bins   => 0 ],
    [ 'INVALID_BIN_COUNT',       bins   => -1 ],
    [ 'INVALID_BIN_COUNT',       bins   => 1.5 ],
    [ 'INVALID_BIN_COUNT',       bins   => 2**32 ],
    [ 'INVALID_BIN_COUNT',       bins   => undef ],
    [ 'INVALID_BIN_COUNT',       bins   => [] ],
    [ 'INVALID_BIN_COUNT',       bins   => 'junk' ],
    [ 'INVALID_BIN_COUNT',       bins   => HUGE_VAL() ],
    [ 'INVALID_NUMERIC_ARRAY',   edges  => undef ],
    [ 'INVALID_NUMERIC_ARRAY',   edges  => [ 0, undef ] ],
    [ 'INVALID_NUMERIC_ARRAY',   edges  => [ 0, HUGE_VAL() ] ],
    [ 'INVALID_NUMERIC_ARRAY',   edges  => [ 0, [] ] ],
    [ 'INVALID_BIN_EDGES',       edges  => [] ],
    [ 'INVALID_BIN_EDGES',       edges  => [0] ],
    [ 'INVALID_BIN_EDGES',       edges  => [ 0, 0 ] ],
    [ 'INVALID_BIN_EDGES',       edges  => [ 1, 0 ] ],
    [ 'INVALID_NUMERIC_ARRAY',   range  => undef ],
    [ 'INVALID_BIN_RANGE',       range  => [0] ],
    [ 'INVALID_BIN_RANGE',       range  => [ 0, 1, 2 ] ],
    [ 'INVALID_BIN_RANGE',       range  => [ 2, 1 ] ],
    [ 'INVALID_BIN_CLOSURE',     closed => undef ],
    [ 'INVALID_BIN_CLOSURE',     closed => [] ],
    [ 'INVALID_BIN_CLOSURE',     closed => 'middle' ],
    [ 'INVALID_BIN_CLOSURE',     closed => "left\0junk" ],
    [ 'CONFLICTING_BIN_OPTIONS', edges  => [ 0, 1 ], bins  => 1 ],
    [ 'CONFLICTING_BIN_OPTIONS', edges  => [ 0, 1 ], range => [ 0, 1 ] ],
    [ 'COLLAPSED_BIN_EDGES',     bins   => 2,        range => [ 0, $smallest ] ],
    [ 'COLLAPSED_BIN_EDGES',     bins   => 2,        range => [ 1, $one_up ] ],
    [ 'UNKNOWN_OPTION',          other  => 1 ],
    [ 'INVALID_OPTION_LIST',     'bins' ],
  )
{
    my ( $code, @options ) = @$case;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    eval { $data->histogram(@options) };
    ok( $@ && $@->has_diagnostic("XStats::$code"), "typed $code" );
    is_deeply( \@warnings, [], 'invalid histogram input emits no incidental warning' );
    is( $$data, $before, 'invalid histogram preserves input' );
}
SKIP: {
    skip '32-bit extent check', 1 if $Config{ptrsize} > 4;
    eval { $data->histogram( bins => 2**32 - 1, range => [ 0, 1 ] ) };
    ok(
        $@ && $@->has_diagnostic('XStats::INVALID_BIN_COUNT'),
        'edge allocation overflow is rejected before allocation'
    );
}
my @sparse = ( 0, 1, 2 );
delete $sparse[1];
eval { $data->histogram( edges => \@sparse ) };
ok( $@ && $@->has_diagnostic('XStats::INVALID_NUMERIC_ARRAY'),
    'sparse edges rejected' );
{

    package XStatsHistogramTied;
    sub TIEARRAY  { bless {}, shift }
    sub FETCHSIZE { die 'unexpected callback' }
    sub FETCH     { die 'unexpected callback' }
}
tie my @tied, 'XStatsHistogramTied';
eval { $data->histogram( edges => \@tied ) };
ok( $@ && $@->has_diagnostic('XStats::INVALID_NUMERIC_ARRAY'),
    'tied edges rejected without callbacks' );
eval { XStats::Full->new( [] )->histogram };
ok(
    $@ && $@->has_diagnostic(
        'XStats::INSUFFICIENT_OBSERVATIONS',
        operation => 'histogram'
    ),
    'empty generated histogram needs an explicit range'
);

for my $edges (
    [ 0,         1,         2 ],
    [ -2,        -1,        0, 1, 2 ],
    [ -$largest, 0,         $largest ],
    [ 0,         $smallest, 2 * $smallest ]
  )
{
    my @values =
      map { ( nextafter( $_, -HUGE_VAL() ), $_, nextafter( $_, HUGE_VAL() ) ) } @$edges;
    @values = grep { isfinite($_) } @values;
    for my $closed (qw(left right)) {
        my @counts = (0) x ($#$edges);
        my ( $under, $over ) = ( 0, 0 );
        for my $v (@values) {
            if ( $v < $edges->[0] )  { ++$under; next; }
            if ( $v > $edges->[-1] ) { ++$over;  next; }
            for my $j ( 0 .. $#$edges - 1 ) {
                if (
                      $closed eq 'left'
                    ? $v >= $edges->[$j]
                    && ( $v < $edges->[ $j + 1 ]
                        || ( $j == $#$edges - 1 && $v == $edges->[-1] ) )
                    : $v <= $edges->[ $j + 1 ]
                    && ( $v > $edges->[$j] || ( $j == 0 && $v == $edges->[0] ) )
                  )
                {
                    ++$counts[$j];
                    last;
                }
            }
        }
        my $histogram =
          XStats::Full->new( \@values )->histogram( edges => $edges, closed => $closed );
        is_deeply( $histogram->{counts}, \@counts,
            'binary search agrees with direct interval membership' );
        is_deeply(
            [ @$histogram{qw(underflow overflow)} ],
            [ $under, $over ],
            'outside counts agree'
        );
        my $total = $under + $over;
        $total += $_ for @{ $histogram->{counts} };
        is( $total, scalar @values, 'histogram conserves observation count' );
    }
}

my $precision = $Config{nvmantbits} + 1;

sub rational {
    my ($x) = @_;
    return Math::BigRat->new(0) unless $x;
    my ( $m, $e ) = frexp($x);
    my $value  = Math::BigRat->new( sprintf( '%.0f', ldexp( $m, $precision ) ) );
    my $factor = Math::BigInt->new(2)->bpow( abs( $e - $precision ) );
    if   ( $e < $precision ) { $value->bdiv($factor); }
    else                     { $value->bmul($factor); }
    return $value;
}
for my $range (
    [ 0,         1 ],
    [ -$largest, $largest ],
    [ 1,         $one_up + ldexp( 1, -$precision + 5 ) ]
  )
{
    my $bins  = 3;
    my $edges = XStats::Full->new( [] )->histogram( bins => $bins, range => $range )->{edges};
    is( $edges->[0],  $range->[0], 'first generated endpoint copied exactly' );
    is( $edges->[-1], $range->[1], 'last generated endpoint copied exactly' );
    for my $j ( 1 .. $bins - 1 ) {
        my $exact = rational( $range->[0] )->bmul( $bins - $j )
          ->badd( rational( $range->[1] )->bmul($j) )->bdiv($bins);
        my $distance = rational( $edges->[$j] )->bsub($exact)->babs;
        for my $direction ( -HUGE_VAL(), HUGE_VAL() ) {
            my $neighbor = nextafter( $edges->[$j], $direction );
            next unless isfinite($neighbor);
            cmp_ok( $distance->bcmp( rational($neighbor)->bsub($exact)->babs ),
                '<=', 0,
                'equal-width edge is nearest to the exact rational affine value' );
        }
    }
}
my $line = __LINE__ + 1;
eval { histogram( [1], bins => 0 ) };
is( $@->find_diagnostic('XStats::INVALID_BIN_COUNT')->location->{line},
    $line, 'histogram errors retain the public functional location' );

SKIP: {
    my $original = eval { POSIX::fegetround() };
    skip 'hardware rounding unavailable', 8 unless defined $original;
    my $data     = XStats::Full->new( [ -$largest, 0, $largest ] );
    my $expected = $data->histogram( bins => 3 );
    for my $name (qw(FE_TONEAREST FE_DOWNWARD FE_TOWARDZERO FE_UPWARD)) {
      SKIP: {
            my $mode = eval { no strict 'refs'; &{"POSIX::$name"}() };
            unless ( defined $mode && POSIX::fesetround($mode) == 0 ) {
                POSIX::fesetround($original);
                skip "$name unavailable", 2;
            }
            my $result = eval { $data->histogram( bins => 3 ) };
            my $error  = $@;
            my $ending = POSIX::fegetround();
            POSIX::fesetround($original);
            is_deeply( $result, $expected,
                "histogram edges round nearest-even under $name" );
            is( $ending, $mode, 'histogram preserves hardware mode' );
            diag($error) if $error;
        }
    }
}
done_testing;
