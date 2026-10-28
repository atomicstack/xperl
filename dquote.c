/*    dquote.c
 *
 * This file contains functions that are related to
 * parsing double-quotish expressions.
 *
*/

/*
 *      Double, double toil and trouble;
 *      Fire burn and cauldron bubble.
 *              --The Weird Sisters
 *
 *     [Act IV, scene i of _Macbeth_]
 */

#include "EXTERN.h"
#define PERL_IN_DQUOTE_C
#include "perl.h"

static UV
Perl_grok_bslash_c_diag_internal(pTHX_ const char source,
                           U8 *result,
                           SV **exception_slot,
                           const bool allow_warning)
{
    PERL_ARGS_ASSERT_GROK_BSLASH_C_DIAG;

    if (! isPRINT_A(source)) {
        if (exception_slot) {
            PERL_APPEND_ERROR_SYNTAX_ESCAPE_CONTROL_NONPRINTABLE_CHARACTER(exception_slot);
        }
        return perl_diag_error_syntax_escape_control_nonprintable_character_idx;
    }

    if (source == '{') {
        const char control = toCTRL('{');
        if (isPRINT_A(control)) {
            if (exception_slot) {
                PERL_APPEND_ERROR_SYNTAX_ESCAPE_CONTROL_OPEN_BRACE_PRINTABLE_RESULT(exception_slot,
                                                        control);
            }
            return perl_diag_error_syntax_escape_control_open_brace_printable_result_idx;
        }
        if (exception_slot) {
            PERL_APPEND_ERROR_SYNTAX_ESCAPE_CONTROL_OPEN_BRACE_INVALID(exception_slot);
        }
        return perl_diag_error_syntax_escape_control_open_brace_invalid_idx;
    }

    *result = toCTRL(source);
    if (allow_warning && isPRINT_A(*result) && ckWARN(WARN_SYNTAX)) {
        U8 clearer[3];
        U8 i = 0;
        if (! isWORDCHAR(*result)) {
            clearer[i++] = '\\';
        }
        clearer[i++] = *result;
        clearer[i++] = '\0';

        if (exception_slot) {
            PERL_APPEND_WARNING_SYNTAX_CONTROL_ESCAPE_PRINTABLE_RESULT(exception_slot, source,
                                               (const char *)clearer);
        }
    }

    return 0;
}

UV
Perl_grok_bslash_c_diag(pTHX_ const char source,
                              U8 *result,
                              SV **exception_slot,
                              const bool allow_warning)
{
    PERL_ARGS_ASSERT_GROK_BSLASH_C_DIAG;
    return Perl_grok_bslash_c_diag_internal(aTHX_ source, result, exception_slot,
                                allow_warning);
}

/* Deprecated in Perl 5.45.4. */
bool
Perl_grok_bslash_c(pTHX_ const char source,
                         U8 *result,
                         const char **message,
                         U32 *packed_warn)
{
    PERL_ARGS_ASSERT_GROK_BSLASH_C;
    PERL_UNUSED_VAR(source);
    PERL_UNUSED_VAR(result);
    PERL_UNUSED_VAR(message);
    PERL_UNUSED_VAR(packed_warn);
    PERL_THROW_ERROR_SYNTAX_ESCAPE_LEGACY_API_UNCALLABLE("Perl_grok_bslash_c");
}

/* Deprecated in Perl 5.45.4. */
bool
Perl_grok_bslash_c_with_reason(pTHX_ const char source,
                               U8 *result,
                               const char **message,
                               U32 *packed_warn,
                               const char **reason)
{
    PERL_ARGS_ASSERT_GROK_BSLASH_C_WITH_REASON;
    PERL_UNUSED_VAR(source);
    PERL_UNUSED_VAR(result);
    PERL_UNUSED_VAR(message);
    PERL_UNUSED_VAR(packed_warn);
    PERL_UNUSED_VAR(reason);
    PERL_THROW_ERROR_SYNTAX_ESCAPE_LEGACY_API_UNCALLABLE("Perl_grok_bslash_c_with_reason");
}

