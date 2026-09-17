#!./perl

use strict;
use warnings;
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

plan(tests => 93);

use generator;
use experimental 'class';
no warnings 'experimental::builtin';

sub next_values {
    my ($generator, @args) = @_;
    my @values = $generator->(@args);
    return \@values;
}

sub is_deeply {
    my ($got, $expected, $name) = @_;
    is(join("\x1f", map { defined $_ ? $_ : "\x00" } @$got),
       join("\x1f", map { defined $_ ? $_ : "\x00" } @$expected), $name);
}

my $finite = gen {
    yield 1;
    yield 2;
};

is(ref($finite), 'generator', 'generator is blessed into generator package');
ok($finite->can('exhausted'), 'generator exposes predicate methods');
ok(!$finite->exhausted, 'new generator is not exhausted');
is_deeply(next_values($finite), [ 1 ], 'first yield');
ok(!$finite->exhausted, 'suspended generator is not exhausted');
is_deeply(next_values($finite), [ 2 ], 'second yield');
is_deeply(next_values($finite), [], 'exhaustion returns an empty list');
ok($finite->exhausted, 'completed generator is exhausted');
ok($finite->completed, 'normally completed generator reports completion');
ok(generator::exhausted($finite), 'package exhausted predicate works');
ok(generator::completed($finite), 'package completed predicate works');
is_deeply(next_values($finite), [],
    'calling a normally exhausted generator returns an empty list');
ok($finite->exhausted, 'normal exhaustion remains permanent');

my $undef = gen { yield undef };
my $undef_values = next_values($undef);
is(scalar(@$undef_values), 1, 'undef is still one yielded value');
ok(!defined($undef_values->[0]), 'yielded undef is preserved');

my $n = 10;
my $closure = gen { yield $n++; yield $n++ };
is_deeply(next_values($closure), [ 10 ], 'generator closes over lexical state');
is_deeply(next_values($closure), [ 11 ], 'lexical state survives suspension');

my $loop = gen {
    for my $value (1 .. 3) {
        yield $value;
    }
};
is_deeply(next_values($loop), [ 1 ], 'loop yield one');
is_deeply(next_values($loop), [ 2 ], 'loop yield two');
is_deeply(next_values($loop), [ 3 ], 'loop yield three');
is_deeply(next_values($loop), [], 'loop generator exhausts');

my $inner_eval = gen {
    my $ignored = eval { die "inner failure\n" };
    yield $@;
};
like($inner_eval->(), qr/inner failure/, 'inner eval catches its failure');
is_deeply(next_values($inner_eval), [], 'inner-eval generator exhausts');

my $failed = gen {
    yield 'before failure';
    die "generator failure\n";
};
ok(!$failed->exhausted, 'failed generator is not initially exhausted');
ok(!$failed->completed, 'failed generator is not initially completed');
ok(!$failed->failed, 'failed generator is not initially failed');
is_deeply(next_values($failed), [ 'before failure' ], 'failure follows a yield');
my ($failure, $failure_error, $resumed_failed, $resumed_failed_error);
{
    local $@;
    $failure = eval { $failed->(); 1 };
    $failure_error = $@;
    $resumed_failed = eval { $failed->(); 1 };
    $resumed_failed_error = $@;
}
ok(!$failure, 'failure is reported by resume');
like($failure_error, qr/generator failure/, 'original failure is rethrown');
ok($failed->exhausted, 'failed generator is terminal');
ok(!$failed->completed, 'failed generator is not completed');
ok($failed->failed, 'failed generator reports failure');
ok(generator::failed($failed), 'package failed predicate works');
ok(!$resumed_failed, 'failed generator cannot be resumed');
like($resumed_failed_error, qr/Cannot resume a failed generator/, 'failed-resume diagnostic');

my $args = gen {
    my ($first, $second) = @_;
    my ($next, @rest) = yield($first + $second);
    return ($next, @rest);
};
is_deeply(next_values($args, 2, 3), [ 5 ], 'initial arguments reach @_');
is_deeply(next_values($args, 7, 8), [ 7, 8 ],
    'resume arguments are returned by yield');
ok($args->exhausted, 'return marks an argument generator exhausted');

my $scalar_resume = gen {
    my $count = yield 1;
    return $count;
};
is($scalar_resume->(), 1, 'initial scalar yield remains available');
is($scalar_resume->(10, 20), 10,
    'scalar yield returns the first resume argument');

my $parameterized = gen ($x, $y, $z) {
    my $sum = yield($x + $y);
    return $z * $sum;
};
my $parameterized_sum = $parameterized->(1, 2, 3);
is($parameterized_sum, 3, 'scalar generator call returns its first yield');
cmp_ok(abs($parameterized->(sqrt($parameterized_sum)) - 5.19615242270663), '<',
    1e-12, 'scalar generator resume returns its first argument');

