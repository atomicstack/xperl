# Deferred RNG follow-up

Status: deferred by Yves on 2026-11-19. Record this proposal for a later
design discussion; it does not select an API or authorize implementation.
The current feedback pass leaves RNG code unchanged.

Source: Claude's proposal in demerphq/xperl commit f0549b9722, also posted
to agent-comms on 2026-11-15. Its evidence refers to the revisions and
configurations named below, and must be rechecked against the current tree.

The follow-up should settle native versus PV-backed state, subclass and
rebless behavior, clone semantics, compatibility, ownership across callbacks,
and the performance/validation plan before an implementation is chosen.

---

# ${^RNG} fast path: design detail

Requested on agent-comms in `2026-11-15T22:34:49Z demerphq/codex`. It follows the report in `2026-11-15T22:08:13Z atomicstack/claude-security`. This is a design for review, not an implementation; nothing here is coded.

Evidence labels used throughout:

- **[confirmed]** I ran it. Builds: xperl/main 5603bec602 plus `atomicstack/sec-fixes`, macOS arm64, ASAN + DEBUGGING, unthreaded and ithreads; timings on an older `-O3` unthreaded build of bb8ac6efef.
- **[source]** concluded from reading the code, not run.
- **[hypothesis]** an expectation I have not checked.

## Correction to my earlier report

I wrote that a new thread "starts on the default generator until `${^RNG}` is assigned there". That was wrong. `perl_clone` resets the three cache variables and then calls `Perl_rng_rebuild` near its end (sv.c), so the clone re-runs the handshake on its own copy of the provider. **[confirmed]** on an ithreads build: a thread created after `${^RNG} = RNG::PCG->new(1)` reports `RNG::PCG` and draws the same first values as the parent, because the state bytes were copied. Parent and child therefore produce identical streams until one reseeds. That is a semantic question for Yves (Q5 below), not a memory-safety problem.

## 0. Requirements I am designing to

- R1. No Perl-level code, however hostile, can make core call an address or dereference a state pointer it chose. Only XS (which can already do anything) may supply either.
- R2. No sequence of Perl-level operations on a provider object, its referent, or `${^RNG}` can leave core holding a pointer to freed or resized memory.
- R3. A scalar that holds a copy of generator state never changes because the generator advanced.
- R4. Steady-state `rand()` with a bundled provider stays within noise of today's fast path.
- R5. Pure-Perl providers keep working unchanged through `rand_bytes`/`srand`.
- R6. Third-party XS providers can opt in without core knowing them in advance.

## 1. C API and descriptor

### 1.1 Types

```c
/* perl.h */
#define PERL_RNG_FAST_ABI 1

typedef struct perl_rng_fast Perl_rng_fast;

/* Draw one uniform NV in [0,1).  Called with the provider's referent.
 * Must not run Perl code, croak, or reallocate anything it does not own. */
typedef NV (*Perl_rng_U01_func)(pTHX_ SV *referent, const Perl_rng_fast *fast);

/* Called by core immediately before the first draw after any event that
 * could have changed the referent (see 3.2).  Returns FALSE to decline the
 * fast path for now; core then uses the rand_bytes fallback.  May croak.
 * Must not run Perl code. */
typedef bool (*Perl_rng_validate_func)(pTHX_ SV *referent, const Perl_rng_fast *fast);

struct perl_rng_fast {
    U32  abi;          /* PERL_RNG_FAST_ABI the provider was compiled with */
    U32  size;         /* sizeof(Perl_rng_fast) as the provider saw it */
    HV  *stash;        /* class the registration is valid for; not counted */
    Perl_rng_U01_func      U01;
    Perl_rng_validate_func validate;   /* may be NULL: always valid */
    void *state;       /* option A: native state owned by the registration */
    void (*free_state)(pTHX_ void *state);               /* may be NULL */
    void *(*dup_state)(pTHX_ const void *state);         /* ithreads; may be NULL */
};
```

The signature of `Perl_rng_U01_func` changes from today's `(pTHX_ void *state)`. That is deliberate: the function is given the referent so that it never depends on a pointer core cached.

### 1.2 Functions

```c
/* embed.fnc: all three  Adp  (public, documented) */

/* Attach a fast path to the referent of a provider object.  Croaks if abi
 * or size is not one core supports, if U01 is NULL, if referent is not a
 * blessed SV, or if its class is not descriptor->stash.  Replaces an
 * existing registration on the same referent (the old state is freed with
 * its free_state).  The descriptor struct is copied; the caller's copy may
 * be static or on the stack. */
void Perl_rng_fast_register(pTHX_ SV *referent, const Perl_rng_fast *descriptor);

/* Remove the registration, freeing its state.  No-op when there is none.
 * If the referent is the installed provider, the core cache is dropped
 * first, so rand() falls back to rand_bytes. */
void Perl_rng_fast_unregister(pTHX_ SV *referent);

/* The registration on a referent, or NULL.  For providers' own XS methods. */
const Perl_rng_fast *Perl_rng_fast_find(pTHX_ SV *referent);
```

### 1.3 Storage and ownership

- The registration is ext magic on the **referent**: `sv_magicext(referent, NULL, PERL_MAGIC_ext, &PL_rng_fast_vtbl, (char *)copy, 0)`, where `copy` is a `Newx`'d `Perl_rng_fast`. `mg_len` is 0, so the magic owns the pointer only through the vtable.
- `PL_rng_fast_vtbl` is a core-private static `MGVTBL` with `svt_free` and `svt_dup` set. Its address is the identity: lookup is `mg_findext(referent, PERL_MAGIC_ext, &PL_rng_fast_vtbl)`. The symbol is not exported, so other XS cannot attach look-alike magic except through `Perl_rng_fast_register`.
- `svt_free` calls `free_state(state)` if set, then `Safefree`s the copy. It runs when the referent is freed or the magic is removed.
- `svt_dup` (with `MGf_DUP`) allocates a new copy for the clone, maps `stash` through `sv_dup`, and sets `state = dup_state(state)`. If `state` is non-NULL and `dup_state` is NULL, the clone gets **no** registration (the magic is dropped in the clone) and falls back to `rand_bytes`. A raw pointer is never shared between interpreters.
- Ownership summary:

| object | owned by | freed |
|---|---|---|
| descriptor passed to register | caller | caller's business; core copied it |
| descriptor copy | the magic | `svt_free` |
| `state` block (option A) | the registration | `free_state` from `svt_free`, or on replace/unregister |
| referent | refcount; pinned by `PL_rng_provider` while installed | normal |
| `stash` | not counted; compared only | n/a |
| `PL_rng_fast` (core cache, replaces `PL_rng_U01`/`PL_rng_U01_state`) | points into the magic's copy; valid only while `PL_rng_provider` pins the referent and the generation matches (3.2) | n/a |

### 1.4 When registration is legal, rollback, destruction

- Legal at any time on a blessed referent whose `SvSTASH` equals `descriptor->stash`. Normally done in the constructor, after `sv_bless`.
- Failure rollback: `register` validates everything before it touches the SV. If it croaks, the referent is unchanged and the caller still owns its `state` block. The recommended pattern is to allocate state, `SAVEFREEPV` it (or use a mortal), register, then disarm; the example in 4.1 shows it.
- Replacement: registering again frees the previous state first. If the referent is the installed provider, core drops its cache before the old state is freed.
- Destruction: object DESTROY (Perl level) runs before magic is freed, so a Perl DESTROY can still call XS methods that use the registration. Global destruction: `perl_destruct` already calls `Perl_rng_clear` before SVs are swept; that stays.

### 1.5 Authentication: why magic alone is not enough

Magic proves that trusted XS registered **this referent while it had class `stash`**. Two things could invalidate that later, and both are checked:

1. **Class changed** (rebless, or the registration was made for a base class and the object is now a subclass instance). Core compares `SvSTASH(referent) == fast->stash` at install and at every revalidation. A mismatch means no fast path. The provider decides what `stash` is; it can register the object's actual class (subclasses allowed, see 3.1) or refuse subclasses.
2. **Representation changed** (the PV was reassigned, truncated, upgraded, made COW). That is what `validate` is for under option B. Under option A the representation core relies on is the magic-owned block, which Perl code cannot reach, so there is nothing to validate.

What stays unauthenticated: the truthfulness of the XS that registered. XS can always corrupt memory; R1 is about Perl code only.

## 2. Lifetime protocol

Two options for where generator state lives. Common to both: the handshake of section 1, and core's cache protocol of section 3.2.

### 2.1 Option A: native state owned by the registration

The object is a blessed scalar whose value is irrelevant to generation (it can be empty, or hold a version tag). The state is `fast->state`.

| operation | behaviour |
|---|---|
| `rand()` (core) | `fast->U01(aTHX_ referent, fast)`; reads and writes `fast->state` only. No SV is touched. |
| `rand_bytes` (core or method) | XS finds the registration with `Perl_rng_fast_find`, uses `state`. |
| `$obj->rand`, `$obj->rand_U01` | same. |
| `srand()` / `$obj->srand` | writes `state` in place; pointer never moves. |
| snapshot | explicit: `$obj->state` returns a fresh byte string (copy out). |
| restore | explicit: `$obj->set_state($bytes)` validates length and copies in. Croaks on a wrong length. |
| `$$obj = ...`, `undef $$obj`, append, upgrade | no effect on the generator. Could be made an error by marking the scalar read-only at construction; I would. |
| COW | cannot arise: state is not in an SV buffer. |
| UTF-8 | `set_state` must `SvPVbyte` its argument (croaks on wide characters). |
| tied/magical arguments | `set_state` and `srand` read their argument (get magic, overload) **before** touching `state`; the copy-in itself is a `memcpy` with no callouts. |
| reference replacement (`$obj = other`) | ordinary Perl; the old referent lives while `PL_rng_provider` holds it. |
| clone/Storable/`dclone` | need `STORABLE_freeze/thaw` (or equivalent) written against `state`/`set_state`; a naive byte copy of the scalar no longer clones the generator. |

Points where Perl code can run: argument conversion in `srand`/`set_state`/`rand(limit)`. None of them hold a state pointer across the conversion, and even if they did the pointer cannot move, because only `free_state` frees it and that runs only when the referent dies, the registration is replaced, or it is unregistered. To make that airtight, a provider's own XS must not call `register`/`unregister` between acquiring `state` and its last use; core never does.

Reentrancy: a `rand_bytes` or `srand` callback implemented in Perl cannot exist for an option-A provider's native methods, so there is no reentrant path into the native state except through XS methods, each of which completes atomically with respect to Perl code.

### 2.2 Option B: state stays in the PV, pointer re-derived per draw

The object layout is unchanged: blessed reference to a PV scalar of exactly `sizeof(state struct)` bytes. `fast->state` is NULL. The fast function is:

```c
static NV
pcg_rng_U01(pTHX_ SV *referent, const Perl_rng_fast *fast)
{
    PERL_UNUSED_ARG(fast);
    /* core has validated; see below for what that guarantees */
    return rng_U64_to_NV_U01(pcg_next_u64((pcg_data *)SvPVX(referent)));
}
```

and `validate` is today's `pcg_state()` made strict:

```c
static bool
pcg_rng_validate(pTHX_ SV *referent, const Perl_rng_fast *fast)
{
    if (SvTYPE(referent) < SVt_PV || !SvPOK(referent) || SvMAGICAL(referent)
        || SvUTF8(referent) || SvCUR(referent) != sizeof(pcg_data))
        return FALSE;                 /* fall back; rand_bytes will croak */
    if (SvIsCOW(referent))
        sv_force_normal(referent);    /* unshare before any in-place write */
    if (SvREADONLY(referent))
        return FALSE;
    return TRUE;
}
```

The question is when core must call `validate`. Two sub-variants:

- **B1, validate on every draw.** `S_call_rand` calls `validate` then `U01` each time (in practice the provider folds both into `U01` and core calls one function). Always safe, no cache protocol needed, costs the checks on every draw.
- **B2, validate once per "epoch".** Core validates at install and again only after something that could have changed the referent. There is no general hook for "a scalar was assigned to", so B2 needs set magic on the referent to bump a counter. That means the referent carries `PERL_MAGIC_ext` with `svt_set` (the registration magic itself can do this), and `SvMAGICAL` is no longer a reason to reject. But set magic only fires for operations that call `SvSETMAGIC`; `undef $$r`, `sv_force_normal`, `utf8::upgrade`, and XS writing the buffer directly do not all do so. **[source]** I do not think B2 can be made complete, and I reject it.

So option B means B1. Per-operation behaviour under B1:

| operation | behaviour |
|---|---|
| `rand()` (core) | validate + step. If validate fails, fall back to `rand_bytes`, whose XS croaks "object does not contain a valid state". |
| `rand_bytes`, `$obj->rand` | `pcg_state()` gains the same COW/UTF-8/magic/read-only checks (this is the slow-path COW fix). |
| `srand()` | as today: core clears its cache, calls the method, rebuilds. A subclass `srand` that reallocates `$$self` (t/pcg.t `RelocatingSrand`) keeps working. |
| `$obj->srand` directly | in place via `pcg_state()`; if the subclass moved the buffer, the next draw re-derives it. |
| snapshot `my $s = $$obj` | shares the buffer COW. The next draw's validate sees `SvIsCOW` and unshares before writing. `$s` keeps the snapshot value. **This fixes R3.** One extra `malloc`+copy on the first draw after each snapshot. |
| snapshot taken before the provider was created from it (`bless \(my $p = $saved)`) | same: the first write unshares. |
| restore `$$obj = $s` | allowed. Next draw re-derives the pointer. If `$s` was itself shared, the assignment may make `$$obj` COW again; the next validate unshares. |
| malformed state (`$$obj = 'ab'`, `undef $$obj`) | validate fails; `rand()` croaks through the fallback. Today it either keeps drawing from the stale buffer or is a use-after-free. |
| read-only `$$obj` | validate fails; croak "state is read-only". (Alternative: allow reads to fail only on write. A generator cannot draw without writing, so this is the same thing.) |
| UTF-8 flagged state | rejected. `utf8::upgrade($$obj)` on high bytes changes the byte length anyway, so the length check already fails; the explicit `SvUTF8` test covers the all-ASCII state whose bytes would be reinterpreted. |
| tied or otherwise magical referent | rejected: validate must not run Perl code, and reading a tied scalar does. A tied state scalar gets the fallback, which calls the provider's Perl-visible methods normally. |
| reference replacement | as option A. |

Where Perl code can run: nowhere between validate and the last write of a draw. `validate` uses only flag tests and `sv_force_normal` (which can `malloc` and `croak` on allocation failure but runs no Perl). `U01` does arithmetic. `rand_bytes(n)` for large `n` writes into a result SV it owns; it must validate once, then generate, with no callouts in between (true today). `rand(limit)` and `srand(seed)` must convert `limit`/`seed` **before** calling `pcg_state()`; **[source]** `rand(self, limit)` already does (`SvGETMAGIC`/`SvNV_nomg` precede `pcg_state`), `_srand` calls `SvGETMAGIC(seed)` first but `pcg_seed()` then reads the seed's bytes while holding the state pointer. If the seed is an overloaded object, stringifying it inside `pcg_seed` runs Perl code. **[confirmed]** `$r->srand($obj)` where `$obj`'s `""` overload does `undef $$r; $$r = ${ RNG::PCG->new(2) }` is a heap-use-after-free write (`pcg_load_raw_seed` <- `pcg_seed` <- `XS_RNG__PCG__srand`), with no `${^RNG}` involved. That path needs the same treatment as the Tensor fix: convert the seed to bytes first, then acquire the state. Only PCG was tried; the other providers have the same shape **[source]**.

### 2.3 Slow-path COW fix, independent of the handshake

`pcg_state()` and its five siblings hand out a writable `SvPVX` without checking `SvIsCOW`. **[confirmed]** `my $c = $$r; $r->rand for 1..3;` changes `$c` with no `${^RNG}` involved. The fix is two lines per accessor (`if (SvIsCOW(state)) sv_force_normal(state);` and a read-only check) and can ship before any redesign. It is needed under option B regardless and is harmless under A.

### 2.4 Callback boundaries in srand, reseed and construction

Codex's note of 22:51:53Z asks for this explicitly, and it is the same class of bug as row 12 in section 6 (which I reproduced through a `""` overload; Codex reproduced it through `RNG::SeedBase::is_redacted`). Re-deriving the pointer at method entry is not enough: the rule has to be **all input is converted to bytes the XS owns before the writable state pointer is acquired, and nothing that can run Perl code happens between acquiring it and the last write.**

Where Perl code can run inside a seed operation today **[source]**, RNG.xs at f8ae5af09c:

