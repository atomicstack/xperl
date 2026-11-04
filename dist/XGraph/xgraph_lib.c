#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "xgraph.h"

#include <string.h>
#include <stdlib.h>

/*
 * The implementation is arranged in the same order a student can use to
 * understand the data structure: storage primitives, names and labels,
 * mutation, queries, graph algorithms, and finally the cursor wrapper.
 */

/*
 * This file owns the graph's native topology.  The XS file is the adapter at
 * the Perl boundary.  Most functions here validate the graph, update compact
 * native storage, and create Perl values only when a public method needs to
 * return them.
 */

static void
xg_error(pTHX_ const char *code, const char *detail)
{
    if (detail && *detail)
        croak("XPERL.GRAPH.%s: %s", code, detail);
    croak("XPERL.GRAPH.%s", code);
}

static xg_adj_list *
xg_adj_new(pTHX)
{
    xg_adj_list *list;
    /* An empty list is allocated lazily, so isolated vertices cost no array. */
    Newxz(list, 1, xg_adj_list);
    return list;
}

static void
xg_adj_free(pTHX_ xg_adj_list *list)
{
    if (!list)
        return;
    /* The entries array and its small header have separate allocations. */
    Safefree(list->entries);
    Safefree(list);
}

static void
xg_adj_reserve(pTHX_ xg_adj_list *list, uint32_t needed)
{
    uint64_t capacity;

    if (needed <= list->capacity)
        return;

    /* Grow geometrically so a sequence of insertions stays inexpensive. */
    capacity = list->capacity ? list->capacity : 8;
    while (capacity < needed) {
        capacity *= 2;
        if (capacity > UINT32_MAX)
            xg_error(aTHX_ "ALLOCATION_FAILED", "adjacency list is too large");
    }

    Renew(list->entries, (size_t)capacity, xg_entry_t);
    list->capacity = (uint32_t)capacity;
}

static uint32_t
xg_adj_lower_bound(const xg_adj_list *list, xg_entry_t entry)
{
    uint32_t first = 0;
    uint32_t count = list->count;

    /*
     * Find the first entry which is not less than the target.  Because the
     * list is sorted, this is both the insertion point and the lookup point.
     */
    while (count) {
        uint32_t step = count / 2;
        uint32_t pos = first + step;
        if (list->entries[pos] < entry) {
            first = pos + 1;
            count -= step + 1;
        } else {
            count = step;
        }
    }
    return first;
}

static void
xg_adj_insert(pTHX_ xg_adj_list *list, xg_entry_t entry)
{
    uint32_t pos = xg_adj_lower_bound(list, entry);
    xg_adj_reserve(aTHX_ list, list->count + 1);
    /* Move the tail one slot right to make room for the new entry. */
    if (pos < list->count)
        Move(list->entries + pos, list->entries + pos + 1,
             list->count - pos, xg_entry_t);
    list->entries[pos] = entry;
    list->count++;
}

static int
xg_adj_remove(xg_adj_list *list, xg_entry_t entry)
{
    uint32_t pos = xg_adj_lower_bound(list, entry);
    if (pos == list->count || list->entries[pos] != entry)
        return 0;
    /* Close the gap left by the removed entry. */
    if (pos + 1 < list->count)
        Move(list->entries + pos + 1, list->entries + pos,
             list->count - pos - 1, xg_entry_t);
    list->count--;
    return 1;
}

xg_entry_t
xg_pack(xg_vertex_id_t vertex, xg_label_id_t label)
{
    /* Labels occupy the low bits, so packed ordering is vertex then label. */
    return (xg_entry_t)(((xg_entry_t)vertex << XG_ENTRY_LABEL_BITS) |
                        ((xg_entry_t)label & XG_MAX_LABEL_ID));
}

xg_vertex_id_t
xg_entry_vertex(xg_entry_t entry)
{
    /* Shifting drops the low label bits and recovers the destination ID. */
    return (xg_vertex_id_t)(entry >> XG_ENTRY_LABEL_BITS);
}

xg_label_id_t
xg_entry_label(xg_entry_t entry)
{
    /* Masking keeps only the low bits reserved for the relationship type. */
    return (xg_label_id_t)(entry & XG_MAX_LABEL_ID);
}

/* The label registry is initialized once per graph, including its reserved IDs. */
static void
xg_init_labels(pTHX_ xg_graph *graph)
{
    /*
     * Label IDs 0, 1, and 2 have fixed meanings.  Slot 0 is invalid, slot 1
     * is undef, and slot 2 is the empty string.
     */
    av_store(graph->labels_by_id, 0, newSV(0));
    av_store(graph->labels_by_id, 1, newSV(0));
    av_store(graph->labels_by_id, 2, newSVpvs(""));
    hv_store(graph->label_ids_by_name, "", 0, newSVuv(2), 0);
}

xg_graph *
xg_new(pTHX_ U8 acyclic, U8 strict_labels)
{
    xg_graph *graph;

    Newxz(graph, 1, xg_graph);
    /* Start small.  xg_vertex_capacity grows this table when needed. */
    graph->vertex_capacity = 16;
    Newxz(graph->vertices, graph->vertex_capacity, xg_vertex);
    graph->next_vertex_id = 1;
    graph->acyclic = acyclic;
    graph->strict_labels = strict_labels;
    graph->labels_by_id = newAV();
    graph->label_ids_by_name = newHV();
    graph->vertex_names_by_id = newHV();
    graph->vertex_ids_by_name = newHV();
    graph->vertex_metadata_by_id = newHV();
    xg_init_labels(aTHX_ graph);
    return graph;
}

static void
xg_free_vertices(pTHX_ xg_graph *graph)
{
    uint32_t i;
    if (!graph->vertices)
        return;
    for (i = 0; i < graph->vertex_capacity; i++) {
        xg_adj_free(aTHX_ graph->vertices[i].in);
        xg_adj_free(aTHX_ graph->vertices[i].out);
    }
    Safefree(graph->vertices);
    graph->vertices = NULL;
}

/*
 * The native vertex/adjacency store is released separately from the Perl
 * registries.  This separation is important when a future frozen store is
 * shared by more than one interpreter.
 */
void
xg_free_store(pTHX_ xg_graph *graph)
{
    if (!graph)
        return;
    xg_free_vertices(aTHX_ graph);
}

void
xg_free(pTHX_ xg_graph *graph)
{
    if (!graph)
        return;
    /* Perl reference counts release the registries after native arrays go away. */
    xg_free_store(aTHX_ graph);
    SvREFCNT_dec(graph->labels_by_id);
    SvREFCNT_dec(graph->label_ids_by_name);
    SvREFCNT_dec(graph->vertex_names_by_id);
    SvREFCNT_dec(graph->vertex_ids_by_name);
    SvREFCNT_dec(graph->vertex_metadata_by_id);
    Safefree(graph);
}

void
xg_require_usable(pTHX_ const xg_graph *graph)
{
    /* A failed ithread clone is deliberately unusable rather than half-valid. */
    if (!graph || graph->unavailable_thread_clone)
        xg_error(aTHX_ "THREAD_CLONE_REQUIRES_FROZEN", NULL);
}

void
xg_require_mutable(pTHX_ const xg_graph *graph)
{
    xg_require_usable(aTHX_ graph);
    if (graph->frozen)
        xg_error(aTHX_ "FROZEN", NULL);
}

/*
 * Normalize a Perl string once at the boundary.  An undef value is represented
 * by an empty, undef SV so callers can distinguish it from the empty string.
 * References are rejected before stringification.
 */
SV *
xg_normalize_name(pTHX_ SV *value, int allow_undef)
{
    SV *copy;

    if (!value)
        value = &PL_sv_undef;
    SvGETMAGIC(value);
    if (!SvOK(value)) {
        if (allow_undef)
            return newSV(0);
        xg_error(aTHX_ "INVALID_ARGUMENT", "undefined string");
    }
    if (SvROK(value))
        xg_error(aTHX_ "INVALID_ARGUMENT", "references are not strings");
    copy = newSVsv(value);
    (void)SvPV_nolen(copy);
    return copy;
}

static SV *
xg_normalize_label(pTHX_ SV *value)
{
    if (value && SvROK(value))
        xg_error(aTHX_ "INVALID_LABEL", "references are not labels");
    return xg_normalize_name(aTHX_ value, 1);
}

int
xg_name_is_anonymous(pTHX_ SV *name)
{
    return !name || !SvOK(name);
}

int
xg_name_lookup(pTHX_ const xg_graph *graph, SV *name,
               xg_vertex_id_t *id_out)
{
    SV *normalized;
    HE *he;
    xg_require_usable(aTHX_ graph);
    normalized = xg_normalize_name(aTHX_ name, 1);
    SAVEFREESV(normalized);
    if (!SvOK(normalized)) {
        return 0;
    }
    he = hv_fetch_ent(graph->vertex_ids_by_name, normalized, 0, 0);
    if (he)
        *id_out = (xg_vertex_id_t)SvUV(HeVAL(he));
    return he != NULL;
}

/* The ID-indexed vertex array grows geometrically and never shrinks. */
static void
xg_vertex_capacity(pTHX_ xg_graph *graph, xg_vertex_id_t id)
{
    uint64_t capacity;
    if (id < graph->vertex_capacity)
        return;
    capacity = graph->vertex_capacity;
    /* The array is indexed by ID, so capacity must cover the requested slot. */
    while (capacity <= id) {
        if (capacity > ((uint64_t)XG_MAX_VERTEX_ID + 1) / 2)
            capacity = (uint64_t)XG_MAX_VERTEX_ID + 1;
        else
            capacity *= 2;
    }
    Renew(graph->vertices, (size_t)capacity, xg_vertex);
    Zero(graph->vertices + graph->vertex_capacity,
         (size_t)capacity - graph->vertex_capacity, xg_vertex);
    graph->vertex_capacity = (uint32_t)capacity;
}

int
xg_has_vertex(const xg_graph *graph, xg_vertex_id_t id)
{
    return id != 0 && id < graph->vertex_capacity && graph->vertices[id].live;
}

static void
xg_require_vertex(pTHX_ const xg_graph *graph, xg_vertex_id_t id)
{
    if (!xg_has_vertex(graph, id))
        xg_error(aTHX_ "UNKNOWN_VERTEX", NULL);
}

