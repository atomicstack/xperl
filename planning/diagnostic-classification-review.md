# Diagnostic naming and hierarchy review

The current classification was partly inferred from message text and code names.
This review process checks those assignments against producer evidence. It produces
recommendations; it does not edit the catalog, source, translations, or generated
files. There is no apply option.

## Run a small review

Run from the Perl checkout with the environment Perl:

```sh
perl regen/diag.pl --review-diagnostics=Error::Format --max-batches=1
```

This selects the class and its descendants through registered ancestry. The
`XPerl::Diagnostic::` prefix is optional. `all` selects the whole catalog; use a
small class for an initial trial. Batches target 30 diagnostics. Entries sharing
English templates, ignoring parameter-name differences, form connected families
and stay together. Families are ordered by their lowest diagnostic number, and
can exceed the batch target rather than being split. `--max-batches` limits newly
processed batches in this invocation.

The default directory is `diagnostic-review-XPerl-Diagnostic-Error-Format` beneath
the current directory. Choose another location with `--work-dir=DIR`.

```sh
perl regen/diag.pl --review-diagnostics=Error::Format --dry-run
perl regen/diag.pl --review-diagnostics=Error::Format --resume
```

Dry runs save evidence, prompts and schemas without launching Codex. Resume skips
accepted batches and can consume a saved raw response after an interrupted run.
Catalog evidence, source snippets, policy, response schema and batch size must
match the saved snapshot. If they change, use a new directory. `--model=MODEL`
and `--codex=PROGRAM` select the model and Codex executable; otherwise the current
Codex configuration is used.

The command requires Python 3 and the development viewer sources in
`planning/exception-system-guide/`. Those share source collection with the HTML
viewer. Normal regeneration does not load the review driver or invoke Python.
Codex runs with the read-only sandbox, without a persistent session, in the review
artifact directory. Progress and a log path are printed while it works.
Inconsistent responses get up to two correction attempts; every response and
validation error is retained.

## Evidence

Each diagnostic includes its stable number, code, class, severity, kind, flags,
message parameters, selectors, domains, templates, delivery configuration, available
explanations, producer files, inferred enclosing definitions and numbered source
snippets. Shared context contains the class registry, known tag definitions,
catalog identities, MANIFEST file descriptions and subsystem notes.
Shared-template families include summaries of related diagnostics outside the
selected class. Those members are context for possible merge proposals, not extra
entries for the reviewer to change. Shared wording does not establish identical
semantics; producer contracts, parameters, selectors and delivery must agree too.

Previous classification judgments are labeled as previous reviews. They are not
authoritative. File names and inferred function names are evidence, not proof;
short source snippets may not establish the complete producer contract.

The scanner inventories references recognized by the catalog tooling. Indirect
selection and out-of-tree producers may have no recognized reference. An empty
reference list is not proof that a diagnostic is unused.

## Review policy

Review the hierarchy before assigning individual items. Existing branches may be
retained, split or replaced in the proposal. Each reviewed branch needs a concrete
definition, inclusion rule and exclusion rule. Preserve useful existing branches
such as `Strict::Vars`; avoid empty abstractions and a class for every code.

Use consistent names for the same concepts. Code names describe a subject and
failure condition in `UPPER_SNAKE_CASE`. Preferred regex vocabulary is `Regexp`
(matching Perl's `REGEXP` reference type) and `CharClass`, with `REGEXP_CC_` and
`REGEXP_ECC_` prefixes for character-class and extended-character-class codes.
An extended subgroup can use `Regexp::CharClass::Extended`. These conventions are
review proposals, not applied renames. Do not rename warning category identifiers.

Distinguish Perl report formats from printf formats and diagnostic templates.
Distinguish dispatch/on shapes from regular expressions. Internal failures use
`Error::Internal` subject branches. Panic and render status remain separate flags.
Warning class names do not alter warning category enablement or fatalization.

Recommendations must preserve diagnostic numbers and message wording. Uncertain
cases, merges and splits are questions for follow-up, with current fields retained.
Every recommendation must provide producer evidence and a rationale. New tags must
have definitions; new classes must declare parents and membership boundaries.

## Outputs

- `catalog-evidence.json` and `source-evidence.json`: review inputs.
- `snapshot.json`: input fingerprint and batch size.
- `batch-NNNN.input.json`, `.prompt`, `.schema.json`: submitted packet and contract.
- `batch-NNNN.log`, `.response.json`: Codex events and raw JSON response.
- `batch-NNNN.recommendations.json`: semantically validated response.
- `recommendations.json`: collected accepted batches for this scope.

The collected file records selected and reviewed counts and whether the review is
complete. A dry run does not claim to have reviewed any entries.

Each response contains a hierarchy assessment, existing-class reviews, proposed
new classes and tags, per-diagnostic recommendations, and follow-up questions.
Diagnostic decisions are `keep`, `change`, `investigate`, `split` or `merge`.
Codex supplies a review status and proposed fields. The script derives keep/change
and a field-by-field change list; tag ordering alone does not count as a change.

The driver rejects missing or repeated identities, conflicting code names, unknown
classes or tags, and proposed ancestry cycles. Validation checks structure and
consistency; it cannot establish that a semantic judgment is correct. Inspect the
recommendations and their evidence before deciding what to implement.

## Next stage

Cross-batch reconciliation, proposal display in the tree viewer,
approval tracking and mechanical application are future work. Separate batches
can propose incompatible branches or names; they are not a globally reconciled
migration plan yet.

## File and function reference

[Producer overview](diagnostic-source-context.txt) lists file → function/macro →
diagnostic codes and reference line numbers. The corresponding
[JSON index](diagnostic-source-context.json) records definition spans, source
hashes, MANIFEST descriptions and review status. It inventories catalog references,
not every function or a complete call graph. A reference can be a producer,
forwarder, framework check, or test fixture.

Rebuild the development reference explicitly:

```sh
python3 -B planning/exception-system-guide/source_reference.py
```

[Focused notes](diagnostic-source-notes.json) are maintained separately from the
generated inventory. The first notes cover file orientation for `pp_ctl.c`,
`pp_sys.c`, `sv.c` and `regcomp.c`, plus six functions relevant to report formats,
printf conversions and character-class parsing. Their status is a focused source
review, not an exhaustive audit of all paths in those files or functions.
Unannotated definitions are explicitly unreviewed. Changed source hashes mark
notes stale; regeneration never silently renews the original review claim.

The review driver includes matching file and function notes once per batch, with
local freshness checks. It does not submit the full index or its hashes. English
wording is included with language names and the full selector/parameter metadata;
non-English template bodies remain in the local evidence snapshot. A proposed
merge still needs translation compatibility review before implementation.

Existing tags must be reassessed individually. In particular, repeated execution
or failure to make progress is not itself recursion. The Format review showed why
an existing `condition:recursion_no_progress` tag must not be accepted solely
because it is already in the catalog.
