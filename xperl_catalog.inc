/* Module catalogs own frozen SV data, never renderer callbacks or C pointers. */

static void
Perl_xperl_catalog_error(pTHX_ const char *field, const char *problem)
{
    PERL_THROW_ERROR_DIAGNOSTIC_API_CATALOG_INVALID(field, problem);
}

static HV *
Perl_xperl_catalog_hash(pTHX_ SV *value, const char *field)
{
    if (SvMAGICAL(value) || !SvROK(value) || SvOBJECT(SvRV(value))
        || SvTYPE(SvRV(value)) != SVt_PVHV || SvMAGICAL(SvRV(value)))
        Perl_xperl_catalog_error(aTHX_ field, "expected_plain_hash");
    return MUTABLE_HV(SvRV(value));
}

static AV *
Perl_xperl_catalog_array(pTHX_ SV *value, const char *field)
{
    if (SvMAGICAL(value) || !SvROK(value) || SvOBJECT(SvRV(value))
        || SvTYPE(SvRV(value)) != SVt_PVAV || SvMAGICAL(SvRV(value)))
        Perl_xperl_catalog_error(aTHX_ field, "expected_plain_array");
    return MUTABLE_AV(SvRV(value));
}

static const char *
Perl_xperl_catalog_text(pTHX_ SV *value, const char *field, STRLEN *length)
{
    const char *text;
    if (SvMAGICAL(value) || SvROK(value) || !SvOK(value))
        Perl_xperl_catalog_error(aTHX_ field, "expected_plain_text");
    text = SvPV(value, *length);
    if (*length > 65536 || memchr(text, 0, *length))
        Perl_xperl_catalog_error(aTHX_ field, "invalid_text_extent");
    return text;
}

static const char *
Perl_xperl_catalog_name(pTHX_ SV *value, const char *field, bool qualified)
{
    STRLEN length, i = 0;
    const char *text = Perl_xperl_catalog_text(aTHX_ value, field, &length);
    if (!length || length > 255)
        Perl_xperl_catalog_error(aTHX_ field, "invalid_identifier");
    while (i < length) {
        if (!isALPHA_A(text[i]) && text[i] != '_')
            Perl_xperl_catalog_error(aTHX_ field, "invalid_identifier");
        while (++i < length && (isALNUM_A(text[i]) || text[i] == '_')) NOOP;
        if (i == length) break;
        if (!qualified || i + 2 >= length || text[i] != ':' || text[i+1] != ':')
            Perl_xperl_catalog_error(aTHX_ field, "invalid_identifier");
        i += 2;
    }
    return text;
}

static void
Perl_xperl_catalog_keys(pTHX_ HV *fields, const char *allowed)
{
    HE *entry;
    hv_iterinit(fields);
    while ((entry = hv_iternext(fields))) {
        SV *key = hv_iterkeysv(entry);
        STRLEN length;
        const char *bytes = SvPV(key, length), *start = allowed + 1;
        bool matched = FALSE;
        while (*start) {
            const char *end = strchr(start, '|');
            if (!end) break;
            if ((STRLEN)(end - start) == length && memEQ(start, bytes, length)) {
                matched = TRUE;
                break;
            }
            start = end + 1;
        }
        if (!matched)
            Perl_xperl_catalog_error(aTHX_ SvPV_nolen(key), "unknown_field");
    }
}

static void
Perl_xperl_catalog_freeze(pTHX_ SV *value)
{
    if (SvROK(value)) {
        SV *target = SvRV(value);
        if (SvTYPE(target) == SVt_PVHV) {
            HE *entry;
            hv_iterinit(MUTABLE_HV(target));
            while ((entry = hv_iternext(MUTABLE_HV(target))))
                Perl_xperl_catalog_freeze(aTHX_ hv_iterval(MUTABLE_HV(target), entry));
        }
        else if (SvTYPE(target) == SVt_PVAV) {
            SSize_t i;
            for (i = 0; i <= av_top_index(MUTABLE_AV(target)); ++i) {
                SV **item = av_fetch(MUTABLE_AV(target), i, FALSE);
                if (item) Perl_xperl_catalog_freeze(aTHX_ *item);
            }
        }
        SvREADONLY_on(target);
    }
    SvREADONLY_on(value);
}

