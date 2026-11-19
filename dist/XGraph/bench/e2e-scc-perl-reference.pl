#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use SCCReference qw(parameters edge_specs build_graph labels grouped_components);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

my ($vertices, $wanted, $iterations) = parameters();
my $edges = edge_specs($vertices, $wanted);
my $start = clock_gettime(CLOCK_MONOTONIC);
my $sink = 0;
for (1 .. $iterations) {
    my $graph = build_graph($vertices, $edges);
    my ($count, $labels) = labels($graph);
    my $components = grouped_components($count, $labels);
    $sink += @$components;
}
my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $start;
printf "perl_reference=kosaraju vertices=%d scc_edges=%d iterations=%d components=%d total=%.6f per_iteration=%.6f\n",
    $vertices, scalar(@$edges), $iterations, $sink, $elapsed, $elapsed / $iterations;