| step | can run Perl | via |
|---|---|---|
| `SvGETMAGIC(seed)` in `_srand`/`_new` | yes | tied seed |
| `rng_raw_seed` -> `rng_seed_method(seed, "is_redacted")` | yes | `call_method` on an `RNG::SeedBase` subclass |
| `rng_raw_seed` -> `rng_seed_method(seed, "bytes")` | yes | `call_method` |
| `SvGETMAGIC(*material)`, `SvPVbyte_nomg(*material)` | yes | tied or overloaded return value of `bytes` |
| string seed: `SvPV`/`SvPVutf8` of the seed | yes | `""` overload |
| `rng_drand48_seed` numeric conversion | yes | `0+` overload |
| `croak` for a wrong-length raw seed, redacted seed, wide character | no Perl, but unwinds | must not leave state half-written |
| HMAC_DRBG reseed: additional input `SvGETMAGIC`/string coercion | yes | tie, overload (Codex, by inspection) |
| HMAC_DRBG automatic reseed inside generate (`reseed_counter > interval`) | no | entropy read only |

The shape that is wrong today is `X_seed(aTHX_ X_state(aTHX_ self), seed)`: C evaluates `X_state(self)` first, then `X_seed` runs every row above while holding it. `RNG::Drand48::_srand` already has the right order (`value = rng_drand48_seed(seed); drand48_seed(drand48_state(self), value);`).

Required shape, for both options:

```c
/* phase 1: may run Perl, may croak; touches no generator state */
X_seed_material material;                 /* fixed-size struct on the C stack */
X_prepare_seed(aTHX_ seed, &material);    /* raw or expanded; all callbacks done */
/* phase 2: no Perl, no croak */
state = X_state_for_write(aTHX_ self);    /* validate (+ unshare COW under B) */
X_load_seed(state, &material);
```

- The prepared material is the generator's fixed-size seed input (16 bytes for PCG, 8 for Wyrand, 32 for Xoshiro, Key||V for HMAC_DRBG), so it lives on the C stack and needs no cleanup on croak. For HMAC_DRBG additional input of arbitrary length, phase 1 copies it into a mortal SV's buffer the XS owns, so later Perl code cannot change it.
- Phase 2 computes the complete new state into a local struct and assigns it in one step where the generator allows, so a state is never observed half-seeded even by a signal handler's `rand()`.
- `_new` is safe either way, since the object is not yet reachable, but should use the same helpers so there is one code path.
- The return value of `srand` (`newSVsv(seed)`, or the raw automatic seed) is built after phase 2, or from the phase-1 material; copying the caller's seed SV can itself run get magic, so it belongs in phase 1.
- Under option A phase 2's pointer cannot be invalidated by Perl code at all, so a violation of the ordering rule would be a logic error (seeding from stale input) and not memory corruption. Under option B it stays a memory-safety rule that every provider must follow. This is one more reason I prefer A.
- `rand_bytes(self, length)`: `length` is converted by the typemap before the body runs; the result SV is allocated before `X_state(self)`; generation runs no Perl. Correct today **[source]**, apart from the small leak of the result SV when `X_state` croaks.
- `rand(self, limit)`: `limit` is converted before `X_state(self)`. Correct today **[source]**.

## 3. Classes, reblessing, clones, teardown

### 3.1 Subclasses and overrides

Policy proposal: **the fast path is used only when the object's class resolves `rand_bytes` to the same CV the registering class did.** Rationale: the documented contract is that `rand()` calls the provider's `rand_bytes`. A subclass that overrides `rand_bytes` (to log, to mix, to count) and still gets the native fast path would silently bypass its own override. Today that bypass happens and is tested for: t/pcg.t has `RNG::PCG::MethodOverride`, whose `rand_bytes` dies with "the Perl rand_bytes fallback was used", and asserts that core `rand()` still returns the native value. So this is a visible behaviour change and needs Yves's decision (Q2).

Mechanically: at registration the provider records `stash`. At install core checks `SvSTASH(referent) == fast->stash`. For subclass support the provider registers with the object's actual class (`SvSTASH` at construction) after checking, in XS, that `gv_fetchmethod(stash, "rand_bytes")` is its own XSUB; it declines to register otherwise. That keeps the policy in the provider, where the knowledge is, and core's check stays a pointer compare.

Method cache invalidation: if someone later defines `Sub::rand_bytes` at runtime, the registration is stale in the policy sense (not the memory sense). Core can catch this cheaply by recording `PL_sub_generation` and the stash's `mro_meta` `cache_gen` at install and revalidating when they change (3.2). **[hypothesis]** that the two counters cover every way a method resolution can change; `mro.c` bumps one or the other on glob assignment, `@ISA` change and stash deletion, but I have not audited every path.

### 3.2 Core cache and revalidation

Core keeps, per interpreter:

```c
SV *PL_rng_provider;              /* RV, counted: pins the referent */
const Perl_rng_fast *PL_rng_fast; /* NULL: use fallback */
U32 PL_rng_fast_subgen;           /* PL_sub_generation at install */
U32 PL_rng_fast_mrogen;           /* HvMROMETA(stash)->cache_gen at install */
```

`S_call_rand` becomes:

```c
if (PL_rng_provider) {
    const Perl_rng_fast * const fast = PL_rng_fast;
    if (fast
        && LIKELY(SvSTASH(SvRV(PL_rng_provider)) == fast->stash)
        && LIKELY(PL_sub_generation == PL_rng_fast_subgen))
        return fast->U01(aTHX_ SvRV(PL_rng_provider), fast);
    return S_call_rand_slow(aTHX);   /* revalidate or fall back */
}
```

