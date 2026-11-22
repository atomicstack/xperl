#!./perl

BEGIN {
    chdir 't' if -d 't';
    @INC = '../lib';
    require './test.pl';
}

use strict;
use warnings;
use feature qw(multisub current_sub state);
no warnings 'experimental::multisub';

use dispatch::Predicates;

# Definitions are compiled before the surrounding scope executes.
multi sub classify("ok", $value) {
    return [$value, [@_], __SUB__];
}

multi sub classify() {
    'empty';
}

my $number = 42;
my $result = classify('ok', $number);
is($result->[0], 42, 'capture receives the matched value');
is(join(',', @{$result->[1]}), 'ok,42', 'original argument list is preserved');
is($result->[2], \&classify, '__SUB__ is the public dispatching sub');
is(classify(), 'empty', 'empty pattern matches an empty argument list');

multi sub mutate("ok", $value) {
    $value = 100;
    my $original = $_[1];
    $_[1] = 99;
    return [$value, $original];
}

$result = mutate('ok', $number);
is($result->[0], 100, 'capture can change independently');
is($result->[1], 42, 'capture assignment leaves original argument alone');
is($number, 99, '@_ preserves caller argument aliases');

my @attempts;
multi sub guarded($value if do { push @attempts, $value; $value < 0 }) {
    'negative';
}

multi sub guarded($value if do { $value += 10; 1 }) {
    return [$value, $_[0]];
}

$result = guarded(3);
is(join(',', @attempts), '3', 'guard runs after binding');
is(join(',', @$result), '13,3', 'successful guard changes reach the body');
is(guarded(-2), 'negative', 'first successful guard selects the clause');

multi sub nested({kind => 'ok', items => [$first, $second]}) {
    return $first + $second;
}

is(nested({kind => 'ok', items => [20, 22]}), 42, 'nested structural patterns');

multi sub recurse(0) { 1 }
multi sub recurse($n) { $n * __SUB__->($n - 1) }
is(recurse(5), 120, 'recursion redispatches through __SUB__');

multi sub context($ignored) {
    return !defined(wantarray) ? 'void' : wantarray ? ('a', 'b') : 'scalar';
}

my @list = context(1);
is(join(',', @list), 'a,b', 'list context reaches the selected body');
is(scalar context(1), 'scalar', 'scalar context reaches the selected body');

my $void;
multi sub void_context() { $void = !defined wantarray }
void_context();
ok($void, 'void context reaches the selected body');

multi sub closure($value) {
    return sub { ++$value };
}

my $one = closure(1);
my $two = closure(10);
is($one->(), 2, 'returned closure retains a clause binding');
is($two->(), 11, 'separate invocations have separate bindings');
is($one->(), 3, 'later calls do not overwrite escaped bindings');

{
    my $setting = 'first';
    multi sub lexical("a") { $setting }
    {
        no warnings 'shadow';
        my $setting = 'second';
        # This is deliberately a different name: groups belong to one scope.
        multi sub other_lexical("b") { $setting }
    }
    is(lexical('a'), 'first', 'outer lexical capture');
    is(other_lexical('b'), 'second', 'different declaration captures its own scope');
}

my $shadowed = eval q{
    no warnings 'shadow';
    my $setting = 'first';
    multi sub shadowed("a") { $setting }
    my $setting = 'second';
    multi sub shadowed("b") { $setting }
    [shadowed('a'), shadowed('b')];
};
is($@, '', 'interleaved lexical declarations compile');
is(join(',', @{$shadowed || []}), 'first,second', 'clauses preserve source-position lookup');

my $eval_capture = eval q{
    no warnings 'shadow';
    my $setting = 'first';
    multi sub eval_capture("a") { eval '$setting' }
    my $setting = 'second';
    multi sub eval_capture("b") { eval '$setting' }
    [eval_capture('a'), eval_capture('b')];
};
is($@, '', 'string eval in clause bodies compiles');
is(join(',', @{$eval_capture || []}), 'first,second', 'string eval resolves the active clause lexical environment');

for my $source (
    'sub mixed_one { 1 } multi sub mixed_one($x) { $x }',
    'multi sub mixed_two($x) { $x } sub mixed_two { 1 }',
    'sub mixed_three; multi sub mixed_three($x) { $x }',
    'multi sub mixed_four($x) { $x } sub mixed_four;',
) {
    eval $source;
    like($@, qr/Cannot mix declaration kinds/, 'ordinary and multi sub declarations cannot mix');
}