static bool
Perl_xperl_catalog_equal(pTHX_ SV *a, SV *b)
{
    if (SvROK(a) != SvROK(b)) return FALSE;
    if (!SvROK(a)) return !!SvIOK(a) == !!SvIOK(b) && sv_eq(a, b);
    if (SvTYPE(SvRV(a)) != SvTYPE(SvRV(b))) return FALSE;
    if (SvTYPE(SvRV(a)) == SVt_PVHV) {
        HV *ah = MUTABLE_HV(SvRV(a)), *bh = MUTABLE_HV(SvRV(b));
        HE *entry;
        if (HvUSEDKEYS(ah) != HvUSEDKEYS(bh)) return FALSE;
        hv_iterinit(ah);
        while ((entry = hv_iternext(ah))) {
            HE *other;
            if (!hv_exists_ent(bh, hv_iterkeysv(entry), 0)) return FALSE;
            other = hv_fetch_ent(bh, hv_iterkeysv(entry), FALSE, 0);
            if (!other || !Perl_xperl_catalog_equal(aTHX_ hv_iterval(ah, entry), HeVAL(other)))
                return FALSE;
        }
        return TRUE;
    }
    if (SvTYPE(SvRV(a)) == SVt_PVAV) {
        AV *aa = MUTABLE_AV(SvRV(a)), *ba = MUTABLE_AV(SvRV(b));
        SSize_t i;
        if (av_top_index(aa) != av_top_index(ba)) return FALSE;
        for (i = 0; i <= av_top_index(aa); ++i) {
            SV **av = av_fetch(aa, i, FALSE), **bv = av_fetch(ba, i, FALSE);
            if (!av || !bv || !Perl_xperl_catalog_equal(aTHX_ *av, *bv)) return FALSE;
        }
        return TRUE;
    }
    return FALSE;
}

static AV *
Perl_xperl_catalog_compile(pTHX_ SV *text, AV *params)
{
    STRLEN length, offset = 0, start = 0;
    const char *bytes = Perl_xperl_catalog_text(aTHX_ text, "template", &length);
    AV *tokens = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));
    while (offset < length) {
        if (bytes[offset] == '%' && offset + 1 < length && bytes[offset+1] == '{') {
            STRLEN end = offset + 2;
            SSize_t i;
            while (end < length && bytes[end] != '}') ++end;
            if (end == length)
                Perl_xperl_catalog_error(aTHX_ "template", "unterminated_placeholder");
            if (offset > start) {
                SV *literal = newSVpvn(bytes + start, offset - start);
                if (SvUTF8(text)) SvUTF8_on(literal);
                av_push(tokens, literal);
            }
            for (i = 0; i <= av_top_index(params); ++i) {
                HV *param = MUTABLE_HV(SvRV(*av_fetch(params, i, FALSE)));
                SV *name = Perl_xperl_field(aTHX_ param, "name");
                STRLEN size;
                const char *name_bytes = SvPV(name, size);
                if (size == end - offset - 2 && memEQ(name_bytes, bytes + offset + 2, size)) break;
            }
            if (i > av_top_index(params))
                Perl_xperl_catalog_error(aTHX_ "template", "unknown_parameter");
            av_push(tokens, newSVuv((UV)i));
            offset = start = end + 1;
        }
        else ++offset;
    }
    if (start < length) {
        SV *literal = newSVpvn(bytes + start, length - start);
        if (SvUTF8(text)) SvUTF8_on(literal);
        av_push(tokens, literal);
    }
    return tokens;
}

