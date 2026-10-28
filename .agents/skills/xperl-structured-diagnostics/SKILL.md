---
name: xperl-structured-diagnostics
description: Convert XPerl diagnostics to typed catalog entries and generated symbolic macros.
---

# Structured diagnostic migration

This skill applies to XPerl's structured exception implementation. Do not
apply its APIs or migration requirements to an ordinary Perl checkout.

For the exception container and warning/error disposition model, also follow
[`xperl-structured-exceptions`](../xperl-structured-exceptions/SKILL.md).

Use this workflow when converting a Perl core diagnostic from a legacy
`croak`, `warn`, `DIE`, or parser `yyerror` call into the generated diagnostic
framework.

## Scope

Work only in the Perl core checkout. The source of truth for migrated
diagnostics and documentation is the consolidated `diag_conf.pl`. The
generated interface is `perldiag.h`; do not edit it by hand.

Before adding an entry, search the existing configuration and generated header
for the message text and its meaning. Reuse an existing diagnostic ID when the
message is the same. Do not create duplicate entries merely because the call
site is in a different subsystem.

For a renderer-owned summary or context wrapper, use `emit.api => 'RENDER'`.
It generates `PERL_FORMAT_<CODE>(language, values)` and shares the ordinary
catalog validation, selectors, translations, and English fallback. It does
not create or deliver a diagnostic. Pass an AV containing all retained values
in `message.args` declaration order, including selector-only sources. Preserve
native enum IDs and unsigned counts as integers. Each language selects its
displayed parameters from this fixed source list. Keep the original diagnostic
records when formatting a group.

## Add or reuse the definition

Add a leaf hash under `diagnostics->{severity}{kind}{code}` in `diag_conf.pl`.
Use the long severity names. The hierarchy keys must match the leaf's
`severity`, `kind`, and `code`. Regeneration rejects mismatches:

```perl
diagnostics => {
    FATAL_ERROR => {
        CORE_COMPILE => {
            TOO_MANY_ARGUMENTS => {
                number => 1405, severity => 'FATAL_ERROR', kind => 'CORE_COMPILE',
                code => 'TOO_MANY_ARGUMENTS',
                message => {
                    templates => { en => 'Too many arguments for %{name}' },
                    args => [
                        { name => 'name', type => 'text', format_str => 's' },
                    ],
                },
                emit => {
                    api => 'YYERROR_PV',
                    args => [ { name => 'flags', type => 'uv' } ],
                    parser_action => 'collect',
                },
            },
        },
    },
},
```

`message.args` defines named diagnostic arguments. An argument can be built
from one or more macro inputs and can serve as a selector, a template value,
or both. All semantic arguments remain in the stored parameter list in
declaration order, including selector-only arguments. Templates display only
the parameters they reference. `emit.args` describes extra inputs required by
the delivery API, such as the SV encoding flags passed to `yyerror_pv`. Use no `emit.args` when plain
`yyerror` is sufficient.

Every parser delivery declares `emit.parser_action`. Use `collect` for ordinary
accumulation, `recover` for a grammar action that invokes `YYERROR`, and
`abort` for a report followed by `yyquit()`. Collection can still abort at
the ten-error limit. `YYERROR` enters grammar recovery and may resume
parsing; `yyquit()` stops compilation. The generator includes the selected
control step in the diagnostic macro. When one message needs different
actions, use action-specific variants with empty `values` and distinct
codes. Use `caller` only for an opaque text adapter whose nullable input
controls whether it reports or aborts. Bare `yyquit()` calls that react to
prior errors or lexer state remain separate control operations.

Use the existing numeric sequence for new entries. Keep the ID stable after it
has been used by generated code.

The symbolic field is `code`, and the numeric field is `number`. `message`
contains `templates`, typed `args`, and ordered `selectors`. `emit.args`
describes delivery inputs. Each object in `emit.aliases` declares another
delivery API and may override its macro name. The explicit field order begins
with `number`, `severity`, `kind`, `code`, `macro`, `message`, and
`counts_as_error`. `macro` is the generated
macro name. Regeneration fills the default when it is omitted and preserves
an explicit name. Names must be unique, including aliases and format macros.
Delivery details are grouped under `emit`.
The schema POD at the top of `diag_conf.pl` documents the fields and grammar.

Pass semantic values to diagnostic macros, not English grammar fragments such
as `"an ARRAY"` or `"a SCALAR"`. When a value selects the wording or grammar,
declare it as a selector. Each language chooses its own cases and wildcard
fallbacks; a missing translated case may fall back to English. Displayed
parameters are the union of named placeholders across languages and cases.
Reserve ordinary message parameters for
runtime data that belongs in the rendered message.

For named formats, use `%{name}` placeholders and put the formatter on the
corresponding argument.  A compound formatter declares ordered `inputs`:

