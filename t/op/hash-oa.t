#!/usr/bin/perl -w

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use strict;

my %h;
for my $round (0 .. 7) {
    for my $i (0 .. 255) { $h{"round:$round:key:$i"} = [$round, $i] }
    is(scalar keys %h, 256, "churn round $round inserts 256 keys");
    my $deleted = 0;
    for my $i (0 .. 255) {
        my $got = delete $h{"round:$round:key:$i"};
        ++$deleted if $got && $got->[0] == $round && $got->[1] == $i;
    }
    is($deleted, 256, "churn round $round deletes every original value");
    is(scalar keys %h, 0, "churn round $round leaves no keys");
}

my $nul_key = "left\0right";
my $bytes = "caf\xE9";
my $chars = "caf\x{E9}";
utf8::upgrade($chars);
my %canonical = ($nul_key => 'nul', $bytes => 'byte');
is($canonical{$nul_key}, 'nul', 'embedded NUL remains part of key');
is($canonical{"left\0right"}, 'nul', 'embedded NUL lookup uses full key');
$canonical{$chars} = 'character';
is($canonical{$chars}, 'character', 'UTF-8 flagged key can be looked up');
is(scalar keys %canonical, 2, 'byte and UTF-8 forms of same character canonicalize');
my $wide = "wide:\x{100}";
utf8::upgrade($wide);
$canonical{$wide} = 'wide';
is($canonical{$wide}, 'wide', 'multi-byte UTF-8 key can be looked up');

my %held = (anchor => 'before');
my $held_ref = \$held{anchor};
$held{"growth:$_"} = $_ for 0 .. 4095;
$$held_ref = 'after';
is($held{anchor}, 'after', 'lvalue reference remains attached after hash growth');

%h = (map { ("iteration:$_" => $_) } (0 .. 199));
my ($seen, $deleted) = (0, 0);
while (my ($k, $v) = each %h) {
    ++$seen;
    if (!$deleted++) { delete $h{$k} }
}
is($seen, 200, 'deleting current key during each visits every original entry');
is(scalar keys %h, 199, 'iteration deletion removes one key');

SKIP: {
    skip_without_dynamic_extension('Hash::Util', 3);
    require Hash::Util;
    my %locked = (alpha => 1, beta => 2);
    Hash::Util::lock_keys(\%locked);
    is($locked{alpha}, 1, 'restricted hash permits existing key lookup');
    eval { $locked{gamma} = 3 };
    like($@, qr/locked|restricted/i, 'restricted hash rejects new key');
    delete $locked{alpha};
    ok(!exists $locked{alpha}, 'restricted hash permits deleting existing key');
}

{
    package HashOATied;
    sub TIEHASH { bless { data => {} }, shift }
    sub STORE { $_[0]{data}{$_[1]} = $_[2] }
    sub FETCH { $_[0]{data}{$_[1]} }
    sub DELETE { delete $_[0]{data}{$_[1]} }
    sub CLEAR { %{$_[0]{data}} = () }
    sub EXISTS { exists $_[0]{data}{$_[1]} }
    sub FIRSTKEY { my $s = scalar keys %{$_[0]{data}}; each %{$_[0]{data}} }
    sub NEXTKEY { each %{$_[0]{data}} }
}
tie my %tied, 'HashOATied';
$tied{one} = 1;
is($tied{one}, 1, 'tied hash stores and fetches');
is(delete $tied{one}, 1, 'tied hash deletes');
$tied{two} = 2;
%tied = (three => 3);
is(join(',', keys %tied), 'three', 'tied hash assignment clears and stores');

{
    package HashOADtor;
    our $callback;
    sub new { bless {}, shift }
    sub DESTROY { my $cb = $callback; $callback = undef; $cb->() if $cb }
}

my %reentrant;
$reentrant{replace} = HashOADtor->new;
$HashOADtor::callback = sub { $reentrant{"replace-growth:$_"} = $_ for 0 .. 511 };
$reentrant{replace} = 'replacement';
is($reentrant{replace}, 'replacement', 'replacement survives destructor-driven growth');
is($reentrant{'replace-growth:511'}, 511, 'replacement destructor can grow its hash');

$reentrant{delete} = HashOADtor->new;
$HashOADtor::callback = sub { $reentrant{"delete-growth:$_"} = $_ for 0 .. 511 };
delete $reentrant{delete};
ok(!exists $reentrant{delete}, 'delete completes after destructor-driven growth');
is($reentrant{'delete-growth:511'}, 511, 'delete destructor can grow its hash');