xg_vertex_id_t
xg_add_vertex(pTHX_ xg_graph *graph, SV *name)
{
    SV *normalized;
    HE *he;
    xg_vertex_id_t id;

    xg_require_mutable(aTHX_ graph);
    normalized = xg_normalize_name(aTHX_ name, 1);
    SAVEFREESV(normalized);
    /*
     * A name is an optional alias.  Anonymous vertices consume no entries in
     * either name map, but every vertex still receives a numeric ID.
     */
    if (SvOK(normalized)) {
        he = hv_fetch_ent(graph->vertex_ids_by_name, normalized, 0, 0);
        if (he)
            xg_error(aTHX_ "DUPLICATE_VERTEX_NAME", NULL);
    }
    if (graph->next_vertex_id == 0 || graph->next_vertex_id > XG_MAX_VERTEX_ID)
        xg_error(aTHX_ "VERTEX_ID_EXHAUSTED", NULL);
    id = graph->next_vertex_id++;
    xg_vertex_capacity(aTHX_ graph, id);
    graph->vertices[id].live = 1;
    graph->live_vertices++;
    if (SvOK(normalized)) {
        SV *name_key = newSVsv(normalized);
        SV *id_key = newSVuv(id);
        hv_store_ent(graph->vertex_ids_by_name, name_key,
                     newSVuv(id), 0);
        hv_store_ent(graph->vertex_names_by_id, id_key,
                     newSVsv(normalized), 0);
        SvREFCNT_dec(name_key);
        SvREFCNT_dec(id_key);
        graph->naming_generation++;
    }
    graph->topology_generation++;
    return id;
}

/* Bulk constructors may receive sparse, explicit numeric IDs. */
void
xg_add_vertex_id(pTHX_ xg_graph *graph, xg_vertex_id_t id)
{
    xg_require_mutable(aTHX_ graph);
    if (id == 0 || id > XG_MAX_VERTEX_ID)
        xg_error(aTHX_ "INVALID_VERTEX_ID", NULL);
    if (xg_has_vertex(graph, id))
        xg_error(aTHX_ "DUPLICATE_VERTEX_ID", NULL);
    xg_vertex_capacity(aTHX_ graph, id);
    graph->vertices[id].live = 1;
    graph->live_vertices++;
    if (id >= graph->next_vertex_id)
        graph->next_vertex_id = id + 1;
    graph->topology_generation++;
}

/* Names are aliases stored in Perl hashes; native vertices carry only IDs. */
SV *
xg_vertex_name(pTHX_ const xg_graph *graph, xg_vertex_id_t id)
{
    HE *he;
    SV *key;
    xg_require_usable(aTHX_ graph);
    xg_require_vertex(aTHX_ graph, id);
    key = newSVuv(id);
    he = hv_fetch_ent(graph->vertex_names_by_id, key, 0, 0);
    SvREFCNT_dec(key);
    if (!he)
        return newSV(0);
    return newSVsv(HeVAL(he));
}

void
xg_rename_vertex(pTHX_ xg_graph *graph, xg_vertex_id_t id, SV *name)
{
    SV *normalized;
    HE *he;
    SV *old;
    SV *key;

    xg_require_mutable(aTHX_ graph);
    xg_require_vertex(aTHX_ graph, id);
    normalized = xg_normalize_name(aTHX_ name, 1);
    SAVEFREESV(normalized);
    /* Check the new alias before removing the old one, so failure is atomic. */
    if (SvOK(normalized)) {
        he = hv_fetch_ent(graph->vertex_ids_by_name, normalized, 0, 0);
        if (he && SvUV(HeVAL(he)) != id)
            xg_error(aTHX_ "DUPLICATE_VERTEX_NAME", NULL);
    }
    key = newSVuv(id);
    he = hv_fetch_ent(graph->vertex_names_by_id, key, 0, 0);
    SvREFCNT_dec(key);
    old = he ? newSVsv(HeVAL(he)) : NULL;
    if (old) {
        hv_delete_ent(graph->vertex_ids_by_name, old, G_DISCARD, 0);
        key = newSVuv(id);
        hv_delete_ent(graph->vertex_names_by_id, key, G_DISCARD, 0);
        SvREFCNT_dec(key);
        SvREFCNT_dec(old);
    }
    if (SvOK(normalized)) {
        SV *name_key = newSVsv(normalized);
        SV *id_key = newSVuv(id);
        hv_store_ent(graph->vertex_ids_by_name, name_key,
                     newSVuv(id), 0);
        hv_store_ent(graph->vertex_names_by_id, id_key,
                     newSVsv(normalized), 0);
        SvREFCNT_dec(name_key);
        SvREFCNT_dec(id_key);
    }
    graph->naming_generation++;
}

void
xg_set_vertex_metadata(pTHX_ xg_graph *graph, xg_vertex_id_t id,
                       SV *metadata)
{
    SV *key;

    xg_require_mutable(aTHX_ graph);
    xg_require_vertex(aTHX_ graph, id);
    SvGETMAGIC(metadata);
    /* Metadata is intentionally Perl-owned and is not copied into topology. */
    key = newSVuv(id);
    hv_store_ent(graph->vertex_metadata_by_id, key, newSVsv(metadata), 0);
    SvREFCNT_dec(key);
}

/* Metadata is optional, so absence is represented by an absent hash entry. */
SV *
xg_vertex_metadata(pTHX_ const xg_graph *graph, xg_vertex_id_t id)
{
    HE *he;
    SV *key;

    xg_require_usable(aTHX_ graph);
    xg_require_vertex(aTHX_ graph, id);
    key = newSVuv(id);
    he = hv_fetch_ent(graph->vertex_metadata_by_id, key, 0, 0);
    SvREFCNT_dec(key);
    return he ? newSVsv(HeVAL(he)) : newSV(0);
}

int
xg_has_vertex_metadata(pTHX_ const xg_graph *graph, xg_vertex_id_t id)
{
    HE *he;
    SV *key;

    xg_require_usable(aTHX_ graph);
    xg_require_vertex(aTHX_ graph, id);
    key = newSVuv(id);
    he = hv_fetch_ent(graph->vertex_metadata_by_id, key, 0, 0);
    SvREFCNT_dec(key);
    return he != NULL;
}

int
xg_delete_vertex_metadata(pTHX_ xg_graph *graph, xg_vertex_id_t id)
{
    SV *key;
    int deleted;

    xg_require_mutable(aTHX_ graph);
    xg_require_vertex(aTHX_ graph, id);
    key = newSVuv(id);
    deleted = hv_exists_ent(graph->vertex_metadata_by_id, key, 0);
    if (deleted)
        (void)hv_delete_ent(graph->vertex_metadata_by_id, key, G_DISCARD, 0);
    SvREFCNT_dec(key);
    return deleted;
}

SV *
xg_label_value(pTHX_ const xg_graph *graph, xg_label_id_t id)
{
    SV **svp;
    xg_require_usable(aTHX_ graph);
    if (id > XG_MAX_LABEL_ID || id > (xg_label_id_t)av_len(graph->labels_by_id))
        xg_error(aTHX_ "INVALID_LABEL", NULL);
    svp = av_fetch(graph->labels_by_id, id, 0);
    return svp ? newSVsv(*svp) : newSV(0);
}

/* Labels are interned once and then represented in every edge by a small ID. */
xg_label_id_t
xg_label_id(pTHX_ xg_graph *graph, SV *label, int declare)
{
    SV *normalized;
    HE *he;
    xg_label_id_t id;

    xg_require_usable(aTHX_ graph);
    normalized = xg_normalize_label(aTHX_ label);
    SAVEFREESV(normalized);

    /* The two reserved labels never consume registration capacity. */
    if (!SvOK(normalized)) {
        return 1;
    }
    if (SvPV_nolen(normalized)[0] == '\0' && SvCUR(normalized) == 0) {
        return 2;
    }
    he = hv_fetch_ent(graph->label_ids_by_name, normalized, 0, 0);
    if (he) {
        id = (xg_label_id_t)SvUV(HeVAL(he));
        return id;
    }
    /* A negative declaration flag means lookup only. */
    if (declare < 0) {
        return 0;
    }
    if (graph->strict_labels && !declare)
        xg_error(aTHX_ "UNKNOWN_LABEL", NULL);
    id = (xg_label_id_t)av_len(graph->labels_by_id) + 1;
    if (id > XG_MAX_LABEL_ID)
        xg_error(aTHX_ "LABEL_LIMIT", NULL);
    av_store(graph->labels_by_id, id, newSVsv(normalized));
    {
        SV *key = newSVsv(normalized);
        hv_store_ent(graph->label_ids_by_name, key, newSVuv(id), 0);
        SvREFCNT_dec(key);
    }
    graph->naming_generation++;
    return id;
}

void
xg_declare_label(pTHX_ xg_graph *graph, SV *label)
{
    xg_require_mutable(aTHX_ graph);
    (void)xg_label_id(aTHX_ graph, label, 1);
}

void
xg_declare_labels(pTHX_ xg_graph *graph, SV **labels, I32 count)
{
    AV *normalized;
    HV *new_names;
    I32 i;
    UV new_count = 0;

    xg_require_mutable(aTHX_ graph);
    if (count <= 0)
        return;

    /*
     * Normalize and validate the complete batch before changing graph state.
     * This makes a failed batch behave like a transaction: either all labels
     * are declared or the graph is unchanged.
     */
    normalized = newAV();
    new_names = newHV();
    SAVEFREESV((SV *)normalized);
    SAVEFREESV((SV *)new_names);
    for (i = 0; i < count; i++) {
        SV *value = xg_normalize_label(aTHX_ labels[i]);
        av_push(normalized, value);
        if (SvOK(value) && SvCUR(value) != 0) {
            HE *existing = hv_fetch_ent(graph->label_ids_by_name, value, 0, 0);
            HE *batch = hv_fetch_ent(new_names, value, 0, 0);
            if (!existing && !batch) {
                SV *key = newSVsv(value);
                hv_store_ent(new_names, key, newSViv(1), 0);
                SvREFCNT_dec(key);
                new_count++;
            }
        }
    }
    if ((UV)av_len(graph->labels_by_id) + new_count > XG_MAX_LABEL_ID)
        xg_error(aTHX_ "LABEL_LIMIT", NULL);

    for (i = 0; i < count; i++) {
        SV **value = av_fetch(normalized, i, 0);
        (void)xg_label_id(aTHX_ graph, value ? *value : &PL_sv_undef, 1);
    }
}

