package XGraph;

use 5.036003;
use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(looks_like_number);

our @ISA = qw();

our $VERSION = '0.01';

require XSLoader;
XSLoader::load('XGraph', $VERSION);

sub CLONE_SKIP { 1 }

sub add_vertex { shift->_add_vertex(@_) }

sub from_edges {
    my ($class, %options) = @_;
    my $mode = delete($options{vertex_mode}) // 'name';
    croak 'XPERL.GRAPH.INVALID_ARGUMENT: vertex_mode must be name or id'
        unless $mode eq 'name' || $mode eq 'id';

    my $acyclic = delete($options{acyclic}) ? 1 : 0;
    my $strict_labels = delete($options{strict_labels}) ? 1 : 0;
    my $declared_labels = delete($options{labels}) // [];
    croak 'XPERL.GRAPH.INVALID_ARGUMENT: labels must be an array reference'
        unless ref($declared_labels) eq 'ARRAY';

    my @vertex_values;
    my %name_to_id;
    my %id_seen;
    my @edges;

    # Keep the common numeric flat-edge form entirely inside XS.  This is the
    # performance path used by bulk graph construction: no per-edge Perl
    # normalization or temporary triples are needed.
    if ($mode eq 'id' && exists $options{edges}
        && !grep { exists $options{$_} }
            qw(vertices labeled_edges paths labeled_paths)) {
        my $pairs = delete $options{edges};
        croak 'XPERL.GRAPH.INVALID_ARGUMENT: edge pairs must be an array reference'
            unless ref($pairs) eq 'ARRAY';
        croak 'XPERL.GRAPH.INVALID_ARGUMENT: edge pairs need an even length'
            if @$pairs % 2;
        croak 'XPERL.GRAPH.INVALID_ARGUMENT: unknown from_edges option'
            if keys %options;
        return $class->_from_edge_pairs(
            [], $pairs, $declared_labels, $acyclic, $strict_labels,
        );
    }

    my $vertex_id = sub {
        my ($value, $allow_undef) = @_;
        croak 'XPERL.GRAPH.INVALID_ARGUMENT: vertex references are not allowed'
            if ref($value);

        if ($mode eq 'name') {
            croak 'XPERL.GRAPH.INVALID_ARGUMENT: undefined vertex name'
                if !defined($value) && !$allow_undef;
            if (!defined($value)) {
                push @vertex_values, undef;
                return scalar @vertex_values;
            }
            my $name = "$value";
            return $name_to_id{$name} if exists $name_to_id{$name};
            my $id = @vertex_values + 1;
            $name_to_id{$name} = $id;
            push @vertex_values, $name;
            return $id;
        }

        croak 'XPERL.GRAPH.INVALID_VERTEX_ID'
            if !defined($value) || !looks_like_number($value);
        my $numeric = 0 + $value;
        croak 'XPERL.GRAPH.INVALID_VERTEX_ID'
            if $numeric < 1 || $numeric != int($numeric);
        my $id = int($numeric);
        unless ($id_seen{$id}++) {
            push @vertex_values, $id;
        }
        return $id;
    };

    if (exists $options{vertices}) {
        my $vertices = delete $options{vertices};
        croak 'XPERL.GRAPH.INVALID_ARGUMENT: vertices must be an array reference'
            unless ref($vertices) eq 'ARRAY';
        $vertex_id->($_, 1) for @$vertices;
    }

    my $append_pairs = sub {
        my ($pairs, $label) = @_;
        croak 'XPERL.GRAPH.INVALID_ARGUMENT: edge pairs must be an array reference'
            unless ref($pairs) eq 'ARRAY';
        croak 'XPERL.GRAPH.INVALID_ARGUMENT: edge pairs need an even length'
            if @$pairs % 2;
        for (my $i = 0; $i < @$pairs; $i += 2) {
            my $from = $vertex_id->($pairs->[$i], 0);
            my $to   = $vertex_id->($pairs->[$i + 1], 0);
            push @edges, $from, $to, $label;
        }
    };

    my $append_path = sub {
        my ($path, $label) = @_;
        croak 'XPERL.GRAPH.INVALID_ARGUMENT: paths must be array references'
            unless ref($path) eq 'ARRAY';
        return unless @$path;
        my @ids = map { $vertex_id->($_, 0) } @$path;
        return if @ids < 2;
        for (my $i = 1; $i < @ids; $i++) {
            push @edges, $ids[$i - 1], $ids[$i], $label;
        }
    };

    my $append_paths = sub {
        my ($paths, $label) = @_;
        croak 'XPERL.GRAPH.INVALID_ARGUMENT: paths must be an array reference'
            unless ref($paths) eq 'ARRAY';
        return unless @$paths;
        if (ref($paths->[0]) eq 'ARRAY') {
            croak 'XPERL.GRAPH.INVALID_ARGUMENT: paths must not mix forms'
                if grep { ref($_) ne 'ARRAY' } @$paths;
            $append_path->($_, $label) for @$paths;
        } else {
            croak 'XPERL.GRAPH.INVALID_ARGUMENT: paths must not mix forms'
                if grep { ref($_) } @$paths;
            $append_path->($paths, $label);
        }
    };

    if (exists $options{edges}) {
        my $edges = delete $options{edges};
        $append_pairs->($edges, undef);
    }
    if (exists $options{labeled_edges}) {
        my $groups = delete $options{labeled_edges};
        croak 'XPERL.GRAPH.INVALID_ARGUMENT: labeled_edges must be a hash reference'
            unless ref($groups) eq 'HASH';
        for my $label (sort keys %$groups) {
            $append_pairs->($groups->{$label}, $label);
        }
    }
    if (exists $options{paths}) {
        my $paths = delete $options{paths};
        $append_paths->($paths, undef);
    }
    if (exists $options{labeled_paths}) {
        my $groups = delete $options{labeled_paths};
        croak 'XPERL.GRAPH.INVALID_ARGUMENT: labeled_paths must be a hash reference'
            unless ref($groups) eq 'HASH';
        for my $label (sort keys %$groups) {
            $append_paths->($groups->{$label}, $label);
        }
    }

    croak 'XPERL.GRAPH.INVALID_ARGUMENT: unknown from_edges option'
        if keys %options;

    return $class->_from_edges_data(
        $mode eq 'id' ? 1 : 0,
        \@vertex_values,
        \@edges,
        $declared_labels,
        $acyclic,
        $strict_labels,
    );
}

