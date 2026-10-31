#!./perl

use strict;
use warnings;
use Config;
use FindBin;
use Test::More;
use Hash::Util qw(hash_storage_info bucket_info bucket_array);

{
    local $ENV{PERL_HASH_LINEAR_MAX} = 2;
    my $script = <<'PERL';
use Hash::Util qw(hash_storage_info);
my %hash;
for my $state (0 .. 2) {
    my $info = hash_storage_info(\%hash);
    print join(':', @{$info}{qw(linear entry_capacity entry_bytes
                                arena_backed arena_slot_size requested_bytes
                                allocator_bytes he_size)}), "\n";
    $hash{one} = 1 if $state == 0;
    $hash{two} = 2 if $state == 1;
}
if (eval { require Config; $Config::Config{useithreads} }) {
    require threads;
    my %single = (one => 1);
    my $thread = threads->create(sub {
        my ($copy) = @_;
        my $before = hash_storage_info($copy);
        die "thread clone lost arena singleton form\n"
            unless $before->{linear} && $before->{arena_backed}
                && $before->{arena_slot_size} == $before->{he_size};
        $copy->{two} = 2;
        $copy->{three} = 3;
        my $after = hash_storage_info($copy);
        die "thread clone failed to promote from singleton\n"
            if $after->{linear} || !$after->{index_capacity}
                || $copy->{one} != 1 || $copy->{three} != 3;
        return 1;
    }, \%single);
    die "thread singleton clone failed\n" unless $thread->join == 1;
    die "thread singleton clone changed its source\n"
        unless keys(%single) == 1 && $single{one} == 1;
}
PERL
    open my $child, '-|', $^X, "-I$FindBin::Bin/../../../lib", '-e', $script
        or die "could not start linear hash storage probe: $!";
    my @state = map { [ split /:/ ] } <$child>;
    close $child;
    my $status = $?;
    is($status, 0, 'linear storage probe exits successfully');
    my $empty_has_storage = grep { $_ } @{$state[0]}[1 .. 6];
    ok(($state[0][0] == 0 || $state[0][0] == 1)
           && !$empty_has_storage,
       'empty hash allocates no entry storage');
    ok($state[1][0] && $state[1][1] == 1
           && $state[1][2] == $state[1][4]
           && $state[1][4] == $state[1][7]
           && $state[1][3] && $state[1][5] == $state[1][4]
           && !$state[1][6],
       'singleton linear hash reports its arena slot stride');
    is_deeply([@{$state[2]}[0 .. 5]],
              [1, 2, 2 * $state[2][7], 0, 0, 2 * $state[2][7]],
              'two-entry linear hash uses compact heap entries');
    ok(!$state[2][6] || $state[2][6] >= $state[2][5],
       'allocator reports usable bytes for a heap entry vector');
}

sub clone_storage_state {
    my ($table, $deleted, $present) = @_;
    return threads->create(sub {
        my ($copy, $deleted_key, $present_key) = @_;
        my $copy_info = hash_storage_info($copy);
        return [
            $copy_info->{index_width},
            $copy_info->{index_deleted},
            $copy_info->{free_list_length},
            exists($copy->{$deleted_key}) ? 1 : 0,
            exists($copy->{$present_key}) ? 1 : 0,
        ];
    }, $table, $deleted, $present)->join;
}

my %hash;
my $info = hash_storage_info(\%hash);
ok($info->{open_addressed}, 'ordinary hash uses open addressing');
is($info->{requested_bytes}, 0, 'empty hash has no storage allocation');
is($info->{free_list_length}, 0, 'empty hash has no recycled entries');
is($info->{index_width}, 0, 'an unallocated index has no entry-index width');
is($info->{hash_bytes}, 0, 'an unallocated index has no cached-hash storage');
is($info->{entry_index_bytes}, 0,
   'an unallocated index has no encoded entry-index storage');

$hash{"key:$_"} = $_ for 1 .. 64;
delete $hash{"key:$_"} for 1 .. 20;
$info = hash_storage_info(\%hash);
is($info->{free_list_length}, 20, 'free list contains every deleted entry');
is($info->{entry_used}, 64, 'deletion retains the entry high-water mark');
is($info->{index_deleted}, $info->{tombstones}, 'maintained tombstones match slot scan');
is($info->{index_empty} + $info->{index_deleted} + $info->{live},
   $info->{index_capacity}, 'slot states account for the whole index');
