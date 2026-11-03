# XPerl differences from mainline Perl

This document summarizes the intentional and material differences between
the current XPerl branch and mainline Perl's `blead` branch. It is a guide
to the shape of the fork, not an exhaustive patch listing. The exact changes
can be inspected with:

```text
git diff origin/blead..HEAD
```

## AI policy is now permissive

We have removed the AI-POLICY document, it was divisive and unbecomming of Perl.

## Language and runtime features

### Generators and resumable execution

The fork contains an experimental generator implementation with
`use feature 'generator'`, `gen` blocks, and explicit `yield` operations.
Generator objects expose running, completed, failed, and exhausted lifecycle
states through functions and methods. Initial arguments may be supplied through
an ordinary `@_` body or a signature, while later calls can send values back
to a suspended `yield` without rebinding the initial arguments. List-valued
yields and scalar-context handling are preserved.

Generator continuation ownership is one-shot, with diagnostics for invalid
resumption. Exception, cleanup, destruction, garbage collection, callback
context, and re-entry behavior are handled across opcode-boundary suspension
and resumption. The saved process state preserves the Perl execution context
across each suspension.

The active `PL_*` variables retain their direct interpreter or global storage.
Only the marked execution state is copied into a generator process state when
a generator is suspended or resumed. This avoids adding an execution-context
pointer dereference to ordinary calls while still allowing generator stacks
and execution state to be switched safely. Threaded and unthreaded
initialization, exports, generated access macros, and lifecycle handling were
updated for this model.

The members of the threaded context structure were also reordered to keep the
hottest execution fields together, improving ordinary subroutine calls by
several instructions per call.

Generators provide cooperative resumable execution: callers explicitly choose
which suspended generator to resume, and no threads or implicit scheduler are
created. A minimal generator can be written as:

```perl
use generator;

my $letters = gen {
    for my $letter ("A".."E") {
        yield $letter;
    }
};

my $numbers = gen {
    for my $number (1..5) {
        yield $number;
    }
};


for (1..5) {
    say $letters->(), $numbers->(), " ";
}
say "done" if $letters->exhausted;

# Outputs:
# A1 B2 C3 D4 E5 done
```

The interface is documented in `pod/perlgenerator.pod` and `lib/generator.pm`;
related feature, syntax, diagnostic, and release documentation was updated.
The runtime and callable-object behavior is covered by the generator and XS
API runtime tests.

The experimental `iterator` package generalizes the callable lifecycle
protocol to ordinary blessed code references. It distinguishes an ordinary
empty return value from completion and exposes running, completed, failed,
and derived exhausted states; generator continuation states remain private to
the generator runtime.

An uncaught exception escaping an iterator body is rethrown without silently
changing its state. The iterator contract requires code presenting itself as
an iterator to report completion accurately, so `exhausted` remains reliable
when an empty list is a valid ordinary result. The protocol also defines
`restartable` and `restart`; iterators are non-restartable by default and the
default restart method reports that restarting is unsupported.

The iterator API is documented in `pod/perliterator.pod` and `lib/iterator.pm`
and is covered by `t/op/iterator.t`.

### Class objects and Data::Dumper

Class objects now understand shallow class-object/hash conversion APIs for
serializer support. `Data::Dumper` uses the new representation in both its XS
and pure-Perl paths, with compatibility guards for building the distribution
on older Perl versions. The class-object support is documented and tested.

The relevant APIs and integration are described in `pod/perlclass.pod` and
the class-object and Data::Dumper tests cover the conversion behavior.

### Classes and roles

The class system now supports reusable `role` declarations and algebraic role
composition. Roles can provide fields, methods, field initializers, required
methods, and `ADJUST` blocks. A class or another role consumes one or more
roles with the experimental `:implements` attribute.

Roles compose transitively, and a shared role reached through a diamond is
included once. Unresolved method conflicts between unrelated roles and
conflicting fields are reported at composition time. The `implements` method
and infix operator provide nominal membership tests, including roles composed
by a superclass; this is distinct from `isa`, while `DOES` reports composed
roles as well as ordinary inheritance relationships.

A minimal example is:

```perl
use feature 'class';

role Named {
    method name() { "a named object" }
}

class Person :implements(Named) {
    field $name :param;
    method name() { $name }
}
```

The class and role behavior, conflict handling, field composition, required
methods, implementation membership, parser support, diagnostics, and threaded
metadata are documented in `pod/perlclass.pod` and covered by the role tests.

#### Custom constructors

