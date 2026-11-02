/*    hv.h
 *
 *    Copyright (C) 1991, 1992, 1993, 1996, 1997, 1998, 1999,
 *    2000, 2001, 2002, 2003, 2005, 2006, 2007, 2008, by Larry Wall and others
 *
 *    You may distribute under the terms of either the GNU General Public
 *    License or the Artistic License, as specified in the README file.
 *
 */

#ifdef PERL_USE_UNSHARED_KEYS_IN_LARGE_HASHES
#define LARGE_HASH_HEURISTIC(hv,new_max) S_large_hash_heuristic(aTHX_ (hv), (new_max))
#else
#define LARGE_HASH_HEURISTIC(hv,new_max) 0
#endif


/* Compact hash entry. */
struct he {
    HEK		*hent_hek;	/* hash key */
    union {
        SV	*hent_val;	/* scalar value that was hashed */
        Size_t	hent_refcount;	/* references for this shared hash key */
        HE      *hent_next_pool; /* tied-fetch pool link while retired */
    } he_valu;
};

#define HV_OA_DELETED U32_MAX

struct hv_oa {
    HE *entries;
    U32 capacity;
    U32 used;
    U32 tombstones;
    U8 indices[1];
};

#define HvOA_INDEX_WIDTH_FOR(capacity) \
    ((capacity) <= 128 ? 1 : (capacity) <= 32768 ? 2 : 4)
#define HvOA_INDEX_WIDTH(hv) \
    HvOA_INDEX_WIDTH_FOR((U32)HvMAX(hv) + 1)
#define HvOA_INDEX_BYTES_FOR(capacity) \
    ((Size_t)(capacity) * HvOA_INDEX_WIDTH_FOR(capacity))
#define HvOA_INDEX_REGION(oa,capacity) ((U8 *)(oa)->indices)


#define HvOA_INDEX_GET(hv,pos) \
    S_hv_oa_index_get(HvOA(hv), (U32)HvMAX(hv) + 1, (U32)(pos))
#define HvOA_INDEX_SET(hv,pos,value) \
    S_hv_oa_index_set(HvOA(hv), (U32)HvMAX(hv) + 1, (U32)(pos), (U32)(value))


/* hash key -- defined separately for use as shared pointer */
struct hek {
    U32         hek_hash;        /* computed hash of key */
    I32         hek_len;        /* length of the hash key */
    /* Be careful! Sometimes we store a pointer in the hek_key
     * buffer, which means it must be 8 byte aligned or things
     * dont work on aligned platforms like HPUX
     * Also beware, the last byte of the hek_key buffer is a
     * hidden flags byte about the key. */
     char       hek_key[1];        /* variable-length hash key */
    /* the hash-key is \0-terminated */
    /* after the \0 there is a byte for flags, such as whether the key
       is UTF-8 or WAS-UTF-8, or an SV */
};

struct shared_hek {
    Size_t refcount;
    struct hek shared_hek_hek;
};

struct hv_strtab_pin {
    struct hv_strtab_pin *next;
    HEK *hek;
    Size_t count;
};

struct hv_strtab {
    struct hv_strtab_pin *pins;
    U32 tombstones;
    HEK *slots[1];
};

/* Subject to change.
   Don't access this directly.
   Use the funcs in mro_core.c
*/

struct mro_alg {
    AV *(*resolve)(pTHX_ HV* stash, U32 level);
    const char *name;
    U16 length;
    U16	kflags;	/* For the hash API - set HVhek_UTF8 if name is UTF-8 */
    U32 hash; /* or 0 */
};

struct mro_meta {
    /* a hash holding the different MROs private data.  */
    HV      *mro_linear_all;
    /* a pointer directly to the current MROs private data.  If mro_linear_all
       is NULL, this owns the SV reference, else it is just a pointer to a
       value stored in and owned by mro_linear_all.  */
    SV      *mro_linear_current;
    HV      *mro_nextmethod; /* next::method caching */
    U32     cache_gen;       /* Bumping this invalidates our method cache */
    U32     pkg_gen;         /* Bumps when local methods/@ISA change */
    const struct mro_alg *mro_which; /* which mro alg is in use? */
    HV      *isa;            /* Everything this class @ISA */
    HV      *super;          /* SUPER method cache */
    CV      *destroy;        /* DESTROY method if destroy_gen non-zero */
    U32     destroy_gen;     /* Generation number of DESTROY cache */
};

#define MRO_GET_PRIVATE_DATA(smeta, which)		   \
    (((smeta)->mro_which && (which) == (smeta)->mro_which) \
     ? (smeta)->mro_linear_current			   \
     : Perl_mro_get_private_data(aTHX_ (smeta), (which)))

/* Subject to change.
   Don't access this directly.
*/

union xhvnameu_ {
    HEK *xhvnameu_name;		/* When xhv_name_count is 0 */
    HEK **xhvnameu_names;	/* When xhv_name_count is non-0 */
};

/* A struct defined by pad.h and used within class.c */
struct suspended_compcv;
struct proto_role;

struct xpvhv_aux {
    union xhvnameu_ xhv_name_u;	/* name, if a symbol table */
    AV		*xhv_backreferences; /* back references for weak references */
    HE		*xhv_eiter;	/* current entry of iterator */
    I32		xhv_riter;	/* current root of iterator */

/* Concerning xhv_name_count: When non-zero, xhv_name_u contains a pointer
 * to an array of HEK pointers, this being the length. The first element is
 * the name of the stash, which may be NULL. If xhv_name_count is positive,
 * then *xhv_name is one of the effective names. If xhv_name_count is nega-
 * tive, then xhv_name_u.xhvnameu_names[1] is the first effective name.
 */
    I32		xhv_name_count;
    struct mro_meta *xhv_mro_meta;
    U32         xhv_aux_flags;      /* assorted extra flags */

