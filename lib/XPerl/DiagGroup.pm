package XPerl::DiagGroup;

use strict;
use warnings;
use Scalar::Util qw(refaddr);

sub diagnostics {
    my ($self) = @_;
    my @pending = $self->isa('XPerl::Diagnostic')
        ? ($self) : reverse @{$self->contents};
    my @found;
    my %seen;

    while (my $diagnostic = pop @pending) {
        my $id = refaddr($diagnostic);
        next if $seen{$id}++;
        push @found, $diagnostic;
        push @pending, reverse @{$diagnostic->contents};
    }

    return \@found;
}

sub find_diagnostic {
    my ($self, $code, @requirements) = @_;
    die "diagnostic code is required\n" unless defined $code && !ref $code;
    die "diagnostic parameters must be name/value pairs\n"
        if @requirements % 2;
    my %required = @requirements;

    for my $diagnostic (@{$self->diagnostics}) {
        next unless defined $diagnostic->code && $diagnostic->code eq $code;
        my %values = map { $_->{name} => $_->{value} }
            @{$diagnostic->params};
        my $matches = 1;
        for my $name (keys %required) {
            if (!exists $values{$name}
                || !_same_value($values{$name}, $required{$name})) {
                $matches = 0;
                last;
            }
        }
        return $diagnostic if $matches;
    }

    return;
}

sub has_diagnostic {
    my ($self, @query) = @_;
    return !!$self->find_diagnostic(@query);
}

sub _same_value {
    my ($left, $right) = @_;
    return !defined $right unless defined $left;
    return 0 unless defined $right;
    return ref($left) eq ref($right) && refaddr($left) == refaddr($right)
        if ref($left) || ref($right);
    return $left eq $right;
}

1;

__END__

=head1 NAME

XPerl::DiagGroup - Common operations on diagnostic collectors

=head1 DESCRIPTION

C<XPerl::Exception> and C<XPerl::Diagnostic> inherit from this common base.
An exception collects immediate diagnostic roots. A diagnostic describes one
condition and can own subordinate diagnostics in its C<contents> list.
Containment does not change inheritance: an error can contain a warning or
a note without becoming a subclass of either.

The methods for direct contents and mutation are compiled into Perl and
miniperl. Loading this file is not required before using those methods.
The graph query methods below are written in Perl and require
C<use XPerl::DiagGroup>. The object construction and mutation interfaces
are under development and are not yet a stable public API.

=head1 METHODS

=head2 contents

Returns a new array reference containing the immediate diagnostic references
in order. It does not flatten nested contents or copy diagnostic objects.
Changing the returned array does not change the collector's contents;
changing a referenced diagnostic changes that shared object.
Both collector classes use the same C<contents> storage and accessor.
Diagnostics allocate storage when contents are added. Reading empty contents
does not allocate storage in the diagnostic.

=head2 contents_count

Returns the number of immediate diagnostic entries, not all nested entries.

=head2 append($diagnostic)

Appends a diagnostic while preserving its identity and sibling order.
Appending the collector to itself or below one of its own descendants is
rejected. Sharing a diagnostic between different branches is permitted.
There is no strong parent backreference.

Containment is allowed by default. The class registry can mark a class as
leaf-only, and subclasses inherit that restriction. Note diagnostics and
their subclasses are leaves. An instance field cannot override a class's
restriction.

=head2 contains($group)

Returns true if the receiver or one of its descendants is the supplied object.
This tests object identity, not diagnostic code or rendered text. The receiver
is included in the search.

=head2 has_errors

Returns true if the receiver or a descendant requires fatal handling. A
diagnostic's own fatal severity counts even when its contents are empty.
Existing exception error counts and recorded fatal disposition also count; deleting
visible diagnostics does not revoke an unwind that handling already requires.

=head2 diagnostics

Returns an array reference of all diagnostics in depth-first encounter order.
For a diagnostic receiver, the receiver is first. For an exception receiver,
the first root is first.
Each object appears once, even if the graph shares it through several paths.
This query does not change the exception or its diagnostics.

=head2 find_diagnostic($code, %params)

Returns the first diagnostic with the given symbolic code and optional named
parameter values, or undef. Parameter names must exist on that diagnostic.
Scalar values compare exactly. Reference values compare by identity.

=head2 has_diagnostic($code, %params)

Returns a boolean using the same matching rules as C<find_diagnostic>.

=head1 OWNERSHIP AND PRESENTATION

C<XPerl::Diagnostic-E<gt>derive($contents)> creates a distinct diagnostic with
replacement contents and the original class and own metadata. References
inside that metadata are shallowly shared. It is not a deep copy or a secure
redaction operation. General structure-preserving filtering APIs, including
C<subgroup> and C<split>, are deferred to a separate design task.

Containment and delivery grouping are different concepts. An owning error
and its notes normally form one legacy hook message, while independent
exception roots retain their order. A fatalized-warning wrapper owns the
original warning and delivers that subtree through C<__DIE__> once.

Structured serializers preserve shared subtrees at each occurrence. Invalid
ancestor cycles inserted through private hash edits serialize their back edge
as JSON C<null> or Dumper C<undef>. Valid deep trees are serialized with an
explicit traversal stack rather than a fixed diagnostic-depth cutoff. Each
parent visits at most the child positions present when its serialization
begins. The writer retains the current diagnostic and looks up each later
child in the current array, so callback-driven replacement or truncation
cannot invalidate a borrowed pointer or autovivify a missing child.

=head1 SEE ALSO

L<XPerl::Diagnostic>, L<XPerl::Exception>

=cut
