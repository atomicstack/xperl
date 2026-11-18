/* Shared-key pointer table, independent of ordinary hash storage. */
#include "EXTERN.h"
#include "perl.h"

#define STRTAB_KEY_FLAGS (0xFF & ~HVhek_NOTSHARED)

bool
Perl_hv_strtab_size_valid(Size_t capacity)
{
    PERL_ARGS_ASSERT_HV_STRTAB_SIZE_VALID;
    return capacity >= PERL_HV_STRTAB_MIN_CAPACITY
        && !(capacity & (capacity - 1))
        && capacity <= ((Size_t)1 << (sizeof(Size_t) * CHAR_BIT - 1))
        && capacity <= (MEM_SIZE_MAX - sizeof(PERL_HV_STRTAB)) / sizeof(HEK *);
}

Size_t
Perl_hv_strtab_capacity_for(Size_t live)
{
    Size_t capacity = PERL_HV_STRTAB_MIN_CAPACITY;
    PERL_ARGS_ASSERT_HV_STRTAB_CAPACITY_FOR;
    if (live > PERL_HV_STRTAB_MAX_KEYS)
        return 0;
    while (capacity < live) {
        if (capacity > MEM_SIZE_MAX / 2)
            return 0;
        capacity *= 2;
    }
    return Perl_hv_strtab_size_valid(capacity) ? capacity : 0;
}

PERL_HV_STRTAB *
Perl_hv_strtab_new(pTHX)
{
    PERL_HV_STRTAB *table;
    PERL_ARGS_ASSERT_HV_STRTAB_NEW;
    Newxz(table, 1, PERL_HV_STRTAB);
    return table;
}

PERL_STATIC_INLINE HEK *
S_strtab_lookup(const PERL_HV_STRTAB *table, U32 hash, const char *key,
                STRLEN len, U8 flags)
{
    HEK *hek;
    if (!table->capacity) return NULL;
    for (hek = table->slots[hash & (table->capacity - 1)]; hek;
         hek = HvSTR_SHARED(hek)->next) {
        if (HEK_HASH(hek) == hash && HEK_LEN(hek) == (I32)len
            && (HEK_FLAGS(hek) & STRTAB_KEY_FLAGS) == flags
            && (HEK_KEY(hek) == key || memEQ(HEK_KEY(hek), key, len)))
            return hek;
    }
    return NULL;
}

HEK *
Perl_hv_strtab_find(pTHX_ const PERL_HV_STRTAB *table, U32 hash,
                    const char *key, STRLEN len, U8 flags)
{
    PERL_ARGS_ASSERT_HV_STRTAB_FIND;
    if (len > I32_MAX) return NULL;
    return S_strtab_lookup(table, hash, key, len, flags & STRTAB_KEY_FLAGS);
}

static void
S_strtab_rehash(pTHX_ PERL_HV_STRTAB *table, Size_t capacity)
{
    HEK **slots;
    Size_t i;
    if (!Perl_hv_strtab_size_valid(capacity)) Perl_croak_memory_wrap();
    Newxz(slots, capacity, HEK *);
    for (i = 0; i < table->capacity; i++) {
        HEK *hek = table->slots[i];
        while (hek) {
            HEK *next = HvSTR_SHARED(hek)->next;
            const Size_t pos = HEK_HASH(hek) & (capacity - 1);
            HvSTR_SHARED(hek)->next = slots[pos];
            slots[pos] = hek;
            hek = next;
        }
    }
    Safefree(table->slots);
    table->slots = slots;
    table->capacity = capacity;
}

void
Perl_hv_strtab_reserve(pTHX_ PERL_HV_STRTAB *table, Size_t live)
{
    Size_t capacity;
    PERL_ARGS_ASSERT_HV_STRTAB_RESERVE;
    if (live > PERL_HV_STRTAB_MAX_KEYS)
        PERL_THROW_ERROR_VALUE_HASH_CAPACITY_EXCEEDED((UV)PERL_HV_STRTAB_MAX_KEYS);
    capacity = Perl_hv_strtab_capacity_for(live);
    if (!capacity) Perl_croak_memory_wrap();
    if (capacity > table->capacity) S_strtab_rehash(aTHX_ table, capacity);
}

