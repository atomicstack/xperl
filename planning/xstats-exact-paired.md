# Exact paired statistics

Status: implemented and reviewed. Independent integer and rounding oracles
cover binary64, x87 extended and binary128. Whole-module tests pass on active,
threaded RC-stack, 32-bit and binary128 XPerl builds. Paired calculations do
not enlarge stored objects or the fixed-size Incremental summary.

## Contract

For finite observations converted to a supported NV format, form raw moments
and cancellation exactly. Round covariance, correlation, slope and intercept
once to nearest-even NV. Intermediate overflow or underflow in NV must not
prevent a representable result. Final overflow uses the module's structured
result-overflow condition. Preserve existing statistical domain requirements.

Round regression coefficients independently. Computing the intercept from a
rounded slope is incorrect, even with compensated multiplication. For
`x=[3*2**500,6*2**500]`, `y=[2**500,2**501]`, the exact slope is 1/3 and the
intercept is zero. The current implementation returns a large false intercept.

Scalar variance remains approximate until separately upgraded. Exact
`covariance(x,x)` can differ from it in the last bits.

## Integer moments

Let `q=NV_MIN_EXP-NV_MANT_DIG`. Express each converted NV as an integer times
`2**q`. Decompose into compact U16 words without first multiplying in NV.
Reuse the object's exact scalar sum where possible.

```
Sx = sum(X)       Sy = sum(Y)
Qxx = sum(X*X)   Qyy = sum(Y*Y)   Qxy = sum(X*Y)
C = n*Qxy - Sx*Sy
Vx = n*Qxx - Sx*Sx
Vy = n*Qyy - Sy*Sy

covariance = C / (n*(n-1)) * 2**(2*q)
slope = C / Vx
intercept = (Qxx*Sy - Sx*Qxy) / Vx * 2**q
correlation = C / sqrt(Vx*Vy)
```

Accumulate only the moments needed for the requested operation.

## Scratch arithmetic

Keep U16 limbs and U32 carries. In schoolbook multiplication, propagate carry
after each limb product: `65535**2 + 65535 + 65535 == U32_MAX`. Split U32
multipliers into two U16 words. Use I32 exponents and bit positions.

Provide signed addition/subtraction, multiplication, multiplication by U32,
shifted comparison/subtraction and quotient/remainder extraction. Keep scratch
in Perl-owned temporary storage, with explicit ownership and bounded extents.
Several binary128 scratch arrays must not live on the C stack.

For `R=NV_MAX_EXP-q`, `P=NV_MANT_DIG` and `n<2**32`, conservative bounds are:

| Scratch value | Bits |
| --- | ---: |
| Scalar sum | R+32 |
| Raw product sum | 2R+32 |
| Centred numerator | 2R+65 |
| Intercept numerator | 3R+65 |
| Largest correlation division buffer | 4R+130+2P+2 |

Individual payloads range from 530 to 1,080 bytes for binary64 and from
8,224 to 16,484 bytes for binary128. These are individual buffers, not peak
workspace. Lay out reusable scratch and measure its actual peak.

## Rational rounding

For `A/B * 2**origin`, find the exact binary exponent using integer bit lengths
and shifted comparison. Choose quantum
`h=max(q,floor(log2(result))-P+1)`. Divide suitably shifted integers to obtain
the significand and remainder. Compare twice the remainder with the denominator;
ties select an even significand. Only about P quotient bits are needed.

Build NV from the rounded integer significand and ldexp. Check overflow after
rounding, including carry at the largest finite value. Retain subnormals and
the sign of a rounded zero.

## Correlation rounding

Set `A=C*C`, `B=Vx*Vy`. Handle C=0 and A=B directly. Negative centred variance
or A>B indicates an invariant failure. Do not clamp it away.

Find `k=floor(log2(sqrt(A/B)))` by exact shifted comparisons. Negative exponent
division needs mathematical floor, rather than C's truncation. Set
`h=max(q,k-P+1)`, then divide `A*2**(-2*h)` by B into quotient J and remainder.
J needs at most 2P bits. Compute `M=isqrt(J)`, `K=J-M*M`.

- K<M rounds down.
- K>M rounds up.
- K=M compares four times the remainder with B; equality selects even M.

Return `sign(C)*ldexp(M,h)`. This compares the exact squared result with
`(M+1/2)**2` without approximate floating square roots.

## Library decision

Use transient native arithmetic for this stage. An external library remains
permitted, but it must preserve the same contract across NV formats.

Local GMP development files are available. Its mpn API can use caller-owned
buffers and may be an acceleration backend after measurement. Its overlap,
length and zero-input rules require explicit wrappers. Its mpz API is useful
for an independent validation driver. Do not replace global allocation hooks
with Perl croaking allocators: GMP documents longjmp recovery from allocation
failure as undefined. See the [low-level API](https://gmplib.org/manual/Low_002dlevel-Functions)
and [allocation contract](https://gmplib.org/manual/Custom-Allocation).

Local MPFR lacks development headers. Fixed extra floating precision does not
prove correctness after arbitrary cancellation. GSL's double return types do
not meet the wider-NV contract. See the [MPFR manual](https://www.mpfr.org/mpfr-current/mpfr.html).

## Implementation and validation order

1. Independently validate compact products and bounded integer primitives.
2. Implement rational rounding, then covariance and regression.
3. Implement square-root-ratio rounding, then correlation.
4. Keep current range guards until each replacement is validated.

Include the 1/3-slope regression above; large adjacent predictors; minimum
subnormals with proportional responses; negative and near-perfect correlations;
overflowing raw sums with finite results; and final result overflow.

For `H=2**600`, `t=2**-600`, `x=[H,-H,t,-t]`, `y=[H,H,H,-H]`, covariance is
2/3. Test exact cancellation, halfway rounding, subnormal transitions, input
permutations and private moment merge partitions. Exercise U32 capacity bounds
without allocating billions of observations.

Use exact rational oracles and exact squared-midpoint comparisons. Generate
wider-format expectations without passing them through Python float. Validate
binary64, binary128, 32-bit x87, threaded RC and sanitizers. Measure query time
and peak scratch memory separately.
