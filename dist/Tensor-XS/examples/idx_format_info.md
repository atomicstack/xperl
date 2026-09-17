# MNIST IDX File Format - Parser Guide

## Format Overview

The IDX format is **very simple** - just a small header followed by raw data bytes.

## File Structure

### Header (Images File)

```
Offset  Size  Value       Description
------  ----  ----------  -----------
0       4     0x00000803  Magic number (2051 in decimal)
4       4     60000       Number of images
8       4     28          Number of rows
12      4     28          Number of columns
16      ...   [data]      Pixel values (unsigned bytes 0-255)
```

### Header (Labels File)

```
Offset  Size  Value       Description
------  ----  ----------  -----------
0       4     0x00000801  Magic number (2049 in decimal)
4       4     60000       Number of labels
8       ...   [data]      Label values (unsigned bytes 0-9)
```

## Complexity: ~30 Lines of Code!

### Simple Perl Implementation

```perl
use v5.40;

sub read_mnist_images ($filename) {
    open my $fh, '<:raw', $filename or die "Cannot open $filename: $!";

    # Read header (16 bytes)
    my $header;
    read($fh, $header, 16) == 16 or die "Failed to read header";

    # Unpack header: 4 big-endian 32-bit integers
    my ($magic, $num_images, $rows, $cols) = unpack('N4', $header);

    die "Invalid magic number" unless $magic == 2051;

    say "Images: $num_images, Size: ${rows}x${cols}";

    # Read all image data
    my $image_size = $rows * $cols;
    my @images;

    for my $i (1 .. $num_images) {
        my $data;
        read($fh, $data, $image_size) == $image_size or die "Failed to read image $i";

        # Convert bytes to array of pixels (0-255)
        my @pixels = unpack('C*', $data);

        # Normalize to 0-1 range
        @pixels = map { $_ / 255.0 } @pixels;

        push @images, \@pixels;
    }

    close $fh;
    return \@images;
}

sub read_mnist_labels ($filename) {
    open my $fh, '<:raw', $filename or die "Cannot open $filename: $!";

    # Read header (8 bytes)
    my $header;
    read($fh, $header, 8) == 8 or die "Failed to read header";

    # Unpack header
    my ($magic, $num_labels) = unpack('N2', $header);

    die "Invalid magic number" unless $magic == 2049;

    say "Labels: $num_labels";

    # Read all labels
    my $data;
    read($fh, $data, $num_labels) == $num_labels or die "Failed to read labels";

    # Convert to array
    my @labels = unpack('C*', $data);

    close $fh;
    return \@labels;
}
```

## That's It!

The entire parser is:
1. **Read 16-byte header** (or 8 bytes for labels)
2. **Extract dimensions** with `unpack('N4', ...)`
3. **Read raw bytes** in a loop
4. **Normalize pixels** to 0-1 range

## Key Points

### Magic Numbers
- `2051` (0x00000803) = Images file
- `2049` (0x00000801) = Labels file

Used to verify file format.

### Data Format
- **Big-endian** 32-bit integers in header
- **Unsigned bytes** (0-255) for pixels/labels
- **Row-major** order (read left-to-right, top-to-bottom)

### Perl's `unpack` Function
```perl
unpack('N4', $header)  # 4 big-endian 32-bit integers
unpack('C*', $data)    # Array of unsigned bytes
```

That's all you need!

## File Download

```bash
# Training set
wget http://yann.lecun.com/exdb/mnist/train-images-idx3-ubyte.gz
wget http://yann.lecun.com/exdb/mnist/train-labels-idx1-ubyte.gz

# Test set
wget http://yann.lecun.com/exdb/mnist/t10k-images-idx3-ubyte.gz
wget http://yann.lecun.com/exdb/mnist/t10k-labels-idx1-ubyte.gz

# Decompress
gunzip *.gz
```

## Integration with Our Library

Convert to Vector format:

```perl
use Vector;

my $images = read_mnist_images('train-images-idx3-ubyte');
my $labels = read_mnist_labels('train-labels-idx1-ubyte');

# Convert first image to Vector
my $image_vector = Vector->initialize(784, $images->[0]);

# Convert label to one-hot Vector
my $label = $labels->[0];  # e.g., 5
my @one_hot = (0) x 10;
$one_hot[$label] = 1;
my $label_vector = Vector->initialize(10, \@one_hot);

# Ready to train!
```

## Complexity Rating

**Difficulty**: ⭐☆☆☆☆ (1/5 stars)

- No complex parsing logic
- No compression handling (just use gunzip first)
- No variable-length records
- Just binary read + unpack

**Time to Implement**: 15-30 minutes

**Lines of Code**: ~50 lines total (with error handling and comments)

## Gotchas (Easy to Handle)

1. **Endianness**: Use `'N'` in unpack for big-endian
2. **Binary Mode**: Open with `<:raw` mode
3. **Gzip**: Decompress files first with gunzip
4. **Memory**: 60,000 × 784 = ~47MB (easily fits in RAM)

## Alternative: Use CPAN Module

If you want even simpler:

```perl
use AI::MNIST;

my ($train_images, $train_labels) = AI::MNIST::load_train();
my ($test_images, $test_labels) = AI::MNIST::load_test();
```

But writing it yourself is educational and only takes a few minutes!
