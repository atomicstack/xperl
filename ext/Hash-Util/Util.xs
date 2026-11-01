#define PERL_NO_GET_CONTEXT

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#if defined(__GLIBC__) && !defined(PERL_TRACK_MEMPOOL) && !defined(MYMALLOC)
#  include <malloc.h>
#endif

MODULE = Hash::Util		PACKAGE = Hash::Util

void
_clear_placeholders(hashref)
        HV *hashref
    PROTOTYPE: \%
    PREINIT:
        HV *hv;
    CODE:
        hv = MUTABLE_HV(hashref);
        hv_clear_placeholders(hv);

void
all_keys(hash,keys,placeholder)
	HV *hash
	AV *keys
	AV *placeholder
    PROTOTYPE: \%\@\@
    PREINIT:
        SV *key;
        HE *he;
    PPCODE:
        av_clear(keys);
        av_clear(placeholder);

        (void)hv_iterinit(hash);
	while((he = hv_iternext_flags(hash, HV_ITERNEXT_WANTPLACEHOLDERS))!= NULL) {
	    key=hv_iterkeysv(he);
	    av_push(HeVAL(he) == &PL_sv_placeholder ? placeholder : keys,
		    SvREFCNT_inc(key));
        }
	XSRETURN(1);

void
hidden_ref_keys(hash)
	HV *hash
    ALIAS:
	Hash::Util::legal_ref_keys = 1
    PREINIT:
        SV *key;
        HE *he;
    PPCODE:
        (void)hv_iterinit(hash);
	while((he = hv_iternext_flags(hash, HV_ITERNEXT_WANTPLACEHOLDERS))!= NULL) {
	    key=hv_iterkeysv(he);
            if (ix || HeVAL(he) == &PL_sv_placeholder) {
                XPUSHs( key );
            }
        }

void
hv_store(hash, key, val)
	HV *hash
	SV* key
	SV* val
    PROTOTYPE: \%$$
    CODE:
    {
        SvREFCNT_inc(val);
	if (!hv_store_ent(hash, key, val, 0)) {
	    SvREFCNT_dec(val);
	    XSRETURN_NO;
	} else {
	    XSRETURN_YES;
	}
    }

void
hash_seed()
    PROTOTYPE:
    PPCODE:
    mXPUSHs(newSVpvn((char *)PERL_HASH_SEED,PERL_HASH_SEED_BYTES));
    XSRETURN(1);


void
hash_value(string,...)
        SV* string
    PROTOTYPE: $;$
    PPCODE:
{
    UV uv;
    STRLEN len;
    char *pv= SvPV(string,len);
    if (items<2) {
        PERL_HASH(uv, pv, len);
    } else {
        STRLEN seedlen;
        U8 *seedbuf= (U8 *)SvPV(ST(1),seedlen);
        if ( seedlen < PERL_HASH_SEED_BYTES ) {
            sv_dump(ST(1));
            Perl_croak(aTHX_ "seed len must be at least %" UVuf " long only got %"
                             UVuf " bytes", (UV)PERL_HASH_SEED_BYTES, (UV)seedlen);
        }

        PERL_HASH_WITH_SEED(seedbuf, uv, pv, len);
    }
    XSRETURN_UV(uv);
}

