use v5.41;
use Test::More;
use JSON::PP ();
use XBench   qw(benchmark compare);

my $time  = 0;
my $calls = 0;
no warnings 'redefine';
local *XBench::_now = sub { $time };

my %settings = (
    min_samples     => 4,
    max_samples     => 4,
    warmup          => 0,
    min_sample_time => 0.5,
    max_seconds     => 100,
    resamples       => 50,
);
my $result =
  benchmark( sub { ++$calls; $time += 0.125 }, name => 'constant', %settings );
isa_ok( $result, 'XBench::Result' );
is( $result->iterations,        4, 'calibration doubles to a sufficiently long batch' );
is( $result->calibration_calls, 7, 'calibration operations are counted separately' );
is( $result->total_samples,     4, 'batches are the statistical observations' );
is( $calls,                     7 + 4 * 4, 'all measured loop iterations execute' );
is( $result->mean,              0.125,     'mean is seconds per operation' );
is( $result->standard_deviation, 0, 'constant observations have zero sample SD' );
is( $result->standard_error,     0, 'constant observations have zero empirical SE' );
is( $result->median,             0.125,       'median' );
is( $result->mad,                0,           'raw MAD' );
is( $result->stop_reason,        'precision', 'precision stops a calibrated run' );
ok( $result->precision_met && $result->resolved, 'positive measurements are resolved' );
cmp_ok( $result->precision_error, '>', 0,
    'clock resolution prevents zero total uncertainty' );
is( $result->elapsed, $time, 'elapsed time includes calibration' );
like(
    $result->as_text,
    qr/mean .*s\/op, SD .*CI/,
    'text identifies mean, SD, units and interval'
);

my $hash = $result->as_hash;
is( $result->environment->{nvtype},
    $Config::Config{nvtype}, 'results record the NV build type' );
is( $result->settings->{resamples}, 50, 'results retain their analysis settings' );
my $settings_copy = $result->settings;
$settings_copy->{seed} = 99;
is( $result->settings->{seed}, 1, 'settings accessors preserve the result snapshot' );
is( $hash->{units}, 'seconds_per_operation', 'machine results identify their units' );
is_deeply( JSON::PP->new->decode( $result->as_json ),
    $hash, 'JSON contains the complete result' );
push @{ $hash->{raw_samples} }, 99;
$hash->{confidence_interval}{lower} = -99;
is( scalar @{ $result->raw_samples },
    4, 'returned arrays do not mutate result storage' );
is( $result->confidence_interval->{lower},
    0.125, 'returned intervals are independent copies' );

$time = 0;
my @phases;
my $baseline = benchmark(
    sub { $time += 0.125 },
    baseline => sub { $time += 0.0625 },
    %settings,
    before_sample => sub {
        push @phases, $_[0] unless $_[0] eq 'calibration';
        $_[0] = 'changed';
        $_[1] = 0;
    }
);
is( $baseline->mean, 0.0625, 'paired baseline subtraction normalizes by iterations' );
is_deeply( $baseline->raw_samples, [ (0.125) x 4 ], 'raw measurements are retained' );
is_deeply(
    $baseline->baseline_samples,
    [ (0.0625) x 4 ],
    'paired baselines are retained'
);
is_deeply(
    \@phases,
    [qw(sample baseline baseline sample sample baseline baseline sample)],
    'baseline order alternates and metadata aliases cannot alter instrumentation'
);

$time = 0;
my $negative = benchmark(
    sub { $time += 0.125 },
    baseline => sub { $time += 0.25 },
    %settings
);
is( $negative->mean, -0.125, 'negative adjusted samples are not clamped' );
ok(
    !$negative->resolved && !$negative->precision_met,
    'negative estimates cannot meet relative precision'
);
ok( !defined( $negative->relative_error ),
    'relative error is unavailable for nonpositive means' );
is( $negative->stop_reason, 'max_samples', 'unresolved data reaches a real limit' );

$time = 0;
my $absolute = benchmark(
    sub { $time += 0.125 }, %settings,
    target_rel_precision => 0,
    target_abs_precision => 1e-6
);
ok( $absolute->precision_met, 'absolute precision can be used alone' );

$time = 0;
my $floor = benchmark(
    sub { $time += 0.125 }, %settings,
    target_rel_precision => 1e-20,
    target_abs_precision => 1
);
ok( !$floor->precision_met,
    'every enabled target must pass, including the resolution floor' );

$time = 0;
my $limited = benchmark(
    sub { $time += 0.125 },
    min_samples     => 4,
    max_samples     => 4,
    warmup          => 0,
    min_sample_time => 0.125,
    max_seconds     => 0.3,
    resamples       => 20
);
is( $limited->stop_reason, 'max_seconds', 'time budget stops at sample boundaries' );
is( $limited->total_samples, 2,
    'a limited run retains enough data for sample statistics' );
ok( !$limited->precision_met,
    'an unmet retained-sample minimum does not claim precision' );

$time = 0;
my $unresolved = benchmark(
    sub { },
    min_samples          => 2,
    max_samples          => 4,
    warmup               => 0,
    max_batch_iterations => 2,
    resamples            => 20
);
is( $unresolved->stop_reason, 'timer_resolution',
    'a frozen clock cannot establish calibration' );
ok( !$unresolved->precision_met,
    'zero empirical variance does not prove timer precision' );