- The stash compare makes a rebless take effect on the very next draw, with no hook needed. This answers the rebless question: ext magic survives `bless`, but the registration is only honoured while `SvSTASH` equals the class it was made for, and an incompatible class never matches because the provider registers per actual class.
- `S_call_rand_slow` re-runs the install logic (find magic, compare stash, compare generations) and either restores `PL_rng_fast` or leaves it NULL and uses `rand_bytes`.
- `Perl_rng_fast_unregister`/replace on the installed referent sets `PL_rng_fast = NULL` before freeing anything.
- Should visible class changes alter core `rand()`? My answer: yes. `rand()` should always be equivalent to "call `rand_bytes` on `${^RNG}` and scale", with the fast path as an unobservable optimisation. That is the property that makes the fallback contract meaningful.

### 3.3 `${^RNG}` assigned or localized during a callback

Callbacks that can run during RNG operations: provider `srand`, provider `rand_bytes` (fallback only), `validate` (must not run Perl), argument conversion.

- Assignment inside `srand` (already handled today): `pp_srand` clears the fast path, calls the method with its own reference to the old provider, then rebuilds from whatever `${^RNG}` now holds. Unchanged.
- Assignment inside a fallback `rand_bytes`: `S_rng_bytes` must hold its own counted reference to the provider for the duration of the call. **[source]** Today `S_call_rand` passes `PL_rng_provider` straight to `S_rng_u64`, and `S_rng_call` is given that pointer; if the callback assigns `${^RNG}`, `Perl_rng_clear` drops the last core reference while the method is still running on it. **[confirmed]** no failure: a pure-Perl provider whose `rand_bytes` does `${^RNG} = undef` completes under ASAN and the next `rand()` uses the built-in generator, so something already keeps the invocant alive for the call. I did not trace what. The design should make that explicit with a mortal copy.
- `local ${^RNG} = $other` inside a callback and scope exit: set magic runs on entry and on restore, each doing a full refresh. The fast function is never on the C stack across a refresh, because it runs no Perl.
- `Perl_rng_fast_register` called from a callback on the installed referent: core drops `PL_rng_fast` first; the in-flight operation is not a fast draw (fast draws run no callbacks), so nothing holds the old pointer.

### 3.4 Cloned interpreters

- Option A: `svt_dup` calls `dup_state`; the clone owns an independent copy with identical contents. Providers that cannot or should not duplicate (HMAC_DRBG seeded from entropy, arguably all of them) leave `dup_state` NULL and the clone falls back to `rand_bytes` on a registration-less object, whose XS then croaks or reseeds as the provider chooses.
- Option B: the PV is duplicated by `sv_dup` as today; the magic's descriptor copy is duplicated by `svt_dup`; `Perl_rng_rebuild` at the end of `perl_clone` reinstalls. Behaviour is identical to today's **[confirmed]** duplicated stream.
- `stash` in the descriptor is remapped with `sv_dup` (no refcount). This is the same class of bug Codex found in my class-layout patch, so it gets an explicit test.

### 3.5 Teardown

- `perl_destruct` calls `Perl_rng_clear` before the SV sweep (already true). After that `rand()` uses the default generator.
- During global destruction objects may be freed in any order; `svt_free` must not touch other SVs. It only calls `free_state` and `Safefree`.
- A provider `DESTROY` that calls `rand()`: `PL_rng_provider` is already NULL, so it draws from the default generator. No change.

## 4. Providers

### 4.1 Third-party XS provider, option A

```c
typedef struct { U64 s; } my_state;

static NV
my_U01(pTHX_ SV *referent, const Perl_rng_fast *fast)
{
    my_state * const st = (my_state *)fast->state;
    PERL_UNUSED_ARG(referent);
    st->s = st->s * 6364136223846793005ULL + 1442695040888963407ULL;
    return (NV)(st->s >> 11) * (1.0 / 9007199254740992.0);
}
static void  my_free(pTHX_ void *p)        { Safefree(p); }
static void *my_dup(pTHX_ const void *p)   { my_state *n; Newx(n, 1, my_state);
                                             *n = *(const my_state *)p; return n; }

MODULE = My::RNG  PACKAGE = My::RNG

SV *
new(class_name, seed = 0)
    const char *class_name
    UV seed
  PREINIT:
    Perl_rng_fast d;
    my_state *st;
    SV *referent;
  CODE:
    referent = newSV(0);
    RETVAL = sv_bless(newRV_noinc(referent), gv_stashpv(class_name, GV_ADD));
    sv_2mortal(RETVAL);                    /* freed if anything below croaks */
    Newx(st, 1, my_state);
    SAVEFREEPV(st);                        /* ditto, until registered */
    st->s = seed;
    Zero(&d, 1, Perl_rng_fast);
    d.abi = PERL_RNG_FAST_ABI;  d.size = sizeof(d);
    d.stash = SvSTASH(referent);
    d.U01 = my_U01;  d.state = st;  d.free_state = my_free;  d.dup_state = my_dup;
    if (my_rand_bytes_is_ours(aTHX_ d.stash)) {   /* subclass policy, 3.1 */
        Perl_rng_fast_register(aTHX_ referent, &d);
        SAVEFREEPV_disarm(st);             /* pseudo: registration now owns st */
    }
    SvREADONLY_on(referent);
    SvREFCNT_inc_simple_void_NN(RETVAL);
  OUTPUT:
    RETVAL

SV *
rand_bytes(self, length)
    SV *self
    UV length
  PREINIT:
    const Perl_rng_fast *fast;
  CODE:
    if (!SvROK(self) || !(fast = Perl_rng_fast_find(aTHX_ SvRV(self))) || fast->U01 != my_U01)
        croak("My::RNG object expected");
    /* check length, allocate RETVAL, then fill from fast->state: no callouts */
    ...
```

