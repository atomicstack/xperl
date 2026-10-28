SV *
diag_template_match_fixture(UV fixture_id, UV selector_key, UV invalid_mask)
CODE:
    {
        const perl_diag_selector_t *selectors;
        const perl_diag_template_case_t *cases;
        U8 selector_count;
        const perl_diag_template_case_t *match;

        switch (fixture_id) {
        case 0:
            selectors = APItest_diag_selectors_wide_first;
            cases = APItest_diag_cases_wide_first;
            selector_count = 3;
            break;
        case 1:
            selectors = APItest_diag_selectors_wide_middle;
            cases = APItest_diag_cases_wide_middle;
            selector_count = 3;
            break;
        case 2:
            selectors = APItest_diag_selectors_wide_last;
            cases = APItest_diag_cases_wide_last;
            selector_count = 3;
            break;
        case 3:
            selectors = APItest_diag_selectors_six_narrow_plus_wide;
            cases = APItest_diag_cases_six_narrow_plus_wide;
            selector_count = 7;
            break;
        case 4:
            selectors = APItest_diag_selectors_seven_narrow;
            cases = APItest_diag_cases_seven_narrow;
            selector_count = 7;
            break;
        default:
            croak("unknown diagnostic selector fixture");
        }

        match = Perl_diag_template_case_find(cases, 990001, selectors,
                                             selector_count,
                                             (U64)selector_key,
                                             (U8)invalid_mask);
        RETVAL = match ? newSVpv(match->positional_template, 0) : newSV(0);
    }
OUTPUT:
    RETVAL

void
diagpack_test_override(const char *language, UV mode)
CODE:
    {
        APItest_diagpack_override_t *slot = NULL;
        const perl_diagpack_engine *engine = Perl_diagpack_find(aTHX_ language);
        if (!engine)
            croak("diagnostic test override requires a registered language");
        for (Size_t index = 0; index < C_ARRAY_LENGTH(APItest_diagpack_overrides); index++) {
            if (!APItest_diagpack_overrides[index].original) {
                slot = &APItest_diagpack_overrides[index];
                break;
            }
        }
        if (!slot)
            croak("too many active diagnostic test overrides");
        slot->original = engine;
        slot->replacement = *engine;
        switch (mode) {
        case 1:
            slot->replacement.render = APItest_diagpack_poison_render;
            break;
        case 2:
            slot->replacement.render = APItest_diagpack_override_render;
            break;
        case 3:
            slot->replacement.render = APItest_diagpack_override_render;
            break;
        case 4:
            slot->replacement.render = APItest_diagpack_partial_override_render;
            break;
        default:
            croak("unknown diagnostic test override mode");
        }
        if (mode == 2) {
            slot->replacement.cardinal = APItest_diagpack_override_plural;
            slot->replacement.ordinal = APItest_diagpack_override_plural;
        }
        else if (mode == 3) {
            slot->replacement.cardinal = APItest_diagpack_invalid_plural;
            slot->replacement.ordinal = APItest_diagpack_invalid_plural;
        }
        Perl_diagpack_register(aTHX_ &slot->replacement);
    }

void
diagpack_test_partial_catalog(const char *language)
CODE:
    {
        APItest_diagpack_override_t *slot = NULL;
        const perl_diagpack_engine *engine = Perl_diagpack_find(aTHX_ language);
        if (!engine)
            croak("partial catalog test requires a registered language");
        for (Size_t index = 0; index < C_ARRAY_LENGTH(APItest_diagpack_overrides); index++) {
            if (!APItest_diagpack_overrides[index].original) {
                slot = &APItest_diagpack_overrides[index];
                break;
            }
        }
        if (!slot)
            croak("too many active diagnostic test overrides");
        APItest_diagpack_make_partial(aTHX_ engine);
        slot->original = engine;
        slot->replacement = APItest_partial_engine;
        Perl_diagpack_register(aTHX_ &slot->replacement);
    }

