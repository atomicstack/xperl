/* XPerl diagnostic objects are available before Perl can load modules. */

static HV *
Perl_xperl_object_hv(pTHX_ SV *object, const char *class_name)
{
    if (!SvROK(object) || SvTYPE(SvRV(object)) != SVt_PVHV
        || !sv_derived_from(object, class_name))
        PERL_THROW_ERROR_DIAGNOSTIC_API_RECEIVER_TYPE_MISMATCH(class_name);
    return MUTABLE_HV(SvRV(object));
}

static SV *
Perl_xperl_field(pTHX_ HV *hv, const char *key)
{
    SV **svp = hv_fetch(hv, key, strlen(key), 0);
    return svp ? *svp : &PL_sv_undef;
}

static const perl_diagpack_engine *
Perl_xperl_render_engine(pTHX_ HV *fields, HV *context)
{
    SV *explicit_language = context
        ? Perl_xperl_field(aTHX_ context, "_explicit_language") : &PL_sv_no;
    SV *value;
    if (SvTRUE(explicit_language))
        return NULL;
    value = Perl_xperl_field(aTHX_ fields, "_diagpack_engine");
    return SvIOK(value) && SvUV(value)
        ? INT2PTR(const perl_diagpack_engine *, SvUV(value)) : NULL;
}

static void
Perl_xperl_render_context_set_explicit(HV *context, bool explicit_language)
{
    SV **slot = hv_fetchs(context, "_explicit_language", TRUE);
    if (!slot)
        croak_no_mem();
    sv_setiv(*slot, explicit_language ? 1 : 0);
}

/* Preserve the historical selector_key observation without storing a key
 * whose layout depends on the English template table during construction. */
static SV *
Perl_xperl_selector_key(pTHX_ HV *fields)
{
    SV **saved = hv_fetchs(fields, "selector_key", FALSE);
    SV *number;
    SV *params;
    SV *result;

    if (saved)
        return newSVsv(*saved);
    number = Perl_xperl_field(aTHX_ fields, "number");
    params = Perl_xperl_field(aTHX_ fields, "params");
    if (!SvOK(number))
        return newSV(0);
    result = Perl_diag_compat_selector_key(aTHX_ SvUV(number),
        SvROK(params) && SvTYPE(SvRV(params)) == SVt_PVAV
            ? MUTABLE_AV(SvRV(params)) : NULL);
    return result;
}

static const char xperl_render_active_key[] = "\0XPerl::render_active";

static bool
Perl_xperl_render_guard_enter(pTHX_ HV *context, HV *fields)
{
    SV **slot;
    SV *active_ref;
    HV *active;
    char *node_key;

    slot = hv_fetch(context, xperl_render_active_key,
                    sizeof(xperl_render_active_key) - 1, FALSE);
    if (!slot) {
        SAVEDELETE(context,
                   savepvn(xperl_render_active_key,
                           sizeof(xperl_render_active_key) - 1),
                   sizeof(xperl_render_active_key) - 1);
        active_ref = newRV_noinc(MUTABLE_SV(newHV()));
        slot = hv_store(context, xperl_render_active_key,
                        sizeof(xperl_render_active_key) - 1, active_ref, 0);
        if (!slot) {
            SvREFCNT_dec_NN(active_ref);
            croak_no_mem();
        }
    }
    if (!SvROK(*slot) || SvTYPE(SvRV(*slot)) != SVt_PVHV)
        PERL_THROW_ERROR_DIAGNOSTIC_API_RENDER_CONTEXT_NOT_HASH();
    active = MUTABLE_HV(SvRV(*slot));
    node_key = savepvn((const char *)&fields, sizeof(fields));

    if (hv_fetch(active, node_key, sizeof(fields), FALSE)) {
        Safefree(node_key);
        return FALSE;
    }

    SAVEDELETE(active, node_key, sizeof(fields));
    if (!hv_store(active, node_key, sizeof(fields), newSViv(1), 0))
        croak_no_mem();
    return TRUE;
}

/* Format a rendering view without adding or replacing diagnostic records. */
static SV *
Perl_xperl_render_format(pTHX_ UV diag_index, const char *language,
                       U32 value_count, ...)
{
    AV *values = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));
    va_list args;
    U32 i;

    va_start(args, value_count);
    for (i = 0; i < value_count; i++) {
        SV *value = va_arg(args, SV *);
        av_push(values, newSVsv(value));
    }
    va_end(args);

    SV *rendered = Perl_diag_render_format(aTHX_ diag_index, values,
                                      language ? language : "en");
    assert(rendered);
    return rendered ? newSVsv(rendered) : newSVpvs("");
}

static SV *
Perl_xperl_render_format_engine(pTHX_ const perl_diagpack_engine *engine,
                                UV diag_index, U32 value_count, ...)
{
    AV *values = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));
    va_list args;
    U32 i;

    va_start(args, value_count);
    for (i = 0; i < value_count; i++) {
        SV *value = va_arg(args, SV *);
        av_push(values, newSVsv(value));
    }
    va_end(args);
    SV *rendered = Perl_diagpack_render_format_engine(aTHX_ engine,
                                                       diag_index, values);
    return rendered ? newSVsv(rendered) : newSVpvs("");
}

static SV *
Perl_xperl_source_location_engine(pTHX_ const perl_diagpack_engine *engine,
                                 SV *file, SV *line, const char *language)
{
    if (engine)
        return Perl_xperl_render_format_engine(aTHX_ engine,
            perl_diag_note_context_location_idx, 5, file,
            sv_2mortal(newSViv(SvIV(line))), &PL_sv_no,
            sv_2mortal(newSVpvs("plain")), sv_2mortal(newSVpvs("source")));
    return Perl_xperl_render_format(aTHX_ perl_diag_note_context_location_idx,
        language, 5, file, sv_2mortal(newSViv(SvIV(line))),
        &PL_sv_no, sv_2mortal(newSVpvs("plain")),
        sv_2mortal(newSVpvs("source")));
}

static void
Perl_xperl_append_source_location_engine(pTHX_
                                const perl_diagpack_engine *engine,
                                SV *text, SV *file, SV *line,
                                const char *language)
{
    SV *location = Perl_xperl_source_location_engine(aTHX_ engine, file, line,
                                                      language);
    sv_catsv(text, location);
    SvREFCNT_dec_NN(location);
}

static SV *Perl_xperl_render_diagnostic_legacy(pTHX_ HV *fields,
                                             const char *language,
                                             HV *context);
static SV *Perl_xperl_render_diagnostic_modern(pTHX_ HV *fields,
                                             const char *language,
                                             HV *context);
static SV *Perl_xperl_render_diagnostic_template(pTHX_ HV *fields,
                                                const char *language,
                                                const perl_diagpack_engine *engine);
static SV *Perl_xperl_named_param(pTHX_ HV *diagnostic, const char *name);
static SV *Perl_xperl_exception_diagnostic_at(pTHX_ SV *exception,
                                            SSize_t index,
                                            bool *in_range);
static bool Perl_xperl_class_is_leaf_only(pTHX_ SV *object);

static bool
Perl_xperl_hint_matches_previous(pTHX_ HV *diagnostic, HV *hint)
{
    SV *has_hint = Perl_xperl_field(aTHX_ diagnostic, "has_following_hint");
    SV *is_hint = Perl_xperl_field(aTHX_ hint, "is_hint");

    return SvTRUE(has_hint) && SvTRUE(is_hint);
}

static bool
Perl_xperl_diagnostic_has_context_followup(pTHX_ HV *diagnostic, HV *context)
{
    SV *light = Perl_xperl_field(aTHX_ diagnostic, "light");
    SV *followup_index = Perl_xperl_field(aTHX_ diagnostic,
                                       "context_follows_index");
    SV *exception;
    SV *index;
    SSize_t target_index;
    SSize_t current_index;
    bool in_range;

    if (!context || !SvTRUE(light) || !SvOK(followup_index)
        || SvROK(followup_index))
        return FALSE;

    exception = Perl_xperl_field(aTHX_ context, "exception");
    index = Perl_xperl_field(aTHX_ context, "index");
    if (!SvROK(exception) || !SvOK(index))
        return FALSE;

    current_index = SvIV(index);
    target_index = SvIV(followup_index);
    if (current_index < 0 || target_index <= current_index)
        return FALSE;

    {
        SV *tail = Perl_xperl_exception_diagnostic_at(
            aTHX_ exception, target_index, &in_range);
        bool valid_tail = in_range && tail && SvROK(tail)
            && SvTYPE(SvRV(tail)) == SVt_PVHV;
        if (tail)
            SvREFCNT_dec_NN(tail);
        return valid_tail;
    }
}

static HV *
Perl_xperl_render_context_from_arg(pTHX_ SV *context_arg)
{
    if (!SvOK(context_arg))
        return NULL;
    if (!SvROK(context_arg) || SvTYPE(SvRV(context_arg)) != SVt_PVHV)
        PERL_THROW_ERROR_DIAGNOSTIC_API_RENDER_CONTEXT_NOT_HASH();
    return MUTABLE_HV(SvRV(context_arg));
}

static void
Perl_xperl_render_context_set(pTHX_ HV *context, SV *exception, SSize_t index)
{
    SV **slot;

    slot = hv_fetchs(context, "exception", 1);
    if (UNLIKELY(!slot))
        croak_no_mem();
    sv_setsv(*slot, exception);

    slot = hv_fetchs(context, "index", 1);
    if (UNLIKELY(!slot))
        croak_no_mem();
    sv_setiv(*slot, index);
}

static SV *
Perl_xperl_exception_diagnostic_at(pTHX_ SV *exception, SSize_t index,
                                bool *in_range)
{
    HV *fields = Perl_xperl_object_hv(aTHX_ exception, "XPerl::Exception");
    SV *messages = Perl_xperl_field(aTHX_ fields, "contents");
    AV *diagnostics;
    SV **item_slot;

    *in_range = FALSE;
    if (!SvROK(messages) || SvTYPE(SvRV(messages)) != SVt_PVAV)
        return NULL;

    diagnostics = MUTABLE_AV(SvRV(messages));
    if (index < 0 || index > av_top_index(diagnostics))
        return NULL;

    *in_range = TRUE;
    item_slot = av_fetch(diagnostics, index, FALSE);
    return item_slot ? newSVsv(*item_slot) : newSV(0);
}

static bool
Perl_xperl_render_context_is_hint(pTHX_ HV *diagnostic, HV *context)
{
    SV *is_hint = Perl_xperl_field(aTHX_ diagnostic, "is_hint");
    SV *exception;
    SV *index;
    SV *previous_item;
    HV *previous;
    SV *previous_has_hint;
    bool in_range;

    if (!context || !SvTRUE(is_hint))
        return FALSE;

    exception = Perl_xperl_field(aTHX_ context, "exception");
    index = Perl_xperl_field(aTHX_ context, "index");
    if (!SvROK(exception) || !SvOK(index) || SvIV(index) <= 0)
        return FALSE;

    previous_item = Perl_xperl_exception_diagnostic_at(aTHX_ exception,
        SvIV(index) - 1, &in_range);
    if (!in_range || !previous_item)
        return FALSE;
    previous = SvROK(previous_item)
        && SvTYPE(SvRV(previous_item)) == SVt_PVHV
        ? MUTABLE_HV(SvRV(previous_item)) : NULL;
    if (!previous) {
        SvREFCNT_dec_NN(previous_item);
        return FALSE;
    }

    previous_has_hint = Perl_xperl_field(aTHX_ previous,
                                      "has_following_hint");

    SvREFCNT_dec_NN(previous_item);
    return SvTRUE(previous_has_hint);
}

static void
Perl_xperl_append_indented_text(pTHX_ SV *output, SV *text)
{
    STRLEN length;
    const char *bytes = SvPV(text, length);
    STRLEN offset = 0;

    while (offset < length) {
        STRLEN end = offset;

        sv_catpvs(output, "  ");
        while (end < length && bytes[end] != '\n')
            end++;
        if (end < length)
            end++;
        sv_catpvn_flags(output, bytes + offset, end - offset,
                        SvUTF8(text) ? SVf_UTF8 : 0);
        offset = end;
    }
}

static void
Perl_xperl_append_diagnostic_contents(pTHX_ SV *output, HV *fields,
                                    const char *language, bool modern,
                                    HV *context)
{
    SV *code = Perl_xperl_field(aTHX_ fields, "code");
    const bool transparent = SvPOK(code)
        && strEQ(SvPV_nolen(code), "ERROR_OBJECT_COMPOSITION_FAILED");
    SV *initial_contents = Perl_xperl_field(aTHX_ fields, "contents");
    SSize_t last_index;
    SSize_t i;

    if (!SvROK(initial_contents) || SvTYPE(SvRV(initial_contents)) != SVt_PVAV)
        return;
    last_index = av_top_index(MUTABLE_AV(SvRV(initial_contents)));
    for (i = 0; i <= last_index; i++) {
        SV *contents = Perl_xperl_field(aTHX_ fields, "contents");
        AV *array;
        SV **child;
        SV *child_object;
        HV *child_fields;
        SV *child_text;

        if (!SvROK(contents) || SvTYPE(SvRV(contents)) != SVt_PVAV)
            break;
        array = MUTABLE_AV(SvRV(contents));
        if (i > av_top_index(array))
            break;
        child = av_fetch(array, i, FALSE);
        if (!child || !SvROK(*child) || SvTYPE(SvRV(*child)) != SVt_PVHV)
            continue;
        child_object = sv_2mortal(newSVsv(*child));
        child_fields = MUTABLE_HV(SvRV(child_object));
        if (!modern && SvTRUE(Perl_xperl_field(aTHX_ child_fields,
                                               "is_hint"))) {
            SV *hint_code = Perl_xperl_field(aTHX_ child_fields, "code");
            SV *hint_text = NULL;
            SV *hint_value = &PL_sv_undef;
            bool had_newline = SvCUR(output)
                && SvEND(output)[-1] == '\n';

            if (had_newline)
                SvCUR_set(output, SvCUR(output) - 1);
            if (SvOK(hint_code) && !SvROK(hint_code)
                && strEQ(SvPV_nolen(hint_code),
                         "NOTE_HINT_OPERATOR_EXPECTED_MISSING_OPERATOR"))
                hint_value = Perl_xperl_named_param(aTHX_ child_fields,
                                                     "context");
            else if (SvOK(hint_code) && !SvROK(hint_code)
                && strEQ(SvPV_nolen(hint_code),
                         "NOTE_HINT_OPERATOR_EXPECTED_PREDECLARE"))
                hint_value = Perl_xperl_named_param(aTHX_ child_fields,
                                                     "name");

            if (SvOK(hint_value) && SvOK(hint_code) && !SvROK(hint_code)
                && (strEQ(SvPV_nolen(hint_code),
                          "NOTE_HINT_OPERATOR_EXPECTED_MISSING_OPERATOR")
                    || strEQ(SvPV_nolen(hint_code),
                             "NOTE_HINT_OPERATOR_EXPECTED_PREDECLARE"))) {
                const char *hint_kind = strEQ(SvPV_nolen(hint_code),
                    "NOTE_HINT_OPERATOR_EXPECTED_PREDECLARE")
                    ? "predeclare" : "missing_operator";
                const perl_diagpack_engine *hint_engine =
                    Perl_xperl_render_engine(aTHX_ child_fields, context);
                hint_text = hint_engine
                    ? Perl_xperl_render_format_engine(aTHX_ hint_engine,
                        perl_diag_note_hint_operator_expected_idx, 2,
                        hint_value, sv_2mortal(newSVpv(hint_kind, 0)))
                    : Perl_xperl_render_format(aTHX_
                        perl_diag_note_hint_operator_expected_idx, language, 2,
                        hint_value, sv_2mortal(newSVpv(hint_kind, 0)));
                sv_catsv(output, hint_text);
            }
            else {
                hint_text = Perl_xperl_render_diagnostic_template(aTHX_
                    child_fields, language,
                    Perl_xperl_render_engine(aTHX_ child_fields, context));
                if (hint_text) {
                    STRLEN hint_length;
                    const char *hint_bytes = SvPV(hint_text, hint_length);
                    while (hint_length
                        && (hint_bytes[hint_length - 1] == '\n'
                            || hint_bytes[hint_length - 1] == '.'))
                        hint_length--;
                    sv_catpvs(output, " (");
                    sv_catpvn_flags(output, hint_bytes, hint_length,
                                    SvUTF8(hint_text) ? SVf_UTF8 : 0);
                    sv_catpvs(output, ")");
                }
            }
            if (hint_text)
                SvREFCNT_dec_NN(hint_text);
            if (had_newline)
                sv_catpvs(output, "\n");
            continue;
        }
        child_text = modern
            ? Perl_xperl_render_diagnostic_modern(aTHX_ child_fields,
                                                   language, context)
            : Perl_xperl_render_diagnostic_legacy(aTHX_ child_fields,
                                                   language, context);
        if (!child_text || SvROK(child_text)) {
            if (child_text)
                SvREFCNT_dec_NN(child_text);
            continue;
        }
        if (modern) {
            SV *number = Perl_xperl_field(aTHX_ child_fields, "number");
            SV *severity = Perl_xperl_field(aTHX_ child_fields, "severity");
            SV *kind = Perl_xperl_field(aTHX_ child_fields, "kind");
            SV *child_code = Perl_xperl_field(aTHX_ child_fields, "code");
            sv_catpvs(output, "\n  #");
            if (SvOK(number))
                sv_catsv(output, number);
            else
                sv_catpvs(output, "0");
            sv_catpvs(output, " ");
            if (SvOK(severity))
                sv_catsv(output, severity);
            else
                sv_catpvs(output, "UNKNOWN");
            sv_catpvs(output, ".");
            if (SvOK(kind))
                sv_catsv(output, kind);
            else
                sv_catpvs(output, "UNKNOWN");
            sv_catpvs(output, ".");
            if (SvOK(child_code))
                sv_catsv(output, child_code);
            else
                sv_catpvs(output, "UNKNOWN");
            sv_catpvs(output, "\n");
            Perl_xperl_append_indented_text(aTHX_ output, child_text);
        }
        else {
            sv_catpvs(output, "\n");
            if (transparent)
                sv_catsv(output, child_text);
            else
                Perl_xperl_append_indented_text(aTHX_ output, child_text);
        }
        SvREFCNT_dec_NN(child_text);
    }
}

static SV *
Perl_xperl_copy_field(pTHX_ HV *hv, const char *key)
{
    SV *value = Perl_xperl_field(aTHX_ hv, key);
    return SvOK(value) ? newSVsv(value) : newSV(0);
}

static void
Perl_xperl_store_copy(pTHX_ HV *hv, const char *key, SV *value)
{
    (void)hv_store(hv, key, strlen(key), newSVsv(value), 0);
}

static AV *
Perl_xperl_copy_array(pTHX_ AV *source, bool copy_hashes)
{
    AV *copy = newAV();
    SSize_t i;
    for (i = 0; i <= av_top_index(source); i++) {
        SV **svp = av_fetch(source, i, 0);
        SV *value = svp ? *svp : &PL_sv_undef;
        if (copy_hashes && SvROK(value)
            && SvTYPE(SvRV(value)) == SVt_PVHV)
            av_push(copy, newRV_noinc(MUTABLE_SV(newHVhv(MUTABLE_HV(SvRV(value))))));
        else
            av_push(copy, newSVsv(value));
    }
    return copy;
}