Every native class exposes its generated constructor as `CONSTRUCT`. It
accepts named argument pairs, allocates the object, initializes fields, and
runs `ADJUST` blocks. A class without a local `new` receives an alias to
`CONSTRUCT`, preserving the usual construction interface.

A class can declare an ordinary `sub new` with its own signature and
delegate to `CONSTRUCT` after processing its arguments:

```perl
use v5.36;
use feature 'class';

class Point {
    field $x :param :reader;
    field $y :param :reader;

    sub new ($class, $x, $y = 0) {
        return $class->CONSTRUCT(x => $x, y => $y);
    }
}

my $point = Point->new(10, 20);
```

The custom sub controls its return value and any work around construction.
Calling `CONSTRUCT` directly bypasses it. Each subclass without a local
`new` gets its own generated alias, so reusing a parent's custom constructor
requires explicit forwarding.

#### Inheritance from conventional packages

The `:isa` attribute accepts a conventional blessed-reference package as
well as a native class. A native class with a conventional parent declares
one scalar field marked `:blessed_self`. Its author supplies the blessed
representation through a field parameter or initializer:

```perl
use v5.36;
use feature 'class';

package BlessedPoint {
    sub new {
        my ($class, %args) = @_;
        return bless \%args, $class;
    }

    sub x { $_[0]{x} }
}

class RGBPoint :isa(BlessedPoint) {
    field $legacy :blessed_self :param;
    field $red :param :reader;

    sub new ($class, $x, $red) {
        my $parent = $class->SUPER::new(x => $x);
        return $class->CONSTRUCT(legacy => $parent, red => $red);
    }
}

my $point = RGBPoint->new(10, 200);
say $point->x;    # conventional method receives the blessed hash
say $point->red;  # native method receives the native object
```

`CONSTRUCT` never calls the conventional parent's constructor automatically.
The association is established when the marked field initializes. Later
field initializers and `ADJUST` blocks can then call both kinds of methods,
and conventional methods can call native overrides. The field becomes
read-only after attachment, while the referenced contents remain mutable.

The native object owns the blessed representation and its destruction.
One blessed referent can belong to only one live native object. Native
subclasses inherit the association and cannot declare a second marked
field. Construction, method dispatch, restoration, and destruction rules
are documented in [perlclass](pod/perlclass.pod).

### Structured exceptions and translated diagnostics

Core errors and warnings now use structured exceptions with stable
diagnostic identifiers, typed arguments, source locations, and ordered
context. Default rendering preserves familiar Perl text. Applications can
inspect the diagnostic objects or select annotated text, JSON, or Dumper
output. A structured exception hook runs before the existing warning and
die hooks, and a two-variable `catch` can retain both the compatibility
value and the structured exception.

Loadable language packs provide translated diagnostics, with English
fallback and lexical or runtime language selection. Alongside English,
translations are available in Arabic, Chinese (Simplified), Dutch,
Finnish, French, German, Hebrew, Hungarian, Icelandic, Italian, Persian,
Portuguese, Russian, Serbian, Spanish, Turkish, Ukrainian, and Welsh.
These languages were chosen to challenge the translation machinery in
different ways. Together they help establish the capabilities needed to
support any language, including plural rules, grammatical forms, word
order, and writing systems. More languages are expected to be added over
time. The translations are machine drafts awaiting native linguistic
review. See
[XPerl::Exception](lib/XPerl/Exception.pm),
[XPerl::Diagnostic](lib/XPerl/Diagnostic.pm), and
[diagpack](lib/diagpack.pm) for the interfaces.

### Compact hash storage

Ordinary hashes use a compact array of `HE` entries and a separate index.
On 64-bit builds an entry occupies 16 bytes, with no collision-chain pointer.
By default, indexed hashes use integer chains: packed bucket heads point to a
packed per-entry next-link array, and both store one-, two-, or four-byte
entry identifiers. Fingerprints are disabled by default. Open addressing
remains available by explicitly selecting `PERL_HASH_INDEX_OA`; its index
stores one-, two-, or four-byte entry identifiers, and the cached hash remains
in the key's `HEK`. Its capacity remains a power of two. Through an index
capacity of 16,384 slots, OA entry capacity is the floor of two-thirds of
index capacity, and filling that allocation can trigger an index rebuild.
The following load, tombstone, growth, and shrink rules describe OA indexes.
Above that size, index pressure triggers a rebuild when live entries plus
tombstones reach the floor of two-thirds of capacity. Above the coupled range,
the full entry array grows independently by 25 percent. Entry compaction uses a 20 percent
hole threshold at all sizes, with no minimum byte threshold. A full entry array compacts when it
meets this threshold. A non-full array compacts at this threshold when its
proposed entry capacity, `live + floor(live/4) + 1` with a minimum of eight,
is at most half its current capacity. Otherwise a full entry array follows
the growth policy described above. Deletion alone does not rebuild either
array. These are standalone insertion checks. An index
rebuild that is otherwise required also packs entries when holes meet the
20 percent threshold; that rebuild does not use the standalone HE shrink
test.

