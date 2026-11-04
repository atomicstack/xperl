package XGraph::Reference;

use strict;
use warnings;

# Deliberately ordinary Perl storage used as a behavioral oracle for the XS
# implementation.  It is not intended to model the compact native layout.

sub new {
    my ($class, %opt) = @_;
    die "XPERL.GRAPH.INVALID_ARGUMENT" if grep { $_ ne 'acyclic' && $_ ne 'strict_labels' } keys %opt;
    return bless {
        acyclic      => $opt{acyclic} ? 1 : 0,
        strict       => $opt{strict_labels} ? 1 : 0,
        frozen       => 0,
        next_id      => 1,
        live         => {},
        name_to_id   => {},
        id_to_name   => {},
        labels       => [ undef, undef, '' ],
        label_to_id  => { '' => 2 },
        edges        => {},
    }, $class;
}

sub _mutable { die "XPERL.GRAPH.FROZEN" if $_[0]{frozen} }
sub _name {
    my ($v) = @_;
    die "XPERL.GRAPH.INVALID_ARGUMENT" if ref $v;
    return undef unless defined $v;
    return "$v";
}
sub _label {
    my ($v) = @_;
    die "XPERL.GRAPH.INVALID_LABEL" if ref $v;
    return undef unless defined $v;
    return "$v";
}
sub _id {
    my ($self, $v) = @_;
    die "XPERL.GRAPH.INVALID_VERTEX_ID" if ref $v || !defined($v) || "$v" !~ /\A[1-9][0-9]*\z/;
    die "XPERL.GRAPH.UNKNOWN_VERTEX" unless $self->{live}{$v};
    return 0 + $v;
}
sub _lid {
    my ($self, $label, $declare) = @_;
    $label = _label($label);
    return 1 unless defined $label;
    return 2 if $label eq '';
    return $self->{label_to_id}{$label} if exists $self->{label_to_id}{$label};
    die "XPERL.GRAPH.UNKNOWN_LABEL" if $self->{strict} && !$declare;
    die "XPERL.GRAPH.LABEL_LIMIT" if @{$self->{labels}} >= 256;
    my $id = @{$self->{labels}};
    push @{$self->{labels}}, $label;
    $self->{label_to_id}{$label} = $id;
    return $id;
}
sub _key { join "\0", $_[1], $_[2], $_[3] }

sub freeze { $_[0]{frozen} = 1; $_[0] }
sub is_frozen { !!$_[0]{frozen} }
sub clone { my $c = bless { %{$_[0]} }, ref $_[0]; _deepcopy($c, $_[0]); $c }
sub mutable_copy { my $c = $_[0]->clone; $c->{frozen} = 0; $c }
sub _deepcopy {
    my ($dst, $src) = @_;
    $dst->{live} = { %{$src->{live}} };
    $dst->{name_to_id} = { %{$src->{name_to_id}} };
    $dst->{id_to_name} = { %{$src->{id_to_name}} };
    $dst->{labels} = [ @{$src->{labels}} ];
    $dst->{label_to_id} = { %{$src->{label_to_id}} };
    $dst->{edges} = { %{$src->{edges}} };
}

sub add_vertex {
    my ($self, $name) = @_;
    $self->_mutable;
    $name = _name($name);
    die "XPERL.GRAPH.DUPLICATE_VERTEX_NAME" if defined($name) && exists $self->{name_to_id}{$name};
    my $id = $self->{next_id}++;
    $self->{live}{$id} = 1;
    if (defined $name) { $self->{name_to_id}{$name} = $id; $self->{id_to_name}{$id} = $name }
    return $id;
}
sub has_vertex_id { my ($self, $id) = @_; return 0 if ref($id) || !defined($id) || "$id" !~ /\A[1-9][0-9]*\z/; !!$self->{live}{0+$id} }
sub vertex_id_by_name { my ($self, $name) = @_; $name = _name($name); return undef unless defined $name; $self->{name_to_id}{$name} }
sub vertex_name_by_id { my ($self, $id) = @_; $id = $self->_id($id); $self->{id_to_name}{$id} }
sub rename_vertex {
    my ($self, $id, $name) = @_; $self->_mutable; $id = $self->_id($id); $name = _name($name);
    die "XPERL.GRAPH.DUPLICATE_VERTEX_NAME" if defined($name) && exists($self->{name_to_id}{$name}) && $self->{name_to_id}{$name} != $id;
    if (exists $self->{id_to_name}{$id}) { delete $self->{name_to_id}{$self->{id_to_name}{$id}}; delete $self->{id_to_name}{$id} }
    if (defined $name) { $self->{name_to_id}{$name} = $id; $self->{id_to_name}{$id} = $name }
    return 1;
}
sub delete_vertex_by_id {
    my ($self, $id) = @_; return 0 unless $self->has_vertex_id($id); $self->_mutable; $id = 0+$id;
    delete $self->{name_to_id}{$self->{id_to_name}{$id}} if exists $self->{id_to_name}{$id}; delete $self->{id_to_name}{$id}; delete $self->{live}{$id};
    delete $self->{edges}{$_} for grep { (split /\0/)[0] == $id || (split /\0/)[1] == $id } keys %{$self->{edges}};
    return 1;
}
sub delete_vertex_by_name { my ($self, $name) = @_; my $id = $self->vertex_id_by_name($name); return 0 unless defined $id; $self->delete_vertex_by_id($id) }
sub vertex_ids { [ sort { $a <=> $b } keys %{$_[0]{live}} ] }
sub vertex_count { scalar keys %{$_[0]{live}} }

