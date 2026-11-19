#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use BenchUtils qw(absolute read_text write_text read_json write_json json sha256 run
    rng shuffle median minimum maximum pin_cpu platform_info);
use Getopt::Long qw(GetOptions);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Time::HiRes qw(time);
use POSIX ();
use Config;
use Encode qw(encode);

my @seed_text = qw(13579bdf2468ace0 fedcba9876543210 0123456789abcdef);
my @seeds;
{
    no warnings 'portable';
    @seeds = map { hex($_) } @seed_text;
}
my @sizes = (0 .. 10, 16, 32, 64, 256, 4096, 65536, 131072);
my @workloads = qw(insert assign presized hit random-hit miss mixed constant-hit
    replace delete churn transitions keys values each);
my %options = (profile => 'quick', operations => 200000);
my $help;
GetOptions(\%options, 'manifest=s', 'output=s', 'profile=s', 'trials=i',
    'operations=i', 'cpu=i', 'reuse=s', 'variants=s', 'sizes=s',
    'key-lengths=s', 'workloads=s', 'smoke', 'help' => \$help) or die "Invalid options\n";
if ($help) {
    print "Usage: $0 --manifest FILE --output DIR --cpu N [--profile quick|full] [--reuse DIR]\n";
    exit;
}
die "Unexpected arguments: @ARGV\n" if @ARGV;
die "--manifest, --output and --cpu are required\n"
    unless $options{manifest} && $options{output} && defined $options{cpu};
die "Invalid profile\n" unless $options{profile} =~ /\A(?:quick|full)\z/;
$options{trials} //= $options{profile} eq 'quick' ? 3 : 5;
die "Trials and operations must be positive\n" if $options{trials} < 1 || $options{operations} < 1;
my $manifest = read_json($options{manifest});
my @variants = @{$manifest->{variants}};
my %names;
die "Variant names must be unique\n" if grep { $names{$_->{name}}++ } @variants;
my $baseline = $manifest->{baseline};
die "Baseline must name a variant\n" unless defined($baseline) && $names{$baseline};
if (defined $options{variants}) {
    my %wanted = map { $_ => 1 } split /,/, $options{variants};
    die "Unknown variant\n" if grep { !$names{$_} } keys %wanted;
    die "--variants must include the baseline\n" unless $wanted{$baseline};
    @variants = grep { $wanted{$_->{name}} } @variants;
}
elsif ($options{profile} eq 'quick' && !$options{smoke}) {
    @variants = grep { quick_variant($_, $baseline) } @variants;
}
$manifest = {%$manifest, variants => \@variants};
pin_cpu($options{cpu});
my $worker = "$FindBin::Bin/bench-hash-options.pl";
my $out = absolute($options{output});
make_path($out);
my %filter_sizes = number_filter($options{sizes}, 0);
my %filter_lengths = number_filter($options{'key-lengths'}, 1);
my %filter_workloads = map { $_ => 1 } split /,/, $options{workloads} // '';
my @cases = cases($options{operations}, keys %filter_sizes);
if ($options{smoke}) {
    @cases = map { +{%$_, operations => 1000} }
        grep { ($_->{n} == 0 || $_->{n} == 2 || $_->{n} == 4) && $_->{key_length} == 9 } @cases;
}
elsif ($options{profile} eq 'quick') {
    @cases = grep { quick_case($_) } @cases;
}
@cases = grep { $filter_sizes{$_->{n}} } @cases if defined $options{sizes};
@cases = grep { $filter_lengths{$_->{key_length}} } @cases if defined $options{'key-lengths'};
@cases = grep { $filter_workloads{$_->{workload}} } @cases if defined $options{workloads};
die "No cases match the requested filters\n" unless @cases;
my $platform = platform_info();
my @cpu_identity = -r '/proc/cpuinfo' ? grep {
    /\A(?:model name|vendor_id|cpu family|model\t|stepping)/
} split(/\n/, read_text('/proc/cpuinfo')) : ();
my $legacy_platform;
if ($^O eq 'linux') {
    my ($system, undef, $release, undef, $machine) = POSIX::uname();
    my $libc = run(['getconf', 'GNU_LIBC_VERSION'], allow_failure => 1);
    my ($version) = $libc->{stdout} =~ /\bglibc\s+(\S+)/;
    $version //= $Config{gnulibc_version};
    $legacy_platform = "$system-$release-$machine-with-glibc$version" if $version;
}
my %metadata = (manifest => $manifest, worker_sha256 => sha256($worker),
    driver_sha256 => sha256(__FILE__), helper_sha256 => sha256("$FindBin::Bin/BenchUtils.pm"),
    cases => \@cases, trials => $options{trials}, seeds => \@seeds, cpu => $options{cpu},
    platform => $platform->{kernel}, machine => $platform->{machine},
    cpu_info => \@cpu_identity, driver_prng => $platform->{driver_prng},
    legacy_platform => $legacy_platform,
    binaries => {map { $_->{name} => sha256($_->{perl}) } @variants},
    profile => $options{profile}, compat => {});
