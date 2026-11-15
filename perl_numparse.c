/* perl_numparse.c
 *
 * Copyright (C) 2026 Yves Orton
 *
 * You may distribute under the terms of either the GNU General Public
 * License or the Artistic License, as specified in the README file.
 */

#include "EXTERN.h"
#define PERL_IN_PERL_NUMPARSE_C
#include "perl.h"

/*
=for apidoc_section $numeric
=cut
*/

typedef struct {
    const char *end;
    const char *radix;
    STRLEN radix_len;
} numeric_span;

static I32
S_grok_number_span(pTHX_ const char *pv, STRLEN len, UV *valuep,
                   U32 flags, numeric_span *span)
{
  const char *s = pv;
  const char * const send = pv + len;
  const char *d;
  int numtype = 0;

  if (span) {
      span->end = pv;
      span->radix = NULL;
      span->radix_len = 0;
  }
  if (!len)
      return 0;

  if (UNLIKELY(isSPACE(*s))) {
      s++;
      while (s < send) {
        if (LIKELY(! isSPACE(*s))) goto non_space;
        s++;
      }
      return 0;
    non_space: ;
  }

  /* See if signed.  This assumes it is more likely to be unsigned, so
   * penalizes signed by an extra conditional; rewarding unsigned by one fewer
   * (because we detect '+' and '-' with a single test and then add a
   * conditional to determine which) */
  if (UNLIKELY((*s & ~('+' ^ '-')) == ('+' & '-') )) {

    /* Here, on ASCII platforms, *s is one of: 0x29 = ')', 2B = '+', 2D = '-',
     * 2F = '/'.  That is, it is either a sign, or a character that doesn't
     * belong in a number at all (unless it's a radix character in a weird
     * locale).  Given this, it's far more likely to be a minus than the
     * others.  (On EBCDIC it is one of 42, 44, 46, 48, 4A, 4C, 4E,  (not 40
     * because can't be a space)    60, 62, 64, 66, 68, 6A, 6C, 6E.  Again,
     * only potentially a weird radix character, or 4E='+', or 60='-') */
    if (LIKELY(*s == '-')) {
        s++;
        numtype = IS_NUMBER_NEG;
    }
    else if (LIKELY(*s == '+'))
        s++;
    else  /* Can't just return failure here, as it could be a weird radix
             character */
        goto done_sign;

    if (UNLIKELY(s == send))
        return 0;
  done_sign: ;
    }

  /* The first digit (after optional sign): note that might
   * also point to "infinity" or "nan", or "1.#INF". */
  d = s;

  /* next must be digit or the radix separator or beginning of infinity/nan */
  if (LIKELY(isDIGIT(*s))) {
    STRLEN len = send - s;
    I32 grok_int_flags = PERL_SCAN_SILENT_ILLDIGIT
                       | PERL_SCAN_SILENT_NON_PORTABLE
                       | PERL_SCAN_DISCARD_INSTEAD_OF_OVERFLOW
              ;
    UV value = grok_uint_by_base(s, &len, &grok_int_flags, NULL,
                                 10, CC_mask_(CC_DIGIT_), 0);
    s += len;
    if (span) span->end = s;

    if (grok_int_flags & PERL_SCAN_DISCARD_INSTEAD_OF_OVERFLOW) {
        numtype |= IS_NUMBER_GREATER_THAN_UV_MAX;
    }
    else {
        // dent XXX

    numtype |= IS_NUMBER_IN_UV;

    if (valuep) {
        *valuep = value;
    }

    if (s >= send) {
        return numtype;
    }
    }

    const char * const radix = s;
    if (GROK_NUMERIC_RADIX(&s, send)) {
      if (span) {
          span->radix = radix;
          span->radix_len = s - radix;
      }
      numtype |= IS_NUMBER_NOT_INT;
      while (s < send && isDIGIT(*s))  /* optional digits after the radix */
        s++;
    }
  } /* End of *s is a digit */
  else if (GROK_NUMERIC_RADIX(&s, send)) {
    if (span) {
        span->radix = d;
        span->radix_len = s - d;
    }
    numtype |= IS_NUMBER_NOT_INT | IS_NUMBER_IN_UV; /* valuep assigned below */
    /* no digits before the radix means we need digits after it */
    if (s < send && isDIGIT(*s)) {
      do {
        s++;
      } while (s < send && isDIGIT(*s));
      if (valuep) {
        /* integer approximation is valid - it's 0.  */
        *valuep = 0;
      }
    }
    else
        return 0;
  }

  if (span && s > d) span->end = s;

  if (LIKELY(s > d) && s < send) {
    /* we can have an optional exponent part */
    if (UNLIKELY(isALPHA_FOLD_EQ(*s, 'e'))) {
      s++;
      if (s < send && (*s == '-' || *s == '+'))
        s++;
      if (s < send && isDIGIT(*s)) {
        do {
          s++;
        } while (s < send && isDIGIT(*s));
      }
      else if (flags & PERL_SCAN_TRAILING)
        return numtype | IS_NUMBER_TRAILING;
      else
        return 0;

      if (span) span->end = s;

      /* The only flag we keep is sign.  Blow away any "it's UV"  */
      numtype &= IS_NUMBER_NEG;
      numtype |= IS_NUMBER_NOT_INT;
    }
  }

  while (s < send) {
    if (LIKELY(! isSPACE(*s))) goto end_space;
    s++;
  }
  return numtype;

 end_space:

  if (UNLIKELY(memEQs(pv, len, "0 but true"))) {
    if (valuep)
      *valuep = 0;
    if (span) span->end = send;
    return IS_NUMBER_IN_UV;
  }

  /* We could be e.g. at "Inf" or "NaN", or at the "#" of "1.#INF". */
  if ((send - s > 2) && UNLIKELY(memCHRs("inqs#", toFOLD(*s)))) {
      /* Really detect inf/nan. Start at d, not s, since the above
       * code might have already consumed the "1." or "1". */
      const int infnan = grok_infnan(&d, send);

      if (span && (infnan & (IS_NUMBER_INFINITY | IS_NUMBER_NAN))) {
          span->end = d;
          span->radix = NULL;
          span->radix_len = 0;
      }
      if ((infnan & IS_NUMBER_TRAILING) && !(flags & PERL_SCAN_TRAILING)) {
          return 0;
      }
      if ((infnan & IS_NUMBER_INFINITY)) {
          return (numtype | infnan); /* Keep sign for infinity. */
      }
      else if ((infnan & IS_NUMBER_NAN)) {
          return (numtype | infnan) & ~IS_NUMBER_NEG; /* Clear sign for nan. */
      }
  }
  else if (flags & PERL_SCAN_TRAILING) {
    return numtype | IS_NUMBER_TRAILING;
  }

  return 0;
}