sub declare_label { my ($self, $label) = @_; $self->_mutable; $self->_lid($label, 1); $self }
sub declare_labels {
    my ($self, @labels) = @_; $self->_mutable;
    my @norm = map { _label($_) } @labels;
    my %new = map { defined($_) && length($_) ? ($_ => 1) : () } @norm;
    delete @new{keys %{$self->{label_to_id}}};
    die "XPERL.GRAPH.LABEL_LIMIT" if @{$self->{labels}} + keys(%new) > 256;
    $self->_lid($_, 1) for @norm;
    return $self;
}
sub labels { my ($self) = @_; [ @{$self->{labels}}[1 .. $#{$self->{labels}}] ] }
sub label_count { my ($self) = @_; scalar @{$self->{labels}} - 1 }

sub add_edge_by_ids {
    my ($self, $from, $to, $label) = @_; $self->_mutable; $from = $self->_id($from); $to = $self->_id($to); my $lid = $self->_lid($label, 0);
    die "XPERL.GRAPH.DUPLICATE_EDGE" if exists $self->{edges}{_key($self,$from,$to,$lid)};
    die "XPERL.GRAPH.CYCLE" if $self->{acyclic} && ($from == $to || $self->has_path($to,$from));
    $self->{edges}{_key($self,$from,$to,$lid)} = 1; 1;
}
sub has_edge_by_ids { my ($self, $from, $to, $label) = @_; $from = $self->_id($from); $to = $self->_id($to); my $lid = $self->_lid($label,0); !!$self->{edges}{_key($self,$from,$to,$lid)} }
sub delete_edge_by_ids { my ($self, $from, $to, $label) = @_; $self->_mutable; return 0 unless $self->has_vertex_id($from) && $self->has_vertex_id($to); my $lid = $self->_lid($label,0); my $k = _key($self,$from,$to,$lid); return 0 unless delete $self->{edges}{$k}; 1 }
sub edges {
    my ($self) = @_;
    return [ map { my ($f,$t,$l) = split /\0/; [ 0+$f, 0+$t, $self->{labels}[$l] ] }
        sort { my @a=split /\0/,$a; my @b=split /\0/,$b; $a[0]<=>$b[0] || $a[1]<=>$b[1] || $a[2]<=>$b[2] } keys %{$self->{edges}} ];
}
sub _adj {
    my ($self,$id,$out) = @_; $id = $self->_id($id);
    my @e = grep { my @p=split /\0/; $out ? $p[0] == $id : $p[1] == $id } keys %{$self->{edges}};
    return [ map { my @p=split /\0/; [0+$p[0],0+$p[1],$self->{labels}[$p[2]]] } sort @e ];
}
sub out_edges { $_[0]->_adj($_[1],1) }
sub in_edges { $_[0]->_adj($_[1],0) }
sub out_neighbors { my $a=$_[0]->out_edges($_[1]); [ map $_->[1], @$a ] }
sub in_neighbors { my $a=$_[0]->in_edges($_[1]); [ map $_->[0], @$a ] }
sub out_degree { scalar @{$_[0]->out_edges($_[1])} }
sub in_degree { scalar @{$_[0]->in_edges($_[1])} }
sub edge_count { scalar keys %{$_[0]{edges}} }
sub has_path {
    my ($self,$from,$to) = @_; $from=$self->_id($from); $to=$self->_id($to); my %seen=($from=>1); my @q=map $_->[1], @{$self->out_edges($from)};
    while (@q) { my $v=shift @q; return 1 if $v == $to; next if $seen{$v}++; push @q, @{ $self->out_neighbors($v) }; }
    return 0;
}
sub path { my ($self,$from,$to) = @_; $from=$self->_id($from); $to=$self->_id($to); my %prev=($from=>undef); my @q=($from); while(@q){my $v=shift @q; for my $n (@{$self->out_neighbors($v)}){next if exists $prev{$n};$prev{$n}=$v;push @q,$n;}} return undef unless exists $prev{$to} && defined($prev{$to}); my @p=($to); unshift @p,$prev{$p[0]} while defined $prev{$p[0]}; \@p }
sub shortest_path { $_[0]->path(@_[1,2]) }
sub add_edge_by_names { my ($self,$f,$t,$l)=@_; my $a=$self->vertex_id_by_name($f); my $b=$self->vertex_id_by_name($t); die "XPERL.GRAPH.UNKNOWN_VERTEX" unless defined $a && defined $b; $self->add_edge_by_ids($a,$b,$l) }
sub has_edge_by_names { my ($self,$f,$t,$l)=@_; my $a=$self->vertex_id_by_name($f); my $b=$self->vertex_id_by_name($t); return 0 unless defined $a && defined $b; $self->has_edge_by_ids($a,$b,$l) }
sub delete_edge_by_names { my ($self,$f,$t,$l)=@_; my $a=$self->vertex_id_by_name($f); my $b=$self->vertex_id_by_name($t); return 0 unless defined $a && defined $b; $self->delete_edge_by_ids($a,$b,$l) }

1;
