#!/usr/bin/perl

use v5.20;
use strict;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

# Keep each workload in its own process when profiling.  The subroutine that
# selects the workload runs only once, outside the hot loop.

sub direct_empty { }
sub direct_args  { }
sub unpack_args  { my ($a, $b, $c) = @_; return $a + $b + $c }
sub signature_args ($a, $b, $c)     { return $a + $b + $c }

my $coderef = \&direct_empty;

{
    package CallProfile::Object;
    sub new { bless [], shift }
    sub empty { }
}

my $object = CallProfile::Object->new;
my $generator;

my %workloads = (
    baseline => sub ($iterations) {
        for (my $i = 0; $i < $iterations; ++$i) { 1 }
    },
    empty => sub ($iterations) {
        for (my $i = 0; $i < $iterations; ++$i) { direct_empty() }
    },
    amp => sub ($iterations) {
        # Reuse this workload's @_ instead of constructing a new one for
        # direct_empty.  This isolates the CXp_HASARGS/@_ part of call setup.
        for (my $i = 0; $i < $iterations; ++$i) { &direct_empty }
    },
    args => sub ($iterations) {
        for (my $i = 0; $i < $iterations; ++$i) { direct_args(1, 2, 3) }
    },
    unpack => sub ($iterations) {
        my $sink;
        for (my $i = 0; $i < $iterations; ++$i) {
            $sink = unpack_args(1, 2, 3);
        }
        die "bad result" unless $sink == 6;
    },
    signature => sub ($iterations) {
        my $sink;
        for (my $i = 0; $i < $iterations; ++$i) {
            $sink = signature_args(1, 2, 3);
        }
        die "bad result" unless $sink == 6;
    },
    coderef => sub ($iterations) {
        for (my $i = 0; $i < $iterations; ++$i) { $coderef->() }
    },
    method => sub ($iterations) {
        for (my $i = 0; $i < $iterations; ++$i) { $object->empty() }
    },
    generator => sub ($iterations) {
        $generator //= eval q{
            use feature 'generator';
            gen { while (1) { yield 1 } }
        };
        die $@ if $@;
        my $sink;
        for (my $i = 0; $i < $iterations; ++$i) {
            $sink = $generator->();
        }
        die "bad result" unless $sink == 1;
    },
);

my $workload   = shift // 'empty';
my $iterations = shift // 20_000_000;

die "usage: $0 [", join('|', sort keys %workloads), "] [iterations]\n"
    unless exists $workloads{$workload};
die "iterations must be a positive integer\n"
    unless $iterations =~ /\A[1-9][0-9_]*\z/;
$iterations =~ tr/_//d;

$workloads{$workload}->($iterations);
