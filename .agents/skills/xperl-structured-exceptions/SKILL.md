---
name: xperl-structured-exceptions
description: Apply XPerl structured exceptions when changing its exception handling or migrating error and warning paths.
---

# Structured exceptions in XPerl

This skill applies to XPerl's structured exception implementation. Do not
apply its APIs or migration requirements to an ordinary Perl checkout.

Use this guidance when changing exception construction, propagation, warning
handling, or converting a core error or warning call site. For catalog entries,
generated macros, and regeneration, also follow
[`xperl-structured-diagnostics`](../xperl-structured-diagnostics/SKILL.md).
For the current implementation status and remaining work, consult
`planning/perl-core-structured-errors.md` in the Perl checkout.

## The basic model

`XPerl::Exception` is the wrapper and accumulator object. It holds an ordered
collection of `XPerl::Diagnostic` objects and the exception-level state needed
to handle or propagate that collection. `XPerl::Diagnostic` represents one
warning or error, including its structured message data and its association
with relevant source locations.
Do not use “exception” and “diagnostic” as interchangeable names.

An exception can contain warnings, errors, or both. Its disposition follows
its diagnostics:

- An exception containing only warning diagnostics is a warning exception.
  Throwing it follows warning handling.
- An exception containing at least one error diagnostic is an error exception.
  Throwing it follows the normal exception and stack-unwind path.

Append diagnostics in encounter order so earlier information is retained.
Use the exception machinery to accumulate warnings as well as errors. This is
the recommended way to collect warnings, including warnings whose delivery is
deferred or combined with other diagnostics. When a non-continuable error
requires an immediate throw, throw the whole accumulated exception, including
diagnostics collected before that error. Do not replace the accumulator with a
new exception containing only the last message.

## Converting a legacy path

When migrating a call site that builds or modifies an error string:

1. Trace how the message is produced, when it is emitted, and whether it is
   deferred or accumulated with other diagnostics.
2. Represent each distinct warning or error as a diagnostic. Put variable
   values in named, typed parameters and keep message structure in the
   diagnostic catalog. Avoid assembling English sentences in C.
3. Append the diagnostic to the active `XPerl::Exception`, creating the
   accumulator when needed. Use this for warnings as well as errors. Preserve
   encounter order and preserve the association between diagnostics and their
   source locations. The representation depends on the diagnostic type and
   scenario: a location may belong to one diagnostic, or a location entry may
   apply to a following group of lightweight diagnostics from the same source
   position. Do not assume either representation universally. Check that
   legacy rendering preserves each diagnostic's location association rather
   than attaching one suffix to the aggregate indiscriminately.
4. Choose the configured warning or error delivery path. Warning delivery
   must retain category enablement and fatalization behavior. Error delivery
   must retain the caller's continuation, parser recovery, or unwind behavior.
5. If the path must defer handling, leave the diagnostics in the accumulator.
   If it must throw now, throw the complete accumulator according to its
   resulting severity.
6. Update related tests, catalog data, generated files, and migration
   documentation. Test aggregation as well as the final rendered message.

Do not turn a warning into an error merely because both use the same wrapper
type. Do not stringify an accumulated exception and later treat that text as
the canonical state. Stringification is a presentation boundary.

Keep source locations in diagnostics distinct from the exception's
propagation context. Current exceptions record origin and rethrow sites,
not full stack traces. A future exception stack would identify where the
exception was thrown or propagated. It does not identify where each error arose inside
compiled source. For example, a failed `require` can have propagation context
up to the `require` call and diagnostic locations in the file being compiled.
Represent both when the scenario needs them, and do not use the exception
stack as a substitute for compilation locations.

When rendering an exception, pass each diagnostic renderer a shared context
containing the exception and the diagnostic's current index. A renderer may
use neighboring diagnostics or shared render state when a message needs
context, such as associating a hint with the preceding diagnostic. Keep that
association in rendering logic rather than merging the diagnostic records.
Standalone diagnostic rendering has no surrounding context, so it must still
produce a complete message and include that diagnostic's own source location.
Exception rendering must walk the live diagnostics array forward and
re-fetch it for each index. Do not autovivify missing entries or assume the
array remains the same size or object while a diagnostic is rendered.

