#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc( qw(. ../lib) );
}

use dispatch::Predicates;

plan(27);

{
    package DispatchOnHardening::ScalarTie;
    our ($fetches, $stores);
    sub TIESCALAR { bless { value => $_[1] }, $_[0] }
    sub FETCH { $fetches++; $_[0]{value} }
    sub STORE { $stores++; $_[0]{value} = $_[1] }
}

{
    package DispatchOnHardening::ArrayTie;
    our ($fetches, $sizes);
    sub TIEARRAY { bless { values => [ @{ $_[1] } ] }, $_[0] }
    sub FETCH { $fetches++; $_[0]{values}[$_[1]] }
    sub FETCHSIZE { $sizes++; scalar @{ $_[0]{values} } }
}

{
    package DispatchOnHardening::HashTie;
    our ($fetches, $exists);
    sub TIEHASH { bless { values => { %{ $_[1] } } }, $_[0] }
    sub FETCH { $fetches++; $_[0]{values}{$_[1]} }
    sub EXISTS { $exists++; exists $_[0]{values}{$_[1]} }
    sub FIRSTKEY { my $self = shift; keys %{ $self->{values} }; each %{ $self->{values} } }
    sub NEXTKEY { my $self = shift; each %{ $self->{values} } }
}

{
    package DispatchOnHardening::Stringified;
    our $stringifications;
    use overload '""' => sub { $stringifications++; $_[0]{value} },
                 fallback => 1;
    sub new { bless { value => $_[1] }, $_[0] }
}

{
    package DispatchOnHardening::Destroyed;
    our $destroyed;
    sub new { bless {}, $_[0] }
    sub DESTROY { $destroyed++ }
}

require Scalar::Util;

my ($scalar_result, @list_result, $void_result);
use feature 'dispatch_on';
use dispatch::Predicates;
sub clause_context {
    return wantarray ? ('list', 'result') : 'scalar';
}
sub clause_void_context {
    $void_result = !defined(wantarray);
}
$scalar_result = do {
    dispatch (1) { on (1) { clause_context() } }
};
@list_result = do {
    dispatch (1) { on (1) { clause_context() } }
};
dispatch (1) { on (1) { clause_void_context() } };
ok($scalar_result eq 'scalar'
   && @list_result == 2 && $list_result[0] eq 'list'
   && $list_result[1] eq 'result' && $void_result,
   'selected clause expressions receive scalar, list, and void context');

my ($empty_matched, $empty_scalar, @empty_list);
my $empty_result_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    $empty_scalar = do { dispatch (1) { on (1) { $empty_matched++; () } } };
    @empty_list = do { dispatch (1) { on (1) { $empty_matched++; () } } };
    1;
};
ok(!$@ && $empty_result_ok && $empty_matched == 2
   && !defined($empty_scalar) && !@empty_list,
   'a matched clause returning an empty list still runs');

my ($no_scalar, @no_list, $no_void);
my $no_match_context_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    $no_scalar = do { dispatch (2) { on (1) { 1 } } };
    @no_list = do { dispatch (2) { on (1) { 1 } } };
    dispatch (2) { on (1) { $no_void = 1 } };
    1;
};
ok(!$@ && $no_match_context_ok && !defined($no_scalar)
   && !@no_list && !defined($no_void),
   'no-match result follows scalar, list, and void context');

my ($subject_fetches, $subject_result);
my $subject_once_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $subject;
    tie $subject, 'DispatchOnHardening::ScalarTie', 7;
    $DispatchOnHardening::ScalarTie::fetches = 0;
    $subject_result = do { dispatch ($subject) {
        on (7) { $subject = 8; 1 }
    } };
    $subject_fetches = $DispatchOnHardening::ScalarTie::fetches;
    1;
};
ok(!$@ && $subject_once_ok && $subject_result == 1
   && $subject_fetches == 1,
   'matching fetches a tied scalar subject once');

my $subject_write_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $subject;
    tie $subject, 'DispatchOnHardening::ScalarTie', 7;
    dispatch ($subject) { on (7) { $subject = 9 } };
    $subject == 9;
};
ok(!$@ && $subject_write_ok, 'a clause can write the original scalar subject');

my ($tied_array_result, $array_fetches, $array_sizes);
my $tied_array_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my @subject;
    tie @subject, 'DispatchOnHardening::ArrayTie', [ 1, 2 ];
    $DispatchOnHardening::ArrayTie::fetches = 0;
    $DispatchOnHardening::ArrayTie::sizes = 0;
    $tied_array_result = do { dispatch (\@subject) {
        on ([ 1, $value ]) { $value }
    } };
    $array_fetches = $DispatchOnHardening::ArrayTie::fetches;
    $array_sizes = $DispatchOnHardening::ArrayTie::sizes;
    1;
};
ok(!$@ && $tied_array_ok && $tied_array_result == 2
   && $array_fetches && $array_sizes,
   'matching reads tied array values through normal magic');