const char *
Perl_form_alien_digit_msg(pTHX_
        const U8 which,           /* 8 or 16 */
        const STRLEN valids_len,  /* length of input before first bad char */
        const char * const first_bad, /* Ptr to that bad char */
        const char * const send,      /* End of input string */
        const bool UTF,               /* Is it in UTF-8? */
        const bool braced)            /* Is it enclosed in {} */
{
    PERL_ARGS_ASSERT_FORM_ALIEN_DIGIT_MSG;

    /* Generate a mortal SV containing an appropriate warning message about
     * alien characters found in an octal or hex constant given by the inputs,
     * and return a pointer to that SV's string.  The message looks like:
     *
     * Non-hex character '?' terminates \x early.  Resolved as "\x{...}"
     *
     */

    /* The usual worst case scenario: 2 chars to display per byte, plus \x{}
     * (leading zeros could take up more space, and the scalar will
     * automatically grow if necessary).  Space for NUL is added by the newSV()
     * function */
    SV * display_char = newSV(2 * UTF8_MAXBYTES + 4);
    SV * message_sv = sv_newmortal();
    char symbol;

    assert(which == 8 || which == 16);

    /* Calculate the display form of the character */
    if (    UVCHR_IS_INVARIANT(*first_bad)
        || (UTF && isUTF8_CHAR((U8 *) first_bad, (U8 *) send)))
    {
        pv_uni_display(display_char, (U8 *) first_bad, UTF8SKIP(first_bad),
                                                    (STRLEN) -1, UNI_DISPLAY_QQ);
    }
    else {  /* Is not UTF-8, or is illegal UTF-8.  Show just the one byte */

        /* It also isn't a UTF-8 invariant character, so no display shortcuts
         * are available.  Use \\x{...} */
        sv_setpvf(display_char, "\\x{%02x}", *first_bad);
    }

    /* Ready to start building the message */
    sv_setpvs(message_sv, "Non-");
    if (which == 8) {
        sv_catpvs(message_sv, "octal");
        if (braced) {
            symbol = 'o';
        }
        else {
            symbol = '0';   /* \008, for example */
        }
    }
    else {
        sv_catpvs(message_sv, "hex");
        symbol = 'x';
    }
    sv_catpvs(message_sv, " character ");

    if (isPRINT(*first_bad)) {
        sv_catpvs(message_sv, "'");
    }
    sv_catsv(message_sv, display_char);
    if (isPRINT(*first_bad)) {
        sv_catpvs(message_sv, "'");
    }
    sv_catpvf(message_sv, " terminates \\%c early.  Resolved as "
                                     "\"\\%c", symbol, symbol);
    if (braced) {
        sv_catpvs(message_sv, "{");
    }

    /* Octal constants have an extra leading 0, but \0 already includes that */
    if (symbol == 'o' && valids_len < 3) {
        sv_catpvs(message_sv, "0");
    }
    if (valids_len == 0) {  /* No legal digits at all */
        sv_catpvs(message_sv, "00");
    }
    else if (valids_len == 1) { /* Just one is legal */
        sv_catpvs(message_sv, "0");
    }
    sv_catpvn(message_sv, first_bad - valids_len, valids_len);

    if (braced) {
        sv_catpvs(message_sv, "}");
    }
    else {
        sv_catsv(message_sv, display_char);
    }
    sv_catpvs(message_sv, "\"");

    SvREFCNT_dec_NN(display_char);

    return SvPVX_const(message_sv);
}

