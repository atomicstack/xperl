#!/usr/bin/perl

use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC CLOCK_PROCESS_CPUTIME_ID);
use Digest::SHA;
use Hash::Util ();
use XS::APItest ();
use B ();

my $case = decode_json(shift // die "usage: $0 CASE_JSON\n");
my $private = ($case->{stored_keys} // 'interned') eq 'private';
my %flag_probe;
my $sharing_flag = B::svref_2object(\%flag_probe)->FLAGS;
XS::APItest::Hash::disable_hash_key_sharing(\%flag_probe);
$sharing_flag ^= B::svref_2object(\%flag_probe)->FLAGS;
die "cannot identify SHAREKEYS flag\n" unless $sharing_flag;
my $shared_table_initial = XS::APItest::Hash::shared_key_storage_info();
my ($work, $n, $length, $budget) = @$case{qw(workload n key_length operations)};
my $pad = 'x' x ($length - 9);
my @keys = map { sprintf('k%08d', $_) . $pad } 0 .. $n - 1;
my @miss = map { sprintf('m%08d', $_) . $pad } 0 .. ($n || 1) - 1;
my @replacement = map { sprintf('r%08d', $_) . $pad } 0 .. $n - 1;
my $value = 'v' x 32;
my $other = 'r' x 32;

if (($case->{distribution} // '') eq 'collision') {
    my $buckets = 8;
    $buckets *= 2 while $buckets < 3 * $n;
    my @collision;
    for (my $i = 0; @collision < 2 * $n; ++$i) {
        my $key = sprintf('c%08d', $i) . $pad;
        push @collision, $key unless Hash::Util::hash_value($key) & ($buckets - 1);
    }
    @keys = @collision[0 .. $n - 1];
    @miss = @collision[$n .. 2 * $n - 1];
}

srand($case->{query_seed});
my @query = @keys;
if ($work eq 'random-hit' || $work eq 'mixed') {
    for (my $i = $#query; $i > 0; --$i) {
        my $j = int rand($i + 1);
        @query[$i, $j] = @query[$j, $i];
    }
}
@query = @miss if $work eq 'miss';
if ($work eq 'mixed') {
    @query = map { ($_ & 1) ? $miss[$_] : $query[$_] } 0 .. $#query;
}
@query = @miss unless @query;

sub storage {
    my ($hash) = @_;
    my $info = Hash::Util::hash_storage_info($hash);
    $info->{sharekeys} = (B::svref_2object($hash)->FLAGS & $sharing_flag) ? 1 : 0;
    # Addresses differ between processes and do not describe storage cost.
    delete @$info{qw(entries_address index_address)};
    $info->{table_bytes} = $info->{requested_bytes} + $info->{hv_size} + $info->{hv_body_size};
    return $info;
}

sub populate {
    my ($hash) = @_;
    $hash->{$keys[$_]} = $value for 0 .. $#keys;
}

my %sample;
XS::APItest::Hash::disable_hash_key_sharing(\%sample) if $private;
keys(%sample) = $case->{reserve} if $case->{reserve};
populate(\%sample);
my $before = storage(\%sample);
die "wrong stored-key interning policy\n" if $before->{sharekeys} == $private;
if ($before->{index_width}) {
    my $expected_width = ($case->{expect_width} // '') eq 'adaptive'
        ? $before->{entry_capacity} <= 255 ? 1 : $before->{entry_capacity} <= 65535 ? 2 : 4
        : $case->{expect_width};
    die "wrong index width: $before->{index_width}\n"
        if defined $expected_width && $before->{index_width} != $expected_width;
}
if ($n && !$case->{reserve} && exists $case->{expect_linear_limit}) {
    my $linear = $n <= $case->{expect_linear_limit};
    die "wrong linear representation\n" unless !!$before->{linear} == !!$linear;
    if ($n == 2 && $linear) {
        die "wrong initial heap allocation\n"
            unless $before->{entry_capacity} == $case->{expect_min_alloc};
    }
}
my ($elapsed, $cpu_elapsed, $operations, $checksum) = (0, 0, 0, 0);
my $last = \%sample;
my $count = int($budget / ($n || 1)) || 1;

if (($case->{query_keys} // '') eq 'interned') {
    @query = map { XS::APItest::Hash::shared_query_key($_) } @query;
}

# A diagnostic sample must not keep the measured keys interned during
# construction or prevent deletion from releasing their last owner.
%sample = () unless $work =~ /^(?:hit|random-hit|miss|mixed|constant-hit)$/;

if ($work =~ /^(?:hit|random-hit|miss|mixed|constant-hit)$/) {
    my @cycle = @query;
    @cycle = (@cycle, @query) while @cycle < 1024;
    if ($work ne 'constant-hit') {
        for my $index (0, $#cycle) {
            my $sv = B::svref_2object(\$cycle[$index]);
            my $interned = ($sv->FLAGS & B::SVf_IsCOW()) && !$sv->LEN;
            die "wrong query interning policy\n"
                unless !!$interned == (($case->{query_keys} // '') eq 'interned');
        }
    }
    my $loops = int($budget / @cycle) || 1;
    my $constant;
    if ($work eq 'constant-hit') {
        my $literal = $keys[0] // ('k00000000' . $pad);
        $constant = eval 'sub { my ($h, $loops, $queries) = @_; my $sum = 0; '
            . 'for (1 .. $loops) { for (@$queries) { $sum += length($h->{'
            . "'$literal'" . '} // q{}) } } return $sum }';
        die $@ if $@;
    }
    my $cpu = clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
    my $start = clock_gettime(CLOCK_MONOTONIC);
    if ($constant) {
        $checksum = $constant->(\%sample, $loops, \@cycle);
    }
    else {
        for (1 .. $loops) {
            $checksum += length($sample{$_} // '') for @cycle;
        }
    }
    $elapsed = clock_gettime(CLOCK_MONOTONIC) - $start;
    $cpu_elapsed = clock_gettime(CLOCK_PROCESS_CPUTIME_ID) - $cpu;
    $operations = $loops * @cycle;
    my $hits = $work eq 'miss' || !$n ? 0
             : $work eq 'mixed' ? scalar(grep { !($_ & 1) } 0 .. $n - 1) : $n;
    my $expected = $work eq 'constant-hit' ? ($n ? 32 * $operations : 0)
                 : $loops * (@cycle / @query) * $hits * 32;
    die "lookup checksum $checksum != $expected\n" unless $checksum == $expected;
}
elsif ($work eq 'many-live') {
    $count = 20000 if $count > 20000;
    my @live = map { {} } 1 .. $count;
    if ($private) { XS::APItest::Hash::disable_hash_key_sharing($_) for @live }
    my $cpu = clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
    my $start = clock_gettime(CLOCK_MONOTONIC);
    populate($_) for @live;
    $elapsed = clock_gettime(CLOCK_MONOTONIC) - $start;
    $cpu_elapsed = clock_gettime(CLOCK_PROCESS_CPUTIME_ID) - $cpu;
    $operations = $count;
    $last = $live[-1];
    $checksum += scalar(keys %$_) for @live;
    die "live hash count mismatch\n" unless $checksum == $n * $count;
    $case->{live_hashes} = $count;
    $case->{retained_shared_table} = XS::APItest::Hash::shared_key_storage_info();
    if (open my $status, '<', '/proc/self/status') {
        while (<$status>) { $case->{retained_rss_kb} = 0 + $1 if /^VmRSS:\s+(\d+)/ }
    }
}
else {
    my $batch = int(4096 / ($n || 1)) || 1;
    $batch = $count if $batch > $count;
    my $done = 0;
    while ($done < $count) {
        undef $last;
        my $take = $count - $done;
        $take = $batch if $take > $batch;
        my @hashes = map { {} } 1 .. $take;
        if ($private) { XS::APItest::Hash::disable_hash_key_sharing($_) for @hashes }
        my $construct = $work eq 'insert' || $work eq 'assign' || $work eq 'presized'
                     || $work eq 'transitions';
        populate($_) for $construct ? () : @hashes;
        keys(%$_) = $n for $work eq 'presized' ? @hashes : ();
        my $remove = int($n * 9 / 10);
        if ($work =~ /-holes$/) {
            for my $h (@hashes) { delete $h->{$keys[$_]} for 0 .. $remove - 1 }
        }
        my @pairs = map { ($_, $value) } @keys;
        my $cpu = clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
        my $start = clock_gettime(CLOCK_MONOTONIC);
        if ($work eq 'insert' || $work eq 'presized') {
            for my $h (@hashes) { $h->{$keys[$_]} = $value for 0 .. $#keys }
        }
        elsif ($work eq 'assign') {
            %$_ = @pairs for @hashes;
        }
        elsif ($work eq 'replace') {
            for my $h (@hashes) { $h->{$keys[$_]} = $other for 0 .. $#keys }
        }
        elsif ($work eq 'delete') {
            for my $h (@hashes) { delete $h->{$keys[$_]} for 0 .. $#keys }
        }
        elsif ($work eq 'churn') {
            for my $h (@hashes) {
                for (0 .. $#keys) { delete $h->{$keys[$_]}; $h->{$replacement[$_]} = $value }
            }
        }
        elsif ($work eq 'transitions') {
            for my $h (@hashes) {
                $h->{$keys[$_]} = $value for 0 .. $#keys;
                delete $h->{$keys[$_]} for 1 .. $#keys;
                $h->{$keys[$_]} = $value for 1 .. $#keys;
            }
        }
        elsif ($work eq 'keys' || $work eq 'keys-holes') {
            for my $h (@hashes) { $checksum += length($_) for keys %$h }
        }
        elsif ($work eq 'values' || $work eq 'values-holes') {
            for my $h (@hashes) { $checksum += length($_) for values %$h }
        }
        elsif ($work eq 'each' || $work eq 'each-holes') {
            for my $h (@hashes) {
                while (my ($k, $v) = each %$h) { $checksum += length($k) + length($v) }
            }
        }
        else { die "unknown workload $work\n" }
        $elapsed += clock_gettime(CLOCK_MONOTONIC) - $start;
        $cpu_elapsed += clock_gettime(CLOCK_PROCESS_CPUTIME_ID) - $cpu;
        $last = $hashes[-1];
        $done += $take;
    }
    my $per_hash = $work eq 'transitions' ? $n + 2 * ($n ? $n - 1 : 0)
                 : $work eq 'churn' ? 2 * $n
                 : $work =~ /-holes$/ ? $n - int($n * 9 / 10) : $n;
    $operations = $count * ($per_hash || 1);
    if ($work =~ /^(?:keys|values|each)(?:-holes)?$/) {
        my $unit = $work =~ /^keys/ ? $length : $work =~ /^values/ ? 32 : $length + 32;
        die "iteration checksum mismatch\n" unless $checksum == $count * $per_hash * $unit;
    }
}

my $expected_n = $work eq 'delete' ? 0 : $work =~ /-holes$/ ? $n - int($n * 9 / 10) : $n;
die "key count mismatch\n" unless keys(%$last) == $expected_n;
my $shared_table_final = XS::APItest::Hash::shared_key_storage_info();
my %expected = map { ($_ => $work eq 'replace' ? $other : $value) }
               $work eq 'churn' ? @replacement : @keys;
%expected = () if $work eq 'delete';
delete @expected{@keys[0 .. int($n * 9 / 10) - 1]} if $work =~ /-holes$/ && int($n * 9 / 10);
my $digest = Digest::SHA->new(256);
for my $key (sort keys %$last) {
    die "wrong value for $key\n" unless exists $expected{$key} && $last->{$key} eq $expected{$key};
    $digest->add(pack('N', length $key), $key, $last->{$key});
}
my $after = storage($last);
die "stored-key interning policy changed during workload\n" if $after->{sharekeys} == $private;
my %rss;
if (open my $status, '<', '/proc/self/status') {
    while (<$status>) { $rss{$1} = 0 + $2 if /^(VmRSS|VmHWM):\s+(\d+)/ }
}
print encode_json({case => $case, elapsed_seconds => $elapsed,
    cpu_seconds => $cpu_elapsed, operations => $operations,
    ns_per_operation => 1e9 * $elapsed / $operations, checksum => $checksum,
    result_sha256 => $digest->hexdigest, before => $before, after => $after,
    shared_table_initial => $shared_table_initial, shared_table_final => $shared_table_final,
    rss_kb => \%rss}), "\n";
