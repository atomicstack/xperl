#!./perl

use strict;
use warnings;
use Config;
use FindBin;
use Test::More;
use Hash::Util qw(hash_storage_info shared_key_refcount shared_keys immortalize_key
                  bucket_info bucket_array hash_value);

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
    local $ENV{PERL_HASH_LINEAR_MAX} = 4;
    my $script = <<'PERL';
use strict;
use warnings;
use Config;
use Hash::Util qw(hash_storage_info);

sub tiny_capacity {
    my ($requested) = @_;
    my $capacity = 1;
    $capacity *= 2 while $capacity < $requested;
    return $capacity;
}

for my $requested (1 .. 4) {
    my %hash;
    my $empty = hash_storage_info(\%hash);
    die "unreserved empty hash allocated storage\n"
        if $empty->{entry_capacity} || $empty->{entry_bytes}
            || $empty->{requested_bytes} || $empty->{entries_address};
    keys %hash = $requested;
    my $reserved = hash_storage_info(\%hash);
    my $capacity = tiny_capacity($requested);
    die "tiny reservation $requested did not reserve its rounded HE capacity\n"
        unless $reserved->{linear} && !$reserved->{index_capacity}
            && $reserved->{entry_capacity} == $capacity
            && !$reserved->{entry_used}
            && $reserved->{entries_address}
            && ($capacity == 1 ? $reserved->{arena_backed}
                               : !$reserved->{arena_backed});
    $hash{"tiny:$requested:$_"} = $_ for 0 .. $requested - 1;
    my $filled = hash_storage_info(\%hash);
    die "filling tiny reservation $requested changed its storage\n"
        unless $filled->{linear} && !$filled->{index_capacity}
            && $filled->{entry_capacity} == $capacity
            && $filled->{entry_used} == $requested
            && keys(%hash) == $requested;
    die "tiny reservation $requested lost a value\n"
        if grep { $hash{"tiny:$requested:$_"} != $_ }
            0 .. $requested - 1;
}

for my $requested (1, 4) {
    my %reserved;
    keys %reserved = $requested;
    my $capacity = tiny_capacity($requested);
    if ($Config::Config{useithreads} && eval { require threads; 1 }) {
        my $thread = threads->create(sub {
            my ($copy, $want, $expected_capacity) = @_;
            my $before = hash_storage_info($copy);
            die "thread clone lost empty reservation $want\n"
                unless $before->{linear} && !$before->{entry_used}
                    && $before->{entry_capacity} == $expected_capacity
                    && !$before->{index_capacity}
                    && ($want == 1 ? $before->{arena_backed}
                                   : !$before->{arena_backed});
            $copy->{"clone:$want:$_"} = $_ for 0 .. $want - 1;
            my $after = hash_storage_info($copy);
            die "thread clone could not fill reservation $want\n"
                unless $after->{linear} && !$after->{index_capacity}
                    && $after->{entry_capacity} == $expected_capacity
                    && $after->{entry_used} == $want
                    && keys(%$copy) == $want;
            return 1;
        }, \%reserved, $requested, $capacity);
        die "empty tiny reservation clone failed\n" unless $thread->join == 1;
        my $original = hash_storage_info(\%reserved);
        die "thread fill changed the reserved source hash\n"
            unless !$original->{entry_used}
                && $original->{entry_capacity} == $capacity
                && !keys(%reserved);
    }
}

for my $requested (11, 43) {
    my %hash;
    keys %hash = $requested;
    my $reserved = hash_storage_info(\%hash);
    my @keys = map { "odd-reserve:$requested:$_" } 0 .. $requested - 1;
    $hash{$keys[$_]} = $_ for 0 .. $#keys;
    my $filled = hash_storage_info(\%hash);
    die "odd reservation $requested grew while filling its requested keys\n"
        unless $filled->{index_capacity} == $reserved->{index_capacity}
            && $filled->{entry_capacity} == $reserved->{entry_capacity}
            && $filled->{entry_used} == $requested;
    die "odd reservation $requested lost a value\n"
        if grep { $hash{$keys[$_]} != $_ } 0 .. $#keys;
}

