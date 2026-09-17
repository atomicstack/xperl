# 🔬 Further Optimization Opportunities

## Current Performance Analysis

We achieved 25x speedup, but there's definitely room for more! Let's analyze the current bottlenecks.

### Current Hotspots (from benchmark)

**Training iteration breakdown (~70ms total):**
- Forward pass: ~7ms
- Backward pass: ~24ms (3.4x slower than forward!)
- Weight updates: ~39ms remaining

The backward pass is the biggest bottleneck now.

## Optimization Opportunities

### 1. **Array Access Pattern (LOW-HANGING FRUIT)**

**Current Code (Matrix×Vector):**
```perl
for my $r (0 .. $rows - 1) {
    my $sum = 0;
    my $row_start = $r * $cols;
    for my $c (0 .. $cols - 1) {
        $sum += $mat_data->[$row_start + $c] * $vec_data->[$c];
    }
    push @result, $sum;
}
```

**Problems:**
- `push @result` reallocates array on each iteration
- Range operator `0 .. $n-1` creates an array in memory
- Hash dereference `$mat_data->[$i]` has overhead

**Optimized Version:**
```perl
# Pre-allocate result array
my @result = (0) x $rows;  # Or: $#result = $rows - 1;

# C-style loop (faster than range)
for (my $r = 0; $r < $rows; $r++) {
    my $sum = 0;
    my $row_start = $r * $cols;

    # Cache array refs in scalars
    for (my $c = 0; $c < $cols; $c++) {
        $sum += $mat_data->[$row_start + $c] * $vec_data->[$c];
    }
    $result[$r] = $sum;
}
```

**Expected speedup:** 10-20%

### 2. **Loop Unrolling (MODERATE EFFORT)**

**Current Inner Loop:**
```perl
for (my $c = 0; $c < $cols; $c++) {
    $sum += $mat_data->[$row_start + $c] * $vec_data->[$c];
}
```

**Unrolled Version (process 4 elements at once):**
```perl
my $c = 0;
my $limit = $cols - 3;

# Process 4 at a time
while ($c < $limit) {
    $sum += $mat_data->[$row_start + $c]     * $vec_data->[$c];
    $sum += $mat_data->[$row_start + $c + 1] * $vec_data->[$c + 1];
    $sum += $mat_data->[$row_start + $c + 2] * $vec_data->[$c + 2];
    $sum += $mat_data->[$row_start + $c + 3] * $vec_data->[$c + 3];
    $c += 4;
}

# Handle remainder
while ($c < $cols) {
    $sum += $mat_data->[$row_start + $c] * $vec_data->[$c];
    $c++;
}
```

**Expected speedup:** 15-30% (reduces loop overhead)

### 3. **Cache Locality for Matrix×Matrix (ALGORITHMIC)**

**Current Code (naive order):**
```perl
for my $i (0 .. $m - 1) {           # Rows of A
    for my $j (0 .. $p - 1) {       # Cols of B
        my $sum = 0;
        for my $k (0 .. $n - 1) {   # Inner dimension
            # Access B[k,j] - stride access, BAD for cache!
            $sum += $a_data->[$i * $n + $k] * $b_data->[$k * $p + $j];
        }
        push @result, $sum;
    }
}
```

**Problem:** Accessing `B[k,j]` with stride `p` causes cache misses.

**Better: Transpose B First (if used multiple times)**
```perl
# In backprop, W2->transpose is computed, then used for gradient
# Instead of: $dA1 = $dZ2->matrix_multiply($W2->transpose)
# Cache:      $W2_T = $W2->transpose  # Do once
#             $dA1 = $dZ2->matrix_multiply($W2_T)  # Use cached
```

We're already doing some transposes, but we could cache them across samples.

**Expected speedup:** 20-40% for matrix×matrix ops

### 4. **Reduce Object Creation (CRITICAL PATH)**

**Current Training Loop:**
```perl
for my $epoch (1 .. $epochs) {
    for my $i (0 .. $num_samples - 1) {
        my ($Z1, $A1, $Z2, $A2) = $self->forward($X);
        # Creates 4 Vector objects per sample

        my ($dW1, $db1, $dW2, $db2) = $self->backward(...);
        # Creates 4 more objects

        $self->update_weights($dW1, $db1, $dW2, $db2);
        # Creates 8 more objects in subtraction operations
    }
}
```

**Each iteration creates ~16 Vector/Matrix objects!**

**Optimization: In-Place Updates**
```perl
# Instead of: $W1 = $W1->sub($dW1->mul($learning_rate))
# Do:         $self->update_weights_inplace($dW1, $db1, $dW2, $db2)

method update_weights_inplace ($dW1, $db1, $dW2, $db2) {
    my $W1_data = $W1->data;
    my $dW1_data = $dW1->data;

    # Update in place (no new object)
    for (my $i = 0; $i < @$W1_data; $i++) {
        $W1_data->[$i] -= $learning_rate * $dW1_data->[$i];
    }
    # Similar for b1, W2, b2
}
```

