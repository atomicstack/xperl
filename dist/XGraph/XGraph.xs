#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "xgraph.h"

/*
 * XS is the narrow adapter between Perl objects and the native graph.  It
 * validates arguments, attaches native pointers to Perl magic, and converts
 * native results into ordinary Perl arrays and scalars.  Graph algorithms
 * and ownership rules live in xgraph_lib.c.
 *
 * The pTHX/aTHX arguments carry Perl's interpreter context through C calls.
 * They are required whenever a helper may allocate an SV, AV, HV, or throw.
 */

static int
xg_magic_free(pTHX_ SV *sv, MAGIC *mg)
{
    /* Perl calls this when the graph wrapper is destroyed. */
    xg_graph *graph = (xg_graph *)mg->mg_ptr;
    PERL_UNUSED_VAR(sv);
    mg->mg_ptr = NULL;
    xg_free(aTHX_ graph);
    return 0;
}

static MGVTBL xg_magic_vtbl = {
    NULL, NULL, NULL, NULL, xg_magic_free, NULL, NULL, NULL
};

static int
xg_cursor_magic_free(pTHX_ SV *sv, MAGIC *mg)
{
    /* Cursors own a Perl reference to the graph and release it here. */
    xg_cursor *cursor = (xg_cursor *)mg->mg_ptr;
    PERL_UNUSED_VAR(sv);
    mg->mg_ptr = NULL;
    xg_cursor_free(aTHX_ cursor);
    return 0;
}

static MGVTBL xg_cursor_magic_vtbl = {
    NULL, NULL, NULL, NULL, xg_cursor_magic_free, NULL, NULL, NULL
};

static xg_graph *
xg_graph_from_sv(pTHX_ SV *sv)
{
    MAGIC *mg;
    if (!sv || !SvROK(sv))
        croak("XPERL.GRAPH.INVALID_ARGUMENT: not an XGraph object");
    /* The magic vtable identifies an XGraph wrapper without trusting class
     * names, which can be inherited or changed from Perl. */
    mg = mg_find(SvRV(sv), PERL_MAGIC_ext);
    if (!mg || mg->mg_virtual != &xg_magic_vtbl)
        croak("XPERL.GRAPH.INVALID_ARGUMENT: not an XGraph object");
    return (xg_graph *)mg->mg_ptr;
}

static SV *
xg_make_object(pTHX_ const char *class_name, xg_graph *graph)
{
    SV *object = newSV(0);
    /* The magic pointer is the native graph owner. */
    sv_setref_pv(object, class_name, (void *)graph);
    sv_magicext(SvRV(object), NULL, PERL_MAGIC_ext, &xg_magic_vtbl,
                (const char *)graph, 0);
    return object;
}

static void
xg_bulk_graph_cleanup(pTHX_ void *ptr)
{
    xg_graph **graphp = (xg_graph **)ptr;
    if (*graphp) {
        xg_free(aTHX_ *graphp);
        *graphp = NULL;
    }
}

static AV *
xg_require_bulk_array(pTHX_ SV *value, const char *name)
{
    if (!value || !SvROK(value) || SvTYPE(SvRV(value)) != SVt_PVAV)
        croak("XPERL.GRAPH.INVALID_ARGUMENT: %s must be an array reference",
              name);
    return MUTABLE_AV(SvRV(value));
}

static void
xg_bulk_add_edge(pTHX_ xg_graph *graph, xg_vertex_id_t from,
                 xg_vertex_id_t to, SV *label)
{
    /* Loose mode interns new labels before checking for duplicates. */
    (void)xg_label_id(aTHX_ graph, label, 0);
    if (xg_has_edge(aTHX_ graph, from, to, label)) {
        Perl_warner(aTHX_ packWARN(WARN_MISC),
                    "XPERL.GRAPH.EDGE_EXISTS: duplicate edge ignored");
        return;
    }
    xg_add_edge(aTHX_ graph, from, to, label);
}

static SV *
xg_make_cursor_object(pTHX_ xg_cursor *cursor)
{
    SV *object = newSV(0);
    sv_setref_pv(object, "XGraph::Cursor", (void *)cursor);
    sv_magicext(SvRV(object), NULL, PERL_MAGIC_ext, &xg_cursor_magic_vtbl,
                (const char *)cursor, 0);
    return object;
}

static xg_cursor *
xg_cursor_from_sv(pTHX_ SV *sv)
{
    MAGIC *mg;
    if (!sv || !SvROK(sv))
        croak("XPERL.GRAPH.INVALID_ARGUMENT: not an XGraph cursor");
    mg = mg_find(SvRV(sv), PERL_MAGIC_ext);
    if (!mg || mg->mg_virtual != &xg_cursor_magic_vtbl)
        croak("XPERL.GRAPH.INVALID_ARGUMENT: not an XGraph cursor");
    return (xg_cursor *)mg->mg_ptr;
}