    /* These fields are valid for class and role stashes. */
    HV          *xhv_class_legacy_parent;
    PADOFFSET    xhv_class_legacy_self; /* field index + 1, or zero */
    HV          *xhv_class_superclass;         /* STASH of the :isa() base class */
    CV          *xhv_class_initfields_cv;      /* CV for running initfields */
    AV          *xhv_class_adjust_blocks;      /* CVs containing the ADJUST blocks */
    PADNAMELIST *xhv_class_fields;             /* PADNAMEs with PadnameIsFIELD() */
    PADOFFSET    xhv_class_next_fieldix;
    HV          *xhv_class_param_map;          /* Maps param names to field index stored in UV */
    AV          *xhv_class_pending_method_cvs; /* method CVs needing field binding at seal time */

    struct suspended_compcv
                *xhv_class_suspended_initfields_compcv;

    AV          *xhv_class_pending_roles;      /* roles awaiting composition */
    AV          *xhv_class_roles;              /* direct and transitive roles */
    struct proto_role *xhv_class_proto_role;   /* declared composition slots */
};

#define HvAUXf_SCAN_STASH   0x1   /* stash is being scanned by gv_check */
#define HvAUXf_NO_DEREF     0x2   /* @{}, %{} etc (and nomethod) not present */
#define HvAUXf_IS_CLASS     0x4   /* the package is a 'class' */
#define HvAUXf_IS_ROLE      0x8   /* the package is a 'role' */
#define HvAUXf_IS_CLASS_SEALED 0x10
#define HvAUXf_ITER_INSERTED   0x20
#define HvAUXf_ITER_ACTIVE     0x40

#define HvSTASH_IS_CLASS(hv) \
    (HvHasAUX(hv) && HvAUX(hv)->xhv_aux_flags & HvAUXf_IS_CLASS)
#define HvSTASH_IS_CLASS_SEALED(hv) \
    (HvHasAUX(hv) && HvAUX(hv)->xhv_aux_flags & HvAUXf_IS_CLASS_SEALED)

#define HvSTASH_IS_ROLE(hv) \
    (HvHasAUX(hv) && HvAUX(hv)->xhv_aux_flags & HvAUXf_IS_ROLE)

#define HvSTASH_IS_CLASS_OR_ROLE(hv) \
    (HvHasAUX(hv) && HvAUX(hv)->xhv_aux_flags & (HvAUXf_IS_CLASS | HvAUXf_IS_ROLE))

#define HvCLASS_IS_SEALED(hv) \
    HvSTASH_IS_CLASS_SEALED(hv)

/* hash structure: */
/* This structure must match the beginning of struct xpvmg in sv.h. */
struct xpvhv {
    HV*		xmg_stash;	/* class package */
    union xmgu_	xmg_u;
    STRLEN      xhv_keys;       /* total keys, including placeholders */
    STRLEN      xhv_max;        /* subscript of last element of xhv_array */
};

struct xpvhv_with_aux {
    HV         *xmg_stash;      /* class package */
    union xmgu_ xmg_u;
    STRLEN      xhv_keys;       /* total keys, including placeholders */
    STRLEN      xhv_max;        /* subscript of last element of xhv_array */
    struct xpvhv_aux xhv_aux;
};

/*
=for apidoc_section $HV

=for apidoc      Am|HV *|HvREFCNT_inc|HV *hv
=for apidoc_item   |HV *|HvREFCNT_inc_simple|HV *hv
=for apidoc_item   |HV *|HvREFCNT_inc_simple_NN|HV *hv

These all increment the reference count of the given SV, which must be a HV.
They are useful when assigning the result into a typed pointer as they avoid
the need to cast the result to the appropriate type.

=cut
*/

#define HvREFCNT_inc(hv)            ((HV *)SvREFCNT_inc((SV *)hv))
#define HvREFCNT_inc_simple(hv)     ((HV *)SvREFCNT_inc_simple((SV *)hv))
#define HvREFCNT_inc_simple_NN(hv)  ((HV *)SvREFCNT_inc_simple_NN((SV *)hv))

