use strict;
use warnings;

# Provenance: ported from Graph 0.9735 (7d3f3ea), primarily t/42_add_path.t
# and the directed portions of t/72_transitive.t.
# Graph's reflexive transitive-closure object was replaced with XGraph's
# explicit reachability, path, and deletion APIs.

use Test::More;
use XGraph;

my $g = XGraph->new;
my %id;
$id{$_} = $g->add_vertex($_) for qw(a b c d e);

$g->add_edge_by_ids($id{a}, $id{b});
$g->add_edge_by_ids($id{b}, $id{c});
$g->add_edge_by_ids($id{c}, $id{d});
$g->add_edge_by_ids($id{a}, $id{e});

ok($g->has_path($id{a}, $id{d}), 'a reaches d through the chain');
ok($g->has_path($id{a}, $id{e}), 'a reaches its branch');
ok(!$g->has_path($id{d}, $id{a}), 'the directed reverse path is absent');
ok(!$g->has_path($id{a}, $id{a}),
   'a zero-length self query is not a path without a cycle');

is_deeply($g->path($id{a}, $id{d}),
          [$id{a}, $id{b}, $id{c}, $id{d}],
          'path returns vertices from source to destination');
is_deeply($g->shortest_path($id{a}, $id{d}),
          [$id{a}, $id{b}, $id{c}, $id{d}],
          'shortest_path returns the minimum-edge route');
ok(!defined $g->path($id{d}, $id{a}), 'path returns undef when unreachable');
ok(!defined $g->shortest_path($id{d}, $id{a}),
   'shortest_path returns undef when unreachable');

is_deeply($g->descendants($id{a}),
          [$id{a}, $id{b}, $id{c}, $id{d}, $id{e}],
          'descendants includes the starting vertex');
is_deeply($g->strict_descendants($id{a}),
          [$id{b}, $id{c}, $id{d}, $id{e}],
          'strict descendants require an edge');
is_deeply($g->ancestors($id{d}),
          [$id{a}, $id{b}, $id{c}, $id{d}],
          'ancestors includes the starting vertex');
is_deeply($g->strict_ancestors($id{d}),
          [$id{a}, $id{b}, $id{c}],
          'strict ancestors exclude the starting vertex');

my $removed = $g->delete_paths($id{a}, $id{d});
is($removed, 3, 'delete_paths removes every edge in the only route');
ok(!$g->has_path($id{a}, $id{d}), 'the deleted path is no longer reachable');
ok($g->has_edge_by_ids($id{a}, $id{e}),
   'an unrelated branch survives path deletion');

my $cycle = XGraph->new;
my ($x, $y, $z) = map { $cycle->add_vertex($_) } qw(x y z);
$cycle->add_edge_by_ids($x, $y);
$cycle->add_edge_by_ids($y, $z);
$cycle->add_edge_by_ids($z, $x);
ok($cycle->has_path($x, $x), 'a directed cycle makes self-reachability true');
is_deeply($cycle->strict_descendants($x), [$x, $y, $z],
          'strict descendants include the start when a cycle returns to it');

done_testing;