const char *
Perl_form_cp_too_large_msg(pTHX_
        const U8 which,        /* 8 or 16 */
        const char * string,   /* NULL, or the text that is supposed to
                                  represent a code point */
        const Size_t len,      /* length of 'string' if not NULL; else 0 */
        const UV cp)           /* 0 if 'string' not NULL; else the too-large
                                  code point */
{
    PERL_ARGS_ASSERT_FORM_CP_TOO_LARGE_MSG;

    /* Generate a mortal SV containing an appropriate warning message about
     * code points that are too large for this system, given by the inputs,
     * and return a pointer to that SV's string.  Either the text of the string
     * to be converted to a code point is input, or a code point itself.  The
     * former is needed to accurately represent something that overflows.
     *
     * The message looks like:
     *
     * Use of code point %s is not allowed; the permissible max is %s
     *
     */

    SV * message_sv = sv_newmortal();
    const char * format;
    const char * prefix;

    assert(which == 8 || which == 16);

    /* One but not both must be non-zero */
    assert((string != NULL) ^ (cp != 0));
    assert((string == NULL) || len);

    if (which == 8) {
        format = "%" UVof;
        prefix = "0";
    }
    else {
        format = "%" UVXf;
        prefix = "0x";
    }

    sv_setpvf(message_sv, "Use of code point %s", prefix);
    if (string) {
        sv_catpvf(message_sv, "%.*s", (int) len, string);
    }
    else {
        sv_catpvf(message_sv, format, cp);
    }
    sv_catpvf(message_sv, " is not allowed; the permissible max is %s", prefix);
    sv_catpvf(message_sv, format, MAX_LEGAL_CP);

    return SvPVX_const(message_sv);
}

void
Perl_diag_append_alien_digit_warning(pTHX_ SV **exception_slot,
                                     UV diag_index,
                                     const U8 radix,
                                     const STRLEN valids_len,
                                     const char * const first_bad,
                                     const char * const send,
                                     const bool UTF,
                                     const bool braced)
{
    SV *display_char;
    SV *character;
    SV *resolved;
    const char *escape;

    PERL_ARGS_ASSERT_DIAG_APPEND_ALIEN_DIGIT_WARNING;
    if (!exception_slot)
        return;

    assert(radix == 8 || radix == 16);

    display_char = newSV(2 * UTF8_MAXBYTES + 4);
    character = newSVpvs("");
    resolved = newSVpvs("");

    if (    UVCHR_IS_INVARIANT(*first_bad)
        || (UTF && isUTF8_CHAR((U8 *)first_bad, (U8 *)send)))
    {
        pv_uni_display(display_char, (U8 *)first_bad, UTF8SKIP(first_bad),
                       (STRLEN)-1, UNI_DISPLAY_QQ);
    }
    else {
        sv_setpvf(display_char, "\\x{%02x}", *first_bad);
    }

    if (isPRINT(*first_bad))
        sv_catpvs(character, "'");
    sv_catsv(character, display_char);
    if (isPRINT(*first_bad))
        sv_catpvs(character, "'");

    if (radix == 8)
        escape = braced ? "\\o" : "\\0";
    else
        escape = "\\x";

    sv_catpv(resolved, escape);
    if (braced)
        sv_catpvs(resolved, "{");
    if (radix == 8 && braced && valids_len < 3)
        sv_catpvs(resolved, "0");
    if (valids_len == 0)
        sv_catpvs(resolved, "00");
    else if (valids_len == 1)
        sv_catpvs(resolved, "0");
    sv_catpvn(resolved, first_bad - valids_len, valids_len);
    if (braced)
        sv_catpvs(resolved, "}");
    else
        sv_catsv(resolved, display_char);

    if (diag_index == perl_diag_warning_syntax_digit_escape_terminated_early_idx) {
        PERL_APPEND_WARNING_SYNTAX_DIGIT_ESCAPE_TERMINATED_EARLY(exception_slot,
                                        radix == 8 ? perl_diag_selector_domain_2094_0_octal_2 : perl_diag_selector_domain_2094_0_hex_1,
                                        SvUTF8(character), SvCUR(character),
                                        SvPVX_const(character), escape,
                                        SvUTF8(resolved), SvCUR(resolved),
                                        SvPVX_const(resolved));
    }
    else if (diag_index == perl_diag_warning_regexp_escape_digit_outside_radix_idx) {
        PERL_APPEND_WARNING_REGEXP_ESCAPE_DIGIT_OUTSIDE_RADIX(exception_slot,
                                              PERL_DIAG_SELECTOR_FROM_WARNING_REGEXP_ESCAPE_DIGIT_OUTSIDE_RADIX_RADIX(radix == 8 ? "octal" : "hex"),
                                              SvUTF8(character), SvCUR(character),
                                              SvPVX_const(character), escape,
                                              SvUTF8(resolved), SvCUR(resolved),
                                              SvPVX_const(resolved));
    }
    else {
        assert(0 && "unsupported alien digit diagnostic");
    }

    SvREFCNT_dec_NN(display_char);
    SvREFCNT_dec_NN(character);
    SvREFCNT_dec_NN(resolved);
}