sub delete_vertex_by_name {
    my ($self, $name) = @_;
    my $id = $self->vertex_id_by_name($name);
    return 0 unless defined $id;
    return $self->delete_vertex_by_id($id);
}

sub edges_between {
    my ($self, $from, $to) = @_;
    my $edges = $self->out_edges($from);
    return [ grep { $_->[1] == $to } @$edges ];
}

sub vertices { shift->vertex_ids(@_) }

sub vertex_iterator {
    my ($self) = @_;
    my $cursor = $self->_vertex_cursor;
    return sub { $cursor->next };
}

sub vertex {
    my ($self, $id) = @_;
    $self->vertex_name_by_id($id); # validate that the ID is live
    return XGraph::Vertex->_new($self, $id);
}

sub fold_vertices {
    my ($self, $acc, $code, $context) = @_;
    croak 'XPERL.GRAPH.INVALID_ARGUMENT: fold_vertices callback is not a code reference'
        unless ref($code) eq 'CODE';

    my $next = $self->vertex_iterator;
    while (defined(my $id = $next->())) {
        my $vertex = XGraph::Vertex->_new($self, $id);
        $acc = $code->($vertex, $acc, $context);
    }
    return $acc;
}

sub to_dot {
    require XGraph::IO::DOT;
    return XGraph::IO::DOT::to_string(@_);
}

sub write_dot {
    require XGraph::IO::DOT;
    return XGraph::IO::DOT::write_file(@_);
}

sub has_edge { shift->has_edge_by_ids(@_) }
sub add_edge { shift->add_edge_by_ids(@_) }
sub delete_edge { shift->delete_edge_by_ids(@_) }

sub delete_edge_by_name { shift->delete_edge_by_names(@_) }
sub has_edge_by_name { shift->has_edge_by_names(@_) }
sub add_edge_by_name { shift->add_edge_by_names(@_) }

package XGraph::Vertex;

sub CLONE_SKIP { 1 }

sub _new {
    my ($class, $graph, $id) = @_;
    return bless [$graph, $id], $class;
}

sub graph { $_[0][0] }
sub id    { $_[0][1] }
sub name  { $_[0][0]->vertex_name_by_id($_[0][1]) }

sub metadata {
    $_[0][0]->vertex_metadata($_[0][1]);
}

sub has_metadata {
    $_[0][0]->has_vertex_metadata($_[0][1]);
}

sub set_metadata {
    $_[0][0]->set_vertex_metadata($_[0][1], $_[1]);
    return $_[0];
}

sub delete_metadata {
    $_[0][0]->delete_vertex_metadata($_[0][1]);
}

sub out_neighbors {
    $_[0][0]->out_neighbors($_[0][1]);
}

sub in_neighbors {
    $_[0][0]->in_neighbors($_[0][1]);
}

sub undirected_neighbors {
    $_[0][0]->undirected_neighbors($_[0][1]);
}

sub out_degree {
    $_[0][0]->out_degree($_[0][1]);
}

sub in_degree {
    $_[0][0]->in_degree($_[0][1]);
}

package XGraph::Cursor;

sub CLONE_SKIP { 1 }

1;
__END__
=head1 NAME

XGraph - compact XS-backed directed graphs

