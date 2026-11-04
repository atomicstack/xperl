use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More;
use XGraph;
use XGraph::IO::DOT;

my $graph = XGraph->new;
my $quoted = $graph->add_vertex("a\"b\\c\nline");
my $anonymous = $graph->add_vertex;
my $sink = $graph->add_vertex('sink');

$graph->add_edge_by_ids($quoted, $sink, "depends\non");
$graph->add_edge_by_ids($anonymous, $sink, undef);
$graph->add_edge_by_ids($sink, $quoted, '');

my $expected = <<'DOT';
digraph "XGraph" {
  v1 [label="a\"b\\c\nline"];
  v2 [label="v2"];
  v3 [label="sink"];
  v1 -> v3 [label="depends\non"];
  v2 -> v3;
  v3 -> v1 [label=""];
}
DOT

is($graph->to_dot, $expected, 'method emits deterministic directed DOT');
is(XGraph::IO::DOT::to_string($graph), $expected,
   'functional interface emits the same DOT');
my $with_ids = <<'DOT';
digraph "XGraph" {
  v1 [label="a\"b\\c\nline\\n(ID 1)"];
  v2 [label="v2\\n(ID 2)"];
  v3 [label="sink\\n(ID 3)"];
  v1 -> v3 [label="depends\non"];
  v2 -> v3;
  v3 -> v1 [label=""];
}
DOT
is($graph->to_dot(show_ids => 1), $with_ids,
   'show_ids appends stable IDs to vertex labels');

my $named_graph = <<'DOT';
digraph "Build" {
  v1 [label="a\"b\\c\nline"];
  v2 [label="v2"];
  v3 [label="sink"];
  v1 -> v3 [label="depends\non"];
  v2 -> v3;
  v3 -> v1 [label=""];
}
DOT
is($graph->to_dot(graph_name => 'Build'), $named_graph,
   'graph_name changes only the DOT graph name');

my $dir = tempdir(CLEANUP => 1);
my $path = "$dir/graph.dot";
ok($graph->write_dot($path), 'write_dot writes a DOT file');
open my $fh, '<:raw', $path or die "open $path: $!";
local $/;
is(<$fh>, $expected, 'written DOT file has the to_dot document');
close $fh or die "close $path: $!";

my $bad = eval { XGraph::IO::DOT::to_string($graph, graph_name => []); 1 };
ok(!$bad, 'references are rejected as graph names');
like($@, qr/graph_name is a reference/, 'graph-name error is explicit');

$bad = eval { XGraph::IO::DOT::to_string($graph, unknown => 1); 1 };
ok(!$bad, 'unknown DOT options are rejected');
like($@, qr/unknown DOT option/, 'unknown-option error is explicit');

done_testing;
