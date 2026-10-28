---
name: xperl-diagnostic-classification
description: Review XPerl diagnostic code names, classes and tags against producer contracts, including related diagnostics and cross-batch consistency.
---

# Classifying XPerl diagnostics

Use this skill for semantic classification of existing catalog diagnostics. For
producer migration and generation mechanics, use `xperl-structured-diagnostics`.
Classification review does not authorize renames, reclassification or regeneration
of catalog output. Save recommendations until the user authorizes application.

## Establish the failed contract

Start with the stable diagnostic number. Current codes, classes and tags are
provisional judgments, not evidence that their own classification is correct.

Use the catalog parameters, selectors, English templates and available diagnostic
documentation to locate the condition. Find all source references through the
review tool or source index. Distinguish actual producers from forwarding code,
framework checks and extension fixtures. For each producer, establish:

- The enclosing function and subsystem.
- The exact predicate that emits the diagnostic.
- The meaning and origin of the tested values and constants.
- The operation or syntax form required to reach that predicate.
- Whether other producers impose different contracts.

Expand beyond a short snippet when it does not establish these facts. An inferred
function name, MANIFEST description or previous classification cannot replace that
inspection. Focused file/function notes are references; check their freshness and
scope. Missing evidence calls for investigation, not a confident guess.

Write one plain sentence describing the violated contract before choosing names.
Separate producer facts, interpretation and recommendation.

## Check that the evidence adds up

Follow this consistency chain:

```text
file/subsystem → function and callers → operation and failed predicate
    → parameters, selectors and templates → proposed class, code and tags
```

Each link should support the same account of the failure. Treat disagreements as
investigation targets: a shared file may contain unrelated features, a helper may
serve multiple operations, or a template may conceal the distinction. The class
names an operation family, not necessarily a single Perl keyword: an opening-IO
family may cover open, sysopen and internal APIs where their contracts fit.

Then review the whole proposed group. State its common contract, check every
member, search neighboring groups for missing members, and separate outliers.
Test inclusion and exclusion rules against concrete producers. A matching word
or code prefix does not establish membership. Shared templates suggest related
cases to inspect, not a preapproved grouping or merge.

Keep grouping confidence separate from confidence in individual assignments.
Several convincing entries do not establish that the whole group is coherent.

## Choose a useful class boundary

Ask what family a caller could reasonably match through `isa`, then compare the
proposed boundary with neighboring classes. Define what belongs and what does not.
Do not preserve a branch solely because it already exists, or make one class per
code to avoid choosing boundaries. Prefer coherent populated subject groups.

Distinguish parameter-declaration grammar, callable signature binding, incompatible
types, invalid operation-specific values, operating-system failures, and internal
invariants. The word "argument" and a count comparison do not establish a generic
argument or arity class. A mode-specific open restriction, for example, belongs
with opening IO handles rather than arbitrary callable signature binding.

Use warning-category vocabulary where it helps, without changing warning policy.
Python's TypeError/ValueError distinction can expose a bad grouping; its class
names are comparisons, not a mandatory mapping. An error in an IO operation is
not automatically an operating-system failure. Internal/panic failures use the
separate Error::Internal subject branches. Panic and render status remain flags.

Keep useful established distinctions such as Strict::Vars. New grouping proposals
must explain their membership and relation to existing branches. Do not force
producers with different meanings into a class simply to retain current names.

## Settle grouping before renaming

Validate the grouping first, settle its class name second, and rename codes last.
Until the group is well supported, retain existing identifiers and store proposed
names separately. Do not manufacture consistent prefixes to make an uncertain
group appear settled. A batch recommendation alone is not approval to rename.

Once grouping is settled, use its full semantic prefix in proposed code names:

```text
Error::IO::InplaceEdit → ERROR_IO_INPLACE_EDIT_<FAILURE>
```

Express the failure after the prefix. CANNOT_RENAME_SKIPPING became
ERROR_IO_INPLACE_EDIT_CANNOT_CREATE_BACKUP after review established that rename
and link paths both preserve the original under its backup name.
"Skipping" describes the consequence, which can remain in the message or data.
Retain a consequence in the code only when it distinguishes the diagnostic's
actual contract. Preserve stable diagnostic numbers through all naming changes.

## Review names and tags together

Use consistent subject and condition vocabulary across related codes. Prefer
`Regexp`/`REGEXP_` and `CharClass`. Use full semantic prefixes after grouping is
settled; the earlier CC/ECC shorthand proposals do not establish an exception.
Other abbreviation conventions remain review decisions: identify inconsistencies rather than silently
accepting mixed ARG/ARGS/ARGUMENT forms. A name must express the actual condition,
not merely restate a broad English message or internal variable name.

Reassess every existing tag against producer evidence. Return the complete
replacement set, removing inaccurate tags. Repetition is not necessarily
recursion; an absent format definition is not an uninitialized scalar; a count
check can validate an operation's mode rather than its callable signature.
Reuse accurate known tags. Define and justify genuinely useful new ones.

Group shared templates for review, but compare parameters, selectors, producer
contracts and delivery before recommending a merge. Different wording can also
hide duplicate errors. Do not merge identities merely because the templates match.

## Use the review artifacts

From the Perl checkout, use the environment Perl:

```sh
perl regen/diag.pl --review-diagnostics=Error::Call::Binding --dry-run
perl regen/diag.pl --review-diagnostics=Error::Call::Binding --resume
```

`planning/diagnostic-classification-review.md` describes options and JSON outputs.
`planning/diagnostic-source-context.txt` gives file → function → code relationships;
its JSON counterpart contains spans and hashes. Focused descriptions live in
`planning/diagnostic-source-notes.json`. Relevant context is selected per batch;
do not submit the complete source index for every review.

The model recommends code, class and tags. The script derives keep/change and
field differences, comparing tags as sets. Diagnostic numbers stay fixed. New
classes/tags, merges, splits and unresolved producer questions remain proposals.

Reconcile batches before applying a family-wide migration. Check terminology,
class inclusion/exclusion rules, tag meanings, neighboring classes and merge
candidates across all results. Structural JSON validation does not establish
semantic correctness. High confidence requires evidence for every producer, not
agreement with an existing label.

For a worked case, read [the input-open example](references/input-open.md).