/*
=for apidoc AmnU||HEf_SVKEY
This flag, used in the length slot of hash entries and magic structures,
specifies the structure contains an C<SV*> pointer where a C<char*> pointer
is to be expected.  (For information only--not to be used).

=for apidoc ADmnU||Nullhv
Null HV pointer.

(deprecated - use C<(HV *)NULL> instead)

=for apidoc Am|char*|HvNAME|HV* stash
Returns the package name of a stash, or C<NULL> if C<stash> isn't a stash.
See C<L</SvSTASH>>, C<L</CvSTASH>>.

=for apidoc Am|STRLEN|HvNAMELEN|HV *stash
Returns the length of the stash's name.

=for apidoc Am|HEK *|HvNAME_HEK|HV *stash
Returns the package name directly as a hash key structure, or C<NULL> if
C<stash> isn't a stash.

=cut

Disfavored forms of HvNAME and HvNAMELEN; suppress mention of them

=for apidoc Cmh|char*|HvNAME_get|HV* stash
=for apidoc Amh|I32|HvNAMELEN_get|HV* stash

=for apidoc Am|unsigned char|HvNAMEUTF8|HV *stash
Returns true if the name is in UTF-8 encoding.

=for apidoc Am|char*|HvENAME|HV* stash
Returns the effective name of a stash, or NULL if there is none.  The
effective name represents a location in the symbol table where this stash
resides.  It is updated automatically when packages are aliased or deleted.
A stash that is no longer in the symbol table has no effective name.  This
name is preferable to C<HvNAME> for use in MRO linearisations and isa
caches.

=for apidoc Am|STRLEN|HvENAMELEN|HV *stash
Returns the length of the stash's effective name.

=for apidoc Am|unsigned char|HvENAMEUTF8|HV *stash
Returns true if the effective name is in UTF-8 encoding.

=for apidoc Am|void*|HeKEY|HE* he
Returns the actual pointer stored in the key slot of the hash entry.  The
pointer may be either C<char*> or C<SV*>, depending on the value of
C<HeKLEN()>.  Can be assigned to.  The C<HePV()> or C<HeSVKEY()> macros are
usually preferable for finding the value of a key.

=for apidoc Am|HEK *|HeKEY_hek|HE *he
Returns the underlying hash key structure stored in the hash entry.

=for apidoc Am|STRLEN|HeKLEN|HE* he
If this is negative, and amounts to C<HEf_SVKEY>, it indicates the entry
holds an C<SV*> key.  Otherwise, holds the actual length of the key.  Can
be assigned to.  The C<HePV()> macro is usually preferable for finding key
lengths.

=for apidoc Am|SV*|HeVAL|HE* he
Returns the value slot (type C<SV*>)
stored in the hash entry.  Can be assigned
to.

  SV *foo= HeVAL(he);
  HeVAL(he)= sv;


=for apidoc Am|U32|HeHASH|HE* he
Returns the computed hash stored in the hash entry.

=for apidoc Am|char*|HePV|HE* he|STRLEN len
Returns the key slot of the hash entry as a C<char*> value, doing any
necessary dereferencing of possibly C<SV*> keys.  The length of the string
is placed in C<len> (this is a macro, so do I<not> use C<&len>).  If you do
not care about what the length of the key is, you may use the global
variable C<PL_na>, though this is rather less efficient than using a local
variable.  Remember though, that hash keys in perl are free to contain
embedded nulls, so using C<strlen()> or similar is not a good way to find
the length of hash keys.  This is very similar to the C<SvPV()> macro
described elsewhere in this document.  See also C<L</HeUTF8>>.

If you are using C<HePV> to get values to pass to C<newSVpvn()> to create a
new SV, you should consider using C<newSVhek(HeKEY_hek(he))> as it is more
efficient.

=for apidoc Am|U32|HeUTF8|HE* he
Returns whether the C<char *> value returned by C<HePV> is encoded in UTF-8,
doing any necessary dereferencing of possibly C<SV*> keys.  The value returned
will be 0 or non-0, not necessarily 1 (or even a value with any low bits set),
so B<do not> blindly assign this to a C<bool> variable, as C<bool> may be a
typedef for C<char>.

=for apidoc Am|SV*|HeSVKEY|HE* he
Returns the key as an C<SV*>, or C<NULL> if the hash entry does not
contain an C<SV*> key.

=for apidoc Am|SV*|HeSVKEY_force|HE* he
Returns the key as an C<SV*>.  Will create and return a temporary mortal
C<SV*> if the hash entry contains only a C<char*> key.

=for apidoc Am|SV*|HeSVKEY_set|HE* he|SV* sv
Sets the key to a given C<SV*>, taking care to set the appropriate flags to
indicate the presence of an C<SV*> key, and returns the same
C<SV*>.

=for apidoc Am|U32|HEK_HASH|HEK *hek
Returns the hash value associated with the given hash key structure.

=for apidoc Am|I32|HEK_LEN|HEK *hek
If non-negative, indicates the length of the string stored by the hash key
structure. It may also be negative and equal to C<HEf_SVKEY>, indicating that
the hash key is not in fact a string but a stored SV pointer value.

=for apidoc Am|char *|HEK_KEY|HEK *hek
If L</HEK_LEN> is non-negative, returns a pointer to the stored string. The
length of the string is given by C<HEK_LEN>, which does not include a
terminating NUL (C<\0>) byte which follows.

If L</HEK_LEN> is negative and equal to C<HEf_SVKEY>, then C<HEK_KEY> returns
a pointer to an SV * - i.e. its value should be treated as C<SV **>.

=for apidoc Am|bool|HEK_UTF8|HEK *hek
Returns true if the hash key structure's string should be considered as UTF-8.

=for apidoc Am|bool|HEK_WASUTF8|HEK *hek
Returns true if the hash key structure's string should be considered as plain
bytes, but they were given as a UTF-8 encoded string to L</share_hek>. This
happens if the encoded codepoints did not exceed the range 0 to 255, and were
thus converted down to plain bytes.

=cut
*/

#define PERL_HASH_DEFAULT_HvMAX 7

/* The high bit of xhv_max marks a headerless, dense linear HE array.  The
 * remaining bits hold its allocated capacity. */
#define HV_LINEAR_FLAG ((STRLEN)1 << (sizeof(STRLEN) * CHAR_BIT - 1))
#define HV_LINEAR_CAP_MASK (~HV_LINEAR_FLAG)

/* these hash entry flags ride on hent_klen (for use only in magic/tied HVs) */
#define HEf_SVKEY	-2	/* hent_key is an SV* */

#ifndef PERL_CORE
#  define Nullhv Null(HV*)
#endif
#define HvARRAY(hv)	((hv)->sv_u.svu_hash)

/*

=for apidoc Am|STRLEN|HvFILL|HV *const hv

Returns the number of hash buckets that happen to be in use.

As of perl 5.25 this function is used only for debugging
purposes, and the number of used hash buckets is not
in any way cached, thus this function can be costly
to execute as it must iterate over all the buckets in the
hash.

=cut

*/

#define HvFILL(hv)	Perl_hv_fill(aTHX_ MUTABLE_HV(hv))
#define HvMAX_RAW(hv)	(((XPVHV*)SvANY(hv))->xhv_max)
#define HvIS_LINEAR(hv) (HvMAX_RAW(hv) & HV_LINEAR_FLAG)
#define HvLINEAR_CAP(hv) ((U32)(HvMAX_RAW(hv) & HV_LINEAR_CAP_MASK))
#define HvMAX(hv) (HvIS_LINEAR(hv) \
                   ? (STRLEN)(HvLINEAR_CAP(hv) ? HvLINEAR_CAP(hv) - 1 : 0) \
                   : HvMAX_RAW(hv))
#define HvMAX_SET(hv,max) (HvMAX_RAW(hv) = (STRLEN)(max))
#define HvMAX_SET_LINEAR(hv,cap) \
    (HvMAX_RAW(hv) = HV_LINEAR_FLAG | (STRLEN)(cap))

/*

=for apidoc Am|bool|HvHasAUX|HV *const hv

Returns true if the HV has a C<struct xpvhv_aux> extension. Use this to check
whether it is valid to call C<HvAUX()>.

=cut

*/
#define HvHasAUX(hv)	(SvFLAGS(hv) & SVphv_HasAUX)

/* This quite intentionally does no flag checking first. That's your
   responsibility. Use HvHasAUX() first */
