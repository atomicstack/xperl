#ifndef PERL_DIAG_TEMPLATE_MATCH_H
#define PERL_DIAG_TEMPLATE_MATCH_H

#include "diagpack.h"

static IV
Perl_diag_selector_value_id(const char * const *values, U16 value_count,
                            const char *value, STRLEN length)
{
    U32 value_id;

    if (!value)
        return -1;
    if (length == 1 && value[0] == '*')
        return 0;
    if (length == 3 && memEQ(value, "any", 3))
        return 0;

    for (value_id = 0; value_id < value_count; value_id++) {
        const char *known = values[value_id];
        if (length == strlen(known) && memEQ(value, known, length))
            return (IV)value_id + 1;
    }

    return -1;
}

static const char *
Perl_diag_selector_value_name(const char * const *values, U16 value_count,
                              IV value_id)
{
    if (value_id == 0)
        return "*";
    if (value_id < 0 || (UV)value_id > value_count)
        return NULL;
    return values[value_id - 1];
}

static bool
Perl_diag_selector_pattern_matches(const perl_diag_selector_t *selectors,
                                   U8 selector_count, U64 selector_key,
                                   U64 selector_pattern,
                                   U8 invalid_selector_mask)
{
    U8 selector_index;

    for (selector_index = 0; selector_index < selector_count;
         selector_index++)
    {
        const perl_diag_selector_t *selector = &selectors[selector_index];
        const U64 mask = selector->value_width == 16
            ? UINT64_C(0xffff) : UINT64_C(0xff);
        const U64 wanted = (selector_pattern >> selector->shift) & mask;
        const U64 have = (selector_key >> selector->shift) & mask;

        if ((invalid_selector_mask & (U8)(1U << selector_index))
            || (wanted && wanted != have))
            return FALSE;
    }

    return TRUE;
}

static const perl_diag_template_case_t *
Perl_diag_template_case_find(const perl_diag_template_case_t *cases,
                            UV diagnostic_number,
                            const perl_diag_selector_t *selectors,
                            U8 selector_count, U64 selector_key,
                            U8 invalid_selector_mask)
{
    const perl_diag_template_case_t *candidate = cases;

    if (candidate->diagnostic_number != diagnostic_number)
        return NULL;

    for (; candidate->diagnostic_number == diagnostic_number; candidate++) {
        if (Perl_diag_selector_pattern_matches(selectors, selector_count,
                                               selector_key,
                                               candidate->selector_pattern,
                                               invalid_selector_mask))
            return candidate;
    }

    return NULL;
}

#endif
