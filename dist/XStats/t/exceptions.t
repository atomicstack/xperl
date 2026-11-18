use strict;
use warnings;
use Test::More;
use POSIX qw(nextafter HUGE_VAL);
use XStats::Full;
use XStats::Functions qw(mean covariance);

my $data = XStats::Full->new( [] );
my $line = __LINE__ + 1;
eval { $data->mean };
my $empty = $@;
isa_ok( $empty, 'XPerl::Exception' );
my $diagnostic = $empty->find_diagnostic(
    'XStats::INSUFFICIENT_OBSERVATIONS',
    operation => 'mean',
    actual    => 0,
    required  => 1
);
isa_ok( $diagnostic, 'XStats::Diagnostic::InsufficientObservations' );
isa_ok( $diagnostic, 'XPerl::Diagnostic::Error::Numeric::Domain' );
is( $diagnostic->location->{line}, $line, 'XS error records the public call location' );
is( $empty->origin->{line},        $line, 'XS error records the original throw site' );
is_deeply(
    [ map { $_->{type} } @{ $diagnostic->params } ],
    [ 'text', 'uv', 'uv' ],
    'count requirements remain typed'
);
ok( !defined $diagnostic->number, 'module conditions have no core number' );
my $large       = nextafter( HUGE_VAL(), 0 );
my $overflowing = XStats::Full->new( [ $large, $large ] );
eval { $overflowing->sum };
my $overflow = $@;
isa_ok( $overflow, 'XPerl::Exception' );
my $result =
  $overflow->find_diagnostic( 'XStats::RESULT_OVERFLOW', statistic => 'sum' );
isa_ok( $result, 'XStats::Diagnostic::ResultOverflow' );
is( $overflowing->mean,  $large, 'typed overflow leaves other results available' );
is( $overflowing->count, 2,      'typed overflow leaves observations intact' );
like( $overflow->as_json, qr/XStats::RESULT_OVERFLOW/,
    'structured output retains the condition' );

$line = __LINE__ + 1;
eval { mean( [] ) };
my $functional = $@;
is(
    $functional->find_diagnostic('XStats::INSUFFICIENT_OBSERVATIONS')->location->{line},
    $line, 'exported functions retain the public call location'
);
is( $functional->origin->{line},
    $line, 'exported functions retain the public throw origin' );

my ( $translated, $translated_line );
{
    use diagpack 'de';
    $translated_line = __LINE__ + 1;
    eval { covariance( [ -$large, $large ], [ -$large, $large ] ) };
    $translated = $@;
}
my $translated_diagnostic = $translated->find_diagnostic('XStats::RESULT_OVERFLOW');
is( $translated_diagnostic->location->{line},
    $translated_line, 'exported paired functions retain the public location' );
{
    local ${^DIAG_RENDER} = 'en:legacy';
    is(
        "$translated",
        $translated->render('de:legacy'),
        'exported functions retain the caller lexical diagnostic language'
    );
    isnt(
        "$translated",
        $translated->render('en:legacy'),
        'explicit English overrides the retained caller language'
    );
}

for my $method (
    qw(median median_absolute_deviation covariance correlation linear_regression))
{
    my $values = XStats::Full->new( [ 1, 2, 3 ] );
    eval { $values->$method( 1, 2 ) };
    ok( ref($@) && $@->has_diagnostic( 'XStats::INVALID_ARITY', argument => $method ),
        "$method validates its public arity" );
}

for my $method (qw(correlation linear_regression)) {
    eval { XStats::Full->new( [ 1, 1 ] )->$method( [ 2, 3 ] ) };
    ok(
        ref($@)
          && $@->has_diagnostic( 'XStats::UNDEFINED_STATISTIC', operation => $method ),
        "$method reports constant predictors as undefined"
    );
}

my $mad = XStats::Full->new( [ -$large, $large, $large ] );
eval { $mad->median_absolute_deviation };
ok(
    ref($@) && $@->has_diagnostic(
        'XStats::NUMERICAL_RESOLUTION',
        operation => 'median_absolute_deviation'
    ),
    'MAD explains its intermediate range limit'
);

SKIP: {
    my $original = eval { POSIX::fegetround() };
    skip 'hardware rounding modes unavailable', 4 unless defined $original;

    for my $name (qw(FE_TONEAREST FE_DOWNWARD FE_TOWARDZERO FE_UPWARD)) {
      SKIP: {
            my $mode = eval { no strict 'refs'; &{"POSIX::$name"}() };
            unless ( defined($mode) && POSIX::fesetround($mode) == 0 ) {
                POSIX::fesetround($original);
                skip "$name unavailable", 1;
            }

            eval { $mad->median_absolute_deviation };
            my $failure = $@;
            POSIX::fesetround($original);
            ok(
                ref($failure) && $failure->has_diagnostic(
                    'XStats::NUMERICAL_RESOLUTION',
                    operation => 'median_absolute_deviation'
                ),
                "MAD detects its range limit under $name"
            );
        }
    }
}

done_testing;