int
Perl_grok_number_flags(pTHX_ const char *pv, STRLEN len, UV *valuep, U32 flags)
{
    PERL_ARGS_ASSERT_GROK_NUMBER_FLAGS;

    return S_grok_number_span(aTHX_ pv, len, valuep, flags, NULL);
}

/* Return a NUL-terminated prefix in the standard numeric locale's syntax.
 * The scanner supplies the radix span so we only replace the radix it
 * actually accepted, including a multibyte locale radix. */
static char *
S_prepare_number(pTHX_ const char *s, STRLEN len, U32 *flags, bool *nonzero)
{
    numeric_span span;
    const char *p;
    char *copy;
    STRLEN prefix_len;
    U32 classification;

    *flags = 0;
    *nonzero = FALSE;
    classification = (U32) S_grok_number_span(aTHX_ s, len, NULL,
                                               PERL_SCAN_TRAILING, &span);
    if (span.end == s)
        return NULL;

    prefix_len = span.end - s;
    /* Some failed special spellings leave a valid decimal prefix, for
     * example "23nan".  Only those failures need a second classification. */
    if (!classification)
        classification = (U32) grok_number(s, prefix_len, NULL);
    classification &= ~IS_NUMBER_TRAILING;
    if (!(classification & (IS_NUMBER_IN_UV | IS_NUMBER_GREATER_THAN_UV_MAX
                            | IS_NUMBER_NOT_INT)))
        return NULL;

    p = span.end;
    while (p < s + len && isSPACE(*p)) p++;
    *flags = classification | ((p < s + len) ? IS_NUMBER_TRAILING : 0);

    /* The system converters don't know Perl's alternative spellings. */
    if (classification & IS_NUMBER_INFINITY)
        return savepv((classification & IS_NUMBER_NEG) ? "-inf" : "inf");
    if (classification & IS_NUMBER_NAN)
        return savepv("nan");
    if (memEQs(s, prefix_len, "0 but true"))
        return savepv("0");

    /* my_atof3 rejects hex and binary prefixes before applying the sign.
     * Preserve its positive zero for inputs such as "-0x1". */
    p = s;
    while (p < span.end && isSPACE(*p)) p++;
    if (p < span.end && (*p == '+' || *p == '-')) p++;
    if (span.end == p + 1 && *p == '0' && span.end < s + len
        && (isALPHA_FOLD_EQ(*span.end, 'x')
            || isALPHA_FOLD_EQ(*span.end, 'b')))
        return savepv("0");

    if (span.radix) {
        STRLEN before = span.radix - s;
        STRLEN after = span.end - span.radix - span.radix_len;
        copy = savepvn(s, before + 1 + after);
        copy[before] = '.';
        Copy(span.radix + span.radix_len, copy + before + 1, after, char);
    }
    else
        copy = savepvn(s, prefix_len);

    /* Exponent digits don't make a zero significand nonzero. */
    for (p = copy; *p && !isALPHA_FOLD_EQ(*p, 'e'); p++) {
        if (isDIGIT(*p) && *p != '0') {
            *nonzero = TRUE;
            break;
        }
    }
    return copy;
}

