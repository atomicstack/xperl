#ifndef XSTATS_SUM_H
#define XSTATS_SUM_H

/* Exact sums of finite, converted NVs, with headroom for a U32 count. */
#define XS_SUM_ORIGIN (NV_MIN_EXP - NV_MANT_DIG)
#define XS_SUM_BITS (NV_MAX_EXP + 32 - XS_SUM_ORIGIN)
#define XS_SUM_LIMBS ((XS_SUM_BITS + 15) / 16)
#define XS_TERM_LIMBS ((NV_MANT_DIG + 30) / 16)

#if FLT_RADIX == 2 &&                                                                  \
    ((NV_MANT_DIG == 53 && NV_MIN_EXP == -1021 && NV_MAX_EXP == 1024) ||               \
     (NV_MANT_DIG == 64 && NV_MIN_EXP == -16381 && NV_MAX_EXP == 16384) ||             \
     (NV_MANT_DIG == 113 && NV_MIN_EXP == -16381 && NV_MAX_EXP == 16384))
#define XS_SUM_SUPPORTED 1
#else
#define XS_SUM_SUPPORTED 0
#endif

enum { XS_SUM_OK, XS_SUM_OVERFLOW, XS_SUM_UNSUPPORTED, XS_SUM_INVALID };
typedef U8 XStatsSumStatus;

typedef struct {
    U16 limb[XS_SUM_LIMBS];
    U16 lo, hi;
    I8 sign;
} XStatsExactSum;

/* frexp requires an int pointer. Keep that ABI type out of our state. */
static NV
xs_nv_parts(NV value, I32 *exponent)
{
    int native_exponent;
    NV fraction = Perl_frexp(value, &native_exponent);
    *exponent = (I32)native_exponent;
    return fraction;
}

static bool
xs_sum_valid(const XStatsExactSum *s)
{
    if (!s->sign)
        return s->lo == 0 && s->hi == 0;
    return (s->sign == 1 || s->sign == -1) && s->lo < s->hi && s->hi <= XS_SUM_LIMBS &&
           s->limb[s->lo] != 0 && s->limb[s->hi - 1] != 0;
}

static void
xs_sum_trim(XStatsExactSum *s, U32 lo, U32 hi)
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

/* Source words start at source_lo, rather than requiring a full-size term. */
static XStatsSumStatus
xs_sum_words(XStatsExactSum *s, const U16 *source, U32 source_lo, U32 source_hi,
             I8 sign)
{
    U32 lo, hi, i, a, b, carry = 0;
    I8 comparison;
    if (source_lo >= source_hi)
        return XS_SUM_OK;
    if (source_hi > XS_SUM_LIMBS)
        return XS_SUM_OVERFLOW;
    if (!s->sign) {
        for (i = source_lo; i < source_hi; ++i)
            s->limb[i] = source[i - source_lo];
        s->sign = (I8)sign;
        xs_sum_trim(s, source_lo, source_hi);
        return XS_SUM_OK;
    }
    lo = s->lo < source_lo ? s->lo : source_lo;
    hi = s->hi > source_hi ? s->hi : source_hi;
    if (s->sign == sign) {
        for (i = lo; i < hi; ++i) {
            a = s->limb[i];
            b = i >= source_lo && i < source_hi ? source[i - source_lo] : 0;
            a += b + carry;
            s->limb[i] = (U16)(a & 0xffff);
            carry = a >> 16;
        }
        if (carry) {
            if (hi == XS_SUM_LIMBS)
                return XS_SUM_OVERFLOW;
            s->limb[hi++] = (U16)carry;
        }
    } else {
        comparison = 0;
        for (i = hi; i-- > lo;) {
            a = s->limb[i];
            b = i >= source_lo && i < source_hi ? source[i - source_lo] : 0;
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
            b = i >= source_lo && i < source_hi ? source[i - source_lo] : 0;
            if (comparison < 0) {
                U32 swap = a;
                a = b;
                b = swap;
            }
            s->limb[i] = (U16)((a - b - carry) & 0xffff);
            carry = a < b + carry;
        }
        if (comparison < 0)
            s->sign = (I8)sign;
    }
    xs_sum_trim(s, lo, hi);
    return XS_SUM_OK;
}

