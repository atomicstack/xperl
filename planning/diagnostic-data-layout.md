# Diagnostic data layout

Current implementation, including the declaration-order capture migration
validated on 2026-10-26. Selector and template-case
structs live in `diagpack.h`; their table-driven matcher lives in
`diag_template_match.h`.
`pp_ctl.c` owns dispatch and inspection. `regen/diag.pl` generates core
metadata and permanent English in `perldiag_data.inc`, identifiers in
`perldiag.h`, and separate XS catalogs through `regen/diag_pack.pm`.
This describes the implementation, not a proposed layout.

## Table connections

Arrows show pointers or indexed lookups. Shared targets are emitted once;
the language lookup and case tables are emitted separately for each language.

```text
CLASS REGISTRY

$CONF->{diagnostic_classes} + regen/warnings_data.pm
    |  regen/diag_classes.pm validates explicit parents and inherited leaf restrictions
    v
perl_diag_class_registry[]
    { name, parent, leaf_only, warning_category_plus_one }
    |                                  |
    +-- runtime class bootstrap        +-- dynamic warning category -> canonical class

SHARED PARAMETER DATA

perl_diag_metadata[_idx]
    |
    +-- param_offset / param_count --> perl_diag_param_ids[span]
    |                                      |
    |                                      +-- pair ID --> perl_diag_param_metadata[ID]
    |                                                         { name, type }
    |
    +-- input_offset --> perl_diag_param_input_ranges[one per captured parameter]
                             |
                             +-- input_offset / input_count --> perl_diag_input_metadata[span]
                                                                    { name, type }

LANGUAGE DATA

interpreter registry: language -> registered static engine
permanent built-in English -> emergency fallback, including miniperl
    | engine -> catalog per language: name, cases/count, projection stream/count,
    |                         diagnostic lookup rows, word groups
    v
catalog.schemas[local_row] -> {diagnostic_number, code, param_ids, param_count}
    | find the stable diagnostic number; never use a core _idx here
    v
perl_diag_templates_<language>[local_row]
    { selector_count, stored_param_count, word_group, first_case, selectors }
                           |                                      |
                           v                                      v
perl_diag_template_cases_<language>                  shared selector descriptors
    { diagnostic_number, selector_pattern,               { source index, domain,
      positional_template, arg_count,                      width/shift, plural rule }
      argument_index_offset }                                     |
            |                 |                                   v
            |                 v                        perl_diag_selector_domains
            |       perl_diag_template_argument_indices_<language>
            |           [canonical source indices for this case]
            |                 |
            v                 v
shared UTF-8 text        current canonical parameter values
    "Error in %1$s"          prepared as temporary display values

```

Catalog entries with `emit.api => 'RENDER'` supply formatting views only.
They share the tables and translation tooling below, but generate
`PERL_FORMAT_<CODE>(language, values)` rather than an emitter. The values AV
contains every retained parameter in declaration order.
`Perl_diag_render_format()` selects the language and case without constructing
or appending a diagnostic. Group summaries retain the original records.

## Identifiers

- `perl_diag_<code>_idx`: one-based metadata index, implicitly numbered in code
  order. It can change when diagnostics are added.
- `perl_diag_<code>_number`: explicit, stable catalog number. Template rows use it
  to identify their owner.
- `perl_diag_template_no_template`: zero, pointing to a null template-case row.
- `perl_diag_template_start_<language>_<number>`: symbolic first-case offset.
  Enum increments are implicit except when skipping multiple case rows.

## Shared tables

