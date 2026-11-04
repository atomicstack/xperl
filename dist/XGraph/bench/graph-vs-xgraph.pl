#!/usr/bin/env perl

use 5.036003;
use strict;
use warnings;
use FindBin qw($Bin);
use Time::HiRes qw(time);

use lib "$Bin/../blib/lib", "$Bin/../blib/arch", "$Bin/../../Graph/lib";

use Graph;
use XGraph;

my $vertex_count = $ENV{XGRAPH_BENCH_VERTICES} // 2_000;
my $edge_count   = $ENV{XGRAPH_BENCH_EDGES}    // 10_000;
my $query_count  = $ENV{XGRAPH_BENCH_QUERIES}  // 1_000;
my $iterations   = $ENV{XGRAPH_BENCH_ITERATIONS} // 5;

die "XGRAPH_BENCH_VERTICES must be at least 2\n"
    unless $vertex_count >= 2;
die "XGRAPH_BENCH_EDGES must be between 0 and V*(V-1)/2\n"
    unless $edge_count >= 0
        && $edge_count <= $vertex_count * ($vertex_count - 1) / 2;
die "XGRAPH_BENCH_QUERIES and XGRAPH_BENCH_ITERATIONS must be positive\n"
    unless $query_count > 0 && $iterations > 0;

sub edge_specs {
    my ($vertices, $wanted) = @_;
    my @edges;
    my %seen;

    # Keep every edge from the lower ID to the higher ID.  This gives both
    # implementations the same DAG for the topological-sort benchmark.
    for my $from (1 .. $vertices - 1) {
        last if @edges == $wanted;
        my $to = $from + 1;
        push @edges, [$from, $to];
        $seen{"$from,$to"} = 1;
    }

    # A fixed LCG gives a reproducible sparse graph without requiring a
    # benchmark dependency or paying random-number setup inside a timed run.
    my $state = 0x13579bdf;
    while (@edges < $wanted) {
        $state = (1664525 * $state + 1013904223) & 0xffffffff;
        my $from = 1 + ($state % ($vertices - 1));
        $state = (1664525 * $state + 1013904223) & 0xffffffff;
        my $to = $from + 1 + ($state % ($vertices - $from));
        next if $seen{"$from,$to"}++;
        push @edges, [$from, $to];
    }
    return \@edges;
}

sub query_pairs {
    my ($vertices, $count) = @_;
    my @queries;
    my $state = 0x2468ace1;
    for (1 .. $count) {
        $state = (1103515245 * $state + 12345) & 0x7fffffff;
        my $from = 1 + ($state % $vertices);
        $state = (1103515245 * $state + 12345) & 0x7fffffff;
        my $to = 1 + ($state % $vertices);
        push @queries, [$from, $to];
    }
    return \@queries;
}

sub scc_edge_specs {
    my ($vertices, $base_edges) = @_;
    my @edges = @$base_edges;
    my %seen = map { ("$_->[0],$_->[1]" => 1) } @edges;
    my $block_size = 50;

    # Reverse the edges inside each block and close the block into a cycle.
    # The result has many non-trivial SCCs while retaining the same vertices.
    for (my $start = 1; $start <= $vertices; $start += $block_size) {
        my $end = $start + $block_size - 1;
        $end = $vertices if $end > $vertices;
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

my $edges   = edge_specs($vertex_count, $edge_count);
my $queries = query_pairs($vertex_count, $query_count);
my $scc_edges = scc_edge_specs($vertex_count, $edges);

sub make_xgraph {
    my ($edge_list) = @_;
    $edge_list //= $edges;
    my $graph = XGraph->new;
    $graph->add_vertex for 1 .. $vertex_count;
    $graph->add_edge_by_ids(@$_) for @$edge_list;
    return $graph;
}

sub make_graph {
    my ($edge_list) = @_;
    $edge_list //= $edges;
    my $graph = Graph->new(directed => 1);
    $graph->add_vertex($_) for 1 .. $vertex_count;
    $graph->add_edge(@$_) for @$edge_list;
    return $graph;
}

my $xgraph = make_xgraph($edges);
my $graph  = make_graph($edges);
my $xgraph_scc = make_xgraph($scc_edges);
my $graph_scc  = make_graph($scc_edges);
my $sink = 0;

sub elapsed {
    my ($code) = @_;
    my $start = time;
    $code->() for 1 .. $iterations;
    return time - $start;
}

sub report {
    my ($name, $xcode, $gcode) = @_;
    my $xseconds = elapsed($xcode);
    my $gseconds = elapsed($gcode);
    my $ratio = $xseconds ? $gseconds / $xseconds : 0;
    printf "%-22s %11.6f %11.6f %8.2fx\n",
        $name, $xseconds, $gseconds, $ratio;
}

print "vertices=$vertex_count edges=$edge_count ",
      "queries=$query_count iterations=$iterations\n";
print "The ratio is Graph seconds divided by XGraph seconds.\n\n";
printf "%-22s %11s %11s %8s\n",
    'operation', 'XGraph', 'Graph', 'Graph/XGraph';
printf "%-22s %11s %11s %8s\n",
    '-' x 22, '-' x 11, '-' x 11, '-' x 8;

report('build',
    sub { make_xgraph },
    sub { make_graph },
);

report('has_edge',
    sub {
        $sink += $xgraph->has_edge_by_ids(@$_) for @$queries;
    },
    sub {
        $sink += $graph->has_edge(@$_) for @$queries;
    },
);

report('out_neighbors',
    sub {
        $sink += scalar @{ $xgraph->out_neighbors($_->[0]) }
            for @$queries;
    },
    sub {
        $sink += scalar $graph->successors($_->[0])
            for @$queries;
    },
);

my $reach_queries = @$queries < 100 ? $queries : [@$queries[0 .. 99]];
report('all_successors',
    sub {
        $sink += scalar @{ $xgraph->descendants($_->[0]) }
            for @$reach_queries;
    },
    sub {
        $sink += scalar $graph->all_successors($_->[0])
            for @$reach_queries;
    },
);

report('edges',
    sub {
        $sink += scalar @{ $xgraph->edges };
    },
    sub {
        $sink += scalar $graph->edges;
    },
);

report('topological_sort',
    sub {
        $sink += scalar @{ $xgraph->topological_sort };
    },
    sub {
        $sink += scalar $graph->topological_sort;
    },
);

report('scc_kosaraju',
    sub {
        $sink += scalar @{ $xgraph_scc->strongly_connected_components };
    },
    sub {
        $graph_scc->strong_connectivity_clear_cache;
        $sink += scalar $graph_scc->strongly_connected_components;
    },
);

report('scc_tarjan',
    sub {
        $sink += scalar @{ $xgraph_scc->strongly_connected_components_tarjan };
    },
    sub {
        $graph_scc->strong_connectivity_clear_cache;
        $sink += scalar $graph_scc->strongly_connected_components;
    },
);

report('scc_pearce',
    sub {
        $sink += scalar @{ $xgraph_scc->strongly_connected_components_pearce };
    },
    sub {
        $graph_scc->strong_connectivity_clear_cache;
        $sink += scalar $graph_scc->strongly_connected_components;
    },
);

report('scc_tarjan_zwick',
    sub {
        $sink += scalar @{ $xgraph_scc->strongly_connected_components_tarjan_zwick };
    },
    sub {
        $graph_scc->strong_connectivity_clear_cache;
        $sink += scalar $graph_scc->strongly_connected_components;
    },
);

die "benchmark sink unexpectedly vanished\n" unless defined $sink;