static xg_vertex_id_t
xg_id_arg(pTHX_ SV *sv)
{
    NV numeric;
    UV value;
    /* IDs must be positive, integral numbers within the compiled limit. */
    if (!sv)
        croak("XPERL.GRAPH.INVALID_VERTEX_ID");
    SvGETMAGIC(sv);
    if (SvROK(sv) || !looks_like_number(sv))
        croak("XPERL.GRAPH.INVALID_VERTEX_ID");
    numeric = SvNV(sv);
    value = SvUV(sv);
    if (numeric < 1 || numeric > (NV)XG_MAX_VERTEX_ID ||
        (NV)value != numeric)
        croak("XPERL.GRAPH.INVALID_VERTEX_ID");
    return (xg_vertex_id_t)value;
}

MODULE = XGraph        PACKAGE = XGraph

PROTOTYPES: DISABLE

void
new(class_sv, ...)
    SV *class_sv
PPCODE:
    {
        U8 acyclic = 0;
        U8 strict_labels = 0;
        int i;
        xg_graph *graph;
        const char *class_name;
        if ((items - 1) % 2)
            croak("XPERL.GRAPH.INVALID_ARGUMENT: options are key/value pairs");
        for (i = 1; i < items; i += 2) {
            STRLEN len;
            const char *key;
            SvGETMAGIC(ST(i));
            if (SvROK(ST(i)))
                croak("XPERL.GRAPH.INVALID_ARGUMENT: option name is a reference");
            key = SvPV(ST(i), len);
            if (len == 7 && memEQ(key, "acyclic", 7))
                acyclic = SvTRUE(ST(i + 1)) ? 1 : 0;
            else if (len == 13 && memEQ(key, "strict_labels", 13))
                strict_labels = SvTRUE(ST(i + 1)) ? 1 : 0;
            else
                croak("XPERL.GRAPH.INVALID_ARGUMENT: unknown option");
        }
        class_name = SvPV_nolen(class_sv);
        graph = xg_new(aTHX_ acyclic, strict_labels);
        XPUSHs(sv_2mortal(xg_make_object(aTHX_ class_name, graph)));
    }

void
_from_edges_data(class_sv, mode, vertices, edges, labels, acyclic, strict_labels)
    SV *class_sv
    IV mode
    SV *vertices
    SV *edges
    SV *labels
    IV acyclic
    IV strict_labels
PPCODE:
    {
        AV *vertex_values = xg_require_bulk_array(aTHX_ vertices, "vertices");
        AV *edge_values = xg_require_bulk_array(aTHX_ edges, "edges");
        AV *declared = xg_require_bulk_array(aTHX_ labels, "labels");
        xg_graph *graph = xg_new(aTHX_ acyclic ? 1 : 0,
                                 strict_labels ? 1 : 0);
        I32 vertex_count = av_len(vertex_values) + 1;
        I32 edge_value_count = av_len(edge_values) + 1;
        const char *class_name;
        I32 i;

        SAVEDESTRUCTOR_X(xg_bulk_graph_cleanup, &graph);
        if (edge_value_count % 3)
            croak("XPERL.GRAPH.INVALID_ARGUMENT: internal edge data is malformed");

        if (av_len(declared) >= 0)
            xg_declare_labels(aTHX_ graph, AvARRAY(declared), av_len(declared) + 1);

        for (i = 0; i < vertex_count; i++) {
            SV **svp = av_fetch(vertex_values, i, 0);
            SV *value = svp ? *svp : &PL_sv_undef;
            if (mode)
                xg_add_vertex_id(aTHX_ graph, xg_id_arg(aTHX_ value));
            else
                (void)xg_add_vertex(aTHX_ graph, value);
        }

        /* The Perl normalizer has already resolved names to IDs. */
        for (i = 0; i < edge_value_count; i += 3) {
            SV **from_sv = av_fetch(edge_values, i, 0);
            SV **to_sv = av_fetch(edge_values, i + 1, 0);
            SV **label_sv = av_fetch(edge_values, i + 2, 0);
            xg_vertex_id_t from = from_sv
                ? xg_id_arg(aTHX_ *from_sv) : 0;
            xg_vertex_id_t to = to_sv
                ? xg_id_arg(aTHX_ *to_sv) : 0;
            SV *label = label_sv ? *label_sv : &PL_sv_undef;
            xg_bulk_add_edge(aTHX_ graph, from, to, label);
        }

        class_name = SvPV_nolen(class_sv);
        {
            SV *object = xg_make_object(aTHX_ class_name, graph);
            graph = NULL;
            XPUSHs(sv_2mortal(object));
        }
    }