void
bucket_info(rhv)
        SV* rhv
    PPCODE:
{
    /*

    Takes a non-magical hash ref as an argument and returns a list of
    statistics about the hash. The number and keys and the size of the
    array will always be reported as the first two values. If the array is
    actually allocated (they are lazily allocated), then additionally
    will return a list of counts of bucket lengths. In other words in

        ($keys, $buckets, $used, @length_count)= hash::bucket_info(\%hash);

    $length_count[0] is the number of empty buckets, and $length_count[1]
    is the number of buckets with only one key in it, $buckets - $length_count[0]
    gives the number of used buckets, and @length_count-1 is the maximum
    bucket depth.

    If the argument is not a hash ref, or if it is magical, then returns
    nothing (the empty list).

    */
    const HV * hv = NULL;
    if (SvROK(rhv) && SvTYPE(SvRV(rhv))==SVt_PVHV && !SvMAGICAL(SvRV(rhv))) {
        hv = (const HV *) SvRV(rhv);
    } else if (!SvOK(rhv)) {
        hv = NULL;
    }
    if (hv) {
        U32 max_bucket_index;
        U32 total_keys;
        HE **bucket_array;
        if (HvIS_STRTAB(hv))
            XSRETURN(0);
        max_bucket_index = HvMAX(hv);
        total_keys = HvUSEDKEYS(hv);
        bucket_array = HvARRAY(hv);
        mXPUSHi(total_keys);
        mXPUSHi(max_bucket_index+1);
        mXPUSHi(0); /* for the number of used buckets */
#define BUCKET_INFO_ITEMS_ON_STACK 3
        if (!bucket_array) {
            XSRETURN(BUCKET_INFO_ITEMS_ON_STACK);
        } else {
            /* we use chain_length to index the stack - we eliminate an add
             * by initializing things with the number of items already on the stack.
             * If we have 2 items then ST(2+0) (the third stack item) will be the counter
             * for empty chains, ST(2+1) will be for chains with one element,  etc.
             */
            I32 max_chain_length= BUCKET_INFO_ITEMS_ON_STACK - 1; /* so we do not have to do an extra push for the 0 index */
            HE *he;
            U32 bucket_index;
            for ( bucket_index= 0; bucket_index <= max_bucket_index; bucket_index++ ) {
                I32 chain_length= BUCKET_INFO_ITEMS_ON_STACK;
                for (he= HvIS_LINEAR(hv)
                         ? bucket_array[bucket_index]
                         : HvIS_OA(hv)
                         ? (HvOA_INDEX_GET(hv, bucket_index) != 0
                            && HvOA_INDEX_GET(hv, bucket_index) != U32_MAX
                            ? &HvOA(hv)->entries[HvOA_INDEX_GET(hv, bucket_index) - 1]
                            : NULL)
                         : bucket_array[bucket_index];
                     he; he= HvENTRY_NEXT(hv, he)) {
                    chain_length++;
                }
                while ( max_chain_length < chain_length ) {
                    mXPUSHi(0);
                    max_chain_length++;
                }
                SvIVX( ST( chain_length ) )++;
            }
            /* now set the number of used buckets */
            SvIVX( ST( BUCKET_INFO_ITEMS_ON_STACK - 1 ) ) = max_bucket_index - SvIVX( ST( BUCKET_INFO_ITEMS_ON_STACK ) ) + 1;
            XSRETURN( max_chain_length + 1 ); /* max_chain_length is the index of the last item on the stack, so we add 1 */
        }
#undef BUCKET_INFO_ITEMS_ON_STACK
    }
    XSRETURN(0);
}

