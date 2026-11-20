# XPerl differences from mainline Perl

XPerl adds experimental language features and changes several parts of the
Perl runtime. This document introduces the main differences from `blead`
and links to their documentation. For the exact source changes, use:

```text
git diff origin/blead..HEAD
```

## AI contributions

XPerl permits AI-assisted contributions. The mainline `AI-POLICY` document
has been removed.

## Language features

### Generators

A generator is a function that can pause and later continue where it left
off. XPerl provides experimental `gen` blocks and `yield` operations through
the `generator` pragma. Each call resumes the generator until its next
`yield` or until it finishes.

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

# A1 B2 C3 D4 E5 done
```

Generators are cooperative: the caller chooses when to resume them. They
create no threads or scheduler. Initial arguments use `@_` or a signature;
later calls can send values back to a suspended `yield`. A generator can
report whether it is running, completed, failed, or exhausted.

The runtime saves the execution state needed to resume each generator.
Ordinary calls keep direct access to interpreter state. The threaded
context layout has also been reordered to reduce the work in ordinary
subroutine calls.

See [perlgenerator](pod/perlgenerator.pod) and
[the generator pragma](lib/generator.pm) for the calling and lifecycle rules.

### Iterators

The experimental `iterator` package lets ordinary blessed code references
use the same calling and completion protocol as generators. An iterator
reports when it has finished, so callers can distinguish completion from a
valid empty result.

Iterators expose their running, completed, failed, and exhausted states.
They can also describe whether they support restarting. An uncaught
exception is rethrown without silently changing the iterator's state.

See [perliterator](pod/perliterator.pod) and
[the iterator package](lib/iterator.pm).

### Classes and roles

Roles let classes share fields, methods, field initializers, and `ADJUST`
blocks. A role can also require methods from its consumers. Classes and
other roles consume them with the experimental `:implements` attribute.

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

Roles can consume other roles. A role reached through several paths is
included once, and unresolved method or field conflicts are reported when
roles are composed. The `implements` method and operator test declared role
membership, including roles inherited from a superclass. `DOES` recognizes
these roles too.

#### Custom constructors

Every native class has a `CONSTRUCT` method that allocates an object,
initializes its fields, and runs `ADJUST`. By default, `new` is an alias for
it. A class can supply its own `new` to process arguments before calling
`CONSTRUCT`:

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

Each subclass gets its own default constructor unless it defines `new`.
Reusing a parent's custom constructor requires explicit forwarding. The
default constructor does not call conventional parent constructors.

#### Working with ordinary Perl objects

A modern class instance is an ordinary blessed reference with hidden field
storage. Calling `CONSTRUCT` on an existing object attaches fields without
changing its blessing, identity, or ordinary contents. This allows a
conventional parent constructor to create the object first.

Fields belong to the class that declares them. A subclass can explicitly
alias an unambiguous ancestor field with `:inherited`; `:private` prevents
such aliases. Other ancestor fields do not enter the subclass's lexical
scope automatically. The former `:blessed_self` attribute is removed.

`class_object_to_hash` and `class_object_from_hash` provide shallow views
for serializers. `Data::Dumper` uses them to preserve class fields, shared
references, and ordinary object contents in both its XS and pure-Perl
implementations. `TEARDOWN` releases class storage after ordinary `DESTROY`,
or before an object is reblessed into another package.

See [perlclass](pod/perlclass.pod) for roles, constructors, field ownership,
and serialization.

### Structured exceptions

Errors and warnings carry structured information: a stable diagnostic
identifier, typed arguments, source locations, and context. Their default
rendering preserves familiar Perl messages. Applications can inspect the
objects or request annotated text, JSON, or Dumper output.

A structured exception hook runs before the existing warning and die hooks.
A two-variable `catch` can retain both the compatibility value and the
structured exception. Annotated text and JSON can show the C source location
separately from the Perl location, which helps when investigating core
errors.

See [XPerl::Exception](lib/XPerl/Exception.pm) and
[XPerl::Diagnostic](lib/XPerl/Diagnostic.pm).

#### Translated diagnostics

Loadable language packs translate errors and warnings, with English as the
fallback. Programs can select a language for a lexical scope or at runtime.

Alongside English, translations are available in Arabic, Chinese
(Simplified), Dutch, Finnish, French, German, Hebrew, Hungarian, Icelandic,
Italian, Persian, Polish, Portuguese, Russian, Serbian, Spanish,
Turkish, Ukrainian, and Welsh.

Klingon is included separately as a constructed-language test case.

These languages exercise different plural rules, grammatical forms, word
orders, and writing systems. More languages are expected. The translations
are machine drafts awaiting review by native speakers.

See [diagpack](lib/diagpack.pm) for language selection and pack loading.

### Lexical namespaces

The experimental `namespaces` feature adds lexical namespace prefixes,
namespace aliases, and `__NAMESPACE__`.

```perl
use feature 'namespaces';

