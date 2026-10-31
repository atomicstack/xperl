#!./perl

BEGIN {
    chdir 't' if -d 't';
    @INC = '../lib';
    require './test.pl';
}
use Config;

skip_all_without_config('d_fork');
skip_all("NO_PERL_HASH_ENV or NO_PERL_HASH_SEED_DEBUG set")
    if $Config{ccflags} =~ /-DNO_PERL_HASH_ENV\b/
    || $Config{ccflags} =~ /-DNO_PERL_HASH_SEED_DEBUG\b/;
use strict;
use warnings;

sub run_with_env {
    my ($env, $program) = @_;
    my %runenv = (%$env, PERL_HASH_SEED_DEBUG => 1);
    return runperl_and_capture(\%runenv, ['-e', $program]);
}

sub seed_from_debug {
    my ($err) = @_;
    my ($seed) = $err =~ /HASH_SEED = (0x[0-9a-f]+)/;
    return $seed;
}

my ($seed_out, $seed_err) = run_with_env({}, '1');
my $seed = seed_from_debug($seed_err);
like($seed_err, qr/HASH_FUNCTION = \S+ HASH_SEED = 0x[0-9a-f]+/,
     'debug output reports the hash function and selected seed');
ok(defined $seed, 'selected hash seed can be captured from debug output');
unless (defined $seed) {
    done_testing();
    exit 0;
}

my $iteration =
    'my %h; $h{$_} = $_ for qw(alpha beta gamma delta epsilon); '
  . 'print join ",", keys %h;';
my ($same_out, $same_err) = run_with_env({PERL_HASH_SEED => $seed}, $iteration);
is(seed_from_debug($same_err), $seed,
   'PERL_HASH_SEED reuses the captured seed');

my $other_seed = $seed;
substr($other_seed, -1) =~ tr/0-9a-f/1-9a-f0/;
my ($other_out, $other_err) =
    run_with_env({PERL_HASH_SEED => $other_seed}, $iteration);
is(seed_from_debug($other_err), $other_seed,
   'a changed PERL_HASH_SEED is used');
is($same_out, $other_out,
   'ordinary hash iteration order is independent of the hash seed');

done_testing();
