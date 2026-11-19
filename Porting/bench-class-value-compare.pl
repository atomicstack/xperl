#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use BenchUtils qw(absolute read_text write_text write_json json sha256 run
    rng shuffle median minimum maximum csv_line source_info source_patch pin_cpu platform_info);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(GetOptions);
use JSON::PP qw(decode_json);
use POSIX qw(strftime);

Getopt::Long::Configure('bundling');

my %options = (
    perl => "$FindBin::Bin/../perl", models => 'class,moo-perl,moo-xs,bless,bless-checked',
    fields => '2,8,32', reads => '1,10,100',
    cases => 'construct,retain,access,internal,create_access,create_internal',
    initialization => 'required', repeats => 7, seconds => 0.2, timeout => 30,
    'memory-counts' => '10000,50000,100000', 'memory-repeats' => 3, seed => 20261030,
);
my (@includes, $help);
GetOptions(\%options, 'perl=s', 'core-lib=s', 'include|I=s@' => \@includes,
    'output=s', 'models=s', 'fields=s', 'reads=s', 'cases=s', 'initialization=s',
    'repeats=i', 'seconds=f', 'timeout=f', 'memory-counts=s', 'memory-repeats=i',
    'cpu=i', 'seed=i', 'check-only', 'help' => \$help) or die "Invalid options\n";
if ($help) {
    print "Usage: $0 --output DIR [--perl PERL] [--models LIST] [--check-only]\n";
    exit;
}
die "Unexpected arguments: @ARGV\n" if @ARGV;
die "--output is required\n" unless $options{output};
die "Repeats, seconds and timeout must be positive\n"
    if grep { $options{$_} <= 0 } qw(repeats seconds timeout memory-repeats);
die "Invalid initialization\n" unless $options{initialization} =~ /\A(?:required|defaults)\z/;
my @models = split /,/, $options{models};
my @fields = split /,/, $options{fields};
my @reads = split /,/, $options{reads};
my @cases = split /,/, $options{cases};
my @counts_input = grep { length } split /,/, $options{'memory-counts'};
die "Memory populations must be positive integers\n"
    if grep { !/\A\d+\z/ || $_ < 1 } @counts_input;
my %counts = map { 0 + $_ => 1 } @counts_input;
my @counts = sort { $a <=> $b } keys %counts;
die "Unknown model\n" if !@models || grep { !/\A(?:class|moo-perl|moo-xs|bless|bless-checked)\z/ } @models;
die "Fields must be 1..256\n" if !@fields || grep { !/\A\d+\z/ || $_ < 1 || $_ > 256 } @fields;
die "Reads must be positive\n" if !@reads || grep { !/\A\d+\z/ || $_ < 1 } @reads;
die "Unknown timing case\n" if !@cases || grep { !/\A(?:construct|retain|access|internal|create_access|create_internal)\z/ } @cases;
@fields = map { 0 + $_ } @fields;
@reads = map { 0 + $_ } @reads;
die "Supply at least two positive memory populations, or an empty string\n"
    if @counts && (@counts < 2 || grep { !/\A\d+\z/ || $_ < 1 } @counts);

