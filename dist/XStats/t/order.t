use strict;
use warnings;
use Test::More;
use Config;
use POSIX qw(frexp ldexp nextafter isfinite HUGE_VAL);
use Math::BigRat;
use Math::BigInt;
use XStats;
use XStats::Functions qw(order_statistic quantile trimmed_mean mode);

my $data   = XStats->new( [ 18, 7, -5, 4, -2, 7 ] );
my $before = $$data;
is( $data->order_statistic(1),                      -5,  'first rank' );
is( $data->order_statistic(6),                      18,  'last rank' );
is( order_statistic( [ 3, 1, 2 ], 2 ),              2,   'functional rank' );
is( $data->quantile( 0.25, method => 'empirical' ), -2,  'empirical first quartile' );
is( $data->quantile( 0.5, method => 'empirical' ),  4,   'empirical even median' );
is( $data->median,                                  5.5, 'linear even median' );
is( $data->quantile(0),                             -5,  'linear lower endpoint' );
is( $data->quantile(1),                             18,  'linear upper endpoint' );
is( $data->quantile( 0, method => 'empirical' ),    -5,  'empirical lower endpoint' );
is( $data->quantile( 1, method => 'empirical' ),    18,  'empirical upper endpoint' );
is( $$data, $before, 'order queries preserve native state and insertion order' );
is( trimmed_mean( [ 1, 2, 3, 4, 100 ], upper => 0.25 ), 2.5,
    'asymmetric trimmed mean' );
is( $data->trimmed_mean, $data->mean, 'zero trimming gives exact mean' );
is_deeply( mode( [] ), { values => [], frequency => 0 }, 'empty mode' );
is_deeply(
    mode( [ 3, 1, 2 ] ),
    { values => [ 1, 2, 3 ], frequency => 1 },
    'all-distinct modes'
);
is_deeply(
    mode( [ 3, 1, 3, 2, 1 ] ),
    { values => [ 1, 3 ], frequency => 2 },
    'mode ties sorted'
);
is_deeply( mode( [ 7, 7, 7 ] ), { values => [7], frequency => 3 }, 'single mode' );
is_deeply(
    mode( [ 0, -0.0, 0 ] ),
    { values => [0], frequency => 3 },
    'signed zeros share a mode'
);
my $one_up = nextafter( 1, 2 );
is_deeply(
    mode( [ 1, $one_up, $one_up ] ),
    { values => [$one_up], frequency => 2 },
    'adjacent NV modes use numeric equality without string keys'
);

for my $operation (
    sub { $data->order_statistic(0) },
    sub { $data->order_statistic(7) },
    sub { $data->order_statistic(1.5) },
    sub { $data->order_statistic( [] ) },
    sub { $data->order_statistic(undef) },
    sub { $data->order_statistic() },
    sub { $data->quantile(undef) },
    sub { $data->quantile( [] ) },
    sub { $data->quantile(-0.1) },
    sub { $data->quantile(1.1) },
    sub { $data->quantile('garbage') },
    sub { $data->quantile( HUGE_VAL() ) },
    sub { $data->quantile( 0.5, method  => 'bogus' ) },
    sub { $data->quantile( 0.5, method  => "linear\0junk" ) },
    sub { $data->quantile( 0.5, method  => "empirical\0junk" ) },
    sub { $data->quantile( 0.5, method  => undef ) },
    sub { $data->quantile( 0.5, method  => [] ) },
    sub { $data->quantile( 0.5, unknown => 1 ) },
    sub { $data->quantile( 0.5, 'method' ) },
    sub { $data->trimmed_mean( lower   => 1 ) },
    sub { $data->trimmed_mean( lower   => 0.5, upper => 0.5 ) },
    sub { $data->trimmed_mean( lower   => -0.1 ) },
    sub { $data->trimmed_mean( lower   => undef ) },
    sub { $data->trimmed_mean( unknown => 0 ) },
    sub { $data->trimmed_mean('upper') },
    sub { $data->mode(1) },
  )
{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    eval { $operation->() };
    ok( $@ && $@->diagnostics->[0]->isa('XStats::Diagnostic::InvalidArgument'),
        'typed invalid argument' );
    is_deeply( \@warnings, [], 'invalid input emits no incidental warning' );
    is( $$data, $before, 'invalid query preserves object' );
}
for my $method (qw(order_statistic quantile trimmed_mean)) {
    my @args = $method eq 'order_statistic' ? (1) : $method eq 'quantile' ? (0.5) : ();
    eval { XStats->new( [] )->$method(@args) };
    ok(
        $@ && $@->has_diagnostic(
            'XStats::INSUFFICIENT_OBSERVATIONS',
            operation => $method
        ),
        'empty selection query has a typed condition'
    );
}

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

