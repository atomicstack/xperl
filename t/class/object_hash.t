#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use v5.36;
use feature 'class';
use Data::Dumper;
use Scalar::Util qw(refaddr);
no warnings 'experimental::class';

class ObjectHashTest {
    field $scalar :param :reader;
    field @array;
    field %hash;
}

my $object = ObjectHashTest->new(scalar => 'value');
my $fields = builtin::class_object_to_hash($object);

is(ref($fields), 'HASH', 'to_hash returns a hash reference');
is($fields->{'$scalar'}, 'value', 'scalar field is represented directly');
is(ref($fields->{'@array'}), 'ARRAY', 'array field is represented by a reference');
is(ref($fields->{'%hash'}), 'HASH', 'hash field is represented by a reference');

$fields->{'@array'}[0] = 'shared';
$fields->{'%hash'}{key} = 'shared';
my $copy = builtin::class_object_from_hash($fields, 'ObjectHashTest');
my $copy_fields = builtin::class_object_to_hash($copy);
is($copy->scalar, 'value', 'from_hash restores scalar fields');
is($copy_fields->{'@array'}[0], 'shared', 'array field values are shared');
is($copy_fields->{'%hash'}{key}, 'shared', 'hash field values are shared');
is(refaddr($copy_fields->{'@array'}), refaddr($fields->{'@array'}),
   'array field referent is shared');
is(refaddr($copy_fields->{'%hash'}), refaddr($fields->{'%hash'}),
   'hash field referent is shared');

my $dump = Dumper($object);
like($dump, qr/builtin::class_object_from_hash/, 'XS Dumper handles class objects');
my $restored = eval "no strict 'vars'; $dump";
is($@, '', 'XS Dumper output evaluates');
is($restored->scalar, 'value', 'XS Dumper restores class fields');

{
    local $Data::Dumper::Useperl = 1;
    my $pure_dump = Dumper($object);
    like($pure_dump, qr/builtin::class_object_from_hash/, 'pure Perl Dumper handles class objects');
    my $pure_restored = eval "no strict 'vars'; $pure_dump";
    is($@, '', 'pure Perl Dumper output evaluates');
    is($pure_restored->scalar, 'value', 'pure Perl Dumper restores class fields');
}

done_testing();