static XStatsSumStatus
xs_sum_term(NV x, U16 *term, U32 *term_lo, U32 *term_hi, I8 *sign)
{
    NV fraction;
    I32 exponent, position;
    U32 lo, hi, word;
    if (!XS_SUM_SUPPORTED)
        return XS_SUM_UNSUPPORTED;
    if (!x) {
        *term_lo = *term_hi = 0;
        *sign = 0;
        return XS_SUM_OK;
    }
    if (!Perl_isfinite(x))
        return XS_SUM_INVALID;
    fraction = xs_nv_parts(Perl_fabs(x), &exponent);
    position = exponent - NV_MANT_DIG - XS_SUM_ORIGIN;
    lo = position > 0 ? (U32)position / 16 : 0;
    position = exponent - 1 - XS_SUM_ORIGIN;
    if (position < 0)
        return XS_SUM_UNSUPPORTED;
    hi = (U32)position / 16 + 1;
    if (hi > XS_SUM_LIMBS || hi - lo > XS_TERM_LIMBS)
        return XS_SUM_UNSUPPORTED;
    fraction = Perl_ldexp(fraction, exponent - XS_SUM_ORIGIN - 16 * (hi - 1));
    for (word = hi; word-- > lo;) {
        U32 digit = (U32)fraction;
        term[word - lo] = (U16)digit;
        fraction = (fraction - digit) * 65536;
    }
    if (fraction)
        return XS_SUM_UNSUPPORTED;
    *term_lo = lo;
    *term_hi = hi;
    *sign = x < 0 ? -1 : 1;
    return XS_SUM_OK;
}

static XStatsSumStatus
xs_sum_add(XStatsExactSum *s, NV x)
{
    U16 term[XS_TERM_LIMBS];
    U32 lo, hi;
    I8 sign;
    XStatsSumStatus status = xs_sum_term(x, term, &lo, &hi, &sign);
    return status == XS_SUM_OK ? xs_sum_words(s, term, lo, hi, sign) : status;
}

static XStatsSumStatus
xs_sum_merge(XStatsExactSum *s, const XStatsExactSum *other)
{
    if (!other->sign)
        return XS_SUM_OK;
    if (s == other) {
        U32 i, carry = 0, word;
        for (i = s->lo; i < s->hi; ++i) {
            word = ((U32)s->limb[i] << 1) | carry;
            s->limb[i] = (U16)(word & 0xffff);
            carry = word >> 16;
        }
        if (carry) {
            if (s->hi == XS_SUM_LIMBS)
                return XS_SUM_OVERFLOW;
            s->limb[s->hi++] = (U16)carry;
        }
        while (!s->limb[s->lo])
            ++s->lo;
        return XS_SUM_OK;
    }
    return xs_sum_words(s, other->limb + other->lo, other->lo, other->hi, other->sign);
}

static bool
xs_raw_bit(const U16 *limb, U32 lo, U32 hi, I32 position)
{
    U32 word;
    if (position < 0)
        return 0;
    word = (U32)position / 16;
    if (word < lo || word >= hi)
        return 0;
    return (limb[word] >> ((U32)position % 16)) & 1;
}

static bool
xs_raw_lower_bits(const U16 *limb, U32 lo, U32 hi, I32 limit)
{
    U32 i;
    if (limit <= 0)
        return 0;
    for (i = lo; i < hi && (I32)(16 * i) < limit; ++i) {
        I32 width = limit - (I32)(16 * i);
        U32 mask = width >= 16 ? 0xffff : ((U32)1 << width) - 1;
        if (limb[i] & mask)
            return 1;
    }
    return 0;
}

/* origin is at most the NV's minimum subnormal exponent. The remainder is
 * the exact fractional part of an integer division, in those origin units. */
