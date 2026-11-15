use strict;
use warnings;
use Test::More;
use Math::BigInt;
use XStats::Full;

my $modulus = Math::BigInt->new(2)->bpow(32);
my $mask    = $modulus - 1;

sub rotate {
    my ( $word, $bits ) = @_;
    return ( ( $word << $bits ) | ( $word >> ( 32 - $bits ) ) ) & $mask;
}

sub stream {
    my ( $seed, $bound, $count ) = @_;
    my $mixer = Math::BigInt->new($seed);
    my @state;

    for ( 1 .. 4 ) {
        $mixer = ( $mixer + Math::BigInt->new('0x9e3779b9') ) & $mask;
        my $word =
          ( ( $mixer ^ ( $mixer >> 16 ) ) * Math::BigInt->new('0x21f0aaad') ) & $mask;
        $word =
          ( ( $word ^ ( $word >> 15 ) ) * Math::BigInt->new('0x735a2d97') ) & $mask;
        push @state, $word ^ ( $word >> 15 );
    }

    my $threshold = $modulus % $bound;
    my @out;
    my $rejected = 0;
    while ( @out < $count ) {
        my $word    = ( rotate( ( $state[1] * 5 ) & $mask, 7 ) * 9 ) & $mask;
        my $shifted = ( $state[1] << 9 ) & $mask;
        $state[2] ^= $state[0];
        $state[3] ^= $state[1];
        $state[1] ^= $state[2];
        $state[0] ^= $state[3];
        $state[2] ^= $shifted;
        $state[3] = rotate( $state[3], 11 );

        if ( $word < $threshold ) {
            ++$rejected;
            next;
        }
        push @out, ( $word % $bound )->numify;
    }

    return ( \@out, $rejected );
}

for my $seed ( 0, 1, 42, 4294967295 ) {
    for my $bound ( 1, 2, 3, 257, 2147483649, 4294967295 ) {
        my ( $expected, $rejected ) = stream( $seed, $bound, 40 );
        my $actual = XStats::_rng_indices( $seed, $bound, 40 );
        is_deeply( $actual, $expected,
            "independent U32 stream: seed $seed, bound $bound" );
        ok( !grep( { $_ < 0 || $_ >= $bound } @$actual ),
            'every bounded index is in range' );
        ok( $rejected > 0, 'large non-power-of-two bound exercises rejection' )
          if $bound == 2147483649;
    }
}

for my $size ( 1, 2, 3, 4, 17, 32, 37 ) {
    my @values    = map { ( $_ * 7 ) % 11 - 5 } 0 .. $size - 1;
    my $full      = XStats::Full->new( \@values );
    my ($indices) = stream( 42, $size, $size * 10 );
    is_deeply(
        $full->resample( seed => 42 ),
        [ map { $values[$_] } @$indices[ 0 .. $size - 1 ] ],
        'public resampling uses the independently checked stream'
    );

    for my $statistic (qw(mean median)) {
        my @expected;
        for my $iteration ( 0 .. 9 ) {
            my @draw =
              sort { $a <=> $b }
              map  { $values[$_] }
              @$indices[ $iteration * $size .. ( $iteration + 1 ) * $size - 1 ];
            if ( $statistic eq 'mean' ) {
                my $sum = 0;
                $sum += $_ for @draw;
                push @expected, $sum / $size;
            }
            else {
                push @expected, $size % 2
                  ? $draw[ int( $size / 2 ) ]
                  : ( $draw[ $size / 2 - 1 ] + $draw[ $size / 2 ] ) / 2;
            }
        }

        is_deeply(
            $full->bootstrap_distribution(
                statistic => $statistic,
                seed      => 42,
                resamples => 10
            ),
            \@expected,
            "native $statistic agrees with independent sorted draws of size $size"
        );
    }
}

done_testing;