my $clear_destructor_ran = 0;
$reentrant{clear} = HashOADtor->new;
$HashOADtor::callback = sub {
    ++$clear_destructor_ran;
    $reentrant{"clear-growth:$_"} = $_ for 0 .. 511;
};
%reentrant = (fresh => 1);
is($reentrant{fresh}, 1, 'clear completes after destructor-driven growth');
is($clear_destructor_ran, 1, 'clear runs destructor that grows its hash');

SKIP: {
    require Config;
    unless ($Config::Config{useithreads}) { skip('threads are not enabled', 2) }
    if (eval { require threads; 1 }) {
        my %original = (before => 1);
        $original{"clone:$_"} = $_ for 0 .. 511;
        my $thread = threads->create(sub {
            my ($copy) = @_;
            $copy->{before} = 2;
            $copy->{"thread-growth:$_"} = $_ for 0 .. 1023;
            return $copy->{before} + $copy->{"thread-growth:1023"};
        }, \%original);
        is($thread->join, 1025, 'cloned hash grows and works in thread');
        ok(!exists $original{'thread-growth:1023'}, 'thread hash clone does not change original');
    }
    else { skip('threads extension unavailable', 2) }
}

SKIP: {
    unless (eval { require Hash::Util; Hash::Util->can('hash_storage_info') }) {
        skip('hash_storage_info unavailable', 13);
    }
    my %storage;
    $storage{"struct:$_"} = $_ for 0 .. 15;
    my $info = Hash::Util::hash_storage_info(\%storage);
    skip('hash is not open-addressed', 13) unless $info->{open_addressed};

    is($info->{hash_bytes}, 0, 'index has no cached-hash array');
    is($info->{slot_size}, $info->{index_width},
       'index slot contains only the adaptive-width entry identifier');
    is($info->{entry_index_bytes},
       $info->{index_capacity} * $info->{index_width},
       'index allocation stores one identifier per slot');
    is($info->{index_bytes}, $info->{metadata_bytes} + $info->{entry_index_bytes},
       'index bytes include metadata and identifier array only');

    is($info->{entry_capacity}, int(2 * $info->{index_capacity} / 3),
       'indexed entry capacity is two-thirds of index capacity');

    if (length(pack('P', 0)) == 8) {
        is($info->{he_size}, 2 * length(pack('P', 0)), 'HE is two pointers on 64-bit');
        is($info->{hv_size}, 24, 'HV size is unchanged on 64-bit');
        is($info->{hv_body_size}, 32, 'XPVHV size is unchanged on 64-bit');
    }
    else { skip('64-bit structure sizes', 3) }

    my $fill = 0;
    while ($info->{entry_used} < $info->{entry_capacity}) {
        $storage{"fill:$fill"} = $fill++;
        $info = Hash::Util::hash_storage_info(\%storage);
    }
    my @old_keys = keys %storage;
    delete @storage{@old_keys[0 .. 7]};
    my $before_compact = Hash::Util::hash_storage_info(\%storage);
    is($before_compact->{free_list_length}, 0,
       'deletion never places indexed entries on a free list');
    is($before_compact->{entry_used}, $info->{entry_capacity},
       'deletion keeps the append-only entry high-water mark');
    $storage{'replacement'} = 999;
    $info = Hash::Util::hash_storage_info(\%storage);
    is($info->{free_list_length}, 0, 'compaction does not create a free list');
    is($info->{entry_capacity}, int(2 * $info->{index_capacity} / 3),
       'compaction restores the indexed entry capacity ratio');
    my @expected = grep { my $key = $_; !grep { $_ eq $key } @old_keys[0 .. 7] }
        @old_keys;
    push @expected, 'replacement';
    ok(eq_array([keys %storage], \@expected),
       'compaction preserves survivor order and appends the new key');
}