my $failed_guard = eval q{
    multi sub guard_throws($x if die "guard failed\n") { $x }
    guard_throws(1);
};
like($@, qr/guard failed/, 'guard exceptions propagate');

{
    local $_ = 'topic';
    classify('ok', 1);
    is($_, 'topic', 'dispatch does not replace the topic');
}

my $no_match_line = __LINE__ + 1;
eval { classify('wrong', 1) };
my $no_match = ${^ERROR_OBJ}->contents->[0];
like($@, qr/No matching clause for multi sub main::classify/,
    'unmatched arguments identify a multi sub');
is($no_match->location->{file}, __FILE__, 'no-match records the caller file');
is($no_match->location->{line}, $no_match_line, 'no-match records the caller line');
is($no_match->params->[1]{name}, 'declaration_kind',
    'no-match retains the declaration-kind selector');
eval { classify('ok', 1, 2) };
like($@, qr/No matching clause for multi sub/, 'array pattern enforces exact arity');

eval q{
    multi sub conditional_no_match(0) { 0 }
    my $enabled = 1;
#line 101 "conditional-caller.pl"
    if ($enabled) {
#line 222 "conditional-caller.pl"
        conditional_no_match(1);
    }
};
$no_match = ${^ERROR_OBJ}->contents->[0];
is($no_match->location->{file}, 'conditional-caller.pl',
    'conditional no-match records the caller file');
is($no_match->location->{line}, 222,
    'conditional no-match reports the call rather than the conditional');

my $standalone_failure_source = <<'SOURCE';
use feature 'multisub';
no warnings 'experimental::multisub';
#line 9 "standalone-multi.pl"
multi sub process(["add", $left, $right]) { $left + $right }
multi sub process(["sub", $left, $right]) { $left - $right }

process(["foo"]);
SOURCE
fresh_perl_like($standalone_failure_source,
    qr/No matching clause for multi sub main::process at standalone-multi\.pl line 12\./,
    {}, 'a standalone call after the final declaration retains its own line');

eval q{ no feature 'multisub'; multi sub disabled($x) { $x } };
ok($@, 'keyword is feature guarded');

my @warnings;
{
    local $SIG{__WARN__} = sub { push @warnings, "$_[0]" };
    eval q{ use warnings 'experimental::multisub'; multi sub warning_example() { 1 } };
}
is($@, '', 'experimental declaration compiles');
like(join('', @warnings), qr/multi is experimental/, 'experimental warning can be enabled');

my $packages = eval q{
    package Multisub::First;
    multi sub choose("first") { __PACKAGE__ }
    package Multisub::Second;
    multi sub choose("second") { __PACKAGE__ }
    [Multisub::First::choose('first'), Multisub::Second::choose('second')];
};
is($@, '', 'groups survive intervening package declarations');
is(join(',', @{$packages || []}), 'Multisub::First,Multisub::Second',
    'each group retains its original package and destination');

my $nested_sub = eval q{
    multi sub nested_identity($value) {
        return sub { __SUB__ };
    }
    nested_identity(1);
};
is($@, '', 'ordinary sub can be nested in a clause');
is($nested_sub->(), $nested_sub, 'nested __SUB__ keeps its own identity');

my $captured_nested = eval q{
    no warnings 'shadow';
    my $setting = 'first';
    multi sub nested_outer("a") { sub { $setting } }
    my $setting = 'second';
    multi sub nested_outer("b") { sub { $setting } }
    [nested_outer('a')->(), nested_outer('b')->()];
};
is($@, '', 'nested closures can capture outer declarations');
is(join(',', @{$captured_nested || []}), 'first,second',
    'nested closures resolve the defining clause environment');

for my $source (
    'multi sub missing;',
    'multi sub missing garbage',
    'multi sub ($x) { $x }',
    'multi sub malformed($x if $x >) { $x }',
    'multi sub malformed($x if $x) ;',
    'multi sub malformed($x) {',
    'multi sub BEGIN() { 1 }',
) {
    my $program = q{use feature q(multisub); no warnings q(experimental::multisub);}
        . ' eval q!' . $source . '!; print $@ ? qq(rejected\n) : qq(accepted\n);';
    my $output = runperl(prog => $program, stderr => 1);
    my $child_status = $?;
    like($output, qr/rejected/, 'malformed declaration is rejected without crashing');
    is($child_status, 0, 'malformed declaration child exits cleanly');
}