When index occupancy reaches two-thirds, tombstones are cleared at the same
index capacity if they make up at least half of occupied slots. With fewer
tombstones, the index grows to preserve the live-load limit. Growth uses the
next power of two that can hold `3 * live` entries, with a minimum of eight
slots. Shrinking is considered only during compaction. The index target must
be at most half its previous capacity. Its target is the next power of two
that can hold `3 * (live + 1)` entries, with a minimum of eight slots. The
entry array can shrink independently when its target capacity,
`live + floor(live/4) + 1` (minimum eight), is at most half its previous
capacity. Otherwise existing capacities are retained. Rebuilds, including
compaction, reuse the index allocation when index and entry capacities are
unchanged. Without compaction, entry positions and holes are preserved. For
initial sizing and ordinary growth through 16,384 index slots, entry capacity
remains coupled to two-thirds of index capacity. Above that size, entry capacity grows
independently. A shrink can leave entry capacity decoupled from index
capacity. Changing it uses `Renew`, which may relocate the array.
Explicit `hv_ksplit()` reservation allocates entry space for the
requested count plus existing holes above the coupled range, including when
the index already has enough capacity. New-key insertion reuses its initial
probe result unless an index rebuild invalidates it.
Entry allocation can exceed index capacity, while
identifier width remains tied to index capacity: one byte through 128 slots,
two bytes through 32,768 slots, and four bytes above that. The ordinary hash
index is capped at 2^30 slots, which supports at most 715,827,882 live keys at
the two-thirds load limit. Inserting beyond that count or explicitly
pre-sizing beyond it throws `Hash key count exceeds limit of 715827882`. The internal
traversal order does not promise a public iteration order. Neither `HV` nor
`XPVHV` grows.

All builds encode the indexed bucket count and tiny-storage state in the
existing `xhv_max` field, so the change does not enlarge `HV` or `XPVHV`.
Indexed storage keeps the bucket-count exponent in the low six bits. Tiny
storage sets bit 6 as its form tag and stores its capacity in the low six bits. This
encoding works on 32-bit builds and does not alter the ordinary index's
2^30-slot cap. `HvMAX(hv)` remains the logical accessor: it returns the bucket
mask for indexed storage and the logical maximum for tiny storage. Use the
form-specific setters; do not read or write `xhv_max` directly. Paired
benchmarks found no broad slowdown, but results do not establish a general
speedup.

Empty hashes allocate no entry storage. With the default positive threshold,
a singleton uses one arena entry. The experimental `PERL_HASH_LINEAR_MAX`
setting can keep up to two, four, or eight entries in a dense array searched
linearly before building an index. Its default is four, so hashes with up to
four entries use linear search before promotion. At threshold zero, hashes
use indexed storage from the first key.

`hv.h` enables `PERL_HASH_INDEX_CHAINS` by default unless
`PERL_HASH_INDEX_OA` is selected. `PERL_HASH_CHAIN_FINGERPRINT` enables
fingerprints for the chain index. Selecting OA together with either chains or
fingerprints is rejected. `PL_strtab` remains open-addressed in every build.
The chain index retains the same compact entry array and tiny-hash form.
The index uses power-of-two buckets, packed bucket heads, and one packed
next identifier per entry slot. Zero marks an empty head or chain end, and
identifiers are one-based. Identifier width follows entry capacity,
including holes: one byte through 255 entries, two through 65,535, then
four. Widening the identifier arrays does not move entries; bucket resizing
and entry compaction rebuild chains.