There is no "disarm" primitive for `SAVEFREEPV`; a real implementation would hold `st` in a mortal SV's buffer until registration and then detach it, or core could offer `Perl_rng_fast_register_new(referent, &d, state_size)` that allocates the zeroed block itself and returns it. I would add that convenience: it removes the only tricky ownership step from provider code. (Open detail, Q4.)

If the subclass check fails and no registration is made, the object has no native state at all under option A, so `rand_bytes` has nowhere to draw from. Either the provider always registers and core applies the override check (moving the policy of 3.1 into core: compare `gv_fetchmethod(SvSTASH, "rand_bytes")` against a CV recorded in the descriptor), or state lives in separate non-fast magic. The first is simpler: add `CV *rand_bytes_cv` to the descriptor and let core do the compare at install. I recommend that, and it is reflected in the comparison table below.

Option B for a third party is the bundled-provider shape from 2.2 with `state = NULL`, `free_state = NULL`, `dup_state = NULL`.

### 4.2 Pure-Perl provider and the fallback contract

Unchanged from today:

```perl
package My::Perl::RNG;
use parent 'RNG::Provider';
sub new        { bless { s => $_[1] // 1 }, $_[0] }
sub rand_bytes { my ($self, $n) = @_; ...; return $bytes }   # exactly $n bytes
sub srand      { my ($self, $seed) = @_; ...; return $seed }
```

Core `rand()` asks for 8 bytes and scales them (`S_rng_u64_to_NV_U01`). No registration is possible from Perl, by design. The contract core enforces on the result stays: defined, POK, byte length equals the request.

### 4.3 Per-object magic vs per-stash registry vs XSUB allowlist

| | per-object magic (recommended) | per-stash registry | XSUB allowlist |
|---|---|---|---|
| how core recognises a fast provider | ext magic with core's vtable on the referent | stash pointer found in a core table filled by XS at BOOT | `CvXSUB(method)` is in a core table |
| can pure Perl forge it | no | no, but it can **inherit** it: `@Fake::ISA = 'RNG::PCG'; bless {}, 'Fake'` unless lookup is by exact stash | no |
| layout check needed at install | none for A (state is in the magic); `validate` for B | always: core or the callback must prove this referent has the registered layout, since any object can be blessed into a registered class | same as registry |
| subclasses | provider or core compares `rand_bytes` CV | exact-stash lookup excludes all subclasses; MRO lookup admits Perl subclasses and then needs the override check too | whatever resolves to an allowed XSUB, including by glob aliasing into an unrelated class, so a layout check is mandatory |
| third-party XS | yes, via one call | yes, via a BOOT-time call; registry needs unregistration on stash destruction and remapping on clone | no, unless the allowlist is itself a registry |
| per-object memory | one MAGIC (about 48 bytes) plus descriptor copy (64 bytes); the copy could be shared per class to save it | none | none |
| per-draw cost | pointer compares | pointer compares after install | pointer compares after install |
| failure mode if the check is forgotten | none: no magic, no fast path | type confusion on a forged object | type confusion on a forged object |

The registry and allowlist both make "this class is trusted" the claim and then need a separate proof that "this object is really one of that class's objects". Per-object magic makes the second statement the thing that is recorded, by the only code able to know it.

### 4.4 Observable changes and method disposition

| item | disposition |
|---|---|
| `get_rand_U01_XS_func_addr`, `get_rand_U01_XS_state_addr` (bundled classes and `RNG::Provider` stubs) | **Remove from the handshake.** Keep the methods for one release returning `undef` with a deprecation warning, so code that calls or overrides them does not die with "no such method". Core stops calling them. A third-party provider that implemented them silently loses its fast path until it registers; it keeps working through `rand_bytes`. |
| diagnostic ERROR_RNG_PROVIDER_INTEGER_ADDRESS_REQUIRED | becomes unreachable; retire with the methods. |
| `Perl_rng_U01_func` typedef | signature changes. It is in perl.h, so any XS that used it must be recompiled; it is not in the documented API today **[source]**. |
| `rand()` with a subclass overriding `rand_bytes` | now calls the override (Q2). |
| `my $s = $$rng` then drawing | `$s` no longer changes (bug fix). |
| `$$rng = 'garbage'` then `rand()` | croaks; was use-after-free or silent stale state. |
| option A only: `$$rng` is no longer the state; `is(ref($$rng), '', 'the state is a scalar')` in t/pcg.t still passes but assignments to it do nothing or croak; `RelocatingSrand` test loses its purpose | new `state`/`set_state` methods. |
| option A only: thread clones of providers without `dup_state` lose the native path | documented. |
| reblessing an installed provider | next draw uses the new class's `rand_bytes`; was: old native function kept running. |

## 5. Cost model and benchmark plan

### 5.1 What runs when

| check | A | B1 | when |
|---|---|---|---|
| `sv_derived_from(RNG::Provider)` | yes | yes | install |
| `mg_findext` | yes | yes | install, revalidation |
| `rand_bytes` CV compare (`gv_fetchmethod`) | yes | yes | install, revalidation |
| `PL_rng_provider != NULL` | yes | yes | per draw (today too) |
| `PL_rng_fast != NULL` | yes | yes | per draw (today: `PL_rng_U01_state`) |
| `SvSTASH == fast->stash` | yes | yes | per draw, new: 2 loads + compare |
| `PL_sub_generation == cached` | yes | yes | per draw, new: 1 load + compare |
| indirect call to `U01` | yes | yes | per draw (today too) |
| load `fast->state` | yes | no | per draw |
| `SvTYPE`/flags mask test, `SvCUR ==` | no | yes | per draw, new: about 3 loads, 2 compares; the flag tests fold into one mask compare |
| `SvIsCOW` -> `sv_force_normal` | no | rare branch | per draw test; `malloc`+copy only after a snapshot |
| generator step | yes | yes | per draw |

