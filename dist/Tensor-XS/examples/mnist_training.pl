#!/usr/bin/env perl
use v5.40;
use experimental qw[ class ];

use lib 'lib';
use Matrix;
use Vector;
use MNIST;

# MNIST Neural Network Training
# Train a neural network to recognize handwritten digits (0-9)

class NeuralNetwork {
    # Network parameters
    field $W1 :reader;  # Weights layer 1
    field $b1 :reader;  # Bias layer 1
    field $W2 :reader;  # Weights layer 2
    field $b2 :reader;  # Bias layer 2

    # Hyperparameters
    field $learning_rate :param = 0.01;
    field $input_size    :param;
    field $hidden_size   :param;
    field $output_size   :param;

    # Training history
    field @loss_history;
    field @accuracy_history;

    ADJUST {
        say "Initializing Neural Network...";
        say "  Input size: $input_size";
        say "  Hidden size: $hidden_size";
        say "  Output size: $output_size";
        say "  Learning rate: $learning_rate";

        # Xavier/Glorot initialization
        my $w1_scale = sqrt(2.0 / $input_size);
        my $w2_scale = sqrt(2.0 / $hidden_size);

        $W1 = Matrix->randn([$input_size, $hidden_size], 0, $w1_scale);
        $b1 = Vector->zeros([$hidden_size]);
        $W2 = Matrix->randn([$hidden_size, $output_size], 0, $w2_scale);
        $b2 = Vector->zeros([$output_size]);

        my $total_params = $input_size * $hidden_size + $hidden_size +
                          $hidden_size * $output_size + $output_size;
        say "  Total parameters: $total_params";

        @loss_history = ();
        @accuracy_history = ();
    }

    method forward ($X) {
        # Forward pass through the network
        # Returns ($Z1, $A1, $Z2, $A2) for use in backprop

        # Layer 1: Linear + ReLU
        my $Z1 = $X->matrix_multiply($W1);

        # Add bias (manual broadcasting)
        for my $i (0 .. $hidden_size - 1) {
            $Z1->data->[$i] += $b1->at($i);
        }

        my $A1 = $Z1->relu;  # ReLU activation

        # Layer 2: Linear + Softmax
        my $Z2 = $A1->matrix_multiply($W2);

        # Add bias (manual broadcasting)
        for my $i (0 .. $output_size - 1) {
            $Z2->data->[$i] += $b2->at($i);
        }

        my $A2 = $Z2->softmax;  # Softmax activation

        return ($Z1, $A1, $Z2, $A2);
    }

    method backward ($X, $y_true, $Z1, $A1, $Z2, $A2, $W2_T) {
        # OPTIMIZED: Backpropagation with cached W2 transpose

        # Output layer gradients
        # For softmax + cross-entropy, derivative simplifies to: y_pred - y_true
        my $dZ2 = $A2->sub($y_true);

        # Gradients for W2 and b2
        # dW2 = A1^T * dZ2 (outer product: hidden_size × output_size)
        # Compute directly without temporary Matrix objects
        my $A1_data = $A1->data;
        my $dZ2_data = $dZ2->data;
        my @dW2_data;
        $#dW2_data = $hidden_size * $output_size - 1;

        my $idx = 0;
        for (my $i = 0; $i < $hidden_size; $i++) {
            for (my $j = 0; $j < $output_size; $j++) {
                $dW2_data[$idx++] = $A1_data->[$i] * $dZ2_data->[$j];
            }
        }
        my $dW2 = Matrix->initialize([$hidden_size, $output_size], \@dW2_data);
        my $db2 = $dZ2;  # Sum over batch (but batch=1 for now)

        # Hidden layer gradients
        # dA1 = dZ2 * W2^T (use cached transpose)
        my $dA1 = $dZ2->matrix_multiply($W2_T);

        # ReLU derivative: gradient flows only where Z1 > 0
        # dZ1 = dA1 * (Z1 > 0)
        my $relu_mask = $Z1->gt(0);  # 1 where Z1 > 0, 0 elsewhere
        my $dZ1 = $dA1->mul($relu_mask);

        # Gradients for W1 and b1
        # dW1 = X^T * dZ1 (outer product: input_size × hidden_size)
        # Compute directly without temporary Matrix objects
        my $X_data = $X->data;
        my $dZ1_data = $dZ1->data;
        my @dW1_data;
        $#dW1_data = $input_size * $hidden_size - 1;

        $idx = 0;
        for (my $i = 0; $i < $input_size; $i++) {
            for (my $j = 0; $j < $hidden_size; $j++) {
                $dW1_data[$idx++] = $X_data->[$i] * $dZ1_data->[$j];
            }
        }
        my $dW1 = Matrix->initialize([$input_size, $hidden_size], \@dW1_data);
        my $db1 = $dZ1;  # Sum over batch

        return ($dW1, $db1, $dW2, $db2);
    }

