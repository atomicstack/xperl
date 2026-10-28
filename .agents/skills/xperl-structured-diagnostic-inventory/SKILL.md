---
name: xperl-structured-diagnostic-inventory
description: Find and group unmanaged XPerl diagnostics for migration to its generated catalog.
---

# Finding and grouping unconverted diagnostics

This skill applies to XPerl's structured exception implementation. Do not
apply its APIs or migration requirements to an ordinary Perl checkout.

When classifying a candidate as a warning or error, preserve the structured
exception model in
[`xperl-structured-exceptions`](../xperl-structured-exceptions/SKILL.md):
diagnostics accumulate in order, warning-only exceptions use warning
handling, and an exception containing an error uses error handling.

Keep producer migration and exception transport as separate audits. This
inventory finds unmanaged emitters and message construction that should move
to the diagnostic catalog. The exception audit traces which accumulator owns
each diagnostic, when a batch is flushed, and what `$@`, `${^ERROR_OBJ}`, and
the hooks expose. A migrated producer can still mishandle the active
accumulator or compatibility value, so completing one audit does not complete
the other.

Use this workflow to identify legacy error and warning call sites and group
them into migration batches. Run every command from the Perl core checkout.

## Find unmanaged call sites

Start with the generated framework checks:

```sh
git grep -n -E 'PERL_DIAG_LEGACY_|PERL_DIAG_DYNAMIC_YYERROR|\b(Perl_croak(_nocontext)?|croak|warn|DIE|yyerror)(_pv|_pvn)?\s*\(' -- '*.c' '*.h' '*.y'
```

Exclude generated headers when inspecting source migration progress. The
compatibility APIs in `embed.h`, parser entry points required by Bison, and
generated macro bodies are API boundaries; ordinary source call sites are
migration candidates.

Check lowercase `die`, SV delivery, and `fatal_warner` as distinct APIs.
Converting uppercase `DIE` does not prove their callers are covered. The
inventory includes these spellings. Use `--lowercase-die` to convert fixed
lowercase calls; their `DIE_NOCONTEXT` macros retain context lookup and the
original call expression. SV aliases retain the opaque value and its delivery
API. A fatal warning can reuse a warning message through a `FATAL_WARNER`
alias without changing fatalization.

The API-list audit also includes `croak_caller` and `noperl_die`:

```sh
perl Porting/diag_bulk_formatted.pl --special-emitters
perl Porting/diag_bulk_formatted.pl --special-emitters --apply
```

Retain caller-COP selection through `CROAK_CALLER`. Keep startup/ABI
failures on `NOPERL_DIE`; these cannot require initialized Perl structures.
Fold literal message fragments supplied as arguments into a complete catalog
message when every use has the same fixed text.

For one source file, use a focused check:

```sh
git grep -n -i 'PERL_DIAG_DYNAMIC_YYERROR\|PERL_DIAG_YYERROR_TEXT' -- toke.c
```

The file is ready for the next phase only when its old dynamic adapter uses
are gone and any remaining text adapters are understood.

## Produce an inventory

Use the repository inventory script rather than scanning by eye:

```sh
perl Porting/diag_inventory.pl > ../tmp/diag-inventory.txt
```

The report groups call sites by emitter and extracted format text. Count the
remaining work by emitter:

```sh
perl Porting/diag_inventory.pl |
  awk -F '\t' 'NR > 1 { count[$1] += $2 } END { for (kind in count) print kind, count[kind] }'
```

The inventory includes direct `Perl_croak` and `Perl_croak_nocontext` calls.
Function declarations, emitter implementations, and the public croak macro
are identified API boundaries.  Other macro bodies are producers.
For a direct-call batch, use report mode before applying changes:

```sh
perl Porting/diag_bulk_formatted.pl --prefixed-croak
perl Porting/diag_bulk_formatted.pl --prefixed-croak --apply
```

Preserve interpreter delivery.  `Perl_croak(aTHX_ ...)` uses
`CROAK_CONTEXT`; `Perl_croak_nocontext(...)` uses `CROAK_NOCONTEXT`.
An explicit interpreter value is a typed `emit.args` parameter. Reuse an
existing definition through a delivery alias when its message schema matches.

For DIE calls, the `--die` mode removes the `aTHX_` delivery prefix and
resolves `PL_*` format constants from their `INIT(...)` declarations in
`perl.h`.  These are fixed formats, not dynamic messages:

```sh
perl Porting/diag_bulk_formatted.pl --die
perl Porting/diag_bulk_formatted.pl --die --apply
```

Inspect the source locations for each group before editing. The same format
text can have different argument types or different delivery APIs, so the
format string alone does not prove that two call sites can share a macro.

For categorized warnings, use the `--warnings` mode. It resolves fixed
formats and retains `warner`, `ck_warner`, or `ck_warner_d` delivery:

```sh
perl Porting/diag_bulk_formatted.pl --warnings
perl Porting/diag_bulk_formatted.pl --warnings --apply
```

The inventory groups warnings by category as well as message and emitter.
Static categories belong in `emit.warning_categories`. A runtime packed
category is one unsigned delivery argument in `emit.args`.

