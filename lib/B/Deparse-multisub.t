#!./perl

BEGIN {
    chdir 't' if -d 't';
    unshift @INC, '../lib';
    require './test.pl';
    skip_all('B is unavailable in miniperl') if is_miniperl();
    require Config;
    skip_all('Perl configured without B')
        unless $Config::Config{extensions} =~ /\bB\b/;
}

use strict;
use warnings;
use B::Deparse;
use feature qw(multisub current_sub state class);
no warnings qw(experimental::multisub experimental::class);
use dispatch::Predicates;

my $deparser = B::Deparse->new;
my $expected = 'ok';
our $observed_context;
$main::multisub_arguments = 42;
our @attempts;

sub copy_multisub {
    my ($original) = @_;
    $deparser->ambient_pragmas_from_caller;
    my $text = $deparser->coderef2text($original);
    my $copy = eval "sub $text";
    is($@, '', 'coderef2text output compiles as an ordinary subroutine')
        or diag($text);
    return $copy;
}

multi sub classify('ok', $value if $value > 0) { $value + 1 }
multi sub classify('ok', $value) { -$value }
multi sub classify() { 'empty' }

my $copy = copy_multisub(\&classify);
is($copy->('ok', 41), 42, 'successful guard selects the first clause');
is($copy->('ok', -3), 3, 'false guard tries the next clause');
is($copy->(), 'empty', 'empty argument pattern survives deparsing');
my $again = eval 'sub ' . $deparser->coderef2text($copy);
is($@, '', 'the generated dispatch body can itself be deparsed');
is($again && $again->('ok', 41), 42, 'repeated deparsing preserves dispatch');

my $no_match_line = __LINE__ + 1;
eval { $copy->('missing') };
my $error = ${^ERROR_OBJ};
is(ref $error, 'XPerl::Exception', 'no-match throws a structured exception');
is($error->diagnostics->[0]->code, 'ERROR_RUNTIME_MULTISUB_NO_MATCH',
    'no-match retains its diagnostic identity');
like("$error", qr/No matching clause for multi sub main::classify/,
    'no-match names the original dispatcher');
my $no_match = $error->contents->[0];
is($no_match->location->{file}, __FILE__, 'deparsed no-match records the caller file');
is($no_match->location->{line}, $no_match_line, 'deparsed no-match records the caller line');
is($no_match->params->[1]{name}, 'declaration_kind',
    'deparsed no-match retains its declaration-kind selector');

my $call_enabled = 1;
eval q{
#line 101 "lowered-conditional-caller.pl"
    if ($call_enabled) {
#line 222 "lowered-conditional-caller.pl"
        $copy->('missing');
    }
};
$no_match = ${^ERROR_OBJ}->contents->[0];
is($no_match->location->{file}, 'lowered-conditional-caller.pl',
    'deparsed conditional no-match records the caller file');
is($no_match->location->{line}, 222,
    'deparsed conditional no-match reports the call rather than the conditional');

SKIP: {
    eval { require XPerl::DiagPack::DE };
    skip('German diagnostic pack is unavailable', 4) if $@;

    for my $callee (\&classify, $copy) {
        my $diagnostic = eval q{
            use diagpack 'de';
            eval { $callee->('missing') };
            ${^ERROR_OBJ}->contents->[0];
        };
        is($@, '', 'a lexical diagnostic language can surround the call');
        is($diagnostic->text, $diagnostic->render_as_legacy('de'),
            'native and deparsed no-match capture the caller diagnostic language');
    }
}

multi sub FAILED_KIND('ok') { 42 }
my $marker_copy = copy_multisub(\&FAILED_KIND);
eval { $marker_copy->('missing') };
is(${^ERROR_OBJ}->contents->[0]->params->[0]{value}, 'main::FAILED_KIND',
    'deparsing preserves a name that resembles an internal substitution marker');

my $direct_failure_source = <<'SOURCE';
#line 305 "direct-failure.pl"
XPerl::Diagnostic::_multisub_no_match('main::top_level', 0);
SOURCE
fresh_perl_like($direct_failure_source,
    qr/No matching clause for multi sub main::top_level at direct-failure\.pl line 305\./,
    {}, 'the shared no-match emitter handles a direct call without a Perl frame');

