#!perl -w

use strict;
use utf8;
use Tie::Hash;
use Test::More;
use Config;

BEGIN {use_ok('XS::APItest')};

sub preform_test;
sub test_present;
sub test_absent;
sub test_delete_present;
sub test_delete_absent;
sub brute_force_exists;
sub test_store;
sub test_fetch_present;
sub test_fetch_absent;

my $utf8_for_258 = chr 258;
utf8::encode $utf8_for_258;

my @testkeys = ('N', chr utf8::unicode_to_native(198), chr 256);
my @keys = (@testkeys, $utf8_for_258);

foreach (@keys) {
  utf8::downgrade $_, 1;
}
main_tests (\@keys, \@testkeys, '');

foreach (@keys) {
  utf8::upgrade $_;
}
main_tests (\@keys, \@testkeys, ' [utf8 hash]');

{
  my %h = (a=>'cheat');
  tie %h, 'Tie::StdHash';
  # is bug 36327 fixed?
  my $result = ($] > 5.009) ? undef : 1;

  is (XS::APItest::Hash::store(\%h, chr 258,  1), $result);

  ok (!exists $h{$utf8_for_258},
      "hv_store doesn't insert a key with the raw utf8 on a tied hash");
}

{
    my $strtab = strtab();
    is (ref $strtab, 'HASH', "The shared string table quacks like a hash");
    my $wibble = "\0";
    eval {
	$strtab->{$wibble}++;
    };
    my $prefix = "Cannot modify shared string table in hv_";
    my $what = $prefix . 'fetch';
    like ($@, qr/^$what/,$what);
    eval {
	XS::APItest::Hash::store($strtab, 'Boom!',  1)
    };
    $what = $prefix . 'store';
    like ($@, qr/^$what/, $what);
    if (0) {
	A::B->method();
    }
    # DESTROY should be in there.
    eval {
	delete $strtab->{DESTROY};
    };
    $what = $prefix . 'delete';
    like ($@, qr/^$what/, $what);
    # I can't work out how to get to the code that flips the wasutf8 flag on
    # the hash key without some ikcy XS
}