XS(Perl_XPerl_Diagnostic_new);
XS(Perl_XPerl_Diagnostic_new)
{
    dXSARGS;
    HV *source;
    HV *fields;
    SV *code;
    SV *params;
    SV *location;
    SV *warning_categories;
    SV *light;
    SV *context_follows_index;
    SV *contents;
    SV *object;
    STRLEN code_len;
    static const char *keys[] = {
        "code", "number", "kind", "severity", "selector_key", "light",
        "context_follows_index"
    };
    Size_t i;

    if (items != 2)
        croak_xs_usage(cv, "class, fields");
    if (!SvROK(ST(1)) || SvTYPE(SvRV(ST(1))) != SVt_PVHV)
        PERL_THROW_ERROR_DIAGNOSTIC_API_CONSTRUCTION_FIELDS_NOT_HASH();
    source = MUTABLE_HV(SvRV(ST(1)));
    code = Perl_xperl_field(aTHX_ source, "code");
    if (!SvOK(code))
        PERL_THROW_ERROR_DIAGNOSTIC_API_CONSTRUCTION_CODE_MISSING();
    (void)SvPV(code, code_len);
    if (!code_len)
        PERL_THROW_ERROR_DIAGNOSTIC_API_CONSTRUCTION_CODE_MISSING();
    params = Perl_xperl_field(aTHX_ source, "params");
    if (!SvROK(params) || SvTYPE(SvRV(params)) != SVt_PVAV)
        PERL_THROW_ERROR_DIAGNOSTIC_API_CONSTRUCTION_PARAMETERS_NOT_ARRAY();
    location = Perl_xperl_field(aTHX_ source, "location");
    if (SvOK(location) && (!SvROK(location)
        || SvTYPE(SvRV(location)) != SVt_PVHV))
        PERL_THROW_ERROR_DIAGNOSTIC_API_CONSTRUCTION_LOCATION_NOT_HASH();
    warning_categories = Perl_xperl_field(aTHX_ source, "warning_categories");
    if (SvOK(warning_categories) && (!SvROK(warning_categories)
        || SvTYPE(SvRV(warning_categories)) != SVt_PVAV))
        PERL_THROW_ERROR_DIAGNOSTIC_API_CONSTRUCTION_WARNING_CATEGORIES_NOT_ARRAY();
    light = Perl_xperl_field(aTHX_ source, "light");
    if (SvOK(light) && SvROK(light))
        PERL_THROW_ERROR_DIAGNOSTIC_API_CONSTRUCTION_LIGHT_FLAG_NOT_SCALAR();
    context_follows_index = Perl_xperl_field(aTHX_ source,
                                          "context_follows_index");
    if (SvOK(context_follows_index)
        && (SvROK(context_follows_index)
            || !looks_like_number(context_follows_index)
            || SvIV(context_follows_index) < 0))
        PERL_THROW_ERROR_DIAGNOSTIC_API_CONSTRUCTION_CONTEXT_INDEX_INVALID();
    contents = Perl_xperl_field(aTHX_ source, "contents");
    if (SvOK(contents) && (!SvROK(contents) || SvTYPE(SvRV(contents)) != SVt_PVAV))
        PERL_THROW_ERROR_DIAGNOSTIC_API_CHILDREN_LIST_NOT_ARRAY();
    if (SvOK(contents)) {
        AV *child_array = MUTABLE_AV(SvRV(contents));
        SSize_t child_index;
        for (child_index = 0; child_index <= av_top_index(child_array); child_index++) {
            SV **child = av_fetch(child_array, child_index, FALSE);
            if (!child || !sv_derived_from(*child, "XPerl::Diagnostic"))
                PERL_THROW_ERROR_DIAGNOSTIC_API_CHILDREN_MEMBER_NOT_DIAGNOSTIC();
        }
        if (av_top_index(child_array) >= 0
            && Perl_xperl_class_is_leaf_only(aTHX_ ST(0)))
            PERL_THROW_ERROR_DIAGNOSTIC_API_CHILDREN_LEAF_CONTAINER_FORBIDDEN();
    }

    fields = newHV();
    for (i = 0; i < 4; i++)
        Perl_xperl_store_copy(aTHX_ fields, keys[i], Perl_xperl_field(aTHX_ source, keys[i]));
    for (i = 4; i < C_ARRAY_LENGTH(keys); i++) {
        SV **svp = hv_fetch(source, keys[i], strlen(keys[i]), 0);
        if (svp)
            Perl_xperl_store_copy(aTHX_ fields, keys[i], *svp);
    }
    {
        SV **engine_slot = sv_derived_from(ST(1), "XPerl::Diagnostic")
            ? hv_fetchs(source, "_diagpack_engine", FALSE) : NULL;
        const perl_diagpack_engine *engine = engine_slot && SvIOK(*engine_slot)
            ? INT2PTR(const perl_diagpack_engine *, SvUV(*engine_slot))
            : Perl_diagpack_current_hint(aTHX);
        if (engine)
            (void)hv_stores(fields, "_diagpack_engine",
                            newSVuv(PTR2UV(engine)));
    }
    (void)hv_stores(fields, "params",
                    newRV_noinc(MUTABLE_SV(Perl_xperl_copy_array(aTHX_
                                      MUTABLE_AV(SvRV(params)), FALSE))));
    if (SvOK(warning_categories))
        (void)hv_stores(fields, "warning_categories",
                        newRV_noinc(MUTABLE_SV(Perl_xperl_copy_array(aTHX_
                            MUTABLE_AV(SvRV(warning_categories)), FALSE))));
    if (SvOK(contents) && av_top_index(MUTABLE_AV(SvRV(contents))) >= 0)
        (void)hv_stores(fields, "contents",
                        newRV_noinc(MUTABLE_SV(Perl_xperl_copy_array(aTHX_
                            MUTABLE_AV(SvRV(contents)), FALSE))));
    (void)hv_stores(fields, "location",
                    newRV_noinc(MUTABLE_SV(SvOK(location)
                        ? newHVhv(MUTABLE_HV(SvRV(location))) : newHV())));
    object = newRV_noinc(MUTABLE_SV(fields));
    sv_bless(object, gv_stashsv(ST(0), GV_ADD));
    ST(0) = sv_2mortal(object);
    XSRETURN(1);
}

static bool Perl_xperl_diag_group_contains(pTHX_ SV *root, SV *target);

static bool
Perl_xperl_class_is_leaf_only(pTHX_ SV *object)
{
    return Perl_diag_class_is_leaf_only(aTHX_ object);
}

XS(Perl_XPerl_Diagnostic_derive);
XS(Perl_XPerl_Diagnostic_derive)
{
    dXSARGS;
    HV *source;
    HV *fields;
    AV *contents;
    SV *derived;
    SSize_t i;

    if (items != 2)
        croak_xs_usage(cv, "self, contents");
    source = Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::Diagnostic");
    if (!SvROK(ST(1)) || SvTYPE(SvRV(ST(1))) != SVt_PVAV)
        PERL_THROW_ERROR_DIAGNOSTIC_API_CHILDREN_DERIVED_LIST_NOT_ARRAY();
    contents = MUTABLE_AV(SvRV(ST(1)));
    if (av_top_index(contents) >= 0
        && Perl_xperl_class_is_leaf_only(aTHX_ ST(0)))
        PERL_THROW_ERROR_DIAGNOSTIC_API_CHILDREN_LEAF_CONTAINER_FORBIDDEN();
    for (i = 0; i <= av_top_index(contents); i++) {
        SV **child = av_fetch(contents, i, FALSE);
        if (!child || !sv_derived_from(*child, "XPerl::Diagnostic"))
            PERL_THROW_ERROR_DIAGNOSTIC_API_CHILDREN_DERIVED_MEMBER_NOT_DIAGNOSTIC();
        if (Perl_xperl_diag_group_contains(aTHX_ *child, ST(0)))
            PERL_THROW_ERROR_DIAGNOSTIC_API_CHILDREN_DERIVE_CYCLE();
    }

    fields = newHVhv(source);
    if (av_top_index(contents) >= 0)
        (void)hv_stores(fields, "contents",
                        newRV_noinc(MUTABLE_SV(Perl_xperl_copy_array(aTHX_
                            contents, FALSE))));
    else
        (void)hv_delete(fields, "contents", sizeof("contents") - 1, G_DISCARD);
    derived = newRV_noinc(MUTABLE_SV(fields));
    sv_bless(derived, SvSTASH(SvRV(ST(0))));
    ST(0) = sv_2mortal(derived);
    XSRETURN(1);
}

XS(Perl_XPerl_DiagGroup_contents);
XS(Perl_XPerl_DiagGroup_contents)
{
    dXSARGS;
    HV *fields;
    SV *contents;
    if (items != 1)
        croak_xs_usage(cv, "self");
    fields = Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::DiagGroup");
    contents = Perl_xperl_field(aTHX_ fields, "contents");
    if (!SvOK(contents)) {
        ST(0) = sv_2mortal(newRV_noinc(MUTABLE_SV(newAV())));
        XSRETURN(1);
    }
    if (!SvROK(contents) || SvTYPE(SvRV(contents)) != SVt_PVAV)
        PERL_THROW_ERROR_DIAGNOSTIC_API_CHILDREN_STORED_LIST_NOT_ARRAY();
    ST(0) = sv_2mortal(newRV_noinc(MUTABLE_SV(Perl_xperl_copy_array(aTHX_
        MUTABLE_AV(SvRV(contents)), FALSE))));
    XSRETURN(1);
}

XS(Perl_XPerl_DiagGroup_contents_count);
XS(Perl_XPerl_DiagGroup_contents_count)
{
    dXSARGS;
    HV *fields;
    SV *contents;
    if (items != 1)
        croak_xs_usage(cv, "self");
    fields = Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::DiagGroup");
    contents = Perl_xperl_field(aTHX_ fields, "contents");
    if (!SvOK(contents)) {
        ST(0) = sv_2mortal(newSViv(0));
        XSRETURN(1);
    }
    if (!SvROK(contents) || SvTYPE(SvRV(contents)) != SVt_PVAV)
        PERL_THROW_ERROR_DIAGNOSTIC_API_CHILDREN_STORED_LIST_NOT_ARRAY();
    ST(0) = sv_2mortal(newSViv(av_top_index(MUTABLE_AV(SvRV(contents))) + 1));
    XSRETURN(1);
}

static bool
Perl_xperl_diag_group_contains(pTHX_ SV *root, SV *target)
{
    AV *pending = newAV();
    AV *visited = newAV();
    SV *node;
    bool found = FALSE;

    av_push(pending, newSVsv(root));
    while (av_top_index(pending) >= 0) {
        HV *fields;
        SV *contents;
        AV *array;
        SSize_t i;

        node = av_pop(pending);
        if (!node || !SvROK(node) || SvTYPE(SvRV(node)) != SVt_PVHV) {
            if (node)
                SvREFCNT_dec_NN(node);
            continue;
        }
        if (SvRV(node) == SvRV(target)) {
            found = TRUE;
            SvREFCNT_dec_NN(node);
            break;
        }
        for (i = 0; i <= av_top_index(visited); i++) {
            SV **seen = av_fetch(visited, i, FALSE);
            if (seen && SvROK(*seen) && SvRV(*seen) == SvRV(node))
                break;
        }
        if (i <= av_top_index(visited)) {
            SvREFCNT_dec_NN(node);
            continue;
        }
        av_push(visited, newSVsv(node));
        fields = MUTABLE_HV(SvRV(node));
        contents = Perl_xperl_field(aTHX_ fields, "contents");
        if (SvROK(contents) && SvTYPE(SvRV(contents)) == SVt_PVAV) {
            array = MUTABLE_AV(SvRV(contents));
            for (i = 0; i <= av_top_index(array); i++) {
                SV **child = av_fetch(array, i, FALSE);
                if (child && SvROK(*child))
                    av_push(pending, newSVsv(*child));
            }
        }
        SvREFCNT_dec_NN(node);
    }

    SvREFCNT_dec_NN((SV *)pending);
    SvREFCNT_dec_NN((SV *)visited);
    return found;
}

static void
Perl_xperl_diag_group_append(pTHX_ SV *parent, SV *child,
                             const bool exception_message)
{
    HV *fields;
    SV *contents;

    fields = Perl_xperl_object_hv(aTHX_ parent, "XPerl::DiagGroup");
    if (!sv_derived_from(child, "XPerl::Diagnostic")) {
        if (exception_message)
            PERL_THROW_ERROR_DIAGNOSTIC_API_CHILDREN_EXCEPTION_ITEM_NOT_DIAGNOSTIC();
        else
            PERL_THROW_ERROR_DIAGNOSTIC_API_CHILDREN_APPENDED_ITEM_NOT_DIAGNOSTIC();
    }
    if (Perl_xperl_class_is_leaf_only(aTHX_ parent))
        PERL_THROW_ERROR_DIAGNOSTIC_API_CHILDREN_LEAF_CONTAINER_FORBIDDEN();
    if (Perl_xperl_diag_group_contains(aTHX_ child, parent))
        PERL_THROW_ERROR_DIAGNOSTIC_API_CHILDREN_APPEND_CYCLE();
    contents = Perl_xperl_field(aTHX_ fields, "contents");
    if (!SvOK(contents) && sv_derived_from(parent, "XPerl::DiagGroup")) {
        contents = newRV_noinc(MUTABLE_SV(newAV()));
        (void)hv_stores(fields, "contents", contents);
    }
    if (!SvROK(contents) || SvTYPE(SvRV(contents)) != SVt_PVAV)
        PERL_THROW_ERROR_DIAGNOSTIC_API_CHILDREN_STORED_LIST_NOT_ARRAY();
    av_push(MUTABLE_AV(SvRV(contents)), newSVsv(child));
}

static bool
Perl_xperl_diag_group_has_errors(pTHX_ SV *root)
{
    AV *pending = newAV();
    AV *visited = newAV();
    SV *node;
    bool found = FALSE;

    av_push(pending, newSVsv(root));
    while (av_top_index(pending) >= 0) {
        HV *fields;
        SV *severity;
        SV *contents;
        AV *array;
        SSize_t i;

        node = av_pop(pending);
        if (!node || !SvROK(node) || SvTYPE(SvRV(node)) != SVt_PVHV) {
            if (node)
                SvREFCNT_dec_NN(node);
            continue;
        }
        for (i = 0; i <= av_top_index(visited); i++) {
            SV **seen = av_fetch(visited, i, FALSE);
            if (seen && SvROK(*seen) && SvRV(*seen) == SvRV(node))
                break;
        }
        if (i <= av_top_index(visited)) {
            SvREFCNT_dec_NN(node);
            continue;
        }
        av_push(visited, newSVsv(node));
        fields = MUTABLE_HV(SvRV(node));
        severity = Perl_xperl_field(aTHX_ fields, "severity");
        if (SvPOK(severity)
            && (strEQ(SvPV_nolen(severity), "FATAL_ERROR")
                || strEQ(SvPV_nolen(severity), "INTERNAL_ERROR")))
            found = TRUE;
        if (SvTRUE(Perl_xperl_field(aTHX_ fields, "_fatal_warning"))
            || SvTRUE(Perl_xperl_field(aTHX_ fields, "_delivery_fatal")))
            found = TRUE;
        if (sv_derived_from(node, "XPerl::Exception")) {
            SV *count = Perl_xperl_field(aTHX_ fields, "error_count");
            if (SvOK(count) && SvUV(count))
                found = TRUE;
        }
        if (found) {
            SvREFCNT_dec_NN(node);
            break;
        }
        contents = Perl_xperl_field(aTHX_ fields, "contents");
        if (SvROK(contents) && SvTYPE(SvRV(contents)) == SVt_PVAV) {
            array = MUTABLE_AV(SvRV(contents));
            for (i = 0; i <= av_top_index(array); i++) {
                SV **child = av_fetch(array, i, FALSE);
                if (child && SvROK(*child))
                    av_push(pending, newSVsv(*child));
            }
        }
        SvREFCNT_dec_NN(node);
    }

    SvREFCNT_dec_NN((SV *)pending);
    SvREFCNT_dec_NN((SV *)visited);
    return found;
}

XS(Perl_XPerl_DiagGroup_contains);
XS(Perl_XPerl_DiagGroup_contains)
{
    dXSARGS;
    if (items != 2)
        croak_xs_usage(cv, "self, group");
    (void)Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::DiagGroup");
    (void)Perl_xperl_object_hv(aTHX_ ST(1), "XPerl::DiagGroup");
    ST(0) = boolSV(Perl_xperl_diag_group_contains(aTHX_ ST(0), ST(1)));
    XSRETURN(1);
}

XS(Perl_XPerl_DiagGroup_has_errors);
XS(Perl_XPerl_DiagGroup_has_errors)
{
    dXSARGS;
    if (items != 1)
        croak_xs_usage(cv, "self");
    (void)Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::DiagGroup");
    ST(0) = boolSV(Perl_xperl_diag_group_has_errors(aTHX_ ST(0)));
    XSRETURN(1);
}

XS(Perl_XPerl_DiagGroup_append);
XS(Perl_XPerl_DiagGroup_append)
{
    dXSARGS;
    if (items != 2)
        croak_xs_usage(cv, "self, child");
    Perl_xperl_diag_group_append(aTHX_ ST(0), ST(1),
                                 sv_derived_from(ST(0), "XPerl::Exception"));
    ST(0) = ST(1);
    XSRETURN(1);
}

XS(Perl_XPerl_noop_destroy);
XS(Perl_XPerl_noop_destroy)
{
    dXSARGS;
    PERL_UNUSED_VAR(items);
    XSRETURN_EMPTY;
}

XS(Perl_XPerl_Diagnostic_field);
XS(Perl_XPerl_Diagnostic_field)
{
    dXSARGS;
    dXSI32;
    static const char *keys[] = {
        "code", "number", "kind", "severity", "selector_key", "light",
        "context_follows_index"
    };
    HV *fields;
    if (items != 1)
        croak_xs_usage(cv, "self");
    fields = Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::Diagnostic");
    if (ix == 4)
        ST(0) = sv_2mortal(Perl_xperl_selector_key(aTHX_ fields));
    else
        ST(0) = sv_2mortal(Perl_xperl_copy_field(aTHX_ fields, keys[ix]));
    XSRETURN(1);
}

XS(Perl_XPerl_Diagnostic_params);
XS(Perl_XPerl_Diagnostic_params)
{
    dXSARGS;
    HV *fields;
    SV *params;
    if (items != 1)
        croak_xs_usage(cv, "self");
    fields = Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::Diagnostic");
    params = Perl_xperl_field(aTHX_ fields, "params");
    ST(0) = sv_2mortal(newRV_noinc(MUTABLE_SV(Perl_xperl_copy_array(aTHX_
                              MUTABLE_AV(SvRV(params)), TRUE))));
    XSRETURN(1);
}

XS(Perl_XPerl_Diagnostic_warning_categories);
XS(Perl_XPerl_Diagnostic_warning_categories)
{
    dXSARGS;
    HV *fields;
    SV *categories;
    if (items != 1)
        croak_xs_usage(cv, "self");
    fields = Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::Diagnostic");
    categories = Perl_xperl_field(aTHX_ fields, "warning_categories");
    ST(0) = sv_2mortal(SvOK(categories)
        ? newRV_noinc(MUTABLE_SV(Perl_xperl_copy_array(aTHX_
                                MUTABLE_AV(SvRV(categories)), FALSE)))
        : newSV(0));
    XSRETURN(1);
}