SKIP: {
    unless (eval { require Hash::Util; Hash::Util->can('hash_storage_info') }) {
        skip('hash_storage_info unavailable', 1);
    }
    my $default_mode = <<'PERL';
use strict;
use warnings;
use Hash::Util qw(hash_storage_info);
my %hash;
$hash{"default:$_"} = $_ for 0 .. 3;
my $info = hash_storage_info(\%hash);
die "default did not keep four entries linear\n"
    unless $info->{linear} && !$info->{index_capacity}
        && $info->{entry_capacity} == 4;
$hash{'default:4'} = 4;
$info = hash_storage_info(\%hash);
die "default did not promote after four entries\n"
    unless !$info->{linear} && $info->{index_capacity} == 8
        && keys(%hash) == 5 && $hash{'default:4'} == 4;

my %compact = map { ("compact:$_" => $_) } 0 .. 4;
my $before = hash_storage_info(\%compact);
die "five entries did not fit the initial indexed entry budget\n"
    unless $before->{index_capacity} == 8
        && $before->{entry_capacity} == 5 && $before->{entry_used} == 5;
my @order = keys %compact;
delete $compact{$order[1]};
delete $compact{$order[3]};
my $deleted = hash_storage_info(\%compact);
die "deletion reused an entry position\n"
    unless $deleted->{entry_used} == 5 && !$deleted->{free_list_length};
$compact{replacement} = 99;
my $after = hash_storage_info(\%compact);
die "entry-budget exhaustion did not compact survivors\n"
    unless $after->{index_capacity} == 16 && $after->{entry_capacity} == 10
        && $after->{entry_used} == 4 && !$after->{tombstones}
        && !$after->{free_list_length};
my @expected = grep { $_ ne $order[1] && $_ ne $order[3] } @order;
push @expected, 'replacement';
my @compacted = keys %compact;
die "compaction did not preserve survivor order and append the new key\n"
    unless join("\0", @compacted) eq join("\0", @expected);
die "compaction lost a surviving value\n"
    unless $compact{$order[0]} == 0 && $compact{$order[2]} == 2
        && $compact{$order[4]} == 4 && $compact{replacement} == 99;

my @iterated;
while (my ($key) = each %compact) { push @iterated, $key }
die "iteration order disagrees with compacted entry order\n"
    unless "@iterated" eq "@expected";

my %lazy = map { ("lazy:$_" => $_) } 0 .. 4;
my ($current) = each %lazy;
die "each did not return a current key\n" unless defined $current;
delete $lazy{$current};
my $lazy_deleted = hash_storage_info(\%lazy);
die "current iterator deletion was not retained lazily\n"
    unless $lazy_deleted->{entry_used} == 5
        && $lazy_deleted->{entry_holes} == 1;
$lazy{replacement} = 99;
my $lazy_after = hash_storage_info(\%lazy);
die "insertion after lazy deletion did not compact the entry vector\n"
    unless $lazy_after->{entry_used} == 5
        && !$lazy_after->{entry_holes}
        && !$lazy_after->{tombstones}
        && $lazy{replacement} == 99;
my ($warning, $next_key) = ('', undef);
{
    local $SIG{__WARN__} = sub { $warning .= join '', @_ };
    ($next_key) = each %lazy;
}
die "insertion after lazy iterator deletion did not warn\n"
    unless !defined($next_key) && $warning =~ /each\(\).*insertion.*iterator/i;
die "insertion after lazy deletion lost a key\n" unless keys(%lazy) == 5;
print "ok\n";
PERL
    my ($out, $err);
    {
        local $ENV{PERL_HASH_LINEAR_MAX};
        delete $ENV{PERL_HASH_LINEAR_MAX};
        ($out, $err) = runperl_and_capture({}, ['-I../lib', '-e', $default_mode]);
    }
    is($out, "ok\n",
       'default K=4 and append-and-compact indexed policy behave as designed')
        or diag($err);
}