Use a diagnostic's ordered `contents` for subordinate records that it owns.
Keep sibling entries for independent messages that remain chronological.
Containment is allowed by default, while Note diagnostics are leaf-only.
`contents`, `contents_count`, `append`, `contains`, and `has_errors` are shared
`DiagGroup` operations. `contents` returns immediate references, `append`
preserves identity, and `contains`/`has_errors` inspect descendants.
`Diagnostic::derive($contents)` returns a new object of the same class and own
metadata with replacement contents, while leaving the source tree unchanged.
It shallowly preserves references inside the diagnostic metadata. `contains`
includes the receiver and its descendants. `has_errors` includes the
receiver's own fatal severity/error count and nested fatal diagnostics.
`Exception->contents` and `Diagnostic->contents` return their immediate
diagnostic references. Both use the `contents` storage key. Diagnostics
allocate that storage when needed. No `children` or `messages` aliases exist.
Do not flatten containment when traversing or serializing a nested tree.

Some unmigrated producers still use `light` and `context_follows_index` to
refer to a later context diagnostic. Preserve that behavior while working on
those paths, but do not introduce new flat tail links when a context diagnostic
can own the subordinate records. The link remains a live array index and may
be invalidated by hook edits, so any remaining consumer must re-fetch and
validate it after formatting callbacks.
Structured diagnostic, exception, and delivery-group JSON/Dumper records use
version 2 schemas. Each diagnostic record carries its ordered `contents` list;
exception and delivery envelopes list only their immediate roots.

## Migrating string accumulators

Look for `SV *` or character buffers that collect warning text for later
emission, especially code that appends punctuation, clauses, or lists of
values. Replace the text accumulator with an `XPerl::Exception` accumulator.
Append a diagnostic when each warning condition is recognized, then deliver
the accumulated exception at the existing flush point. Preserve the existing
warning category, enablement, fatalization, and reset behavior.

Keep separate warning conditions as separate diagnostics in encounter order.
When one warning describes several values or properties, keep it as one
diagnostic with typed, named parameters. Do not pass a preassembled English
sentence as one text parameter when its semantic parts can be represented
directly. For example, a locale warning can carry locale type, problematic
characters, and codeset state as structured values, while the catalog owns
the sentence and language-specific ordering.

## Compatibility interfaces

The canonical structured state is the `XPerl::Exception`. Compatibility
interfaces such as `$@` may expose a historical user-thrown reference while
the structured exception retains the corresponding diagnostic. Keep that
projection separate from the canonical object. When touching this behavior,
follow the current design and status in the structured errors planning
document. Do not assume planned hooks or APIs exist just because they appear
in design notes.

At a propagation boundary, forward an existing `XPerl::Exception` or
user-thrown reference without stringifying or rewriting it. If context is
needed, append a diagnostic to the same exception and then throw that object.
Convert ordinary scalar user errors to `ERROR_USER_TEXT` where they enter the
structured exception path.

`try`/`catch` accepts one or two lexical variables. In `catch ($value)`, the
variable follows `$@` compatibility behavior. In `catch ($value, $exception)`,
the second variable always receives the canonical `XPerl::Exception`, even
when the first variable is an original reference thrown by user code.

`$SIG{__EXCEPT__}` receives the canonical exception before the legacy warning
or die hooks. Its diagnostic content changes are visible to those hooks and
to rendering. It may promote a warning to an error, but an error's severity
must not be downgraded. Recheck disposition after the hook. A promoted
warning follows the fatal path and is not sent to `__WARN__`. Each warning
sent to `__WARN__` uses its selected rendered value, including source
location in text modes. Reference-valued warnings keep their original reference.
The legacy `__WARN__` and `__DIE__` hooks retain their one-argument
signatures. During either hook, `${^CUR_ERROR_OBJ}` exposes the canonical
exception currently being delivered. A warning raised inside `__DIE__` goes
directly to `__WARN__` without starting a new exception episode. If that
warning hook throws, its exception replaces the active fatal and does not
recursively invoke `__DIE__`.