my %cleared_reservation;
keys %cleared_reservation = 1;
my $reserved_singleton = hash_storage_info(\%cleared_reservation);
die "one-entry reservation did not use its arena slot\n"
    unless $reserved_singleton->{arena_backed}
        && $reserved_singleton->{entry_capacity} == 1;
%cleared_reservation = ();
my $cleared_singleton = hash_storage_info(\%cleared_reservation);
die "clear discarded or used the empty singleton reservation\n"
    unless $cleared_singleton->{arena_backed}
        && $cleared_singleton->{entry_capacity} == 1
        && !$cleared_singleton->{entry_used};
undef %cleared_reservation;
my $undefined_singleton = hash_storage_info(\%cleared_reservation);
die "undef retained the reserved singleton arena slot\n"
    if $undefined_singleton->{entry_capacity}
        || $undefined_singleton->{entry_bytes}
        || $undefined_singleton->{requested_bytes}
        || $undefined_singleton->{entries_address};
PERL
    open my $child, '-|', $^X, "-I$FindBin::Bin/../../../lib", '-e', $script
        or die "could not start tiny reservation storage probe: $!";
    my $output = do { local $/; <$child> };
    close $child;
    is($?, 0, 'tiny and odd-sized reservation storage probe exits successfully')
        or diag($output);
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
    my $info = hash_storage_info($hash);
    my $buckets = bucket_array($hash);
    my $occupied_buckets = $info->{integer_chained} && !$info->{linear}
        ? ($buckets ? scalar(grep { ref($_) } @$buckets) : 0) : @$expected;
    die "$where: bucket_info used count" unless $used == $occupied_buckets;
    my $expected_slots = $info->{linear}
        ? $info->{entry_capacity} : $info->{index_capacity};
    die "$where: bucket_info slot count"
        if @$expected && $slots != $expected_slots;
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

sub clone_integer_chain_state {
    my ($table) = @_;
    return threads->create(sub {
        my ($copy) = @_;
        my $info = hash_storage_info($copy);
        my @physical = sort map { ref($_) ? @$_ : () }
            @{bucket_array($copy)};
        return [
            $info->{integer_chained}, $info->{index_width},
            $info->{fingerprint_bits},
            $info->{link_bytes}, $info->{fullchains}, $info->{entry_holes},
            \@physical, [sort keys %$copy],
        ];
    }, $table)->join;
}

sub integer_chain_keys {
    my ($prefix, $buckets, $wanted) = @_;
    my %by_bucket;
    for my $candidate (0 .. 1_000_000) {
        my $key = "$prefix-$$-$candidate";
        my $bucket = hash_value($key) & ($buckets - 1);
        push @{$by_bucket{$bucket}}, $key;
        return @{$by_bucket{$bucket}}
            if @{$by_bucket{$bucket}} == $wanted;
    }
    die "could not find $wanted keys sharing one bucket among $buckets buckets\n";
}

sub filled_indexed_hash {
    my ($prefix, $reservation) = @_;
    my %hash;
    keys %hash = $reservation;
    my $reserved = hash_storage_info(\%hash);
    my $capacity = $reserved->{entry_capacity};
    my @keys = map { "$prefix:$$:$_" } 0 .. $capacity - 1;
    $hash{$keys[$_]} = $_ for 0 .. $#keys;
    my $filled = hash_storage_info(\%hash);
    die "$prefix: reserved entry array did not fill\n"
        unless $filled->{entry_used} == $capacity
            && $filled->{live} == $capacity;
    return (\%hash, \@keys, $filled);
}

