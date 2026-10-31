#!/usr/bin/perl
use v5.36;
use Getopt::Long qw(GetOptions);
use JSON::PP qw(encode_json);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use Config;
use B ();

my ($model, $case, $fields, $reads, $iterations) = ('class', 'check', 2, 1, 10000);
my ($source, $help);
my $initialization = 'required';
GetOptions('model=s' => \$model, 'case=s' => \$case,
    'fields=i' => \$fields, 'reads=i' => \$reads,
    'iterations=i' => \$iterations, 'source' => \$source,
    'initialization=s' => \$initialization, 'help' => \$help) or die "Invalid options\n";
if ($help) {
    print "See perldoc Porting/bench-class-value.pl; use bench-class-value.py to run comparisons.\n";
    exit;
}
die "Invalid model\n" unless $model =~ /\A(?:class|moo-perl|moo-xs|bless|bless-checked)\z/;
die "Invalid case\n" unless $case =~ /\A(?:check|construct|retain|access|internal|create_access|create_internal|memory)\z/;
die "Positive fields/reads and nonnegative iterations required\n"
    unless $fields > 0 && $fields <= 256 && $reads > 0 && $iterations >= 0;
die "Invalid initialization\n" unless $initialization =~ /\A(?:required|defaults)\z/;
my @names = map { "f$_" } 0 .. $fields - 1;
my @args = map { ($names[$_], $_ + 1) } 0 .. $#names;
@args = () if $initialization eq 'defaults';
my $sum = $fields * ($fields + 1) / 2;
my $package = 'ClassValueBench';
my $definition;
my $xs = 0;
my %versions;
my @setup_warnings;
$SIG{__WARN__} = sub { push @setup_warnings, "$_[0]" };
if ($model eq 'class') {
    $definition = "use feature 'class'; no warnings 'experimental::class'; class $package {\n";
    for my $index (0 .. $#names) {
        my $name = $names[$index];
        my $default = $initialization eq 'defaults' ? ' = ' . ($index + 1) : '';
        $definition .= "field \$$name :param$default; method $name { \$$name }\n";
    }
    $definition .= 'method scan($rounds) { my $total = 0; for (1..$rounds) {';
    $definition .= join '', map { "\$total += \$$_;" } @names;
    $definition .= '} return $total } }';
} else {
    $definition = "package $package;\n";
    if ($model =~ /^moo/) {
        $ENV{MOO_XS_DISABLE} = $model eq 'moo-perl' ? 1 : 0;
        require Moo;
        require Method::Generate::Accessor;
        $versions{Moo} = $Moo::VERSION;
        if ($model eq 'moo-xs') {
            require Class::XSAccessor;
            $versions{'Class::XSAccessor'} = $Class::XSAccessor::VERSION;
        }
        $definition .= 'use Moo;';
        for my $index (0 .. $#names) {
            my $options = $initialization eq 'defaults' ? 'default => ' . ($index + 1) : 'required => 1';
            $definition .= "has $names[$index] => (is => 'ro', $options);";
        }
    } else {
        my $defaults = $initialization eq 'defaults'
            ? join('', map { "$names[$_] => " . ($_ + 1) . ', ' } 0 .. $#names) : '';
        $definition .= 'sub new { my $class = shift; my $self = bless { ' . $defaults . '@_ }, $class;';
        if ($model eq 'bless-checked' && $initialization eq 'required') {
            $definition .= join '', map { "die 'Missing $_' unless exists \$self->{$_};" } @names;
        }
        $definition .= 'return $self }';
        $definition .= join '', map { "sub $_ { \$_[0]->{$_} }" } @names;
    }
    $definition .= 'sub scan { my ($self, $rounds) = @_; my $total = 0; for (1..$rounds) {';
    $definition .= join '', map { "\$total += \$self->{$_};" } @names;
    $definition .= '} return $total } 1;';
}
if ($source) { print "$definition\n"; exit }
eval $definition;
die $@ if $@;
my $object = $package->new(@args);
# Force deferred Moo construction and accessor generation before measuring.
for my $index (0 .. $#names) {
    my $name = $names[$index];
    die "Incorrect $name\n" unless $object->$name == $index + 1;
}
die "Incorrect internal scan\n" unless $object->scan($reads) == $sum * $reads;
$xs = B::svref_2object($package->can('f0'))->XSUB ? 1 : 0;
die "moo-xs did not generate an XS accessor\n" if $model eq 'moo-xs' && !$xs;
die "moo-perl unexpectedly generated an XS accessor\n" if $model eq 'moo-perl' && $xs;
if ($model ne 'bless' && $initialization eq 'required') {
    eval { $package->new() };
    die "Required fields were not enforced\n" unless $@;
}
$SIG{__WARN__} = 'DEFAULT';
my %result = (setup_warnings => \@setup_warnings, initialization => $initialization, model => $model, case => $case, fields => $fields,
    reads => $reads, iterations => $iterations, accessor_xs => $xs,
    versions => \%versions, perl => "$^V", executable => $^X,
    archname => $Config{archname}, optimize => $Config{optimize},
    cc => $Config{cc}, ccflags => $Config{ccflags},
    useithreads => $Config{useithreads}, ptrsize => $Config{ptrsize});
if ($case eq 'check') { print encode_json(\%result), "\n"; exit }
sub rss_bytes {
    open my $fh, '<', '/proc/self/smaps_rollup' or die "RSS measurement needs Linux smaps_rollup: $!\n";
    while (<$fh>) { return $1 * 1024 if /^Rss:\s+(\d+)/ }
    die "No RSS value\n";
}
if ($case eq 'memory') {
    # Populate the retaining array before measuring, so its slots are excluded.
    my @objects = (undef) x $iterations;
    for (1..100) { my $warm = $package->new(@args) }
    my $before = rss_bytes();
    for my $i (0 .. $iterations - 1) { $objects[$i] = $package->new(@args) }
    my $after = rss_bytes();
    $result{rss_before} = $before;
    $result{rss_after} = $after;
    $result{rss_delta} = $after - $before;
    $result{checksum} = $iterations ? $objects[-1]->scan(1) : 0;
    print encode_json(\%result), "\n";
    exit;
}
my $access = join '', map { "\$total += \$current->$_;" } @names;
my $body = $case eq 'construct' ? 'my $current = $package->new(@args);' :
           $case eq 'retain' ? 'push @held, $package->new(@args);' :
           $case eq 'access' ? 'my $current = $object; for (1..$reads) {' . $access . '}' :
           $case eq 'internal' ? '$total += $object->scan($reads);' :
           $case eq 'create_access' ? 'my $current = $package->new(@args); for (1..$reads) {' . $access . '}' :
           'my $current = $package->new(@args); $total += $current->scan($reads);';
my @held;
my $run = eval 'sub { my ($n) = @_; my $total = 0; for (1..$n) {' . $body . '} return $total }';
die $@ unless $run;
$run->(100);
@held = ();
my $start = clock_gettime(CLOCK_MONOTONIC);
my $total = $run->($iterations);
my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $start;
my $expected = $case eq 'construct' || $case eq 'retain' ? 0 : $iterations * $reads * $sum;
die "Incorrect checksum: $total != $expected\n" unless $total == $expected;
die "Incorrect retained count\n" if $case eq 'retain' && @held != $iterations;
$result{seconds} = $elapsed;
$result{checksum} = $total;
print encode_json(\%result), "\n";

__END__

=head1 NAME

bench-class-value.pl - measure class, Moo, and blessed hash objects

=head1 SYNOPSIS

    ./perl -Ilib Porting/bench-class-value.pl --model class --case access
    python3 Porting/bench-class-value.py --help

=head1 RUNNING A COMPARISON

From a built Perl source tree, run:

    python3 Porting/bench-class-value.py --output ../tmp/class-value-run \
        -I /path/to/moo/lib \
        -I /path/to/xs/blib/lib -I /path/to/xs/blib/arch

The output directory must not already exist. C<--perl> selects another Perl
and C<--core-lib> supplies its matching core library directory. External XS
modules must be built for that interpreter. Nothing is installed by this
runner. To run without optional dependencies, use C<--models class,bless>.

Use C<--initialization defaults> for constructors with no arguments and
constant default values. Use C<--fields 2,8,32> and C<--reads 1,10,100> to
choose the object sizes and read rounds. Each read round visits every field,
so two fields and ten rounds means twenty reads per timed iteration.

C<--check-only> validates the models without running measurements. The driver
checks every generated reader, internal scan, required-input behavior, and
measured checksum. Every worker has a C<--timeout> limit (30 seconds by
default). A timed-out worker is killed and the run stops with a failure file.

Timing samples run sequentially in randomized order, with optional CPU
pinning via C<--cpu>. The runner calibrates to C<--seconds> per sample and
reports medians, ranges, and median absolute deviations. Retained-construction
samples are capped at 50,000 objects to bound memory, so they may be shorter
than the requested duration. Do not run builds or other benchmarks alongside
the timing run.

Output includes C<config.json>, C<samples.jsonl>, C<timing.csv>, C<memory.csv>,
and C<memory-slopes.csv>. Generated model sources and copies of the worker
and driver are saved for review. Setup warnings are captured in each JSON
record, outside the timing interval. C<process_seconds> includes loading,
validation, measurement, and teardown and is not a standalone startup metric.

Memory sampling requires Linux. Pass C<--memory-counts ''> to skip it. The
default populations are 10,000, 50,000, and 100,000 retained objects, with
three fresh processes at each population. The output preserves both the
individual RSS deltas and a slope between the smallest and largest sizes.

The timing unit is nanoseconds per outer iteration: one object lifetime for
construction cases, or the requested read rounds for access cases. It is not
nanoseconds per individual field access unless the case has one field and
one read round.

=head1 DESCRIPTION

This is the worker for C<bench-class-value.py>. Each process loads one model,
checks its constructor and readers, warms deferred code, and emits one JSON
record. No benchmark modules are needed for C<class> or C<bless>. Moo is an
optional external dependency. C<moo-xs> requires Class::XSAccessor built for
the selected interpreter and verifies that its reader is an XSUB.
C<moo-perl> explicitly disables XS accessors.

With C<--initialization required> (the default), all models receive the same
named argument pairs and store the same integer
values. The fields are required in class, Moo, and bless-checked. Plain bless
omits validation and is a minimal baseline, not an equivalent constructor.
With C<--initialization defaults>, every field has a constant integer default
and constructors receive no arguments. The two bless models coincide in this
scenario, since there are no missing required fields to validate.
Other constructor semantics, such as handling unknown keys, are not equated.

C<construct> includes immediate destruction. C<retain> retains every object
until after timing and measures construction plus the retaining array's
pushes. C<access> reads every field through a reader, repeating C<--reads>
times per object. C<internal> calls one method that reads every field directly
that many times. For Moo this uses its hash representation, not its accessors.
C<create_access> and C<create_internal> construct and destroy one object per
iteration and perform the corresponding reads. Timings include loop costs.

C<memory> reports incremental resident bytes on Linux, retaining all objects.
The retaining array is populated with undef before the initial RSS reading.
This measures allocator/page-level resident growth, not exact reachable object
size. Shared class/module metadata and interpreter startup are outside the
delta. Compare several population sizes because arenas and page granularity
can distort small samples. The driver reports the slope between the smallest
and largest populations as well as individual measurements.

C<--source> prints the generated model for inspection. The suite is an
independent comparison until the original benchmark source is supplied. It
does not claim to replicate an unpublished benchmark exactly.

=cut
