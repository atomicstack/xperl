# Parser evaluation-order audit

Audit date: 2026-11-09. Source revision: `abc49230f7` (XPerl 5.45.5).

This audit covers `perly.y`, `toke.c`, and the parser-facing optree
construction routines in `op.c`. It follows the multiline `use` line-number
repair. It does not cover the rest of the interpreter or CPAN distributions.

## Findings

Three parser paths have confirmed compiler-dependent diagnostics. They share
one mechanism: sibling C arguments call routines which can emit diagnostics
or change the parser's error state. C does not specify their evaluation order.
The calls themselves are permitted C. The observable parser result depends
on which call runs first.

### Binary operands

Eight grammar actions have two `scalar()` calls in sibling arguments:

| Rule | Location in the audited revision |
| --- | --- |
| Power | `perly.y:1826` |
| Addition and subtraction | `perly.y:1837` |
| Shifts | `perly.y:1841` |
| Bitwise AND | `perly.y:1847` |
| Bitwise OR and XOR | `perly.y:1849` |
| Range | `perly.y:1851` |
| Nonchaining relational comparison | `perly.y:1871` |
| Nonchaining equality comparison | `perly.y:1889` |

For example:

```c
newBINOP($ADDOP, 0, scalar($lhs), scalar($rhs))
```

`scalar()` is not a pure tree annotation. It can emit warnings for `sort`
and key/value slices, and it stops processing when compile errors exist.

Compile this source:

```perl
use warnings FATAL => 'all';
my @a; my %h;
my $x = (sort @a) + %h{1,2};
```

GCC first reports the hash-slice scalar-context warning. Clang first reports
the useless-sort warning. Without fatal warnings, both warnings appear in
opposite orders. The same difference was reproduced for power, shifts,
bitwise operators, ranges, `<=>`, and `cmp`. Chained comparisons did not
show this difference in the probes.

The corresponding sibling `scalar()` calls exist in the separate upstream
blead checkout at `20aecbd6fc`. That is source-level evidence that this
pattern is not unique to XPerl; no upstream binary comparison was performed.

The logical-XOR builder has the same pair at `op.c:10143`. A separate probe
with `my $x = ((sort @a) xor %h{1,2})` confirmed the same fatal-warning
selection difference. Parentheses matter here: without them, assignment
precedence contextualizes the left expression before the XOR is built.

### Assignment construction

`Perl_newASSIGNOP()` has sibling contextualization and lvalue-validation
calls at `op.c:9671`, `op.c:9838`, and `op.c:9844`. The logical-assignment
construction at `op.c:9667` is related, though its probes did not show a
diagnostic difference after normalization.

The scalar-assignment case is a stronger example than warning ordering:

```perl
use warnings FATAL => 'all';
my @a;
1 = sort @a;
```

GCC reports `ERROR_MUTATION_LVALUE_TARGET_NOT_MODIFIABLE`. Clang reports
`WARNING_SCALAR_USELESS_EXPRESSION`, promoted to a fatal error. For
`1 += sort @a`, those outcomes are reversed.

Without fatal warnings, one compiler emits the warning before the assignment
error, while the other omits it. Lvalue validation adds a compile error;
`scalar()` then observes the nonzero error count and returns without issuing
the warning. This is a shared-state dependency, not merely different
formatting of an identical result.

### Array dereference and subscript

At `perly.y:1772`, the grammar passes these as sibling arguments:

```c
ref(newAVREF($array_reference), OP_RV2AV), scalar($selector)
```

`newAVREF()` can impose scalar context on the reference expression. Thus
the reference and the selector can both produce warnings. This source
reproduces the same sort-versus-hash-slice warning reversal:

```perl
use warnings FATAL => 'all';
my @a; my %h;
(sort @a)->[%h{1,2}];
```

The neighboring hash-dereference probe did not show this reversal. It uses
`jmaybe()` for its selector and reaches scalar context through a different
path; it should not be classified as a confirmed instance from appearance
alone.

