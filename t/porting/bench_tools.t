#!/usr/bin/env perl

BEGIN {
    chdir '..' if -f 'test.pl';
    @INC = ('./lib');
    require './t/test.pl';
}

use strict;
use warnings;
use lib 'Porting';
use BenchUtils qw(run json write_json read_json csv_line csv_rows median parse_sizes
    rng random32 shuffle source_info source_patch absolute);
use File::Temp qw(tempdir);

my $temporary = tempdir(CLEANUP => 1);
my @perl = (absolute($^X), '-I'.absolute('lib'), '-e');
my $result = run([@perl, 'print "x" x 140000; print STDERR "y" x 150000']);
is(length $result->{stdout}, 140000, 'capture stdout larger than a pipe buffer');
is(length $result->{stderr}, 150000, 'capture stderr without blocking stdout');
is($result->{status}, 0, 'successful child status survives capture');
$result = run([@perl, 'print "partial"; print STDERR "failure"; exit 7'], allow_failure => 1);
is($result->{status} >> 8, 7, 'preserve a failed child exit code');
is($result->{stdout}, 'partial', 'preserve partial output on failure');
is($result->{stderr}, 'failure', 'preserve failed child diagnostics');
my $ok = eval { run([@perl, 'exit 7']); 1 };
ok(!$ok && $@ =~ /Command failed/, 'failed commands throw unless explicitly allowed');
$ok = eval { run([@perl, 'sleep 10'], timeout => 0.05); 1 };
ok(!$ok && $@ =~ /timed out/, 'deadline terminates a stalled worker');
$result = run(["$temporary/no-such-command"], allow_failure => 1);
ok($result->{status} && length($result->{stderr}), 'missing commands have a failure result');
{
    local $ENV{PATH} = $temporary;
    my $source = source_info($temporary);
    ok(!defined($source->{revision}), 'source exports work without Git installed');
    my $patch = source_patch($temporary, "$temporary/unavailable.diff");
    ok(!defined($patch->{path}), 'missing Git does not invent a source patch');
}
my @fields = ('', 'plain', 'a,b', '"quoted"', "two\nlines", "CR\rLF", '');
my @rows = csv_rows(csv_line(@fields));
ok(@rows == 1 && eq_array($rows[0], \@fields), 'CSV round-trips empty, quoted and multiline fields');
@rows = csv_rows("\"a\"\r\n");
ok(@rows == 1 && eq_array($rows[0], ['a']), 'CSV accepts CRLF record separators');
$ok = eval { csv_rows('"unterminated'); 1 };
ok(!$ok, 'malformed CSV is rejected');
is(median(8, 1, 3, 4), 3.5, 'even-sized median averages the middle values');
ok(eq_array([parse_sizes('0-2,4..5')], [0, 1, 2, 4, 5]), 'size ranges retain their order');
$ok = eval { parse_sizes('1,01'); 1 };
ok(!$ok, 'numeric duplicates in size lists are rejected');
my $first = rng(123);
my $second = rng(123);
ok(eq_array([map { random32($first) } 1..20], [map { random32($second) } 1..20]), 'driver PRNG is reproducible');
ok(eq_array([sort {$a <=> $b} shuffle(rng(9), 1..20)], [1..20]), 'shuffle preserves every input element');
write_json("$temporary/data.json", {value => 'text'});
ok(eq_hash(read_json("$temporary/data.json"), {value => 'text'}), 'metadata round-trips');
ok(json({value => 'text'}) !~ /\n/, 'pretty metadata output does not change JSONL encoding');

done_testing();