The default chain index grows entry storage independently, starting at eight
entries and increasing it by 25 percent when full. Entry compaction uses a
20 percent hole threshold at every capacity, with no byte threshold. A full entry array
compacts at this threshold while retaining the bucket count. A non-full array
compacts at this threshold when its proposed entry capacity,
`live + floor(live/4) + 1` (minimum eight), is at most half its current
capacity. These are standalone insertion checks. An index rebuild that is
otherwise required also packs entries at this threshold, but does not apply
the standalone HE shrink test. Otherwise a full entry array grows by 25
percent without changing the bucket array. When live
entries reach two-thirds of bucket capacity, the
index grows to the next power of two that can hold `3 * live` entries, with
a minimum of eight buckets. Compaction normally keeps the bucket count. It
shrinks the bucket array only when its target, the next power of two at least
`3 * (live + 1)`, is at most half its current capacity. `hv_ksplit()`
pre-sizing uses a baseline of 1.5 times the requested count and reserves
entry space for that count. Promotion from the tiny linear form uses the
baseline open-addressed sizing policy.

The optional `PERL_HASH_CHAIN_FINGERPRINT` build option stores an 8-, 16-, or
32-bit fingerprint with each entry link. Lookup checks it before loading the
candidate entry and its key. This can reduce key-record reads on misses, at
the cost of a larger link array. The next-identifier array adds memory
proportional to entry capacity alongside bucket heads. Fingerprints remain
disabled by default. To select open addressing, use a clean build with
`-DPERL_HASH_INDEX_OA` applied to all objects, for example:

    make clean
    ./Configure -S -Doptimize='-O3 -DPERL_HASH_INDEX_OA'
    make -j4 test_prep

Shared-key interning uses an open-addressed slot array of `HEK *` pointers.
The slots have tombstones; each shared `HEK` carries a `U32` reference-count
prefix (12 bytes total for count, hash, and length), and its allocation remains stable while referenced, including when
the slot array grows. Capacity, probe positions, and tombstone count use
native-size integers. The pointer index has no fixed `2^26` slot limit; its
growth is limited by checked allocation arithmetic and available memory. The
cached hash and reference count in each `HEK` remain `U32`. Since the hash is
32 bits, hash distribution can limit performance above `2^32` slots. This
does not change the ordinary hash index's `2^30` slot limit. The table has a
minimum capacity of 32,768 slots.
Before insertion, when live entries plus tombstones reach
`floor(2*capacity/3)`, it targets the next power of two that can hold three
times the live entries, retaining the minimum capacity. It grows when
tombstones are below half the occupied slots. Otherwise it clears
tombstones at the same capacity, except that it shrinks when the target is
at most half the current capacity. It has no entry-array compaction or early
shrink check. Hash::Util provides
`shared_key_refcount` for non-mutating reference-count lookup and
`shared_keys` for copied key strings, and `immortalize_key` to acquire a
permanent reference until interpreter destruction. Pins are copied into
cloned interpreters. Its bucket diagnostics do not expose
the shared-key table.

Iteration scans the entry array. Hash-function seeding remains enabled,
while bucket-order perturbation, `PERL_PERTURB_KEYS`, and
`Hash::Util::hash_traversal_mask` are removed. Insertion during iteration is
detected through iterator state. Hashes do not promise insertion order.
`Hash::Util::hash_storage_info` exposes allocation sizes, capacities,
entry holes, the compatibility free-list count, tombstones, and probe
distances. Ordinary hash value and
iteration APIs do not apply to `PL_strtab`.

The representation changes the XS ABI and requires rebuilding extensions.
`HeNEXT` and `HeSHARED_NEXT` are removed, and writes to `HvMAX` use explicit
setters. Returned `HE *` and `SV **` pointers must be reacquired after
entry-array relocation or compaction during insertion or preallocation, and
after deletion that shifts entries in a dense array. Core consumers and bundled XS
modules are adapted to these lifetime rules. The
[design and benchmark report](Porting/hash-oa-design.pod) records the
compatibility limits, memory accounting, and measured performance trade-offs.

## Bundled distribution changes

### Tensor-XS and p5-matrix-utils

The p5-matrix-utils code is imported and developed as the bundled experimental
`Tensor-XS` distribution. It includes Perl `Tensor`, `Matrix`, `Vector`, and
related classes backed by XS storage, together with extensive tests and
examples.

The native tensor work includes descriptor-driven numeric data types,
integer and floating-point storage, coordinate-based indexing, row-major
strides, precomputed element counts, flat and nested data loading, native
tensor blob headers with alignment and trailing sentinels, bulk operations,
native access bridges, and core build integration. The public Perl classes
retain their interfaces while values use contiguous typed native buffers.

The distribution remains an experimental area rather than a finalized
numerical-computing ABI. Design and status details are recorded in
`dist/Tensor-XS/Changes`, `dist/Tensor-XS/XS_DESIGN.md`, and the related
distribution notes and result documents.

