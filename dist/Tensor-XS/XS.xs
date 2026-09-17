#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include <math.h>

#define TENSOR_MAGIC   ((UV)0x54454e53U) /* "TENS" */
#define TENSOR_VERSION ((UV)1)

typedef struct {
    UV magic;
    UV version;
    UV rank;
    UV size;
    UV dtype;
    /* Followed by rank UV shape values, rank UV stride values, and size
     * NV data values, then a zero UV sentinel.  The whole representation is
     * owned by one PV. */
} tensor_header;

typedef enum {
    TENSOR_DTYPE_U8 = 1,
    TENSOR_DTYPE_U16,
    TENSOR_DTYPE_U32,
    TENSOR_DTYPE_U64,
    TENSOR_DTYPE_I8,
    TENSOR_DTYPE_I16,
    TENSOR_DTYPE_I32,
    TENSOR_DTYPE_I64,
    TENSOR_DTYPE_F16,
    TENSOR_DTYPE_BF16,
    TENSOR_DTYPE_F32,
    TENSOR_DTYPE_F64,
    TENSOR_DTYPE_NV
} tensor_dtype;

typedef enum {
    TENSOR_OP_NEG,
    TENSOR_OP_ABS,
    TENSOR_OP_EXP,
    TENSOR_OP_LOG,
    TENSOR_OP_SQRT,
    TENSOR_OP_TRUNC,
    TENSOR_OP_FRACT,
    TENSOR_OP_FLOOR,
    TENSOR_OP_CEIL,
    TENSOR_OP_NOT,
    TENSOR_OP_ADD,
    TENSOR_OP_SUB,
    TENSOR_OP_MUL,
    TENSOR_OP_DIV,
    TENSOR_OP_MOD,
    TENSOR_OP_POW,
    TENSOR_OP_EQ,
    TENSOR_OP_NE,
    TENSOR_OP_LT,
    TENSOR_OP_LE,
    TENSOR_OP_GT,
    TENSOR_OP_GE,
    TENSOR_OP_CMP,
    TENSOR_OP_AND,
    TENSOR_OP_OR,
    TENSOR_OP_MIN,
    TENSOR_OP_MAX
} tensor_op;

static Size_t
tensor_dtype_size(tensor_dtype dtype)
{
    switch (dtype) {
    case TENSOR_DTYPE_U8:
    case TENSOR_DTYPE_I8:
        return 1;
    case TENSOR_DTYPE_U16:
    case TENSOR_DTYPE_I16:
    case TENSOR_DTYPE_F16:
    case TENSOR_DTYPE_BF16:
        return 2;
    case TENSOR_DTYPE_U32:
    case TENSOR_DTYPE_I32:
    case TENSOR_DTYPE_F32:
        return 4;
    case TENSOR_DTYPE_U64:
    case TENSOR_DTYPE_I64:
    case TENSOR_DTYPE_F64:
        return 8;
    case TENSOR_DTYPE_NV:
        return sizeof(NV);
    }
    croak("unknown tensor dtype");
}

static const char *
tensor_dtype_name(tensor_dtype dtype)
{
    switch (dtype) {
    case TENSOR_DTYPE_U8:   return "U8";
    case TENSOR_DTYPE_U16:  return "U16";
    case TENSOR_DTYPE_U32:  return "U32";
    case TENSOR_DTYPE_U64:  return "U64";
    case TENSOR_DTYPE_I8:   return "I8";
    case TENSOR_DTYPE_I16:  return "I16";
    case TENSOR_DTYPE_I32:  return "I32";
    case TENSOR_DTYPE_I64:  return "I64";
    case TENSOR_DTYPE_F16:  return "F16";
    case TENSOR_DTYPE_BF16: return "BF16";
    case TENSOR_DTYPE_F32:  return "F32";
    case TENSOR_DTYPE_F64:  return "F64";
    case TENSOR_DTYPE_NV:   return "NV";
    }
    croak("unknown tensor dtype");
}

static U16
tensor_float_to_bf16(NV value)
{
    float input = (float)value;
    U32 bits;
    memcpy(&bits, &input, sizeof(bits));
    bits += 0x7fffU + ((bits >> 16) & 1);
    return (U16)(bits >> 16);
}

static NV
tensor_bf16_to_float(U16 value)
{
    U32 bits = (U32)value << 16;
    float result;
    memcpy(&result, &bits, sizeof(result));
    return (NV)result;
}