namespace MyApp;
package Model;

sub name { "model" }
```

Here `Model` means `MyApp::Model` while this code is compiled. The prefix is
lexical and does not replace Perl's ordinary current package. An explicit
`:::` boundary resolves a name from the top level. `CORE:::` provides access
to Perl's implementation namespace.

See [perlnamespace](pod/perlnamespace.pod).

### Dispatch/on matching

The experimental `dispatch_on` feature selects code according to a value's
shape. A `dispatch` evaluates its subject once and tries ordered `on`
clauses. The first match runs. `on (_)` provides a default clause; without
a match, the result is `undef` in scalar context or an empty list in list
context.

Patterns can describe literals, arrays, hashes, nested structures, class
objects, regular expressions, and numeric or reference criteria. Scalar
names capture values for use within a clause, while `^` pins an existing
value. An optional `if` guard runs after the shape matches.

Object patterns inspect structure without calling constructors or arbitrary
methods. Inheritance and role matching are reserved for future extensions.
This feature is independent of `given`/`when`.

See [the tutorial](pod/perldispatchontut.pod) for examples and
[the reference](pod/perldispatchon.pod) for pattern and binding rules.

### Multi subroutines and methods

The experimental `multisub` feature lets a named subroutine or method have
several clauses selected by argument patterns. Perl tries clauses in source
order and runs the first whose pattern and optional guard succeed. Guards
go inside the declaration's parentheses:

```perl
use feature 'multisub';
no warnings 'experimental::multisub';

multi sub magnitude($value if $value < 0) { -$value }
multi sub magnitude($value)               { $value }

