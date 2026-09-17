=head1 NAME

MNIST - MNIST data helper class

=cut

use v5.40;
use experimental qw[ class ];

our $VERSION = '0.01';

use Carp;
use Vector;

# MNIST IDX File Format Parser
# Reads MNIST dataset files in IDX format
class MNIST {

    # Read MNIST images file (IDX3 format)
    sub read_images ($class, $filename) {
        open my $fh, '<:raw', $filename
            or Carp::croak "Cannot open $filename: $!";

        # Read 16-byte header
        my $header;
        read($fh, $header, 16) == 16
            or Carp::croak "Failed to read header from $filename";

        # Unpack header: 4 big-endian 32-bit integers
        my ($magic, $num_images, $rows, $cols) = unpack('N4', $header);

        # Verify magic number for images file
        Carp::croak "Invalid magic number (got $magic, expected 2051)"
            unless $magic == 2051;

        say "Loading images from $filename...";
        say "  Number of images: $num_images";
        say "  Image size: ${rows}x${cols}";

        my $image_size = $rows * $cols;
        my @images;
        my $progress_step = int($num_images / 10) || 1;

        for my $i (0 .. $num_images - 1) {
            # Show progress
            if (($i + 1) % $progress_step == 0) {
                printf "  Loading... %.0f%%\r", (($i + 1) / $num_images * 100);
            }

            # Read image data
            my $data;
            read($fh, $data, $image_size) == $image_size
                or Carp::croak "Failed to read image $i";

            # Convert bytes to array of pixels (0-255)
            my @pixels = unpack('C*', $data);

            # Normalize to 0-1 range
            @pixels = map { $_ / 255.0 } @pixels;

            # Convert to Vector
            my $image_vector = Vector->initialize($image_size, \@pixels);
            push @images, $image_vector;
        }

        close $fh;
        say "  Loading... 100% - Complete!          ";
        return \@images;
    }

    # Read MNIST labels file (IDX1 format)
    sub read_labels ($class, $filename) {
        open my $fh, '<:raw', $filename
            or Carp::croak "Cannot open $filename: $!";

        # Read 8-byte header
        my $header;
        read($fh, $header, 8) == 8
            or Carp::croak "Failed to read header from $filename";

        # Unpack header: 2 big-endian 32-bit integers
        my ($magic, $num_labels) = unpack('N2', $header);

        # Verify magic number for labels file
        Carp::croak "Invalid magic number (got $magic, expected 2049)"
            unless $magic == 2049;

        say "Loading labels from $filename...";
        say "  Number of labels: $num_labels";

        # Read all label data
        my $data;
        read($fh, $data, $num_labels) == $num_labels
            or Carp::croak "Failed to read labels";

        # Convert to array
        my @labels = unpack('C*', $data);

        close $fh;
        say "  Complete!";
        return \@labels;
    }

    # Convert a label (0-9) to one-hot encoded vector
    sub label_to_one_hot ($class, $label, $num_classes=10) {
        my @one_hot = (0) x $num_classes;
        $one_hot[$label] = 1;
        return Vector->initialize($num_classes, \@one_hot);
    }

    # Load training set
    sub load_training_data ($class, $images_file, $labels_file, $limit=undef) {
        my $images = $class->read_images($images_file);
        my $labels = $class->read_labels($labels_file);

        Carp::croak "Mismatch: " . scalar(@$images) . " images vs " .
                    scalar(@$labels) . " labels"
            unless scalar(@$images) == scalar(@$labels);

        # Apply limit if specified
        if (defined $limit && $limit < scalar(@$images)) {
            say "\nLimiting dataset to first $limit samples...";
            @$images = @$images[0 .. $limit - 1];
            @$labels = @$labels[0 .. $limit - 1];
        }

        # Convert labels to one-hot vectors
        my @one_hot_labels = map {
            $class->label_to_one_hot($_)
        } @$labels;

        say "\nDataset ready:";
        say "  Total samples: " . scalar(@$images);
        say "  Input size: " . $images->[0]->size;
        say "  Output size: " . $one_hot_labels[0]->size;

        return ($images, \@one_hot_labels, $labels);
    }