```perl
message => {
  templates => { en => 'Unknown mode %{mode}' },
  args => [ {
    name => 'mode', type => 'text', format_str => '.*s',
    inputs => [
        { name => 'length', type => 'iv' },
        { name => 'text', type => 'text' },
    ],
  } ],
},
```

When several macro inputs together form one semantic message parameter, use
`pass => 'sv_setpvf'` with a complete format string in `format_str`. The
generator formats the inputs into the structured parameter's value SV.
It does not build a separate template-argument AV during capture. Use
`sv_catpvf` when the generated code should append formatted text. An optional `utf8_input` names an
integer input whose true value marks the composed string as UTF-8. Keep the
structured parameter named for its meaning, such as `var_name`, rather than
exposing implementation pieces such as `sigil` and `name` separately.

Keep delivery parameters in `emit.args`. `CROAK_CONTEXT` preserves
`Perl_croak(aTHX_ ...)`, or accepts one explicit interpreter parameter there.
Use `aTHX_` only as the leading context argument to a context-taking function.
Bare `aTHX` expands away in non-multiplicity builds, so ordinary diagnostic
parameters must not depend on it. A multiplicity-only panic diagnostic may
report the current interpreter address as thread identity; use a clearly
named field and ensure every expansion site is multiplicity-only.
`CROAK_NOCONTEXT` preserves `Perl_croak_nocontext(...)`. Delivery aliases
can share one message definition without changing the emitter's context.
Use fixed macro parameters rather than `__VA_ARGS__`.

Preserve `DIE` delivery when reusing a croak diagnostic. A DIE alias must
emit the configured DIE delivery call and retain its unwind behavior. The
generated helper is non-returning because the diagnostic always throws. For formats
such as `PL_no_sock_func`, extract the initializer from `perl.h` and reuse
the resolved message schema.  Do not classify these constants as runtime
format strings.

Decode C escapes once when extracting literals.  Physical backslash-newline
continuations contribute no characters.  Store actual newlines and quotes
in the Perl value, then let the generator quote them for C.

For categorized warnings, use `WARNER`, `CK_WARNER`, or `CK_WARNER_D` to
preserve the original API's enablement and fatalization rules. Store static
category names in `emit.warning_categories => ['WARN_UTF8']`; the generator
validates them against `warnings.h` and emits `packWARN`, `packWARN2`, etc.
A runtime packed category uses one `emit.args` entry with type `uv`. Share
the same warning message through a delivery alias only when its categories
and argument schema match.

For the conditional `pTHX__FORMAT`/`pTHX__VALUE` pair, use
`emit.interpreter_suffix => 1`. The generator emits both together, including in
zero-argument messages. The bulk parser recognizes the pair. Do not turn
the optional interpreter value into an unconditional message argument.

When a producer selects between known formats, split it into calls to
separate diagnostic symbols. Shared render-only uses can reference a
generated `emit.format_macro` from the same entry. Trace truly composed messages
before choosing an adapter. The queued locale format has an explicit,
fixed-argument compatibility entry preserving its dummy-zero printf call.

Regex warnings set `emit.regex_location => 1` and have one pointer delivery
parameter with `role => 'regex_location'`. The generator owns the
`REPORT_LOCATION` suffix, its values, and the `WARN_HELPER_` call. Set
`emit.warn_once` to the experimental category symbol to retain its compiler-state
flag. These fields distinguish reuse signatures from ordinary warnings.

Check `handy.h` before adding a C helper. It contains shared macros such as
`ASSERT_IS_LITERAL` and `STR_WITH_LEN`, and documents their contracts.

The internal literal-only deprecation interfaces use `literal_fragment` on
text parameters and an explicit compatibility description. The generator
concatenates these C string literal parameters into the printf format and
wraps the complete format in `ASSERT_IS_LITERAL` from `handy.h`. Do not wrap
individual fragments in parentheses before concatenating them. Preserve this
restriction when retaining those interfaces; ordinary diagnostic arguments
must use typed formatters.

## Integer plural rules

Use the shared cardinal or ordinal rule helper rather than choosing English
`one`/`many` categories in producer code. `diag_conf.pl` owns a shared
`plural_rules` registry of C expressions. Each language under `languages`
selects its `cardinal` and `ordinal` rule by name. Regeneration validates
references, rule kinds, and categories, then emits shared rule macros,
per-language aliases and dispatch macros within each generated catalog.
Only permanent English is compiled through `perldiag_data.inc`; the other
catalogs belong to their `XPerl::DiagPack::XX` XS modules.
Fixed C API bodies remain in `pp_ctl.c`, registered in `embed.fnc`.
Both C helpers take a language and a `UV n` and return a category string.
The experimental builtins
`cardinal_plural_form($language, $n)` and
`ordinal_plural_form($language, $n)` expose them. These queries use all the
retained CLDR 49 integer rules, generated by `regen/diag_plural.pm` through
`regen/diag.pl` into `perldiag_plural.inc`. They are available in miniperl
without diagnostic packs and ignore registered engine replacements. They
accept language tags and code-based POSIX locales, including regional plural
overrides. Known languages without an explicit ordinal rule use `other`.
Unknown languages return NULL from C and undef from the builtins. No
fractional counts are supported. Diagnostic rendering continues to use its
selected engine's own plural callbacks and configured rules.