is($info->{entry_used} + $info->{entry_spare}, $info->{entry_capacity},
   'used and spare positions account for entry capacity');
is($info->{index_bytes} + $info->{entry_bytes}, $info->{requested_bytes},
   'requested bytes account for both allocations');
is($info->{metadata_bytes} + $info->{entry_index_bytes}, $info->{index_bytes},
   'index bytes account for metadata and encoded indices');
is($info->{hash_bytes}, 0,
   'index slots contain no separate cached-hash array');
is($info->{entry_index_bytes},
   $info->{index_capacity} * $info->{index_width},
   'encoded indices use the selected width per index slot');
is($info->{slot_size}, $info->{index_width},
   'effective slot size is the encoded entry-index width');
cmp_ok($info->{probe_total}, '>=', $info->{probe_max},
       'total displacement includes the largest displacement');

my ($keys, $slots, $used, @lengths) = bucket_info(\%hash);
is($keys, 44, 'bucket summary reports remaining keys');
is($slots, $info->{index_capacity}, 'bucket summary uses index capacity');
is($used, 44, 'each live index slot holds one key');
is($lengths[0], $info->{index_empty} + $info->{index_deleted},
   'bucket summary combines vacant and deleted slots');
my @physical_keys = map { ref($_) ? @$_ : () } @{bucket_array(\%hash)};
is_deeply([sort @physical_keys], [sort keys %hash],
          'physical index view contains exactly the live keys');

my $current = each %hash;
delete $hash{$current};
$info = hash_storage_info(\%hash);
is($info->{free_list_length}, 20, 'deleted iterator entry is retained until reset');
keys %hash;
is(hash_storage_info(\%hash)->{free_list_length}, 21,
   'iterator reset releases the deleted entry');

$hash{"replacement:$_"} = $_ for 1 .. 21;
$info = hash_storage_info(\%hash);
is($info->{free_list_length}, 0, 'insertion consumes the recycled entries');
is($info->{entry_used}, 64, 'recycling avoids appending entry positions');

my %narrow;
my $narrow_next = 0;
my $narrow_info = hash_storage_info(\%narrow);
while ($narrow_info->{index_capacity} < 128) {
    my $key = "narrow:$narrow_next";
    $narrow{$key} = $narrow_next++;
    $narrow_info = hash_storage_info(\%narrow);
}
is($narrow_info->{index_capacity}, 128,
   'one-byte index reaches the 128-slot boundary');
is($narrow_info->{index_width}, 1,
   '128 index slots use one-byte entry indices');
delete $narrow{'narrow:0'};
is(hash_storage_info(\%narrow)->{index_deleted}, 1,
   'a tombstone exists before the one-to-two-byte transition');
SKIP: {
    skip 'Perl not compiled with useithreads', 4
        unless $Config{useithreads};
    require threads;
    my $snapshot = clone_storage_state(\%narrow, 'narrow:0', 'narrow:1');
    is($snapshot->[0], 1, 'thread clone preserves the one-byte index width');
    is($snapshot->[1], 1, 'thread clone preserves one-byte-index tombstones');
    is($snapshot->[2], 1, 'thread clone preserves one-byte free entries');
    ok(!$snapshot->[3] && $snapshot->[4],
       'thread clone preserves one-byte deleted and live lookups');
}
while ($narrow_info->{index_capacity} < 256) {
    my $key = "narrow:$narrow_next";
    $narrow{$key} = $narrow_next++;
    $narrow_info = hash_storage_info(\%narrow);
}
is($narrow_info->{index_capacity}, 256,
   'index growth crosses from 128 to 256 slots');
is($narrow_info->{index_width}, 2,
   '256 index slots use two-byte entry indices');
ok(exists $narrow{'narrow:1'} && exists $narrow{"narrow:" . ($narrow_next - 1)},
   'entries survive the one-to-two-byte transition');
delete $narrow{'narrow:1'};
$narrow_info = hash_storage_info(\%narrow);
is($narrow_info->{index_deleted}, 1,
   'two-byte indices retain tombstones after transition');