XS(Perl_XPerl_Diagnostic_location);
XS(Perl_XPerl_Diagnostic_location)
{
    dXSARGS;
    HV *fields;
    SV *location;
    if (items != 1)
        croak_xs_usage(cv, "self");
    fields = Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::Diagnostic");
    location = Perl_xperl_field(aTHX_ fields, "location");
    ST(0) = sv_2mortal(newRV_noinc(MUTABLE_SV(
                       newHVhv(MUTABLE_HV(SvRV(location))))));
    XSRETURN(1);
}

XS(Perl_XPerl_Exception_new);
XS(Perl_XPerl_Exception_new)
{
    dXSARGS;
    HV *fields;
    SV *object;
    if (items != 1)
        croak_xs_usage(cv, "class");
    fields = newHV();
    (void)hv_stores(fields, "contents", newRV_noinc(MUTABLE_SV(newAV())));
    (void)hv_stores(fields, "origin", newSV(0));
    (void)hv_stores(fields, "error_count", newSVuv(0));
    (void)hv_stores(fields, "thrown", newSViv(0));
    object = newRV_noinc(MUTABLE_SV(fields));
    sv_bless(object, gv_stashsv(ST(0), GV_ADD));
    ST(0) = sv_2mortal(object);
    XSRETURN(1);
}

XS(Perl_XPerl_Exception_propagate);
XS(Perl_XPerl_Exception_propagate)
{
    dXSARGS;
    if (items != 3)
        croak_xs_usage(cv, "self, file, line");
    PERL_APPEND_ERROR_PROPAGATION_RETHROW_CONTEXT(&ST(0), SvPV_nolen(ST(1)), SvUV(ST(2)));
    XSRETURN(1);
}

XS(Perl_XPerl_Exception_record_throw);
XS(Perl_XPerl_Exception_record_throw)
{
    dXSARGS;
    HV *fields;
    HV *record;
    SV *reason;
    SV *origin;
    SV *messages;
    if (items < 2 || items > 3)
        croak_xs_usage(cv, "self, event, diagnostic = undef");
    fields = Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::Exception");
    if (!SvROK(ST(1)) || SvTYPE(SvRV(ST(1))) != SVt_PVHV)
        PERL_THROW_ERROR_DIAGNOSTIC_API_THROW_EVENT_NOT_HASH();
    record = MUTABLE_HV(SvRV(ST(1)));
    if (hv_exists(record, "message_index", 13))
        PERL_THROW_ERROR_DIAGNOSTIC_API_THROW_MESSAGE_INDEX_RESERVED();
    reason = Perl_xperl_field(aTHX_ record, "reason");
    if (SvOK(reason) && strEQ(SvPV_nolen(reason), "rethrow")
        && (items < 3 || !SvOK(ST(2))))
        PERL_THROW_ERROR_DIAGNOSTIC_API_THROW_RETHROW_DIAGNOSTIC_MISSING();
    if (items == 3 && SvOK(ST(2))
        && !sv_derived_from(ST(2), "XPerl::Diagnostic"))
        PERL_THROW_ERROR_DIAGNOSTIC_API_CHILDREN_EXCEPTION_ITEM_NOT_DIAGNOSTIC();
    if (items == 3 && SvOK(ST(2)))
        Perl_xperl_diag_group_append(aTHX_ ST(0), ST(2),
                                     TRUE);
    origin = Perl_xperl_field(aTHX_ fields, "origin");
    if (SvOK(origin))
        XSRETURN(1);

    record = newHVhv(record);
    if (items == 3 && SvOK(ST(2))) {
        messages = Perl_xperl_field(aTHX_ fields, "contents");
        (void)hv_stores(record, "message_index",
            newSViv(av_top_index(MUTABLE_AV(SvRV(messages)))));
    }
    (void)hv_stores(fields, "origin", newRV_noinc(MUTABLE_SV(record)));
    XSRETURN(1);
}

static HV *
Perl_xperl_primary_diagnostic(pTHX_ HV *fields)
{
    SV *messages = Perl_xperl_field(aTHX_ fields, "contents");
    AV *diagnostics;
    AV *pending = newAV();
    AV *visited = newAV();
    SV *item;
    HV *first_warning = NULL;
    SSize_t i;

    if (!SvROK(messages) || SvTYPE(SvRV(messages)) != SVt_PVAV) {
        SvREFCNT_dec_NN((SV *)pending);
        SvREFCNT_dec_NN((SV *)visited);
        return NULL;
    }
    diagnostics = MUTABLE_AV(SvRV(messages));
    for (i = av_top_index(diagnostics); i >= 0; i--) {
        SV **item_slot = av_fetch(diagnostics, i, FALSE);
        if (item_slot && SvROK(*item_slot))
            av_push(pending, newSVsv(*item_slot));
    }
    while (av_top_index(pending) >= 0) {
        HV *diagnostic;
        SV *severity;
        const char *severity_pv;

        item = av_pop(pending);
        if (!item || !SvROK(item) || SvTYPE(SvRV(item)) != SVt_PVHV) {
            if (item)
                SvREFCNT_dec_NN(item);
            continue;
        }
        for (i = 0; i <= av_top_index(visited); i++) {
            SV **seen = av_fetch(visited, i, FALSE);
            if (seen && SvROK(*seen) && SvRV(*seen) == SvRV(item))
                break;
        }
        if (i <= av_top_index(visited)) {
            SvREFCNT_dec_NN(item);
            continue;
        }
        av_push(visited, newSVsv(item));
        diagnostic = MUTABLE_HV(SvRV(item));
        severity = Perl_xperl_field(aTHX_ diagnostic, "severity");
        severity_pv = SvOK(severity) && !SvROK(severity)
            ? SvPV_nolen(severity) : "";
        if (strEQ(severity_pv, "FATAL_ERROR")
            || strEQ(severity_pv, "INTERNAL_ERROR")) {
            SvREFCNT_dec_NN(item);
            SvREFCNT_dec_NN((SV *)pending);
            SvREFCNT_dec_NN((SV *)visited);
            return diagnostic;
        }
        if (strEQ(severity_pv, "WARNING")
            || strEQ(severity_pv, "DEPRECATION")
            || strEQ(severity_pv, "SEVERE_WARNING")) {
            if (!first_warning)
                first_warning = diagnostic;
        }
        SV *contents = Perl_xperl_field(aTHX_ diagnostic, "contents");
        AV *child_array = SvROK(contents) && SvTYPE(SvRV(contents)) == SVt_PVAV
            ? MUTABLE_AV(SvRV(contents)) : NULL;
        for (i = child_array ? av_top_index(child_array) : -1; i >= 0; i--) {
            SV **child = av_fetch(child_array, i, FALSE);
            if (child && SvROK(*child))
                av_push(pending, newSVsv(*child));
        }
        SvREFCNT_dec_NN(item);
    }

    SvREFCNT_dec_NN((SV *)pending);
    SvREFCNT_dec_NN((SV *)visited);
    return first_warning;
}

static SV *
Perl_xperl_exception_state(pTHX_ HV *fields, const char *key)
{
    HV *diagnostic = Perl_xperl_primary_diagnostic(aTHX_ fields);
    return diagnostic
        ? Perl_xperl_copy_field(aTHX_ diagnostic, key)
        : newSV(0);
}

XS(Perl_XPerl_Exception_field);
XS(Perl_XPerl_Exception_field)
{
    dXSARGS;
    HV *fields;
    if (items != 1)
        croak_xs_usage(cv, "self");
    fields = Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::Exception");
    ST(0) = sv_2mortal(Perl_xperl_exception_state(aTHX_ fields, "kind"));
    XSRETURN(1);
}

XS(Perl_XPerl_Exception_severity);
XS(Perl_XPerl_Exception_severity)
{
    dXSARGS;
    HV *fields;
    if (items != 1)
        croak_xs_usage(cv, "self");
    fields = Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::Exception");
    ST(0) = sv_2mortal(Perl_xperl_exception_state(aTHX_ fields, "severity"));
    XSRETURN(1);
}

XS(Perl_XPerl_Exception_origin);
XS(Perl_XPerl_Exception_origin)
{
    dXSARGS;
    HV *fields;
    SV *origin;
    if (items != 1)
        croak_xs_usage(cv, "self");
    fields = Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::Exception");
    origin = Perl_xperl_field(aTHX_ fields, "origin");
    ST(0) = sv_2mortal(SvOK(origin)
        ? newRV_noinc(MUTABLE_SV(newHVhv(MUTABLE_HV(SvRV(origin)))))
        : newSV(0));
    XSRETURN(1);
}

static void
Perl_xperl_json_string(pTHX_ SV *out, SV *value)
{
    STRLEN len;
    const U8 *p;
    const U8 *end;
    bool is_utf8;

    if (!value || !SvOK(value) || SvROK(value)) {
        sv_catpvs(out, "null");
        return;
    }
    p = (const U8 *)SvPV(value, len);
    end = p + len;
    is_utf8 = cBOOL(SvUTF8(value));
    sv_catpvs(out, "\"");
    while (p < end) {
        UV cp;
        STRLEN width = 1;
        if (is_utf8) {
            width = isUTF8_CHAR(p, end);
            if (width)
                cp = utf8_to_uvchr_buf(p, p + width, NULL);
            else {
                cp = NATIVE_TO_UNI(*p);
                width = 1;
            }
        }
        else {
            cp = NATIVE_TO_UNI(*p);
        }
        p += width;
        if (cp == 0x22)
            sv_catpvs(out, "\\\"");
        else if (cp == 0x5c)
            sv_catpvs(out, "\\\\");
        else if (cp >= 0x20 && cp <= 0x7e) {
            char c = (char)UNI_TO_NATIVE(cp);
            sv_catpvn(out, &c, 1);
        }
        else if (cp <= 0xffff)
            sv_catpvf(out, "\\u%04X", (unsigned int)cp);
        else {
            UV above_bmp = cp - 0x10000;
            sv_catpvf(out, "\\u%04X\\u%04X",
                      (unsigned int)(0xd800 + (above_bmp >> 10)),
                      (unsigned int)(0xdc00 + (above_bmp & 0x3ff)));
        }
    }
    sv_catpvs(out, "\"");
}

static void
Perl_xperl_json_integer(pTHX_ SV *out, SV *value)
{
    if (!value || !SvOK(value))
        sv_catpvs(out, "null");
    else if (SvIOK(value)) {
        if (SvIsUV(value))
            sv_catpvf(out, "%" UVuf, SvUV(value));
        else
            sv_catpvf(out, "%" IVdf, SvIV(value));
    }
    else
        sv_catpvs(out, "null");
}

static void
Perl_xperl_json_location(pTHX_ SV *out, SV *location)
{
    HV *fields = SvROK(location) && SvTYPE(SvRV(location)) == SVt_PVHV
        ? MUTABLE_HV(SvRV(location)) : NULL;
    if (!fields) {
        sv_catpvs(out, "null");
        return;
    }
    sv_catpvs(out, "{\"file\":");
    Perl_xperl_json_string(aTHX_ out, Perl_xperl_field(aTHX_ fields, "file"));
    sv_catpvs(out, ",\"line\":");
    Perl_xperl_json_integer(aTHX_ out, Perl_xperl_field(aTHX_ fields, "line"));
    {
        SV *parser_context = Perl_xperl_field(aTHX_ fields, "parser_context");
        if (SvOK(parser_context)) {
            sv_catpvs(out, ",\"parser_context\":");
            Perl_xperl_json_string(aTHX_ out, parser_context);
        }
    }
    {
        SV *panic = Perl_xperl_field(aTHX_ fields, "panic");
        if (SvROK(panic) && SvTYPE(SvRV(panic)) == SVt_PVHV) {
            HV *context = MUTABLE_HV(SvRV(panic));
            static const char *names[] = {
                "file", "line", "errno", "extended_errno",
                "caller_file", "caller_line"
            };
            sv_catpvs(out, ",\"panic\":{");
            for (Size_t i = 0; i < C_ARRAY_LENGTH(names); i++) {
                if (i)
                    sv_catpvs(out, ",");
                sv_catpvf(out, "\"%s\":", names[i]);
                SV *value = Perl_xperl_field(aTHX_ context, names[i]);
                if (i == 0 || i == 4)
                    Perl_xperl_json_string(aTHX_ out, value);
                else
                    Perl_xperl_json_integer(aTHX_ out, value);
            }
            sv_catpvs(out, "}");
        }
    }
    sv_catpvs(out, "}");
}

static void
Perl_xperl_json_event(pTHX_ SV *out, SV *event)
{
    HV *fields = SvROK(event) && SvTYPE(SvRV(event)) == SVt_PVHV
        ? MUTABLE_HV(SvRV(event)) : NULL;
    if (!fields) {
        sv_catpvs(out, "null");
        return;
    }
    sv_catpvs(out, "{\"file\":");
    Perl_xperl_json_string(aTHX_ out, Perl_xperl_field(aTHX_ fields, "file"));
    sv_catpvs(out, ",\"line\":");
    Perl_xperl_json_integer(aTHX_ out, Perl_xperl_field(aTHX_ fields, "line"));
    sv_catpvs(out, ",\"reason\":");
    Perl_xperl_json_string(aTHX_ out, Perl_xperl_field(aTHX_ fields, "reason"));
    sv_catpvs(out, ",\"message_index\":");
    Perl_xperl_json_integer(aTHX_ out,
                         Perl_xperl_field(aTHX_ fields, "message_index"));
    sv_catpvs(out, "}");
}

static void
Perl_xperl_json_params(pTHX_ SV *out, SV *params, SV *code)
{
    SV *params_ref = sv_2mortal(params ? newSVsv(params) : newSV(0));
    AV *values = SvROK(params_ref) && SvTYPE(SvRV(params_ref)) == SVt_PVAV
        ? MUTABLE_AV(SvRV(params_ref)) : NULL;
    const SSize_t last = values ? av_top_index(values) : -1;
    SSize_t i;
    sv_catpvs(out, "[");
    if (values) {
        for (i = 0; i <= last; i++) {
            SV **svp = av_fetch(values, i, 0);
            SV *item = sv_2mortal(svp ? newSVsv(*svp) : newSV(0));
            HV *fields = SvROK(item) && SvTYPE(SvRV(item)) == SVt_PVHV
                ? MUTABLE_HV(SvRV(item)) : NULL;
            if (i)
                sv_catpvs(out, ",");
            if (!fields) {
                sv_catpvs(out, "null");
                continue;
            }
            SV *name = sv_2mortal(newSVsv(Perl_xperl_field(aTHX_ fields, "name")));
            SV *type = sv_2mortal(newSVsv(Perl_xperl_field(aTHX_ fields, "type")));
            SV *value = sv_2mortal(newSVsv(Perl_xperl_field(aTHX_ fields, "value")));
            SV *domain = Perl_xperl_field(aTHX_ fields, "selector_domain");
            sv_catpvs(out, "{\"name\":");
            Perl_xperl_json_string(aTHX_ out, name);
            sv_catpvs(out, ",\"type\":");
            Perl_xperl_json_string(aTHX_ out, type);
            if (SvOK(domain) && !SvROK(domain) && SvIOK(domain)
                && SvIOK(value) && !SvROK(value)) {
                UV domain_id = SvUV(domain);
                const char *domain_name = domain_id > 0 && domain_id <= 0xffff
                    ? Perl_diag_selector_name(aTHX_ (U16)domain_id, 0)
                    : NULL;
                if (domain_name) {
                    SV *locator = sv_2mortal(newSVsv_nomg(code));
                    sv_catpvs(locator, ".");
                    sv_catsv(locator, name);
                    sv_catpvs(out, ",\"selector_domain\":");
                    Perl_xperl_json_string(aTHX_ out, locator);
                }
            }
            sv_catpvs(out, ",\"value\":");
            Perl_xperl_json_string(aTHX_ out, value);
            sv_catpvs(out, "}");
        }
    }
    sv_catpvs(out, "]");
}

static void
Perl_xperl_json_diagnostic_head(pTHX_ SV *out, HV *fields)
{
    SV *warning_categories = sv_2mortal(newSVsv(
        Perl_xperl_field(aTHX_ fields, "warning_categories")));
    SV *promotion_reason = sv_2mortal(newSVsv(
        Perl_xperl_field(aTHX_ fields, "promotion_reason")));
    sv_catpvs(out, "{\"schema\":\"xperl.diagnostic.v2\",\"code\":");
    Perl_xperl_json_string(aTHX_ out, Perl_xperl_field(aTHX_ fields, "code"));
    sv_catpvs(out, ",\"number\":");
    Perl_xperl_json_integer(aTHX_ out, Perl_xperl_field(aTHX_ fields, "number"));
    sv_catpvs(out, ",\"kind\":");
    Perl_xperl_json_string(aTHX_ out, Perl_xperl_field(aTHX_ fields, "kind"));
    sv_catpvs(out, ",\"severity\":");
    Perl_xperl_json_string(aTHX_ out, Perl_xperl_field(aTHX_ fields, "severity"));
    if (SvOK(promotion_reason)) {
        sv_catpvs(out, ",\"promotion_reason\":");
        Perl_xperl_json_string(aTHX_ out, promotion_reason);
    }
    if (SvOK(warning_categories) && SvROK(warning_categories)
        && SvTYPE(SvRV(warning_categories)) == SVt_PVAV) {
        AV *values = MUTABLE_AV(SvRV(warning_categories));
        const SSize_t last = av_top_index(values);
        SSize_t i;
        sv_catpvs(out, ",\"warning_categories\":[");
        for (i = 0; i <= last; i++) {
            SV **svp = av_fetch(values, i, 0);
            if (i)
                sv_catpvs(out, ",");
            {
                SV *value = sv_2mortal(svp ? newSVsv(*svp) : newSV(0));
                Perl_xperl_json_string(aTHX_ out, value);
            }
        }
        sv_catpvs(out, "]");
    }
    sv_catpvs(out, ",\"selector_key\":");
    Perl_xperl_json_integer(aTHX_ out,
        sv_2mortal(Perl_xperl_selector_key(aTHX_ fields)));
    if (SvTRUE(Perl_xperl_field(aTHX_ fields, "_fatal_warning"))
        || SvTRUE(Perl_xperl_field(aTHX_ fields, "_delivery_fatal")))
        sv_catpvs(out, ",\"fatal\":true");
    if (SvTRUE(Perl_xperl_field(aTHX_ fields, "is_hint")))
        sv_catpvs(out, ",\"is_hint\":true");
    if (SvTRUE(Perl_xperl_field(aTHX_ fields, "has_following_hint")))
        sv_catpvs(out, ",\"has_following_hint\":true");
    if (SvTRUE(Perl_xperl_field(aTHX_ fields, "light"))) {
        sv_catpvs(out, ",\"light\":true");
    }
    if (SvOK(Perl_xperl_field(aTHX_ fields, "context_follows_index"))) {
        sv_catpvs(out, ",\"context_follows_index\":");
        Perl_xperl_json_integer(aTHX_ out,
            Perl_xperl_field(aTHX_ fields, "context_follows_index"));
    }
    sv_catpvs(out, ",\"params\":");
    Perl_xperl_json_params(aTHX_ out,
        Perl_xperl_field(aTHX_ fields, "params"),
        Perl_xperl_field(aTHX_ fields, "code"));
    sv_catpvs(out, ",\"location\":");
    Perl_xperl_json_location(aTHX_ out, Perl_xperl_field(aTHX_ fields, "location"));
    sv_catpvs(out, ",\"contents\":[");
}

