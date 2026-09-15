#!./perl

BEGIN {
    chdir 't' if -d 't';
    unshift @INC, '../lib';
}

no warnings 'experimental::namespaces';

print "1..25\n";

my $result = eval q{
    use feature 'namespaces';
    namespace Alpha;
    my $one = __NAMESPACE__;
    package Beta;
    my $two = __PACKAGE__;
    namespace Gamma;
    my $three = __NAMESPACE__;
    namespace :::Root;
    my $four = __NAMESPACE__;
    [ $one, $two, $three, $four ];
};
print !$@ && $result->[0] eq 'Alpha' ? "ok 1 - namespace\n" : "not ok 1 - namespace\n";
print !$@ && $result->[1] eq 'Alpha::Beta' ? "ok 2 - package\n" : "not ok 2 - package\n";
print !$@ && $result->[2] eq 'Alpha::Gamma' ? "ok 3 - relative namespace\n" : "not ok 3 - relative namespace\n";
print !$@ && $result->[3] eq 'Root' ? "ok 4 - absolute namespace\n" : "not ok 4 - absolute namespace\n";

my $off = eval q{
    package NamespaceFeatureOff;
    __PACKAGE__;
};
print !$@ && $off eq 'NamespaceFeatureOff' ? "ok 5 - feature off\n" : "not ok 5 - feature off\n";

my $bad = eval q{
    use feature 'namespaces';
    namespace A:::B:::C;
};
print $@ =~ /Malformed namespace separator/ ? "ok 6 - malformed separator\n" : "not ok 6 - malformed separator\n";

my $alias = eval q{
    use feature 'namespaces';
    use Carp as C;
    C::croak('alias works');
};
print $@ =~ /alias works/ ? "ok 7 - package alias\n" : "not ok 7 - package alias\n";

my $duplicate = eval q{
    use feature 'namespaces';
    use Carp as C;
    use Carp as C;
};
print $@ =~ /Duplicate package alias/ ? "ok 8 - duplicate alias\n" : "not ok 8 - duplicate alias\n";

my $core = eval q{
    use feature 'namespaces';
    CORE:::abs(-2) == CORE::abs(-2);
};
print !$@ && $core ? "ok 9 - explicit CORE boundary\n" : "not ok 9 - explicit CORE boundary\n";

my $block = eval q{
    use feature 'namespaces';
    namespace Block {
        my $inside = __NAMESPACE__;
        namespace Child;
        [ $inside, __NAMESPACE__ ];
    }
};
print !$@ && $block->[0] eq 'Block' && $block->[1] eq 'Block::Child'
    ? "ok 10 - namespace block\n"
    : "not ok 10 - namespace block\n";

my $class = eval q{
    use feature qw(namespaces class);
    no warnings qw(experimental::namespaces experimental::class);
    namespace NamespaceClass;
    class Parent 1.23 { }
    class Writer :isa(Parent 1.0) {
        method label ($suffix) { __CLASS__ . $suffix }
    }
    class Nested::Writer {
        method label { __CLASS__ }
    }
    my $writer = Writer->new;
    $writer->isa('NamespaceClass::Parent') && $writer->label('!')
        . ',' . Nested::Writer->new->label;
};
print !$@ && $class eq 'NamespaceClass::Writer!,NamespaceClass::Nested::Writer'
    ? "ok 11 - class method call in namespace\n"
    : "not ok 11 - class method call in namespace\n";

my $role = eval q{
    use feature qw(namespaces class);
    no warnings qw(experimental::namespaces experimental::class);
    namespace NamespaceRole;
    role First {
        method first { 'first' }
    }
    role Second {
        method second { 'second' }
    }
    class Writer :implements(First, Second) { }
    Writer->new->first . ',' . Writer->new->second;
};
print !$@ && $role eq 'first,second'
    ? "ok 12 - role implementation in namespace\n"
    : "not ok 12 - role implementation in namespace\n";

my $sub = eval q{
    use feature 'namespaces';
    namespace NamespaceSub;
    sub Tools::answer { 42 }
    Tools::answer();
};
print !$@ && $sub == 42
    ? "ok 13 - qualified subroutine in namespace\n"
    : "not ok 13 - qualified subroutine in namespace\n";

my $variables = eval q{
    use feature 'namespaces';
    namespace NamespaceVariable;
    package Store;
    our $scalar = 42;
    our @array = qw(a b);
    our %hash = (key => 'value');
    [$Store::scalar, join(',', @Store::array), $Store::hash{'key'}];
};
print !$@ && $variables->[0] == 42 && $variables->[1] eq 'a,b'
    && $variables->[2] eq 'value'
    ? "ok 14 - qualified variables in namespace\n"
    : "not ok 14 - qualified variables in namespace\n";

my $scope = eval q{
    use feature 'namespaces';
    namespace Outer;
    my $before = __NAMESPACE__;
    my $inside = do {
        namespace Inner;
        __NAMESPACE__;
    };
    my $from_eval = eval q{__NAMESPACE__};
    [$before, $inside, __NAMESPACE__, $from_eval];
};
print !$@ && $scope->[0] eq 'Outer' && $scope->[1] eq 'Outer::Inner'
    && $scope->[2] eq 'Outer' && $scope->[3] eq 'Outer'
    ? "ok 15 - namespace lexical scope\n"
    : "not ok 15 - namespace lexical scope\n";

