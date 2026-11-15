use strict;
use warnings;
use Test::More;
use POSIX qw(nextafter HUGE_VAL frexp ldexp);
use XStats;
use XStats::Incremental;
use XStats::Functions qw(summary);

my @keys = sort qw(count sum sum_of_squares min max min_index max_index range mean
  variance standard_deviation population_variance population_standard_deviation q1 median q3 unavailable);
for my $class (qw(XStats XStats::Incremental)) {
    for my $values ( [], [3], [ 1, 2, 3, 4 ], [ -10, 0, 2, 8, 50 ], [ 7, 7, 7 ] ) {
        my $object =
          $class eq 'XStats' ? $class->new($values) : $class->new->add($values);
        my $before = $$object;
        my $result = $object->summary;
        is_deeply( [ sort keys %$result ], \@keys, 'summary has a fixed schema' );
        is( $$object,         $before, 'summary preserves native storage and caches' );
        is( $result->{count}, scalar @$values, 'summary count' );
        for my $key (@keys) {
            next if $key =~ /\A(?:count|unavailable|q1|median|q3)\z/;
            if ( !@$values && $key ne 'sum' && $key ne 'sum_of_squares' ) {
                ok( !defined $result->{$key}, 'empty result is unavailable' );
                is( $result->{unavailable}{$key}, 'empty', 'empty reason' );
            }
            elsif ( @$values == 1 && $key =~ /\A(?:variance|standard_deviation)\z/ ) {
                ok( !defined $result->{$key},
                    'singleton sample spread is unavailable' );
                is( $result->{unavailable}{$key},
                    'insufficient_observations', 'singleton reason' );
            }
            else {
                is( $result->{$key}, $object->$key, "summary agrees with $key" );
                ok(
                    !exists $result->{unavailable}{$key},
                    'available result has no unavailability entry'
                );
            }
        }
        for my $q ( [ 'q1', 0.25 ], [ 'median', 0.5 ], [ 'q3', 0.75 ] ) {
            my ( $key, $p ) = @$q;
            if ( $class eq 'XStats::Incremental' || !@$values ) {
                ok( !defined $result->{$key}, 'unavailable quartile is undef' );
                is(
                    $result->{unavailable}{$key},
                    $class eq 'XStats::Incremental' ? 'requires_stored_data' : 'empty',
'quartile reason distinguishes absent observations from absent storage'
                );
            }
            else {
                is(
                    $result->{$key},
                    $object->quantile($p),
                    'summary quartile matches exact quantile'
                );
            }
        }
        Internals::SvREADONLY( $$object, 1 );
        is_deeply( $object->summary, $result, 'read-only summary supported' );
    }
}
is( summary( [ 1, 2, 3 ] )->{mean}, 2, 'functional summary' );
my $largest = nextafter( HUGE_VAL(), 0 );
for my $class (qw(XStats XStats::Incremental)) {
    my $object =
        $class eq 'XStats'
      ? $class->new( [ $largest, $largest ] )
      : $class->new->add( [ $largest, $largest ] );
    my $result = $object->summary;
    is_deeply(
        [ @$result{qw(sum sum_of_squares)} ],
        [ undef, undef ],
        'sum and square overflow are independent missing results'
    );
    is_deeply( [ @{ $result->{unavailable} }{qw(sum sum_of_squares)} ],
        [qw(overflow overflow)], 'overflow reasons' );
    is( $result->{mean}, $largest,        'overflowing sums preserve a finite mean' );
    is( $result->{standard_deviation}, 0, 'overflowing sums preserve a finite SD' );
    $object =
        $class eq 'XStats'
      ? $class->new( [ -$largest, $largest ] )
      : $class->new->add( [ -$largest, $largest ] );
    $result = $object->summary;
    is( $result->{sum}, 0, 'huge opposite observations retain exact sum' );
    is( $result->{unavailable}{range},
        'overflow', 'range overflow reported separately' );
    is( $result->{unavailable}{population_variance},
        'overflow', 'population variance overflow' );
    is( $result->{population_standard_deviation},
        $largest, 'population SD remains available despite variance overflow' );
    is( $result->{unavailable}{standard_deviation},
        'overflow', 'sample SD can overflow independently' );
}
my $overflow = XStats->new( [ -$largest, $largest ] );
eval { $overflow->population_variance };
ok(
    $@ && $@->has_diagnostic(
        'XStats::RESULT_OVERFLOW', statistic => 'population_variance'
    ),
    'population overflow names the public statistic'
);
my $h      = ldexp( 1, 500 );
my $copy   = XStats->new( [ -$h, $h ] );
my $native = $$copy;
my $clone  = bless \( my $storage = $$copy ), 'XStats';
my $result = $clone->summary;
is( $$copy, $native, 'summary preserves COW original' );
$result->{unavailable}{mean} = 'changed';
$result->{mean} = 77;
is( $clone->summary->{mean}, 0, 'summary hashes are independent snapshots' );
my $line = __LINE__ + 1;
eval { summary( [1], 1 ) };
ok(
    $@ && $@->has_diagnostic('XStats::INVALID_ARITY'),
    'summary arity uses a structured condition'
);
is( $@->find_diagnostic('XStats::INVALID_ARITY')->location->{line},
    $line, 'summary errors retain public location' );

SKIP: {
    my $object = XStats->new( [ 1, 2 ] );
    my $needle = pack( 'F', 0.5 );
    my @positions;
    for ( my $offset = 0 ; $offset + length($needle) <= length($$object) ; ++$offset ) {
        push @positions, $offset
          if substr( $$object, $offset, length($needle) ) eq $needle;
    }
    skip 'cannot isolate native second-moment storage', 2 unless @positions == 1;
    my $bytes = $$object;
    substr( $bytes, $positions[0], length($needle) ) = pack( 'F', -1 );
    my $invalid = bless \$bytes, 'XStats';
    for my $method (qw(summary variance)) {
        eval { $invalid->$method };
        ok(
            $@ && $@->has_diagnostic('XStats::NUMERICAL_INVARIANT'),
            'invalid moments raise an invariant error instead of hiding it as overflow'
        );
    }
}

SKIP: {
    my $original = eval { POSIX::fegetround() };
    skip 'hardware rounding unavailable', 16 unless defined $original;
    my $object = XStats->new( [ -$largest, $largest ] );
    for my $name (qw(FE_TONEAREST FE_DOWNWARD FE_TOWARDZERO FE_UPWARD)) {
      SKIP: {
            my $mode = eval { no strict 'refs'; &{"POSIX::$name"}() };
            unless ( defined $mode && POSIX::fesetround($mode) == 0 ) {
                POSIX::fesetround($original);
                skip "$name unavailable", 4;
            }
            my $summary = eval { $object->summary };
            my $error   = $@;
            eval { $object->range };
            my $range_error = $@;
            my $ending      = POSIX::fegetround();
            POSIX::fesetround($original);
            is( $summary && $summary->{unavailable}{range},
                'overflow', "range overflow under $name" );
            is( $summary && $summary->{unavailable}{population_variance},
                'overflow', "variance overflow under $name" );
            ok(
                $range_error && $range_error->has_diagnostic(
                    'XStats::RESULT_OVERFLOW', statistic => 'range'
                ),
                'scalar range uses the same overflow check'
            );
            is( $ending, $mode, 'summary preserves hardware mode' );
            diag($error) if $error;
        }
    }
}
done_testing;