void
_from_edge_pairs(class_sv, vertices, pairs, labels, acyclic, strict_labels)
    SV *class_sv
    SV *vertices
    SV *pairs
    SV *labels
    IV acyclic
    IV strict_labels
PPCODE:
    {
        AV *vertex_values = xg_require_bulk_array(aTHX_ vertices, "vertices");
        AV *edge_values = xg_require_bulk_array(aTHX_ pairs, "edges");
        AV *declared = xg_require_bulk_array(aTHX_ labels, "labels");
        xg_graph *graph = xg_new(aTHX_ acyclic ? 1 : 0,
                                 strict_labels ? 1 : 0);
        I32 vertex_count = av_len(vertex_values) + 1;
        I32 edge_value_count = av_len(edge_values) + 1;
        const char *class_name;
        I32 i;

        SAVEDESTRUCTOR_X(xg_bulk_graph_cleanup, &graph);
        if (edge_value_count % 2)
            croak("XPERL.GRAPH.INVALID_ARGUMENT: internal edge data is malformed");
        if (av_len(declared) >= 0)
            xg_declare_labels(aTHX_ graph, AvARRAY(declared), av_len(declared) + 1);

        for (i = 0; i < vertex_count; i++) {
            SV **svp = av_fetch(vertex_values, i, 0);
            xg_add_vertex_id(aTHX_ graph,
                             xg_id_arg(aTHX_ svp ? *svp : &PL_sv_undef));
        }

        /* Discover referenced IDs in XS so the flat input remains cheap. */
        for (i = 0; i < edge_value_count; i++) {
            SV **svp = av_fetch(edge_values, i, 0);
            xg_vertex_id_t id = xg_id_arg(aTHX_ svp ? *svp : &PL_sv_undef);
            if (!xg_has_vertex(graph, id))
                xg_add_vertex_id(aTHX_ graph, id);
        }
        for (i = 0; i < edge_value_count; i += 2) {
            SV **from_sv = av_fetch(edge_values, i, 0);
            SV **to_sv = av_fetch(edge_values, i + 1, 0);
            xg_vertex_id_t from = xg_id_arg(aTHX_ from_sv ? *from_sv : &PL_sv_undef);
            xg_vertex_id_t to = xg_id_arg(aTHX_ to_sv ? *to_sv : &PL_sv_undef);
            xg_bulk_add_edge(aTHX_ graph, from, to, &PL_sv_undef);
        }

        class_name = SvPV_nolen(class_sv);
        {
            SV *object = xg_make_object(aTHX_ class_name, graph);
            graph = NULL;
            XPUSHs(sv_2mortal(object));
        }
    }

void
DESTROY(self)
    SV *self
CODE:
    PERL_UNUSED_VAR(self);

void
clone(self)
    SV *self
PPCODE:
    {
        xg_graph *graph = xg_graph_from_sv(aTHX_ self);
        XPUSHs(sv_2mortal(xg_make_object(aTHX_ "XGraph",
                                        xg_clone(aTHX_ graph, 0))));
    }

void
mutable_copy(self)
    SV *self
PPCODE:
    {
        xg_graph *graph = xg_graph_from_sv(aTHX_ self);
        XPUSHs(sv_2mortal(xg_make_object(aTHX_ "XGraph",
                                        xg_clone(aTHX_ graph, 1))));
    }

void
freeze(self)
    SV *self
PPCODE:
    {
        xg_graph *graph = xg_graph_from_sv(aTHX_ self);
        xg_require_usable(aTHX_ graph);
        graph->frozen = 1;
        XPUSHs(self);
    }

void
is_frozen(self)
    SV *self
PPCODE:
    {
        xg_graph *graph = xg_graph_from_sv(aTHX_ self);
        xg_require_usable(aTHX_ graph);
        XPUSHs(sv_2mortal(newSViv(graph->frozen ? 1 : 0)));
    }

void
_add_vertex(self, ...)
    SV *self
PPCODE:
    {
        xg_graph *graph = xg_graph_from_sv(aTHX_ self);
        SV *name;
        if (items > 2)
            croak("XPERL.GRAPH.INVALID_ARGUMENT: add_vertex takes one name");
        name = items == 2 ? ST(1) : &PL_sv_undef;
        XPUSHs(sv_2mortal(newSVuv(xg_add_vertex(aTHX_ graph, name))));
    }

