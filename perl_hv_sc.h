/* SC storage layout and accessors. The second inclusion from inline.h
 * supplies definitions after the generated core declarations are available. */
#ifndef PERL_HV_SC_H
#define PERL_HV_SC_H

typedef struct perl_hv_sc {
    HE *entries;
    U32 capacity;
    U32 used;
    U32 tombstones;
    U8 indices[1];
} PERL_HV_INDEX;

#  ifdef PERL_HASH_INDEX_32BIT
#    define HvINDEX_WIDTH_FOR(capacity) 4
#  else
#    define HvINDEX_WIDTH_FOR(capacity) \
    ((capacity) <= 255 ? 1 : (capacity) <= 65535 ? 2 : 4)
#  endif
#  define HvINDEX_WIDTH(hv) HvINDEX_WIDTH_FOR(HvINDEX(hv)->capacity)
#  ifdef PERL_HASH_CHAIN_FINGERPRINT
#    define HvINDEX_RECORD_WIDTH_FOR(capacity) \
      (2 * HvINDEX_WIDTH_FOR(capacity))
#    define HvINDEX_STORAGE_BYTES(buckets,entries) \
      ((Size_t)(buckets) * HvINDEX_WIDTH_FOR(entries) \
       + (Size_t)(entries) * HvINDEX_RECORD_WIDTH_FOR(entries))
#    define HvINDEX_FINGERPRINT_BYTES_FOR(entries) \
      ((Size_t)(entries) * HvINDEX_WIDTH_FOR(entries))
#    define HvINDEX_FINGERPRINT_GET(hv,pos) \
      S_hv_index_fingerprint_get(HvINDEX(hv), (U32)HvMAX(hv) + 1, (U32)(pos))
#    define HvINDEX_FINGERPRINT_SET(hv,pos,hash) \
      S_hv_index_fingerprint_set(HvINDEX(hv), (U32)HvMAX(hv) + 1, (U32)(pos), \
                              (U32)(hash))
#    define HvINDEX_FINGERPRINT_VALUE_SET(hv,pos,value) \
      S_hv_index_fingerprint_set_value(HvINDEX(hv), (U32)HvMAX(hv) + 1, \
                                    (U32)(pos), (U32)(value))
#  else
#    define HvINDEX_RECORD_WIDTH_FOR(capacity) HvINDEX_WIDTH_FOR(capacity)
#    define HvINDEX_STORAGE_BYTES(buckets,entries) \
      (((Size_t)(buckets) + (entries)) * HvINDEX_WIDTH_FOR(entries))
#    define HvINDEX_FINGERPRINT_BYTES_FOR(entries) 0
#  endif
#  define HvCHAIN_NEXT(hv,ix) \
    HvINDEX_GET((hv), (U32)HvMAX(hv) + 1 + (ix))
#  define HvCHAIN_NEXT_SET(hv,ix,value) \
    HvINDEX_SET((hv), (U32)HvMAX(hv) + 1 + (ix), (value))
#define HvINDEX_BYTES_FOR(capacity) \
    ((Size_t)(capacity) * HvINDEX_WIDTH_FOR(capacity))
#define HvINDEX_REGION(storage,capacity) ((U8 *)(storage)->indices)


#define HvINDEX_GET(hv,pos) \
    S_hv_index_get(HvINDEX(hv), (U32)HvMAX(hv) + 1, (U32)(pos))
#define HvINDEX_SET(hv,pos,value) \
    S_hv_index_set(HvINDEX(hv), (U32)HvMAX(hv) + 1, (U32)(pos), (U32)(value))


#define HvINDEX_RESERVE_ENTRIES(hv) (1)

#endif

#if defined(PERL_HV_INLINE_FUNCTIONS) && !defined(PERL_HV_SC_INLINE_H)
#define PERL_HV_SC_INLINE_H

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
    const U32 width = HvINDEX_WIDTH_FOR(entries);
    if (!buckets || buckets > HV_MAX_BUCKETS || (buckets & (buckets - 1))
        || entries > (U32)I32_MAX
        || (entries && sizeof(HE) > MEM_SIZE_MAX / (Size_t)entries)
        || (Size_t)buckets > available / width)
        return FALSE;
    available -= (Size_t)buckets * width;
    if (entries > U32_MAX - buckets
        || (Size_t)entries > available / HvINDEX_RECORD_WIDTH_FOR(entries))
        return FALSE;
    return TRUE;
}

