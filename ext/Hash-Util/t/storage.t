#!./perl

use strict;
use warnings;
use Config;
use FindBin;
use Test::More;
use Hash::Util qw(hash_storage_info shared_key_refcount shared_keys immortalize_key
                  bucket_info bucket_array);

{
    my $key = "xperl-hash-util-shared-key-$$";
    my @before = shared_keys();
    my $absent_refcount = shared_key_refcount($key);
    my $count_after_absent_lookup = scalar shared_keys();
    ok(!grep($_ eq $key, @before), 'fresh shared key is absent');
    is($absent_refcount, 0,
       'refcount lookup does not intern an absent key');
    is($count_after_absent_lookup, scalar @before,
       'absent refcount lookup leaves shared-key count unchanged');

    my %first = ($key => 1);
    is(shared_key_refcount($key), 1, 'one hash owns one shared-key reference');
    my %second = %first;
    is(shared_key_refcount($key), 2, 'copying a hash acquires a shared-key ref');
    my @keys = shared_keys();
    is(scalar @keys, scalar shared_keys(),
       'shared_keys list and scalar contexts report the same count');
    my ($copy) = grep { $_ eq $key } @keys;
    ok(defined $copy, 'shared_keys includes the interned key');
    $copy .= '-changed';
    ok(exists $first{$key} && exists $second{$key},
       'changing a returned key copy does not change either hash');
    is(shared_key_refcount($key), 2,
       'changing a returned key copy does not change the interned refcount');
    delete $first{$key};
    is(shared_key_refcount($key), 1, 'deletion releases one shared-key ref');
    delete $second{$key};
    is(shared_key_refcount($key), 0, 'last deletion releases the shared key');
}

{
    my $base = scalar shared_keys();
    my %hash;
    $hash{"xperl-strtab-growth-$$-$_"} = $_ for 0 .. 22_000;
    is(scalar(shared_keys()), $base + 22_001,
       'shared-key table retains keys across large growth');
    is(shared_key_refcount("xperl-strtab-growth-$$-11000"), 1,
       'grown shared-key table reports the live key reference');

    delete $hash{"xperl-strtab-growth-$$-$_"} for 0 .. 4_999;
    is(shared_key_refcount("xperl-strtab-growth-$$-2500"), 0,
       'deleting a key after shared-key growth releases its reference');
    $hash{"xperl-strtab-reinsert-$$-$_"} = $_ for 0 .. 4_999;
    is(scalar(shared_keys()), $base + 22_001,
       'shared-key table remains valid after deletion and reinsertion');
    is($hash{"xperl-strtab-growth-$$-22000"}, 22_000,
       'late shared-key entry survives deletion and reinsertion churn');
}

for my $key ("xperl-hash-util-nul-$$\0tail",
             "xperl-hash-util-utf8-$$\x{e9}",
             "xperl-hash-util-wide-$$\x{100}") {
    utf8::upgrade($key) if $key =~ /\x{e9}/;
    my %hash = ($key => 1);
    is(shared_key_refcount($key), 1,
       'shared_key_refcount accepts binary and UTF8 keys');
    my ($copy) = grep { $_ eq $key } shared_keys();
    ok(defined $copy, 'shared_keys returns binary and UTF8 key copies');
    is(utf8::is_utf8($copy), utf8::is_utf8($key),
       'shared_keys preserves the key UTF8 flag');
    $copy = 'changed';
    ok(exists $hash{$key}, 'mutating copied binary or UTF8 key has no effect');
}


{
    my $bytes = "xperl-hash-util-wasutf8-$$\x{e9}";
    my $utf8 = $bytes;
    utf8::upgrade($utf8);
    my %byte_hash = ($bytes => 1);
    my %utf8_hash = ($utf8 => 2);
    is(shared_key_refcount($bytes), 1, 'byte HEK has its own reference count');
    is(shared_key_refcount($utf8), 1, 'WASUTF8 HEK has its own reference count');
    my @copies = grep { $_ eq $bytes } shared_keys();
    is(scalar @copies, 2, 'shared_keys includes both byte and WASUTF8 HEKs');
    is(scalar(grep { utf8::is_utf8($_) } @copies), 1,
       'only the WASUTF8 copy is upgraded');
    is(scalar(grep { !utf8::is_utf8($_) } @copies), 1,
       'the plain byte copy remains downgraded');

    $byte_hash{$utf8} = 3;
    is(scalar keys %byte_hash, 1, 'UTF8 replacement preserves hash key identity');
    is(shared_key_refcount($bytes), 0, 'replacement releases the byte HEK');
    is(shared_key_refcount($utf8), 2, 'replacement acquires the WASUTF8 HEK');
    my ($returned) = keys %byte_hash;
    ok(utf8::is_utf8($returned), 'keys returns the upgraded replacement key');
    undef $returned;
    delete $utf8_hash{$utf8};
    is(shared_key_refcount($utf8), 1, 'deletion releases one WASUTF8 reference');
    $byte_hash{$bytes} = 4;
    is(shared_key_refcount($utf8), 0, 'byte replacement releases the WASUTF8 HEK');
    is(shared_key_refcount($bytes), 1, 'byte replacement acquires a byte HEK');
    delete $byte_hash{$bytes};
    is(shared_key_refcount($bytes), 0, 'last byte reference is released');
}