my ($tied_hash_result, $hash_fetches, $hash_exists);
my $tied_hash_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my %subject;
    tie %subject, 'DispatchOnHardening::HashTie', { answer => 42 };
    $DispatchOnHardening::HashTie::fetches = 0;
    $DispatchOnHardening::HashTie::exists = 0;
    $tied_hash_result = do { dispatch (\%subject) {
        on ({ answer => $answer }) { $answer }
    } };
    $hash_fetches = $DispatchOnHardening::HashTie::fetches;
    $hash_exists = $DispatchOnHardening::HashTie::exists;
    1;
};
ok(!$@ && $tied_hash_ok && $tied_hash_result == 42
   && $hash_fetches,
   'matching reads tied hash values through normal magic');

my ($stringified_result, $stringifications);
my $overload_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $value = DispatchOnHardening::Stringified->new('target');
    $DispatchOnHardening::Stringified::stringifications = 0;
    $stringified_result = do { dispatch ($value) {
        on ('target') { 1 }
    } };
    $stringifications = $DispatchOnHardening::Stringified::stringifications;
    1;
};
ok(!$@ && $overload_ok && $stringified_result == 1
   && $stringifications,
   'string matching invokes the selected string overload');

my ($structural_result, $structural_stringifications);
my $structural_overload_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $value = bless { value => 'target' }, 'DispatchOnHardening::Stringified';
    $DispatchOnHardening::Stringified::stringifications = 0;
    $structural_result = do { dispatch ($value) {
        on ($object = BlessedVal()) { Scalar::Util::refaddr($object) == Scalar::Util::refaddr($value) }
    } };
    $structural_stringifications = $DispatchOnHardening::Stringified::stringifications;
    1;
};
ok(!$@ && $structural_overload_ok && $structural_result
   && !$structural_stringifications,
   'structural object matching does not stringify the whole object');

my ($captured_ref, $original_ref);
my $identity_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $value = [ 1, 2 ];
    $original_ref = Scalar::Util::refaddr($value);
    dispatch ($value) {
        on ($captured = RefVal()) { $captured_ref = Scalar::Util::refaddr($captured) }
    }
    1;
};
ok(!$@ && $identity_ok && $captured_ref == $original_ref,
   'reference captures preserve referent identity');

my ($array_changed, $hash_changed);
my $aggregate_mutation_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $array = [ 1, 2 ];
    dispatch ($array) { on ([ 1, $value ]) { $array->[1] = 9 } };
    $array_changed = $array->[1] == 9;
    my $hash = { value => 1 };
    dispatch ($hash) { on ({ value => $value }) { $hash->{value} = 8 } };
    $hash_changed = $hash->{value} == 8;
    1;
};
ok(!$@ && $aggregate_mutation_ok && $array_changed && $hash_changed,
   'a clause can mutate the original array and hash subjects');

my ($subject_die, $pattern_die, $guard_die, $body_die);
my $exception_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    eval { dispatch (die 'subject failure') { on (_) { 1 } } };
    $subject_die = $@;
    sub die_pattern { die 'pattern failure' }
    eval { dispatch (1) { on (die_pattern()) { 1 } } };
    $pattern_die = $@;
    eval { dispatch (1) { on (1 if die 'guard failure') { 1 } } };
    $guard_die = $@;
    eval { dispatch (1) { on (1) { die 'body failure' } } };
    $body_die = $@;
    1;
};
ok(!$@ && $exception_ok && $subject_die =~ /subject failure/
   && $pattern_die =~ /pattern failure/
   && $guard_die =~ /guard failure/
   && $body_die =~ /body failure/,
   'exceptions from subject, pattern, guard, and body propagate to eval');

my ($nested_caught, $nested_after);
my $nested_eval_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (1) {
        on (1) {
            $nested_caught = eval { dispatch (die 'inner') { on (_) { 1 } } };
            $nested_after = $@ =~ /inner/;
        }
    }
    1;
};
ok(!$@ && $nested_eval_ok && !defined($nested_caught) && $nested_after,
   'an inner eval catches an exception without aborting its clause');

my ($outer_error, $after_error);
my $outer_eval_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    eval { dispatch (1) { on (1) { die 'uncaught clause' } } };
    $outer_error = $@;
    $after_error = do { dispatch (2) { on (1) { 1 } } };
    1;
};
ok(!$@ && $outer_eval_ok && $outer_error =~ /uncaught clause/
   && !defined($after_error),
   'dispatch state is restored after an exception and later dispatches still run');

# The dispatch context owns its subject: user code run during matching may
# replace *_'s scalar, which used to free the unnamed subject's snapshot
# while later clauses still matched against it.
fresh_perl_is(<<'CODE', "second", {},
use feature 'dispatch_on'; no warnings;
my $v = "hello";
my $out = do { dispatch ($v) {
    on (_ if do { *_ = \my $other; my @junk = map { [] } 1..300; 0 }) { "first" }
    on ("hello") { "second" }
    on (_) { "wild" }
} };
print $out;
CODE
    'a guard replacing *_ does not free the dispatch subject');