## Other inspected paths

The remaining `newSTATEOP()` call sites contain no second confirmed race
over consumption of `copline`. In particular, the `elsif` action combines
`newSTATEOP()` with `op_scope()`, but the latter does not consume `copline`
as another `newSTATEOP()` would. Its diagnostic probe agreed across both
compiler variants.

The signature builder creates its two state ops in separate statements.
Anonymous-sub construction and the block/subparse helpers were checked for
sibling calls that enter or leave different parser scopes. No additional
confirmed scope-transition race was found in the examined calls.

Attribute/import argument construction, overridden `readline` construction,
slice construction, method-call construction, and the lexer helpers were
reviewed as candidates. Multiple independent allocations can change pad or
allocation order without establishing a language-level bug. No additional
diagnostic or semantic bug was confirmed for these candidates by this audit.

## Validation method and limits

The baseline is an ordinary-stack, nonthreaded Linux x86_64 checkout build
of XPerl 5.45.5, compiled with GCC 13.3.0. Its embedded revision is
`539e0b6fab`, the pre-merge identity of the multiline-use repair. The parser
sources and generated actions are byte-identical to merged `abc49230f7`.

For the comparison, only `perly.c`, `op.c`, and `toke.c` were recompiled with
Clang 18.1.3 using the same configuration and optimization flags. Their
objects replaced those three members in a copy of `libperl.a`, which was
linked with the existing `perlmain.o` and remaining core objects. This keeps
the compiler comparison confined to the parser code. It is not a substitute
for a separately configured full Clang build.

There were 33 source probes, each compiled with ordinary and fatal warnings
under both executables: 132 child compilations. Of the 66 source/warning-mode
pairs, 34 had different normalized diagnostic results. These are variants of
the three paths above, not 34 independent bugs.

Comparisons used `PERL_DIAG_RENDER=json`. They retained diagnostic order,
codes, parameters, Perl source locations, messages, and exit status. The
internal `c_source` metadata was excluded because some macro expansion
locations differ between the compilers even when the Perl diagnostic agrees.
The Clang-parser executable also passed all 128 tests in `t/op/caller.t`.

The candidate finder masks comments and literals and groups nested calls by
sibling argument. It is a screening aid, not a complete C parser or a proof
of order independence. Runtime behavior outside parser construction,
arbitrary XS check hooks, threaded builds, and RC-stack builds were not
audited by this compiler comparison.

## Repair approach

Sequence the contextualization and validation calls in separate statements,
then pass their results to the constructor. Choose the intended order for
each construct. For assignments, decide whether to validate the left-hand
target before contextualizing the right-hand expression, so suppression of
secondary diagnostics is deliberate.

Add regressions for diagnostic code order, the fatalized diagnostic, and
suppression after a compile error. Regenerate grammar outputs from
`perly.y`, then run the same regressions with GCC and Clang parser builds.
Avoid mechanically rewriting independent nested allocations which have no
demonstrated shared-state dependency.

The follow-up repair, `431373cd01`, sequences those calls and adds portable
regressions in `t/op/context_order.t`. The tests use ordinary warning
categories and counts, without depending on XPerl exception APIs or rendered
text. The generic code, regenerated grammar files, tests and release note belong in a
separate commit marked `Blead-port: suitable`. This audit and the contributor
guidance are separate from that candidate for upstream porting.

The repaired GCC and Clang parser variants pass all 124 new regressions.
The original Clang parser variant fails the invalid scalar-assignment
regression. The GCC focused suite and a separate RC-stack build each pass
563 tests across contextualization order, parser edge cases, assignment
warnings, and caller locations. Repeating the 66 normalized differential
probes after the repair produces no differences.

The final full ordinary-stack GCC core suite passes: 3,313 files and
1,470,069 tests. The portable regression lives under `t/op`, alongside the
assignment-warning tests, so it does not violate the bootstrap restrictions
on `t/comp` tests.