void
bucket_array(rhv)
        SV* rhv
    PPCODE:
{
    /* Returns an array of arrays representing key/bucket mappings.
     * Each element of the array contains either an integer or a reference
     * to an array of keys. A plain integer represents K empty buckets. An
     * array ref represents a single bucket, with each element being a key in
     * the hash. (Note this treats a placeholder as a normal key.)
     *
     * This allows one to "see" the keyorder. Note the "insert first" nature
     * of the hash store, combined with regular remappings means that relative
     * order of keys changes each remap.
     */
    const HV * hv = NULL;
    if (SvROK(rhv) && SvTYPE(SvRV(rhv))==SVt_PVHV && !SvMAGICAL(SvRV(rhv))) {
        hv = (const HV *) SvRV(rhv);
    } else if (!SvOK(rhv)) {
        hv = NULL;
    }
    if (hv) {
        HE **he_ptr = HvARRAY(hv);
        if (HvIS_STRTAB(hv))
            XSRETURN(0);
        if (!he_ptr) {
            XSRETURN(0);
        } else {
            U32 i, max;
            AV *info_av;
            HE *he;
            I32 empty_count=0;
            if (SvMAGICAL(hv)) {
                Perl_croak(aTHX_ "hash::bucket_array only works on 'normal' hashes");
            }
            info_av= newAV();
            max= HvMAX(hv);
            mXPUSHs(newRV_noinc((SV*)info_av));
            for ( i= 0; i <= max; i++ ) {
                AV *key_av= NULL;
                for (he= HvIS_LINEAR(hv)
                         ? (HE *)&HvENTRIES(hv)[i]
                         : HvIS_OA(hv)
                         ? (HvOA_INDEX_GET(hv, i) != 0
                            && HvOA_INDEX_GET(hv, i) != U32_MAX
                            ? &HvOA(hv)->entries[HvOA_INDEX_GET(hv, i) - 1]
                            : NULL)
                         : he_ptr[i];
                     he; he= HvENTRY_NEXT(hv, he)) {
                    SV *key_sv;
                    char *str;
                    STRLEN len;
                    char mode;
                    if (!key_av) {
                        key_av= newAV();
                        if (empty_count) {
                            av_push_simple(info_av, newSViv(empty_count));
                            empty_count= 0;
                        }
                        av_push_simple(info_av, (SV *)newRV_noinc((SV *)key_av));
                    }
                    if (HeKLEN(he) == HEf_SVKEY) {
                        SV *sv= HeSVKEY(he);
                        SvGETMAGIC(sv);
                        str= SvPV(sv, len);
                        mode= SvUTF8(sv) ? 1 : 0;
                    } else {
                        str= HeKEY(he);
                        len= HeKLEN(he);
                        mode= HeKUTF8(he) ? 1 : 0;
                    }
                    key_sv= newSVpvn(str,len);
                    av_push_simple(key_av,key_sv);
                    if (mode) {
                        SvUTF8_on(key_sv);
                    }
                }
                if (!key_av)
                    empty_count++;
            }
            if (empty_count) {
                av_push_simple(info_av, newSViv(empty_count));
                empty_count++;
            }
        }
        XSRETURN(1);
    }
    XSRETURN(0);
}

void
bucket_ratio(rhv)
        SV* rhv
    PROTOTYPE: \%
    PPCODE:
{
    if (SvROK(rhv)) {
        rhv= SvRV(rhv);
        if ( SvTYPE(rhv)==SVt_PVHV && !HvIS_STRTAB((HV *)rhv) ) {
#if PERL_VERSION_LT(5,25,0)
            SV *ret= Perl_hv_scalar(aTHX_ (HV*)rhv);
#else
            SV *ret= Perl_hv_bucket_ratio(aTHX_ (HV*)rhv);
#endif
            ST(0)= ret;
            XSRETURN(1);
        }
    }
    XSRETURN_UNDEF;
}

void
num_buckets(rhv)
        SV* rhv
    PROTOTYPE: \%
    PPCODE:
{
    if (SvROK(rhv)) {
        rhv= SvRV(rhv);
        if ( SvTYPE(rhv)==SVt_PVHV && !HvIS_STRTAB((HV *)rhv) ) {
            XSRETURN_UV(HvMAX((HV*)rhv)+1);
        }
    }
    XSRETURN_UNDEF;
}

void
used_buckets(rhv)
        SV* rhv
    PROTOTYPE: \%
    PPCODE:
{
    if (SvROK(rhv)) {
        rhv= SvRV(rhv);
        if ( SvTYPE(rhv)==SVt_PVHV && !HvIS_STRTAB((HV *)rhv) ) {
            XSRETURN_UV(HvFILL((HV*)rhv));
        }
    }
    XSRETURN_UNDEF;
}


