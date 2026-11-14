package XPerl::Diagnostic::Catalog;
use strict;
use warnings;

our $VERSION = '0.01';

sub _pairs {
    die 'Expected name/value pairs' if @_ % 2;
    my %values;
    while (@_) {
        my ($name, $value) = splice @_, 0, 2;
        die 'Duplicate argument' if exists $values{$name};
        $values{$name} = $value;
    }
    return \%values;
}

sub define {
    my ($class, @definition) = @_;
    return $class->_register(_pairs(@definition));
}

sub diagnostic {
    my ($self, $condition, @values) = @_;
    my (undef, $file, $line) = caller;
    return $self->_capture($condition, _pairs(@values), $file, $line);
}

sub exception {
    my ($self, $condition, @values) = @_;
    my (undef, $file, $line) = caller;
    my $exception = XPerl::Exception->_new;
    $exception->append($self->_capture($condition, _pairs(@values), $file, $line));
    return $exception;
}

sub emit {
    my ($self, $condition, @values) = @_;
    my (undef, $file, $line) = caller;
    my $exception = XPerl::Exception->_new;
    $exception->append($self->_capture($condition, _pairs(@values), $file, $line));
    $exception->_record_throw({ reason => 'throw', file => $file, line => $line });
    die $exception if $exception->has_errors;
    warn $exception;
    return;
}

1;

__END__

=head1 NAME

XPerl::Diagnostic::Catalog - Experimental module-owned diagnostic definitions

=head1 DESCRIPTION

This prototype lets an X module declare conditions without adding them to the
core diagnostic catalog. The API is experimental and may change.

    my $catalog = XPerl::Diagnostic::Catalog->define(
        namespace => 'Example',
        conditions => {
            EMPTY => {
                class => 'Example::Diagnostic::Empty',
                parent => 'XPerl::Diagnostic::Error::Numeric::Domain',
                severity => 'FATAL_ERROR',
                params => [{ name => 'operation', type => 'text' }],
                templates => { en => 'No observations for %{operation}' },
            },
        },
    );
    $catalog->emit('EMPTY', operation => 'mean');

Conditions have namespace-qualified codes, such as C<Example::EMPTY>, and
no core diagnostic number. Definitions are copied, compiled and retained as
immutable interpreter-owned data. Repeating an identical definition returns
the same catalog. Conflicting definitions are rejected.

The catalog creates ancestry only for classes without existing descendants.
For an established hierarchy, predeclare matching ancestry before registering
the catalog. Registration does not alter that hierarchy.

Each condition requires C<class>, C<parent>, C<severity>, C<params> and
C<templates>. Classes must be below C<namespace::Diagnostic::>. Severity is
C<FATAL_ERROR>, C<WARNING> or C<NOTE>, with a matching existing diagnostic
parent class. Parameters have unique names and types C<text>, C<iv>, C<uv>,
C<nv> or C<bool>. Numeric parameters require numeric values without string
coercion. NV parameters must be finite. References and magical values are
rejected. English templates are required. Named placeholders refer to declared
parameters. Rendering uses captured or explicitly selected languages, falls
back to English and never loads a module or calls a module renderer.

The prototype permits at most 256 conditions, 32 parameters per condition,
and 32 translations per condition. Identifiers are limited to 255 bytes and
text values to 65,536 bytes. Rendering stops at a one-megabyte output limit
and uses a bounded fallback for malformed private data.

C<diagnostic> constructs one diagnostic. C<exception> constructs an exception
containing it without recording a throw. C<emit> records the first origin and
delivers through the ordinary exception machinery. Warnings follow warning
delivery. All three methods take a condition name and named parameter values
and record the caller's source location.

Append a catalog diagnostic to an existing exception to retain its identity
and history. C<derive> preserves the module definition when replacing a
diagnostic's contents. Note diagnostics remain leaf-only.

=cut
