#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC CLOCK_PROCESS_CPUTIME_ID);
use Hash::Util ();
use List::Util qw(sum);
use File::Spec;
use Getopt::Long qw(GetOptions);

if (@ARGV && $ARGV[0] eq '--worker') {
    shift;
    my $c = decode_json(shift);
    my $n = $c->{n};
    my @keys = map { sprintf 'k%08d', $_ } 0 .. $n - 1;
    my %hash;
    my $value = 'v' x 32;
    $hash{$keys[$_]} = $value for 0 .. $#keys;
    my $storage = Hash::Util::hash_storage_info(\%hash);
    my ($live, $buckets, $used, @histogram) = Hash::Util::bucket_info(\%hash);
    my $probe_total = 0;
    for my $length (1 .. $#histogram) {
        $probe_total += ($histogram[$length] || 0) * $length * ($length + 1) / 2;
    }
    my @queries = @keys;
    srand($c->{query_seed});
    if ($c->{scope} ne 'sequential') {
        for (my $i = $#queries; $i > 0; --$i) {
            my $j = int rand($i + 1);
            @queries[$i, $j] = @queries[$j, $i];
        }
    }
    @queries = @queries[0 .. 127] if $c->{scope} eq 'hot128' && @queries > 128;
    @queries = map { XS::APItest::Hash::shared_query_key($_) } @queries
        if $c->{query} eq 'interned';
    my $batches = int(($c->{operations} || 1000000) / @queries) || 1;
    my $operations = $batches * @queries;
    my $checksum = 0;
    my $run;
    if ($c->{operation} eq 'fetch') {
        $run = sub {
            my ($count) = @_;
            for (1 .. $count) { $checksum += length($hash{$_} // '') for @queries }
        };
    }
    elsif ($c->{operation} eq 'exists') {
        $run = sub {
            my ($count) = @_;
            for (1 .. $count) { $checksum += exists($hash{$_}) ? 1 : 0 for @queries }
        };
    }
    elsif ($c->{operation} eq 'query_only') {
        $run = sub {
            my ($count) = @_;
            for (1 .. $count) { $checksum += length($_) for @queries }
        };
    }
    else { die "unknown operation\n" }
    $run->(int(100000 / @queries) + 1);
    $checksum = 0;
    my $cpu = clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
    my $start = clock_gettime(CLOCK_MONOTONIC);
    $run->($batches);
    my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $start;
    my $cpu_elapsed = clock_gettime(CLOCK_PROCESS_CPUTIME_ID) - $cpu;
    my $unit = $c->{operation} eq 'fetch' ? 32 : $c->{operation} eq 'exists' ? 1 : 9;
    die "bad checksum\n" unless $checksum == $operations * $unit;
    die "hash content changed\n" unless keys(%hash) == $n;
    print encode_json({case => $c, operations => $operations,
        elapsed_seconds => $elapsed, cpu_seconds => $cpu_elapsed,
        ns_per_operation => $elapsed * 1e9 / $operations,
        checksum => $checksum, query_count => scalar(@queries),
        average_probes => $probe_total / $live,
        maximum_chain => $#histogram, storage => $storage}), "\n";
    exit;
}

require Dumbbench;
{
    package MeasuredHashCommand;
    our @ISA = ('Dumbbench::Instance');
    sub single_run {
        my ($self) = @_;
        local %ENV = %ENV;
        delete @ENV{qw(PERL5LIB PERL5OPT PERL_HASH_SEED_DEBUG)};
        $ENV{PERL_HASH_SEED} = $self->{hash_seed};
        $ENV{PERL_PERTURB_KEYS} = 0;
        $ENV{PERL_HASH_LINEAR_MAX} = $self->{variant}{linear_max};
        my @command = @{$self->{command}};
        open my $child, '-|', @command or die "start worker: $!";
        my $output = do { local $/; <$child> };
        close $child or die "worker failed: $?";
        my $row = JSON::PP::decode_json($output);
        $row->{variant} = $self->{variant}{name};
        $row->{sequence} = ++$self->{sequence};
        print {$self->{raw}} JSON::PP::encode_json($row), "\n";
        return $row->{ns_per_operation} / 1e9;
    }
}
my ($manifest_path, $output, $phase) = ('', '', 'focused');
GetOptions('manifest=s' => \$manifest_path, 'output=s' => \$output, 'phase=s' => \$phase)
    or die "invalid arguments\n";
die "--manifest and --output required\n" unless $manifest_path && $output;
open my $manifest_file, '<', $manifest_path or die $!;
my $manifest = decode_json(do { local $/; <$manifest_file> });
mkdir $output unless -d $output;
my @variants = grep { $_->{name} eq 'blead' || $_->{name} eq 'xperl-linear8-alloc4' }
               @{$manifest->{variants}};
my @sizes = $phase eq 'focused' ? (1000, 10000, 100000)
    : (16, 50, 100, 500, 1000, 5000, 10000, 20000, 40000, 60000, 80000, 100000, 200000, 500000, 1000000);
my @cases;
for my $n (@sizes) {
    for my $query ('plain', 'interned') {
        for my $mode (['fetch','all'], ['fetch','hot128'], ['query_only','all'], ['exists','all'], ['fetch','sequential']) {
            for my $variant (@variants) {
                push @cases, [{n => $n, query => $query, operation => $mode->[0],
                    scope => $mode->[1], operations => 1000000, query_seed => 610839776}, $variant];
            }
        }
    }
}
srand(20261113);
for (my $i = $#cases; $i > 0; --$i) { my $j = int rand($i + 1); @cases[$i,$j] = @cases[$j,$i] }
open my $raw, '>>', "$output/raw.jsonl" or die $!;
open my $summary, '>>', "$output/summary.jsonl" or die $!;
select((select($raw), $|=1)[0]); select((select($summary), $|=1)[0]); $|=1;
my $worker = File::Spec->rel2abs(__FILE__);
my $done = 0;
my $start = clock_gettime(CLOCK_MONOTONIC);
for my $pair (@cases) {
    my ($case, $variant) = @$pair;
    (my $lib = $variant->{perl}) =~ s{/perl$}{/lib};
    my @command = ($variant->{perl}, "-I$lib",
        "-I$variant->{compat}/blib/lib", "-I$variant->{compat}/blib/arch",
        '-MHashOptionsCompat', $worker, '--worker', encode_json($case));
    my $instance = MeasuredHashCommand->new(name => join('/', @$case{qw(n query operation scope)}, $variant->{name}),
        command => \@command, variant => $variant, raw => $raw,
        hash_seed => '0x13579bdf2468ace0', sequence => 0);
    my $bench = Dumbbench->new(initial_runs => 20, max_iterations => 60,
        target_rel_precision => 0.025, subtract_dry_run => 0, verbosity => 0);
    $bench->add_instances($instance);
    $bench->run;
    my $result = $instance->result;
    print {$summary} encode_json({case => $case, variant => $variant->{name},
        dumbbench_version => $Dumbbench::VERSION, robust_mean_ns => 1e9 * $result->raw_number,
        uncertainty_ns => 1e9 * $result->raw_error->[0], accepted_samples => $result->nsamples,
        total_samples => scalar(@{$instance->timings}),
        raw_seconds_per_op => $instance->timings}), "\n";
    printf "%d/%d cases complete; %.1fs elapsed; %s\n", ++$done, scalar(@cases),
        clock_gettime(CLOCK_MONOTONIC)-$start, $instance->name;
}
print "STUDY COMPLETE\n";
