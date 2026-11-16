#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP qw(decode_json);

my ($directory, $report, @followups) = @ARGV;
die "usage: $0 RESULTS_DIRECTORY REPORT.md [FOLLOWUP_DIRECTORY ...]\n"
    unless $directory && $report;
sub read_json {
    my ($path) = @_;
    open my $f, '<', $path or die "$path: $!";
    return decode_json(do { local $/; <$f> });
}
my $meta = read_json("$directory/metadata.json");
open my $in, '<', "$directory/summary.jsonl" or die $!;
my (%rows, %storage);
while (<$in>) {
    my $r = decode_json($_);
    die "duplicate case\n" if $rows{"$r->{n}/$r->{mode}"};
    $rows{"$r->{n}/$r->{mode}"} = $r;
    $storage{$r->{n}} ||= $r;
}
my @sizes = sort {$a <=> $b} @{$meta->{sizes}};
my @modes = @{$meta->{modes}};
die "incomplete run\n" unless keys(%rows) == @sizes * @modes;
my $first_pass_met = grep { $_->{difference}{precision_met} } values %rows;
my @followup_notes;
for my $followup (@followups) {
    my $followup_meta = read_json("$followup/metadata.json");
    die "follow-up worker differs\n"
        unless $followup_meta->{worker_sha256} eq $meta->{worker_sha256};
    for my $variant (qw(sc oa)) {
        die "follow-up binary differs\n"
            unless $followup_meta->{variants}{$variant}{binary_sha256}
                eq $meta->{variants}{$variant}{binary_sha256};
    }
    my $settings = $followup_meta->{settings};
    open my $extra, '<', "$followup/summary.jsonl" or die $!;
    while (<$extra>) {
        my $r = decode_json($_);
        my $id = "$r->{n}/$r->{mode}";
        die "unknown follow-up case $id\n" unless $rows{$id};
        $r->{followup} = $followup;
        $rows{$id} = $r;
        push @followup_notes, "$id: at least $settings->{min_samples} pairs; "
            . "pilots of at least $settings->{minimum_pilot_sample_seconds} seconds; "
            . "limits of $settings->{max_samples} pairs or $settings->{max_seconds} seconds; `$followup`.";
    }
}
sub number {
    my $v = shift;
    $v =~ s/\B(?=(\d{3})+(?!\d))/,/g;
    return $v;
}
sub interval {
    my ($v, $scale) = @_;
    return sprintf '[%.3f, %.3f]', $scale * $v->{lower}, $scale * $v->{upper};
}
my @results = values %rows;
my $met = grep { $_->{difference}{precision_met} } @results;
my @counts = sort {$a <=> $b} map { $_->{difference}{total_samples} } @results;
my $total = scalar @results;
open my $out, '>', $report or die $!;
print {$out} <<'INTRO';
# XPerl hash index benchmarks

This compares XPerl's compact ordinary hashes using integer separate chaining
(SC) and open addressing (OA), with independent entry-array growth in both.
Both retain the pointer-based shared string table and the eight-key linear
path. The workloads use nine-byte ASCII string keys and 32-byte values.

INTRO
my $largest = $sizes[-1];
my $largest_storage = $storage{$largest};
my $memory_ratio = $largest_storage->{variants}{oa}{initial}{requested_bytes}
    / $largest_storage->{variants}{sc}{initial}{requested_bytes};
printf {$out} "At %s entries, OA requests %.1f percent %s table storage.\n\n",
    number($largest), abs(100 * ($memory_ratio - 1)), $memory_ratio < 1 ? 'less' : 'more';
print {$out} "Selected paired mean time changes at this size:\n\n";
for my $mode (qw(fetch-random fetch-shared fetch-sequential miss churn)) {
    next unless my $r = $rows{"$largest/$mode"};
    printf {$out} "- %s: %.1f percent %s elapsed time.\n", $mode,
        abs(100 * ($r->{paired_mean_ratio} - 1)), $r->{paired_mean_ratio} < 1 ? 'less' : 'more';
}
print {$out} "\n## Builds and measurement\n\n";
print {$out} "Run started: $meta->{date}. CPU: $meta->{cpu_model}; affinity: CPU $meta->{cpu_affinity}.\n\n";
for my $name (qw(sc oa)) {
    my $v = $meta->{variants}{$name};
    print {$out} uc($name), ": `$v->{commit}`; `$v->{config}{cc}` $v->{config}{gccversion}, `$v->{config}{optimize}`.\n\n";
}
print {$out} <<'METHOD';
XBench controls paired measurements using reported worker-loop durations.
OA is the measured case and SC is its paired baseline. Execution order
alternates. Each pair uses the same hash seed and operation count. Worker
startup, key preparation, warmup, and storage diagnostics are outside timing.
METHOD
my $settings = $meta->{settings};
printf {$out} "Pilots choose a common operation count lasting at least %.3g seconds in both builds.\n\n",
    $settings->{minimum_pilot_sample_seconds};
printf {$out} "The primary estimate is paired mean OA minus SC time per operation. XBench targets\n"
    . "a maximum distance from this mean to either %.1f%% bootstrap bound within %.1f%%\n"
    . "of the SC pilot time. It collects at least %d pairs, with limits of %d pairs\n"
    . "or %g seconds per case. Filtering is %s. XStats supplies the intervals using\n"
    . "%s resamples. Every pilot and measured sample is retained.\n\n",
    100 * $settings->{confidence}, 100 * $settings->{target_difference_fraction_of_sc},
    $settings->{min_samples}, $settings->{max_samples}, $settings->{max_seconds},
    $settings->{filtering}, number($settings->{resamples});
