use strict;
use warnings;

# Provenance: ported from the directed transitive-closure cases in Graph
# 0.9735 (7d3f3ea), t/72_transitive.t, using the larger Sedgewick SCC graph
# from t/63_scc.t.  The reference matrix below is intentionally independent
# of XGraph's traversal implementation.  Graph's closure object and weighted
# path attributes are replaced by explicit boolean reachability and shortest
# unweighted paths.

use Test::More;
use XGraph;

my $g = XGraph->new;
my %id;
$id{$_} = $g->add_vertex("$_") for 0 .. 12;

my @edges = (
    [0, 1], [0, 5], [0, 6], [2, 0], [2, 3], [3, 2], [3, 5],
    [4, 2], [4, 3], [4, 11], [5, 4], [6, 4], [6, 9], [7, 6],
    [7, 8], [8, 7], [8, 9], [9, 10], [9, 11], [10, 12], [11, 12],
    [12, 9],
);
$g->add_edge_by_ids($id{$_->[0]}, $id{$_->[1]}) for @edges;

my @vertices = map $id{$_}, 0 .. 12;
my %out = map { $_ => [] } @vertices;
my %in  = map { $_ => [] } @vertices;
for my $edge (@edges) {
    push @{ $out{ $id{ $edge->[0] } } }, $id{ $edge->[1] };
    push @{ $in{ $id{ $edge->[1] } } }, $id{ $edge->[0] };
}

# Compute transitive reachability without using XGraph's algorithms.  The
# diagonal is true only when a non-empty cycle returns to the vertex.
my %reachable;
for my $from (@vertices) {
    for my $to (@{ $out{$from} }) {
        $reachable{$from}{$to} = 1;
    }
}
for my $via (@vertices) {
    for my $from (@vertices) {
        next unless $reachable{$from}{$via};
        for my $to (@vertices) {
            $reachable{$from}{$to} = 1 if $reachable{$via}{$to};
        }
    }
}

sub distances_from {
    my ($start) = @_;
    my %distance;
    my @queue;
    push @queue, $_ for @{ $out{$start} };
    $distance{$_} = 1 for @{ $out{$start} };
    my $head = 0;
    while ($head < @queue) {
        my $current = $queue[$head++];
        my $next_distance = $distance{$current} + 1;
        for my $next (@{ $out{$current} }) {
            next if exists $distance{$next};
            $distance{$next} = $next_distance;
            push @queue, $next;
        }
    }
    return \%distance;
}

for my $from (@vertices) {
    my $distance = distances_from($from);
    my @expected_descendants = grep {
        $_ == $from || $reachable{$from}{$_}
    } @vertices;
    my @expected_strict = grep {
        $_ != $from || $reachable{$from}{$_}
    } grep { $reachable{$from}{$_} } @vertices;
    my @expected_ancestors = grep {
        $_ == $from || $reachable{$_}{$from}
    } @vertices;
    my @expected_strict_ancestors = grep {
        $_ != $from || $reachable{$_}{$from}
    } grep { $reachable{$_}{$from} } @vertices;

    is($g->has_path($from, $_) ? 1 : 0,
       $reachable{$from}{$_} ? 1 : 0,
       "reachability matrix $from -> $_") for @vertices;
    is_deeply($g->descendants($from), \@expected_descendants,
              "descendants for $from");
    is_deeply($g->strict_descendants($from), \@expected_strict,
              "strict descendants for $from");
    is_deeply($g->ancestors($from), \@expected_ancestors,
              "ancestors for $from");
    is_deeply($g->strict_ancestors($from), \@expected_strict_ancestors,
              "strict ancestors for $from");

    for my $to (@vertices) {
        my $path = $g->path($from, $to);
        my $shortest = $g->shortest_path($from, $to);
        if (!$reachable{$from}{$to}) {
            ok(!defined $path, "no path $from -> $to");
            ok(!defined $shortest, "no shortest path $from -> $to");
            next;
        }
        ok(ref($path) eq 'ARRAY', "path $from -> $to is an array");
        ok(ref($shortest) eq 'ARRAY',
           "shortest path $from -> $to is an array");
        is($path->[0], $from, "path $from -> $to starts correctly");
        is($path->[-1], $to, "path $from -> $to ends correctly");
        is($shortest->[0], $from,
           "shortest path $from -> $to starts correctly");
        is($shortest->[-1], $to,
           "shortest path $from -> $to ends correctly");
        for my $result ($path, $shortest) {
            ok((!grep {
                !$g->has_edge_by_ids($result->[$_], $result->[$_ + 1])
            } 0 .. $#$result - 1),
               "path $from -> $to follows live edges");
        }
        is(@$shortest - 1, $distance->{$to},
           "shortest path $from -> $to has minimum length");
    }
}

done_testing;