{
    require Hash::Util;
    my $strtab = strtab();
    is_deeply([Hash::Util::bucket_info(undef)], [],
       'bucket_info does not expose the shared-key table');
    is_deeply([Hash::Util::bucket_array(undef)], [],
       'bucket_array does not expose the shared-key table');
    is_deeply([Hash::Util::bucket_info($strtab)], [],
       'bucket_info rejects an explicit shared-key table reference');
    is_deeply([Hash::Util::bucket_array($strtab)], [],
       'bucket_array rejects an explicit shared-key table reference');

    my $strtab_info = XS::APItest::Hash::shared_key_storage_info();
    cmp_ok($strtab_info->[0], '>=', 32768,
           'shared-key table reserves at least 16K keys');
    is($strtab_info->[3], length(pack('p', '')),
       'shared-key slots are HEK pointers');
    cmp_ok($strtab_info->[5], '<=', $strtab_info->[0],
           'private APItest probe distance is bounded by table capacity');
    cmp_ok($strtab_info->[6], '>=', $strtab_info->[5],
           'private APItest total probe distance includes its maximum');

    my $ordinary_info_error;
    eval { Hash::Util::hash_storage_info(strtab()) };
    $ordinary_info_error = $@;
    like($ordinary_info_error, qr/PL_strtab/,
         'ordinary hash diagnostics reject PL_strtab');

    my $probe = XS::APItest::Hash::test_shared_hek_probe(
        "xperl-strtab-ref-probe-$$", 0);
    ok($probe->[3], 'duplicate interning returns the same shared HEK');
    is_deeply([@$probe[4..6]], [1, 2, 1],
              'shared HEK reference counts track duplicate interning');
    is($probe->[12], $probe->[11] + 1,
       'unsharing the last reference leaves one tombstone');
    cmp_ok($probe->[13], '<', $probe->[12],
           'reinterning a deleted key reuses or rebuilds its tombstone');

    my $binary_probe = XS::APItest::Hash::test_shared_hek_probe(
        "xperl\0strtab-$$", 0);
    ok($binary_probe->[3] && $binary_probe->[9] == length("xperl\0strtab-$$"),
       'shared HEKs preserve embedded NUL bytes');

    my $latin1 = "\x{e9}";
    utf8::upgrade($latin1);
    my $latin1_probe = XS::APItest::Hash::test_shared_hek_probe($latin1, 0);
    ok(!$latin1_probe->[7] && $latin1_probe->[8],
       'UTF-8 Latin-1 keys retain the shared HEK WASUTF8 flag');
    my $wide = "\x{100}";
    utf8::upgrade($wide);
    my $wide_probe = XS::APItest::Hash::test_shared_hek_probe($wide, 0);
    ok($wide_probe->[7] && !$wide_probe->[8],
       'wide shared keys retain the UTF8 HEK flag');

    my $growth_key = "xperl-strtab-growth-probe-$$";
    my $growth_limit = $strtab_info->[0];
    my $growth = XS::APItest::Hash::test_shared_hek_probe(
        $growth_key, $growth_limit);
    ok($growth->[2], 'interning enough keys grows PL_strtab');
    ok($growth->[3], 'the held shared HEK pointer survives table growth');
    is_deeply([@$growth[4..6]], [1, 2, 1],
              'reference counts remain correct across table growth');
    ok($growth->[14] > 0, 'growth probe retained keys across the resize');
    ok($growth->[16], 'tombstone pressure triggers a same-size table rebuild');
    is($growth->[15], 0, 'tombstone rebuild clears old deleted slots');
    cmp_ok($growth->[17], '>=', $growth->[18],
           'shared-key cleanup starts when tombstones reach half of occupied slots');

    if ($Config::Config{useithreads} && eval { require threads; 1 }) {
        my $thread_key = "xperl-strtab-thread-key-$$";
        my %thread_hash = ($thread_key => 1);
        my $thread = threads->create(sub {
            my ($hash) = @_;
            my ($key) = keys %$hash;
            my $before = Hash::Util::shared_key_refcount($key);
            my $probe = XS::APItest::Hash::test_shared_hek_probe($key, 0);
            return [$probe->[3], $probe->[4] - $before,
                    $probe->[5] - $before, $probe->[6] - $before];
        }, \%thread_hash);
        is_deeply($thread->join, [1, 1, 2, 1],
                  'thread clone probe preserves HEK identity and refcount deltas');
        is($thread_hash{$thread_key}, 1,
           'thread shared-key probe leaves the source hash unchanged');
    }
    else {
        pass('thread shared-key probe is skipped without ithreads');
        pass('thread shared-key source check is skipped without ithreads');
    }

    my $plain_ascii = "xperl-unsharepvn-plain-$$";
    my $utf8_ascii = "xperl-unsharepvn-utf8-ascii-$$";
    utf8::upgrade($utf8_ascii);
    my $downgradable = "\x{e9}xperl-unsharepvn-$$";
    utf8::upgrade($downgradable);
    my $wide_key = "\x{100}xperl-unsharepvn-$$";
    utf8::upgrade($wide_key);
    my $nul_key = "xperl\0unsharepvn-$$";
    my $wide_bytes = $wide_key;
    utf8::encode($wide_bytes);
    my @unsharepvn_cases = (
        ['plain ASCII', $plain_ascii, 0, 0, length($plain_ascii)],
        ['UTF8 flagged ASCII', $utf8_ascii, 0, 0, length($utf8_ascii)],
        ['downgradable UTF8', $downgradable, 0, 1,
         1 + length('xperl-unsharepvn-' . $$)],
        ['wide UTF8', $wide_key, 1, 0, length($wide_bytes)],
        ['embedded NUL', $nul_key, 0, 0, length($nul_key)],
    );
    for my $case (@unsharepvn_cases) {
        my ($label, $key, $expect_utf8, $expect_wasutf8, $expect_len) = @$case;
        my $result = XS::APItest::Hash::test_unsharepvn_refcount($key);
        is_deeply([@$result[0..2]], [1, 2, 1],
                  "unsharepvn decrements the canonical HEK refcount for $label");
        is_deeply([@$result[3..5]],
                  [$expect_utf8, $expect_wasutf8, $expect_len],
                  "unsharepvn canonicalizes $label consistently with share_hek");
    }
}

{
    is_deeply([&XS::APItest::Hash::test_hv_free_ent], [2,2,1,1],
	      "hv_free_ent frees the value immediately");
    is_deeply([&XS::APItest::Hash::test_hv_delayfree_ent], [2,2,2,1],
	      "hv_delayfree_ent keeps the value around until FREETMPS");
}

foreach my $in ("", "N", "a\0b") {
    my $got = XS::APItest::Hash::test_share_unshare_pvn($in);
    is ($got, $in, "test_share_unshare_pvn");
}