| Data | Fields / representation | Use |
| --- | --- | --- |
| `perl_diag_class_registry` | `name`, explicit `parent`, effective `leaf_only`, `warning_category_plus_one` | Shared class hierarchy and warning category mapping. A category field of zero means no category; valid category `WARN_ALL` is represented as `WARN_ALL + 1`. |
| `perl_diag_metadata` | Identity/severity fields, parameter offsets/counts, compatibility hint flags; `class_name`, `allowed_class`, `category_policy`, `role`, `grouping_role`, `review_status`, `leaf_only`, `dynamic_category` | One row per diagnostic, indexed by its generated `_idx` enum value. Classification is computed from shipped catalog and warning-hierarchy inputs. |
| `perl_diag_param_metadata` | Unique `{ name, type }` pairs | Parameter descriptions; pair IDs are `U16`. |
| `perl_diag_param_ids` | Packed flat list of pair IDs | Metadata offset/count selects each diagnostic's captured parameter list. Longest lists are placed first; lists reuse the first matching contiguous span or append if none exists. |
| `perl_diag_param_input_ranges` | `{ input_offset, input_count }` | Metadata `input_offset` selects one range per captured parameter. Identical or contained per-diagnostic range sequences share spans. |
| `perl_diag_input_metadata` | `{ name, type }` | Direct row stream of raw macro inputs. Identical or contained compound input sequences share spans. |
| Selector value arrays | Ordered string literals | Producer semantic domains and language-local render domains. Equal arrays are shared within each compiled output. |
| `perl_diag_selector_domains` | `{ values, U16 value_count }` | Producer domain IDs used by symbolic values and dynamic string conversion. Plural and operation-grammar fields use domain zero and do not consume producer IDs. A wide domain can contain 65,535 concrete values. |
| Selector descriptor arrays | `{ name, index, domain_id, values, value_count, value_width, shift, plural_kind, assert_unknown, operation_word, plural_form, native_id }` | Locate selector sources and map them to packed keys. Native IDs are distinguished explicitly from integer-valued text. Equal descriptors share storage within an output. |
| `perl_diag_template_text_<hash>[]` | `static const char` arrays containing UTF-8 positional text | Strings are interned within each catalog output; a pack does not reference another DSO's text. |
| Pack schemas and parameter pairs | Stable number/code, packed U16 name/type IDs and count | Aligned with compact template rows. Registration checks supplied schemas against core metadata; omitted rows are valid misses. |

Parameter pairs are assigned in diagnostic-number order. Parameter-ID lists
are packed longest first, with equal-length ties in diagnostic-number order.
Each list reuses the first matching contiguous span, otherwise it is appended.
Zero is reserved in the metadata, parameter-pair and parameter-ID tables.
The wrapped parameter-ID list uses four-character numeric fields, padded
with spaces on the left.

The raw-input rows and per-diagnostic input ranges use the same longest-first
span packing. The generator interns `{ name, type }` pairs as temporary U16 IDs
while packing, then emits the selected rows directly into the existing tables.
The IDs are not stored in the compiled catalog, so runtime inspection follows
the same two range lookups and allocates no extra lookup table. A diagnostic
with no parameters keeps input offset and count zero.

For the current catalog, this reduces `perl_diag_input_metadata` from 2,329 to
452 rows and `perl_diag_param_input_ranges` from 1,793 to 769 rows, including
their sentinels. In a 64-bit optimized build, the two arrays occupy 13,384
bytes instead of 51,608 bytes. These figures cover the arrays' pointers and
range fields, not the string literals they reference.

Template names use eight SHA-256 hex digits, extended until colliding prefixes
disambiguate. A full-digest collision fails generation. Definitions sort by
case-insensitive full text, with original text breaking ties. `%1$s`, `%2$s`,
etc. refer to already formatted display values; `%%` represents a percent.

Normalization sorts selector-domain array leaves in place, preserving shared
references. An argument's `selector_unsorted => 1`, or an explicit selector's
`unsorted => 1`, preserves its configured order for all aliases of that array.
Their order determines producer semantic IDs; conditional domains combine branches in
the preceding selectors' configured order. Wildcard branch collection visits
sorted hash keys. The reference-type domain is an ordering exception:
`UNKNOWN` comes first, followed by the native `SVrt_*` order. Its selector IDs
are one greater than the native IDs, reserving zero for wildcard. Ordinary
selector producers pass domain-local symbolic integer IDs. Dynamic strings
convert at explicit PV/SV boundaries; generated helpers retain the domain and
ID for key construction. Displayed selector parameters obtain their names
through the shared lookup. Canonical table strings do not make arbitrary input
SV strings suitable for pointer-identity comparisons. Plural selectors resolve
numeric counts through generated macros instead.

Compiled plural exact cases and operation-grammar values belong to each
language. Their IDs are assigned locally and used consistently by that
language's word rules, plural resolver and template cases. The producer
header contains neither those exact-count IDs nor grammar-tag IDs. ABI 4
marks the change in producer-domain numbering after removing render-only
domains from the shared registry. Canonical domain ownership is assigned
in diagnostic-number order, regardless of the caller's input order.

## Tables per language

Only English is built into `perldiag_data.inc`. Other catalogs live in
ordinary `XPerl::DiagPack::XX` XS extensions. Each static engine has a language name,
a catalog pointer, a render callback and cardinal/ordinal callbacks. The
catalog holds that language's case, projection, lookup and word tables with
their bounds. XS packs use the same structs from `diagpack.h` and the same
generator writers.