=head1 SYNOPSIS

    use XGraph;

    my $g = XGraph->new(strict_labels => 1);
    $g->declare_label('depends_on');

    my $parse = $g->add_vertex('parse');
    my $emit  = $g->add_vertex('emit');
    my $anon  = $g->add_vertex;

    $g->add_edge_by_ids($parse, $emit, 'depends_on');
    $g->add_edge_by_names('parse', 'emit', 'depends_on');

    my $path = $g->shortest_path($parse, $emit);
    my $edges = $g->out_edges($parse);

=head1 DESCRIPTION

C<XGraph> is a directed graph implemented in XS.  It provides compact native
topology, stable numeric vertex IDs, optional vertex names, registered edge
labels, incoming and outgoing adjacency, and graph algorithms.

The API is deliberately narrower than the older CPAN C<Graph> distribution.
XGraph is directed-only, does not use arbitrary Perl values as vertex
identities, does not attach arbitrary attributes to edges, and does not assign
independent edge IDs.  These restrictions keep the topology compact and make
the boundary between Perl values and native storage clear.

The module is bundled with XPerl.  It is not a drop-in replacement for
C<Graph>.  Planned generator and frozen-store ithread integration are not
implemented yet.

XS is the bridge that lets a Perl module call C code.  XGraph uses C for the
topology and algorithms, then turns the results back into ordinary Perl
values.  This lets the same example be studied at two levels: the graph
algorithm and the data structure which makes it fast.

=head2 A short graph lesson

A graph is a collection of vertices and edges.  A vertex is a thing we want
to describe.  An edge is a relationship between two vertices.  XGraph uses
directed edges, so an edge has a beginning and an end:

    parse  --depends_on-->  emit

This edge says that C<parse> depends on C<emit>.  It does not say that
C<emit> depends on C<parse>.  If both relationships are true, add both
directed edges.

Some books call a vertex a node.  The terms mean the same thing here.  Every
XGraph vertex has a numeric ID.  The ID is its machine-friendly identity.  A
name is an optional human-friendly alias.  An anonymous vertex is still a
normal vertex because its ID is enough to identify it.

An edge is the relationship value

    (from vertex ID, to vertex ID, label)

The label describes the kind of relationship.  It is not an arbitrary record
attached to the edge.  Two edges may have the same endpoints when their
labels differ.  The exact same tuple cannot be inserted twice.  An omitted
label and C<undef> are the same label, while C<''> is different.

Useful vocabulary:

=over 4

=item * The out-degree is the number of edges leaving a vertex.  The
in-degree is the number entering it.

=item * A path is a sequence of vertices connected by edges.  A cycle is a
path which returns to its starting vertex.

=item * A source has no incoming edges.  A sink has no outgoing edges.

=item * A directed acyclic graph, or DAG, has no directed cycle.  A
topological ordering lists its vertices so every edge points forward.

=item * A strongly connected component is a group in which every vertex can
reach every other vertex.  A weakly connected component ignores arrow
direction while deciding membership.

=back

The algorithm methods return IDs because IDs work for both named and
anonymous vertices.  Use C<vertex($id)> or the name lookup methods when you
want a more descriptive Perl-facing view.

=head2 How XGraph stores the idea

The native graph keeps two sorted adjacency lists for each live vertex:

    vertex A, outgoing: (B, label)
    vertex B, incoming: (A, label)

Keeping both lists makes either direction quick to inspect.  It also means
that deleting one edge must remove two entries.  The entries contain only
integer IDs.  Names, labels, and vertex metadata stay in ordinary Perl AV/HV
structures at the boundary.  This keeps the frequently visited topology
compact and gives Perl its normal reference-ownership rules.

In Perl's C API, an SV is a scalar, an AV is an array, and an HV is a hash.
Those names appear in the XS and C sources because the graph uses Perl's
normal memory and reference-counting rules for this boundary data.

The compact build packs a neighboring vertex ID and a label ID into one
integer.  Because the lists are sorted by that packed value, binary search
can find an edge without a separate hash table.  The wide build uses the same
logical design with larger fields.  The packing is an implementation detail,
not a file format.

=head2 How to read the algorithms

The path and reachability methods use breadth-first search.  Breadth-first
search visits all vertices one edge away, then all vertices two edges away,
and so on.  The first time it reaches a destination therefore gives a
shortest path measured in edges.  A queue holds the frontier, and a
seen-set prevents revisiting a vertex.

The depth-first methods use a stack.  They can report the order in which
vertices are first discovered (preorder), the order in which exploration
finishes (postorder), or the reverse of the finishing order.  XGraph stores
its own stack instead of using C recursion, so a deep graph does not consume
the C call stack one vertex at a time.

Topological sorting repeatedly chooses a vertex with no remaining incoming
edges.  Removing that vertex exposes new candidates.  If vertices remain when
no candidate exists, those vertices are part of a cycle and no topological
order exists.

Strongly connected components use two depth-first passes.  The first records
finishing order.  The second walks reversed edges in that order.  This is
Kosaraju's algorithm.  The condensation operation then replaces each
component with one vertex, producing a smaller acyclic graph.

=head2 Vertices and IDs

