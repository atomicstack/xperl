/* OA ordinary-hash storage. Included only by the selected hv.c build.
 * Perl-facing magic, ties, and key/value ownership stay in hv.c. */

#define HV_INDEX_NO_SLOT U32_MAX
#define HV_INDEX_DELETED U32_MAX
#define HV_INDEX_NEEDS_INSERT_SLOT 1
#define HV_INDEX_COUPLED_MAX 16384
#define HV_INDEX_LOAD_LIMIT(capacity) \
    (((capacity) / 3) * 2 + ((capacity) % 3) * 2 / 3)

static void S_hv_index_insert(HV *hv, HE *entry, U32 hash);
static HE *S_hv_index_new_entry(pTHX_ HV *hv, U32 hash, U32 *slotp);

/* A proportional threshold amortizes packing over subsequent insertions
 * without making small hashes accumulate a fixed byte budget of holes. */
static bool
S_hv_index_compaction_worthwhile(U32 used, U32 live, U32 capacity)
{
    const U32 holes = used - live;
    return holes >= capacity / 5 + (capacity % 5 != 0);
}

static U32
S_hv_index_rebuild_capacity(pTHX_ U32 live, U32 minimum)
{
    const U32 capacity = S_hv_index_capacity_for(live, minimum);
    if (!capacity)
        PERL_THROW_ERROR_VALUE_HASH_CAPACITY_EXCEEDED((UV)HV_MAX_KEYS);
    return capacity;
}

static bool
S_linear_enabled(pTHX_ HV *hv)
{
    return PL_hash_linear_max
        && !SvTIED_mg((const SV *)hv, PERL_MAGIC_tied);
}

