#!/usr/bin/perl

use strict;
use warnings;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

my ($mode, $n, $rounds, $trial) = @ARGV;
die "usage: bench-strtab.pl lastowner|secondowner N ROUNDS TRIAL\n"
    unless defined $trial && ($mode eq 'lastowner' || $mode eq 'secondowner')
        && $n =~ /^\d+$/ && $n > 0 && $rounds =~ /^\d+$/ && $rounds > 0;

my $stats_available = eval { require XS::APItest; 1 }
    && defined &XS::APItest::Hash::shared_key_storage_info;
my @initial = table_snapshot();
my %keeper;
my $keeper_setup = 0;
if ($mode eq 'secondowner') {
    my $start = clock_gettime(CLOCK_MONOTONIC);
    for my $i (0 .. $n - 1) {
        my $key = "strtab-bench-$trial-key-$i";
        $keeper{$key} = $i;
    }
    $keeper_setup = clock_gettime(CLOCK_MONOTONIC) - $start;
    die "keeper setup failed\n" unless scalar(keys %keeper) == $n;
}

my @rows;
my $checksum = 0;
my %target;
for my $round (0 .. $rounds - 1) {
    my @before = table_snapshot();
    my $fill_start = clock_gettime(CLOCK_MONOTONIC);
    if ($mode eq 'lastowner') {
        for my $i (0 .. $n - 1) {
            my $key = "strtab-bench-$trial-key-$i";
            $target{$key} = $i;
            $checksum += $i;
        }
    }
    else {
        keys %keeper;
        my $i = 0;
        while (my ($key, $value) = each %keeper) {
            $target{$key} = $i;
            $checksum += $i++;
        }
        die "keeper iteration failed in round $round\n" unless $i == $n;
    }
    my $fill_time = clock_gettime(CLOCK_MONOTONIC) - $fill_start;
    die "target fill failed in round $round\n" unless scalar(keys %target) == $n;
    my @filled = table_snapshot();
    my $rss_filled = rss_kib();

    my $delete_start = clock_gettime(CLOCK_MONOTONIC);
    undef %target;
    my $delete_time = clock_gettime(CLOCK_MONOTONIC) - $delete_start;
    die "target not empty after clear in round $round\n" if keys %target;
    my @cleared = table_snapshot();
    my $rss_cleared = rss_kib();
    push @rows, [$round + 1, \@before, \@filled, \@cleared,
                 $fill_time, $delete_time, $rss_filled, $rss_cleared];
}

my $expected = $rounds * $n * ($n - 1) / 2;
die "checksum mismatch\n" unless $checksum == $expected;
my @after = table_snapshot();
print join("\t", "META", $mode, $n, $rounds, $trial,
           sprintf("%.9f", $keeper_setup), $stats_available ? 1 : 0,
           @initial, @after), "\n";
for my $row (@rows) {
    my ($round, $before, $filled, $cleared, $fill_time, $delete_time,
        $rss_filled, $rss_cleared) = @$row;
    print join("\t", "ROUND", $round,
               sprintf("%.9f", $fill_time), sprintf("%.9f", $delete_time),
               $n, $mode eq 'lastowner' ? $n : 0,
               @$before, @$filled, @$cleared, $rss_filled, $rss_cleared), "\n";
}
print join("\t", "CHECK", $checksum, scalar(keys %target),
           $mode eq 'secondowner' ? scalar(keys %keeper) : 0), "\n";

sub table_snapshot {
    return ('') x 8 unless $stats_available;
    my $info = XS::APItest::Hash::shared_key_storage_info();
    my ($capacity, $live, $tombstones, $slot_size, $metadata,
        $probe_max, $probe_total) = @$info;
    return ($live, $capacity, $tombstones, $slot_size, $metadata,
            $metadata + $capacity * $slot_size, $probe_max, $probe_total);
}

sub rss_kib {
    return '' unless open my $status, '<', '/proc/self/status';
    my $rss = '';
    while (<$status>) {
        $rss = $1 if /^VmRSS:\s+(\d+)/;
    }
    close $status;
    return $rss;
}