    method update_weights ($dW1, $db1, $dW2, $db2) {
        # OPTIMIZED: In-place gradient descent (no object creation)
        # W -= learning_rate * dW

        my $W1_data = $W1->data;
        my $dW1_data = $dW1->data;
        for (my $i = 0; $i < @$W1_data; $i++) {
            $W1_data->[$i] -= $learning_rate * $dW1_data->[$i];
        }

        my $b1_data = $b1->data;
        my $db1_data = $db1->data;
        for (my $i = 0; $i < @$b1_data; $i++) {
            $b1_data->[$i] -= $learning_rate * $db1_data->[$i];
        }

        my $W2_data = $W2->data;
        my $dW2_data = $dW2->data;
        for (my $i = 0; $i < @$W2_data; $i++) {
            $W2_data->[$i] -= $learning_rate * $dW2_data->[$i];
        }

        my $b2_data = $b2->data;
        my $db2_data = $db2->data;
        for (my $i = 0; $i < @$b2_data; $i++) {
            $b2_data->[$i] -= $learning_rate * $db2_data->[$i];
        }
    }

    method compute_loss ($predictions, $targets) {
        # Cross-entropy loss: -sum(y_true * log(y_pred))
        my $epsilon = 1e-7;  # Prevent log(0)

        # Clip predictions to prevent numerical issues
        my $clipped = $predictions->max($epsilon);
        my $clipped_upper = $clipped->min(1 - $epsilon);

        # Element-wise: targets * log(predictions)
        my $log_pred = $clipped_upper->log;
        my $product = $targets->mul($log_pred);

        # Negative sum
        return -$product->sum;
    }

    method train ($X_train, $y_train, $epochs, $verbose=1) {
        my $num_samples = scalar @$X_train;

        say "\nStarting training for $epochs epochs...";
        say "Training samples: $num_samples";
        say "=" x 60;

        for my $epoch (1 .. $epochs) {
            my $total_loss = 0;
            my $correct = 0;

            # Train on each sample
            for my $i (0 .. $num_samples - 1) {
                my $X = $X_train->[$i];
                my $y_true = $y_train->[$i];

                # Cache W2 transpose (computed once per sample)
                my $W2_T = $W2->transpose;

                # Forward pass
                my ($Z1, $A1, $Z2, $A2) = $self->forward($X);

                # Compute loss
                my $loss = $self->compute_loss($A2, $y_true);
                $total_loss += $loss;

                # Check if prediction is correct
                my $pred_class = $self->predict_class($A2);
                my $true_class = $self->vector_to_class($y_true);
                $correct++ if $pred_class == $true_class;

                # Backward pass (uses cached W2_T)
                my ($dW1, $db1, $dW2, $db2) =
                    $self->backward($X, $y_true, $Z1, $A1, $Z2, $A2, $W2_T);

                # Update weights (in-place, no object creation)
                $self->update_weights($dW1, $db1, $dW2, $db2);

                # Progress indicator
                if ($verbose && ($i + 1) % 1000 == 0) {
                    printf "  Epoch %2d: Processed %5d/%5d samples...\r",
                        $epoch, $i + 1, $num_samples;
                }
            }

            # Compute epoch metrics
            my $avg_loss = $total_loss / $num_samples;
            my $accuracy = $correct / $num_samples;

            push @loss_history, $avg_loss;
            push @accuracy_history, $accuracy;

            # Print progress
            if ($verbose) {
                printf "Epoch %2d: Loss = %.4f, Accuracy = %.2f%% (%d/%d)\n",
                    $epoch, $avg_loss, $accuracy * 100, $correct, $num_samples;
            }
        }

        say "=" x 60;
        say "Training complete!";
    }

    method predict_class ($output_vector) {
        # Find the index of maximum probability
        my $max_idx = 0;
        my $max_val = $output_vector->at(0);
        for my $i (1 .. $output_size - 1) {
            if ($output_vector->at($i) > $max_val) {
                $max_val = $output_vector->at($i);
                $max_idx = $i;
            }
        }
        return $max_idx;
    }