my $namespaced_original = eval q{
    use feature 'namespaces';
    namespace Multisub::Lowered;
    multi sub choose_value(1) { 42 }
    \&choose_value;
};
is($@, '', 'a multi can be defined with lexical namespaces enabled');
my $namespaced_copy = copy_multisub($namespaced_original);
is($namespaced_copy->(1), 42, 'a namespaced multi body recompiles in ordinary ambient pragmas');
eval { $namespaced_copy->(2) };
is(${^ERROR_OBJ}->contents->[0]->code, 'ERROR_RUNTIME_MULTISUB_NO_MATCH',
    'the deparsed no-match emitter resolves outside clause namespace pragmas');

multi sub original_arguments('ok', $value) {
    $value += 1;
    $_[1] += 10;
    return [$value, [@_], __SUB__];
}

$copy = copy_multisub(\&original_arguments);
my $argument = 41;
my $result = $copy->('ok', $argument);
is($argument, 51, 'original argument aliases survive deparsing');
is($result->[0], 42, 'pattern binding remains a copy');
is(join(',', @{$result->[1]}), 'ok,51', '@_ contains all original arguments');
is($result->[2], $copy, '__SUB__ identifies the anonymous dispatcher');

multi sub factorial(0) { 1 }
multi sub factorial($n) { $n * __SUB__->($n - 1) }
$copy = copy_multisub(\&factorial);
is($copy->(5), 120, 'recursive __SUB__ redispatches');

multi sub contexts($value) {
    return !defined wantarray ? () : wantarray ? ($value, $value + 1) : $value;
}
$copy = copy_multisub(\&contexts);
is(scalar $copy->(41), 41, 'explicit return preserves scalar context');
is(join(',', $copy->(41)), '41,42', 'explicit return preserves list context');

multi sub implicit_context($value) {
    $main::observed_context = wantarray;
    ($value, $value + 1);
}
$copy = copy_multisub(\&implicit_context);
is(scalar $copy->(41), 42, 'implicit return preserves scalar context');
is(join(',', $copy->(41)), '41,42', 'implicit return preserves list context');
$copy->(41);
ok(!defined $observed_context, 'implicit return preserves void context');

multi sub shapes(^$expected, {items => [$first, @tail], ...}) {
    return [$first, @tail];
}
$copy = copy_multisub(\&shapes);
is(join(',', @{$copy->('ok', {items => [20, 21, 22], extra => 1})}),
    '20,21,22', 'pins, nested shapes, ellipses, and tail bindings survive');
$expected = 'changed';
is(join(',', @{$copy->('changed', {items => [42]})}), '42',
    'pin reads its lexical at call time');

multi sub hash_tail({name => $name, %rest}) { [$name, $rest{answer}] }
$copy = copy_multisub(\&hash_tail);
is(join(',', @{$copy->({name => 'ok', answer => 42})}), 'ok,42',
    'hash tail bindings survive');

multi sub predicates($value = Int()) { $value }
$copy = copy_multisub(\&predicates);
is($copy->('42'), '42', 'predicate capture survives');

multi sub regexp(/(?<word>ok)/) { $word }
$copy = copy_multisub(\&regexp);
is($copy->('ok'), 'ok', 'regexp named capture survives');

multi sub wildcard(_) { 'anything' }
$copy = copy_multisub(\&wildcard);
is($copy->(42), 'anything', 'wildcard stays distinct from a string literal');

multi sub concatenate($prefix . ':' . $suffix) { [$prefix, $suffix] }
$copy = copy_multisub(\&concatenate);
is(join(',', @{$copy->('one:two')}), 'one,two',
    'concatenation captures survive');

multi sub object_shape(DeparsePoint { x => $x, y => $y }) { $x + $y }
$copy = copy_multisub(\&object_shape);
is($copy->(bless({x => 20, y => 22}, 'DeparsePoint')), 42,
    'class-qualified object shapes survive');

multi sub reference_shape(\$value) { $value }
$copy = copy_multisub(\&reference_shape);
my $referent = 42;
is($copy->(\$referent), 42, 'scalar reference shapes survive');

