#!/usr/bin/perl

use strict;
use warnings;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

my ($filename, $sets, $keys, $repetitions) = @ARGV;
die "usage: $0 KEYFILE SETS KEYS REPETITIONS\n"
    unless @ARGV == 4 && $sets =~ /^\d+$/ && $sets > 0
        && $keys =~ /^\d+$/ && $keys > 0
        && $repetitions =~ /^\d+$/ && $repetitions > 0;

open my $input, '<:raw', $filename or die "$filename: $!";
my @key_sets;
while (my $line = <$input>) {
    chomp $line;
    my @set = split /\t/, $line, -1;
    die "wrong key count\n" unless @set == $keys;
    push @key_sets, \@set;
}
close $input or die "$filename: $!";
die "wrong set count\n" unless @key_sets == $sets;

my $checksum = 0;
my $cpu_start = eval { clock_gettime(Time::HiRes::CLOCK_PROCESS_CPUTIME_ID()) };
my $start = clock_gettime(CLOCK_MONOTONIC);
for my $set (@key_sets) {
    for (1 .. $repetitions) {
        my %hash;
        $hash{$_} = 1 for @$set;
        $checksum += keys %hash;
    }
}
my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $start;
my $cpu_elapsed = defined $cpu_start
    ? clock_gettime(Time::HiRes::CLOCK_PROCESS_CPUTIME_ID()) - $cpu_start : undef;
my $constructions = $sets * $repetitions;
die "construction checksum mismatch\n" unless $checksum == $constructions * $keys;

# Loading output helpers after timing keeps their keys out of the measured
# string-table state. Every construction above owns and frees a fresh hash.
require JSON::PP;
require Digest::SHA;
open my $digest_input, '<:raw', $filename or die "$filename: $!";
my $digest = Digest::SHA->new(256)->addfile($digest_input)->hexdigest;
close $digest_input or die "$filename: $!";
print JSON::PP::encode_json({
    sets => 0 + $sets, keys => 0 + $keys, repetitions => 0 + $repetitions,
    constructions => $constructions, assignments => $constructions * $keys,
    checksum => $checksum, dataset_sha256 => $digest,
    elapsed_seconds => $elapsed, cpu_seconds => $cpu_elapsed,
    ns_per_construction => $elapsed * 1e9 / $constructions,
}), "\n";

__END__

=head1 NAME

bench-hash-random-insert - construct hashes from distinct random key sets

=head1 DESCRIPTION

The companion Python driver creates tab-separated sets of random ASCII
keys. This worker reads them before timing. Each set is used for the
requested repetitions, with a fresh lexical hash and constant value C<1>
for every construction. The timer includes hash creation, insertion,
destruction, loop overhead, and a scalar key-count check per hash.

The driver runs each measurement in a fresh Perl process with matched
keys and hash seeds. Output and dataset checksums are produced after timing.

=cut