SKIP: {
    unless (eval { require Hash::Util; Hash::Util->can('hash_storage_info') }) {
        skip('hash_storage_info unavailable', 1);
    }
    my $magic_compaction = <<'PERL';
use strict;
use warnings;
use Hash::Util qw(hash_storage_info);

{
    package OACompactionMagic;
    sub TIESCALAR {
        my ($class, $hash, $key) = @_;
        return bless { hash => $hash, key => $key, value => 'original',
                       changed => 0 }, $class;
    }
    sub FETCH {
        my ($self) = @_;
        unless ($self->{changed}++) {
            $self->{hash}{'growth:' . $self->{key}} = 99;
        }
        return $self->{value};
    }
    sub STORE { $_[0]{value} = $_[1] }
}

sub setup {
    my ($ordinary, @magic) = @_;
    my %hash;
    $hash{"ordinary:$_"} = $_ for 0 .. $ordinary - 1;
    tie $hash{$_}, 'OACompactionMagic', \%hash, $_ for @magic;
    my $before = hash_storage_info(\%hash);
    die "setup did not fill the indexed entry budget\n"
        unless $before->{index_capacity} == 8
            && $before->{entry_capacity} == 5
            && $before->{entry_used} == 5;
    delete $hash{'ordinary:0'};
    delete $hash{'ordinary:1'};
    return \%hash;
}

my $scalar = setup(4, 'target');
{
    local $scalar->{target} = 'localized';
    die "scalar local value was lost\n" unless $scalar->{target} eq 'localized';
}
die "scalar local restoration was lost\n"
    unless $scalar->{target} eq 'original'
        && $scalar->{'growth:target'} == 99;
die "scalar local callback did not compact\n"
    unless hash_storage_info($scalar)->{entry_used} == 4;

my $slice = setup(3, 'target', 'second');
{
    local @{$slice}{qw(target second)} = qw(localized other);
    die "slice local values were lost\n"
        unless $slice->{target} eq 'localized' && $slice->{second} eq 'other';
}
die "slice local restoration was lost\n"
    unless $slice->{target} eq 'original' && $slice->{second} eq 'original'
        && $slice->{'growth:target'} == 99;
die "slice local callback did not compact\n"
    unless hash_storage_info($slice)->{entry_used} == 5
        && $slice->{'growth:target'} == 99
        && $slice->{'growth:second'} == 99;

my $outer = { inner => setup(4, 'target') };
{
    local $outer->{inner}{target} = 'localized';
    die "multideref local value was lost\n"
        unless $outer->{inner}{target} eq 'localized';
}
die "multideref local restoration was lost\n"
    unless $outer->{inner}{target} eq 'original'
        && $outer->{inner}{'growth:target'} == 99;
die "multideref callback did not compact\n"
    unless hash_storage_info($outer->{inner})->{entry_used} == 4;
print "ok\n";
PERL
    my ($out, $err);
    {
        local $ENV{PERL_HASH_LINEAR_MAX};
        delete $ENV{PERL_HASH_LINEAR_MAX};
        ($out, $err) = runperl_and_capture({}, ['-I../lib', '-e', $magic_compaction]);
    }
    is($out, "ok\n", 'localization callbacks survive compaction in indexed hashes')
        or diag($err);
}

SKIP: {
    unless (eval { require Hash::Util; Hash::Util->can('hash_storage_info') }) {
        skip('hash_storage_info unavailable', 1);
    }
    my $independent_growth = <<'PERL';
use strict;
use warnings;
use Hash::Util qw(hash_storage_info);
my %hash;
$hash{"growth:$_"} = $_ for 0 .. 10_921;
my $info = hash_storage_info(\%hash);
die "coupled growth did not reach the two-thirds entry budget\n"
    unless $info->{index_capacity} == 16_384
        && $info->{entry_capacity} == 10_922;
my $next = 10_922;
my $id = $next++;
$hash{"growth:$id"} = $id;
$info = hash_storage_info(\%hash);
die "index growth did not preserve the 1.25 HE growth step\n"
    unless $info->{index_capacity} == 32_768
        && $info->{entry_capacity} == 13_652
        && $info->{entry_used} == 10_923;
my $limit = $info->{entry_capacity};
while ($next < $limit) {
    my $id = $next++;
    $hash{"growth:$id"} = $id;
}
my $last = $next++;
$hash{"growth:$last"} = $last;
$info = hash_storage_info(\%hash);
die "independent HE growth changed the index capacity\n"
    unless $info->{index_capacity} == 32_768
        && $info->{entry_capacity} == 17_065
        && $info->{entry_used} == 13_653;
die "independent growth lost entries\n"
    unless $hash{'growth:0'} == 0 && $hash{"growth:$last"} == $last;
print "ok\n";
PERL
    my ($out, $err) = runperl_and_capture({}, ['-I../lib', '-e', $independent_growth]);
    is($out, "ok\n", 'entry storage grows independently above 16K index slots')
        or diag($err);
}