    method vector_to_class ($one_hot_vector) {
        # Convert one-hot encoding to class index
        return $self->predict_class($one_hot_vector);
    }

    method evaluate ($X_test, $y_test, $raw_labels, $show_samples=5) {
        my $num_samples = scalar @$X_test;
        my $correct = 0;

        say "\nEvaluating on $num_samples samples...";

        for my $i (0 .. $num_samples - 1) {
            my ($Z1, $A1, $Z2, $A2) = $self->forward($X_test->[$i]);
            my $pred_class = $self->predict_class($A2);
            my $true_class = $raw_labels->[$i];

            if ($pred_class == $true_class) {
                $correct++;
            }

            # Show first few predictions with images
            if ($i < $show_samples) {
                say "\n" . "-" x 30;
                say "Sample $i:";
                MNIST->display_image($X_test->[$i], $true_class);
                printf "Predicted: %d, Actual: %d %s\n",
                    $pred_class, $true_class,
                    ($pred_class == $true_class ? "✓" : "✗");
            }
        }

        my $accuracy = $correct / $num_samples;
        say "\n" . "=" x 60;
        printf "Final Accuracy: %.2f%% (%d/%d correct)\n",
            $accuracy * 100, $correct, $num_samples;
        say "=" x 60;

        return $accuracy;
    }

    method get_history {
        return (\@loss_history, \@accuracy_history);
    }
}

# =============================================================================
# MNIST Training Example
# =============================================================================

say "=" x 60;
say "MNIST Handwritten Digit Classification";
say "=" x 60;

# Configuration
my $TRAINING_LIMIT = $ARGV[0] // 1000;  # Default to 1000 samples for testing
my $EPOCHS = $ARGV[1] // 10;
my $LEARNING_RATE = 0.01;
my $HIDDEN_SIZE = 128;

say "\nConfiguration:";
say "  Training samples: $TRAINING_LIMIT";
say "  Epochs: $EPOCHS";
say "  Learning rate: $LEARNING_RATE";
say "  Hidden layer size: $HIDDEN_SIZE";

# Check for MNIST data files
my $train_images = 'data/train-images.idx3-ubyte';
my $train_labels = 'data/train-labels.idx1-ubyte';

unless (-f $train_images && -f $train_labels) {
    say "\n" . "!" x 60;
    say "ERROR: MNIST data files not found!";
    say "\nExpected files:";
    say "  $train_images";
    say "  $train_labels";
    say "\nTo download MNIST dataset:";
    say "  mkdir -p data";
    say "  cd data";
    say "  wget http://yann.lecun.com/exdb/mnist/train-images-idx3-ubyte.gz";
    say "  wget http://yann.lecun.com/exdb/mnist/train-labels-idx1-ubyte.gz";
    say "  gunzip *.gz";
    say "!" x 60;
    exit 1;
}

# Load MNIST training data
say "\n" . "=" x 60;
say "Loading MNIST Dataset";
say "=" x 60;

my ($images, $one_hot_labels, $raw_labels) =
    MNIST->load_training_data($train_images, $train_labels, $TRAINING_LIMIT);

# Show dataset statistics
MNIST->dataset_stats($raw_labels);

# Display a few sample images
say "\nSample Training Images:";
for my $i (0 .. 2) {
    MNIST->display_image($images->[$i], $raw_labels->[$i]);
}

# Create neural network
say "\n" . "=" x 60;
say "Creating Neural Network";
say "=" x 60;

my $network = NeuralNetwork->new(
    input_size => 784,      # 28×28 pixels
    hidden_size => $HIDDEN_SIZE,
    output_size => 10,      # 10 digits (0-9)
    learning_rate => $LEARNING_RATE,
);

# Train the network
$network->train($images, $one_hot_labels, $EPOCHS, 1);

# Evaluate on training set
say "\n" . "=" x 60;
say "Final Evaluation";
say "=" x 60;

my $accuracy = $network->evaluate($images, $one_hot_labels, $raw_labels, 5);

# Show learning curves
my ($loss_history, $accuracy_history) = $network->get_history;

say "\n" . "=" x 60;
say "Learning Curves";
say "=" x 60;

say "\nEpoch    Loss      Accuracy";
say "-" x 35;
for my $i (0 .. $EPOCHS - 1) {
    printf "%5d  %.6f   %.2f%%\n",
        $i + 1,
        $loss_history->[$i],
        $accuracy_history->[$i] * 100;
}

