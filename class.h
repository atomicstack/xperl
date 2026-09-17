/*    class.h
 *
 *    Copyright (C) 2025 by Stevan Little and others
 *
 *    You may distribute under the terms of either the GNU General Public
 *    License or the Artistic License, as specified in the README file.
 *
 */

/* Proto-role types and composition helpers for `use feature 'class'`.
 *
 * A proto-role records the fields and methods declared by a class or role.
 * During composition, slots with the same name are merged and their sets of
 * providers are combined. */

#ifndef PERL_CLASS_H
#define PERL_CLASS_H

/* --- Origin Set (Bitset) ------------------------------------------------
 *
 * Each proto-role participating in a composition is assigned a bit position.
 * An origin set is a bitset over these positions.
 *
 *   Required:   origins == 0   (no origin — pure obligation)
 *   Defined:    popcount == 1  (exactly one origin)
 *   Conflicted: popcount >  1  (multiple origins)
 *
 * Combining two slots amounts to taking the union of their provider sets.
 * The consumer occupies one bit, leaving 31 bits for roles.
 */

typedef U32 origin_set_t;

#define ORIGIN_SET_EMPTY    ((origin_set_t)0)
#define ORIGIN_SET_MAX_BITS 32

/* Compose two origin sets. */
#define compose_origins(a, b)  ((origin_set_t)((a) | (b)))

#define origin_is_required(o)   ((o) == 0)
#define origin_is_conflicted(o) (Perl_bitcount32(o) > 1)

/* --- Origin Map ---------------------------------------------------------
 *
 * Maps bit positions back to stash pointers for error messages and
 * ->DOES checks. Built at the start of a composition pipeline.
 */

typedef struct {
    HV    *stashes[ORIGIN_SET_MAX_BITS]; /* bit position -> stash pointer */
    U8     next_id;                      /* next available bit position */
} origin_map_t;

#define origin_map_init(map)  \
    STMT_START { Zero((map), 1, origin_map_t); } STMT_END

/* --- Method Slot --------------------------------------------------------
 *
 * The atomic unit of the method algebra. Carries its own name
 * (self-describing), matching the PADNAME/PADNAMELIST idiom.
 */

typedef struct method_slot {
    SV           *name;       /* method name (shared HEK-backed SV) */
    origin_set_t  origins;    /* bitset encoding (see above) */
    CV           *cv;         /* the method CV; NULL for Required */
    PADNAME      *from_field; /* field which generated this accessor, if any */
} method_slot_t;

/* --- Field Slot ---------------------------------------------------------
 *
 * Reuses existing PADNAME infrastructure. The PADNAME carries the field's
 * name, sigil, default, :param info, and fieldstash. We add the origin
 * bitset for composition tracking.
 */

typedef struct field_slot {
    PADNAME      *padname;    /* the PADNAME (carries name, sigil, fieldinfo) */
    origin_set_t  origins;    /* bitset encoding */
} field_slot_t;

/* --- Proto-Role ---------------------------------------------------------
 *
 * The intermediate representation for a class or role during construction
 * and composition. Allocated at parse time, populated incrementally,
 * composed and resolved at seal time.
 *
 * Slot arrays are sorted by name for efficient merge-join composition.
 */

typedef struct proto_role {
    HV              *stash;          /* the class/role stash (origin) */
    method_slot_t   *method_slots;   /* sorted by name */
    UV               method_count;
    UV               method_alloc;   /* allocated capacity */

    field_slot_t    *field_slots;    /* sorted by name */
    UV               field_count;
    UV               field_alloc;    /* allocated capacity */

    AV              *adjust_blocks;  /* ADJUST CVs (not part of the algebra) */
} proto_role_t;

/* --- Proto-Role Helpers ------------------------------------------------- */

/* Append a method slot to the proto-role (unsorted; sort before compose) */
PERL_STATIC_INLINE void
S_proto_role_add_method(pTHX_ proto_role_t *pr, SV *name,
                        origin_set_t origins, CV *cv, PADNAME *from_field)
{
    if (pr->method_count >= pr->method_alloc) {
        pr->method_alloc = pr->method_alloc ? pr->method_alloc * 2 : 8;
        Renew(pr->method_slots, pr->method_alloc, method_slot_t);
    }
    method_slot_t *slot = &pr->method_slots[pr->method_count++];
    slot->name       = SvREFCNT_inc(name);
    slot->origins    = origins;
    slot->cv         = cv ? (CV *)SvREFCNT_inc((SV *)cv) : NULL;
    slot->from_field = from_field ? PadnameREFCNT_inc(from_field) : NULL;
}
#define proto_role_add_method(pr, name, origins, cv, from_field) \
    S_proto_role_add_method(aTHX_ pr, name, origins, cv, from_field)

