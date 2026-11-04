#ifndef XGRAPH_H
#define XGRAPH_H

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <stdint.h>

/*
 * The native graph uses integer IDs.  Perl names and labels stay in AV/HV
 * registries, so the hot topology arrays never have to own Perl SV values.
 * Zero is reserved as an invalid vertex ID.
 */
typedef uint32_t xg_vertex_id_t;
typedef uint32_t xg_label_id_t;

/*
 * One adjacency entry stores the other endpoint and the edge label.  Compact
 * builds use one 32-bit word: 24 bits for the vertex and 8 bits for the
 * label.  Wide builds use two 32-bit fields in a 64-bit word.  The helper
 * functions at the end of this header hide that representation choice.
 */
#ifdef XGRAPH_WIDE
typedef uint64_t xg_entry_t;
#else
typedef uint32_t xg_entry_t;
#endif

#ifdef XGRAPH_WIDE
#define XG_MAX_VERTEX_ID UINT32_C(0xffffffff)
#define XG_MAX_LABEL_ID  UINT32_C(0xffffffff)
#define XG_ENTRY_LABEL_BITS 32
#else
#define XG_MAX_VERTEX_ID UINT32_C(0x00ffffff)
#define XG_MAX_LABEL_ID  UINT32_C(0xff)
#define XG_ENTRY_LABEL_BITS 8
#endif

typedef struct xg_adj_list {
    /* Entries are sorted by their packed (vertex ID, label ID) value. */
    uint32_t count;
    uint32_t capacity;
    xg_entry_t *entries;
} xg_adj_list;

typedef struct xg_vertex {
    /* A directed edge appears in both lists, once in each direction. */
    xg_adj_list *in;
    xg_adj_list *out;
    U8 live;
} xg_vertex;

typedef struct xg_graph {
    /* The vertex array is indexed directly by vertex ID. */
    xg_vertex *vertices;
    uint32_t vertex_capacity;
    xg_vertex_id_t next_vertex_id;
    uint32_t live_vertices;
    uint64_t live_edges;
    uint64_t topology_generation;
    uint64_t naming_generation;
    U8 acyclic;
    U8 strict_labels;
    U8 frozen;
    U8 unavailable_thread_clone;

    /*
     * These are Perl-owned registries.  Native records store only IDs.  The
     * two vertex maps provide name-to-ID and ID-to-name lookup, while the
     * label AV/HV pair provides label interning.
     */
    AV *labels_by_id;
    HV *label_ids_by_name;
    HV *vertex_names_by_id;
    HV *vertex_ids_by_name;
    HV *vertex_metadata_by_id;
} xg_graph;

typedef struct xg_cursor {
    /* Cursors are pull iterators over the monotonically ordered ID space. */
    xg_graph *graph;
    SV *graph_sv;
    xg_vertex_id_t next_vertex;
    uint64_t topology_generation;
    U8 done;
} xg_cursor;

xg_graph *xg_new(pTHX_ U8 acyclic, U8 strict_labels);
xg_graph *xg_clone(pTHX_ const xg_graph *source, U8 mutable_copy);
void xg_free(pTHX_ xg_graph *graph);
void xg_free_store(pTHX_ xg_graph *graph);

void xg_require_usable(pTHX_ const xg_graph *graph);
void xg_require_mutable(pTHX_ const xg_graph *graph);

int xg_name_lookup(pTHX_ const xg_graph *graph, SV *name,
                   xg_vertex_id_t *id_out);
int xg_name_is_anonymous(pTHX_ SV *name);
SV *xg_normalize_name(pTHX_ SV *value, int allow_undef);

xg_vertex_id_t xg_add_vertex(pTHX_ xg_graph *graph, SV *name);
void xg_add_vertex_id(pTHX_ xg_graph *graph, xg_vertex_id_t id);
int xg_has_vertex(const xg_graph *graph, xg_vertex_id_t id);
SV *xg_vertex_name(pTHX_ const xg_graph *graph, xg_vertex_id_t id);
void xg_rename_vertex(pTHX_ xg_graph *graph, xg_vertex_id_t id, SV *name);
int xg_delete_vertex(pTHX_ xg_graph *graph, xg_vertex_id_t id);
void xg_set_vertex_metadata(pTHX_ xg_graph *graph, xg_vertex_id_t id,
                            SV *metadata);