#define HvAUX(hv)       (&(((struct xpvhv_with_aux*)  SvANY(hv))->xhv_aux))
#define HvRITER(hv)	(*Perl_hv_riter_p(aTHX_ MUTABLE_HV(hv)))
#define HvEITER(hv)	(*Perl_hv_eiter_p(aTHX_ MUTABLE_HV(hv)))
#define HvRITER_set(hv,r)	Perl_hv_riter_set(aTHX_ MUTABLE_HV(hv), r)
#define HvEITER_set(hv,e)	Perl_hv_eiter_set(aTHX_ MUTABLE_HV(hv), e)
#define HvRITER_get(hv)	(HvHasAUX(hv) ? HvAUX(hv)->xhv_riter : -1)
#define HvEITER_get(hv)	(HvHasAUX(hv) ? HvAUX(hv)->xhv_eiter : NULL)

#define HvNAME(hv)	HvNAME_get(hv)
#define HvNAMELEN(hv)   HvNAMELEN_get(hv)
#define HvENAME(hv)	HvENAME_get(hv)
#define HvENAMELEN(hv)  HvENAMELEN_get(hv)

/* Checking that hv is a valid package stash is the
   caller's responsibility */
#define HvMROMETA(hv) (HvAUX(hv)->xhv_mro_meta \
                       ? HvAUX(hv)->xhv_mro_meta \
                       : Perl_mro_meta_init(aTHX_ hv))

#define HvNAME_HEK_NN(hv)			  \
 (						  \
  HvAUX(hv)->xhv_name_count			  \
  ? *HvAUX(hv)->xhv_name_u.xhvnameu_names	  \
  : HvAUX(hv)->xhv_name_u.xhvnameu_name		  \
 )

#define HvNAME_HEK(hv) \
        (HvHasAUX(hv) && HvAUX(hv)->xhv_name_u.xhvnameu_name ? HvNAME_HEK_NN(hv) : NULL)
#define HvHasNAME(hv) \
        (HvHasAUX(hv) && HvAUX(hv)->xhv_name_u.xhvnameu_name && HvNAME_HEK_NN(hv))
#define HvNAME_get(hv) \
        (HvHasNAME(hv) ? HEK_KEY(HvNAME_HEK_NN(hv)) : NULL)
#define HvNAMELEN_get(hv) \
        ((HvHasAUX(hv) && HvAUX(hv)->xhv_name_u.xhvnameu_name && HvNAME_HEK_NN(hv)) \
                                 ? HEK_LEN(HvNAME_HEK_NN(hv)) : 0)
#define HvNAMEUTF8(hv) \
        ((HvHasAUX(hv) && HvAUX(hv)->xhv_name_u.xhvnameu_name && HvNAME_HEK_NN(hv)) \
                                 ? HEK_UTF8(HvNAME_HEK_NN(hv)) : 0)
#define HvENAME_HEK_NN(hv)                                             \
 (                                                                      \
  HvAUX(hv)->xhv_name_count > 0   ? HvAUX(hv)->xhv_name_u.xhvnameu_names[0] : \
  HvAUX(hv)->xhv_name_count < -1  ? HvAUX(hv)->xhv_name_u.xhvnameu_names[1] : \
  HvAUX(hv)->xhv_name_count == -1 ? NULL                              : \
                                    HvAUX(hv)->xhv_name_u.xhvnameu_name \
 )
#define HvHasENAME_HEK(hv) \
        (HvHasAUX(hv) && HvAUX(hv)->xhv_name_u.xhvnameu_name)
#define HvENAME_HEK(hv) \
        (HvHasENAME_HEK(hv) ? HvENAME_HEK_NN(hv) : NULL)
#define HvHasENAME(hv) \
        (HvHasENAME_HEK(hv) && HvAUX(hv)->xhv_name_count != -1)
#define HvENAME_get(hv) \
        (HvHasENAME(hv) ? HEK_KEY(HvENAME_HEK_NN(hv)) : NULL)
#define HvENAMELEN_get(hv) \
        (HvHasENAME(hv) ? HEK_LEN(HvENAME_HEK_NN(hv)) : 0)
#define HvENAMEUTF8(hv) \
        (HvHasENAME(hv) ? HEK_UTF8(HvENAME_HEK_NN(hv)) : 0)

/*
 * HvKEYS gets the number of keys that actually exist(), and is provided
 * for backwards compatibility with old XS code. The core uses HvUSEDKEYS
 * (keys, excluding placeholders) and HvTOTALKEYS (including placeholders)
 */
#define HvKEYS(hv)		HvUSEDKEYS(hv)
#define HvUSEDKEYS(hv)		(HvTOTALKEYS(hv) - HvPLACEHOLDERS_get(hv))
#define HvTOTALKEYS(hv)         (((XPVHV*) SvANY(hv))->xhv_keys)
#define HvPLACEHOLDERS(hv)	(*Perl_hv_placeholders_p(aTHX_ MUTABLE_HV(hv)))
#define HvPLACEHOLDERS_get(hv)	(SvMAGIC(hv) ? Perl_hv_placeholders_get(aTHX_ (const HV *)hv) : 0)
#define HvPLACEHOLDERS_set(hv,p)	Perl_hv_placeholders_set(aTHX_ MUTABLE_HV(hv), p)

/* This (now) flags whether *new* keys in the hash will be allocated from the
 * shared string table. We have a heuristic to call HvSHAREKEYS_off() if a hash
 * is "getting large". After which, the first keys in that hash will be from
 * the shared string table, but subsequent keys will not be.
 *
 * If we didn't do this, we'd have to reallocate all keys when we switched this
 * flag, which would be work for no real gain. */
#define HvSHAREKEYS(hv)		(SvFLAGS(hv) & SVphv_SHAREKEYS)
#define HvSHAREKEYS_on(hv)	(SvFLAGS(hv) |= SVphv_SHAREKEYS)
#define HvSHAREKEYS_off(hv)	(SvFLAGS(hv) &= ~SVphv_SHAREKEYS)

