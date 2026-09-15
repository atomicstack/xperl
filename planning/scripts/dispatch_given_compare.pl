#!./perl
use Benchmark qw(timethese);

my $sink = 0;

sub rate {
    my ($b) = @_;
    my $elapsed = $b->[1] + $b->[2];
    return 0 unless $elapsed;
    return $b->[5] / $elapsed;
}

sub if_sub {
    my ($n) = @_;
    my $chain = join '', map {
        my $value = 2 * ($_ + 1);
        $_ ? "elsif (\$x == $value) { \$sink++ }\n"
           : "if (\$x == $value) { \$sink++ }\n"
    } 0 .. $n - 1;
    my $sub = eval qq{
        sub { my (\$x) = \@_; for (1 .. 100) { $chain else { \$sink++ } } }
    };
    die "$@\n" unless $sub;
    return $sub;
}

sub given_sub {
    my ($n) = @_;
    my $clauses = join '', map {
        my $value = 2 * ($_ + 1);
        "when ($value) { \$sink++ }\n"
    } 0 .. $n - 1;
    my $sub = eval qq{
        use feature 'switch';
        no warnings 'experimental::smartmatch';
        sub { my (\$x) = \@_; for (1 .. 100) { given (\$x) { $clauses default { \$sink++ } } } }
    };
    die "$@\n" unless $sub;
    return $sub;
}

sub case_sub {
    my ($mode, $n) = @_;
    my $clauses = join '', map {
        my $value = 2 * ($_ + 1);
        "on ($value) { \$sink++ }\n"
    } 0 .. $n - 1;
    local $ENV{PERL_CONST_DISPATCH_STRATEGY} = $mode;
    my $sub = eval qq{
        use feature 'dispatch_on';
        sub { my (\$x) = \@_; for (1 .. 100) { dispatch (\$x) { $clauses on (_) { \$sink++ } } } }
    };
    die "$@\n" unless $sub;
    return $sub;
}

printf "%-16s %10s %12s %13s %13s %10s\n",
    'clauses/probes', 'if/else', 'given/when', 'case-none',
    'case-binary', 'case-hv';
my %duration_for = (
    256  => -2,
    512  => -4,
    1024 => -16,
    2048 => -32,
);
for my $n (2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048) {
    my %sub = (
        if_else   => if_sub($n),
        given_when => given_sub($n),
        case_none => case_sub('none', $n),
        case_array_binary => case_sub('array-binary', $n),
        case_hv => case_sub('hv', $n),
    );
    my $max = 2 * $n;
    my @probe_sets = (
        ["hits-2..$max", [map { 2 * $_ } 1 .. $n]],
        ["range-1.." . ($max + 1), [1 .. $max + 1]],
    );
    for my $probe_set (@probe_sets) {
        my ($label, $probes) = @$probe_set;
        my %bench = map {
            my $runner = $sub{$_};
            ($_ => sub { $runner->($_) for @$probes })
        } keys %sub;
        my $duration = $duration_for{$n} // -1;
        my $result = timethese($duration, \%bench, 'none');
        printf "%-16s %10.1f %12.1f %13.1f %13.1f %10.1f\n",
            "$n/$label", map { rate($result->{$_}) * @$probes }
            qw(if_else given_when case_none case_array_binary case_hv);
    }
}
print "sink=$sink\n";