my $perl = absolute($options{perl});
my $core_lib = absolute($options{'core-lib'} // dirname($perl).'/lib');
@includes = map { absolute($_) } @includes;
my $worker = "$FindBin::Bin/bench-class-value.pl";
my @prefix = ($perl, "-I$core_lib", (map { "-I$_" } @includes), $worker);
my $out = absolute($options{output});
die "Output directory already exists: $out\n" if -e $out;
make_path($out);
pin_cpu($options{cpu});
my %environment = (PERL_HASH_SEED => '0', PERL_PERTURB_KEYS => '0');
my @unset = qw(PERL5OPT PERL5LIB PERLLIB);

my $platform = platform_info();
$platform->{cpu_model} = delete $platform->{cpu};
write_json("$out/config.json", {
    %options, output => $out, executable => $perl, core_lib => $core_lib,
    includes => \@includes, executable_sha256 => sha256($perl),
    worker_sha256 => sha256($worker), driver_sha256 => sha256(__FILE__),
    helper_sha256 => sha256("$FindBin::Bin/BenchUtils.pm"),
    start_time => strftime('%Y-%m-%dT%H:%M:%S%z', localtime),
    %$platform, repository => source_info("$FindBin::Bin/.."),
    working_tree_patch => source_patch("$FindBin::Bin/..", "$out/working-tree.patch"),
});
write_text("$out/bench-class-value.pl", read_text($worker));
write_text("$out/bench-class-value-compare.pl", read_text(__FILE__));
write_text("$out/BenchUtils.pm", read_text("$FindBin::Bin/BenchUtils.pm"));
open my $raw, '>:raw', "$out/samples.jsonl" or die "$out/samples.jsonl: $!\n";
$raw->autoflush(1);
my @rows;

sub sample {
    my ($model, $fields, $case, $reads, $iterations, $phase, $repeat) = @_;
    my @command = (@prefix, '--model', $model, '--fields', $fields,
        '--case', $case, '--reads', $reads, '--iterations', $iterations,
        '--initialization', $options{initialization});
    my $result = eval {
        run(\@command, env => \%environment, unset => \@unset,
            timeout => $options{timeout}, allow_failure => 1);
    };
    if (!$result || $result->{status} || length $result->{stderr}) {
        write_json("$out/failure.json", {command => \@command,
            error => "$@", ($result ? %$result : ())});
        die "Worker $model/$fields/$case failed; see $out/failure.json\n";
    }
    my $row = decode_json($result->{stdout});
    @$row{qw(phase repeat process_seconds)} = ($phase, $repeat, $result->{wall_seconds});
    push @rows, $row;
    print {$raw} json($row), "\n" or die "Cannot write samples: $!\n";
    return $row;
}

for my $model (@models) {
    for my $fields (@fields) {
        my $row = sample($model, $fields, 'check', 1, 0, 'check', 0);
        print "checked $model, fields=$fields, XS reader=$row->{accessor_xs}\n";
        my $source = run([@prefix, '--model', $model, '--fields', $fields,
            '--source', '--initialization', $options{initialization}],
            env => \%environment, unset => \@unset, timeout => $options{timeout});
        write_text("$out/model-$model-$fields.pl", $source->{stdout});
    }
}
exit if $options{'check-only'};

my @jobs;
for my $model (@models) {
    for my $fields (@fields) {
        for my $case (@cases) {
            push @jobs, map { [$model, $fields, $case, $_] }
                $case =~ /\A(?:construct|retain)\z/ ? (1) : @reads;
        }
    }
}
my $state = rng($options{seed});
@jobs = shuffle($state, @jobs);
my %iterations;
for my $job (@jobs) {
    my $n = 1000;
    my $cap = $job->[2] eq 'retain' ? 50000 : 10000000;
    my $row;
    for (1 .. 4) {
        $row = sample(@$job, $n, 'calibrate', 0);
        last if $row->{seconds} >= 0.01 || $n == $cap;
        my $factor = int(0.012 / ($row->{seconds} || 1e-9));
        $factor = 2 if $factor < 2;
        $factor = 20 if $factor > 20;
        $n = $n * $factor > $cap ? $cap : $n * $factor;
    }
    my $wanted = int($n * $options{seconds} / ($row->{seconds} || 1e-9));
    $iterations{join ':', @$job} = $wanted > $cap ? $cap : $wanted < 1 ? 1 : $wanted;
}
for my $repeat (0 .. $options{repeats} - 1) {
    @jobs = shuffle($state, @jobs);
    sample(@$_, $iterations{join ':', @$_}, 'timing', $repeat) for @jobs;
    print "timing round ", $repeat + 1, "/$options{repeats}\n";
}
my @memory;
for my $model (@models) {
    for my $fields (@fields) {
        push @memory, map { [$model, $fields, $_] } @counts;
    }
}
for my $repeat (0 .. $options{'memory-repeats'} - 1) {
    @memory = shuffle($state, @memory);
    sample($_->[0], $_->[1], 'memory', 1, $_->[2], 'memory', $repeat) for @memory;
    print "memory round ", $repeat + 1, "/$options{'memory-repeats'}\n" if @memory;
}
close $raw or die "Cannot close samples: $!\n";

my $timing = csv_line(qw(model fields case reads iterations median_ns_per_iteration
    min_ns max_ns median_absolute_deviation_ns samples));
for my $job (sort { join(':', @$a) cmp join(':', @$b) } @jobs) {
    my $key = join ':', @$job;
    my @times = map { $_->{seconds} * 1e9 / $_->{iterations} }
        grep { $_->{phase} eq 'timing'
            && join(':', @$_{qw(model fields case reads)}) eq $key } @rows;
    my $median = median(@times);
    $timing .= csv_line(@$job, $iterations{$key}, $median, minimum(@times),
        maximum(@times), median(map { abs($_ - $median) } @times), scalar @times);
}
write_text("$out/timing.csv", $timing);

my $memory = csv_line(qw(model fields population median_rss_delta median_bytes_per_object));
my %rss;
for my $job (sort { join(':', @$a) cmp join(':', @$b) } @memory) {
    my ($model, $fields, $n) = @$job;
    my $median = median(map { $_->{rss_delta} }
        grep { $_->{phase} eq 'memory' && $_->{model} eq $model
            && $_->{fields} == $fields && $_->{iterations} == $n } @rows);
    $rss{"$model:$fields:$n"} = $median;
    $memory .= csv_line($model, $fields, $n, $median, $median / $n);
}
write_text("$out/memory.csv", $memory);
my $slopes = csv_line(qw(model fields min_population max_population resident_bytes_per_object));
if (@counts) {
    for my $model (@models) {
        for my $fields (@fields) {
            my ($low, $high) = @counts[0, -1];
            $slopes .= csv_line($model, $fields, $low, $high,
                ($rss{"$model:$fields:$high"} - $rss{"$model:$fields:$low"}) / ($high - $low));
        }
    }
}
write_text("$out/memory-slopes.csv", $slopes);
print "Completed. Raw samples and CSV summaries: $out\n";