/* This is an optimisation flag. It won't be set if all hash keys have a 0
 * flag. Currently the only flags relate to utf8.
 * Hence it won't be set if all keys are 8 bit only. It will be set if any key
 * is utf8 (including 8 bit keys that were entered as utf8, and need upgrading
 * when retrieved during iteration. It may still be set when there are no longer
 * any utf8 keys.
 * See HVhek_ENABLEHVKFLAGS for the trigger.
 */
#define HvHASKFLAGS(hv)		(SvFLAGS(hv) & SVphv_HASKFLAGS)
#define HvHASKFLAGS_on(hv)	(SvFLAGS(hv) |= SVphv_HASKFLAGS)
#define HvHASKFLAGS_off(hv)	(SvFLAGS(hv) &= ~SVphv_HASKFLAGS)

#define HvLAZYDEL(hv)		(SvFLAGS(hv) & SVphv_LAZYDEL)
#define HvLAZYDEL_on(hv)	(SvFLAGS(hv) |= SVphv_LAZYDEL)
#define HvLAZYDEL_off(hv)	(SvFLAGS(hv) &= ~SVphv_LAZYDEL)

#ifndef PERL_CORE

/*
=for apidoc ABmn|HE*|Nullhe

Null HE pointer.

=cut
*/

#  define Nullhe Null(HE*)
#endif
#define HePOOL_NEXT(he)		((he)->he_valu.hent_next_pool)
#define HvIS_OA(hv)		((const HV *)(hv) != PL_strtab)
#define HvIS_STRTAB(hv)		((const HV *)(hv) == PL_strtab)
#define HvSTR_TOMBSTONE		INT2PTR(HEK *, 1)
#define HvSTRTAB(hv)		((struct hv_strtab *)HvARRAY(hv))
#define HvSTRSLOTS(hv)		(HvSTRTAB(hv)->slots)
#define HvSTR_BYTES_FOR(capacity) \
    (STRUCT_OFFSET(struct hv_strtab, slots) + (capacity) * sizeof(HEK *))
#define HvSTR_SHARED(hek) \
    ((struct shared_hek *)((char *)(hek) \
      - STRUCT_OFFSET(struct shared_hek, shared_hek_hek)))
#define HvSTR_REFCOUNT(hek)	(HvSTR_SHARED(hek)->refcount)
#define HvOA(hv)		((struct hv_oa *)HvARRAY(hv))
#define HvENTRIES(hv) \
    (HvIS_LINEAR(hv) ? (HE *)HvARRAY(hv) : \
     (HvARRAY(hv) ? HvOA(hv)->entries : NULL))
/*
=for apidoc_section $HV
=for apidoc Cm|HE *|HePOOL_NEXT|HE *he

Accesses the next free tied-fetch entry. The value field stores this link only
while the HE is retired in the tied-fetch pool.

=for apidoc Cmn|U32|HV_OA_DELETED

The reserved index-slot entry value identifying a tombstone.

=for apidoc Cm|HEK **|HvSTRSLOTS|HV *hv

Returns the shared string table's HEK pointer slots.

=for apidoc Cm|struct hv_strtab *|HvSTRTAB|HV *hv

Returns the shared string table header.

=for apidoc Cmn|HEK *|HvSTR_TOMBSTONE

The shared string table slot value marking a deleted key.

=for apidoc Cm|Size_t|HvSTR_REFCOUNT|HEK *hek

Returns the reference count for a shared HEK.

=for apidoc Cm|struct shared_hek *|HvSTR_SHARED|HEK *hek

Returns the allocation containing a shared HEK.

=for apidoc Cm|Size_t|HvSTR_BYTES_FOR|U32 capacity

Returns the allocation size for a shared string table with the given
capacity.

=for apidoc Cm|U32|HvOA_INDEX_WIDTH_FOR|U32 capacity

Returns the stored entry-index width: one byte through 128 slots, two bytes
through 32,768 slots, and four bytes above that.

=for apidoc Cm|U32|HvOA_INDEX_WIDTH|HV *hv

Returns the stored entry-index width for C<hv>.

=for apidoc Cm|Size_t|HvOA_INDEX_BYTES_FOR|U32 capacity

Returns the byte size of the compact entry-index region for C<capacity>
slots.

=for apidoc Cm|U8 *|HvOA_INDEX_REGION|struct hv_oa *oa|U32 capacity

Returns the compact entry-index region after the open-addressed header.

=for apidoc Cm|struct hv_oa *|HvOA|HV *hv

Returns the open-addressed storage header. The hash must have an allocated
index and must not be the shared string table.

=for apidoc Cm|U32|HvOA_INDEX_GET|HV *hv|U32 pos

Returns an entry index encoded as index plus one, zero for an empty slot,
or C<HV_OA_DELETED> for a tombstone.

=for apidoc Cm|void|HvOA_INDEX_SET|HV *hv|U32 pos|U32 value

Stores a normalized encoded entry index, empty value, or tombstone.

=for apidoc Cm|bool|HvIS_OA|HV *hv

Returns true for ordinary hashes using compact HE entries. They may use a
small linear array or an open-addressed index. The shared string table uses a
separate HEK pointer index.

=for apidoc Cm|bool|HvIS_STRTAB|HV *hv

Returns true for the interpreter's shared string table.

=for apidoc Cm|bool|HvIS_LINEAR|HV *hv

Returns true when C<hv> stores its entries in a small, headerless dense array.

=for apidoc Cmn|STRLEN|HV_LINEAR_FLAG

The tag bit in the raw maximum field identifying headerless linear storage.

=for apidoc Cmn|STRLEN|HV_LINEAR_CAP_MASK

The mask extracting the linear entry capacity from the raw maximum field.

=for apidoc Cm|STRLEN|HvMAX_RAW|HV *hv

Accesses the raw maximum field, including the linear-storage tag. Use
C<HvMAX> for the logical maximum and the form-specific setters for updates.

=for apidoc Cm|U32|HvLINEAR_CAP|HV *hv

Returns the allocated entry capacity for a headerless linear hash.

=for apidoc Cm|HE *|HvENTRIES|HV *hv

Returns the compact entry array for either linear or indexed storage.

=for apidoc Cm|void|HvMAX_SET|HV *hv|STRLEN max

Sets the index maximum for an indexed hash. C<HvMAX> is read-only.

=for apidoc Cm|void|HvMAX_SET_LINEAR|HV *hv|U32 capacity

Sets the capacity for headerless linear storage. C<HvMAX> is read-only.

=for apidoc Amx|STRLEN|HvENTRY_LIMIT|HV *hv

Returns the storage traversal limit for XPerl's experimental hash layout.

=for apidoc Amx|HE *|HvENTRY_FIRST|HV *hv|STRLEN index

Returns the first live entry at storage position C<index>, or NULL for a
vacant position. C<index> must be less than C<HvENTRY_LIMIT(hv)>.

=for apidoc Amx|HE *|HvENTRY_NEXT|HV *hv|HE *entry

Returns the next entry at the same storage position, or NULL. Compact
entry arrays have one entry per position. PL_strtab contains HEK pointers,
not HE records, and is not traversed through these macros.

These macros traverse storage without changing the hash iterator. Obtain
each position with C<HvENTRY_FIRST> and follow it with C<HvENTRY_NEXT>.
Entry-array growth, compaction, and transitions between a singleton HE and
an entry array invalidate returned entry pointers. Compaction also changes
integer positions. Retain keys and refetch entries after callbacks that can
insert or delete keys. The SV values remain separately allocated.

=cut
*/
/* Direct traversal leaves the public iterator state untouched. A current
 * lazily deleted entry owns its key until iterator advance or reset. */
