use strict;
use warnings;

use Test::More;
use XGraph;

my $graph = XGraph->new;
can_ok($graph, qw(
    new from_edges freeze is_frozen clone mutable_copy vertex fold_vertices to_dot write_dot
    add_vertex has_vertex_id vertex_id_by_name vertex_name_by_id
    rename_vertex delete_vertex_by_id delete_vertex_by_name vertex_ids vertices
    vertex_count set_vertex_metadata vertex_metadata has_vertex_metadata
    delete_vertex_metadata declare_label declare_labels labels label_count
    add_edge_by_ids add_edge_by_names has_edge_by_ids has_edge_by_names
    delete_edge_by_ids delete_edge_by_names edges edges_between
    out_edges in_edges out_neighbors in_neighbors undirected_neighbors
    out_degree in_degree edge_count
    has_path path shortest_path descendants strict_descendants ancestors
    strict_ancestors dfs_preorder dfs_postorder dfs_reverse_postorder
    topological_sort source_vertices sink_vertices loop_vertices
    weakly_connected_components strongly_connected_components
    strongly_connected_components_tarjan
    strongly_connected_components_pearce
    strongly_connected_components_tarjan_zwick
    cyclic_strongly_connected_components is_acyclic cycle shortest_cycle
    is_tree is_arborescence arborescence_root delete_paths reachability_roots
    induced_subgraph condensation vertex_iterator
));

my $cursor = $graph->_vertex_cursor;
can_ok($cursor, qw(next next_batch));

my $surface_id = $graph->add_vertex('surface');
my $vertex = $graph->vertex($surface_id);
can_ok($vertex, qw(graph id name metadata has_metadata set_metadata
    delete_metadata out_neighbors in_neighbors undirected_neighbors
    out_degree in_degree));

done_testing;