my $method_alias = eval q{
    BEGIN {
        package NamespaceAliasTarget;
        sub import { }
        sub new { bless {}, shift }
        sub label { 'alias' }
        $INC{'NamespaceAliasTarget.pm'} = 1;
    }
    use feature 'namespaces';
    namespace NamespaceAlias;
    use :::NamespaceAliasTarget as Target;
    Target->new->label;
};
print !$@ && $method_alias eq 'alias'
    ? "ok 16 - package alias method call in namespace\n"
    : "not ok 16 - package alias method call in namespace\n";

my $ordinary_names = eval q{
    use feature 'namespaces';
    namespace NamespaceOrdinary;
    sub compare { $a cmp $b }
    sub Tools::reverse { $b cmp $a }
    my @ascending = sort compare qw(c a b);
    my @descending = sort Tools::reverse qw(c a b);
    goto done;
    done: [join('', @ascending), join('', @descending)];
};
print !$@ && $ordinary_names->[0] eq 'abc' && $ordinary_names->[1] eq 'cba'
    ? "ok 17 - labels and sort names in namespace\n"
    : "not ok 17 - labels and sort names in namespace\n";

my $statement_class = eval q{
    use feature qw(namespaces class);
    no warnings qw(experimental::namespaces experimental::class);
    namespace NamespaceStatement;
    class Parent;
    method label { __CLASS__ }
    class Child :isa(Parent);
    method label { $self->SUPER::label . ':' . __CLASS__ }
    Child->new->label;
};
print !$@ && $statement_class eq 'NamespaceStatement::Child:NamespaceStatement::Child'
    ? "ok 18 - class statement form in namespace\n"
    : "not ok 18 - class statement form in namespace\n";

my $class_receiver = eval q{
    use feature qw(namespaces class);
    no warnings qw(experimental::namespaces experimental::class);
    namespace NamespaceReceiver;
    class Models::Writer {
        method label { __CLASS__ }
    }
    Models::Writer->new->label;
};
print !$@ && $class_receiver eq 'NamespaceReceiver::Models::Writer'
    ? "ok 19 - qualified class receiver in namespace\n"
    : "not ok 19 - qualified class receiver in namespace\n";

my $class_field = eval q{
    use feature qw(namespaces class);
    no warnings qw(experimental::namespaces experimental::class);
    namespace NamespaceField;
    class Defaults {
        sub value { 'default' }
    }
    class Writer {
        field $value = Defaults->value;
        method value { $value }
    }
    Writer->new->value;
};
print !$@ && $class_field eq 'default'
    ? "ok 20 - class field initializer in namespace\n"
    : "not ok 20 - class field initializer in namespace\n";

my $class_alias = eval q{
    BEGIN {
        package NamespaceClassAliasTarget;
        sub import { }
        $INC{'NamespaceClassAliasTarget.pm'} = 1;
    }
    use feature qw(namespaces class);
    no warnings qw(experimental::namespaces experimental::class);
    namespace NamespaceClassAlias;
    use :::NamespaceClassAliasTarget as Target;
    class Target::Parent {
        method label { 'parent' }
    }
    class Child :isa(Target::Parent) { }
    Child->new->label;
};
print !$@ && $class_alias eq 'parent'
    ? "ok 21 - class inheritance through package alias\n"
    : "not ok 21 - class inheritance through package alias\n";

my $class_root = eval q{
    use feature qw(namespaces class);
    no warnings qw(experimental::namespaces experimental::class);
    namespace NamespaceRoot;
    class :::NamespaceRootTarget {
        method label { __CLASS__ }
    }
    :::NamespaceRootTarget->new->label;
};
print !$@ && $class_root eq 'NamespaceRootTarget'
    ? "ok 22 - explicit root class in namespace\n"
    : "not ok 22 - explicit root class in namespace\n";

my $class_scope = eval q{
    use feature qw(namespaces class);
    no warnings qw(experimental::namespaces experimental::class);
    namespace NamespaceOuter;
    namespace Inner {
        class Writer {
            method label { __CLASS__ }
        }
    }
    class Writer {
        method label { __CLASS__ }
    }
    [Inner::Writer->new->label, Writer->new->label];
};
print !$@ && $class_scope->[0] eq 'NamespaceOuter::Inner::Writer'
    && $class_scope->[1] eq 'NamespaceOuter::Writer'
    ? "ok 23 - namespace block around classes\n"
    : "not ok 23 - namespace block around classes\n";

my $class_role_alias = eval q{
    BEGIN {
        package NamespaceRoleAliasTarget;
        sub import { }
        $INC{'NamespaceRoleAliasTarget.pm'} = 1;
    }
    use feature qw(namespaces class);
    no warnings qw(experimental::namespaces experimental::class);
    namespace NamespaceRoleAlias;
    use :::NamespaceRoleAliasTarget as Target;
    role Target::Role {
        method label { 'role' }
    }
    class Writer :implements(Target::Role) { }
    Writer->new->label;
};
print !$@ && $class_role_alias eq 'role'
    ? "ok 24 - class role through package alias\n"
    : "not ok 24 - class role through package alias\n";

my $lowercase_use = eval q{
    BEGIN {
        package NamespacePragma::Module;
        sub import { }
        sub label { 'relative' }
        $INC{'NamespacePragma/Module.pm'} = 1;
    }
    use feature 'namespaces';
    namespace NamespacePragma;
    use feature 'class';
    use strict;
    use warnings;
    no warnings qw(experimental::namespaces experimental::class);
    require strict;
    use Module;
    class Writer {
        method label { __CLASS__ }
    }
    Module::label() . ':' . Writer->new->label;
};
print !$@ && $lowercase_use eq 'relative:NamespacePragma::Writer'
    ? "ok 25 - lowercase pragmas in namespace\n"
    : "not ok 25 - lowercase pragmas in namespace\n";
