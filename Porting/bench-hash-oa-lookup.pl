#!/usr/bin/perl

use strict;
use warnings;
use Digest::SHA;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

my ($mode, $n, $lookups, $query_seed, $warmup_seconds, $cpu) = @ARGV;
$warmup_seconds = 0 unless defined $warmup_seconds;
die "usage: bench-hash-oa-lookup.pl hit|control N LOOKUPS QUERY_SEED WARMUP_SECONDS CPU\n"
    unless defined $query_seed && defined $cpu
        && ($mode eq 'hit' || $mode eq 'control')
        && $n =~ /^\d+$/ && $n >= 0
        && $lookups =~ /^\d+$/ && $lookups > 0
        && $query_seed =~ /^\d+$/;

my @keys = map { sprintf 'customer:%08d:region:%02d', $_, $_ % 37 }
           0 .. $n - 1;
my @values = map { 'v' x 32 } 0 .. $n - 1;
my $empty_key = 'customer:00000000:region:00';
my %hash;
@hash{@keys} = @values if $mode eq 'hit';

# Small hashes reuse a balanced 1,024-query cycle. For larger hashes, shuffle
# the full key set so a lookup run does not repeatedly sample only its prefix.
my @queries;
if (!$n) {
    @queries = ($empty_key) x 1024;
}
elsif ($n <= 1024) {
    @queries = map { $keys[$_ % $n] } 0 .. 1023;
}
else {
    @queries = @keys;
}
srand($query_seed);
for (my $i = $#queries; $i > 0; --$i) {
    my $j = int rand($i + 1);
    @queries[$i, $j] = @queries[$j, $i];
}
my $batches = int($lookups / @queries);
my $tail_count = $lookups % @queries;
my @tail = $tail_count ? @queries[0 .. $tail_count - 1] : ();

sub run_queries {
    my ($sum_ref, $count_batches, $tail) = @_;
    if ($mode eq 'hit') {
        for (1 .. $count_batches) {
            for my $key (@queries) { $$sum_ref += length($hash{$key} // '') }
        }
        for my $key (@$tail) { $$sum_ref += length($hash{$key} // '') }
    }
    else {
        for (1 .. $count_batches) {
            for my $key (@queries) { $$sum_ref += length $key }
        }
        for my $key (@$tail) { $$sum_ref += length $key }
    }
}
my $warm_sum = 0;
my $warm_start = clock_gettime(CLOCK_MONOTONIC);
while (clock_gettime(CLOCK_MONOTONIC) - $warm_start < $warmup_seconds) {
    run_queries(\$warm_sum, 1, []);
}
my $frequency_path = defined($cpu) && $cpu ne ''
    ? "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_cur_freq" : '';
sub cpu_frequency {
    return '' unless $frequency_path && open my $fh, '<', $frequency_path;
    my $value = <$fh> // '';
    close $fh;
    chomp $value;
    return $value;
}
my $frequency_before = cpu_frequency();
my $cpu_start = eval {
    Time::HiRes::clock_gettime(Time::HiRes::CLOCK_PROCESS_CPUTIME_ID())
};
my $sum = 0;
my $start = clock_gettime(CLOCK_MONOTONIC);
run_queries(\$sum, $batches, \@tail);
my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $start;
my $cpu_end = eval {
    Time::HiRes::clock_gettime(Time::HiRes::CLOCK_PROCESS_CPUTIME_ID())
};
my $cpu_elapsed = defined($cpu_start) && defined($cpu_end)
    ? $cpu_end - $cpu_start : '';
my $frequency_after = cpu_frequency();
my $current_rss_kb = '';
if (open my $status, '<', '/proc/self/status') {
    while (my $line = <$status>) {
        $current_rss_kb = $1 if $line =~ /^VmRSS:\s+(\d+)/;
    }
    close $status;
}
my $memory_available = 0;
my %storage;
if ($mode eq 'hit') {
    my $info;
    if (eval { require Hash::Util; Hash::Util->can('hash_storage_info') }) {
        $info = eval { Hash::Util::hash_storage_info(\%hash) };
    }
    if ($info) {
        $memory_available = 1;
        %storage = map { $_ => $info->{$_} }
                   qw(requested_bytes index_bytes entry_bytes hv_size hv_body_size
                      arena_backed index_capacity index_width slot_size hash_bytes
                      entry_index_bytes allocator_bytes live entry_capacity);
    }
}
my $expected = $mode eq 'hit'
    ? $lookups * ($n ? 32 : 0)
    : $lookups * length($queries[0]);
die "lookup result mismatch: got $sum expected $expected\n"
    unless $sum == $expected;
my $final_keys = $mode eq 'hit' ? scalar(keys %hash) : 0;
die "hash key count mismatch\n" if $mode eq 'hit' && $final_keys != $n;
my $digest = '';
if ($mode eq 'hit') {
    my $sha = Digest::SHA->new(256);
    for my $key (sort keys %hash) {
        my $value = $hash{$key};
        $sha->add(pack('N', length($key)), $key,
                  pack('N', length($value)), $value);
    }
    $digest = $sha->hexdigest;
}

my @storage_fields = qw(requested_bytes index_bytes entry_bytes hv_size
                        hv_body_size arena_backed index_capacity index_width
                        slot_size hash_bytes entry_index_bytes allocator_bytes
                        live entry_capacity);
my @storage_values = map {
    defined $storage{$_} ? $storage{$_} : ''
} @storage_fields;
print join(',', $mode, $n, $lookups, sprintf('%.9f', $elapsed),
           sprintf('%.3f', $elapsed * 1e9 / $lookups), $sum, $final_keys, $digest,
           $memory_available, @storage_values, $current_rss_kb,
           $warmup_seconds, (defined($cpu_elapsed) ? sprintf('%.6f', $cpu_elapsed) : ''),
           $frequency_before, $frequency_after), "\n";