{
    foreach ([\&XS::APItest::Hash::rot13_hash, \&rot13, "rot 13"],
	     [\&XS::APItest::Hash::bitflip_hash, \&bitflip, "bitflip"],
	    ) {
	my ($setup, $mapping, $name) = @$_;
	my %hash;
	my %placebo = (a => 1, p => 2, i => 4, e => 8);
	$setup->(\%hash);
	$hash{a}++; @hash{qw(p i e)} = (2, 4, 8);

	test_U_hash(\%hash, \%placebo, [f => 9, g => 10, h => 11], $mapping,
		    $name);
    }
    foreach my $upgrade_o (0, 1) {
	foreach my $upgrade_n (0, 1) {
	    my (%hash, %placebo);
	    XS::APItest::Hash::bitflip_hash(\%hash);
	    foreach my $new (["7", utf8::unicode_to_native(65),
                                   utf8::unicode_to_native(67),
                                   utf8::unicode_to_native(80)
                             ],
			     ["8", utf8::unicode_to_native(163),
                                   utf8::unicode_to_native(171),
                                   utf8::unicode_to_native(215)
                             ],
			     ["U", 2603, 2604, 2604],
                ) {
		foreach my $code (utf8::unicode_to_native(78),
                                  utf8::unicode_to_native(240),
                                  256,
                                  1336
                ) {
		    my $key = chr $code;
		    # This is the UTF-8 byte sequence for the key.
		    my $key_utf8 = $key;
		    utf8::encode($key_utf8);
		    if ($upgrade_o) {
			$key .= chr 256;
			chop $key;
		    }
		    $hash{$key} = $placebo{$key} = $code;
		    $hash{$key_utf8} = $placebo{$key_utf8} = "$code as UTF-8";
		}
		my $name = 'bitflip ' . shift @$new;
		my @new_kv;
		foreach my $code (@$new) {
		    my $key = chr $code;
		    if ($upgrade_n) {
			$key .= chr 256;
			chop $key;
		    }
		    push @new_kv, $key, $_;
		}

		$name .= ' upgraded(orig) ' if $upgrade_o;
		$name .= ' upgraded(new) ' if $upgrade_n;
		test_U_hash(\%hash, \%placebo, \@new_kv, \&bitflip, $name);
	    }
	}
    }
}

sub test_precomputed_hashes {
    my $what = shift;
    my $hash_it = shift;
    my $ord = shift;
    my $key_copy = $_[0];
    $key_copy .= '';

    my %hash;
    is (XS::APItest::Hash::common({hv => \%hash,
				   "key$what" => $_[0],
				   val => $ord,
				   "hash_$what" => $hash_it,
				   action => XS::APItest::HV_FETCH_ISSTORE}),
	$ord, "store $ord with $what \$hash_it = $hash_it");
    is_deeply ([each %hash], [$_[0], $ord], "First key read is good");
    is_deeply ([each %hash], [], "No second key good");
    
    is ($hash{$_[0]}, $ord, "Direct hash read finds $ord");

    is_deeply ([each %hash], [$key_copy, $ord],
	       "First key read is good with a copy");
    is_deeply ([each %hash], [], "No second key good");
    
    is ($hash{$key_copy}, $ord, "Direct hash read finds $ord");
}

{
    my $as_utf8 = "\241" . chr 256;
    chop $as_utf8;
    my $as_bytes = "\243";
    foreach my $key ('N', $as_bytes, $as_utf8, "\x{2623}") {
	my $ord = ord $key;
	foreach my $hash_it (0, 1) {
	    foreach my $what (qw(pv sv)) {
		test_precomputed_hashes($what, $hash_it, $ord, $key);
	    }
	    # Generate a shared hash key scalar
	    my %h = ($key => 1);
	    test_precomputed_hashes('sv', $hash_it, $ord, (keys %h)[0]);
	}
    }
}

{
    no warnings 'experimental::builtin';
    use builtin 'weaken';
    my %h;
    fill_hash_with_nulls(\%h);
    my @objs;
    for("a".."z","A".."Z") {
	weaken($objs[@objs] = $h{$_} = []);
    }
    undef %h;
    no warnings 'uninitialized';
    local $" = "";
    is "@objs", "",
      'explicitly undeffing a hash with nulls frees all entries';

    my $h = {};
    fill_hash_with_nulls($h);
    @objs = ();
    for("a".."z","A".."Z") {
	weaken($objs[@objs] = $$h{$_} = []);
    }
    undef $h;
    is "@objs", "", 'freeing a hash with nulls frees all entries';
}

# Tests for HvENAME and UTF8
{
    no strict;
    no warnings 'void';
    my $hvref;

    *{"\xff::bar"}; # autovivify %ÿ:: without UTF8
    *{"\xff::bαr::"} = $hvref = \%foo::;
    undef *foo::;
    is HvENAME($hvref), "\xff::bαr",
	'stash alias (utf8 inside bytes) does not create malformed UTF8';

    *{"é::foo"}; # autovivify %é:: with UTF8
    *{"\xe9::\xe9::"} = $hvref = \%bar::;
    undef *bar::;
    is HvENAME($hvref), "\xe9::\xe9",
	'stash alias (bytes inside utf8) does not create malformed UTF8';

    *{"\xfe::bar"}; *{"\xfd::bar"};
    *{"\xfe::bαr::"} = \%goo::;
    *{"\xfd::bαr::"} = $hvref = \%goo::;
    undef *goo::;
    like HvENAME($hvref), qr/^[\xfe\xfd]::bαr\z/,
	'multiple stash aliases (utf8 inside bytes) do not cause bad UTF8';

    *{"è::foo"}; *{"ë::foo"};
    *{"\xe8::\xe9::"} = $hvref = \%bear::;
    *{"\xeb::\xe9::"} = \%bear::;
    undef *bear::;
    like HvENAME($hvref), qr"^[\xe8\xeb]::\xe9\z",
	'multiple stash aliases (bytes inside utf8) do not cause bad UTF8';
}