Every vertex receives a graph-assigned numeric ID.  ID zero is invalid.  IDs
start at one, increase monotonically, and are not reused after deletion.
Deleting a vertex also deletes every incident edge.

A vertex may have a unique name.  Omitting the name, or passing C<undef>,
creates an anonymous vertex.  XGraph does not manufacture a name for an
anonymous vertex.  The empty string is a valid name.

Names are stringified once and then compared using the same byte and UTF-8
semantics as ordinary Perl hash keys.  References are rejected.  A numeric
value such as C<42> and the string C<'42'> therefore denote the same name.
Names and IDs are separate namespaces.  Use an C<_by_id> method when the
argument is an ID and an C<_by_name> method when it is a name.

=head2 Edges and labels

An edge is the unique relationship tuple

    (from vertex ID, to vertex ID, label)

There is no independent edge ID.  Two edges may join the same ordered pair of
vertices when their labels differ.  Adding the same tuple twice throws.

Labels are graph-local relationship names.  They are stringified once and
interned by the graph.  References are rejected.  The reserved labels are:

    label ID 1  undef
    label ID 2  the empty string

An omitted label and an explicit C<undef> are the same edge label.  C<''> is
different from C<undef>.  In the default loose mode, a new non-empty label is
registered the first time it is used for an edge.  With
C<< strict_labels => 1 >>, non-empty labels must first be declared with
C<declare_label> or C<declare_labels>.

The private label IDs are not returned by the normal API.  Edge results use
the public label value:

    [ FROM_ID, TO_ID, LABEL ]

where C<LABEL> is C<undef>, the empty string, or a registered string.

=head2 Vertex metadata and edge payloads

Vertices may have one arbitrary Perl metadata value, stored in the graph's
Perl-side registry and accessed by ID or through an C<XGraph::Vertex> view.
Edges still do not store arbitrary payloads; relationship labels remain their
only attached public value.  Applications needing richer edge records should
maintain a separate map keyed by edge tuple.

=head2 Ordering and result shapes

Collection methods return array references.  Vertex IDs are returned in
ascending numeric order unless a method documents a traversal order.  The
native adjacency lists are sorted, which gives deterministic edge and
neighbor results.  Components are ordered by their smallest member ID.

Paths are arrays ordered from source to destination.  Cycles are closed paths,
so a self-loop is C<[$id, $id]>.  An absent path, cycle, or topological order
is returned as C<undef>.  Predicates return a Perl boolean.

=head1 CONSTRUCTORS

=head2 new

    my $g = XGraph->new;
    my $g = XGraph->new(
        acyclic       => 1,
        strict_labels => 1,
    );

Creates an empty directed graph.  The following boolean options are accepted:

=over 4

=item C<acyclic>

When true, adding a loop or any edge which would create a cycle throws
C<XPERL.GRAPH.CYCLE_REJECTED>.  The check is performed before the edge is
committed.

=item C<strict_labels>

When true, non-empty string labels must have been declared before they are
used by an edge.  The reserved C<undef> and empty labels are always available.

=back

Unknown options and malformed option lists throw
C<XPERL.GRAPH.INVALID_ARGUMENT>.
Both options default to false.

=head2 from_edges

    my $g = XGraph->from_edges(
        paths => ['parse', 'emit', 'run'],
    );

    my $g = XGraph->from_edges(
        vertex_mode => 'id',
        edges       => [1, 2, 2, 3],
    );

    my $g = XGraph->from_edges(
        labeled_edges => {
            depends_on => ['parse', 'emit', 'emit', 'run'],
        },
    );

Constructs a graph in one bulk operation.  Vertex references are names by
default.  Set C<vertex_mode =E<gt> 'id'> when the references are numeric
vertex IDs.  Names encountered in the input are created in the graph and
repeated names refer to the same vertex.  In ID mode, referenced IDs are
created as needed.  The optional C<vertices> array declares isolated vertices.

C<edges> is a flat list of unlabeled C<(from, to)> pairs.  C<labeled_edges>
is a hash whose values are flat endpoint pairs grouped by their edge label.
C<paths> accepts either one vertex sequence or an array of vertex sequences;
each consecutive pair becomes an edge.  C<labeled_paths> groups paths by a
single label per group.  The C<acyclic>, C<strict_labels>, and C<labels>
options have the same meanings as for C<new>; C<labels> declares labels before
the input is processed, which is useful with strict mode.

Duplicate edge tuples produce a warning and are ignored.  The constructor is
atomic: malformed input or a graph constraint failure does not return a
partially built graph.  References are not valid vertex names, IDs, or labels.

=head1 LIFECYCLE METHODS

=head2 freeze

    $g->freeze;

Makes the graph immutable and returns C<$g>.  Freezing is irreversible and
idempotent.  It prevents changes to vertices, names, labels, edges, and graph
options.

=head2 is_frozen

    my $frozen = $g->is_frozen;

Returns true after C<freeze> and false otherwise.

