use strict;
use warnings;

# Provenance: ported from Graph 0.9735 (7d3f3ea), primarily t/10_has_vertices.t,
# t/11_vertices.t, t/12_has_vertex.t, and t/14_delete_vertex.t.
# Graph-specific scalar context, stringification, and counted vertices were
# replaced with XGraph's explicit ID/name API.

use Test::More;
use XGraph;

my $g = XGraph->new;
is($g->vertex_count, 0, 'an empty graph has no live vertices');
is_deeply($g->vertex_ids, [], 'an empty graph has no IDs');

my $a = $g->add_vertex('a');
my $b = $g->add_vertex('b');
my $anonymous = $g->add_vertex;
my $empty = $g->add_vertex('');

is_deeply($g->vertex_ids, [$a, $b, $anonymous, $empty],
          'vertices are enumerated by ascending ID');
is($g->vertex_count, 4, 'all four vertices are live');
ok($g->has_vertex_id($a), 'named vertex is present by ID');
ok($g->has_vertex_id($anonymous), 'anonymous vertex is present by ID');
is($g->vertex_id_by_name('a'), $a, 'name lookup returns the stable ID');
is($g->vertex_id_by_name('b'), $b, 'a second name lookup returns its ID');
is($g->vertex_name_by_id($a), 'a', 'ID lookup returns a name');
ok(!defined $g->vertex_name_by_id($anonymous),
   'anonymous vertices have no manufactured name');
is($g->vertex_name_by_id($empty), '', 'the empty name is retained');
ok(!$g->has_vertex_id(0), 'zero is not a vertex ID');
ok(!$g->has_vertex_id(99), 'an unknown ID is absent');
ok(!defined $g->vertex_id_by_name('missing'), 'an unknown name is absent');

ok($g->delete_vertex_by_name('a'), 'deletion by name succeeds');
ok(!$g->has_vertex_id($a), 'the deleted vertex is no longer live');
ok(!defined $g->vertex_id_by_name('a'), 'the deleted name is no longer indexed');
is($g->delete_vertex_by_id($a), 0,
   'deleting an already deleted vertex is false');

my $replacement = $g->add_vertex('replacement');
is($replacement, 5, 'a deleted ID is not reused');
is($g->vertex_count, 4, 'the replacement restores the live count');

$g->rename_vertex($b, 'renamed');
ok(!defined $g->vertex_id_by_name('b'), 'old name is removed on rename');
is($g->vertex_id_by_name('renamed'), $b, 'new name points to the same ID');
$g->rename_vertex($b, undef);
ok(!defined $g->vertex_name_by_id($b), 'undef removes a vertex name');
ok(!defined $g->vertex_id_by_name('renamed'),
   'removed name is no longer indexed');

done_testing;
