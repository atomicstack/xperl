#!/usr/bin/perl

use strict;
use warnings;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

# Run each workload in a separate process so VmHWM describes that workload.
my @sizes = (1 .. 32, 100, 1_000, 1_000_000);
my @workloads = qw(hit miss insert delete churn keys values each presized highholes tombstonechurn);
if (@ARGV && $ARGV[0] eq '--worker') {
    my ($work, $n, $query_seed) = @ARGV[1, 2, 3];
    my @keys = map { sprintf 'customer:%08d:region:%02d', $_, $_ % 37 } 0 .. $n-1;
    my @vals = map { "value-$_-" . ('x' x 24) } 0 .. $n-1;
    my @random_keys;
    if ($work eq 'random-hit') {
        @random_keys = @keys;
        srand($query_seed);
        for (my $i = $#random_keys; $i > 0; --$i) {
            my $j = int rand($i + 1);
            @random_keys[$i, $j] = @random_keys[$j, $i];
        }
    }
    if ($work eq 'growth-index' || $work eq 'growth-entry') {
        my $want_entry = $work eq 'growth-entry';
        my $stat = sub {
            return unless eval { require Hash::Util; Hash::Util->can('hash_storage_info') };
            return Hash::Util::hash_storage_info($_[0]);
        };
        my %empty;
        my $empty_info = $stat->(\%empty);
        my $status = $empty_info ? 'supported' : 'unsupported';
        $status = 'unsupported'
            if $status eq 'supported' && $want_entry && !$empty_info->{open_addressed};
        my ($elapsed, $last_hash, @storage) = (0, {});
        my $repetitions = $status eq 'supported' ? 5 : 0;
        my (@index_transitions, @entry_transitions);
        my @event_start_live;
        @storage = ('') x 17;
        if ($status eq 'supported') {
            for (1 .. $repetitions) {
                undef $last_hash;
                my %h;
                $h{$keys[$_]} = $vals[$_] for 0 .. $n-1;
                my $info = $stat->(\%h);
                my $entry_limit = $info->{entry_capacity};
                my $index_limit = int($info->{index_capacity} * 2 / 3);
                my $id = $n;
                # Fill well short of the next threshold without consulting the
                # O(index_capacity) diagnostic for every ordinary insertion.
                my $target = $want_entry ? $entry_limit : $index_limit;
                if (defined $target && $target > $id) {
                    for (; $id < $target; ++$id) {
                        $h{"growth:$id"} = "value-$id-" . ('x' x 24);
                    }
                    $info = $stat->(\%h);
                    # A collision-gated index split can happen inside the
                    # bulk fill. Continue from the new capacity's threshold.
                    while (!$want_entry && $info->{live} < int($info->{index_capacity} * 2 / 3)) {
                        my $new_target = int($info->{index_capacity} * 2 / 3);
                        for (; $id < $new_target; ++$id) {
                            $h{"growth:$id"} = "value-$id-" . ('x' x 24);
                        }
                        $info = $stat->(\%h);
                    }
                }
                my ($sample_before, $sample_after);
                my $max_probes = 4096;
                for (1 .. $max_probes) {
                    $sample_before = $info;
                    my $trigger_key = "growth:$id";
                    my $trigger_value = "value-$id-" . ('x' x 24);
                    my $start = clock_gettime(CLOCK_MONOTONIC);
                    $h{$trigger_key} = $trigger_value;
                    my $stop = clock_gettime(CLOCK_MONOTONIC);
                    $info = $stat->(\%h);
                    $sample_after = $info;
                    my $index_change = $sample_after->{index_capacity}
                        != $sample_before->{index_capacity};
                    my $entry_change = defined $sample_before->{entry_capacity}
                        && $sample_after->{entry_capacity} != $sample_before->{entry_capacity};
                    if (($want_entry && $entry_change && !$index_change)
                        || (!$want_entry && $index_change && !$entry_change)) {
                        $elapsed += $stop - $start;
                        last;
                    }
                    ++$id;
                }
                my $index_changed = $sample_after->{index_capacity}
                    != $sample_before->{index_capacity};
                my $entry_changed = defined $sample_before->{entry_capacity}
                    && $sample_after->{entry_capacity} != $sample_before->{entry_capacity};
                if ($want_entry) {
                    die "entry-growth sample did not occur within $max_probes probes\n"
                        unless $entry_changed && !$index_changed;
                }
                else {
                    die "index-growth sample did not occur within $max_probes probes\n"
                        unless $index_changed && !$entry_changed;
                }
                push @event_start_live, $sample_before->{live};
                push @index_transitions,
                    "$sample_before->{index_capacity}>$sample_after->{index_capacity}";
                push @entry_transitions,
                    (defined $sample_before->{entry_capacity}
                        ? "$sample_before->{entry_capacity}>$sample_after->{entry_capacity}"
                        : 'unsupported');
                $last_hash = \%h;
            }
            my $info = $stat->($last_hash);
            @storage = map { defined $_ ? $_ : '' }
                @$info{qw(live index_capacity entry_capacity tombstones requested_bytes
                          allocator_bytes metadata_bytes index_bytes entry_bytes
                          entry_used entry_spare free_list_length index_empty
                          index_deleted probe_total probe_max probe_mean)};
        }
        my ($rss, $current_rss) = (0, 0);
        if (open my $fh, '<', '/proc/self/status') {
            while (<$fh>) {
                $rss = $1 if /^VmHWM:\s+(\d+)/;
                $current_rss = $1 if /^VmRSS:\s+(\d+)/;
            }
            close $fh;
        }
        require Digest::SHA;
        my $digest = Digest::SHA->new(256);
        for my $key (sort keys %$last_hash) {
            my $value = $last_hash->{$key};
            $digest->add(pack('N', length $key), $key,
                         pack('N', length $value), $value);
        }
        my $signature = $digest->hexdigest;
        my $op_count = $repetitions;
        my $seconds_per_event = $op_count ? $elapsed / $op_count : 0;
        print join(',', $work, $n, $repetitions, $op_count, $repetitions,
                   sprintf('%.9f', $elapsed), sprintf('%.9f', $seconds_per_event),
                   sprintf('%.9f', $seconds_per_event), $rss, $current_rss,
                   scalar(keys %$last_hash), @storage, $signature, $status,
                   ($status eq 'supported' ? join(';', @event_start_live) : ''),
                   join(';', @index_transitions), join(';', @entry_transitions),
                   ($status eq 'supported' ? 'verified' : 'unsupported')), "\n";
        exit;
    }
    my $repetitions = int(100_000 / $n);
    $repetitions = 1 if $repetitions < 1;
    $repetitions = 3 if $n >= 1_000_000;
    $repetitions = 1 if $work eq 'highholes' || $work eq 'tombstonechurn';
    my $batch_size = int(100 / $n);
    $batch_size = 1 if $batch_size < 1;
    $batch_size = $repetitions if $batch_size > $repetitions;
    my $groups = int(($repetitions + $batch_size - 1) / $batch_size);
    my @misses = map { "missing:$_" } 0 .. $n-1;
    my @replacements = map { "replacement:$_" } 0 .. $n-1;
    my ($elapsed, $last_hash, $done) = (0, undef, 0);

    while ($done < $repetitions) {
        my $count = $repetitions - $done;
        $count = $batch_size if $count > $batch_size;
        undef $last_hash;
        my @batches = map { {} } 1 .. $count;

        # Build input hashes before timing. Each group caps live entries at
        # about 100 so repeats do not multiply the measured table size.
        if ($work ne 'insert' && $work ne 'presized') {
            for my $href (@batches) {
                $href->{$keys[$_]} = $vals[$_] for 0 .. $n-1;
            }
        }
        if ($work eq 'presized') { keys(%$_) = $n for @batches }
        if ($work eq 'keys-holes' || $work eq 'values-holes' || $work eq 'each-holes') {
            my $remove = int($n * 9 / 10);
            for my $href (@batches) { delete $href->{$keys[$_]} for 0 .. $remove - 1 }
        }

        my $start = clock_gettime(CLOCK_MONOTONIC);
        if ($work eq 'hit' || $work eq 'random-hit') {
            my $query = $work eq 'random-hit' ? \@random_keys : \@keys;
            for my $href (@batches) { my $x; $x = $href->{$query->[$_]} for 0 .. $n-1 }
        }
        elsif ($work eq 'miss') {
            for my $href (@batches) { my $x; $x = $href->{$misses[$_]} for 0 .. $n-1 }
        }
        elsif ($work eq 'insert' || $work eq 'presized') {
            for my $href (@batches) { $href->{$keys[$_]} = $vals[$_] for 0 .. $n-1 }
        }
        elsif ($work eq 'delete') {
            for my $href (@batches) { delete $href->{$keys[$_]} for 0 .. $n-1 }
        }
        elsif ($work eq 'churn') {
            for my $href (@batches) {
                for (0 .. $n-1) {
                    delete $href->{$keys[$_]};
                    $href->{$replacements[$_]} = $vals[$_];
                }
            }
        }
        elsif ($work eq 'highholes') {
            my $remove = int($n * 9 / 10);
            for my $href (@batches) { delete $href->{$keys[$_]} for 0 .. $remove - 1 }
        }
        elsif ($work eq 'tombstonechurn') {
            for my $href (@batches) {
                for my $round (0 .. 7) {
                    for (0 .. $n-1) {
                        my $oldkey = $round ? "tombstone:" . ($round - 1) . ":$_" : $keys[$_];
                        delete $href->{$oldkey};
                        $href->{"tombstone:$round:$_"} = $vals[$_];
                    }
                }
            }
        }
        elsif ($work eq 'keys') {
            for my $href (@batches) {
                my $x = 0;
                $x += length($_) for keys %$href;
            }
        }
        elsif ($work eq 'keys-holes') {
            for my $href (@batches) {
                my $x = 0;
                $x += length($_) for keys %$href;
            }
        }
        elsif ($work eq 'values') {
            for my $href (@batches) {
                my $x = 0;
                $x += length($_) for values %$href;
            }
        }
        elsif ($work eq 'values-holes') {
            for my $href (@batches) {
                my $x = 0;
                $x += length($_) for values %$href;
            }
        }
        elsif ($work eq 'each') {
            for my $href (@batches) {
                my $x = 0;
                while (my ($key, $value) = each %$href) {
                    $x += length($key) + length($value);
                }
            }
        }
        elsif ($work eq 'each-holes') {
            for my $href (@batches) {
                my $x = 0;
                while (my ($key, $value) = each %$href) {
                    $x += length($key) + length($value);
                }
            }
        }
        $elapsed += clock_gettime(CLOCK_MONOTONIC) - $start;
        $done += $count;
        $last_hash = $batches[-1];
    }

    my $ops_per_batch = $n * ($work eq 'churn' ? 2 :
                              $work eq 'tombstonechurn' ? 16 : 1);
    my $live_per_batch = $n - int($n * 9 / 10);
    my $op_count = $work eq 'highholes' ? int($n * 9 / 10) :
                    $work =~ /-holes$/ ? $live_per_batch * $repetitions :
                    $work eq 'tombstonechurn' ? 16 * $n : $ops_per_batch * $repetitions;
    $op_count = 1 if !$op_count;
    my $operations = $op_count;
    my $seconds_per_batch = $elapsed / $repetitions;
    my $seconds_per_operation = $elapsed / $operations;
    my ($rss, $current_rss) = (0, 0);
    if (open my $fh, '<', '/proc/self/status') {
        while (<$fh>) {
            $rss = $1 if /^VmHWM:\s+(\d+)/;
            $current_rss = $1 if /^VmRSS:\s+(\d+)/;
        }
        close $fh;
    }
    my @storage = ('') x 17;
    if (eval { require Hash::Util; Hash::Util->can('hash_storage_info') }) {
        my $info = Hash::Util::hash_storage_info($last_hash);
        @storage = map { defined $_ ? $_ : '' }
            @$info{qw(live index_capacity entry_capacity tombstones requested_bytes
                      allocator_bytes metadata_bytes index_bytes entry_bytes
                      entry_used entry_spare free_list_length index_empty
                      index_deleted probe_total probe_max probe_mean)};
    }
    require Digest::SHA;
    my $digest = Digest::SHA->new(256);
    for my $key (sort keys %$last_hash) {
        my $value = $last_hash->{$key};
        $digest->add(pack('N', length $key), $key,
                     pack('N', length $value), $value);
    }
    my $signature = $digest->hexdigest;
    print join(',', $work, $n, $repetitions, $operations, $groups,
               sprintf('%.9f', $elapsed), sprintf('%.9f', $seconds_per_batch),
               sprintf('%.9f', $seconds_per_operation), $rss, $current_rss,
               scalar(keys %$last_hash), @storage, $signature, 'supported', '', '', '', ''), "\n";
    exit;
}

print "version,workload,n,repetitions,operations,measurement_groups,elapsed_seconds,seconds_per_batch,seconds_per_operation,peak_rss_kb,current_rss_kb,final_keys,live,index_capacity,entry_capacity,tombstones,requested_bytes,allocator_bytes,metadata_bytes,index_bytes,entry_bytes,entry_used,entry_spare,free_list_length,index_empty,index_deleted,probe_total,probe_max,probe_mean,result_signature,status,event_start_live,event_index_transitions,event_entry_transitions,event_validation\n";
for my $n (@sizes) {
    for my $work (@workloads) {
        open my $pipe, '-|', $^X, '-Ilib', $0, '--worker', $work, $n
            or die "cannot start worker $work/$n: $!";
        my $out = <$pipe>;
        close $pipe or die "worker failed: $work/$n ($?)";
        chomp $out;
        my $version = sprintf '%vd', $^V;
        print join(',', $version, $out), "\n";
    }
}