static U16
tensor_float_to_f16(NV value)
{
    float input = (float)value;
    U32 bits;
    U32 sign;
    U32 exponent;
    U32 mantissa;
    IV adjusted_exponent;

    memcpy(&bits, &input, sizeof(bits));
    sign = (bits >> 16) & 0x8000U;
    exponent = (bits >> 23) & 0xffU;
    mantissa = bits & 0x7fffffU;

    if (exponent == 0xffU)
        return (U16)(sign | 0x7c00U | (mantissa ? 0x0200U : 0));

    adjusted_exponent = (IV)exponent - 127;
    if (adjusted_exponent > 15)
        return (U16)(sign | 0x7c00U);
    if (adjusted_exponent < -24)
        return (U16)sign;

    if (adjusted_exponent < -14) {
        U32 shift = (U32)(-adjusted_exponent - 1);
        U32 significand = mantissa | 0x800000U;
        U32 half = significand >> (shift + 13);
        U32 remainder = significand & ((1U << (shift + 13)) - 1);
        U32 halfway = 1U << (shift + 12);
        if (remainder > halfway || (remainder == halfway && (half & 1)))
            half++;
        return (U16)(sign | half);
    }
    else {
        U32 half_mantissa = mantissa >> 13;
        U32 remainder = mantissa & 0x1fffU;
        if (remainder > 0x1000U
            || (remainder == 0x1000U && (half_mantissa & 1))) {
            half_mantissa++;
            if (half_mantissa == 0x400U) {
                half_mantissa = 0;
                adjusted_exponent++;
                if (adjusted_exponent > 15)
                    return (U16)(sign | 0x7c00U);
            }
        }
        return (U16)(sign | ((U32)(adjusted_exponent + 15) << 10)
                     | half_mantissa);
    }
}

static NV
tensor_f16_to_float(U16 value)
{
    U32 sign = ((U32)value & 0x8000U) << 16;
    U32 exponent = ((U32)value >> 10) & 0x1fU;
    U32 mantissa = (U32)value & 0x3ffU;
    U32 bits;
    float result;

    if (exponent == 0) {
        if (mantissa == 0)
            bits = sign;
        else {
            IV exponent_adjustment = -1;
            while ((mantissa & 0x400U) == 0) {
                mantissa <<= 1;
                exponent_adjustment--;
            }
            mantissa &= 0x3ffU;
            bits = sign | ((U32)(exponent_adjustment + 127) << 23)
                   | (mantissa << 13);
        }
    }
    else if (exponent == 0x1fU)
        bits = sign | 0x7f800000U | (mantissa << 13);
    else
        bits = sign | ((exponent + 112) << 23) | (mantissa << 13);

    memcpy(&result, &bits, sizeof(result));
    return (NV)result;
}

static tensor_dtype
tensor_dtype_from_sv(pTHX_ SV *value)
{
    const char *name;

    if (!value || !SvOK(value))
        return TENSOR_DTYPE_F64;
    name = SvPV_nolen(value);
    if (strEQ(name, "U8"))   return TENSOR_DTYPE_U8;
    if (strEQ(name, "U16"))  return TENSOR_DTYPE_U16;
    if (strEQ(name, "U32"))  return TENSOR_DTYPE_U32;
    if (strEQ(name, "U64"))  return TENSOR_DTYPE_U64;
    if (strEQ(name, "I8"))   return TENSOR_DTYPE_I8;
    if (strEQ(name, "I16"))  return TENSOR_DTYPE_I16;
    if (strEQ(name, "I32"))  return TENSOR_DTYPE_I32;
    if (strEQ(name, "I64"))  return TENSOR_DTYPE_I64;
    if (strEQ(name, "F16"))  return TENSOR_DTYPE_F16;
    if (strEQ(name, "BF16")) return TENSOR_DTYPE_BF16;
    if (strEQ(name, "F32"))  return TENSOR_DTYPE_F32;
    if (strEQ(name, "F64"))  return TENSOR_DTYPE_F64;
    if (strEQ(name, "NV"))   return TENSOR_DTYPE_NV;
    croak("unknown tensor dtype '%s'", name);
}

static Size_t
tensor_align_offset(Size_t offset)
{
    const Size_t alignment = MEM_ALIGNBYTES;
    return (offset + alignment - 1) / alignment * alignment;
}

static Size_t
tensor_data_offset(UV rank)
{
    return tensor_align_offset(sizeof(tensor_header)
                               + rank * sizeof(UV) * 2);
}

static bool
tensor_blob_size(UV rank, UV size, Size_t element_size, Size_t *result)
{
    Size_t metadata;
    Size_t data_offset;
    Size_t data_bytes;
    Size_t tail_offset;

    if (rank > (UV)Size_t_MAX
        || (Size_t)rank > (Size_t_MAX - sizeof(tensor_header))
                            / (sizeof(UV) * 2)
        || size > (UV)(Size_t_MAX / element_size))
        return FALSE;

    metadata = sizeof(tensor_header) + (Size_t)rank * sizeof(UV) * 2;
    if (metadata > Size_t_MAX - MEM_ALIGNBYTES + 1)
        return FALSE;
    data_offset = tensor_align_offset(metadata);
    data_bytes = (Size_t)size * element_size;
    if (data_offset > Size_t_MAX - data_bytes)
        return FALSE;
    metadata = data_offset + data_bytes;
    if (metadata > Size_t_MAX - MEM_ALIGNBYTES + 1)
        return FALSE;
    tail_offset = tensor_align_offset(metadata);
    if (tail_offset > Size_t_MAX - sizeof(UV))
        return FALSE;

    *result = tail_offset + sizeof(UV);
    return TRUE;
}