/* Use Perl's infinity and NaN values.  Older system converters may not
 * recognize even the standard special spellings. */
static NV
S_parse_special(pTHX_ U32 flags)
{
    PERL_UNUSED_CONTEXT;
    PERL_UNUSED_ARG(flags);
#ifdef NV_NAN
    if (flags & IS_NUMBER_NAN)
        return NV_NAN;
#endif
#ifdef NV_INF
    if (flags & IS_NUMBER_INFINITY)
        return (flags & IS_NUMBER_NEG) ? -NV_INF : NV_INF;
#endif
    return 0;
}

/* Keep syntax and range policy common, but convert directly to each target
 * type.  In particular, parsing a float through double can round twice. */
#define PARSE_NUMBER_BODY(type, convert, minimum, maximum)                  \
STMT_START {                                                                \
    const I32 saved_errno = errno;                                          \
    U32 status;                                                             \
    bool nonzero;                                                           \
    char *text;                                                             \
    type value = 0;                                                         \
    I32 conversion_errno;                                                   \
    DECLARATION_FOR_LC_NUMERIC_MANIPULATION;                                \
    text = S_prepare_number(aTHX_ s, len, &status, &nonzero);               \
    if (text) {                                                             \
        if (status & (IS_NUMBER_INFINITY | IS_NUMBER_NAN))                  \
            value = (type) S_parse_special(aTHX_ status);                   \
        else {                                                              \
            STORE_LC_NUMERIC_SET_STANDARD();                                \
            LOCK_LC_NUMERIC_STANDARD();                                     \
            errno = 0;                                                      \
            value = convert;                                                \
            conversion_errno = errno;                                       \
            UNLOCK_LC_NUMERIC_STANDARD();                                   \
            RESTORE_LC_NUMERIC();                                           \
                                                                            \
            if (value > (maximum) || value < -(maximum)                     \
                || (conversion_errno == ERANGE                              \
                    && (value >= 1 || value <= -1)))                        \
                status |= PERL_PARSE_OVERFLOW;                              \
            else if (conversion_errno == ERANGE || (value == 0 && nonzero)) \
                status |= PERL_PARSE_UNDERFLOW;                             \
            if ((value > 0 && value < (minimum))                            \
                || (value < 0 && value > -(minimum)))                       \
                status |= PERL_PARSE_SUBNORMAL;                             \
        }                                                                   \
        Safefree(text);                                                     \
    }                                                                       \
    if (flags) *flags = status;                                             \
    errno = saved_errno;                                                    \
    return value;                                                           \
} STMT_END


static NV
S_parse_native(pTHX_ const char *text)
{
    NV value = 0;
    my_atof3(text, &value, 0);
    return value;
}

NV
Perl_parse_nv(pTHX_ const char *s, STRLEN len, U32 *flags)
{
    PERL_ARGS_ASSERT_PARSE_NV;
    PARSE_NUMBER_BODY(NV, S_parse_native(aTHX_ text), NV_MIN, NV_MAX);
}