void
has_vertex_id(self, id)
    SV *self
    SV *id
PPCODE:
    {
        xg_graph *graph = xg_graph_from_sv(aTHX_ self);
        int valid = 0;
        xg_require_usable(aTHX_ graph);
        if (id) {
            NV numeric;
            UV value;
            SvGETMAGIC(id);
            if (!SvROK(id) && looks_like_number(id)) {
                numeric = SvNV(id);
                value = SvUV(id);
                if (numeric >= 1 && numeric <= (NV)XG_MAX_VERTEX_ID &&
                    (NV)value == numeric)
                    valid = xg_has_vertex(graph, (xg_vertex_id_t)value);
            }
        }
        XPUSHs(sv_2mortal(newSViv(valid ? 1 : 0)));
    }

void
vertex_id_by_name(self, name)
    SV *self
    SV *name
PPCODE:
    {
        xg_graph *graph = xg_graph_from_sv(aTHX_ self);
        xg_vertex_id_t id;
        if (xg_name_lookup(aTHX_ graph, name, &id))
            XPUSHs(sv_2mortal(newSVuv(id)));
        else
            XPUSHs(&PL_sv_undef);
    }

void
vertex_name_by_id(self, id)
    SV *self
    SV *id
PPCODE:
    XPUSHs(sv_2mortal(xg_vertex_name(
        aTHX_ xg_graph_from_sv(aTHX_ self), xg_id_arg(aTHX_ id))));

void
rename_vertex(self, id, name)
    SV *self
    SV *id
    SV *name
PPCODE:
    xg_rename_vertex(aTHX_ xg_graph_from_sv(aTHX_ self),
                     xg_id_arg(aTHX_ id), name);
    XPUSHs(self);

void
delete_vertex_by_id(self, id)
    SV *self
    SV *id
PPCODE:
    XPUSHs(sv_2mortal(newSViv(xg_delete_vertex(
        aTHX_ xg_graph_from_sv(aTHX_ self), xg_id_arg(aTHX_ id)) ? 1 : 0)));

void
vertex_ids(self)
    SV *self
PPCODE:
    {
        AV *ids = xg_vertex_ids(aTHX_ xg_graph_from_sv(aTHX_ self));
        XPUSHs(sv_2mortal(newRV_noinc((SV *)ids)));
    }

void
vertex_count(self)
    SV *self
PPCODE:
    {
        xg_graph *graph = xg_graph_from_sv(aTHX_ self);
        xg_require_usable(aTHX_ graph);
        XPUSHs(sv_2mortal(newSVuv(graph->live_vertices)));
    }

void
set_vertex_metadata(self, id, metadata)
    SV *self
    SV *id
    SV *metadata
PPCODE:
    xg_set_vertex_metadata(aTHX_ xg_graph_from_sv(aTHX_ self),
                           xg_id_arg(aTHX_ id), metadata);
    XPUSHs(self);

void
vertex_metadata(self, id)
    SV *self
    SV *id
PPCODE:
    XPUSHs(sv_2mortal(xg_vertex_metadata(
        aTHX_ xg_graph_from_sv(aTHX_ self), xg_id_arg(aTHX_ id))));

void
has_vertex_metadata(self, id)
    SV *self
    SV *id
PPCODE:
    XPUSHs(sv_2mortal(newSViv(xg_has_vertex_metadata(
        aTHX_ xg_graph_from_sv(aTHX_ self), xg_id_arg(aTHX_ id)) ? 1 : 0)));

void
delete_vertex_metadata(self, id)
    SV *self
    SV *id
PPCODE:
    XPUSHs(sv_2mortal(newSViv(xg_delete_vertex_metadata(
        aTHX_ xg_graph_from_sv(aTHX_ self), xg_id_arg(aTHX_ id)) ? 1 : 0)));

void
declare_label(self, label)
    SV *self
    SV *label
PPCODE:
    xg_declare_label(aTHX_ xg_graph_from_sv(aTHX_ self), label);
    XPUSHs(self);

void
declare_labels(self, ...)
    SV *self
PPCODE:
    {
        xg_graph *graph = xg_graph_from_sv(aTHX_ self);
        xg_require_mutable(aTHX_ graph);
        xg_declare_labels(aTHX_ graph, &ST(1), items - 1);
        XPUSHs(self);
    }

void
labels(self)
    SV *self
PPCODE:
    {
        AV *labels = xg_labels(aTHX_ xg_graph_from_sv(aTHX_ self));
        XPUSHs(sv_2mortal(newRV_noinc((SV *)labels)));
    }