sub exercise_chain_all_ones {
    my ($capacity, $width) = @_;
    my %hash;
    keys %hash = $capacity;
    my $reserved = hash_storage_info(\%hash);
    is($reserved->{entry_capacity}, $capacity,
       "$width-byte chain test reserves exactly $capacity HE positions");
    is($reserved->{index_width}, $width,
       "$width-byte chain test starts at the expected encoded width");

    my @colliding = integer_chain_keys(
        "xperl-chain-all-ones-$capacity", $reserved->{index_capacity}, 3);
    my ($tail, $middle, $head) = @colliding;
    $hash{$tail} = 'tail';
    $hash{$middle} = 'middle';
    $hash{"all-ones:$capacity:$_"} = $_ for 1 .. $capacity - 3;
    $hash{$head} = 'all-ones';
    is(scalar keys %hash, $capacity,
       "$width-byte chain test fills every reserved HE position");
    is($hash{$head}, 'all-ones',
       "$width-byte chain test looks up the all-ones entry index");
    is($hash{$middle}, 'middle',
       "$width-byte chain test looks up a middle chain entry");
    is($hash{$tail}, 'tail',
       "$width-byte chain test looks up the chain tail");

    delete $hash{$head};
    delete $hash{$tail};
    ok(!exists($hash{$head}),
       "$width-byte chain head is absent after deletion");
    ok(!exists($hash{$tail}),
       "$width-byte chain tail is absent after deletion");
    is($hash{$middle}, 'middle',
       "$width-byte chain remains searchable after head and tail deletion");
    is(hash_storage_info(\%hash)->{index_deleted}, 0,
       "$width-byte chain deletion does not create tombstones");
    $hash{$head} = 'reinserted';
    is($hash{$head}, 'reinserted',
       "$width-byte all-ones key can be reinserted after deletion");
    is($hash{$middle}, 'middle',
       "$width-byte chain survivor remains searchable after reinsertion");
}

my %hash;
my $info = hash_storage_info(\%hash);
ok($info->{open_addressed} || $info->{integer_chained},
   'ordinary hash uses an indexed layout');
is($info->{integer_chained} ? 1 : 0,
   $info->{integer_chained}, 'integer-chain mode is reported as a boolean');
is($info->{requested_bytes}, 0, 'empty hash has no storage allocation');
is($info->{free_list_length}, 0, 'empty hash has no recycled entries');
is($info->{entry_holes}, 0, 'empty hash has no deleted entry positions');
is($info->{index_width}, 0, 'an unallocated index has no entry-index width');
is($info->{hash_bytes}, 0, 'an unallocated index has no cached-hash storage');
is($info->{entry_index_bytes}, 0,
   'an unallocated index has no encoded entry-index storage');
is($info->{link_bytes}, 0, 'an empty hash has no chain links');
is($info->{fullchains}, 0, 'an empty hash has no full chains');

SKIP: {
    skip 'integer-chain mode is not enabled in this Perl', 1
        unless $info->{integer_chained};
    pass('integer-chain diagnostics are enabled');
}