static void
S_hv_index_rebuild(pTHX_ HV *hv, U32 capacity, U32 entry_capacity, bool pack)
{
    const bool was_linear = HvIS_LINEAR(hv);
    PERL_HV_INDEX *old = HvARRAY(hv) && !was_linear ? HvINDEX(hv) : NULL;
    const bool reuse_index = old && capacity == (U32)HvMAX(hv) + 1
        && entry_capacity == old->capacity;
    PERL_HV_INDEX *storage;
    HE *entries = was_linear ? (HE *)HvARRAY(hv)
                             : old ? old->entries : NULL;
    U32 used = was_linear ? (U32)HvTOTALKEYS(hv) : old ? old->used : 0;
    struct xpvhv_aux *iter = HvHasAUX(hv) ? HvAUX(hv) : NULL;
    HE *old_eiter = iter ? iter->xhv_eiter : NULL;
    I32 old_riter = iter ? iter->xhv_riter : -1;
    I32 new_riter = -1;
    U32 i;
    char *raw;
    Size_t bytes;
    if (capacity > HV_MAX_BUCKETS || HvTOTALKEYS(hv) > HV_MAX_KEYS)
        PERL_THROW_ERROR_VALUE_HASH_CAPACITY_EXCEEDED((UV)HV_MAX_KEYS);
    /* Chaining permits more live entries than buckets. Only open addressing
     * needs a live-count limit on the index slots. */
    if (!S_hv_index_size_valid(capacity, entry_capacity)
        || HvTOTALKEYS(hv) > HV_INDEX_LOAD_LIMIT(capacity)
        )
        Perl_croak_memory_wrap();
    assert(entry_capacity >= HvTOTALKEYS(hv));
    bytes = STRUCT_OFFSET(PERL_HV_INDEX, indices)
            + HvINDEX_STORAGE_BYTES(capacity, entry_capacity);
    if (reuse_index) {
        /* Compaction rewrites identifiers, but unchanged capacities need
         * no allocation. Capture iterator and entry state before clearing. */
        storage = old;
        Zero(storage->indices, HvINDEX_STORAGE_BYTES(capacity, entry_capacity), U8);
        storage->used = 0;
        storage->tombstones = 0;
    }
    else {
        Newxz(raw, bytes, char);
        storage = (PERL_HV_INDEX *)raw;
    }
    storage->capacity = entry_capacity;
    {
        const U32 old_capacity = was_linear ? HvLINEAR_CAP(hv)
                                            : old ? old->capacity : 0;
        const U32 holes = used - (U32)HvTOTALKEYS(hv);
        const bool compact = holes
            && (
                pack || storage->capacity < used
                || (capacity <= 128 && used >= 0xFEU)
                || (capacity <= 32768 && used >= 0xFFFEU)
                );
        SSize_t eiter_offset = -1;
        if (compact) {
            for (i = 0; i < used; i++) {
                HE *entry = &entries[i];
                if (entry == old_eiter && HvLAZYDEL(hv)) {
                    /* Detach the deleted key without running its destructor
                     * while the entry array and index are inconsistent. */
                    HE *retired = S_alloc_he(aTHX);
                    *retired = *entry;
                    iter->xhv_eiter = retired;
                }
                else if (HeKEY_hek(entry)) {
                    if (i != storage->used)
                        entries[storage->used] = *entry;
                    if (entry == old_eiter)
                        eiter_offset = storage->used;
                    storage->used++;
                }
                if (old_riter >= 0 && i <= (U32)old_riter)
                    new_riter = (I32)storage->used - 1;
            }
            if (iter) {
                iter->xhv_riter = new_riter;
                /* Removing the first, deleted entry maps its cursor to -1.
                 * Keep the active state so insertion is still detected. */
                if (old_riter >= 0)
                    iter->xhv_aux_flags |= HvAUXf_ITER_ACTIVE;
            }
        }
        else {
            storage->used = used;
            if (old_eiter && entries) {
                UV ptr = PTR2UV(old_eiter), base = PTR2UV(entries);
                if (ptr >= base && ptr - base < (UV)used * sizeof(HE)
                    && (ptr - base) % sizeof(HE) == 0)
                    eiter_offset = (SSize_t)((ptr - base) / sizeof(HE));
            }
        }
        if (was_linear && entries && old_capacity == 1) {
            Newx(storage->entries, storage->capacity, HE);
            Copy(entries, storage->entries, storage->used, HE);
            S_release_he(aTHX_ entries);
        }
        else {
            storage->entries = entries;
            /* Renew lets the allocator grow or shrink the block in place.
             * An index-only resize does not touch the entry allocation. */
            if (storage->capacity != old_capacity)
                Renew(storage->entries, storage->capacity, HE);
        }
        if (compact || storage->capacity != old_capacity)
            Zero(storage->entries + storage->used, storage->capacity - storage->used, HE);
        if (eiter_offset >= 0)
            iter->xhv_eiter = &storage->entries[eiter_offset];
    }
    if (!reuse_index)
        Safefree(old);
    HvARRAY(hv) = (HE **)storage;
    HvMAX_SET(hv, capacity - 1);
    for (i = 0; i < storage->used; i++) {
        HE *entry = HvENTRY_FIRST(hv, i);
        if (entry)
            S_hv_index_insert(hv, entry, HeHASH(entry));
    }
}

static void
S_hv_index_resize(pTHX_ HV *hv, U32 capacity)
{
    PERL_HV_INDEX *old = HvARRAY(hv) && !HvIS_LINEAR(hv) ? HvINDEX(hv) : NULL;
    const U32 live = (U32)HvTOTALKEYS(hv);
    U32 entry_capacity;
    entry_capacity = old ? old->capacity : HV_INDEX_LOAD_LIMIT(
        capacity <= HV_INDEX_COUPLED_MAX ? capacity : HV_INDEX_COUPLED_MAX);
    if (capacity <= HV_INDEX_COUPLED_MAX
        && entry_capacity < HV_INDEX_LOAD_LIMIT(capacity))
        entry_capacity = HV_INDEX_LOAD_LIMIT(capacity);
    while (entry_capacity < live)
        entry_capacity += entry_capacity >> 2;
    S_hv_index_rebuild(aTHX_ hv, capacity, entry_capacity,
        old && S_hv_index_compaction_worthwhile(old->used, live, old->capacity));
}