#if defined(HAS_STRTOF)
float
Perl_parse_float(pTHX_ const char *s, STRLEN len, U32 *flags)
{
    PERL_ARGS_ASSERT_PARSE_FLOAT;
    PARSE_NUMBER_BODY(float, strtof(text, NULL), FLT_MIN, FLT_MAX);
}
#endif

#if defined(HAS_STRTOD)
double
Perl_parse_double(pTHX_ const char *s, STRLEN len, U32 *flags)
{
    PERL_ARGS_ASSERT_PARSE_DOUBLE;
    PARSE_NUMBER_BODY(double, strtod(text, NULL), DBL_MIN, DBL_MAX);
}
#endif

#if defined(HAS_LONG_DOUBLE) && defined(HAS_STRTOLD)
long double
Perl_parse_ld(pTHX_ const char *s, STRLEN len, U32 *flags)
{
    PERL_ARGS_ASSERT_PARSE_LD;
#  if defined(__MINGW64_VERSION_MAJOR)
    PARSE_NUMBER_BODY(long double, __mingw_strtold(text, NULL), LDBL_MIN, LDBL_MAX);
#  else
    PARSE_NUMBER_BODY(long double, strtold(text, NULL), LDBL_MIN, LDBL_MAX);
#  endif
}
#endif

#ifdef USE_QUADMATH
__float128
Perl_parse_f128(pTHX_ const char *s, STRLEN len, U32 *flags)
{
    PERL_ARGS_ASSERT_PARSE_F128;
    PARSE_NUMBER_BODY(__float128, strtoflt128(text, NULL), FLT128_MIN, FLT128_MAX);
}
#endif
#undef PARSE_NUMBER_BODY

/*
=for apidoc parse_nv
=for apidoc_flag PERL_PARSE_OVERFLOW
=for apidoc_flag PERL_PARSE_UNDERFLOW
=for apidoc_flag PERL_PARSE_SUBNORMAL
=for apidoc_item parse_float
=for apidoc_item parse_double
=for apidoc_item parse_ld
=for apidoc_item parse_f128

Convert the numeric prefix of C<s> directly to the return type.  Exactly
C<len> bytes are available.  They need not be NUL-terminated, and zero length
means empty input.  An embedded NUL is trailing nonnumeric content.

These functions follow Perl's numeric string syntax, including leading and
trailing whitespace, signs, decimal exponents, C<Inf>, C<NaN>, their alternate
Perl spellings, and the exact string C<0 but true>.  Hexadecimal and binary
prefixes are not interpreted.  A dot radix is always accepted.  A locale
radix is accepted within the lexical scope of C<use locale>, as with
L</my_atof>.  NaN signs and payloads are not retained.

If C<flags> is non-NULL, it receives C<grok_number>-style C<IS_NUMBER_*>
classification of the recognized prefix.  These bits describe the input,
rather than the rounded result.  C<IS_NUMBER_IN_UV> does not promise exact
conversion to the return type.  C<IS_NUMBER_TRAILING> indicates
remaining non-whitespace content.  No numeric prefix gives zero flags and a
zero return value.  Conversion does not warn and preserves the caller's
C<errno>.  Callers choose whether to reject trailing content or range errors.

The following disjoint conversion flags may be added:

=over 4

=item C<PERL_PARSE_OVERFLOW>

A finite input overflows the target type.  The returned value is the system
converter's result, which may be infinity or a finite limit depending on the
rounding mode.  An explicit infinity does not set this flag.

=item C<PERL_PARSE_UNDERFLOW>

The converter reports underflow, or a nonzero significand converts to zero.
Underflow can produce a nonzero subnormal result.

=item C<PERL_PARSE_SUBNORMAL>

The result is finite and nonzero, with magnitude below the target type's
minimum normal value.  This flag is independent of underflow.

=back

C<parse_nv> is always available.  On platforms without a system converter for
C<NV>, its fallback detects infinite overflow and nonzero-to-zero underflow,
but cannot report every range error involving a finite nonzero result.
C<parse_float> requires C<HAS_STRTOF> and returns C<float>.
C<parse_double> requires C<HAS_STRTOD> and returns C<double>.
C<parse_ld> requires C<HAS_LONG_DOUBLE> and C<HAS_STRTOLD>.
C<parse_f128> requires C<USE_QUADMATH> and returns its IEEE binary128 type.
No finite typed conversion passes through C<NV> first.

=cut
*/
