# XS Tensor Representation

## Implementation status

The prototype distribution now contains a standalone `Tensor::XS` layer with
one PV-owned native allocation containing the tensor header, shape, strides,
and numeric data.  It currently exposes construction, rank, size, shape,
strides, flat indexing, row-major data access, and bounds-checked coordinate
access and mutation.  Flat and nested bulk loads validate completely before
publishing native data.  The existing `Tensor`, `Vector`, and `Matrix` classes
The public `Tensor` class now owns this native storage, and `Vector` and
`Matrix` inherit that storage through the Perl class layer.

The higher-level Perl methods retain their existing API.  Accessing `data`
returns a Perl list copy for those methods, and an in-place operation publishes
its completed result back through the XS bulk setter.  This keeps the native
allocation authoritative while allowing the existing Perl implementations to
be migrated to direct native operations independently.

This document describes the intended native representation of `Tensor` and
records the incremental XS implementation as it lands.

## Objective

Move the implementation of the core `Tensor` class from Perl arrays to XS,
while keeping `Vector`, `Matrix`, `Scalar`, and the higher-level neural-network
code layered on top of it.

The native tensor should be a single contiguous allocation. The allocation
should contain the tensor descriptor, its dimensions, its strides, and its
typed numeric data. It should be possible to allocate and free the complete
native tensor with one operation.

## Perl object representation

The Perl-facing object will be a blessed scalar reference. The scalar being
referenced will contain the native tensor allocation in its PV storage. The PV
is an opaque byte buffer as far as Perl is concerned; XS methods interpret its
contents according to the tensor header and dtype.

Conceptually:

```text
blessed scalar reference
└── scalar PV
    └── one native tensor allocation
```

The Perl wrapper is therefore small, while the tensor state is owned by the PV
and released when the object is destroyed. The XS destructor must release the
PV-backed allocation exactly once.

## Native allocation layout

The native allocation uses a fixed-size header followed by rank-sized metadata
arrays and then the aligned data region:

```text
┌──────────────────────────┐
│ fixed header             │
│   magic/version          │
│   rank                   │
│   element count          │
│   dtype                  │
│   flags/version          │
├──────────────────────────┤
│ shape[rank]              │
├──────────────────────────┤
│ strides[rank]            │
├──────────────────────────┤
│ alignment padding        │
├──────────────────────────┤
│ data[element count]      │
├──────────────────────────┤
│ aligned zero sentinel    │
└──────────────────────────┘
```

There are no pointers to `shape`, `strides`, or `data` stored in the native
allocation. Their addresses are calculated from the base address and the
header's rank and dtype. This keeps the allocation relocatable and makes the
whole tensor one owned block.

The blob begins with a nonzero magic and layout version.  Accessors validate
both values and the complete calculated blob size before interpreting the
metadata.  The data region is placed at an alignment boundary suitable for
the native numeric type, and the allocation ends with an aligned zero
sentinel outside the data region.  The sentinel is an integrity/layout aid;
it is not an element and is not included in `size`.

Rank determines the sizes of the metadata arrays. For example, rank 3 means
that the allocation contains three shape values and three stride values. The
dimension values themselves are supplied by the constructor. Their product
determines the number of data elements, which is stored separately in the
header.

For a contiguous row-major tensor with shape `[2, 3, 4]`:

```text
element count = 24
strides       = [12, 4, 1]
```

There is one stored stride per dimension, and the innermost stride is
explicitly stored as `1`.  This is the conventional layout used by CUDA and
similar tensor libraries.  The total element count remains in the header
rather than being added as a stride sentinel, so the native descriptor can be
passed to backend APIs with minimal translation.

The data offset is calculated after the metadata and rounded up to the
alignment required by the selected dtype. The XS implementation must not cast
an arbitrary byte offset to a typed pointer without performing this alignment
calculation.

## Header information

The fixed header should contain at least:

```text
magic         nonzero representation/layout marker
version       native layout version
rank          number of dimensions
size          total number of elements
dtype         representation of each element
flags         ownership/layout/version information as needed
```

Dimensions and strides should use a type capable of representing large tensor
sizes, such as `size_t` or an explicitly sized unsigned integer. 32-bit packed
integer fields should not be assumed to be sufficient for all tensors.

Shape and strides are technically redundant for contiguous row-major tensors,
but both should initially be stored. Shape is part of the public interface,
while strides are used frequently by indexing and multidimensional operations.
The small metadata cost is preferable to repeatedly reconstructing either one.

If non-contiguous views are introduced later, retaining both arrays becomes
necessary: arbitrary strides cannot in general be reconstructed from shape
alone.

## Supported data types