void
diagpack_test_bad_catalog(const char *language, UV mode)
CODE:
    {
        const perl_diagpack_engine *engine = Perl_diagpack_find(aTHX_ language);
        UV target = mode == 3 ? 1435 : 1429;
        UV row;
        if (!engine)
            croak("bad catalog test requires a registered language");
        if (engine->catalog->template_count > C_ARRAY_LENGTH(APItest_bad_templates)
            || engine->catalog->param_table_count > C_ARRAY_LENGTH(APItest_bad_params))
            croak("bad catalog test fixture exceeds static capacity");
        APItest_bad_catalog = *engine->catalog;
        for (UV index = 0; index < engine->catalog->template_count; index++) {
            APItest_bad_templates[index] = engine->catalog->templates[index];
            APItest_bad_schemas[index] = engine->catalog->schemas[index];
        }
        APItest_bad_catalog.templates = APItest_bad_templates;
        APItest_bad_catalog.schemas = APItest_bad_schemas;
        row = APItest_diagpack_row(engine->catalog, target);
        if (!row)
            croak("bad catalog test row is unavailable");
        if (mode == 1) {
            APItest_bad_schema_row = *engine->catalog->schemas[row];
            APItest_bad_schema_row.code = "INCOMPATIBLE_TEST_CODE";
            APItest_bad_schemas[row] = &APItest_bad_schema_row;
        }
        else if (mode == 2) {
            const perl_diagpack_schema_t *schema = engine->catalog->schemas[row];
            if (!schema->param_count)
                croak("parameter mismatch test row has no parameters");
            for (U32 index = 0; index < engine->catalog->param_table_count; index++)
                APItest_bad_params[index] = engine->catalog->param_table[index];
            APItest_bad_catalog.param_table = APItest_bad_params;
            APItest_bad_params[schema->param_ids[0]].name = "incompatible_test_parameter";
        }
        else if (mode == 3) {
            perl_diag_template_t *definition = &APItest_bad_templates[row];
            if (!definition->selector_count || definition->selector_count > C_ARRAY_LENGTH(APItest_bad_selectors))
                croak("native selector mismatch test row has no selectors");
            for (U8 index = 0; index < definition->selector_count; index++)
                APItest_bad_selectors[index] = definition->selectors[index];
            APItest_bad_selectors[0].native_id = !APItest_bad_selectors[0].native_id;
            definition->selectors = APItest_bad_selectors;
        }
        else if (mode == 4) {
            const perl_diagpack_schema_t *schema = engine->catalog->schemas[row];
            if (!schema->param_count)
                croak("null parameter schema test row has no parameters");
            for (U32 index = 0; index < engine->catalog->param_table_count; index++)
                APItest_bad_params[index] = engine->catalog->param_table[index];
            APItest_bad_catalog.param_table = APItest_bad_params;
            APItest_bad_params[schema->param_ids[0]].name = NULL;
        }
        else if (mode == 5) {
            static const char * const values[] = { "one", "two" };
            perl_diag_template_t *definition = &APItest_bad_templates[row];
            for (U8 index = 0; index < 7; index++) {
                APItest_bad_selectors[index].name = "narrow";
                APItest_bad_selectors[index].index = 0;
                APItest_bad_selectors[index].domain_id = 0;
                APItest_bad_selectors[index].values = values;
                APItest_bad_selectors[index].value_count = 2;
                APItest_bad_selectors[index].value_width = 8;
                APItest_bad_selectors[index].shift = (U8)(8 * index);
                APItest_bad_selectors[index].plural_kind = NULL;
                APItest_bad_selectors[index].assert_unknown = FALSE;
                APItest_bad_selectors[index].operation_word = FALSE;
                APItest_bad_selectors[index].plural_form = NULL;
                APItest_bad_selectors[index].native_id = FALSE;
            }
            definition->selector_count = 7;
            definition->selectors = APItest_bad_selectors;
        }
        else
            croak("unknown bad catalog test mode");
        APItest_bad_engine = *engine;
        APItest_bad_engine.catalog = &APItest_bad_catalog;
        if (mode == 5) {
            APItest_diagpack_override_t *slot = NULL;
            for (Size_t index = 0; index < C_ARRAY_LENGTH(APItest_diagpack_overrides); index++) {
                if (!APItest_diagpack_overrides[index].original) {
                    slot = &APItest_diagpack_overrides[index];
                    break;
                }
            }
            if (!slot)
                croak("too many active diagnostic test overrides");
            slot->original = engine;
            slot->replacement = APItest_bad_engine;
            Perl_diagpack_register(aTHX_ &slot->replacement);
            XSRETURN_EMPTY;
        }
        Perl_diagpack_register(aTHX_ &APItest_bad_engine);
    }

void
diagpack_test_restore(const char *language)
CODE:
    {
        for (Size_t index = C_ARRAY_LENGTH(APItest_diagpack_overrides); index-- > 0;) {
            APItest_diagpack_override_t *slot = &APItest_diagpack_overrides[index];
            if (slot->original && strEQ(language, slot->original->language)) {
                Perl_diagpack_register(aTHX_ slot->original);
                slot->original = NULL;
                XSRETURN_EMPTY;
            }
        }
        croak("diagnostic test override is not active");
    }

void
diagpack_test_bad_register(const char *language)
CODE:
    {
        const perl_diagpack_engine *engine = Perl_diagpack_find(aTHX_ language);
        perl_diagpack_engine invalid;
        if (!engine)
            croak("bad diagnostic test registration requires a registered language");
        invalid = *engine;
        invalid.abi_version++;
        Perl_diagpack_register(aTHX_ &invalid);
    }

SV *
diagpack_test_render_template(UV diagnostic_number, UV selector_key, AV *values, const char *language)
CODE:
    {
        SV *rendered = Perl_diag_render_template(aTHX_ diagnostic_number,
            (U64)selector_key, values, language);
        RETVAL = rendered ? newSVsv(rendered) : newSV(0);
    }
OUTPUT:
    RETVAL

SV *
diagpack_test_format_template(const char *keyword)
CODE:
    {
        AV *params = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));
        HV *record = newHV();
        (void)hv_stores(record, "name", newSVpvs("keyword"));
        (void)hv_stores(record, "type", newSVpvs("text"));
        (void)hv_stores(record, "value", newSVpv(keyword, 0));
        av_push(params, newRV_noinc(MUTABLE_SV(record)));
        SV *rendered = Perl_diag_format_template(aTHX_
            perl_diag_error_syntax_declaration_use_no_in_expression_idx,
            params);
        RETVAL = rendered ? newSVsv(rendered) : newSV(0);
    }
OUTPUT:
    RETVAL

SV *
diag_selector_fixture(const char *value, IV value_id)
CODE:
    {
        AV *result = newAV();
        IV converted = Perl_diag_selector_value_id(
            APItest_diag_wide_values, 65535, value, strlen(value));
        const char *name = Perl_diag_selector_value_name(
            APItest_diag_wide_values, 65535, value_id);

        av_push(result, newSViv(converted));
        av_push(result, name ? newSVpv(name, 0) : newSV(0));
        RETVAL = newRV_noinc((SV *)result);
    }
OUTPUT:
    RETVAL