Safe to cache: the descriptor pointer (pinned by `PL_rng_provider`), the stash identity, the generation numbers. Not safe to cache: `SvPVX` (option B), which is the whole bug.

### 5.2 Baseline numbers I have

**[confirmed]**, but rough: one machine (Apple arm64), `-O3` unthreaded build of bb8ac6efef, best of 5 runs of 5M iterations of `$x = rand() for 1..$n`, wall clock, no pinning, no XBench. Treat differences under about 1 ns as noise.

| case | ns per iteration |
|---|---|
| empty loop (`$x = 1`) | 15.1 |
| `rand()`, no provider | 16.3 |
| `rand()`, RNG::PCG fast path | 17.2 |
| `rand()`, RNG::Wyrand fast path | 16.3 |
| `rand()`, RNG::Xoshiro fast path | 16.4 |
| `rand()`, RNG::Drand48 fast path | 16.2 |
| `rand()`, fallback via `rand_bytes` (subclass that disables the fast path) | 167 to 171 |
| `$obj->rand` method call | 42 to 45 |
| `rand()`, RNG::HMAC_DRBG | about 2800 |

Reading: the loop and assignment dominate; a fast draw costs on the order of 1 to 2 ns over an empty loop, the fallback costs about 150 ns more. So the fast path is worth keeping (roughly 100x on the draw itself), and the candidates differ from today by a handful of predictable compares.

