MODULE = XS::APItest:Hash               PACKAGE = XS::APItest::Hash

AV *
shared_hek_refcount_probe(count)
    UV count
    PREINIT:
        struct shared_hek key;
        HEK *hek = &key.shared_hek_hek;
    CODE:
        if (count > U32_MAX)
            croak("test count exceeds U32");
        key.refcount = (U32)count;
        (void)share_hek_hek(hek);
        RETVAL = newAV();
        av_push(RETVAL, newSVuv(sizeof(key.refcount)));
        av_push(RETVAL, newSVuv(STRUCT_OFFSET(struct shared_hek,
                                             shared_hek_hek.hek_key[0])));
        av_push(RETVAL, newSVuv(key.refcount));
    OUTPUT:
        RETVAL

AV *
shared_key_storage_info()
    PREINIT:
        AV *result;
        U32 capacity;
        U32 live;
        U32 tombstones;
        U32 i;
        UV max_distance = 0;
        UV total_distance = 0;
        HEK **slots;
    CODE:
        capacity = HvARRAY(PL_strtab) ? HvMAX(PL_strtab) + 1 : 0;
        live = HvTOTALKEYS(PL_strtab);
        tombstones = HvSTRTAB(PL_strtab)->tombstones;
        slots = HvSTRSLOTS(PL_strtab);
        for (i = 0; i < capacity; i++) {
            HEK *hek = slots[i];
            if (hek && hek != HvSTR_TOMBSTONE) {
                UV distance = (i - (HEK_HASH(hek) & (capacity - 1)))
                              & (capacity - 1);
                total_distance += distance;
                if (distance > max_distance)
                    max_distance = distance;
            }
        }
        result = newAV();
        av_push(result, newSVuv(capacity));
        av_push(result, newSVuv(live));
        av_push(result, newSVuv(tombstones));
        av_push(result, newSVuv(sizeof(HEK *)));
        av_push(result, newSVuv(STRUCT_OFFSET(struct hv_strtab, slots)));
        av_push(result, newSVuv(max_distance));
        av_push(result, newSVuv(total_distance));
        RETVAL = result;
    OUTPUT:
        RETVAL

void
rot13_hash(hash)
        HV *hash
        CODE:
        {
            struct ufuncs uf;
            uf.uf_val = rot13_key;
            uf.uf_set = 0;
            uf.uf_index = 0;

            sv_magic((SV*)hash, NULL, PERL_MAGIC_uvar, (char*)&uf, sizeof(uf));
        }

void
bitflip_hash(hash)
        HV *hash
        CODE:
        {
            struct ufuncs uf;
            uf.uf_val = bitflip_key;
            uf.uf_set = 0;
            uf.uf_index = 0;

            sv_magic((SV*)hash, NULL, PERL_MAGIC_uvar, (char*)&uf, sizeof(uf));
        }

#define UTF8KLEN(sv, len)   (SvUTF8(sv) ? -(I32)len : (I32)len)

bool
exists(hash, key_sv)
        PREINIT:
        STRLEN len;
        const char *key;
        INPUT:
        HV *hash
        SV *key_sv
        CODE:
        key = SvPV(key_sv, len);
        RETVAL = hv_exists(hash, key, UTF8KLEN(key_sv, len));
        OUTPUT:
        RETVAL

bool
exists_ent(hash, key_sv)
        PREINIT:
        INPUT:
        HV *hash
        SV *key_sv
        CODE:
        RETVAL = hv_exists_ent(hash, key_sv, 0);
        OUTPUT:
        RETVAL

SV *
delete(hash, key_sv, flags = 0)
        PREINIT:
        STRLEN len;
        const char *key;
        INPUT:
        HV *hash
        SV *key_sv
        I32 flags;
        CODE:
        key = SvPV(key_sv, len);
        /* It's already mortal, so need to increase reference count.  */
        RETVAL
            = SvREFCNT_inc(hv_delete(hash, key, UTF8KLEN(key_sv, len), flags));
        OUTPUT:
        RETVAL