static int
xg_reaches(pTHX_ const xg_graph *graph, xg_vertex_id_t start,
           xg_vertex_id_t wanted)
{
    xg_vertex_id_t *stack;
    U8 *seen;
    uint32_t top = 0;
    int found = 0;

    Newxz(stack, graph->vertex_capacity, xg_vertex_id_t);
    Newxz(seen, graph->vertex_capacity, U8);
    /*
     * This is an iterative depth-first search used by acyclic insertion.
     * The arrays are sized by vertex_capacity, so each vertex is pushed at
     * most once.
     */
    stack[top++] = start;
    seen[start] = 1;
    while (top) {
        xg_vertex_id_t id = stack[--top];
        xg_adj_list *out;
        uint32_t i;
        if (id == wanted) {
            found = 1;
            break;
        }
        if (id >= graph->vertex_capacity || !graph->vertices[id].live)
            continue;
        out = graph->vertices[id].out;
        if (!out)
            continue;
        for (i = 0; i < out->count; i++) {
            xg_vertex_id_t next = xg_entry_vertex(out->entries[i]);
            if (!seen[next]) {
                seen[next] = 1;
                stack[top++] = next;
            }
        }
    }
    Safefree(stack);
    Safefree(seen);
    return found;
}

/* ----------------------------- Edge mutation ---------------------------- */

void
xg_add_edge(pTHX_ xg_graph *graph, xg_vertex_id_t from,
            xg_vertex_id_t to, SV *label)
{
    SV *normalized;
    xg_label_id_t lid;
    xg_entry_t out_entry;
    xg_entry_t in_entry;
    uint32_t i;

    xg_require_mutable(aTHX_ graph);
    normalized = xg_normalize_label(aTHX_ label);
    SAVEFREESV(normalized);
    xg_require_vertex(aTHX_ graph, from);
    xg_require_vertex(aTHX_ graph, to);
    /*
     * Adding from -> to creates a cycle exactly when to can already reach
     * from.  Check this before publishing either adjacency entry.
     */
    if (graph->acyclic && (from == to || xg_reaches(aTHX_ graph, to, from)))
        xg_error(aTHX_ "CYCLE_REJECTED", NULL);
    lid = xg_label_id(aTHX_ graph, normalized, 0);
    out_entry = xg_pack(to, lid);
    in_entry = xg_pack(from, lid);
    if (!graph->vertices[from].out)
        graph->vertices[from].out = xg_adj_new(aTHX);
    if (!graph->vertices[to].in)
        graph->vertices[to].in = xg_adj_new(aTHX);
    i = xg_adj_lower_bound(graph->vertices[from].out, out_entry);
    if (i < graph->vertices[from].out->count &&
        graph->vertices[from].out->entries[i] == out_entry)
        xg_error(aTHX_ "EDGE_EXISTS", NULL);
    xg_adj_reserve(aTHX_ graph->vertices[from].out,
                   graph->vertices[from].out->count + 1);
    xg_adj_reserve(aTHX_ graph->vertices[to].in,
                   graph->vertices[to].in->count + 1);
    /*
     * Keep both directions in sync.  The two reserve calls happen first so
     * allocation failure cannot leave only one side of the edge installed.
     */
    xg_adj_insert(aTHX_ graph->vertices[from].out, out_entry);
    xg_adj_insert(aTHX_ graph->vertices[to].in, in_entry);
    graph->live_edges++;
    graph->topology_generation++;
}

int
xg_has_edge(pTHX_ const xg_graph *graph, xg_vertex_id_t from,
            xg_vertex_id_t to, SV *label)
{
    xg_label_id_t lid;
    xg_entry_t entry;
    xg_adj_list *out;
    uint32_t pos;
    xg_require_vertex(aTHX_ graph, from);
    xg_require_vertex(aTHX_ graph, to);
    /* Lookup mode must not intern an unknown label as a side effect. */
    lid = xg_label_id(aTHX_ (xg_graph *)graph, label, -1);
    if (!lid)
        return 0;
    entry = xg_pack(to, lid);
    out = graph->vertices[from].out;
    if (!out)
        return 0;
    pos = xg_adj_lower_bound(out, entry);
    return pos < out->count && out->entries[pos] == entry;
}

int
xg_delete_edge(pTHX_ xg_graph *graph, xg_vertex_id_t from,
               xg_vertex_id_t to, SV *label)
{
    xg_label_id_t lid;
    xg_entry_t out_entry;
    xg_entry_t in_entry;
    xg_adj_list *out;
    xg_adj_list *in;
    xg_require_mutable(aTHX_ graph);
    xg_require_vertex(aTHX_ graph, from);
    xg_require_vertex(aTHX_ graph, to);
    lid = xg_label_id(aTHX_ graph, label, -1);
    if (!lid)
        return 0;
    out_entry = xg_pack(to, lid);
    in_entry = xg_pack(from, lid);
    out = graph->vertices[from].out;
    in = graph->vertices[to].in;
    /* Removing the outgoing entry identifies the exact labelled tuple. */
    if (!out || !in || !xg_adj_remove(out, out_entry))
        return 0;
    if (!xg_adj_remove(in, in_entry))
        xg_error(aTHX_ "INVALID_ARGUMENT", "adjacency invariant violated");
    graph->live_edges--;
    graph->topology_generation++;
    return 1;
}

int
xg_delete_vertex(pTHX_ xg_graph *graph, xg_vertex_id_t id)
{
    xg_adj_list *out;
    xg_adj_list *in;
    uint32_t i;
    HE *he;

    xg_require_mutable(aTHX_ graph);
    if (!xg_has_vertex(graph, id))
        return 0;
    /*
     * Delete outgoing and incoming entries one at a time.  Each removal also
     * removes the matching entry from the neighboring vertex.
     */
    out = graph->vertices[id].out;
    while (out && out->count) {
        xg_entry_t entry = out->entries[0];
        xg_vertex_id_t to = xg_entry_vertex(entry);
        xg_label_id_t lid = xg_entry_label(entry);
        xg_adj_remove(graph->vertices[to].in, xg_pack(id, lid));
        xg_adj_remove(out, entry);
        graph->live_edges--;
    }
    in = graph->vertices[id].in;
    while (in && in->count) {
        xg_entry_t entry = in->entries[0];
        xg_vertex_id_t from = xg_entry_vertex(entry);
        xg_label_id_t lid = xg_entry_label(entry);
        xg_adj_remove(graph->vertices[from].out, xg_pack(id, lid));
        xg_adj_remove(in, entry);
        graph->live_edges--;
    }
    {
        SV *key = newSVuv(id);
        he = hv_fetch_ent(graph->vertex_names_by_id, key, 0, 0);
        SvREFCNT_dec(key);
    }
    if (he) {
        SV *name = newSVsv(HeVAL(he));
        hv_delete_ent(graph->vertex_ids_by_name, name, G_DISCARD, 0);
        SvREFCNT_dec(name);
        {
            SV *key = newSVuv(id);
            hv_delete_ent(graph->vertex_names_by_id, key, G_DISCARD, 0);
            SvREFCNT_dec(key);
        }
        graph->naming_generation++;
    }
    {
        SV *key = newSVuv(id);
        hv_delete_ent(graph->vertex_metadata_by_id, key, G_DISCARD, 0);
        SvREFCNT_dec(key);
    }
    graph->vertices[id].live = 0;
    graph->live_vertices--;
    graph->topology_generation++;
    return 1;
}

/* -------------------------- Perl result snapshots ----------------------- */

static AV *
xg_new_av(void)
{
    return newAV();
}

/*
 * These functions materialize native IDs into Perl arrays.  The native graph
 * does not keep Perl array objects for query results, so each call returns a
 * fresh snapshot.
 */
AV *
xg_vertex_ids(pTHX_ const xg_graph *graph)
{
    AV *result = xg_new_av();
    xg_vertex_id_t id;
    xg_require_usable(aTHX_ graph);
    for (id = 1; id < graph->next_vertex_id; id++)
        if (xg_has_vertex(graph, id))
            av_push(result, newSVuv(id));
    return result;
}

AV *
xg_labels(pTHX_ const xg_graph *graph)
{
    AV *result = xg_new_av();
    I32 i;
    xg_require_usable(aTHX_ graph);
    for (i = 1; i <= av_len(graph->labels_by_id); i++) {
        SV **svp = av_fetch(graph->labels_by_id, i, 0);
        av_push(result, svp ? newSVsv(*svp) : newSV(0));
    }
    return result;
}

static AV *
xg_edge_value(pTHX_ const xg_graph *graph, xg_vertex_id_t from,
             xg_vertex_id_t to, xg_label_id_t lid)
{
    AV *edge = newAV();
    av_push(edge, newSVuv(from));
    av_push(edge, newSVuv(to));
    av_push(edge, xg_label_value(aTHX_ graph, lid));
    return edge;
}

AV *
xg_edges(pTHX_ const xg_graph *graph)
{
    AV *result = xg_new_av();
    xg_vertex_id_t from;
    xg_require_usable(aTHX_ graph);
    for (from = 1; from < graph->next_vertex_id; from++) {
        xg_adj_list *out;
        uint32_t i;
        if (!xg_has_vertex(graph, from) || !(out = graph->vertices[from].out))
            continue;
        for (i = 0; i < out->count; i++) {
            xg_entry_t entry = out->entries[i];
            av_push(result, newRV_noinc((SV *)xg_edge_value(
                aTHX_ graph, from, xg_entry_vertex(entry),
                xg_entry_label(entry))));
        }
    }
    return result;
}

AV *
xg_edges_for_vertex(pTHX_ const xg_graph *graph, xg_vertex_id_t id,
                     int outgoing)
{
    AV *result = xg_new_av();
    xg_adj_list *list;
    uint32_t i;
    xg_require_vertex(aTHX_ graph, id);
    list = outgoing ? graph->vertices[id].out : graph->vertices[id].in;
    if (!list)
        return result;
    for (i = 0; i < list->count; i++) {
        xg_entry_t entry = list->entries[i];
        xg_vertex_id_t other = xg_entry_vertex(entry);
        xg_label_id_t lid = xg_entry_label(entry);
        av_push(result, newRV_noinc((SV *)xg_edge_value(
            aTHX_ graph, outgoing ? id : other, outgoing ? other : id, lid)));
    }
    return result;
}

