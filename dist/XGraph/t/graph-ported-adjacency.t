use strict;
use warnings;

# Provenance: ported from Graph 0.9735 (7d3f3ea), primarily t/16_edges.t,
# t/39_edges_at.t, t/40_edges_from.t, t/41_edges_to.t, t/56_neighbourhood.t,
# and t/57_degree.t.
# Graph's edge stringification and undirected cases were replaced with
# explicit XGraph edge tuples and incoming/outgoing adjacency queries.

use Test::More;
use XGraph;

my $g = XGraph->new;
my %id;
$id{$_} = $g->add_vertex($_) for qw(a b c d e f);

sub tuples {
    my ($edges) = @_;
    return [ map { [ @$_ ] } @$edges ];
}

$g->add_edge_by_ids($id{a}, $id{a});
$g->add_edge_by_ids($id{a}, $id{b});
$g->add_edge_by_ids($id{a}, $id{c});
$g->add_edge_by_ids($id{b}, $id{d});
$g->add_edge_by_ids($id{e}, $id{d});

is($g->edge_count, 5, 'the directed edge count matches the source graph');
is_deeply(tuples($g->out_edges($id{a})),
          [[$id{a}, $id{a}, undef],
           [$id{a}, $id{b}, undef],
           [$id{a}, $id{c}, undef]],
          'outgoing edges are sorted by destination');
is_deeply(tuples($g->in_edges($id{d})),
          [[$id{b}, $id{d}, undef], [$id{e}, $id{d}, undef]],
          'incoming edges contain both predecessors');
is_deeply($g->out_neighbors($id{a}),
          [$id{a}, $id{b}, $id{c}],
          'outgoing neighbours follow outgoing edges');
is_deeply($g->in_neighbors($id{d}), [$id{b}, $id{e}],
          'incoming neighbours follow incoming edges');
is($g->out_degree($id{a}), 3, 'a loop counts as an outgoing edge');
is($g->in_degree($id{a}), 1, 'a loop counts as an incoming edge');
is($g->in_degree($id{d}), 2, 'two incoming edges give degree two');
is_deeply($g->edges_between($id{a}, $id{b}),
          [[$id{a}, $id{b}, undef]],
          'edges_between selects the ordered endpoint pair');
ok($g->has_edge_by_ids($id{a}, $id{b}), 'the exact unlabelled edge exists');
ok(!$g->has_edge_by_ids($id{b}, $id{a}), 'the reverse edge is absent');

$g->add_edge_by_ids($id{a}, $id{b}, 'alternate');
is($g->edge_count, 6, 'a different label creates a parallel relationship');
is_deeply($g->out_neighbors($id{a}),
          [$id{a}, $id{b}, $id{b}, $id{c}],
          'neighbours contain one entry for each labelled edge');
is($g->out_degree($id{a}), 4, 'parallel labelled edges count separately');
is_deeply($g->edges_between($id{a}, $id{b}),
          [[$id{a}, $id{b}, undef], [$id{a}, $id{b}, 'alternate']],
          'edges_between returns every label for the endpoint pair');

ok($g->delete_edge_by_ids($id{a}, $id{b}, 'alternate'),
   'deleting one labelled relationship succeeds');
ok(!$g->has_edge_by_ids($id{a}, $id{b}, 'alternate'),
   'the deleted labelled relationship is absent');
is($g->edge_count, 5, 'deleting one relationship leaves the others intact');

done_testing;
