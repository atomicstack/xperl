#!./perl
use Benchmark qw(timethese);

my $sink = 0;
sub rate {
    my ($b) = @_;
    return $b->[5] / ($b->[1] + $b->[2]);
}
sub dispatch_sub {
    my ($mode, $n, $default) = @_;
    my $clauses = join '', map { "on ($_ ) { \$sink++ }\n" } 0 .. $n - 1;
    $clauses .= "on (_) { () }\n" if $default;
    local $ENV{PERL_CONST_DISPATCH_STRATEGY} = $mode;
    my $sub = eval qq{
        use feature 'dispatch_on';
        sub { my (\$x) = \@_; for (1 .. 100) { dispatch (\$x) { $clauses } } }
    };
    die "$@\n" unless $sub;
    return $sub;
}
sub if_sub {
    my ($n) = @_;
    my $chain = join '', map {
        $_ ? "elsif (\$x == $_) { \$sink++ }\n"
           : "if (\$x == $_) { \$sink++ }\n"
    } 0 .. $n - 1;
    my $sub = eval qq{
        sub { my (\$x) = \@_; for (1 .. 100) { $chain else { \$sink++ } } }
    };
    die "$@\n" unless $sub;
    return $sub;
}

printf "%-12s %10s %12s %13s %13s %10s %18s\n",
    'clauses/probe', 'if/else', 'dispatch-none', 'dispatch-linear',
    'dispatch-binary', 'dispatch-hv', 'hv+empty-default';
for my $n (4, 32, 256) {
    my $if = if_sub($n);
    my %sub = (if_else => $if);
    for my $mode (qw(none array-linear array-binary hv)) {
        $sub{"dispatch_$mode"} = dispatch_sub($mode, $n, 0);
    }
    $sub{case_hv_empty_default} = case_sub('hv', $n, 1);
    for my $where (qw(hit-first hit-middle hit-last miss)) {
        my $probe = $where eq 'hit-first'  ? 0
                  : $where eq 'hit-middle' ? int($n / 2)
                  : $where eq 'hit-last'   ? $n - 1
                  : $n + 1;
        my %bench = map {
            my $runner = $sub{$_};
            ($_ => sub { $runner->($probe) })
        } keys %sub;
        my $result = timethese(-1, \%bench, 'none');
        printf "%-12s %10.1f %12.1f %13.1f %13.1f %10.1f %18.1f\n",
            "$n/$where", map { rate($result->{$_}) }
            qw(if_else case_none case_array-linear case_array-binary
               case_hv case_hv_empty_default);
    }
}
print "sink=$sink\n";
