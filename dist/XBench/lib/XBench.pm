use v5.41;
use feature qw(class defer dispatch_on);
no warnings qw(experimental::class experimental::defer);

class XBench;

use Exporter 'import';
use Config;
use POSIX             qw(isfinite);
use Scalar::Util      qw(looks_like_number refaddr);
use Time::HiRes       ();
use XStats::Full      ();
use XStats::Functions qw(normal_quantile);
use XPerl::Diagnostic::Catalog;
use XBench::Result ();

our $VERSION   = '0.01';
our @EXPORT_OK = qw(benchmark benchmark_command compare);

my $catalog = XPerl::Diagnostic::Catalog->define(
    namespace  => 'XBench',
    conditions => {
        (
            map {
                my ( $code, $class, $template, $parameters ) = @$_;
                $code => {
                    class     => "XBench::Diagnostic::$class",
                    parent    => 'XPerl::Diagnostic::Error',
                    severity  => 'FATAL_ERROR',
                    params    => $parameters,
                    templates => { en => $template },
                }
            } (
                [
                    'INVALID_ARGUMENT',
                    'InvalidArgument',
                    'XBench: invalid argument %{argument}',
                    [ { name => 'argument', type => 'text' } ]
                ],
                [
                    'UNKNOWN_OPTION',
                    'UnknownOption',
                    'XBench: unknown option %{argument}',
                    [ { name => 'argument', type => 'text' } ]
                ],
                [
                    'DUPLICATE_OPTION',
                    'DuplicateOption',
                    'XBench: duplicate option %{argument}',
                    [ { name => 'argument', type => 'text' } ]
                ],
                [
                    'INVALID_OPTION_LIST',
                    'OptionList',
                    'XBench: %{operation} requires key/value options',
                    [ { name => 'operation', type => 'text' } ]
                ],
                [
                    'STATE', 'State',
                    'XBench: %{operation} is unavailable in state %{state}',
                    [
                        { name => 'operation', type => 'text' },
                        { name => 'state',     type => 'text' }
                    ]
                ],
                [ 'NO_CASES', 'NoCases', 'XBench: no benchmark cases', [] ],
                [
                    'DUPLICATE_NAME',
                    'DuplicateName',
                    'XBench: duplicate case name %{name}',
                    [ { name => 'name', type => 'text' } ]
                ],
                [
                    'CLOCK', 'Clock',
                    'XBench: invalid monotonic clock reading during %{phase}',
                    [ { name => 'phase', type => 'text' } ]
                ],
                [
                    'COMMAND_FAILED',
                    'CommandFailed',
                    'XBench: command for %{name} failed (wait status %{status})',
                    [
                        { name => 'name',   type => 'text' },
                        { name => 'status', type => 'iv' }
                    ]
                ],
                [
                    'COMMAND_START_FAILED',
                    'CommandStartFailed',
                    'XBench: cannot start command for %{name}: %{reason}',
                    [
                        { name => 'name',   type => 'text' },
                        { name => 'errno',  type => 'iv' },
                        { name => 'reason', type => 'text' }
                    ]
                ],
                [
                    'REPORT_FAILED',                      'ReportFailed',
                    'XBench: could not write the report', []
                ],
            )
        ),
        CASE_CONTEXT => {
            class     => 'XBench::Diagnostic::CaseContext',
            parent    => 'XPerl::Diagnostic::Note',
            severity  => 'NOTE',
            params    => [ { name => 'name', type => 'text' } ],
            templates => { en => 'Benchmark case %{name}' },
        },
        PHASE_CONTEXT => {
            class    => 'XBench::Diagnostic::PhaseContext',
            parent   => 'XPerl::Diagnostic::Note',
            severity => 'NOTE',
            params   => [
                { name => 'phase',      type => 'text' },
                { name => 'iterations', type => 'uv' }
            ],
            templates => { en => 'During %{phase} (%{iterations} operations)' },
        },
    },
);

field $options :param;
field $state :reader   = 'new';
field $failure :reader = undef;
field @cases;
field @results;
field %names;

sub _diagnostic ( $condition, %parameters ) {
    my ( $file, $line );
    my $depth = 0;

    # Capture the public location and lexical language outside this file.
    while ( my @frame = caller($depth) ) {
        ( $file, $line ) = @frame[ 1, 2 ];
        last unless $file eq __FILE__;
        ++$depth;
    }

    return $catalog->_capture( $condition, \%parameters, $file, $line, $depth );
}

