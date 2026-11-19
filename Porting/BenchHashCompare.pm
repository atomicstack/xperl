package BenchHashCompare;

use strict;
use warnings;
use BenchUtils qw(absolute sha256 perl_info source_info source_patch platform_info
    write_json run rng random32 shuffle hash_seed median minimum maximum
    parse_sizes csv_rows csv_line pin_cpu);
use File::Basename qw(dirname);
use Getopt::Long qw(GetOptionsFromArray);
use POSIX qw(strftime);
use JSON::PP ();

my @oa_fields = qw(workload n repetitions operations measurement_groups elapsed_seconds
    seconds_per_batch seconds_per_operation peak_rss_kb current_rss_kb final_keys
    live index_capacity entry_capacity tombstones requested_bytes allocator_bytes
    metadata_bytes index_bytes entry_bytes entry_used entry_spare free_list_length
    index_empty index_deleted probe_total probe_max probe_mean result_signature status
    event_start_live event_index_transitions event_entry_transitions event_validation);
my @lookup_fields = qw(mode n lookups elapsed_seconds ns_per_lookup sum final_keys
    result_sha256 memory_available requested_bytes index_bytes entry_bytes hv_size
    hv_body_size arena_backed index_capacity index_width slot_size hash_bytes
    entry_index_bytes allocator_bytes live entry_capacity current_rss_kb warmup_seconds
    process_cpu_seconds cpu_freq_before_khz cpu_freq_after_khz);

sub field_median {
    my ($rows, $field) = @_;
    return median(map { $_->{$field} } @$rows);
}

sub per_live {
    my ($rows, $field, $scale) = @_;
    $scale //= 1;
    return median(map { $_->{$field} * $scale / $_->{live} }
        grep { $_->{live} && defined($_->{$field}) && $_->{$field} ne '' } @$rows);
}

sub summarize {
    my ($rows, $lookup, $sizes, $workloads) = @_;
    my @summary;
    for my $work ($lookup ? ('hit') : sort @$workloads) {
        for my $n ($lookup ? @$sizes : sort { $a <=> $b } @$sizes) {
            my @group = grep { $_->{n} == $n && ($lookup || $_->{workload} eq $work) } @$rows;
            my (%pairs, %by_build);
            for my $row (@group) {
                push @{$by_build{$row->{build}}}, $row
                    if $lookup || $row->{status} eq 'supported';
                $pairs{$row->{trial}}{$row->{build}} = $row
                    if !$lookup || $row->{mode} eq 'hit';
            }
            my $time = $lookup ? 'ns_per_lookup' : 'seconds_per_operation';
            my @ratios;
            for my $pair (values %pairs) {
                my ($baseline, $candidate) = @$pair{qw(baseline candidate)};
                next unless $baseline && $candidate && $baseline->{$time} && $candidate->{$time};
                next if !$lookup && ($baseline->{status} ne 'supported' || $candidate->{status} ne 'supported');
                next if !$lookup && $work =~ /^growth-/
                    && $baseline->{event_start_live} ne $candidate->{event_start_live};
                push @ratios, $baseline->{$time} / $candidate->{$time};
            }
            my $speedup = $lookup ? 'speedup_baseline_over_candidate_median'
                : 'median_speedup_baseline_over_candidate';
            my %item = (n => $n, paired_trials => scalar @ratios,
                $speedup => median(@ratios), speedup_min => minimum(@ratios),
                speedup_max => maximum(@ratios));
            if (!$lookup) {
                $item{workload} = $work;
                $item{candidate_supported_trials} = scalar @{$by_build{candidate} || []};
                $item{growth_events_comparable} = $work =~ /^growth-/ ? scalar @ratios : undef;
            }
            for my $build (qw(baseline candidate)) {
                my $selected = $by_build{$build} || [];
                my $value = field_median($selected, $time);
                my $time_field = $build.($lookup ? '_ns_per_lookup_median' : '_ns_per_op_median');
                $item{$time_field} = defined($value) ? $value * ($lookup ? 1 : 1e9) : undef;
                for my $field (qw(requested_bytes allocator_bytes current_rss_kb),
                    $lookup ? () : 'peak_rss_kb') {
                    $item{"${build}_${field}_median"} = field_median($selected, $field);
                    if (!$lookup || $field eq 'requested_bytes') {
                        (my $normalized = $field) =~ s/_kb$/_bytes/;
                        $item{"${build}_${normalized}_per_live"} =
                            per_live($selected, $field, $field =~ /_kb$/ ? 1024 : 1);
                    }
                }
                if ($lookup) {
                    $item{"${build}_memory_available"} = @$selected && $selected->[0]{memory_available}
                        ? JSON::PP::true : JSON::PP::false;
                    $item{"${build}_total_bytes_including_hv_median"} = median(map {
                        $_->{requested_bytes} + $_->{hv_size} + $_->{hv_body_size}
                    } grep { defined($_->{requested_bytes}) && defined($_->{hv_size})
                        && defined($_->{hv_body_size}) } @$selected);
                    $item{"${build}_control_ns_per_lookup_median"} =
                        field_median($by_build{"$build-control"} || [], $time);
                }
            }
            if ($lookup) {
                $item{control_ns_per_lookup_median} = field_median(
                    [map { @{$by_build{$_} || []} } qw(baseline-control candidate-control)], $time);
            }
            push @summary, \%item;
        }
    }
    return \@summary;
}