static void
S_hv_index_promote(pTHX_ HV *hv)
{
    U32 used = (U32)HvTOTALKEYS(hv), cap = 8;
    while (used + (used >> 1) > cap - 1) {
        if (cap >= HV_MAX_BUCKETS)
            PERL_THROW_ERROR_VALUE_HASH_CAPACITY_EXCEEDED((UV)HV_MAX_KEYS);
        cap <<= 1;
    }
    S_hv_index_resize(aTHX_ hv, cap);
}

static void
S_linear_reserve(pTHX_ HV *hv, U32 capacity)
{
    HE *entries = (HE *)HvARRAY(hv);
    const U32 used = (U32)HvTOTALKEYS(hv);
    const U32 old_capacity = entries ? HvLINEAR_CAP(hv) : 0;
    SSize_t eiter_offset = -1;

    assert(!entries || HvIS_LINEAR(hv));
    assert(capacity >= used);
    if (capacity <= old_capacity)
        return;
    if (HvHasAUX(hv) && HvAUX(hv)->xhv_eiter && entries) {
        UV p = PTR2UV(HvAUX(hv)->xhv_eiter), b = PTR2UV(entries);
        if (p >= b && p < b + used * sizeof(HE)
            && (p - b) % sizeof(HE) == 0)
            eiter_offset = (SSize_t)((p - b) / sizeof(HE));
    }
    if (capacity == 1) {
        assert(!entries);
        entries = S_alloc_he(aTHX);
    }
    else if (old_capacity == 1) {
        HE *expanded;
        Newx(expanded, capacity, HE);
        Copy(entries, expanded, used, HE);
        S_release_he(aTHX_ entries);
        entries = expanded;
    }
    else if (entries)
        Renew(entries, capacity, HE);
    else
        Newx(entries, capacity, HE);
    Zero(entries + used, capacity - used, HE);
    HvARRAY(hv) = (HE **)entries;
    HvMAX_SET_LINEAR(hv, capacity);
    if (eiter_offset >= 0)
        HvAUX(hv)->xhv_eiter = &entries[eiter_offset];
}

/* Benchmark the first heap allocation independently of the linear limit. */
#ifndef PERL_HASH_LINEAR_MIN_ALLOC
#  define PERL_HASH_LINEAR_MIN_ALLOC 4
#endif
#if PERL_HASH_LINEAR_MIN_ALLOC != 2 && PERL_HASH_LINEAR_MIN_ALLOC != 4
#  error "PERL_HASH_LINEAR_MIN_ALLOC must be 2 or 4"
#endif

static HE *
S_linear_new_entry(pTHX_ HV *hv, U32 hash)
{
    U32 used = (U32)HvTOTALKEYS(hv), cap = HvLINEAR_CAP(hv);
    U32 limit = (U32)PL_hash_linear_max;
    HE *entries = (HE *)HvARRAY(hv);
    if (!entries && used == 0) {
        HE *entry = S_alloc_he(aTHX);
        HvARRAY(hv) = (HE **)entry;
        HvMAX_SET_LINEAR(hv, 1);
        return entry;
    }
    if (used == cap) {
        if (cap < limit) {
            U32 next = cap ? cap * 2 : 1;
            if (cap == 1 && next < PERL_HASH_LINEAR_MIN_ALLOC)
                next = PERL_HASH_LINEAR_MIN_ALLOC;
            if (next > limit) next = limit;
            if (next <= cap || next > (U32)HV_LINEAR_CAP_MASK)
                Perl_croak_memory_wrap();
            S_linear_reserve(aTHX_ hv, next);
            entries = (HE *)HvARRAY(hv);
        }
        else {
            S_hv_index_promote(aTHX_ hv);
            return S_hv_index_new_entry(aTHX_ hv, hash, NULL);
        }
    }
    return &entries[used];
}

/* Remove a dense entry, preserving the compact form's canonical storage:
 * no allocation when empty, an arena HE when one entry remains, and a heap
 * vector only for two or more entries.  Key/value ownership is returned to
 * the caller so callbacks happen after the array and iterator are repaired. */
