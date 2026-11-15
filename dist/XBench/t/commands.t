use v5.41;
use Test::More;
use FindBin;
use File::Basename qw(dirname);
use File::Spec;
use JSON::PP   ();
use IPC::Open3 ();
use Symbol     qw(gensym);
use XBench     qw(benchmark benchmark_command);

my %settings = (
    min_samples => 2,
    max_samples => 2,
    warmup      => 0,
    max_seconds => 1,
    resamples   => 20
);
my $commands = benchmark_command( [ $^X, '-e', 'exit 0' ], %settings );
is( $commands->iterations,        1, 'commands execute once per sample' );
is( $commands->calibration_calls, 0, 'command execution needs no loop calibration' );
is( $commands->total_samples,     2, 'successful commands produce measured batches' );
cmp_ok( $commands->mean, '>', 0, 'actual monotonic-clock duration is positive' );

my @arguments = ( $^X, '-e', 'exit 0' );
my $runner    = XBench->new(%settings);
$runner->add( name => 'copied', command => \@arguments );
@arguments = ('missing-program-after-add');
$runner->run;
is( $runner->state, 'complete', 'a completed runner records its state' );
is( $runner->results->[0]->name,
    'copied', 'command arguments are copied at registration' );
eval { $runner->run };
ok( ref($@) && $@->has_diagnostic('XBench::STATE'), 'a completed runner cannot rerun' );

my $text = '';
open my $handle, '>', \$text or die $!;
$runner->report($handle);
close $handle;
like( $text, qr/copied: mean .*SD .*CI/, 'explicit reports use the requested handle' );

eval { benchmark_command( [ $^X, '-e', 'exit 7' ], %settings ) };
ok( ref($@) && $@->has_diagnostic( 'XBench::COMMAND_FAILED', status => 7 << 8 ),
    'command failures retain their raw wait status' );
ok(
    $@->has_diagnostic('XBench::CASE_CONTEXT'),
    'command errors retain benchmark context'
);

my @warnings;
{
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    eval { benchmark_command( ['xbench-nonexistent-command-4387102'], %settings ) };
}
ok(
    ref($@) && $@->has_diagnostic('XBench::COMMAND_START_FAILED'),
    'a failed launch has an explicit structured condition'
);
is_deeply( \@warnings, [],
    'failed launches do not duplicate the structured error as a warning' );

my $count  = 0;
my $actual = benchmark(
    sub { ++$count for 1 .. 1000 }, %settings,
    max_batch_iterations => 16,
    min_sample_time      => 0.0001
);
cmp_ok( $actual->mean, '>',  0,    'real callback timing uses the monotonic clock' );
cmp_ok( $count,        '>=', 2000, 'real callbacks execute during measurements' );

my $script     = "$FindBin::Bin/../bin/xbench";
my $driver_lib = dirname( File::Spec->rel2abs( $INC{'Config.pm'} ) );
my @include    = ( "-I$FindBin::Bin/../lib", "-I$driver_lib" );
open my $child, '-|', $^X, @include, $script, '--json', '--min-samples', 2,
  '--max-samples', 2, '--warmup', 0, '--resamples', 20, '--', $^X, '-e', 'exit 0'
  or die $!;
my $json = do { local $/; <$child> };
ok( close($child), 'the command-line benchmark completes successfully' );
my $decoded = JSON::PP->new->decode($json);
is( $decoded->{units}, 'seconds_per_operation', 'CLI JSON reports explicit units' );
is( $decoded->{total_samples}, 2, 'CLI JSON contains the full measurement record' );

my $errors = gensym;
my $pid    = IPC::Open3::open3(
    undef,    my $output,
    $errors,  $^X,
    @include, $script,
    '--json', '--min-samples',
    2,        '--max-samples',
    2,        '--warmup',
    0,        '--resamples',
    20,       '--',
    $^X,      '-e',
    'print "child output\\n"'
);
my $machine_output = do { local $/; <$output> };
my $child_errors   = do { local $/; <$errors> };
waitpid $pid, 0;
is( $?, 0, 'JSON output routing completes successfully' );
is( JSON::PP->new->decode($machine_output)->{total_samples},
    2, 'child output cannot corrupt the JSON stream' );
like( $child_errors, qr/child output/, 'JSON mode routes child stdout to stderr' );

done_testing;