/* Keep traversal state in mortal Perl containers so callbacks and croaks cannot
 * leave a heap stack or borrowed diagnostic pointer behind. Each frame owns its
 * node and a finite child range; contents are looked up again before each visit. */
enum {
    perl_xperl_json_frame_node,
    perl_xperl_json_frame_next,
    perl_xperl_json_frame_last
};

static void
Perl_xperl_json_push_diagnostic(pTHX_ SV *out, HV *fields,
                                AV *frames, HV *ancestors)
{
    AV *frame = newAV();
    SV *contents;
    SSize_t last;

    av_push(frames, newRV_noinc(MUTABLE_SV(frame)));
    av_push(frame, newRV_inc(MUTABLE_SV(fields)));
    av_push(frame, newSViv(0));
    if (!hv_store(ancestors, (const char *)&fields, sizeof(fields), newSViv(1), 0))
        croak_no_mem();

    Perl_xperl_json_diagnostic_head(aTHX_ out, fields);
    contents = Perl_xperl_field(aTHX_ fields, "contents");
    last = SvROK(contents) && SvTYPE(SvRV(contents)) == SVt_PVAV
        ? av_top_index(MUTABLE_AV(SvRV(contents))) : -1;
    av_push(frame, newSViv(last));
}

/* Serialize by occurrence, not by unique identity: a shared child belongs in
 * each branch. Only an edge back to an active ancestor is a cycle. Such edges
 * can arise through raw hash edits despite the public append checks. */
static void
Perl_xperl_json_diagnostic(pTHX_ SV *out, HV *fields)
{
    AV *frames = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));
    HV *ancestors = MUTABLE_HV(sv_2mortal(MUTABLE_SV(newHV())));

    Perl_xperl_json_push_diagnostic(aTHX_ out, fields, frames, ancestors);
    while (av_top_index(frames) >= 0) {
        AV *frame = MUTABLE_AV(SvRV(*av_fetch(frames, av_top_index(frames), FALSE)));
        HV *node = MUTABLE_HV(SvRV(*av_fetch(frame, perl_xperl_json_frame_node, FALSE)));
        SV *next_slot = *av_fetch(frame, perl_xperl_json_frame_next, FALSE);
        SSize_t next = SvIV(next_slot);
        SSize_t last = SvIV(*av_fetch(frame, perl_xperl_json_frame_last, FALSE));
        SV *contents;
        SV **child;
        HV *child_fields;

        if (next > last) {
            sv_catpvs(out, "]}");
            (void)hv_delete(ancestors, (const char *)&node, sizeof(node), G_DISCARD);
            SvREFCNT_dec_NN(av_pop(frames));
            continue;
        }
        sv_setiv(next_slot, next + 1);
        if (next)
            sv_catpvs(out, ",");

        contents = sv_2mortal(newSVsv(Perl_xperl_field(aTHX_ node, "contents")));
        if (!SvROK(contents) || SvTYPE(SvRV(contents)) != SVt_PVAV) {
            sv_catpvs(out, "null");
            continue;
        }
        child = av_fetch(MUTABLE_AV(SvRV(contents)), next, FALSE);
        if (!child || !SvROK(*child) || SvTYPE(SvRV(*child)) != SVt_PVHV) {
            sv_catpvs(out, "null");
            continue;
        }
        child_fields = MUTABLE_HV(SvRV(*child));
        if (hv_exists(ancestors, (const char *)&child_fields, sizeof(child_fields))) {
            sv_catpvs(out, "null");
            continue;
        }
        Perl_xperl_json_push_diagnostic(aTHX_ out, child_fields, frames, ancestors);
    }
}

static void
Perl_xperl_json_exception(pTHX_ SV *out, HV *fields)
{
    SV *messages = Perl_xperl_field(aTHX_ fields, "contents");
    AV *diagnostics = SvROK(messages) && SvTYPE(SvRV(messages)) == SVt_PVAV
        ? MUTABLE_AV(SvRV(messages)) : NULL;
    SV *kind = Perl_xperl_exception_state(aTHX_ fields, "kind");
    SV *severity = Perl_xperl_exception_state(aTHX_ fields, "severity");
    SSize_t i;
    sv_catpvs(out, "{\"schema\":\"xperl.exception.v2\",\"kind\":");
    Perl_xperl_json_string(aTHX_ out, kind);
    sv_catpvs(out, ",\"severity\":");
    Perl_xperl_json_string(aTHX_ out, severity);
    sv_catpvs(out, ",\"contents\":[");
    if (diagnostics) {
        for (i = 0; i <= av_top_index(diagnostics); i++) {
            SV **svp = av_fetch(diagnostics, i, 0);
            SV *item = svp ? *svp : &PL_sv_undef;
            if (i)
                sv_catpvs(out, ",");
            if (SvROK(item) && SvTYPE(SvRV(item)) == SVt_PVHV)
                Perl_xperl_json_diagnostic(aTHX_ out,
                    MUTABLE_HV(SvRV(item)));
            else
                sv_catpvs(out, "null");
        }
    }
    sv_catpvs(out, "],\"origin\":");
    Perl_xperl_json_event(aTHX_ out, Perl_xperl_field(aTHX_ fields, "origin"));
    sv_catpvs(out, "}");
    SvREFCNT_dec_NN(kind);
    SvREFCNT_dec_NN(severity);
}

XS(Perl_XPerl_Diagnostic_as_json);
XS(Perl_XPerl_Diagnostic_as_json)
{
    dXSARGS;
    HV *fields;
    SV *json;
    if (items != 1)
        croak_xs_usage(cv, "self");
    fields = Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::Diagnostic");
    json = sv_2mortal(newSVpvs(""));
    Perl_xperl_json_diagnostic(aTHX_ json, fields);
    ST(0) = json;
    XSRETURN(1);
}

XS(Perl_XPerl_Exception_as_json);
XS(Perl_XPerl_Exception_as_json)
{
    dXSARGS;
    HV *fields;
    SV *json;
    if (items != 1)
        croak_xs_usage(cv, "self");
    fields = Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::Exception");
    json = sv_2mortal(newSVpvs(""));
    Perl_xperl_json_exception(aTHX_ json, fields);
    ST(0) = json;
    XSRETURN(1);
}

static SV *
Perl_xperl_named_param(pTHX_ HV *diagnostic, const char *name)
{
    SV *params = Perl_xperl_field(aTHX_ diagnostic, "params");
    AV *param_array;
    SSize_t i;

    if (!SvROK(params) || SvTYPE(SvRV(params)) != SVt_PVAV)
        return &PL_sv_undef;
    param_array = MUTABLE_AV(SvRV(params));
    for (i = 0; i <= av_top_index(param_array); i++) {
        SV **item = av_fetch(param_array, i, 0);
        HV *param;
        SV *param_name;

        if (!item || !SvROK(*item) || SvTYPE(SvRV(*item)) != SVt_PVHV)
            continue;
        param = MUTABLE_HV(SvRV(*item));
        param_name = Perl_xperl_field(aTHX_ param, "name");
        if (SvOK(param_name) && !SvROK(param_name)
            && strEQ(SvPV_nolen(param_name), name))
            return Perl_xperl_field(aTHX_ param, "value");
    }
    return &PL_sv_undef;
}