Audit direct prefixed warning APIs after converting the legacy adapters:

```sh
perl Porting/diag_bulk_formatted.pl --prefixed-warnings
perl Porting/diag_bulk_formatted.pl --prefixed-warnings --apply
```

The inventory includes these calls and excludes their definitions, prototypes,
and generated public forwarding macros. Other macro bodies are producers.
`WARN_CONTEXT` and categorized `*_CONTEXT` emitters retain explicit `aTHX_`;
`WARN_NOCONTEXT` retains delivery without an interpreter argument.

For regex warning helpers, use `--regex-warnings` on their source callers:

```sh
perl Porting/diag_bulk_formatted.pl --regex-warnings regcomp.c regcomp_study.c
perl Porting/diag_bulk_formatted.pl --regex-warnings --apply regcomp.c regcomp_study.c
```

This mode preserves category, location reporting, suppression, and
experimental once flags. Returned helper text is an explicit message
argument. Known shared formats such as `PL_extended_cp_format` resolve to
identified messages. Remove unused helper definitions only after auditing
their callers throughout the checkout.

## Classify each group

Put each call site into one of these migration groups:

1. **Fixed literal**: a quoted message with no substitutions. Convert in bulk
   with `Porting/diag_bulk_formatted.pl`, then review for an existing matching definition.
2. **Fixed format with simple arguments**: a literal format plus stable C
   arguments. Add one config entry with typed `message.args` and generate a symbolic
   macro.
3. **Format with delivery arguments**: a format plus API metadata such as
   `yyerror_pv` encoding flags. Put substitutions in `message.args` and
   metadata in `emit.args`.
4. **Equivalent existing message**: reuse the existing diagnostic ID and
   generated macro. Do not add a second entry for a message already present.
5. **Preformatted or propagated text**: the message comes from a helper, an
   SV, or another eval layer. Use a named text adapter temporarily and record
   why the text cannot be reconstructed from typed arguments.
6. **Context-sensitive or variadic call**: calls whose arguments change the
   format or control flow. Leave these until the fixed and simple format
   groups are complete.

## Normalize before grouping

When comparing messages, normalize only for analysis. Preserve the original
format in the configuration entry. Treat these as significant:

- `%s` versus `SVf` and `SVf_UTF8`
- precision and length modifiers such as `%.*s`
- argument order
- `yyerror`, `yyerror_pv`, and `yyerror_pvn`
- warning versus fatal emitters
- compile-time versus runtime exception kinds

Search the configuration and generated header before adding a file:

```sh
rg -n '"templates"|PERL_DIAG_' diag_conf.pl perldiag.h
```

For a duplicate check, load the Perl data structure and report templates with
more than one ID:

```sh
perl -e '
  use charnames ":full";
  our ($CONF, $META);
  require "./regen/diag_lib.pm";
  do "./diag_conf.pl" or die $@ || $!;
  my %templates;
  for my $diag (@{Diag::Migration::diagnostics($CONF)}) {
    next if $diag->{dynamic};
    for my $case (@{Diag::Migration::template_cases($diag, "en")}) {
      $templates{$case->{template}}{$diag->{code}} = 1;
    }
  }
  for my $template (sort keys %templates) {
    my @codes = sort keys %{$templates{$template}};
    print join(" | ", @codes), "\n" if @codes > 1;
  }
'
```

Review every duplicate. Reuse the existing ID when the diagnostic is
semantically the same.

## Choose a batch strategy

Prefer batches with one clear transformation: fixed literals, one parser
family with the same `yyerror_pv` shape, one source file, or one existing
message reused at several call sites.

Use a Perl regeneration or bulk-modification script for repetitive edits. The
script should read `diag_conf.pl`, allocate IDs, update the consolidated
catalog, rewrite only matching call sites, and report the files changed.
The temporary `diag_conf/` entry files have been merged. The formatted bulk
updater supports the consolidated layout. Its default mode reports candidates;
`--apply` writes the catalog only if a definition or delivery alias changes.
Run `perl regen/diag.pl` after applying a batch. It normalizes the catalog
and preserves the schema POD at its top. Fixed messages use
`message.templates.en` with named placeholders and formatters in
`message.args`.
Definitions live under `diagnostics->{severity}{kind}{code}` with long
severity names. The leaf identity fields must agree with the hierarchy keys.
Do not use a broad replacement when identical wording has different argument
signatures.

After each batch:

```sh
perl regen/diag.pl
make manisort
git diff --check
```

Then rerun the focused inventory and relevant build or test. Commit each
reviewable batch separately.

## Regex diagnostics

The former `vFAIL*` regex wrappers have been removed. For future regex
diagnostic audits, search `reg*.c` and `reg*.h`, then run
`perl Porting/diag_inventory.pl` to find calls that bypass the catalog.

## Completion checks

A source file is complete for a migration phase when no unmanaged legacy
emitter remains in ordinary source, no dynamic adapter remains where a typed
generated macro can represent the message, remaining text adapters are
documented as genuine propagation boundaries, duplicate checks show no new
copies of existing diagnostics, and generated files and focused tests pass.
