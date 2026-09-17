#!/usr/bin/env perl
use v5.40;
use experimental qw[ class ];

use lib 'lib';
use Matrix;
use Vector;
use Time::HiRes qw(time);

# Focused Matrix Multiplication Benchmark

sub benchmark ($name, $iterations, $code) {
    print "$name... ";
    STDOUT->flush();

    my $start = time();
    for (1 .. $iterations) {
        $code->();
    }
    my $elapsed = time() - $start;
    my $per_iter = $elapsed / $iterations * 1000;

    printf "%.3fs (%.2f ms/op, %.1f ops/sec)\n",
        $elapsed, $per_iter, $iterations / $elapsed;

    return $elapsed;
}

say "=" x 70;
say "Matrix Multiplication Performance Benchmark";
say "=" x 70;

# Small matrices (quick test)
say "\n[1] Small: 10×10 matrix × 10 vector (100 multiplications)";
my $m_small = Matrix->randn([10, 10]);
my $v_small = Vector->randn([10]);
benchmark("  Current implementation", 100, sub {
    my $result = $v_small->matrix_multiply($m_small);
});

# Medium matrices
say "\n[2] Medium: 100×50 matrix × 100 vector (5000 multiplications)";
my $m_med = Matrix->randn([100, 50]);
my $v_med = Vector->randn([100]);
benchmark("  Current implementation", 10, sub {
    my $result = $v_med->matrix_multiply($m_med);
});

# MNIST-sized (the real test)
say "\n[3] MNIST Hidden Layer: 784×128 matrix × 784 vector (100,352 multiplications)";
my $m_mnist = Matrix->randn([784, 128]);
my $v_mnist = Vector->randn([784]);
benchmark("  Current implementation", 10, sub {
    my $result = $v_mnist->matrix_multiply($m_mnist);
});

say "\n[4] MNIST Output Layer: 128×10 matrix × 128 vector (1,280 multiplications)";
my $m_out = Matrix->randn([128, 10]);
my $v_out = Vector->randn([128]);
benchmark("  Current implementation", 100, sub {
    my $result = $v_out->matrix_multiply($m_out);
});

# Matrix transpose (used in backprop)
say "\n[5] Matrix Transpose: 784×128 matrix";
benchmark("  Current implementation", 100, sub {
    my $result = $m_mnist->transpose;
});

say "\n[6] Matrix Transpose: 128×10 matrix";
benchmark("  Current implementation", 1000, sub {
    my $result = $m_out->transpose;
});

# Matrix-matrix multiplication (gradients)
say "\n[7] Small Matrix×Matrix: 1×128 × 128×10 = 1×10";
my $grad_h = Matrix->randn([1, 128]);
benchmark("  Current implementation", 100, sub {
    my $result = $grad_h->matrix_multiply($m_out);
});

say "\n[8] Large Matrix×Matrix: 1×784 × 784×128 = 1×128";
my $grad_in = Matrix->randn([1, 784]);
benchmark("  Current implementation", 10, sub {
    my $result = $grad_in->matrix_multiply($m_mnist);
});

say "\n" . "=" x 70;
say "Benchmark Complete";
say "=" x 70;

__END__

=head1 NAME

matrix_bench.pl - Focused Matrix Operation Benchmark

=head1 DESCRIPTION

Micro-benchmark focusing on matrix operations to identify optimization
opportunities. Tests various sizes from small to MNIST-scale.

=cut
