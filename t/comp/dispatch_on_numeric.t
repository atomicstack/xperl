#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc( qw(. ../lib) );
}

use strict;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

sub Between ($subject, $low, $high) {
    $subject >= $low && $subject <= $high
}

sub predicate_matches ($value, $shape) {
    my $result = eval qq{
        use feature 'dispatch_on';
        use dispatch::Predicates;
        dispatch (\$value) {
            on ($shape) { 1 }
            on (_)      { 0 }
        }
    };
    die $@ if $@;
    return $result;
}

plan tests => 18;

ok(predicate_matches(42, 'Int()'), 'Int accepts a native integer');
ok(predicate_matches('42', 'Int()'), 'Int accepts an integer string');
ok(predicate_matches('+42', 'Int()'), 'Int accepts a signed integer string');
ok(predicate_matches('1E1', 'Int()'), 'Int accepts integral exponent notation');
ok(!predicate_matches('42.5', 'Int()'), 'Int rejects a fractional value');
ok(!predicate_matches('42x', 'Int()'), 'Int rejects a nonnumeric string');

ok(predicate_matches('42.5', 'Num()'), 'Num accepts a numeric string');
ok(predicate_matches('1E3', 'Num()'), 'Num accepts exponent notation');
ok(!predicate_matches('42x', 'Num()'), 'Num rejects a nonnumeric string');

my $iv = 42;
my $nv = 42.5;
my $string = '42';
ok(predicate_matches($iv, 'Integer()'), 'Integer accepts native IV');
ok(!predicate_matches($nv, 'Integer()'), 'Integer rejects native NV');
ok(predicate_matches($nv, 'Number()'), 'Number accepts native NV');
ok(!predicate_matches($string, 'Number()'), 'Number rejects a string');

my $value = 7;
my $capture;
my $captured = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $observed;
    dispatch ($value) {
        on ($capture = Int()) { $observed = $capture; 1 }
        on (_) { 0 }
    }
    $observed;
};
ok(!$@ && $captured == 7,
   'assignment captures the original subject after predicate success');

my $upper = 10;
my $in_range = eval q{
    use feature 'dispatch_on';
    dispatch (7) {
        on (Between(1, ^$upper)) { 1 }
        on (_) { 0 }
    }
};
ok(!$@ && $in_range, 'predicate receives subject, constants, and pins');

my $dynamic_argument = eval q{
    use feature 'dispatch_on';
    my $bound = 10;
    dispatch (7) { on (Between(1, $bound)) { 1 } }
};
ok($@ =~ /predicate arguments must be constants or pinned values/,
   'predicate rejects an unpinned lexical argument');

my $extra_unary_argument = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $pinned = 1;
    dispatch (1) { on (Int(^$pinned)) { 1 } }
};
ok($@ =~ /predicate has the wrong number of arguments/,
   'unary predicate rejects an explicit argument');

ok(predicate_matches(1, 'Any()'), 'Any always succeeds');