my $empty_yield = gen {
    yield ();
    return 9;
};
is_deeply(next_values($empty_yield), [], 'empty list is a real yield');
ok(!$empty_yield->exhausted, 'empty yield does not exhaust');
is_deeply(next_values($empty_yield), [ 9 ], 'return follows an empty yield');

my $return_list = gen {
    yield 1;
    return (2, 3);
};
is_deeply(next_values($return_list), [ 1 ], 'yield precedes list return');
is_deeply(next_values($return_list), [ 2, 3 ],
    'list return values are returned on completion');
is_deeply(next_values($return_list), [],
    'later calls after normal completion return an empty list');

my $unparenthesized_list = gen {
    my $source = gen { yield 1 };
    yield $source->(), 'A';
};
is_deeply(next_values($unparenthesized_list), [ 1, 'A' ],
    'unparenthesized yield accepts multiple values');

my $unparenthesized_nested = gen {
    my $source = gen { yield 'left' };
    for my $right ('A' .. 'B') {
        yield $source->(), $right;
    }
};
is_deeply(next_values($unparenthesized_nested), [ 'left', 'A' ],
    'unparenthesized yield keeps a nested call and following value together');

my $signature_args = gen ($x, $y) {
    my $sum = yield($x + $y);
    return $sum;
};
is($signature_args->(4, 5), 9, 'generator signature binds initial arguments');
is($signature_args->(12), 12,
    'signature bindings survive while resume args are supplied');

my $scalar = gen { yield 42 };
is(scalar($scalar->()), 42, 'scalar context returns the yielded value');

my $list_context = gen {
    yield (wantarray ? 'list' : 'scalar');
};
is_deeply(next_values($list_context), [ 'list' ],
    'generator body sees list context');
my $scalar_context = gen {
    yield (wantarray ? 'list' : 'scalar');
};
is($scalar_context->(), 'scalar', 'generator body sees scalar context');

my $list_resume_context = gen {
    yield 1;
    return wantarray ? 'list' : 'scalar';
};
is_deeply(next_values($list_resume_context), [ 1 ],
    'first generator call supplies list context');
is_deeply(next_values($list_resume_context), [ 'list' ],
    'list context is supplied when resuming after a yield');

my $scalar_resume_context = gen {
    yield 1;
    return wantarray ? 'list' : 'scalar';
};
is($scalar_resume_context->(), 1,
    'first scalar generator call supplies scalar context');
is($scalar_resume_context->(), 'scalar',
    'scalar context is supplied when resuming after a yield');

my $void_resume_context;
my $void_context = gen {
    yield 1;
    $void_resume_context = !defined(wantarray) ? 'void'
                         : wantarray ? 'list' : 'scalar';
};
$void_context->();
$void_context->();
is($void_resume_context, 'void',
    'void context is supplied when resuming after a yield');

my $running_one = gen { yield 1 };
my $running_two = gen { yield 2 };
ok($running_one->running, 'running method works in scalar context');
my @running = generator::running($running_one, $finite, $running_two);
is(scalar @running, 2, 'running filters terminal generators');
is($running[0], $running_one, 'running keeps the first active generator');
is($running[1], $running_two, 'running keeps the second active generator');
my $empty_yield_running = gen {
    yield ();
    yield 9;
};
is_deeply(next_values($empty_yield_running), [],
    'fresh generator produces an empty yield');
is_deeply([ generator::running($empty_yield_running) ], [ $empty_yield_running ],
    'running keeps a generator after an empty yield');
is_deeply([ generator::running($failed) ], [],
    'running omits a failed generator');

my $saved_input_separator = $/;
my $localized = gen {
    local $/ = 'generator separator';
    yield $/;
    yield $/;
};
    is_deeply(next_values($localized), [ 'generator separator' ],
    'localization survives the first suspension');
is_deeply(next_values($localized), [ 'generator separator' ],
    'localization survives the second suspension');
is_deeply(next_values($localized), [], 'localized generator exhausts');
is($/, $saved_input_separator, 'localization is restored at exhaustion');

my $default_scalar_isolated;
my $default_scalar_generator = gen {
    $_ = 'generator';
    yield $_;
    yield $_;
};
{
    local $_ = 'caller';
    is($default_scalar_generator->(), 'generator',
       'generator has its own default scalar on first run');
    $_ = 'caller changed';
    $default_scalar_isolated = $default_scalar_generator->();
    is($default_scalar_isolated, 'generator',
       'caller changes to the default scalar do not affect a generator');
    is($_, 'caller changed',
       'generator changes to the default scalar do not affect its caller');
}

