use strict;
use warnings;

# Provenance: ported from the directed vertex-induced cases in Graph 0.9735
# (7d3f3ea), t/85_subgraph.t.  Graph's optional source/destination cut and
# radius variants were omitted because XGraph exposes induced_subgraph.

use Test::More;
use XGraph;

my $g = XGraph->new;
my %id;
$id{$_} = $g->add_vertex($_) for qw(a b c d e f g);
for my $edge ([qw(a b)], [qw(a c)], [qw(b d)], [qw(b e)],
              [qw(c f)], [qw(c g)]) {
    $g->add_edge_by_ids($id{$edge->[0]}, $id{$edge->[1]});
}

my $sub = $g->induced_subgraph([$id{a}, $id{b}, $id{c}]);
is_deeply($sub->vertex_ids, [$id{a}, $id{b}, $id{c}],
          'the induced graph preserves the selected vertex IDs');
is($sub->vertex_name_by_id($id{a}), 'a',
   'the induced graph preserves vertex names');
is_deeply($sub->edges,
          [[$id{a}, $id{b}, undef], [$id{a}, $id{c}, undef]],
          'only edges with both endpoints selected are retained');
ok(!$sub->has_vertex_id($id{d}), 'an unselected endpoint is absent');
is($sub->vertex_count, 3, 'the induced graph contains only selected vertices');

ok($sub->delete_edge_by_ids($id{a}, $id{b}),
   'the induced graph is independently mutable');
ok($g->has_edge_by_ids($id{a}, $id{b}),
   'mutating the induced graph does not mutate the source');
ok(!$sub->has_edge_by_ids($id{a}, $id{b}),
   'the induced graph reflects its own deletion');

my $isolated = $g->induced_subgraph([$id{a}, $id{e}]);
is_deeply($isolated->vertex_ids, [$id{a}, $id{e}],
          'an induced graph can contain disconnected selected vertices');
is_deeply($isolated->edges, [], 'no unselected edge is imported');

done_testing;