for my $variant (@variants) {
    next unless $variant->{compat};
    $metadata{compat}{$variant->{name}} = {map {
        $_ => sha256("$variant->{compat}/$_")
    } ('HashOptionsCompat.xs', 'blib/lib/HashOptionsCompat.pm',
        'blib/arch/auto/HashOptionsCompat/HashOptionsCompat.so')};
}
my @reused;
if ($options{reuse}) {
    my $source = absolute($options{reuse});
    die "--reuse must name a different result directory\n" if $source eq $out;
    @reused = reusable_rows($source, \%metadata);
    $metadata{reuse} = {path => $source, samples => scalar @reused,
        metadata_sha256 => sha256("$source/metadata.json"), raw_sha256 => sha256("$source/raw.jsonl")};
}
if (-e "$out/metadata.json") {
    die "Output directory belongs to a different experiment\n"
        unless json(read_json("$out/metadata.json")) eq json(\%metadata);
}
else {
    write_json("$out/metadata.json", \%metadata);
}
my @rows = -e "$out/raw.jsonl" ? read_rows("$out/raw.jsonl") : ();
my %completed = map { identity($_) => 1 } @rows;
my @additions;
for my $row (@reused) {
    next if $completed{identity($row)}++;
    push @rows, $row;
    push @additions, $row;
}
my %signatures;
for my $row (@rows) {
    my $key = "$row->{trial}:$row->{case}{id}";
    $signatures{$key} //= $row->{result_sha256};
    die "Reused results differ between variants: $key\n"
        unless $signatures{$key} eq $row->{result_sha256};
}
my @schedule;
for my $trial (0 .. $options{trials} - 1) {
    push @schedule, map { [$trial, $_] } @cases;
}
@schedule = shuffle(rng(20261113), @schedule);
my $state = rng(20261114);
my $total = @schedule * @variants;
my $start = time;
printf "%d cases, %d variants, %d trials: %d workers\n", scalar(@cases), scalar(@variants), $options{trials}, $total;
open my $raw, '>>:raw', "$out/raw.jsonl" or die "$out/raw.jsonl: $!\n";
$raw->autoflush(1);
print {$raw} json($_), "\n" for @additions;
summarize(\@rows, $out, $baseline) if @additions;
for my $job (@schedule) {
    my ($trial, $template) = @$job;
    for my $variant (shuffle($state, @variants)) {
        my $id = join ':', $trial, $template->{id}, $variant->{name};
        next if $completed{$id};
        my %case = (%$template,
            query_seed => hex(substr($seed_text[$trial % 3], -8)) & 0x7fffffff,
            expect_width => $variant->{width} eq '32' ? 4 : 'adaptive',
            expect_linear_limit => $variant->{linear_max}, expect_min_alloc => $variant->{min_alloc});
        my $seed = '0x'.$seed_text[$trial % 3];
        my $perl = absolute($variant->{perl});
        my @command = ($perl, '-Ilib');
        if ($variant->{compat}) {
            my $compat = absolute($variant->{compat});
            push @command, "-I$compat/blib/lib", "-I$compat/blib/arch", '-MHashOptionsCompat';
        }
        push @command, $worker, json(\%case);
        my $result = run(\@command, cwd => dirname($perl),
            env => {PERL_HASH_LINEAR_MAX => $variant->{linear_max}, PERL_HASH_SEED => $seed, PERL_PERTURB_KEYS => '0'},
            unset => [qw(PERL5OPT PERL5LIB PERL_HASH_SEED_DEBUG)]);
        die "Worker $id wrote stderr: $result->{stderr}" if length $result->{stderr};
        my $row = JSON::PP::decode_json($result->{stdout});
        my $key = "$trial:$template->{id}";
        $signatures{$key} //= $row->{result_sha256};
        die "Result differs between variants: $id\n" unless $signatures{$key} eq $row->{result_sha256};
        @$row{qw(variant trial hash_seed cpu)} = ($variant->{name}, $trial, $seed, $options{cpu});
        push @rows, $row;
        print {$raw} json($row), "\n" or die "Cannot write sample: $!\n";
        $completed{$id} = 1;
    }
    if (@rows % 55 < @variants) {
        summarize(\@rows, $out, $baseline);
        printf "%d/%d complete; %.1fs elapsed\n", scalar(keys %completed), $total, time - $start;
    }
}
close $raw or die "Cannot close samples: $!\n";
summarize(\@rows, $out, $baseline);
print "Complete: $out/summary.csv\n";