Pack generation uses a selected language's render layout. Its data file
records a digest of that emitted body and footer digests for shared generator
sources and opcodes. It does not hash the complete multilingual config files.
These digests describe generated output; they are not registration gates.

The interpreter's optional overrides live in a language-keyed hash under
`PL_modglobal->{"XPerl::DiagPack::registry"}`. Registration validates a
replacement before storing its static pointer. Lookup allocates nothing.
Before that interpreter hash exists, permanent English remains usable.

Core tries the selected captured or registered engine,
then registered English, then permanent built-in English. Duplicate engine
pointers are tried only once. Each attempt gets new scalar and display views
from the original snapshot. A callback returns an owned string or NULL for
a miss; it does not choose fallback. Core's outward rendering APIs return
mortal strings. Direct pack rendering keeps its owned return contract.

Early compatibility formatting during capture is a separate path. It calls
the permanent English engine directly, without consulting registrations or
running fallback. This preserves parser control behavior without exposing
construction to a registered language callback. The resulting text is not
the diagnostic's canonical state.

```c
typedef struct {
    UV diagnostic_number;
    U64 selector_pattern;
    const char *positional_template; /* points to perl_diag_template_text_<hash> */
    U8 arg_count;
    U32 argument_index_offset;
} perl_diag_template_case_t;

typedef struct {
    U8                     selector_count;
    U8                     stored_param_count;
    U16                    word_group;
    UV                     first_case;
    const perl_diag_selector_t *selectors;
} perl_diag_template_t;
```

- `perl_diag_template_cases_<language>` groups cases by diagnostic number.
  It has null rows at zero and at the end. Narrow selectors occupy one byte
  each, with zero as wildcard and concrete values starting at one. With only
  narrow selectors, positions 1–7 are available and position 8 stays zero.
  With one wide selector, it occupies positions 7–8 (bits 48–63) as a U16;
  up to six narrow selectors use positions 1–6. The wide field's zero value
  is wildcard; `0x0100` is a concrete value and remains distinct from
  `0x0101`. Selector order in metadata remains configuration order, while
  each descriptor's `shift` maps it to its packed position.
- `perl_diag_templates_<language>` has compact rows aligned with its schema
  pointer array. Lookup uses the stable diagnostic number. Missing rows are
  valid misses, independent of the core metadata table's order or length.
- `perl_diagpack_builtin_engines` contains permanent English and a null
  terminator. Registered engines provide the other languages and can override
  English lookup without removing the emergency descriptor.
- `perl_diag_template_argument_indices_<language>` maps each case's dense
  display slots to canonical source indices. Offset zero is reserved for an
  empty projection. Source index zero is valid within a nonempty projection.

Generated tables and enums use one compact formatter in `regen/diag.pl`.
Column widths follow the actual rendered cells, with text aligned left and
numbers right. Small separators replace the old fixed growth allowance.
Implicit enum names do not widen columns used only by explicit assignments.
Selector keys align inside `UINT64_C(...)`; constant literals are not padded
before their semicolons. Language tables remain separate.

Core metadata uses `_idx`; each catalog separately resolves the stable number
to its local row. Matching scans from `first_case` while rows belong to that
number. The first matching case wins. Missing translations fall back to English.

`use diagpack 'de'` installs a static engine pointer in lexical hints. Capture
retains it per diagnostic; an absent hint stays absent so the mutable default
still applies later. Explicit render languages override the entire tree.
Registration replaces lookup capability, while captured pointers keep their
original static descriptor. Rendering does not load modules.

## Runtime objects and argument roles

Locale panic diagnostics retain numeric errno and C source/caller locations
in `location->{panic}`, separately from the Perl source location. A render-only
catalog format wraps their semantic message with this context. JSON and Dumper
include the context fields explicitly.

`XPerl::Exception` owns the ordered `messages` array of diagnostics.
Diagnostics retain identity, severity, named parameters and source/context
data. New captures do not store a selector key. The compatibility accessor
derives one when requested; explicitly supplied legacy keys remain readable.
Diagnostics retain neither template text nor a preformatted message.
Rendering selects the catalog template later.

Macro inputs, selector sources and template values are overlapping roles.
Captured values follow parameter declaration order, including internal values
and selector-only sources. Each translated case has its own dense display
slots. Its projection maps those slots to canonical source indices, ordered
by source index. Adding a placeholder to a translation does not change the
producer's parameter order, allocations or helper body.