SKIP: {
    unless (eval { require Hash::Util; Hash::Util->can('hash_storage_info') }) {
        skip('hash_storage_info unavailable', 1);
    }
    my $wide_entry_reuse = <<'PERL';
use strict;
use warnings;
use Hash::Util qw(hash_storage_info);
my %hash;
$hash{"seed:$_"} = $_ for 0 .. 87_380;
my $info = hash_storage_info(\%hash);
die "large table did not reach 131072 slots at two-thirds occupancy\n"
    unless $info->{index_capacity} == 131_072 && $info->{live} == 87_381;
delete $hash{"seed:$_"} for 0 .. 81_380;
die "large-table deletion setup did not leave 6000 entries\n"
    unless keys(%hash) == 6_000;
$hash{'shrink-trigger'} = 99;
$info = hash_storage_info(\%hash);
die "index shrink did not shrink the entry vector with 25 percent spare\n"
    unless $info->{index_capacity} == 32_768
        && $info->{entry_capacity} == 7_500;
for my $i (1 .. 70_000) {
    delete $hash{churn};
    $hash{churn} = $i;
}
$info = hash_storage_info(\%hash);
die "entry identifiers crossed the two-byte high-water limit\n"
    unless $info->{entry_used} < 65_534;
die "churn corrupted survivors or the repeatedly reinserted key\n"
    unless $hash{'seed:81381'} == 81_381
        && $hash{'seed:87380'} == 87_380
        && $hash{'shrink-trigger'} == 99
        && $hash{churn} == 70_000;
print "ok\n";
PERL
    my ($out, $err) = runperl_and_capture({}, ['-I../lib', '-e', $wide_entry_reuse]);
    is($out, "ok\n", 'index shrink also shrinks entries and preserves them through churn')
        or diag($err);
}

SKIP: {
    unless (eval { require Hash::Util; Hash::Util->can('hash_storage_info') }) {
        skip('hash_storage_info unavailable', 1);
    }
    my $optional_compaction = <<'PERL';
use strict;
use warnings;
use Hash::Util qw(hash_storage_info);
my %hash;
$hash{"seed:$_"} = $_ for 0 .. 79_998;
$hash{churn} = 0;
my $info = hash_storage_info(\%hash);
die "setup did not use a 131072-slot index below its load limit\n"
    unless $info->{index_capacity} == 131_072
        && $info->{live} == 80_000
        && $info->{live} + $info->{tombstones} < 87_381;

delete $hash{"seed:$_"} for 0 .. 19_999;
$info = hash_storage_info(\%hash);
my $old_capacity = $info->{entry_capacity};
my $spare = $old_capacity - $info->{entry_used};
for my $i (1 .. $spare) {
    delete $hash{churn};
    $hash{churn} = $i;
}
$info = hash_storage_info(\%hash);
die "HE fill did not reach its budget with sub-MiB holes above 20 percent\n"
    unless $info->{entry_used} == $old_capacity
        && $info->{entry_holes} * 5 >= $old_capacity
        && $info->{entry_holes} * $info->{he_size} < 1_048_576
        && $info->{live} + $info->{tombstones} < 87_381;
delete $hash{churn};
$hash{churn} = 99;
$info = hash_storage_info(\%hash);
my $grown_capacity = $old_capacity + ($old_capacity >> 2);
die "sub-MiB holes caused optional compaction instead of HE growth\n"
    unless $info->{index_capacity} == 131_072
        && $info->{entry_capacity} == $grown_capacity
        && $info->{entry_used} == $old_capacity + 1
        && $info->{entry_holes} * $info->{he_size} < 1_048_576;

delete $hash{"seed:$_"} for 20_000 .. 64_999;
$info = hash_storage_info(\%hash);
$spare = $info->{entry_capacity} - $info->{entry_used};
for my $i (1 .. $spare) {
    delete $hash{churn};
    $hash{churn} = $i;
}
$info = hash_storage_info(\%hash);
die "large-hole setup did not exceed both optional-compaction thresholds\n"
    unless $info->{entry_used} == $info->{entry_capacity}
        && $info->{entry_holes} * 5 >= $info->{entry_capacity}
        && $info->{entry_holes} * $info->{he_size} >= 1_048_576
        && $info->{live} + $info->{tombstones} < 87_381;
my $capacity = $info->{entry_capacity};
delete $hash{churn};
$hash{churn} = 99;
$info = hash_storage_info(\%hash);
die "large holes did not trigger optional compaction\n"
    unless $info->{index_capacity} == 131_072
        && $info->{entry_capacity} == $capacity
        && !$info->{entry_holes}
        && $info->{entry_used} == $info->{live}
        && $hash{'seed:65000'} == 65_000
        && $hash{'seed:79998'} == 79_998
        && $hash{churn} == 99;
print "ok\n";
PERL
    my ($out, $err) = runperl_and_capture({}, ['-I../lib', '-e', $optional_compaction]);
    is($out, "ok\n", 'optional compaction requires both hole thresholds')
        or diag($err);
}

