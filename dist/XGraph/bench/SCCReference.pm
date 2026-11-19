package SCCReference;

use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(parameters edge_specs build_graph labels grouped_components);

sub parameters {
    my $vertices = $ENV{XGRAPH_BENCH_VERTICES} // 2000;
    my $edges = $ENV{XGRAPH_BENCH_EDGES} // 10000;
    my $iterations = $ENV{XGRAPH_BENCH_ITERATIONS} // 5;
    die "XGRAPH_BENCH_VERTICES must be an integer of at least 2\n"
        unless $vertices =~ /\A\d+\z/ && $vertices >= 2;
    die "XGRAPH_BENCH_EDGES is out of range\n"
        unless $edges =~ /\A\d+\z/ && $edges <= $vertices * ($vertices - 1) / 2;
    die "XGRAPH_BENCH_ITERATIONS must be positive\n"
        unless $iterations =~ /\A\d+\z/ && $iterations > 0;
    return ($vertices, $edges, $iterations);
}

# Match the archived comparison's graph input, including the fifty-vertex
# cycles. The Perl reference measures Kosaraju's algorithm, not SciPy.
sub edge_specs {
    my ($vertices, $wanted) = @_;
    my (@edges, %seen);
    for my $source (1 .. $vertices - 1) {
        last if @edges == $wanted;
        push @edges, [$source, $source + 1];
        $seen{"$source,".($source + 1)} = 1;
    }
    my $state = 0x13579bdf;
    my $attempts = 0;
    while (@edges < $wanted) {
        $state = (1664525 * $state + 1013904223) & 0xffffffff;
        my $source = 1 + $state % ($vertices - 1);
        $state = (1664525 * $state + 1013904223) & 0xffffffff;
        my $target = $source + 1 + $state % ($vertices - $source);
        if (!$seen{"$source,$target"}++) {
            push @edges, [$source, $target];
        }
        # Rejection sampling can exhaust the generator's reachable pairs on
        # tiny dense inputs. Complete those deterministically rather than hang.
        if (++$attempts > 100 * ($wanted + $vertices)) {
            OUTER: for my $from (1 .. $vertices - 1) {
                for my $to ($from + 1 .. $vertices) {
                    last OUTER if @edges == $wanted;
                    push @edges, [$from, $to] unless $seen{"$from,$to"}++;
                }
            }
            last;
        }
    }
    for (my $start = 1; $start <= $vertices; $start += 50) {
        my $end = $start + 49 < $vertices ? $start + 49 : $vertices;
        for my $source ($start .. $end - 1) {
            my $from = $source + 1;
            push @edges, [$from, $source] unless $seen{"$from,$source"}++;
        }
        push @edges, [$end, $start] if $end != $start && !$seen{"$end,$start"}++;
    }
    return \@edges;
}

sub build_graph {
    my ($vertices, $edges) = @_;
    my @forward = map { [] } 1 .. $vertices;
    my @reverse = map { [] } 1 .. $vertices;
    for my $edge (@$edges) {
        my ($from, $to) = map { $_ - 1 } @$edge;
        push @{$forward[$from]}, $to;
        push @{$reverse[$to]}, $from;
    }
    return [\@forward, \@reverse];
}

# Iterative DFS avoids depending on the interpreter's recursion depth for
# the long chain in the benchmark input.
sub labels {
    my ($graph) = @_;
    my ($forward, $reverse) = @$graph;
    my (@seen, @order);
    for my $root (0 .. $#$forward) {
        next if $seen[$root];
        $seen[$root] = 1;
        my @stack = ([$root, 0]);
        while (@stack) {
            my ($vertex, $next) = @{$stack[-1]};
            if ($next < @{$forward->[$vertex]}) {
                ++$stack[-1][1];
                my $child = $forward->[$vertex][$next];
                next if $seen[$child];
                $seen[$child] = 1;
                push @stack, [$child, 0];
            }
            else {
                push @order, $vertex;
                pop @stack;
            }
        }
    }
    my (@labels, $count);
    $count = 0;
    for my $root (reverse @order) {
        next if defined $labels[$root];
        $labels[$root] = $count;
        my @stack = ($root);
        while (@stack) {
            my $vertex = pop @stack;
            for my $child (@{$reverse->[$vertex]}) {
                next if defined $labels[$child];
                $labels[$child] = $count;
                push @stack, $child;
            }
        }
        ++$count;
    }
    return ($count, \@labels);
}

sub grouped_components {
    my ($count, $labels) = @_;
    my @components = map { [] } 1 .. $count;
    push @{$components[$labels->[$_]]}, $_ + 1 for 0 .. $#$labels;
    return [sort { $a->[0] <=> $b->[0] } @components];
}

1;