{ # newHVhv
    use Tie::Hash;
    tie my %h, 'Tie::StdHash';
    %h = 1..10;
    is join(' ', sort %{newHVhv \%h}), '1 10 2 3 4 5 6 7 8 9',
      'newHVhv on tied hash';
}

{
    my %source;
    disable_hv_sharekeys(\%source);
    $source{plain} = 'unshared value';
    my $utf8_key = "wide:\x{100}";
    utf8::upgrade($utf8_key);
    $source{$utf8_key} = 'UTF-8 value';

    my $copy = newHVhv \%source;
    is($copy->{plain}, 'unshared value', 'newHVhv copies unshared keys');
    is($copy->{$utf8_key}, 'UTF-8 value', 'newHVhv copies UTF-8 key value');
    my ($copy_key) = grep { $_ eq $utf8_key } keys %$copy;
    ok(defined($copy_key) && utf8::is_utf8($copy_key),
       'newHVhv preserves UTF-8 key flag');
}

{
    my %hash;
    {
        my $original_key = chr 0xE9;
        utf8::upgrade($original_key);
        $hash{$original_key} = 'original';
    }
    ok(store_using_raw_entry_key(\%hash),
       'raw-key replacement targets a key marked WASUTF8');
    my $byte_key = pack 'C', 0xE9;
    ok(!utf8::is_utf8($byte_key), 'replacement lookup key is byte encoded');
    is($hash{$byte_key}, 'rewritten',
       'replacement is safe when the key pointer aliases the old HEK');
}

{
    my %source = (first => 1, second => 2, third => 3);
    my ($current) = each %source;
    delete $source{$current};
    my $copy = newHVhv \%source;
    is_deeply([sort keys %$copy], [sort grep { $_ ne $current } qw(first second third)],
              'newHVhv copies entries around a lazy-deleted iterator entry');
    my ($next) = each %source;
    ok(defined($next) && $next ne $current && exists $source{$next},
       'newHVhv leaves the source iterator safe to continue');
}

{
    package XSAPITestHintsGrow;
    our ($hash, $fetches);
    sub TIESCALAR { bless {}, shift }
    sub FETCH {
        ++$fetches;
        $hash->{"hints-grow-$_"} = $_ for 1..200;
        return 'magical value';
    }
    package main;

    my %source = (first => 1, second => 2, third => 3);
    my ($current) = each %source;
    delete $source{$current};
    tie my $magical, 'XSAPITestHintsGrow';
    $XSAPITestHintsGrow::hash = \%source;
    $XSAPITestHintsGrow::fetches = 0;
    my $copy = copy_hints_hv_with_tied_value(\%source, \$magical);
    is($copy->{trigger}, 'magical value',
       'hv_copy_hints_hv copies a magical value');
    is($XSAPITestHintsGrow::fetches, 1,
       'hv_copy_hints_hv fetches the magical value once');
    is($source{'hints-grow-200'}, 200,
       'magical value callback grows source hash');

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $next = each %source;
    ok(!defined($next), 'copy leaves source iterator safe after growth');
    like(join('', @warnings), qr/after insertion.*iterator/i,
         'source iterator reports insertion after callback');
}

{
    my %source = (first => 1, second => 2, third => 3);
    my ($current) = each %source;
    delete $source{$current};
    tie my $magical, 'XSAPITestHintsGrow';
    $XSAPITestHintsGrow::hash = \%source;
    $XSAPITestHintsGrow::fetches = 0;
    my $copy = newHVhv_with_tied_value(\%source, \$magical);
    is($copy->{trigger}, 'magical value',
       'newHVhv copies values from a magical non-tied hash');
    is($XSAPITestHintsGrow::fetches, 1,
       'newHVhv fetches a magical value once');
    is($source{'hints-grow-200'}, 200,
       'newHVhv callback grows source hash');
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $next = each %source;
    ok(!defined($next), 'newHVhv leaves the source iterator safe');
}

