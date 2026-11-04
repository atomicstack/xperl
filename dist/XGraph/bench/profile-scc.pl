#!/usr/bin/env perl

use 5.036003;
use strict;
use warnings;
use FindBin qw($Bin);

use lib "$Bin/../blib/lib", "$Bin/../blib/arch";

use XGraph;

my $vertices = $ENV{XGRAPH_BENCH_VERTICES} // 2_000;
my $wanted   = $ENV{XGRAPH_BENCH_EDGES}    // 10_000;
my $runs     = $ENV{XGRAPH_PROFILE_ITERATIONS} // 100;
my $method   = $ENV{XGRAPH_PROFILE_METHOD}
    // 'strongly_connected_components_tarjan_zwick';

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
my $graph = XGraph->new;
$graph->add_vertex for 1 .. $vertices;
$graph->add_edge_by_ids(@$_) for @$edges;

my $sink = 0;
$sink += scalar @{ $graph->$method } for 1 .. $runs;
print "$method runs=$runs components=$sink\n";