Enum inputs retain native integer SVs, with a numeric `selector_domain`
annotation; no `selector_id` mirror is stored. Plain integer decimal sources
retain native values, while precision, padding and composed strings retain
their formatted representation. Rendering snapshots current values once,
recomputes selectors, and prepares temporary display spellings. Stored keys
do not override edits. JSON/Dumper quote values and identify native enum
values with an optional `<diagnostic-code>.<parameter-name>` domain locator.

## Accepted storage trade-offs

- Each language lookup repeats shared selector pointers and counts, plus
  the stored-parameter count. Only the case offset needs to vary by language.
- Each case stores its own displayed-argument count and an offset into a
  language-owned U8 projection stream. Identical and contained projections
  share spans. The U32 offset uses existing padding in the 64-bit case struct.
- Parameter-ID lists now reuse identical and contained contiguous spans.

Language-table separation is intentional. Parameter-ID span packing is
implemented. The duplication above is accepted rather than unfinished
closeout work; further compression would be a separate optimization task.

## Integer plural rules

`diag_conf.pl` stores shared C expressions and declared standard `forms`
under `plural_rules` and assigns
a `cardinal` and `ordinal` rule name to each language under `languages`.
`regen/diag.pl` validates rule definitions, references, and kinds. It emits
each shared rule once, per-language aliases, and combined dispatch macros in
`perldiag_data.inc`, using the generated language-ID order.

The fixed C function bodies remain in `pp_ctl.c`, registered in `embed.fnc`.
The functions `Perl_cardinal_plural_form(aTHX_ language, n)` and
`Perl_ordinal_plural_form(aTHX_ language, n)` invoke generated dispatch macros
and call the effective engine's category callback. The builtins `cardinal_plural_form($language, $n)`
and `ordinal_plural_form($language, $n)` expose those values to Perl. Unknown
languages return NULL in C and undef from the builtins. Rule calculation uses
a local `UV` and allocates nothing. The callback returns a category enum;
core checks its bounds and converts it to a name. An invalid category returns
NULL in C and undef through the builtins.

A selector with `plural => 'cardinal'` or `'ordinal'` names an unsigned source
argument. Configuration and inspection expose the union of exact numeric
cases across languages. Each compiled language domain contains the six
categories plus only its own exact cases (`"0"`, `"21"`). The numeric
source remains in `params` even when no template displays it. The compatibility
key contains zero for plural octets because no language has been selected yet.

Plural categories use fixed enum IDs, followed by each selector's exact
numeric cases in that language. `perl_diag_selector_t` refers to a generated inline resolver.
Per-diagnostic, per-language macros test their own exact counts first, then
call the shared cardinal or ordinal rule macro. Exact cases requested only
by another language do not change the category chosen for this language.
Equivalent resolvers are shared. Their enum members use `perl_`, functions
use `Perl_`, and macros use `PERL_`.

At rendering, each count is parsed once and its resolver fills the packed
selector octet. The existing ordered template scan compares integer keys.
English fallback repeats resolution using English rules and exact cases.
No string comparison occurs in the plural template-matching loop. `any` and
`*` are accepted wildcard spellings, stored as `*` in the normalized config.

## Compiled matcher fixtures

`Perl_diag_template_case_find()` in `diag_template_match.h` scans ordered
compiled cases with the selector descriptors' configured widths and shifts.
`pp_ctl.c` calls it after resolving language-specific plural values. The
XS::APItest extension includes a generated fixture from
`ext/XS-APItest/diag_match_fixture.json`. Its make dependency regenerates
`diag_match_fixture.inc` with the environment Perl. The XS test calls the same
compiled matcher and generic name/ID conversion helpers as the production
wrappers. The fixture covers U16 boundary values and metadata orders without
adding a diagnostic to the production catalog.

Production B4 warnings now use the generated U16 operation-name selector in
`ERROR_UNICODE_WIDE_CHARACTER_BYTE_CONVERSION_FAILED_IN_OPERATION`, `WARNING_UTF8_TRUNCATED_SEQUENCE_IN_OPERATION`,
`WARNING_UTF8_TWO_BYTE_SEQUENCE_CONTINUATION_INVALID`, both code-point warnings, and the two locale
warnings. The operation selector occupies bits 48–63; selector-only source
arguments are not stored among display parameters. Existing narrow context
selectors and displayed `OP_DESC` values remain independent fields. The
locale warning templates currently have exact cases for the five case-mapping
operations and wildcard fallback elsewhere; that fallback remains an explicit
localization audit item.