sub argument_isolation_probe {
    my $argument_isolated = gen {
        my $before = join ',', @_;
        yield $before;
        push @_, 'generator';
        yield join ',', @_;
    };
    my $first = $argument_isolated->('initial');
    @_ = ('caller changed');
    my $second = $argument_isolated->();
    return "$first|$second|" . join(',', @_);
}
is(argument_isolation_probe(), 'initial|initial,generator|caller changed',
   'generator @_ is isolated from the caller @_');

my $reentrant;
$reentrant = gen { yield $reentrant->() };
my ($reentered, $reentered_error);
{
    local $@;
    $reentered = eval { $reentrant->(); 1 };
    $reentered_error = $@;
}
ok(!$reentered, 're-entrant resume is rejected');
like($reentered_error, qr/Generator has no suspended continuation/,
    're-entrant resume diagnostic');
$reentrant = undef;

my $nested_inner = gen { yield 10; yield 20 };
my $nested_outer = gen {
    yield $nested_inner->();
    yield $nested_inner->();
};
is_deeply(next_values($nested_outer), [ 10 ],
    'nested generator resumes its inner generator');
is_deeply(next_values($nested_outer), [ 20 ],
    'nested generator preserves the inner continuation');
is_deeply(next_values($nested_outer), [], 'nested generator exhausts');

my $nested_runops_comparisons = 0;
my $nested_runops = gen {
    my @sorted = sort {
        yield "$a:$b";
        $nested_runops_comparisons++;
        $a <=> $b;
    } 2, 1;
    yield "sorted:@sorted";
};
is_deeply(next_values($nested_runops), [ '2:1' ],
    'yield reached through nested runops is deferred safely');
is($nested_runops_comparisons, 1,
    'nested C operation completes before suspension');
is_deeply(next_values($nested_runops), [ 'sorted:1 2' ],
    'nested operation completes before the generator resumes');
is_deeply(next_values($nested_runops), [],
    'nested-runops generator exhausts');

class GeneratorClassConstructionTest {}
my $class_inside_generator = gen {
    my $object = GeneratorClassConstructionTest->new;
    yield $object;
};
my $class_value = $class_inside_generator->();
ok(defined($class_value) && ref($class_value) eq 'GeneratorClassConstructionTest',
   'class construction inside a generator survives until yield');

like(runperl(switches => ['-Mfeature=generator'], stderr => 1,
             prog => 'yield 1'),
    qr/yield outside a gen/, 'yield is rejected outside a generator');

like(runperl(switches => ['-Mfeature=generator'], stderr => 1,
             prog => 'sub ordinary_generator_test { yield 1 }'),
    qr/yield outside a gen/, 'yield is rejected in an ordinary sub');

like(runperl(switches => ['-Mfeature=generator'], stderr => 1,
             prog => 'sort { yield 1 } 1, 2'),
    qr/yield outside a gen/, 'yield is rejected in sort callbacks');
like(runperl(switches => ['-Mfeature=generator'], stderr => 1,
             prog => 'map { yield 1 } 1, 2'),
    qr/yield outside a gen/, 'yield is rejected in map callbacks');
like(runperl(switches => ['-Mfeature=generator'], stderr => 1,
             prog => 'grep { yield 1 } 1, 2'),
    qr/yield outside a gen/, 'yield is rejected in grep callbacks');
like(runperl(switches => ['-Mfeature=generator'], stderr => 1,
             prog => 'q[a] =~ /(?{ yield 1 })/'),
    qr/yield outside a gen/, 'yield is rejected in regex callbacks');

is(runperl(switches => ['-Mfeature=generator', '-Mbuiltin=weaken'],
           prog => 'package Generator::Cleanup; sub DESTROY { }'
                . ' package main; my $weak;'
                . ' my $generator = gen { my $object = bless {},'
                . ' q[Generator::Cleanup]; $weak = $object; weaken($weak);'
                . ' yield 1 }; $generator->(); undef $generator;'
                . ' print defined($weak) ? q[live] : q[destroyed]'),
   'destroyed', 'dropping a suspended generator releases its pad');

like(runperl(stderr => 1,
             prog => 'my $not_a_generator = gen { 1 }'),
    qr/Can't locate object method "gen"/,
    'generator syntax remains feature gated');

undef $finite;
undef $undef;
undef $closure;
undef $loop;
undef $inner_eval;
undef $failed;
undef $args;
undef $scalar;
undef $list_context;
undef $scalar_context;
undef $localized;
undef $nested_outer;
undef $nested_inner;
undef $undef_values;
undef $reentered;
undef $failure;
undef $resumed_failed;
undef $saved_input_separator;
undef $n;
undef $@;
