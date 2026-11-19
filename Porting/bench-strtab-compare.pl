#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use BenchUtils qw(absolute sha256 perl_info source_info platform_info write_json
    run rng shuffle median value_range parse_sizes csv_line);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time);

my %options = (sizes => '100000,1000000', 'rounds-100k' => 20,
    'rounds-1m' => 5, trials => 5, seed => '0x123456789abcdef0');
my $help;
GetOptions(\%options, 'baseline=s', 'candidate=s', 'lib-baseline=s',
    'lib-candidate=s', 'outdir=s', 'sizes=s', 'rounds-100k=i', 'rounds-1m=i',
    'trials=i', 'seed=s', 'help' => \$help) or die "Invalid options\n";
if ($help) {
    print "Usage: $0 --baseline PERL --candidate PERL --outdir DIR [--sizes LIST]\n";
    exit;
}
die "Unexpected arguments: @ARGV\n" if @ARGV;
die "--baseline, --candidate and --outdir are required\n"
    unless $options{baseline} && $options{candidate} && $options{outdir};
die "Trials and round counts must be positive\n"
    if grep { $options{$_} < 1 } qw(trials rounds-100k rounds-1m);
my @sizes = parse_sizes($options{sizes}, 1);
my $out = absolute($options{outdir});
make_path($out);
my (%builds, %libs);
for my $build (qw(baseline candidate)) {
    $builds{$build} = absolute($options{$build});
    $libs{$build} = absolute($options{"lib-$build"} // dirname($builds{$build}).'/lib');
    die "Missing executable or library directory for $build\n"
        unless -x $builds{$build} && -d $libs{$build};
}
my $worker = "$FindBin::Bin/bench-strtab.pl";
write_json("$out/metadata.json", {
    baseline => $builds{baseline}, candidate => $builds{candidate},
    lib_baseline => $libs{baseline}, lib_candidate => $libs{candidate},
    worker => $worker, worker_sha256 => sha256($worker),
    driver => absolute(__FILE__), driver_sha256 => sha256(__FILE__),
    helper_sha256 => sha256("$FindBin::Bin/BenchUtils.pm"),
    baseline_sha256 => sha256($builds{baseline}),
    candidate_sha256 => sha256($builds{candidate}),
    baseline_perl_config => perl_info($builds{baseline}, $libs{baseline}),
    candidate_perl_config => perl_info($builds{candidate}, $libs{candidate}),
    repository => source_info("$FindBin::Bin/.."), %{platform_info()},
    sizes => \@sizes, rounds_100k => $options{'rounds-100k'},
    rounds_1m => $options{'rounds-1m'}, trials => $options{trials}, seed => $options{seed},
    modes => [qw(lastowner secondowner)], key_pattern => 'strtab-bench-TRIAL-key-INDEX',
    timed_regions => ['target hash fill', 'undef %target teardown'],
    full_cycle_average => 'mean of (fill + clear) ns per inserted key across all process rounds',
    statistics => 'PL_strtab slots and requested index bytes sampled outside timers; RSS is whole-process',
    started_unix => time,
});
my @stats = qw(live capacity tombstones slot_size metadata_bytes index_requested_bytes probe_max probe_total);
my @columns = qw(trial order build mode n round fill_s teardown_s fill_ns_per_key
    teardown_ns_per_key unique_hek_allocations rss_after_fill_kib rss_after_clear_kib);
for my $stage (qw(before_fill after_fill after_clear)) {
    push @columns, map { "${stage}_$_" } @stats;
}
open my $raw, '>:raw', "$out/raw.csv" or die "$out/raw.csv: $!\n";
$raw->autoflush(1);
print {$raw} csv_line(@columns);
my $state = rng(20261103);
my @rows;
for my $trial (1 .. $options{trials}) {
    for my $n (@sizes) {
        my $rounds = $options{$n <= 100000 ? 'rounds-100k' : 'rounds-1m'};
        for my $mode (qw(lastowner secondowner)) {
            my $rank = 0;
            for my $build (shuffle($state, qw(baseline candidate))) {
                my $result = run([$builds{$build}, "-I$libs{$build}", $worker,
                    $mode, $n, $rounds, $trial],
                    env => {PERL_HASH_SEED => $options{seed}, PERL_PERTURB_KEYS => '0'});
                my @lines = split /\r?\n/, $result->{stdout};
                my @meta = split /\t/, shift(@lines) // '', -1;
                my @check = split /\t/, pop(@lines) // '', -1;
                die "Unexpected metadata from $build\n"
                    unless @meta == 23 && $meta[0] eq 'META' && $meta[1] eq $mode
                        && $meta[2] == $n && $meta[3] == $rounds;
                die "Worker checksum failed for $build/$mode/$n\n"
                    unless @check == 4 && $check[0] eq 'CHECK'
                        && $check[1] == $rounds * $n * ($n - 1) / 2 && !$check[2]
                        && ($mode ne 'secondowner' || $check[3] == $n);
                die "Incomplete round output\n" unless @lines == $rounds;
                my $expected_round = 1;
                for my $line (@lines) {
                    my @parts = split /\t/, $line, -1;
                    die "Unexpected round record\n"
                        unless @parts == 32 && $parts[0] eq 'ROUND'
                            && $parts[1] == $expected_round++;
                    my %row = (trial => $trial, order => $rank, build => $build,
                        mode => $mode, n => $n, round => 0 + $parts[1],
                        fill_s => 0 + $parts[2], teardown_s => 0 + $parts[3],
                        fill_ns_per_key => $parts[2] * 1e9 / $n,
                        teardown_ns_per_key => $parts[3] * 1e9 / $n,
                        unique_hek_allocations => $mode eq 'lastowner' ? $n : 0,
                        rss_after_fill_kib => $parts[30], rss_after_clear_kib => $parts[31]);
                    for my $stage (0 .. 2) {
                        my $name = (qw(before_fill after_fill after_clear))[$stage];
                        @row{map { "${name}_$_" } @stats} = @parts[6 + 8*$stage .. 13 + 8*$stage];
                    }
                    print {$raw} csv_line(@row{@columns}) or die "Cannot write raw CSV: $!\n";
                    push @rows, \%row;
                }
                ++$rank;
            }
        }
    }
}
close $raw or die "Cannot close raw CSV: $!\n";

my @summary;
for my $n (@sizes) {
    for my $mode (qw(lastowner secondowner)) {
        for my $build (qw(baseline candidate)) {
            my @group = grep { $_->{n} == $n && $_->{mode} eq $mode && $_->{build} eq $build } @rows;
            for my $phase (qw(first_round reused_rounds)) {
                my @selected = grep { ($_->{round} == 1) == ($phase eq 'first_round') } @group;
                next unless @selected;
                my %item = (n => $n, mode => $mode, build => $build, phase => $phase);
                for my $part (qw(fill teardown)) {
                    my @values = map { $_->{"${part}_ns_per_key"} } @selected;
                    $item{"${part}_median_ns_per_key"} = median(@values);
                    $item{"${part}_range_ns_per_key"} = value_range(@values);
                }
                for my $stage (qw(after_fill after_clear)) {
                    for my $stat (qw(capacity tombstones live)) {
                        my $field = "${stage}_$stat";
                        my @values = map { 0 + $_->{$field} } grep { $_->{$field} ne '' } @selected;
                        $item{"${field}_median"} = median(@values) if @values;
                    }
                }
                push @summary, \%item;
            }
            # Average complete cycles within each process before comparing
            # trials. Individual fill/clear rounds are not independent samples.
            my %trials;
            push @{$trials{$_->{trial}}}, $_ for @group;
            my @cycles;
            for my $rows (values %trials) {
                my ($seconds, $keys) = (0, 0);
                for my $row (@$rows) {
                    $seconds += $row->{fill_s} + $row->{teardown_s};
                    $keys += $row->{n};
                }
                push @cycles, $seconds * 1e9 / $keys;
            }
            my $item = {n => $n, mode => $mode, build => $build,
                phase => 'full_cycle_per_trial_average', trials => scalar @cycles,
                median_ns_per_key => median(@cycles), range_ns_per_key => value_range(@cycles)};
            push @summary, $item;
            printf "N=%d %s %s full-cycle median %.1f ns/key range %.1f..%.1f\n",
                $n, $mode, $build, $item->{median_ns_per_key}, @{$item->{range_ns_per_key}};
        }
    }
}
write_json("$out/summary.json", \@summary);
