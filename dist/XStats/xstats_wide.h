#ifndef XSTATS_WIDE_H
#define XSTATS_WIDE_H

/* Query scratch includes headroom for exact centred products and rounding. */
#define XS_WIDE_BITS (4 * (NV_MAX_EXP - XS_SUM_ORIGIN) + 130 + 2 * NV_MANT_DIG + 2)
#define XS_WIDE_LIMBS ((XS_WIDE_BITS + 15) / 16)
#if XS_WIDE_LIMBS > 65535
#error XStats scratch bounds exceed U16 metadata
#endif

typedef struct {
    /* Every limb outside [lo,hi) is zero. Initialize the whole scratch value. */
    U16 limb[XS_WIDE_LIMBS];
    U16 lo, hi;
    I8 sign;
} XStatsWide;

static void
xs_wide_trim(XStatsWide *s, U32 lo, U32 hi)
{
    while (hi > lo && !s->limb[hi - 1])
        --hi;
    while (lo < hi && !s->limb[lo])
        ++lo;
    if (lo == hi)
        s->sign = 0, s->lo = s->hi = 0;
    else
        s->lo = (U16)lo, s->hi = (U16)hi;
}

static I32
xs_wide_bits(const XStatsWide *s)
{
    I32 bits;
    U16 top;
    if (!s->sign)
        return 0;
    bits = 16 * ((I32)s->hi - 1);
    top = s->limb[s->hi - 1];
    while (top)
        ++bits, top >>= 1;
    return bits;
}

static U16
xs_wide_word(const XStatsWide *s, I32 index)
{
    return index >= s->lo && index < s->hi ? s->limb[index] : 0;
}

static U16
xs_wide_shift_word(const XStatsWide *s, I32 shift, I32 index)
{
    I32 whole = shift / 16, part = shift % 16;
    U32 word = (U32)xs_wide_word(s, index - whole) << part;
    if (part)
        word |= xs_wide_word(s, index - whole - 1) >> (16 - part);
    return (U16)(word & 0xffff);
}

static I8
xs_wide_compare(const XStatsWide *a, I32 ashift, const XStatsWide *b, I32 bshift)
{
    I32 abits, bbits, i, lo;
    assert(ashift >= 0 && ashift <= 16 * XS_WIDE_LIMBS);
    assert(bshift >= 0 && bshift <= 16 * XS_WIDE_LIMBS);
    if (!a->sign || !b->sign)
        return a->sign ? 1 : b->sign ? -1 : 0;
    abits = xs_wide_bits(a) + ashift;
    bbits = xs_wide_bits(b) + bshift;
    if (abits != bbits)
        return abits > bbits ? 1 : -1;
    lo = (I32)a->lo + ashift / 16;
    if ((I32)b->lo + bshift / 16 < lo)
        lo = (I32)b->lo + bshift / 16;
    for (i = (abits + 15) / 16; i-- > lo;) {
        U16 av = xs_wide_shift_word(a, ashift, i);
        U16 bv = xs_wide_shift_word(b, bshift, i);
        if (av != bv)
            return av > bv ? 1 : -1;
    }
    return 0;
}

static void
xs_wide_scalar(XStatsWide *out, const XStatsExactSum *source)
{
    Zero(out, 1, XStatsWide);
    if (!source->sign)
        return;
    Copy(source->limb + source->lo, out->limb + source->lo, source->hi - source->lo,
         U16);
    out->lo = source->lo;
    out->hi = source->hi;
    out->sign = source->sign;
}

static void
xs_wide_u32(XStatsWide *out, U32 value)
{
    Zero(out, 1, XStatsWide);
    if (!value)
        return;
    out->limb[0] = (U16)(value & 0xffff);
    out->limb[1] = (U16)(value >> 16);
    out->sign = 1;
    xs_wide_trim(out, 0, 2);
}