### Cpanel::JSON::XS

`Cpanel::JSON::XS` is added as a bundled core distribution, including its XS
implementation, Perl support files, command-line utility, test suite, JSON
specification fixtures, extended tests, metadata, and core maintainer/build
integration.

The imported distribution's API and tests remain documented in its own source
and test files. Its core integration is covered by the dual-life and build
checks.

### Lexical namespaces

The experimental `namespaces` feature adds lexical namespace state,
`namespace` declarations, `__NAMESPACE__`, namespace aliases,
namespace-qualified symbol resolution, and explicit `CORE:::` boundaries.
The parser, keyword tables, diagnostics, deparser tests, generated headers,
and documentation were updated. `CORE` receives special handling because it
is the implementation namespace for Perl's builtins and operators.

For example:

```perl
use feature 'namespaces';

namespace MyApp;
package Model;

sub name { "model" }
```

Here `Model` means `MyApp::Model` while this code is compiled. The namespace
prefix is lexical and does not replace Perl's ordinary current package. An
explicit `:::` boundary resolves a name from the top level instead.

The behavior is documented in `pod/perlnamespace.pod`, with related syntax,
builtin, experimental-status, diagnostic, and release documentation updated.
The namespace and bootstrap tests cover the implementation.

### `-E` enables the XPerl experimental surface

The `-E` command-line switch now enables `feature ':all'` and imports
`builtin ':all'`. This makes the branch's experimental keywords and builtin
functions available directly in one-liners and command-line programs, while
preserving the ordinary `-e` behavior. Experimental functions retain their
normal warnings. The behavior is documented in `pod/perlrun.pod` and covered
by the command-line regression tests.

### Dispatch/on data-shape matching

The experimental `dispatch_on` feature adds a conditional construct for values
whose shape matters. A `dispatch` evaluates one subject and considers ordered
`on` clauses from top to bottom. The first matching clause runs, and the outer
dispatch body may contain only dispatch-on clauses. A wildcard `on (_)` is the
usual default. Without a successful clause, `dispatch` returns `undef` in
scalar context and an empty list in list context.

The pattern inside `on (...)` is a data-shape language rather than an ordinary
Perl expression. It supports scalar literals, arrays, hashes, nested shapes,
class-qualified objects, regular-expression criteria, typed numeric criteria,
reference/value criteria, tails, and open shapes. Scalar names introduce
clause-local bindings, while `^` pins existing values. An optional
`if` introduces an unrestricted Perl guard that runs after the shape matches.

Bindings are discarded when a shape or guard fails, but closures may retain
them after the clause ends. Duplicate capture names, unsupported or ambiguous
syntax, invalid regex constructs, impossible slurp combinations, and repeated
constant keys are rejected explicitly rather than silently reinterpreted.
Pins preserve reference identity and undefined-value distinctions; captured
references preserve identity and tail captures do not alias source slots.

Object shapes inspect blessed references structurally without invoking
constructors or arbitrary methods. Native class objects are supported, while
inheritance and role matching remain reserved for future pattern forms. Simple
constant-only dispatches may use specialized linear, binary-search, or hash
dispatch, but source order and first-match semantics remain unchanged. This
feature is independent of the older `given`/`when` mechanism.

The reference and tutorial are in `pod/perldispatchon.pod` and
`pod/perldispatchontut.pod`; `pod/perlsyn.pod`, `pod/perldiag.pod`,
`pod/perlexperiment.pod`, and `pod/perldelta.pod` cover syntax, diagnostics,
experimental status, and release notes. Compiler and runtime behavior is
covered by the dispatch-matching tests and the associated planning notes.

## Generated and platform integration

The feature work changes keywords, features, opcodes, embedding declarations,
interpreter variables, parser grammar, warnings, and bundled distributions.
The branch therefore includes regenerated parser and header artifacts,
generated keyword and opcode files, generated POD indexes, and corresponding
build and platform integration. These generated changes are consequences of
the source changes above and must be regenerated when their inputs change.

## Compatibility posture

C and XS extensions can identify XPerl with `#ifdef XPERL` after including
`perl.h`, which defines the macro to `1`.

Existing Perl behavior is preserved where practical. The fork's experimental
features and development policies may continue to evolve as the branch
develops. Compatibility handling includes feature-disabled code paths,
`CORE` behavior, threaded builds, and bundled distributions.
