#!./perl

BEGIN {
    chdir 't' if -d 't';
    @INC = '../lib';
    require './test.pl';
}

use strict;
use warnings;
use feature qw(class multisub current_sub);
no warnings qw(experimental::class experimental::multisub);

class MultiExample {
    field $offset = 40;

    multi method classify($value if $value < 10) {
        [$self, $offset + $value, [@_], __SUB__];
    }
    multi method classify($value) { [$self, $value, [@_], __SUB__] }

    multi method empty(if $self) { $self }

    multi method change($value) {
        ++$_[0];
        [$value, $_[0], $self];
    }

    multi method factorial(0) { 1 }
    multi method factorial($n if $n > 0) { $n * __SUB__->($self, $n - 1) }

    multi method field_guard($value if $value == $offset) { 'field' }
    multi method field_guard($value) { 'fallback' }

    multi method OtherMultiPackage::qualified($value) { $offset + $value }
}

my $object = MultiExample->new;
my $result = $object->classify(2);
is($result->[0], $object, 'implicit self holds the native invocant');
is($result->[1], 42, 'the selected body can access fields');
is(join(',', @{$result->[2]}), '2', '@_ contains explicit arguments only');
is($result->[3], $object->can('classify'), '__SUB__ identifies the public method');
is($object->classify(12)->[1], 12, 'guard rejection selects the next method clause');
is($object->empty(), $object, 'an empty pattern excludes the invocant');

my $argument = 41;
$result = $object->change($argument);
is($argument, 42, 'method argument aliases survive dispatch');
is(join(',', @{$result}[0, 1]), '41,42', 'captures retain value semantics');
is($result->[2], $object, 'argument changes do not change self');
is($object->factorial(5), 120, 'recursive method calls redispatch with their invocant');
is($object->field_guard(40), 'field', 'fields are bound before guard evaluation');
is($object->field_guard(41), 'fallback', 'field guards retain clause order');
is(OtherMultiPackage::qualified($object, 2), 42,
    'a qualified method name retains its declaring class field bindings');

class MultiChild :isa(MultiExample) { }
my $child = MultiChild->new;
is($child->classify(2)->[0], $child, 'an inherited dispatcher keeps the actual invocant');
is($child->classify(2)->[1], 42, 'inherited clauses use the declaring field owner');

my $no_match_line = __LINE__ + 1;
eval { $child->classify() };
my $no_match = ${^ERROR_OBJ}->contents->[0];
like($@, qr/No matching clause for multi method MultiExample::classify/,
    'inherited method no-match identifies a multi method');
is($no_match->location->{file}, __FILE__, 'method no-match records the caller file');
is($no_match->location->{line}, $no_match_line, 'method no-match records the caller line');
is($no_match->params->[1]{name}, 'declaration_kind',
    'method no-match retains its declaration-kind selector');

multi sub LegacyMulti::describe($invocant, $value if $value < 10) {
    [$invocant, $value, [@_]];
}
my $legacy = bless {}, 'LegacyMulti';
$result = $legacy->describe(2);
is($result->[0], $legacy, 'multi sub includes a method-call invocant in its pattern');
is(scalar @{$result->[2]}, 2, 'multi sub retains the complete ordinary argument list');

eval { $legacy->describe() };
like($@, qr/No matching clause for multi sub LegacyMulti::describe/,
    'method-call syntax does not change a multi sub diagnostic into a method diagnostic');

role MultiRole {
    field $role_value = 40;
    my $setting = 'first';
    multi method role_value('first', $value if $value > 0) {
        [$self, $role_value + $value, eval '$setting', __SUB__, $setting];
    }
    no warnings 'shadow';
    my $setting = 'second';
    multi method role_value('second', $value) {
        [$self, $role_value + $value, eval '$setting', __SUB__, $setting];
    }
}

role PrefixRole { field $prefix = 100 }

class RoleConsumerA :implements(MultiRole) { field $prefix = 100 }
class RoleConsumerB :implements(PrefixRole, MultiRole) { field $extra = 300 }

for my $class ('RoleConsumerA', 'RoleConsumerB') {
    my $consumer = $class->new;
    my $first = $consumer->role_value('first', 2);
    my $second = $consumer->role_value('second', 3);
    is($first->[0], $consumer, "$class binds self after role composition");
    is($first->[1], 42, "$class uses its composed role field offset");
    is($first->[2], 'first', "$class retains the first clause lexical environment");
    is($second->[2], 'second', "$class retains the later clause lexical environment");
    is($first->[3], $consumer->can('role_value'), "$class keeps its public method identity");
}

for my $source (
    'multi method outside($x) { $x }',
    'class MixedA { multi method same($x) { $x } multi sub same($x) { $x } }',
    'class MixedB { multi sub same($x) { $x } multi method same($x) { $x } }',
    'class MixedC { method same($x) { $x } multi method same($x) { $x } }',
    'class MixedD { multi method same($x) { $x } method same($x) { $x } }',
    'class BadGuard { multi method same($x) if ($x) { $x } }',
) {
    eval $source;
    ok($@, 'invalid method declaration or mixed declaration kinds are rejected');
}

eval { MultiExample->can('classify')->(42, 2) };
like($@, qr/instance|object/, 'multi method retains native invocant validation');

my $early_source = <<'SOURCE';
use feature qw(class multisub);
no warnings qw(experimental::class experimental::multisub);
class EarlyMethod {
    multi method pending($value) { $value }
    BEGIN {
        my $reference = __PACKAGE__->can('pending');
        for my $call (
            sub { $reference->(undef, 1) },
            sub { __PACKAGE__->pending(1) },
            sub { goto &$reference },
        ) {
            eval { $call->() };
            my $exception = $@;
            my $diagnostic = $exception->contents->[0];
            print $diagnostic->code, ':',
                ($exception =~ /Multi-method EarlyMethod::pending is not complete/ ? 'method' : 'wrong'), ';';
        }
    }
    multi method pending() { 42 }
}
print EarlyMethod->new->pending();
SOURCE
my $early_error = 'ERROR_RUNTIME_MULTISUB_NOT_COMPLETE:method;';
fresh_perl_is($early_source, $early_error x 3 . '42', {},
    'BEGIN distinguishes incomplete true methods and allows their later completion');

require B;
my $rollback_reference = \&FailedMultiMethod::pending;
my $original_flags = B::svref_2object($rollback_reference)->CvFLAGS;
eval q{
    class FailedMultiMethod {
        multi method pending($value) { $value }
        my $broken = ;
    }
};
ok($@, 'the method rollback fixture fails to compile');
my $kind_flags = B::CVf_IsMETHOD() | B::PERL_CVf_MULTISUB();
is(B::svref_2object($rollback_reference)->CvFLAGS & $kind_flags,
    $original_flags & $kind_flags,
    'failed compilation restores the adopted stub declaration flags');

done_testing();