=head2 clone

    my $copy = $g->clone;

Creates an independent deep copy of the graph.  Vertex IDs, names, label
registration order, edges, options, and frozen state are preserved.  Changes
to the copy do not affect the source.

=head2 mutable_copy

    my $copy = $g->mutable_copy;

Creates an independent deep copy which is mutable even when C<$g> is frozen.
The logical graph state, IDs, names, labels, edges, and options are preserved.

=head1 VERTEX METHODS

=head2 add_vertex

    my $id = $g->add_vertex;
    my $id = $g->add_vertex($name);

Adds a vertex and returns its numeric ID.  An omitted name or C<undef> creates
an anonymous vertex.  A duplicate normalized name throws
C<XPERL.GRAPH.DUPLICATE_VERTEX_NAME>.

=head2 has_vertex_id

    my $exists = $g->has_vertex_id($id);

Returns false for zero, negative, malformed, deleted, or unknown IDs.  Unlike
methods which require a live endpoint, this predicate treats an invalid ID as
ordinary absence.

=head2 vertex_id_by_name

    my $id = $g->vertex_id_by_name($name);

Returns the ID for a named live vertex, or C<undef> when the name is absent.
References are rejected.

=head2 vertex_name_by_id

    my $name = $g->vertex_name_by_id($id);

Returns the name for a live vertex, or C<undef> when the vertex is anonymous.
An invalid or deleted ID throws C<XPERL.GRAPH.UNKNOWN_VERTEX> or
C<XPERL.GRAPH.INVALID_VERTEX_ID>, as appropriate.

=head2 rename_vertex

    $g->rename_vertex($id, $name);
    $g->rename_vertex($id, undef);       # make it anonymous

Changes or removes a vertex name and returns C<$g>.  The ID and all edges are
preserved.  A name collision throws and leaves the graph unchanged.

=head2 delete_vertex_by_id

    my $deleted = $g->delete_vertex_by_id($id);

Deletes a live vertex and all incident edges.  Returns true when a vertex was
deleted and false when the ID is well-formed but absent.  Deleted IDs are not
reused.

=head2 delete_vertex_by_name

    my $deleted = $g->delete_vertex_by_name($name);

Deletes the named vertex and its incident edges.  Returns false when the name
is absent.  Otherwise this is equivalent to
C<delete_vertex_by_id(vertex_id_by_name($name))>.

=head2 vertex_ids

    my $ids = $g->vertex_ids;

Returns an array reference containing all live vertex IDs in ascending order.

=head2 vertices

    my $ids = $g->vertices;

Alias for C<vertex_ids>, provided as a conventional graph spelling.

=head2 vertex_count

    my $count = $g->vertex_count;

Returns the number of live vertices.

=head2 vertex

    my $vertex = $g->vertex($id);

Returns a lightweight C<XGraph::Vertex> view for a live vertex.  The view
retains the graph through a normal Perl reference and keeps the numeric ID as
the vertex's identity.  Its C<id> and C<graph> remain available after vertex
deletion, while operations that query live vertex state throw
C<XPERL.GRAPH.UNKNOWN_VERTEX>.

=head2 vertex metadata

    $g->set_vertex_metadata($id, $value);
    my $value = $g->vertex_metadata($id);
    my $present = $g->has_vertex_metadata($id);
    $g->delete_vertex_metadata($id);

Associates one arbitrary Perl value with a vertex.  The association is
optional, and an explicitly stored C<undef> can be distinguished from an
absent value with C<has_vertex_metadata>.  Metadata is owned by the graph's
Perl-side registry; referenced values are not deep-cloned.

=head1 LABEL METHODS

=head2 declare_label

    $g->declare_label($label);

Registers a non-empty string label, or does nothing if it is already known.
The graph is returned.  C<undef> and the empty string are reserved and do not
consume registration capacity.  A reference throws
C<XPERL.GRAPH.INVALID_LABEL>.

=head2 declare_labels

    $g->declare_labels(@labels);

Registers several labels and returns the graph.  The complete input is
validated before the graph is changed, so a failed declaration is atomic.

=head2 labels

    my $labels = $g->labels;

Returns an array reference in label-ID order.  The first two elements are
C<undef> and the empty string.

=head2 label_count

    my $count = $g->label_count;

Returns the number of valid labels, including the two reserved labels.

=head1 EDGE METHODS

The C<_by_ids> methods take numeric vertex IDs.  The C<_by_names> methods
resolve both endpoint names before performing the same operation.  The label
argument is optional and defaults to C<undef>.

=head2 add_edge_by_ids, add_edge_by_names

    $g->add_edge_by_ids($from_id, $to_id, $label);
    $g->add_edge_by_names($from_name, $to_name, $label);

Adds one directed edge and returns true.  Unknown endpoints, duplicate edge
tuples, invalid labels, undeclared strict labels, and cycle rejection throw.
The mutation is not partially committed when one of these checks fails.

