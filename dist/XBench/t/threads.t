use v5.41;
use Config;
use Test::More;
BEGIN { plan skip_all => 'Perl has no ithreads' unless $Config{useithreads}; }
use threads;
use XBench qw(benchmark);

my $time = 0;
no warnings 'redefine';
local *XBench::_now = sub { $time };
my $result = benchmark(
    sub { $time += 0.125 },
    min_samples     => 2,
    max_samples     => 2,
    warmup          => 0,
    min_sample_time => 0.125,
    max_seconds     => 100,
    resamples       => 20
);
my $expected = $result->as_hash;
my $thread   = threads->create( sub { $result->as_hash } );
is_deeply( $thread->join, $expected,
    'native result fields and XStats data clone independently' );

my $runner = XBench->new(
    min_samples     => 2,
    max_samples     => 2,
    warmup          => 0,
    min_sample_time => 0.125,
    max_seconds     => 100,
    resamples       => 20
);
$runner->add( name => 'cloned', code => sub { $time += 0.125 } );
my $worker = threads->create( sub { $runner->run->[0]->mean } );
is( $worker->join,  0.125, 'a cloned native runner retains its callback and catalog' );
is( $runner->state, 'new', 'running a clone preserves the parent state' );
is( scalar @{ $runner->results }, 0, 'cloned results do not populate the parent' );

my $invalid = threads->create(
    sub {
        try { XBench->new( seed => -1 ) }
        catch ( $value, $exception ) {
            return $exception->has_diagnostic( 'XBench::INVALID_ARGUMENT',
                argument => 'seed' );
        }
        return 0;
    }
);
ok( $invalid->join, 'cloned catalogs produce structured conditions in the worker' );

done_testing;
