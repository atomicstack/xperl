# Dispatch/on: borrowed capture lifetime analysis

Originally reviewed after `41e8545b84` using a threaded DEBUGGING build.
The analysis below describes the implementation before the ownership fix.

**Status: implemented and validated.** Commits `6b778208fc` and `193542e2a7`
introduce the lazy mortal AV owner, traversal retention, exception-safe
publication storage and constraint-first capture collection. The chosen
contract retains ordinary SVs rather than snapshotting them: callbacks can
still change their values, but removing a source slot cannot free a retained
SV. The snapshot recommendation below was superseded by that decision.

Full threaded DEBUGGING and nonthreaded production suites, plus focused
ASan/LSan tests, passed. See
[`dispatch_on_constraint_first.md`](dispatch_on_constraint_first.md)
for the final behavior and exact validation results.

## Summary

Ordinary captures currently record a pointer to the source scalar, without
copying its value or retaining its lifetime. A later pattern callback can
overwrite or delete that scalar before bindings are published. Overwriting
changes what is captured; deletion can destroy a captured object too early
and cause internal errors.

There are related borrowed pointers outside the binding list: the current
subject passed to a pattern call, and containers traversed recursively.
Fixing only the binding list would therefore be incomplete.

## Execution and ownership

1. `pp_on` creates a temporary C array of `case_binding` records.
2. `S_dispatch_pattern_match` walks the shape. Plain and typed scalar captures
   set `value` to the input SV pointer and `owned` to false.
3. Further shape elements can execute zero-argument functions or methods,
   tied callbacks, or overloads. These can mutate the source structure.
4. Repeated bindings consult the stored pointer during matching. On success,
   `pp_on` copies it into the lexical pad before evaluating the guard.
5. Normal completion and open-array retry paths call `S_case_free_bindings`.
   This decrements only records marked owned.

The missing ownership is between steps 2 and 4. Delaying publication until
the whole shape succeeds is appropriate; delaying ownership of the observed
value until publication is not.

## Direct observations

The following probes were executed separately with warnings and strictness
enabled. No sanitizer was enabled for these runs.

| Probe | Observed result |
| --- | --- |
| Capture `"before"`, then overwrite its source with `"after"` | Captures `"after"` |
| Same probe with `ScalarVal($x)` | Captures `"after"` |
| Same overwrite through a hash field | Captures `"after"` |
| Same overwrite through a scalar-reference shape | Captures `"after"` |
| Capture an object, then delete its source element | Loses the reference |
| Deletion probe with a destructor printing a marker | Destructor runs before publication; internal copy error |
| Repeat the captured variable after changing its source | Can match the replacement value |
| Callback deletes the current comparison element | Reports a miss |
| Callback releases the nested array being traversed | Reports a miss |
| Tied scalar-referent snapshot control | Captures `"before"` |
| Previously captured array-tail copy control | Retains the original element |

The current-element and nested-array probes establish observable behavior,
not independently validated memory errors. The source shows unretained
pointers spanning callbacks in both paths. The deletion symptoms depend on
allocation and lifetime details: absence of a crash is not evidence of safety.

### Small reproducer with destruction ordering

```perl
use strict;
use warnings;
use feature qw(dispatch_on say);

package Box {
    sub DESTROY { say 'destroyed' }
}

my @values = (bless({}, 'Box'), 1);
sub remove_first {
    delete $values[0];
    say 'callback';
    return 1;
}

dispatch (\@values) {
    on ([$captured, remove_first()]) { say ref $captured }
}
```

The object is destroyed inside `remove_first`. The observed run then exits
255 with `Bizarre copy of ARRAY in dispatch pattern match`. Stderr/stdout buffering
can display the exception before the printed markers.

### Mutation without deletion

```perl
my @values = ('before', 1, 'after');
sub change_first { $values[0] = 'after'; return 1 }

dispatch (\@values) {
    on ([$x, change_first(), $x]) { say "hit:$x" }
    on (_) { say 'miss' }
}
```

Currently prints `hit:after`. Under capture-at-observation semantics, the
first capture is `before`, so the last requirement should fail.

## Why narrower fixes are insufficient

- **Copy only at publication:** too late; the source has already changed or
  been destroyed. This is essentially the current behavior.
- **Increment the source SV's refcount:** retains the scalar allocation,
  but an assignment can still overwrite its value. This does not implement
  independent captured values.
- **Copy only ordinary capture records:** protects those records, but not
  the current comparison subject or a recursively traversed container.
- **Deep-copy the subject:** unnecessary for lifetime safety, changes
  reference identity and magic behavior, and introduces graph-copy concerns.
- **Forbid zero-argument calls:** would not remove tied/overload callbacks
  or destructor re-entry, and would discard supported functionality.

## Recommended repair when this item is resumed

### 1. Define and preserve the observation boundary

Use a shallow value snapshot for each captured scalar at observation time.
Retain reference identity; do not clone the referent. Once copied, that
capture must not change because a later callback overwrites its source slot.

Protect a recursive match's current value before it invokes user code.
A copied reference retains its container even if the parent slot is removed.
The existing magical-value path already demonstrates fetching once followed
by a non-magical snapshot. Do not fetch tied values again while making or
publishing the snapshot.

This does not freeze the entire input graph. Decide separately how later
reads observe callbacks that resize or mutate an aggregate. At minimum,
avoid dangling pointers, stale SV/HE pointers, and unsafe traversal bounds.
Array lengths are currently computed before callbacks can mutate the array.

### 2. Give temporary values an exception-safe owner

Prefer ordinary SV/AV ownership and existing unwind mechanisms. One option
is a per-match-attempt AV owning snapshots, with binding records borrowing
only from that owner. Another is a scoped mortal-based scheme. Whichever
is chosen must survive nested callback temporary scopes and release values
on rejection, open-array retry, exceptions, and successful publication.

Do not merely change every record to `owned = TRUE`: cleanup currently runs
on explicit return paths, not on every exception path. Regex and concat
captures already own values and need inclusion in this audit. A completed
tail also has a binding-owned reference beyond its mortal allocation.
The recent tail change protects partial construction, not every subsequent
exception after that tail has been recorded.

Audit publication as well: its `pending` AV is attached to the dispatch context
only after the publication loop. Cleanup ownership should be established
before any operation that can throw or invoke a destructor.

### 3. Preserve transactional publication

Continue publishing bindings only after all structural requirements succeed,
then run the guard. Keep existing rollback behavior for rejected guards and
escaped closures. Temporary ownership must not reintroduce source aliases.

### 4. Validate beyond the minimal reproducer

Cover plain/typed captures, references, array/hash/native-object fields,
deletion and in-place replacement, nested container removal, repeated
bindings, open-array retries, and guard/closure behavior. Include mutation
from ties and overloads, not just explicit pattern calls.

Test exceptions after partial scalar, regex, concat, and tail captures;
destructor ordering/re-entry; recursive dispatch calls; and interpreter cloning.
Run focused ASan/LSan checks with `PERL_DESTRUCT_LEVEL=2`, then the relevant
threaded DEBUGGING and production suites. The suspected dangling-pointer
mechanism has not yet been independently diagnosed by a fresh sanitizer run.

## Scope and decision

This is a bounded runtime ownership repair, not a parser change or a reason
to redesign shape syntax. It is more than a one-line refcount fix because
snapshot semantics, callback safety and exception cleanup must agree.

Recommended contract: retain shallow observations, preserve reference
identity, and keep ordinary callback side effects visible to later reads.
Whether to freeze aggregate membership/length for an entire attempt is a
separate semantic decision; it is not required merely to retain captured
values safely. No implementation of these recommendations is included here.