my $namespaced = eval q{
    use feature 'namespaces';
    no warnings 'experimental::namespaces';
    namespace Shapes;
    multi sub namespace_shapes(Point [$x]) { $x }
    multi sub namespace_shapes(A::Point {x => $x}) { $x }
    \&namespace_shapes;
};
is($@, '', 'class patterns compile in a namespace');
$copy = copy_multisub($namespaced);
is($copy->(bless([41], 'Shapes::Point')), 41, 'bare class names resolve in a namespace');
is($copy->(bless({x => 42}, 'Shapes::A::Point')), 42,
    'deparsed class names retain their resolved namespace');
eval { $copy->() };
is(${^ERROR_OBJ}->diagnostics->[0]->code, 'ERROR_RUNTIME_MULTISUB_NO_MATCH',
    'generated errors use the core diagnostic constructors inside a namespace');

my $unicode_name = "\x{03a9}mega";
my $unicode_source = "use utf8; use feature 'namespaces'; no warnings; namespace Shapes;"
                   . "multi sub unicode_shapes(${unicode_name}::Point [\$x]) { \$x }"
                   . '\&unicode_shapes;';
my $unicode_dispatcher = eval $unicode_source;
is($@, '', 'Unicode class names compile in namespaced patterns');
$copy = copy_multisub($unicode_dispatcher);
is($copy->(bless([42], "Shapes::${unicode_name}::Point")), 42,
    'deparsed class constraints preserve character names');

multi sub separate_state('first') { state $n = 0; ++$n }
multi sub separate_state('second') { state $n = 10; ++$n }
$copy = copy_multisub(\&separate_state);
is(join(',', $copy->('first'), $copy->('second'), $copy->('first')),
    '1,11,2', 'each clause retains independent state');

multi sub global_subject_name() { $main::multisub_arguments }
$copy = copy_multisub(\&global_subject_name);
is($copy->(), 42, 'generated subject does not shadow a package variable');

{
    my $original = eval q{
        package Deparse::Global;
        no strict 'vars';
        $multisub_arguments = 42;
        multi sub braced_subject_name() { "a${multisub_arguments}b" }
        \&braced_subject_name;
    };
    $copy = copy_multisub($original);
    is($copy->(), 'a42b', 'generated subject does not shadow braced globals');
}

multi sub lexical_helpers('one') { my sub helper { 41 } helper() }
multi sub lexical_helpers('two') { my sub helper { 42 } helper() }
$copy = copy_multisub(\&lexical_helpers);
is(join(',', $copy->('one'), $copy->('two')), '41,42',
    'clause-local lexical subs retain their scopes');

multi sub header_pragmas($n if $n / 2 == 1.5) { use integer; $n / 2 }
multi sub header_pragmas($n) { 'fallback' }
$copy = copy_multisub(\&header_pragmas);
is($copy->(3), 1, 'body pragmas do not affect the guard');

{
    use feature 'dispatch_on';
    multi sub feature_changes(1) { 41 }
    no feature 'dispatch_on';
    multi sub feature_changes(2) { 42 }

    $copy = copy_multisub(\&feature_changes);
    is(join(',', $copy->(1), $copy->(2)), '41,42',
        'clause feature changes do not disable the generated dispatcher');
}

{
    my sub dispatch { 123 }
    my sub on { 123 }
    my sub return { 123 }
    my sub do { 123 }
    my sub die { 123 }
    my sub no { 123 }
    my sub my { 123 }
    multi sub shadowed_keywords(1) { 41 }

    CORE::my $deparser = B::Deparse->new;
    $deparser->ambient_pragmas_from_caller;
    CORE::my $text = $deparser->coderef2text(\&shadowed_keywords);
    CORE::my $dispatcher = eval "sub $text";
    is($@, '', 'generated syntax compiles with shadowed keywords') or diag($text);
    is($dispatcher && $dispatcher->(1), 41,
        'shadowed keywords do not intercept successful dispatch');
    eval { $dispatcher->(2) };
    is(${^ERROR_OBJ}->diagnostics->[0]->code, 'ERROR_RUNTIME_MULTISUB_NO_MATCH',
        'shadowed die does not intercept the generated no-match error');
}

multi sub guard_bindings($value if do { push @attempts, $value; $value = 99; 0 }) {
    'unreachable';
}
multi sub guard_bindings($value if do { $value += 10; 1 }) { $value }
$copy = copy_multisub(\&guard_bindings);
is($copy->(32), 42, 'failed guard bindings roll back before the next clause');
is(join(',', @attempts), '32', 'guard side effects retain their usual scope');