{
    my ($below, $below_keys, $below_full)
        = filled_indexed_hash('xperl-compaction-below', 20_000);
    my $below_capacity = $below_full->{entry_capacity};
    my $hole_threshold = int(($below_capacity + 4) / 5);
    my $below_holes = $hole_threshold - 1;
    delete $below->{$below_keys->[$_]}
        for 0 .. $below_holes - 1;
    my $below_deleted = hash_storage_info($below);
    is($below_deleted->{entry_holes}, $below_holes,
       'large indexed hash retains holes just below the 20% threshold');
    $below->{'xperl-compaction-below:replacement'} = 'below threshold';
    my $below_after = hash_storage_info($below);
    is($below_after->{entry_holes}, $below_holes,
       'insertion below the 20% threshold does not compact the entry array');
    is($below_after->{entry_used}, $below_capacity + 1,
       'insertion below the threshold appends after retained holes');
    is($below->{'xperl-compaction-below:replacement'}, 'below threshold',
       'lookup works after insertion below the compaction threshold');

    my ($at_threshold, $threshold_keys, $threshold_full)
        = filled_indexed_hash('xperl-compaction-at', 20_000);
    my $threshold_capacity = $threshold_full->{entry_capacity};
    my $threshold_holes = int(($threshold_capacity + 4) / 5);
    delete $at_threshold->{$threshold_keys->[$_]}
        for 0 .. $threshold_holes - 1;
    is(hash_storage_info($at_threshold)->{entry_holes}, $threshold_holes,
       'large indexed hash reaches the 20% compaction threshold');
    $at_threshold->{'xperl-compaction-at:replacement'} = 'compacted';
    my $at_after = hash_storage_info($at_threshold);
    is($at_after->{entry_holes}, 0,
       'insertion at the 20% threshold compacts a sub-megabyte hole set');
    is($at_after->{entry_used}, $at_after->{live},
       'threshold compaction leaves no unused entry positions');
    cmp_ok($at_after->{entry_capacity}, '>',
       $threshold_full->{entry_capacity} / 2,
       'compaction retains HE capacity when the live set is not small');
    is($at_threshold->{'xperl-compaction-at:replacement'}, 'compacted',
       'lookup works after threshold compaction');
    if ($at_after->{integer_chained}) {
        is($at_after->{index_capacity}, $threshold_full->{index_capacity},
           'full chain entry-array compaction keeps the bucket index size');
    }
    else {
        is($at_after->{index_capacity}, $threshold_full->{index_capacity},
           'entry compaction clears tombstones before index pressure');
    }
}

{
    my ($churn, $active, $initial)
        = filled_indexed_hash('xperl-storage-churn', 2_048);
    my $count = @$active;
    my $batch = int($count / 4);
    my ($max_index_capacity, $max_entry_capacity)
        = @{$initial}{qw(index_capacity entry_capacity)};
    for my $round (1 .. 16) {
        my @removed = splice @$active, 0, $batch;
        delete $churn->{$_} for @removed;
        for my $i (0 .. $#removed) {
            my $key = "xperl-storage-churn:$$:$round:$i";
            $churn->{$key} = $round * $batch + $i;
            push @$active, $key;
        }
        my $state = hash_storage_info($churn);
        $max_index_capacity = $state->{index_capacity}
            if $state->{index_capacity} > $max_index_capacity;
        $max_entry_capacity = $state->{entry_capacity}
            if $state->{entry_capacity} > $max_entry_capacity;
        is($state->{live}, $count,
           "stable-size churn round $round preserves the live key count");
    }
    cmp_ok($max_index_capacity, '<=', 2 * $initial->{index_capacity},
       'stable-size churn bounds index growth');
    cmp_ok($max_entry_capacity, '<=', 2 * $initial->{entry_capacity},
       'stable-size churn bounds entry-array growth');
    my @iterated;
    while (my ($key, $value) = each %$churn) {
        push @iterated, $key;
    }
    is_deeply([sort @iterated], [sort @$active],
       'stable-size churn iteration finds each surviving key once');
    is_deeply(\@iterated, $active,
       'stable-size churn compaction preserves survivor and insertion order');
}