# The group keeps its glob alive, but not a foreign stash that owns it.
{
    my $program = q{use feature q(multisub); no warnings q(experimental::multisub);}
        . q{ eval q!multi sub MultisubGone::lost(1) { 1 }}
        . q{ BEGIN { delete $::{q(MultisubGone::)} }!;}
        . q{ print $@ =~ /changed while its multi declaration was incomplete/}
        . q{ ? qq(diagnosed\n) : qq(unexpected: $@\n);};
    my $output = runperl(prog => $program, stderr => 1);
    my $child_status = $?;
    is($output, "diagnosed\n", 'a group whose target stash was deleted is diagnosed');
    is($child_status, 0, 'abandoning that group exits cleanly');
}

eval q{
    multi sub frozen_group($x) { $x }
    { multi sub frozen_group($y) { $y } }
};
like($@, qr/must share a lexical scope/, 'clauses cannot cross lexical scope boundaries');

our $early_reference;
multi sub referenced("first") { 1 }
BEGIN { $early_reference = \&referenced }
multi sub referenced("second") { 2 }
is($early_reference, \&referenced, 'group finalization preserves existing code references');
is($early_reference->('second'), 2, 'early reference sees the complete group');

fresh_perl_is(q{
    use feature 'multisub';
    no warnings 'experimental::multisub';
    our $saved;
    multi sub restored(1) { 41 }
    BEGIN { $saved = \&restored; undef *restored }
    multi sub restored(2) { 42 }
    print join ',', $saved == \&restored, $saved->(1), restored(2);
}, '1,41,42', {}, 'clearing the glob between clauses preserves the reserved CV');

fresh_perl_is(q{
    use feature 'multisub';
    no warnings 'experimental::multisub';
    our $saved;
    multi sub restored(1) { 42 }
    BEGIN { $saved = \&restored; undef *restored }
    print join ',', $saved == \&restored, $saved->(1);
}, '1,42', {}, 'clearing the final code slot still completes the reserved CV');

fresh_perl_is(q{
    use feature 'multisub';
    no warnings 'experimental::multisub';
    our $saved;
    multi sub reattached(1) { 41 }
    BEGIN {
        $saved = \&reattached;
        no warnings 'redefine';
        *reattached = sub { 99 };
        *reattached = $saved;
    }
    multi sub reattached(2) { 42 }
    print join ',', $saved == \&reattached, $saved->(1), reattached(2);
}, '1,41,42', {}, 'reattaching the reserved CV between clauses completes it in place');

fresh_perl_is(q{
    use feature 'multisub';
    no warnings 'experimental::multisub';
    our $saved;
    multi sub reattached_final(1) { 42 }
    BEGIN { $saved = \&reattached_final; *reattached_final = $saved }
    print join ',', $saved == \&reattached_final, $saved->(1), reattached_final(1);
}, '1,42,42', {}, 'final assembly accepts the original reservation after glob assignment');

fresh_perl_is(q{
    use feature 'multisub';
    no warnings 'experimental::multisub';
    eval q{
        multi sub replaced(1) { 1 }
        BEGIN { no warnings 'redefine'; *replaced = sub { 99 } }
        multi sub replaced(2) { 2 }
    };
    my $error = $@;
    print($error && $error->find_diagnostic('ERROR_SYNTAX_MULTISUB_NAME_REPLACED')
        ? 'rejected,' : 'wrong,');
    print replaced();
}, 'rejected,99', {}, 'an independently installed CV survives rejected group completion');

fresh_perl_is(q{
    use feature 'multisub';
    no warnings 'experimental::multisub';
    eval q{
        multi sub replaced_final(1) { 1 }
        BEGIN { no warnings 'redefine'; *replaced_final = sub { 99 } }
    };
    my $error = $@;
    print($error && $error->find_diagnostic('ERROR_SYNTAX_MULTISUB_NAME_REPLACED')
        ? 'rejected,' : 'wrong,');
    print replaced_final();
}, 'rejected,99', {}, 'final assembly detects interference before consuming the body');

fresh_perl_is(q{
    use feature 'multisub';
    no warnings 'experimental::multisub';
    package RestoreParent;
    sub cached { 'parent' }
    package RestoreChild;
    BEGIN { our @ISA = ('RestoreParent') }
    our $saved;
    multi sub cached($self, 1) { 41 }
    BEGIN { $saved = \&cached; undef *cached; RestoreChild->can('cached') }
    multi sub cached($self, 2) { 42 }
    print join ',', $saved == RestoreChild->can('cached'),
        $saved->('RestoreChild', 1), RestoreChild->cached(2);
}, '1,41,42', {}, 'an inherited method cache cannot replace the pending public CV');

