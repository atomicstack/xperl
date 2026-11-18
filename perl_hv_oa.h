/* OA storage layout and accessors. The second inclusion from inline.h
 * supplies definitions after the generated core declarations are available. */
#ifndef PERL_HV_OA_H
#define PERL_HV_OA_H

typedef struct perl_hv_oa {
    HE *entries;
    U32 capacity;
    U32 used;
    U32 tombstones;
    U8 indices[1];
} PERL_HV_INDEX;

#  define HvINDEX_WIDTH_FOR(capacity) \
    ((capacity) <= 128 ? 1 : (capacity) <= 32768 ? 2 : 4)
#  define HvINDEX_WIDTH(hv) \
    HvINDEX_WIDTH_FOR((U32)HvMAX(hv) + 1)
#  define HvINDEX_STORAGE_BYTES(buckets,entries) HvINDEX_BYTES_FOR(buckets)
#  define HvINDEX_RECORD_WIDTH_FOR(capacity) HvINDEX_WIDTH_FOR(capacity)
#  define HvINDEX_FINGERPRINT_BYTES_FOR(entries) 0
#define HvINDEX_BYTES_FOR(capacity) \
    ((Size_t)(capacity) * HvINDEX_WIDTH_FOR(capacity))
#define HvINDEX_REGION(storage,capacity) ((U8 *)(storage)->indices)


#define HvINDEX_GET(hv,pos) \
    S_hv_index_get(HvINDEX(hv), (U32)HvMAX(hv) + 1, (U32)(pos))
#define HvINDEX_SET(hv,pos,value) \
    S_hv_index_set(HvINDEX(hv), (U32)HvMAX(hv) + 1, (U32)(pos), (U32)(value))


#define HvINDEX_RESERVE_ENTRIES(hv) ((U32)HvMAX(hv) + 1 > 16384)

#endif

#if defined(PERL_HV_INLINE_FUNCTIONS) && !defined(PERL_HV_OA_INLINE_H)
#define PERL_HV_OA_INLINE_H

/* Capacity policy is independent of whether the allocation fits this host. */
PERL_STATIC_INLINE U32
S_hv_index_capacity_for(U32 live, U32 minimum)
{
    U32 capacity;
    UV target;
    if (live > HV_MAX_KEYS || !minimum || minimum > HV_MAX_BUCKETS
        || (minimum & (minimum - 1)))
        return 0;
    capacity = MAX(minimum, 8);
    target = (UV)live * 3;
    while (capacity < target && capacity < HV_MAX_BUCKETS)
        capacity *= 2;
    return capacity;
}

PERL_STATIC_INLINE bool
S_hv_index_size_valid(U32 buckets, U32 entries)
{
    Size_t available = MEM_SIZE_MAX - STRUCT_OFFSET(PERL_HV_INDEX, indices);
    const U32 width = HvINDEX_WIDTH_FOR(buckets);
    if (!buckets || buckets > HV_MAX_BUCKETS || (buckets & (buckets - 1))
        || entries > (U32)I32_MAX
        || (entries && sizeof(HE) > MEM_SIZE_MAX / (Size_t)entries)
        || (Size_t)buckets > available / width)
        return FALSE;
    return TRUE;
}

PERL_STATIC_INLINE U32
S_hv_index_get(const PERL_HV_INDEX *storage, U32 capacity, U32 pos)
{
    U8 width = (U8)HvINDEX_WIDTH_FOR(capacity);
    const U8 *region = (const U8 *)storage->indices;
    assert(pos < capacity);
    if (width == 1) {
        U8 value = region[pos];
        return value == (U8)~(U8)0 ? HV_INDEX_DELETED : value;
    }
    if (width == 2) {
        U16 value;
        Copy(region + (Size_t)pos * sizeof(U16), &value, 1, U16);
        return value == (U16)~(U16)0 ? HV_INDEX_DELETED : value;
    }
    {
        U32 value;
        Copy(region + (Size_t)pos * sizeof(U32), &value, 1, U32);
        return value;
    }
}


PERL_STATIC_INLINE void
S_hv_index_set(PERL_HV_INDEX *storage, U32 capacity, U32 pos, U32 value)
{
    U8 width = (U8)HvINDEX_WIDTH_FOR(capacity);
    U8 *region = (U8 *)storage->indices;
    assert(pos < capacity);
    if (width == 1) {
        assert(value == HV_INDEX_DELETED || value <= 0xFE);
        region[pos] = value == HV_INDEX_DELETED ? (U8)~(U8)0 : (U8)value;
    }
    else if (width == 2) {
        U16 encoded = value == HV_INDEX_DELETED ? (U16)~(U16)0 : (U16)value;
        assert(value == HV_INDEX_DELETED || value <= 0xFFFE);
        Copy(&encoded, region + (Size_t)pos * sizeof(U16), 1, U16);
    }
    else {
        U32 encoded = value;
        assert(value == HV_INDEX_DELETED || value < U32_MAX);
        Copy(&encoded, region + (Size_t)pos * sizeof(U32), 1, U32);
    }
}




#endif