=head2 add_edge

    $g->add_edge($from_id, $to_id, $label);

Alias for C<add_edge_by_ids>.

The singular spelling C<add_edge_by_name> is also provided as a Perl
convenience alias for C<add_edge_by_names>.

=head2 has_edge_by_ids, has_edge_by_names

    $g->has_edge_by_ids($from_id, $to_id, $label);
    $g->has_edge_by_names($from_name, $to_name, $label);

Returns true when the exact tuple exists.  The ID form throws for an unknown
endpoint.  The name form returns false when either name is absent.  Looking up
an unknown non-empty label does not register it.

=head2 has_edge

    $g->has_edge($from_id, $to_id, $label);

Alias for C<has_edge_by_ids>.

C<has_edge_by_name> is the corresponding singular alias for
C<has_edge_by_names>.

=head2 delete_edge_by_ids, delete_edge_by_names

    my $deleted = $g->delete_edge_by_ids($from_id, $to_id, $label);
    my $deleted = $g->delete_edge_by_names($from_name, $to_name, $label);

Deletes the exact tuple and returns true.  Returns false when the tuple is
absent.  The name form also returns false when either endpoint name is absent.

=head2 delete_edge

    $g->delete_edge($from_id, $to_id, $label);

Alias for C<delete_edge_by_ids>.

C<delete_edge_by_name> is the corresponding singular alias for
C<delete_edge_by_names>.

=head2 edges

    my $edges = $g->edges;

Returns all edges as C<[FROM_ID, TO_ID, LABEL]> array references.  Results are
ordered by source ID, destination ID, and internal label registration order.

=head2 edges_between

    my $edges = $g->edges_between($from_id, $to_id);

Returns all labelled edges between two numeric endpoint IDs.  The result is
ordered by label registration order.

=head2 out_edges, in_edges

    my $out = $g->out_edges($id);
    my $in  = $g->in_edges($id);

Return outgoing or incoming edge tuples for a live vertex.  The result is
ordered by the adjacent vertex ID and then the label registration order.

=head2 out_neighbors, in_neighbors

    my $out = $g->out_neighbors($id);
    my $in  = $g->in_neighbors($id);

Return an array reference of adjacent vertex IDs.  There is one result per
edge, so differently labelled parallel edges produce repeated IDs.

=head2 undirected_neighbors

    my $neighbors = $g->undirected_neighbors($id);

Returns the unique vertex IDs adjacent to C<$id> when edge direction is
ignored.  Incoming and outgoing relationships are combined, parallel labels
are collapsed to one neighbor, and a loop appears once.  This is an
undirected interpretation of the directed graph; it does not create reverse
edges and does not change path, cycle, degree, or edge-count semantics.

=head2 out_degree, in_degree

    my $out_degree = $g->out_degree($id);
    my $in_degree  = $g->in_degree($id);

Return the number of outgoing or incoming edge tuples.  Loops contribute to
both degrees.

=head2 edge_count

    my $count = $g->edge_count;

Returns the number of live edge tuples.

=head1 ALGORITHMS

All algorithm arguments and results use numeric vertex IDs.  Every method
which takes a vertex ID requires a live vertex unless stated otherwise.

=head2 has_path, path, shortest_path

    $g->has_path($from, $to);
    my $path = $g->path($from, $to);
    my $shortest = $g->shortest_path($from, $to);

C<has_path> returns a boolean.  C<path> and C<shortest_path> return an array
reference ordered from source to destination, or C<undef> if no path exists.
The shortest path is measured in edges.  A query from a vertex to itself
requires a loop or a longer cycle.

=head2 descendants, strict_descendants, ancestors, strict_ancestors

    $g->descendants($id);
    $g->strict_descendants($id);
    $g->ancestors($id);
    $g->strict_ancestors($id);

Return reachable IDs as an array reference.  The non-strict forms include the
starting vertex.  The strict forms require at least one edge, but a cycle may
still cause the starting vertex to appear.

=head2 dfs_preorder, dfs_postorder, dfs_reverse_postorder

    $g->dfs_preorder($id);
    $g->dfs_postorder($id);
    $g->dfs_reverse_postorder($id);

Return the IDs reachable from the start in the corresponding depth-first
order.  Adjacency ordering makes the result deterministic.

=head2 topological_sort

    my $order = $g->topological_sort;

Returns a topological ordering, or C<undef> if the graph contains a cycle.
The empty graph returns an empty array reference.  When more than one vertex
is available, the smallest ID is selected first.

=head2 is_acyclic

    my $acyclic = $g->is_acyclic;

Returns true when the graph has no directed cycle.

=head2 source_vertices, sink_vertices, loop_vertices

    $g->source_vertices;
    $g->sink_vertices;
    $g->loop_vertices;

Return IDs with in-degree zero, out-degree zero, or a self-loop,
respectively.

=head2 weakly_connected_components, strongly_connected_components,
cyclic_strongly_connected_components

    $g->weakly_connected_components;
    $g->strongly_connected_components;
    $g->cyclic_strongly_connected_components;