void
label_count(self)
    SV *self
PPCODE:
    {
        xg_graph *graph = xg_graph_from_sv(aTHX_ self);
        xg_require_usable(aTHX_ graph);
        XPUSHs(sv_2mortal(newSViv(av_len(graph->labels_by_id))));
    }

void
add_edge_by_ids(self, from, to, ...)
    SV *self
    SV *from
    SV *to
PPCODE:
    {
        xg_graph *graph = xg_graph_from_sv(aTHX_ self);
        if (items > 4)
            croak("XPERL.GRAPH.INVALID_ARGUMENT: too many edge arguments");
        xg_add_edge(aTHX_ graph, xg_id_arg(aTHX_ from), xg_id_arg(aTHX_ to),
                    items > 3 ? ST(3) : &PL_sv_undef);
        XPUSHs(&PL_sv_yes);
    }

void
has_edge_by_ids(self, from, to, ...)
    SV *self
    SV *from
    SV *to
PPCODE:
    {
        xg_graph *graph = xg_graph_from_sv(aTHX_ self);
        if (items > 4)
            croak("XPERL.GRAPH.INVALID_ARGUMENT: too many edge arguments");
        XPUSHs(sv_2mortal(newSViv(xg_has_edge(
            aTHX_ graph, xg_id_arg(aTHX_ from), xg_id_arg(aTHX_ to),
            items > 3 ? ST(3) : &PL_sv_undef) ? 1 : 0)));
    }

void
delete_edge_by_ids(self, from, to, ...)
    SV *self
    SV *from
    SV *to
PPCODE:
    {
        xg_graph *graph = xg_graph_from_sv(aTHX_ self);
        if (items > 4)
            croak("XPERL.GRAPH.INVALID_ARGUMENT: too many edge arguments");
        XPUSHs(sv_2mortal(newSViv(xg_delete_edge(
            aTHX_ graph, xg_id_arg(aTHX_ from), xg_id_arg(aTHX_ to),
            items > 3 ? ST(3) : &PL_sv_undef) ? 1 : 0)));
    }

void
add_edge_by_names(self, from, to, ...)
    SV *self
    SV *from
    SV *to
PPCODE:
    {
        xg_graph *graph = xg_graph_from_sv(aTHX_ self);
        xg_vertex_id_t from_id, to_id;
        if (items > 4)
            croak("XPERL.GRAPH.INVALID_ARGUMENT: too many edge arguments");
        if (!xg_name_lookup(aTHX_ graph, from, &from_id) ||
            !xg_name_lookup(aTHX_ graph, to, &to_id))
            croak("XPERL.GRAPH.UNKNOWN_VERTEX");
        xg_add_edge(aTHX_ graph, from_id, to_id,
                    items > 3 ? ST(3) : &PL_sv_undef);
        XPUSHs(&PL_sv_yes);
    }

void
has_edge_by_names(self, from, to, ...)
    SV *self
    SV *from
    SV *to
PPCODE:
    {
        xg_graph *graph = xg_graph_from_sv(aTHX_ self);
        xg_vertex_id_t from_id, to_id;
        if (items > 4)
            croak("XPERL.GRAPH.INVALID_ARGUMENT: too many edge arguments");
        if (!xg_name_lookup(aTHX_ graph, from, &from_id) ||
            !xg_name_lookup(aTHX_ graph, to, &to_id))
            XPUSHs(&PL_sv_no);
        else
            XPUSHs(sv_2mortal(newSViv(xg_has_edge(
                aTHX_ graph, from_id, to_id,
                items > 3 ? ST(3) : &PL_sv_undef) ? 1 : 0)));
    }

void
delete_edge_by_names(self, from, to, ...)
    SV *self
    SV *from
    SV *to
PPCODE:
    {
        xg_graph *graph = xg_graph_from_sv(aTHX_ self);
        xg_vertex_id_t from_id, to_id;
        if (items > 4)
            croak("XPERL.GRAPH.INVALID_ARGUMENT: too many edge arguments");
        if (!xg_name_lookup(aTHX_ graph, from, &from_id) ||
            !xg_name_lookup(aTHX_ graph, to, &to_id))
            XPUSHs(&PL_sv_no);
        else
            XPUSHs(sv_2mortal(newSViv(xg_delete_edge(
                aTHX_ graph, from_id, to_id,
                items > 3 ? ST(3) : &PL_sv_undef) ? 1 : 0)));
    }

void
edges(self)
    SV *self
PPCODE:
    {
        AV *edges = xg_edges(aTHX_ xg_graph_from_sv(aTHX_ self));
        XPUSHs(sv_2mortal(newRV_noinc((SV *)edges)));
    }