static tensor_header *
tensor_from_object(pTHX_ SV *object)
{
    SV *payload;

    if (!SvROK(object) || !SvPOK(SvRV(object)))
        croak("Tensor::XS object expected");

    payload = SvRV(object);
    if (SvCUR(payload) < sizeof(tensor_header))
        croak("invalid Tensor::XS object");

    {
        tensor_header *tensor = (tensor_header *)SvPV_nolen(payload);
        Size_t expected;
        if (tensor->magic != TENSOR_MAGIC || tensor->version != TENSOR_VERSION
            || tensor->dtype == 0
            || !tensor_blob_size(tensor->rank, tensor->size,
                                 tensor_dtype_size((tensor_dtype)tensor->dtype),
                                 &expected)
            || SvCUR(payload) < expected)
            croak("invalid Tensor::XS object");
        return tensor;
    }
}

static UV *
tensor_shape(tensor_header *tensor)
{
    return (UV *)(tensor + 1);
}

static UV *
tensor_strides(tensor_header *tensor)
{
    return tensor_shape(tensor) + tensor->rank;
}

static char *
tensor_data(tensor_header *tensor)
{
    return (char *)tensor + tensor_data_offset(tensor->rank);
}

static NV
tensor_load(tensor_header *tensor, UV index)
{
    char *data = tensor_data(tensor) + index * tensor_dtype_size((tensor_dtype)tensor->dtype);
    switch ((tensor_dtype)tensor->dtype) {
    case TENSOR_DTYPE_U8:   return *(U8 *)data;
    case TENSOR_DTYPE_U16:  return *(U16 *)data;
    case TENSOR_DTYPE_U32:  return *(U32 *)data;
    case TENSOR_DTYPE_U64:  return *(U64 *)data;
    case TENSOR_DTYPE_I8:   return *(I8 *)data;
    case TENSOR_DTYPE_I16:  return *(I16 *)data;
    case TENSOR_DTYPE_I32:  return *(I32 *)data;
    case TENSOR_DTYPE_I64:  return *(I64 *)data;
    case TENSOR_DTYPE_F32:  return *(float *)data;
    case TENSOR_DTYPE_F64:  return *(double *)data;
    case TENSOR_DTYPE_NV:   return *(NV *)data;
    case TENSOR_DTYPE_F16:  return tensor_f16_to_float(*(U16 *)data);
    case TENSOR_DTYPE_BF16: return tensor_bf16_to_float(*(U16 *)data);
    }
    croak("unknown tensor dtype");
}

static SV *
tensor_load_sv(pTHX_ tensor_header *tensor, UV index)
{
    char *data = tensor_data(tensor) + index * tensor_dtype_size((tensor_dtype)tensor->dtype);
    switch ((tensor_dtype)tensor->dtype) {
    case TENSOR_DTYPE_U8:   return newSVuv(*(U8 *)data);
    case TENSOR_DTYPE_U16:  return newSVuv(*(U16 *)data);
    case TENSOR_DTYPE_U32:  return newSVuv(*(U32 *)data);
    case TENSOR_DTYPE_U64:  return newSVuv(*(U64 *)data);
    case TENSOR_DTYPE_I8:   return newSViv(*(I8 *)data);
    case TENSOR_DTYPE_I16:  return newSViv(*(I16 *)data);
    case TENSOR_DTYPE_I32:  return newSViv(*(I32 *)data);
    case TENSOR_DTYPE_I64:  return newSViv(*(I64 *)data);
    case TENSOR_DTYPE_F32:  return newSVnv(*(float *)data);
    case TENSOR_DTYPE_F64:  return newSVnv(*(double *)data);
    case TENSOR_DTYPE_NV:   return newSVnv(*(NV *)data);
    case TENSOR_DTYPE_F16:  return newSVnv(tensor_f16_to_float(*(U16 *)data));
    case TENSOR_DTYPE_BF16: return newSVnv(tensor_bf16_to_float(*(U16 *)data));
    }
    croak("unknown tensor dtype");
}

static void
tensor_store(tensor_header *tensor, UV index, SV *value_sv)
{
    char *data = tensor_data(tensor) + index * tensor_dtype_size((tensor_dtype)tensor->dtype);
    switch ((tensor_dtype)tensor->dtype) {
    case TENSOR_DTYPE_U8:   *(U8 *)data = (U8)SvUV(value_sv); return;
    case TENSOR_DTYPE_U16:  *(U16 *)data = (U16)SvUV(value_sv); return;
    case TENSOR_DTYPE_U32:  *(U32 *)data = (U32)SvUV(value_sv); return;
    case TENSOR_DTYPE_U64:  *(U64 *)data = (U64)SvUV(value_sv); return;
    case TENSOR_DTYPE_I8:   *(I8 *)data = (I8)SvIV(value_sv); return;
    case TENSOR_DTYPE_I16:  *(I16 *)data = (I16)SvIV(value_sv); return;
    case TENSOR_DTYPE_I32:  *(I32 *)data = (I32)SvIV(value_sv); return;
    case TENSOR_DTYPE_I64:  *(I64 *)data = (I64)SvIV(value_sv); return;
    case TENSOR_DTYPE_F32:  *(float *)data = (float)SvNV(value_sv); return;
    case TENSOR_DTYPE_F64:  *(double *)data = (double)SvNV(value_sv); return;
    case TENSOR_DTYPE_NV:   *(NV *)data = SvNV(value_sv); return;
    case TENSOR_DTYPE_F16:  *(U16 *)data = tensor_float_to_f16(SvNV(value_sv)); return;
    case TENSOR_DTYPE_BF16: *(U16 *)data = tensor_float_to_bf16(SvNV(value_sv)); return;
    }
    croak("unknown tensor dtype");
}