static void
S_linear_remove_at(pTHX_ HV *hv, U32 idx, HEK **hekp, I32 *lenp, U8 *flagsp)
{
    HE *entries = (HE *)HvARRAY(hv);
    const U32 used = (U32)HvTOTALKEYS(hv);
    HE *entry = &entries[idx];
    struct xpvhv_aux *iter = HvHasAUX(hv) ? HvAUX(hv) : NULL;
    SSize_t eiter_idx = -1;
    *hekp = HeKEY_hek(entry);
    *lenp = HeKLEN(entry);
    *flagsp = HeKFLAGS(entry);
    if (iter && iter->xhv_eiter) {
        UV p = PTR2UV(iter->xhv_eiter), b = PTR2UV(entries);
        if (p >= b && p < b + used * sizeof(HE)
            && (p - b) % sizeof(HE) == 0)
            eiter_idx = (SSize_t)((p - b) / sizeof(HE));
    }
    if (iter && iter->xhv_riter >= 0 && (U32)iter->xhv_riter >= idx)
        iter->xhv_riter--;
    if (iter && eiter_idx >= 0) {
        if ((U32)eiter_idx == idx)
            iter->xhv_eiter = NULL;
        else if ((U32)eiter_idx > idx)
            iter->xhv_eiter = &entries[eiter_idx - 1];
    }

    if (used == 1) {
        if (HvLINEAR_CAP(hv) == 1)
            S_release_he(aTHX_ entries);
        else
            Safefree(entries);
        HvARRAY(hv) = NULL;
        HvTOTALKEYS(hv) = 0;
        HvMAX_SET_LINEAR(hv, 0);
        return;
    }

    Move(&entries[idx + 1], &entries[idx], used - idx - 1, HE);
    Zero(&entries[used - 1], 1, HE);
    HvTOTALKEYS(hv)--;
    if (used == 2) {
        HE *singleton = S_alloc_he(aTHX);
        *singleton = entries[0];
        Safefree(entries);
        HvARRAY(hv) = (HE **)singleton;
        HvMAX_SET_LINEAR(hv, 1);
        if (iter && eiter_idx >= 0 && (U32)eiter_idx != idx)
            iter->xhv_eiter = singleton;
    }
}

PERL_STATIC_INLINE bool
S_hv_index_key_eq(const HEK *hek, const HEK *keyhek, U32 hash,
            const char *key, STRLEN klen, U32 flags)
{
    if (hek == keyhek)
        return TRUE;
    /* Encoding variants and HEKs from another interpreter can have
     * different pointers for the same key. Retain the content fallback. */
    return HEK_HASH(hek) == hash && HEK_LEN(hek) == (I32)klen
        && memEQ(HEK_KEY(hek), key, klen)
        && !((HEK_FLAGS(hek) ^ flags) & HVhek_UTF8);
}

PERL_STATIC_INLINE HE *
S_hv_index_find(pTHX_ HV *hv, U32 hash, const char *key, STRLEN klen, U32 flags,
          HEK *keyhek, U32 *slotp)
{
    U32 mask = (U32)HvMAX(hv);
    U32 pos = hash & mask;
    U32 first_deleted = HV_INDEX_NO_SLOT;
    U32 n;
    if (HvIS_LINEAR(hv)) {
        HE *entries = (HE *)HvARRAY(hv);
        if (slotp) *slotp = HV_INDEX_NO_SLOT;
        for (n = 0; n < (U32)HvTOTALKEYS(hv); n++) {
            HE *entry = &entries[n];
            if (S_hv_index_key_eq(HeKEY_hek(entry), keyhek, hash, key, klen, flags))
                return entry;
        }
        return NULL;
    }
    if (!HvARRAY(hv)) { if (slotp) *slotp = HV_INDEX_NO_SLOT; return NULL; }
    for (n = 0; n <= mask; n++, pos = (pos + 1) & mask) {
        U32 ix = HvINDEX_GET(hv, pos);
        HE *entry;
        if (ix == 0) {
            if (slotp) *slotp = first_deleted != HV_INDEX_NO_SLOT ? first_deleted : pos;
            return NULL;
        }
        if (ix == HV_INDEX_DELETED) { if (first_deleted == HV_INDEX_NO_SLOT) first_deleted = pos; continue; }
        entry = &HvINDEX(hv)->entries[ix - 1];
        if (S_hv_index_key_eq(HeKEY_hek(entry), keyhek, hash, key, klen, flags)) {
            if (slotp) *slotp = pos;
            return entry;
        }
    }
    if (slotp) *slotp = first_deleted;
    return NULL;
}