void
out_edges(self, id)
    SV *self
    SV *id
PPCODE:
    {
        AV *edges = xg_edges_for_vertex(aTHX_ xg_graph_from_sv(aTHX_ self),
                                         xg_id_arg(aTHX_ id), 1);
        XPUSHs(sv_2mortal(newRV_noinc((SV *)edges)));
    }

void
in_edges(self, id)
    SV *self
    SV *id
PPCODE:
    {
        AV *edges = xg_edges_for_vertex(aTHX_ xg_graph_from_sv(aTHX_ self),
                                         xg_id_arg(aTHX_ id), 0);
        XPUSHs(sv_2mortal(newRV_noinc((SV *)edges)));
    }

void
out_neighbors(self, id)
    SV *self
    SV *id
PPCODE:
    {
        AV *neighbors = xg_neighbors(aTHX_ xg_graph_from_sv(aTHX_ self),
                                      xg_id_arg(aTHX_ id), 1);
        XPUSHs(sv_2mortal(newRV_noinc((SV *)neighbors)));
    }

void
in_neighbors(self, id)
    SV *self
    SV *id
PPCODE:
    {
        AV *neighbors = xg_neighbors(aTHX_ xg_graph_from_sv(aTHX_ self),
                                      xg_id_arg(aTHX_ id), 0);
        XPUSHs(sv_2mortal(newRV_noinc((SV *)neighbors)));
    }

void
undirected_neighbors(self, id)
    SV *self
    SV *id
PPCODE:
    {
        AV *neighbors = xg_undirected_neighbors(
            aTHX_ xg_graph_from_sv(aTHX_ self), xg_id_arg(aTHX_ id));
        XPUSHs(sv_2mortal(newRV_noinc((SV *)neighbors)));
    }

void
out_degree(self, id)
    SV *self
    SV *id
PPCODE:
    XPUSHs(sv_2mortal(newSVuv(xg_degree(
        aTHX_ xg_graph_from_sv(aTHX_ self), xg_id_arg(aTHX_ id), 1))));

void
in_degree(self, id)
    SV *self
    SV *id
PPCODE:
    XPUSHs(sv_2mortal(newSVuv(xg_degree(
        aTHX_ xg_graph_from_sv(aTHX_ self), xg_id_arg(aTHX_ id), 0))));

void
edge_count(self)
    SV *self
PPCODE:
    {
        xg_graph *graph = xg_graph_from_sv(aTHX_ self);
        xg_require_usable(aTHX_ graph);
        XPUSHs(sv_2mortal(newSVuv((UV)graph->live_edges)));
    }

void
_vertex_cursor(self)
    SV *self
PPCODE:
    XPUSHs(sv_2mortal(xg_make_cursor_object(aTHX_
        xg_cursor_new(aTHX_ xg_graph_from_sv(aTHX_ self), self))));

void
has_path(self, from, to)
    SV *self
    SV *from
    SV *to
PPCODE:
    XPUSHs(sv_2mortal(newSViv(xg_has_path(
        aTHX_ xg_graph_from_sv(aTHX_ self), xg_id_arg(aTHX_ from),
        xg_id_arg(aTHX_ to), 0) ? 1 : 0)));

void
path(self, from, to)
    SV *self
    SV *from
    SV *to
PPCODE:
    {
        AV *path = xg_path(aTHX_ xg_graph_from_sv(aTHX_ self),
                           xg_id_arg(aTHX_ from), xg_id_arg(aTHX_ to), 0);
        if (path)
            XPUSHs(sv_2mortal(newRV_noinc((SV *)path)));
        else
            XPUSHs(&PL_sv_undef);
    }

void
shortest_path(self, from, to)
    SV *self
    SV *from
    SV *to
PPCODE:
    {
        AV *path = xg_path(aTHX_ xg_graph_from_sv(aTHX_ self),
                           xg_id_arg(aTHX_ from), xg_id_arg(aTHX_ to), 0);
        if (path)
            XPUSHs(sv_2mortal(newRV_noinc((SV *)path)));
        else
            XPUSHs(&PL_sv_undef);
    }

void
descendants(self, id)
    SV *self
    SV *id
PPCODE:
    {
        AV *result = xg_reachable(aTHX_ xg_graph_from_sv(aTHX_ self),
                                  xg_id_arg(aTHX_ id), 0, 0);
        XPUSHs(sv_2mortal(newRV_noinc((SV *)result)));
    }

void
strict_descendants(self, id)
    SV *self
    SV *id