The tensor header contains an explicit dtype.  The dtype should be represented
by a stable code that indexes a descriptor rather than by a collection of
layout-specific conditionals.  The descriptor should provide at least:

```text
family       unsigned integer, signed integer, or floating point
bits         number of bits per element
encoding     ordinary integer, IEEE, BF16, FP8 variant, and so on
alignment    required alignment of an element
load/store   conversion between native storage and the operation type
```

Quantized formats should additionally be able to carry an optional scale and
zero point.  Those are interpretation metadata, not alternate element sizes,
and must not be confused with the raw storage dtype.

The initial practical candidates are:

```text
U8 U16 U32 U64
I8 I16 I32 I64
F16 BF16 F32 F64 NV
```

`NV` is Perl's native floating-point representation and uses `sizeof(NV)`
directly.  It may therefore coincide with `F64` on one build and have a
different width on another; it is not an alias that the layout may assume is
always eight bytes.

The data region is a homogeneous byte array interpreted through the selected
descriptor. The XS layer should centralize dtype properties such as element
size, alignment, numeric load/store behavior, and operation dispatch.  This
also permits later additions such as FP8 or packed integer formats without
changing the allocation header or pointer-calculation scheme.

The standalone XS constructor currently defaults to `BF16`, reflecting the
common reduced-precision neural-network use case.  The public `Tensor` wrapper
currently requests `F64` to preserve the established Perl API's precision;
that policy can change independently once operation promotion rules are
defined.  A C `short` is normally a 16-bit integer, not a 16-bit floating-point
type.  Half precision (`float16`) and bfloat16 are distinct dtypes.

Operations need explicit promotion rules. In particular, integer division,
transcendental functions, and neural-network operations will generally produce
floating-point results. Integer matrix multiplication should use a wider or
floating-point accumulator to avoid avoidable overflow.

## Allocation and destruction

Construction should:

1. Validate rank and dimension values.
2. Calculate the element count, checking for multiplication overflow.
3. Calculate contiguous row-major strides.
4. Calculate the metadata and aligned data offsets.
5. Allocate the complete byte block once.
6. Populate the header, shape, strides, and data.
7. Store the allocation in the scalar's PV and bless the scalar reference.

Destruction should release the single PV-backed allocation. No separate frees
should be necessary for shape, strides, or data.

The XS code should treat the PV as native storage, not as a serialized `pack`
format. The layout is an in-process representation and should not depend on
`pack "L"`, implicit endianness, or unaligned casts.

## Layering

The intended class layering is:

```text
XS Tensor storage and primitive operations
├── Vector-specific methods
├── Matrix-specific methods
└── Scalar wrapper/conversions
```

The existing Perl-level API should remain the conceptual guide:

- `shape`, `rank`, and `size`
- element access and dimension access
- element-wise unary and binary operations
- reductions
- matrix/vector multiplication
- constructors and dtype selection

`Vector`, `Matrix`, and `Scalar` should use the XS Tensor representation rather
than maintain separate storage models. Their methods may dispatch to
specialized XS implementations where that is useful, but ownership and basic
indexing should remain centralized in Tensor.

## Device backends

The native layout should be suitable for accelerator backends, but CUDA does
not require one universal matrix representation. CUDA kernels can use arbitrary
layouts, and traditional cuBLAS interfaces commonly use column-major matrices,
while C and this project currently use contiguous row-major matrices. Newer
CUDA interfaces can describe layouts explicitly. The important properties are
therefore:

- contiguous typed data for dense tensors;
- explicit dtype, shape, and stride information;
- a well-defined row-major convention for the host representation; and
- backend adapters that translate the descriptor to the selected device API.

The contiguous data region should be exposable to a backend as a pointer, byte
size, and dtype. Device APIs manage alignment for device allocations
independently; the CPU-side tensor metadata does not need to be arranged as a
GPU command or serialization format.

Automatic CUDA use requires more than choosing a compatible memory layout. A
CUDA backend will need to allocate a device buffer, copy host data to it,
dispatch a kernel or library operation, and copy results back or maintain a
device-resident tensor. The Tensor layer should consequently separate:

```text
Tensor descriptor and ownership
└── execution backend
    ├── Perl/XS CPU implementation
    ├── CUDA implementation
    └── other accelerator implementation
```

The backend should receive the data pointer together with rank, shape, and
strides. A future device-aware tensor may additionally track a host buffer, a
device buffer, and which copy is current. This allows CUDA or an equivalent
backend to be selected automatically without changing the public Vector or
Matrix API.

For matrix multiplication, the backend can either use a row-major-capable API,
map the operands through transpose/leading-dimension parameters, or perform a
conversion when necessary. The Tensor representation should not be changed to
column-major solely to match one CUDA library interface.