{
    require Hash::Util;
    my %hash;
    my (@keys, @hashes);
    my $collision;
    for my $i (0..10000) {
        my $key = "collision-policy:$i";
        my $value = Hash::Util::hash_value($key);
        my $home = $value & 7;
        if (!defined $keys[$home]) {
            $keys[$home] = $key;
            $hashes[$home] = $value;
        }
        elsif ($home == 0) {
            $collision = [$key, $value];
        }
        last if $collision && grep(defined, @keys) == 8;
    }
    die 'Could not find keys for the collision-policy test'
        unless $collision && grep(defined, @keys) == 8;
    store_prehashed(\%hash, $keys[0], 0, $hashes[0]);
    keys(%hash) = 4;
    store_prehashed(\%hash, $keys[$_], $_, $hashes[$_]) for 1..5;
    is(Hash::Util::hash_storage_info(\%hash)->{index_capacity}, 8,
       'noncolliding inserts keep the initial index size');
    store_prehashed(\%hash, $keys[$_], $_, $hashes[$_]) for 6..7;
    is(Hash::Util::hash_storage_info(\%hash)->{index_capacity}, 8,
       'noncolliding inserts may fill the whole index');
    ok(!exists $hash{'absent from full index'},
       'unsuccessful lookup terminates when no index slot is empty');
    is($hash{$keys[7]}, 7, 'successful lookup works in a full index');
    store_prehashed(\%hash, $collision->[0], 99, $collision->[1]);
    is(Hash::Util::hash_storage_info(\%hash)->{index_capacity}, 16,
       'a collision grows the index at the two-thirds threshold');

    my %lazy;
    store_prehashed(\%lazy, $keys[0], 0, $hashes[0]);
    keys(%lazy) = 4;
    store_prehashed(\%lazy, $keys[$_], $_, $hashes[$_]) for 1..7;
    my $current = each %lazy;
    delete $lazy{$current};
    store_prehashed(\%lazy, $collision->[0], 99, $collision->[1]);
    my $lazy_info = Hash::Util::hash_storage_info(\%lazy);
    is($lazy_info->{entry_used}, 9,
       'insertion appends while the deleted iterator entry is retained');
    is($lazy_info->{free_list_length}, 0,
       'the lazy-deleted entry stays out of the free list until iterator reset');

    my %sparse_lazy;
    store_prehashed(\%sparse_lazy, $keys[0], 0, $hashes[0]);
    keys(%sparse_lazy) = 4;
    my $sparse_current = each %sparse_lazy;
    delete $sparse_lazy{$sparse_current};
    store_prehashed(\%sparse_lazy, $collision->[0], 99, $collision->[1]);
    store_prehashed(\%sparse_lazy, $keys[$_], $_, $hashes[$_]) for 1..7;
    my $sparse_info = Hash::Util::hash_storage_info(\%sparse_lazy);
    is($sparse_info->{index_capacity}, 8,
       'noncolliding inserts can fill an index with a lazy entry retained');
    is($sparse_info->{entry_used}, 9,
       'one-byte indices encode an entry number above slot capacity');
    is($sparse_info->{index_width}, 1,
       'the full eight-slot index retains one-byte entry indices');
    is($sparse_lazy{$collision->[0]}, 99,
       'lookup works after filling slots around a lazy entry');
}

{
    my %source = map { ("key$_" => $_) } (1..20);
    my ($current) = each %source;
    delete $source{$current};
    $source{$current} = 'reinserted';
    my $warnings = 0;
    local $SIG{__WARN__} = sub {
        ++$warnings;
        $source{"warning-grow-$_"} = $_ for (1..1000);
    };
    my $next = each %source;
    ok(!defined($next), 'insertion stops the active iterator');
    is($warnings, 1, 'iterator insertion warning is emitted once');
    is($source{'warning-grow-1000'}, 1000,
       'warning callback can grow the hash after lazy deletion');
}

{
    package XSAPITestStoreDtor;
    our ($callback, $calls);
    sub new { bless {}, shift }
    sub DESTROY {
        ++$calls;
        my $cb = $callback;
        $callback = undef;
        $cb->() if $cb;
    }
}

{
    my %source = (replace => XSAPITestStoreDtor->new);
    my $replacement = XSAPITestStoreDtor->new;
    my $delete_ran = 0;
    $XSAPITestStoreDtor::callback = sub {
        ++$delete_ran;
        delete $source{replace};
    };
    store_ent_with_callback_owner(\%source, 'replace', $replacement);
    ok(!exists $source{replace},
       'store returns safely when old value destructor deletes the new entry');
    is($delete_ran, 1, 'reentrant store callback ran once');
    is(ref($replacement), 'XSAPITestStoreDtor',
       'failed reentrant store leaves caller value reference valid');
}

# helem and hslice on entry with null value
# This is actually a test for a Perl operator, not an XS API test.  But it
# requires a hash that can only be produced by XS (although recently it
# could be encountered when tying hint hashes).
{
    my %h;
    fill_hash_with_nulls(\%h);
    eval{ $h{84} = 1 };
    pass 'no crash when writing to hash elem with null value';
    eval{ no # silly
	  warnings; # thank you!
	  @h{85} = 1 };
    pass 'no crash when writing to hash elem with null value via slice';
    eval { delete local $h{86} };
    pass 'no crash during local deletion of hash elem with null value';
    eval { delete local @h{87,88} };
    pass 'no crash during local deletion of hash slice with null values';
}