Return an array reference of array references.  Each inner array contains one
component's vertex IDs.  Weak components ignore edge direction.  Strong
components use directed reachability.  The cyclic form retains only strong
components containing more than one vertex or a self-loop.

=head2 strongly_connected_components_tarjan

    my $components = $g->strongly_connected_components_tarjan;

Returns the same mathematical result as
C<strongly_connected_components>, but uses Tarjan's one-pass algorithm.  This
method is useful for studying and comparing the two classic SCC algorithms.
The component and member ordering follows the same deterministic rules as the
ordinary method.

=head2 strongly_connected_components_pearce

    my $components = $g->strongly_connected_components_pearce;

Returns the same component partition using David Pearce's space-efficient
variant of Tarjan's algorithm.  XGraph uses the paper's non-recursive
continuation-stack form, so a long DFS path does not consume the C call stack.
The result has the same deterministic component and member ordering as the
other SCC methods.  See L<https://whileydave.com/publications/Pea16_IPL_preprint.pdf>
for the algorithm's derivation and storage invariants.

=head2 strongly_connected_components_tarjan_zwick

    my $components = $g->strongly_connected_components_tarjan_zwick;

Returns the same component partition using the compact iterative Tarjan
variant used by current SciPy releases.  It counts discovery timestamps
backwards, reuses one high-link array for active and completed vertices, and
uses explicit stacks instead of C recursion.  The result has the same
deterministic component and member ordering as the other SCC methods.

=head2 cycle, shortest_cycle

    my $cycle = $g->cycle;
    my $shortest = $g->shortest_cycle;

Return a closed cycle as an ID array reference, or C<undef> when no cycle
exists.  A self-loop is represented as C<[$id, $id]>.

=head2 is_tree

    my $tree = $g->is_tree;

Returns true when the non-empty directed graph is a weakly connected tree
when edge direction is ignored.  Loops and parallel labelled edges prevent a
graph from being a tree.

=head2 is_arborescence, arborescence_root

    my $is_arborescence = $g->is_arborescence;
    my $root = $g->arborescence_root;

An arborescence has one root with in-degree zero, every other vertex has
in-degree one, and every vertex is reachable from the root.  The predicate
returns a boolean.  The root method returns the root ID or C<undef>.

=head2 delete_paths

    my $removed = $g->delete_paths($from, $to);

Repeatedly finds paths from C<$from> to C<$to> and deletes every labelled edge
on those paths.  Returns the number of edge tuples removed.  This mutates the
graph and is unavailable after C<freeze>.

=head2 reachability_roots

    my $roots = $g->reachability_roots;

Returns the smallest ID from each source strongly connected component.  The
returned roots form a deterministic minimal set from which every live vertex
is reachable.

=head2 induced_subgraph

    my $subgraph = $g->induced_subgraph(\@vertex_ids);

Returns a new mutable graph containing the selected live vertices and every
edge whose endpoints are selected.  IDs, names, and label registration order
are preserved.  The input must be an array reference of vertex IDs.

=head2 condensation

    my $result = $g->condensation;

Returns a hash reference with these keys:

=over 4

=item C<graph>

A new mutable acyclic graph.  Each vertex represents one strongly connected
component of the original graph.

=item C<components>

An array reference of component arrays.  Component number C<N> is represented
by vertex ID C<N + 1> in the condensed graph.

=item C<component_of>

An array reference mapping each original vertex ID to its condensed component
ID.  Element zero is unused.

=back

=head1 ITERATION

=head2 vertex_iterator

    my $next = $g->vertex_iterator;
    while (defined(my $id = $next->())) {
        ...
    }

Returns a Perl closure which yields live vertex IDs in ascending order and
returns C<undef> after exhaustion.  The closure retains the graph.  A
structural mutation invalidates the cursor and the next call throws
C<XPERL.GRAPH.ITERATOR_INVALIDATED>.

The cursor is an ordinary XS object wrapped by Perl code.  It is not a Perl
generator and it does not suspend an XS call stack.  XGraph does not expose
C<_vertex_cursor> as a public API.

=head2 fold_vertices

    my $result = $g->fold_vertices($initial, \&Reducer::visit, $context);

Folds over live vertices in ascending ID order.  The callback is invoked as

    ($vertex, $accumulator, $context)

and must return the next accumulator.  The context argument is optional and
is C<undef> when omitted; it allows a named subroutine to receive per-fold
state without requiring a closure.  The callback receives an
C<XGraph::Vertex> view, whose C<id>, C<name>, and C<metadata> methods expose
the vertex information without copying the graph topology.

The cursor is invalidated by structural graph mutation during the fold.  A
metadata update does not change topology and does not invalidate it.

=head1 GRAPHVIZ OUTPUT

=head2 to_dot

    my $dot = $g->to_dot;
    my $dot = $g->to_dot(
        graph_name => 'Build',
        show_ids   => 1,
    );

