#!./perl

BEGIN {
    chdir 't' if -d 't';
    @INC = '../lib';
    require './test.pl';
}

use strict;
use warnings;

my @shapes = (
    ['Point { x => $x }', 'bless({x => 42}, q(Point))'],
    ['Geometry::Point { x => $x }', 'bless({x => 42}, q(Geometry::Point))'],
    ['Point [$x]', 'bless([42], q(Point))'],
    ['Geometry::Point [$x]', 'bless([42], q(Geometry::Point))'],
    ['Point \\$x', 'do { my $n = 42; bless \\$n, q(Point) }'],
    ['Geometry::Point \\$x', 'do { my $n = 42; bless \\$n, q(Geometry::Point) }'],
    ['Point { x => Geometry::Point [$x] }',
     'bless({x => bless([42], q(Geometry::Point))}, q(Point))'],
    ['Point [Geometry::Point {x => $x}]',
     'bless([bless({x => 42}, q(Geometry::Point))], q(Point))'],
    ["Geometry::Point # a shape may start on the next line\n [\$x]",
     'bless([42], q(Geometry::Point))'],
);

my $prelude = <<'SOURCE';
use strict;
use warnings;
use feature qw(dispatch_on multisub);
no warnings 'experimental::multisub';
no feature 'indirect';
sub Point { die 'a class shape must not call this subroutine' }
SOURCE

for my $case (@shapes) {
    my ($pattern, $argument) = @$case;
    fresh_perl_is($prelude . <<"SOURCE", '42', {}, "multi sub argument: $pattern");
multi sub example($pattern) { print \$x }
example($argument);
SOURCE
    fresh_perl_is($prelude . <<"SOURCE", '42', {}, "nested on pattern: $pattern");
my \$value = $argument;
dispatch ([\$value]) { on ([$pattern]) { print \$x } }
SOURCE
}

fresh_perl_is($prelude . <<'SOURCE', '42', {}, 'a lexical sub does not hide a class shape');
my sub Shape { die 'not a class shape' }
multi sub example(Shape [$x]) { print $x }
example(bless [42], 'Shape');
SOURCE

fresh_perl_is($prelude . <<'SOURCE', '42', {}, 'fat commas and function calls retain their syntax');
sub Constant() { 42 }
multi sub example({ Point => $x }, Constant()) { print $x }
example({Point => 42}, 42);
SOURCE

fresh_perl_is(<<'SOURCE', '41,42', {}, 'namespace boundaries preserve adjacent attribute syntax');
use feature 'namespaces';
no warnings 'experimental::namespaces';
namespace Scope;
sub value:lvalue { $main::first }
sub Scope:::value:lvalue { $main::second }
value() = 41;
'Scope'->can('value')->() = 42;
print "$main::first,$main::second";
SOURCE

fresh_perl_is($prelude . <<'SOURCE', '42,missing', {}, 'capture assignments are patterns rather than defaults');
multi sub example($x = 42,) { $x }
print example(42);
eval { example() };
print ',missing' if $@;
SOURCE

for my $declaration (
    'multisub example($x) { 1 }',
    'multi sub example($x) if ($x) { 1 }',
    'multi subclass example($x) { 1 }',
    'multi methods example($x) { 1 }',
    'multi sub example($x) if $x { 1 }',
    'multi sub example($x) unless ($x) { 1 }',
    'multi sub example($x, $x) { 1 }',
    'multi sub example(^$unknown) { 1 }',
    'multi sub example(Point [) { 1 }',
    'multi sub example(Point { x => $x) { 1 }',
    'multi sub example($x) :method { 1 }',
    'my multi sub example($x) { 1 }',
) {
    fresh_perl_is($prelude . "local \$SIG{__WARN__} = sub {}; eval q!$declaration!; print \$@ ? q(rejected) : q(accepted);",
        'rejected', {}, "reject malformed declaration: $declaration");
}

fresh_perl_is(<<'SOURCE', 'rejected', {}, 'multi sub syntax requires its feature');
use strict;
no feature 'multisub';
eval q{multi sub example($x) { $x }};
print $@ ? 'rejected' : 'accepted';
SOURCE

fresh_perl_is(<<'SOURCE', 'experimental', {}, 'enabling multi sub retains its experimental warning');
BEGIN {
    $SIG{__WARN__} = sub { print 'experimental' if $_[0] =~ /multi is experimental/ };
}
use feature 'multisub';
multi sub example() { 42 }
SOURCE

fresh_perl_is($prelude . <<'SOURCE', '42,43', {}, 'empty guards and trailing commas share on syntax');
multi # a declaration modifier may be separated from its kind
sub empty(if 1) { 42 }
multi sub trailing($value, if $value > 0) { $value }
print join(',', empty(), trailing(43));
SOURCE

done_testing();