sub _error ( $condition, %parameters ) {
    my $diagnostic = _diagnostic( $condition, %parameters );
    my $location   = $diagnostic->location;
    my $exception  = XPerl::Exception->_new;
    $exception->append($diagnostic);
    $exception->_record_throw( { reason => 'throw', %$location } );
    die $exception;
}

sub _pairs ( $operation, @pairs ) {
    _error( 'INVALID_OPTION_LIST', operation => $operation ) if @pairs % 2;
    my %values;

    while (@pairs) {
        my ( $name, $value ) = splice @pairs, 0, 2;
        _error( 'INVALID_ARGUMENT', argument => 'option name' )
          unless defined($name) && !ref($name) && length($name) && length($name) <= 255;
        _error( 'DUPLICATE_OPTION', argument => $name ) if exists $values{$name};
        $values{$name} = $value;
    }

    return \%values;
}

sub _number ( $name, $value, $minimum, $integer = 0 ) {
    _error( 'INVALID_ARGUMENT', argument => $name )
      unless defined($value) && !ref($value) && looks_like_number($value);

    my $number = 0 + $value;
    _error( 'INVALID_ARGUMENT', argument => $name )
      unless isfinite($number)
      && $number >= $minimum
      && ( !$integer || ( int($number) == $number && $number <= 4294967295 ) );

    return $number;
}

sub _options (@pairs) {
    my $supplied = _pairs( 'new', @pairs );
    my %settings = (
        target_rel_precision => 0.05,
        target_abs_precision => 0,
        min_samples          => 20,
        max_samples          => 200,
        max_seconds          => 5,
        min_sample_time      => 0.001,
        max_batch_iterations => 1_048_576,
        warmup               => 1,
        confidence           => 0.95,
        resamples            => 1000,
        seed                 => 1,
        outlier_sigma        => 0,
        outlier_method       => 'mad',
    );

    for my $name ( keys %$supplied ) {
        _error( 'UNKNOWN_OPTION', argument => $name ) unless exists $settings{$name};
        $settings{$name} = $supplied->{$name};
    }

    for my $name (qw(target_rel_precision target_abs_precision outlier_sigma)) {
        $settings{$name} = _number( $name, $settings{$name}, 0 );
    }
    for my $name (qw(min_samples max_samples resamples)) {
        $settings{$name} = _number( $name, $settings{$name}, 2, 1 );
    }
    for my $name (qw(seed warmup)) {
        $settings{$name} = _number( $name, $settings{$name}, 0, 1 );
    }
    $settings{max_batch_iterations} =
      _number( 'max_batch_iterations', $settings{max_batch_iterations}, 1, 1 );

    for my $name (qw(max_seconds min_sample_time confidence)) {
        $settings{$name} = _number( $name, $settings{$name}, 0 );
        _error( 'INVALID_ARGUMENT', argument => $name ) unless $settings{$name} > 0;
    }
    _error( 'INVALID_ARGUMENT', argument => 'confidence' )
      unless $settings{confidence} < 1;
    _error( 'INVALID_ARGUMENT', argument => 'max_samples' )
      if $settings{max_samples} < $settings{min_samples};
    _error( 'INVALID_ARGUMENT', argument => 'precision' )
      unless $settings{target_rel_precision} || $settings{target_abs_precision};
    _error( 'INVALID_ARGUMENT', argument => 'outlier_method' )
      unless defined( $settings{outlier_method} )
      && !ref( $settings{outlier_method} )
      && $settings{outlier_method} =~ /\A(?:mad|sd)\z/;

    return \%settings;
}

sub new ( $class, @pairs ) {
    return $class->CONSTRUCT( options => _options(@pairs) );
}

sub _now() {
    return Time::HiRes::clock_gettime( Time::HiRes::CLOCK_MONOTONIC() );
}

sub _clock ($phase) {
    my $time = _now();
    _error( 'CLOCK', phase => $phase )
      unless defined($time)
      && !ref($time)
      && looks_like_number($time)
      && isfinite($time)
      && $time >= 0;

    return $time;
}

