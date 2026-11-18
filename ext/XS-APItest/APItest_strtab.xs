MODULE = XS::APItest:Strtab PACKAGE = XS::APItest::Strtab

bool
CLONE_SKIP(classname)
        const char *classname
    CODE:
        PERL_UNUSED_ARG(classname);
        RETVAL = TRUE;
    OUTPUT:
        RETVAL

SV *
new(classname)
        const char *classname
    CODE:
        RETVAL = newRV_noinc(newSViv(PTR2IV(Perl_hv_strtab_new(aTHX))));
        sv_bless(RETVAL, gv_stashpv(classname, GV_ADD));
    OUTPUT:
        RETVAL

UV
share(self, key, flags = 0, hash = 0)
        SV *self
        SV *key
        U8 flags
        U32 hash
    PREINIT:
        STRLEN len;
        const char *pv;
    CODE:
        pv = SvPV(key, len);
        RETVAL = PTR2UV(Perl_hv_strtab_share(aTHX_ S_test_strtab(aTHX_ self),
                                           hash, pv, len, flags));
    OUTPUT:
        RETVAL

UV
find(self, key, flags = 0, hash = 0)
        SV *self
        SV *key
        U8 flags
        U32 hash
    PREINIT:
        STRLEN len;
        const char *pv;
    CODE:
        pv = SvPV(key, len);
        RETVAL = PTR2UV(Perl_hv_strtab_find(aTHX_ S_test_strtab(aTHX_ self),
                                          hash, pv, len, flags));
    OUTPUT:
        RETVAL

UV
refcount(self, key, flags = 0, hash = 0)
        SV *self
        SV *key
        U8 flags
        U32 hash
    PREINIT:
        STRLEN len;
        const char *pv;
        HEK *hek;
    CODE:
        pv = SvPV(key, len);
        hek = Perl_hv_strtab_find(aTHX_ S_test_strtab(aTHX_ self), hash, pv, len, flags);
        RETVAL = hek ? HvSTR_REFCOUNT(hek) : 0;
    OUTPUT:
        RETVAL

bool
release(self, key, flags = 0, hash = 0)
        SV *self
        SV *key
        U8 flags
        U32 hash
    PREINIT:
        STRLEN len;
        const char *pv;
    CODE:
        pv = SvPV(key, len);
        RETVAL = Perl_hv_strtab_release_key(aTHX_ S_test_strtab(aTHX_ self),
                                            hash, pv, len, flags);
    OUTPUT:
        RETVAL

void
reserve(self, live)
        SV *self
        UV live
    CODE:
        if ((UV)(Size_t)live != live) Perl_croak_memory_wrap();
        Perl_hv_strtab_reserve(aTHX_ S_test_strtab(aTHX_ self), live);

void
pin(self, key, count = 1)
        SV *self
        SV *key
        UV count
    PREINIT:
        PERL_HV_STRTAB *table;
        STRLEN len;
        const char *pv;
        HEK *hek;
    CODE:
        table = S_test_strtab(aTHX_ self);
        pv = SvPV(key, len);
        hek = Perl_hv_strtab_find(aTHX_ table, 0, pv, len, 0);
        if (!hek || !count || count > HvSTR_REFCOUNT(hek))
            croak("invalid pin ownership");
        Perl_hv_strtab_pin(aTHX_ table, hek, count);

AV *
info(self)
        SV *self
    PREINIT:
        PERL_HV_STRTAB *table;
    CODE:
        table = S_test_strtab(aTHX_ self);
        RETVAL = newAV();
        av_push(RETVAL, newSVuv(table->capacity));
        av_push(RETVAL, newSVuv(table->live));
        av_push(RETVAL, newSVuv(table->tombstones));
        av_push(RETVAL, newSVuv(PTR2UV(table->slots)));
    OUTPUT:
        RETVAL

UV
set_live(self, live)
        SV *self
        UV live
    PREINIT:
        PERL_HV_STRTAB *table;
    CODE:
        if ((UV)(Size_t)live != live) Perl_croak_memory_wrap();
        table = S_test_strtab(aTHX_ self);
        RETVAL = table->live;
        table->live = live;
    OUTPUT:
        RETVAL

void
set_refcount(self, key, count)
        SV *self
        SV *key
        U32 count
    PREINIT:
        STRLEN len;
        const char *pv;
        HEK *hek;
    CODE:
        pv = SvPV(key, len);
        hek = Perl_hv_strtab_find(aTHX_ S_test_strtab(aTHX_ self), 0, pv, len, 0);
        if (!hek || !count) croak("invalid reference-count probe");
        HvSTR_REFCOUNT(hek) = count;

AV *
free(self)
        SV *self
    PREINIT:
        UV refs = 0;
        Size_t retained;
    CODE:
        retained = Perl_hv_strtab_free(aTHX_ S_test_strtab(aTHX_ self),
                                       S_test_strtab_retained, &refs);
        sv_setiv(SvRV(self), 0);
        RETVAL = newAV();
        av_push(RETVAL, newSVuv(retained));
        av_push(RETVAL, newSVuv(refs));
    OUTPUT:
        RETVAL

void
DESTROY(self)
        SV *self
    CODE:
        if (SvIV(SvRV(self))) {
            (void)Perl_hv_strtab_free(aTHX_ S_test_strtab(aTHX_ self), NULL, NULL);
            sv_setiv(SvRV(self), 0);
        }

UV
capacity_for(live)
        UV live
    CODE:
        RETVAL = (UV)(Size_t)live == live
            ? (UV)Perl_hv_strtab_capacity_for((Size_t)live) : 0;
    OUTPUT:
        RETVAL