#define PERL_GROK_BSLASH_ERROR(slot, append, code) \
    STMT_START { \
        if (slot) append(slot); \
        return code; \
    } STMT_END

static UV
Perl_grok_bslash_o_internal(pTHX_ char **s, const char * const send, UV *uv,
                SV **exception_slot, const bool strict,
                const bool allow_UV_MAX, const bool UTF,
                const bool allow_warning)
{
    char *e;
    char *rbrace;
    STRLEN numbers_len;
    STRLEN trailing_blanks_len = 0;
    I32 flags = PERL_SCAN_ALLOW_UNDERSCORES
              | PERL_SCAN_DISALLOW_PREFIX
              | PERL_SCAN_SILENT_NON_PORTABLE
              | PERL_SCAN_SILENT_ILLDIGIT
              | PERL_SCAN_SILENT_OVERFLOW;

    assert(*(*s - 1) == '\\');
    assert(**s == 'o');

    (*s)++;

    if (send <= *s || **s != '{')
        PERL_GROK_BSLASH_ERROR(exception_slot,
                          PERL_APPEND_ERROR_SYNTAX_ESCAPE_OCTAL_BRACES_REQUIRED,
                          perl_diag_error_syntax_escape_octal_braces_required_idx);

    rbrace = (char *)memchr(*s, '}', send - *s);
    if (!rbrace) {
        (*s)++;
        while (*s < send && isBLANK(**s))
            (*s)++;
        while (*s < send && isOCTAL(**s))
            (*s)++;

        PERL_GROK_BSLASH_ERROR(exception_slot,
                          PERL_APPEND_ERROR_SYNTAX_ESCAPE_OCTAL_CLOSE_BRACE_MISSING,
                          perl_diag_error_syntax_escape_octal_close_brace_missing_idx);
    }

    (*s)++;
    while (isBLANK(**s))
        (*s)++;

    e = rbrace;
    while (*s < e && isBLANK(*(e - 1)))
        e--;

    numbers_len = e - *s;
    if (numbers_len == 0) {
        (*s)++;
        PERL_GROK_BSLASH_ERROR(exception_slot, PERL_APPEND_ERROR_SYNTAX_ESCAPE_OCTAL_DIGITS_MISSING,
                          perl_diag_error_syntax_escape_octal_digits_missing_idx);
    }

    *uv = grok_oct(*s, &numbers_len, &flags, NULL);
    if (UNLIKELY((flags & PERL_SCAN_GREATER_THAN_UV_MAX)
                 || (!allow_UV_MAX && *uv == UV_MAX)))
    {
        if (exception_slot)
            PERL_APPEND_ERROR_UNICODE_CODE_POINT_OCTAL_ESCAPE_OVERFLOW(
                exception_slot, numbers_len, *s, MAX_LEGAL_CP);
        *s = rbrace + 1;
        return perl_diag_error_unicode_code_point_octal_escape_overflow_idx;
    }

    while (isBLANK(**s)) {
        trailing_blanks_len++;
        (*s)++;
    }

    if (numbers_len + trailing_blanks_len != (STRLEN)(e - *s)) {
        *s += numbers_len;
        if (strict) {
            *s += UTF ? UTF8_SAFE_SKIP(*s, send) : 1;
            PERL_GROK_BSLASH_ERROR(exception_slot,
                              PERL_APPEND_ERROR_SYNTAX_ESCAPE_OCTAL_DIGIT_INVALID,
                              perl_diag_error_syntax_escape_octal_digit_invalid_idx);
        }

        if (allow_warning && ckWARN(WARN_DIGIT)) {
            if (exception_slot) {
                Perl_diag_append_alien_digit_warning(aTHX_
                    exception_slot, perl_diag_warning_syntax_digit_escape_terminated_early_idx,
                    8, numbers_len, *s, send, UTF, TRUE);
            }
        }
    }

    *s = rbrace + 1;
    return 0;
}