{
    my $bytes = "xperl-immortal-byte-$$\x{e9}";
    my $utf8 = $bytes;
    utf8::upgrade($utf8);
    my $ascii = "xperl-immortal-ascii-$$";
    utf8::upgrade($ascii);
    for my $key ($bytes, $utf8, $ascii, "xperl-immortal-wide-$$\x{100}",
                 "xperl-immortal-nul-$$\0tail") {
        is(shared_key_refcount($key), 0, 'key starts absent before immortalization');
        is(immortalize_key($key), 1, 'immortalization interns an absent key');
        is(immortalize_key($key), 2, 'each immortalization acquires one reference');
        {
            my %hash = ($key => 1);
            is(shared_key_refcount($key), 3, 'a hash acquires its own reference');
        }
        is(shared_key_refcount($key), 2, 'pins survive the last hash owner');
    }
    my @copies = grep { $_ eq $bytes } shared_keys();
    is(scalar @copies, 2, 'byte and WASUTF8 immortalizations stay distinct');
    is(scalar(grep { utf8::is_utf8($_) } @copies), 1,
       'immortalized WASUTF8 key is upgraded when listed');

    SKIP: {
        skip 'Perl not compiled with useithreads', 2 unless $Config{useithreads};
        require threads;
        my $thread = threads->create(sub {
            my ($key) = @_;
            my $before = shared_key_refcount($key);
            my $after = immortalize_key($key);
            return [$before, $after];
        }, $utf8);
        is_deeply($thread->join, [2, 3], 'thread clone inherits independent pins');
        is(shared_key_refcount($utf8), 2, 'child pin does not change parent refs');
    }

    my $cow_key = "xperl-immortal-cow-$$";
    {
        my %hash = ($cow_key => 1);
        my ($key) = keys %hash;
        my $before = shared_key_refcount($key);
        is(immortalize_key($key), $before + 1,
           'immortalizing a shared key SV acquires exactly one reference');
    }
    is(shared_key_refcount($cow_key), 1,
       'pin survives both the shared key SV and its source hash');

    local $ENV{PERL_DESTRUCT_LEVEL} = 2;
    my $script = q{
        open STDERR, '>&', STDOUT or die $!;
        require Hash::Util;
        my $key = "xperl-immortal-shutdown-$$";
        Hash::Util::immortalize_key($key);
        Hash::Util::immortalize_key($key);
        print "ok\n";
    };
    open my $child, '-|', $^X, "-I$FindBin::Bin/../../../lib", '-e', $script
        or die "could not start immortal-key shutdown probe: $!";
    my $output = do { local $/; <$child> };
    close $child;
    is($?, 0, 'immortal-key shutdown probe exits successfully');
    is($output, "ok\n", 'intentional pins produce no unbalanced-key warning');
}

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

