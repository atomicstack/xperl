#!/usr/bin/env perl
use v5.40;
use experimental qw[ class ];

use lib 'lib';
use Matrix;
use Vector;
use MNIST;
use Time::HiRes qw(time);

# Performance Benchmark for MNIST Training

sub benchmark ($name, $iterations, $code) {
    say "\n$name:";
    say "  Running $iterations iterations...";

    my $start = time();
    for (1 .. $iterations) {
        $code->();
    }
    my $elapsed = time() - $start;
    my $per_iter = $elapsed / $iterations * 1000;

    printf "  Total: %.3f seconds\n", $elapsed;
    printf "  Per iteration: %.3f ms\n", $per_iter;
    printf "  Throughput: %.1f ops/sec\n", $iterations / $elapsed;

    return $elapsed;
}

say "=" x 60;
say "MNIST Training Performance Benchmark";
say "=" x 60;

# Test 1: Data loading
say "\n" . "=" x 60;
say "Test 1: Data Loading";
say "=" x 60;

my $start = time();
my ($images, $one_hot_labels, $raw_labels) =
    MNIST->load_training_data('data/train-images.idx3-ubyte',
                               'data/train-labels.idx1-ubyte',
                               100);
my $load_time = time() - $start;
printf "Loaded 100 images in %.3f seconds (%.1f images/sec)\n",
    $load_time, 100 / $load_time;

# Test 2: Basic vector/matrix operations
say "\n" . "=" x 60;
say "Test 2: Basic Operations";
say "=" x 60;

my $v1 = Vector->randn([784]);
my $v2 = Vector->randn([784]);
my $m1 = Matrix->randn([784, 128]);

benchmark("Vector addition (784 elements)", 1000, sub {
    my $result = $v1->add($v2);
});

benchmark("Vector dot product (784 elements)", 1000, sub {
    my $result = $v1->dot_product($v2);
});

benchmark("Matrix-Vector multiply (784x128)", 100, sub {
    my $result = $v1->matrix_multiply($m1);
});

# Test 3: Activation functions
say "\n" . "=" x 60;
say "Test 3: Activation Functions";
say "=" x 60;

my $hidden = Vector->randn([128]);

benchmark("ReLU (128 elements)", 1000, sub {
    my $result = $hidden->relu;
});

benchmark("Softmax (10 elements)", 1000, sub {
    my $out = Vector->randn([10]);
    my $result = $out->softmax;
});

# Test 4: Single forward pass
say "\n" . "=" x 60;
say "Test 4: Neural Network Forward Pass";
say "=" x 60;

my $W1 = Matrix->randn([784, 128], 0, 0.05);
my $b1 = Vector->zeros([128]);
my $W2 = Matrix->randn([128, 10], 0, 0.05);
my $b2 = Vector->zeros([10]);

my $sample_image = $images->[0];

benchmark("Forward pass (784->128->10)", 100, sub {
    # Layer 1
    my $Z1 = $sample_image->matrix_multiply($W1);
    for my $i (0 .. 127) {
        $Z1->data->[$i] += $b1->at($i);
    }
    my $A1 = $Z1->relu;

    # Layer 2
    my $Z2 = $A1->matrix_multiply($W2);
    for my $i (0 .. 9) {
        $Z2->data->[$i] += $b2->at($i);
    }
    my $A2 = $Z2->softmax;
});

# Test 5: Gradient computation
say "\n" . "=" x 60;
say "Test 5: Backward Pass (Gradients)";
say "=" x 60;

# Forward pass first
my $Z1 = $sample_image->matrix_multiply($W1);
for my $i (0 .. 127) {
    $Z1->data->[$i] += $b1->at($i);
}
my $A1 = $Z1->relu;
my $Z2 = $A1->matrix_multiply($W2);
for my $i (0 .. 9) {
    $Z2->data->[$i] += $b2->at($i);
}
my $A2 = $Z2->softmax;

benchmark("Backward pass (gradients)", 100, sub {
    # Output gradients
    my $dZ2 = $A2->sub($one_hot_labels->[0]);

    # W2 gradients
    my $A1_as_matrix = Matrix->initialize([1, 128], [$A1->to_list]);
    my $dZ2_as_matrix = Matrix->initialize([1, 10], [$dZ2->to_list]);
    my $dW2 = $A1_as_matrix->transpose->matrix_multiply($dZ2_as_matrix);

    # Hidden gradients
    my $dA1 = $dZ2->matrix_multiply($W2->transpose);
    my $relu_mask = $Z1->gt(0);
    my $dZ1 = $dA1->mul($relu_mask);

    # W1 gradients
    my $X_as_matrix = Matrix->initialize([1, 784], [$sample_image->to_list]);
    my $dZ1_as_matrix = Matrix->initialize([1, 128], [$dZ1->to_list]);
    my $dW1 = $X_as_matrix->transpose->matrix_multiply($dZ1_as_matrix);
});