static UV
Perl_grok_bslash_x_internal(pTHX_ char **s, const char * const send, UV *uv,
                SV **exception_slot, const bool strict,
                const bool allow_UV_MAX, const bool UTF,
                const bool allow_warning)
{
    char *e;
    char *rbrace;
    STRLEN numbers_len;
    STRLEN trailing_blanks_len = 0;
    I32 flags = PERL_SCAN_DISALLOW_PREFIX
              | PERL_SCAN_SILENT_ILLDIGIT
              | PERL_SCAN_NOTIFY_ILLDIGIT
              | PERL_SCAN_SILENT_NON_PORTABLE
              | PERL_SCAN_SILENT_OVERFLOW;

    assert(*(*s - 1) == '\\');
    assert(**s == 'x');

    (*s)++;

    if (send <= *s) {
        if (strict)
            PERL_GROK_BSLASH_ERROR(exception_slot, PERL_APPEND_ERROR_SYNTAX_ESCAPE_HEX_DIGITS_MISSING,
                              perl_diag_error_syntax_escape_hex_digits_missing_idx);

        *uv = 0;
        return 0;
    }

    if (**s != '{') {
        numbers_len = strict ? 3 : 2;
        *uv = grok_hex(*s, &numbers_len, &flags, NULL);
        *s += numbers_len;

        if (numbers_len != 2
            && (strict || (flags & PERL_SCAN_NOTIFY_ILLDIGIT)))
        {
            if (numbers_len == 3) {
                PERL_GROK_BSLASH_ERROR(
                    exception_slot,
                    PERL_APPEND_ERROR_SYNTAX_ESCAPE_HEX_UNBRACED_DIGITS_EXCESS,
                    perl_diag_error_syntax_escape_hex_unbraced_digits_excess_idx);
            }
            else if (strict) {
                *s += UTF ? UTF8_SAFE_SKIP(*s, send) : 1;
                PERL_GROK_BSLASH_ERROR(exception_slot,
                                  PERL_APPEND_ERROR_SYNTAX_ESCAPE_HEX_UNBRACED_DIGIT_INVALID,
                                  perl_diag_error_syntax_escape_hex_unbraced_digit_invalid_idx);
            }
            else if (allow_warning && ckWARN(WARN_DIGIT)) {
                if (exception_slot) {
                    Perl_diag_append_alien_digit_warning(aTHX_
                        exception_slot, perl_diag_warning_syntax_digit_escape_terminated_early_idx,
                        16, numbers_len, *s, send, UTF, FALSE);
                }
            }
        }
        return 0;
    }

    rbrace = (char *)memchr(*s, '}', send - *s);
    if (!rbrace) {
        (*s)++;
        while (*s < send && isBLANK(**s))
            (*s)++;
        while (*s < send && isXDIGIT(**s))
            (*s)++;

        PERL_GROK_BSLASH_ERROR(exception_slot,
                          PERL_APPEND_ERROR_SYNTAX_ESCAPE_HEX_CLOSE_BRACE_MISSING,
                          perl_diag_error_syntax_escape_hex_close_brace_missing_idx);
    }

    (*s)++;
    while (isBLANK(**s))
        (*s)++;

    e = rbrace;
    while (*s < e && isBLANK(*(e - 1)))
        e--;

    numbers_len = e - *s;
    if (numbers_len == 0) {
        if (strict) {
            (*s)++;
            PERL_GROK_BSLASH_ERROR(
                exception_slot, PERL_APPEND_ERROR_SYNTAX_ESCAPE_HEX_BRACED_DIGITS_MISSING,
                perl_diag_error_syntax_escape_hex_braced_digits_missing_idx);
        }

        *s = rbrace + 1;
        *uv = 0;
        return 0;
    }

    flags |= PERL_SCAN_ALLOW_UNDERSCORES;
    *uv = grok_hex(*s, &numbers_len, &flags, NULL);
    if (UNLIKELY((flags & PERL_SCAN_GREATER_THAN_UV_MAX)
                 || (!allow_UV_MAX && *uv == UV_MAX)))
    {
        if (exception_slot)
            PERL_APPEND_ERROR_UNICODE_CODE_POINT_HEX_ESCAPE_OVERFLOW(exception_slot, numbers_len,
                                            *s, MAX_LEGAL_CP);
        *s = e + 1;
        return perl_diag_error_unicode_code_point_hex_escape_overflow_idx;
    }

    while (isBLANK(**s)) {
        trailing_blanks_len++;
        (*s)++;
    }

    if (numbers_len + trailing_blanks_len != (STRLEN)(e - *s)) {
        *s += numbers_len;
        if (strict) {
            *s += UTF ? UTF8_SAFE_SKIP(*s, send) : 1;
            PERL_GROK_BSLASH_ERROR(
                exception_slot, PERL_APPEND_ERROR_SYNTAX_ESCAPE_HEX_BRACED_DIGIT_INVALID,
                perl_diag_error_syntax_escape_hex_braced_digit_invalid_idx);
        }

        if (allow_warning && ckWARN(WARN_DIGIT)) {
            if (exception_slot) {
                Perl_diag_append_alien_digit_warning(aTHX_
                    exception_slot, perl_diag_warning_syntax_digit_escape_terminated_early_idx,
                    16, numbers_len, *s, send, UTF, TRUE);
            }
        }
    }

    *s = rbrace + 1;
    return 0;
}