sub number_filter {
    my ($text, $minimum) = @_;
    return () unless defined $text;
    my %values;
    for my $number (split /,/, $text) {
        die "Invalid numeric filter\n" unless $number =~ /\A\d+\z/ && $number >= $minimum;
        $values{0 + $number} = 1;
    }
    die "Empty numeric filter\n" unless %values;
    return %values;
}

sub cases {
    my ($operations, @extra_sizes) = @_;
    my @base;
    my $add = sub {
        my ($workload, $n, $length, %extra) = @_;
        push @base, {workload => $workload, n => 0 + $n, key_length => $length,
            operations => $operations, %extra};
    };
    for my $n (@sizes) { $add->($_, $n, 9) for @workloads }
    for my $n (1, 4, 8, 64, 4096) { $add->($_, $n, 128) for @workloads }
    for my $n (4, 8, 64, 4096, 65536) { $add->($_, $n, 9) for qw(keys-holes values-holes each-holes) }
    $add->('many-live', $_, 9) for (0, 1, 2, 3, 4, 5, 8, 9, 64);
    for my $n (8, 64) { $add->($_, $n, 9, distribution => 'collision') for qw(hit miss delete churn) }
    $add->('random-hit', 64, 9, reserve => $_) for (255, 256, 65535, 65536);
    my %known = map { $_ => 1 } @sizes;
    for my $n (sort { $a <=> $b } @extra_sizes) {
        $add->($_, $n, 9) for $known{$n} ? () : @workloads;
    }
    my @expanded;
    for my $case (@base) {
        for my $stored (qw(interned private)) {
            my @queries = $case->{workload} =~ /\A(?:hit|random-hit|miss|mixed)\z/
                ? qw(plain interned) : $case->{workload} eq 'constant-hit' ? 'constant' : 'none';
            push @expanded, map { +{%$case, stored_keys => $stored, query_keys => $_} } @queries;
        }
    }
    $expanded[$_]{id} = $_ for 0 .. $#expanded;
    return @expanded;
}

sub quick_case {
    my ($case) = @_;
    return 0 if $case->{reserve} || $case->{distribution};
    my ($work, $n) = @$case{qw(workload n)};
    return $work eq 'random-hit' && $n == 8 if $case->{key_length} == 128;
    return ($work eq 'random-hit' && grep { $_ == $n } (1, 2, 4, 5, 8, 9, 256, 65536))
        || ($work eq 'insert' && grep { $_ == $n } (2, 3, 4, 8, 9))
        || (($work eq 'miss' || $work eq 'churn') && ($n == 4 || $n == 8));
}

sub quick_variant {
    my ($variant, $baseline) = @_;
    return 1 if $variant->{name} eq $baseline;
    my $policy = join ':', @$variant{qw(width linear_max min_alloc)};
    return scalar grep { $policy eq $_ } qw(adaptive:0:2 adaptive:4:2 adaptive:8:2 32:4:2 adaptive:4:4);
}

sub read_rows {
    my ($path) = @_;
    return map { JSON::PP::decode_json($_) } grep { length } split /\n/, read_text($path);
}

