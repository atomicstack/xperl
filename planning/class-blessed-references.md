# Ordinary references and explicit inherited fields

## Representation

Every public modern instance is an ordinary blessed reference. Class-name
CONSTRUCT creates an undef scalar referent. Object-invoked CONSTRUCT keeps
its reference identity, referent type, contents, and blessing. Ordinary subs,
methods, XSUBs, and ADJUST receive this same public $self.

The public referent owns class-storage magic whose value is an internal,
unblessed PVOBJ. The PVOBJ owns metadata containing the effective package,
an ancestor-first list of modern classes, and per-class layout shifts.
The internal class object is the authority for storage validation. The
public SvSTASH provides standard Perl dispatch and compatibility.

The contiguous vector contains one slot per original declaration in the
effective hierarchy, including modern ancestors reached through legacy
packages or multiple @ISA paths. Shared ancestors contribute once. Existing
compiler class-layout indices and composed-role offsets are retained, then
translated through runtime class shifts. Composed role CVs carry their
consumer identity in a reserved pad. Role algebra and its conflict rules
remain the composition mechanism. There is no second public object,
weak backlink, invocant substitution, or :blessed_self attribute.

## Field declarations and inheritance

A plain field declaration owns storage. Distinct storage declarations with
the same full field name conflict throughout an object, including direct
modern ancestors. The sigil is part of the name, matching existing role
rules. Shared ancestor declarations are deduplicated. Known conflicts are
rejected when a class is sealed. Runtime conventional unions are validated
before a new object is blessed or any initialization runs.

field $foo :inherited declares a lexical alias to existing ancestor storage.
It preserves the child's lexical declaring stash and records strong
references to the original field PADNAME and the original storage consumer.
Aliases through several generations flatten to the same origin. They add
no role algebra slot, field slot, initializer, parameter, or serializer
entry. The original declaration owns initialization. No ancestor field is
implicitly introduced into descendant lexical scope.

An alias cannot have an initializer, :param, :private, a value, or repeated
:inherited. Reader/writer attributes can expose it. Missing, ambiguous, and
private origins are diagnosed at seal time. Conventional ancestry required
for alias resolution must already exist then, using BEGIN or use parent.
Runtime @ISA changes do not rebind sealed aliases. Construction checks that
all original alias owners are present in the effective layout.

field $foo :private prevents descendants from declaring an inherited alias.
It does not prevent the original class's methods from using the field on a
descendant object, nor hide the field from explicit serializers/debuggers.
Roles cannot declare :inherited because they have no class ancestry. A
class can alias a field from an ancestor's composed role.

OP_METHSTART retains its numeric auxiliary format. A binding's pad index
selects the alias metadata where necessary, then resolves that field through
its original storage owner. Bounds are checked per final field index.
Initializer CVs bind aliases before own defaults run. Own initializer target
maps exclude aliases so unrelated compiled indices cannot overwrite them.
Field info free/clone paths own and duplicate origin references and flags.

## Construction and serialization

Per-class CONSTRUCT/new aliases and custom new remain. A conventional-base
constructor creates the public reference, then calls $self->CONSTRUCT with
modern parameters. The default never calls conventional parent constructors.
Each class's own initializers run once in ancestor-first @ISA order, then
all own ADJUST blocks run once in the same order. Constructor parameter
names must be unique across distinct original declarations.

Argument-free repeated CONSTRUCT preserves an initialized object. Supplying
parameters again or reentering initialization/release is an error. Existing
objects whose initialization fails retain their ordinary payload and can
retry with fresh storage. Failed class-name construction preserves partial
fields through normal DESTROY. Layout validation failures occur before a
new referent is blessed, so they do not create spurious destruction calls.

The shallow field conversion APIs serialize original fields once. The
from_hash builtin accepts an optional unblessed payload reference and
validates storage before blessing it. Failed restoration keeps the caller's
payload unblessed with identity and contents preserved.

Data::Dumper wraps its ordinary referent dump in the restoration call.
Both implementations share graph handling between payload and fields;
Purity fixups use class_object_to_hash($object) field paths. The nonthrowing
is_class_object builtin avoids error probes and user die hooks. Object-shape
matching inspects attached modern fields. Devel::Peek describes the public
ordinary reference and hidden vector safely. Storable requires explicit
freeze/thaw hooks instead of silently discarding modern fields.