multi sub escaped_binding($value) { sub { $value } }
$copy = copy_multisub(\&escaped_binding);
my $first = $copy->(41);
my $second = $copy->(42);
is(join(',', $first->(), $second->()), '41,42',
    'escaped closures keep independent pattern bindings');

multi sub topic() { $_ }
$copy = copy_multisub(\&topic);
{
    local $_ = 'original topic';
    is($copy->(), 'original topic', 'dispatch leaves the caller topic alone');
}

sub native_roundtrip {
    my ($source) = @_;
    my $file = tempfile();
    open my $fh, '>', $file or die "$file: $!";
    print {$fh} $source;
    close $fh or die "$file: $!";

    my $native = runperl(progfile => $file, switches => ['-MO=-qq,Deparse']);
    open $fh, '>', $file or die "$file: $!";
    print {$fh} $native;
    close $fh or die "$file: $!";
    return ($native, runperl(progfile => $file));
}

# Full-program deparsing must emit each declaration where its outer lexicals
# are visible. Grouping the clauses would make these pins refer to one slot.
my $source = <<'SOURCE';
use strict;
use warnings;
use feature qw(multisub current_sub);
no warnings 'experimental::multisub';
no warnings 'shadow';
my $setting = 'first';
multi sub choose(^$setting) { 'one' }
my $setting = 'second';
multi sub choose(^$setting) { 'two' }
multi sub choose($value if $value eq 'other') { __SUB__->('first') }
print join(',', choose('first'), choose('second'), choose('other'));
SOURCE

