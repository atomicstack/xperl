#!/usr/bin/env perl
use v5.40;
use experimental qw[ class ];

use lib 'lib';
use Matrix;
use Vector;

# XOR Neural Network with Backpropagation Training
# This is a classic test case - XOR is not linearly separable,
# so it requires a hidden layer to learn.

class NeuralNetwork {
    # Network parameters
    field $W1 :reader;  # Weights layer 1
    field $b1 :reader;  # Bias layer 1
    field $W2 :reader;  # Weights layer 2
    field $b2 :reader;  # Bias layer 2

    # Hyperparameters
    field $learning_rate :param = 0.1;
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

    method backward ($X, $y_true, $Z1, $A1, $Z2, $A2) {
        # Backpropagation to compute gradients

        # Output layer gradients
        # For softmax + cross-entropy, derivative simplifies to: y_pred - y_true
        my $dZ2 = $A2->sub($y_true);

        # Gradients for W2 and b2
        # dW2 = A1^T * dZ2
        my $A1_as_matrix = Matrix->initialize([1, $hidden_size], [$A1->to_list]);
        my $dZ2_as_matrix = Matrix->initialize([1, $output_size], [$dZ2->to_list]);
        my $dW2 = $A1_as_matrix->transpose->matrix_multiply($dZ2_as_matrix);
        my $db2 = $dZ2;  # Sum over batch (but batch=1 for now)

        # Hidden layer gradients
        # dA1 = dZ2 * W2^T
        my $dA1 = $dZ2->matrix_multiply($W2->transpose);

        # ReLU derivative: gradient flows only where Z1 > 0
        # dZ1 = dA1 * (Z1 > 0)
        my $relu_mask = $Z1->gt(0);  # 1 where Z1 > 0, 0 elsewhere
        my $dZ1 = $dA1->mul($relu_mask);

        # Gradients for W1 and b1
        # dW1 = X^T * dZ1
        my $X_as_matrix = Matrix->initialize([1, $input_size], [$X->to_list]);
        my $dZ1_as_matrix = Matrix->initialize([1, $hidden_size], [$dZ1->to_list]);
        my $dW1 = $X_as_matrix->transpose->matrix_multiply($dZ1_as_matrix);
        my $db1 = $dZ1;  # Sum over batch

        return ($dW1, $db1, $dW2, $db2);
    }