PERL_STATIC_INLINE U32
S_hv_index_get(const PERL_HV_INDEX *storage, U32 buckets, U32 pos)
{
    U32 width = HvINDEX_WIDTH_FOR(storage->capacity);
    const U8 *region = storage->indices;
    assert((Size_t)pos < (Size_t)buckets + storage->capacity);
    if (pos < buckets)
        region += (Size_t)pos * width;
    else
        region += (Size_t)buckets * width
            + ((Size_t)pos - buckets) * HvINDEX_RECORD_WIDTH_FOR(storage->capacity);
    PERL_UNUSED_ARG(buckets);
    if (width == 1) return region[0];
    if (width == 2) {
        U16 value;
        Copy(region, &value, 1, U16);
        return value;
    }
    {
        U32 value;
        Copy(region, &value, 1, U32);
        return value;
    }
}

PERL_STATIC_INLINE void
S_hv_index_set(PERL_HV_INDEX *storage, U32 buckets, U32 pos, U32 value)
{
    U32 width = HvINDEX_WIDTH_FOR(storage->capacity);
    U8 *region = storage->indices;
    assert((Size_t)pos < (Size_t)buckets + storage->capacity);
    assert(value <= storage->capacity);
    if (pos < buckets)
        region += (Size_t)pos * width;
    else
        region += (Size_t)buckets * width
            + ((Size_t)pos - buckets) * HvINDEX_RECORD_WIDTH_FOR(storage->capacity);
    PERL_UNUSED_ARG(buckets);
    if (width == 1) region[0] = (U8)value;
    else if (width == 2) {
        U16 encoded = (U16)value;
        Copy(&encoded, region, 1, U16);
    }
    else Copy(&value, region, 1, U32);
}

#ifdef PERL_HASH_CHAIN_FINGERPRINT
PERL_STATIC_INLINE U32
S_hv_index_fingerprint_get(const PERL_HV_INDEX *storage, U32 buckets, U32 pos)
{
    U32 width = HvINDEX_WIDTH_FOR(storage->capacity);
    const U8 *region;
    assert(pos >= buckets);
    assert((Size_t)pos < (Size_t)buckets + storage->capacity);
    PERL_UNUSED_ARG(buckets);
    region = storage->indices + (Size_t)buckets * width
             + ((Size_t)pos - buckets) * HvINDEX_RECORD_WIDTH_FOR(storage->capacity)
             + width;
    if (width == 1) return region[0];
    if (width == 2) {
        U16 value;
        Copy(region, &value, 1, U16);
        return value;
    }
    {
        U32 value;
        Copy(region, &value, 1, U32);
        return value;
    }
}

PERL_STATIC_INLINE void
S_hv_index_fingerprint_set_value(PERL_HV_INDEX *storage, U32 buckets, U32 pos,
                              U32 fingerprint)
{
    U32 width = HvINDEX_WIDTH_FOR(storage->capacity);
    U8 *region;
    assert(pos >= buckets);
    assert((Size_t)pos < (Size_t)buckets + storage->capacity);
    PERL_UNUSED_ARG(buckets);
    region = storage->indices + (Size_t)buckets * width
             + ((Size_t)pos - buckets) * HvINDEX_RECORD_WIDTH_FOR(storage->capacity)
             + width;
    if (width == 1) region[0] = (U8)fingerprint;
    else if (width == 2) {
        U16 encoded = (U16)fingerprint;
        Copy(&encoded, region, 1, U16);
    }
    else Copy(&fingerprint, region, 1, U32);
}

PERL_STATIC_INLINE void
S_hv_index_fingerprint_set(PERL_HV_INDEX *storage, U32 buckets, U32 pos, U32 hash)
{
    U32 width = HvINDEX_WIDTH_FOR(storage->capacity);
    S_hv_index_fingerprint_set_value(storage, buckets, pos,
        width == 1 ? hash >> 24 : width == 2 ? hash >> 16 : hash);
}
#endif


#endif