Returns a deterministic Graphviz DOT document.  Vertices use stable DOT node
IDs such as C<v1> and are emitted in numeric ID order.  Named vertices use
their names as labels.  Anonymous vertices use their DOT node IDs as labels.
Edges are emitted as directed C<< -> >> statements.  Defined edge labels are
written as DOT C<label> attributes.  An C<undef> label has no attribute, while
the empty string is written as C<label="">.

C<graph_name> defaults to C<XGraph>.  C<show_ids> appends the numeric ID to
each vertex label.  The writer escapes quotes, backslashes, and control
characters needed by DOT quoted strings.  It does not require Graphviz to be
installed.

=head2 write_dot

    $g->write_dot('build.dot', graph_name => 'Build');

Writes the same document as C<to_dot> to a raw-byte file and returns true on
success.  The DOT writer is implemented in the separate
C<XGraph::IO::DOT> Perl module, which can also be called directly with
C<XGraph::IO::DOT::to_string> and C<XGraph::IO::DOT::write_file>.

=head1 REPRESENTATION AND LIMITS

The default build stores each adjacency occurrence in one 32-bit word.  The
upper 24 bits hold a vertex ID and the lower 8 bits hold a label ID.  This
limits a compact graph to vertex IDs through C<0xFFFFFF> and label IDs through
C<255>, including the two reserved labels.  A deleted ID remains consumed.

Set C<XGRAPH_WIDE=1> while running C<Makefile.PL> to build the validation
variant with 32-bit vertex and label fields.  This is a compile-time choice,
not a run-time promotion mechanism or a serialization format.

The native topology contains only integers.  Perl strings and metadata values
are kept in graph-side Perl registries.  Metadata is optional and does not
consume native vertex storage.

=head1 ERRORS

Failures currently use C<croak> with an C<XPERL.GRAPH.*> code.  Important
codes include:

=over 4

=item C<XPERL.GRAPH.INVALID_ARGUMENT>

Malformed calls, options, or containers.

=item C<XPERL.GRAPH.INVALID_VERTEX_ID>

A required ID is a reference, non-integral, zero, negative, or outside the
compiled representation.

=item C<XPERL.GRAPH.UNKNOWN_VERTEX>

A well-formed ID or name does not identify a live vertex where one is required.

=item C<XPERL.GRAPH.DUPLICATE_VERTEX_NAME>

Adding or renaming would reuse a live vertex name.

=item C<XPERL.GRAPH.INVALID_LABEL>

A label is a reference or cannot be normalized as a string.

=item C<XPERL.GRAPH.UNKNOWN_LABEL>

Strict mode received an undeclared non-empty label.

=item C<XPERL.GRAPH.LABEL_LIMIT>, C<XPERL.GRAPH.VERTEX_ID_EXHAUSTED>

The compact representation cannot allocate another label or vertex ID.

=item C<XPERL.GRAPH.EDGE_EXISTS>

The exact edge tuple already exists.

=item C<XPERL.GRAPH.CYCLE_REJECTED>

An insertion into an acyclic graph would create a cycle.

=item C<XPERL.GRAPH.FROZEN>

A mutation was attempted after C<freeze>.

=item C<XPERL.GRAPH.ITERATOR_INVALIDATED>

A cursor observed a structural mutation after it was created.

=back

Predicate and deletion methods return false for ordinary absence where this
document says they do so.  Methods which require a live vertex throw for an
unknown vertex.  A malformed ID is not treated as ordinary absence.

=head1 THREADS AND CORE INTEGRATION

The graph, vertex-view, and cursor classes use C<CLONE_SKIP>.  They are not
cloned into child interpreters, and frozen native stores are not shared
between ithreads.  The Perl closure around C<XGraph::Cursor> is the current
lazy interface; no new Perl-core generator or iterator C API is required.

=head1 DOCUMENTATION

The repository's C<planning/> directory contains the design record.  The
most useful files are:

=over 4

=item F<planning/xgraph.md>

The normative data model, API contract, representation, ownership rules,
algorithms, and deferred work.

=item F<planning/xgraph-implementation-packets.md>

The bounded implementation and validation packets.

=item F<planning/xperl-graph-module-recommendations.md>

The rationale for the XGraph API and its comparison with the OTP graph model.

=item F<planning/xgraph-discussion-summary.md>

A concise summary of the design discussion.

=back

=head1 SEE ALSO

C<Graph> is the established CPAN graph distribution.  XGraph has a different
data model and is not API-compatible with it.  OTP's C<graph> module is the
semantic reference for several algorithms, but XGraph uses Perl-oriented
names, return values, and mutation semantics.

Graphviz DOT language: L<https://graphviz.org/doc/info/lang.html>

=head1 AUTHOR

Yves Orton, E<lt>demerphq@(none)E<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by Yves Orton

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself, either Perl version 5.36.3 or, at your option,
any later version of Perl 5 you may have available.

=cut