AV *
xg_neighbors(pTHX_ const xg_graph *graph, xg_vertex_id_t id, int outgoing)
{
    AV *result = xg_new_av();
    xg_adj_list *list;
    uint32_t i;
    xg_require_vertex(aTHX_ graph, id);
    list = outgoing ? graph->vertices[id].out : graph->vertices[id].in;
    if (!list)
        return result;
    for (i = 0; i < list->count; i++)
        av_push(result, newSVuv(xg_entry_vertex(list->entries[i])));
    return result;
}

static int
xg_vertex_id_compare(const void *left, const void *right)
{
    xg_vertex_id_t a = *(const xg_vertex_id_t *)left;
    xg_vertex_id_t b = *(const xg_vertex_id_t *)right;
    return a < b ? -1 : a > b ? 1 : 0;
}

AV *
xg_undirected_neighbors(pTHX_ const xg_graph *graph, xg_vertex_id_t id)
{
    AV *result = xg_new_av();
    xg_adj_list *in;
    xg_adj_list *out;
    xg_vertex_id_t *ids;
    uint64_t total;
    uint32_t count = 0;
    uint32_t i;

    xg_require_vertex(aTHX_ graph, id);
    in = graph->vertices[id].in;
    out = graph->vertices[id].out;
    total = (uint64_t)(in ? in->count : 0) +
            (uint64_t)(out ? out->count : 0);
    /*
     * A directed graph can be viewed as undirected by combining both
     * adjacency lists.  Sorting and skipping equal IDs removes duplicates
     * caused by reciprocal edges, parallel labels, or a self-loop.
     */
    if (!total)
        return result;
    if (total > UINT32_MAX)
        xg_error(aTHX_ "ALLOCATION_FAILED", "neighbor list is too large");
    Newx(ids, (size_t)total, xg_vertex_id_t);
    if (in)
        for (i = 0; i < in->count; i++)
            ids[count++] = xg_entry_vertex(in->entries[i]);
    if (out)
        for (i = 0; i < out->count; i++)
            ids[count++] = xg_entry_vertex(out->entries[i]);
    qsort(ids, count, sizeof(*ids), xg_vertex_id_compare);
    for (i = 0; i < count; i++) {
        if (i && ids[i] == ids[i - 1])
            continue;
        av_push(result, newSVuv(ids[i]));
    }
    Safefree(ids);
    return result;
}

uint32_t
xg_degree(pTHX_ const xg_graph *graph, xg_vertex_id_t id, int outgoing)
{
    xg_require_vertex(aTHX_ graph, id);
    return (outgoing ? graph->vertices[id].out : graph->vertices[id].in)
        ? (outgoing ? graph->vertices[id].out : graph->vertices[id].in)->count
        : 0;
}

/* ------------------------------- Traversals ----------------------------- */

static xg_adj_list *
xg_walk_list(const xg_graph *graph, xg_vertex_id_t id, int incoming)
{
    return incoming ? graph->vertices[id].in : graph->vertices[id].out;
}

static AV *
xg_reverse_ids(pTHX_ AV *reverse)
{
    AV *result = newAV();
    I32 i;
    for (i = av_len(reverse); i >= 0; i--) {
        SV **svp = av_fetch(reverse, i, 0);
        av_push(result, svp ? newSVsv(*svp) : newSV(0));
    }
    SvREFCNT_dec(reverse);
    return result;
}

AV *
xg_path(pTHX_ const xg_graph *graph, xg_vertex_id_t from,
        xg_vertex_id_t to, int incoming)
{
    U8 *seen;
    xg_vertex_id_t *previous;
    xg_vertex_id_t *queue;
    uint32_t head = 0;
    uint32_t tail = 0;
    int found = 0;
    AV *reverse;
    xg_vertex_id_t current;

    /*
     * Breadth-first search stores one predecessor per discovered vertex.
     * Following those predecessors backwards reconstructs a shortest path.
     * The incoming flag runs the same search over reverse edges.
     */
    xg_require_usable(aTHX_ graph);
    xg_require_vertex(aTHX_ graph, from);
    xg_require_vertex(aTHX_ graph, to);
    /*
     * A request from a vertex to itself is a cycle query in XGraph.  Search
     * for a real loop rather than returning the trivial one-vertex path.
     */
    if (from == to) {
        xg_vertex_id_t *cycle_queue;
        xg_vertex_id_t *cycle_previous;
        U8 *cycle_seen;
        uint32_t cycle_head = 0;
        uint32_t cycle_tail = 0;
        xg_adj_list *list = xg_walk_list(graph, from, incoming);
        Newxz(cycle_seen, graph->vertex_capacity, U8);
        Newxz(cycle_previous, graph->vertex_capacity, xg_vertex_id_t);
        Newxz(cycle_queue, graph->vertex_capacity, xg_vertex_id_t);
        cycle_seen[from] = 1;
        if (list) {
            for (uint32_t i = 0; i < list->count; i++) {
                xg_vertex_id_t next = xg_entry_vertex(list->entries[i]);
                if (next == from) {
                    AV *loop = newAV();
                    av_push(loop, newSVuv(from));
                    av_push(loop, newSVuv(from));
                    Safefree(cycle_seen);
                    Safefree(cycle_previous);
                    Safefree(cycle_queue);
                    return loop;
                }
                if (!cycle_seen[next]) {
                    cycle_seen[next] = 1;
                    cycle_previous[next] = from;
                    cycle_queue[cycle_tail++] = next;
                }
            }
        }
        while (cycle_head < cycle_tail) {
            xg_vertex_id_t current = cycle_queue[cycle_head++];
            xg_adj_list *next_list = xg_walk_list(graph, current, incoming);
            if (!next_list)
                continue;
            for (uint32_t i = 0; i < next_list->count; i++) {
                xg_vertex_id_t next = xg_entry_vertex(next_list->entries[i]);
                if (next == from) {
                    AV *result = newAV();
                    xg_vertex_id_t walk = current;
                    av_push(result, newSVuv(from));
                    while (walk != from) {
                        av_push(result, newSVuv(walk));
                        walk = cycle_previous[walk];
                    }
                    av_push(result, newSVuv(from));
                    Safefree(cycle_seen);
                    Safefree(cycle_previous);
                    Safefree(cycle_queue);
                    return xg_reverse_ids(aTHX_ result);
                }
                if (!cycle_seen[next]) {
                    cycle_seen[next] = 1;
                    cycle_previous[next] = current;
                    cycle_queue[cycle_tail++] = next;
                }
            }
        }
        Safefree(cycle_seen);
        Safefree(cycle_previous);
        Safefree(cycle_queue);
        return NULL;
    }
    Newxz(seen, graph->vertex_capacity, U8);
    Newxz(previous, graph->vertex_capacity, xg_vertex_id_t);
    Newxz(queue, graph->vertex_capacity, xg_vertex_id_t);
    seen[from] = 1;
    queue[tail++] = from;
    while (head < tail && !found) {
        xg_vertex_id_t id = queue[head++];
        xg_adj_list *list = xg_walk_list(graph, id, incoming);
        uint32_t i;
        if (!list)
            continue;
        for (i = 0; i < list->count; i++) {
            xg_vertex_id_t next = xg_entry_vertex(list->entries[i]);
            if (seen[next])
                continue;
            seen[next] = 1;
            previous[next] = id;
            if (next == to) {
                found = 1;
                break;
            }
            queue[tail++] = next;
        }
    }
    Safefree(seen);
    Safefree(queue);
    if (!found) {
        Safefree(previous);
        return NULL;
    }
    reverse = newAV();
    current = to;
    while (current) {
        av_push(reverse, newSVuv(current));
        if (current == from)
            break;
        current = previous[current];
    }
    Safefree(previous);
    return xg_reverse_ids(aTHX_ reverse);
}

int
xg_has_path(pTHX_ const xg_graph *graph, xg_vertex_id_t from,
            xg_vertex_id_t to, int incoming)
{
    AV *path = xg_path(aTHX_ graph, from, to, incoming);
    int found = path != NULL;
    SvREFCNT_dec(path);
    return found;
}

AV *
xg_reachable(pTHX_ const xg_graph *graph, xg_vertex_id_t start,
              int incoming, int strict)
{
    AV *result = newAV();
    U8 *seen;
    xg_vertex_id_t *queue;
    uint32_t head = 0;
    uint32_t tail = 0;
    xg_vertex_id_t id;

    xg_require_usable(aTHX_ graph);
    xg_require_vertex(aTHX_ graph, start);
    Newxz(seen, graph->vertex_capacity, U8);
    Newxz(queue, graph->vertex_capacity, xg_vertex_id_t);
    /* Mark vertices when enqueued so each vertex enters the queue once. */
    seen[start] = 1;
    queue[tail++] = start;
    while (head < tail) {
        xg_adj_list *list;
        uint32_t i;
        id = queue[head++];
        list = xg_walk_list(graph, id, incoming);
        if (!list)
            continue;
        for (i = 0; i < list->count; i++) {
            xg_vertex_id_t next = xg_entry_vertex(list->entries[i]);
            if (!seen[next]) {
                seen[next] = 1;
                queue[tail++] = next;
            }
        }
    }
    for (id = 1; id < graph->next_vertex_id; id++)
        if (seen[id] && (!strict || id != start ||
                         xg_has_path(aTHX_ graph, start, start, incoming)))
            av_push(result, newSVuv(id));
    Safefree(seen);
    Safefree(queue);
    return result;
}

AV *
xg_dfs_order(pTHX_ const xg_graph *graph, xg_vertex_id_t start,
             int incoming, int postorder)
{
    AV *result = newAV();
    xg_vertex_id_t *stack;
    uint32_t *positions;
    U8 *seen;
    uint32_t top = 0;
    xg_vertex_id_t id;

    xg_require_usable(aTHX_ graph);
    xg_require_vertex(aTHX_ graph, start);
    Newxz(stack, graph->vertex_capacity, xg_vertex_id_t);
    Newxz(positions, graph->vertex_capacity, uint32_t);
    Newxz(seen, graph->vertex_capacity, U8);
    /*
     * The stack stores the current DFS path.  positions[id] remembers which
     * adjacency entry should be examined next, which lets us avoid recursion.
     */
    stack[top++] = start;
    seen[start] = 1;
    if (!postorder)
        av_push(result, newSVuv(start));
    while (top) {
        xg_vertex_id_t current = stack[top - 1];
        xg_adj_list *list = xg_walk_list(graph, current, incoming);
        if (list && positions[current] < list->count) {
            xg_vertex_id_t next = xg_entry_vertex(
                list->entries[positions[current]++]);
            if (!seen[next]) {
                seen[next] = 1;
                stack[top++] = next;
                if (!postorder)
                    av_push(result, newSVuv(next));
            }
        } else {
            top--;
            if (postorder)
                av_push(result, newSVuv(current));
        }
    }
    Safefree(stack);
    Safefree(positions);
    Safefree(seen);
    return result;
}