static void
S_hv_index_insert(HV *hv, HE *entry, U32 hash)
{
    PERL_HV_INDEX *storage = HvINDEX(hv);
    U32 mask = (U32)HvMAX(hv), pos = hash & mask, n;
    for (n = 0; n <= mask; n++, pos = (pos + 1) & mask) {
        U32 index = HvINDEX_GET(hv, pos);
        if (!index || index == HV_INDEX_DELETED) {
            U32 encoded = (U32)(entry - storage->entries) + 1;
            if (index == HV_INDEX_DELETED) storage->tombstones--;
            if (encoded >= (HvINDEX_WIDTH(hv) == 1 ? 0xFFU
                           : HvINDEX_WIDTH(hv) == 2 ? 0xFFFFU
                           : U32_MAX))
                Perl_croak_memory_wrap();
            HvINDEX_SET(hv, pos, encoded);
            return;
        }
    }
    Perl_croak_memory_wrap();
}

static void
S_hv_index_delete(HV *hv, U32 pos)
{
    HvINDEX_SET(hv, pos, HV_INDEX_DELETED);
    HvINDEX(hv)->tombstones++;
}

static void
S_hv_index_reserve_entries(pTHX_ HV *hv, U32 capacity)
{
    PERL_HV_INDEX *storage = HvINDEX(hv);
    U32 old_capacity = storage->capacity;
    SSize_t eiter_offset = -1;
    if (capacity <= storage->capacity)
        return;
    if (!S_hv_index_size_valid((U32)HvMAX(hv) + 1, capacity))
        Perl_croak_memory_wrap();
    if (HvHasAUX(hv) && HvAUX(hv)->xhv_eiter) {
        UV ptr = PTR2UV(HvAUX(hv)->xhv_eiter);
        UV base = PTR2UV(storage->entries);
        if (ptr >= base && ptr - base < (UV)storage->used * sizeof(HE)
            && (ptr - base) % sizeof(HE) == 0)
            eiter_offset = (SSize_t)((ptr - base) / sizeof(HE));
    }
    Renew(storage->entries, capacity, HE);
    Zero(storage->entries + old_capacity, capacity - old_capacity, HE);
    storage->capacity = capacity;
    if (eiter_offset >= 0)
        HvAUX(hv)->xhv_eiter = &storage->entries[eiter_offset];
}

