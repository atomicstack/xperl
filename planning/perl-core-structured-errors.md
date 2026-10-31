# XPerl exceptions and diagnostics: remaining work

The implemented interfaces are documented in [perlexcept](../pod/perlexcept.pod)
and [perlexcephack](../pod/perlexcephack.pod). This file records unresolved
work, not a history of completed migrations or validation runs.

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

Subgroup/split filtering is deferred until there is a safe policy for a
selected item beneath an unmatched Error ancestor. Traversal conveniences,
sharing and redaction semantics need an explicit design before adding APIs.
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

## Deferred capture and compatibility work

Automatic stack capture and chronological propagation history are deferred.
Capture portable Perl-level frame data at the first throw, rather than live
stack pointers or a platform-specific native backtrace. Preserve that original
snapshot across rethrows and record propagation sites separately. Diagnostic
source locations remain independent of both. Define which internal frames to
omit and how eval, require, generators, and thread boundaries appear before
implementing capture.
Argument inclusion remains unresolved. Applications can enrich objects in
`__EXCEPT__` or collect caller information at reporting sites. Current
objects do not provide an automatic full stack or THROW/CATCH history.

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
