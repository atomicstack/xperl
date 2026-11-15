use strict;
use warnings;
use Test::More;
use XStats::Functions qw(covariance correlation linear_regression);
is( covariance( [ 1 .. 5 ], [ 2, 4, 6, 8, 10 ] ), 5, 'sample covariance' );
cmp_ok( abs( correlation( [ 1 .. 5 ], [ 2, 4, 6, 8, 10 ] ) - 1 ),
    '<', 1e-12, 'correlation' );
is_deeply(
    linear_regression( [ 1 .. 5 ], [ 5, 7, 9, 11, 13 ] ),
    {
        slope        => 2,
        intercept    => 3,
        count        => 5,
        correlation  => 1,
        r_squared    => 1,
        residual_rms => 0,
        unavailable  => {}
    },
    'regression'
);
eval { correlation( [ 1, 1 ], [ 2, 3 ] ) };
ok(
    ref($@)
      && $@->has_diagnostic( 'XStats::UNDEFINED_STATISTIC',
        operation => 'correlation' ),
    'constant correlation rejected'
);
eval { covariance( [ 1, 2 ], [2] ) };
like( $@, qr/lengths differ/, 'length mismatch' );
done_testing;