static SV *
Perl_xperl_legacy_from_diagnostics(pTHX_ SV *object, HV *fields,
                                const char *language,
                                bool explicit_language)
{
    SV *messages = Perl_xperl_field(aTHX_ fields, "contents");
    AV *diagnostics;
    SV *result;
    SSize_t i;
    SSize_t last_diagnostic_index = 0;
    bool found = FALSE;
    HV *last_diagnostic = NULL;
    SV *last_diagnostic_ref = NULL;
    bool last_has_location = FALSE;
    SV *pending_propagated_error = NULL;
    SV *render_context_ref;
    HV *render_context;

    if (!SvROK(messages) || SvTYPE(SvRV(messages)) != SVt_PVAV)
        return NULL;

    result = newSVpvs("");
    render_context_ref = sv_2mortal(newRV_noinc(MUTABLE_SV(newHV())));
    render_context = MUTABLE_HV(SvRV(render_context_ref));
    Perl_xperl_render_context_set_explicit(render_context,
                                           explicit_language);
    Perl_xperl_render_context_set(aTHX_ render_context, object, 0);
    for (i = 0;; i++) {
        SV *item_ref;
        SV *item;
        SV *presentation_ref = NULL;
        SV **item_slot;
        HV *diagnostic;
        SV *code;
        SV *number;
        SV *kind;
        SV *text;
        SV *grouped_hint_ref = NULL;
        HV *grouped_hint = NULL;
        bool is_require_compilation_failed;
        bool attach_compile_location;
        bool attach_pattern_location;
        bool legacy_raw;
        bool fatalized_presentation = FALSE;

        messages = Perl_xperl_field(aTHX_ fields, "contents");
        if (!SvROK(messages) || SvTYPE(SvRV(messages)) != SVt_PVAV)
            break;
        diagnostics = MUTABLE_AV(SvRV(messages));
        if (i > av_top_index(diagnostics))
            break;
        item_slot = av_fetch(diagnostics, i, FALSE);
        item_ref = item_slot ? newSVsv(*item_slot) : NULL;
        item = item_ref ? item_ref : &PL_sv_undef;
        diagnostic = SvROK(item) && SvTYPE(SvRV(item)) == SVt_PVHV
            ? MUTABLE_HV(SvRV(item)) : NULL;
        Perl_xperl_render_context_set(aTHX_ render_context, object, i);

        if (!diagnostic)
            goto next_diagnostic;
        if (SvTRUE(Perl_xperl_field(aTHX_ fields,
                                 "suppress_delivered_warnings"))
            && SvTRUE(Perl_xperl_field(aTHX_ diagnostic,
                                    "_warning_delivered")))
            goto next_diagnostic;
        code = Perl_xperl_field(aTHX_ diagnostic, "code");
        number = Perl_xperl_field(aTHX_ diagnostic, "number");
        kind = Perl_xperl_field(aTHX_ diagnostic, "kind");
        if (SvOK(number) && !SvROK(number)
            && SvUV(number) == perl_diag_error_fatalized_warning_wrapper_number) {
            SV *contents = Perl_xperl_field(aTHX_ diagnostic, "contents");
            AV *child_array = SvROK(contents)
                && SvTYPE(SvRV(contents)) == SVt_PVAV
                ? MUTABLE_AV(SvRV(contents)) : NULL;
            SV **child_slot = child_array ? av_fetch(child_array, 0, FALSE)
                : NULL;
            HV *child_fields = child_slot && SvROK(*child_slot)
                && SvTYPE(SvRV(*child_slot)) == SVt_PVHV
                ? MUTABLE_HV(SvRV(*child_slot)) : NULL;
            SV *child_kind = child_fields
                ? Perl_xperl_field(aTHX_ child_fields, "kind")
                : &PL_sv_undef;

            /* Compile warnings need their parser context and legacy layout.
             * Keep the wrapper in the tree and render its child for display. */
            if (child_fields) {
                presentation_ref = newSVsv(*child_slot);
                child_fields = MUTABLE_HV(SvRV(presentation_ref));
                diagnostic = child_fields;
                code = Perl_xperl_field(aTHX_ diagnostic, "code");
                number = Perl_xperl_field(aTHX_ diagnostic, "number");
                kind = child_kind;
                fatalized_presentation = TRUE;
            }
        }
        legacy_raw = SvTRUE(Perl_xperl_field(aTHX_ diagnostic, "legacy_raw"));
        is_require_compilation_failed =
            SvOK(number) && !SvROK(number) && SvUV(number) == 1721;
        attach_compile_location =
            ((SvOK(kind) && !SvROK(kind)
              && strEQ(SvPV_nolen(kind), "CORE_COMPILE"))
             || (SvOK(code) && !SvROK(code)
                 && (strEQ(SvPV_nolen(code),
                           "WARNING_SYNTAX_AMBIGUOUS_REGEXP_BACKSLASH_VARIABLE_INTERPOLATION")
                     || strEQ(SvPV_nolen(code),
                              "WARNING_SYNTAX_CONTROL_ESCAPE_PRINTABLE_RESULT")
                     || strEQ(SvPV_nolen(code),
                              "ERROR_SYNTAX_QUOTED_STRING_TERMINATOR_MISSING")
                     || strEQ(SvPV_nolen(code),
                              "ERROR_IO_LAYER_MODULE_LOAD_REENTRY")
                     || strEQ(SvPV_nolen(code),
                              "ERROR_PHASE_BEGIN_UNSAFE_AFTER_COMPILATION_ERRORS")))
             )
            && !(SvOK(code) && !SvROK(code)
                 && (strEQ(SvPV_nolen(code),
                           "ERROR_COMPILATION_EXECUTION_ABORTED")
                     || strEQ(SvPV_nolen(code),
                              "WARNING_SYNTAX_RUNAWAY_MULTILINE_STRING_SUGGESTION")
                     || strEQ(SvPV_nolen(code),
                              "ERROR_PHASE_BEGIN_FAILED")));
        if (fatalized_presentation)
            attach_compile_location = TRUE;
        if (SvTRUE(Perl_xperl_field(aTHX_ diagnostic,
                                    "has_following_hint"))
            && i < av_top_index(diagnostics)) {
            SV **hint_slot = av_fetch(diagnostics, i + 1, FALSE);
            SV *hint_ref = hint_slot ? newSVsv(*hint_slot) : NULL;

            if (hint_ref && SvROK(hint_ref)
                && SvTYPE(SvRV(hint_ref)) == SVt_PVHV
                && Perl_xperl_hint_matches_previous(aTHX_ diagnostic,
                    MUTABLE_HV(SvRV(hint_ref)))) {
                grouped_hint_ref = hint_ref;
                grouped_hint = MUTABLE_HV(SvRV(hint_ref));
            }
            else if (hint_ref)
                SvREFCNT_dec_NN(hint_ref);
        }
        {
            SV *pattern_context = Perl_xperl_field(aTHX_ diagnostic,
                                                "pattern_context");
            attach_pattern_location =
                (SvROK(pattern_context)
                 && SvTYPE(SvRV(pattern_context)) == SVt_PVHV)
                || (SvOK(Perl_xperl_named_param(aTHX_ diagnostic, "before"))
                    && SvOK(Perl_xperl_named_param(aTHX_ diagnostic, "after")));
        }
        if (found && SvOK(code) && !SvROK(code)
            && strEQ(SvPV_nolen(code), "ERROR_COMPILATION_FAILED"))
            goto next_diagnostic;
        if (SvOK(code) && !SvROK(code)
            && (strEQ(SvPV_nolen(code),
                      "ERROR_UNICODE_PROPERTY_CONTEXT_INVALID_DEFINITION_AT_PATTERN")
                || strEQ(SvPV_nolen(code),
                         "ERROR_UNICODE_CHARACTER_NAME_FAILURE_AT_PATTERN")))
        {
            SV *contents = Perl_xperl_field(aTHX_ diagnostic, "contents");
            AV *child_array = SvROK(contents)
                && SvTYPE(SvRV(contents)) == SVt_PVAV
                ? MUTABLE_AV(SvRV(contents)) : NULL;
            const bool has_nested_context = child_array
                && av_top_index(child_array) >= 0;
            SV *before = Perl_xperl_named_param(aTHX_ diagnostic, "before");
            SV *after = Perl_xperl_named_param(aTHX_ diagnostic, "after");
            SV *location = Perl_xperl_field(aTHX_ diagnostic, "location");

            if (!found && !has_nested_context)
                goto render_context_diagnostic_normally;
            if (has_nested_context) {
                SSize_t child_index;
                for (child_index = 0;
                     child_index <= av_top_index(child_array); child_index++) {
                    SV **child_slot = av_fetch(child_array, child_index, FALSE);
                    HV *child_hv = child_slot && SvROK(*child_slot)
                        && SvTYPE(SvRV(*child_slot)) == SVt_PVHV
                        ? MUTABLE_HV(SvRV(*child_slot)) : NULL;
                    SV *child_text;

                    if (!child_hv)
                        continue;
                    child_text = Perl_xperl_render_diagnostic_legacy(aTHX_
                        child_hv, language, render_context);
                    if (child_text) {
                        STRLEN child_length;
                        const char *child_bytes = SvPV(child_text,
                                                       child_length);
                        if (child_length && child_bytes[0] == ' '
                            && SvCUR(result)
                            && SvEND(result)[-1] == '\n')
                            SvCUR_set(result, SvCUR(result) - 1);
                        sv_catsv(result, child_text);
                        SvREFCNT_dec_NN(child_text);
                    }
                }
            }
            if (SvCUR(result) && SvEND(result)[-1] == '\n')
                sv_setpvn(result, SvPVX(result), SvCUR(result) - 1);
            const perl_diagpack_engine *engine =
                Perl_xperl_render_engine(aTHX_ diagnostic, render_context);
            SV *wrapped = engine
                ? Perl_xperl_render_format_engine(aTHX_ engine,
                    perl_diag_error_regexp_message_at_location_idx, 3,
                    result, before, after)
                : Perl_xperl_render_format(aTHX_
                    perl_diag_error_regexp_message_at_location_idx, language, 3,
                    result, before, after);
            sv_setsv(result, wrapped);
            SvREFCNT_dec_NN(wrapped);
            if (SvROK(location) && SvTYPE(SvRV(location)) == SVt_PVHV) {
                HV *loc_hv = MUTABLE_HV(SvRV(location));
                SV *file = Perl_xperl_field(aTHX_ loc_hv, "file");
                SV *line = Perl_xperl_field(aTHX_ loc_hv, "line");
                if (SvOK(file) && SvOK(line)) {
                    Perl_xperl_append_source_location_engine(aTHX_
                        Perl_xperl_render_engine(aTHX_ diagnostic,
                                                 render_context),
                        result, file, line, language);
                        sv_catpvs(result, ".\n");
                }
            }
            if (last_diagnostic_ref)
                SvREFCNT_dec_NN(last_diagnostic_ref);
            last_diagnostic_ref = item_ref ? newSVsv(item_ref) : NULL;
            last_diagnostic = diagnostic;
            last_diagnostic_index = i;
            last_has_location = TRUE;
            found = TRUE;
            goto next_diagnostic;
        }
render_context_diagnostic_normally:
        if (SvOK(code) && !SvROK(code)
            && (strEQ(SvPV_nolen(code), "ERROR_CALL_BINDING_NAMED_PARAMETER_REQUIRED_NAME_MISSING")
                || strEQ(SvPV_nolen(code), "ERROR_CALL_BINDING_NAMED_PARAMETER_UNKNOWN_NAME")))
        {
            const bool missing = strEQ(SvPV_nolen(code),
                                       "ERROR_CALL_BINDING_NAMED_PARAMETER_REQUIRED_NAME_MISSING");
            SV *group_code = sv_2mortal(newSVsv(code));
            const char *code_text = SvPV_nolen(group_code);
            SV *function = sv_2mortal(newSVsv(
                Perl_xperl_named_param(aTHX_ diagnostic, "function")));
            SV *names = newSVpvs("");
            SV *child_list = Perl_xperl_field(aTHX_ diagnostic, "contents");
            AV *nested_contents = SvROK(child_list)
                && SvTYPE(SvRV(child_list)) == SVt_PVAV
                ? MUTABLE_AV(SvRV(child_list)) : NULL;
            SSize_t j;
            UV count = 0;
            bool omitted = FALSE;

            if (nested_contents && av_top_index(nested_contents) >= 0) {
                SV *parameter = Perl_xperl_named_param(aTHX_ diagnostic,
                                                       "parameter");
                if (count < 5) {
                    sv_catpvs(names, "'");
                    sv_catsv(names, parameter);
                    sv_catpvs(names, "'");
                }
                count++;
                for (j = 0; j <= av_top_index(nested_contents); j++) {
                    SV **next_slot = av_fetch(nested_contents, j, FALSE);
                    HV *next_hv = next_slot && SvROK(*next_slot)
                        && SvTYPE(SvRV(*next_slot)) == SVt_PVHV
                        ? MUTABLE_HV(SvRV(*next_slot)) : NULL;
                    SV *next_code;
                    SV *next_function;

                    if (!next_hv)
                        continue;
                    next_code = Perl_xperl_field(aTHX_ next_hv, "code");
                    if (SvOK(next_code) && !SvROK(next_code)
                        && strEQ(SvPV_nolen(next_code),
                                 "NOTE_OMISSION_NAMED_PARAMETER_DIAGNOSTICS")) {
                        SV *omitted_count = Perl_xperl_named_param(aTHX_
                            next_hv, "omitted_count");
                        if (SvOK(omitted_count) && !SvROK(omitted_count)) {
                            UV additional = SvUV(omitted_count);
                            count = UV_MAX - count < additional
                                ? UV_MAX : count + additional;
                        }
                        omitted = TRUE;
                        break;
                    }
                    if (!SvOK(next_code) || SvROK(next_code)
                        || !strEQ(SvPV_nolen(next_code), code_text))
                        continue;
                    next_function = Perl_xperl_named_param(aTHX_ next_hv,
                                                            "function");
                    if (!SvOK(function) || !SvOK(next_function)
                        || strNE(SvPV_nolen(function), SvPV_nolen(next_function)))
                        continue;
                    parameter = Perl_xperl_named_param(aTHX_ next_hv,
                                                       "parameter");
                    if (count < 5) {
                        if (count)
                            sv_catpvs(names, ", ");
                        sv_catpvs(names, "'");
                        sv_catsv(names, parameter);
                        sv_catpvs(names, "'");
                    }
                    else
                        omitted = TRUE;
                    count++;
                }
                j = i + 1;
            }
            else for (j = i;; j++) {
                bool in_range;
                SV *next = Perl_xperl_exception_diagnostic_at(aTHX_ object,
                                                            j, &in_range);
                SV *next_ref = next ? sv_2mortal(next) : &PL_sv_undef;
                HV *next_hv = SvROK(next_ref)
                    && SvTYPE(SvRV(next_ref)) == SVt_PVHV
                    ? MUTABLE_HV(SvRV(next_ref)) : NULL;
                SV *next_code;
                SV *next_function;
                SV *parameter;

                if (!in_range || !next_hv)
                    break;
                next_code = Perl_xperl_field(aTHX_ next_hv, "code");
                if (SvOK(next_code) && !SvROK(next_code)
                    && strEQ(SvPV_nolen(next_code),
                             "NOTE_OMISSION_NAMED_PARAMETER_DIAGNOSTICS")) {
                    SV *omitted_count = Perl_xperl_named_param(aTHX_
                        next_hv, "omitted_count");
                    if (SvOK(omitted_count) && !SvROK(omitted_count)) {
                        UV additional = SvUV(omitted_count);
                        count = (UV_MAX - count < additional)
                            ? UV_MAX : count + additional;
                    }
                    omitted = TRUE;
                    j++;
                    break;
                }
                if (!SvOK(next_code) || SvROK(next_code)
                    || !strEQ(SvPV_nolen(next_code), code_text))
                    break;
                next_function = Perl_xperl_named_param(aTHX_ next_hv,
                                                    "function");
                if (!SvOK(function) || !SvOK(next_function)
                    || strNE(SvPV_nolen(function), SvPV_nolen(next_function)))
                    break;
                parameter = Perl_xperl_named_param(aTHX_ next_hv, "parameter");
                if (count < 5) {
                    if (count)
                        sv_catpvs(names, ", ");
                    sv_catpvs(names, "'");
                    sv_catsv(names, parameter);
                    sv_catpvs(names, "'");
                }
                else
                    omitted = TRUE;
                count++;

            }

            if (count) {
                SV *location;
                if (omitted)
                    sv_catpvs(names, ", ...");
                if (found && SvCUR(result)
                    && !isSPACE_A((U8)SvEND(result)[-1]))
                    sv_catpvs(result, " ");
                const perl_diagpack_engine *engine =
                    Perl_xperl_render_engine(aTHX_ diagnostic, render_context);
                SV *summary = engine
                    ? Perl_xperl_render_format_engine(aTHX_ engine,
                        perl_diag_error_call_binding_named_parameter_summary_idx,
                        4, names, function,
                        sv_2mortal(newSVpv(missing ? "missing" : "unknown", 0)),
                        sv_2mortal(newSVuv(count)))
                    : Perl_xperl_render_format(aTHX_
                        perl_diag_error_call_binding_named_parameter_summary_idx,
                        language, 4, names, function,
                        sv_2mortal(newSVpv(missing ? "missing" : "unknown", 0)),
                        sv_2mortal(newSVuv(count)));
                sv_catsv(result, summary);
                SvREFCNT_dec_NN(summary);
                location = Perl_xperl_field(aTHX_ diagnostic, "location");
                if (SvROK(location) && SvTYPE(SvRV(location)) == SVt_PVHV) {
                    HV *loc_hv = MUTABLE_HV(SvRV(location));
                    SV *file = Perl_xperl_field(aTHX_ loc_hv, "file");
                    SV *line = Perl_xperl_field(aTHX_ loc_hv, "line");
                    if (SvOK(file) && SvOK(line)) {
                        Perl_xperl_append_source_location_engine(aTHX_
                            Perl_xperl_render_engine(aTHX_ diagnostic,
                                                     render_context),
                            result, file, line, language);
                        sv_catpvs(result, ".\n");
                    }
                }
                if (last_diagnostic_ref)
                    SvREFCNT_dec_NN(last_diagnostic_ref);
                last_diagnostic_ref = item_ref ? newSVsv(item_ref) : NULL;
                last_diagnostic = diagnostic;
                last_diagnostic_index = i;
                last_has_location = TRUE;
                found = TRUE;
                i = j - 1;
                SvREFCNT_dec_NN(names);
                goto next_diagnostic;
            }
            SvREFCNT_dec_NN(names);
        }
        text = Perl_xperl_render_diagnostic_legacy(aTHX_ diagnostic, language,
                                                render_context);
        if (text && grouped_hint) {
            bool had_newline = SvPOK(text) && SvCUR(text) && SvEND(text)[-1] == '\n';
            if (had_newline)
                sv_setpvn(text, SvPVX(text), SvCUR(text) - 1);
            SV *hint_code = Perl_xperl_field(aTHX_ grouped_hint, "code");
            SV *hint_text = NULL;
            SV *hint_value = &PL_sv_undef;

            if (SvOK(hint_code) && !SvROK(hint_code)
                && strEQ(SvPV_nolen(hint_code),
                         "NOTE_HINT_OPERATOR_EXPECTED_MISSING_OPERATOR"))
                hint_value = Perl_xperl_named_param(aTHX_ grouped_hint,
                                                 "context");
            else if (SvOK(hint_code) && !SvROK(hint_code)
                && strEQ(SvPV_nolen(hint_code),
                         "NOTE_HINT_OPERATOR_EXPECTED_PREDECLARE"))
                hint_value = Perl_xperl_named_param(aTHX_ grouped_hint, "name");

            if (SvOK(hint_value) && SvOK(hint_code) && !SvROK(hint_code)
                && (strEQ(SvPV_nolen(hint_code),
                          "NOTE_HINT_OPERATOR_EXPECTED_MISSING_OPERATOR")
                    || strEQ(SvPV_nolen(hint_code),
                             "NOTE_HINT_OPERATOR_EXPECTED_PREDECLARE"))) {
                const char *hint_kind = strEQ(SvPV_nolen(hint_code),
                    "NOTE_HINT_OPERATOR_EXPECTED_PREDECLARE")
                    ? "predeclare" : "missing_operator";
                const perl_diagpack_engine *hint_engine =
                    Perl_xperl_render_engine(aTHX_ grouped_hint,
                                             render_context);
                hint_text = hint_engine
                    ? Perl_xperl_render_format_engine(aTHX_ hint_engine,
                        perl_diag_note_hint_operator_expected_idx, 2,
                        hint_value, sv_2mortal(newSVpv(hint_kind, 0)))
                    : Perl_xperl_render_format(aTHX_
                        perl_diag_note_hint_operator_expected_idx, language, 2,
                        hint_value, sv_2mortal(newSVpv(hint_kind, 0)));
                sv_catsv(text, hint_text);
            }
            else {
                hint_text = Perl_xperl_render_diagnostic_template(aTHX_
                    grouped_hint, language,
                    Perl_xperl_render_engine(aTHX_ grouped_hint,
                                             render_context));
                if (hint_text) {
                    STRLEN hint_length;
                    const char *hint_pv = SvPV(hint_text, hint_length);

                    while (hint_length
                        && (hint_pv[hint_length - 1] == '\n'
                            || hint_pv[hint_length - 1] == '.'))
                        hint_length--;
                    sv_catpvs(text, " (");
                    sv_catpvn_flags(text, hint_pv, hint_length,
                        SvUTF8(hint_text) ? SVf_UTF8 : 0);
                    sv_catpvs(text, ")");
                }
            }
            if (hint_text)
                SvREFCNT_dec_NN(hint_text);
            if (had_newline)
                sv_catpvs(text, "\n");
        }
        if (text) {
            if (is_require_compilation_failed) {
                SV *location = Perl_xperl_field(aTHX_ diagnostic, "location");
                if (SvROK(location)
                    && SvTYPE(SvRV(location)) == SVt_PVHV) {
                    HV *loc_hv = MUTABLE_HV(SvRV(location));
                    SV *file = Perl_xperl_field(aTHX_ loc_hv, "file");
                    SV *line = Perl_xperl_field(aTHX_ loc_hv, "line");
                    if (SvOK(file) && SvOK(line) && SvIV(line) > 0) {
                        Perl_xperl_append_source_location_engine(aTHX_
                            Perl_xperl_render_engine(aTHX_ diagnostic,
                                                     render_context),
                            text, file, line, language);
                        sv_catpvs(text, ".\n");
                    }
                }
            }
            if (found && SvOK(code) && !SvROK(code)
                && strEQ(SvPV_nolen(code), "ERROR_PROPAGATION_EVAL_CONTEXT")) {
                SV *location = Perl_xperl_field(aTHX_ diagnostic, "location");
                SV *parser_context = SvROK(location)
                    && SvTYPE(SvRV(location)) == SVt_PVHV
                    ? Perl_xperl_field(aTHX_ MUTABLE_HV(SvRV(location)),
                                    "parser_context")
                    : &PL_sv_undef;

                if (SvOK(parser_context)
                    && SvROK(location)
                    && SvTYPE(SvRV(location)) == SVt_PVHV) {
                    HV *loc_hv = MUTABLE_HV(SvRV(location));
                    SV *file = Perl_xperl_field(aTHX_ loc_hv, "file");
                    SV *line = Perl_xperl_field(aTHX_ loc_hv, "line");

                    if (SvOK(file) && SvOK(line) && SvCUR(result)
                        && SvEND(result)[-1] != '\n') {
                        Perl_xperl_append_source_location_engine(aTHX_
                            Perl_xperl_render_engine(aTHX_ diagnostic,
                                                     render_context),
                            result, file, line, language);
                        sv_catpvs(result, ".\n");
                    }
                }
            }
            if (SvOK(code) && !SvROK(code)
                && strEQ(SvPV_nolen(code), "ERROR_PROPAGATION_EVAL_ERROR_TEXT")) {
                if (pending_propagated_error)
                    SvREFCNT_dec_NN(pending_propagated_error);
                pending_propagated_error = text;
                goto next_diagnostic;
            }
            if (pending_propagated_error && SvOK(code) && !SvROK(code)
                && strEQ(SvPV_nolen(code), "ERROR_PROPAGATION_EVAL_CONTEXT")) {
                STRLEN error_len;
                const char *error_text = SvPV(pending_propagated_error,
                                              error_len);
                const char *newline = (const char *)memchr(error_text, '\n',
                                                            error_len);
                if (found && SvCUR(result)) {
                    if (SvCUR(result)
                        && !isSPACE_A((U8)SvEND(result)[-1])
                        && error_len && !isSPACE_A((U8)error_text[0]))
                        sv_catpvs(result, "\n");
                }
                if (newline) {
                    const STRLEN first_line_len = newline - error_text + 1;
                    sv_catpvn(result, error_text, first_line_len);
                    sv_catsv(result, text);
                    sv_catpvn(result, newline + 1,
                              error_len - first_line_len);
                }
                else {
                    sv_catsv(result, pending_propagated_error);
                    sv_catsv(result, text);
                }
                SvREFCNT_dec_NN(pending_propagated_error);
                pending_propagated_error = NULL;
                if (last_diagnostic_ref)
                    SvREFCNT_dec_NN(last_diagnostic_ref);
                last_diagnostic_ref = item_ref ? newSVsv(item_ref) : NULL;
                last_diagnostic = diagnostic;
                last_diagnostic_index = i;
                last_has_location = TRUE;
                found = TRUE;
                SvREFCNT_dec_NN(text);
                goto next_diagnostic;
            }
            if (found && last_diagnostic && !last_has_location
                && !SvTRUE(Perl_xperl_field(aTHX_ last_diagnostic,
                                         "legacy_raw"))
                && SvOK(code) && !SvROK(code)
                && (strEQ(SvPV_nolen(code), "ERROR_PHASE_BEGIN_FAILED")
                    || strEQ(SvPV_nolen(code), "ERROR_PHASE_CALL_QUEUE_ABORTED")))
            {
                SV *location = Perl_xperl_field(aTHX_ last_diagnostic,
                                             "location");
                if (SvROK(location)
                    && SvTYPE(SvRV(location)) == SVt_PVHV) {
                    HV *loc_hv = MUTABLE_HV(SvRV(location));
                    SV *file = Perl_xperl_field(aTHX_ loc_hv, "file");
                    SV *line = Perl_xperl_field(aTHX_ loc_hv, "line");
                    if (SvOK(file) && SvOK(line)) {
                        SV *last_text = text ? text : &PL_sv_undef;
                        SV *last_code = Perl_xperl_field(aTHX_
                            last_diagnostic, "code");
                        if (SvOK(last_code) && !SvROK(last_code)
                            && strEQ(SvPV_nolen(last_code), "ERROR_USER_TEXT"))
                            last_text = Perl_xperl_named_param(aTHX_
                                last_diagnostic, "text");
                        STRLEN message_len = 0;
                        const char *message = SvOK(last_text)
                            ? SvPV(last_text, message_len) : "";
                        const bool explicit_newline = message_len
                            && message[message_len - 1] == '\n'
                            && !(message_len == 5
                                 && memEQ(message, "Died\n", 5));
                        bool already_has_location = explicit_newline;
                        if (already_has_location) {
                            last_has_location = TRUE;
                        }
                        else {
                            if (SvCUR(result)
                                && SvEND(result)[-1] == '\n')
                                sv_setpvn(result, SvPVX(result),
                                          SvCUR(result) - 1);
                            if (SvIV(line) == 0)
                                sv_catpvs(result, ".\n");
                            else {
                                Perl_xperl_append_source_location_engine(aTHX_
                                    Perl_xperl_render_engine(aTHX_
                                        last_diagnostic, render_context),
                                    result, file, line, language);
                                sv_catpvs(result, ".\n");
                            }
                            last_has_location = TRUE;
                        }
                    }
                }
            }
            if (found && last_diagnostic && !last_has_location
                && !SvTRUE(Perl_xperl_field(aTHX_ last_diagnostic,
                                         "legacy_raw"))
                && SvOK(code) && !SvROK(code)
                && strEQ(SvPV_nolen(code), "ERROR_PROPAGATION_RETHROW_CONTEXT")) {
                SV *location = Perl_xperl_field(aTHX_ last_diagnostic,
                                             "location");
                if (SvROK(location) && SvTYPE(SvRV(location)) == SVt_PVHV) {
                    HV *loc_hv = MUTABLE_HV(SvRV(location));
                    SV *file = Perl_xperl_field(aTHX_ loc_hv, "file");
                    SV *line = Perl_xperl_field(aTHX_ loc_hv, "line");

                    if (SvOK(file) && SvOK(line) && SvIV(line) > 0
                        && SvCUR(file) && SvCUR(result)
                        && SvEND(result)[-1] != '\n') {
                        SV *location_text = Perl_xperl_source_location_engine(
                            aTHX_ Perl_xperl_render_engine(aTHX_ last_diagnostic,
                                                           render_context),
                            file, line, language);
                        STRLEN result_len;
                        const char *result_pv = SvPV(result, result_len);
                        if (!ninstr(result_pv, result_pv + result_len,
                                    SvPVX(location_text),
                                    SvPVX(location_text)
                                        + SvCUR(location_text))) {
                            sv_catsv(result, location_text);
                            sv_catpvs(result, ".\n");
                        }
                        SvREFCNT_dec_NN(location_text);
                    }
                }
            }
            if (found && SvCUR(result)) {
                STRLEN text_len;
                const char *text_pv = SvPV(text, text_len);
                if (text_len && text_pv[0] == ' '
                    && SvEND(result)[-1] == '\n'
                    && !(SvOK(code) && !SvROK(code)
                         && strEQ(SvPV_nolen(code),
                                  "WARNING_SYNTAX_RUNAWAY_MULTILINE_STRING_SUGGESTION")))
                    sv_setpvn(result, SvPVX(result), SvCUR(result) - 1);
                if (SvCUR(result)
                    && !isSPACE_A((U8)SvEND(result)[-1])
                    && text_len && !isSPACE_A((U8)text_pv[0]))
                    sv_catpvs(result, "\n");
            }
            last_has_location = FALSE;
            sv_catsv(result, text);
            if (is_require_compilation_failed)
                last_has_location = TRUE;
            if (!legacy_raw
                && (attach_compile_location || attach_pattern_location)) {
                SV *location = Perl_xperl_field(aTHX_ diagnostic, "location");
                if (SvROK(location) && SvTYPE(SvRV(location)) == SVt_PVHV) {
                    HV *loc_hv = MUTABLE_HV(SvRV(location));
                    SV *file = Perl_xperl_field(aTHX_ loc_hv, "file");
                    SV *line = Perl_xperl_field(aTHX_ loc_hv, "line");
                    SV *parser_context = Perl_xperl_field(aTHX_ loc_hv,
                                                       "parser_context");
                    SV *parser_context_value = Perl_xperl_field(aTHX_ loc_hv,
                                                       "parser_context_value");
                    bool has_context_followup =
                        Perl_xperl_diagnostic_has_context_followup(aTHX_
                            diagnostic, render_context);

                    if ((!SvOK(parser_context) || SvROK(parser_context))
                        && SvOK(code) && !SvROK(code)
                        && strEQ(SvPV_nolen(code), "ERROR_SYNTAX_INVALID")
                        && i < av_top_index(diagnostics)) {
                        SV **next_slot = av_fetch(diagnostics, i + 1, 0);
                        SV *next = next_slot ? *next_slot : &PL_sv_undef;
                        HV *next_hv = SvROK(next)
                            && SvTYPE(SvRV(next)) == SVt_PVHV
                            ? MUTABLE_HV(SvRV(next)) : NULL;

                        if (next_hv) {
                            SV *next_code = Perl_xperl_field(aTHX_ next_hv,
                                                          "code");
                            SV *next_location = Perl_xperl_field(aTHX_ next_hv,
                                                              "location");
                            if (SvOK(next_code) && !SvROK(next_code)
                                && strEQ(SvPV_nolen(next_code),
                                         "WARNING_SYNTAX_RUNAWAY_MULTILINE_STRING_SUGGESTION")
                                && SvROK(next_location)
                                && SvTYPE(SvRV(next_location)) == SVt_PVHV) {
                                HV *next_loc_hv =
                                    MUTABLE_HV(SvRV(next_location));
                                parser_context = Perl_xperl_field(aTHX_
                                    next_loc_hv, "parser_context");
                                parser_context_value = Perl_xperl_field(aTHX_
                                    next_loc_hv, "parser_context_value");
                            }
                        }
                    }
                    if (!has_context_followup
                        && SvOK(file) && SvOK(line) && SvIV(line) > 0
                        && SvCUR(file)) {
                        SV *location_text = Perl_xperl_source_location_engine(
                            aTHX_ Perl_xperl_render_engine(aTHX_ diagnostic,
                                                           render_context),
                            file, line, language);
                        STRLEN text_len;
                        const char *text_pv = SvPV(text, text_len);
                        if (!ninstr(text_pv, text_pv + text_len,
                                    SvPVX(location_text), SvPVX(location_text)
                                    + SvCUR(location_text))) {
                            if (SvCUR(result) && SvEND(result)[-1] == '\n')
                                sv_setpvn(result, SvPVX(result),
                                          SvCUR(result) - 1);
                            if (SvOK(kind) && !SvROK(kind)
                                && strEQ(SvPV_nolen(kind), "CORE_COMPILE")) {
                                const perl_diagpack_engine *engine =
                                    Perl_xperl_render_engine(aTHX_ diagnostic,
                                                             render_context);
                                SV *clause = engine
                                    ? Perl_xperl_render_format_engine(aTHX_ engine,
                                        perl_diag_note_context_location_idx, 5,
                                        file, sv_2mortal(newSViv(SvIV(line))),
                                        SvOK(parser_context_value)
                                            ? parser_context_value : &PL_sv_no,
                                        SvOK(parser_context) && !SvROK(parser_context)
                                            ? parser_context
                                            : sv_2mortal(newSVpvs("plain")),
                                        sv_2mortal(newSVpvs("parser")))
                                    : Perl_xperl_render_format(aTHX_
                                        perl_diag_note_context_location_idx,
                                        language, 5,
                                        file, sv_2mortal(newSViv(SvIV(line))),
                                        SvOK(parser_context_value)
                                            ? parser_context_value : &PL_sv_no,
                                        SvOK(parser_context) && !SvROK(parser_context)
                                            ? parser_context
                                            : sv_2mortal(newSVpvs("plain")),
                                        sv_2mortal(newSVpvs("parser")));
                                sv_catsv(result, clause);
                                SvREFCNT_dec_NN(clause);
                            }
                            else {
                                sv_catsv(result, location_text);
                                sv_catpvs(result, ".\n");
                            }

                        }
                        else if (!SvCUR(result)
                                 || SvEND(result)[-1] != '\n') {
                            sv_catpvs(result, "\n");
                        }
                        SvREFCNT_dec_NN(location_text);
                        last_has_location = TRUE;
                    }
                }
            }
            if (SvOK(code) && !SvROK(code)
                && strEQ(SvPV_nolen(code), "ERROR_PHASE_CALL_QUEUE_ABORTED"))
                sv_catpvs(result, ".\n");
            if (last_diagnostic_ref)
                SvREFCNT_dec_NN(last_diagnostic_ref);
            last_diagnostic_ref = item_ref ? newSVsv(item_ref) : NULL;
            last_diagnostic = diagnostic;
            last_diagnostic_index = i;
            if (SvOK(code) && !SvROK(code)
                && strEQ(SvPV_nolen(code),
                         "ERROR_COMPILATION_EXECUTION_ABORTED"))
                last_has_location = TRUE;
            if (SvOK(code) && !SvROK(code)
                && strEQ(SvPV_nolen(code), "ERROR_PHASE_BEGIN_FAILED")) {
                SV *location = Perl_xperl_field(aTHX_ diagnostic, "location");
                if (SvROK(location) && SvTYPE(SvRV(location)) == SVt_PVHV) {
                    HV *loc_hv = MUTABLE_HV(SvRV(location));
                    SV *file = Perl_xperl_field(aTHX_ loc_hv, "file");
                    SV *line = Perl_xperl_field(aTHX_ loc_hv, "line");
                    if (SvOK(file) && SvOK(line)) {
                                Perl_xperl_append_source_location_engine(aTHX_
                                    Perl_xperl_render_engine(aTHX_
                                        last_diagnostic, render_context),
                                    result, file, line, language);
                        sv_catpvs(result, ".\n");
                        last_has_location = TRUE;
                    }
                }
            }
            found = TRUE;
        }
        if (text)
            SvREFCNT_dec_NN(text);
      next_diagnostic:
        if (presentation_ref)
            SvREFCNT_dec_NN(presentation_ref);
        if (grouped_hint_ref) {
            i++;
            SvREFCNT_dec_NN(grouped_hint_ref);
        }
        if (item_ref)
            SvREFCNT_dec_NN(item_ref);
    }

    if (pending_propagated_error) {
        sv_catsv(result, pending_propagated_error);
        SvREFCNT_dec_NN(pending_propagated_error);
    }

    if (!found) {
        SvREFCNT_dec_NN(result);
        if (last_diagnostic_ref)
            SvREFCNT_dec_NN(last_diagnostic_ref);
        return NULL;
    }
    if (last_diagnostic && !last_has_location
        && !SvTRUE(Perl_xperl_field(aTHX_ last_diagnostic, "legacy_raw"))) {
        SV *code = Perl_xperl_field(aTHX_ last_diagnostic, "code");
        SV *location = Perl_xperl_field(aTHX_ last_diagnostic, "location");
        if ((!SvOK(code) || SvROK(code)
             || strNE(SvPV_nolen(code), "ERROR_USER_REFERENCE"))
            && SvROK(location)
            && SvTYPE(SvRV(location)) == SVt_PVHV
            && (!SvCUR(result) || SvEND(result)[-1] != '\n')) {
            HV *loc_hv = MUTABLE_HV(SvRV(location));
            SV *file = Perl_xperl_field(aTHX_ loc_hv, "file");
            SV *line = Perl_xperl_field(aTHX_ loc_hv, "line");
            if (SvOK(file) && SvOK(line) && SvIV(line) == 0) {
                sv_catpvs(result, ".\n");
            }
            else if (SvOK(file) && SvOK(line)) {
                SV *location_text = Perl_xperl_source_location_engine(aTHX_
                    Perl_xperl_render_engine(aTHX_ last_diagnostic,
                                             render_context),
                    file, line, language);
                bool has_location;
                bool has_io = FALSE;
                SV *io_text = NULL;
                bool line_mode = FALSE;
                bool have_io = FALSE;
                {
                    SV *last_text;
                    Perl_xperl_render_context_set(aTHX_ render_context, object,
                                               last_diagnostic_index);
                    last_text = Perl_xperl_render_diagnostic_legacy(
                        aTHX_ last_diagnostic, language, render_context);
                    const char *last_message = last_text
                        ? SvPV_nolen(last_text) : "";
                    has_location = strstr(last_message,
                                          SvPV_nolen(location_text)) != NULL;
                    if (!has_location)
                        has_location = strstr(SvPV_nolen(result),
                                              SvPV_nolen(location_text))
                            != NULL;
                    if (last_text)
                        SvREFCNT_dec_NN(last_text);
                }
                /* Match mess_sv(), which adds the active input handle's
                 * line or chunk information to legacy error strings. */
                if (GvIO(PL_last_in_gv)
                    && SvTYPE(GvIOp(PL_last_in_gv)) == SVt_PVIO
                    && IoLINES(GvIOp(PL_last_in_gv))) {
                    STRLEN l;
                    line_mode = (RsSIMPLE(PL_rs)
                        && *SvPV_const(PL_rs, l) == '\n' && l == 1);
                    have_io = TRUE;
                    const perl_diagpack_engine *engine =
                        Perl_xperl_render_engine(aTHX_ last_diagnostic,
                                                 render_context);
                    io_text = engine
                        ? Perl_xperl_render_format_engine(aTHX_ engine,
                            perl_diag_note_context_input_location_idx, 3,
                            PL_last_in_gv == PL_argvgv ? &PL_sv_no
                                : newSVhek_mortal(GvNAME_HEK(PL_last_in_gv)),
                            sv_2mortal(newSViv((IV)IoLINES(GvIOp(PL_last_in_gv)))),
                            sv_2mortal(newSVpv(line_mode ? "line" : "chunk", 0)))
                        : Perl_xperl_render_format(aTHX_
                            perl_diag_note_context_input_location_idx,
                            language, 3,
                            PL_last_in_gv == PL_argvgv ? &PL_sv_no
                                : newSVhek_mortal(GvNAME_HEK(PL_last_in_gv)),
                            sv_2mortal(newSViv((IV)IoLINES(GvIOp(PL_last_in_gv)))),
                            sv_2mortal(newSVpv(line_mode ? "line" : "chunk", 0)));
                    has_io = strstr(SvPV_nolen(result),
                                    SvPV_nolen(io_text)) != NULL;
                }
                if (!has_location || (have_io && !has_io)) {
                    if (SvCUR(result) && SvEND(result)[-1] == '\n')
                        sv_setpvn(result, SvPVX(result), SvCUR(result) - 1);
                    if (has_location && SvCUR(result)
                        && SvEND(result)[-1] == '.')
                        sv_setpvn(result, SvPVX(result), SvCUR(result) - 1);
                    if (!has_location)
                        sv_catsv(result, location_text);
                    if (have_io)
                        sv_catsv(result, io_text);
                    sv_catpvs(result, ".\n");
                }
                SvREFCNT_dec_NN(location_text);
                if (io_text)
                    SvREFCNT_dec_NN(io_text);
            }
        }
    }
    if (last_diagnostic_ref)
        SvREFCNT_dec_NN(last_diagnostic_ref);
    if (PL_phase == PERL_PHASE_DESTRUCT && SvCUR(result)) {
        if (SvEND(result)[-1] == '\n')
            sv_setpvn(result, SvPVX(result), SvCUR(result) - 1);
        if (SvCUR(result) && SvEND(result)[-1] == '.')
            sv_setpvn(result, SvPVX(result), SvCUR(result) - 1);
        const perl_diagpack_engine *engine = last_diagnostic
            ? Perl_xperl_render_engine(aTHX_ last_diagnostic, render_context)
            : NULL;
        SV *destruction = engine
            ? Perl_xperl_render_format_engine(aTHX_ engine,
                perl_diag_note_context_global_destruction_idx, 0)
            : Perl_xperl_render_format(aTHX_
                perl_diag_note_context_global_destruction_idx, language, 0);
        sv_catsv(result, destruction);
        sv_catpvs(result, ".\n");
        SvREFCNT_dec_NN(destruction);
    }
    return result;
}

