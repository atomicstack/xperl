use strict;
use warnings;

use Test::More;
use XGraph;

my $named = XGraph->from_edges(
    paths => ['a', 'b', 'c'],
);
is($named->vertex_count, 3, 'a named path creates its vertices');
is($named->edge_count, 2, 'a named path creates consecutive edges');
ok($named->has_edge_by_names('a', 'b'), 'first named path edge exists');
ok($named->has_edge_by_names('b', 'c'), 'second named path edge exists');

my $singleton = XGraph->from_edges(paths => ['only']);
is($singleton->vertex_count, 1, 'a singleton path declares its vertex');
is($singleton->edge_count, 0, 'a singleton path has no edges');

my $grouped = XGraph->from_edges(
    labeled_edges => {
        depends_on => ['a', 'b', 'b', 'c'],
    },
    labeled_paths => {
        calls => [['c', 'd', 'e'], ['e', 'f']],
    },
);
is($grouped->edge_count, 5, 'grouped edges and paths are expanded');
ok($grouped->has_edge_by_names('a', 'b', 'depends_on'),
   'grouped labeled edge exists');
ok($grouped->has_edge_by_names('c', 'd', 'calls'),
   'grouped labeled path edge exists');
ok($grouped->has_edge_by_names('e', 'f', 'calls'),
   'second grouped path edge exists');

my $isolated = XGraph->from_edges(
    vertices => ['a', 'b', 'isolated'],
    edges    => ['a', 'b'],
);
is($isolated->vertex_count, 3, 'vertices declares an isolated named vertex');
is($isolated->edge_count, 1, 'flat named edges are accepted');
is($isolated->vertex_name_by_id(
       $isolated->vertex_id_by_name('isolated')), 'isolated',
   'isolated vertex retains its name');

my $ids = XGraph->from_edges(
    vertex_mode => 'id',
    vertices    => [10, 20, 99],
    edges       => [10, 20],
    paths       => [20, 30],
);
is($ids->vertex_count, 4, 'ID mode infers referenced vertices');
ok($ids->has_vertex_id(99), 'ID mode keeps an explicitly declared isolated ID');
ok($ids->has_edge_by_ids(10, 20), 'ID edge exists');
ok($ids->has_edge_by_ids(20, 30), 'ID path edge exists');

my @warnings;
{
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $duplicates = XGraph->from_edges(
        vertex_mode   => 'id',
        edges         => [1, 2, 1, 2],
        labeled_edges => { calls => [1, 2, 1, 2] },
    );
    is($duplicates->edge_count, 2,
       'duplicate tuples are ignored independently for each label');
}
like(join('', @warnings), qr/EDGE_EXISTS/, 'duplicates warn');

my $strict = XGraph->from_edges(
    strict_labels  => 1,
    labels         => ['calls'],
    labeled_edges  => { calls => ['a', 'b'] },
);
ok($strict->has_edge_by_names('a', 'b', 'calls'),
   'declared labels work in strict mode');

my $strict_error = eval {
    XGraph->from_edges(
        strict_labels  => 1,
        labeled_edges => { missing => ['a', 'b'] },
    );
    1;
};
ok(!$strict_error, 'unknown strict bulk labels fail');
like($@, qr/UNKNOWN_LABEL/, 'strict bulk label error is reported');

my $bad_mode = eval { XGraph->from_edges(vertex_mode => 'other'); 1 };
ok(!$bad_mode, 'unknown vertex mode fails');
like($@, qr/vertex_mode/, 'vertex mode error is reported');

my $bad_shape = eval { XGraph->from_edges(edges => [1]); 1 };
ok(!$bad_shape, 'odd flat edge input fails');
like($@, qr/even length/, 'flat edge shape error is reported');

my $bad_reference = eval { XGraph->from_edges(paths => [[{}, 'a']]); 1 };
ok(!$bad_reference, 'reference vertex input fails');
like($@, qr/references are not allowed/, 'reference vertex error is reported');

done_testing;
