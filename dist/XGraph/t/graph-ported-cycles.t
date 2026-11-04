use strict;
use warnings;

# Provenance: ported from Graph 0.9735 (7d3f3ea), primarily t/45_add_cycle.t
# and the cycle-related cases in t/59_dfs.t.  Graph's explicit cycle-builder
# and traversal-object APIs were replaced with XGraph's cycle queries.

use Test::More;
use XGraph;

my $g = XGraph->new;
my %id;
$id{$_} = $g->add_vertex($_) for qw(a b c d e);
$g->add_edge_by_ids($id{a}, $id{b});
$g->add_edge_by_ids($id{b}, $id{c});
$g->add_edge_by_ids($id{c}, $id{a});
$g->add_edge_by_ids($id{d}, $id{d});
$g->add_edge_by_ids($id{d}, $id{e});

ok(!$g->is_acyclic, 'a graph with a cycle is not acyclic');
ok(!$g->topological_sort, 'a cyclic graph has no topological ordering');
is_deeply($g->loop_vertices, [$id{d}], 'loop_vertices finds the self-loop');

sub check_cycle {
    my ($cycle, $label) = @_;
    ok(ref($cycle) eq 'ARRAY' && @$cycle >= 2, "$label has at least one edge");
    is($cycle->[0], $cycle->[-1], "$label is closed");
    for my $i (0 .. $#$cycle - 1) {
        ok($g->has_edge_by_ids($cycle->[$i], $cycle->[$i + 1]),
           "$label follows a live edge at step $i");
    }
}

my $cycle = $g->cycle;
check_cycle($cycle, 'cycle');
is_deeply($g->shortest_cycle, [$id{d}, $id{d}],
          'the self-loop is the shortest cycle');

my $dag = XGraph->new(acyclic => 1);
my ($x, $y, $z) = map { $dag->add_vertex($_) } qw(x y z);
$dag->add_edge_by_ids($x, $y);
$dag->add_edge_by_ids($y, $z);
ok($dag->is_acyclic, 'the DAG remains acyclic');
is_deeply($dag->topological_sort, [$x, $y, $z],
          'the DAG has a topological order');
my $error = eval { $dag->add_edge_by_ids($z, $x); 1 };
ok(!$error, 'acyclic insertion rejects a cycle');
like($@, qr/CYCLE_REJECTED/, 'the rejected cycle has the planned error code');
is($dag->edge_count, 2, 'cycle rejection does not partially mutate the DAG');

done_testing;
