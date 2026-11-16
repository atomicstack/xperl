#!/usr/bin/perl
use strict;
use warnings;
use XBench;
use XStats::Full;
use JSON::PP qw(encode_json decode_json);
use Time::HiRes qw(clock_getres CLOCK_MONOTONIC);
use Getopt::Long qw(GetOptions);
use FindBin;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use Digest::SHA qw(sha256_hex);
use IO::Handle;

my $workspace = abs_path("$FindBin::Bin/../../..");
my ($sc, $oa, $output) = ("$workspace/xperl", "$workspace/tmp/xperl-oa-independent",
                         "$workspace/tmp/hash-index-xbench");
my ($sizes, $modes) = ('8,16,100,1000,10000,100000,300000',
    'fetch-random,fetch-shared,fetch-sequential,miss,exists,iterate,construct,churn,query-only');
my ($min_samples, $max_samples, $max_seconds, $precision, $sample_time) =
    (30, 120, 60, 0.02, 0.1);
GetOptions('sc=s' => \$sc, 'oa=s' => \$oa, 'output=s' => \$output,
    'sizes=s' => \$sizes, 'modes=s' => \$modes,
    'min-samples=i' => \$min_samples, 'max-samples=i' => \$max_samples,
    'max-seconds=f' => \$max_seconds, 'precision=f' => \$precision,
    'sample-time=f' => \$sample_time) or die "invalid arguments\n";
die "positive sample time and precision required\n" unless $sample_time > 0 && $precision > 0;
make_path($output);
my $worker = "$FindBin::Bin/bench-hash-index.pl";
my %core = (sc => abs_path($sc), oa => abs_path($oa));
my @sizes = split /,/, $sizes;
die "invalid sizes\n" if grep { !/^\d+$/ || $_ < 1 } @sizes;
my @cases = map { my $n = $_; map { [$n, $_] } split /,/, $modes } @sizes;
srand(20261117);
for (my $i = $#cases; $i > 0; $i--) {
    my $j = int rand($i + 1);
    @cases[$i, $j] = @cases[$j, $i];
}
open my $raw, '>', "$output/raw.jsonl" or die $!;
open my $summaries, '>', "$output/summary.jsonl" or die $!;
$raw->autoflush(1);
$summaries->autoflush(1);
$| = 1;

sub capture {
    open my $child, '-|', @_ or die "start child: $!";
    my $text = do { local $/; <$child> };
    close $child or die "child failed: $?\n";
    return $text;
}
sub digest_file {
    open my $file, '<', $_[0] or die $!;
    return sha256_hex(do { local $/; <$file> });
}
my %provenance;
for my $variant (qw(sc oa)) {
    my $path = $core{$variant};
    my $commit = capture('git', '-C', $path, 'rev-parse', 'HEAD');
    chomp $commit;
    my $config = capture("$path/perl", "-I$path/lib", '-MConfig', '-MJSON::PP=encode_json',
        '-e', 'print encode_json({map {$_=>$Config{$_}} qw(cc gccversion optimize ccflags nvtype useithreads)});');
    $provenance{$variant} = {directory => $path, commit => $commit,
        binary_sha256 => digest_file("$path/perl"), config => decode_json($config)};
}
my ($cpu_model, $cpu_affinity);
open my $cpu_file, '<', '/proc/cpuinfo' or die $!;
while (<$cpu_file>) { $cpu_model = $1, last if /^model name\s*:\s*(.+)/ }
open my $status_file, '<', '/proc/self/status' or die $!;
while (<$status_file>) { $cpu_affinity = $1, last if /^Cpus_allowed_list:\s*(.+)/ }
open my $meta, '>', "$output/metadata.json" or die $!;
print {$meta} encode_json({variants => \%provenance, xbench_version => $XBench::VERSION,
    xbench_sha256 => digest_file("$sc/lib/XBench.pm"),
    cpu_model => $cpu_model, cpu_affinity => $cpu_affinity, modes => [split /,/, $modes],
    worker_sha256 => digest_file($worker), driver_sha256 => digest_file(__FILE__),
    settings => {min_samples => $min_samples, max_samples => $max_samples,
        max_seconds => $max_seconds, target_difference_fraction_of_sc => $precision,
        minimum_pilot_sample_seconds => $sample_time, confidence => 0.95,
        resamples => 4000, filtering => 'disabled', linear_max => 8,
        perturb_keys => 0}, sizes => \@sizes,
    date => scalar(gmtime) . ' UTC'}), "\n";
close $meta;