# [perl #111000] Bug number eleventy-one thousand:
#                hv_store should work on hint hashes
eval q{
    BEGIN {
	XS::APItest::Hash::store \%^H, "XS::APItest/hash.t", undef;
	delete $^H{"XS::APItest/hash.t"};
    }
};
pass("hv_store works on the hint hash");

{
    # [perl #79074] HeSVKEY_force loses UTF8ness
    my %hash = ( "\xff" => 1, "\x{100}" => 1 );
    my @keys = sort ( XS::APItest::Hash::test_force_keys(\%hash) );
    is_deeply(\@keys, [ sort keys %hash ], "check HeSVKEY_force()");
}

# Test that mg_copy is called when expected (and not called when not)
# No (other) tests in core will fail if the implementation of `keys %tied_hash`
# is (accidentally) changed to also call hv_iterval() and trigger mg_copy.
# However, this behaviour is visible, and tested by Variable::Magic on CPAN.

{
    my %h;
    my $obj = tie %h, 'Tie::StdHash';
    sv_magic_mycopy(\%h);

    is(sv_magic_mycopy_count(\%h), 0);

    $h{perl} = "rules";

    is(sv_magic_mycopy_count(\%h), 1);

    is($h{perl}, "rules", "found key");

    is(sv_magic_mycopy_count(\%h), 2);

    # keys *doesn't* trigger copy magic, so the count is still 2
    my @flat = keys %h;

    is(sv_magic_mycopy_count(\%h), 2);

    @flat = values %h;

    is(sv_magic_mycopy_count(\%h), 3);

    @flat = each %h;

    is(sv_magic_mycopy_count(\%h), 4);
}

{
    # There are two API variants - hv_delete and hv_delete_ent. The Perl
    # interpreter exclusively uses hv_delete_ent. Only XS code uses hv_delete.
    # Hence the problem case could only be triggered by XS code called on
    # symbol tables, and with particular non-ASCII keys:

    # Deleting a key with WASUTF from a stash used to trigger a use-after free:
    my $key = "\xFF\x{100}";
    chop $key;
    ++$main::{$key};
    is(XS::APItest::Hash::delete(\%main::, $key), 1,
       "hv_delete doesn't trigger a use-after free");

    # Perl code has always used this API, which never had the problem:
    ++$main::{$key};
    is(XS::APItest::Hash::delete_ent(\%main::, $key), 1,
       "hv_delete_ent never triggered a use-after free, but test it anyway");
}

done_testing;
exit;

################################   The End   ################################

