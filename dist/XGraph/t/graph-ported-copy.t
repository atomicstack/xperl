use strict;
use warnings;

# Provenance: ported from the directed copy portions of Graph 0.9735
# (7d3f3ea), t/67_copy.t.  XGraph's clone/mutable_copy methods replace
# Graph's copy variants.  Undirected copies, complements, transposes, and
# attribute/deep-copy cases have no XGraph equivalent.

use Test::More;
use XGraph;

my $g = XGraph->new(strict_labels => 1);
$g->declare_labels(qw(red blue));
my %id;
$id{$_} = $g->add_vertex($_) for qw(a b c d);
$g->delete_vertex_by_id($id{d});
$g->add_edge_by_ids($id{a}, $id{b}, 'red');
$g->add_edge_by_ids($id{b}, $id{c}, 'blue');
$g->add_edge_by_ids($id{c}, $id{a});

my $clone = $g->clone;
is_deeply($clone->vertex_ids, $g->vertex_ids,
          'clone preserves live vertex IDs');
is_deeply($clone->labels, $g->labels,
          'clone preserves label registration order');
is_deeply($clone->edges, $g->edges,
          'clone preserves labelled edge tuples');
is($clone->vertex_id_by_name('b'), $id{b},
   'clone preserves the name index');
is($clone->add_vertex('clone-only'), 5,
   'clone preserves the monotonic ID counter');
ok(!defined $g->vertex_id_by_name('clone-only'),
   'mutating the clone does not mutate the source');

my $mutable = $g->mutable_copy;
ok(!$mutable->is_frozen, 'mutable_copy is mutable');
ok($mutable->delete_edge_by_ids($id{a}, $id{b}, 'red'),
   'mutable_copy can remove a copied edge');
ok($g->has_edge_by_ids($id{a}, $id{b}, 'red'),
   'removing an edge from mutable_copy leaves the source intact');

$g->freeze;
ok($g->is_frozen, 'the source can be frozen after copying');
my $frozen_clone = $g->clone;
ok($frozen_clone->is_frozen, 'clone preserves frozen state');
my $frozen_error = eval { $frozen_clone->add_vertex('not-allowed'); 1 };
ok(!$frozen_error, 'a frozen clone rejects mutation');
like($@, qr/FROZEN/, 'frozen clone reports the planned error code');

my $mutable_from_frozen = $g->mutable_copy;
ok(!$mutable_from_frozen->is_frozen,
   'mutable_copy clears frozen state');
ok($mutable_from_frozen->add_vertex('allowed'),
   'mutable_copy of a frozen graph accepts mutation');
ok($g->is_frozen, 'mutating mutable_copy leaves the frozen source unchanged');

done_testing;