AV *
xg_topological_sort(pTHX_ const xg_graph *graph)
{
    AV *result = newAV();
    uint32_t *degree;
    xg_vertex_id_t *ready;
    uint32_t ready_count = 0;
    xg_vertex_id_t id;

    xg_require_usable(aTHX_ graph);
    Newxz(degree, graph->vertex_capacity, uint32_t);
    Newxz(ready, graph->vertex_capacity, xg_vertex_id_t);
    /*
     * Kahn's algorithm repeatedly removes a vertex with zero incoming degree.
     * The ready array is kept sorted so the result is deterministic.
     */
    for (id = 1; id < graph->next_vertex_id; id++) {
        if (!xg_has_vertex(graph, id))
            continue;
        degree[id] = xg_degree(aTHX_ graph, id, 0);
        if (!degree[id])
            ready[ready_count++] = id;
    }
    while (ready_count) {
        uint32_t i;
        xg_vertex_id_t current = ready[0];
        xg_adj_list *out = graph->vertices[current].out;
        av_push(result, newSVuv(current));
        for (i = 1; i < ready_count; i++)
            ready[i - 1] = ready[i];
        ready_count--;
        if (out) {
            for (i = 0; i < out->count; i++) {
                xg_vertex_id_t next = xg_entry_vertex(out->entries[i]);
                if (--degree[next] == 0) {
                    uint32_t pos = ready_count;
                    while (pos && ready[pos - 1] > next) {
                        ready[pos] = ready[pos - 1];
                        pos--;
                    }
                    ready[pos] = next;
                    ready_count++;
                }
            }
        }
    }
    Safefree(degree);
    Safefree(ready);
    if ((uint32_t)(av_len(result) + 1) != graph->live_vertices) {
        SvREFCNT_dec(result);
        return NULL;
    }
    return result;
}

AV *
xg_source_vertices(pTHX_ const xg_graph *graph)
{
    AV *result = newAV();
    xg_vertex_id_t id;
    xg_require_usable(aTHX_ graph);
    for (id = 1; id < graph->next_vertex_id; id++)
        if (xg_has_vertex(graph, id) && xg_degree(aTHX_ graph, id, 0) == 0)
            av_push(result, newSVuv(id));
    return result;
}

AV *
xg_sink_vertices(pTHX_ const xg_graph *graph)
{
    AV *result = newAV();
    xg_vertex_id_t id;
    xg_require_usable(aTHX_ graph);
    for (id = 1; id < graph->next_vertex_id; id++)
        if (xg_has_vertex(graph, id) && xg_degree(aTHX_ graph, id, 1) == 0)
            av_push(result, newSVuv(id));
    return result;
}

AV *
xg_loop_vertices(pTHX_ const xg_graph *graph)
{
    AV *result = newAV();
    xg_vertex_id_t id;
    xg_require_usable(aTHX_ graph);
    for (id = 1; id < graph->next_vertex_id; id++) {
        xg_adj_list *out;
        uint32_t i;
        if (!xg_has_vertex(graph, id) || !(out = graph->vertices[id].out))
            continue;
        for (i = 0; i < out->count; i++)
            if (xg_entry_vertex(out->entries[i]) == id) {
                av_push(result, newSVuv(id));
                break;
            }
    }
    return result;
}

/* ----------------------- Connected-component algorithms ----------------- */

static void
xg_finish_from(pTHX_ const xg_graph *graph, xg_vertex_id_t start,
               int incoming, U8 *seen, AV *finish)
{
    xg_vertex_id_t *stack;
    uint32_t *positions;
    uint32_t top = 0;
    Newxz(stack, graph->vertex_capacity, xg_vertex_id_t);
    Newxz(positions, graph->vertex_capacity, uint32_t);
    /* First pass of Kosaraju's algorithm records DFS finish order. */
    stack[top++] = start;
    seen[start] = 1;
    while (top) {
        xg_vertex_id_t current = stack[top - 1];
        xg_adj_list *list = xg_walk_list(graph, current, incoming);
        if (list && positions[current] < list->count) {
            xg_vertex_id_t next = xg_entry_vertex(
                list->entries[positions[current]++]);
            if (!seen[next]) {
                seen[next] = 1;
                stack[top++] = next;
            }
        } else {
            top--;
            av_push(finish, newSVuv(current));
        }
    }
    Safefree(stack);
    Safefree(positions);
}

static void
xg_mark_component(pTHX_ const xg_graph *graph, xg_vertex_id_t start,
                  int strong, U32 mark, U32 *marks)
{
    xg_vertex_id_t *stack;
    uint32_t top = 0;
    Newxz(stack, graph->vertex_capacity, xg_vertex_id_t);
    stack[top++] = start;
    marks[start] = mark;
    while (top) {
        xg_vertex_id_t current = stack[--top];
        xg_adj_list *list = graph->vertices[current].in;
        uint32_t i;
        /*
         * For strong components, walk reverse edges during the second
         * Kosaraju pass.  For weak components, walk both directions.
         */
        if (strong) {
            if (!list)
                continue;
            for (i = 0; i < list->count; i++) {
                xg_vertex_id_t next = xg_entry_vertex(list->entries[i]);
                if (!marks[next]) {
                    marks[next] = mark;
                    stack[top++] = next;
                }
            }
        } else {
            for (int direction = 0; direction < 2; direction++) {
                list = direction ? graph->vertices[current].out
                                  : graph->vertices[current].in;
                if (!list)
                    continue;
                for (i = 0; i < list->count; i++) {
                    xg_vertex_id_t next = xg_entry_vertex(list->entries[i]);
                    if (!marks[next]) {
                        marks[next] = mark;
                        stack[top++] = next;
                    }
                }
            }
        }
    }
    Safefree(stack);
}

static int
xg_component_compare(const void *left, const void *right)
{
    AV *a = MUTABLE_AV(SvRV(*(SV * const *)left));
    AV *b = MUTABLE_AV(SvRV(*(SV * const *)right));
    SV **as = av_fetch(a, 0, 0);
    SV **bs = av_fetch(b, 0, 0);
    UV av = as ? SvUV(*as) : 0;
    UV bv = bs ? SvUV(*bs) : 0;
    return av < bv ? -1 : av > bv ? 1 : 0;
}

static int
xg_component_member_compare(const void *left, const void *right)
{
    SV *a = *(SV * const *)left;
    SV *b = *(SV * const *)right;
    UV av = SvUV(a);
    UV bv = SvUV(b);
    return av < bv ? -1 : av > bv ? 1 : 0;
}

typedef struct xg_tarjan_frame {
    xg_vertex_id_t vertex;
    uint32_t next_edge;
} xg_tarjan_frame;

/*
 * Tarjan's algorithm finds all strongly connected components in one DFS.
 *
 * index[v] is the order in which v was first visited.  low[v] is the
 * smallest index reachable from v while staying on the current DFS stack.
 * When low[v] == index[v], v is the root of one complete component.
 *
 * The textbook description uses recursion.  The explicit frame stack below
 * stores the same "where should this DFS resume?" information without using
 * the C call stack, so very deep graphs are safe.
 */
AV *
xg_components_tarjan(pTHX_ const xg_graph *graph)
{
    AV *components = newAV();
    uint32_t *indices;
    uint32_t *low;
    U8 *on_stack;
    xg_vertex_id_t *vertex_stack;
    xg_tarjan_frame *frames;
    uint32_t next_index = 0;
    uint32_t stack_count = 0;
    uint32_t frame_count = 0;
    xg_vertex_id_t root;

    xg_require_usable(aTHX_ graph);
    Newxz(indices, graph->vertex_capacity, uint32_t);
    Newxz(low, graph->vertex_capacity, uint32_t);
    Newxz(on_stack, graph->vertex_capacity, U8);
    Newxz(vertex_stack, graph->vertex_capacity, xg_vertex_id_t);
    Newxz(frames, graph->vertex_capacity, xg_tarjan_frame);

    for (root = 1; root < graph->next_vertex_id; root++) {
        if (!xg_has_vertex(graph, root) || indices[root])
            continue;

        indices[root] = low[root] = ++next_index;
        on_stack[root] = 1;
        vertex_stack[stack_count++] = root;
        frames[frame_count].vertex = root;
        frames[frame_count].next_edge = 0;
        frame_count++;

        while (frame_count) {
            xg_tarjan_frame *frame = &frames[frame_count - 1];
            xg_adj_list *out = graph->vertices[frame->vertex].out;

            if (out && frame->next_edge < out->count) {
                xg_vertex_id_t next = xg_entry_vertex(
                    out->entries[frame->next_edge++]);

                if (!indices[next]) {
                    indices[next] = low[next] = ++next_index;
                    on_stack[next] = 1;
                    vertex_stack[stack_count++] = next;
                    frames[frame_count].vertex = next;
                    frames[frame_count].next_edge = 0;
                    frame_count++;
                } else if (on_stack[next] &&
                           low[frame->vertex] > indices[next]) {
                    low[frame->vertex] = indices[next];
                }
                continue;
            }

            {
                xg_vertex_id_t finished = frame->vertex;
                frame_count--;

                /*
                 * The parent resumes after this child finishes.  Its low
                 * value may inherit the child's low value.
                 */
                if (frame_count) {
                    xg_vertex_id_t parent = frames[frame_count - 1].vertex;
                    if (low[parent] > low[finished])
                        low[parent] = low[finished];
                }

                if (low[finished] == indices[finished]) {
                    AV *component = newAV();
                    xg_vertex_id_t member;

                    do {
                        member = vertex_stack[--stack_count];
                        on_stack[member] = 0;
                        av_push(component, newSVuv(member));
                    } while (member != finished);

                    qsort(AvARRAY(component), (size_t)av_len(component) + 1,
                          sizeof(SV *), xg_component_member_compare);
                    av_push(components, newRV_noinc((SV *)component));
                }
            }
        }
    }

    if (av_len(components) >= 1)
        qsort(AvARRAY(components), (size_t)av_len(components) + 1,
              sizeof(SV *), xg_component_compare);
    Safefree(indices);
    Safefree(low);
    Safefree(on_stack);
    Safefree(vertex_stack);
    Safefree(frames);
    return components;
}

