/* Shared-key interning storage. This table is not an SV or a value hash. */
#ifndef PERL_HV_STRTAB_H
#define PERL_HV_STRTAB_H

#define PERL_HV_STRTAB_MIN_CAPACITY 32768
#define PERL_HV_STRTAB_MAX_KEYS ((U32)1431655765)
#define PERL_HV_STRTAB_TOMBSTONE INT2PTR(HEK *, 1)

struct shared_hek {
    U32 refcount;
    struct hek shared_hek_hek;
};

#define HvSTR_SHARED(hek) \
    ((struct shared_hek *)((char *)(hek) \
      - STRUCT_OFFSET(struct shared_hek, shared_hek_hek)))
#define HvSTR_REFCOUNT(hek)	(HvSTR_SHARED(hek)->refcount)

struct perl_hv_strtab_pin {
    struct perl_hv_strtab_pin *next;
    HEK *hek;
    Size_t count;
};

typedef struct perl_hv_strtab {
    HEK **slots;
    Size_t capacity;
    Size_t live;
    Size_t tombstones;
    struct perl_hv_strtab_pin *pins;
} PERL_HV_STRTAB;

typedef void (*perl_hv_strtab_report_t)(pTHX_ const HEK *, void *);

/* Keys passed to this layer are canonical bytes, with a computed hash and
 * storage flags. Encoding conversion and ownership of the query buffer
 * belong to the caller. HEK addresses are stable until final release.
 *
 * A table owns its slot allocation and pinned references. Other HEK owners
 * must release their references before the table is freed. free reports
 * remaining owners through its optional callback and returns their distinct
 * key count. The callback must not mutate the table.
 *
 * pin adopts references already acquired by the caller. It does not acquire
 * additional references. Tables and keys belong to one interpreter. */
#endif