PPCODE:
    {
        AV *result = xg_reachable(aTHX_ xg_graph_from_sv(aTHX_ self),
                                  xg_id_arg(aTHX_ id), 0, 1);
        XPUSHs(sv_2mortal(newRV_noinc((SV *)result)));
    }

void
ancestors(self, id)
    SV *self
    SV *id
PPCODE:
    {
        AV *result = xg_reachable(aTHX_ xg_graph_from_sv(aTHX_ self),
                                  xg_id_arg(aTHX_ id), 1, 0);
        XPUSHs(sv_2mortal(newRV_noinc((SV *)result)));
    }

void
strict_ancestors(self, id)
    SV *self
    SV *id
PPCODE:
    {
        AV *result = xg_reachable(aTHX_ xg_graph_from_sv(aTHX_ self),
                                  xg_id_arg(aTHX_ id), 1, 1);
        XPUSHs(sv_2mortal(newRV_noinc((SV *)result)));
    }

void
dfs_preorder(self, id)
    SV *self
    SV *id
PPCODE:
    {
        AV *result = xg_dfs_order(aTHX_ xg_graph_from_sv(aTHX_ self),
                                  xg_id_arg(aTHX_ id), 0, 0);
        XPUSHs(sv_2mortal(newRV_noinc((SV *)result)));
    }

void
dfs_postorder(self, id)
    SV *self
    SV *id
PPCODE:
    {
        AV *result = xg_dfs_order(aTHX_ xg_graph_from_sv(aTHX_ self),
                                  xg_id_arg(aTHX_ id), 0, 1);
        XPUSHs(sv_2mortal(newRV_noinc((SV *)result)));
    }

void
dfs_reverse_postorder(self, id)
    SV *self
    SV *id
PPCODE:
    {
        AV *result = xg_dfs_order(aTHX_ xg_graph_from_sv(aTHX_ self),
                                  xg_id_arg(aTHX_ id), 0, 1);
        AV *reverse = newAV();
        I32 i;
        for (i = av_len(result); i >= 0; i--) {
            SV **svp = av_fetch(result, i, 0);
            av_push(reverse, svp ? newSVsv(*svp) : newSV(0));
        }
        SvREFCNT_dec(result);
        XPUSHs(sv_2mortal(newRV_noinc((SV *)reverse)));
    }

void
topological_sort(self)
    SV *self
PPCODE:
    {
        AV *result = xg_topological_sort(aTHX_ xg_graph_from_sv(aTHX_ self));
        if (result)
            XPUSHs(sv_2mortal(newRV_noinc((SV *)result)));
        else
            XPUSHs(&PL_sv_undef);
    }

void
source_vertices(self)
    SV *self
PPCODE:
    XPUSHs(sv_2mortal(newRV_noinc((SV *)xg_source_vertices(
        aTHX_ xg_graph_from_sv(aTHX_ self)))));

void
sink_vertices(self)
    SV *self
PPCODE:
    XPUSHs(sv_2mortal(newRV_noinc((SV *)xg_sink_vertices(
        aTHX_ xg_graph_from_sv(aTHX_ self)))));

void
loop_vertices(self)
    SV *self
PPCODE:
    XPUSHs(sv_2mortal(newRV_noinc((SV *)xg_loop_vertices(
        aTHX_ xg_graph_from_sv(aTHX_ self)))));

void
weakly_connected_components(self)
    SV *self
PPCODE:
    XPUSHs(sv_2mortal(newRV_noinc((SV *)xg_components(
        aTHX_ xg_graph_from_sv(aTHX_ self), 0, 0))));

void
strongly_connected_components(self)
    SV *self
PPCODE:
    XPUSHs(sv_2mortal(newRV_noinc((SV *)xg_components(
        aTHX_ xg_graph_from_sv(aTHX_ self), 1, 0))));

void
strongly_connected_components_tarjan(self)
    SV *self
PPCODE:
    XPUSHs(sv_2mortal(newRV_noinc((SV *)xg_components_tarjan(
        aTHX_ xg_graph_from_sv(aTHX_ self)))));

void
strongly_connected_components_pearce(self)
    SV *self
PPCODE:
    XPUSHs(sv_2mortal(newRV_noinc((SV *)xg_components_pearce(
        aTHX_ xg_graph_from_sv(aTHX_ self)))));

void
strongly_connected_components_tarjan_zwick(self)
    SV *self
PPCODE:
    XPUSHs(sv_2mortal(newRV_noinc((SV *)xg_components_tarjan_zwick(
        aTHX_ xg_graph_from_sv(aTHX_ self)))));

void
cyclic_strongly_connected_components(self)
    SV *self