SKIP: {
    unless (eval { require Hash::Util; Hash::Util->can('hash_storage_info') }) {
        skip('hash_storage_info unavailable', 6);
    }
    my %preallocated;
    $preallocated{"prealloc:$_"} = $_ for 0 .. 11_999;
    my $before = Hash::Util::hash_storage_info(\%preallocated);
    ok($before->{index_capacity} == 32_768
       && $before->{entry_capacity} == 13_652
       && $before->{entry_used} == 12_000,
       'sparse hash reaches the expected large-index HE allocation');
    delete $preallocated{"prealloc:$_"} for 0 .. 99;
    $before = Hash::Util::hash_storage_info(\%preallocated);
    is($before->{entry_holes}, 100, 'deletion leaves sparse HE holes');

    keys %preallocated = 30_000;
    my $after = Hash::Util::hash_storage_info(\%preallocated);
    is($after->{index_capacity}, 65_536,
       'keys preallocation grows the index to 65536 slots');
    ok($after->{entry_used} == $before->{entry_used}
       && $after->{entry_capacity} >= 30_100,
       'explicit reservation grows entry space without compacting holes');
    is($after->{entry_holes}, 100,
       'explicit reservation preserves sparse deleted entries');
    ok($preallocated{'prealloc:100'} == 100
       && $preallocated{'prealloc:11999'} == 11_999,
       'explicit reservation preserves existing values');
}

