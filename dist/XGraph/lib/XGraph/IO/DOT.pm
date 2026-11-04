package XGraph::IO::DOT;

use 5.036003;
use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);

our $VERSION = '0.01';

sub _quote {
    my ($value) = @_;
    $value =~ s/\\/\\\\/g;
    $value =~ s/"/\\"/g;
    $value =~ s/\r/\\r/g;
    $value =~ s/\n/\\n/g;
    $value =~ s/\t/\\t/g;
    return '"' . $value . '"';
}

sub _check_graph {
    my ($graph) = @_;
    croak 'XPERL.GRAPH.INVALID_ARGUMENT: expected an XGraph object'
        unless blessed($graph) && $graph->isa('XGraph');
}

sub _options {
    my (@args) = @_;
    croak 'XPERL.GRAPH.INVALID_ARGUMENT: DOT options are key/value pairs'
        if @args % 2;

    my %options = (
        graph_name => 'XGraph',
        show_ids   => 0,
    );
    while (@args) {
        my ($key, $value) = splice @args, 0, 2;
        croak 'XPERL.GRAPH.INVALID_ARGUMENT: DOT option name is a reference'
            if ref($key);
        croak "XPERL.GRAPH.INVALID_ARGUMENT: unknown DOT option '$key'"
            unless exists $options{$key};
        $options{$key} = $value;
    }

    croak 'XPERL.GRAPH.INVALID_ARGUMENT: DOT graph_name is a reference'
        if ref($options{graph_name});
    return \%options;
}

=head1 NAME

XGraph::IO::DOT - write XGraph graphs in Graphviz DOT format

=head1 SYNOPSIS

    use XGraph;

    my $graph = XGraph->new;
    my $a = $graph->add_vertex('parse');
    my $b = $graph->add_vertex('emit');
    $graph->add_edge_by_ids($a, $b, 'depends_on');

    my $dot = $graph->to_dot;
    $graph->write_dot('graph.dot', graph_name => 'Build');

    # The functional interface is useful when the I/O layer is optional.
    my $same_dot = XGraph::IO::DOT::to_string($graph);

=head1 DESCRIPTION

This module provides a small, deterministic Graphviz DOT writer for XGraph.
It is a Perl I/O layer.  It does not add Graphviz as a runtime dependency and
it does not expose XGraph's packed native adjacency representation.

Vertices are emitted in ascending numeric ID order.  Their DOT node IDs are
C<v1>, C<v2>, and so on.  A named vertex uses its name as the node label.  An
anonymous vertex uses its C<v<ID>> node ID as the label.  Edge tuples are
emitted in the order returned by C<edges>, with the public edge label
as the DOT C<label> attribute when it is defined.  An C<undef> edge label has
no C<label> attribute.  An empty-string label is emitted as C<label=""> so
that it remains distinct from C<undef>.

The writer always emits a directed DOT graph.  It does not turn a pair of
opposite directed edges into one undirected edge.  An undirected rendering
option can be added later without changing the native XGraph data model.

=head1 FUNCTIONS

=head2 to_string

    my $dot = XGraph::IO::DOT::to_string($graph, %options);

Returns a complete DOT document as a string.  The supported options are:

=over 4

=item C<graph_name>

The DOT graph name.  It defaults to C<XGraph>.  References are rejected.

=item C<show_ids>

When true, append C<\n(ID N)> to every vertex label.  This is useful when a
diagram is being used to inspect stable numeric IDs.

=back

=head2 write_file

    XGraph::IO::DOT::write_file($graph, $path, %options);

Writes the same document returned by C<to_string> to C<$path> using raw
bytes.  The function returns true after the file has been closed successfully
and throws an XGraph-style invalid-argument error for malformed arguments or
an ordinary Perl error when the path cannot be opened or written.

=cut

sub to_string {
    my ($graph, @args) = @_;
    _check_graph($graph);
    my $options = _options(@args);
    my $show_ids = $options->{show_ids} ? 1 : 0;
    my $name = defined $options->{graph_name} ? "$options->{graph_name}" : '';

    my $dot = 'digraph ' . _quote($name) . " {\n";
    for my $id (@{ $graph->vertex_ids }) {
        my $vertex_name = $graph->vertex_name_by_id($id);
        my $label = defined $vertex_name ? "$vertex_name" : "v$id";
        $label .= "\\n(ID $id)" if $show_ids;
        $dot .= "  v$id [label=" . _quote($label) . "];\n";
    }

    for my $edge (@{ $graph->edges }) {
        my ($from, $to, $label) = @$edge;
        $dot .= "  v$from -> v$to";
        $dot .= ' [label=' . _quote("$label") . ']' if defined $label;
        $dot .= ";\n";
    }
    $dot .= "}\n";
    return $dot;
}

sub write_file {
    my ($graph, $path, @args) = @_;
    _check_graph($graph);
    croak 'XPERL.GRAPH.INVALID_ARGUMENT: DOT path is required'
        unless defined $path && !ref($path);
    my $dot = to_string($graph, @args);
    open my $fh, '>:raw', $path
        or croak "XPERL.GRAPH.INVALID_ARGUMENT: cannot write '$path': $!";
    print {$fh} $dot
        or croak "XPERL.GRAPH.INVALID_ARGUMENT: cannot write '$path': $!";
    close $fh
        or croak "XPERL.GRAPH.INVALID_ARGUMENT: cannot close '$path': $!";
    return 1;
}

1;
