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
        skip('hash_storage_info unavailable', 15);
    }
    my %storage;
    $storage{"struct:$_"} = $_ for 0 .. 15;
    my $info = Hash::Util::hash_storage_info(\%storage);
    skip('hash is not open-addressed', 15) unless $info->{open_addressed};

    is($info->{hash_bytes}, 0, 'index has no cached-hash array');
    is($info->{slot_size}, $info->{index_width},
       'index slot contains only the adaptive-width entry identifier');
    is($info->{entry_index_bytes},
       $info->{index_capacity} * $info->{index_width},
       'index allocation stores one identifier per slot');
    is($info->{index_bytes}, $info->{metadata_bytes} + $info->{entry_index_bytes},
       'index bytes include metadata and identifier array only');

    my ($index_only, $entries_only) = (0, 0);
    my $next = 16;
    while ($next < 100_000 && (!$index_only || !$entries_only)) {
        my @before = @$info{qw(index_capacity entry_capacity entries_address index_address)};
        my $id = $next++;
        $storage{"struct:$id"} = $id;
        $info = Hash::Util::hash_storage_info(\%storage);
        my @after = @$info{qw(index_capacity entry_capacity entries_address index_address)};
        $index_only = 1 if $after[0] > $before[0]
            && $after[1] == $before[1] && $after[2] == $before[2];
        $entries_only = 1 if $after[1] > $before[1]
            && $after[0] == $before[0] && $after[3] == $before[3];
    }
    ok($index_only, 'index grows while entry capacity and address stay fixed');
    ok($entries_only, 'entry vector grows while index capacity and address stay fixed');

    if (length(pack('P', 0)) == 8) {
        is($info->{he_size}, 2 * length(pack('P', 0)), 'HE is two pointers on 64-bit');
        is($info->{hv_size}, 24, 'HV size is unchanged on 64-bit');
        is($info->{hv_body_size}, 32, 'XPVHV size is unchanged on 64-bit');
    }
    else { skip('64-bit structure sizes', 3) }

    while ($info->{index_capacity} < 4096) {
        my $id = $next++;
        $storage{"struct:$id"} = $id;
        $info = Hash::Util::hash_storage_info(\%storage);
    }
    my $limit = int($info->{index_capacity} * 2 / 3) - 1;
    while ($info->{live} < $limit) {
        my $id = $next++;
        $storage{"struct:$id"} = $id;
        $info = Hash::Util::hash_storage_info(\%storage);
    }
    delete $storage{"struct:$_"} for 0 .. 999;
    $info = Hash::Util::hash_storage_info(\%storage);
    cmp_ok($info->{tombstones}, '>', 0, 'deletion leaves index tombstones');
    is($info->{free_list_length}, 1000, 'deleted entry records join the freelist');
    my $entry_used = $info->{entry_used};
    for my $i (0 .. 999) { $storage{"replacement:$i"} = $i }
    $info = Hash::Util::hash_storage_info(\%storage);
    is($info->{entry_used}, $entry_used, 'deleted entry records are reused');
    is($info->{free_list_length}, 0, 'reused entries leave the freelist empty');
    cmp_ok($info->{tombstones}, '<', 1000, 'insertion rebuilds tombstones');
    my $correct = 1;
    $correct &&= $storage{"replacement:$_"} == $_ for 0 .. 999;
    ok($correct, 'keys remain correct after tombstone rebuild and reuse');
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
