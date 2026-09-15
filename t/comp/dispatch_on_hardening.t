#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc( qw(. ../lib) );
}

use dispatch::Predicates;

plan(14);

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