static void
tensor_store_nv(tensor_header *tensor, UV index, NV value)
{
    char *data = tensor_data(tensor) + index * tensor_dtype_size((tensor_dtype)tensor->dtype);
    switch ((tensor_dtype)tensor->dtype) {
    case TENSOR_DTYPE_U8:   *(U8 *)data = (U8)value; return;
    case TENSOR_DTYPE_U16:  *(U16 *)data = (U16)value; return;
    case TENSOR_DTYPE_U32:  *(U32 *)data = (U32)value; return;
    case TENSOR_DTYPE_U64:  *(U64 *)data = (U64)value; return;
    case TENSOR_DTYPE_I8:   *(I8 *)data = (I8)value; return;
    case TENSOR_DTYPE_I16:  *(I16 *)data = (I16)value; return;
    case TENSOR_DTYPE_I32:  *(I32 *)data = (I32)value; return;
    case TENSOR_DTYPE_I64:  *(I64 *)data = (I64)value; return;
    case TENSOR_DTYPE_F32:  *(float *)data = (float)value; return;
    case TENSOR_DTYPE_F64:  *(double *)data = (double)value; return;
    case TENSOR_DTYPE_NV:   *(NV *)data = value; return;
    case TENSOR_DTYPE_F16:  *(U16 *)data = tensor_float_to_f16(value); return;
    case TENSOR_DTYPE_BF16: *(U16 *)data = tensor_float_to_bf16(value); return;
    }
    croak("unknown tensor dtype");
}

static NV
tensor_unary_op(tensor_op op, NV value)
{
    switch (op) {
    case TENSOR_OP_NEG:   return -value;
    case TENSOR_OP_ABS:   return fabs(value);
    case TENSOR_OP_EXP:   return exp(value);
    case TENSOR_OP_LOG:   return log(value);
    case TENSOR_OP_SQRT:  return sqrt(value);
    case TENSOR_OP_TRUNC: return trunc(value);
    case TENSOR_OP_FRACT: return trunc(value) - value;
    case TENSOR_OP_FLOOR: return floor(value);
    case TENSOR_OP_CEIL:  return ceil(value);
    case TENSOR_OP_NOT:   return !value;
    default: croak("invalid unary tensor operation");
    }
}

static NV
tensor_binary_op(tensor_op op, NV left, NV right)
{
    switch (op) {
    case TENSOR_OP_ADD: return left + right;
    case TENSOR_OP_SUB: return left - right;
    case TENSOR_OP_MUL: return left * right;
    case TENSOR_OP_DIV: return left / right;
    case TENSOR_OP_MOD: return fmod(left, right);
    case TENSOR_OP_POW: return pow(left, right);
    case TENSOR_OP_EQ:  return left == right;
    case TENSOR_OP_NE:  return left != right;
    case TENSOR_OP_LT:  return left < right;
    case TENSOR_OP_LE:  return left <= right;
    case TENSOR_OP_GT:  return left > right;
    case TENSOR_OP_GE:  return left >= right;
    case TENSOR_OP_CMP: return left < right ? -1 : left > right ? 1 : 0;
    case TENSOR_OP_AND: return left && right;
    case TENSOR_OP_OR:  return left || right;
    case TENSOR_OP_MIN: return left < right ? left : right;
    case TENSOR_OP_MAX: return left > right ? left : right;
    default: croak("invalid binary tensor operation");
    }
}