my ($native, $output) = native_roundtrip($source);
like($native, qr/multi sub choose\(/, 'program deparse emits native declarations');
unlike($native, qr/multisub_arguments|dispatch my/, 'native output omits implementation scaffolding');
is($output, 'one,two,one',
    'native clauses preserve interleaved lexical shadowing and recursion')
    or diag($native);

($native, $output) = native_roundtrip(<<'SOURCE');
use feature 'multisub';
no warnings 'experimental::multisub';
multi sub fraction($n if $n / 2 == 1.5) { use integer; $n / 2 }
multi sub fraction($n) { 'fallback' }
multi sub helpers('one') { my sub helper { 41 } helper() }
multi sub helpers('two') { my sub helper { 42 } helper() }
print join(',', fraction(3), 3 / 2, helpers('one'), helpers('two'));
SOURCE
is($output, '1,1.5,41,42',
    'native output preserves header pragmas and lexical subs') or diag($native);

($native, $output) = native_roundtrip(<<'SOURCE');
use feature 'multisub';
no warnings 'experimental::multisub';
package First;
our $value = 41;
multi sub Other::answer('one') { $value }
package Second;
our $value = 42;
multi sub Other::answer('two') { $value }
package main;
print join(',', Other::answer('one'), Other::answer('two'));
SOURCE
is($output, '41,42', 'native clauses retain their declaration packages')
    or diag($native);

($native, $output) = native_roundtrip(<<'SOURCE');
use feature qw(multisub namespaces);
no warnings;
namespace Shapes;
multi sub Local::answer(Point [$x]) { $x }
multi sub Local::answer(A::Point {x => $x}) { $x }
my $answer = 'Shapes::Local'->can('answer');
print join(',', $answer->(bless([41], 'Shapes::Point')),
                $answer->(bless({x => 42}, 'Shapes::A::Point')));
SOURCE
is($output, '41,42', 'native names and class patterns retain namespace boundaries')
    or diag($native);

($native, $output) = native_roundtrip(<<'SOURCE');
use feature qw(multisub namespaces);
no warnings;
namespace App;
package First;
multi sub Tool::name(1) { __PACKAGE__ }
package Second;
multi sub Tool::name(2) { __PACKAGE__ }
print join(',', 'App::Tool'->can('name')->(1), 'App::Tool'->can('name')->(2));
SOURCE
is($output, 'App::First,App::Second', 'native clause packages retain namespace boundaries')
    or diag($native);

class DeparseMultiMethod {
    field $base = 40;
    multi method answer($value if $value < 10) { $base + $value }
    multi method answer($value) { $value }
}

role DeparseMultiRole {
    field $base = 40;
    multi method answer($value if $value < 10) { $base + $value }
    multi method answer($value) { $value }
}
class DeparseRoleUser :implements(DeparseMultiRole) { field $prefix = 100 }

for my $case (
    ['DeparseMultiMethod', 'class DeparseMultiMethod { field $base = 40;',
     '}', 'DeparseMultiMethod'],
    ['DeparseRoleUser', 'role DeparseMultiRole { field $base = 40;',
     '} class DeparseRoleUser :implements(DeparseMultiRole) { field $prefix = 100 }',
     'DeparseRoleUser'],
) {
    my ($provider, $opening, $closing, $consumer) = @$case;
    my $text = B::Deparse->new->coderef2text($provider->can('answer'));
    unlike($text, qr/XXX/, 'a method body omits its native compiler prologue');

    my $file = tempfile();
    open my $fh, '>', $file or die "$file: $!";
    print {$fh} "use feature qw(class multisub); no warnings;\n",
        $opening, "method answer $text\n", $closing,
        "\nmy \$object = $consumer->new; print join(',', \$object->answer(2), \$object->answer(12));",
        <<'SOURCE';

#line 600 "multi-method-caller.pl"
eval { $object->answer() };
my $diagnostic = ${^ERROR_OBJ}->contents->[0];
my ($kind) = $diagnostic->render_as_legacy('en') =~ /for multi (sub|method) /;
print '|', $kind, '|',
    $diagnostic->location->{file}, ':', $diagnostic->location->{line};
SOURCE
    close $fh or die "$file: $!";
    is(runperl(progfile => $file), '42,12|method|multi-method-caller.pl:600',
        'a multi method body round-trips in its declaring class or role context');
}

my $method_source = <<'SOURCE';
use feature qw(class multisub);
no warnings;
role NativeMultiRole {
    field $base = 40;
    multi method answer($x if $x < 10) { $base + $x }
    multi method answer($x) { $x }
}
class NativeMultiUserA :implements(NativeMultiRole) { field $prefix = 1 }
class NativeMultiUserB :implements(NativeMultiRole) { field $prefix = 2 }
SOURCE
my $method_file = tempfile();
open my $method_fh, '>', $method_file or die "$method_file: $!";
print {$method_fh} $method_source;
close $method_fh or die "$method_file: $!";
my $method_native = runperl(progfile => $method_file, switches => ['-MO=-qq,Deparse']);
like($method_native, qr/multi method answer\(\$x if \$x < 10\)/,
    'native method clauses use multi method with an inner guard');
is(scalar(() = $method_native =~ /multi method answer\(/g), 2,
    'native output emits provider clauses once across role consumers');

{
    use feature 'dispatch_on';
    no warnings 'exiting';

    multi sub deparse_loop_next($n) { next }
    multi sub deparse_loop_last($n) { last }
    sub deparse_last_helper { last }
    multi sub deparse_guard_last($n if do { deparse_last_helper(); 1 }) { $n }
    multi sub deparse_local_dispatch($n) {
        dispatch ($n) { on (_) { last } }
        'after dispatch';
    }

    for my $case (
        [\&deparse_loop_next, 'before 1,before 2,before 3'],
        [\&deparse_loop_last, 'before 1'],
        [\&deparse_guard_last, 'before 1'],
    ) {
        my ($action, $expected) = @$case;
        for my $generation (0..2) {
            my @trace;
            for my $n (1..3) {
                push @trace, "before $n";
                $action->($n);
                push @trace, "after $n";
            }
            is(join(',', @trace), $expected,
                "deparse generation $generation preserves caller loop control");
            $action = copy_multisub($action) if $generation < 2;
        }
    }

    my $nested = \&deparse_local_dispatch;
    for my $generation (0..2) {
        is($nested->(1), 'after dispatch',
            "deparse generation $generation preserves an explicit nested dispatch");
        $nested = copy_multisub($nested) if $generation < 2;
    }
}

SKIP: {
    skip('threads are unavailable', 1) unless $Config::Config{useithreads};
    require threads;
    my $thread = threads->create(sub {
        my $text = B::Deparse->new->coderef2text(\&classify);
        my $dispatcher = eval "sub $text";
        die $@ unless $dispatcher;
        return $dispatcher->('ok', 41);
    });
    is($thread->join, 42, 'a cloned CV retains deparseable patterns and headers');
}

done_testing();