typedef struct xg_pearce_frame {
    xg_vertex_id_t vertex;
    uint32_t next_edge;
    xg_vertex_id_t pending_child;
} xg_pearce_frame;

/*
 * Pearce's space-efficient SCC algorithm keeps one rindex value per vertex.
 * While a vertex is still being explored, rindex is its visitation index or
 * the visitation index of its local root.  Once its component is complete,
 * rindex becomes that component's label.  Component labels are chosen above
 * all live visitation indices, so an already completed successor can never
 * incorrectly lower the current vertex's local root.
 *
 * The paper presents this as PEA FIND SCC3.  Its imperative Algorithm 4 uses
 * two stacks: one for the active DFS path and one for vertices waiting to be
 * assigned to a component.  The frame below stores the same continuation as
 * the paper's edge-position stack, while pending_child tells us which tree
 * edge must be finished when a child returns.  No C recursion is needed.
 */
AV *
xg_components_pearce(pTHX_ const xg_graph *graph)
{
    AV *components = newAV();
    uint32_t *rindex;
    U8 *is_root;
    xg_vertex_id_t *component_stack;
    xg_pearce_frame *frames;
    AV **component_by_label;
    uint32_t visit_count = 0;
    uint32_t component_count = 0;
    uint32_t index = 1;
    uint32_t component_label = graph->live_vertices
        ? graph->live_vertices : 1;
    xg_vertex_id_t start;

    xg_require_usable(aTHX_ graph);
    Newxz(rindex, graph->vertex_capacity, uint32_t);
    Newxz(is_root, graph->vertex_capacity, U8);
    Newxz(component_stack, graph->vertex_capacity, xg_vertex_id_t);
    Newxz(frames, graph->vertex_capacity, xg_pearce_frame);
    Newxz(component_by_label, graph->vertex_capacity, AV *);

    for (start = 1; start < graph->next_vertex_id; start++) {
        if (!xg_has_vertex(graph, start) || rindex[start])
            continue;

        /* beginVisiting(start): assign its first local-root index. */
        rindex[start] = index++;
        is_root[start] = 1;
        visit_count++;
        frames[visit_count - 1].vertex = start;
        frames[visit_count - 1].next_edge = 0;
        frames[visit_count - 1].pending_child = 0;

        while (visit_count) {
            xg_pearce_frame *frame = &frames[visit_count - 1];
            xg_vertex_id_t vertex = frame->vertex;
            xg_adj_list *out = graph->vertices[vertex].out;

            /* Finish the tree edge whose child has just returned. */
            if (frame->pending_child) {
                xg_vertex_id_t child = frame->pending_child;
                frame->pending_child = 0;
                if (rindex[child] < rindex[vertex]) {
                    rindex[vertex] = rindex[child];
                    is_root[vertex] = 0;
                }
                continue;
            }

            if (out && frame->next_edge < out->count) {
                xg_vertex_id_t next = xg_entry_vertex(
                    out->entries[frame->next_edge++]);
                if (!rindex[next]) {
                    /* beginEdge: save the continuation before descending. */
                    frame->pending_child = next;
                    rindex[next] = index++;
                    is_root[next] = 1;
                    frames[visit_count].vertex = next;
                    frames[visit_count].next_edge = 0;
                    frames[visit_count].pending_child = 0;
                    visit_count++;
                } else if (rindex[next] < rindex[vertex]) {
                    /* finishEdge for a back or cross edge. */
                    rindex[vertex] = rindex[next];
                    is_root[vertex] = 0;
                }
                continue;
            }

            /* finishVisiting: pop the DFS frame and, if it is a root, emit. */
            visit_count--;
            if (is_root[vertex]) {
                xg_vertex_id_t member;
                index--;
                while (component_count &&
                       rindex[vertex] <=
                       rindex[component_stack[component_count - 1]]) {
                    member = component_stack[--component_count];
                    rindex[member] = component_label;
                    index--;
                }
                rindex[vertex] = component_label--;
            } else {
                component_stack[component_count++] = vertex;
            }
        }
    }

    /* IDs are scanned in ascending order, so members and components arrive
     * already sorted in the same deterministic form as the other SCC APIs. */
    for (xg_vertex_id_t id = 1; id < graph->next_vertex_id; id++) {
        AV *component;
        uint32_t label;
        if (!xg_has_vertex(graph, id))
            continue;
        label = rindex[id];
        if (!label)
            xg_error(aTHX_ "INVALID_ARGUMENT", "Pearce SCC state incomplete");
        component = component_by_label[label];
        if (!component) {
            component = newAV();
            component_by_label[label] = component;
            av_push(components, newRV_noinc((SV *)component));
        }
        av_push(component, newSVuv(id));
    }

    Safefree(rindex);
    Safefree(is_root);
    Safefree(component_stack);
    Safefree(frames);
    Safefree(component_by_label);
    return components;
}

/*
 * This is the iterative Tarjan variant used by current SciPy releases.  It
 * follows the Tarjan--Zwick idea of counting discovery timestamps downwards
 * and reusing one high-link array for both active DFS state and final
 * component labels.  A component label is always smaller than an active
 * high-link value, so an edge to a finished component can be ignored without
 * a separate "already assigned" array.
 *
 * SciPy stores the lead bit in the sign bit of its DFS stack entries.  XGraph
 * wide mode permits the full uint32_t vertex-ID range, so using that bit would
 * make some valid IDs ambiguous.  The parallel lead array below preserves the
 * same algorithm and invariant while keeping IDs lossless.
 */
AV *
xg_components_tarjan_zwick(pTHX_ const xg_graph *graph)
{
    AV *components = newAV();
    uint32_t *successor_position;
    uint32_t *high_link;
    U8 *lead;
    xg_vertex_id_t *dfs_stack;
    xg_vertex_id_t *component_stack;
    AV **component_by_label;
    uint32_t dfs_count = 0;
    uint32_t pending_count = 0;
    uint32_t component_count = 0;
    uint32_t index;
    xg_vertex_id_t start;

    xg_require_usable(aTHX_ graph);
    if (!graph->live_vertices)
        return components;

    index = graph->live_vertices;
    Newxz(successor_position, graph->vertex_capacity, uint32_t);
    Newxz(high_link, graph->vertex_capacity, uint32_t);
    Newxz(lead, graph->vertex_capacity, U8);
    Newxz(dfs_stack, graph->vertex_capacity, xg_vertex_id_t);
    Newxz(component_stack, graph->vertex_capacity, xg_vertex_id_t);
    Newxz(component_by_label, graph->vertex_capacity, AV *);
    for (xg_vertex_id_t id = 0; id < graph->vertex_capacity; id++)
        successor_position[id] = UINT32_MAX;

    for (start = 1; start < graph->next_vertex_id; start++) {
        xg_vertex_id_t vertex;
        if (!xg_has_vertex(graph, start) ||
            successor_position[start] != UINT32_MAX)
            continue;

        /* Previsit a new DFS-tree root. */
        dfs_stack[dfs_count] = start;
        lead[dfs_count] = 1;
        dfs_count++;
        high_link[start] = index--;
        successor_position[start] = 0;

        while (dfs_count) {
            xg_adj_list *out;
            vertex = dfs_stack[dfs_count - 1];
            out = graph->vertices[vertex].out;

            if (out && successor_position[vertex] < out->count) {
                xg_vertex_id_t next = xg_entry_vertex(
                    out->entries[successor_position[vertex]++]);

                if (successor_position[next] == UINT32_MAX) {
                    /* Tree edge: save the child and continue its DFS. */
                    dfs_stack[dfs_count] = next;
                    lead[dfs_count] = 1;
                    dfs_count++;
                    high_link[next] = index--;
                    successor_position[next] = 0;
                } else if (high_link[vertex] < high_link[next]) {
                    /* Back/cross edge to an active vertex raises high_link. */
                    lead[dfs_count - 1] = 0;
                    high_link[vertex] = high_link[next];
                }
                continue;
            }

            /* Postvisit.  A lead vertex closes one SCC; a non-lead vertex
             * waits on the component stack for its lead to finish. */
            if (lead[dfs_count - 1]) {
                xg_vertex_id_t member;
                dfs_count--;
                while (pending_count) {
                    member = component_stack[pending_count - 1];
                    if (high_link[vertex] < high_link[member])
                        break;
                    component_stack[--pending_count] = 0;
                    high_link[member] = component_count;
                    index++;
                }
                high_link[vertex] = component_count;
                index++;
                component_count++;
            } else {
                xg_vertex_id_t parent;
                dfs_count--;
                component_stack[pending_count++] = vertex;
                if (!dfs_count)
                    continue;
                parent = dfs_stack[dfs_count - 1];
                if (high_link[parent] < high_link[vertex]) {
                    lead[dfs_count - 1] = 0;
                    high_link[parent] = high_link[vertex];
                }
            }
        }
    }

    /* Group by the final labels.  The ID scan appends members in ascending
     * order, so no per-component member sort is needed here. */
    for (xg_vertex_id_t id = 1; id < graph->next_vertex_id; id++) {
        AV *component;
        uint32_t label;
        if (!xg_has_vertex(graph, id))
            continue;
        label = high_link[id];
        component = component_by_label[label];
        if (!component) {
            component = newAV();
            component_by_label[label] = component;
            av_push(components, newRV_noinc((SV *)component));
        }
        av_push(component, newSVuv(id));
    }
    if (av_len(components) >= 1)
        qsort(AvARRAY(components), (size_t)av_len(components) + 1,
              sizeof(SV *), xg_component_compare);

    Safefree(successor_position);
    Safefree(high_link);
    Safefree(lead);
    Safefree(dfs_stack);
    Safefree(component_stack);
    Safefree(component_by_label);
    return components;
}

