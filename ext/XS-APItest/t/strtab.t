use strict;
use warnings;
use Config;
use Test::More;
use XS::APItest;

my $class = 'XS::APItest::Strtab';
my $a = $class->new;
my $b = $class->new;
is_deeply($a->info, [0, 0, 0, 0], 'empty table is lazy');
is($a->find('missing'), 0, 'missing lookup does not allocate');
is_deeply($a->info, [0, 0, 0, 0], 'lookup preserves empty table');
my $key = $a->share("key\0tail");
is($a->share("key\0tail"), $key, 'duplicate acquisition preserves HEK identity');
is($a->refcount("key\0tail"), 2, 'duplicate acquisition owns a reference');
isnt($b->share("key\0tail"), $key, 'tables have independent key ownership');
ok($a->release("key\0tail"), 'release by bytes succeeds');
is($a->find("key\0tail"), $key, 'nonfinal release preserves identity');
ok($a->release("key\0tail"), 'final release succeeds');
is($a->find("key\0tail"), 0, 'final release removes key');
ok(!$a->release('missing'), 'missing release reports failure');
my $utf8 = $a->share('same bytes', 1);
my $bytes = $a->share('same bytes', 0);
isnt($utf8, $bytes, 'encoding flags participate in key identity');
$a->release('same bytes', 1);
$a->release('same bytes', 0);

subtest 'collisions and wraparound' => sub {
    my $table = $class->new;
    my @pointers = map { $table->share("collision:$_", 0, 32767) } 0..511;
    ok($table->release("collision:$_", 0, 32767), "release collision $_") for 0..255;
    is($table->find("collision:$_", 0, 32767), $pointers[$_],
       "probe crosses deleted slots for $_") for 256..511;
    $table->share("replacement:$_", 0, 32767) for 0..255;
    is($table->info->[1], 512, 'replacements preserve distinct population');
    $table->release("collision:$_", 0, 32767) for 256..511;
    $table->release("replacement:$_", 0, 32767) for 0..255;
    is_deeply($table->free, [0, 0], 'all collision owners released');
};

subtest 'growth preserves pointers and pins' => sub {
    my $table = $class->new;
    my $held = $table->share('held');
    $table->pin('held');
    my $before = $table->info->[0];
    $table->reserve(40000);
    cmp_ok($table->info->[0], '>', $before, 'reservation grows the index');
    is($table->find('held'), $held, 'reservation preserves HEK address');
    $table->share('held');
    $table->pin('held');
    is($table->refcount('held'), 2, 'repeated pins own separate references');
    is_deeply($table->free, [0, 0], 'destruction releases all intentional pins');
};

subtest 'half-full tombstone reuse and cleanup' => sub {
    my $table = $class->new;
    my @pointers = map { $table->share("slot:$_", 0, $_) } 0..16383;
    my $before = $table->info;
    $table->release('slot:0', 0, 0);
    $table->share('slot:0', 0, 0);
    is($table->info->[0], $before->[0], 'half-full tombstone reuse retains capacity');
    is($table->info->[3], $before->[3], 'half-full tombstone reuse retains allocation');
    $table->share('grow', 0, 16384);
    is($table->info->[0], 65536, 'fresh slot at half occupancy doubles capacity');
    is($table->find('slot:16383', 0, 16383), $pointers[16383], 'growth preserves identity');
    $table->release("slot:$_", 0, $_) for 0..16383;
    $table->release('grow', 0, 16384);
    # Disjoint batches force tombstones to occupy half the table, then clean it.
    my $cleaned = 0;
    for my $batch (0..5) {
        my $previous = $table->info->[3];
        for my $i (0..16383) {
            my $hash = 20000 + 16384 * $batch + $i;
            $table->share("churn:$batch:$i", 0, $hash);
            $table->release("churn:$batch:$i", 0, $hash);
        }
        $cleaned ||= $table->info->[3] != $previous;
    }
    ok($cleaned, 'tombstone-heavy churn rebuilds the allocation');
    is($table->info->[0], 65536, 'cleanup retains capacity');
    is_deeply($table->free, [0, 0], 'churn leaves no owners');
};

subtest 'capacity and reference-count boundaries' => sub {
    my $table = $class->new;
    $table->share('kept');
    my $before = $table->info;
    eval { $table->reserve(1431655766) };
    like($@, qr/Hash key count exceeds limit/, 'oversized reserve is rejected');
    is_deeply($table->info, $before, 'failed reserve preserves table state');
    is(XS::APItest::Strtab::capacity_for(1431655766), 0, 'capacity arithmetic rejects excess keys');
    $table->set_refcount('kept', 0xffffffff);
    eval { $table->share('kept') };
    like($@, qr/memory wrap/, 'reference acquisition cannot wrap');
    $table->set_refcount('kept', 1);
    my $live = $table->set_live(1431655765);
    is($table->share('kept'), $table->find('kept'), 'existing key can gain a reference at capacity');
    $table->set_live($live);
    is_deeply($table->free, [1, 2], 'explicit free reports outstanding owners');
};

$a->release("same bytes", 0);
$b->release("key\0tail");
is_deeply($a->free, [0, 0], 'first isolated table is fully released');
is_deeply($b->free, [0, 0], 'second isolated table is fully released');

subtest 'UV arguments cannot wrap the table size' => sub {
    plan skip_all => 'requires UV wider than Size_t'
        unless $Config{uvsize} > $Config{ptrsize};
    my $table = $class->new;
    my $before = $table->info;
    my $oversized = 4294967296;
    is(XS::APItest::Strtab::capacity_for($oversized), 0,
       'capacity arithmetic rejects a value wider than Size_t');
    eval { $table->reserve($oversized) };
    like($@, qr/memory wrap/, 'reserve rejects an unrepresentable size');
    eval { $table->set_live($oversized) };
    like($@, qr/memory wrap/, 'population probe rejects an unrepresentable size');
    is_deeply($table->info, $before, 'rejected sizes preserve the table');
};

subtest 'table ownership stays in the creating interpreter' => sub {
    plan skip_all => 'requires ithreads' unless $Config{useithreads};
    require threads;
    my $table = $class->new;
    my $held = $table->share('parent key');
    ok(threads->create(sub {
        my ($copy) = @_;
        return ref($copy) eq 'SCALAR' && !defined $$copy;
    }, $table)->join, 'child receives no owning table handle');
    is($table->find('parent key'), $held, 'child destruction preserves parent table');
    $table->release('parent key');
    is_deeply($table->free, [0, 0], 'parent releases its own table');
};
done_testing;