sub test_U_hash {
    my ($hash, $placebo, $new, $mapping, $message) = @_;
    my @hitlist = keys %$placebo;
    print "# $message\n";

    my @keys = sort keys %$hash;
    is ("@keys", join(' ', sort($mapping->(keys %$placebo))),
	"uvar magic called exactly once on store");

    is (keys %$hash, keys %$placebo);

    my $victim = shift @hitlist;
    is (delete $hash->{$victim}, delete $placebo->{$victim});

    is (keys %$hash, keys %$placebo);
    @keys = sort keys %$hash;
    is ("@keys", join(' ', sort($mapping->(keys %$placebo))));

    $victim = shift @hitlist;
    is (XS::APItest::Hash::delete_ent ($hash, $victim,
				       XS::APItest::HV_DISABLE_UVAR_XKEY),
	undef, "Deleting a known key with conversion disabled fails (ent)");
    is (keys %$hash, keys %$placebo);

    is (XS::APItest::Hash::delete_ent ($hash, $victim, 0),
	delete $placebo->{$victim},
	"Deleting a known key with conversion enabled works (ent)");
    is (keys %$hash, keys %$placebo);
    @keys = sort keys %$hash;
    is ("@keys", join(' ', sort($mapping->(keys %$placebo))));

    $victim = shift @hitlist;
    is (XS::APItest::Hash::delete ($hash, $victim,
				   XS::APItest::HV_DISABLE_UVAR_XKEY),
	undef, "Deleting a known key with conversion disabled fails");
    is (keys %$hash, keys %$placebo);

    is (XS::APItest::Hash::delete ($hash, $victim, 0),
	delete $placebo->{$victim},
	"Deleting a known key with conversion enabled works");
    is (keys %$hash, keys %$placebo);
    @keys = sort keys %$hash;
    is ("@keys", join(' ', sort($mapping->(keys %$placebo))));

    my ($k, $v) = splice @$new, 0, 2;
    $hash->{$k} = $v;
    $placebo->{$k} = $v;
    is (keys %$hash, keys %$placebo);
    @keys = sort keys %$hash;
    is ("@keys", join(' ', sort($mapping->(keys %$placebo))));

    ($k, $v) = splice @$new, 0, 2;
    is (XS::APItest::Hash::store_ent($hash, $k, $v), $v, "store_ent");
    $placebo->{$k} = $v;
    is (keys %$hash, keys %$placebo);
    @keys = sort keys %$hash;
    is ("@keys", join(' ', sort($mapping->(keys %$placebo))));

    ($k, $v) = splice @$new, 0, 2;
    is (XS::APItest::Hash::store($hash, $k, $v), $v, "store");
    $placebo->{$k} = $v;
    is (keys %$hash, keys %$placebo);
    @keys = sort keys %$hash;
    is ("@keys", join(' ', sort($mapping->(keys %$placebo))));

    @hitlist = keys %$placebo;
    $victim = shift @hitlist;
    is (XS::APItest::Hash::fetch_ent($hash, $victim), $placebo->{$victim},
	"fetch_ent");
    is (XS::APItest::Hash::fetch_ent($hash, $mapping->($victim)), undef,
	"fetch_ent (missing)");

    $victim = shift @hitlist;
    is (XS::APItest::Hash::fetch($hash, $victim), $placebo->{$victim},
	"fetch");
    is (XS::APItest::Hash::fetch($hash, $mapping->($victim)), undef,
	"fetch (missing)");

    $victim = shift @hitlist;
    ok (XS::APItest::Hash::exists_ent($hash, $victim), "exists_ent");
    ok (!XS::APItest::Hash::exists_ent($hash, $mapping->($victim)),
	"exists_ent (missing)");

    $victim = shift @hitlist;
    die "Need a victim" unless defined $victim;
    ok (XS::APItest::Hash::exists($hash, $victim), "exists");
    ok (!XS::APItest::Hash::exists($hash, $mapping->($victim)),
	"exists (missing)");

    is (XS::APItest::Hash::common({hv => $hash, keysv => $victim}),
	$placebo->{$victim}, "common (fetch)");
    is (XS::APItest::Hash::common({hv => $hash, keypv => $victim}),
	$placebo->{$victim}, "common (fetch pv)");
    is (XS::APItest::Hash::common({hv => $hash, keysv => $victim,
				   action => XS::APItest::HV_DISABLE_UVAR_XKEY}),
	undef, "common (fetch) missing");
    is (XS::APItest::Hash::common({hv => $hash, keypv => $victim,
				   action => XS::APItest::HV_DISABLE_UVAR_XKEY}),
	undef, "common (fetch pv) missing");
    is (XS::APItest::Hash::common({hv => $hash, keysv => $mapping->($victim),
				   action => XS::APItest::HV_DISABLE_UVAR_XKEY}),
	$placebo->{$victim}, "common (fetch) missing mapped");
    is (XS::APItest::Hash::common({hv => $hash, keypv => $mapping->($victim),
				   action => XS::APItest::HV_DISABLE_UVAR_XKEY}),
	$placebo->{$victim}, "common (fetch pv) missing mapped");
}

sub main_tests {
  my ($keys, $testkeys, $description) = @_;
  foreach my $key (@$testkeys) {
    my $lckey = ($key eq chr utf8::unicode_to_native(198)) ? chr utf8::unicode_to_native(230) : lc $key;
    my $unikey = $key;
    utf8::encode $unikey;

    utf8::downgrade $key, 1;
    utf8::downgrade $lckey, 1;
    utf8::downgrade $unikey, 1;
    main_test_inner ($key, $lckey, $unikey, $keys, $description);

    utf8::upgrade $key;
    utf8::upgrade $lckey;
    utf8::upgrade $unikey;
    main_test_inner ($key, $lckey, $unikey, $keys,
		     $description . ' [key utf8 on]');
  }

  # hv_exists was buggy for tied hashes, in that the raw utf8 key was being
  # used - the utf8 flag was being lost.
  perform_test (\&test_absent, (chr 258), $keys, '');

  perform_test (\&test_fetch_absent, (chr 258), $keys, '');
  perform_test (\&test_delete_absent, (chr 258), $keys, '');
}

sub main_test_inner {
  my ($key, $lckey, $unikey, $keys, $description) = @_;
  perform_test (\&test_present, $key, $keys, $description);
  perform_test (\&test_fetch_present, $key, $keys, $description);
  perform_test (\&test_delete_present, $key, $keys, $description);

  perform_test (\&test_store, $key, $keys, $description, [a=>'cheat']);
  perform_test (\&test_store, $key, $keys, $description, []);

  perform_test (\&test_absent, $lckey, $keys, $description);
  perform_test (\&test_fetch_absent, $lckey, $keys, $description);
  perform_test (\&test_delete_absent, $lckey, $keys, $description);

  return if $unikey eq $key;

  perform_test (\&test_absent, $unikey, $keys, $description);
  perform_test (\&test_fetch_absent, $unikey, $keys, $description);
  perform_test (\&test_delete_absent, $unikey, $keys, $description);
}