static HE *
S_hv_index_new_entry(pTHX_ HV *hv, U32 hash, U32 *slotp)
{
    PERL_HV_INDEX *storage = HvINDEX(hv);
    U32 index_capacity = (U32)HvMAX(hv) + 1;
    const U32 live = (U32)HvTOTALKEYS(hv);
    PERL_UNUSED_ARG(hash);
    /* Shrink only when entry exhaustion requires growing or packing.
     * An index rebuild invalidates the saved insertion slot, even at unchanged
     * capacity. Moving only the HE array preserves it. */
    if (storage->used == storage->capacity
        && S_hv_index_compaction_worthwhile(storage->used, live, storage->capacity)) {
        const U32 shrink_entries = MAX(8, live + (live >> 2) + 1);
        U32 entry_capacity = storage->capacity;
        const U32 smaller_index = S_hv_index_rebuild_capacity(aTHX_ live + 1, 8);

        /* Ordinary churn packs in place. A sustained fall in live keys can
         * release storage, retaining room for the pending insertion. */
        if (smaller_index <= index_capacity / 2)
            index_capacity = smaller_index;
        if (shrink_entries <= entry_capacity / 2)
            entry_capacity = shrink_entries;
        if (slotp) *slotp = HV_INDEX_NO_SLOT;
        S_hv_index_rebuild(aTHX_ hv, index_capacity, entry_capacity, TRUE);
        storage = HvINDEX(hv);
    }
    if (live + storage->tombstones >= HV_INDEX_LOAD_LIMIT(index_capacity)) {
        if (storage->tombstones < (live + storage->tombstones + 1) / 2)
            index_capacity = S_hv_index_rebuild_capacity(aTHX_ live, 8);
        if (slotp) *slotp = HV_INDEX_NO_SLOT;
        S_hv_index_resize(aTHX_ hv, index_capacity);
        storage = HvINDEX(hv);
    }
    if (storage->used == storage->capacity) {
        if (index_capacity <= HV_INDEX_COUPLED_MAX
            && storage->capacity >= HV_INDEX_LOAD_LIMIT(index_capacity)) {
            /* Below the coupled limit, reserve entry headroom by growing
             * the index too. Substantial holes were reclaimed above. */
            index_capacity = S_hv_index_rebuild_capacity(aTHX_ live, index_capacity * 2);
            if (slotp) *slotp = HV_INDEX_NO_SLOT;
            S_hv_index_resize(aTHX_ hv, index_capacity);
            storage = HvINDEX(hv);
        }
    }
    if (storage->used == storage->capacity) {
        const U32 increment = storage->capacity >> 2;
        const U32 capacity = storage->capacity + increment;
        if (!increment || capacity < storage->capacity)
            Perl_croak_memory_wrap();
        S_hv_index_reserve_entries(aTHX_ hv, capacity);
        storage = HvINDEX(hv);
    }
    /* A narrowed index may retain a much larger HE allocation. Reclaim
     * holes before the next position exceeds the index's encoding range. */
    if ((index_capacity <= 128 && storage->used >= 0xFEU)
        || (index_capacity <= 32768 && storage->used >= 0xFFFEU)) {
        if (slotp) *slotp = HV_INDEX_NO_SLOT;
        S_hv_index_resize(aTHX_ hv, index_capacity);
        storage = HvINDEX(hv);
    }
    assert(storage->used < storage->capacity);
    return &storage->entries[storage->used++];
}


static void
S_hv_index_store(HV *hv, HE *entry, U32 hash, U32 insert_pos)
{
            if (insert_pos != HV_INDEX_NO_SLOT) {
                PERL_HV_INDEX *storage = HvINDEX(hv);
                U32 index;
                U32 encoded = (U32)(entry - storage->entries) + 1;
                assert(insert_pos <= (U32)HvMAX(hv));
                index = HvINDEX_GET(hv, insert_pos);
                assert(!index || index == HV_INDEX_DELETED);
                assert(encoded && encoded < (HvINDEX_WIDTH(hv) == 1
                    ? 0xFFU : HvINDEX_WIDTH(hv) == 2 ? 0xFFFFU : U32_MAX));
                if (index == HV_INDEX_DELETED) storage->tombstones--;
                HvINDEX_SET(hv, insert_pos, encoded);
            }
            else
                S_hv_index_insert(hv, entry, hash);

}

static bool
S_hv_index_contains(pTHX_ HV *hv, HE *entry)
{
    PERL_HV_INDEX *oa;
    UV p, b;
    if (HvIS_LINEAR(hv) || !HvARRAY(hv)) return FALSE;
    oa = HvINDEX(hv);
    if (!oa->entries) return FALSE;
    p = PTR2UV(entry);
    b = PTR2UV(oa->entries);
    return p >= b && p < b + oa->used * sizeof(HE) &&
           (p - b) % sizeof(HE) == 0;
}