    # Display an image as ASCII art (for debugging)
    sub display_image ($class, $image_vector, $label=undef) {
        my @pixels = $image_vector->to_list;

        say "=" x 30;
        say "Label: $label" if defined $label;
        say "-" x 30;

        # Display 28x28 image
        for my $row (0 .. 27) {
            for my $col (0 .. 27) {
                my $idx = $row * 28 + $col;
                my $pixel = $pixels[$idx];

                # Convert to ASCII shade
                if ($pixel < 0.2) {
                    print ' ';
                } elsif ($pixel < 0.4) {
                    print '.';
                } elsif ($pixel < 0.6) {
                    print ':';
                } elsif ($pixel < 0.8) {
                    print '#';
                } else {
                    print '@';
                }
            }
            say '';
        }
        say "=" x 30;
    }

    # Get dataset statistics
    sub dataset_stats ($class, $labels) {
        my %counts;
        for my $label (@$labels) {
            $counts{$label}++;
        }

        say "\nDataset Statistics:";
        say "  Total samples: " . scalar(@$labels);
        say "  Class distribution:";
        for my $digit (0 .. 9) {
            my $count = $counts{$digit} || 0;
            my $pct = sprintf("%.1f", $count / scalar(@$labels) * 100);
            my $bar = '#' x int($count / 100);
            printf "    Digit %d: %5d (%5s%%) %s\n",
                $digit, $count, $pct, $bar;
        }
    }
}

1;

__END__

=head1 NAME

MNIST - MNIST Dataset IDX Format Parser

=head1 SYNOPSIS

    use MNIST;

    # Load training data
    my ($images, $one_hot_labels, $raw_labels) =
        MNIST->load_training_data(
            'train-images-idx3-ubyte',
            'train-labels-idx1-ubyte'
        );

    # Load with limit (for testing)
    my ($images, $labels, $raw) =
        MNIST->load_training_data(
            'train-images-idx3-ubyte',
            'train-labels-idx1-ubyte',
            1000  # Only load first 1000 samples
        );

    # Display sample image
    MNIST->display_image($images->[0], $raw_labels->[0]);

    # Show dataset statistics
    MNIST->dataset_stats($raw_labels);

=head1 DESCRIPTION

This module parses MNIST dataset files in IDX format and converts them
to Vector objects suitable for neural network training.

=head1 METHODS

=head2 read_images($filename)

Reads MNIST images file (IDX3 format). Returns arrayref of Vector objects.

=head2 read_labels($filename)

Reads MNIST labels file (IDX1 format). Returns arrayref of label integers (0-9).

=head2 load_training_data($images_file, $labels_file, $limit)

Convenience method that loads both images and labels, converts labels to
one-hot encoding, and returns everything ready for training.

Returns: ($images_arrayref, $one_hot_labels_arrayref, $raw_labels_arrayref)

=head2 label_to_one_hot($label, $num_classes)

Converts a label (0-9) to a one-hot encoded Vector.

=head2 display_image($image_vector, $label)

Displays an image as ASCII art for debugging/visualization.

=head2 dataset_stats($labels)

Prints statistics about the dataset (class distribution).

=head1 FILE FORMAT

MNIST IDX format specification:

Images file header (16 bytes):
  - Magic number: 2051 (0x00000803)
  - Number of images: 32-bit integer
  - Rows: 32-bit integer (28)
  - Columns: 32-bit integer (28)
  - Pixel data: unsigned bytes (0-255)

Labels file header (8 bytes):
  - Magic number: 2049 (0x00000801)
  - Number of labels: 32-bit integer
  - Label data: unsigned bytes (0-9)

All integers are big-endian.

=head1 AUTHOR

Generated for the Tensor-XS MNIST training example.

=cut