{
    my ($shrink, $all_keys, $before)
        = filled_indexed_hash('xperl-storage-shrink', 20_000);
    my @old_order = keys %$shrink;
    my ($lazy_key) = each %$shrink;
    ok(defined $lazy_key, 'mass-delete test starts an active iterator');
    delete $shrink->{$lazy_key};
    my @survivors = grep { $_ ne $lazy_key } @old_order;
    @survivors = @survivors[0 .. 31];
    my %keep = map { $_ => 1 } @survivors;
    delete $shrink->{$_}
        for grep { $_ ne $lazy_key && !$keep{$_} } @$all_keys;
    is(hash_storage_info($shrink)->{live}, scalar @survivors,
       'mass deletion leaves the selected live entries');

    $shrink->{'xperl-storage-shrink:replacement'} = 'survives';
    my $after_shrink = hash_storage_info($shrink);
    cmp_ok($after_shrink->{index_capacity}, '<=', $before->{index_capacity} / 2,
       'compaction substantially shrinks the bucket index');
    cmp_ok($after_shrink->{entry_capacity}, '<=', $before->{entry_capacity} / 2,
       'compaction substantially shrinks the HE array');
    cmp_ok($after_shrink->{requested_bytes}, '<', $before->{requested_bytes},
       'compaction releases the large table allocation');
    is($after_shrink->{entry_holes}, 0,
       'shrinking compaction removes deleted HE positions');
    is($shrink->{'xperl-storage-shrink:replacement'}, 'survives',
       'shrinking compaction preserves the inserted value');
    ok(!exists $shrink->{$lazy_key},
       'shrinking compaction keeps the lazily deleted key absent');

    my ($next, $warning) = (undef, '');
    {
        local $SIG{__WARN__} = sub { $warning .= join '', @_ };
        ($next) = each %$shrink;
    }
    ok(!defined($next) && $warning =~ /each\(\).*insertion.*iterator/i,
       'insertion after lazy deletion terminates the active iterator');
    my @expected_order = (@survivors, 'xperl-storage-shrink:replacement');
    is_deeply([keys %$shrink], \@expected_order,
       'shrinking compaction preserves survivor order and appends the new key');
    my @iterated;
    while (my ($key) = each %$shrink) { push @iterated, $key }
    is_deeply(\@iterated, \@expected_order,
       'iteration follows the compacted order after lazy deletion');
}

if (!$info->{integer_chained}) {
    for my $case (
        ['same-size', 'many'],
        ['growth', 'few'],
    ) {
        my ($label, $tombstone_level) = @$case;
        my %tombstones;
        keys %tombstones = 100;
        my $reserved = hash_storage_info(\%tombstones);
        my $initial_capacity = $reserved->{entry_capacity};
        my @colliding = map { "xperl-oa-tombstone-$label:seed:$_" }
            0 .. $initial_capacity - 1;
        $tombstones{$colliding[$_]} = $_ for 0 .. $#colliding;
        my $full = hash_storage_info(\%tombstones);
        my $capacity = $full->{index_capacity};
        my $delete_count = $full->{live} - 40;
        delete $tombstones{$colliding[$_]}
            for 0 .. $delete_count - 1;
        $tombstones{"xperl-oa-tombstone-$label:shrink"} = 'shrink';
        my $shrunk = hash_storage_info(\%tombstones);
        is($shrunk->{index_capacity}, $capacity / 2,
           "$label tombstone setup first shrinks the index");
        my $next = 0;
        while ($shrunk->{live} + $shrunk->{tombstones}
                < int(2 * $shrunk->{index_capacity} / 3)) {
            my $key = "xperl-oa-tombstone-$label:grow:" . $next++;
            $tombstones{$key} = $next;
            $shrunk = hash_storage_info(\%tombstones);
        }
        my $occupied = $shrunk->{live} + $shrunk->{tombstones};
        is($occupied, int(2 * $shrunk->{index_capacity} / 3),
           "$label tombstone case reaches index occupancy with HE spare");
        my $pressure_delete_count = $tombstone_level eq 'many'
            ? int(($occupied + 1) / 2)
            : int($occupied / 3);
        my @delete = grep { $_ ne $colliding[-1] } keys %tombstones;
        delete $tombstones{$delete[$_]}
            for 0 .. $pressure_delete_count - 1;
        my $before_rebuild = hash_storage_info(\%tombstones);
        my $entry_shrink_target = $before_rebuild->{live}
            + ($before_rebuild->{live} >> 2) + 1;
        $entry_shrink_target = 8 if $entry_shrink_target < 8;
        ok($before_rebuild->{entry_used} < $before_rebuild->{entry_capacity}
           && $before_rebuild->{entry_holes} * 5
                >= $before_rebuild->{entry_capacity}
           && $entry_shrink_target > $before_rebuild->{entry_capacity} / 2,
           "$label case reaches index cleanup without triggering HE compaction");
        my $trigger = "xperl-oa-tombstone-$label:trigger";
        $tombstones{$trigger} = 'new';
        my $rebuilt = hash_storage_info(\%tombstones);
        if ($label eq 'same-size') {
            is($rebuilt->{index_capacity}, $shrunk->{index_capacity},
               'many tombstones clear at the existing index capacity');
        }
        else {
            is($rebuilt->{index_capacity}, 2 * $shrunk->{index_capacity},
               'few tombstones grow the index to retain the live-load rule');
        }
        is($rebuilt->{index_deleted}, 0,
           "$label rebuild clears deleted index slots");
        is($tombstones{$trigger}, 'new', "$label rebuild preserves the new key");
        ok(exists $tombstones{$colliding[-1]},
           "$label rebuild preserves a colliding survivor");
    }
}