/* Append a field slot to the proto-role (unsorted; sort before compose) */
PERL_STATIC_INLINE void
S_proto_role_add_field(pTHX_ proto_role_t *pr, PADNAME *pn, origin_set_t origins)
{
    if (pr->field_count >= pr->field_alloc) {
        pr->field_alloc = pr->field_alloc ? pr->field_alloc * 2 : 4;
        Renew(pr->field_slots, pr->field_alloc, field_slot_t);
    }
    field_slot_t *slot = &pr->field_slots[pr->field_count++];
    slot->padname = PadnameREFCNT_inc(pn);
    slot->origins = origins;
}
#define proto_role_add_field(pr, pn, origins) \
    S_proto_role_add_field(aTHX_ pr, pn, origins)

/* Allocate a new proto-role */
PERL_STATIC_INLINE proto_role_t *
S_proto_role_new(pTHX_ HV *stash)
{
    proto_role_t *pr;
    Newxz(pr, 1, proto_role_t);
    pr->stash = stash;
    return pr;
}
#define proto_role_new(stash) S_proto_role_new(aTHX_ stash)

/* Free a proto-role and its contents */
PERL_STATIC_INLINE void
S_proto_role_free(pTHX_ proto_role_t *pr)
{
    if (!pr)
        return;

    for (UV i = 0; i < pr->method_count; i++) {
        SvREFCNT_dec(pr->method_slots[i].name);
        SvREFCNT_dec(pr->method_slots[i].cv);
        if (pr->method_slots[i].from_field)
            PadnameREFCNT_dec(pr->method_slots[i].from_field);
    }
    Safefree(pr->method_slots);

    for (UV i = 0; i < pr->field_count; i++) {
        PadnameREFCNT_dec(pr->field_slots[i].padname);
    }
    Safefree(pr->field_slots);

    SvREFCNT_dec(pr->adjust_blocks);

    Safefree(pr);
}
#define proto_role_free(pr) S_proto_role_free(aTHX_ pr)

#ifdef USE_ITHREADS
/* Duplicate the metadata owned by a class or role stash when its stash is
 * cloned into another interpreter.  The proto-role is not a Perl SV, so it
 * is not covered by the ordinary HV auxiliary-data duplication. */
PERL_STATIC_INLINE proto_role_t *
S_proto_role_dup(pTHX_ const proto_role_t *src, CLONE_PARAMS *param)
{
    proto_role_t *dst;
    Newxz(dst, 1, proto_role_t);

    dst->stash = src->stash ? hv_dup_inc(src->stash, param) : NULL;
    dst->method_count = src->method_count;
    dst->method_alloc = src->method_alloc;
    if (src->method_alloc)
        Newx(dst->method_slots, src->method_alloc, method_slot_t);
    for (UV i = 0; i < src->method_count; i++) {
        dst->method_slots[i].name = sv_dup_inc(src->method_slots[i].name, param);
        dst->method_slots[i].origins = src->method_slots[i].origins;
        dst->method_slots[i].cv = src->method_slots[i].cv
            ? cv_dup_inc(src->method_slots[i].cv, param) : NULL;
        dst->method_slots[i].from_field = src->method_slots[i].from_field
            ? padname_dup_inc(src->method_slots[i].from_field, param) : NULL;
    }

    dst->field_count = src->field_count;
    dst->field_alloc = src->field_alloc;
    if (src->field_alloc)
        Newx(dst->field_slots, src->field_alloc, field_slot_t);
    for (UV i = 0; i < src->field_count; i++) {
        dst->field_slots[i].padname =
            padname_dup_inc(src->field_slots[i].padname, param);
        dst->field_slots[i].origins = src->field_slots[i].origins;
    }

    dst->adjust_blocks = av_dup_inc(src->adjust_blocks, param);
    return dst;
}
#define proto_role_dup(pr, param) S_proto_role_dup(aTHX_ pr, param)
#endif

#endif /* PERL_CLASS_H */
