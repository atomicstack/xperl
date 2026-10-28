package XPerl::Diagnostic;

1;

__END__

=head1 NAME

XPerl::Diagnostic - A structured diagnostic message

=head1 DESCRIPTION

An XPerl::Diagnostic holds one symbolic diagnostic code, its parameters,
and its source location. XPerl::Exception objects keep diagnostics in the
order they were reported. Its methods are compiled into Perl and miniperl;
loading this file is not required to use a diagnostic.

Diagnostics store their code, number, typed parameters, and source location.
They do not store a rendered message or a copy of the catalog template. The
compatibility C<selector_key> accessor derives its value from the current
parameters. Rendering reads the same current values and selects the requested
language's template. L<diagpack> can capture a lexical language choice when
the diagnostic is constructed. That choice survives later changes to the
default language or replacement of the registered pack. An explicit render
language overrides it.

Plural selectors retain their unsigned numeric sources in C<params>, even
when the count is not displayed. Their bytes in the compatibility
C<selector_key> value are zero.
Rendering resolves cardinal or ordinal categories for the requested
language and tests diagnostic-specific exact-number cases against the
original count. C<other> is a category. C<any> and C<*> are equivalent
template fallbacks, normalized to C<*> in the catalog.

The constructor is currently private to the core diagnostics work.

Diagnostics share the C<XPerl::DiagGroup> operations C<contents>,
C<contents_count>, C<append>, C<contains>, and C<has_errors>. C<derive> returns
a distinct diagnostic of the same class and metadata with replacement
contents; it preserves diagnostic references and leaves the original unchanged.
C<contents> returns the immediate diagnostic references in a new array.
C<append> rejects containment cycles and Note diagnostics cannot contain
other diagnostics.

C<render_as_json> (also named C<as_json>) returns a C<xperl.diagnostic.v2> JSON document without loading
a JSON module. The document contains C<code>, C<number>, C<kind>,
C<severity>, C<selector_key>, C<params>, and C<location>.
The location currently contains C<file> and C<line>.
Categorized warnings include C<warning_categories>, an array of symbolic
category names such as C<WARN_UNINITIALIZED>. Other diagnostics omit it.
Categorized core warning subclasses follow the warning-control hierarchy.
Diagnostics with runtime-selected categories use their category class, or the
common ancestor when several categories apply. Their catalog class is the
generic Warning base. Uncategorized diagnostics retain subject classes.
An explicit catalog class overrides runtime class inference. Warning categories
control enablement and fatalization independently of that override.
Compatibility hint records include C<is_hint> and C<has_following_hint>.
A fatalized warning is contained in an C<Error::FatalizedWarning> diagnostic
with code C<ERROR_FATALIZED_WARNING_WRAPPER>, number 2719, and fatal severity.
The original warning keeps its own identity and severity in the wrapper's
contents. The C<fatal> flag records fatal handling. Each diagnostic has an
ordered C<contents> array;
leaves serialize it as empty. Each ordinary parameter has
C<name>, C<type>, and a stringified C<value>.

Locale panics retain their C source file and line, errno, extended errno,
and higher caller location under C<location-E<gt>{panic}>. This context is
separate from the diagnostic's Perl source location. Rendering combines
the semantic failure and this context through catalog formats.
The type records the value's semantic type before stringification. Special
parameters, such as a reference thrown by user code, may retain a reference
value. C<render('legacy')> uses the captured language, or English when no
lexical language was captured.
C<render_as_legacy> accepts an explicit language. Source-location wording,
regex context, and missing-context notices use that language with English
fallback. Regex position markers such as C<< <-- HERE >> retain their syntax.
Legacy caller-created light diagnostics include their own location and explain
that following context is unavailable when the referenced tail is missing.
Missing values are JSON null. The output fields are selected explicitly
rather than copied from the object's private hash. Serialization preserves
valid deep trees without a fixed diagnostic-depth cutoff and emits a shared
subtree at each occurrence. An invalid ancestor cycle introduced through
private hash edits is cut at its back edge, which serializes as null.

C<render_as_dumper> returns a single-line unblessed Perl hash literal with
these same selected fields. Unicode, control characters, quotes, backslashes,
and Perl interpolation characters are escaped. It requires no Data::Dumper
module. Missing values are C<undef>; opaque reference parameter values are
not recursively serialized and appear as null in JSON or C<undef> in Dumper.
Exception rendering adds the translated human message and groups related
records into delivery envelopes. These standalone methods return only the
diagnostic record.

=cut