SV *
delete_ent(hash, key_sv, flags = 0)
        INPUT:
        HV *hash
        SV *key_sv
        I32 flags;
        CODE:
        /* It's already mortal, so need to increase reference count.  */
        RETVAL = SvREFCNT_inc(hv_delete_ent(hash, key_sv, flags, 0));
        OUTPUT:
        RETVAL

SV *
store_ent(hash, key, value)
        PREINIT:
        SV *copy;
        HE *result;
        INPUT:
        HV *hash
        SV *key
        SV *value
        CODE:
        copy = newSV(0);
        result = hv_store_ent(hash, key, copy, 0);
        SvSetMagicSV(copy, value);
        if (!result) {
            SvREFCNT_dec(copy);
            XSRETURN_EMPTY;
        }
        /* It's about to become mortal, so need to increase reference count.
         */
        RETVAL = SvREFCNT_inc(HeVAL(result));
        OUTPUT:
        RETVAL

SV *
store(hash, key_sv, value)
        PREINIT:
        STRLEN len;
        const char *key;
        SV *copy;
        SV **result;
        INPUT:
        HV *hash
        SV *key_sv
        SV *value
        CODE:
        key = SvPV(key_sv, len);
        copy = newSV(0);
        result = hv_store(hash, key, UTF8KLEN(key_sv, len), copy, 0);
        SvSetMagicSV(copy, value);
        if (!result) {
            SvREFCNT_dec(copy);
            XSRETURN_EMPTY;
        }
        /* It's about to become mortal, so need to increase reference count.
         */
        RETVAL = SvREFCNT_inc(*result);
        OUTPUT:
        RETVAL

SV *
fetch_ent(hash, key_sv)
        PREINIT:
        HE *result;
        INPUT:
        HV *hash
        SV *key_sv
        CODE:
        result = hv_fetch_ent(hash, key_sv, 0, 0);
        if (!result) {
            XSRETURN_EMPTY;
        }
        /* Force mg_get  */
        RETVAL = newSVsv(HeVAL(result));
        OUTPUT:
        RETVAL

SV *
fetch(hash, key_sv)
        PREINIT:
        STRLEN len;
        const char *key;
        SV **result;
        INPUT:
        HV *hash
        SV *key_sv
        CODE:
        key = SvPV(key_sv, len);
        result = hv_fetch(hash, key, UTF8KLEN(key_sv, len), 0);
        if (!result) {
            XSRETURN_EMPTY;
        }
        /* Force mg_get  */
        RETVAL = newSVsv(*result);
        OUTPUT:
        RETVAL

SV *
common(params)
        INPUT:
        HV *params
        PREINIT:
        HE *result;
        HV *hv = NULL;
        SV *keysv = NULL;
        const char *key = NULL;
        STRLEN klen = 0;
        int flags = 0;
        int action = 0;
        SV *val = NULL;
        U32 hash = 0;
        SV **svp;
        CODE:
        if ((svp = hv_fetchs(params, "hv", 0))) {
            SV *const rv = *svp;
            if (!SvROK(rv))
                croak("common passed a non-reference for parameter hv");
            hv = (HV *)SvRV(rv);
        }
        if ((svp = hv_fetchs(params, "keysv", 0)))
            keysv = *svp;
        if ((svp = hv_fetchs(params, "keypv", 0))) {
            key = SvPV_const(*svp, klen);
            if (SvUTF8(*svp))
                flags = HVhek_UTF8;
        }
        if ((svp = hv_fetchs(params, "action", 0)))
            action = SvIV(*svp);
        if ((svp = hv_fetchs(params, "val", 0)))
            val = newSVsv(*svp);
        if ((svp = hv_fetchs(params, "hash", 0)))
            hash = SvUV(*svp);

        if (hv_fetchs(params, "hash_pv", 0)) {
            assert(key);
            PERL_HASH(hash, key, klen);
        }
        if (hv_fetchs(params, "hash_sv", 0)) {
            assert(keysv);
            {
              STRLEN len;
              const char *const p = SvPV(keysv, len);
              PERL_HASH(hash, p, len);
            }
        }

        result = (HE *)hv_common(hv, keysv, key, klen, flags, action, val, hash);
        if (!result) {
            XSRETURN_EMPTY;
        }
        /* Force mg_get  */
        RETVAL = newSVsv(HeVAL(result));
        OUTPUT:
        RETVAL

