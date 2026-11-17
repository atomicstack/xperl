# XPerl exceptions and diagnostics: remaining work

The implemented interfaces are documented in [perlexcept](../pod/perlexcept.pod)
and [perlexcephack](../pod/perlexcephack.pod). This file records unresolved
work, not a history of completed migrations or validation runs.

Use [X modules as consumers](exception-module-dogfooding.md) to explore a
reusable module layer for defining diagnostics, constructing exceptions and
adding context. Those notes are proposals, not an extension API contract.

## Classification and numbering

Review names and class boundaries against producer contracts using the
[classification review workflow](diagnostic-classification-review.md).
Cross-batch reconciliation, proposal display, approval tracking and mechanical
application need separate work before independent recommendations can become
a coherent migration.

Renumbering diagnostics into populated class blocks of 100 is a proposal.
Choose the starting range, handling of retired identifiers and treatment of
numeric literals before changing any numbers. Existing numbers stay stable
until that decision is made.

Review subordinate hints and context diagnostics whose severity or warning
categories still describe an independent warning. Trace their producers and
containers before changing classification. The parent should control warning
enablement and fatalization when the child only supplies an explanation.
Keep diagnostic numbers stable and test containment, standalone inspection,
and legacy rendering when moving these records into the Note hierarchy.

## Translation maintenance

Imported packs need native linguistic review, including complete phrases,
agreement and technical vocabulary. Machine-generated drafts and successful
structural checks do not establish linguistic quality. Audit provenance and
source freshness when revisiting translations. Review Arabic and Persian
mixed-direction display in terminals and HTML independently of canonical
Unicode storage.

Use the existing audit, repair and review commands rather than retaining
one-off pilot scripts. Additional languages and their open script choices
are in the [language queue](diagnostic-language-queue.md).

## Public object and mutation contracts

Read-only traversal and code/parameter predicates are available through
`XPerl::DiagGroup`. They visit shared diagnostics once without changing the
graph. The next graph-query task is a predicate-driven `subgroup`/`split`
interface. It needs an explicit policy for a selected item beneath an
unmatched Error ancestor and for how shared subtrees appear in each result.
Applications can already intercept and edit objects through the hooks.
Shared aliases and earlier output prevent any promise of secure erasure.

Before stabilizing additional mutation APIs, specify their count and state
invariants. `error_count` records producer/parser accounting, not a live
recursive count; there is no `warning_count`. `thrown` has a narrow explicit
throw meaning. `origin` is not filled automatically. Keep these distinctions
consistent with supported edits and delivery's required unwind behavior.

Removal of legacy light/context-tail readers and obsolete hint/fatality
metadata is a separate migration. Preserve existing compatibility behavior
until actual producers and consumers have moved.

## Stack capture and deferred compatibility work

First delivery captures portable Perl frames through the innermost eval or
try boundary. `stack_trace` returns detached records containing function,
file, line, and anonymous argument descriptions. Arguments retain only cached
type labels, reference classes and addresses, and a `/MG` marker for magic.
Capture neither fetches magic nor invokes overload or retains arguments.
Shifted-out argument slots are omitted; tied argument arrays remain opaque.
Require frames remain visible as capture continues toward the application's
eval or try. Internal diagnostic-hook evals terminate capture without
appearing in the records; debugger wrappers and regex reentry duplicates are
omitted.

Rethrows preserve the snapshot. `extend_stack` explicitly appends a segment
from the handler's current location to its enclosing boundary. This is not a
chronological THROW/CATCH history, and it does not deduplicate repeated
explicit extensions. Diagnostic source locations and reserved origin
metadata remain separate from stack frames. Whole-exception JSON includes
the stack; legacy text and per-group delivery envelopes retain their shapes.

Inventory existing C/XS text interfaces before replacing their adapters.
Assess source compatibility, ABI and ownership per interface. New-API
backports and PPPort support are separate decisions.

Preserve both charname resolution paths: tokenizer lookup freezes successful
escapes; runtime pattern strings can require regex-engine lookup with their
own context. Fix demonstrated context loss without changing successful
lookup freezing or caching. Failure locations may need pattern-relative
line/column alongside byte offset and caller source location.

Review the provisional `diagpack` pragma name, parameter API names and the
usefulness of exposed `type` metadata before treating them as stable.

## Validation coverage

Repeat current-tip checks on available native 32-bit, EBCDIC, Windows,
OS/2, VMS and Amiga configurations. Repeat language-pack and delivery checks
with debugging, threads and sanitizers. Earlier checks establish only the
source state and build configurations actually exercised; the optimized,
non-threaded squash validation does not establish these other configurations.