XS(Perl_XPerl_Catalog_register);
XS(Perl_XPerl_Catalog_register)
{
    dXSARGS;
    HV *source, *conditions, *catalog, *definitions, *registry, *classes;
    SV *namespace_sv, *object, **registry_slot, **existing;
    const char *namespace_name;
    HE *entry;
    if (items != 2) croak_xs_usage(cv, "class, definition");
    source = Perl_xperl_catalog_hash(aTHX_ ST(1), "definition");
    Perl_xperl_catalog_keys(aTHX_ source, "|namespace|conditions|");
    namespace_sv = Perl_xperl_field(aTHX_ source, "namespace");
    namespace_name = Perl_xperl_catalog_name(aTHX_ namespace_sv, "namespace", TRUE);
    if (strEQ(namespace_name, "XPerl") || strBEGINs(namespace_name, "XPerl::"))
        Perl_xperl_catalog_error(aTHX_ "namespace", "reserved");
    conditions = Perl_xperl_catalog_hash(aTHX_ Perl_xperl_field(aTHX_ source, "conditions"), "conditions");
    if (!HvUSEDKEYS(conditions) || HvUSEDKEYS(conditions) > 256)
        Perl_xperl_catalog_error(aTHX_ "conditions", "invalid_count");
    object = sv_2mortal(newRV_noinc(MUTABLE_SV(newHV())));
    catalog = MUTABLE_HV(SvRV(object));
    classes = MUTABLE_HV(sv_2mortal(MUTABLE_SV(newHV())));
    (void)hv_stores(catalog, "namespace", newSVsv(namespace_sv));
    definitions = newHV();
    (void)hv_stores(catalog, "conditions", newRV_noinc(MUTABLE_SV(definitions)));
    hv_iterinit(conditions);
    while ((entry = hv_iternext(conditions))) {
        SV *name = hv_iterkeysv(entry), *descriptor_ref;
        HV *definition, *descriptor, *templates, *compiled, *seen;
        AV *params, *copied_params;
        SV *class_name, *parent, *severity;
        const char *parent_name, *severity_name;
        STRLEN length;
        SSize_t i;
        HE *translation;
        (void)Perl_xperl_catalog_name(aTHX_ name, "condition", FALSE);
        definition = Perl_xperl_catalog_hash(aTHX_ hv_iterval(conditions, entry), "condition");
        Perl_xperl_catalog_keys(aTHX_ definition, "|class|parent|severity|params|templates|");
        class_name = Perl_xperl_field(aTHX_ definition, "class");
        (void)Perl_xperl_catalog_name(aTHX_ class_name, "class", TRUE);
        if (strnNE(SvPV_nolen(class_name), namespace_name, strlen(namespace_name))
            || !strBEGINs(SvPV_nolen(class_name) + strlen(namespace_name), "::Diagnostic::"))
            Perl_xperl_catalog_error(aTHX_ "class", "outside_namespace");
        parent = Perl_xperl_field(aTHX_ definition, "parent");
        parent_name = Perl_xperl_catalog_name(aTHX_ parent, "parent", TRUE);
        severity = Perl_xperl_field(aTHX_ definition, "severity");
        severity_name = Perl_xperl_catalog_text(aTHX_ severity, "severity", &length);
        if (!((strEQ(severity_name, "FATAL_ERROR") && sv_derived_from(parent, "XPerl::Diagnostic::Error"))
            || (strEQ(severity_name, "WARNING") && sv_derived_from(parent, "XPerl::Diagnostic::Warning"))
            || (strEQ(severity_name, "NOTE") && sv_derived_from(parent, "XPerl::Diagnostic::Note"))))
            Perl_xperl_catalog_error(aTHX_ "parent", "severity_mismatch");
        {
            HE *prior = hv_fetch_ent(classes, class_name, FALSE, 0);
            if (prior && !sv_eq(HeVAL(prior), parent))
                Perl_xperl_catalog_error(aTHX_ "class", "conflicting_ancestry");
            (void)hv_store_ent(classes, class_name, newSVsv(parent), 0);
        }
        PERL_UNUSED_VAR(parent_name);
        params = Perl_xperl_catalog_array(aTHX_ Perl_xperl_field(aTHX_ definition, "params"), "params");
        if (av_top_index(params) >= 32)
            Perl_xperl_catalog_error(aTHX_ "params", "invalid_count");
        descriptor_ref = newRV_noinc(MUTABLE_SV(newHV()));
        (void)hv_store_ent(definitions, name, descriptor_ref, 0);
        descriptor = MUTABLE_HV(SvRV(descriptor_ref));
        (void)hv_stores(descriptor, "code", newSVpvf("%s::%s", namespace_name, SvPV_nolen(name)));
        (void)hv_stores(descriptor, "class", newSVsv(class_name));
        (void)hv_stores(descriptor, "parent", newSVsv(parent));
        (void)hv_stores(descriptor, "severity", newSVsv(severity));
        copied_params = newAV();
        (void)hv_stores(descriptor, "params", newRV_noinc(MUTABLE_SV(copied_params)));
        seen = MUTABLE_HV(sv_2mortal(MUTABLE_SV(newHV())));
        for (i = 0; i <= av_top_index(params); ++i) {
            SV **slot = av_fetch(params, i, FALSE);
            HV *param, *copy;
            SV *param_name, *type;
            const char *type_name;
            if (!slot) Perl_xperl_catalog_error(aTHX_ "params", "sparse_array");
            param = Perl_xperl_catalog_hash(aTHX_ *slot, "parameter");
            Perl_xperl_catalog_keys(aTHX_ param, "|name|type|");
            param_name = Perl_xperl_field(aTHX_ param, "name");
            (void)Perl_xperl_catalog_name(aTHX_ param_name, "parameter.name", FALSE);
            if (hv_exists_ent(seen, param_name, 0))
                Perl_xperl_catalog_error(aTHX_ "parameter.name", "duplicate");
            (void)hv_store_ent(seen, param_name, newSViv(1), 0);
            type = Perl_xperl_field(aTHX_ param, "type");
            type_name = Perl_xperl_catalog_text(aTHX_ type, "parameter.type", &length);
            if (strNE(type_name, "text") && strNE(type_name, "iv") && strNE(type_name, "uv")
                && strNE(type_name, "nv") && strNE(type_name, "bool"))
                Perl_xperl_catalog_error(aTHX_ "parameter.type", "unsupported_type");
            copy = newHV();
            (void)hv_stores(copy, "name", newSVsv(param_name));
            (void)hv_stores(copy, "type", newSVsv(type));
            av_push(copied_params, newRV_noinc(MUTABLE_SV(copy)));
        }
        templates = Perl_xperl_catalog_hash(aTHX_ Perl_xperl_field(aTHX_ definition, "templates"), "templates");
        if (!hv_exists(templates, "en", 2) || HvUSEDKEYS(templates) > 32)
            Perl_xperl_catalog_error(aTHX_ "templates", "english_required_or_too_many");
        compiled = newHV();
        (void)hv_stores(descriptor, "templates", newRV_noinc(MUTABLE_SV(compiled)));
        hv_iterinit(templates);
        while ((translation = hv_iternext(templates))) {
            SV *language = hv_iterkeysv(translation);
            (void)Perl_xperl_catalog_name(aTHX_ language, "language", FALSE);
            (void)hv_store_ent(compiled, language,
                newRV_inc(MUTABLE_SV(Perl_xperl_catalog_compile(aTHX_
                    hv_iterval(templates, translation), copied_params))), 0);
        }
    }
    registry_slot = hv_fetchs(PL_modglobal, "XPerl::Diagnostic::Catalog/registry", TRUE);
    if (!SvOK(*registry_slot)) sv_setrv_noinc(*registry_slot, MUTABLE_SV(newHV()));
    registry = MUTABLE_HV(SvRV(*registry_slot));
    existing = hv_fetch(registry, namespace_name, strlen(namespace_name), FALSE);
    if (existing) {
        if (!Perl_xperl_catalog_equal(aTHX_ object, *existing))
            Perl_xperl_catalog_error(aTHX_ "namespace", "conflicting_definition");
        ST(0) = sv_2mortal(newSVsv(*existing));
        XSRETURN(1);
    }
    /* Validate all declarations before changing any class ancestry. */
    hv_iterinit(definitions);
    while ((entry = hv_iternext(definitions))) {
        HV *descriptor = MUTABLE_HV(SvRV(hv_iterval(definitions, entry)));
        SV *class_name = Perl_xperl_field(aTHX_ descriptor, "class");
        SV *parent = Perl_xperl_field(aTHX_ descriptor, "parent");
        AV *isa = get_av(SvPV_nolen(sv_2mortal(newSVpvf("%s::ISA", SvPV_nolen(class_name)))), 0);
        if (sv_derived_from(parent, SvPV_nolen(class_name)))
            Perl_xperl_catalog_error(aTHX_ "class", "inheritance_cycle");
        if (isa && SvMAGICAL(MUTABLE_SV(isa))) {
            MAGIC *magic;
            for (magic = SvMAGIC(MUTABLE_SV(isa)); magic; magic = magic->mg_moremagic)
                if (magic->mg_type != PERL_MAGIC_isa)
                    Perl_xperl_catalog_error(aTHX_ "class", "magical_ancestry");
        }
        if (isa && ((av_top_index(isa) < 0 && SvREADONLY(MUTABLE_SV(isa)))
            || (av_top_index(isa) >= 0 && !sv_derived_from(class_name, SvPV_nolen(parent)))))
            Perl_xperl_catalog_error(aTHX_ "class", "conflicting_ancestry");
        if (!isa || av_top_index(isa) < 0) {
            HE *descendants = hv_fetch_ent(PL_isarev, class_name, FALSE, 0);
            if (descendants && SvTYPE(HeVAL(descendants)) == SVt_PVHV
                && HvUSEDKEYS(MUTABLE_HV(HeVAL(descendants))))
                Perl_xperl_catalog_error(aTHX_ "class", "existing_descendants");
        }
    }
    hv_iterinit(definitions);
    while ((entry = hv_iternext(definitions))) {
        HV *descriptor = MUTABLE_HV(SvRV(hv_iterval(definitions, entry)));
        SV *class_name = Perl_xperl_field(aTHX_ descriptor, "class");
        SV *parent = Perl_xperl_field(aTHX_ descriptor, "parent");
        AV *isa = get_av(SvPV_nolen(sv_2mortal(newSVpvf("%s::ISA", SvPV_nolen(class_name)))), GV_ADD);
        if (av_top_index(isa) < 0) av_push(isa, newSVsv(parent));
    }
    sv_bless(object, gv_stashpvs("XPerl::Diagnostic::Catalog", GV_ADD));
    Perl_xperl_catalog_freeze(aTHX_ object);
    (void)hv_store(registry, namespace_name, strlen(namespace_name), newSVsv(object), 0);
    ST(0) = object;
    XSRETURN(1);
}