sub _batch ( $case, $callback, $iterations, $phase ) {
    my ( $duration, $primary );
    my $ready = 0;

    try {
        # Hooks receive copies so aliases cannot change the timed loop.
        $case->{before_sample}->( $phase . '', 0 + $iterations )
          if $case->{before_sample};
        $ready = 1;
        my $start = _clock($phase);

        for ( 1 .. $iterations ) {
            $callback->();
        }

        $duration = _clock($phase) - $start;
        _error( 'CLOCK', phase => $phase ) unless isfinite($duration) && $duration >= 0;
    }
    catch ( $value, $exception ) {
        $primary = $exception;
        $primary->append(
            _diagnostic(
                'PHASE_CONTEXT',
                phase      => $phase,
                iterations => $iterations
            )
        );
    }

    # Cleanup is outside the timed section, including when the callback dies.
    # Preserve both failures rather than replacing the original exception.
    if ( $ready && $case->{after_sample} ) {
        try {
            $case->{after_sample}->( $phase . '', 0 + $iterations );
        }
        catch ( $value, $exception ) {
            $exception->append(
                _diagnostic(
                    'PHASE_CONTEXT',
                    phase      => 'after_sample',
                    iterations => $iterations
                )
            );

            if ( defined $primary ) {
                if ( refaddr($primary) != refaddr($exception) ) {
                    $primary->append($_) for @{ $exception->contents };
                }
            }
            else {
                $primary = $exception;
            }
        }
    }

    die $primary if defined $primary;
    return $duration;
}

sub _command_valid ($arguments) {
    return
         ref($arguments) eq 'ARRAY'
      && @$arguments
      && !grep { !defined($_) || ref($_) } @$arguments;
}

method add (@pairs) {
    _error( 'STATE', operation => 'add', state => $state ) unless $state eq 'new';
    my $definition = _pairs( 'add', @pairs );

    for my $name ( keys %$definition ) {
        _error( 'UNKNOWN_OPTION', argument => $name )
          unless $name =~
          /\A(?:name|code|command|baseline|before_sample|after_sample)\z/;
    }

    my $name = $definition->{name};
    _error( 'INVALID_ARGUMENT', argument => 'name' )
      unless defined($name) && !ref($name) && length($name) && length($name) <= 255;
    _error( 'DUPLICATE_NAME',   name     => $name ) if exists $names{$name};
    _error( 'INVALID_ARGUMENT', argument => 'code/command' )
      if exists( $definition->{code} ) && exists( $definition->{command} );

    for my $key (qw(baseline before_sample after_sample)) {
        _error( 'INVALID_ARGUMENT', argument => $key )
          if defined( $definition->{$key} ) && ref( $definition->{$key} ) ne 'CODE';
    }

    my ( $callback, $command );
    dispatch($definition) {
        on( { code => $code, ... } if ref($code) eq 'CODE' ) {
            $callback = $code;
            $command  = 0;
        }
        on( { command => $arguments, ... } if _command_valid($arguments) ) {
            my @arguments = @$arguments;
            $command  = 1;
            $callback = sub {
                local $?;
                local $!;
                no warnings 'exec';
                my $status = system { $arguments[0] } @arguments;
                _error(
                    'COMMAND_START_FAILED',
                    name   => $name,
                    errno  => 0 + $!,
                    reason => "$!"
                ) if $status == -1;
                _error( 'COMMAND_FAILED', name => $name, status => 0 + $status )
                  if $status;
            };
        }
        on(_) {
            _error( 'INVALID_ARGUMENT', argument => 'code/command' );
        }
    }

    push @cases, { %$definition, callback => $callback, is_command => $command };
    $names{$name} = 1;
    return $self;
}

sub _analyze ( $values, $settings ) {
    my $statistics = XStats::Full->new($values);
    my $kept       = [@$values];

    if ( $settings->{outlier_sigma} ) {
        my $center = $statistics->median;
        my $scale;
        if ( $settings->{outlier_method} eq 'mad' ) {
            my $mad = $statistics->median_absolute_deviation;
            if ( $mad > 0 ) {
                state $normal_quartile = normal_quantile(0.75);
                $scale = $mad / $normal_quartile;
            }
            else {
                $scale = 0;
            }
        }
        else {
            $scale = $statistics->standard_deviation;
        }

        if ( $scale > 0 ) {
            my $threshold = $settings->{outlier_sigma} * $scale;
            my @filtered  = grep { abs( $_ - $center ) <= $threshold } @$values;

            # A quantized or very small sample must not empty the analysis.
            if ( @filtered >= 2 ) {
                $kept       = \@filtered;
                $statistics = XStats::Full->new($kept);
            }
        }
    }

    my $interval = $statistics->bootstrap_interval(
        confidence => $settings->{confidence},
        resamples  => $settings->{resamples},
        seed       => $settings->{seed},
    );
    my $mean        = $statistics->mean;
    my $error       = abs( $interval->{lower} - $mean );
    my $upper_error = abs( $interval->{upper} - $mean );
    $error = $upper_error if $upper_error > $error;

    return { kept => $kept, interval => $interval, mean => $mean, error => $error };
}