SV *
hash_storage_info(hash)
        HV *hash
    CODE:
    {
        HV *info;
        UV index_bytes, entry_bytes, allocated_bytes;
        if (HvIS_STRTAB(hash))
            Perl_croak(aTHX_ "hash_storage_info cannot inspect PL_strtab");
        info = newHV();
        index_bytes = HvARRAY(hash) ? (HvMAX(hash) + 1) * sizeof(HE *) : 0;
        entry_bytes = HvTOTALKEYS(hash) * sizeof(HE);
        allocated_bytes = 0;
#define STORAGE_INFO(name, value) \
        (void)hv_stores(info, name, newSVuv((UV)(value)))
        STORAGE_INFO("he_size", sizeof(HE));
        STORAGE_INFO("hv_size", sizeof(HV));
        STORAGE_INFO("hv_body_size", sizeof(XPVHV));
        STORAGE_INFO("live", HvTOTALKEYS(hash));
        STORAGE_INFO("index_capacity", HvARRAY(hash) && !HvIS_LINEAR(hash)
                     ? HvMAX(hash) + 1 : 0);
#ifdef HvIS_OA
        STORAGE_INFO("linear", HvIS_LINEAR(hash) ? 1 : 0);
        STORAGE_INFO("open_addressed", HvIS_OA(hash) && !HvIS_LINEAR(hash));
        if (HvIS_LINEAR(hash)) {
            const U32 capacity = HvLINEAR_CAP(hash);
            const bool arena_backed = capacity == 1 && HvARRAY(hash);
            index_bytes = 0;
            entry_bytes = arena_backed ? sizeof(HE)
                         : (UV)capacity * sizeof(HE);
            STORAGE_INFO("entry_capacity", capacity);
            STORAGE_INFO("entry_used", HvTOTALKEYS(hash));
            STORAGE_INFO("arena_backed", arena_backed ? 1 : 0);
            STORAGE_INFO("arena_slot_size", arena_backed
                         ? sizeof(HE) : 0);
            STORAGE_INFO("free_head", 0);
            STORAGE_INFO("tombstones", 0);
            STORAGE_INFO("index_width", 0);
            STORAGE_INFO("slot_size", 0);
            STORAGE_INFO("metadata_bytes", 0);
            STORAGE_INFO("hash_bytes", 0);
            STORAGE_INFO("entry_index_bytes", 0);
            STORAGE_INFO("entry_spare", capacity - HvTOTALKEYS(hash));
            STORAGE_INFO("free_list_length", 0);
            STORAGE_INFO("index_empty", 0);
            STORAGE_INFO("index_deleted", 0);
            STORAGE_INFO("probe_total", 0);
            STORAGE_INFO("probe_max", 0);
            (void)hv_stores(info, "probe_mean", newSVnv(0));
            STORAGE_INFO("entries_address", PTR2UV(HvARRAY(hash)));
            STORAGE_INFO("index_address", 0);
#if defined(__GLIBC__) && !defined(PERL_TRACK_MEMPOOL) && !defined(MYMALLOC)
            if (capacity >= 2)
                allocated_bytes = malloc_usable_size(HvARRAY(hash));
#endif
        }
        else if (HvIS_OA(hash)) {
            struct hv_oa *oa = HvARRAY(hash) ? HvOA(hash) : NULL;
            const U32 capacity = oa ? HvMAX(hash) + 1 : 0;
            const U32 index_width = oa ? HvOA_INDEX_WIDTH(hash) : 0;
            const UV hash_bytes = 0;
            const UV entry_index_bytes = (UV)capacity * index_width;
            index_bytes = oa ? STRUCT_OFFSET(struct hv_oa, indices)
                              + entry_index_bytes : 0;
            entry_bytes = oa ? oa->capacity * sizeof(HE) : 0;
            STORAGE_INFO("entry_capacity", oa ? oa->capacity : 0);
            STORAGE_INFO("entry_used", oa ? oa->used : 0);
            STORAGE_INFO("free_head", oa ? oa->free_head : 0);
            STORAGE_INFO("tombstones", oa ? oa->tombstones : 0);
            STORAGE_INFO("index_width", index_width);
            STORAGE_INFO("slot_size", index_width);
            STORAGE_INFO("metadata_bytes", oa
                         ? STRUCT_OFFSET(struct hv_oa, indices) : 0);
            STORAGE_INFO("hash_bytes", hash_bytes);
            STORAGE_INFO("entry_index_bytes", entry_index_bytes);
            STORAGE_INFO("entry_spare", oa ? oa->capacity - oa->used : 0);
            if (oa) {
                U32 link = oa->free_head;
                UV free_count = 0, empty = 0, deleted = 0;
                UV probe_total = 0, probe_max = 0;
                STRLEN i;
                while (link) {
                    if (link > oa->used || free_count >= oa->used)
                        Perl_croak(aTHX_ "Corrupt hash entry free list");
                    free_count++;
                    link = HeNEXT_FREE(&oa->entries[link - 1]);
                }
                for (i = 0; i <= HvMAX(hash); i++) {
                    const U32 entry_index = HvOA_INDEX_GET(hash, i);
                    if (!entry_index)
                        empty++;
                    else if (entry_index == U32_MAX)
                        deleted++;
                    else {
                        const U32 slot_hash = HeHASH(&oa->entries[entry_index - 1]);
                        UV distance = (i - (slot_hash & HvMAX(hash))) & HvMAX(hash);
                        probe_total += distance;
                        if (distance > probe_max) probe_max = distance;
                    }
                }
                STORAGE_INFO("free_list_length", free_count);
                STORAGE_INFO("index_empty", empty);
                STORAGE_INFO("index_deleted", deleted);
                STORAGE_INFO("probe_total", probe_total);
                STORAGE_INFO("probe_max", probe_max);
                (void)hv_stores(info, "probe_mean", newSVnv(HvTOTALKEYS(hash)
                    ? (NV)probe_total / HvTOTALKEYS(hash) : 0));
            }
            else {
                STORAGE_INFO("free_list_length", 0);
                STORAGE_INFO("index_empty", 0);
                STORAGE_INFO("index_deleted", 0);
                STORAGE_INFO("probe_total", 0);
                STORAGE_INFO("probe_max", 0);
                (void)hv_stores(info, "probe_mean", newSVnv(0));
            }
            STORAGE_INFO("entries_address", oa ? PTR2UV(oa->entries) : 0);
            STORAGE_INFO("index_address", PTR2UV(oa));
#if defined(__GLIBC__) && !defined(PERL_TRACK_MEMPOOL) && !defined(MYMALLOC)
            if (oa) {
                allocated_bytes = malloc_usable_size(oa);
                if (oa->entries)
                    allocated_bytes += malloc_usable_size(oa->entries);
            }
#endif
        }
#else
        STORAGE_INFO("open_addressed", 0);
#endif
        STORAGE_INFO("index_bytes", index_bytes);
        STORAGE_INFO("entry_bytes", entry_bytes);
        STORAGE_INFO("requested_bytes", index_bytes + entry_bytes);
        STORAGE_INFO("allocator_bytes", allocated_bytes);
#undef STORAGE_INFO
        RETVAL = newRV_noinc((SV *)info);
    }
    OUTPUT:
        RETVAL

UV
immortalize_key(key)
        SV *key
    CODE:
        RETVAL = Perl_immortalize_key(aTHX_ key);
    OUTPUT:
        RETVAL

UV
shared_key_refcount(key)
        SV *key
    CODE:
        RETVAL = Perl_shared_key_refcount(aTHX_ key);
    OUTPUT:
        RETVAL

void
shared_keys()
    PREINIT:
        AV *keys;
        SSize_t i, last;
        SV **slot;
    PPCODE:
        if (GIMME_V == G_VOID)
            XSRETURN_EMPTY;
        if (GIMME_V == G_SCALAR)
            XSRETURN_UV(HvTOTALKEYS(PL_strtab));
        keys = MUTABLE_AV(sv_2mortal((SV *)Perl_shared_keys(aTHX)));
        last = av_len(keys);
        EXTEND(SP, last + 1);
        for (i = 0; i <= last; i++) {
            slot = av_fetch(keys, i, FALSE);
            if (slot && *slot)
                XPUSHs(sv_2mortal(SvREFCNT_inc_simple_NN(*slot)));
        }