static XStatsSumStatus
xs_raw_round(const U16 *limb, U32 lo, U32 hi, I8 sign, I32 origin, U32 remainder,
             U32 divisor, NV *out)
{
    I32 highest, shift, bit;
    bool round_up;
    NV value = 0;
    U16 top;
    if (!XS_SUM_SUPPORTED)
        return XS_SUM_UNSUPPORTED;
    if (origin > XS_SUM_ORIGIN || !divisor || remainder >= divisor)
        return XS_SUM_INVALID;
    highest = -1;
    if (sign) {
        highest = (I32)(16 * (hi - 1));
        top = limb[hi - 1];
        while (top >>= 1)
            ++highest;
    }
    shift = highest >= NV_MANT_DIG ? highest - NV_MANT_DIG + 1 : 0;
    if (shift < XS_SUM_ORIGIN - origin)
        shift = XS_SUM_ORIGIN - origin;
    for (bit = highest; bit >= shift; --bit)
        value = value * 2 + xs_raw_bit(limb, lo, hi, bit);
    if (shift) {
        round_up = xs_raw_bit(limb, lo, hi, shift - 1) &&
                   (remainder || xs_raw_lower_bits(limb, lo, hi, shift - 1) ||
                    xs_raw_bit(limb, lo, hi, shift));
    } else {
        round_up = remainder > divisor - remainder ||
                   (remainder == divisor - remainder && xs_raw_bit(limb, lo, hi, 0));
    }
    if (round_up)
        value += 1;
    if (value == Perl_ldexp((NV)1, NV_MANT_DIG))
        ++highest;
    if (highest + origin >= NV_MAX_EXP)
        return XS_SUM_OVERFLOW;
    value = Perl_ldexp(value, origin + shift);
    if (!Perl_isfinite(value))
        return XS_SUM_OVERFLOW;
    *out = sign < 0 ? -value : value;
    return XS_SUM_OK;
}

static XStatsSumStatus
xs_sum_round(const XStatsExactSum *s, U32 remainder, U32 divisor, NV *out)
{
    return xs_raw_round(s->limb, s->lo, s->hi, s->sign, XS_SUM_ORIGIN, remainder,
                        divisor, out);
}

static XStatsSumStatus
xs_sum_value(const XStatsExactSum *s, U32 divisor, NV *out)
{
    XStatsExactSum quotient;
    U32 remainder = 0, word, carry, qword;
    I32 i, bit, end;
    XStatsSumStatus status;
    if (!divisor || !xs_sum_valid(s))
        return XS_SUM_INVALID;
    if (divisor == 1)
        return xs_sum_round(s, 0, 1, out);
    Zero(&quotient, 1, XStatsExactSum);
    if (!s->sign) {
        *out = 0;
        return XS_SUM_OK;
    }
    quotient.sign = s->sign;
    /* Division by a U32 loses at most 32 leading bits. Keep enough words
     * for the NV significand and guard bit. Lower words only affect sticky. */
    end = (I32)s->hi - (NV_MANT_DIG + 63) / 16;
    if (end < 0)
        end = 0;
    for (i = s->hi - 1; i >= end; --i) {
        word = i >= s->lo ? s->limb[i] : 0;
        qword = 0;
        for (bit = 15; bit >= 0; --bit) {
            carry = remainder >> 31;
            remainder = (remainder << 1) | ((word >> bit) & 1);
            if (carry || remainder >= divisor) {
                remainder -= divisor;
                qword |= (U32)1 << bit;
            }
        }
        quotient.limb[i] = (U16)qword;
    }
    xs_sum_trim(&quotient, (U32)end, s->hi);
    if (end && !remainder && xs_raw_lower_bits(s->limb, s->lo, s->hi, 16 * end))
        remainder = 1;
    /* A quotient rounded from zero must retain the original sign. */
    status = xs_sum_round(&quotient, remainder, divisor, out);
    if (status == XS_SUM_OK && s->sign < 0 && quotient.sign == 0)
        *out = -*out;
    return status;
}

#endif