fresh_perl_is(q{
    use feature 'multisub';
    no warnings 'experimental::multisub';
    eval q{
        multi sub removed(1) { 1 }
        BEGIN { delete $main::{removed} }
        multi sub removed(2) { 2 }
    };
    print $@ && $@->find_diagnostic('ERROR_SYNTAX_MULTISUB_NAME_REPLACED')
        ? 'rejected' : 'wrong';
}, 'rejected', {}, 'a replaced stash entry cannot start a second group for the same name');

fresh_perl_is(q{
    use feature 'multisub';
    no warnings 'experimental::multisub';
    eval q{
        multi sub detached(1) { 1 }
        BEGIN {
            *detached_alias = \&detached;
            undef *detached;
            undef &detached_alias;
        }
    };
    print $@ && $@->find_diagnostic('ERROR_SYNTAX_MULTISUB_NAME_REPLACED')
        ? 'rejected' : 'wrong';
}, 'rejected', {}, 'an invalidated detached reservation is diagnosed before restoration');

my $incomplete_output = runperl(prog => <<'SOURCE', stderr => 1);
use feature q(multisub);
no warnings q(experimental::multisub);
multi sub incomplete(1) { print q(body ran) }
BEGIN { incomplete(1) }
multi sub incomplete(2) { 2 }
SOURCE
my $incomplete_status = $?;
like($incomplete_output, qr/Multi-sub main::incomplete is not complete/,
    'BEGIN reports an incomplete clause group');
ok($incomplete_status != 0, 'an uncaught incomplete call aborts compilation');
unlike($incomplete_output, qr/body ran/, 'an incomplete call executes no clause body');

my $compiling_source = <<'SOURCE';
use feature 'multisub';
no warnings 'experimental::multisub';
multi sub compiling(1) { BEGIN { compiling(1) } 42 }
SOURCE
fresh_perl_like($compiling_source, qr/Multi-sub main::compiling is not complete/, {},
    'a BEGIN inside the first clause cannot call the unfinished group');

my $incomplete_calls = join(',', ('ERROR_RUNTIME_MULTISUB_NOT_COMPLETE') x 4, 0);
my $pending_source = <<'SOURCE';
use feature 'multisub';
no warnings 'experimental::multisub';
our $autoloads;
sub AUTOLOAD { ++$autoloads }
sub trampoline { goto &pending }
multi sub pending(1) { 1 }
BEGIN {
    $autoloads = 0;
    my $reference = \&pending;
    my @codes;
    for my $call (
        sub { pending(1) },
        sub { $reference->(1) },
        \&trampoline,
        sub { main->pending(1) },
    ) {
        eval { $call->() };
        push @codes, $@->contents->[0]->code;
    }
    print join(',', @codes, $autoloads), ';';
}
multi sub pending(2) { 2 }
print join(',', pending(1), pending(2));
SOURCE
fresh_perl_is($pending_source, "$incomplete_calls;1,2", {},
    'caught early calls preserve the group and bypass AUTOLOAD');

fresh_perl_is(<<'SOURCE', '42', {}, 'BEGIN can call a group whose lexical scope is complete');
use feature 'multisub';
no warnings 'experimental::multisub';
{ multi sub complete(1) { 42 } }
BEGIN { print complete(1) }
SOURCE

our $forward_reference;
BEGIN { $forward_reference = \&forward_referenced }
multi sub forward_referenced($value) { $value }
is($forward_reference, \&forward_referenced,
    'reference before the first clause preserves its identity');
is($forward_reference->(42), 42, 'forward code reference is not an ordinary declaration');

my $inherited = eval q{
    package Multisub::CacheParent;
    sub cached { 'parent' }

    package Multisub::CacheChild;
    BEGIN { our @ISA = ('Multisub::CacheParent') }

    package Multisub::CacheGrandchild;
    BEGIN {
        our @ISA = ('Multisub::CacheChild');
        Multisub::CacheChild->can('cached');
        Multisub::CacheGrandchild->can('cached');
    }

    package Multisub::CacheChild;
    multi sub cached($self, $value) { $value }

    [Multisub::CacheChild->cached(42),
     Multisub::CacheGrandchild->cached(43),
     Multisub::CacheParent->cached()];
};
is($@, '', 'an inherited method cache does not fix a local declaration kind');
is(join(',', @{$inherited || []}), '42,43,parent',
    'local multi sub overrides inherited caches without changing the parent');

