# Neural Network Examples

This directory contains examples demonstrating how to use the Matrix/Vector/Tensor library for machine learning tasks.

## MNIST Neural Network (`mnist_network.pl`)

A complete 2-layer neural network implementation for MNIST digit classification (28x28 grayscale images → 10 digit classes).

### Architecture

```
Input Layer:    784 neurons (28×28 flattened image)
                    ↓
Hidden Layer:   128 neurons + ReLU activation
                    ↓
Output Layer:   10 neurons + Softmax activation
```

### Features Demonstrated

1. **Xavier Weight Initialization** - Proper initialization for deep learning
2. **Forward Propagation** - Complete forward pass through the network
3. **Activation Functions** - ReLU (hidden) and Softmax (output)
4. **Matrix Operations** - Efficient matrix-vector multiplication
5. **Predictions** - Classify inputs and output confidence scores

### Running the Example

```bash
perl examples/mnist_network.pl
```

### Key Operations Used

- `Matrix->randn()` - Normal distribution weight initialization
- `Vector->matrix_multiply()` - Linear transformations
- `->relu()` - ReLU activation function
- `->softmax()` - Softmax for probability distribution
- `->transpose()` - Matrix transposition (for backprop)
- `->mean()` - Compute averages for metrics

### Next Steps for Full Training

The example demonstrates the network architecture and forward pass. To build a complete MNIST classifier, you would need to:

1. **Load MNIST Dataset**
   - Download from http://yann.lecun.com/exdb/mnist/
   - Parse binary files into Matrix/Vector format
   - Normalize pixel values (0-255 → 0-1)

2. **Implement Backpropagation**
   ```perl
   method backward ($X, $y_true, $A1, $A2) {
       # Compute gradients for W2, b2
       my $dZ2 = $A2->sub($y_true);  # Softmax + Cross-entropy gradient
       my $dW2 = $A1->transpose->matrix_multiply($dZ2);
       my $db2 = $dZ2;

       # Compute gradients for W1, b1
       my $dA1 = $dZ2->matrix_multiply($W2->transpose);
       my $dZ1 = $dA1 * ($A1 > 0);  # ReLU derivative
       my $dW1 = $X->transpose->matrix_multiply($dZ1);
       my $db1 = $dZ1;

       return ($dW1, $db1, $dW2, $db2);
   }
   ```

3. **Training Loop**
   ```perl
   for my $epoch (1 .. $num_epochs) {
       for my $batch (@training_batches) {
           my ($X, $y) = $batch->@*;

           # Forward pass
           my ($A1, $A2) = $network->forward($X);

           # Compute loss
           my $loss = cross_entropy_loss($A2, $y);

           # Backward pass
           my ($dW1, $db1, $dW2, $db2) = $network->backward($X, $y, $A1, $A2);

           # Update weights
           $W1 = $W1->sub($dW1->mul($learning_rate));
           $b1 = $b1->sub($db1->mul($learning_rate));
           $W2 = $W2->sub($dW2->mul($learning_rate));
           $b2 = $b2->sub($db2->mul($learning_rate));
       }
   }
   ```

4. **Evaluation**
   ```perl
   my $correct = 0;
   my $total = 0;
   for my ($X, $y_true) (@test_data) {
       my ($pred, $conf) = $network->predict($X);
       $correct++ if $pred == $y_true;
       $total++;
   }
   my $accuracy = $correct / $total;
   ```

## Available Operations for Neural Networks

### Matrix Operations
- `transpose()` - Essential for backpropagation
- `matrix_multiply()` - Linear layer computations
- `->add()`, `->sub()`, `->mul()`, `->div()` - Element-wise operations

### Activation Functions
- `relu()` - ReLU: max(0, x)
- `sigmoid()` - Sigmoid: 1/(1+exp(-x))
- `tanh()` - Hyperbolic tangent
- `softmax()` - Probability distribution for classification

### Initialization
- `random([shape], min, max)` - Uniform random distribution
- `randn([shape], mean, stddev)` - Normal/Gaussian distribution
- `zeros([shape])` - Initialize with zeros
- `ones([shape])` - Initialize with ones

### Reductions
- `sum()` - Sum all elements
- `mean()` - Average of all elements
- `min_value()`, `max_value()` - Find extrema

### Mathematical Functions
- `exp()`, `log()`, `sqrt()` - Element-wise math
- `abs()`, `neg()` - Absolute value and negation
- `pow()` - Element-wise exponentiation

### Numerical Operations
- `clamp(min, max)` - Clip values to range
- `min(other)`, `max(other)` - Element-wise min/max

## Performance Notes

This is a pure Perl implementation optimized for clarity and correctness. For production use with large datasets:

- Consider using PDL (Perl Data Language) for faster computations
- Implement mini-batch processing to leverage vectorization
- Use L-BFGS or Adam optimizers instead of plain SGD
- Add regularization (L1/L2) to prevent overfitting
- Implement early stopping and learning rate scheduling

## References

- MNIST Dataset: http://yann.lecun.com/exdb/mnist/
- Neural Networks and Deep Learning: http://neuralnetworksanddeeplearning.com/
- CS231n Stanford Course: http://cs231n.stanford.edu/