sub identity { return join ':', $_[0]{trial}, $_[0]{case}{id}, $_[0]{variant} }

sub reusable_rows {
    my ($source, $metadata) = @_;
    my $old = read_json("$source/metadata.json");
    for my $field (qw(worker_sha256 cpu seeds machine cpu_info)) {
        die "Cannot reuse samples with different $field\n" unless json($old->{$field}) eq json($metadata->{$field});
    }
    # Legacy runs recorded Python's platform spelling. Match its Linux
    # kernel, architecture and runtime libc identity, not merely the CPU model.
    my $platform = $old->{driver_prng} ? $metadata->{platform} : $metadata->{legacy_platform};
    die "Cannot reuse samples with different platform\n"
        unless defined($platform) && $old->{platform} eq $platform;
    my %variants = map { $_->{name} => $_ } @{$old->{manifest}{variants}};
    for my $variant (@{$metadata->{manifest}{variants}}) {
        my $name = $variant->{name};
        next unless exists $variants{$name};
        die "Cannot reuse samples from a different build: $name\n"
            if json($variants{$name}) ne json($variant)
                || $old->{binaries}{$name} ne $metadata->{binaries}{$name};
        die "Cannot reuse different benchmark helpers: $name\n"
            unless json($old->{compat}{$name}) eq json($metadata->{compat}{$name});
    }
    my %old_cases = map { $_->{id} => $_ } @{$old->{cases}};
    my %wanted = map { $_->{id} => $_ } @{$metadata->{cases}};
    for my $id (keys %wanted) {
        die "Cannot reuse a different workload: $id\n"
            if $old_cases{$id} && json($old_cases{$id}) ne json($wanted{$id});
    }
    return map { +{%$_, reused_from => $source} }
        grep { $wanted{$_->{case}{id}} && exists($metadata->{binaries}{$_->{variant}})
            && $_->{trial} < $metadata->{trials} } read_rows("$source/raw.jsonl");
}

sub summarize {
    my ($rows, $out, $baseline) = @_;
    my (%grouped, %references);
    for my $row (@$rows) {
        push @{$grouped{$row->{case}{id}}{$row->{variant}}}, $row;
        $references{"$row->{case}{id}:$row->{trial}"} = $row if $row->{variant} eq $baseline;
    }
    my @summary;
    for my $id (sort { $a <=> $b } keys %grouped) {
        for my $variant (sort keys %{$grouped{$id}}) {
            my $samples = $grouped{$id}{$variant};
            my (@times, @ratios);
            for my $sample (@$samples) {
                push @times, $sample->{ns_per_operation};
                my $reference = $references{"$id:$sample->{trial}"};
                push @ratios, $reference->{ns_per_operation} / $sample->{ns_per_operation} if $reference;
            }
            my $case = $samples->[0]{case};
            my $before = $samples->[0]{before};
            push @summary, {
                case_id => $id, variant => $variant,
                (map { $_ => $case->{$_} } qw(workload n key_length stored_keys query_keys)),
                distribution => $case->{distribution} // 'ordinary', reserve => $case->{reserve} // 0,
                samples => scalar @$samples, ns_median => median(@times), ns_min => minimum(@times), ns_max => maximum(@times),
                speedup_median => median(@ratios), speedup_min => minimum(@ratios), speedup_max => maximum(@ratios),
                linear => $before->{linear}, width => $before->{index_width},
                (map { $_ => $before->{$_} } qw(entry_capacity table_bytes allocator_bytes)),
                retained_rss_kb_median => median(map { $_->{case}{retained_rss_kb} // $_->{rss_kb}{VmRSS} // 0 } @$samples),
            };
        }
    }
    return unless @summary;
    my @columns = qw(case_id variant workload n key_length stored_keys query_keys distribution reserve
        samples ns_median ns_min ns_max speedup_median speedup_min speedup_max linear width
        entry_capacity table_bytes allocator_bytes retained_rss_kb_median);
    my $csv = BenchUtils::csv_line(@columns);
    $csv .= BenchUtils::csv_line(@$_{@columns}) for @summary;
    write_text("$out/summary.csv.tmp", encode('UTF-8', $csv));
    rename "$out/summary.csv.tmp", "$out/summary.csv" or die "Cannot replace summary: $!\n";
}
