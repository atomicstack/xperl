package XPerl::Exception;

1;

__END__

=head1 NAME

XPerl::Exception - A structured exception with ordered diagnostics

=head1 DESCRIPTION

An XPerl::Exception holds an ordered array of diagnostics. Propagation paths
can append context diagnostics without replacing the original diagnostics.
The private C<_record_throw> method can record an origin, but ordinary core
delivery does not currently populate it automatically. The exception's
C<kind> and C<severity> are derived from its diagnostic tree: the
first fatal or internal error in depth-first order takes precedence, then the
first warning, including deprecations and severe warnings. With neither,
the accessors return undef. Appending an error to a warning-only exception
changes its derived state.

Locale construction runs before exception hooks and C<${^DIAG_RENDER}> are
initialized. Its startup warnings use the permanent English catalog and
plain-text direct output. Language packs load later, before user compilation.
Serialization settings apply to ordinary
exception delivery. C<PERL_BADLANG> and the initialization API's warning
control retain their existing behavior.

See L<perlexcept> for the complete Perl-facing guide and L<perlexcephack>
for the core implementation.

The constructor and mutation methods are currently private to the core
diagnostics work.

C<${^DIAG_RENDER}> controls implicit stringification. It is initialized from
C<PERL_DIAG_RENDER> at startup, defaulting to C<auto:legacy>. Assignments apply
at render time, including to previously caught exceptions, and C<local>
restores the previous setting on scope exit. A diagnostic captured under
L<diagpack> retains that lexical language instead; presentation style and
serialization still follow the current setting. For example:

    local ${^DIAG_RENDER} = 'fr:annotated';
    print $exception;

Text settings have the form C<language:format>. Formats are C<legacy> and
C<annotated>. A bare language such as C<de> means C<de:legacy>.
Bare C<auto> means C<auto:legacy>. C<auto> chooses the language from the first nonempty environment
value among C<LC_ALL>, C<LC_MESSAGES>, and C<LANG>. A locale's language prefix
is used, so C<fr_FR.UTF-8> selects C<fr>. C<C>, C<POSIX>, missing settings, and
missing translations fall back to English. This selection is independent of
terminal encoding and output layers. Startup loads the selected pack, except
in taint mode. A failed load reports one English warning and keeps English
available. Later rendering never loads modules: require
C<XPerl::DiagPack::DE>, for example, to make German available, or use
C<use XPerl::DiagPack qw(all)> to load installed packs. Loading alone does not
select a language.

An optional third component selects a serialized envelope, for example
C<en:legacy:JSON> or C<fr:annotated:Dumper>. Each physical line contains one
logical message group, including attached hints or following location
context. The record contains C<schema>, the human C<message>, the primary
disposition as C<type>, and a C<contents> array. Fatalized warnings use
C<FATAL_ERROR> as the record type. Embedded newlines are escaped.
The schema is C<xperl.diagnostic-group.v2>. Independent warnings and errors
have separate groups.

C<JSON> and C<JSONL> are aliases for C<en:legacy:JSON>. C<Dumper> and
C<DumperL> are aliases for C<en:legacy:Dumper>. Dumper records are unblessed
Perl hash literals with the same fields as JSON records. Both writers are
implemented in the core and require no serialization module. They select
public fields explicitly and do not dump private object contents.
Unrecognized settings fall back to English legacy output. C<render($setting)>
accepts the same settings. Without an argument it uses legacy text and an
English default, while honoring captured lexical languages. Implicit
stringification instead reads C<${^DIAG_RENDER}>. An explicit language
overrides lexical choices throughout the tree. Independent entries can retain different lexical choices during
implicit rendering.

C<render_as_annotated($language)> is the descriptive name for the metadata
format. C<render_as_modern($language)> remains an alias. It
renders the whole exception from catalog templates and diagnostic data for
the requested language. Consecutive identical headers are shown once, and
contained hints appear on their own indented lines under the parent's
header. Parser context, including nearby source text, is retained.
English annotated syntax errors use sentence capitalization and put nearby
source before the file and line. Legacy wording and ordering are preserved.
Diagnostic objects do not retain rendered C<text>
fields or copies of templates. The class methods are compiled into Perl and
miniperl, so they work before this file is loaded. Parser compile
failures, catalogued C<croak> and C<DIE> failures, and
catalogued warnings deliver objects by default. Plain C<die "text"> and
C<warn "text"> get C<ERROR_USER_TEXT> and C<WARNING_USER_TEXT> diagnostics
respectively, with the text as a parameter. Uncatalogued C croak/die text uses a generic
C<ERROR_USER_TEXT> diagnostic.

C<as_json> returns a JSON document without loading a JSON module.
This explicit inspection API is separate from line-oriented delivery. The
C<xperl.exception.v2> document has derived C<kind> and C<severity>, an ordered
C<contents> array of immediate roots, and C<origin>. Each diagnostic uses
the C<xperl.diagnostic.v2> schema and contains an ordered C<contents> array,
including an empty array for leaves. Propagation context is represented in
that array, so JSON has no separate history list. Missing values are JSON null.
Private delivery bookkeeping is omitted.
The schema is independent of the object's private hash layout. To inspect
private contents, call Data::Dumper yourself from C<__EXCEPT__> or inspect
C<${^CUR_ERROR_OBJ}> in a legacy hook.

=head1 HOOK DELIVERY

C<__EXCEPT__> receives the canonical exception once before the legacy hooks.
It may change diagnostic content or promote severity. Legacy hook replacements
do not invoke it again. C<__WARN__> and C<__DIE__> retain one argument, with
C<${^CUR_ERROR_OBJ}> exposing the canonical exception during each handler.

Returning from C<__WARN__> suppresses automatic warning output. A warning or
error emitted by the handler is captured for delivery after it finishes.
A dying warning handler stops at its protected boundary, so the remaining
diagnostics can still be handled before the application unwinds.

Returning from C<__DIE__> does not suppress fatal output or unwinding. A die
inside it replaces the current error group without calling that hook again
for its replacement. Later independent error groups visit the hook separately.
C<__DIE__> receives the rendered group, or the original user-thrown reference.
A nonfinal textual error argument includes a localized unwind-deferred hint.
Reference arguments retain their identity without that suffix. A warning
inside the die hook calls C<__WARN__> directly. A die in that warning handler replaces
the enclosing die handler's fatal error.

After each group finishes its hook, automatic output for that group is written
before the next group is delivered. This includes JSON and Dumper envelopes.
Caught errors have no automatic fatal output. The application unwinds once
after all groups finish. Pure compilation error batches are delivered together,
and light diagnostics stay with their linked tail. Explicit C<print STDERR>
in hooks is immediate. Hooks may rewrite their argument; rewritten output is
not required to remain a valid serialized record.

A warning emitted by C<__EXCEPT__> is captured without calling either warning
or exception hooks again. A die ends that handler and supplies a replacement
for the legacy die stage. Explicit C<print STDERR> and file logging remain
immediate side effects and are never captured by this machinery.

=cut
