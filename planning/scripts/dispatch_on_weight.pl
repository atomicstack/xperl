#!./perl
use Benchmark qw(timethese);

my $sink = 0;

sub make_dispatch {
    my ($mode, $n) = @_;
    my $clauses = join '', map {
        my $value = 2 * ($_ + 1);
        "on ($value) { \$sink++ }\n"
    } 0 .. $n - 1;
    local $ENV{PERL_CONST_DISPATCH_STRATEGY} = $mode;
    my $sub = eval qq{
        use feature 'dispatch_on';
        sub { my (\$x) = \@_; dispatch (\$x) { $clauses } }
    };
    die "$@\n" unless $sub;
    return $sub;
}

sub rate {
    my ($result, $name) = @_;
    return $result->{$name}->[5]
        / ($result->{$name}->[1] + $result->{$name}->[2]);
}

printf "%-5s %-16s %-16s %16s %16s\n",
    'clauses', 'probes', 'implementation', 'probe_sets/sec', 'lookups/sec';
printf "%s\n", '-' x 75;

for my $n (2, 4, 8, 16, 32, 64, 128, 256) {
    my $min = 2;
    my $max = 2 * $n;
    my $miss = $max + 1;

    my $clauses = join '', map {
        "elsif (\$x == $_) { \$sink++ }\n"
    } 2 .. $n - 1;
    my $if = eval qq{
        sub { my (\$x) = \@_; if (\$x == 2) { \$sink++ } $clauses }
    };
    die "$@\n" unless $if;

    for my $probe_set (
        ["hits-2..$max", [map { 2 * $_ } 1 .. $n]],
        ["range-" . ($min - 1) . "..$miss", [$min - 1 .. $max + 1]],
    ) {
        my ($label, $probes) = @$probe_set;
        my %sub = (if_else => $if);
        for my $mode (qw(none array-linear array-binary hv)) {
            $sub{"dispatch_$mode"} = make_dispatch($mode, $n);
        }
        my %bench = map {
            my $runner = $sub{$_};
            my $values = $probes;
            ($_ => sub { $runner->($_) for @$values })
        } keys %sub;
        my $result = timethese(-1, \%bench, 'none');
        for my $name (qw(if_else case_none case_array-linear
                         case_array-binary case_hv)) {
            my $sets = rate(\%$result, $name);
            printf "%-5d %-16s %-16s %16.1f %16.1f\n",
                $n, $label, $name, $sets, $sets * @$probes;
        }
    }
}
print "sink=$sink\n";