void
test_hv_free_ent()
        PPCODE:
        test_freeent(&Perl_hv_free_ent);
        XSRETURN(4);

void
test_hv_delayfree_ent()
        PPCODE:
        test_freeent(&Perl_hv_delayfree_ent);
        XSRETURN(4);

SV *
test_share_unshare_pvn(input)
        PREINIT:
        STRLEN len;
        U32 hash;
        char *pvx;
        char *p;
        INPUT:
        SV *input
        CODE:
        pvx = SvPV(input, len);
        PERL_HASH(hash, pvx, len);
        p = sharepvn(pvx, len, hash);
        RETVAL = newSVpvn(p, len);
        unsharepvn(p, len, hash);
        OUTPUT:
        RETVAL

SV *
test_shared_hek_probe(input, max_growth_keys = 0)
        SV *input
        UV max_growth_keys
    PREINIT:
        STRLEN len;
        const char *pv;
        SSize_t share_len;
        U32 hash;
        HEK *target;
        HEK *duplicate;
        HEK **held = NULL;
        U32 held_count = 0;
        U32 held_capacity = 0;
        U32 capacity_before;
        U32 capacity_after;
        U32 i;
        Size_t refs_after_first;
        Size_t refs_after_duplicate;
        Size_t refs_after_release;
        U32 target_hash;
        bool same_pointer;
        bool target_utf8;
        bool target_was_utf8;
        I32 target_len;
        U32 tombstones_before;
        U32 tombstones_after_delete;
        U32 tombstones_after_reinsert;
        U32 tombstones_after_cleanup;
        U32 cleanup_limit;
        U32 tombstones_at_cleanup = 0;
        U32 live_at_cleanup = 0;
        bool cleanup_observed = FALSE;
        char keybuf[96];
        STRLEN keylen;
        HEK *reinserted;
        HEK *cleanup_hek;
        AV *result;
    CODE:
        if (max_growth_keys > 1000000)
            croak("test_shared_hek_probe growth limit is too large");
        pv = SvPV(input, len);
        if (len > I32_MAX)
            croak("test_shared_hek_probe key is too long");
        share_len = SvUTF8(input) ? -(SSize_t)len : (SSize_t)len;
        PERL_HASH(hash, pv, len);
        target = share_hek(pv, share_len, hash);
        capacity_before = HvMAX(PL_strtab) + 1;
        refs_after_first = HvSTR_REFCOUNT(target);
        duplicate = share_hek(pv, share_len, hash);
        refs_after_duplicate = HvSTR_REFCOUNT(target);
        unshare_hek(duplicate);
        refs_after_release = HvSTR_REFCOUNT(target);
        target_hash = HEK_HASH(target);
        target_utf8 = HEK_UTF8(target);
        target_was_utf8 = HEK_WASUTF8(target);
        target_len = HEK_LEN(target);

        if (max_growth_keys) {
            held_capacity = 64;
            Newx(held, held_capacity, HEK *);
            for (i = 0; i < max_growth_keys; i++) {
                if (held_count == held_capacity) {
                    held_capacity *= 2;
                    Renew(held, held_capacity, HEK *);
                }
                my_snprintf(keybuf, sizeof keybuf,
                            "xperl-shared-hek-growth-%" UVuf "-%" UVuf,
                            PTR2UV(input), (UV)i);
                keylen = strlen(keybuf);
                PERL_HASH(hash, keybuf, keylen);
                held[held_count++] = share_hek(keybuf, keylen, hash);
                if (HvMAX(PL_strtab) + 1 > capacity_before)
                    break;
            }
        }
        capacity_after = HvMAX(PL_strtab) + 1;
        duplicate = share_hek(pv, share_len, HEK_HASH(target));
        refs_after_duplicate = HvSTR_REFCOUNT(target);
        same_pointer = target == duplicate;
        unshare_hek(duplicate);
        refs_after_release = HvSTR_REFCOUNT(target);

        tombstones_before = HvSTRTAB(PL_strtab)->tombstones;
        unshare_hek(target);
        for (i = held_count; i > 0; i--)
            unshare_hek(held[i - 1]);
        tombstones_after_delete = HvSTRTAB(PL_strtab)->tombstones;

        reinserted = share_hek(pv, share_len, target_hash);
        tombstones_after_reinsert = HvSTRTAB(PL_strtab)->tombstones;
        unshare_hek(reinserted);

        if (max_growth_keys) {
            cleanup_limit = capacity_after * 2;
            for (i = 0; i < cleanup_limit; i++) {
                const U32 old_capacity = HvMAX(PL_strtab) + 1;
                HEK **old_slots = HvSTRSLOTS(PL_strtab);
                const U32 old_tombstones = HvSTRTAB(PL_strtab)->tombstones;
                const U32 old_live = HvTOTALKEYS(PL_strtab);
                my_snprintf(keybuf, sizeof keybuf,
                            "xperl-shared-hek-cleanup-%" UVuf "-%" UVuf,
                            PTR2UV(input), (UV)i);
                keylen = strlen(keybuf);
                PERL_HASH(hash, keybuf, keylen);
                cleanup_hek = share_hek(keybuf, keylen, hash);
                if (old_tombstones
                    && HvMAX(PL_strtab) + 1 == old_capacity
                    && HvSTRSLOTS(PL_strtab) != old_slots) {
                    cleanup_observed = TRUE;
                    tombstones_at_cleanup = old_tombstones;
                    live_at_cleanup = old_live;
                    tombstones_after_cleanup =
                        HvSTRTAB(PL_strtab)->tombstones;
                }
                unshare_hek(cleanup_hek);
                if (cleanup_observed)
                    break;
            }
            if (!cleanup_observed)
                tombstones_after_cleanup = HvSTRTAB(PL_strtab)->tombstones;
        }
        else {
            tombstones_after_cleanup = HvSTRTAB(PL_strtab)->tombstones;
        }
        Safefree(held);

        result = newAV();
        av_push(result, newSVuv(capacity_before));
        av_push(result, newSVuv(capacity_after));
        av_push(result, newSVuv(capacity_after > capacity_before));
        av_push(result, newSVuv(same_pointer));
        av_push(result, newSVuv(refs_after_first));
        av_push(result, newSVuv(refs_after_duplicate));
        av_push(result, newSVuv(refs_after_release));
        av_push(result, newSVuv(target_utf8 ? 1 : 0));
        av_push(result, newSVuv(target_was_utf8 ? 1 : 0));
        av_push(result, newSVuv(target_len));
        av_push(result, newSVuv(target_hash));
        av_push(result, newSVuv(tombstones_before));
        av_push(result, newSVuv(tombstones_after_delete));
        av_push(result, newSVuv(tombstones_after_reinsert));
        av_push(result, newSVuv(held_count));
        av_push(result, newSVuv(tombstones_after_cleanup));
        av_push(result, newSVuv(cleanup_observed));
        av_push(result, newSVuv(tombstones_at_cleanup));
        av_push(result, newSVuv(live_at_cleanup));
        RETVAL = newRV_noinc((SV *)result);
    OUTPUT:
        RETVAL