sub perform_test {
  my ($test_sub, $key, $keys, $message, @other) = @_;
  my $printable = join ',', map {ord} split //, $key;

  my (%hash, %tiehash);
  tie %tiehash, 'Tie::StdHash';

  @hash{@$keys} = @$keys;
  @tiehash{@$keys} = @$keys;

  &$test_sub (\%hash, $key, $printable, $message, @other);
  &$test_sub (\%tiehash, $key, $printable, "$message tie", @other);
}

sub test_present {
  my ($hash, $key, $printable, $message) = @_;

  ok (exists $hash->{$key}, "hv_exists_ent present$message $printable");
  ok (XS::APItest::Hash::exists ($hash, $key),
      "hv_exists present$message $printable");
}

sub test_absent {
  my ($hash, $key, $printable, $message) = @_;

  ok (!exists $hash->{$key}, "hv_exists_ent absent$message $printable");
  ok (!XS::APItest::Hash::exists ($hash, $key),
      "hv_exists absent$message $printable");
}

sub test_delete_present {
  my ($hash, $key, $printable, $message) = @_;

  my $copy = {};
  my $class = tied %$hash;
  if (defined $class) {
    tie %$copy, ref $class;
  }
  $copy = {%$hash};
  ok (brute_force_exists ($copy, $key),
      "hv_delete_ent present$message $printable");
  is (delete $copy->{$key}, $key, "hv_delete_ent present$message $printable");
  ok (!brute_force_exists ($copy, $key),
      "hv_delete_ent present$message $printable");
  $copy = {%$hash};
  ok (brute_force_exists ($copy, $key),
      "hv_delete present$message $printable");
  is (XS::APItest::Hash::delete ($copy, $key), $key,
      "hv_delete present$message $printable");
  ok (!brute_force_exists ($copy, $key),
      "hv_delete present$message $printable");
}

sub test_delete_absent {
  my ($hash, $key, $printable, $message) = @_;

  my $copy = {};
  my $class = tied %$hash;
  if (defined $class) {
    tie %$copy, ref $class;
  }
  $copy = {%$hash};
  is (delete $copy->{$key}, undef, "hv_delete_ent absent$message $printable");
  $copy = {%$hash};
  is (XS::APItest::Hash::delete ($copy, $key), undef,
      "hv_delete absent$message $printable");
}

sub test_store {
  my ($hash, $key, $printable, $message, $defaults) = @_;
  my $HV_STORE_IS_CRAZY = 1;

  # We are cheating - hv_store returns NULL for a store into an empty
  # tied hash. This isn't helpful here.

  my $class = tied %$hash;

  # It's important to do this with nice new hashes created each time round
  # the loop, rather than hashes in the pad, which get recycled, and may have
  # xhv_array non-NULL
  my $h1 = {@$defaults};
  my $h2 = {@$defaults};
  if (defined $class) {
    tie %$h1, ref $class;
    tie %$h2, ref $class;
    if ($] > 5.009) {
      # bug 36327 is fixed
      $HV_STORE_IS_CRAZY = undef;
    } else {
      # HV store_ent returns 1 if there was already underlying hash storage
      $HV_STORE_IS_CRAZY = undef unless @$defaults;
    }
  }
  is (XS::APItest::Hash::store_ent($h1, $key, 1), $HV_STORE_IS_CRAZY,
      "hv_store_ent$message $printable");
  ok (brute_force_exists ($h1, $key), "hv_store_ent$message $printable");
  is (XS::APItest::Hash::store($h2, $key,  1), $HV_STORE_IS_CRAZY,
      "hv_store$message $printable");
  ok (brute_force_exists ($h2, $key), "hv_store$message $printable");
}

sub test_fetch_present {
  my ($hash, $key, $printable, $message) = @_;

  is ($hash->{$key}, $key, "hv_fetch_ent present$message $printable");
  is (XS::APItest::Hash::fetch ($hash, $key), $key,
      "hv_fetch present$message $printable");
}

sub test_fetch_absent {
  my ($hash, $key, $printable, $message) = @_;

  is ($hash->{$key}, undef, "hv_fetch_ent absent$message $printable");
  is (XS::APItest::Hash::fetch ($hash, $key), undef,
      "hv_fetch absent$message $printable");
}

sub brute_force_exists {
  my ($hash, $key) = @_;
  foreach (keys %$hash) {
    return 1 if $key eq $_;
  }
  return 0;
}

sub rot13 {
    my @results = map {my $a = $_; $a =~ tr/A-Za-z/N-ZA-Mn-za-m/; $a} @_;
    wantarray ? @results : $results[0];
}

sub bitflip {
    my $flip_bit = ord("A") ^ ord("a");
    my @results = map {join '', map {chr($flip_bit ^ ord $_)} split '', $_} @_;
    wantarray ? @results : $results[0];
}