## Lifecycle

Only objects with attached modern state participate in TEARDOWN. Named
inherited lookup selects one hook, without AUTOLOAD or an automatic ancestor
walk. Parents require explicit SUPER delegation. A legacy package merely
naming TEARDOWN gains no behavior; an inherited legacy sub can serve as the
hook for an object that has modern storage.

Normal destruction calls DESTROY first. Its resurrection check decides
whether destruction proceeds. TEARDOWN runs with old blessing and fields
intact, then storage is released. TEARDOWN can resurrect the public reference,
but its state is released and the hook is not repeated. Later modern field
methods fail cleanly; ordinary DESTROY can run again on final release.

Reblessing into another package runs TEARDOWN, releases old state, then
applies the new blessing. It does not invoke DESTROY. Same-package bless
preserves storage and ordinary bless magic side effects. Explicit teardown
exceptions propagate, leaving the old blessing with modern state released.
Destruction follows the usual cleanup-error policy. Different-package
blessing during TEARDOWN is rejected.

The internal sv_unbless C helper uses this lifecycle, with XS-APItest
coverage. Raw XS SvOBJECT flag surgery cannot be intercepted. Field pads
and escaped aliases retain their individual SV references after storage
release. A release-fields marker permits field destructors to rebless the
owner but rejects reentrant storage attachment. Final cleanup hands storage
to sv_clear's existing iterative container walk through a temporary AV,
preserving depth-first reverse-field order before ordinary payload cleanup.
Explicit blessing/unblessing remains synchronous. A 100,000-node chain was
verified to free without C stack overflow after this integration.

## Validation record

The final build uses -Dusethreads -DDEBUGGING and -g -O1 with workspace
ccache. Final affected validation passes 102 files and 5,781 tests, covering
all class/role tests, inherited/private fields, croak/warning fixtures,
Devel::Peek, Data::Dumper, and Storable. The final __CLASS__ guard diagnoses
active-method unblessing safely while preserving the effective classname
after reblessing into a conventional package.

The broad harness excluding porting ran 3,110 files and 1,419,179 tests.
Its four obsolete class diagnostic expectations were corrected and verified
in the passing affected run. The other failures are 24 Encode taint tests
(numbers 251-254, 261-262, 267-268, and 473-488). They reproduce with the
original unmodified 5.45.5 nonthreaded interpreter, with the same failing
numbers and exit status 24. That baseline differs from the new threaded
debug build, so this is a matching baseline reproduction rather than a
claim of a configuration-identical comparison. No Encode change is included.

Final porting validation covers 47 files and 54,068 tests, excluding only
the unchanged diag_churn utility test which passed in the earlier full
porting run. One embed.fnc formatting failure was normalized through the
generator. All 122 regeneration checks then pass. The remaining porting
checks pass, including diagnostics, diagnostic packs and migration,
manifest, POD, API assertions, exports, headers, and platform checks.

ASan and LSan pass 251 class assertions across lifecycle91, hierarchy34,
inherited_fields52, and object_hash74. The final active-unbless guard was
rerun after its incremental build. All sanitizer processes use
PERL_DESTRUCT_LEVEL=2, detect_leaks=1, and an ordinary tmux shell with
TracerPid=0. No sanitizer reports remain. A 100,000-node acyclic class
chain frees successfully under the sanitizers. Initial clone leaks were
traced to double-counting newPADNAMEouter's existing field-info ownership;
the corrected conditional ownership is included and verified.

Final logs live in workspace tmp:

- class-blessed-final-build.log and class-blessed-final-focused.log
- class-blessed-final-full.log
- class-blessed-guard-focused.log (final 102-file passing affected run)
- class-blessed-final-porting.log and class-blessed-final-regen-detail.log
- class-blessed-baseline-encode-taint.log
- class-blessed-final-asan-tests.log and class-blessed-guard-asan-tests.log

Generated diagnostics, magic metadata, prototypes, and English pack data
are regenerated from their inputs. The historical broad regen_headers target
passes unsupported -v to diag_pack.pl, so its narrow generators were used
where needed. MANIFEST contains the new tests and was sorted through
make manisort. The interrupted Devel-PPPort ppptmp test artifact is excluded.
No shared skills or unrelated worktrees were changed.