static SV *
Perl_xperl_render_diagnostic_legacy_body(pTHX_ HV *fields,
                                      const char *language, HV *context,
                                      const perl_diagpack_engine *engine)
{
    SV *code = Perl_xperl_field(aTHX_ fields, "code");
    SV *number = Perl_xperl_field(aTHX_ fields, "number");
    SV *pattern_context = Perl_xperl_field(aTHX_ fields, "pattern_context");

    if (SvOK(number) && !SvROK(number)
        && (SvUV(number) == perl_diag_error_unicode_property_context_expansion_number
            || SvUV(number) == perl_diag_error_unicode_property_context_name_number
            || SvUV(number) == perl_diag_error_unicode_property_context_runtime_name_number)) {
        SV *result = newSVpvs("");
        SV *initial_contents = Perl_xperl_field(aTHX_ fields, "contents");
        SSize_t last = SvROK(initial_contents)
            && SvTYPE(SvRV(initial_contents)) == SVt_PVAV
            ? av_top_index(MUTABLE_AV(SvRV(initial_contents))) : -1;
        SSize_t i;

        for (i = 0; i <= last; i++) {
            SV *contents = Perl_xperl_field(aTHX_ fields, "contents");
            AV *array;
            SV **child_slot;
            SV *child_object;
            SV *child_text;

            if (!SvROK(contents) || SvTYPE(SvRV(contents)) != SVt_PVAV)
                break;
            array = MUTABLE_AV(SvRV(contents));
            if (i > av_top_index(array))
                break;
            child_slot = av_fetch(array, i, FALSE);
            if (!child_slot || !SvROK(*child_slot)
                || SvTYPE(SvRV(*child_slot)) != SVt_PVHV)
                continue;
            child_object = sv_2mortal(newSVsv(*child_slot));
            child_text = Perl_xperl_render_diagnostic_legacy(aTHX_
                MUTABLE_HV(SvRV(child_object)), language, context);
            if (child_text) {
                sv_catsv(result, child_text);
                SvREFCNT_dec_NN(child_text);
            }
        }

        {
            SV *context_text = Perl_xperl_render_diagnostic_template(aTHX_
                fields, language, engine);
            if (context_text) {
                STRLEN context_length;
                const char *context_bytes = SvPV(context_text,
                                                  context_length);
                if (context_length && context_bytes[0] == ' '
                    && SvCUR(result) && SvEND(result)[-1] == '\n')
                    SvCUR_set(result, SvCUR(result) - 1);
                sv_catsv(result, context_text);
                SvREFCNT_dec_NN(context_text);
            }
        }
        return result;
    }

    if (SvOK(code) && !SvROK(code)
        && strEQ(SvPV_nolen(code), "ERROR_USER_REFERENCE"))
        return newSVsv(Perl_xperl_named_param(aTHX_ fields, "object"));

    if (SvOK(code) && !SvROK(code)
        && strEQ(SvPV_nolen(code), "ERROR_FATALIZED_WARNING_WRAPPER")) {
        SV *contents = Perl_xperl_field(aTHX_ fields, "contents");
        if (SvROK(contents) && SvTYPE(SvRV(contents)) == SVt_PVAV) {
            SV **child = av_fetch(MUTABLE_AV(SvRV(contents)), 0, FALSE);
            if (child && SvROK(*child) && SvTYPE(SvRV(*child)) == SVt_PVHV)
                return Perl_xperl_render_diagnostic_legacy(aTHX_
                    MUTABLE_HV(SvRV(*child)), language, context);
        }
        return newSVpvs("");
    }

    if (SvOK(Perl_xperl_field(aTHX_ fields, "context_follows_index"))) {
        SV *text = Perl_xperl_render_diagnostic_template(aTHX_ fields,
                                                      language, engine);
        if (text
            && !Perl_xperl_diagnostic_has_context_followup(aTHX_ fields, context)) {
            SV *unavailable = engine
                ? Perl_xperl_render_format_engine(aTHX_ engine,
                    perl_diag_note_context_unavailable_idx, 0)
                : Perl_xperl_render_format(aTHX_
                    perl_diag_note_context_unavailable_idx, language, 0);
            sv_catsv(text, unavailable);
            SvREFCNT_dec_NN(unavailable);
        }
        return text;
    }

    if (SvROK(pattern_context)
        && SvTYPE(SvRV(pattern_context)) == SVt_PVHV) {
        HV *context = MUTABLE_HV(SvRV(pattern_context));
        SV *before = Perl_xperl_field(aTHX_ context, "before");
        SV *after = Perl_xperl_field(aTHX_ context, "after");
        SV *message = Perl_xperl_named_param(aTHX_ fields, "message");
        SV *template_message = NULL;
        AV *format_values = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));

        if (!SvOK(message)) {
            template_message = Perl_xperl_render_diagnostic_template(
                aTHX_ fields, language, engine);
            message = template_message ? template_message : &PL_sv_undef;
        }
        if (!message)
            message = &PL_sv_undef;

        av_push(format_values, newSVsv(message));
        av_push(format_values, newSVsv(before));
        av_push(format_values, newSVsv(after));
        message = engine
            ? newSVsv(Perl_diagpack_render_format_engine(aTHX_ engine,
                perl_diag_error_regexp_message_at_location_idx, format_values))
            : newSVsv(Perl_diag_render_format(aTHX_
                perl_diag_error_regexp_message_at_location_idx,
                format_values, language ? language : "en"));
        if (template_message)
            SvREFCNT_dec_NN(template_message);
        return message;
    }

    if (SvOK(number))
        return Perl_xperl_render_diagnostic_template(aTHX_ fields, language,
                                                      engine);

    {
        SV *message = Perl_xperl_named_param(aTHX_ fields, "message");
        if (!SvOK(message))
            message = Perl_xperl_named_param(aTHX_ fields, "text");
        if (SvOK(message))
            return newSVsv(message);
    }

    return NULL;
}

static SV *
Perl_xperl_render_diagnostic_legacy(pTHX_ HV *fields, const char *language,
                                  HV *context)
{
    SV *context_ref = NULL;
    SV *text;
    const perl_diagpack_engine *engine;
    bool standalone = !context;

    if (!context) {
        context_ref = sv_2mortal(newRV_noinc(MUTABLE_SV(newHV())));
        context = MUTABLE_HV(SvRV(context_ref));
    }
    else {
        SV **standalone_slot = hv_fetchs(context, "_standalone", FALSE);
        if (standalone_slot && SvTRUE(*standalone_slot)) {
            standalone = TRUE;
            sv_setiv(*standalone_slot, 0);
        }
    }
    ENTER;
    if (!Perl_xperl_render_guard_enter(aTHX_ context, fields)) {
        LEAVE;
        return newSVpvs("");
    }

    engine = Perl_xperl_render_engine(aTHX_ fields, context);
    text = Perl_xperl_render_diagnostic_legacy_body(aTHX_ fields, language,
        context, engine);

    if (text && !SvROK(text) && standalone) {
        SV *location = Perl_xperl_field(aTHX_ fields, "location");

        if (SvROK(location) && SvTYPE(SvRV(location)) == SVt_PVHV) {
            HV *location_hv = MUTABLE_HV(SvRV(location));
            SV *file = Perl_xperl_field(aTHX_ location_hv, "file");
            SV *line = Perl_xperl_field(aTHX_ location_hv, "line");

            if (SvOK(file) && SvOK(line)) {
                SV *location_search = Perl_xperl_source_location_engine(aTHX_
                    engine, file, line, language);
                SV *location_text = newSVsv(location_search);
                STRLEN text_length;
                STRLEN location_length;
                const char *text_bytes = SvPV(text, text_length);
                const char *location_bytes;

                sv_catpvs(location_text, ".");
                location_bytes = SvPV(location_search, location_length);
                if (!ninstr(text_bytes, text_bytes + text_length,
                            location_bytes,
                            location_bytes + location_length))
                {
                    if (text_length && text_bytes[text_length - 1] == '\n')
                        SvCUR_set(text, text_length - 1);
                    sv_catsv(text, location_text);
                }
                SvREFCNT_dec_NN(location_search);
                SvREFCNT_dec_NN(location_text);
            }
        }
    }

    SV *number = Perl_xperl_field(aTHX_ fields, "number");
    if (text && !SvROK(text)
        && !(SvOK(number) && !SvROK(number)
             && (SvUV(number) == perl_diag_error_fatalized_warning_wrapper_number
                 || SvUV(number) == perl_diag_error_unicode_property_context_expansion_number
                 || SvUV(number) == perl_diag_error_unicode_property_context_name_number
                 || SvUV(number) == perl_diag_error_unicode_property_context_runtime_name_number)))
        Perl_xperl_append_diagnostic_contents(aTHX_ text, fields, language,
                                               FALSE, context);

    LEAVE;

    return text;
}