# Success message
say "\n" . "=" x 60;
if ($accuracy >= 0.90) {
    say "SUCCESS! Network achieved >90% accuracy on MNIST!";
} elsif ($accuracy >= 0.80) {
    say "GOOD! Network learned well. Try more epochs for better accuracy.";
} elsif ($accuracy >= 0.60) {
    say "MODERATE. Network is learning. Try more epochs or larger hidden layer.";
} else {
    say "Network needs more training. Try more epochs or adjust hyperparameters.";
}
say "=" x 60;

say "\nTo train on more data:";
say "  perl examples/mnist_training.pl 10000 20  # 10k samples, 20 epochs";
say "\nTo train on full dataset (60,000 samples):";
say "  perl examples/mnist_training.pl 60000 10  # Will take ~30-60 minutes";

__END__

=encoding UTF-8

=head1 NAME

mnist_training.pl - MNIST Handwritten Digit Classification with Neural Network

=head1 SYNOPSIS

    # Quick test (1000 samples, 10 epochs)
    perl examples/mnist_training.pl

    # Train on more data
    perl examples/mnist_training.pl 5000 15

    # Full training (60,000 samples, 10 epochs)
    perl examples/mnist_training.pl 60000 10

=head1 DESCRIPTION

This script trains a neural network to recognize handwritten digits from
the MNIST dataset. It demonstrates a complete machine learning pipeline:

1. Load and parse MNIST IDX binary format
2. Normalize pixel values (0-255 -> 0.0-1.0)
3. Convert labels to one-hot encoding
4. Train neural network with backpropagation
5. Evaluate accuracy on training set

=head1 ARCHITECTURE

  Input Layer:    784 neurons (28×28 pixels)
                     v W1 (784x128) + b1
  Hidden Layer:   128 neurons + ReLU
                     v W2 (128x10) + b2
  Output Layer:   10 neurons + Softmax (digits 0-9)

  Total Parameters: 101,770
  - W1: 784 × 128 = 100,352
  - b1: 128
  - W2: 128 × 10 = 1,280
  - b2: 10

=head1 HYPERPARAMETERS

- Learning Rate: 0.01 (lower than XOR due to larger network)
- Optimizer: Vanilla SGD (online learning, batch size = 1)
- Weight Init: Xavier/Glorot (scaled by sqrt(2/fan_in))
- Loss Function: Cross-entropy with numerical stability

=head1 EXPECTED RESULTS

With 1,000 samples (10 epochs):
- Accuracy: 85-92%
- Training time: ~1-2 minutes

With 10,000 samples (10 epochs):
- Accuracy: 92-95%
- Training time: ~10-20 minutes

With 60,000 samples (10 epochs):
- Accuracy: 95-98%
- Training time: ~60-120 minutes (pure Perl)

=head1 DOWNLOAD MNIST DATA

    mkdir -p data
    cd data

    # Training set (60,000 samples)
    wget http://yann.lecun.com/exdb/mnist/train-images-idx3-ubyte.gz
    wget http://yann.lecun.com/exdb/mnist/train-labels-idx1-ubyte.gz

    # Test set (10,000 samples)
    wget http://yann.lecun.com/exdb/mnist/t10k-images-idx3-ubyte.gz
    wget http://yann.lecun.com/exdb/mnist/t10k-labels-idx1-ubyte.gz

    # Decompress
    gunzip *.gz

=head1 USAGE

Run with defaults (1000 samples, 10 epochs):

    perl examples/mnist_training.pl

Run with custom parameters:

    perl examples/mnist_training.pl <num_samples> <num_epochs>

Examples:

    perl examples/mnist_training.pl 5000 15
    perl examples/mnist_training.pl 60000 10

=head1 FEATURES

- Complete backpropagation implementation
- Cross-entropy loss with numerical stability
- Xavier weight initialization
- ReLU and Softmax activations
- Training progress reporting
- ASCII art image visualization
- Learning curves tracking
- Comprehensive evaluation

=head1 IMPROVEMENTS

Potential enhancements:

1. Mini-batch training (currently batch=1)
2. Momentum or Adam optimizer
3. Dropout for regularization
4. Data augmentation
5. Separate test set evaluation
6. Model checkpointing
7. Early stopping

=head1 SEE ALSO

- examples/xor_training.pl - Simpler training example
- examples/mnist_network.pl - Inference-only example
- lib/MNIST.pm - Data loader implementation

=cut
