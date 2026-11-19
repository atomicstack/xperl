#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use SCCReference qw(parameters edge_specs build_graph labels);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

my ($vertices, $edges, $iterations) = parameters();
my $graph = build_graph($vertices, edge_specs($vertices, $edges));
my $start = clock_gettime(CLOCK_MONOTONIC);
my $count;
for (1 .. $iterations) {
    ($count) = labels($graph);
}
my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $start;
printf "perl_reference=kosaraju vertices=%d edges=%d iterations=%d\n", $vertices, $edges, $iterations;
printf "scc_perl_reference %.6f seconds (%d components)\n", $elapsed, $count;