sub nearest {
    my ( $value, $exact, $name ) = @_;
    my $distance = rational($value)->bsub($exact)->babs;
    for my $direction ( -HUGE_VAL(), HUGE_VAL() ) {
        my $neighbor = nextafter( $value, $direction );
        next unless isfinite($neighbor);
        my $alternative = rational($neighbor)->bsub($exact)->babs;
        cmp_ok( $distance->bcmp($alternative), '<=', 0, $name );
    }
}
my $smallest = nextafter( 0,          1 );
my $largest  = nextafter( HUGE_VAL(), 0 );
my $half_ulp = ldexp( 1, -$precision );
my @sets     = (
    [ 1 .. 10 ],
    [ -$largest,  $largest ],
    [ $smallest,  2 * $smallest ],
    [ 1,          $one_up ],
    [ 1,          1,         1, $one_up, $one_up ],
    [ -$largest,  -1,        0, 1,       $largest ],
    [ -$half_ulp, $half_ulp, 1, $one_up ]
);
for my $values (@sets) {
    my @sorted = sort { $a <=> $b } @$values;
    my $object = XStats->new($values);
    for my $p (
        0, $smallest, 0.1, 0.3, 0.5,
        nextafter( 0.5, 0 ),
        nextafter( 0.5, 1 ),
        0.9, 1
      )
    {
        my $position = rational($p)->bmul($#sorted);
        my $lo       = 0 + $position->copy->bfloor->bstr;
        my $fraction = $position->copy->bsub($lo);
        my $exact    = rational( $sorted[$lo] );
        if ( !$fraction->is_zero ) {
            $exact->badd(
                rational( $sorted[ $lo + 1 ] )->bsub( rational( $sorted[$lo] ) )
                  ->bmul($fraction) );
        }
        nearest( $object->quantile($p),
            $exact, 'linear quantile rounds exact affine combination' );
        my $rank = rational($p)->bmul( scalar @sorted )->bceil->numify;
        $rank ||= 1;
        is(
            $object->quantile( $p, method => 'empirical' ),
            $sorted[ $rank - 1 ],
            'empirical rank uses exact converted probability'
        );
    }
    for my $lower ( 0, 0.1, 0.3, nextafter( 0.5, 0 ) ) {
        my $upper = 0.25;
        my $lo    = rational($lower)->bmul( scalar @sorted )->bfloor->numify;
        my $hi    = rational($upper)->bmul( scalar @sorted )->bfloor->numify;
        my $exact = Math::BigRat->new(0);
        $exact->badd( rational( $sorted[$_] ) ) for $lo .. $#sorted - $hi;
        $exact->bdiv( @sorted - $lo - $hi );
        nearest( $object->trimmed_mean( lower => $lower, upper => $upper ),
            $exact, 'trimmed mean sums and divides retained observations exactly' );
    }
}
my $almost_half = nextafter( 0.5, 0 );
is( XStats->new( [ 1 .. 4 ] )->trimmed_mean( lower => $almost_half, upper => 0.5 ),
    2, 'exact trim sum below one is accepted even if its NV sum rounds to one' );

my $a        = ldexp( 5424227312930681, 1022 - 52 );
my $b        = ldexp( 7925679643308305, 1023 - 52 );
my $midpoint = XStats->new( [ $a, $b ] )->median;
my $draws    = XStats->new( [ $a, $b ] )
  ->bootstrap_distribution( statistic => 'median', resamples => 64 );
ok(
    scalar( grep { $_ == $midpoint } @$draws ),
    'bootstrap draws include an even midpoint'
);
is_deeply( [ grep { $_ != $a && $_ != $b && $_ != $midpoint } @$draws ],
    [], 'bootstrap midpoint agrees with the exact ordinary median' );
my $line = __LINE__ + 1;
eval { quantile( [1], -1 ) };
my $diagnostic =
  $@->find_diagnostic( 'XStats::INVALID_PROBABILITY', argument => 'probability' );
isa_ok( $diagnostic, 'XStats::Diagnostic::InvalidArgument' );
is( $diagnostic->location->{line},
    $line, 'invalid probability retains functional caller location' );
$line = __LINE__ + 1;
eval { quantile( [1], 0.5, unknown => 1 ) };
is( $@->find_diagnostic('XStats::UNKNOWN_OPTION')->location->{line},
    $line, 'Perl option validation retains functional caller location' );

my $iqr_input = XStats->new( [ 1, 2, 3, 4 ] );
is( $iqr_input->interquartile_range, 1.5, 'IQR uses the two linear quartiles' );
is_deeply( $iqr_input->values, [ 1, 2, 3, 4 ], 'IQR preserves stored order' );
my $iqr_tiny = nextafter( 0, 1 );
is(
    XStats->new( [ $iqr_tiny, 5 * $iqr_tiny ] )->interquartile_range,
    2 * $iqr_tiny,
    'IQR subtracts rounded subnormal quartiles exactly'
);

my $iqr_large    = nextafter( HUGE_VAL(), 0 );
my $iqr_overflow = XStats->new( [ -$iqr_large, -$iqr_large, $iqr_large, $iqr_large ] );
eval { $iqr_overflow->interquartile_range };
ok(
    ref($@) && $@->has_diagnostic(
        'XStats::RESULT_OVERFLOW', statistic => 'interquartile_range'
    ),
    'IQR reports a structured overflow'
);
eval { XStats->new( [] )->interquartile_range };
ok(
    ref($@) && $@->has_diagnostic(
        'XStats::INSUFFICIENT_OBSERVATIONS',
        operation => 'interquartile_range'
    ),
    'IQR reports its empty domain'
);

SKIP: {
    my $original = eval { POSIX::fegetround() };
    skip 'hardware rounding modes unavailable', 16 unless defined $original;
    my $expected = XStats->new( [ -1, $one_up ] )->quantile(0.3);
    my $values   = XStats->new( [ -1, $one_up ] );
    for my $name (qw(FE_TONEAREST FE_DOWNWARD FE_TOWARDZERO FE_UPWARD)) {
      SKIP: {
            my $mode = eval { no strict 'refs'; &{"POSIX::$name"}() };
            unless ( defined($mode) && POSIX::fesetround($mode) == 0 ) {
                POSIX::fesetround($original);
                skip "$name unavailable", 4;
            }
            my ( $result, $rank, $ending );
            eval {
                $result = $values->quantile(0.3);
                $rank   = quantile( [ 1 .. 10 ], 0.1, method => 'empirical' );
                $ending = POSIX::fegetround();
            };
            my $unexpected = $@;
            POSIX::fesetround($original);
            is( $result, $expected, "linear quantile rounds nearest-even under $name" );
            my $expected_rank = rational(0.1)->bmul(10)->bceil->numify;
            is( $rank, $expected_rank,
                'empirical rank is independent of hardware mode' );
            is( $ending, $mode, 'order statistics preserve hardware rounding mode' );
            POSIX::fesetround($mode);
            eval { $iqr_overflow->interquartile_range };
            my $overflow_error = $@;
            POSIX::fesetround($original);
            ok(
                ref($overflow_error) && $overflow_error->has_diagnostic(
                    'XStats::RESULT_OVERFLOW', statistic => 'interquartile_range'
                ),
                "IQR detects overflow under $name"
            );
            diag($unexpected) if $unexpected;
        }
    }
}

done_testing;