AV *
xg_components(pTHX_ const xg_graph *graph, int strong, int cyclic_only)
{
    AV *finish = newAV();
    AV *components = newAV();
    U8 *seen;
    U32 *marks;
    U32 component_count = 0;
    xg_vertex_id_t id;

    xg_require_usable(aTHX_ graph);
    Newxz(seen, graph->vertex_capacity, U8);
    Newxz(marks, graph->vertex_capacity, U32);
    /*
     * Strong components use Kosaraju's two DFS passes.  Weak components use
     * one traversal over the union of incoming and outgoing edges.
     */
    if (strong) {
        for (id = 1; id < graph->next_vertex_id; id++)
            if (xg_has_vertex(graph, id) && !seen[id])
                xg_finish_from(aTHX_ graph, id, 0, seen, finish);
        memset(seen, 0, graph->vertex_capacity * sizeof(U8));
        for (I32 i = av_len(finish); i >= 0; i--) {
            SV **svp = av_fetch(finish, i, 0);
            xg_vertex_id_t start = svp ? (xg_vertex_id_t)SvUV(*svp) : 0;
            AV *component;
            if (!start || marks[start])
                continue;
            xg_mark_component(aTHX_ graph, start, 1,
                              ++component_count, marks);
            component = newAV();
            for (id = 1; id < graph->next_vertex_id; id++)
                if (marks[id] == component_count)
                    av_push(component, newSVuv(id));
            av_push(components, newRV_noinc((SV *)component));
        }
    } else {
        for (id = 1; id < graph->next_vertex_id; id++) {
            AV *component;
            if (!xg_has_vertex(graph, id) || marks[id])
                continue;
            xg_mark_component(aTHX_ graph, id, 0,
                              ++component_count, marks);
            component = newAV();
            for (xg_vertex_id_t member = 1;
                 member < graph->next_vertex_id; member++)
                if (marks[member] == component_count)
                    av_push(component, newSVuv(member));
            av_push(components, newRV_noinc((SV *)component));
        }
    }
    if (av_len(components) >= 1)
        qsort(AvARRAY(components), (size_t)av_len(components) + 1,
              sizeof(SV *), xg_component_compare);
    if (cyclic_only) {
        AV *filtered = newAV();
        for (I32 i = 0; i <= av_len(components); i++) {
            SV **svp = av_fetch(components, i, 0);
            AV *component = svp ? MUTABLE_AV(SvRV(*svp)) : NULL;
            int cyclic = component && av_len(component) >= 1;
            if (component && av_len(component) == 0) {
                SV **member = av_fetch(component, 0, 0);
                xg_vertex_id_t vertex = member ? SvUV(*member) : 0;
                xg_adj_list *out = vertex ? graph->vertices[vertex].out : NULL;
                if (out)
                    for (uint32_t j = 0; j < out->count; j++)
                        if (xg_entry_vertex(out->entries[j]) == vertex)
                            cyclic = 1;
            }
            if (cyclic && svp)
                av_push(filtered, SvREFCNT_inc(*svp));
        }
        SvREFCNT_dec(components);
        components = filtered;
    }
    Safefree(seen);
    Safefree(marks);
    SvREFCNT_dec(finish);
    return components;
}

/* --------------------------- Graph predicates ---------------------------- */

int
xg_is_acyclic(pTHX_ const xg_graph *graph)
{
    /* A graph is acyclic exactly when a topological order contains all nodes. */
    AV *sorted = xg_topological_sort(aTHX_ graph);
    int result = sorted != NULL;
    SvREFCNT_dec(sorted);
    return result;
}

AV *
xg_cycle(pTHX_ const xg_graph *graph, int shortest)
{
    AV *best = NULL;
    xg_vertex_id_t from;
    xg_require_usable(aTHX_ graph);
    /*
     * Every non-loop cycle begins with an edge from -> to followed by a path
     * from to back to from.  Try that construction for each stored edge.
     */
    for (from = 1; from < graph->next_vertex_id; from++) {
        xg_adj_list *out;
        uint32_t i;
        if (!xg_has_vertex(graph, from) || !(out = graph->vertices[from].out))
            continue;
        for (i = 0; i < out->count; i++) {
            xg_vertex_id_t to = xg_entry_vertex(out->entries[i]);
            AV *tail;
            AV *candidate;
            if (from == to) {
                if (best)
                    SvREFCNT_dec(best);
                best = newAV();
                av_push(best, newSVuv(from));
                av_push(best, newSVuv(from));
                if (shortest)
                    return best;
                continue;
            }
            tail = xg_path(aTHX_ graph, to, from, 0);
            if (!tail)
                continue;
            candidate = newAV();
            av_push(candidate, newSVuv(from));
            for (I32 j = 0; j <= av_len(tail); j++) {
                SV **svp = av_fetch(tail, j, 0);
                av_push(candidate, svp ? newSVsv(*svp) : newSV(0));
            }
            SvREFCNT_dec(tail);
            if (!best || (shortest && av_len(candidate) < av_len(best))) {
                SvREFCNT_dec(best);
                best = candidate;
            } else {
                SvREFCNT_dec(candidate);
            }
        }
    }
    return best;
}

int
xg_is_tree(pTHX_ const xg_graph *graph)
{
    AV *components;
    AV *loops;
    int result;
    xg_require_usable(aTHX_ graph);
    /*
     * A tree has V-1 edges, no self-loop, and one weakly connected
     * component.  These checks are sufficient for this directed storage
     * because tree-ness is defined using the undirected view.
     */
    if (!graph->live_vertices || graph->live_edges != graph->live_vertices - 1)
        return 0;
    loops = xg_loop_vertices(aTHX_ graph);
    if (av_len(loops) >= 0) {
        SvREFCNT_dec(loops);
        return 0;
    }
    SvREFCNT_dec(loops);
    components = xg_components(aTHX_ graph, 0, 0);
    result = av_len(components) == 0;
    SvREFCNT_dec(components);
    return result;
}

int
xg_is_arborescence(pTHX_ const xg_graph *graph, xg_vertex_id_t *root_out)
{
    xg_vertex_id_t root = 0;
    xg_vertex_id_t id;
    AV *reachable;
    xg_require_usable(aTHX_ graph);
    /*
     * An arborescence has one root with in-degree zero and every other
     * vertex with in-degree one.  The final reachability check ensures all
     * vertices belong to the root's directed tree.
     */
    if (!graph->live_vertices || graph->live_edges != graph->live_vertices - 1)
        return 0;
    for (id = 1; id < graph->next_vertex_id; id++) {
        if (!xg_has_vertex(graph, id))
            continue;
        if (xg_degree(aTHX_ graph, id, 0) == 0) {
            if (root)
                return 0;
            root = id;
        } else if (xg_degree(aTHX_ graph, id, 0) != 1) {
            return 0;
        }
    }
    if (!root)
        return 0;
    reachable = xg_reachable(aTHX_ graph, root, 0, 0);
    if (av_len(reachable) + 1 != (I32)graph->live_vertices) {
        SvREFCNT_dec(reachable);
        return 0;
    }
    SvREFCNT_dec(reachable);
    if (root_out)
        *root_out = root;
    return 1;
}

/* --------------------------- Graph transformations ---------------------- */

static void
xg_copy_maps(pTHX_ xg_graph *dest, const xg_graph *source)
{
    I32 i;
    HE *he;

    /* Copy Perl registries separately from native topology arrays. */
    av_clear(dest->labels_by_id);
    for (i = 0; i <= av_len(source->labels_by_id); i++) {
        SV **svp = av_fetch(source->labels_by_id, i, 0);
        av_store(dest->labels_by_id, i, svp ? newSVsv(*svp) : newSV(0));
    }
    hv_clear(dest->label_ids_by_name);
    hv_iterinit(source->label_ids_by_name);
    while ((he = hv_iternext(source->label_ids_by_name))) {
        SV *key = hv_iterkeysv(he);
        SV *copy = newSVsv(key);
        hv_store_ent(dest->label_ids_by_name, copy,
                     newSVsv(HeVAL(he)), 0);
        SvREFCNT_dec(copy);
    }
    hv_clear(dest->vertex_names_by_id);
    hv_clear(dest->vertex_ids_by_name);
    hv_iterinit(source->vertex_names_by_id);
    while ((he = hv_iternext(source->vertex_names_by_id))) {
        SV *key = hv_iterkeysv(he);
        SV *value = HeVAL(he);
        SV *id_key = newSVsv(key);
        SV *name_key = newSVsv(value);
        hv_store_ent(dest->vertex_names_by_id, id_key,
                     newSVsv(value), 0);
        hv_store_ent(dest->vertex_ids_by_name, name_key,
                     newSVsv(key), 0);
        SvREFCNT_dec(id_key);
        SvREFCNT_dec(name_key);
    }
}

static void
xg_copy_vertex_metadata(pTHX_ xg_graph *dest, const xg_graph *source)
{
    HE *he;

    hv_clear(dest->vertex_metadata_by_id);
    hv_iterinit(source->vertex_metadata_by_id);
    while ((he = hv_iternext(source->vertex_metadata_by_id))) {
        SV *key = hv_iterkeysv(he);
        SV *copy = newSVsv(key);
        hv_store_ent(dest->vertex_metadata_by_id, copy,
                     newSVsv(HeVAL(he)), 0);
        SvREFCNT_dec(copy);
    }
}

xg_graph *
xg_clone(pTHX_ const xg_graph *source, U8 mutable_copy)
{
    xg_graph *dest;
    uint32_t i;

    /*
     * Cloning makes independent adjacency storage and copies Perl values.
     * mutable_copy changes only the frozen flag; it does not share state.
     */
    xg_require_usable(aTHX_ source);
    dest = xg_new(aTHX_ source->acyclic, source->strict_labels);
    dest->next_vertex_id = source->next_vertex_id;
    dest->live_vertices = source->live_vertices;
    dest->live_edges = source->live_edges;
    dest->topology_generation = source->topology_generation;
    dest->naming_generation = source->naming_generation;
    dest->frozen = mutable_copy ? 0 : source->frozen;
    xg_vertex_capacity(aTHX_ dest, source->vertex_capacity - 1);
    for (i = 0; i < source->vertex_capacity; i++) {
        const xg_vertex *srcv = &source->vertices[i];
        xg_vertex *dstv = &dest->vertices[i];
        uint32_t j;
        dstv->live = srcv->live;
        if (srcv->in) {
            dstv->in = xg_adj_new(aTHX);
            xg_adj_reserve(aTHX_ dstv->in, srcv->in->count);
            for (j = 0; j < srcv->in->count; j++)
                dstv->in->entries[j] = srcv->in->entries[j];
            dstv->in->count = srcv->in->count;
        }
        if (srcv->out) {
            dstv->out = xg_adj_new(aTHX);
            xg_adj_reserve(aTHX_ dstv->out, srcv->out->count);
            for (j = 0; j < srcv->out->count; j++)
                dstv->out->entries[j] = srcv->out->entries[j];
            dstv->out->count = srcv->out->count;
        }
    }
    xg_copy_maps(aTHX_ dest, source);
    xg_copy_vertex_metadata(aTHX_ dest, source);
    return dest;
}