**Expected speedup:** 30-50% (eliminates most allocations)

### 5. **Vectorized Operations (XS/PDL)**

**Current: Pure Perl loops**
```perl
for (my $c = 0; $c < $cols; $c++) {
    $sum += $mat_data->[$row_start + $c] * $vec_data->[$c];
}
```

**Option A: Perl Data Language (PDL)**
```perl
use PDL;

# Convert to PDL objects (once)
my $mat_pdl = pdl($mat_data)->reshape($rows, $cols);
my $vec_pdl = pdl($vec_data);

# Matrix multiply in C
my $result_pdl = $mat_pdl x $vec_pdl;
```

**Option B: Inline::C**
```perl
use Inline C => <<'END_C';
void matrix_vec_mult(AV* mat, AV* vec, AV* result,
                     int rows, int cols) {
    double* m = /* extract from AV */;
    double* v = /* extract from AV */;
    double* r = /* extract from AV */;

    for (int i = 0; i < rows; i++) {
        double sum = 0.0;
        for (int j = 0; j < cols; j++) {
            sum += m[i * cols + j] * v[j];
        }
        r[i] = sum;
    }
}
END_C
```

**Expected speedup:** 5-10x additional (C is much faster than Perl)

### 6. **Reduce Method Call Overhead**

**Current:**
```perl
my $rows = $self->rows;  # Method call
my $cols = $self->cols;  # Method call
my $data = $self->data;  # Method call
```

Each method call has overhead. For hot paths:

**Optimization:**
```perl
# Cache in object fields (if not already)
field $rows :reader;
field $cols :reader;
field $data :reader;

# Or access directly (if same class)
my $rows = $self->{rows};  # Direct hash access (faster)
```

**Expected speedup:** 5-10%

### 7. **Specialized Fast Paths**

**For common sizes (784×128, 128×10):**
```perl
method matrix_multiply_fast ($other) {
    # Fast path for specific sizes
    if ($self->rows == 784 && $self->cols == 128 && $other isa Vector) {
        return $self->matrix_multiply_784x128_vec($other);
    }
    # ... general case
}

method matrix_multiply_784x128_vec ($vec) {
    # Hand-optimized for this exact size
    # Could unroll loops, use specific patterns, etc.
}
```

**Expected speedup:** 20-30% for MNIST specifically

## Potential Speedup Stack

If we implement all of these:

| Optimization | Expected Gain | Cumulative |
|--------------|---------------|------------|
| Current | 1.0x (baseline) | 1.0x |
| Pre-allocated arrays + C-style loops | 1.15x | 1.15x |
| Loop unrolling | 1.20x | 1.38x |
| Cache transposes | 1.30x | 1.79x |
| In-place updates | 1.40x | 2.51x |
| Inline::C for matmul | 8.0x | **20x** |

**Total potential: 20x on top of current = 500x vs original!**

With that, full MNIST (60k samples) would take:
- Current optimized: 11.7 hours
- Fully optimized: **1.4 hours**
- With XS/C: **~20 minutes** 🚀

## Benchmarking the Optimizations

Let's measure each one systematically:

```perl
# examples/optimization_bench.pl

sub test_optimization {
    my ($name, $implementation) = @_;

    # Warm up
    for (1..10) { $implementation->() }

    # Measure
    my $start = time();
    for (1..1000) { $implementation->() }
    my $elapsed = time() - $start;

    printf "%s: %.3f ms/op\n", $name, $elapsed;
}
```

## Recommended Priority

**Quick Wins (1-2 hours):**
1. ✅ Pre-allocated arrays + C-style loops
2. ✅ In-place weight updates
3. ✅ Cache transposed weights in training loop

**Expected: 2-3x additional speedup (50-75x total)**

**Medium Effort (4-6 hours):**
4. Loop unrolling for inner products
5. Specialized fast paths for MNIST sizes
6. Better cache locality patterns

**Expected: 1.5-2x additional (100-150x total)**

**Big Project (1-2 days):**
7. Inline::C or PDL integration
8. BLAS backend (OpenBLAS, Intel MKL)

**Expected: 5-10x additional (500-1000x total)**

## Next Steps

Want me to implement the quick wins? We could potentially get to **50-75x** total speedup with just a few hours of work!

The approach would be:
1. Create `lib/Matrix/Fast.pm` with optimized versions
2. Add in-place update methods
3. Modify training loop to use cached transposes
4. Benchmark and compare

What do you think?