    method update_weights ($dW1, $db1, $dW2, $db2) {
        # Gradient descent weight update
        # W = W - learning_rate * dW

        # Update W1
        my $W1_update = $dW1->mul($learning_rate);
        $W1 = $W1->sub($W1_update);

        # Update b1
        my $b1_update = $db1->mul($learning_rate);
        $b1 = $b1->sub($b1_update);

        # Update W2
        my $W2_update = $dW2->mul($learning_rate);
        $W2 = $W2->sub($W2_update);

        # Update b2
        my $b2_update = $db2->mul($learning_rate);
        $b2 = $b2->sub($b2_update);
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
        say "=" x 60;

        for my $epoch (1 .. $epochs) {
            my $total_loss = 0;
            my $correct = 0;

            # Train on each sample
            for my $i (0 .. $num_samples - 1) {
                my $X = $X_train->[$i];
                my $y_true = $y_train->[$i];

                # Forward pass
                my ($Z1, $A1, $Z2, $A2) = $self->forward($X);

                # Compute loss
                my $loss = $self->compute_loss($A2, $y_true);
                $total_loss += $loss;

                # Check if prediction is correct
                my $pred_class = $self->predict_class($A2);
                my $true_class = $self->vector_to_class($y_true);
                $correct++ if $pred_class == $true_class;

                # Backward pass
                my ($dW1, $db1, $dW2, $db2) =
                    $self->backward($X, $y_true, $Z1, $A1, $Z2, $A2);

                # Update weights
                $self->update_weights($dW1, $db1, $dW2, $db2);
            }

            # Compute epoch metrics
            my $avg_loss = $total_loss / $num_samples;
            my $accuracy = $correct / $num_samples;

            push @loss_history, $avg_loss;
            push @accuracy_history, $accuracy;

            # Print progress
            if ($verbose && ($epoch % 100 == 0 || $epoch == 1 || $epoch == $epochs)) {
                printf "Epoch %4d: Loss = %.4f, Accuracy = %.2f%%\n",
                    $epoch, $avg_loss, $accuracy * 100;
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

    method evaluate ($X_test, $y_test) {
        my $num_samples = scalar @$X_test;
        my $correct = 0;

        say "\nEvaluating on $num_samples samples...";

        for my $i (0 .. $num_samples - 1) {
            my ($Z1, $A1, $Z2, $A2) = $self->forward($X_test->[$i]);
            my $pred_class = $self->predict_class($A2);
            my $true_class = $self->vector_to_class($y_test->[$i]);

            if ($pred_class == $true_class) {
                $correct++;
            }

            # Print individual predictions
            printf "  Sample %d: Predicted=%d, Actual=%d %s\n",
                $i, $pred_class, $true_class,
                ($pred_class == $true_class ? "✓" : "✗");
        }

        my $accuracy = $correct / $num_samples;
        printf "\nFinal Accuracy: %.2f%% (%d/%d correct)\n",
            $accuracy * 100, $correct, $num_samples;

        return $accuracy;
    }

    method get_history {
        return (\@loss_history, \@accuracy_history);
    }
}

# =============================================================================
# XOR Training Example
# =============================================================================

say "=" x 60;
say "XOR Neural Network Training";
say "=" x 60;

say "\nXOR Problem:";
say "  0 XOR 0 = 0";
say "  0 XOR 1 = 1";
say "  1 XOR 0 = 1";
say "  1 XOR 1 = 0";
say "\nThis is a non-linearly separable problem that requires a hidden layer.";

# XOR training data (2 inputs, 2 outputs with one-hot encoding)
my @X_train = (
    Vector->initialize(2, [0, 0]),
    Vector->initialize(2, [0, 1]),
    Vector->initialize(2, [1, 0]),
    Vector->initialize(2, [1, 1]),
);

# One-hot encoded labels: [1,0] for 0, [0,1] for 1
my @y_train = (
    Vector->initialize(2, [1, 0]),  # 0 XOR 0 = 0
    Vector->initialize(2, [0, 1]),  # 0 XOR 1 = 1
    Vector->initialize(2, [0, 1]),  # 1 XOR 0 = 1
    Vector->initialize(2, [1, 0]),  # 1 XOR 1 = 0
);

# Create network: 2 inputs → 4 hidden → 2 outputs
my $network = NeuralNetwork->new(
    input_size => 2,
    hidden_size => 4,
    output_size => 2,
    learning_rate => 0.5,
);

# Train the network
$network->train(\@X_train, \@y_train, 2000, 1);

# Evaluate on training set (should be 100% accurate)
say "\n" . "=" x 60;
say "Evaluation";
say "=" x 60;

my $accuracy = $network->evaluate(\@X_train, \@y_train);

# Show learning curves
my ($loss_history, $accuracy_history) = $network->get_history;

say "\n" . "=" x 60;
say "Learning Curves (Sample)";
say "=" x 60;

say "\nEpoch    Loss    Accuracy";
say "-" x 30;
for my $i (0, 99, 199, 499, 999, 1499, 1999) {
    if ($i < scalar @$loss_history) {
        printf "%5d  %.4f   %.2f%%\n",
            $i + 1,
            $loss_history->[$i],
            $accuracy_history->[$i] * 100;
    }
}

if ($accuracy >= 1.0) {
    say "\n" . "🎉 SUCCESS! Network learned XOR perfectly!";
} elsif ($accuracy >= 0.75) {
    say "\n" . "✓ Network learned XOR (may need more epochs for 100%)";
} else {
    say "\n" . "⚠ Network struggled - try different hyperparameters";
}

__END__

=encoding UTF-8

=head1 NAME

xor_training.pl - XOR Neural Network Training with Backpropagation

=head1 DESCRIPTION

This script demonstrates complete neural network training with backpropagation
on the classic XOR problem. XOR is the "Hello World" of neural networks because
it's not linearly separable and requires a hidden layer.

=head1 FEATURES

- Complete backpropagation implementation
- Cross-entropy loss function
- Gradient descent optimization
- Xavier weight initialization
- Training loop with loss/accuracy tracking
- Evaluation metrics

=head1 ARCHITECTURE

  Input Layer:    2 neurons (x1, x2)
                     v
  Hidden Layer:   4 neurons + ReLU
                     v
  Output Layer:   2 neurons + Softmax (one-hot: 0 or 1)

=head1 EXPECTED RESULTS

The network should achieve 100% accuracy on XOR within 1000-2000 epochs.

Loss should decrease from ~0.7 to ~0.01
Accuracy should increase from ~25% to 100%

=head1 USAGE

    perl examples/xor_training.pl

=head1 NEXT STEPS

After XOR works:
1. Try other simple problems (AND, OR, NAND)
2. Implement mini-batch training
3. Add momentum or Adam optimizer
4. Scale to MNIST dataset

=cut