static xg_vertex_id_t
xg_id_from_sv(pTHX_ SV *sv)
{
    NV numeric;
    UV value;
    if (!sv)
        xg_error(aTHX_ "INVALID_VERTEX_ID", NULL);
    SvGETMAGIC(sv);
    if (SvROK(sv) || !looks_like_number(sv))
        xg_error(aTHX_ "INVALID_VERTEX_ID", NULL);
    numeric = SvNV(sv);
    value = SvUV(sv);
    if (numeric < 1 || numeric > (NV)XG_MAX_VERTEX_ID ||
        (NV)value != numeric)
        xg_error(aTHX_ "INVALID_VERTEX_ID", NULL);
    return (xg_vertex_id_t)value;
}

AV *
xg_reachability_roots(pTHX_ const xg_graph *graph)
{
    AV *components = xg_components(aTHX_ graph, 1, 0);
    AV *result = newAV();
    U32 *component_of;
    U8 *has_incoming;
    xg_vertex_id_t id;
    I32 component_count = av_len(components) + 1;

    Newxz(component_of, graph->vertex_capacity, U32);
    Newxz(has_incoming, (size_t)component_count + 1, U8);
    /*
     * A component is a reachability root when no edge enters it from another
     * strongly connected component.
     */
    for (I32 i = 0; i < component_count; i++) {
        SV **svp = av_fetch(components, i, 0);
        AV *component = svp ? MUTABLE_AV(SvRV(*svp)) : NULL;
        if (!component)
            continue;
        for (I32 j = 0; j <= av_len(component); j++) {
            SV **member = av_fetch(component, j, 0);
            if (member)
                component_of[SvUV(*member)] = (U32)i + 1;
        }
    }
    for (id = 1; id < graph->next_vertex_id; id++) {
        xg_adj_list *out;
        uint32_t i;
        if (!xg_has_vertex(graph, id) || !(out = graph->vertices[id].out))
            continue;
        for (i = 0; i < out->count; i++) {
            xg_vertex_id_t to = xg_entry_vertex(out->entries[i]);
            if (component_of[id] != component_of[to])
                has_incoming[component_of[to]] = 1;
        }
    }
    for (I32 i = 0; i < component_count; i++) {
        SV **svp = av_fetch(components, i, 0);
        AV *component = svp ? MUTABLE_AV(SvRV(*svp)) : NULL;
        SV **member = component ? av_fetch(component, 0, 0) : NULL;
        if (!has_incoming[i + 1] && member)
            av_push(result, newSVsv(*member));
    }
    Safefree(component_of);
    Safefree(has_incoming);
    SvREFCNT_dec(components);
    return result;
}

xg_graph *
xg_induced_subgraph(pTHX_ const xg_graph *graph, AV *vertex_ids)
{
    xg_graph *result;
    U8 *selected;
    I32 i;
    xg_vertex_id_t id;

    /* Clone first to preserve IDs, names, and label registration order. */
    xg_require_usable(aTHX_ graph);
    result = xg_clone(aTHX_ graph, 1);
    Newxz(selected, result->vertex_capacity, U8);
    for (i = 0; i <= av_len(vertex_ids); i++) {
        SV **svp = av_fetch(vertex_ids, i, 0);
        id = xg_id_from_sv(aTHX_ svp ? *svp : NULL);
        xg_require_vertex(aTHX_ result, id);
        selected[id] = 1;
    }
    for (id = 1; id < result->next_vertex_id; id++)
        if (xg_has_vertex(result, id) && !selected[id])
            (void)xg_delete_vertex(aTHX_ result, id);
    Safefree(selected);
    return result;
}

xg_graph *
xg_condensation(pTHX_ const xg_graph *graph, AV **components_out,
                AV **component_of_out)
{
    AV *components = xg_components(aTHX_ graph, 1, 0);
    AV *component_of = newAV();
    xg_graph *result = xg_new(aTHX_ 1, graph->strict_labels);
    U32 *mapping;
    I32 component_count = av_len(components) + 1;
    xg_vertex_id_t id;

    /*
     * Replace each strongly connected component by one vertex.  Edges between
     * members of the same component disappear; parallel component edges are
     * collapsed by the normal unique-edge rule.
     */
    xg_require_usable(aTHX_ graph);
    xg_copy_maps(aTHX_ result, graph);
    Newxz(mapping, graph->vertex_capacity, U32);
    av_store(component_of, 0, newSV(0));
    for (I32 i = 0; i < component_count; i++) {
        SV **svp = av_fetch(components, i, 0);
        AV *component = svp ? MUTABLE_AV(SvRV(*svp)) : NULL;
        (void)xg_add_vertex(aTHX_ result, &PL_sv_undef);
        if (!component)
            continue;
        for (I32 j = 0; j <= av_len(component); j++) {
            SV **member = av_fetch(component, j, 0);
            if (member) {
                id = (xg_vertex_id_t)SvUV(*member);
                mapping[id] = (U32)i + 1;
                av_store(component_of, id, newSVuv((UV)i + 1));
            }
        }
    }
    for (id = 1; id < graph->next_vertex_id; id++) {
        xg_adj_list *out;
        uint32_t i;
        if (!xg_has_vertex(graph, id) || !(out = graph->vertices[id].out))
            continue;
        for (i = 0; i < out->count; i++) {
            xg_entry_t entry = out->entries[i];
            xg_vertex_id_t to = xg_entry_vertex(entry);
            xg_label_id_t label_id = xg_entry_label(entry);
            SV *label;
            if (mapping[id] == mapping[to])
                continue;
            label = xg_label_value(aTHX_ graph, label_id);
            if (!xg_has_edge(aTHX_ result, mapping[id], mapping[to], label))
                xg_add_edge(aTHX_ result, mapping[id], mapping[to], label);
            SvREFCNT_dec(label);
        }
    }
    Safefree(mapping);
    *components_out = components;
    *component_of_out = component_of;
    return result;
}

static UV
xg_delete_all_between(pTHX_ xg_graph *graph, xg_vertex_id_t from,
                      xg_vertex_id_t to)
{
    UV removed = 0;
    xg_adj_list *out = graph->vertices[from].out;
    while (out) {
        uint32_t i;
        xg_label_id_t label_id;
        SV *label;
        int found = 0;
        for (i = 0; i < out->count; i++) {
            if (xg_entry_vertex(out->entries[i]) == to) {
                label_id = xg_entry_label(out->entries[i]);
                found = 1;
                label = xg_label_value(aTHX_ graph, label_id);
                (void)xg_delete_edge(aTHX_ graph, from, to, label);
                SvREFCNT_dec(label);
                removed++;
                break;
            }
            if (xg_entry_vertex(out->entries[i]) > to)
                break;
        }
        if (!found)
            break;
    }
    return removed;
}

UV
xg_delete_paths(pTHX_ xg_graph *graph, xg_vertex_id_t from,
                xg_vertex_id_t to)
{
    UV removed = 0;
    xg_require_mutable(aTHX_ graph);
    xg_require_vertex(aTHX_ graph, from);
    xg_require_vertex(aTHX_ graph, to);
    /* Remove every edge on one found path, then search again until none remain. */
    for (;;) {
        AV *path = xg_path(aTHX_ graph, from, to, 0);
        I32 i;
        if (!path)
            break;
        for (i = 0; i < av_len(path); i++) {
            SV **left = av_fetch(path, i, 0);
            SV **right = av_fetch(path, i + 1, 0);
            if (left && right)
                removed += xg_delete_all_between(
                    aTHX_ graph, SvUV(*left), SvUV(*right));
        }
        SvREFCNT_dec(path);
    }
    return removed;
}

/* ------------------------------- Cursor API ------------------------------ */

xg_cursor *
xg_cursor_new(pTHX_ xg_graph *graph, SV *graph_sv)
{
    xg_cursor *cursor;
    xg_require_usable(aTHX_ graph);
    Newxz(cursor, 1, xg_cursor);
    cursor->graph = graph;
    cursor->graph_sv = SvREFCNT_inc(graph_sv);
    /*
     * The cursor scans the ID array rather than storing a second list.  The
     * generation check below makes that safe only while topology is stable.
     */
    cursor->next_vertex = 1;
    cursor->topology_generation = graph->topology_generation;
    return cursor;
}

void
xg_cursor_free(pTHX_ xg_cursor *cursor)
{
    if (!cursor)
        return;
    SvREFCNT_dec(cursor->graph_sv);
    Safefree(cursor);
}

static void
xg_cursor_check(pTHX_ xg_cursor *cursor)
{
    xg_require_usable(aTHX_ cursor->graph);
    /* Structural mutation can move adjacency data or change live IDs. */
    if (cursor->graph->topology_generation != cursor->topology_generation)
        xg_error(aTHX_ "ITERATOR_INVALIDATED", NULL);
}

SV *
xg_cursor_next(pTHX_ xg_cursor *cursor)
{
    xg_cursor_check(aTHX_ cursor);
    if (cursor->done)
        return newSV(0);
    /* Deleted IDs are skipped because IDs are never reused. */
    while (cursor->next_vertex < cursor->graph->next_vertex_id) {
        xg_vertex_id_t id = cursor->next_vertex++;
        if (xg_has_vertex(cursor->graph, id))
            return newSVuv(id);
    }
    cursor->done = 1;
    return newSV(0);
}

AV *
xg_cursor_batch(pTHX_ xg_cursor *cursor, UV count)
{
    AV *result;
    if (!count)
        xg_error(aTHX_ "INVALID_ARGUMENT", "batch size must be positive");
    xg_cursor_check(aTHX_ cursor);
    if (cursor->done)
        return NULL;
    /* Batch calls reduce the number of Perl-to-XS transitions for consumers. */
    result = newAV();
    while (count--) {
        SV *value = xg_cursor_next(aTHX_ cursor);
        if (!SvOK(value)) {
            SvREFCNT_dec(value);
            break;
        }
        av_push(result, value);
    }
    if (av_len(result) < 0) {
        SvREFCNT_dec(result);
        return NULL;
    }
    return result;
}