static XStatsSumStatus
xs_wide_add_words(XStatsWide *s, const U16 *source, U32 slo, U32 shi, I8 sign)
{
    U32 lo, hi, i, a, b, carry = 0;
    I8 comparison = 0;
    if (slo >= shi)
        return XS_SUM_OK;
    if (shi > XS_WIDE_LIMBS)
        return XS_SUM_OVERFLOW;
    if (!s->sign) {
        Copy(source, s->limb + slo, shi - slo, U16);
        s->sign = sign;
        xs_wide_trim(s, slo, shi);
        return XS_SUM_OK;
    }
    lo = s->lo < slo ? s->lo : slo;
    hi = s->hi > shi ? s->hi : shi;
    if (s->sign == sign) {
        for (i = lo; i < hi; ++i) {
            b = i >= slo && i < shi ? source[i - slo] : 0;
            a = (U32)s->limb[i] + b + carry;
            s->limb[i] = (U16)(a & 0xffff);
            carry = a >> 16;
        }
        if (carry) {
            if (hi == XS_WIDE_LIMBS)
                return XS_SUM_OVERFLOW;
            s->limb[hi++] = (U16)carry;
        }
    } else {
        for (i = hi; i-- > lo;) {
            a = s->limb[i];
            b = i >= slo && i < shi ? source[i - slo] : 0;
            if (a != b) {
                comparison = a > b ? 1 : -1;
                break;
            }
        }
        if (!comparison) {
            Zero(s->limb + lo, hi - lo, U16);
            s->sign = 0;
            s->lo = s->hi = 0;
            return XS_SUM_OK;
        }
        for (i = lo; i < hi; ++i) {
            a = s->limb[i];
            b = i >= slo && i < shi ? source[i - slo] : 0;
            if (comparison < 0) {
                U32 swap = a;
                a = b;
                b = swap;
            }
            s->limb[i] = (U16)((a - b - carry) & 0xffff);
            carry = a < b + carry;
        }
        if (comparison < 0)
            s->sign = sign;
    }
    xs_wide_trim(s, lo, hi);
    return XS_SUM_OK;
}

static XStatsSumStatus
xs_wide_add(XStatsWide *s, const XStatsWide *other, bool subtract)
{
    if (!other->sign)
        return XS_SUM_OK;
    return xs_wide_add_words(s, other->limb + other->lo, other->lo, other->hi,
                             subtract ? -other->sign : other->sign);
}

static XStatsSumStatus
xs_wide_shift(XStatsWide *out, const XStatsWide *source, I32 shift)
{
    I32 bits, lo, hi, i;
    I8 sign = source->sign;
    if (shift < 0)
        return XS_SUM_INVALID;
    if (!sign) {
        if (out != source)
            Zero(out, 1, XStatsWide);
        return XS_SUM_OK;
    }
    bits = xs_wide_bits(source);
    if (shift > XS_WIDE_LIMBS * 16 - bits)
        return XS_SUM_OVERFLOW;
    lo = source->lo + shift / 16;
    hi = (bits + shift + 15) / 16;
    if (out != source)
        Zero(out, 1, XStatsWide);
    for (i = hi; i-- > lo;)
        out->limb[i] = xs_wide_shift_word(source, shift, i);
    if (out == source)
        Zero(out->limb, lo, U16);
    out->sign = sign;
    xs_wide_trim(out, (U32)lo, (U32)hi);
    return XS_SUM_OK;
}