$time = 0;
my $cost  = 0.125;
my @costs = ( 0.125, 0.25, 0.375, 0.125, 4 );
SKIP: {
    skip 'native normal-quantile support unavailable', 4
      unless eval { XStats::Functions::normal_quantile(0.75); 1 };
    my $filtered = benchmark(
        sub { $time += $cost },
        min_samples     => 5,
        max_samples     => 5,
        warmup          => 0,
        min_sample_time => 0.125,
        max_seconds     => 100,
        resamples       => 20,
        outlier_sigma   => 1.5,
        before_sample   => sub {
            $cost = shift @costs if $_[0] eq 'sample';
        }
    );
    is( $filtered->rejected, 1,
        'opt-in scaled MAD filtering rejects the extreme timing' );
    is( $filtered->samples,       4, 'retained sample count is explicit' );
    is( $filtered->total_samples, 5, 'rejected data remains in the result' );
    is( $filtered->mean, 0.21875,
        'reported mean uses the documented retained population' );

    $time  = 0;
    $cost  = 0.125;
    @costs = ( 0.125, 0.125, 0.125, 0.125, 1 );
    my $quantized = benchmark(
        sub { $time += $cost },
        min_samples     => 5,
        max_samples     => 5,
        warmup          => 0,
        min_sample_time => 0.125,
        max_seconds     => 100,
        resamples       => 20,
        outlier_sigma   => 1,
        before_sample   => sub {
            $cost = shift @costs if $_[0] eq 'sample';
        }
    );
    is( $quantized->rejected, 0,
        'zero MAD does not justify discarding the other observations' );

}

$time = 0;
my $ordered = compare(
    [
        { name => 'first',  code => sub { $time += 0.125 } },
        { name => 'second', code => sub { $time += 0.25 } },
    ],
    %settings
);
is_deeply( [ map { $_->name } @$ordered ],
    [qw(first second)], 'comparison preserves case order' );
is( $ordered->[1]->mean, 0.25, 'cases retain independent analysis' );

$time = 0;
srand 123;
my $expected_random = rand();
srand 123;
benchmark( sub { $time += 0.125 }, %settings );
is( rand(), $expected_random,
    'measurement and bootstrap analysis preserve the application RNG' );

$time = 0;
my $measured_calls = 0;
my @measured_phases;
my %measured_settings = ( %settings, warmup => 1 );
my $measured          = XBench->new(%measured_settings);
$measured->add(
    name       => 'worker',
    operations => 8,
    resolution => 0.03125,
    measure    => sub {
        ++$measured_calls;
        $time += 10;
        return 0.25;
    },
    before_sample => sub { push @measured_phases, [@_] },
);
my $reported = $measured->run->[0];
is( $reported->mean, 0.03125, 'reported duration is normalized by worker operations' );
is( $reported->iterations, 8, 'results retain the worker operation count' );
is( $reported->calibration_calls, 0,
    'reported batches are not calibrated or repeated' );
is( $measured_calls,    5,  'one callback supplies each warmup or measured batch' );
is( $reported->elapsed, 50, 'driver time still bounds the cost of collecting samples' );
is( $reported->resolution_floor,
    0.00390625, 'resolution comes from the measurement clock' );
is( $reported->environment->{measurement},
    'reported', 'reported timings are identified' );
is_deeply(
    \@measured_phases,
    [ [ 'warmup', 8 ], map { [ 'sample', 8 ] } 1 .. 4 ],
    'reported batch hooks receive their operation count'
);

$time = 0;
my $paired = XBench->new(%settings);
$paired->add(
    name       => 'paired worker',
    operations => 8,
    resolution => 0.03125,
    measure    => sub { $time += 10; return 0.25 },
    baseline   => sub { $time += 10; return 0.125 },
);
my $paired_result = $paired->run->[0];
is( $paired_result->mean, 0.015625,
    'reported baselines use the same duration contract' );
is( $paired_result->resolution_floor,
    0.0078125, 'reported paired samples account for both clock resolutions' );
is_deeply(
    $paired_result->baseline_samples,
    [ (0.015625) x 4 ],
    'reported baseline timings remain available'
);

$time = 0;
my %reported_limit_settings = ( %settings, max_seconds => 15 );
my $reported_limit          = XBench->new(%reported_limit_settings);
$reported_limit->add(
    name       => 'slow worker',
    operations => 8,
    resolution => 0.03125,
    measure    => sub { $time += 10; return 0.25 }
);
my $limited_report = $reported_limit->run->[0];
is( $limited_report->stop_reason,
    'max_seconds', 'reported samples obey the driver time budget' );
is( $limited_report->total_samples,
    2, 'a reported run keeps the minimum analysable sample' );
is( $limited_report->elapsed, 20,
    'the time budget includes worker startup and reporting' );
is( $limited_report->mean, 0.03125, 'driver overhead does not enter reported means' );
ok( !$limited_report->precision_met,
    'the time limit cannot waive the minimum retained count' );

for my $duration ( undef, -1, 'NaN', 'Inf', 'not a duration', [] ) {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $invalid = XBench->new(%settings);
    $invalid->add(
        name       => 'invalid worker',
        operations => 8,
        resolution => 0.03125,
        measure    => sub { $duration }
    );
    eval { $invalid->run };
    ok(
        ref($@) && $@->has_diagnostic('XBench::MEASUREMENT'),
        'malformed reported durations raise a structured condition'
    );
    is_deeply( \@warnings, [],
        'malformed reported durations emit no incidental warning' );
}

done_testing;