sub main {
    my ($lookup, $directory, $driver, @args) = @_;
    my %options = (trials => 7, seed => 20261031, lookups => 1000000,
        'warmup-seconds' => 0, sizes => $lookup ? '0-9' : '1-32,128,1000,10000,100000,1000000',
        workloads => 'hit,miss,insert,delete,churn,random-hit,keys,values,each,keys-holes,values-holes,each-holes,presized,highholes,tombstonechurn,growth-index,growth-entry');
    GetOptionsFromArray(\@args, \%options, 'baseline=s', 'candidate=s', 'outputdir=s',
        'trials=i', 'sizes=s', 'workloads=s', 'seed=i', 'linear-max=i', 'lookups=i',
        'warmup-seconds=f', 'cpu=i', 'help') or die "Invalid options\n";
    if ($options{help}) {
        print "Usage: $driver --baseline PERL --candidate PERL --outputdir DIR [--sizes LIST] [--trials N]\n";
        return;
    }
    die "--baseline, --candidate and --outputdir are required\n"
        unless $options{baseline} && $options{candidate} && $options{outputdir};
    die "Counts must be positive and warmup nonnegative\n"
        if $options{trials} < 1 || $options{lookups} < 1 || $options{'warmup-seconds'} < 0;
    die "Invalid --linear-max\n" if defined($options{'linear-max'})
        && $options{'linear-max'} !~ /\A(?:0|2|4|8)\z/;
    die "Unexpected arguments: @args\n" if @args;
    my @sizes = parse_sizes($options{sizes});
    my @workloads = $lookup ? ('hit') : split /,/, $options{workloads};
    die "Empty workloads\n" unless @workloads;
    my $platform = platform_info();
    pin_cpu($options{cpu});
    my $out = absolute($options{outputdir});
    my $worker = "$directory/bench-hash-oa".($lookup ? '-lookup' : '').'.pl';

    my (%builds, %patches, %info);
    for my $build (qw(baseline candidate)) {
        my $perl = $builds{$build} = absolute($options{$build});
        $patches{$build} = source_patch(dirname($perl), "$out/source-patches/$build.diff");
        $patches{$build}{path} = "source-patches/$build.diff" if $patches{$build}{path};
        $info{$build} = {perl => $perl, sha256 => sha256($perl),
            %{perl_info($perl)}, %{source_info(dirname($perl))}};
    }
    write_json("$out/metadata.json", {
        created_utc => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime), %$platform,
        seed => $options{seed}, trials => $options{trials}, sizes => \@sizes,
        workloads => \@workloads, lookups_per_trial => $options{lookups}, script => $worker,
        worker => {path => $worker, sha256 => sha256($worker)},
        driver => {path => $driver, sha256 => sha256($driver)},
        helpers => {map { $_ => sha256("$directory/$_") } qw(BenchUtils.pm BenchHashCompare.pm)},
        source_patches => \%patches, builds => \%info,
        runtime_environment => {baseline_PERL_HASH_LINEAR_MAX => 'unset',
            candidate_PERL_HASH_LINEAR_MAX => $options{'linear-max'}},
        measurement => {warmup_seconds => $options{'warmup-seconds'}, pinned_cpu => $options{cpu},
            allowed_cpus => $platform->{allowed_cpus},
            frequency_sampling => 'per-worker before/after timed section when available',
            process_cpu_clock => 'CLOCK_PROCESS_CPUTIME_ID when available'},
        query_cycle_small_hashes => 1024, larger_hash_queries => 'shuffle full key set before timing',
        n_zero_behavior => 'empty hash; repeated unsuccessful lookups',
    });
    open my $raw, '>:raw', "$out/raw.csv" or die "$out/raw.csv: $!\n";
    $raw->autoflush(1);
    my @fields = $lookup ? @lookup_fields : @oa_fields;
    my @columns = (qw(trial build run_order hash_seed query_seed), @fields,
        qw(worker_wall_seconds linear_max));
    print {$raw} csv_line(@columns);
    my $state = rng($options{seed});
    my @rows;
    for my $trial (1 .. $options{trials}) {
        for my $work (@workloads) {
            for my $n (@sizes) {
                my $seed = hash_seed($state);
                my $query = random32($state);
                my %pair;
                my $rank = 0;
                for my $control ($lookup ? (0, 1) : (0)) {
                    for my $build (shuffle($state, qw(baseline candidate))) {
                        my $perl = $builds{$build};
                        my %env = (PERL_HASH_SEED => $seed);
                        $env{PERL_HASH_LINEAR_MAX} = $options{'linear-max'}
                            if $build eq 'candidate' && defined $options{'linear-max'};
                        my @parameters = $lookup
                            ? ($control ? 'control' : 'hit', $n, $options{lookups},
                                $query, $options{'warmup-seconds'}, $options{cpu} // '')
                            : ('--worker', $work, $n, $query);
                        my $result = run([$perl, '-Ilib', $worker, @parameters],
                            cwd => dirname($perl), env => \%env, unset => ['PERL_HASH_LINEAR_MAX']);
                        die "Worker stderr: $result->{stderr}" if $lookup && length $result->{stderr};
                        my @records = csv_rows($result->{stdout});
                        die "Unexpected worker CSV: $result->{stdout}\n"
                            unless @records == 1 && @{$records[0]} == @fields;
                        my %row;
                        @row{@fields} = @{$records[0]};
                        for my $field (@fields) {
                            next if $field =~ /\A(?:mode|workload|result_sha256|result_signature|status|event_start_live|event_index_transitions|event_entry_transitions|event_validation)\z/;
                            $row{$field} = $row{$field} ne '' ? 0 + $row{$field} : $lookup ? undef : '';
                        }
                        @row{qw(trial build run_order hash_seed query_seed worker_wall_seconds linear_max)} =
                            ($trial, $build.($control ? '-control' : ''), ++$rank, $seed,
                                $query, $result->{wall_seconds}, $build eq 'candidate' ? $options{'linear-max'} : '');
                        push @rows, \%row;
                        print {$raw} csv_line(@row{@columns}) or die "Cannot write samples: $!\n";
                        $pair{$build} = \%row unless $control;
                    }
                    if (!$control && ($lookup || $work !~ /^growth-/)) {
                        for my $field ($lookup ? qw(sum final_keys result_sha256)
                            : qw(final_keys result_signature)) {
                            die "Worker $field mismatch for $work/$n/trial $trial\n"
                                if $pair{baseline}{$field} ne $pair{candidate}{$field};
                        }
                    }
                }
                print STDERR "$trial/$options{trials} $work/$n done\n";
            }
        }
    }
    close $raw or die "Cannot close samples: $!\n";
    write_json("$out/summary.json", summarize(\@rows, $lookup, \@sizes, \@workloads));
}

1;