UV
Perl_grok_bslash_o_diag(pTHX_ char **s, const char * const send, UV *uv,
                        SV **exception_slot, const bool strict,
                        const bool allow_UV_MAX, const bool UTF,
                        const bool allow_warning)
{
    PERL_ARGS_ASSERT_GROK_BSLASH_O_DIAG;
    return Perl_grok_bslash_o_internal(aTHX_ s, send, uv, exception_slot, strict,
                           allow_UV_MAX, UTF, allow_warning);
}

UV
Perl_grok_bslash_x_diag(pTHX_ char **s, const char * const send, UV *uv,
                        SV **exception_slot, const bool strict,
                        const bool allow_UV_MAX, const bool UTF,
                        const bool allow_warning)
{
    PERL_ARGS_ASSERT_GROK_BSLASH_X_DIAG;
    return Perl_grok_bslash_x_internal(aTHX_ s, send, uv, exception_slot, strict,
                           allow_UV_MAX, UTF, allow_warning);
}

/* Deprecated in Perl 5.45.4. */
bool
Perl_grok_bslash_o(pTHX_ char **s, const char * const send, UV *uv,
                   const char **message, U32 *packed_warn,
                   const bool strict, const bool allow_UV_MAX,
                   const bool UTF)
{
    PERL_ARGS_ASSERT_GROK_BSLASH_O;
    PERL_UNUSED_VAR(s);
    PERL_UNUSED_VAR(send);
    PERL_UNUSED_VAR(uv);
    PERL_UNUSED_VAR(message);
    PERL_UNUSED_VAR(packed_warn);
    PERL_UNUSED_VAR(strict);
    PERL_UNUSED_VAR(allow_UV_MAX);
    PERL_UNUSED_VAR(UTF);
    PERL_THROW_ERROR_SYNTAX_ESCAPE_LEGACY_API_UNCALLABLE("Perl_grok_bslash_o");
}

/* Deprecated in Perl 5.45.4. */
bool
Perl_grok_bslash_x(pTHX_ char **s, const char * const send, UV *uv,
                   const char **message, U32 *packed_warn,
                   const bool strict, const bool allow_UV_MAX,
                   const bool UTF)
{
    PERL_ARGS_ASSERT_GROK_BSLASH_X;
    PERL_UNUSED_VAR(s);
    PERL_UNUSED_VAR(send);
    PERL_UNUSED_VAR(uv);
    PERL_UNUSED_VAR(message);
    PERL_UNUSED_VAR(packed_warn);
    PERL_UNUSED_VAR(strict);
    PERL_UNUSED_VAR(allow_UV_MAX);
    PERL_UNUSED_VAR(UTF);
    PERL_THROW_ERROR_SYNTAX_ESCAPE_LEGACY_API_UNCALLABLE("Perl_grok_bslash_x");
}

/*
 *      Whereof one cannot speak, thereof one must be silent.
 *              --Ludwig Wittgenstein
 *
 *     [Proposition 7 of _Tractatus Logico-Philosophicus_]
 */

/*
 * ex: set ts=8 sts=4 sw=4 et:
 */