These functions only calculate categories. Selector matching also supports
exact-number cases, wildcard cases, and language fallback. Exact-number config
keys are bare numeric strings such as `"0"` and `"21"`, without `=`. Keep
`other` distinct from `*`. Each language can define its own selector cases.
Producer code should pass generated domain-local integer constants for known
values. Convert dynamic strings at an explicit boundary, and use the shared
value-to-name helper when a selector value is displayed in a parameter.

## Generated diagnostic namespace

Regeneration owns the diagnostic interface names. Use `perl_` for generated
types, data, and enum members, `Perl_` for functions, and `PERL_` for macros,
including guards. Do not add compatibility aliases with the former
`DIAG_*`, `DIAG_TMPL_*`, or `S_diag_*` names. When registering a new
`embed.fnc` function for this feature, use the `o` flag to suppress the
generated short alias and call it by its `Perl_` name with explicit `aTHX_`
where required. Do not change inherited embedvar naming conventions.

## Convert the call site

Replace the legacy or dynamic call with the generated symbolic macro. The call
site should contain only the diagnostic arguments and any delivery parameters:

```c
PERL_ADD_COMPILE_ERR_TOO_MANY_ARGUMENTS(name, flags);
```

The generated macro owns `form(...)`, the format string, and the call to
`yyerror_pv(...)`. Do not leave `form("...", ...)` or a copied message string
at the call site. Documentation data lives in the same catalog under
`documentation`. Preserve its verbatim headings, shared explanations,
introduction, trailer and order. `regen/diag.pl` generates `perldiag.pod`
without reading that output. Do not edit the generated POD directly.

For a fixed message, use a zero-argument generated macro. For a preformatted
message that cannot be reconstructed from typed arguments, reuse the
catalog's identified propagation boundary:

```c
PERL_ADD_COMPILE_ERR_PROPAGATED_TEXT_PV(message, flags);
```

These fixed-arity adapters deliver opaque external or propagated text.
They should not be used for a literal
format string that can be represented in `diag_conf`.
Before retaining a dynamic-text boundary, trace the value back to its source.
A helper returning a preassembled string may still represent a finite set of
producer-owned cases, or one fixed message. Model those cases with catalog
templates and semantic inputs instead of treating the string as arbitrary
external text.
Do not remove public variadic formatting APIs just because they use `vmess()`.
Keep their compatibility behavior, but route ordinary catalogued producers
through generated diagnostic macros. Classify generic regex reporting and
extension error-capture paths separately from those producers.
Low-level parsers such as the `grok_bslash_*` helpers may also be used as
functional utilities. Their shared diagnostic interface takes an optional
`SV **exception_slot` and returns zero on success or a diagnostic code on
failure. A NULL slot means the helper reports the result without allocating
or appending an exception. A non-NULL slot lets it append structured
diagnostics, creating the exception on demand. Keep the helper independent of
global exception state. Whenever a caller needs to accumulate diagnostics or
exception data, it passes `&PL_pending_exception`. Do not create a separate
local accumulator for a standalone operation. The slot is shared so warnings
and errors produced by nested helpers remain part of one ordered exception.

These helpers do not decide whether parsing continues or when diagnostics are
flushed. The caller owns recovery and disposition. When a caller decides to
flush, it delivers the entire exception in the slot, including diagnostics
appended earlier, rather than delivering only the latest diagnostic.
At runtime, the emitter flushes at the operation boundary, before its owner
returns or unwinds. During compilation, the parser decides when to flush based
on whether an error is continuable and whether parsing can safely continue.
Warnings and errors can both accumulate in source order. A flush
calls `__EXCEPT__` once with the complete canonical exception, then rechecks
the diagnostics.
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
Keep `croak` and `die` producer APIs distinct where their control-flow
contracts differ. `${^CUR_ERROR_OBJ}` exposes the canonical aggregate during
legacy hooks, which retain their one-argument signatures.

Use the same pending accumulator across nested parser operations. For example,
`scan_const()` appends diagnostics while it processes one quoted string, and
the compiler decides when the shared accumulator is ready to flush. A
successful compile must flush any accumulated exception when compilation
finishes. Deliver remaining groups in source order, then throw the aggregate
once if it contains an error. Runtime code flushes the shared accumulator before its owner
returns or unwinds. Do not make a low-level helper choose the flush point.