HEK *
Perl_hv_strtab_share(pTHX_ PERL_HV_STRTAB *table, U32 hash,
                     const char *key, STRLEN len, U8 flags)
{
    HEK *hek;
    struct shared_hek *shared;
    Size_t pos;
    char *raw;
    PERL_ARGS_ASSERT_HV_STRTAB_SHARE;
    if (len > I32_MAX) PERL_THROW_ERROR_VALUE_HASH_KEY_LENGTH_OUT_OF_RANGE();
    flags &= STRTAB_KEY_FLAGS;
    if (!table->capacity)
        S_strtab_rehash(aTHX_ table, PERL_HV_STRTAB_MIN_CAPACITY);
    hek = S_strtab_lookup(table, hash, key, len, flags);
    if (hek) return share_hek_hek(hek);
    /* Reporting exhaustion must not intern another key or invoke Perl hooks. */
    if (table->live >= PERL_HV_STRTAB_MAX_KEYS)
        PERL_THROW_ERROR_VALUE_HASH_CAPACITY_EXCEEDED_STRTAB((UV)PERL_HV_STRTAB_MAX_KEYS);
    /* Grow for the pending distinct key. Chaining has no deleted slots
     * to count or clean, and keeps HEK addresses stable during a split. */
    if (table->live >= table->capacity) {
        if (table->capacity > MEM_SIZE_MAX / 2) Perl_croak_memory_wrap();
        S_strtab_rehash(aTHX_ table, table->capacity * 2);
    }
    pos = hash & (table->capacity - 1);
    Newx(raw, STRUCT_OFFSET(struct shared_hek, shared_hek_hek.hek_key[0])
               + len + 2, char);
    shared = (struct shared_hek *)raw;
    hek = &shared->shared_hek_hek;
    Copy(key, HEK_KEY(hek), len, char);
    HEK_KEY(hek)[len] = 0;
    HEK_LEN(hek) = len;
    HEK_HASH(hek) = hash;
    HEK_FLAGS(hek) = flags;
    shared->refcount = 1;
    shared->next = table->slots[pos];
    table->slots[pos] = hek;
    table->live++;
    return hek;
}

bool
Perl_hv_strtab_release(pTHX_ PERL_HV_STRTAB *table, const HEK *hek)
{
    HEK **link;
    struct shared_hek *shared;
    PERL_ARGS_ASSERT_HV_STRTAB_RELEASE;
    assert(!(HEK_FLAGS(hek) & HVhek_NOTSHARED));
    shared = HvSTR_SHARED(hek);
    if (shared->refcount > 1) { shared->refcount--; return TRUE; }
    if (!table->capacity) return FALSE;
    /* Keep the incoming link so final release can unlink without a second
     * search. Pointer identity avoids comparing candidate key bytes. */
    for (link = &table->slots[HEK_HASH(hek) & (table->capacity - 1)];
         *link; link = &HvSTR_SHARED(*link)->next) {
        if (*link == hek) {
            *link = shared->next;
            table->live--;
            Safefree(shared);
            return TRUE;
        }
    }
    return FALSE;
}

bool
Perl_hv_strtab_release_key(pTHX_ PERL_HV_STRTAB *table, U32 hash,
                           const char *key, STRLEN len, U8 flags)
{
    HEK *hek;
    PERL_ARGS_ASSERT_HV_STRTAB_RELEASE_KEY;
    hek = Perl_hv_strtab_find(aTHX_ table, hash, key, len, flags);
    return hek ? Perl_hv_strtab_release(aTHX_ table, hek) : FALSE;
}

void
Perl_hv_strtab_pin(pTHX_ PERL_HV_STRTAB *table, HEK *hek, Size_t count)
{
    struct perl_hv_strtab_pin *pin;
    PERL_ARGS_ASSERT_HV_STRTAB_PIN;
    assert(count && count <= HvSTR_REFCOUNT(hek));
    for (pin = table->pins; pin; pin = pin->next) {
        if (pin->hek == hek) { pin->count += count; return; }
    }
    Newx(pin, 1, struct perl_hv_strtab_pin);
    pin->hek = hek;
    pin->count = count;
    pin->next = table->pins;
    table->pins = pin;
}

Size_t
Perl_hv_strtab_free(pTHX_ PERL_HV_STRTAB *table,
                    perl_hv_strtab_report_t report, void *arg)
{
    Size_t i, retained = 0;
    struct perl_hv_strtab_pin *pin;
    PERL_ARGS_ASSERT_HV_STRTAB_FREE;
    if (!table) return 0;
    pin = table->pins;
    while (pin) {
        struct perl_hv_strtab_pin *next = pin->next;
        assert(HvSTR_REFCOUNT(pin->hek) >= pin->count);
        HvSTR_REFCOUNT(pin->hek) -= pin->count - 1;
        (void)Perl_hv_strtab_release(aTHX_ table, pin->hek);
        Safefree(pin);
        pin = next;
    }
    for (i = 0; i < table->capacity; i++) {
        HEK *hek = table->slots[i];
        while (hek) {
            HEK *next = HvSTR_SHARED(hek)->next;
            retained++;
            if (report) report(aTHX_ hek, arg);
            Safefree(HvSTR_SHARED(hek));
            hek = next;
        }
    }
    Safefree(table->slots);
    Safefree(table);
    return retained;
}

#undef STRTAB_KEY_FLAGS
