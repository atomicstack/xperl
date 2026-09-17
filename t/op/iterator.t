#!./perl

BEGIN {
    chdir 't' if -d 't';
    unshift @INC, '../lib';
    require './test.pl';
}

use iterator;
use generator;

plan tests => 33;

my @items = qw(one two three);
my $index = 0;
my $iterator = iterator->new(sub {
    CORE::__SUB__->set_state(iterator::COMPLETED) if $index == $#items;
    return $items[$index++];
});

is(ref($iterator), 'iterator', 'iterator is a blessed coderef');
ok(ref($iterator) eq 'iterator', 'iterator remains a code reference');
ok($iterator->running, 'new iterator is running');
is($iterator->state, iterator::RUNNING, 'new iterator has running state');
is($iterator->(), 'one', 'iterator returns its first value');
ok($iterator->running, 'iterator remains running before final value');
is($iterator->(), 'two', 'iterator returns its second value');
is($iterator->(), 'three', 'iterator returns its final value');
ok($iterator->completed, 'iterator can mark itself completed');
ok($iterator->exhausted, 'completed iterator is exhausted');
is(iterator::state($iterator), iterator::COMPLETED,
   'state package function works');
ok(!iterator::running($iterator), 'running package function sees completion');
ok(!$iterator->restartable, 'ordinary iterators are not restartable by default');
eval { $iterator->restart };
like($@, qr/does not support restarting/,
    'default restart reports unsupported operation');

my $next_val = iterator->new(sub {
    return wantarray ? @_ : $_[0];
});
is($next_val->next_val(11), 11, 'next_val forwards scalar calls');
is(join(',', $next_val->next_val(12, 13)), '12,13',
    'next_val preserves list context');

iterator::set_state($iterator, iterator::RUNNING);
ok($iterator->running, 'package setter changes iterator state');
$iterator->set_state(iterator::COMPLETED);
ok($iterator->completed, 'method setter changes iterator state');

my $generator = gen { yield 1 };
ok($generator->isa('iterator'), 'generator inherits from iterator');
ok(!$generator->restartable, 'generators are not restartable by default');
my $method_generator = gen { yield @_ };
is(join(',', $method_generator->next_val(21, 22)), '21,22',
    'generator inherits next_val');
ok(iterator::running($generator), 'iterator predicate accepts generators');
is(iterator::state($generator), iterator::RUNNING,
   'iterator state maps generator suspension state');
eval { $generator->set_state(iterator::COMPLETED) };
like($@, qr/cannot set the state of a generator/,
     'ordinary iterator setter cannot modify a generator');

my $failed = iterator->new(sub { die "iterator failure\n" });
my $failure_result = eval { $failed->() };
like($@, qr/iterator failure/, 'iterator exception is rethrown');
ok(!$failure_result, 'failed iterator call has no result');
ok(!$failed->failed, 'escaping exception does not choose iterator state');
$failed->set_state(iterator::FAILED);
ok($failed->failed, 'caller can mark an iterator failed');
ok($failed->exhausted, 'failed iterator is exhausted');
ok(!$failed->completed, 'failed iterator is not completed');

my $caught = iterator->new(sub {
    my $caught = eval { die "handled inside iterator\n" };
    return 42;
});
is($caught->(), 42, 'iterator can catch its own exception');
ok($caught->running, 'caught exception does not fail iterator');
ok(!$caught->failed, 'iterator remains non-failed after inner eval');