#define HvENTRY_LIMIT(hv) \
    (HvIS_STRTAB(hv) ? 0 : HvIS_LINEAR(hv) ? HvTOTALKEYS(hv) : \
     HvIS_OA(hv) ? (HvARRAY(hv) ? HvOA(hv)->used : 0) : HvMAX(hv) + 1)
#define HvENTRY_FIRST(hv,i) \
    (HvIS_STRTAB(hv) ? NULL : HvIS_LINEAR(hv) ? (HvARRAY(hv) ? &((HE *)HvARRAY(hv))[(i)] : NULL) : HvIS_OA(hv) \
     ? ((HvARRAY(hv) && HvOA(hv)->entries[(i)].hent_hek \
         && !(HvLAZYDEL(hv) \
              && &HvOA(hv)->entries[(i)] == HvEITER_get(hv))) \
        ? &HvOA(hv)->entries[(i)] : NULL) \
     : HvARRAY(hv)[i])
#define HvENTRY_NEXT(hv,e) NULL
#define HvENTRY_INDEX(hv,sptr,idx) \
    (HvIS_OA(hv) && !HvIS_LINEAR(hv) && HvARRAY(hv) && HvOA(hv)->entries \
     && PTR2UV(sptr) >= PTR2UV(&HeVAL(HvOA(hv)->entries)) \
     && (PTR2UV(sptr) - PTR2UV(&HeVAL(HvOA(hv)->entries))) \
        % sizeof(HE) == 0 \
     && (PTR2UV(sptr) - PTR2UV(&HeVAL(HvOA(hv)->entries))) \
        / sizeof(HE) < HvOA(hv)->used \
     && (((idx) = (U32)((PTR2UV(sptr) \
                        - PTR2UV(&HeVAL(HvOA(hv)->entries))) / sizeof(HE))), 1))
#define HvENTRY_SVP(hv,idx)	(&HeVAL(&HvENTRIES(hv)[(idx)]))
#define HeKEY_hek(he)		(he)->hent_hek
#define HeKEY(he)		HEK_KEY(HeKEY_hek(he))
#define HeKEY_sv(he)		(*(SV**)HeKEY(he))
#define HeKLEN(he)		HEK_LEN(HeKEY_hek(he))
#define HeKUTF8(he)  HEK_UTF8(HeKEY_hek(he))
#define HeKWASUTF8(he)  HEK_WASUTF8(HeKEY_hek(he))
#define HeKLEN_UTF8(he)  (HeKUTF8(he) ? -HeKLEN(he) : HeKLEN(he))
#define HeKFLAGS(he)  HEK_FLAGS(HeKEY_hek(he))
#define HeVAL(he)		(he)->he_valu.hent_val
#define HeHASH(he)		HEK_HASH(HeKEY_hek(he))
#define HePV(he,lp)		((HeKLEN(he) == HEf_SVKEY) ?		\
                                 SvPV(HeKEY_sv(he),lp) :		\
                                 ((lp = HeKLEN(he)), HeKEY(he)))
#define HeUTF8(he)		((HeKLEN(he) == HEf_SVKEY) ?		\
                                 SvUTF8(HeKEY_sv(he)) :			\
                                 (U32)HeKUTF8(he))

#define HeSVKEY(he)		((HeKEY(he) && 				\
                                  HeKLEN(he) == HEf_SVKEY) ?		\
                                 HeKEY_sv(he) : NULL)

#define HeSVKEY_force(he)	(HeKEY(he) ?				\
                                 ((HeKLEN(he) == HEf_SVKEY) ?		\
                                  HeKEY_sv(he) :			\
                                  newSVpvn_flags(HeKEY(he),		\
                                                 HeKLEN(he),            \
                                                 SVs_TEMP |             \
                                      ( HeKUTF8(he) ? SVf_UTF8 : 0 ))) : \
                                 &PL_sv_undef)
#define HeSVKEY_set(he,sv)	((HeKLEN(he) = HEf_SVKEY), (HeKEY_sv(he) = sv))

#ifndef PERL_CORE

/*
=for apidoc ABmn|HE*|Nullhek

Null HEK pointer.

=cut
*/

#  define Nullhek Null(HEK*)
#endif
#define HEK_BASESIZE		STRUCT_OFFSET(HEK, hek_key[0])
#define HEK_HASH(hek)		(hek)->hek_hash
#define HEK_LEN(hek)		(hek)->hek_len
#define HEK_KEY(hek)		(hek)->hek_key
#define HEK_FLAGS(hek)	(*((unsigned char *)(HEK_KEY(hek))+HEK_LEN(hek)+1))