Never assemble sentence fragments in a parser helper. Return the diagnostic
code and append individual catalogued diagnostics with semantic parameters.
Keep historical rendered-text entry points only as deprecated compatibility
boundaries. Internal callers should use the shared exception-slot convention.
When inspecting diagnostic strings with `Data::Dumper`, UTF-8-upgrade the
strings before dumping them so non-ASCII characters are shown readably.

## Share templates while retaining per-message macros

Keep fixed diagnostic text in the config. When messages share a template,
add `variants` under its definition. Each variant has a symbolic code, a
generated or explicit `macro`, and `values` keyed by message parameter name:

```perl
variants => {
    CWD_CWD_USAGE => {
        values => { signature => { en => 'Cwd::cwd()' } },
    },
},
```

Use `PERL_THROW_CWD_CWD_USAGE()` at the call site. The generator supplies
the fixed signature to the shared `FUNCTION_USAGE` macro. Unbound message
and delivery parameters remain wrapper arguments in their original order.
Variants may bind several simple `text` parameters with `format_str => 's'`.
Use language keys for fixed text. English is required, and values can be
provided for each supported translation.

Variant codes and macro names must be globally unique. A variant's `emit.api`
must be the parent's API or one of its delivery aliases. It inherits the
message schema, warning categories, and formatting rules. Preserve `DIE`
delivery through its `_DIE` alias when needed.

Do not remove per-message macros or move fixed values into C to reduce the
number of definitions. The source guard rejects literal bindings passed
directly to shared macros. Runtime values can use a shared macro or a
configured wrapper that supplies the remaining fixed parameters.

## Preserve Unicode when editing the catalog

`diag_conf.pl` is UTF-8 source and declares `use utf8;`. Write printable
Unicode directly in catalog strings. Regeneration requests Data::Dumper's
`Useutf8` option when the installed module supports it and has a safe
compatibility path for older versions. Controls, separators,
default-ignorable characters, and other non-printing values remain escaped.
Translation import must supply decoded character strings. Catalog output is
encoded as UTF-8 once when written.

Check the intended code points and rendered text, not just schema validity or
the source spelling. For proven repeated encoding in a specific value,
`utf8::repeat_decode($text, 1)` can remove the repeated layer; repair only the
identified fragments when a template mixes correct and corrupt text. Keep
repair scripts separate from regeneration; use the environment Perl for
writing and regenerating the catalog.

## Regenerate and validate

Run regeneration with the environment Perl. It normalizes the catalog with
`Data::Dumper`, explicit `Sortkeys` and `Useqq`, plus `Useutf8` when available.
It preserves schema POD, writes the normalized catalog as UTF-8, and generates
`perldiag.h`, `perldiag_data.inc`, `perldiag_helpers.inc`, and documentation.
The shared `regen_lib.pl` handles
`--tap` for generated-file checks. Check the generator and emitted files with:

```sh
perl regen/diag.pl
make manisort
git diff --check
```

For parser changes, rebuild the affected objects or the core binary and run:

```sh
CCACHE_DIR=/home/demerphq/git_tree/perldev/.ccache make -j10 perl
./perl -Ilib t/comp/parser.t
```

Check for duplicate templates and unmanaged call sites:

```sh
perl Porting/diag_inventory.pl
./perl -Ilib t/porting/diag.t path/to/source.c
```

The inventory should contain only its column header. `diag.t` checks calls
to old APIs, including parser variants, SV delivery and `va_list` forms.
It excludes declarations and narrowly identified public formatter forwarding
implementations. It has no per-message exception list. The generated header
has no legacy wrappers, dynamic parser aliases or `__VA_ARGS__` adapters.

Compile-time producers may behave differently in top-level compilation and
nested `eval`. If a path is guarded by `!PL_in_eval`, an `eval q{...}` test can
bypass its recover-and-append branch. Test that behavior in a child interpreter
compiling a top-level script, and use `PERL_DIAG_RENDER=Dumper` to check the
selected diagnostic fields and their order. For private hash inspection,
call Data::Dumper from `__EXCEPT__` instead.

## Review checklist

- Existing message definitions were searched and reused where appropriate.
- The new catalog hash has the correct delivery API, severity, default exception kind, and typed
  arguments.
- `message.args` defines named input, selector, and template roles;
  `emit.args` contains delivery-specific inputs.
- Generated diagnostic data/types/enums use `perl_`, functions use `Perl_`,
  and macros use `PERL_`. New `embed.fnc` functions suppress short aliases.
- The call site has no free-form diagnostic text or `form()` call.
- `perldiag.h` and `MANIFEST` were regenerated as required.
- The focused build and parser test pass.
- The change is committed separately from unrelated diagnostic migrations.
