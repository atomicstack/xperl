/* Isolated table handles belong to the test object, never PL_strtab. */
static PERL_HV_STRTAB *
S_test_strtab(pTHX_ SV *self)
{
    PERL_HV_STRTAB *table = INT2PTR(PERL_HV_STRTAB *, SvIV(SvRV(self)));
    if (!table) croak("string table has been freed");
    return table;
}

static void
S_test_strtab_retained(pTHX_ const HEK *hek, void *arg)
{
    UV *refs = (UV *)arg;
    PERL_UNUSED_CONTEXT;
    *refs += HvSTR_REFCOUNT(hek);
}