SKIP: {
    unless (eval { require Hash::Util; Hash::Util->can('hash_storage_info') }) {
        skip('hash_storage_info unavailable', 4);
    }
    my $linear_mode = <<'PERL';
use strict;
use warnings;
no warnings 'once';
use Hash::Util qw(hash_storage_info lock_keys);
my $limit = shift;
my %h;
if ($limit) {
    my $empty = hash_storage_info(\%h);
    die "empty hash allocated entry storage\n"
        if $empty->{entry_capacity} || $empty->{entry_bytes}
            || $empty->{requested_bytes} || $empty->{entries_address};
    keys %h;
    each %h;
    $empty = hash_storage_info(\%h);
    die "keys/each allocated empty-hash storage\n"
        if $empty->{entry_capacity} || $empty->{entry_bytes}
            || $empty->{requested_bytes} || $empty->{entries_address};
    for my $i (0 .. $limit - 1) {
        $h{"small:$i"} = $i;
        my $step = hash_storage_info(\%h);
        my $capacity = 1;
        $capacity *= 2 while $capacity < $i + 1;
        my $single_arena = $i == 0;
        die "linear capacity growth failed at $i\n"
            unless $step->{linear} && !$step->{open_addressed}
                && $step->{entry_capacity} == $capacity
                && $step->{entry_used} == $i + 1
                && $step->{entry_spare} == $capacity - $i - 1
                && !$step->{index_capacity}
                && !$step->{metadata_bytes} && !$step->{index_bytes}
                && !$step->{hash_bytes} && !$step->{entry_index_bytes}
                && !$step->{tombstones} && !$step->{free_list_length}
                && !$step->{index_empty} && !$step->{index_deleted}
                && !$step->{probe_total} && !$step->{probe_max}
                && !$step->{probe_mean}
                && ($single_arena
                    ? $step->{arena_backed}
                        && $step->{entry_bytes} == $step->{arena_slot_size}
                        && $step->{arena_slot_size} == $step->{he_size}
                        && $step->{requested_bytes} == $step->{arena_slot_size}
                        && (length(pack('P', 0)) != 8
                            || ($step->{he_size} == 16
                                && $step->{hv_size} == 24
                                && $step->{hv_body_size} == 32
                                && $step->{requested_bytes} + $step->{hv_size}
                                    + $step->{hv_body_size} == 72))
                        && !$step->{allocator_bytes}
                    : !$step->{arena_backed}
                        && $step->{requested_bytes} == $step->{entry_capacity} * $step->{he_size});
    }
}
else { $h{'small:0'} = 0 }
my $before = hash_storage_info(\%h);
if ($limit) {
    die "did not stay in linear mode at the limit\n"
        unless $before->{linear} && !$before->{open_addressed}
            && !$before->{index_capacity}
            && !$before->{metadata_bytes} && !$before->{index_bytes}
            && !$before->{hash_bytes} && !$before->{entry_index_bytes}
            && !$before->{free_list_length}
            && !$before->{tombstones} && $before->{entry_capacity} == $limit
            && $before->{entry_used} == $limit;
    delete $h{'small:0'};
    my $after_delete = hash_storage_info(\%h);
    die "linear deletion did not compact the entry array\n"
        unless $after_delete->{linear} && !$after_delete->{index_capacity}
            && $after_delete->{entry_used} == $limit - 1
            && $after_delete->{live} == $limit - 1
            && keys(%h) == $limit - 1;
    my %singleton = (first => 1, second => 2);
    delete $singleton{second};
    my $one_left = hash_storage_info(\%singleton);
    die "two-to-one deletion did not retain one arena-backed compact HE\n"
        unless $one_left->{arena_backed} && $one_left->{entry_capacity} == 1
            && $one_left->{entry_used} == 1
            && $one_left->{arena_slot_size} == $one_left->{he_size}
            && $one_left->{entry_bytes} == $one_left->{arena_slot_size}
            && (length(pack('P', 0)) != 8
                || ($one_left->{he_size} == 16
                    && $one_left->{hv_size} == 24
                    && $one_left->{hv_body_size} == 32
                    && $one_left->{requested_bytes} + $one_left->{hv_size}
                        + $one_left->{hv_body_size} == 72))
            && $one_left->{entries_address};
    %singleton = ();
    my $cleared = hash_storage_info(\%singleton);
    die "clear retained singleton entry storage\n"
        if $cleared->{entry_capacity} || $cleared->{entry_bytes}
            || $cleared->{requested_bytes} || $cleared->{entries_address};
    $h{'small:replacement'} = 999;
    die "linear insertion before the threshold promoted early\n"
        unless hash_storage_info(\%h)->{linear};
    $h{promote} = 1000;
    my $after_promote = hash_storage_info(\%h);
    die "insertion beyond the threshold did not promote\n"
        unless !$after_promote->{linear} && $after_promote->{index_capacity};
    die "promotion lost entries\n"
        unless $h{'small:replacement'} == 999 && $h{promote} == 1000;
}
else {
    die "zero threshold did not start indexed\n"
        if $before->{linear} || !$before->{index_capacity};
}

my %iter;
$iter{"iter:$_"} = $_ for 0 .. ($limit || 1) - 1;
my $seen = 0;
while (my ($key, $value) = each %iter) {
    ++$seen;
    delete $iter{$key};
}
die "delete-current iteration visited $seen entries\n"
    unless $seen == ($limit || 1) && !keys %iter;

my %iter_change = (current => 7);
my ($current_key) = each %iter_change;
die "each did not return the initial key\n" unless defined $current_key;
delete $iter_change{$current_key};
$iter_change{replacement} = 9;
my ($warning, $next_key) = ('', undef);
{
    local $SIG{__WARN__} = sub { $warning .= join '', @_ };
    ($next_key) = each %iter_change;
}
die "insert-after-delete iterator did not terminate with a warning\n"
    unless !defined($next_key)
        && $warning =~ /each\(\).*insertion.*iterator/i;
die "insert-after-delete lost replacement value\n"
    unless keys(%iter_change) == 1 && $iter_change{replacement} == 9;

my $nul = "left\0right";
my $bytes = "caf\xE9";
my $chars = "caf\x{E9}";
utf8::upgrade($chars);
my %unicode = ($nul => 'nul', $bytes => 'byte');
$unicode{$chars} = 'character';
die "UTF-8/NUL key canonicalization failed\n"
    unless keys(%unicode) == 2 && $unicode{$nul} eq 'nul'
        && $unicode{$chars} eq 'character';

my %restricted = (alpha => 1, beta => 2);
lock_keys(%restricted);
die "restricted hash lookup failed\n" unless $restricted{alpha} == 1;
delete $restricted{alpha};
die "restricted hash deletion failed\n" if exists $restricted{alpha};

{
    package LinearModeTie;
    sub TIEHASH { bless { data => {} }, shift }
    sub STORE { $_[0]{data}{$_[1]} = $_[2] }
    sub FETCH { $_[0]{data}{$_[1]} }
    sub DELETE { delete $_[0]{data}{$_[1]} }
    sub CLEAR { %{$_[0]{data}} = () }
    sub EXISTS { exists $_[0]{data}{$_[1]} }
    sub FIRSTKEY { my $s = scalar keys %{$_[0]{data}}; each %{$_[0]{data}} }
    sub NEXTKEY { each %{$_[0]{data}} }
}
tie my %tied, 'LinearModeTie';
$tied{one} = 1;
die "tied hash access failed\n" unless $tied{one} == 1;
delete $tied{one};
die "tied hash delete failed\n" if exists $tied{one};

{
    package LinearModeDtor;
    our $callback;
    sub new { bless {}, shift }
    sub DESTROY { my $cb = $callback; $callback = undef; $cb->() if $cb }
}
my %reentrant = map { ("reentrant:$_" => $_) } 0 .. ($limit || 1) - 1;
$reentrant{'reentrant:0'} = LinearModeDtor->new;
$LinearModeDtor::callback = sub {
    $reentrant{"growth:$_"} = $_ for 0 .. ($limit || 1);
};
$reentrant{'reentrant:0'} = 'replaced';
die "destructor reentrant growth lost values\n"
    unless $reentrant{'reentrant:0'} eq 'replaced'
        && exists $reentrant{"growth:" . ($limit || 1)};
die "destructor reentrant growth failed to promote\n"
    if $limit && hash_storage_info(\%reentrant)->{linear};

my %clearing;
$clearing{"clear-key:$_"} = $_ for 0 .. ($limit ? $limit - 2 : -1);
$clearing{victim} = LinearModeDtor->new;
my ($clear_dtor_ran, $clear_promoted) = (0, 0);
$LinearModeDtor::callback = sub {
    ++$clear_dtor_ran;
    $clearing{"clear-growth:$_"} = $_ for 0 .. ($limit || 1);
    $clear_promoted = !hash_storage_info(\%clearing)->{linear};
};
%clearing = (fresh => 456);
die "clear did not replace old contents or call the destructor once\n"
    unless $clearing{fresh} == 456 && $clear_dtor_ran == 1
        && !exists $clearing{"clear-growth:" . ($limit || 1)}
        && keys(%clearing) == 1;
die "clear destructor growth did not promote the linear hash\n"
    if $limit && !$clear_promoted;

{
    package LinearModeLocalizeScalar;
    sub TIESCALAR {
        my ($class, $hash, $max) = @_;
        return bless { hash => $hash, max => $max, value => 'original',
                       changed => 0 }, $class;
    }
    sub FETCH {
        my ($self) = @_;
        unless ($self->{changed}++) {
            delete $self->{hash}{'dense:0'} if $self->{max};
            $self->{hash}{"local-growth:$_"} = $_
                for 0 .. ($self->{max} || 1) - 1;
        }
        return $self->{value};
    }
    sub STORE { $_[0]{value} = $_[1] }
}
my %localized;
$localized{"dense:$_"} = $_ for 0 .. ($limit ? $limit - 2 : -1);
tie $localized{target}, 'LinearModeLocalizeScalar', \%localized, $limit;
if ($limit) {
    my $before_local = hash_storage_info(\%localized);
    die "localization setup did not remain linear\n" unless $before_local->{linear};
}
{
    local $localized{target} = 'localized';
}
my $after_local = hash_storage_info(\%localized);
die "localized fetch did not promote after compacting and inserting\n"
    if $limit && ($after_local->{linear} || !$after_local->{index_capacity});
die "localization did not restore or retain callback insertions\n"
    unless $localized{target} eq 'original'
        && $localized{"local-growth:" . (($limit || 1) - 1)}
            == (($limit || 1) - 1);

if (eval { require Config; $Config::Config{useithreads} }) {
    if (eval { require threads; 1 }) {
        my %source;
        $source{"thread:$_"} = $_ for 0 .. ($limit ? $limit - 1 : 0);
        my $thread = threads->create(sub {
            my ($copy, $max) = @_;
            my $initial = hash_storage_info($copy);
            die "thread clone lost its linear state\n"
                if $max && (!$initial->{linear} || $initial->{index_capacity});
            die "thread clone lost its indexed state\n"
                if !$max && ($initial->{linear} || !$initial->{index_capacity});
            $copy->{'thread:promotion'} = 123;
            my $after = hash_storage_info($copy);
            die "thread clone failed to promote or retain values\n"
                if $after->{linear} || !$after->{index_capacity}
                    || $copy->{'thread:promotion'} != 123
                    || $copy->{'thread:0'} != 0;
            return 1;
        }, \%source, $limit);
        die "thread clone returned failure\n" unless $thread->join == 1;
        die "thread growth changed the original\n"
            if exists $source{'thread:promotion'};
    }
}
print "ok\n";
PERL
    for my $limit (0, 2, 4, 8) {
        my ($out, $err) = runperl_and_capture(
            { PERL_HASH_LINEAR_MAX => $limit },
            ['-I../lib', '-e', $linear_mode, $limit]);
        is($out, "ok\n", "linear threshold $limit preserves hash behavior")
            or diag $err;
    }
}

done_testing();