static tensor_op
tensor_op_from_sv(pTHX_ SV *name, bool unary)
{
    const char *op = SvPV_nolen(name);
#define TENSOR_OP_NAME(name, value) if (strEQ(op, name)) return value
    if (unary) {
        TENSOR_OP_NAME("neg", TENSOR_OP_NEG);
        TENSOR_OP_NAME("abs", TENSOR_OP_ABS);
        TENSOR_OP_NAME("exp", TENSOR_OP_EXP);
        TENSOR_OP_NAME("log", TENSOR_OP_LOG);
        TENSOR_OP_NAME("sqrt", TENSOR_OP_SQRT);
        TENSOR_OP_NAME("trunc", TENSOR_OP_TRUNC);
        TENSOR_OP_NAME("fract", TENSOR_OP_FRACT);
        TENSOR_OP_NAME("floor", TENSOR_OP_FLOOR);
        TENSOR_OP_NAME("ceil", TENSOR_OP_CEIL);
        TENSOR_OP_NAME("not", TENSOR_OP_NOT);
    }
    else {
        TENSOR_OP_NAME("add", TENSOR_OP_ADD);
        TENSOR_OP_NAME("sub", TENSOR_OP_SUB);
        TENSOR_OP_NAME("mul", TENSOR_OP_MUL);
        TENSOR_OP_NAME("div", TENSOR_OP_DIV);
        TENSOR_OP_NAME("mod", TENSOR_OP_MOD);
        TENSOR_OP_NAME("pow", TENSOR_OP_POW);
        TENSOR_OP_NAME("eq", TENSOR_OP_EQ);
        TENSOR_OP_NAME("ne", TENSOR_OP_NE);
        TENSOR_OP_NAME("lt", TENSOR_OP_LT);
        TENSOR_OP_NAME("le", TENSOR_OP_LE);
        TENSOR_OP_NAME("gt", TENSOR_OP_GT);
        TENSOR_OP_NAME("ge", TENSOR_OP_GE);
        TENSOR_OP_NAME("cmp", TENSOR_OP_CMP);
        TENSOR_OP_NAME("and", TENSOR_OP_AND);
        TENSOR_OP_NAME("or", TENSOR_OP_OR);
        TENSOR_OP_NAME("min", TENSOR_OP_MIN);
        TENSOR_OP_NAME("max", TENSOR_OP_MAX);
    }
#undef TENSOR_OP_NAME
    croak("unknown %s tensor operation '%s'", unary ? "unary" : "binary", op);
}

static SV *
tensor_new_result(pTHX_ const UV *shape, UV rank, const char *class_name,
                 tensor_dtype dtype, tensor_header **resultp)
{
    UV i;
    UV size = 1;
    Size_t bytes;
    char *storage;
    tensor_header *tensor;
    SV *payload;
    SV *object;

    for (i = 0; i < rank; i++) {
        if (size > UV_MAX / shape[i])
            croak("tensor size overflow");
        size *= shape[i];
    }
    if (!tensor_blob_size(rank, size, tensor_dtype_size(dtype), &bytes))
        croak("tensor blob size overflow");
    Newxz(storage, bytes, char);
    tensor = (tensor_header *)storage;
    tensor->magic = TENSOR_MAGIC;
    tensor->version = TENSOR_VERSION;
    tensor->rank = rank;
    tensor->size = size;
    tensor->dtype = dtype;

    {
        UV *shape_out = tensor_shape(tensor);
        UV *strides_out = tensor_strides(tensor);
        UV stride = 1;
        for (i = rank; i-- > 0;) {
            shape_out[i] = shape[i];
            strides_out[i] = stride;
            stride *= shape[i];
        }
    }
    payload = newSV(0);
    sv_usepvn(payload, storage, bytes);
    object = newRV_noinc(payload);
    sv_bless(object, gv_stashpv(class_name, GV_ADD));
    *resultp = (tensor_header *)SvPV_nolen(payload);
    return object;
}

static tensor_header *
tensor_other(pTHX_ SV *other, bool *is_tensor)
{
    if (SvROK(other) && SvPOK(SvRV(other))) {
        *is_tensor = TRUE;
        return tensor_from_object(aTHX_ other);
    }
    *is_tensor = FALSE;
    return NULL;
}

static UV
tensor_coordinate_index(pTHX_ tensor_header *tensor, SV **coordinates,
                        I32 count)
{
    UV index = 0;
    I32 i;

    if ((UV)count != tensor->rank)
        croak("coordinate count does not match tensor rank");

    for (i = 0; i < count; i++) {
        IV coordinate = SvIV(coordinates[i]);
        if (coordinate < 0 || (UV)coordinate >= tensor_shape(tensor)[i])
            croak("Index out of bounds");
        index += (UV)coordinate * tensor_strides(tensor)[i];
    }

    return index;
}

static void
tensor_copy_array(pTHX_ AV *source, tensor_header *tensor, UV depth,
                  UV *position, SV **output)
{
    const UV count = av_count(source);
    UV i;

    if (depth == 0 && count == tensor->size
        && (!count || !SvROK(*av_fetch(source, 0, 0)))) {
        for (i = 0; i < count; i++) {
            SV *value = *av_fetch(source, i, 0);
            if (SvROK(value))
                croak("flat tensor data cannot contain nested arrays");
            output[(*position)++] = value;
        }
        return;
    }

    if (depth >= tensor->rank || count != tensor_shape(tensor)[depth])
        croak("nested tensor data does not match tensor shape");

    for (i = 0; i < count; i++) {
        SV *value = *av_fetch(source, i, 0);
        if (depth + 1 == tensor->rank) {
            if (SvROK(value))
                croak("nested tensor data has too many dimensions");
            output[(*position)++] = value;
        }
        else {
            if (!SvROK(value) || SvTYPE(SvRV(value)) != SVt_PVAV)
                croak("nested tensor data has too few dimensions");
            tensor_copy_array(aTHX_ (AV *)SvRV(value), tensor, depth + 1,
                              position, output);
        }
    }
}

MODULE = Tensor::XS  PACKAGE = Tensor::XS