# Test 6: Complete training iteration
say "\n" . "=" x 60;
say "Test 6: Complete Training Iteration";
say "=" x 60;

benchmark("Full iteration (forward + backward + update)", 10, sub {
    # Forward
    my $Z1 = $sample_image->matrix_multiply($W1);
    for my $i (0 .. 127) {
        $Z1->data->[$i] += $b1->at($i);
    }
    my $A1 = $Z1->relu;
    my $Z2 = $A1->matrix_multiply($W2);
    for my $i (0 .. 9) {
        $Z2->data->[$i] += $b2->at($i);
    }
    my $A2 = $Z2->softmax;

    # Backward
    my $dZ2 = $A2->sub($one_hot_labels->[0]);
    my $A1_as_matrix = Matrix->initialize([1, 128], [$A1->to_list]);
    my $dZ2_as_matrix = Matrix->initialize([1, 10], [$dZ2->to_list]);
    my $dW2 = $A1_as_matrix->transpose->matrix_multiply($dZ2_as_matrix);
    my $dA1 = $dZ2->matrix_multiply($W2->transpose);
    my $relu_mask = $Z1->gt(0);
    my $dZ1 = $dA1->mul($relu_mask);
    my $X_as_matrix = Matrix->initialize([1, 784], [$sample_image->to_list]);
    my $dZ1_as_matrix = Matrix->initialize([1, 128], [$dZ1->to_list]);
    my $dW1 = $X_as_matrix->transpose->matrix_multiply($dZ1_as_matrix);

    # Update (simplified)
    $W1 = $W1->sub($dW1->mul(0.01));
    $W2 = $W2->sub($dW2->mul(0.01));
});

# Summary
say "\n" . "=" x 60;
say "Performance Estimates";
say "=" x 60;

# Calculate estimated training times
my $iter_time = 0;
benchmark("Sample training iteration", 1, sub {
    my $Z1 = $sample_image->matrix_multiply($W1);
    for my $i (0 .. 127) { $Z1->data->[$i] += $b1->at($i); }
    my $A1 = $Z1->relu;
    my $Z2 = $A1->matrix_multiply($W2);
    for my $i (0 .. 9) { $Z2->data->[$i] += $b2->at($i); }
    my $A2 = $Z2->softmax;
    my $dZ2 = $A2->sub($one_hot_labels->[0]);
    my $A1_as_matrix = Matrix->initialize([1, 128], [$A1->to_list]);
    my $dZ2_as_matrix = Matrix->initialize([1, 10], [$dZ2->to_list]);
    my $dW2 = $A1_as_matrix->transpose->matrix_multiply($dZ2_as_matrix);
    my $dA1 = $dZ2->matrix_multiply($W2->transpose);
    my $relu_mask = $Z1->gt(0);
    my $dZ1 = $dA1->mul($relu_mask);
    my $X_as_matrix = Matrix->initialize([1, 784], [$sample_image->to_list]);
    my $dZ1_as_matrix = Matrix->initialize([1, 128], [$dZ1->to_list]);
    my $dW1 = $X_as_matrix->transpose->matrix_multiply($dZ1_as_matrix);
    $W1 = $W1->sub($dW1->mul(0.01));
    $W2 = $W2->sub($dW2->mul(0.01));
});

say "\nEstimated Training Times:";
say "-" x 60;

my $sec_per_sample = $iter_time;
my $samples_per_sec = $sec_per_sample > 0 ? (1 / $sec_per_sample) : 0;

printf "  Throughput: %.1f samples/second\n", $samples_per_sec;
printf "  Time per sample: %.0f ms\n", $sec_per_sample * 1000;

say "\n  For different dataset sizes (10 epochs):";
my @sizes = (100, 500, 1000, 5000, 10000, 60000);
for my $size (@sizes) {
    my $total_sec = $size * 10 * $sec_per_sample;
    if ($total_sec < 60) {
        printf "    %6d samples: %.1f seconds\n", $size, $total_sec;
    } elsif ($total_sec < 3600) {
        printf "    %6d samples: %.1f minutes\n", $size, $total_sec / 60;
    } else {
        printf "    %6d samples: %.1f hours\n", $size, $total_sec / 3600;
    }
}

say "\n" . "=" x 60;
say "Benchmark Complete";
say "=" x 60;

__END__

=head1 NAME

benchmark.pl - Performance Benchmark for MNIST Training

=head1 SYNOPSIS

    perl examples/benchmark.pl

=head1 DESCRIPTION

This script benchmarks the performance of various operations used in
MNIST training to estimate total training time and identify bottlenecks.

Tests include:
- Data loading
- Vector/matrix operations
- Activation functions
- Forward pass
- Backward pass (gradients)
- Complete training iteration

The script provides estimates for training time with different dataset
sizes and helps identify performance optimization opportunities.

=cut
