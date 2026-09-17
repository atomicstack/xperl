#!/usr/bin/env perl
use v5.40;
use experimental qw[ class ];

use lib 'lib';
use Matrix;
use Vector;

# Simple 2-layer neural network for MNIST digit classification
# Architecture: 784 -> 128 -> 10
# Input: 28x28 grayscale image (784 pixels)
# Hidden: 128 neurons with ReLU activation
# Output: 10 neurons with softmax (digit 0-9)

class MNISTNetwork {
    # Network parameters
    field $W1 :reader;  # Weights layer 1: (784, 128)
    field $b1 :reader;  # Bias layer 1: (128,)
    field $W2 :reader;  # Weights layer 2: (128, 10)
    field $b2 :reader;  # Bias layer 2: (10,)

    # Hyperparameters
    field $learning_rate :param = 0.01;
    field $input_size    :param = 784;   # 28x28 flattened
    field $hidden_size   :param = 128;
    field $output_size   :param = 10;    # 10 digits

    ADJUST {
        say "Initializing MNIST Neural Network...";
        say "  Input size: $input_size";
        say "  Hidden size: $hidden_size";
        say "  Output size: $output_size";
        say "  Learning rate: $learning_rate";

        # Xavier/Glorot initialization for better convergence
        my $w1_scale = sqrt(2.0 / $input_size);
        my $w2_scale = sqrt(2.0 / $hidden_size);

        $W1 = Matrix->randn([$input_size, $hidden_size], 0, $w1_scale);
        $b1 = Vector->zeros([$hidden_size]);
        $W2 = Matrix->randn([$hidden_size, $output_size], 0, $w2_scale);
        $b2 = Vector->zeros([$output_size]);

        say "  Weights initialized with Xavier scaling";
    }

    method forward ($X) {
        # Forward pass through the network
        # $X is a Vector of size 784 (flattened 28x28 image)

        # Layer 1: Linear + ReLU
        # Z1 = X^T * W1 + b1
        my $X_vec = $X;
        my $Z1 = $X_vec->matrix_multiply($W1);

        # Add bias (broadcasting)
        for my $i (0 .. $hidden_size - 1) {
            $Z1->data->[$i] += $b1->at($i);
        }

        my $A1 = $Z1->relu;  # ReLU activation

        # Layer 2: Linear + Softmax
        # Z2 = A1^T * W2 + b2
        my $Z2 = $A1->matrix_multiply($W2);

        # Add bias (broadcasting)
        for my $i (0 .. $output_size - 1) {
            $Z2->data->[$i] += $b2->at($i);
        }

        my $A2 = $Z2->softmax;  # Softmax for probability distribution

        return ($A1, $A2);  # Return hidden activation and final output
    }

    method predict ($X) {
        # Make a prediction for input $X
        my ($A1, $output) = $self->forward($X);

        # Find the index of maximum probability (predicted digit)
        my $max_idx = 0;
        my $max_val = $output->at(0);
        for my $i (1 .. $output_size - 1) {
            if ($output->at($i) > $max_val) {
                $max_val = $output->at($i);
                $max_idx = $i;
            }
        }

        return ($max_idx, $max_val, $output);
    }

    method summary {
        say "\n" . "=" x 60;
        say "Neural Network Architecture Summary";
        say "=" x 60;
        say sprintf("Layer 1 (Input):   %d neurons", $input_size);
        say sprintf("Layer 2 (Hidden):  %d neurons (ReLU activation)", $hidden_size);
        say sprintf("Layer 3 (Output):  %d neurons (Softmax activation)", $output_size);
        say "-" x 60;
        say sprintf("Total parameters: %d",
            $W1->size + $b1->size + $W2->size + $b2->size);
        say sprintf("  W1: %dx%d = %d", $input_size, $hidden_size, $W1->size);
        say sprintf("  b1: %d", $b1->size);
        say sprintf("  W2: %dx%d = %d", $hidden_size, $output_size, $W2->size);
        say sprintf("  b2: %d", $b2->size);
        say "=" x 60;
    }
}

# Demonstrate the network
say "\n" . "=" x 60;
say "MNIST Neural Network Example";
say "=" x 60 . "\n";

# Create the network
my $network = MNISTNetwork->new(
    input_size => 784,
    hidden_size => 128,
    output_size => 10,
    learning_rate => 0.01
);

$network->summary;

# Create a sample input (random image)
say "\nGenerating random test image (28x28 = 784 pixels)...";
my $sample_image = Vector->random([784], 0, 1);

say "Running forward pass...";
my ($predicted_digit, $confidence, $probabilities) = $network->predict($sample_image);

say "\nPrediction Results:";
say "  Predicted digit: $predicted_digit";
say sprintf("  Confidence: %.2f%%", $confidence * 100);
say "\nProbability distribution:";
for my $digit (0 .. 9) {
    my $prob = $probabilities->at($digit);
    my $bar = "#" x int($prob * 50);
    say sprintf("  Digit %d: %.4f %s", $digit, $prob, $bar);
}

# Demonstrate network operations
say "\n" . "=" x 60;
say "Testing Network Operations";
say "=" x 60;

say "\n1. Testing activation functions:";
my $test_vec = Vector->initialize(5, [-2, -1, 0, 1, 2]);
say "   Input: " . join(", ", map { sprintf("%.1f", $_) } $test_vec->to_list);
say "   ReLU: " . join(", ", map { sprintf("%.1f", $_) } $test_vec->relu->to_list);
say "   Sigmoid: " . join(", ", map { sprintf("%.3f", $_) } $test_vec->sigmoid->to_list);

say "\n2. Testing matrix operations:";
my $test_matrix = Matrix->initialize([2, 3], [1, 2, 3, 4, 5, 6]);
say "   Original matrix (2x3):";
say "   " . join("\n   ", split /\n/, "$test_matrix");
my $transposed = $test_matrix->transpose;
say "   Transposed matrix (3x2):";
say "   " . join("\n   ", split /\n/, "$transposed");

say "\n3. Testing reductions:";
my $data = Vector->initialize(5, [1, 2, 3, 4, 5]);
say "   Vector: " . join(", ", $data->to_list);
say "   Sum: " . $data->sum;
say "   Mean: " . $data->mean;
say "   Min: " . $data->min_value;
say "   Max: " . $data->max_value;

say "\n" . "=" x 60;
say "Network ready for training!";
say "=" x 60;

say "\nNext steps for MNIST classification:";
say "  1. Load MNIST dataset (training and test images)";
say "  2. Implement backpropagation for training";
say "  3. Train the network with mini-batch gradient descent";
say "  4. Evaluate accuracy on test set";
say "  5. Visualize learned weights and predictions";

__END__

=head1 NAME

mnist_network.pl - MNIST Digit Classification Neural Network Example

=head1 DESCRIPTION

This script demonstrates a 2-layer neural network for MNIST digit classification
using the Matrix/Vector/Tensor library.

Architecture:
- Input Layer: 784 neurons (28x28 flattened grayscale image)
- Hidden Layer: 128 neurons with ReLU activation
- Output Layer: 10 neurons with Softmax activation (digits 0-9)

Features demonstrated:
- Xavier weight initialization
- Forward propagation
- ReLU and Softmax activations
- Matrix-vector operations
- Prediction with confidence scores

=head1 USAGE

    perl examples/mnist_network.pl

=head1 NEXT STEPS

To build a complete MNIST classifier:
1. Load MNIST dataset (http://yann.lecun.com/exdb/mnist/)
2. Implement backpropagation
3. Add training loop with mini-batch gradient descent
4. Compute cross-entropy loss
5. Track accuracy metrics

=cut
