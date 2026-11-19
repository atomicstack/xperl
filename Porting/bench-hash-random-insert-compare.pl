#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use BenchUtils qw(absolute sha256 perl_info source_info platform_info write_text write_json json run rng random32 shuffle hash_seed median value_range);
use Getopt::Long qw(GetOptions);
use File::Basename qw(dirname);
use JSON::PP qw(decode_json);

my %o = (baseline => 'blead', sets => 100, keys => 16, repetitions => 1000,
    'key-length' => 27, trials => 31, seed => 20261118, reserve => 0);
my @entries;
GetOptions(\%o, 'build=s@' => \@entries, 'baseline=s', 'output=s', 'sets=i',
    'keys=i', 'repetitions=i', 'key-length=i', 'trials=i', 'seed=i', 'reserve=i',
    'linear-max=i', 'help') or die "Invalid options\n";
if ($o{help}) {
    print "Usage: $0 --build NAME=PERL --output DIR [--baseline NAME] [--trials N]\n";
    exit;
}
die "Unexpected arguments: @ARGV\n" if @ARGV;
die "--build and --output are required\n" unless @entries && $o{output};
die "Counts must be positive and reserve nonnegative\n"
    if grep({ $o{$_} < 1 } qw(sets keys repetitions key-length trials)) || $o{reserve} < 0;
die "Invalid --linear-max\n" if defined($o{'linear-max'}) && $o{'linear-max'} !~ /\A(?:0|2|4|8)\z/;
my (%builds, @names);
for (@entries) {
    my ($name, $path) = split /=/, $_, 2;
    die "Builds must use distinct NAME=PERL names\n" unless defined($path) && length($name) && !exists($builds{$name});
    $builds{$name} = absolute($path);
    die "Not executable: $path\n" unless -x $builds{$name};
    push @names, $name;
}
die "Unknown baseline\n" unless exists $builds{$o{baseline}};
die "Key space too small\n" if $o{sets} * $o{keys} > 62 ** $o{'key-length'};
my $out = absolute($o{output});
my $worker = "$FindBin::Bin/bench-hash-random-insert.pl";
my %arguments = (%o, build => \@entries, output => $out,
    key_length => $o{'key-length'}, linear_max => $o{'linear-max'});
delete @arguments{qw(key-length linear-max)};
write_json("$out/metadata.json", {arguments => \%arguments, worker => $worker,
    worker_sha256 => sha256($worker), driver_sha256 => sha256(__FILE__),
    helper_sha256 => sha256("$FindBin::Bin/BenchUtils.pm"), %{platform_info()},
    cpu_affinity => platform_info()->{allowed_cpus},
    method => 'Each trial uses a new key corpus and a fresh process per build. Timed regions include construction, destruction, loops, and scalar key counts.',
    statistical_unit => 'one process batch; repeated constructions are not independent samples',
    builds => {map { $_ => {perl => $builds{$_}, sha256 => sha256($builds{$_}),
        %{source_info(dirname($builds{$_}))}, config => perl_info($builds{$_})} } @names}});
my $state = rng($o{seed});
my @alphabet = ('a'..'z', 'A'..'Z', '0'..'9');
open my $raw, '>', "$out/raw.jsonl" or die $!;
$raw->autoflush(1);
my @rows;
for my $trial (1..$o{trials}) {
    my (%seen, @sets);
    for (1..$o{sets}) {
        my @keys;
        while (@keys < $o{keys}) {
            my $key = join '', map { $alphabet[random32($state) % @alphabet] } 1..$o{'key-length'};
            push @keys, $key unless $seen{$key}++;
        }
        push @sets, join "\t", @keys;
    }
    my $dataset = sprintf '%s/datasets/%03d.tsv', $out, $trial;
    write_text($dataset, join("\n", @sets)."\n");
    my $digest = sha256($dataset);
    my $seed = hash_seed($state);
    my $rank = 0;
    for my $name (shuffle($state, @names)) {
        my %env = (PERL_HASH_SEED => $seed);
        $env{PERL_HASH_LINEAR_MAX} = $o{'linear-max'} if $name ne $o{baseline} && defined $o{'linear-max'};
        my $perl = $builds{$name};
        my $result = run([$perl, '-I'.dirname($perl).'/lib', $worker, $dataset,
            @o{qw(sets keys repetitions reserve)}], env => \%env,
            unset => [qw(PERL5LIB PERL5OPT PERL_HASH_LINEAR_MAX PERL_HASH_SEED_DEBUG PERL_PERTURB_KEYS)]);
        my $row = decode_json($result->{stdout});
        die "Worker result does not match dataset\n" unless $row->{checksum} == $o{sets}*$o{keys}*$o{repetitions} && $row->{dataset_sha256} eq $digest;
        @$row{qw(trial build order hash_seed dataset)} = ($trial, $name, $rank++, $seed, $dataset);
        print {$raw} json($row), "\n";
        push @rows, $row;
    }
    print "$trial/$o{trials} paired trial complete\n";
}
close $raw or die $!;
my %base = map { $_->{trial} => $_ } grep { $_->{build} eq $o{baseline} } @rows;
my @summary;
for my $name (@names) {
    my @selected = grep { $_->{build} eq $name } @rows;
    my @ratios = map { $_->{elapsed_seconds}/$base{$_->{trial}}{elapsed_seconds} } @selected;
    my $bootstrap = rng($o{seed});
    my @samples = sort { $a <=> $b } map { median(map { $ratios[random32($bootstrap) % @ratios] } @ratios) } 1..10000;
    push @summary, {build => $name, trials => scalar @selected,
        median_ns_per_construction => median(map { $_->{ns_per_construction} } @selected),
        paired_time_ratio_median => median(@ratios),
        paired_time_ratio_95_percent_interval => [@samples[249,9749]],
        paired_time_ratio_range => value_range(@ratios)};
}
write_json("$out/summary.json", \@summary);
print json(\@summary), "\n";
