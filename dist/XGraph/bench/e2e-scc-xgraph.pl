#!/usr/bin/env perl

use 5.036003;
use strict;
use warnings;
use FindBin qw($Bin);
use Time::HiRes qw(time);

use lib "$Bin/../blib/lib", "$Bin/../blib/arch";

use XGraph;

my $vertices = $ENV{XGRAPH_BENCH_VERTICES} // 2_000;
my $wanted   = $ENV{XGRAPH_BENCH_EDGES}    // 10_000;
my $runs     = $ENV{XGRAPH_BENCH_ITERATIONS} // 5;
my $method   = $ENV{XGRAPH_BENCH_METHOD}
    // 'strongly_connected_components_tarjan_zwick';

die "XGRAPH_BENCH_VERTICES must be at least 2\n" unless $vertices >= 2;
die "XGRAPH_BENCH_EDGES is out of range\n"
    unless $wanted >= 0 && $wanted <= $vertices * ($vertices - 1) / 2;
die "XGRAPH_BENCH_ITERATIONS must be positive\n" unless $runs > 0;

sub edge_specs {
    my ($count, $wanted_edges) = @_;
    my (@edges, %seen);
    for my $from (1 .. $count - 1) {
        last if @edges == $wanted_edges;
        my $to = $from + 1;
        push @edges, [$from, $to];
        $seen{"$from,$to"} = 1;
    }
    my $state = 0x13579bdf;
    while (@edges < $wanted_edges) {
        $state = (1664525 * $state + 1013904223) & 0xffffffff;
        my $from = 1 + ($state % ($count - 1));
        $state = (1664525 * $state + 1013904223) & 0xffffffff;
        my $to = $from + 1 + ($state % ($count - $from));
        next if $seen{"$from,$to"}++;
        push @edges, [$from, $to];
    }
    return \@edges;
}

sub scc_edge_specs {
    my ($count, $base) = @_;
    my @edges = @$base;
    my %seen = map { ("$_->[0],$_->[1]" => 1) } @edges;
    for (my $start = 1; $start <= $count; $start += 50) {
        my $end = $start + 49;
        $end = $count if $end > $count;
        for my $from ($start .. $end - 1) {
            my $to = $from + 1;
            next if $seen{"$to,$from"}++;
            push @edges, [$to, $from];
        }
        next if $start == $end || $seen{"$end,$start"}++;
        push @edges, [$end, $start];
    }
    return \@edges;
}

my $edges = scc_edge_specs($vertices, edge_specs($vertices, $wanted));
my @flat_edges = map { @$_ } @$edges;
my $start = time;
my $sink = 0;

for (1 .. $runs) {
    my $graph = XGraph->from_edges(
        vertex_mode => 'id',
        edges       => \@flat_edges,
    );

    my $components = $graph->$method;
    $sink += scalar @$components;

    # Include destruction of the high-level result and graph in the measured
    # end-to-end operation, rather than retaining work across iterations.
    undef $components;
    undef $graph;
}

my $elapsed = time - $start;
printf "xgraph_method=%s vertices=%d scc_edges=%d iterations=%d "
    . "components=%d total=%.6f per_iteration=%.6f\n",
    $method, $vertices, scalar(@$edges), $runs, $sink,
    $elapsed, $elapsed / $runs;