static XStatsSumStatus
xs_wide_multiply_words(XStatsWide *out, const XStatsWide *a, const U16 *b, U32 blo,
                       U32 bhi, I8 sign)
{
    U32 i, j, k, word, carry, hi;
    if (out == a)
        return XS_SUM_INVALID;
    Zero(out, 1, XStatsWide);
    if (!a->sign || blo >= bhi || !sign)
        return XS_SUM_OK;
    for (i = a->lo; i < a->hi; ++i) {
        if (!a->limb[i])
            continue;
        carry = 0;
        for (j = blo; j < bhi; ++j) {
            k = i + j;
            if (k >= XS_WIDE_LIMBS) {
                if (b[j - blo] || carry)
                    return XS_SUM_OVERFLOW;
                continue;
            }
            word = (U32)a->limb[i] * b[j - blo] + out->limb[k] + carry;
            out->limb[k] = (U16)(word & 0xffff);
            carry = word >> 16;
        }
        k = i + bhi;
        while (carry) {
            if (k >= XS_WIDE_LIMBS)
                return XS_SUM_OVERFLOW;
            word = (U32)out->limb[k] + carry;
            out->limb[k++] = (U16)(word & 0xffff);
            carry = word >> 16;
        }
    }
    out->sign = (I8)(a->sign * sign);
    hi = a->hi + bhi;
    if (hi > XS_WIDE_LIMBS)
        hi = XS_WIDE_LIMBS;
    xs_wide_trim(out, a->lo + blo, hi);
    return XS_SUM_OK;
}

static XStatsSumStatus
xs_wide_multiply(XStatsWide *out, const XStatsWide *a, const XStatsWide *b)
{
    if (out == b)
        return XS_SUM_INVALID;
    return xs_wide_multiply_words(out, a, b->limb + b->lo, b->lo, b->hi, b->sign);
}

static XStatsSumStatus
xs_wide_multiply_u32(XStatsWide *out, const XStatsWide *a, U32 b)
{
    U16 words[2];
    words[0] = (U16)(b & 0xffff);
    words[1] = (U16)(b >> 16);
    return xs_wide_multiply_words(out, a, words, 0, words[1] ? 2 : 1, b ? 1 : 0);
}

static XStatsSumStatus
xs_wide_product(XStatsWide *sum, NV a, NV b)
{
    U16 av[XS_TERM_LIMBS], bv[XS_TERM_LIMBS], product[2 * XS_TERM_LIMBS];
    U32 alo, ahi, blo, bhi, i, j, word, carry;
    I8 asign, bsign;
    XStatsSumStatus status;
    status = xs_sum_term(a, av, &alo, &ahi, &asign);
    if (status != XS_SUM_OK)
        return status;
    status = xs_sum_term(b, bv, &blo, &bhi, &bsign);
    if (status != XS_SUM_OK)
        return status;
    if (!asign || !bsign)
        return XS_SUM_OK;
    Zero(product, 2 * XS_TERM_LIMBS, U16);
    for (i = 0; i < ahi - alo; ++i) {
        carry = 0;
        for (j = 0; j < bhi - blo; ++j) {
            word = (U32)av[i] * bv[j] + product[i + j] + carry;
            product[i + j] = (U16)(word & 0xffff);
            carry = word >> 16;
        }
        product[i + bhi - blo] = (U16)carry;
    }
    return xs_wide_add_words(sum, product, alo + blo, ahi + bhi, (I8)(asign * bsign));
}

/* The caller has established that s is at least b*2**shift. */
static XStatsSumStatus
xs_wide_subtract_shift(XStatsWide *s, const XStatsWide *b, I32 shift)
{
    I32 lo = s->lo, hi = s->hi, i;
    U32 a, word, borrow = 0;
    if ((I32)b->lo + shift / 16 < lo)
        lo = (I32)b->lo + shift / 16;
    for (i = lo; i < hi; ++i) {
        a = s->limb[i];
        word = xs_wide_shift_word(b, shift, i);
        s->limb[i] = (U16)((a - word - borrow) & 0xffff);
        borrow = a < word + borrow;
    }
    if (borrow)
        return XS_SUM_INVALID;
    xs_wide_trim(s, (U32)lo, (U32)hi);
    return XS_SUM_OK;
}