static SV *
Perl_xperl_render_diagnostic_template(pTHX_ HV *fields, const char *language,
                                     const perl_diagpack_engine *engine)
{
    SV *number = Perl_xperl_field(aTHX_ fields, "number");
    SV *params = Perl_xperl_field(aTHX_ fields, "params");

    if (!SvOK(number) || SvROK(number))
        return NULL;

    if (SvROK(params) && SvTYPE(SvRV(params)) == SVt_PVAV) {
        AV *param_array = MUTABLE_AV(SvRV(params));
        SV *rendered;
        if (engine) {
            rendered = Perl_diag_render_diagnostic_engine(aTHX_
                SvUV(number), param_array, engine);
        }
        else
            rendered = Perl_diag_render_diagnostic(aTHX_ SvUV(number),
                param_array, language ? language : "en");

        SV *location = Perl_xperl_field(aTHX_ fields, "location");
        SV *panic = SvROK(location) && SvTYPE(SvRV(location)) == SVt_PVHV
            ? Perl_xperl_field(aTHX_ MUTABLE_HV(SvRV(location)), "panic")
            : &PL_sv_undef;
        if (rendered && SvROK(panic) && SvTYPE(SvRV(panic)) == SVt_PVHV) {
            HV *context = MUTABLE_HV(SvRV(panic));
            SV *file = Perl_xperl_field(aTHX_ context, "file");
            SV *line = Perl_xperl_field(aTHX_ context, "line");
            SV *errnum = Perl_xperl_field(aTHX_ context, "errno");
            SV *extended = Perl_xperl_field(aTHX_ context, "extended_errno");
            SV *caller_file = Perl_xperl_field(aTHX_ context, "caller_file");
            SV *caller_line = Perl_xperl_field(aTHX_ context, "caller_line");
            const bool called_by = SvOK(file) && SvOK(caller_file)
                && (strNE(SvPV_nolen(file), SvPV_nolen(caller_file))
                    || SvUV(line) != SvUV(caller_line));
            return engine
                ? Perl_xperl_render_format_engine(aTHX_ engine,
                    perl_diag_error_internal_locale_panic_context_idx, 9,
                    file, line, rendered, errnum, extended, caller_file,
                    caller_line,
                    sv_2mortal(newSVpv(SvIV(errnum) != SvIV(extended)
                        ? "extended" : "plain", 0)),
                    sv_2mortal(newSVpv(called_by ? "present" : "absent", 0)))
                : Perl_xperl_render_format(aTHX_
                    perl_diag_error_internal_locale_panic_context_idx,
                    language, 9, file, line, rendered, errnum, extended,
                    caller_file, caller_line,
                    sv_2mortal(newSVpv(SvIV(errnum) != SvIV(extended)
                        ? "extended" : "plain", 0)),
                    sv_2mortal(newSVpv(called_by ? "present" : "absent", 0)));
        }

        return rendered ? newSVsv(rendered) : NULL;
    }
    return NULL;
}

static SV *
Perl_xperl_render_diagnostic_modern_body(pTHX_ HV *fields, const char *language,
                                      HV *context,
                                      const perl_diagpack_engine *engine)
{
    SV *code = Perl_xperl_field(aTHX_ fields, "code");
    SV *pattern_context = Perl_xperl_field(aTHX_ fields, "pattern_context");

    if (SvOK(code) && !SvROK(code)
        && strEQ(SvPV_nolen(code), "ERROR_USER_REFERENCE"))
        return newSVsv(Perl_xperl_named_param(aTHX_ fields, "object"));

    if (SvOK(code) && !SvROK(code)
        && strEQ(SvPV_nolen(code), "ERROR_FATALIZED_WARNING_WRAPPER")) {
        SV *reason = Perl_xperl_field(aTHX_ fields, "promotion_reason");
        return newSVpvf("Fatalized warning: %s",
                        SvOK(reason) ? SvPV_nolen(reason) : "policy");
    }

    if (SvOK(Perl_xperl_field(aTHX_ fields, "context_follows_index"))) {
        SV *text = Perl_xperl_render_diagnostic_template(aTHX_ fields,
                                                      language, engine);
        if (!text)
            text = newSVpvs("<no catalog template>");
        if (!Perl_xperl_diagnostic_has_context_followup(aTHX_ fields, context)) {
            SV *unavailable = engine
                ? Perl_xperl_render_format_engine(aTHX_ engine,
                    perl_diag_note_context_unavailable_idx, 0)
                : Perl_xperl_render_format(aTHX_
                    perl_diag_note_context_unavailable_idx, language, 0);
            sv_catsv(text, unavailable);
            SvREFCNT_dec_NN(unavailable);
        }
        return text;
    }

    if (SvROK(pattern_context)
        && SvTYPE(SvRV(pattern_context)) == SVt_PVHV) {
        HV *context = MUTABLE_HV(SvRV(pattern_context));
        SV *before = Perl_xperl_field(aTHX_ context, "before");
        SV *after = Perl_xperl_field(aTHX_ context, "after");
        SV *message = Perl_xperl_named_param(aTHX_ fields, "message");
        AV *format_values = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));

        if (!SvOK(message)) {
            message = Perl_xperl_render_diagnostic_template(aTHX_ fields,
                                                         language, engine);
            if (!message)
                message = newSVpvs("<no catalog template>");
        }
        else {
            message = newSVsv(message);
        }

        av_push(format_values, message);
        av_push(format_values, newSVsv(before));
        av_push(format_values, newSVsv(after));
        SV *rendered = engine
            ? Perl_diagpack_render_format_engine(aTHX_ engine,
                perl_diag_error_regexp_message_at_location_idx, format_values)
            : Perl_diag_render_format(aTHX_
                perl_diag_error_regexp_message_at_location_idx,
                format_values, language ? language : "en");
        return rendered ? newSVsv(rendered) : NULL;
    }

    {
        SV *rendered = Perl_xperl_render_diagnostic_template(aTHX_ fields,
                                                         language, engine);

        return rendered ? rendered : newSVpvs("<no catalog template>");
    }
}

static SV *
Perl_xperl_render_diagnostic_modern(pTHX_ HV *fields, const char *language,
                                 HV *context)
{
    SV *context_ref = NULL;
    SV *text;
    const perl_diagpack_engine *engine;

    if (!context) {
        context_ref = sv_2mortal(newRV_noinc(MUTABLE_SV(newHV())));
        context = MUTABLE_HV(SvRV(context_ref));
    }
    ENTER;
    if (!Perl_xperl_render_guard_enter(aTHX_ context, fields)) {
        LEAVE;
        return newSVpvs("");
    }

    engine = Perl_xperl_render_engine(aTHX_ fields, context);
    text = Perl_xperl_render_diagnostic_modern_body(aTHX_ fields,
        language, context, engine);
    if (text && !SvROK(text))
        Perl_xperl_append_diagnostic_contents(aTHX_ text, fields, language,
                                               TRUE, context);
    LEAVE;
    return text;
}

XS(Perl_XPerl_Diagnostic_render);
XS(Perl_XPerl_Diagnostic_render)
{
    dXSARGS;
    HV *fields;
    const char *format = "legacy";
    SV *result;

    if (items < 1 || items > 3)
        croak_xs_usage(cv, "self, format = 'legacy', context = undef");
    fields = Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::Diagnostic");
    if (items == 2 && SvOK(ST(1)))
        format = SvPV_nolen(ST(1));
    if (!strEQ(format, "legacy"))
        PERL_THROW_ERROR_DIAGNOSTIC_API_RENDER_FORMAT_UNKNOWN(format);
    HV *context = items == 3
        ? Perl_xperl_render_context_from_arg(aTHX_ ST(2)) : NULL;
    if (!context) {
        SV *context_ref = sv_2mortal(newRV_noinc(MUTABLE_SV(newHV())));
        context = MUTABLE_HV(SvRV(context_ref));
        (void)hv_stores(context, "_standalone", newSViv(1));
    }
    ENTER;
    SAVETMPS;
    SV *explicit_key = sv_2mortal(newSVpvs("_explicit_language"));
    SV **explicit_slot = hv_fetchs(context, "_explicit_language", FALSE);
    if (explicit_slot)
        save_helem(context, explicit_key, explicit_slot);
    else
        SAVEHDELETE(context, explicit_key);
    Perl_xperl_render_context_set_explicit(context, FALSE);
    result = Perl_xperl_render_diagnostic_legacy(aTHX_ fields, "en",
                                                 context);
    FREETMPS;
    LEAVE;
    ST(0) = sv_2mortal(result ? result
        : newSVpvf("XPerl::Diagnostic=HASH(%p)", SvRV(ST(0))));
    XSRETURN(1);
}

XS(Perl_XPerl_Diagnostic_render_as_legacy);
XS(Perl_XPerl_Diagnostic_render_as_legacy)
{
    dXSARGS;
    HV *fields;
    SV *result;

    if (items < 2 || items > 3)
        croak_xs_usage(cv, "self, language, context = undef");
    fields = Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::Diagnostic");
    HV *context = items == 3
        ? Perl_xperl_render_context_from_arg(aTHX_ ST(2)) : NULL;
    if (!context) {
        SV *context_ref = sv_2mortal(newRV_noinc(MUTABLE_SV(newHV())));
        context = MUTABLE_HV(SvRV(context_ref));
        (void)hv_stores(context, "_standalone", newSViv(1));
    }
    ENTER;
    SAVETMPS;
    SV *explicit_key = sv_2mortal(newSVpvs("_explicit_language"));
    SV **explicit_slot = hv_fetchs(context, "_explicit_language", FALSE);
    if (explicit_slot)
        save_helem(context, explicit_key, explicit_slot);
    else
        SAVEHDELETE(context, explicit_key);
    Perl_xperl_render_context_set_explicit(context, TRUE);
    result = Perl_xperl_render_diagnostic_legacy(aTHX_ fields,
        SvPV_nolen(ST(1)), context);
    FREETMPS;
    LEAVE;
    ST(0) = sv_2mortal(result ? result : newSVpvf(
        "XPerl::Diagnostic=HASH(%p)", SvRV(ST(0))));
    XSRETURN(1);
}

static SV *
Perl_xperl_render_exception_legacy(pTHX_ SV *object, HV *fields,
                                const char *language,
                                bool explicit_language)
{
    SV *result;

    result = Perl_xperl_legacy_from_diagnostics(aTHX_ object, fields,
        language, explicit_language);
    if (result)
        return result;

    return newSVpvf("XPerl::Exception=HASH(%p)", SvRV(object));
}

XS(Perl_XPerl_Exception_render_as_legacy);
XS(Perl_XPerl_Exception_render_as_legacy)
{
    dXSARGS;
    HV *fields;
    SV *result;

    if (items != 2)
        croak_xs_usage(cv, "self, language");
    fields = Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::Exception");
    result = Perl_xperl_render_exception_legacy(aTHX_ ST(0), fields,
                                               SvPV_nolen(ST(1)), TRUE);
    ST(0) = sv_2mortal(result);
    XSRETURN(1);
}

static SV *
Perl_xperl_render_exception_annotated(pTHX_ SV *object, const char *language,
                                    bool explicit_language)
{
    SV *result;
    {
        SV *context_ref = sv_2mortal(newRV_noinc(MUTABLE_SV(newHV())));
        HV *context = MUTABLE_HV(SvRV(context_ref));
        SSize_t i = 0;

        Perl_xperl_render_context_set_explicit(context, explicit_language);

        result = newSVpvs("");
        Perl_xperl_render_context_set(aTHX_ context, object, i);
        for (;;) {
            bool in_range;
            SV *item = Perl_xperl_exception_diagnostic_at(aTHX_ object, i,
                                                       &in_range);
            HV *diagnostic;
            SV *severity;
            SV *kind;
            SV *number;
            SV *code;
            SV *location;
            SV *text_location = NULL;
            SV *text;
            SV *prefix;
            bool grouped_hint;
            bool grouped_context;

            if (!in_range)
                break;
            if (!item) {
                i++;
                continue;
            }

            diagnostic = SvROK(item) && SvTYPE(SvRV(item)) == SVt_PVHV
                ? MUTABLE_HV(SvRV(item)) : NULL;
            if (!diagnostic) {
                SvREFCNT_dec_NN(item);
                i++;
                continue;
            }

            HV *fields = MUTABLE_HV(SvRV(object));
            if (SvTRUE(Perl_xperl_field(aTHX_ fields, "suppress_delivered_warnings"))
                && SvTRUE(Perl_xperl_field(aTHX_ diagnostic, "_warning_delivered"))) {
                SvREFCNT_dec_NN(item);
                i++;
                continue;
            }
            Perl_xperl_render_context_set(aTHX_ context, object, i);
            grouped_hint = Perl_xperl_render_context_is_hint(
                aTHX_ diagnostic, context);
            severity = Perl_xperl_field(aTHX_ diagnostic, "severity");
            kind = Perl_xperl_field(aTHX_ diagnostic, "kind");
            number = Perl_xperl_field(aTHX_ diagnostic, "number");
            code = Perl_xperl_field(aTHX_ diagnostic, "code");
            location = Perl_xperl_field(aTHX_ diagnostic, "location");

            /* Rendering template arguments can run overloaded stringification
             * which mutates the diagnostics array.  Recheck the tail link
             * after rendering so a removed or replaced tail is not hidden. */
            text = Perl_xperl_render_diagnostic_modern(aTHX_ diagnostic,
                                                    language, context);
            grouped_context =
                Perl_xperl_diagnostic_has_context_followup(aTHX_ diagnostic,
                                                        context);

            prefix = newSVpv(grouped_hint ? "  #" : "#", 0);
            if (!grouped_context && SvOK(number))
                sv_catsv(prefix, number);
            else if (!grouped_context)
                sv_catpvs(prefix, "0");
            sv_catpvs(prefix, " ");
            if (SvOK(severity))
                sv_catsv(prefix, severity);
            else
                sv_catpvs(prefix, "UNKNOWN");
            sv_catpvs(prefix, ".");
            if (SvOK(kind))
                sv_catsv(prefix, kind);
            else
                sv_catpvs(prefix, "UNKNOWN");
            if (!grouped_context) {
                sv_catpvs(prefix, ".");
                if (SvOK(code))
                    sv_catsv(prefix, code);
                else
                    sv_catpvs(prefix, "UNKNOWN");
            }
            if (!grouped_context && SvROK(location)
                && SvTYPE(SvRV(location)) == SVt_PVHV) {
                HV *location_hv = MUTABLE_HV(SvRV(location));
                SV *file = Perl_xperl_field(aTHX_ location_hv, "file");
                SV *line = Perl_xperl_field(aTHX_ location_hv, "line");

                if (SvOK(file) && SvOK(line)) {
                    sv_catpvs(prefix, " ");
                    sv_catsv(prefix, file);
                    sv_catpvs(prefix, ":");
                    sv_catsv(prefix, line);

                    text_location = Perl_xperl_source_location_engine(aTHX_
                        Perl_xperl_render_engine(aTHX_ diagnostic, context),
                        file, line, language);
                    sv_catpvs(text_location, ".");
                }
            }
            if (SvCUR(result) && SvEND(result)[-1] != '\n')
                sv_catpvs(result, "\n");
            sv_catsv(result, prefix);
            sv_catpvs(result, "\n");
            if (SvUTF8(text))
                SvUTF8_on(result);

            if (grouped_hint && !SvROK(text)) {
                Perl_xperl_append_indented_text(aTHX_ result, text);
            }
            else if (SvROK(text)) {
                sv_catsv(result, text);
            }
            else {
                STRLEN text_length;
                const char *text_bytes = SvPV(text, text_length);

                sv_catpvn(result, text_bytes, text_length);
            }
            if (text_location && !grouped_context)
                sv_catsv(result, text_location);
            if (!SvCUR(result) || SvEND(result)[-1] != '\n')
                sv_catpvs(result, "\n");

            SvREFCNT_dec_NN(prefix);
            if (text_location)
                SvREFCNT_dec_NN(text_location);
            SvREFCNT_dec_NN(text);
            SvREFCNT_dec_NN(item);
            i++;
        }
    }
    return result;
}

XS(Perl_XPerl_Exception_render_as_modern);
XS(Perl_XPerl_Exception_render_as_modern)
{
    dXSARGS;
    if (items != 2)
        croak_xs_usage(cv, "self, language");
    (void)Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::Exception");
    ST(0) = sv_2mortal(Perl_xperl_render_exception_annotated(aTHX_ ST(0),
        SvOK(ST(1)) ? SvPV_nolen(ST(1)) : "en", TRUE));
    XSRETURN(1);
}

static SV *
Perl_xperl_exception_for_implicit_stringify(pTHX_ SV *object, HV *fields)
{
    SV *messages = Perl_xperl_field(aTHX_ fields, "contents");
    AV *diagnostics;
    SSize_t i;

    if (!SvROK(messages) || SvTYPE(SvRV(messages)) != SVt_PVAV)
        return object;

    /* A warning delivered to __WARN__ may be rethrown by the hook.  Once
     * that has happened, implicit stringification must show the warning
     * diagnostics instead of suppressing the already-delivered copy. */
    if (SvTRUE(Perl_xperl_field(aTHX_ fields, "thrown")))
        return object;

    diagnostics = MUTABLE_AV(SvRV(messages));
    for (i = 0; i <= av_top_index(diagnostics); i++) {
        SV **diagnostic_slot = av_fetch(diagnostics, i, FALSE);
        SV *diagnostic = diagnostic_slot ? *diagnostic_slot : &PL_sv_undef;

        if (SvROK(diagnostic) && SvTYPE(SvRV(diagnostic)) == SVt_PVHV
            && SvTRUE(Perl_xperl_field(aTHX_ MUTABLE_HV(SvRV(diagnostic)),
                                    "_warning_delivered")))
        {
            SV *copy = newRV_noinc(MUTABLE_SV(newHVhv(fields)));
            HV *copy_fields = MUTABLE_HV(SvRV(copy));

            sv_bless(copy, SvSTASH(SvRV(object)));
            if (!hv_stores(copy_fields, "suppress_delivered_warnings",
                           newSViv(1)))
                croak_no_mem();
            return sv_2mortal(copy);
        }
    }

    return object;
}