PPCODE:
    XPUSHs(sv_2mortal(newRV_noinc((SV *)xg_components(
        aTHX_ xg_graph_from_sv(aTHX_ self), 1, 1))));

void
is_acyclic(self)
    SV *self
PPCODE:
    XPUSHs(sv_2mortal(newSViv(xg_is_acyclic(
        aTHX_ xg_graph_from_sv(aTHX_ self)) ? 1 : 0)));

void
cycle(self)
    SV *self
PPCODE:
    {
        AV *cycle = xg_cycle(aTHX_ xg_graph_from_sv(aTHX_ self), 0);
        if (cycle)
            XPUSHs(sv_2mortal(newRV_noinc((SV *)cycle)));
        else
            XPUSHs(&PL_sv_undef);
    }

void
shortest_cycle(self)
    SV *self
PPCODE:
    {
        AV *cycle = xg_cycle(aTHX_ xg_graph_from_sv(aTHX_ self), 1);
        if (cycle)
            XPUSHs(sv_2mortal(newRV_noinc((SV *)cycle)));
        else
            XPUSHs(&PL_sv_undef);
    }

void
is_tree(self)
    SV *self
PPCODE:
    XPUSHs(sv_2mortal(newSViv(xg_is_tree(
        aTHX_ xg_graph_from_sv(aTHX_ self)) ? 1 : 0)));

void
is_arborescence(self)
    SV *self
PPCODE:
    XPUSHs(sv_2mortal(newSViv(xg_is_arborescence(
        aTHX_ xg_graph_from_sv(aTHX_ self), NULL) ? 1 : 0)));

void
arborescence_root(self)
    SV *self
PPCODE:
    {
        xg_vertex_id_t root = 0;
        if (xg_is_arborescence(aTHX_ xg_graph_from_sv(aTHX_ self), &root))
            XPUSHs(sv_2mortal(newSVuv(root)));
        else
            XPUSHs(&PL_sv_undef);
    }

void
delete_paths(self, from, to)
    SV *self
    SV *from
    SV *to
PPCODE:
    XPUSHs(sv_2mortal(newSVuv(xg_delete_paths(
        aTHX_ xg_graph_from_sv(aTHX_ self), xg_id_arg(aTHX_ from),
        xg_id_arg(aTHX_ to)))));

void
reachability_roots(self)
    SV *self
PPCODE:
    XPUSHs(sv_2mortal(newRV_noinc((SV *)xg_reachability_roots(
        aTHX_ xg_graph_from_sv(aTHX_ self)))));

void
induced_subgraph(self, vertex_ids)
    SV *self
    SV *vertex_ids
PPCODE:
    {
        xg_graph *graph = xg_graph_from_sv(aTHX_ self);
        xg_graph *result;
        if (!SvROK(vertex_ids) || SvTYPE(SvRV(vertex_ids)) != SVt_PVAV)
            croak("XPERL.GRAPH.INVALID_ARGUMENT: vertex IDs must be an array");
        result = xg_induced_subgraph(aTHX_ graph,
                                     MUTABLE_AV(SvRV(vertex_ids)));
        XPUSHs(sv_2mortal(xg_make_object(aTHX_ "XGraph", result)));
    }

void
condensation(self)
    SV *self
PPCODE:
    {
        AV *components;
        AV *component_of;
        xg_graph *result = xg_condensation(
            aTHX_ xg_graph_from_sv(aTHX_ self), &components, &component_of);
        HV *value = newHV();
        hv_store(value, "graph", 5,
                 xg_make_object(aTHX_ "XGraph", result), 0);
        hv_store(value, "components", 10,
                 newRV_noinc((SV *)components), 0);
        hv_store(value, "component_of", 12,
                 newRV_noinc((SV *)component_of), 0);
        XPUSHs(sv_2mortal(newRV_noinc((SV *)value)));
    }

MODULE = XGraph        PACKAGE = XGraph::Cursor

PROTOTYPES: DISABLE

void
DESTROY(self)
    SV *self
CODE:
    PERL_UNUSED_VAR(self);

void
next(self)
    SV *self
PPCODE:
    XPUSHs(sv_2mortal(xg_cursor_next(aTHX_ xg_cursor_from_sv(aTHX_ self))));

void
next_batch(self, count)
    SV *self
    UV count
PPCODE:
    {
        AV *batch = xg_cursor_batch(aTHX_ xg_cursor_from_sv(aTHX_ self), count);
        if (batch)
            XPUSHs(sv_2mortal(newRV_noinc((SV *)batch)));
        else
            XPUSHs(&PL_sv_undef);
    }