#define HVhek_UTF8	0x01 /* Key is utf8 encoded. */
#define HVhek_WASUTF8	0x02 /* Key is bytes here, but was supplied as utf8. */
#define HVhek_NOTSHARED 0x04 /* This key isn't a shared hash key. */
/* the following flags are options for functions, they are not stored in heks */
#define HVhek_FREEKEY	0x100 /* Internal flag to say key is Newx()ed.  */
#define HVhek_PLACEHOLD	0x200 /* Internal flag to create placeholder.
                               * (may change, but Storable is a core module) */
#define HVhek_KEYCANONICAL 0x400 /* Internal flag - key is in canonical form.
                                    If the string is UTF-8, it cannot be
                                    converted to bytes. */
#define HVhek_ENABLEHVKFLAGS        (HVhek_UTF8|HVhek_WASUTF8)

#define HEK_UTF8(hek)		(HEK_FLAGS(hek) & HVhek_UTF8)
#define HEK_UTF8_on(hek)	(HEK_FLAGS(hek) |= HVhek_UTF8)
#define HEK_UTF8_off(hek)	(HEK_FLAGS(hek) &= ~HVhek_UTF8)
#define HEK_WASUTF8(hek)	(HEK_FLAGS(hek) & HVhek_WASUTF8)
#define HEK_WASUTF8_on(hek)	(HEK_FLAGS(hek) |= HVhek_WASUTF8)
#define HEK_WASUTF8_off(hek)	(HEK_FLAGS(hek) &= ~HVhek_WASUTF8)

/* calculate HV array allocation */
#ifndef PERL_USE_LARGE_HV_ALLOC
/* Default to allocating the correct size - default to assuming that malloc()
   is not broken and is efficient at allocating blocks sized at powers-of-two.
*/   
#  define PERL_HV_ARRAY_ALLOC_BYTES(size) ((size) * sizeof(HE*))
#else
#  define MALLOC_OVERHEAD 16
#  define PERL_HV_ARRAY_ALLOC_BYTES(size) \
                        (((size) < 64)					\
                         ? (size) * sizeof(HE*)				\
                         : (size) * sizeof(HE*) * 2 - MALLOC_OVERHEAD)
#endif

/* Flags for hv_iternext_flags.  */
#define HV_ITERNEXT_WANTPLACEHOLDERS	0x01	/* Don't skip placeholders.  */

#define hv_iternext(hv)	hv_iternext_flags(hv, 0)
#define hv_magic(hv, gv, how) sv_magic(MUTABLE_SV(hv), MUTABLE_SV(gv), how, NULL, 0)
#define hv_undef(hv) Perl_hv_undef_flags(aTHX_ hv, 0)

#define Perl_sharepvn(pv, len, hash) HEK_KEY(share_hek(pv, len, hash))
#define sharepvn(pv, len, hash)	     Perl_sharepvn(pv, len, hash)

#define share_hek_hek(hek) (++HvSTR_REFCOUNT(hek), (hek))

#define hv_store_ent(hv, keysv, val, hash)				\
    ((HE *) hv_common((hv), (keysv), NULL, 0, 0, HV_FETCH_ISSTORE,	\
                      (val), (hash)))

#define hv_exists_ent(hv, keysv, hash)					\
    cBOOL(hv_common((hv), (keysv), NULL, 0, 0, HV_FETCH_ISEXISTS, 0, (hash)))
#define hv_fetch_ent(hv, keysv, lval, hash)				\
    ((HE *) hv_common((hv), (keysv), NULL, 0, 0,			\
                      ((lval) ? HV_FETCH_LVALUE : 0), NULL, (hash)))
#define hv_delete_ent(hv, key, flags, hash)				\
    (MUTABLE_SV(hv_common((hv), (key), NULL, 0, 0, (flags) | HV_DELETE,	\
                          NULL, (hash))))

#define hv_store_flags(hv, key, klen, val, hash, flags)			\
    ((SV**) hv_common((hv), NULL, (key), (klen), (flags),		\
                      (HV_FETCH_ISSTORE|HV_FETCH_JUST_SV), (val),	\
                      (hash)))

#define hv_store(hv, key, klen, val, hash)				\
    ((SV**) hv_common_key_len((hv), (key), (klen),			\
                              (HV_FETCH_ISSTORE|HV_FETCH_JUST_SV),	\
                              (val), (hash)))



#define hv_exists(hv, key, klen)					\
    cBOOL(hv_common_key_len((hv), (key), (klen), HV_FETCH_ISEXISTS, NULL, 0))

#define hv_fetch(hv, key, klen, lval)					    \
    ((SV**) hv_common_key_len((hv), (key), (klen),                          \
                              (HV_FETCH_JUST_SV | ((lval)                   \
                                                   ? HV_FETCH_LVALUE        \
                                                   : 0)),                   \
                              NULL, 0))

#define hv_delete(hv, key, klen, flags)					\
    (MUTABLE_SV(hv_common_key_len((hv), (key), (klen),			\
                                  (flags) | HV_DELETE, NULL, 0)))

/* Provide 's' suffix subs for constant strings (and avoid needing to count
 * chars). See STR_WITH_LEN in handy.h - because these are macros we cant use
 * STR_WITH_LEN to do the work, we have to unroll it.
 *
 *
=for apidoc_defn AmR|bool|hv_existss|HV *hv|"key"
=cut
*/
#define hv_existss(hv, key) \
    hv_exists((hv), ASSERT_IS_LITERAL(key), (sizeof(key)-1))

/*
=for apidoc_defn Am|SV**|hv_fetchs|HV* hv|"key"|I32 lval
=for apidoc_defn Am|SV *|hv_deletes|HV *hv|"key"|U32 flags
=for apidoc_defn Am|void|hv_name_sets|HV *hv|"name"|U32 flags
=for apidoc_defn Am|SV**|hv_stores|HV *hv|"name"|U32 flags
=cut
*/
#define hv_fetchs(hv, key, lval) \
    hv_fetch((hv), ASSERT_IS_LITERAL(key), (sizeof(key)-1), (lval))

#define hv_deletes(hv, key, flags) \
    hv_delete((hv), ASSERT_IS_LITERAL(key), (sizeof(key)-1), (flags))