if ($info->{integer_chained}) {
    my %chain;
    keys %chain = 64;
    my $buckets = (bucket_info(\%chain))[1];
    my @colliding = integer_chain_keys('xperl-integer-chain', $buckets, 4);
    is(scalar @colliding, 4, 'found keys sharing one integer-chain bucket');
    $chain{$colliding[$_]} = $_ for 0 .. $#colliding;
    my $chain_info = hash_storage_info(\%chain);
    is($chain_info->{integer_chained}, 1,
       'allocated ordinary hash reports integer chaining');
    is($chain_info->{fullchains}, 1,
       'diagnostics count a bucket with multiple live entries');
    is($chain_info->{link_bytes},
       $chain_info->{entry_capacity}
           * ($chain_info->{index_width} + $chain_info->{fingerprint_bits} / 8),
       'link storage includes each encoded link and its fingerprint');
    is($chain_info->{index_bytes},
       $chain_info->{metadata_bytes} + $chain_info->{entry_index_bytes},
       'index bytes include metadata and encoded bucket/link indices');
    is($chain_info->{requested_bytes},
       $chain_info->{index_bytes} + $chain_info->{entry_bytes},
       'requested bytes include the expanded index and HE allocations');
    is($chain_info->{entry_index_bytes},
       $chain_info->{index_capacity} * $chain_info->{index_width}
           + $chain_info->{link_bytes},
       'index storage includes bucket heads and chain link records');
    is($chain_info->{slot_size}, $chain_info->{index_width},
       'bucket-head slot size is the encoded identifier width');
    is($chain_info->{fingerprint_bytes},
       $chain_info->{entry_capacity} * $chain_info->{fingerprint_bits} / 8,
       'fingerprint byte count covers allocated HE link records only');
    is($chain_info->{hash_bytes}, 0,
       'fingerprints do not use a separate cached-hash allocation');
    ok(!$chain_info->{fingerprint_bits}
       || $chain_info->{fingerprint_bits} == $chain_info->{index_width} * 8,
       'fingerprint width is zero or tracks the encoded chain-link width');

    exercise_chain_all_ones(255, 1);
    exercise_chain_all_ones(65_535, 2);

    my ($keys, $slots, $used, @lengths) = bucket_info(\%chain);
    is($keys, 4, 'bucket_info counts all keys in an integer chain');
    is($slots, $chain_info->{index_capacity},
       'bucket_info reports the integer-chain bucket count');
    is($used, 1, 'bucket_info counts one occupied bucket for the chain');
    is($lengths[4], 1, 'bucket_info reports the full chain length');
    my @physical = map { ref($_) ? @$_ : () } @{bucket_array(\%chain)};
    is_deeply([sort @physical], [sort @colliding],
       'bucket_array traverses every integer-chain link');

    delete $chain{$colliding[1]};
    my $after_delete = hash_storage_info(\%chain);
    is($after_delete->{fullchains}, 1,
       'deleting a middle chain entry preserves the remaining chain');
    is($after_delete->{index_deleted}, 0,
       'integer-chain deletion does not create index tombstones');
    ok(!exists($chain{$colliding[1]}), 'deleted middle chain key is absent');
    is($chain{$colliding[0]}, 0, 'head-side chain entry remains searchable');
    is($chain{$colliding[2]}, 2, 'tail-side chain entry remains searchable');
    @physical = map { ref($_) ? @$_ : () } @{bucket_array(\%chain)};
    is_deeply([sort @physical], [sort($colliding[0], $colliding[2], $colliding[3])],
       'bucket_array omits a deleted chain entry');

    my %small_width;
    keys %small_width = 128;
    my $width_one = hash_storage_info(\%small_width);
    ok($width_one->{entry_capacity} <= 255 && $width_one->{index_width} == 1,
       'integer-chain links use one byte at small entry capacity');
    is($width_one->{fingerprint_bits},
       $chain_info->{fingerprint_bits} ? 8 : 0,
       'one-byte indexes report their enabled fingerprint width');
    my @small_colliding = integer_chain_keys(
        'xperl-integer-chain-small', $width_one->{index_capacity}, 4);
    $small_width{$small_colliding[$_]} = $_ for 0 .. $#small_colliding;
    delete $small_width{$small_colliding[1]};
    $width_one = hash_storage_info(\%small_width);
    SKIP: {
        skip 'Perl not compiled with useithreads', 1
            unless $Config{useithreads};
        require threads;
        my $snapshot = clone_integer_chain_state(\%small_width);
        is_deeply($snapshot, [
            1, $width_one->{index_width}, $width_one->{fingerprint_bits},
            $width_one->{link_bytes},
            $width_one->{fullchains}, $width_one->{entry_holes},
            [sort map { ref($_) ? @$_ : () } @{bucket_array(\%small_width)}],
            [sort keys %small_width],
        ], 'thread clone retains one-byte integer chains and holes');
    }
    keys %small_width = 256;
    my $width_two = hash_storage_info(\%small_width);
    ok($width_two->{entry_capacity} >= 256 && $width_two->{index_width} == 2,
       'integer-chain links widen after entry capacity crosses 255');
    is($width_two->{fingerprint_bits},
       $chain_info->{fingerprint_bits} ? 16 : 0,
       'two-byte indexes report their enabled fingerprint width');
    my @wider_colliding = integer_chain_keys(
        'xperl-integer-chain-small-wide', $width_two->{index_capacity}, 4);
    $small_width{$wider_colliding[$_]} = $_ for 0 .. $#wider_colliding;
    delete $small_width{$wider_colliding[1]};
    $width_two = hash_storage_info(\%small_width);
    SKIP: {
        skip 'Perl not compiled with useithreads', 1
            unless $Config{useithreads};
        require threads;
        my $snapshot = clone_integer_chain_state(\%small_width);
        is_deeply($snapshot, [
            1, $width_two->{index_width}, $width_two->{fingerprint_bits},
            $width_two->{link_bytes},
            $width_two->{fullchains}, $width_two->{entry_holes},
            [sort map { ref($_) ? @$_ : () } @{bucket_array(\%small_width)}],
            [sort keys %small_width],
        ], 'thread clone retains two-byte integer chains and holes');
    }

    my %wide;
    keys %wide = 65_535;
    my $wide_info = hash_storage_info(\%wide);
    is($wide_info->{entry_capacity}, 65_535,
       'known-size reservation reaches 65,535 HE positions');
    is($wide_info->{index_width}, 2,
       '65,535 HE positions still use two-byte chain links');
    my $wide_buckets = $wide_info->{index_capacity};
    my @wide_colliding = integer_chain_keys(
        'xperl-integer-chain-wide', $wide_buckets, 4);
    is(scalar @wide_colliding, 4,
       'found a four-entry chain in the wide index');
    $wide{$wide_colliding[$_]} = $_ for 0 .. $#wide_colliding;
    delete $wide{$wide_colliding[1]};
    my $lazy_key = each %wide;
    delete $wide{$lazy_key};
    my $wide_holes = hash_storage_info(\%wide);
    cmp_ok($wide_holes->{entry_holes}, '>=', 2,
       'ordinary and lazy deletion retain HE holes below the chain index');
    is($wide_holes->{fullchains}, 1,
       'chain diagnostics retain the surviving colliding entries');

    SKIP: {
        skip 'Perl not compiled with useithreads', 1
            unless $Config{useithreads};
        require threads;
        my $snapshot = threads->create(sub {
            my ($copy, $deleted, @expected) = @_;
            my $copy_info = hash_storage_info($copy);
            my @physical = map { ref($_) ? @$_ : () }
                @{bucket_array($copy)};
            return [
                $copy_info->{integer_chained}, $copy_info->{index_width},
                $copy_info->{fingerprint_bits}, $copy_info->{link_bytes},
                $copy_info->{entry_holes},
                exists($copy->{$deleted}) ? 1 : 0,
                [sort @physical], [sort keys %$copy],
            ];
        }, \%wide, $wide_colliding[1], @wide_colliding)->join;
        is_deeply($snapshot, [
            1, 2, $wide_holes->{fingerprint_bits}, $wide_holes->{link_bytes},
            $wide_holes->{entry_holes}, 0,
            [sort map { ref($_) ? @$_ : () } @{bucket_array(\%wide)}],
            [sort keys %wide],
        ], 'thread cloning retains colliding chains and a lazy deletion');
    }

    keys %wide = 65_536;
    my $wider_info = hash_storage_info(\%wide);
    cmp_ok($wider_info->{entry_capacity}, '>=', 65_536,
       'known-size reservation crosses 65,535 HE positions');
    is($wider_info->{index_width}, 4,
       'chain links widen to four bytes above 65,535 HE positions');
    is($wider_info->{link_bytes},
       $wider_info->{entry_capacity}
           * ($wider_info->{index_width} + $wider_info->{fingerprint_bits} / 8),
       'four-byte chain-link allocation includes fingerprint storage');
    SKIP: {
        skip 'Perl not compiled with useithreads', 1
            unless $Config{useithreads};
        require threads;
        my $snapshot = clone_integer_chain_state(\%wide);
        is_deeply($snapshot, [
            1, 4, $wider_info->{fingerprint_bits}, $wider_info->{link_bytes},
            $wider_info->{fullchains},
            $wider_info->{entry_holes},
            [sort map { ref($_) ? @$_ : () } @{bucket_array(\%wide)}],
            [sort keys %wide],
        ], 'thread clone retains four-byte chains after the width transition');
    }
}
else {

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
}

if ($info->{integer_chained}) {
    my %small_churn;
    keys %small_churn = 8;
    my $capacity = hash_storage_info(\%small_churn)->{entry_capacity};
    my @keys = map { "small-churn:$_" } 0 .. $capacity - 1;
    $small_churn{$keys[$_]} = $_ for 0 .. $#keys;
    my $hole_count = int($capacity / 5) + 1;
    delete $small_churn{$keys[$_]} for 0 .. $hole_count - 1;
    is(hash_storage_info(\%small_churn)->{entry_holes}, $hole_count,
       'small full chain table retains deleted positions before insertion');
    $small_churn{'small-churn:replacement'} = 100;
    my $after_churn = hash_storage_info(\%small_churn);
    is($after_churn->{entry_holes}, 0,
       'small full chain table compacts holes when its entry budget fills');
    is($after_churn->{entry_used}, $after_churn->{live},
       'small-table compaction leaves no unused HE positions');
    cmp_ok($after_churn->{entry_capacity}, '<=', 16_384,
       'small-table compaction keeps HE capacity within the coupled limit');
    is($small_churn{'small-churn:replacement'}, 100,
       'small-table compaction preserves the newly inserted value');
}

done_testing();