/* The schema writer emits an ASCII JSON token stream. Convert only that
 * trusted stream to Perl literals, escaping interpolation characters and
 * converting Unicode escapes rather than loading a serialization module. */
static SV *
Perl_xperl_dumper_from_json(pTHX_ SV *json)
{
    SV *out = newSVpvs("");
    const char *p = SvPVX(json);
    bool quoted = FALSE;
    while (*p) {
        if (*p == '"') {
            quoted = !quoted;
            sv_catpvn(out, p++, 1);
        }
        else if (quoted && *p == '\\') {
            if (p[1] == 'u') {
                UV cp = 0;
                unsigned i;
                for (i = 2; i < 6; i++)
                    cp = cp * 16 + (p[i] <= '9' ? p[i] - '0' : p[i] - 'A' + 10);
                p += 6;
                if (cp >= 0xd800 && cp <= 0xdbff && p[0] == '\\' && p[1] == 'u') {
                    UV low = 0;
                    for (i = 2; i < 6; i++)
                        low = low * 16 + (p[i] <= '9' ? p[i] - '0' : p[i] - 'A' + 10);
                    cp = 0x10000 + ((cp - 0xd800) << 10) + low - 0xdc00;
                    p += 6;
                }
                sv_catpvf(out, "\\x{%" UVxf "}", cp);
            }
            else {
                sv_catpvn(out, p, 2);
                p += 2;
            }
        }
        else if (quoted && (*p == '$' || *p == '@')) {
            sv_catpvs(out, "\\");
            sv_catpvn(out, p++, 1);
        }
        else if (!quoted && *p == ':') {
            sv_catpvs(out, " => ");
            p++;
        }
        else if (!quoted && strnEQ(p, "null", 4)) {
            sv_catpvs(out, "undef");
            p += 4;
        }
        else if (!quoted && strnEQ(p, "true", 4)) {
            sv_catpvs(out, "1");
            p += 4;
        }
        else if (!quoted && strnEQ(p, "false", 5)) {
            sv_catpvs(out, "0");
            p += 5;
        }
        else
            sv_catpvn(out, p++, 1);
    }
    return out;
}

XS(Perl_XPerl_Diagnostic_render_as_dumper);
XS(Perl_XPerl_Diagnostic_render_as_dumper)
{
    dXSARGS;
    if (items != 1)
        croak_xs_usage(cv, "self");
    HV *fields = Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::Diagnostic");
    SV *json = sv_2mortal(newSVpvs(""));
    Perl_xperl_json_diagnostic(aTHX_ json, fields);
    ST(0) = sv_2mortal(Perl_xperl_dumper_from_json(aTHX_ json));
    XSRETURN(1);
}

/* Each physical line describes one human message and its diagnostic records.
 * Temporary exception views preserve the ordinary contextual text renderer. */
static SV *
Perl_xperl_render_exception_records(pTHX_ SV *object, HV *fields,
                                const char *language, bool annotated,
                                bool explicit_language, bool dumper)
{
    SV *result = newSVpvs("");
    SSize_t index = 0;
    for (;;) {
        bool in_range;
        SV *item = Perl_xperl_exception_diagnostic_at(aTHX_ object, index, &in_range);
        if (!in_range)
            break;
        if (!item) {
            index++;
            continue;
        }
        HV *diagnostic = MUTABLE_HV(SvRV(item));
        if (SvTRUE(Perl_xperl_field(aTHX_ fields, "suppress_delivered_warnings"))
            && SvTRUE(Perl_xperl_field(aTHX_ diagnostic, "_warning_delivered"))) {
            SvREFCNT_dec_NN(item);
            index++;
            continue;
        }

        SSize_t start = index;
        SSize_t last = index;
        SV *tail = Perl_xperl_field(aTHX_ diagnostic, "context_follows_index");
        if (SvTRUE(Perl_xperl_field(aTHX_ diagnostic, "light")) && SvOK(tail)
            && SvIV(tail) > index)
            last = SvIV(tail);
        else if (SvTRUE(Perl_xperl_field(aTHX_ diagnostic, "has_following_hint"))) {
            bool hint_in_range;
            SV *hint = Perl_xperl_exception_diagnostic_at(aTHX_ object, index + 1, &hint_in_range);
            if (hint) {
                if (SvTRUE(Perl_xperl_field(aTHX_ MUTABLE_HV(SvRV(hint)), "is_hint")))
                    last++;
                SvREFCNT_dec_NN(hint);
            }
        }
        /* Delivery has already selected the complete logical group. */
        if (SvOK(Perl_xperl_field(aTHX_ fields, "_delivery_group_first"))) {
            SV *messages = Perl_xperl_field(aTHX_ fields, "contents");
            if (SvROK(messages) && SvTYPE(SvRV(messages)) == SVt_PVAV)
                last = av_top_index(MUTABLE_AV(SvRV(messages)));
        }

        AV *group = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));
        SV *view = sv_2mortal(newRV_noinc(MUTABLE_SV(newHVhv(fields))));
        sv_bless(view, SvSTASH(SvRV(object)));
        HV *view_fields = MUTABLE_HV(SvRV(view));
        (void)hv_stores(view_fields, "contents", newRV_inc(MUTABLE_SV(group)));
        bool light_group = SvTRUE(Perl_xperl_field(aTHX_ diagnostic, "light"));
        SV *type = sv_mortalcopy(Perl_xperl_field(aTHX_ diagnostic, "severity"));
        for (;;) {
            HV *copy = newHVhv(MUTABLE_HV(SvRV(item)));
            SV *copy_rv = newRV_noinc(MUTABLE_SV(copy));
            sv_bless(copy_rv, SvSTASH(SvRV(item)));
            SV *link = Perl_xperl_field(aTHX_ copy, "context_follows_index");
            if (SvOK(link) && SvIV(link) >= start)
                (void)hv_stores(copy, "context_follows_index", newSViv(SvIV(link) - start));
            av_push(group, copy_rv);
            if (index == start || (light_group
                && !SvTRUE(Perl_xperl_field(aTHX_ copy, "light"))
                && !SvTRUE(Perl_xperl_field(aTHX_ copy, "is_hint")))) {
                sv_setsv(type, Perl_xperl_field(aTHX_ copy, "severity"));
                if (SvTRUE(Perl_xperl_field(aTHX_ copy, "_fatal_warning"))
                    || SvTRUE(Perl_xperl_field(aTHX_ copy, "_delivery_fatal")))
                    sv_setpvs(type, "FATAL_ERROR");
            }
            SvREFCNT_dec_NN(item);
            index++;
            if (index > last)
                break;
            item = Perl_xperl_exception_diagnostic_at(aTHX_ object, index, &in_range);
            if (!item)
                break;
        }

        SV *message = annotated
            ? Perl_xperl_render_exception_annotated(aTHX_ view, language,
                                                    explicit_language)
            : Perl_xperl_legacy_from_diagnostics(aTHX_ view, view_fields,
                                                  language, explicit_language);
        message = sv_2mortal(message ? message : newSVpvs(""));
        SV *record = sv_2mortal(newSVpvs("{\"schema\":\"xperl.diagnostic-group.v2\",\"message\":"));
        Perl_xperl_json_string(aTHX_ record, message);
        sv_catpvs(record, ",\"type\":");
        Perl_xperl_json_string(aTHX_ record, type);
        sv_catpvs(record, ",\"contents\":[");
        SSize_t i;
        for (i = 0; i <= av_top_index(group); i++) {
            SV **slot = av_fetch(group, i, FALSE);
            if (i)
                sv_catpvs(record, ",");
            if (slot && SvROK(*slot) && SvTYPE(SvRV(*slot)) == SVt_PVHV)
                Perl_xperl_json_diagnostic(aTHX_ record,
                    MUTABLE_HV(SvRV(*slot)));
            else
                sv_catpvs(record, "null");
        }
        sv_catpvs(record, "]}");
        if (dumper)
            record = sv_2mortal(Perl_xperl_dumper_from_json(aTHX_ record));
        sv_catsv(result, record);
        sv_catpvs(result, "\n");
    }
    return result;
}

/* Language and text style select the human message. The optional third
 * component selects a line-oriented envelope for that same message. */
static SV *
Perl_xperl_render_exception(pTHX_ SV *object, HV *fields, const char *setting,
                           bool language_setting_explicit)
{
    const char *language = "en";
    const char *format = setting;
    const char *envelope = NULL;
    const char *colon = strchr(setting, ':');
    bool explicit_language = FALSE;
    if (colon) {
        explicit_language = language_setting_explicit;
        SV *name = sv_2mortal(newSVpvn(setting, colon - setting));
        language = strEQ(SvPVX(name), "auto") ? Perl_diag_auto_language(aTHX) : SvPVX(name);
        format = colon + 1;
        colon = strchr(format, ':');
        if (colon) {
            envelope = colon + 1;
            format = SvPVX(sv_2mortal(newSVpvn(format, colon - format)));
        }
    }
    else if (strEQ(setting, "JSON") || strEQ(setting, "json")
        || strEQ(setting, "JSONL") || strEQ(setting, "jsonl")
        || strEQ(setting, "Dumper") || strEQ(setting, "DumperL")) {
        envelope = setting;
        format = "legacy";
    }
    else if (!strEQ(setting, "legacy") && !strEQ(setting, "annotated")
        && !strEQ(setting, "modern")) {
        explicit_language = language_setting_explicit
            && !strEQ(setting, "auto");
        language = strEQ(setting, "auto") ? Perl_diag_auto_language(aTHX) : setting;
        format = "legacy";
    }
    bool annotated = strEQ(format, "annotated") || strEQ(format, "modern");
    if (!annotated && !strEQ(format, "legacy"))
        language = "en";
    if (envelope && (strEQ(envelope, "JSON") || strEQ(envelope, "json")
        || strEQ(envelope, "JSONL") || strEQ(envelope, "jsonl")
        || strEQ(envelope, "Dumper") || strEQ(envelope, "DumperL")))
        return Perl_xperl_render_exception_records(aTHX_ object, fields, language,
            annotated, explicit_language,
            strEQ(envelope, "Dumper") || strEQ(envelope, "DumperL"));
    if (annotated)
        return Perl_xperl_render_exception_annotated(aTHX_ object, language,
            explicit_language);
    return Perl_xperl_render_exception_legacy(aTHX_ object, fields, language,
        explicit_language);
}

XS(Perl_XPerl_Exception_render);
XS(Perl_XPerl_Exception_render)
{
    dXSARGS;
    if (items < 1 || items > 2)
        croak_xs_usage(cv, "self, setting = 'en:legacy'");
    HV *fields = Perl_xperl_object_hv(aTHX_ ST(0), "XPerl::Exception");
    SV *setting = sv_mortalcopy(items == 2 ? ST(1) : &PL_sv_undef);
    SV *result = Perl_xperl_render_exception(aTHX_ ST(0), fields,
        SvOK(setting) && !SvROK(setting) ? SvPV_nolen(setting) : "en:legacy",
        items == 2);
    SPAGAIN;
    ST(0) = sv_2mortal(result);
    XSRETURN(1);
}

XS(Perl_XPerl_Exception_stringify);
XS(Perl_XPerl_Exception_stringify)
{
    dXSARGS;
    if (items < 1)
        croak_xs_usage(cv, "self");
    SV *setting = sv_mortalcopy(get_sv("\004IAG_RENDER", GV_ADD));
    SV *object = ST(0);
    HV *fields = Perl_xperl_object_hv(aTHX_ object, "XPerl::Exception");
    const char *mode = SvROK(setting) ? "en:legacy"
        : SvOK(setting) ? SvPV_nolen(setting) : "auto:legacy";
    object = Perl_xperl_exception_for_implicit_stringify(aTHX_ object, fields);
    fields = MUTABLE_HV(SvRV(object));
    SV *result = Perl_xperl_render_exception(aTHX_ object, fields, mode, FALSE);
    SPAGAIN;
    ST(0) = sv_2mortal(result);
    XSRETURN(1);
}

XS(Perl_XPerl_Exception_bool);
XS(Perl_XPerl_Exception_bool)
{
    dXSARGS;
    PERL_UNUSED_VAR(items);
    ST(0) = &PL_sv_yes;
    XSRETURN(1);
}

XS(Perl_XPerl_overload_marker);
XS(Perl_XPerl_overload_marker)
{
    dXSARGS;
    PERL_UNUSED_VAR(items);
    XSRETURN_EMPTY;
}

static const char *
Perl_xperl_diagpack_language_id(pTHX_ SV *value)
{
    STRLEN length;
    const char *language;

    if (!SvOK(value) || SvROK(value))
        PERL_THROW_ERROR_DIAGNOSTIC_API_RENDER_INPUT_INVALID();
    language = SvPV(value, length);
    if (length != 2 || !isLOWER_A(language[0])
        || !isLOWER_A(language[1]))
        PERL_THROW_ERROR_DIAGNOSTIC_API_RENDER_INPUT_INVALID();
    return language;
}

XS(Perl_diagpack_validate_language_xs);
XS(Perl_diagpack_validate_language_xs)
{
    dXSARGS;

    if (items != 1)
        croak_xs_usage(cv, "language");
    (void)Perl_xperl_diagpack_language_id(aTHX_ ST(0));
    XSRETURN_EMPTY;
}

XS(Perl_diagpack_set_lexical_hint_xs);
XS(Perl_diagpack_set_lexical_hint_xs)
{
    dXSARGS;
    const char *language;

    if (items != 1)
        croak_xs_usage(cv, "language");
    language = Perl_xperl_diagpack_language_id(aTHX_ ST(0));
    Perl_diagpack_set_lexical_hint(aTHX_ language);
    XSRETURN_EMPTY;
}

static void
Perl_xperl_boot_core(pTHX)
{
    static const char file[] = __FILE__;
    static const char *diagnostic_fields[] = {
        "code", "number", "kind", "severity", "selector_key", "light",
        "context_follows_index"
    };
    HV *exception_stash;
    HV *diagnostic_stash;
    Size_t i;
    CV *cv;
    SV *mode;
    const char *env_mode;
    HV *group_stash;
    group_stash = gv_stashpvs("XPerl::DiagGroup", GV_ADD);
    exception_stash = gv_stashpvs("XPerl::Exception", GV_ADD);
    diagnostic_stash = gv_stashpvs("XPerl::Diagnostic", GV_ADD);
    PERL_UNUSED_VAR(group_stash);
    Perl_diag_boot_class_registry(aTHX);
    hv_stores(PL_modglobal, "XPerl::Exception_stash",
              newRV_inc(MUTABLE_SV(exception_stash)));
    hv_stores(PL_modglobal, "XPerl::Diagnostic_stash",
              newRV_inc(MUTABLE_SV(diagnostic_stash)));
    newXS("XPerl::DiagPack::_set_lexical_hint",
          Perl_diagpack_set_lexical_hint_xs, file);
    newXS("XPerl::DiagPack::_validate_language",
          Perl_diagpack_validate_language_xs, file);
    newXS("XPerl::Diagnostic::_new", Perl_XPerl_Diagnostic_new, file);
    newXS("XPerl::Diagnostic::derive", Perl_XPerl_Diagnostic_derive, file);
    newXS("XPerl::DiagGroup::contents", Perl_XPerl_DiagGroup_contents, file);
    newXS("XPerl::DiagGroup::contents_count", Perl_XPerl_DiagGroup_contents_count, file);
    newXS("XPerl::DiagGroup::append", Perl_XPerl_DiagGroup_append, file);
    newXS("XPerl::DiagGroup::contains", Perl_XPerl_DiagGroup_contains, file);
    newXS("XPerl::DiagGroup::has_errors", Perl_XPerl_DiagGroup_has_errors, file);
    newXS("XPerl::Diagnostic::DESTROY", Perl_XPerl_noop_destroy, file);
    for (i = 0; i < C_ARRAY_LENGTH(diagnostic_fields); i++) {
        SV *name = sv_2mortal(newSVpvf("XPerl::Diagnostic::%s",
                                       diagnostic_fields[i]));
        cv = newXS(SvPV_nolen(name), Perl_XPerl_Diagnostic_field, file);
        XSANY.any_i32 = i;
    }
    newXS("XPerl::Diagnostic::params", Perl_XPerl_Diagnostic_params, file);
    newXS("XPerl::Diagnostic::warning_categories",
          Perl_XPerl_Diagnostic_warning_categories, file);
    newXS("XPerl::Diagnostic::location", Perl_XPerl_Diagnostic_location, file);
    newXS("XPerl::Diagnostic::as_json", Perl_XPerl_Diagnostic_as_json, file);
    newXS("XPerl::Diagnostic::render_as_json", Perl_XPerl_Diagnostic_as_json, file);
    newXS("XPerl::Diagnostic::render_as_dumper", Perl_XPerl_Diagnostic_render_as_dumper, file);
    newXS("XPerl::Diagnostic::render", Perl_XPerl_Diagnostic_render, file);
    newXS("XPerl::Diagnostic::text", Perl_XPerl_Diagnostic_render, file);
    newXS("XPerl::Diagnostic::render_as_legacy",
          Perl_XPerl_Diagnostic_render_as_legacy, file);
    newXS("XPerl::Exception::_new", Perl_XPerl_Exception_new, file);
    newXS("XPerl::Exception::DESTROY", Perl_XPerl_noop_destroy, file);
    newXS("XPerl::Exception::PROPAGATE", Perl_XPerl_Exception_propagate, file);
    newXS("XPerl::Exception::_record_throw", Perl_XPerl_Exception_record_throw, file);
    newXS("XPerl::Exception::kind", Perl_XPerl_Exception_field, file);
    newXS("XPerl::Exception::severity", Perl_XPerl_Exception_severity, file);
    newXS("XPerl::Exception::origin", Perl_XPerl_Exception_origin, file);
    newXS("XPerl::Exception::render", Perl_XPerl_Exception_render, file);
    newXS("XPerl::Exception::render_as_legacy",
          Perl_XPerl_Exception_render_as_legacy, file);
    newXS("XPerl::Exception::render_as_modern",
          Perl_XPerl_Exception_render_as_modern, file);
    newXS("XPerl::Exception::render_as_annotated",
          Perl_XPerl_Exception_render_as_modern, file);
    newXS("XPerl::Exception::as_json", Perl_XPerl_Exception_as_json, file);
    newXS("XPerl::Exception::(\"\"", Perl_XPerl_Exception_stringify, file);
    newXS("XPerl::Exception::(bool", Perl_XPerl_Exception_bool, file);
    newXS("XPerl::Exception::((", Perl_XPerl_overload_marker, file);
    newXS("XPerl::Exception::()", Perl_XPerl_overload_marker, file);
    sv_setiv(GvSVn(gv_fetchpvs("XPerl::Exception::()", GV_ADD, SVt_PV)), 1);
    GvMULTI_on(gv_fetchpvs("\004IAG_RENDER", GV_ADD|GV_NOTQUAL, SVt_PV));
    mode = get_sv("\004IAG_RENDER", GV_ADD);
    env_mode = PerlEnv_getenv("PERL_DIAG_RENDER");
    sv_setpv(mode, env_mode && *env_mode ? env_mode : "auto:legacy");

}