PROTOTYPES: DISABLE

SV *
new_with_dtype(class_name, shape, data, dtype)
    const char *class_name
    SV *shape
    SV *data
    SV *dtype
  PREINIT:
    AV *shape_av;
    AV *data_av = NULL;
    UV rank;
    UV size = 1;
    UV i;
    Size_t bytes;
    tensor_dtype dtype_value;
    char *storage;
    tensor_header *tensor;
    SV **values = NULL;
    SV *payload;
    SV *object;
  CODE:
    if (!SvROK(shape) || SvTYPE(SvRV(shape)) != SVt_PVAV)
        croak("shape must be an array reference");
    shape_av = (AV *)SvRV(shape);
    rank = av_count(shape_av);

    if (SvROK(data) && SvTYPE(SvRV(data)) == SVt_PVAV)
        data_av = (AV *)SvRV(data);
    dtype_value = tensor_dtype_from_sv(aTHX_ dtype);

    for (i = 0; i < rank; i++) {
        SV **value = av_fetch(shape_av, i, 0);
        UV dimension;
        if (!value || !SvOK(*value) || SvIV(*value) < 0
            || (dimension = SvUV(*value)) != SvNV(*value))
            croak("shape dimensions must be nonnegative integers");
        if (size > UV_MAX / dimension)
            croak("tensor size overflow");
        size *= dimension;
    }

    if (!tensor_blob_size(rank, size, tensor_dtype_size(dtype_value), &bytes))
        croak("tensor blob size overflow");
    Newxz(storage, bytes, char);
    tensor = (tensor_header *)storage;
    tensor->magic = TENSOR_MAGIC;
    tensor->version = TENSOR_VERSION;
    tensor->rank = rank;
    tensor->size = size;
    tensor->dtype = dtype_value;

    {
        UV *shape_out = tensor_shape(tensor);
        UV *strides_out = tensor_strides(tensor);
        UV stride = 1;

        for (i = rank; i-- > 0;) {
            SV **value = av_fetch(shape_av, i, 0);
            shape_out[i] = SvUV(*value);
            strides_out[i] = stride;
            stride *= shape_out[i];
        }

        if (data_av) {
            UV position = 0;
            Newx(values, size, SV *);
            SAVEFREEPV((char *)values);
            tensor_copy_array(aTHX_ data_av, tensor, 0, &position, values);
            if (position != size)
                croak("data size does not match tensor shape");
            for (i = 0; i < size; i++)
                tensor_store(tensor, i, values[i]);
        }
        else {
            for (i = 0; i < size; i++)
                tensor_store(tensor, i, data);
        }
    }

    payload = newSV(0);
    sv_usepvn(payload, (char *)tensor, bytes);
    object = newRV_noinc(payload);
    sv_bless(object, gv_stashpv(class_name, GV_ADD));
    RETVAL = object;
    OUTPUT:
    RETVAL

AV *
strides(object)
    SV *object
  PREINIT:
    tensor_header *tensor;
    AV *result;
    UV i;
  CODE:
    tensor = tensor_from_object(aTHX_ object);
    result = newAV();
    for (i = 0; i < tensor->rank; i++)
        av_push(result, newSVuv(tensor_strides(tensor)[i]));
    RETVAL = result;
  OUTPUT:
    RETVAL

UV
rank(object)
    SV *object
  CODE:
    RETVAL = tensor_from_object(aTHX_ object)->rank;
  OUTPUT:
    RETVAL

UV
size(object)
    SV *object
  CODE:
    RETVAL = tensor_from_object(aTHX_ object)->size;
  OUTPUT:
    RETVAL

AV *
shape(object)
    SV *object
  PREINIT:
    tensor_header *tensor;
    AV *result;
    UV i;
  CODE:
    tensor = tensor_from_object(aTHX_ object);
    result = newAV();
    for (i = 0; i < tensor->rank; i++)
        av_push(result, newSVuv(tensor_shape(tensor)[i]));
    RETVAL = result;
    OUTPUT:
    RETVAL

SV *
dtype(object)
    SV *object
  PREINIT:
    tensor_header *tensor;
  CODE:
    tensor = tensor_from_object(aTHX_ object);
    RETVAL = newSVpv(tensor_dtype_name((tensor_dtype)tensor->dtype), 0);
  OUTPUT:
    RETVAL

UV
element_size(object)
    SV *object
  CODE:
    RETVAL = tensor_dtype_size((tensor_dtype)
                               tensor_from_object(aTHX_ object)->dtype);
  OUTPUT:
    RETVAL

SV *
at(object, ...)
    SV *object
  PREINIT:
    tensor_header *tensor;
    UV index;
  CODE:
    tensor = tensor_from_object(aTHX_ object);
    index = tensor_coordinate_index(aTHX_ tensor,
                                    items > 1 ? &ST(1) : NULL, items - 1);
    RETVAL = tensor_load_sv(aTHX_ tensor, index);
  OUTPUT:
    RETVAL