SKIP: {
    skip 'Perl not compiled with useithreads', 4
        unless $Config{useithreads};
    require threads;
    my $snapshot = clone_storage_state(\%narrow, 'narrow:1', 'narrow:2');
    is($snapshot->[0], 2, 'thread clone preserves the two-byte index width');
    is($snapshot->[1], $narrow_info->{index_deleted},
       'thread clone preserves two-byte-index tombstones');
    is($snapshot->[2], $narrow_info->{free_list_length},
       'thread clone preserves the recycled entry list');
    ok(!$snapshot->[3] && $snapshot->[4],
       'thread clone preserves deleted and live lookups');
}
my $narrow_used = $narrow_info->{entry_used};
$narrow{"narrow:replacement"} = 999;
$narrow_info = hash_storage_info(\%narrow);
is($narrow_info->{free_list_length}, 0,
   'entry deleted after the transition is reused');
is($narrow_info->{entry_used}, $narrow_used,
   'reusing the entry does not extend the high-water mark');
is($narrow{'narrow:replacement'}, 999,
   'lookup works after two-byte entry reuse');

my %wide;
my @wide_keys;
my $wide_next = 0;
my $add_wide = sub {
    my $key = "wide:$wide_next";
    $wide{$key} = $wide_next++;
    push @wide_keys, $key;
};
my $wide_info = hash_storage_info(\%wide);
while ($wide_info->{index_capacity} < 128) {
    $add_wide->();
    $wide_info = hash_storage_info(\%wide);
}
while ($wide_info->{index_capacity} < 256) {
    $add_wide->();
    $wide_info = hash_storage_info(\%wide);
}
while ($wide_info->{index_capacity} < 32768) {
    $add_wide->() for 1..128;
    $wide_info = hash_storage_info(\%wide);
}
is($wide_info->{index_capacity}, 32768,
   'two-byte index reaches the 32768-slot boundary');
is($wide_info->{index_width}, 2,
   '32768 index slots use two-byte entry indices');
while ($wide_info->{index_capacity} < 65536) {
    $add_wide->() for 1..128;
    $wide_info = hash_storage_info(\%wide);
}
is($wide_info->{index_capacity}, 65536,
   'index growth crosses from 32768 to 65536 slots');
is($wide_info->{index_width}, 4,
   '65536 index slots use four-byte entry indices');
ok(exists $wide{$wide_keys[0]} && exists $wide{$wide_keys[-1]},
   'early and late entries survive the two-to-four-byte transition');
my ($wide_early, $wide_late) = @wide_keys[0, -1];
delete $wide{$wide_early};
delete $wide{$wide_late};
$wide_info = hash_storage_info(\%wide);
is($wide_info->{index_deleted}, 2,
   'four-byte indices retain tombstones after transition');
SKIP: {
    skip 'Perl not compiled with useithreads', 4
        unless $Config{useithreads};
    require threads;
    my $snapshot = clone_storage_state(\%wide, $wide_early, $wide_keys[100]);
    is($snapshot->[0], 4, 'thread clone preserves the four-byte index width');
    is($snapshot->[1], $wide_info->{index_deleted},
       'thread clone preserves four-byte-index tombstones');
    is($snapshot->[2], $wide_info->{free_list_length},
       'thread clone preserves the wide recycled entry list');
    ok(!$snapshot->[3] && $snapshot->[4],
       'thread clone preserves early deleted and live wide lookups');
}
my $wide_used = $wide_info->{entry_used};
my $wide_replacement_one = "wide:replacement:$wide_next";
$wide{$wide_replacement_one} = $wide_next;
$wide_next++;
my $wide_replacement_two = "wide:replacement:$wide_next";
$wide{$wide_replacement_two} = $wide_next;
$wide_next++;
$wide_info = hash_storage_info(\%wide);
is($wide_info->{free_list_length}, 0,
   'entries deleted after the wide transition are reused');
is($wide_info->{entry_used}, $wide_used,
   'wide-index entry reuse preserves the high-water mark');
ok(!exists $wide{$wide_early} && !exists $wide{$wide_late}
       && exists $wide{$wide_replacement_one}
       && exists $wide{$wide_replacement_two},
   'lookups remain correct after wide-index deletions and reuse');

done_testing();
