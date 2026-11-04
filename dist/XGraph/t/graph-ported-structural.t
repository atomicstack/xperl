use strict;
use warnings;

# Provenance: adapted from the simple/multiple/loop distinctions in Graph
# 0.9735 (7d3f3ea), t/16_edges.t, t/26_multiedged.t, and t/66_simple.t.
# XGraph has no Graph multiedge IDs.  Its relationship labels are the explicit
# mathematical distinction between parallel edge tuples.

use Test::More;
use XGraph;

my $g = XGraph->new;
my ($a, $b, $c) = map { $g->add_vertex($_) } qw(a b c);

$g->add_edge_by_ids($a, $b);
my $duplicate = eval { $g->add_edge_by_ids($a, $b); 1 };
ok(!$duplicate, 'the same unlabelled edge cannot be inserted twice');
like($@, qr/EDGE_EXISTS/, 'duplicate edge reports the planned error code');

$g->add_edge_by_ids($a, $b, 'parallel');
$g->add_edge_by_ids($a, $a);
is($g->edge_count, 3, 'labels distinguish parallel relationships and loops');
is($g->out_degree($a), 3, 'out-degree counts every relationship tuple');
is($g->in_degree($a), 1, 'the self-loop contributes one incoming edge');
ok($g->has_edge_by_ids($a, $b, 'parallel'),
   'the labelled parallel relationship is queryable');
ok($g->has_edge_by_ids($a, $a), 'the self-loop is queryable');

ok(!$g->is_tree, 'loops and parallel relationships prevent tree status');
ok(!$g->is_arborescence, 'loops and parallel relationships prevent arborescence');

$g->delete_edge_by_ids($a, $a);
$g->delete_edge_by_ids($a, $b, 'parallel');
$g->add_edge_by_ids($b, $c);
ok($g->is_tree, 'a connected V-1 edge graph is a tree');
ok($g->is_arborescence, 'a directed chain is an arborescence');
is($g->arborescence_root, $a, 'the chain source is its arborescence root');

$g->add_edge_by_ids($c, $a, 'back');
ok(!$g->is_tree, 'adding a cycle breaks tree status');
ok(!$g->is_arborescence, 'adding a cycle breaks arborescence status');

done_testing;