print {$out} "Precision target met: **$met/$total** cases. Measured pairs per case: **$counts[0]–$counts[-1]**.\n\n";
if (@followup_notes) {
    print {$out} "The initial pass met its target in $first_pass_met/$total cases. Longer-batch follow-ups are marked (R):\n\n";
    print {$out} "- $_\n" for @followup_notes;
    print {$out} "\n";
}
print {$out} <<'MEANING';
Precision met describes interval width, not a resolved advantage. A difference
interval containing zero does not establish a direction. Ratios below are
means of paired OA/SC elapsed-time ratios: below one favors OA. These differ
from the ratio of the separately reported per-build means. Intervals describe
observed batch variability on this machine. CPU frequency is uncontrolled,
and bootstrap coverage is affected by correlation and adaptive stopping.

## Initial populated storage

Requested bytes include index metadata, bucket slots, chain links, and the
allocated entry array, including unused capacity. Common HV bodies, key and
value allocations, and allocator rounding are additional. These snapshots
describe an incrementally populated hash before timed warmup; churn snapshots
are retained separately in raw data.

| Entries | SC bytes | OA bytes | OA change | Entry capacity in both | SC/OA index bytes per slot |
| ---: | ---: | ---: | ---: | ---: | ---: |
MEANING
for my $n (@sizes) {
    my $r = $storage{$n};
    my ($a, $b) = map { $r->{variants}{$_}{initial} } qw(sc oa);
    die "entry capacities differ\n" unless $a->{entry_capacity} == $b->{entry_capacity};
    printf {$out} "| %s | %s | %s | %+.1f%% | %s | %s/%s |\n", number($n),
        number($a->{requested_bytes}), number($b->{requested_bytes}),
        100 * ($b->{requested_bytes} / $a->{requested_bytes} - 1),
        number($a->{entry_capacity}), $a->{index_width}, $b->{index_width};
}
print {$out} <<'ALLOCATION';

The eight-entry case uses linear storage and has no bucket index.

At larger sizes, the previous partly coupled OA policy happened to leave less
entry slack at some sampled counts. Independent growth can therefore increase
OA storage relative to that policy. Matching capacities makes the SC/OA
comparison easier to interpret; it does not minimize every allocation.

## Paired mean time ratios

Ratios above one mean OA takes longer. Construction includes destruction of
each newly populated hash. A churn operation deletes and reinserts a key.
Iteration measures each visited entry. Fetches use byte-string queries except
`fetch-shared`, whose query scalars hold shared keys. The query-only control
loops over query lengths without looking up a hash entry.

ALLOCATION
print {$out} '| Entries | ', join(' | ', @modes), " |\n";
print {$out} '| ---: | ', join(' | ', map {'---:'} @modes), " |\n";
for my $n (@sizes) {
    print {$out} '| ', number($n), ' | ', join(' | ', map {
        sprintf '%.3f%s%s', $rows{"$n/$_"}{paired_mean_ratio},
            $rows{"$n/$_"}{difference}{precision_met} ? '' : '*',
            $rows{"$n/$_"}{followup} ? ' (R)' : ''
    } @modes), " |\n";
}
print {$out} "\n";
print {$out} "An asterisk marks a case that stopped without meeting the precision target.\n\n"
    if $met < $total;
print {$out} "## Detailed estimates at ", number($largest), " entries\n\n";
print {$out} "| Operation | SC mean ns/op | OA mean ns/op | OA minus SC ns/op | Difference 95% interval | Pairs | Stop |\n";
print {$out} "| --- | ---: | ---: | ---: | --- | ---: | --- |\n";
for my $mode (@modes) {
    my $r = $rows{"$largest/$mode"};
    my $d = $r->{difference};
    printf {$out} "| %s | %.2f | %.2f | %+.2f | %s | %d | %s%s |\n", $mode,
        1e9 * $r->{variants}{sc}{mean}, 1e9 * $r->{variants}{oa}{mean}, 1e9 * $d->{mean},
        interval($d->{confidence_interval}, 1e9), $d->{total_samples},
        $d->{stop_reason}, $d->{precision_met} ? '' : ' (unmet)';
}
print {$out} <<'REPRODUCE';

## Reproduction and artifacts

Run `planning/scripts/bench-hash-index-xbench.pl` from the SC build with its
core library path, selecting the independent OA build with `--oa`. The
protocol and options are described in [the XBench plan](../xbench.md).

`metadata.json` records source revisions, compiler settings, affinity,
executable hashes, and driver and worker hashes. `raw.jsonl` preserves complete
worker diagnostics, timings, seeds, and phases. `summary.jsonl` preserves each
XBench result, its settings, sample arrays, precision status, and stop reason.

These artifacts and generated figures are in the workspace
`tmp/hash-index-xbench/` directory. The earlier fixed-count screening runs are
in `tmp/hash-index-comparison/` and `tmp/hash-index-independent-comparison/`.
Their paired medians use a different estimator and are kept separate.
REPRODUCE
close $out;
open my $plot, '>', "$directory/plot.tsv" or die $!;
for my $n (@sizes) {
    my $r = $storage{$n};
    my ($a, $b) = map { $r->{variants}{$_}{initial}{requested_bytes} } qw(sc oa);
    my @values = ($n, $b / $a, $a, $b);
    for my $mode (qw(fetch-random fetch-shared churn construct miss)) {
        my $case = $rows{"$n/$mode"};
        push @values, $case->{paired_mean_ratio}, @{$case->{ratio_interval}}{qw(lower upper)};
    }
    print {$plot} join("\t", @values), "\n";
}
close $plot;