method _run_case ($case) {
    my $start      = _clock('start');
    my $resolution = Time::HiRes::clock_getres( Time::HiRes::CLOCK_MONOTONIC() );
    _error( 'CLOCK', phase => 'resolution' )
      unless defined($resolution) && isfinite($resolution) && $resolution > 0;

    my ( $warmup_calls, $calibration_calls ) = ( 0, 0 );
    for ( 1 .. $options->{warmup} ) {
        _batch( $case, $case->{callback}, 1, 'warmup' );
        _batch( $case, $case->{baseline}, 1, 'baseline_warmup' ) if $case->{baseline};
        ++$warmup_calls;
        last if _clock('warmup') - $start >= $options->{max_seconds};
    }

    my $iterations = 1;
    my $calibrated = $case->{is_command};
    unless ( $case->{is_command} ) {
        while (1) {
            my $duration =
              _batch( $case, $case->{callback}, $iterations, 'calibration' );
            $calibration_calls += $iterations;
            $calibrated = $duration >= $options->{min_sample_time};
            last
              if $calibrated
              || $iterations >= $options->{max_batch_iterations}
              || _clock('calibration') - $start >= $options->{max_seconds};

            $iterations *= 2;
            $iterations = $options->{max_batch_iterations}
              if $iterations > $options->{max_batch_iterations};
        }
    }

    my ( @raw,      @adjusted, @baselines );
    my ( $analysis, $reason,   $met );
    my $next_analysis = $options->{min_samples};
    my $floor         = ( $case->{baseline} ? 2 : 1 ) * $resolution / $iterations;

    while (1) {
        my ( $duration, $baseline );
        if ( $case->{baseline} && @raw % 2 ) {
            $baseline = _batch( $case, $case->{baseline}, $iterations, 'baseline' );
            $duration = _batch( $case, $case->{callback}, $iterations, 'sample' );
        }
        else {
            $duration = _batch( $case, $case->{callback}, $iterations, 'sample' );
            $baseline = _batch( $case, $case->{baseline}, $iterations, 'baseline' )
              if $case->{baseline};
        }

        push @raw,       $duration / $iterations;
        push @baselines, $baseline / $iterations if defined $baseline;
        push @adjusted, ( $duration - ( $baseline // 0 ) ) / $iterations;

        my $elapsed = _clock('sample') - $start;
        next if @raw < 2;
        next
          if @raw < $next_analysis
          && @raw < $options->{max_samples}
          && $elapsed < $options->{max_seconds}
          && $calibrated;

        $analysis = _analyze( \@adjusted, $options );
        my $error = $analysis->{error} > $floor ? $analysis->{error} : $floor;
        $met = $calibrated && @{ $analysis->{kept} } >= $options->{min_samples};
        $met &&= $analysis->{mean} > 0
          && $error / $analysis->{mean} <= $options->{target_rel_precision}
          if $options->{target_rel_precision};
        $met &&= $error <= $options->{target_abs_precision}
          if $options->{target_abs_precision};

        if ($met) {
            $reason = 'precision';
            last;
        }
        if ( !$calibrated ) {
            $reason = 'timer_resolution';
            last;
        }
        if ( @raw >= $options->{max_samples} ) {
            $reason = 'max_samples';
            last;
        }
        if ( _clock('analysis') - $start >= $options->{max_seconds} ) {
            $reason = 'max_seconds';
            last;
        }

        my $extra = int( @raw / 10 ) || 1;
        $next_analysis = @raw + $extra;
    }

    return XBench::Result->new(
        name                => $case->{name},
        iterations          => $iterations,
        elapsed             => _clock('finish') - $start,
        stop_reason         => $reason,
        precision_met       => $met ? 1 : 0,
        confidence          => $options->{confidence},
        resolution_floor    => $floor,
        calibration_calls   => $calibration_calls,
        warmup_calls        => $warmup_calls,
        baseline_subtracted => $case->{baseline} ? 1 : 0,
        settings            => $options,
        environment         => {
            scope          => 'benchmark_driver',
            clock          => 'monotonic',
            xbench_version => $VERSION,
            perl_version   => "$^V",
            os             => $^O,
            map { $_ => $Config{$_} }
              qw(archname nvtype cc ccflags optimize useithreads),
        },
        raw       => \@raw,
        adjusted  => \@adjusted,
        baselines => \@baselines,
        kept      => $analysis->{kept},
        interval  => $analysis->{interval},
    );
}

method run() {
    _error( 'STATE', operation => 'run', state => $state ) unless $state eq 'new';
    _error('NO_CASES')                                     unless @cases;

    $state = 'running';
    defer {
        # A one-shot runner need not retain workload closures or their data.
        @cases = ();
        %names = ();
        $state = 'failed' if $state eq 'running';
    }

    for my $case (@cases) {
        try {
            push @results, $self->_run_case($case);
        }
        catch ( $value, $exception ) {
            $failure = $exception;
            $failure->append( _diagnostic( 'CASE_CONTEXT', name => $case->{name} ) );
            die $failure;
        }
    }

    $state = 'complete';
    return $self->results;
}

method results() { [@results] }

method report ( $handle = \*STDOUT ) {
    for my $result (@results) {
        print {$handle} $result->as_text or _error('REPORT_FAILED');
    }
    return $self;
}

sub _one ( $kind, $work, @pairs ) {
    my $settings = _pairs( 'benchmark', @pairs );
    my $name     = exists $settings->{name} ? delete $settings->{name} : 'benchmark';
    my %case     = ( name => $name, $kind => $work );
    for my $key (qw(baseline before_sample after_sample)) {
        $case{$key} = delete $settings->{$key} if exists $settings->{$key};
    }

    my $bench = XBench->new(%$settings);
    $bench->add(%case);
    return $bench->run->[0];
}

sub benchmark ( $callback, @options ) { _one( 'code', $callback, @options ) }

sub benchmark_command ( $arguments, @options ) {
    _one( 'command', $arguments, @options );
}

sub compare ( $definitions, @options ) {
    _error( 'INVALID_ARGUMENT', argument => 'cases' )
      unless ref($definitions) eq 'ARRAY';
    my $bench = XBench->new(@options);

    for my $definition (@$definitions) {
        _error( 'INVALID_ARGUMENT', argument => 'case' )
          unless ref($definition) eq 'HASH';
        $bench->add(%$definition);
    }

    return $bench->run;
}

1;

=head1 NAME

XBench - Calibrated benchmarks with XStats uncertainty and retained samples

=head1 SYNOPSIS

    use XBench qw(benchmark);

    my $result = benchmark(
        sub { my $value = work() },
        name => 'work',
        target_rel_precision => 0.02,
    );
    print $result->as_text;
    my $data = $result->as_hash;

    my $bench = XBench->new(max_seconds => 3);
    $bench->add(name => 'first', code => sub { first() });
    $bench->add(name => 'second', command => ['./program', 'argument']);
    my $results = $bench->run;
    $bench->report;

=head1 DESCRIPTION

XBench measures monotonic wall time and reports seconds per operation, sample
SD and a bootstrap confidence interval for the mean.  It warms up and
calibrates repeated callback batches, then collects timing
observations at the batch level.  Loop iterations are not counted as
independent statistical samples.  Cases run sequentially in insertion order.

The API is inspired by Dumbbench and uses only modules supplied with XPerl.
Native classes, readers, signatures, shape dispatch, defer and two-variable
catches exercise the XPerl language and structured exception machinery.

=head1 CASES AND FUNCTIONS

C<add(name =E<gt> $name, code =E<gt> \&work)> adds a callback case.
C<add(name =E<gt> $name, command =E<gt> \@arguments)> executes a command
directly without a shell, once per sample.  Names must be unique, nonempty
strings of at most 255 characters.  Callback return values are discarded.

Optional C<baseline =E<gt> \&baseline> pairs each measured batch with a
baseline batch using the same iteration count.  Execution order alternates.
The adjusted sample is their elapsed-time difference divided by iterations.
Negative adjusted values are retained.  Subtraction is disabled by default.
The caller chooses whether an additive baseline models the operation.

C<before_sample> and C<after_sample> receive phase and iteration count.
They run outside the timed section, including warmup and calibration.
Cleanup runs after a completed setup even when the measured callback fails.

The exported C<benchmark(\&work, %options)> and
C<benchmark_command(\@arguments, %options)> return a single Result.
They accept an optional C<name> and the per-case callbacks above.
C<compare(\@cases, %options)> accepts ordered case-definition hashes and
returns an array reference of results.

=head1 RUNNER OPTIONS

=over 4

=item target_rel_precision, target_abs_precision

Maximum uncertainty relative to a positive mean (default 0.05), or absolute
uncertainty in seconds per operation (default zero, disabled).  Each enabled
target must be met.  At least one must be positive.

=item min_samples, max_samples

Minimum retained batches (default 20) and maximum measured batches (default
200).  Both are integers of at least two, with maximum at least minimum.

=item max_seconds

Soft elapsed-time budget per case, including warmup, calibration and analysis
(default five seconds).  It is checked between batches and cannot interrupt
a running callback or command.  At least two measured samples are collected.

=item min_sample_time, max_batch_iterations

Callback calibration doubles iterations until a batch takes at least 0.001
seconds, subject to an iteration cap (default 1,048,576) and the time budget.
An unmet calibration target returns a C<timer_resolution> stop reason.
Commands use one execution per sample and need no loop calibration.

=item warmup

Unmeasured single-operation warmups per case (default one).  A supplied
baseline is warmed up too.  Zero disables warmup.

=item confidence, resamples, seed

Confidence level strictly between zero and one (default 0.95), bootstrap
repeat count of at least two (default 1000), and local U32 seed (default one).
XStats supplies a percentile bootstrap interval for the retained mean.
The application's random generator is unaffected.

=item outlier_sigma, outlier_method

Filtering is disabled by default (zero sigma).  A positive threshold keeps
values within that many deviations of the median.  C<mad> uses raw MAD
divided by the normal 0.75 quantile; C<sd> uses sample SD.  A zero scale
keeps every observation.  Filtering never leaves fewer than two samples.
Rejected values and all pre-filter measurements remain available.

=back

Numeric options must be finite.  Counts and the seed fit U32.  Unknown,
duplicate and incomplete options raise module-owned structured conditions.

=head1 RESULTS AND STOPPING

C<run> returns an array reference of L<XBench::Result> objects.  The runner
state progresses from C<new> to C<running>, then C<complete> or C<failed>.
A runner cannot be rerun or extended after starting.  C<results> retains
completed earlier cases if a later case fails; C<failure> retains the
canonical exception.

Precision uses the larger distance from the mean to either confidence bound,
with a clock-resolution floor per operation (twice the floor for paired
subtraction).  The result records whether the target was met and why it
stopped: C<precision>, C<max_samples>, C<max_seconds> or
C<timer_resolution>.  Uniform zero measurements do not establish relative
precision.  Time and sample limits return results rather than discarding data.

Bootstrap intervals describe observed batch variability.  Sequential timing
data can be correlated, adaptive stopping affects coverage, and opt-in
filtering describes a selected distribution.  The confidence level is not a
universal coverage guarantee.  Results retain the evidence needed to assess
those assumptions.

Callback timings include invocation and loop overhead.  Command timings
include process startup and inherited I/O.  Use an explicit baseline when
that subtraction answers the measurement question.

=head1 EXCEPTIONS

Failures use XPerl's structured exceptions.  Callback and cleanup errors
retain their original diagnostics in encounter order, with phase and case
context appended.  C<defer> restores the runner's state during unwinding.
No error is reduced to rendered text.  Command failures include their raw
system wait status.

=head1 DEPENDENCIES AND ACKNOWLEDGEMENTS

Runtime dependencies are XStats, XPerl::Diagnostic::Catalog, Time::HiRes,
Scalar::Util, POSIX, Config and JSON::PP, all supplied with XPerl.  The command-line
tool also uses the bundled Getopt::Long.

The measurement design is inspired by Dumbbench 0.505 by Steffen Mueller.
XBench uses XStats and native XPerl objects in place of its external
statistics, accessor and error-number dependencies.

=head1 LICENSE

Distributed under the same terms as Perl itself.

=cut