## Language-owned operation vocabulary

`diag_op_conf.pl` owns complete phrases, named forms, grammatical tags and
reusable rules. `regen/diag_words.pm` resolves those rules during generation.
The runtime bindings cover 49 diagnostics. Their operation parameters retain
numeric identities and their original display strings. No language
choice or translated phrase is stored back into the diagnostic.

```text
language template row: word_group (U16)
    |
    +--> language word_groups[word_group] {word_count, words}
            |
            +--> binding { source, target, numeric, assert_unknown, map_count, map, values, selector_mask }
            |                           |             |
            |                           v             v
            |              U16 opcode-to-value map   resolved values
            |              [1 + opcode] -> value ID  [value ID] -> {text, selector_key}
            |                                                |
            |                                                +--> shared UTF-8 text pool
            v
       retained identity parameter          temporary template argument at target
```

Word-group zero means no bindings. Nonzero group IDs index a small array
per language. The U16 index fits the usual template-struct padding, avoiding
a word-binding pointer in every diagnostic row. Each language has its own
resolved-value and packed-map arrays. Equal text
shares the ordinary hashed string constants. Equal `{text, selector_key}`
results share a value record. Maps use longest-first offset/span packing,
sharing equal or contained sequences with the existing parameter-ID packer.
Map entries use U16 IDs: zero is unavailable, one preserves the original
value without grammatical outputs, and larger IDs select resolved records.
A resolved record with NULL text preserves the original phrase while applying
an explicitly configured fallback category. Identity zero and out-of-range
identities use the binding’s fallback entry; a missing rule is unavailable. `PERL_DIAG_WORD_OPERATION(opcode)` is `1 + opcode`;
`perl_diag_word_operation_do_block` follows the actual opcode range. A static
assertion checks the generated map bound against `OP_max`.

Dynamic operation-name producers use the counted
`Perl_diag_word_operation_from_name(name, length)` helper at the boundary.
It compares complete opcode names, rejects embedded-NUL prefixes, and returns
zero for unknown names. Uninitialized-warning aliases map to their underlying
opcode before capture. Numeric producers avoid this name lookup entirely.

A binding's mask clears only its own grammatical fields. Its precomputed key
then supplies those fields using the ordinary selector domains and packed
layout. Derived dimensions are generated from the union of bound language
rules, rather than stored as new diagnostic parameters. A union over 255
values uses the existing wide field; ordinary field-budget checks apply.
The pilot needs no grammatical fields because its phrases contain the
required articles and agreement. Its operation identities consume no key bits.

`Perl_diag_render_attempt` resolves words into a temporary AV, runs the
existing template matcher (including plural rules), and formats the result.
Early English formatting, later rendering and render-only helpers use that
boundary. Diagnostics without word bindings allocate no extra argument AV.
If a word or template is unavailable, the English attempt starts from the
original arguments and recomputes all language-dependent choices. Canonical
parameters and their SV values remain unchanged.

Bindings with `assert_unknown` preserve source-domain checks in debugging
builds. Their maps reserve U16 value 65535 for identities outside the audited
domain. Map entry zero retains the release fallback. Missing translations
use value zero and request an English retry, independently of domain checks.
The flag uses existing padding in the binding structure.


## Vocabulary maintenance boundary

`regen/diag_word_translate.pm` adapts shared words to the optional translation
driver. It reuses JSON::PP, process monitoring, retries, checkpoints and
publication support from `regen/diag_translate.pm`. Ordinary regeneration
does not load that workflow module.

Saved word documents contain canonical opcode names and named forms/tags,
not generated C IDs. Typed declaration changes can update forms, tag domains,
rules and language-local bindings. Validation uses private candidates.
Publication preserves canonical producer inputs and common domain references,
updating only bindings and derived selector metadata. Word-only repairs do
not change `diag_conf.pl`.

Word provenance lives under `words/language/operation` in the existing
translation-provenance file, separately from sentence `entries`. Source forms, declared tag domains, rules, bindings and sentence roles
determine word freshness. Sentence provenance additionally tracks the used
translated phrases and tags. Draft/reviewed
status is independent of source freshness and runtime completeness.
Incomplete-form inspection is allowed for maintenance; final import and
code generation require complete dependencies.