print magnitude(-42), "\n"; # 42
```

The argument patterns use the same language as dispatch/on array patterns.
They are patterns rather than signatures: scalar captures receive copies,
while `@_` retains the original argument aliases. Clause bodies share the
public subroutine's identity, call context, and ordinary control flow.
`__SUB__`, when enabled, refers to that public dispatcher.

`multi method` also requires the `class` feature. Its method prologue binds
`$self` and fields before matching, and only explicit arguments participate
in the patterns or appear in `@_`. Inheritance and role composition treat
the completed group as one method rather than merging clause lists.

All clauses for a name must share an enclosing lexical scope and compilation
unit. Calling the group before that scope finishes compiling throws an
incomplete-group error. A call with no matching clause also throws an error.
Ordinary and multi declarations cannot share a name. No version bundle
enables this feature.

See [perlmultitut](pod/perlmultitut.pod) for a tutorial built on dispatch/on,
[perlsub](pod/perlsub.pod#multisubs) for declaration and call rules, and
[perlclass](pod/perlclass.pod#multi-method) for true methods. The shared
pattern language is defined in [perldispatchon](pod/perldispatchon.pod).

### Experimental features in one-liners

The `-E` switch enables `feature ':all'` and imports `builtin ':all'`. This
makes XPerl's experimental keywords and builtins available in one-liners.
Their normal experimental warnings apply. The behavior of `-e` is unchanged.

See [perlrun](pod/perlrun.pod).

### SipHash builtins

The experimental `builtin::siphash` computes SipHash with caller-selected
compression and finalization rounds. `builtin::siphash_1_3` and
`builtin::siphash_2_4` provide fixed variants.

Each accepts a byte string and an optional 16-byte key, and returns eight
little-endian bytes. The default key is the published test-vector key,
`00` through `0f`.

## Hash storage

### Compact entries and small hashes

Ordinary hashes keep their entries in a compact array. On 64-bit builds,
each entry occupies 16 bytes and has no collision-chain pointer. `HV` and
`XPVHV` retain their sizes.

Empty hashes allocate no entry storage. By default, hashes with up to eight
entries use a linear search. Larger hashes add an index. The experimental
`PERL_HASH_LINEAR_MAX` setting changes the promotion threshold; zero selects
indexed storage from the first key.

### Separate indexing algorithms

The default index uses integer chains: bucket heads and links contain
compact entry numbers instead of pointers. Open addressing is available
with `PERL_HASH_INDEX_OA`. Both algorithms use identifiers sized to their
storage needs, from one to four bytes.

The implementations live in `perl_hv_sc.[ch]` and `perl_hv_oa.[ch]`. The
build compiles only the selected backend into `hv.o`. Lookup, insertion,
deletion, reservation, resizing, and compaction belong to that backend.
`hv.c` handles Perl hash semantics, magic, tied hashes, and key/value
ownership.

Ordinary inserts with spare entry positions skip shrink checks. Shrinking
is considered during required growth or compaction.

`keys(%hash) = N` reserves room for N distinct key/value pairs.
`Hash::Util::reserve_buckets(\%hash, N)` reserves at least N buckets,
rounded up to a supported size. Both retain larger existing capacities.

`PERL_HASH_CHAIN_FINGERPRINT` optionally adds small hash fingerprints to the
chain index. They can avoid loading candidate keys during lookup, at the
cost of more index storage. Fingerprints are disabled by default and cannot
be combined with OA. Changing the indexing options requires a clean build.

Both backends grow storage as needed and can reclaim gaps left by deletions
during later insertions. Deleting an entry alone does not rebuild the hash.
The ordinary index supports at most 715,827,882 live keys. Requests beyond
that limit report a hash-capacity error.

Final destruction of ordinary hashes with plain scalar values can discard
the index and release entries directly. Hashes that need callback or
iterator handling use the general cleanup path.

The [design and benchmark report](Porting/hash-oa-design.pod) describes the
allocation, growth, and compaction rules. Performance depends on hash size
and workload. Large hashes benefit from compact traversal, while some
smaller indexed hashes take longer than `blead` for insertion and churn.

### An independent shared-key table

The interpreter shares key strings between hashes through `PL_strtab`.
This table now has its own C type, `PERL_HV_STRTAB`, and implementation in
`perl_hv_strtab.[ch]`. Ordinary hash operations no longer need special cases
for it.

The table uses separate chaining in every build. Final release unlinks the
key without leaving a tombstone. Shared key addresses remain stable while
referenced, even when the bucket array grows. It supports at most
1,431,655,765 distinct keys. Existing keys can acquire more references at
that limit, subject to reference-count overflow checks.

The string table has an explicit lifetime. Interpreter destruction frees
it after the last SV owners and interpreter constants release their keys.
Thread cloning creates an independent table and copies intentional pins
into it.

Hash::Util provides:

- `shared_key_refcount` to inspect a key's reference count.
- `shared_keys` to obtain copies of the shared key strings.
- `immortalize_key` to retain a key until interpreter destruction.

### Iteration and inspection

Iteration scans the entry array and does not promise insertion order.
Hash-function seeding remains enabled. Bucket-order perturbation,
`PERL_PERTURB_KEYS`, and `Hash::Util::hash_traversal_mask` are removed.
Insertion during iteration is detected through iterator state.

`Hash::Util::hash_storage_info` reports allocation sizes, capacities, entry
gaps, tombstones, and probe distances. Ordinary hash value and iteration
APIs do not apply to the shared-key table.

## Bundled distributions and tools

### Added CPAN distributions

These distributions are bundled in addition to those supplied by `blead`.
Each includes its supporting modules, documentation, and tests.

| Distribution | Purpose |
| --- | --- |
| `Cpanel::JSON::XS` | JSON encoding and decoding, including Boolean and type helpers |
| `DBI` | Database interface and supporting drivers |
| `DBD::SQLite` | SQLite driver for DBI, with constants and virtual-table helpers |
| `IO::Socket::SSL` | TLS sockets, with certificate and public-suffix helpers |
| `Net::SSLeay` | OpenSSL/LibreSSL bindings used by the TLS socket layer |
| `Perl::Tidy` | Perl source formatting |
| `TOML::Tiny` | TOML parsing and writing |
| `Text::CSV_XS` | CSV parsing and writing |
| `YAML::XS` | YAML parsing and writing through LibYAML |

### RNG

The experimental [RNG](dist/RNG/lib/RNG.pm) distribution provides selectable
random-number generators and reusable random distributions. `${^RNG}`
selects the provider used by `rand`, `srand`, and `builtin::rand_bytes`.
Localizing it lets a scope select a different provider. Each provider owns
its state; changing the selection does not copy or rewind that state.

Bundled providers include `RNG::Drand48`, `RNG::HMAC_DRBG`, `RNG::PCG`,
`RNG::Wyrand`, and `RNG::Xoshiro`. The PCG family includes
`RNG::PCG::RXS_M_XS_64_64`, `RNG::PCG::XSL_RR_128_64_LCG`, and
`RNG::PCG::XSL_RR_128_64_MCG`. `RNG::Provider`, `RNG::PCG::Variant`,
`RNG::Seed`, and `RNG::SeedBase` support provider and seed management.

### Tensor-XS

The p5-matrix-utils work is bundled as the experimental `Tensor-XS`
distribution. It provides `Tensor::XS` and the Perl `Tensor`, `Matrix`,
`Vector`, and `Scalar` classes backed by contiguous XS storage. `MNIST`
provides helpers for reading the MNIST dataset format.

The implementation supports integer and floating-point types, indexed
access, flat or nested input, bulk operations, and native access bridges.
Its numerical API and binary representation are experimental.

See [Changes](dist/Tensor-XS/Changes) and
[the XS design](dist/Tensor-XS/XS_DESIGN.md).

### XStats, XBench, and XGraph

These new distributions provide statistics, benchmarking, and graph tools:

| Distribution | Modules and purpose |
| --- | --- |
| [XStats](dist/XStats/lib/XStats.pm) | Statistics with retained observations or bounded summaries, plus resampling and probability functions |
| [XBench](dist/XBench/lib/XBench.pm) | Calibrated benchmarks with retained samples and confidence intervals, with results represented by `XBench::Result` |
| [XGraph](dist/XGraph/lib/XGraph.pm) | Compact directed graphs and graph algorithms, with DOT import/export through `XGraph::IO::DOT` |

The statistics modules are `XStats::Full`, `XStats::Sparse`, and
`XStats::Functions`. Construct statistics objects with `Full` or `Sparse`.

### New core modules

The language and diagnostic features also add these modules outside the
new distributions above:

| Modules | Purpose |
| --- | --- |
| `generator`, `iterator` | Generator syntax and the callable iterator protocol |
| `dispatch::Predicates` | Standard predicates for dispatch/on patterns |
| `XPerl::Exception`, `XPerl::Diagnostic`, `XPerl::DiagGroup` | Structured exceptions, individual diagnostics, and diagnostic groups |
| `XPerl::Diagnostic::Catalog` | Experimental module-owned diagnostic definitions |
| `diagpack`, `XPerl::DiagPack` | Diagnostic language selection and pack loading |
| `XPerl::REPL` | Interactive shell, supported by `XPerl::REPL::Commands`, `Complete`, `Config`, `Evaluator`, `Input`, and `Render` |

Each diagnostic language pack has its own `XPerl::DiagPack::*` extension.
The bundled suffixes are `AR`, `CY`, `DE`, `EN`, `ES`, `FA`, `FI`, `FR`,
`HE`, `HU`, `IS`, `IT`, `NL`, `PL`, `PT`, `RU`, `SR`, `TR`, `UK`, and `ZH`.
The English pack is included alongside the translations. The special-case
Klingon pack uses `TLH`.

### Interactive shell

`xperl-repl` starts an interactive Perl shell. It keeps lexical variables,
the current package, and compile-time hints between inputs. It recognizes
incomplete input through the parser's structured diagnostics, so expressions
can span several lines.

On Unix-like terminals, the bundled `Term::ReadLine::XPerl` extension provides
history, prefix search, tab completion, key bindings, and UTF-8 editing
without an external library. Other systems use the `Term::ReadLine` stub.

The engine is [XPerl::REPL](lib/XPerl/REPL.pm), with supporting code under
`lib/XPerl/REPL/`. The command-line utility is built from
`utils/xperl-repl.PL`.

### Added command-line utilities

Alongside `xperl-repl`, the core utility list adds `xbench` for benchmarking,
and `perltidy` and `perltidy-auto` for formatting Perl source. The JSON
distribution also supplies `cpanel_json_xs`.

### Changes to existing modules

`Data::Dumper` supports modern class objects and adds opt-in `Useutf8` and
`PreserveUnicode` settings for Unicode output and round trips. `Storable`
requires explicit freeze/thaw hooks for modern class objects, so their
hidden fields cannot be silently discarded. `Carp` and the small Test2
warning helper adapt structured exceptions to their text-based interfaces.

`Hash::Util` adds the storage and shared-key inspection described above.
`UNIVERSAL` and `mro` support role membership. `B`, `B::Deparse`, and
`Opcode` account for the new language operations. `builtin`, `feature`,
and `warnings` expose the matching runtime interfaces and feature metadata.
`attributes` adjusts diagnostic wording. `threads`, `DynaLoader`, and
`XS::APItest` are adapted to the runtime and extension changes.

`utf8::repeat_decode` removes repeated UTF-8 encoding from input known to
have that problem. It modifies the input in place and can force a final
UTF-8 representation. It does not guess the intended encoding of arbitrary
text. See [utf8](lib/utf8.pm).

## Build and platform integration

The source changes include the matching generated parser, keywords,
opcodes, headers, and documentation indexes. The relevant Windows, VMS, and
other platform build files are updated alongside them. Generated files need
to be regenerated when their inputs change.

## Compatibility

The language features and runtime interfaces are experimental and may
change. Existing Perl behavior is preserved where practical, including when
features are disabled.

C and XS extensions can identify XPerl with `#ifdef XPERL` after including
`perl.h`. `XPERL` is an alias for `XPERL_VERSION`, currently `1`.

The hash representation changes the XS ABI. Extensions must be rebuilt,
and code that accesses hash internals needs the following changes:

- Use `PERL_HV_INDEX` and `HvINDEX` in place of `struct hv_oa` and `HvOA`.
  The `HvIS_OA` and `HvIS_STRTAB` predicates are removed.
- Replace uses of `HeNEXT` and `HeSHARED_NEXT`. These macros are removed.
- Use explicit setters when changing `HvMAX`; do not write `xhv_max`
  directly.
- Reacquire `HE *` and `SV **` pointers after operations that relocate or
  compact entries. Dense-array deletion can also invalidate them.
- Treat `PL_strtab` as an independent C table. It cannot be cast to an SV
  or HV, passed to generic hash APIs, or managed with SV reference counts.

The string table uses `Perl_hv_strtab_new` and `Perl_hv_strtab_free` for its
lifetime. Shared-key acquisition and release through `share_hek` and
`unshare_hek` are preserved.

See [perlguts](pod/perlguts.pod) and
[the hash design report](Porting/hash-oa-design.pod) for the internal API and
pointer-lifetime rules.