static void
S_hv_index_reserve(pTHX_ HV *hv, IV newmax)
{

    U32 oldsize;
    U32 newsize;
    U32 wantsize;
    U32 entry_capacity;
    bool pack = FALSE;

    if (newmax <= 0)
        return;
    if ((UV)newmax > HV_MAX_KEYS)
        PERL_THROW_ERROR_VALUE_HASH_CAPACITY_EXCEEDED((UV)HV_MAX_KEYS);

    /* Explicit reservations within the tiny limit need only HE storage.
     * Unreserved empty hashes continue to allocate on their first store. */
    if ((UV)newmax <= PL_hash_linear_max
        && (!HvARRAY(hv) || HvIS_LINEAR(hv))
        && S_linear_enabled(aTHX_ hv)) {
        U32 capacity = HvARRAY(hv) ? HvLINEAR_CAP(hv) : 1;
        while (capacity < (UV)newmax) {
            U32 next = capacity * 2;
            if (next > PL_hash_linear_max)
                next = (U32)PL_hash_linear_max;
            if (next <= capacity || next > (U32)HV_LINEAR_CAP_MASK)
                Perl_croak_memory_wrap();
            capacity = next;
        }
        S_linear_reserve(aTHX_ hv, capacity);
        return;
    }

    oldsize = HvIS_LINEAR(hv) ? 8 : (U32)HvMAX(hv) + 1;

    /* Round up so requests such as 11 entries fit below the load limit
     * instead of selecting 16 slots with room for only 10 entries. */
    wantsize = (U32)newmax + ((U32)newmax >> 1) + ((U32)newmax & 1);
    newsize = oldsize;
    while (wantsize > newsize) {
        if (newsize >= HV_MAX_BUCKETS)
            PERL_THROW_ERROR_VALUE_HASH_CAPACITY_EXCEEDED((UV)HV_MAX_KEYS);
        newsize *= 2;
    }

    /* Check the final reservation before either allocation changes. In a
     * packed chain table, reserving entries can widen the bucket records. */
    {
        UV entries = MAX((UV)newmax, HV_INDEX_LOAD_LIMIT(
            MIN(newsize, HV_INDEX_COUPLED_MAX)));
        if (HvARRAY(hv) && !HvIS_LINEAR(hv)) {
            const PERL_HV_INDEX *oa = HvINDEX(hv);
            pack = S_hv_index_compaction_worthwhile(oa->used,
                (U32)HvTOTALKEYS(hv), oa->capacity);
            if (!pack && (UV)newmax > HvTOTALKEYS(hv))
                entries += (UV)oa->used - HvTOTALKEYS(hv);
            if (entries < oa->capacity)
                entries = oa->capacity;
        }
        else if (HvARRAY(hv) && entries < HvLINEAR_CAP(hv))
            entries = HvLINEAR_CAP(hv);
        if (entries > U32_MAX || !S_hv_index_size_valid(newsize, (U32)entries))
            Perl_croak_memory_wrap();
        entry_capacity = (U32)entries;
    }

    if (!pack && HvARRAY(hv) && !HvIS_LINEAR(hv) && newsize <= oldsize) {
        S_hv_index_reserve_entries(aTHX_ hv, entry_capacity);
        return;
    }

    if (!HvARRAY(hv) && LARGE_HASH_HEURISTIC(hv, newmax))
        HvSHAREKEYS_off(hv);
    /* Reserve buckets and entries together. We know the requested live
     * count, so an intermediate minimum-sized entry block is needless. */
    S_hv_index_rebuild(aTHX_ hv, newsize, entry_capacity, pack);
}

/* Bucket reservation leaves the entry reservation independent. Preserve
 * both capacities when the requested bucket count already fits. */
static U32
S_hv_index_reserve_buckets(pTHX_ HV *hv, U32 minimum)
{
    const bool indexed = HvARRAY(hv) && !HvIS_LINEAR(hv);
    const PERL_HV_INDEX *old = indexed ? HvINDEX(hv) : NULL;
    U32 capacity = indexed ? (U32)HvMAX(hv) + 1 : 8;
    U32 entries = old ? old->capacity
        : HvARRAY(hv) ? HvLINEAR_CAP(hv) : 0;
    const U32 live = (U32)HvTOTALKEYS(hv);

    if (!minimum)
        return indexed ? capacity : 0;
    while (capacity < minimum)
        capacity *= 2;
    while (live > HV_INDEX_LOAD_LIMIT(capacity))
        capacity *= 2;
    entries = MAX(entries, HV_INDEX_LOAD_LIMIT(
        MIN(capacity, HV_INDEX_COUPLED_MAX)));
    entries = MAX(entries, live);
    if (!indexed || capacity > (U32)HvMAX(hv) + 1)
        S_hv_index_rebuild(aTHX_ hv, capacity, entries,
            old && S_hv_index_compaction_worthwhile(old->used,
                live, old->capacity));
    return capacity;
}