UV
index(object, ...)
    SV *object
  PREINIT:
    tensor_header *tensor;
  CODE:
    tensor = tensor_from_object(aTHX_ object);
    RETVAL = tensor_coordinate_index(aTHX_ tensor,
                                     items > 1 ? &ST(1) : NULL, items - 1);
  OUTPUT:
    RETVAL

NV
at_index(object, index)
    SV *object
    UV index
  PREINIT:
    tensor_header *tensor;
  CODE:
    tensor = tensor_from_object(aTHX_ object);
    if (index >= tensor->size)
        croak("tensor index out of bounds");
    RETVAL = tensor_load(tensor, index);
  OUTPUT:
    RETVAL

void
set_index(object, index, value)
    SV *object
    UV index
    SV *value
  PREINIT:
    tensor_header *tensor;
  CODE:
    tensor = tensor_from_object(aTHX_ object);
    if (index >= tensor->size)
        croak("tensor index out of bounds");
    tensor_store(tensor, index, value);

void
set_at(object, ...)
    SV *object
  PREINIT:
    tensor_header *tensor;
    UV index;
  CODE:
    tensor = tensor_from_object(aTHX_ object);
    index = tensor_coordinate_index(aTHX_ tensor,
                                    items > 2 ? &ST(1) : NULL, items - 2);
    tensor_store(tensor, index, ST(items - 1));

void
set_data(object, data)
    SV *object
    SV *data
  PREINIT:
    tensor_header *tensor;
    AV *data_av;
    UV i;
  CODE:
    if (!SvROK(data) || SvTYPE(SvRV(data)) != SVt_PVAV)
        croak("data must be an array reference");
    tensor = tensor_from_object(aTHX_ object);
    data_av = (AV *)SvRV(data);
    {
        UV position = 0;
        SV **values;
        Newx(values, tensor->size, SV *);
        SAVEFREEPV((char *)values);
        tensor_copy_array(aTHX_ data_av, tensor, 0, &position, values);
        if (position != tensor->size)
            croak("data size does not match tensor shape");
        for (i = 0; i < tensor->size; i++)
            tensor_store(tensor, i, values[i]);
    }

AV *
data(object)
    SV *object
  PREINIT:
    tensor_header *tensor;
    AV *result;
    UV i;
  CODE:
    tensor = tensor_from_object(aTHX_ object);
    result = newAV();
    for (i = 0; i < tensor->size; i++)
        av_push(result, tensor_load_sv(aTHX_ tensor, i));
    RETVAL = result;
  OUTPUT:
    RETVAL

SV *
unary(object, operation)
    SV *object
    SV *operation
  PREINIT:
    tensor_header *source;
    tensor_header *result;
    SV *result_object;
    tensor_op op;
    UV i;
    UV *shape;
  CODE:
    source = tensor_from_object(aTHX_ object);
    op = tensor_op_from_sv(aTHX_ operation, TRUE);
    shape = tensor_shape(source);
    result_object = tensor_new_result(aTHX_ shape, source->rank,
                                      "Tensor::XS",
                                      (tensor_dtype)source->dtype,
                                      &result);
    result->dtype = source->dtype;
    for (i = 0; i < source->size; i++)
        tensor_store_nv(result, i, tensor_unary_op(op, tensor_load(source, i)));
    RETVAL = result_object;
  OUTPUT:
    RETVAL

SV *
binary(object, other, operation)
    SV *object
    SV *other
    SV *operation
  PREINIT:
    tensor_header *source;
    tensor_header *right;
    tensor_header *result;
    SV *result_object;
    tensor_op op;
    bool is_tensor;
    NV right_value;
    UV i;
    UV *shape;
  CODE:
    source = tensor_from_object(aTHX_ object);
    right = tensor_other(aTHX_ other, &is_tensor);
    if (is_tensor && !((right->size == source->size && right->rank == source->rank)
                       || (source->rank == 2 && right->rank == 1
                           && right->size == tensor_shape(source)[1])))
        croak("tensor operands must have compatible shapes");
    op = tensor_op_from_sv(aTHX_ operation, FALSE);
    shape = tensor_shape(source);
    result_object = tensor_new_result(aTHX_ shape, source->rank,
                                      "Tensor::XS",
                                      (tensor_dtype)source->dtype,
                                      &result);
    result->dtype = source->dtype;
    for (i = 0; i < source->size; i++) {
        right_value = is_tensor
            ? tensor_load(right, right->rank == 1 && source->rank == 2
                                ? i % tensor_shape(source)[1] : i)
            : SvNV(other);
        tensor_store_nv(result, i,
                        tensor_binary_op(op, tensor_load(source, i),
                                         right_value));
    }
    RETVAL = result_object;
  OUTPUT:
    RETVAL

void
inplace(object, other, operation)
    SV *object
    SV *other
    SV *operation
  PREINIT:
    tensor_header *source;
    tensor_header *right;
    tensor_op op;
    bool is_tensor;
    NV right_value;
    UV i;
  CODE:
    source = tensor_from_object(aTHX_ object);
    right = tensor_other(aTHX_ other, &is_tensor);
    if (is_tensor && (right->size != source->size || right->rank != source->rank))
        croak("tensor operands must have the same shape");
    op = tensor_op_from_sv(aTHX_ operation, FALSE);
    for (i = 0; i < source->size; i++) {
        right_value = is_tensor ? tensor_load(right, i) : SvNV(other);
        tensor_store_nv(source, i,
                        tensor_binary_op(op, tensor_load(source, i),
                                         right_value));
    }