**[hypothesis]**, unmeasured: option A adds about 0.3 to 0.6 ns per draw (three loads, two well-predicted branches); B1 adds about 0.6 to 1.2 ns (those plus the referent's flags and `SvCUR`, same cache line as `SvPVX`). Both would be invisible in the table above and visible only in a tight C-level microbenchmark.

### 5.3 XBench plan

Cases (each as an XBench calibrated benchmark, so loop overhead is subtracted):

1. Interpreter overhead only: `pp_rand` with a stub `U01` returning a constant, registered through the new API. Isolates dispatch + checks from generator cost.
2. `rand()` no provider (Drand48 built in).
3. For each of PCG (all four variants), Wyrand, Xoshiro, Drand48: (a) current fast path at 5603bec602, (b) candidate A, (c) candidate B1, (d) fallback via `rand_bytes`.
4. HMAC_DRBG: current vs candidate; expected indistinguishable, included to confirm.
5. `builtin::rand_bytes(8)`, `rand_bytes(4096)` for each: checks happen once per call, so only the 8-byte case should move.
6. `$obj->rand`, `$obj->rand_U01`: unaffected by the handshake, affected by B1's stricter accessor.
7. Mutation cases, reported separately from steady state: (a) snapshot then draw, in a loop (`my $s = $$r; rand()`): B1 pays an unshare per iteration, A pays nothing but has no `$$r` snapshot; compare against A's `$r->state; rand()`. (b) restore then draw. (c) `srand()` then draw (cache rebuild cost). (d) `local ${^RNG} = $p; rand()` (install cost per scope, dominated by `mg_findext` + method lookup). (e) rebless then draw (revalidation).
8. Build matrix for timing: threaded and unthreaded, `-O2`/`-O3`, NV = double, long double, binary128 (the U64 -> NV conversion differs: `NVMANTBITS < 63` uses `ldexp`).

Acceptance threshold proposal: steady-state fast `rand()` within 3% of 5603bec602 for the cheap generators, or within XBench's reported noise if that is larger.

## 6. Regression and validation matrix

Rows are tests; all run on the configurations listed after the table.

| # | scenario | expected | status today |
|---|---|---|---|
| 1 | handshake forged with aliased `refaddr` as state (report 2b, first) | no fast path; `rand()` uses `Fake::rand_bytes` | **[confirmed]** memory corruption |
| 2 | handshake forged with constant subs (report 2b, second) | same | **[confirmed]** jump to chosen address |
| 3 | `$$r = big`, `undef $$r`, `$$r .= ...`, `utf8::upgrade($$r)` on installed provider, then `rand()` | A: no effect or read-only croak. B1: draw from new state if valid, else croak | **[confirmed]** use-after-free |
| 4 | `$$r = 'ab'` then `rand()` | croak "does not contain a valid state" | **[confirmed]** keeps drawing from stale state |
| 5 | snapshot `my $s = $$r` before drawing; draw; compare `$s` | unchanged | **[confirmed]** changes (fast and slow path) |
| 6 | pre-existing snapshot: `my $s = $$r0; my $r = bless \(my $p = $s)`; install `$r`; draw; compare `$s` and `$$r0` | unchanged | **[confirmed]** both change |
| 7 | state replaced through an alias (`my $a = \$$r; $$a = $saved`), `foreach` alias, closure | as 3 | **[confirmed]** for the direct alias; others **[source]** |
| 8 | `rand_bytes` with negative, huge, non-numeric, fractional counts; on non-ref, short-state and array-ref invocants | croak | fixed on `atomicstack/sec-fixes` **[confirmed]** |
| 9 | read-only state scalar, then `rand()`, `srand()`, `rand_bytes` | croak, state unchanged | **[confirmed]** written through today by `$obj->rand`, `$obj->srand` and core `rand()`, with no error |
| 10 | `srand()` with a subclass `srand` that relocates the buffer (existing `RelocatingSrand`) | works | passes today |
| 11 | `$obj->srand` directly, relocating, on the installed provider, then `rand()` | works | **[confirmed]** heap-use-after-free read in `pcg_rng_U01_fast` from `S_call_rand` (cache not cleared on a direct method call) |
| 12 | overloaded seed object whose stringification reassigns `$$r` | croak or clean reseed | **[confirmed]** heap-use-after-free write in `pcg_load_raw_seed` from `pcg_seed` from `_srand`; needs no `${^RNG}` at all |
| 13 | rebless installed provider into (a) pure-Perl provider class, (b) another bundled XS class with a different state size, (c) unrelated class not derived from RNG::Provider | (a),(b): next draw uses that class's `rand_bytes` (which for (b) croaks on the wrong-sized state); (c): croak "provider object required" | **[source]** old function keeps running |
| 14 | subclass overriding `rand_bytes`; subclass overriding nothing; override added at runtime after install; `@ISA` changed after install | override honoured in every case; fast path only when not overridden | first case **[source]** bypassed today: t/pcg.t `RNG::PCG::MethodOverride` asserts "the core uses the discovered XS callback without Perl method dispatch" |
| 15 | `${^RNG}` assigned / `local`ized inside `srand`, inside fallback `rand_bytes`, inside an overloaded `limit` to `rand` | no stale cache, no use-after-free | `srand` case handled today; others **[source]** |
| 16 | provider freed while installed is impossible; provider's last other reference dropped, then `${^RNG} = undef` | state freed exactly once (ASAN, and a `free_state` counter in XS::APItest) | n/a |
| 17 | `Perl_rng_fast_register` twice, `unregister` while installed, register with wrong abi/size/stash (XS::APItest) | replace frees old state; croaks leave the SV unchanged | n/a |
| 18 | ithreads: thread created with provider installed; thread draws; parent draws; both destroyed in either order | independent state; no shared pointer; `stash` remapped | B behaviour **[confirmed]** today |
| 19 | ithreads: provider with `dup_state == NULL` | clone has no fast path, falls back | n/a |
| 20 | global destruction with provider installed and `DESTROY` calling `rand()` | no crash | **[hypothesis]** fine today |
| 21 | tied state scalar; state scalar with other ext magic | fallback, no Perl code run inside the fast path | **[source]** |
| 22 | every bundled provider, each PCG variant | all of the above | |

Configurations: unthreaded and ithreads; `PERL_RC_STACK` on and off; DEBUGGING; ASAN (and UBSAN if available); NV = double, long double, binary128; 32-bit IV if a build is to hand. I can run macOS arm64 ASAN/DEBUGGING with and without ithreads; the binary128 and RC-stack builds are on Yves's side.

Left to a third-party XS provider (core cannot check): that `U01` and `validate` run no Perl code and do not croak mid-update; that `U01` only touches memory it owns; that `free_state`/`dup_state` are correct; that its own XS methods convert arguments before acquiring state; under option B, that every accessor uses the strict validate.

Remaining limitations under either option: XS can still defeat everything (by design); `Internals::SvREADONLY` can unlock a read-only state scalar (harmless under A, re-checked every draw under B1); thread clones duplicate the stream unless the provider opts out.

## 7. Recommendation

1. **Now, independent of the design:** the slow-path COW and read-only fix in the six `*_state()` accessors (2.3), and convert-before-acquire in `_srand`/`pcg_seed` and siblings (row 12, a reproduced use-after-free that does not involve `${^RNG}`). Small, no API change. I have not written these; say the word and I will, as a separate commit.
2. **Handshake:** per-object ext magic with a core-private vtable (section 1), with `rand_bytes_cv` in the descriptor and the stash and generation checks in core (3.1, 3.2).
3. **State lifetime: option A for the bundled providers**, with `state`/`set_state` methods and the scalar made read-only. I said B in the earlier report; working through section 2 changed my mind. B1 is safe, but its safety rests on every accessor in every provider repeating a seven-condition check correctly forever, and on nobody adding a callout between validate and write. A makes the dangerous state unreachable from Perl, so R2 and R3 hold by construction, and the per-draw path is shorter. The price is that `$$rng` stops being the state, which is a visible change for anyone who discovered it; it was never documented (**[source]**: perlrng says only "the provider owns its state").
4. The API still **permits** option B for third parties (`state = NULL` + `validate`), so a provider that wants PV-backed state can have it.

Rejected:

- Read-only flag as the fix (my first interim idea): leaves the handshake open, bypassable with `Internals::SvREADONLY`, changes user-visible behaviour anyway.
- B2 (validate once, invalidate via set magic): cannot be made complete.
- Per-stash registry and XSUB allowlist: both need a per-object layout proof that the per-object design gets for free (4.3).
- Keeping integer-address methods but validating the integers against a table of known functions: fixes the function pointer but not the state pointer.

## 8. Questions for Yves

- Q1. Option A or B for the bundled providers? (Section 7 item 3.)
- Q2. Should a subclass that overrides `rand_bytes` lose the native fast path, so that `rand()` always honours the override? Today the override is bypassed and t/pcg.t asserts that.
- Q3. Deprecation path for `get_rand_U01_XS_*`: remove outright, or keep as warning stubs for a release?
- Q4. Should core allocate the state block (`Perl_rng_fast_register_new(referent, &d, size)` returning zeroed memory core owns), or should providers allocate and hand over?
- Q5. Thread clones currently duplicate the generator stream. Keep, reseed in the clone, or leave to each provider via `dup_state`?
- Q6. Should a reblessed provider that no longer derives from `RNG::Provider` make the next `rand()` croak, or silently fall back to the built-in generator?
- Q7. Is `Perl_rng_U01_func` (perl.h) considered public today? If so the signature change needs a new typedef name instead of a redefinition.