SV *xg_vertex_metadata(pTHX_ const xg_graph *graph, xg_vertex_id_t id);
int xg_has_vertex_metadata(pTHX_ const xg_graph *graph, xg_vertex_id_t id);
int xg_delete_vertex_metadata(pTHX_ xg_graph *graph, xg_vertex_id_t id);

xg_label_id_t xg_label_id(pTHX_ xg_graph *graph, SV *label, int declare);
void xg_declare_label(pTHX_ xg_graph *graph, SV *label);
void xg_declare_labels(pTHX_ xg_graph *graph, SV **labels, I32 count);
SV *xg_label_value(pTHX_ const xg_graph *graph, xg_label_id_t id);

void xg_add_edge(pTHX_ xg_graph *graph, xg_vertex_id_t from,
                 xg_vertex_id_t to, SV *label);
int xg_has_edge(pTHX_ const xg_graph *graph, xg_vertex_id_t from,
                xg_vertex_id_t to, SV *label);
int xg_delete_edge(pTHX_ xg_graph *graph, xg_vertex_id_t from,
                   xg_vertex_id_t to, SV *label);

AV *xg_vertex_ids(pTHX_ const xg_graph *graph);
AV *xg_labels(pTHX_ const xg_graph *graph);
AV *xg_edges(pTHX_ const xg_graph *graph);
AV *xg_edges_for_vertex(pTHX_ const xg_graph *graph, xg_vertex_id_t id,
                        int outgoing);
AV *xg_neighbors(pTHX_ const xg_graph *graph, xg_vertex_id_t id,
                 int outgoing);
AV *xg_undirected_neighbors(pTHX_ const xg_graph *graph,
                             xg_vertex_id_t id);
uint32_t xg_degree(pTHX_ const xg_graph *graph, xg_vertex_id_t id,
                   int outgoing);

int xg_has_path(pTHX_ const xg_graph *graph, xg_vertex_id_t from,
                xg_vertex_id_t to, int incoming);
AV *xg_path(pTHX_ const xg_graph *graph, xg_vertex_id_t from,
            xg_vertex_id_t to, int incoming);
AV *xg_reachable(pTHX_ const xg_graph *graph, xg_vertex_id_t start,
                 int incoming, int strict);
AV *xg_dfs_order(pTHX_ const xg_graph *graph, xg_vertex_id_t start,
                 int incoming, int postorder);
AV *xg_topological_sort(pTHX_ const xg_graph *graph);
AV *xg_source_vertices(pTHX_ const xg_graph *graph);
AV *xg_sink_vertices(pTHX_ const xg_graph *graph);
AV *xg_loop_vertices(pTHX_ const xg_graph *graph);
AV *xg_components(pTHX_ const xg_graph *graph, int strong, int cyclic_only);
AV *xg_components_tarjan(pTHX_ const xg_graph *graph);
AV *xg_components_pearce(pTHX_ const xg_graph *graph);
AV *xg_components_tarjan_zwick(pTHX_ const xg_graph *graph);
int xg_is_acyclic(pTHX_ const xg_graph *graph);
AV *xg_cycle(pTHX_ const xg_graph *graph, int shortest);
int xg_is_tree(pTHX_ const xg_graph *graph);
int xg_is_arborescence(pTHX_ const xg_graph *graph, xg_vertex_id_t *root_out);
AV *xg_reachability_roots(pTHX_ const xg_graph *graph);
xg_graph *xg_induced_subgraph(pTHX_ const xg_graph *graph, AV *vertex_ids);
xg_graph *xg_condensation(pTHX_ const xg_graph *graph, AV **components_out,
                          AV **component_of_out);
UV xg_delete_paths(pTHX_ xg_graph *graph, xg_vertex_id_t from,
                   xg_vertex_id_t to);
xg_cursor *xg_cursor_new(pTHX_ xg_graph *graph, SV *graph_sv);
void xg_cursor_free(pTHX_ xg_cursor *cursor);
SV *xg_cursor_next(pTHX_ xg_cursor *cursor);
AV *xg_cursor_batch(pTHX_ xg_cursor *cursor, UV count);

xg_entry_t xg_pack(xg_vertex_id_t vertex, xg_label_id_t label);
xg_vertex_id_t xg_entry_vertex(xg_entry_t entry);
xg_label_id_t xg_entry_label(xg_entry_t entry);

#endif