#define hv_name_sets(hv, name, flags) \
    hv_name_set((hv),ASSERT_IS_LITERAL(name),(sizeof(name)-1), flags)

#define hv_stores(hv, key, val) \
    hv_store((hv), ASSERT_IS_LITERAL(key), (sizeof(key)-1), (val), 0)

#ifdef PERL_CORE
# define hv_storehek(hv, hek, val) \
    hv_common((hv), NULL, HEK_KEY(hek), HEK_LEN(hek), HEK_UTF8(hek),	\
              HV_FETCH_ISSTORE|HV_FETCH_JUST_SV, (val), HEK_HASH(hek))
# define hv_fetchhek(hv, hek, lval) \
    ((SV **)								\
     hv_common((hv), NULL, HEK_KEY(hek), HEK_LEN(hek), HEK_UTF8(hek),	\
               (lval)							\
                ? (HV_FETCH_JUST_SV | HV_FETCH_LVALUE)			\
                : HV_FETCH_JUST_SV,					\
               NULL, HEK_HASH(hek)))
# define hv_deletehek(hv, hek, flags) \
    hv_common((hv), NULL, HEK_KEY(hek), HEK_LEN(hek), HEK_UTF8(hek), \
              (flags)|HV_DELETE, NULL, HEK_HASH(hek))
#define hv_existshek(hv, hek)                                           \
    cBOOL(hv_common((hv), NULL, HEK_KEY(hek), HEK_LEN(hek), HEK_UTF8(hek), \
                    HV_FETCH_ISEXISTS, NULL, HEK_HASH(hek)))
#endif

/* This refcounted he structure is used for storing the hints used for lexical
   pragmas. Without threads, it's basically struct he + refcount.
   With threads, life gets more complex as the structure needs to be shared
   between threads (because it hangs from OPs, which are shared), hence the
   alternate definition and mutex.  */

struct refcounted_he;

/* flags for the refcounted_he API */
#define REFCOUNTED_HE_KEY_UTF8		0x00000001
#define REFCOUNTED_HE_EXISTS		0x00000002

#ifdef PERL_CORE

/* Gosh. This really isn't a good name any longer.  */
struct refcounted_he {
    struct refcounted_he *refcounted_he_next;	/* next entry in chain */
#ifdef USE_ITHREADS
    U32                   refcounted_he_hash;
    U32                   refcounted_he_keylen;
#else
    HEK                  *refcounted_he_hek;	/* hint key */
#endif
    union {
        IV                refcounted_he_u_iv;
        UV                refcounted_he_u_uv;
        STRLEN            refcounted_he_u_len;
        void		 *refcounted_he_u_ptr;	/* Might be useful in future */
    } refcounted_he_val;
    U32	                  refcounted_he_refcnt;	/* reference count */
    /* First byte is flags. Then NUL-terminated value. Then for ithreads,
       non-NUL terminated key.  */
    char                  refcounted_he_data[1];
};

#define refcounted_he_fetch_pvs(chain, key, flags) \
    Perl_refcounted_he_fetch_pvn(aTHX_ chain, STR_WITH_LEN(key), 0, flags)

#define refcounted_he_new_pvs(parent, key, value, flags) \
    Perl_refcounted_he_new_pvn(aTHX_ parent, STR_WITH_LEN(key), 0, value, flags)

/* Flag bits are HVhek_UTF8, HVhek_WASUTF8, then */
#define HVrhek_undef	0x00 /* Value is undef. */
#define HVrhek_delete	0x10 /* Value is placeholder - signifies delete. */
#define HVrhek_IV	0x20 /* Value is IV. */
#define HVrhek_UV	0x30 /* Value is UV. */
#define HVrhek_PV	0x40 /* Value is a (byte) string. */
#define HVrhek_PV_UTF8	0x50 /* Value is a (utf8) string. */
/* Two spare. As these have to live in the optree, you can't store anything
   interpreter specific, such as SVs. :-( */
#define HVrhek_typemask 0x70

#ifdef USE_ITHREADS
/* A big expression to find the key offset */
#define REF_HE_KEY(chain)						\
        ((((chain->refcounted_he_data[0] & 0x60) == 0x40)		\
            ? chain->refcounted_he_val.refcounted_he_u_len + 1 : 0)	\
         + 1 + chain->refcounted_he_data)
#endif

#  ifdef USE_ITHREADS
#    define HINTS_REFCNT_LOCK		MUTEX_LOCK(&PL_hints_mutex)
#    define HINTS_REFCNT_UNLOCK		MUTEX_UNLOCK(&PL_hints_mutex)
#  else
#    define HINTS_REFCNT_LOCK		NOOP
#    define HINTS_REFCNT_UNLOCK		NOOP
#  endif
#endif

#ifdef USE_ITHREADS
#  define HINTS_REFCNT_INIT		MUTEX_INIT(&PL_hints_mutex)
#  define HINTS_REFCNT_TERM		MUTEX_DESTROY(&PL_hints_mutex)
#else
#  define HINTS_REFCNT_INIT		NOOP
#  define HINTS_REFCNT_TERM		NOOP
#endif

/* Hash actions
 * Passed in PERL_MAGIC_uvar calls
 */
#define HV_DISABLE_UVAR_XKEY	0x01
#define HV_FETCH_ISSTORE	0x02
/* We need to ensure that these don't clash with G_DISCARD, which is 4, as it
   is documented as being passed to hv_delete().  */
#define HV_FETCH_ISEXISTS	0x08
#define HV_FETCH_LVALUE		0x10
#define HV_FETCH_JUST_SV	0x20
#define HV_DELETE		0x40
#define HV_FETCH_EMPTY_HE	0x80 /* Leave HeVAL null. */

/* Must not conflict with HVhek_UTF8 */
#define HV_NAME_SETALL		0x02

/*
=for apidoc newHV

Creates a new HV.  The reference count is set to 1.

=cut
*/

#define newHV()	MUTABLE_HV(newSV_type(SVt_PVHV))

#include "hv_func.h"

/*
 * ex: set ts=8 sts=4 sw=4 et:
 */