XS(Perl_XPerl_Catalog_capture);
XS(Perl_XPerl_Catalog_capture)
{
    dXSARGS;
    HV *catalog, *definitions, *descriptor, *values, *fields, *location;
    AV *schema, *params;
    SV *descriptor_ref, *object, *namespace_sv;
    SV **registry_slot, **registered;
    SSize_t i;
    STRLEN length;
    U8 caller_depth = 0;
    if (items < 5 || items > 6)
        croak_xs_usage(cv, "catalog, condition, values, file, line, caller_depth = 0");
    if (items == 6) {
        if (SvMAGICAL(ST(5)) || SvROK(ST(5)) || !SvIOK(ST(5)) || SvUV(ST(5)) > 32)
            Perl_xperl_catalog_error(aTHX_ "caller_depth", "invalid_integer");
        caller_depth = (U8)SvUV(ST(5));
    }
    catalog = Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::Diagnostic::Catalog");
    if (SvMAGICAL(MUTABLE_SV(catalog)))
        Perl_xperl_catalog_error(aTHX_ "catalog", "invalid_handle");
    namespace_sv = Perl_xperl_field(aTHX_ catalog, "namespace");
    (void)Perl_xperl_catalog_name(aTHX_ namespace_sv, "namespace", TRUE);
    registry_slot = hv_fetchs(PL_modglobal, "XPerl::Diagnostic::Catalog/registry", FALSE);
    registered = registry_slot && SvROK(*registry_slot)
        ? hv_fetch_ent(MUTABLE_HV(SvRV(*registry_slot)), namespace_sv, FALSE, 0)
            ? &HeVAL(hv_fetch_ent(MUTABLE_HV(SvRV(*registry_slot)), namespace_sv, FALSE, 0)) : NULL
        : NULL;
    if (!registered || !SvROK(*registered) || SvRV(*registered) != MUTABLE_SV(catalog))
        Perl_xperl_catalog_error(aTHX_ "catalog", "invalid_handle");
    (void)Perl_xperl_catalog_name(aTHX_ ST(1), "condition", FALSE);
    definitions = MUTABLE_HV(SvRV(Perl_xperl_field(aTHX_ catalog, "conditions")));
    {
        if (!hv_exists_ent(definitions, ST(1), 0))
            Perl_xperl_catalog_error(aTHX_ "condition", "unknown_condition");
        HE *entry = hv_fetch_ent(definitions, ST(1), FALSE, 0);
        if (!entry) Perl_xperl_catalog_error(aTHX_ "condition", "unknown_condition");
        descriptor_ref = hv_iterval(definitions, entry);
    }
    descriptor = MUTABLE_HV(SvRV(descriptor_ref));
    values = Perl_xperl_catalog_hash(aTHX_ ST(2), "values");
    schema = MUTABLE_AV(SvRV(Perl_xperl_field(aTHX_ descriptor, "params")));
    if (HvUSEDKEYS(values) != (UV)(av_top_index(schema) + 1))
        Perl_xperl_catalog_error(aTHX_ "values", "parameter_count");
    (void)Perl_xperl_catalog_text(aTHX_ ST(3), "file", &length);
    if (SvMAGICAL(ST(4)) || SvROK(ST(4)) || !SvIOK(ST(4)) || SvIV(ST(4)) < 0)
        Perl_xperl_catalog_error(aTHX_ "line", "expected_nonnegative_integer");
    object = sv_2mortal(newRV_noinc(MUTABLE_SV(newHV())));
    fields = MUTABLE_HV(SvRV(object));
    params = newAV();
    (void)hv_stores(fields, "params", newRV_noinc(MUTABLE_SV(params)));
    for (i = 0; i <= av_top_index(schema); ++i) {
        HV *definition = MUTABLE_HV(SvRV(*av_fetch(schema, i, FALSE)));
        SV *name = Perl_xperl_field(aTHX_ definition, "name");
        SV *type = Perl_xperl_field(aTHX_ definition, "type");
        const char *type_name = SvPV_nolen(type);
        HE *entry = hv_fetch_ent(values, name, FALSE, 0);
        SV *value;
        SV *captured;
        HV *param;
        if (!entry) Perl_xperl_catalog_error(aTHX_ SvPV_nolen(name), "missing_parameter");
        value = hv_iterval(values, entry);
        if (SvMAGICAL(value) || SvROK(value) || !SvOK(value))
            Perl_xperl_catalog_error(aTHX_ SvPV_nolen(name), "expected_plain_value");
        if (strEQ(type_name, "text"))
            (void)Perl_xperl_catalog_text(aTHX_ value, SvPV_nolen(name), &length);
        else if (strEQ(type_name, "nv")) {
            if ((!SvNOK(value) && !SvIOK(value)) || !Perl_isfinite(SvNV(value)))
                Perl_xperl_catalog_error(aTHX_ SvPV_nolen(name), "expected_finite_number");
        }
        else if (!SvIOK(value)
            || (strEQ(type_name, "uv") && !SvIsUV(value) && SvIV(value) < 0)
            || (strEQ(type_name, "iv") && SvIsUV(value) && SvUV(value) > IV_MAX)
            || (strEQ(type_name, "bool") && SvUV(value) > 1))
            Perl_xperl_catalog_error(aTHX_ SvPV_nolen(name), "invalid_integer");
        if (strEQ(type_name, "nv")) captured = newSVnv(SvNV(value));
        else if (strEQ(type_name, "uv")) captured = newSVuv(SvUV(value));
        else if (strEQ(type_name, "iv") || strEQ(type_name, "bool")) captured = newSViv(SvIV(value));
        else {
            const char *bytes = SvPV(value, length);
            captured = newSVpvn(bytes, length);
            if (SvUTF8(value)) SvUTF8_on(captured);
        }
        param = newHV();
        (void)hv_stores(param, "name", newSVsv(name));
        (void)hv_stores(param, "type", newSVsv(type));
        (void)hv_stores(param, "value", captured);
        av_push(params, newRV_noinc(MUTABLE_SV(param)));
    }
    (void)hv_stores(fields, "code", newSVsv(Perl_xperl_field(aTHX_ descriptor, "code")));
    (void)hv_stores(fields, "number", newSV(0));
    (void)hv_stores(fields, "kind", newSVpvs("USER_RUNTIME"));
    (void)hv_stores(fields, "severity", newSVsv(Perl_xperl_field(aTHX_ descriptor, "severity")));
    (void)hv_stores(fields, "_module_descriptor", newSVsv(descriptor_ref));
    location = newHV();
    (void)hv_stores(location, "file", newSVsv(ST(3)));
    (void)hv_stores(location, "line", newSVsv(ST(4)));
    (void)hv_stores(fields, "location", newRV_noinc(MUTABLE_SV(location)));
    {
        const PERL_CONTEXT *caller = caller_cx(caller_depth, NULL);
        const COP *site = caller ? caller->blk_oldcop : PL_curcop;
        SV *hint = site ? cop_hints_fetch_pvs(site, PERL_DIAGPACK_HINT_KEY, 0) : NULL;
        const perl_diagpack_engine *engine = hint && SvIOK(hint) && SvUV(hint)
            ? INT2PTR(const perl_diagpack_engine *, SvUV(hint)) : NULL;
        if (engine) (void)hv_stores(fields, "_diagpack_engine", newSVuv(PTR2UV(engine)));
    }
    sv_bless(object, gv_stashsv(Perl_xperl_field(aTHX_ descriptor, "class"), GV_ADD));
    ST(0) = object;
    XSRETURN(1);
}