static XStatsSumStatus
xs_wide_divide(XStatsWide *remainder, const XStatsWide *denominator,
               XStatsWide *quotient)
{
    I32 bit, word;
    XStatsSumStatus status;
    if (denominator->sign <= 0 || remainder->sign < 0 || remainder == denominator ||
        remainder == quotient || denominator == quotient)
        return XS_SUM_INVALID;
    Zero(quotient, 1, XStatsWide);
    for (bit = xs_wide_bits(remainder) - xs_wide_bits(denominator); bit >= 0; --bit) {
        if (xs_wide_compare(remainder, 0, denominator, bit) < 0)
            continue;
        status = xs_wide_subtract_shift(remainder, denominator, bit);
        if (status != XS_SUM_OK)
            return status;
        word = bit / 16;
        quotient->limb[word] |= (U16)((U32)1 << (bit % 16));
        if (!quotient->sign)
            quotient->lo = quotient->hi = (U16)word;
        quotient->sign = 1;
        if (word < quotient->lo)
            quotient->lo = (U16)word;
        if (word >= quotient->hi)
            quotient->hi = (U16)(word + 1);
    }
    return XS_SUM_OK;
}

static NV
xs_wide_coefficient(const XStatsWide *s)
{
    NV value = 0;
    I32 i;
    for (i = s->hi; i-- > 0;)
        value = Perl_ldexp(value, 16) + s->limb[i];
    return value;
}

/* Buffers are distinct from the inputs and each other. */
static XStatsSumStatus
xs_wide_ratio(const XStatsWide *a, const XStatsWide *b, I32 origin, NV *out,
              XStatsWide *remainder, XStatsWide *denominator, XStatsWide *quotient)
{
    I32 exponent, quantum, shift;
    I8 comparison;
    U16 one = 1;
    XStatsSumStatus status;
    NV value;
    const XStatsWide *buffers[] = {a, b, remainder, denominator, quotient};
    U8 i, j;
    if (!XS_SUM_SUPPORTED)
        return XS_SUM_UNSUPPORTED;
    for (i = 2; i < C_ARRAY_LENGTH(buffers); ++i)
        for (j = 0; j < i; ++j)
            if (buffers[i] == buffers[j])
                return XS_SUM_INVALID;
    if (b->sign <= 0)
        return XS_SUM_INVALID;
    if (!a->sign) {
        *out = 0;
        return XS_SUM_OK;
    }
    exponent = xs_wide_bits(a) - xs_wide_bits(b);
    comparison = exponent >= 0 ? xs_wide_compare(a, 0, b, exponent)
                               : xs_wide_compare(a, -exponent, b, 0);
    if (comparison < 0)
        --exponent;
    exponent += origin;
    if (exponent >= NV_MAX_EXP)
        return XS_SUM_OVERFLOW;
    if (exponent < XS_SUM_ORIGIN - 1) {
        *out = a->sign < 0 ? -(NV)0 : (NV)0;
        return XS_SUM_OK;
    }
    quantum = exponent - NV_MANT_DIG + 1;
    if (quantum < XS_SUM_ORIGIN)
        quantum = XS_SUM_ORIGIN;
    shift = origin - quantum;
    *remainder = *a;
    remainder->sign = 1;
    *denominator = *b;
    status = shift >= 0 ? xs_wide_shift(remainder, remainder, shift)
                        : xs_wide_shift(denominator, denominator, -shift);
    if (status != XS_SUM_OK)
        return XS_SUM_INVALID;
    status = xs_wide_divide(remainder, denominator, quotient);
    if (status != XS_SUM_OK)
        return status;
    comparison = xs_wide_compare(remainder, 1, denominator, 0);
    if (comparison > 0 || (!comparison && (quotient->limb[0] & 1))) {
        status = xs_wide_add_words(quotient, &one, 0, 1, 1);
        if (status != XS_SUM_OK)
            return status;
    }
    /* ldexp can saturate under directed hardware rounding modes. */
    if (xs_wide_bits(quotient) + quantum > NV_MAX_EXP)
        return XS_SUM_OVERFLOW;
    value = Perl_ldexp(xs_wide_coefficient(quotient), quantum);
    if (!Perl_isfinite(value))
        return XS_SUM_OVERFLOW;
    *out = a->sign < 0 ? -value : value;
    return XS_SUM_OK;
}

#endif
