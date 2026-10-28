#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    require Config;
}

use v5.42;
use feature 'class';
no warnings 'experimental::class';

# Field conflict between two roles - always an error
{
    role FA1 { field $x :param; }
    role FB1 { field $x :param; }

    eval q{
        class FC1 :implements(FA1) :implements(FB1) { }
    };
    like($@, qr/Field.*\$x.*conflicts/i, "field conflict detected between two roles");
    is($@->contents->[0]->code, 'ERROR_OBJECT_COMPOSITION_FAILED',
       'role composition summary keeps its diagnostic identity');
    is(scalar @{$@->contents}, 1,
       'role composition summary remains the only top-level diagnostic');
    is($@->contents->[0]->params->[1]{value},
       $@->contents->[0]->contents_count,
       'role composition summary retains the number of error diagnostics');
}

# Diamond field composition - no conflict (same origin)
{
    role FBase2 { field $x :param = 42; method get_x { $x } }
    role FLeft2 :implements(FBase2) { }
    role FRight2 :implements(FBase2) { }

    class FC2 :implements(FLeft2) :implements(FRight2) { }
    is(FC2->new->get_x, 42, "diamond field - no conflict, default works");
    is(FC2->new(x => 23)->get_x, 23,
       "diamond field - constructor parameter is consumed once");
}

# Conflicting fields remain visible through intermediate roles
{
    role FBaseA2 { field $x; }
    role FBaseB2 { field $x; }
    role FLeftNested2 :implements(FBaseA2) { }
    role FRightNested2 :implements(FBaseB2) { }

    eval q{
        class FCNested2
            :implements(FLeftNested2)
            :implements(FRightNested2) { }
    };
    like($@, qr/Field.*\$x.*conflicts/i,
         "field conflict detected through intermediate roles");
}

# Field + method conflicts reported together in batch
{
    role FA3 { field $x :param; method m { 1 } }
    role FB3 { field $x :param; method m { 2 } }

    eval q{
        class FC3 :implements(FA3) :implements(FB3) { }
    };
    like($@, qr/Role composition could not be completed/, "batch error header");
    like($@, qr/Field.*\$x.*conflicts/i, "field conflict in batch");
    like($@, qr/Method.*'m'.*conflicts/i, "method conflict in batch");
    is($@->contents->[0]->params->[1]{value},
       $@->contents->[0]->contents_count,
       'role composition summary retains all error diagnostics');
    is(scalar @{$@->contents}, 1,
       'role composition summary remains the only top-level batch diagnostic');
    is($@->contents->[0]->contents_count,
       $@->contents->[0]->params->[1]{value},
       'role composition summary owns all field and method conflicts');
}

# Field conflict cannot be resolved by consumer method
{
    role FA4 { field $x :param; }
    role FB4 { field $x :param; }

    eval q{
        class FC4 :implements(FA4) :implements(FB4) {
            method x { "override" }
        }
    };
    like($@, qr/Field.*\$x.*conflicts/i,
         "field conflict is unresolvable even with consumer method");
}

done_testing;