static SV *
Perl_xperl_catalog_render_field(pTHX_ HV *fields, const char *key)
{
    if (SvMAGICAL(MUTABLE_SV(fields)) || !hv_exists(fields, key, strlen(key)))
        return &PL_sv_undef;
    return Perl_xperl_field(aTHX_ fields, key);
}

static SV *
Perl_xperl_catalog_render(pTHX_ HV *fields, const char *language)
{
    SV *descriptor_ref = Perl_xperl_catalog_render_field(aTHX_ fields, "_module_descriptor");
    SV *templates_ref, *params_ref, *tokens_ref;
    HV *descriptor, *templates;
    AV *tokens, *params;
    SV *output;
    SSize_t i;
    if (SvMAGICAL(descriptor_ref) || !SvROK(descriptor_ref)
        || SvTYPE(SvRV(descriptor_ref)) != SVt_PVHV || SvMAGICAL(SvRV(descriptor_ref)))
        return NULL;
    descriptor = MUTABLE_HV(SvRV(descriptor_ref));
    templates_ref = Perl_xperl_catalog_render_field(aTHX_ descriptor, "templates");
    params_ref = Perl_xperl_catalog_render_field(aTHX_ fields, "params");
    if (!SvROK(templates_ref) || SvTYPE(SvRV(templates_ref)) != SVt_PVHV
        || SvMAGICAL(templates_ref) || SvMAGICAL(SvRV(templates_ref))
        || !SvROK(params_ref) || SvTYPE(SvRV(params_ref)) != SVt_PVAV
        || SvMAGICAL(params_ref) || SvMAGICAL(SvRV(params_ref)))
        return newSVpvs("Invalid module diagnostic data");
    templates = MUTABLE_HV(SvRV(templates_ref));
    tokens_ref = language && hv_exists(templates, language, strlen(language))
        ? Perl_xperl_catalog_render_field(aTHX_ templates, language)
        : Perl_xperl_catalog_render_field(aTHX_ templates, "en");
    if (SvMAGICAL(tokens_ref) || !SvROK(tokens_ref)
        || SvTYPE(SvRV(tokens_ref)) != SVt_PVAV || SvMAGICAL(SvRV(tokens_ref)))
        return newSVpvs("Invalid module diagnostic data");
    tokens = MUTABLE_AV(SvRV(tokens_ref));
    params = MUTABLE_AV(SvRV(params_ref));
    output = newSVpvs("");
    if (av_top_index(tokens) > 65536 || av_top_index(params) >= 32) goto invalid;
    for (i = 0; i <= av_top_index(tokens); ++i) {
        SV **slot = av_fetch(tokens, i, FALSE);
        SV *token;
        if (!slot || SvMAGICAL(*slot) || SvROK(*slot)) goto invalid;
        token = *slot;
        if (SvIOK(token)) {
            SV **param = SvUV(token) <= 31 ? av_fetch(params, (SSize_t)SvUV(token), FALSE) : NULL;
            SV *value;
            if (!param || SvMAGICAL(*param) || !SvROK(*param)
                || SvTYPE(SvRV(*param)) != SVt_PVHV || SvMAGICAL(SvRV(*param))) goto invalid;
            value = Perl_xperl_catalog_render_field(aTHX_ MUTABLE_HV(SvRV(*param)), "value");
            if (SvMAGICAL(value) || SvROK(value) || !SvOK(value)) goto invalid;
            if (SvPOK(value) && SvCUR(value) > 65536) goto invalid;
            if (SvPOK(value) && SvCUR(value) > 1048576 - SvCUR(output)) goto invalid;
            sv_catsv(output, value);
        }
        else if (SvPOK(token)) {
            if (SvCUR(token) > 65536 || SvCUR(token) > 1048576 - SvCUR(output)) goto invalid;
            sv_catsv(output, token);
        }
        else goto invalid;
        if (SvCUR(output) > 1048576) goto invalid;
    }
    return output;
invalid:
    sv_setpvs(output, "Invalid module diagnostic data");
    return output;
}