fresh_perl_is(<<'CODE', "second [abc][def]", {},
use feature 'dispatch_on'; no warnings;
package O { use overload '""' => sub { *_ = \my $o; my @j = map { [] } 1..300; "zzz" } }
my $pin = bless {}, 'O';
my $v = "abc-def";
my $out = do { dispatch ($v) {
    on (^$pin . "-" . $rest) { "first $rest" }
    on ($a . "-" . $b) { "second [$a][$b]" }
    on (_) { "wild" }
} };
print $out;
CODE
    'overloading that replaces *_ during matching does not free the subject');

fresh_perl_is(<<'CODE', "outer|second", {},
use feature 'dispatch_on'; no warnings;
$_ = "outer";
my $out = do { dispatch ("hello") {
    on (_ if do { *_ = \my $other; 0 }) { "first" }
    on ("hello") { "second" }
} };
print "$_|$out";
CODE
    '$_ is restored after a dispatch whose matching replaced *_');

# Pattern nesting is limited at compile time so that the recursive pattern
# walkers cannot exhaust the C stack.
sub dispatch_on_nested_shape {
    my ($depth, $kind) = @_;
    return $kind eq 'hash'
        ? ('{a=>' x $depth) . '1' . ('}' x $depth)
        : ('[' x $depth) . '1' . (']' x $depth);
}

for my $kind (qw(array hash)) {
    my $shape = dispatch_on_nested_shape(1000, $kind);
    my $got = eval qq{
        use feature 'dispatch_on';
        my \$x = $shape;
        do { dispatch (\$x) { on ($shape) { 'match' } on (_) { 'wild' } } };
    };
    is($got, 'match', "$kind shape nested 1000 levels deep compiles and matches")
        or diag($@);

    $shape = dispatch_on_nested_shape(1001, $kind);
    $got = eval qq{
        use feature 'dispatch_on';
        my \$x = 1;
        do { dispatch (\$x) { on ($shape) { 'match' } on (_) { 'wild' } } };
    };
    like($@, qr/^dispatch pattern nested more than 1000 levels deep/,
         "$kind shape nested 1001 levels deep is rejected");

    fresh_perl_like(<<"CODE", qr/^err: dispatch pattern nested more than 1000 levels deep/, {},
my \$shape = '$kind' eq 'hash'
    ? ('{a=>' x 100000) . '1' . ('}' x 100000)
    : ('[' x 100000) . '1' . (']' x 100000);
eval "use feature 'dispatch_on'; my \\\$x = 1; dispatch (\\\$x) { on (\$shape) { 1 } }";
print "err: \$@";
CODE
        "$kind shape nested 100000 levels deep fails cleanly");
}

# A capture inside a class-qualified hash shape makes the pattern's pad
# references be rebound before validation; that walk must not recurse once
# per optree level either.
fresh_perl_like(<<'CODE', qr/^err: dispatch pattern nested more than 1000 levels deep/, {},
my $n = 1_000_000;
my $shape = ('[' x $n) . '1' . (']' x $n);
eval "use feature 'dispatch_on'; no warnings; package Point { sub new { bless {x => 1, y => 2}, shift } } my \$v = Point->new; dispatch (\$v) { on (Point { 'x' => \$x, 'y' => $shape }) { 1 } on (_) { 2 } }";
print "err: $@";
CODE
    "deep shape beside a rebound capture fails cleanly");

# A constant-folded dispatch must not release pad slots it does not own.
# The marker values stored in the op_targ of OP_ENTERDISPATCH and
# OP_DISPATCH_ON used to be passed to pad_free, letting two live ops share a
# target.
{
    use feature 'dispatch_on';
    no warnings;
    sub dispatch_on_fold_f {
        my @r = ($_[0] . "x", (0 ? do { dispatch ($_[0]) { on (_) { 1 } } } : 0), $_[1] . "y");
        return @r;
    }
    sub dispatch_on_fold_g {
        my @r = ($_[0] . "x", (0 ? do { dispatch my $s ($_[0]) { on (1) { 1 } } } : 0), $_[1] . "y");
        return @r;
    }
    sub dispatch_on_fold_h {
        my @r = ($_[0] . "x", (0 ? do { 1 } : 0), $_[1] . "y");
        return @r;
    }
    is(join(",", dispatch_on_fold_f("a", "b")), "ax,0,by",
       'a folded-away on (_) clause does not free a live pad slot');
    is(join(",", dispatch_on_fold_g("a", "b")), "ax,0,by",
       'a folded-away named-subject dispatch does not free a live pad slot');
    is(join(",", dispatch_on_fold_h("a", "b")), "ax,0,by",
       'control: folded-away plain block');
}