Hook delivery uses protected internal boundaries. They must not add visible
`caller` frames, change `$^S`, fetch tied `$@`, or discard a hook's explicit
assignment to `$@`. A user eval inside a hook remains an independent boundary.
Test these properties whenever changing hook invocation or capture state.

`__EXCEPT__` runs once before legacy delivery. Legacy replacements do not
re-enter it. A warning from that hook is captured without invoking `__WARN__`.
Its die stops the handler and supplies a replacement for the legacy die stage.
A dying warning hook stops its own handler, then delivery continues through
remaining diagnostics before one final application unwind.
Legacy hooks receive one rendered value per logical group, with original
user-reference identity preserved. A group contains one primary severity and
its hints or context. Independent warnings and errors remain separate groups.
Finish automatic STDERR output for a group before invoking the next group's
hook. Caught errors have no automatic fatal output. Unwind the application
once after delivery finishes. A replacement does not recursively revisit the
same die hook, but later independent error groups can visit it. Pure compile
error batches and their owned context are delivered together.
Nonfinal textual die-hook arguments include a localized unwind-deferred hint.
Explicit `print STDERR` in a hook is immediate and is never intercepted.

The private `_delivery` journal retains original diagnostic groups and links
replacement records for direct core debugging. Public `as_json()` output
omits this internal state. These originals share their diagnostic objects,
so sanitization before delivery also applies to the journal. Do not copy
sensitive values into detached history records. This
journal is development data, not a stable propagation-history API.

## Rendering controls

`${^DIAG_RENDER}` controls exception stringification at render time. Startup
initializes it from `PERL_DIAG_RENDER`, defaulting to `auto:legacy`. Assignments
and `local` affect unscoped caught exceptions as well as newly delivered ones.
A diagnostic captured under the provisional `diagpack` pragma retains its
static engine choice during implicit rendering. An explicit render language
overrides captured choices throughout the tree.
Text modes are `language:legacy` and `language:annotated`. A bare language
selects legacy text: `de` means `de:legacy`, and `auto` means `auto:legacy`.
`auto` chooses the
first nonempty `LC_ALL`, `LC_MESSAGES`, or `LANG` environment setting and uses
its language prefix. Startup can load the selected pack, while later render
operations use registered capabilities only. Requiring a pack registers it
without selecting it; `use XPerl::DiagPack qw(all)` loads installed packs.
Missing translations fall back through registered English to permanent
English. This locale
choice is separate from detecting terminal encoding or respecting IO layers.

The optional third setting component is `JSON` or `Dumper`, such as
`fr:legacy:JSON`. Both produce one physical line per logical message group,
containing `schema`, translated `message`, primary `type`, and `diagnostics`.
Fatalized warnings use `FATAL_ERROR` for the group type and retain a `fatal`
flag in the diagnostic record.
JSON/JSONL and Dumper/DumperL are aliases using English legacy text when given
alone. Every format uses the same immediate group output path through legacy
hooks. Hook rewrites need not preserve serialization validity.

The serializers select defined fields in C without loading modules or dumping
private hashes. Each diagnostic supports `render_as_json()` and
`render_as_dumper()`. Explicit exception `as_json()` remains a whole-object
inspection API. To inspect private contents, use Data::Dumper in `__EXCEPT__`
or inspect `${^CUR_ERROR_OBJ}`. `render($setting)` shares the setting parser.
`render_as_annotated($language)` names the metadata text format, with
`render_as_modern` retained as an alias.

## Review checklist

- Is each warning or error represented as a separate diagnostic?
- Does the exception retain all diagnostics in chronological order?
- Does any non-continuable error throw the accumulated exception?
- Does a warning-only exception remain on the warning path, including its
  category and fatal-warning behavior?
- Are source locations and typed parameters preserved without building the
  final English sentence at the call site?
- Are compatibility projections kept distinct from canonical structured
  state?
- Do two-value catches expose the compatibility value and canonical object
  in the correct arguments?
- Do exception hooks preserve monotonic severity and deliver rendered warning
  text while retaining the canonical aggregate?
- Do tests cover accumulation, disposition, and any legacy behavior changed?
