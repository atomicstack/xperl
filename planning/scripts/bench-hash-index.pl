#!/usr/bin/perl
use strict;
use warnings;
use Hash::Util qw(hash_storage_info);
use XS::APItest ();
use JSON::PP qw(encode_json);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC CLOCK_PROCESS_CPUTIME_ID);

my ($n, $requested, $mode) = @ARGV;
die "usage: $0 SIZE OPERATIONS MODE\n" unless $n && $requested && defined $mode;
my @keys = map { sprintf 'k%08d', $_ } 0 .. $n - 1;
my $value = 'v' x 32;
my %hash;
$hash{$_} = $value for @keys;
my $initial = hash_storage_info(\%hash);
my @queries = @keys;
srand(0x2468ace0);
if ($mode ne 'fetch-sequential') {
    for (my $i = $#queries; $i > 0; $i--) {
        my $j = int rand($i + 1);
        @queries[$i, $j] = @queries[$j, $i];
    }
}
@queries = map { XS::APItest::Hash::shared_query_key($_) } @queries
    if $mode eq 'fetch-shared';
@queries = map { 'm' . substr($_, 1) } @queries if $mode eq 'miss';

my $checksum = 0;
my ($run, $unit);
if ($mode =~ /^fetch-/) {
    $unit = 32;
    $run = sub {
        for (1 .. $_[0]) { $checksum += length($hash{$_} // '') for @queries }
    };
}
elsif ($mode eq 'miss') {
    $unit = 1;
    $run = sub {
        for (1 .. $_[0]) { $checksum += defined($hash{$_}) ? 0 : 1 for @queries }
    };
}
elsif ($mode eq 'exists') {
    $unit = 1;
    $run = sub {
        for (1 .. $_[0]) { $checksum += exists($hash{$_}) ? 1 : 0 for @queries }
    };
}
elsif ($mode eq 'iterate') {
    $unit = 32;
    $run = sub {
        for (1 .. $_[0]) {
            while (my ($key, $val) = each %hash) { $checksum += length $val }
        }
    };
}
elsif ($mode eq 'construct') {
    %hash = ();
    $unit = 1;
    $run = sub {
        for (1 .. $_[0]) {
            my %fresh;
            $fresh{$_} = $value for @keys;
            $checksum += scalar keys %fresh;
        }
    };
}
elsif ($mode eq 'churn') {
    $unit = 32;
    $run = sub {
        for (1 .. $_[0]) {
            for (@queries) {
                $checksum += length(delete($hash{$_}) // '');
                $hash{$_} = $value;
            }
        }
    };
}
elsif ($mode eq 'query-only') {
    $unit = 9;
    $run = sub {
        for (1 .. $_[0]) { $checksum += length($_) for @queries }
    };
}
else { die "unknown mode $mode\n" }

my $warmup = int(100000 / $n) || 1;
$run->($warmup);
die "warmup checksum mismatch\n" unless $checksum == $warmup * $n * $unit;
my $before = hash_storage_info(\%hash);
$checksum = 0;
my $batches = int($requested / $n) || 1;
my $operations = $batches * $n;
my $cpu = clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
my $start = clock_gettime(CLOCK_MONOTONIC);
$run->($batches);
my $seconds = clock_gettime(CLOCK_MONOTONIC) - $start;
my $cpu_seconds = clock_gettime(CLOCK_PROCESS_CPUTIME_ID) - $cpu;
die "checksum mismatch\n" unless $checksum == $operations * $unit;
die "hash contents changed\n" unless keys(%hash) == ($mode eq 'construct' ? 0 : $n);
print encode_json({
    n => 0 + $n, mode => $mode, operations => $operations,
    seconds => $seconds, cpu_seconds => $cpu_seconds,
    ns_per_operation => $seconds * 1e9 / $operations,
    checksum => $checksum, initial => $initial, before => $before,
    after => hash_storage_info(\%hash),
}), "\n";