SV *
test_unsharepvn_refcount(input)
        SV *input
    PREINIT:
        STRLEN len;
        const char *pv;
        I32 share_len;
        U32 hash;
        HEK *hek;
        Size_t refs_after_hold;
        Size_t refs_after_duplicate;
        Size_t refs_after_unshare;
        Size_t refs_to_release;
        U32 hek_utf8;
        U32 hek_wasutf8;
        I32 hek_len;
        AV *result;
    CODE:
        pv = SvPV(input, len);
        if (len > I32_MAX)
            croak("test_unsharepvn_refcount key is too long");
        share_len = SvUTF8(input) ? -(I32)len : (I32)len;
        PERL_HASH(hash, pv, len);
        hek = share_hek(pv, share_len, hash);
        refs_after_hold = HvSTR_REFCOUNT(hek);
        (void)share_hek(pv, share_len, hash);
        refs_after_duplicate = HvSTR_REFCOUNT(hek);

        unsharepvn(pv, share_len, hash);
        refs_after_unshare = HvSTR_REFCOUNT(hek);
        hek_utf8 = cBOOL(HEK_UTF8(hek));
        hek_wasutf8 = cBOOL(HEK_WASUTF8(hek));
        hek_len = HEK_LEN(hek);

        /* Release every remaining reference, including the extra one if
         * unsharepvn failed to match this key's canonical shared HEK. */
        refs_to_release = HvSTR_REFCOUNT(hek);
        while (refs_to_release) {
            refs_to_release--;
            unshare_hek(hek);
        }

        result = newAV();
        av_push(result, newSVuv(refs_after_hold));
        av_push(result, newSVuv(refs_after_duplicate));
        av_push(result, newSVuv(refs_after_unshare));
        av_push(result, newSVuv(hek_utf8));
        av_push(result, newSVuv(hek_wasutf8));
        av_push(result, newSViv(hek_len));
        RETVAL = newRV_noinc((SV *)result);
    OUTPUT:
        RETVAL