{
    my $script = <<'PERL';
use strict;
use warnings;
use Hash::Util qw(bucket_info bucket_array hash_storage_info);

sub check_hash {
    my ($hash, $expected, $where) = @_;
    my ($keys, $slots, $used) = bucket_info($hash);
    die "$where: bucket_info key count" unless $keys == @$expected;
    die "$where: bucket_info used count" unless $used == @$expected;
    my $info = hash_storage_info($hash);
    my $expected_slots = $info->{linear}
        ? $info->{entry_capacity} : $info->{index_capacity};
    die "$where: bucket_info slot count"
        if @$expected && $slots != $expected_slots;
    my $buckets = bucket_array($hash);
    my @physical = $buckets ? map { ref($_) ? @$_ : () } @$buckets : ();
    my @actual = sort @physical;
    my @wanted = sort @$expected;
    die "$where: bucket_array keys" unless "@actual" eq "@wanted";
}

for my $count (1 .. 8) {
    my %hash = map { ("linear:$_" => $_) } 0 .. $count - 1;
    my @expected = map { "linear:$_" } 0 .. $count - 1;
    check_hash(\%hash, \@expected, "inserted $count");

    delete $hash{$expected[0]};
    shift @expected;
    check_hash(\%hash, \@expected, "deleted from $count");
}
print "ok\n";
PERL
    for my $limit (0, 2, 4, 8) {
        local $ENV{PERL_HASH_LINEAR_MAX} = $limit;
        open my $child, '-|', $^X, "-I$FindBin::Bin/../../../lib",
            '-e', $script
            or die "could not start bucket diagnostics probe: $!";
        my $output = do { local $/; <$child> };
        close $child;
        is($?, 0, "bucket diagnostics handle threshold $limit")
            or diag($output);
        is($output, "ok\n", "bucket diagnostics preserve threshold $limit keys");
    }
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
            $copy_info->{entry_holes},
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
is($info->{entry_holes}, 0, 'empty hash has no deleted entry positions');
is($info->{index_width}, 0, 'an unallocated index has no entry-index width');
is($info->{hash_bytes}, 0, 'an unallocated index has no cached-hash storage');
is($info->{entry_index_bytes}, 0,
   'an unallocated index has no encoded entry-index storage');

$hash{"key:$_"} = $_ for 1 .. 64;
delete $hash{"key:$_"} for 1 .. 20;
$info = hash_storage_info(\%hash);
is($info->{free_list_length}, 0, 'deleted indexed entries are not recycled');
is($info->{entry_used}, 64, 'deletion retains the entry high-water mark');
is($info->{entry_holes}, 20, 'deleted positions are reported as entry holes');
is($info->{entry_capacity}, int(2 * $info->{index_capacity} / 3),
   'indexed entry allocation is two-thirds of index capacity');
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
is($info->{free_list_length}, 0, 'lazy iterator deletion does not use a free list');
is($info->{entry_used}, 64, 'lazy iterator deletion retains its entry position');
is($info->{entry_holes}, 21, 'lazy deletion adds one entry hole');
keys %hash;
is(hash_storage_info(\%hash)->{free_list_length}, 0,
   'iterator reset keeps indexed entries append-only');
is(hash_storage_info(\%hash)->{entry_holes}, 21,
   'iterator reset retains the deleted entry position');

$hash{"replacement:$_"} = $_ for 1 .. 21;
$info = hash_storage_info(\%hash);
is($info->{free_list_length}, 0, 'insertion leaves the free list empty');
is($info->{entry_used}, 85, 'new keys append after deleted entry positions');
is($info->{entry_holes}, 21, 'appending leaves deleted positions as holes');

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
    skip 'Perl not compiled with useithreads', 5
        unless $Config{useithreads};
    require threads;
    my $snapshot = clone_storage_state(\%narrow, 'narrow:0', 'narrow:1');
    is($snapshot->[0], 1, 'thread clone preserves the one-byte index width');
    is($snapshot->[1], 1, 'thread clone preserves one-byte-index tombstones');
    is($snapshot->[2], 0, 'thread clone preserves the empty free list');
    is($snapshot->[3], 1, 'thread clone preserves one entry hole');
    ok(!$snapshot->[4] && $snapshot->[5],
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
    skip 'Perl not compiled with useithreads', 5
        unless $Config{useithreads};
    require threads;
    my $snapshot = clone_storage_state(\%narrow, 'narrow:1', 'narrow:2');
    is($snapshot->[0], 2, 'thread clone preserves the two-byte index width');
    is($snapshot->[1], $narrow_info->{index_deleted},
       'thread clone preserves two-byte-index tombstones');
    is($snapshot->[2], 0, 'thread clone preserves the empty free list');
    is($snapshot->[3], $narrow_info->{entry_holes},
       'thread clone preserves two-byte entry holes');
    ok(!$snapshot->[4] && $snapshot->[5],
       'thread clone preserves deleted and live lookups');
}
my $narrow_used = $narrow_info->{entry_used};
$narrow{"narrow:replacement"} = 999;
$narrow_info = hash_storage_info(\%narrow);
is($narrow_info->{free_list_length}, 0,
   'entry deleted after the transition is not recycled');
is($narrow_info->{entry_used}, $narrow_used + 1,
   'insertion appends after a deleted entry position');
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
    skip 'Perl not compiled with useithreads', 5
        unless $Config{useithreads};
    require threads;
    my $snapshot = clone_storage_state(\%wide, $wide_early, $wide_keys[100]);
    is($snapshot->[0], 4, 'thread clone preserves the four-byte index width');
    is($snapshot->[1], $wide_info->{index_deleted},
       'thread clone preserves four-byte-index tombstones');
    is($snapshot->[2], 0, 'thread clone preserves the empty free list');
    is($snapshot->[3], $wide_info->{entry_holes},
       'thread clone preserves wide entry holes');
    ok(!$snapshot->[4] && $snapshot->[5],
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
   'entries deleted after the wide transition are not recycled');
is($wide_info->{entry_used}, $wide_used + 2,
   'wide-index insertions append after deleted entry positions');
ok(!exists $wide{$wide_early} && !exists $wide{$wide_late}
       && exists $wide{$wide_replacement_one}
       && exists $wide{$wide_replacement_two},
   'lookups remain correct after wide-index deletions and appends');

is(shared_key_refcount("xperl-immortal-byte-$$\x{e9}"), 2,
   'permanent references survive shared-key index growth');

{
    my %reserved;
    keys %reserved = 10_000;
    my $small = hash_storage_info(\%reserved);
    is($small->{index_capacity}, 16_384,
       'reservation reaches the coupled index cutoff');
    is($small->{entry_capacity}, int(2 * 16_384 / 3),
       'reservation preserves coupled two-thirds entry sizing');

    keys %reserved = 20_000;
    my $before = hash_storage_info(\%reserved);
    cmp_ok($before->{entry_capacity}, '>=', 20_000,
           'large reservation allocates entry space up front');
    $reserved{"reserve:$_"} = $_ for 1 .. 20_000;
    my $filled = hash_storage_info(\%reserved);
    is($filled->{entry_capacity}, $before->{entry_capacity},
       'filling reserved entries needs no entry-array growth');
    is($filled->{index_capacity}, $before->{index_capacity},
       'filling reserved entries needs no index growth');

    my $first = each %reserved;
    keys %reserved = 21_000;
    my $grown = hash_storage_info(\%reserved);
    is($grown->{index_capacity}, $filled->{index_capacity},
       'entry reservation can grow without index growth');
    cmp_ok($grown->{entry_capacity}, '>=', 21_000,
           'reservation is honored when the index is already large enough');
    my %seen;
    while (my ($key, $value) = each %reserved) {
        $seen{$key}++;
    }
    is(scalar(keys %seen), 20_000,
       'keys reservation resets iteration over all entries');
    ok(!grep($_ != 1, values %seen),
       'entry reservation does not repeat iterated entries');

    delete $reserved{"reserve:$_"} for 1 .. 1_000;
    keys %reserved = 21_000;
    my $holes = hash_storage_info(\%reserved);
    cmp_ok($holes->{entry_spare}, '>=', 2_000,
           'reservation accounts for positions occupied by deleted entries');
    is($holes->{entry_holes}, 1_000,
       'reservation leaves compaction to the normal policy');
    is($reserved{'reserve:20000'}, 20_000,
       'entry relocation preserves existing values');
}

{
    my @colliding;
    my $candidate = 0;
    while (@colliding < 40) {
        my $key = "probe-wrap:" . $candidate++;
        push @colliding, $key if (Hash::Util::hash_value($key) & 127) == 127;
    }
    my %probe;
    keys %probe = 64;
    $probe{$colliding[$_]} = $_ for 0 .. 19;
    delete $probe{$colliding[$_]} for 0 .. 9;
    $probe{$colliding[19]} = 100;
    is(scalar(keys %probe), 10,
       'replacement past tombstones does not create a duplicate entry');
    $probe{$colliding[$_]} = $_ for 20 .. 39;
    is(scalar(keys %probe), 30,
       'saved insertion slots support a cluster wrapping past the index end');
    ok(!grep(!exists $probe{$colliding[$_]}, 10 .. 39),
       'all colliding survivors and appended entries remain reachable');
    is($probe{$colliding[19]}, 100,
       'tombstone reuse preserves the replaced value');
    my $info = hash_storage_info(\%probe);
    is($info->{index_deleted}, $info->{tombstones},
       'saved-slot insertion maintains the tombstone count');
}

done_testing();
