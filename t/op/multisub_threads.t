#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    @INC = '../lib';
}

use strict;
use warnings;
use Config;
use feature qw(multisub current_sub class);
no warnings qw(experimental::multisub experimental::class);

skip_all('threads are not available') unless $Config{useithreads};
skip_all_without_dynamic_extension('threads');
require threads;

multi sub shared("ok", $value) {
    return [$value, join(',', @_), __SUB__ == \&shared];
}

multi sub shared("closure", $value) {
    return sub { ++$value };
}

my @workers = map {
    my $value = $_;
    threads->create(sub { shared('ok', $value) });
} (10, 20);

for my $i (0..$#workers) {
    my $value = ($i + 1) * 10;
    my $row = $workers[$i]->join;
    is(join(',', @$row), "$value,ok,$value,1",
        'cloned CV preserves arguments, bindings, and public identity');
}

my $closure = shared('closure', 40);
my $cloned = threads->create(sub { $closure->() });
is($cloned->join, 41, 'escaped clause closure survives thread cloning');
is($closure->(), 41, 'child closure mutation does not change parent state');

my $compiled = threads->create(sub {
    return eval q{
        no warnings 'shadow';
        my $setting = 'first';
        multi sub child_group("a") { eval '$setting' }
        my $setting = 'second';
        multi sub child_group("b") { eval '$setting' }
        join ',', child_group('a'), child_group('b');
    };
});
is($compiled->join, 'first,second', 'child compilation preserves clause lexical lookup');

role ThreadMultiRole {
    field $base = 40;
    multi method answer($value if $value < 10) { [$base + $value, $self, __SUB__, [@_]] }
    multi method answer($value) { [$value, $self, __SUB__, [@_]] }
}
class ThreadMultiConsumer :implements(ThreadMultiRole) { field $prefix = 100 }

my $method_thread = threads->create(sub {
    my $object = ThreadMultiConsumer->new;
    my $row = $object->answer(2);
    return join(',', $row->[0], $row->[1] == $object,
        $row->[2] == $object->can('answer'), @{$row->[3]});
});
is($method_thread->join, '42,1,1,2',
    'threaded composed multi methods preserve fields, self, identity, and explicit arguments');

done_testing();