sub worker {
    my ($variant, $n, $operations, $mode, $pair, $phase) = @_;
    local %ENV = %ENV;
    delete @ENV{qw(PERL5LIB PERL5OPT PERL_HASH_SEED_DEBUG)};
    $ENV{PERL_HASH_SEED} = sprintf '0x13579bdf%08x', 0x2468ace0 + $pair;
    $ENV{PERL_PERTURB_KEYS} = 0;
    $ENV{PERL_HASH_LINEAR_MAX} = 8;
    my $path = $core{$variant};
    my $row = decode_json(capture("$path/perl", "-I$path/lib", $worker, $n, $operations, $mode));
    die "operation count changed\n" unless $row->{operations} == $operations;
    die "wrong index layout\n" unless !!$row->{initial}{integer_chained} == ($variant eq 'sc');
    @$row{qw(variant pair phase hash_seed)} = ($variant, $pair, $phase, $ENV{PERL_HASH_SEED});
    print {$raw} encode_json($row), "\n";
    return $row;
}

my $done = 0;
for my $case (@cases) {
    my ($n, $mode) = @$case;
    my $operations = int((100000 + $n - 1) / $n) * $n;
    my ($pilot_sc, $pilot_oa);
    for my $attempt (1 .. 8) {
        $pilot_sc = worker('sc', $n, $operations, $mode, 0, 'pilot');
        $pilot_oa = worker('oa', $n, $operations, $mode, 0, 'pilot');
        my $shorter = $pilot_sc->{seconds} < $pilot_oa->{seconds}
            ? $pilot_sc->{seconds} : $pilot_oa->{seconds};
        last if $shorter >= $sample_time;
        die "zero pilot time\n" unless $shorter > 0;
        my $desired = $operations * $sample_time * 1.1 / $shorter;
        $operations = int(($desired + $n - 1) / $n) * $n;
        die "pilot batch too large\n" if $operations > 100000000;
    }
    die "pilot did not reach sample duration\n"
        if $pilot_sc->{seconds} < $sample_time || $pilot_oa->{seconds} < $sample_time;
    my $target = $precision * $pilot_sc->{seconds} / $operations;
    my $pair = 1;
    my %pending;
    my $phase;
    my @paired;
    my $callback = sub {
        my ($variant) = @_;
        return sub {
            die "duplicate variant in a pair\n" if exists $pending{$variant};
            my $row = worker($variant, $n, $operations, $mode, $pair, $phase);
            $pending{$variant} = $row;
            if (keys(%pending) == 2) {
                push @paired, {%pending} unless $phase =~ /warmup/;
                %pending = ();
                $pair++;
            }
            return $row->{seconds};
        };
    };
    my $bench = XBench->new(min_samples => $min_samples, max_samples => $max_samples,
        max_seconds => $max_seconds, target_rel_precision => 0,
        target_abs_precision => $target, warmup => 1, confidence => 0.95,
        resamples => 4000, seed => 20261117, outlier_sigma => 0);
    $bench->add(name => "$n/$mode", operations => $operations,
        resolution => clock_getres(CLOCK_MONOTONIC), measure => $callback->('oa'),
        baseline => $callback->('sc'), before_sample => sub { $phase = $_[0] });
    my $result = $bench->run->[0];
    die "incomplete pair\n" if keys %pending;
    die "pair count differs from XBench samples\n" unless @paired == $result->total_samples;
    my @ratios = map { $_->{oa}{seconds} / $_->{sc}{seconds} } @paired;
    my $ratios = XStats::Full->new(\@ratios);
    my %timings;
    for my $variant (qw(sc oa)) {
        my @seconds = map { $_->{$variant}{seconds} / $operations } @paired;
        my $stats = XStats::Full->new(\@seconds);
        $timings{$variant} = {mean => $stats->mean, median => $stats->median,
            standard_deviation => $stats->standard_deviation,
            confidence_interval => $stats->bootstrap_interval(confidence => 0.95,
                resamples => 4000, seed => 20261117), initial => $paired[0]{$variant}{initial}};
    }
    print {$summaries} encode_json({n => 0 + $n, mode => $mode,
        operations => $operations, difference => $result->as_hash,
        paired_mean_ratio => $ratios->mean,
        ratio_interval => $ratios->bootstrap_interval(confidence => 0.95,
            resamples => 4000, seed => 20261117), variants => \%timings}), "\n";
    printf "%d/%d %s: delta %.2f ns/op; %d pairs; %s; precision %s\n",
        ++$done, scalar(@cases), "$n/$mode", 1e9 * $result->mean,
        $result->total_samples, $result->stop_reason, $result->precision_met ? 'met' : 'UNMET';
}
print "XBENCH HASH COMPARISON COMPLETE\n";
