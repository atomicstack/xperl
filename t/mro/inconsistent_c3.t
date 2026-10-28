#!./perl

BEGIN {
    unless (-d 'blib') {
        chdir 't' if -d 't';
    }
    require q(./test.pl);
    set_up_inc('../lib');
}

use strict;
use warnings;

plan(tests => 7);

require mro;

=pod

This example is take from: http://www.python.org/2.3/mro.html

"Serious order disagreement" # From Guido
class O: pass
class X(O): pass
class Y(O): pass
class A(X,Y): pass
class B(Y,X): pass
try:
    class Z(A,B): pass #creates Z(A,B) in Python 2.2
except TypeError:
    pass # Z(A,B) cannot be created in Python 2.3

=cut

{
    package X;
    
    package Y;
    
    package XY;
    our @ISA = ('X', 'Y');
    
    package YX;
    our @ISA = ('Y', 'X');

    package Z;
    our @ISA = ('XY', 'YX');
}

eval { mro::get_linear_isa('Z', 'c3') };
like($@, qr/^Inconsistent hierarchy during C3 merge of class 'Z'/,
     '... got the right error with an inconsistent hierarchy');

my $diagnostics = $@->contents;
is(scalar @$diagnostics, 5,
   'the C3 failure keeps its merge details as separate diagnostics');
is($diagnostics->[0]->code, 'ERROR_OBJECT_COMPOSITION_INHERITANCE_C3_HIERARCHY_INCONSISTENT',
   'the first diagnostic identifies the inconsistent hierarchy');
is($diagnostics->[0]->params->[0]{value}, 'Z',
   'the hierarchy diagnostic records the class');
is(join('|', map { $_->code } @$diagnostics[1..3]),
   'ERROR_OBJECT_COMPOSITION_INHERITANCE_C3_MERGE_RESULT_CONTEXT|ERROR_OBJECT_COMPOSITION_INHERITANCE_C3_MERGE_RESULT_CONTEXT|ERROR_OBJECT_COMPOSITION_INHERITANCE_C3_MERGE_RESULT_CONTEXT',
   'each partial merge result has its own diagnostic');
is(join('|', map { $_->params->[0]{value} } @$diagnostics[1..3]),
   'Z|XY|YX', 'the partial merge diagnostics preserve result order');
is($diagnostics->[4]->params->[0]{value}, 'Y',
   'the final diagnostic records the parent that blocked the merge');
