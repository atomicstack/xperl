# Type Syntax for Perl

Source: [Claude public artifact](https://claude.ai/public/artifacts/ded72e63-3cf7-4681-8485-9eb390743b04)

**Status:** Experimental specification. Targets the `xperl` fork and the Chalk compiler. Not currently proposed to perl5-porters.

**Baseline:** Perl 5.42 and 5.44. Both are under full support as of this writing (5.44.0 released 2026-07-15; 5.40 went security-only on the same date). Claims about existing behaviour are stated against both, and divergences between them are noted where they bear on the syntax.

Supersedes the separate *Type Annotation Syntax* and *Named Type Declarations* drafts.

---

## 1. Abstract

This specifies a syntax for writing types in Perl: where an annotation may appear, how type expressions are formed, and how named types are declared.

It is an extension of the latent type system formalised in *Formal Definition of Perl's Latent Dynamic Type System*, which establishes that Perl already has a type lattice with a subtyping relation and operational contracts, computed on every operation and impossible to write down. Most of what follows is therefore notation for something that exists. The exception is nominal types (§8.3), identified as such.

It is a syntax proposal. It says what a type annotation *asserts*, because syntax with no assertion is meaningless, but it does not say when an assertion is checked, by what mechanism, or with what consequence. Those are implementation concerns and are excluded deliberately.

Three positions are specified: after a variable declarator, before a signature parameter, and after a signature. One declaration keyword is added: `type`.

---

## 2. Scope: three layers

Most previous attempts to add types to Perl failed by trying to settle everything at once. This proposal separates three questions and answers only the first two.

| Layer | Question | Status here |
|---|---|---|
| **Syntax** | Where may a type be written, and how is it spelled? | Specified |
| **Meaning** | What does writing one assert? | Specified minimally — see §8 |
| **Detection** | When is a violated assertion caught, and by what? | **Out of scope** |

The third layer is where the hard disagreements live: runtime cost, coercion, what happens to `$count += "19 apples"`. Excluding it is not evasion. It is what allows a compiler and an interpreter to conform to the same language while differing enormously in what they catch.

This separation is also the point. Perl the language has no opinion about these matters; perl the interpreter has opinions that are artefacts of its implementation. A specification that describes when checks happen has baked an implementation into a language.

---

## 3. Relationship to the latent type system

*Formal Definition of Perl's Latent Dynamic Type System* (pvm.tools/papers/perl-types-formal.html) characterises the type system Perl already has: latent, dynamic, and unwritten. Its Future Work section names "design optional type annotation system for Perl" as a listed extension. This document is that item, not a departure from it.

### 3.1 What the paper establishes

**Membership has a two-part criterion.** A value belongs to type T if it satisfies *syntactic preservation* — interpreting it through T and converting to some reference type S yields the same result as converting directly to S — and *semantic fulfilment* — it satisfies the contracts of every operation in Operations(T). Both are required. `"NaN"` survives the round trip but violates reflexivity under `==`, so it is not a Num. `"hello"` fails the round trip outright.

**The scalar chain is `Int <: Num <: Str <: Scalar`.** This is the paper's central structural result, proved as three lemmas. `Str` sits between `Num` and `Scalar`: every Num survives stringification, but not every Str survives numification. References stringify but do not round-trip back, so references are not in `Str` despite being stringifiable.

**The hierarchy:**

```
Unknown / Any (⊤ = V)
├── Scalar
│   ├── Undef
│   ├── Boolean
│   ├── Str ── Num ── Int
│   ├── DualVar          (in Scalar, in neither Str nor Num)
│   └── Ref
│       └── Object, ScalarRef, ArrayRef, HashRef, CodeRef, GlobRef
├── List
│   └── Array, Hash
├── Code
├── Glob
└── None (⊥ = ∅)
```

`List` is a separate branch, not a scalar type. `Code` and `Glob` are further top-level branches.

**`Unknown` and `Any` are distinct.** They contain the same values and differ in tooling semantics: `Unknown` is the default for unanalysed expressions and signals a checker to infer; `Any` is an explicit polymorphic annotation and signals a checker to accept without inference.

**`Scalar` is concrete, not a union.** A dualvar belongs to `Scalar` and to neither `Str` nor `Num`, because it fails syntactic preservation in both directions. That is what proves `Scalar` has membership criteria of its own.

**Native class objects are opaque.** `ClassObject <: Object <: Ref`, and cannot be dereferenced as their storage type. Blessed references are intersections: `BlessedHashRef = Object ∩ HashRef`.

**`Boolean` is the two-element primitive `{true, false}`.** The published paper leaves its status open, on the grounds that if `is_bool()` counts as an operation on Boolean then "no coercion produces values satisfying all Boolean operations," making Boolean an exception to the formalism.

Testing against perl 5.38 indicates the premise no longer holds and that no exception is needed:

- **`!!` is a total coercion to Boolean**, producing `is_bool`-satisfying values for every input including `undef`. The paper treats this as speculative future evolution; it is present behaviour in 5.36+.
- **Under `∃S` syntactic preservation with `C = !!`**, Boolean admits `{1, 0, '', undef, true, false}`. Under `is_bool` it admits `{true, false}`.
- **The gap is exactly the `"NaN"` pattern.** `1` passes syntactic preservation and fails semantic fulfilment, so `1 ∉ Boolean` falls out of the two-component definition unaided. Boolean is not an exception; it is a second worked instance of the mechanism the paper already relies on.
- `is_bool` therefore **narrows** the type rather than contradicting the model: Boolean-by-preservation is a proper superset of Boolean-by-`is_bool`.

An incidental correction: the paper's Historical Context gives the pre-5.36 coercion-based Boolean as `{1, 0, '', undef}`. That holds only under `∃S`. With `S = Str` alone, `0` fails — `!!0` stringifies to `''` while `0` stringifies to `'0'` — and it is `S = Num` that admits it. A concrete case where the existential quantifier does real work rather than offering convenience.

*Practical consequence for annotations.* `Bool` is genuinely the two-element type, so `my Bool $flag = 1;` asserts something false. This is less restrictive than it sounds, since comparison, equality, `defined`, `!`, and `!!` all yield real booleans, and booleanness survives copying, subroutine return, and storage in arrays and hashes:

```perl
my Bool $ok   = $x > 5;          # holds
my Bool $seen = defined $y;      # holds
my Bool $flag = 1;               # erroneous — 1 is Int
my Bool $both = $a && $b;        # erroneous — && returns an operand
my Bool $both = !!($a && $b);    # holds
```

The traps are bare literals and `&&`/`||` over non-boolean operands, since those operators return one of their arguments rather than a truth value. Note that `$a > 1 && $b > 1` does hold, because the operand returned is itself a comparison result.

*(Tested on 5.38.2, below this document's 5.42/5.44 baseline. `is_bool` dates to 5.36, so the behaviour should carry, but it is worth re-running.)*

**The formalism is descriptive, not enforcing.** From its Note on Enforcement: the types describe what values *should* be used with which operations for semantically meaningful results, not what Perl prevents.

### 3.2 What this document adds

**Notation, mostly.** Perl computes these memberships on every operation and offers no way to write one down. The primitive vocabulary in §6 is therefore cited rather than proposed — the largest bikeshed in this space is settled by the paper's analysis rather than by design argument.

**Nominal brands are the one genuine extension.** The paper characterises Perl's latent types as structural plus behavioural, explicitly contrasting both with Cardelli's nominal typing. Nothing in latent Perl distinguishes a `Celsius` from a `Num`, because membership never depends on what was declared. §8.3 adds that, to make the Celsius/Fahrenheit case work. Given that `type N as P;` is legal and preserves P's representation, a brand is the only thing that can distinguish N from P — but both premises are choices, and §8.1 records them as such.

**Refinement is layered, not the same mechanism.** The paper is explicit that its semantic contracts "don't refine types, they define them." A `where` block (§8.2) refines an already-defined type, which is the Typed Racket relationship the paper distinguishes itself from. The two should not be conflated.

**Absent and explicit annotations differ.** Following §3.1, an unannotated binding is `Unknown` and an explicitly annotated `Any` is `Any`. A consumer should infer in the first case and not in the second.

**Version scope.** The paper applies to 5.36+ with coercion rules reflecting 5.38 behaviour. This document's 5.42/5.44 baseline is narrower, which is a strengthening rather than a conflict.

### 3.3 Inherited framing

§9's separation of a program error from its detection is not novel here; it restates the paper's Note on Enforcement at the level of a single feature. The paper's Future Work also names gradual typing, connecting `Unknown`/`Any` to Siek and Taha's dynamic type and placing runtime checks at type boundaries — which is where §9.1's checked-boundary constraint comes from.

## 4. Motivation

Perl already has a type slot:

```
my VARLIST
my TYPE VARLIST
my VARLIST : ATTRS
my TYPE VARLIST : ATTRS
```

`perldoc -f my` records that TYPE "is currently bound to the use of the fields pragma" and that its semantics "are still evolving." It is a vestige of pseudohashes and is used by almost nobody.

Meanwhile every serious attempt to write type information in Perl — Type::Tiny, Moose constraints, `sealed.pm`, Devel::TypeCheck, Perl::Critic policies, IDE conventions like `#@type` — has invented a private carrier, because the language offers no place to write it down where the parser can see it. The information exists; it is fragmented across a dozen mutually unintelligible dialects and invisible to every tool but the one that defined it.

Python resolved the same impasse by specifying annotation syntax and storage while explicitly declining to specify semantics (PEP 3107, PEP 526). Every typed-Python tool exists because of that decision. This proposal makes the same move, with one addition: Perl needs a way to name types, which Python got from its existing class system and Perl cannot, because classes and roles do not cover the cases that matter most.

---

## 5. Feature gate

```perl
use feature 'types';
```

All syntax below is enabled only under this feature. Outside it, current behaviour is unchanged, including the existing `fields`-bound meaning of the type slot. `types` requires `signatures` to be in effect, since two of the three annotation positions are defined in terms of a signature.

---

## 6. Type expressions

```
TypeExpression  ::= TypeName
                  | TypeName '[' Constraints ']'

Constraints     ::= Constraint ( ',' Constraint )*

Constraint      ::= TypeExpression
                  | Expression

TypeName        ::= identifier ( '::' identifier )*
```

`identifier` is not stable across the baseline. Perl 5.44 enforces Unicode 17 `XID_Start`/`XID_Continue` for identifiers, rejecting roughly 160 characters that 5.42 accepted through Perl's broader `\w` interpretation. `TypeName` therefore denotes a smaller set in 5.44 than in 5.42. This is a lexical specification decision rather than anything to do with the latent type system, and this document follows whichever definition the host perl uses rather than fixing one.

### 6.1 Brackets bind `$_`

`T[...]` binds `$_` to the value positions the constructor `T` defines, and the bracket contents constrain it.

```perl
Array[Int]                  # every element satisfies Int
Array[$_ > 0]               # every element is positive
Array[Int[$_ > 0]]          # both — inner $_ shadows
Hash[Str, Int]              # keys satisfy Str, values satisfy Int
Int[0 < $_ < 20]            # the value itself, in range
```

A bare `TypeExpression` in constraint position is a membership test on `$_`, so `Array[Int]` and `Array[$_ isa Int]` express the same thing. This is what makes the two apparent categories one category: the bracket always contains a constraint, and a type name is a constraint.

Chained comparisons work as written — `0 < $_ < 20` means `0 < $_ && $_ < 20` with the middle evaluated once, as of Perl 5.32. Note that relational and equality operators sit at different precedence levels and do **not** chain with each other, so `Int[0 <= $_ != 13]` does not mean what it appears to.

Each constructor defines its arity and what each position binds. For a scalar type the single position is the value itself. Constraints are positional.

The constraint may refer only to `$_`. Closing over a lexical would make two textually identical annotations denote different types, destroying the property that structural types need no coordination between authors (§7.3).

`[OPEN]` Function types cannot use this model. `Code[(A, B) -> R]` has no value to bind `$_` to — a coderef's parameter types are not observable by inspecting it. Function types would have to be checked at call sites rather than by examining a value, which is a different mechanism, and are not specified here.

`[OPEN]` A bare identifier in constraint position must be distinguished from a bareword expression. This is decidable but requires the parser to know whether the identifier names a type. Free in an Earley parser; awkward in perl's LALR grammar.

---

### 6.2 Measures — contingent

**Not specified. Recorded because it constrains a decision that must be made first.**

If brands carry integer exponents over base units (§8.3), the arithmetic belongs **inside the brackets**, attached to a numeric type, rather than at the top level of a type expression. This is F#'s design:

```fsharp
[<Measure>] type m
[<Measure>] type s
[<Measure>] type N = kg m / s^2      // derived measure
let v : float<m/s> = 3.1<m/s>
```

Transposed:

```
Measure     ::= MeasureAtom
              | Measure Measure                  -- implicit product
              | Measure '*' Measure
              | Measure '/' Measure
              | Measure '^' Integer
MeasureAtom ::= TypeName | '(' Measure ')'
```

```perl
unit Metre;
unit Second;
unit Newton = Kilogram Metre / Second^2;

my Num[Metre/Second] $velocity = 12;
my Num[Metre/Second^2] $accel  = 9.81;
sub kinetic (Num[Kilogram] $m, Num[Metre/Second] $v) Num[Newton Metre] { ... }
```

Putting the formula inside brackets avoids the lexer hazard that a top-level infix form would create: `/` after a bareword is the most context-sensitive sequence in perl's tokenizer, and `^` is xor. Inside a delimited measure sublanguage neither collides with anything, which is why F# can use `^` where this document would otherwise have needed `**`.

Three things to settle before adopting it:

1. **Is a measure a type?** F# says no — measures are declared by a separate mechanism and the language specification states they "differ from types in several important ways." You cannot write `let x : m`, only `float<m>`. That conflicts with §8.3 as written, where `type Metre as Num;` produces an ordinary brand usable bare as `my Metre $x`. The bracketed form only coheres if a measure is a *modifier on a numeric type* rather than a type in its own right, which argues for a distinct `unit` declaration rather than reusing `type`.
2. **Derived measures need a declaration form.** `unit Newton = Kilogram Metre / Second^2;` — F# has this alongside inline composites, and it is how Newtons and Pascals get names.
3. **Implicit product by juxtaposition** (`Kilogram Metre / Second^2`) reads well and is what F# uses. Whether two adjacent barewords should multiply inside a bracket is a tokenizer question, not a grammar one.

Dimensionless results reduce to the erasure: `Num[Metre/Metre]` is `Num`, the group identity.

## 7. Annotation positions

Two lexical contexts. The tokenizer needs to recognise a type expression after a variable declarator, and within a signature.

### 7.1 After a variable declarator

```
my    TypeExpression? VARLIST ATTRS?
our   TypeExpression? VARLIST ATTRS?
state TypeExpression? VARLIST ATTRS?
local TypeExpression? LVALUE
field TypeExpression? VARIABLE ATTRS?
```

```perl
my Int $count;
my Array[Int] @items;
our Registry::Handle $registry;
state Hash[Str, Int] %cache;
field Logger $log :param;
```

A single annotation applies to a list declaration as a whole: `my Int ($x, $y);` annotates both. Per-element annotation is not proposed.

`local` is included for uniformity. It declares no storage, so the annotation attaches to the localisation; this is harmless given §8.

`sub` and `method` are **not** in this position — see §7.2 and §11.2.

### 7.2 Within a signature

The return type is part of the signature, not a separate element following it. This keeps the proposal at two lexical contexts rather than three: signature parsing owns the return type, so the tokenizer enters type-reading state once, on `(`.

```
Signature ::= '(' Parameters? ')' TypeExpression?

Parameter ::= TypeExpression? SIGIL IDENTIFIER ( '=' EXPR )?
            | TypeExpression? ':' SIGIL IDENTIFIER ( '=' EXPR )?
            | TypeExpression? SLURPY
```

The second alternative covers the named parameters added in 5.44 (`sub foo (:$alpha, :$beta)`), placing the type in the same position as for a positional parameter:

```perl
sub connect (Str $host, Int :$port = 5432, Bool :$tls = false) { ... }
```

`[OPEN]` This placement is the obvious one but has not been argued. Named parameters postdate every prior discussion of types in Perl, so there is no prior art to defer to.

```perl
sub distance (Num $x, Num $y) Num { ... }
sub tokenize (Str $src) Array[Token] { ... }
sub foo :lvalue ($x) Int { ... }
method fetch (Int $id) Maybe[Record] { ... }

my $parse = sub (Str $in) Node { ... };     # anonymous
sub forward ($x) Int;                       # forward declaration
```

Attributes keep their existing position before the signature, so no ordering rule between attributes and the return type is needed.

A type in parameter position requires a following variable: `sub f (Int)` is a syntax error, not an anonymous typed parameter, and must not be confused with a prototype.

**A signature is required for a return annotation.** `sub foo Int { ... }` is a syntax error; write `sub foo () Int { ... }` or `sub foo (@) Int { ... }`. A return type without a signature is half a signature, with nothing to belong to.

`[OPEN]` What a return annotation on a generator (`gen` under xperl) describes — the generator object or the yielded values. `Gen[Int]` composes with §6 and is the more honest reading; disallowing it initially is cheaper.

---

## 8. Type declarations

```
TypeDeclaration ::= 'type' TypeName TypeParameters?
                    ( 'as' TypeExpression )?
                    ( 'where' BLOCK )?
                    ';'

TypeParameters  ::= '[' TypeName ( ',' TypeName )* ']'
```

At least one of `as` or `where` must appear. With `as` omitted the parent is `Any`.

A class, a role, and a type are three different things, and a language with the first two still needs the third:

| | Provides | Instances | Membership |
|---|---|---|---|
| `class` | constructor, state, identity | yes | `isa` |
| `role` | behavioural contract | no | `DOES` |
| `type` | a distinct name over a representation, optionally refined | no | brand, or membership function |

A class induces a type and a role induces a type, but `PositiveInt`, `NonEmptyStr`, and `Probability` have no constructor and no method contract. All three declare into one namespace; `class Foo`, `role Foo`, and `type Foo` in one scope is a redeclaration error, and class and role names are usable in type position.

### 8.1 The predicate decides membership; its absence introduces a brand

The presence of `where` is not merely the presence of a check. It decides how membership is determined — and the two cases are not peers.

**With a predicate, nothing is added to the language.** `type N as P where {χ}` names the subset of P satisfying χ. Membership is decided by the value, by a criterion of the same kind the latent formalism already applies to primitives. The type existed; it had no name. This is notation.

**Without a predicate, only a brand can distinguish the type.** `type N as P;` supplies no membership function, so nothing about a *value* can decide whether it belongs to N rather than merely to P. The declaration itself is the only remaining source of information, which makes N nominal.

This is a conditional result, not an absolute one. It holds given two premises, both of which this proposal adopts deliberately:

1. **`type N as P;` is legal**, rather than requiring a `where` clause (§11.6).
2. **N preserves P's representation**, rather than becoming a distinct value such as a blessed scalar (§11.7).

Granted those, nominal typing is forced rather than chosen — the formalism's membership criterion is entirely value-based, and representation preservation is precisely what denies it anything to inspect.

The motivating case is Celsius and Fahrenheit (§8.3). It requires both premises: a distinction with no predicate to express it, over values that must stay ordinary numbers. Brands are what make that example work, and it is the reason this proposal introduces a distinction Perl does not already draw (§3.2).

| | Membership by | Adds to the language | Cost |
|---|---|---|---|
| `type N as P where {χ};` | **the value** — anything satisfying χ | nothing; notation | a call to χ |
| `type N as P;` | **declaration** — the value carries the brand | a new distinction | none; static |

A structural type asks only what a value is. A nominal type asks where it came from — a question latent Perl has no way to pose.

The mixed case is inheritance rather than a third discipline: `type PositiveCelsius as Celsius where { $_ > 0 }` requires the Celsius brand *and* satisfies χ, because the brand arrives through the parent chain while the predicate refines its extension.

The two are presented below in that order: the notation first, then the extension.

### 8.2 `where` names a type that already exists

The block is the characteristic function of a set: anything satisfying it is a member, regardless of how the value was produced.

Note that this is *not* the same mechanism as the paper's semantic contracts, which "don't refine types, they define them." A `where` block refines a type already defined by the latent criterion — the Typed Racket relationship the paper distinguishes itself from. Refinement is layered on top of the formalism, not an instance of it.

**Membership is a subset of the parent's extension.** Membership in `Probability` is membership in `Num` conjoined with χ. Subtyping between two structural types is therefore not computable — showing every `Probability` is a `UnitInterval` means proving χ₁ ⇒ χ₂ — which is why only the declared parent chain gives a usable relation, and why erasure is the part a compiler can act on.

**The function is partial**, defined on the parent's extension. The parent test runs first and χ may assume it, which is what permits `where { 0 <= $_ && $_ <= 1 }` with no `looks_like_number` guard.

**Nested declarations conjoin, parent-first.** Each function may assume every function above it has succeeded.

**The function must be pure** — deterministic, free of externally observable side effects, total on the parent's extension, terminating. `$_` is read-only within it. Perl cannot enforce this; violating it makes consumers' behaviour undefined.

The requirement is not pedantry. It is what permits an implementation to check once and cache, rather than re-check at every use. If χ may observe mutable state outside the value, no implementation may ever elide, reorder, or skip a check.

**Structural types need no coordination.** Two modules independently declaring `type Positive as Num where { $_ > 0 }` produce interoperable types, since membership is decided by χ and not by identity. The same two modules independently declaring `type Celsius as Num;` produce *incompatible* types — correctly, since neither said what makes a value a Celsius.

### 8.3 `as` alone introduces a brand

**This is the proposal's one genuine extension to the latent system.** The paper characterises Perl's latent types as structural plus behavioural, explicitly contrasting both with nominal typing in Cardelli's sense. Nothing in latent Perl distinguishes a `Celsius` from a `Num`: membership is about what a value *is*, never about what was declared of it. A brand is about where a value came from, and that information does not exist until a declaration creates it.

`type Name as Parent;` does not create an alias. It creates a distinct type with the parent's representation, not interchangeable with the parent or with siblings. This is Haskell's `newtype`, Ada's derived types, Go's type definitions.

```perl
type Celsius    as Num;
type Fahrenheit as Num;

my Celsius    $inside  = 21;
my Fahrenheit $outside = 70;
my Num $mean = ($inside + $outside) / 2;    # erroneous
```

Under an alias reading both are `Num` and nothing is caught.

The example is Ovid's, from "Data Types in Perl" (2022), and it is the reason this proposal admits brands at all. Every prior discussion of types in Perl reaches for some version of it, and none of them work without nominal `as`.

A purely multiplicative case behaves better under any later dimensional extension, and is worth stating alongside it:

```perl
type Metre as Num;
type Foot  as Num;

my Metre $altitude  = 125;
my Foot  $clearance = 400;
my Num $margin = $altitude - $clearance;    # erroneous
```

Frink was written after the Mars Climate Orbiter for exactly this class of error. Temperature is the harder case: Celsius and Fahrenheit are affine rather than multiplicative, and units-of-measure systems handle affine units poorly (see the open issue below).

**Brands are static.** A nominal type changes no representation — `Celsius` is stored exactly as `Num`, and `erase(Celsius)` is `Num`. The brand exists only in the annotation. A static consumer can enforce it at zero cost; an implementation that ignores brands entirely is not wrong, merely less helpful, because nothing about a value's behaviour depends on one.

This makes `as` and `where` different in kind, not merely in slot: `as` is compile-time-only, `where` is inherently a runtime obligation.

**Construction.** Rather than introduce cast syntax, ascription is by assignment under one rule:

> A nominal type accepts values of its erasure carrying **no other brand**, and rejects values carrying a **different** brand.

```perl
my Celsius $a = 21;             # ok — literal is unbranded
my Celsius $b = $some_num;      # ok — unbranded
my Celsius $c = $fahrenheit;    # erroneous — different brand
```

**Subtyping.** Brands form a tree, since a nominal type may derive from another. A tree expresses derivation and cannot express composition; measures (§6.2) supply the latter as a separate mechanism. Subtyping is one-way up the chain: a `BodyTemp` is usable as a `Celsius`, not the reverse. Equal erasure is therefore *not* sufficient for compatibility — `Celsius` and `Num` erase alike and are not interchangeable — so a subtype test is equal erasure **and** ancestor in the brand chain. Both are constant-time bitset tests.

**Brands and measures are separate mechanisms.** An earlier draft treated the brand tree and dimensioned units as competing models of one feature. They are not: they are different algebraic structures answering different questions, and neither subsumes the other.

| | brand tree (§8.3) | measure group (§6.2) |
|---|---|---|
| `Celsius ≠ Fahrenheit` | yes | yes |
| `BodyTemp <: Celsius` | yes | no — measures do not specialise |
| `Metre * Metre = Metre^2` | no | yes |
| `Newton = Kilogram Metre / Second^2` | no | yes |
| brand space | finite, declared | infinite, generated |
| check | bitset ancestor, constant time | exponent-vector equality |

A tree expresses derivation and cannot compose; a group composes and cannot specialise. This proposal admits both, which is also why F# keeps measures a separate kind from types.

One consequence worth noting: as distinct base measures, `Num[Celsius]` and `Num[Fahrenheit]` are simply incompatible, and conversion is an explicit function. The affine-units problem that afflicts dimensional systems only arises if automatic conversion between them is wanted, and it is not.

`[OPEN]` **Brand propagation through operators**, for tree brands specifically. `$celsius + $celsius` could yield `Celsius` or `Num`; `$celsius * 2` probably stays `Celsius`. Measures answer this by construction — exponent vectors add under multiplication — but tree brands have no such algebra, and a rule is still needed. Blocking for arithmetic on non-measure nominal types.

### 8.4 Parametric declarations

```perl
type Pair[A, B] as Array where { $_->@* == 2 };
type NonEmpty[T] as Array[T] where { $_->@* > 0 };
```

Parameters are in scope within `as` and `where`. Without this there is a cliff between builtin parametrics such as `Array[Int]` and user declarations stuck at arity zero.

`[OPEN]` Whether a membership function can inspect its type parameters at runtime. The conservative answer is that it cannot, and parameters exist for `as` and for static consumers.

### 8.5 Scoping: lexical name, global identity

Classes and roles do not solve this problem, they avoid it: `class Foo { }` declares a package, universally visible. That is the namespace pollution a type vocabulary should not require — thirty type names in a scope should not mean thirty package symbols.

**The name is lexical.** The precedent is `builtin`, which has installed lexically-scoped names since 5.36:

```perl
use Units qw( Celsius Fahrenheit Kelvin );
my Celsius $inside = 21;
```

Exporter-style export is glob copying and therefore package-global; it is the wrong model. Lexical subroutines have the right scoping but no cross-module story.

**The identity is global.** A brand must be one thing: two modules importing `Celsius` from `Units` must receive the *same* brand, not two bindings that share a spelling. A lexical binding refers to a single entity, exactly as `use builtin 'true'` binds a name to the one canonical `true`. The entity's designator is the declaring namespace plus the name, and is usable directly:

```perl
package Units;
type Celsius as Num;            # entity: Units::Celsius

# elsewhere
my Units::Celsius $t = 21;      # no import
```

**Brand equality is entity identity, never name comparison.**

`[OPEN]` Whether an annotation records the name as written or the resolved designator. A lexically bound name is meaningless without its scope, so resolved designators are probably correct — but that means the parser resolves, which is a departure from recording syntax inertly.

---

## 9. What an annotation asserts

An annotation asserts that the value bound at that point is a member of the named type, in the sense of membership defined by the latent formalism (§3.1).

An *absent* annotation is `Unknown`: a consumer should attempt inference. An *explicit* `Any` is `Any`: a consumer should accept without inference. These denote the same values and differ in what they ask a tool to do.

Violating the assertion is a **program error**. This restates the paper's Note on Enforcement — the formalism describes what values *should* be used with which operations, not what Perl prevents — at the level of a single feature. The language does not specify when, whether, or by what mechanism the error is detected. An implementation that catches it statically, one that checks at runtime, and one that never notices are all conforming; detection is quality of implementation.

This dissolves what looks like a fork between "advisory" and "enforced" semantics. They are points on an enforcement spectrum over one semantics, not rival answers. It likewise makes the question of whether a type attaches to a variable, a value, or an SSA definition an implementation concern — it determines what a given implementation can catch, not what the annotation means.

### 9.1 Erroneous, not undefined

Separating an error from its detection is one step from undefined behaviour, and the specification must say which it means, because an optimizer's licence depends on it.

**Undefined** would permit an implementation to assume annotations hold. A compiler unboxing `Array[Int]` into an integer buffer on the strength of an annotation alone turns a violated annotation into memory corruption rather than a wrong answer.

**Erroneous but bounded** is specified. A violation is a program error; implementations may diagnose it anywhere or not at all; behaviour remains memory-safe regardless. An optimizer may assume an annotation **only where it has verified it, or inserted a check where unverified data entered.**

That constraint is what makes representation-changing optimisation safe without making the language unsafe.

### 9.2 Mutation

Membership is asserted at binding. Mutation can invalidate it without any assignment to the annotated binding:

```perl
my NonEmpty[Int] @xs = (1);
pop @xs;                        # now empty
```

Under §9 this is a program error, and whether anything notices is an implementation matter. An SSA-based compiler can catch it — the mutation produces a new definition whose type is `Array[Int]`, not `NonEmpty[Int]`. An interpreter would need to check every mutation. Neither is required.

The same reasoning covers container variance, which is the same phenomenon: passing an `Array[Int]` where `Array[Num]` is expected and having the callee store a float is erroneous, and an implementation may detect it, widen the caller's type after the call, or permit it.

Note that this affects `where` only. A brand cannot be invalidated by mutation, since it does not depend on the value.

---

## 10. Backwards compatibility

**The signature positions are strictly additive.** `sub f (Int $x)` is a syntax error in every released perl, as is a bareword between a signature's closing parenthesis and the block. Nothing that parses today reaches either.

**No currently-valid subroutine declaration changes meaning.** This is the benefit of putting the return type after the signature rather than after `sub`: `sub Int { ... }` keeps its meaning as a subroutine named `Int`, and no lookahead rule is needed to preserve it.

**The declarator position has one collision, resolved by the feature gate.** `my Dog $spot` parses today and interacts with `fields`; that is unchanged unless `use feature 'types'` is in scope. Code combining `use fields` with the new feature does not currently exist. Bracketed forms are a syntax error today regardless.

**`type` as a keyword** shadows subroutines named `type` in statement position under the feature. Standard for a gated keyword; `class` has the same property.

**Static tooling** — PPI, Perl::Critic, highlighters — will not recognise the syntax until updated.

`[OPEN]` Whether current perl accepts a bareword in `field Foo $x` and in `local Foo $x`. Both are one-line tests and determine whether those forms are additive or gated.

---

## 11. Rejected

### 11.1 Attribute syntax — `my $x :type(Array[Int])`

The KIM form Conway proposed for Corinna and Ovid adopted, on the grounds that reusing the type slot risks breaking `fields`-using code. Rejected because:

1. **It does not unify.** It needs `:type()` for variables, `:returns()` for subs, and — by Ovid's own account — prefix position or a parser complication for parameters. Prefix-plus-signature is one rule per context with no interaction.
2. **Attribute arguments are opaque strings today.** Parsing one as a type expression is the same core change as prefix position, with an extra layer. (`:prototype` is precedent that core will do this, so this objection is weaker than it looks.)
3. **The compatibility argument dissolves** under a feature gate, and under lexical namespaces the namespace-pollution motivation dissolves too.

This remains the decision most worth settling in public. The attribute form has momentum; the prefix form has better ergonomics.

Note that the position argued against here was stated in 2022, and three of its premises have since changed: `:prototype` establishes that core will parse an attribute argument rather than capture it as text, the feature gate resolves the `fields` collision, and lexical namespaces (§8.5) remove the namespace-pollution motivation. Whether the attribute form is still preferred given those changes is a question for its proponents, not something this document should assume an answer to.

### 11.2 Return type in declarator position — `sub Int foo ($x)`

Reads correctly, needs no extra lexical context, and has precedent in the Perl 6 design documents (`our Animal sub get_pet()`). Rejected because `sub Int { ... }` already declares a subroutine named `Int`, so distinguishing name from type needs a lookahead rule touching currently-valid code; and because under any such rule `sub Int ($x) { }` resolves `Int` as the name, so anonymous subroutines could never carry a return annotation.

### 11.3 `:returns(TypeExpression)`

`perlsub` requires attributes to precede the signature, so the only legal form places the return type before the parameters — `sub foo :returns(Int) ($x, $y)` — inheriting the awkwardness of `:prototype($$) ($left, $right)`.

### 11.4 Raku-style `sub foo ($x --> Int)`

Also inside the signature, so it shares the two-context property. Rejected because `-->` is a tokenizing hazard: the sequence can arise in a parameter default, as in `sub f ($x = $i-- > 5)`.

### 11.5 Comment-carried annotations — `my $x; #[ Array[Int] ]`

Invisible to older perls and adoptable immediately, but unparseable by definition, and IDE conventions like `#@type` already occupy the space without needing core.

### 11.6 Requiring a `where` clause

Making `type N as P;` a syntax error, so that every declaration supplies a membership function, would keep this proposal to pure notation with no extension to the latent system at all. It is the minimal-proposal option and entirely coherent.

Rejected because it cannot express the motivating case. `Celsius` and `Fahrenheit` are distinguished by intent, not by any property of their values, so there is no predicate to write. Requiring one would mean either abandoning the example or writing a predicate that is a lie.

A bare `type Identifier as Str;` as a transparent alias — `Celsius ≡ Num`, interchangeable — is coherent for the same reason and rejected for a stronger one: it is not worth a keyword, since a comment does the same work.

### 11.7 Nominal typing by blessing

Making a `Celsius` a blessed scalar gives a genuinely value-based distinction, since `blessed()` can see it. This defeats the strong form of the argument in §8.1 — the formalism *can* supply a membership function here — and it is what the existing ecosystem does.

Rejected because it changes the representation. A blessed `Celsius` is an `Object` (§3.1), not a refinement of `Num`: `erase(Celsius)` is no longer `Num`, arithmetic requires overloading, the value costs an allocation, and the zero-cost static property in §8.3 disappears. It is also no longer `as Num` in any meaningful sense.

The trade is explicit: representation-preserving brands are free and invisible to the runtime; blessed brands are visible and expensive. This proposal takes the first.

### 11.8 Types as values — deferred, not rejected

```perl
sub make_unit { return type as Num }
BEGIN { type Metre = make_unit(); }         # computed declaration
BEGIN { our $X = type as Str; }
my $X $y = "hello";                         # scalar in annotation position
```

Deferred pending further thought. Recorded state of the argument:

*What it buys:* generative types. A factory yields a fresh distinct brand per call, so `Metre` and `Second` become different brands over one representation without either being written out. No literal form expresses this.

*The timing objection was wrong.* `BEGIN` runs during compilation, so the binding does exist when the following statement compiles. A file-scope lexical works too.

*Two objections survive, and only against the scalar-in-annotation-position form:* `my $X $y` needs lookahead and reads like a typo; and a consumer that is not a Perl interpreter cannot know what `$X` holds without evaluating arbitrary compile-time code.

*A named computed form* — `type NAME = EXPR;` — avoids both while keeping generativity, and is the shape to revisit first.

*One consequence either way:* computed brands make identity depend on evaluation rather than source text, implying a tier split for static consumers — literal declarations carry an erasure and can drive representation choices, computed ones are opaque brands useful only for nominal checking.

### 11.9 Also deferred

- **Union types** — spellable as `Union[...]` under §6, so no syntax is needed.
- **Nullability sugar** — `Int?`, spellable as `Maybe[Int]`.
- **Enumerations** — `type Colour as Str where { /^(red|green|blue)$/ }` works and reads badly; a dedicated form is worth having, and nothing here forecloses it.
- **Coercions.** Coercion is where type systems acquire their worst ambiguities and should not be designed in the same pass as declaration.
- **Per-element list annotation** — `my (Int $x, Str $y)`.
- **Function types** — see §6.1.

---

## 12. Open issues

1. **Brand propagation through operators** (§8.3), for tree brands. Measures resolve this by construction; tree brands do not. Blocking for arithmetic on non-measure nominal types.
2. **Whether a measure is a type or a separate kind** (§6.2), and the resulting declaration syntax. Note that the latent system offers no guidance here, since it has no brands — this is genuinely new design.
3. **Bare identifiers in constraint position** (§6.1) — decidable, but costly in an LALR grammar.
4. **Return annotations on generators** (§7.2).
5. **Type placement on named parameters** (§7.2), new in 5.44 and without prior art.
6. **Names as written versus resolved designators** (§8.5).
7. **Explicit re-branding syntax**, if the unbranded-source rule proves too restrictive.
8. **Runtime access to type parameters** inside a membership function (§8.4).
9. **Tokenizer feasibility** for bracketed expressions in both contexts, particularly between `)` and `{`. Needs a `toke.c`-literate assessment; this is the main implementation risk.
10. **Does current perl accept `field Foo $x` and `local Foo $x`?** (§10)
11. **Introspection interface.** Consumers need the erasure and the membership function as separate things, not one opaque object.

---

## 13. References

- *Formal Definition of Perl's Latent Dynamic Type System* — https://pvm.tools/papers/perl-types-formal.html — the membership criterion, the `Int <: Num <: Str <: Scalar` chain, the `Unknown`/`Any` distinction, and the Note on Enforcement. Its Future Work names the annotation system this document specifies.
- `perigrin/perl5-son` — `SoN::IR::Stamp` implements the lattice with `is_subtype_of`, `meet`, and `join`; constants are stamped automatically and inference passes are not yet written
- Ovid, "Data Types in Perl" (2022) — https://gist.github.com/Ovid/5ae3752e260219a575ddfdea4c2194f7
- PEP 3107, PEP 526 — the syntax-without-semantics precedent
- `perlsub`, "Signatures" — attribute/signature ordering, `:prototype`
- `perlop` — chained comparisons (5.32), and the relational/equality precedence split
- `perldelta` 5.44 — named parameters in signatures; Unicode 17 identifier tightening
- `perldoc -f my` — the existing type slot and its `fields` binding
- PPC0021, Optional Chaining — the "currently a syntax error, therefore additive" argument
- `demerphq/xperl` — `pod/perlclass.pod`, `pod/perlnamespace.pod`, `pod/perlgenerator.pod`
- Haskell `newtype`, Ada derived types, Go type definitions — nominal types over an existing representation
- F# units of measure — nominal, statically checked, erased at runtime; the closest precedent for dimensioned brands. Note that F# treats measures as a separate kind from types (F# Language Specification §9)
- Farnsworth (Ryan Voots, 2010) and Frink — dimensioned numbers as a language primitive, implemented in Perl
- Type::Tiny, Moose — `subtype`/`as`/`where`, the source of this spelling
- `sealed.pm` — an existing consumer; uses prefix-position types in signatures