NV
reduce(object, operation)
    SV *object
    SV *operation
  PREINIT:
    tensor_header *tensor;
    const char *op;
    NV result;
    UV i;
  CODE:
    tensor = tensor_from_object(aTHX_ object);
    op = SvPV_nolen(operation);
    if (!tensor->size) {
        RETVAL = 0;
    }
    else {
        result = tensor_load(tensor, 0);
        for (i = 1; i < tensor->size; i++) {
            NV value = tensor_load(tensor, i);
            if (strEQ(op, "sum")) result += value;
            else if (strEQ(op, "min")) result = result < value ? result : value;
            else if (strEQ(op, "max")) result = result > value ? result : value;
            else croak("unknown tensor reduction '%s'", op);
        }
        RETVAL = result;
    }
  OUTPUT:
    RETVAL

SV *
transpose(object)
    SV *object
  PREINIT:
    tensor_header *source;
    tensor_header *result;
    SV *result_object;
    UV shape[2];
    UV row;
    UV col;
  CODE:
    source = tensor_from_object(aTHX_ object);
    if (source->rank != 2)
        croak("transpose requires a rank-two tensor");
    shape[0] = tensor_shape(source)[1];
    shape[1] = tensor_shape(source)[0];
    result_object = tensor_new_result(aTHX_ shape, 2, "Tensor::XS",
                                      (tensor_dtype)source->dtype, &result);
    result->dtype = source->dtype;
    for (row = 0; row < shape[1]; row++)
        for (col = 0; col < shape[0]; col++)
            tensor_store_nv(result, col * shape[1] + row,
                            tensor_load(source, row * shape[0] + col));
    RETVAL = result_object;
  OUTPUT:
    RETVAL

SV *
matrix_multiply(object, other)
    SV *object
    SV *other
  PREINIT:
    tensor_header *left;
    tensor_header *right;
    tensor_header *result;
    SV *result_object;
    UV left_rows;
    UV left_cols;
    UV right_rows;
    UV right_cols;
    UV shape[2];
    UV i;
    UV j;
    UV k;
    NV sum;
  CODE:
    left = tensor_from_object(aTHX_ object);
    right = tensor_from_object(aTHX_ other);
    if (!((left->rank == 2 && (right->rank == 1 || right->rank == 2))
          || (left->rank == 1 && right->rank == 2)))
        croak("matrix multiplication requires a matrix and vector or matrix");
    if (left->rank == 1) {
        left_rows = 1;
        left_cols = tensor_shape(left)[0];
        right_rows = tensor_shape(right)[0];
        right_cols = tensor_shape(right)[1];
        if (left_cols != right_rows)
            croak("matrix multiplication dimensions do not agree");
        shape[0] = right_cols;
    }
    else {
        left_rows = tensor_shape(left)[0];
        left_cols = tensor_shape(left)[1];
        right_rows = tensor_shape(right)[0];
        if (left_cols != right_rows)
            croak("matrix multiplication dimensions do not agree");
        right_cols = right->rank == 1 ? 1 : tensor_shape(right)[1];
        if (right->rank == 2)
            shape[0] = left_rows, shape[1] = right_cols;
        else
            shape[0] = left_rows;
    }
    result_object = tensor_new_result(aTHX_ shape,
                                      left->rank == 1 || right->rank == 1 ? 1 : 2,
                                      "Tensor::XS", (tensor_dtype)left->dtype,
                                      &result);
    result->dtype = left->dtype;
    if (left->rank == 1) {
        for (j = 0; j < right_cols; j++) {
            sum = 0;
            for (k = 0; k < left_cols; k++)
                sum += tensor_load(left, k) * tensor_load(right, k * right_cols + j);
            tensor_store_nv(result, j, sum);
        }
    }
    else for (i = 0; i < left_rows; i++) {
        for (j = 0; j < right_cols; j++) {
            sum = 0;
            for (k = 0; k < left_cols; k++)
                sum += tensor_load(left, i * left_cols + k)
                     * tensor_load(right, k * right_cols + j);
            tensor_store_nv(result, i * right_cols + j, sum);
        }
    }
    RETVAL = result_object;
  OUTPUT:
    RETVAL

NV
dot_product(object, other)
    SV *object
    SV *other
  PREINIT:
    tensor_header *left;
    tensor_header *right;
    UV i;
    NV result = 0;
  CODE:
    left = tensor_from_object(aTHX_ object);
    right = tensor_from_object(aTHX_ other);
    if (left->size != right->size)
        croak("dot product operands must have the same size");
    for (i = 0; i < left->size; i++)
        result += tensor_load(left, i) * tensor_load(right, i);
    RETVAL = result;
  OUTPUT:
    RETVAL