our $rollback_reference;
BEGIN { $rollback_reference = \&Multisub::Rollback::original }
eval q{
    multi sub Multisub::Rollback::original($value) {
        BEGIN {
            *Multisub::Rollback::alias = \&Multisub::Rollback::original;
            undef *Multisub::Rollback::original;
        }
        my $bad = ;
    }
};
like($@, qr/syntax error/, 'adopted stub can escape before a parse failure');
ok(!defined &$rollback_reference, 'failed parsing leaves the saved reference undefined');
eval q{no warnings 'redefine'; sub Multisub::Rollback::alias { 42 }};
is($@, '', 'failed parse restores an escaped adopted stub declaration kind');
is(Multisub::Rollback::alias(), 42, 'escaped alias can receive an ordinary body');

eval q{
    multi sub Multisub::NewRollback::original($value) {
        BEGIN {
            *Multisub::NewRollback::alias = \&Multisub::NewRollback::original;
            undef *Multisub::NewRollback::original;
        }
        my $bad = ;
    }
};
like($@, qr/syntax error/, 'new stub can escape before a parse failure');
eval q{no warnings 'redefine'; sub Multisub::NewRollback::alias { 43 }};
is($@, '', 'failed parse clears the escaped new stub declaration kind');
is(Multisub::NewRollback::alias(), 43, 'escaped new stub can receive an ordinary body');

my $expected = 'wanted';
multi sub pinned(^$expected, $value) { $value }
is(pinned('wanted', 42), 42, 'parameter patterns support pinned lexicals');

multi sub predicate($value = Int()) { $value }
is(predicate('42'), '42', 'predicate captures reuse the pattern language');

multi sub regular(/(?<word>ok)/) { $word }
is(regular('ok'), 'ok', 'regex named captures reach the body');

multi sub stateful("first") { state $count = 0; ++$count }
multi sub stateful("second") { state $count = 10; ++$count }
is(stateful('first'), 1, 'first clause has its own state variable');
is(stateful('second'), 11, 'second clause has independent state');
is(stateful('first'), 2, 'clause state survives another dispatch');

{
    use feature 'dispatch_on';
    no warnings 'exiting';

    sub multisub_loop_trace {
        my ($action) = @_;
        my @trace;
        for my $n (1..3) {
            push @trace, "before $n";
            $action->($n);
            push @trace, "after $n";
        }
        return join ',', @trace;
    }

    sub multisub_next_helper { next }
    multi sub loop_last($n) { last }
    multi sub loop_next($n) { next }
    multi sub loop_helper($n) { multisub_next_helper() }
    multi sub loop_guard($n if do { multisub_next_helper(); 1 }) { die 'body ran' }
    multi sub loop_label($n) { last MULTISUB_OUTER }

    my $restarts = 0;
    multi sub loop_redo($n) {
        redo if $n == 1 && ++$restarts == 1;
        $n;
    }

    is(multisub_loop_trace(\&loop_last), 'before 1',
        'last exits the caller loop as in an ordinary sub');
    is(multisub_loop_trace(\&loop_next), 'before 1,before 2,before 3',
        'next advances the caller loop as in an ordinary sub');
    is(multisub_loop_trace(\&loop_helper), 'before 1,before 2,before 3',
        'a helper sub cannot see the synthetic dispatcher as a loop');
    is(multisub_loop_trace(\&loop_guard), 'before 1,before 2,before 3',
        'loop control in a guard crosses the synthetic dispatcher');
    is(multisub_loop_trace(\&loop_redo),
        'before 1,before 1,after 1,before 2,after 2,before 3,after 3',
        'redo restarts the caller iteration');

    my @label_trace;
    MULTISUB_OUTER: for my $n (1..3) {
        push @label_trace, $n;
        loop_label($n);
    }
    is(join(',', @label_trace), '1', 'labeled loop control finds the caller label');

    multi sub local_loop($n) {
        my @values;
        for my $value (1..3) {
            next if $value == 1;
            push @values, $value;
            last;
        }
        join ',', @values;
    }
    is(local_loop(1), '2', 'loops inside a clause retain their normal control flow');

    multi sub local_dispatch($n) {
        dispatch ($n) { on (_) { last } }
        'after dispatch';
    }
    is(local_dispatch(1), 'after dispatch',
        'an explicit dispatch inside a clause remains a loop-control target');
}

SKIP: {
    skip_if_miniperl('B is unavailable in miniperl', 1);
    require B::Deparse;
    my $text = B::Deparse->new->coderef2text(\&classify);
    my $copy = eval "sub $text";
    is($copy && $copy->(), 'empty', 'deparsed dispatcher can be compiled and called');
}

done_testing();