void
test_unsharepvn_nonexistent(input, utf8)
        SV *input
        IV utf8
        PREINIT:
        SV *key;
        STRLEN len;
        U32 hash;
        const char *pv;
        CODE:
        key = newSVpvf("xperl-unsharepvn-%p", (void *)input);
        if (utf8) {
            sv_catpvn(key, "\xC4\x80", 2);
            SvUTF8_on(key);
        }
        pv = SvPV(key, len);
        PERL_HASH(hash, pv, len);
        unsharepvn(pv, utf8 ? -(I32)len : (I32)len, hash);
        SvREFCNT_dec_NN(key);

bool
refcounted_he_exists(key, level=0)
        SV *key
        IV level
        CODE:
        if (level) {
            croak("level must be zero, not %" IVdf, level);
        }
        RETVAL = (cop_hints_fetch_sv(PL_curcop, key, 0, 0) != &PL_sv_placeholder);
        OUTPUT:
        RETVAL

SV *
refcounted_he_fetch(key, level=0)
        SV *key
        IV level
        CODE:
        if (level) {
            croak("level must be zero, not %" IVdf, level);
        }
        RETVAL = cop_hints_fetch_sv(PL_curcop, key, 0, 0);
        SvREFCNT_inc(RETVAL);
        OUTPUT:
        RETVAL

void
test_force_keys(HV *hv)
    PREINIT:
        HE *he;
        SSize_t count = 0;
    PPCODE:
        hv_iterinit(hv);
        he = hv_iternext(hv);
        while (he) {
            SV *sv = HeSVKEY_force(he);
            ++count;
            EXTEND(SP, count);
            PUSHs(sv_mortalcopy(sv));
            he = hv_iternext(hv);
        }

=pod

sub TIEHASH  { bless {}, $_[0] }
sub STORE    { $_[0]->{$_[1]} = $_[2] }
sub FETCH    { $_[0]->{$_[1]} }
sub FIRSTKEY { my $a = scalar keys %{$_[0]}; each %{$_[0]} }
sub NEXTKEY  { each %{$_[0]} }
sub EXISTS   { exists $_[0]->{$_[1]} }
sub DELETE   { delete $_[0]->{$_[1]} }
sub CLEAR    { %{$_[0]} = () }

=cut
