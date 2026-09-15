#!./perl

BEGIN {
    chdir 't' if -d 't';
    unshift @INC, '../lib';
}

use dispatch::Predicates;

print "1..175\n";

my $ran = 0;
$_ = 'outside';
my $ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (1) {
        on (1) { $ran = 1; }
    }
    1;
};
print !$@ && $ok && $ran ? "ok 1 - dispatch/on syntax\n"
                         : "not ok 1 - dispatch/on syntax\n";

my $off = eval q{ dispatch (1) { on (1) {} } 1 };
print $@ ? "ok 2 - feature gated\n" : "not ok 2 - feature gated\n";

my $nested = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (2) {
        on (1) { die 'wrong clause'; }
        on (2) { $ran = 2; }
    }
    1;
};
print !$@ && $nested && $ran == 2 ? "ok 3 - multiple clauses\n"
                                  : "not ok 3 - multiple clauses\n";
print $_ eq 'outside' ? "ok 4 - does not leak $_\n"
                      : "not ok 4 - does not leak $_\n";

my ($numeric, $string) = (0, 0);
my $typed_numeric = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('00123') {
        on (123) { $numeric = 1; }
    }
    1;
};
my $typed_string = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (123) {
        on ('123') { $string = 2; }
    }
    1;
};
print !$@ && $typed_numeric && $typed_string
    && $numeric == 1 && $string == 2
    ? "ok 5 - numeric and string literals use their comparison modes\n"
    : "not ok 5 - numeric and string literals use their comparison modes\n";

my $wildcard = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (999) {
        on (_) { 1; }
    }
};
print !$@ && $wildcard ? "ok 6 - wildcard\n" : "not ok 6 - wildcard\n";

my ($first, $second, $nested_first, $nested_second);
my $nested = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ([ { foo => 1 }, { foo => 2 } ]) {
        on ([ { foo => $first }, { foo => $second } ]) {
            $nested_first = $first;
            $nested_second = $second;
            1;
        }
    }
};
print !$@ && $nested && $nested_first == 1 && $nested_second == 2
    ? "ok 7 - nested captures\n" : "not ok 7 - nested captures\n";

my $rollback = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ([ { foo => 1 }, { bar => 2 } ]) {
        on ([ { foo => $first }, { foo => $second } ]) { 1; }
    }
};
print !$@ && !defined($rollback)
    ? "ok 8 - failed match rolls back\n"
    : "not ok 8 - failed match rolls back\n";

my $open_array = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ([ 1, 2, 3 ]) {
        on ([ 1, ... ]) { 1; }
    }
};
print !$@ && $open_array ? "ok 9 - open array pattern\n"
                         : "not ok 9 - open array pattern\n";

my $open_hash = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ({ foo => 1, bar => 2 }) {
        on ({ foo => 1, ... }) { 1; }
    }
};
print !$@ && $open_hash ? "ok 10 - open hash pattern\n"
                        : "not ok 10 - open hash pattern\n";

my $open_prefix = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ([ 1, 2, 3 ]) {
        on ([ ..., 3 ]) { 1; }
    }
};
print !$@ && $open_prefix ? "ok 11 - open prefix pattern\n"
                          : "not ok 11 - open prefix pattern\n";

my $subsequence;
my $subsequence_result;
my $open_both = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ([ 0, 'foo', 10, 'bar', 20, 'foo', 30, 'bar' ]) {
        on ([ ..., 'foo', $subsequence, 'bar', ... ]) {
            $subsequence_result = $subsequence;
            1;
        }
    }
    1;
};
print !$@ && $open_both && $subsequence_result == 10
    ? "ok 12 - leftmost subsequence pattern\n"
    : "not ok 12 - leftmost subsequence pattern\n";

my $nested_open;
my $nested_value;
my $nested_value_result;
my $nested_open_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ([ { foo => 1 }, { foo => 2 }, { foo => 3 } ]) {
        on ([ { foo => $nested_value }, ... ]) {
            $nested_open = 1;
            $nested_value_result = $nested_value;
        }
    }
    1;
};
print !$@ && $nested_open_ok && $nested_open && $nested_value_result == 1
    ? "ok 13 - nested open pattern\n"
    : "not ok 13 - nested open pattern\n";

my $dynamic_array = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $offset = 2;
    dispatch ([ 3 ]) {
        on ([ $offset + 1 ]) { 1; }
    }
    1;
};
print $@ =~ /unsupported dispatch pattern expression/
    ? "ok 14 - dynamic nested array pattern is rejected\n"
    : "not ok 14 - dynamic nested array pattern is rejected\n";

my $dynamic_hash = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $offset = 2;
    dispatch ({ foo => 3 }) {
        on ({ foo => $offset + 1 }) { 1; }
    }
    1;
};
print $@ =~ /unsupported dispatch pattern expression/
    ? "ok 15 - dynamic nested hash pattern is rejected\n"
    : "not ok 15 - dynamic nested hash pattern is rejected\n";

my $regex_match = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('abc') {
        on (/b/) { 1; }
    }
    1;
};
print !$@ && $regex_match ? "ok 16 - regex pattern\n"
                          : "not ok 16 - regex pattern\n";

{
    package DispatchOn::Tie;
    our $fetches;
    sub TIESCALAR { bless {}, shift }
    sub FETCH { $fetches++; 7 }
    sub STORE { $_[0]{value} = $_[1] }
}

{
    package DispatchOn::RegexTie;
    our $fetches;
    sub TIESCALAR { bless { value => $_[1] }, shift }
    sub FETCH { $fetches++; $_[0]{value} }
    sub STORE { $_[0]{value} = $_[1] }
}

{
    package DispatchOn::Stringified;
    use overload '""' => sub { $_[0]{value} }, fallback => 1;
    sub new { bless { value => $_[1] }, shift }
}

{
    package DispatchOn::IdentityString;
    use overload '""' => sub { 'same' }, 'eq' => sub { 1 }, fallback => 1;
    sub new { bless {}, shift }
}

my $subject;
tie $subject, 'DispatchOn::Tie';
my $changed;
my $snapshot = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ($subject) {
        on (7) { $subject = 9; $changed = 1; }
    }
    1;
};
print !$@ && $snapshot && $changed && $DispatchOn::Tie::fetches == 1
    ? "ok 17 - subject fetched once\n"
    : "not ok 17 - subject fetched once\n";
print $subject == 7 ? "ok 18 - clause can write subject\n"
                    : "not ok 18 - clause can write subject\n";

my $clause_result = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    do {
        dispatch (1) {
            on (1) { 7; 42; }
        }
    }
};
print !$@ && defined($clause_result) && $clause_result == 42
    ? "ok 19 - dispatch returns the clause's last expression\n"
    : "not ok 19 - dispatch returns the clause's last expression\n";

my @clause_result = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    do {
        dispatch (1) {
            on (1) { (7, 42) }
        }
    }
};
print !$@ && @clause_result == 2 && $clause_result[0] == 7 && $clause_result[1] == 42
    ? "ok 20 - dispatch preserves list context\n"
    : "not ok 20 - dispatch preserves list context\n";

my $no_match = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    do {
        dispatch (2) {
            on (1) { 42 }
        }
    }
};
my @no_match = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    do {
        dispatch (2) {
            on (1) { 42 }
        }
    }
};
print !$@ && !defined($no_match) && !@no_match
    ? "ok 21 - no match returns undef or an empty list\n"
    : "not ok 21 - no match returns undef or an empty list\n";

my $default = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    do {
        dispatch ('other') {
            on ('expected') { die 'wrong clause'; }
            on (_) { 99 }
        }
    }
};
print !$@ && defined($default) && $default == 99
    ? "ok 22 - wildcard clause is the default\n"
    : "not ok 22 - wildcard clause is the default\n";

my $named_subject = eval q{
    use feature qw(dispatch_on namespaces);
    use dispatch::Predicates;
    do {
        dispatch my $bound (21) {
            on (21) { $bound }
        }
    }
};
print !$@ && defined($named_subject) && $named_subject == 21
    ? "ok 23 - dispatch binds a named subject\n"
    : "not ok 23 - dispatch binds a named subject\n";

my $scope_error = eval q{
    use feature qw(dispatch_on namespaces);
    use dispatch::Predicates;
    no warnings 'syntax';
    do {
        dispatch my $bound (21) {
            on (21) { 1 }
        }
    }
    $bound;
};
print $@ ? "ok 24 - named subject is dispatch-local\n"
         : "not ok 24 - named subject is dispatch-local\n";

my $guard_capture;
my $guard_fallback = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    do {
        dispatch ([1]) {
            on ([$guard_capture] if $guard_capture == 2) { die 'wrong clause'; }
            on (_) { 88 }
        }
    }
};
print !$@ && $guard_fallback == 88 && !defined($guard_capture)
    ? "ok 25 - failed guard rolls back captures\n"
    : "not ok 25 - failed guard rolls back captures\n";

my $guard_success = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    do {
        dispatch ([1]) {
            on ([$guard_capture] if $guard_capture == 1) { $guard_capture }
        }
    }
};
print !$@ && defined($guard_success) && $guard_success == 1
    ? "ok 26 - guard can use captures\n"
    : "not ok 26 - guard can use captures\n";

undef $guard_capture;
my $guard_exception = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ([1]) {
        on ([$guard_capture] if die 'guard failure') { 1 }
    }
};
print $@ && !defined($guard_capture)
    ? "ok 27 - guard exceptions restore captures\n"
    : "not ok 27 - guard exceptions restore captures\n";

my $with_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my ($left, $right) = (1, 2);
    dispatch ({ left => 1, right => 2 }) {
        on ({ left => ^$left, right => ^$right }) { 1 }
    }
};
print !$@ && $with_ok == 1 ? "ok 28 - direct pins compare lexical values\n"
                           : "not ok 28 - direct pins compare lexical values\n";

my $with_mismatch = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $left = 9;
    dispatch ({ left => 1 }) {
        on ({ left => ^$left }) { 1 }
    }
};
print !$@ && !defined($with_mismatch)
    ? "ok 29 - direct pins reject a mismatched value\n"
    : "not ok 29 - direct pins reject a mismatched value\n";

my $ordinary_case_statement = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (1) {
        1;
        on (1) { 2 }
    }
};
print $@ =~ /only dispatch-on clauses are allowed directly in a dispatch/
    ? "ok 30 - dispatch body rejects ordinary statements\n"
    : "not ok 30 - dispatch body rejects ordinary statements\n";

my $ordinary_clause_block = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (1) {
        on (1) {
            my $value = 0;
            for (1 .. 2) {
                $value += $_;
            }
            $value;
        }
    }
};
print !$@ && defined($ordinary_clause_block) && $ordinary_clause_block == 3
    ? "ok 31 - dispatch-on clause retains ordinary block syntax\n"
    : "not ok 31 - dispatch-on clause retains ordinary block syntax\n";

my $nested_case_in_clause = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $value;
    dispatch (1) {
        on (1) {
            dispatch (2) {
                on (2) { $value = 7 }
            }
        }
    }
    $value;
};
print !$@ && defined($nested_case_in_clause) && $nested_case_in_clause == 7
    ? "ok 32 - nested dispatch is valid inside a clause\n"
    : "not ok 32 - nested dispatch is valid inside a clause\n";

my $nested_case_as_clause = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (1) {
        dispatch (1) { on (1) { 7 } }
    }
};
print $@ =~ /only dispatch-on clauses are allowed directly in a dispatch/
    ? "ok 33 - nested dispatch is not a clause\n"
    : "not ok 33 - nested dispatch is not a clause\n";

my $expression_subject = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (int('12')) {
        on (12) { 1 }
    }
};
print !$@ && $expression_subject
    ? "ok 34 - dispatch accepts ordinary subject expressions\n"
    : "not ok 34 - dispatch accepts ordinary subject expressions\n";

my $undef_pattern = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (undef) {
        on (undef) { 1 }
    }
};
print !$@ && defined($undef_pattern) && $undef_pattern == 1
    ? "ok 35 - undef is a literal pattern\n"
    : "not ok 35 - undef is a literal pattern\n";

my $typed_reference = [];
my $typed_reference_result = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ($typed_reference) {
        on ($typed_reference) { 1 }
    }
};
print !$@ && $typed_reference_result
    ? "ok 36 - dispatch subjects preserve references\n"
    : "not ok 36 - dispatch subjects preserve references\n";

my ($typed_expression, $typed_parenthesized) = (undef, undef);
my $typed_expression_result = eval q{
    use feature qw(dispatch_on namespaces);
    use dispatch::Predicates;
    my $x = 1;
    dispatch my $bound ($x + 1) {
        on (2) { $typed_expression = $bound }
    }
    dispatch my $bound2 (($x + 1)) {
        on (2) { $typed_parenthesized = $bound2 }
    }
    1;
};
print !$@ && $typed_expression_result
    && $typed_expression eq '2' && $typed_parenthesized eq '2'
    ? "ok 37 - subject expressions bind equivalently\n"
    : "not ok 37 - subject expressions bind equivalently\n";

my $with_expression = eval q{
    use feature qw(dispatch_on namespaces);
    use dispatch::Predicates;
    my $base = 4;
    my $evaluations = 0;
    my $expected = ++$evaluations + $base;
    dispatch (8) {
        on (^$expected) { 1 }
    }
    $evaluations == 1;
};
print !$@ && $with_expression
    ? "ok 38 - a lexical can hold a computed pin value\n"
    : "not ok 38 - a lexical can hold a computed pin value\n";

my ($bool_yes, $bool_no, $bool_string) = (0, 0, 0);
my $typed_boolean = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    use builtin qw(true false);
    dispatch (true)  { on (true)  { $bool_yes = 1 } }
    dispatch (false) { on (false) { $bool_no = 1 } }
    dispatch ('yes') { on (true)  { $bool_string = 1 } }
    1;
};
print !$@ && $typed_boolean && $bool_yes && $bool_no && !$bool_string
    ? "ok 39 - boolean literals require boolean values\n"
    : "not ok 39 - boolean literals require boolean values\n";

my ($dispatch_order, $dispatch_duplicate, $dispatch_miss) = (0, 0, 0);
my @dispatch_warnings;
my $constant_dispatch;
{
    local $SIG{__WARN__} = sub { push @dispatch_warnings, @_ };
    $constant_dispatch = eval q{
        use feature 'dispatch_on';
        use dispatch::Predicates;
        use builtin qw(true false);
        dispatch (1) {
            on ('1') { $dispatch_order = 1 }
            on (true) { $dispatch_order = 2 }
            on (1) { $dispatch_order = 3 }
        }
        dispatch (1) {
            on (1) { $dispatch_duplicate++ }
            on (1) { $dispatch_duplicate += 10 }
        }
        dispatch (3) {
            on (1) { $dispatch_miss = 1 }
        }
        1;
    };
}
print !$@ && $constant_dispatch && $dispatch_order == 1
    && $dispatch_duplicate == 1 && !$dispatch_miss
    && @dispatch_warnings == 1
    ? "ok 40 - cross-type literal matches preserve source order\n"
    : "not ok 40 - cross-type literal matches preserve source order\n";

my ($dispatch_default, $dispatch_early_default) = (0, 0);
my $constant_dispatch_default = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (99) {
        on (1) { $dispatch_default = 1 }
        on (_) { $dispatch_default = 2 }
    }
    dispatch (99) {
        on (_)  { $dispatch_early_default = 3 }
        on (99) { $dispatch_early_default = 4 }
    }
    1;
};
print !$@ && $constant_dispatch_default
    && $dispatch_default == 2 && $dispatch_early_default == 3
    ? "ok 41 - constant dispatch preserves wildcard defaults\n"
    : "not ok 41 - constant dispatch preserves wildcard defaults\n";

my ($empty_default_scalar, @empty_default_list);
my $empty_default_result = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    $empty_default_scalar = sub {
        dispatch (99) {
            on (1) { 1 }
            on (_) { () }
        }
    }->();
    @empty_default_list = sub {
        dispatch (99) {
            on (1) { 1 }
            on (_) { () }
        }
    }->();
    1;
};
print !$@ && $empty_default_result && !defined($empty_default_scalar)
    && !@empty_default_list
    ? "ok 42 - empty wildcard default preserves context\n"
    : "not ok 42 - empty wildcard default preserves context\n";

my ($last_label, $next_label, $redo_label) = (0, 0, 0);
my $label_control = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    LABEL_LAST: dispatch (1) {
        on (1) { $last_label = 1; last LABEL_LAST; $last_label = 2 }
    }
    LABEL_NEXT: dispatch (1) {
        on (1) { $next_label = 1; next LABEL_NEXT; $next_label = 2 }
    }
    my $n = 0;
    LABEL_REDO: dispatch my $redo_subject (++$n) {
        on (1) { $redo_subject = 2; redo LABEL_REDO }
        on (2) { $redo_label = $n }
    }
    1;
};
print !$@ && $label_control && $last_label == 1 && $next_label == 1
    && $redo_label == 1
    ? "ok 43 - labelled dispatch control exits and redoes without reevaluating subject\n"
    : "not ok 43 - labelled dispatch control exits and redoes without reevaluating subject\n";

my ($captured_suffix, $unchanged_suffix, $empty_suffix) = ();
my ($captured_suffix_result, $empty_suffix_result);
my $concat_capture = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $text = 'foo_bar';
    dispatch ($text) {
        on ('foo_' . $captured_suffix) {
            $captured_suffix_result = $captured_suffix;
        }
    }
    $text = 'foo_';
    dispatch ($text) {
        on ('foo_' . $empty_suffix) {
            $empty_suffix_result = $empty_suffix;
        }
    }
    $text = 'not_bar';
    $unchanged_suffix = 'OLD';
    dispatch ($text) {
        on ('foo_' . $unchanged_suffix) { 1 }
    }
    1;
};
print !$@ && $concat_capture && $captured_suffix_result eq 'bar'
    && $empty_suffix_result eq '' && $unchanged_suffix eq 'OLD'
    ? "ok 44 - concatenation captures an unpinned suffix\n"
    : "not ok 44 - concatenation captures an unpinned suffix\n";

my ($pinned_match, $pinned_miss) = (0, 0);
my $concat_pin = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $p = 'bar';
    dispatch ('foo_bar') {
        on ('foo_' . ^$p) { $pinned_match = $p eq 'bar' }
    }
    $p = 'baz';
    dispatch ('foo_bar') {
        on ('foo_' . ^$p) { $pinned_miss = 1 }
    }
    1;
};
print !$@ && $concat_pin && $pinned_match && !$pinned_miss
    ? "ok 45 - pinned concatenation compares its complete value\n"
    : "not ok 45 - pinned concatenation compares its complete value\n";

my ($sandwich, $leading, $trailing) = ();
my ($sandwich_result, $leading_result, $trailing_result);
my $concat_shapes = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('xmiddlez') {
        on ('x' . $sandwich . 'z') { $sandwich_result = $sandwich }
    }
    dispatch ('middlez') {
        on ($leading . 'z') { $leading_result = $leading }
    }
    dispatch ('xmiddle') {
        on ('x' . $trailing) { $trailing_result = $trailing }
    }
    1;
};
print !$@ && $concat_shapes && $sandwich_result eq 'middle'
    && $leading_result eq 'middle' && $trailing_result eq 'middle'
    ? "ok 46 - concatenation supports prefix suffix and sandwich forms\n"
    : "not ok 46 - concatenation supports prefix suffix and sandwich forms\n";

my $strict_wildcard = eval q{
    use v5.45.3;
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (10) {
        on (_) { 1 }
    }
};
print !$@ && $strict_wildcard
    ? "ok 47 - wildcard works with strict subs\n"
    : "not ok 47 - wildcard works with strict subs\n";

my ($scope_label, $scope_p, $scope_q) = ('outer', 'outer', 'outer');
my @pattern_warnings;
my $implicit_bindings;
{
    local $SIG{__WARN__} = sub { push @pattern_warnings, @_ };
    $implicit_bindings = eval q{
        use strict;
        use warnings;
        use feature 'dispatch_on';
        use dispatch::Predicates;
        dispatch ('pfx_whatzit_thing') {
            on ('pfx_' . $label . '_thing' if $label eq 'whatzit') {
                $scope_label = $label;
            }
        }
        dispatch (['a', 1, 2]) {
            on (['a', $p, $q] if $p == 1) {
                $scope_p = $p;
                $scope_q = $q;
            }
        }
        1;
    };
}
print !$@ && $implicit_bindings && !@pattern_warnings
    && $scope_label eq 'whatzit' && $scope_p == 1 && $scope_q == 2
    ? "ok 48 - pattern names are implicit clause-local bindings\n"
    : "not ok 48 - pattern names are implicit clause-local bindings\n";

my $match_outside_case = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    on (1) { 1 }
};
print $match_outside_case eq '' && $@ =~ /only allowed directly in a dispatch/
    ? "ok 49 - on is forbidden outside dispatch\n"
    : "not ok 49 - on is forbidden outside dispatch\n";

my ($ref_kind, $scalar_kind, $undef_kind, $object_kind, $plain_ref_kind);
my $value_kinds = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $plain = [];
    my $object = bless {}, 'DispatchOnTestObject';

    dispatch ($plain) {
        on (BlessedVal()) { $object_kind = 1 }
        on (RefVal())    { $ref_kind = 1 }
    }
    dispatch (42) {
        on (RefVal())    { $plain_ref_kind = 1 }
        on (NonRefVal()) { $scalar_kind = 1 }
    }
    dispatch (undef) {
        on (NonRefVal()) { $undef_kind = 1 }
    }
    dispatch ($object) {
        on (BlessedVal()) { $object_kind = 2 }
    }
    1;
};
print !$@ && $value_kinds && $ref_kind == 1
    ? "ok 50 - RefVal matches unblessed references\n"
    : "not ok 50 - RefVal matches unblessed references\n";
print !$@ && $value_kinds && $scalar_kind && !$plain_ref_kind
    ? "ok 51 - NonRefVal matches non-references\n"
    : "not ok 51 - NonRefVal matches non-references\n";
print !$@ && $value_kinds && $undef_kind
    ? "ok 52 - NonRefVal includes undef\n"
    : "not ok 52 - NonRefVal includes undef\n";
print !$@ && $value_kinds && $object_kind == 2
    ? "ok 53 - BlessedVal matches blessed references\n"
    : "not ok 53 - BlessedVal matches blessed references\n";

my ($object_ref, $object_scalar);
my $object_subset = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $plain = {};
    dispatch ($plain) {
        on (BlessedVal()) { $object_ref = 1 }
        on (RefVal())    { $object_ref = 2 }
    }
    dispatch ('value') {
        on (BlessedVal()) { $object_scalar = 1 }
        on (NonRefVal()) { $object_scalar = 2 }
    }
    1;
};
print !$@ && $object_subset && $object_ref == 2
    ? "ok 54 - BlessedVal is a subset of RefVal\n"
    : "not ok 54 - BlessedVal is a subset of RefVal\n";
print !$@ && $object_subset && $object_scalar == 2
    ? "ok 55 - BlessedVal rejects non-references\n"
    : "not ok 55 - BlessedVal rejects non-references\n";

my ($ordinary_ref, $ordinary_scalar, $ordinary_object, $ordinary_subject);
my $ordinary_functions = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    sub RefVal    { 'ordinary ref function' }
    sub NonRefVal { 'ordinary scalar function' }
    sub BlessedVal { 'ordinary object function' }
    $ordinary_ref = RefVal();
    $ordinary_scalar = NonRefVal();
    $ordinary_object = BlessedVal();
    dispatch (RefVal()) {
        on ('ordinary ref function') { $ordinary_subject = 1 }
    }
    1;
};
print !$@ && $ordinary_functions
    && $ordinary_ref eq 'ordinary ref function'
    && $ordinary_scalar eq 'ordinary scalar function'
    && $ordinary_object eq 'ordinary object function'
    && $ordinary_subject
    ? "ok 56 - predicate names remain ordinary functions outside patterns\n"
    : "not ok 56 - predicate names remain ordinary functions outside patterns\n";
print !$@ && $ordinary_functions && $ordinary_subject
    ? "ok 57 - predicate names remain ordinary in a dispatch subject\n"
    : "not ok 57 - predicate names remain ordinary in a dispatch subject\n";

my ($pin_left, $pin_right);
my $multiple_with_aliases = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    ($pin_left, $pin_right) = (1, 2);
    dispatch ([1, 2]) {
        on ([^$pin_left, ^$pin_right]) { 1 }
    }
};
print !$@ && $multiple_with_aliases
    ? "ok 58 - lexical pins can be used directly\n"
    : "not ok 58 - lexical pins can be used directly\n";

my ($header_subject, $header_pin);
my $case_as_without_namespaces = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $value = 7;
    my $header_pin = 7;
    dispatch my $header_subject ($value) {
        on (7) { $header_subject == 7 && $header_pin == 7 }
    }
};
print !$@ && $case_as_without_namespaces
    ? "ok 59 - named dispatch subjects do not require namespaces\n"
    : "not ok 59 - named dispatch subjects do not require namespaces\n";

my ($slurp_result, $slurp_empty_result);
my $array_slurps = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ([1, 2, 3, 4]) {
        on ([1, @rest]) { $slurp_result = join(',', @rest) }
    }
    dispatch ([1]) {
        on ([1, @rest]) { $slurp_empty_result = join(',', @rest) }
    }
    1;
};
print !$@ && $array_slurps && $slurp_result eq '2,3,4'
    ? "ok 60 - array slurp captures the remaining elements\n"
    : "not ok 60 - array slurp captures the remaining elements\n";
print !$@ && $array_slurps && $slurp_empty_result eq ''
    ? "ok 61 - array slurp can be empty\n"
    : "not ok 61 - array slurp can be empty\n";

my ($ref_seen, $scalar_seen, $object_seen);
my $typed_pattern_targets = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $ref = [1];
    my $object = bless {}, 'DispatchOn::Object';
    dispatch ($ref) {
        on ($ref_target = RefVal()) { $ref_seen = $ref_target->[0] }
    }
    dispatch ('value') {
        on ($scalar_target = NonRefVal()) { $scalar_seen = $scalar_target }
    }
    dispatch ($object) {
        on ($object_target = BlessedVal()) { $object_seen = ref($object_target) }
    }
    1;
};
print !$@ && $typed_pattern_targets
    && $ref_seen == 1
    && $scalar_seen eq 'value'
    && $object_seen eq 'DispatchOn::Object'
    ? "ok 62 - predicate patterns bind assignment captures\n"
    : "not ok 62 - predicate patterns bind assignment captures\n";

my $typed_pattern_with_capture = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $ref = [];
    dispatch ($ref) {
        on ($ref = RefVal()) { 1 }
    }
    1;
};
print !$@ && $typed_pattern_with_capture
    ? "ok 63 - assignment capture is independent of an outer lexical\n"
    : "not ok 63 - assignment capture is independent of an outer lexical\n";

my $typed_pattern_wrong_target = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ({}) {
        on (@rest = RefVal()) { 1 }
    }
    1;
};
print $@ ? "ok 64 - predicate captures require scalar assignment targets\n"
         : "not ok 64 - predicate captures require scalar assignment targets\n";

my $typed_pattern_empty = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ([]) {
        on ([RefVal()]) { 1 }
    }
    1;
};
print !$@ && $typed_pattern_empty
    ? "ok 65 - predicates can match without a capture\n"
    : "not ok 65 - predicates can match without a capture\n";

my ($scalar_ref_value, $nested_ref_value);
my $reference_shapes = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $scalar = 7;
    my $scalar_ref = \$scalar;
    my $nested_ref = \\\\$scalar;
    dispatch ($scalar_ref) {
        on (\$captured) { $scalar_ref_value = $captured }
    }
    dispatch ($nested_ref) {
        on (\\\\$nested_captured) { $nested_ref_value = $nested_captured }
    }
    1;
};
print !$@ && $reference_shapes && $scalar_ref_value == 7
    && $nested_ref_value == 7
    ? "ok 66 - scalar and nested reference shapes bind referents\n"
    : "not ok 66 - scalar and nested reference shapes bind referents\n";

my $reference_mismatch = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ([ 7 ]) {
        on (\$captured) { 1 }
    }
};
print !$@ && !defined($reference_mismatch)
    ? "ok 67 - reference shapes reject non-references\n"
    : "not ok 67 - reference shapes reject non-references\n";

my $reference_pinned = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $expected = 7;
    my $actual = \$expected;
    dispatch ($actual) {
        on (^$actual) { 1 }
    }
};
print !$@ && $reference_pinned
    ? "ok 68 - direct reference pins compare by identity\n"
    : "not ok 68 - direct reference pins compare by identity\n";

my ($regex_capture, $regex_named);
my $regex_captures = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('user: Ada') {
        on (/^user: (?'name'\w+)$/) {
            $regex_capture = $1;
            $regex_named = $+{name};
        }
    }
    1;
};
print !$@ && $regex_captures && $regex_capture eq 'Ada'
    && $regex_named eq 'Ada'
    ? "ok 69 - regex captures are available in the clause\n"
    : "not ok 69 - regex captures are available in the clause\n";

my $regex_runtime = eval q{
    my $subject = 'value: 42';
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ($subject) {
        on (/^value: (\d+)$/) { 1 }
    }
};
print !$@ && $regex_runtime
    ? "ok 70 - regex patterns match runtime subjects\n"
    : "not ok 70 - regex patterns match runtime subjects\n";

my $regex_implicit;
my $regex_implicit_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('user: Grace') {
        on (/^user: (?<user>\w+)$/) {
            $regex_implicit = $user;
        }
    }
    1;
};
print !$@ && $regex_implicit_ok && $regex_implicit eq 'Grace'
    ? "ok 71 - named regex captures bind clause lexicals\n"
    : "not ok 71 - named regex captures bind clause lexicals\n";

my $regex_unmatched;
my $regex_unmatched_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('plain') {
        on (/^(?<prefix>extra:)?plain$/) {
            $regex_unmatched = !defined($prefix);
        }
    }
    1;
};
print !$@ && $regex_unmatched_ok && $regex_unmatched
    ? "ok 72 - nonparticipating named captures bind undef\n"
    : "not ok 72 - nonparticipating named captures bind undef\n";

my @numeric_shapes;
my $numeric_shapes_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    for my $value (0, 0.0, '0000', '0.0', '0000.0', ' 0000 ', 'A') {
        dispatch ($value) {
            on (Integer()) { push @numeric_shapes, 'I' }
            on (Number())  { push @numeric_shapes, 'N' }
            on (Num())     { push @numeric_shapes, 'S' }
            on (_)         { push @numeric_shapes, '-' }
        }
    }
    1;
};
print !$@ && $numeric_shapes_ok
    && join('', @numeric_shapes) eq 'INSSSS-'
    ? "ok 73 - numeric predicates classify native and string values\n"
    : "not ok 73 - numeric predicates classify native and string values\n";

my ($intstr_value, $floatstr_value);
my ($intstr_result, $floatstr_result);
my $numeric_bindings = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (' 0007 ') {
        on ($intstr_value = Int()) { $intstr_result = $intstr_value }
    }
    dispatch ('0007.0') {
        on ($floatstr_value = Num()) { $floatstr_result = $floatstr_value }
    }
    1;
};
print !$@ && $numeric_bindings && $intstr_result eq ' 0007 '
    && $floatstr_result eq '0007.0'
    ? "ok 74 - predicate captures preserve the original value\n"
    : "not ok 74 - predicate captures preserve the original value\n";

my $predicate_pin = eval q{
    use feature qw(dispatch_on signatures);
    no warnings 'experimental::signatures';
    use dispatch::Predicates;
    sub Between ($subject, $low, $high) {
        $subject >= $low && $subject <= $high
    }
    my $high = 10;
    dispatch (7) {
        on (Between(1, ^$high)) { 1 }
        on (_) { 0 }
    }
};
print !$@ && $predicate_pin
    ? "ok 75 - predicates receive the subject, constants, and pins\n"
    : "not ok 75 - predicates receive the subject, constants, and pins\n";

my ($integer_hit, $number_hit, $string_rejected);
my $native_numeric = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (12) {
        on (Integer()) { $integer_hit = 1 }
    }
    dispatch (12.5) {
        on (Number()) { $number_hit = 1 }
    }
    dispatch ('12') {
        on (Number()) { $string_rejected = 1 }
    }
    1;
};
print !$@ && $native_numeric && $integer_hit && $number_hit
    && !$string_rejected
    ? "ok 76 - Integer and Number require native numeric values\n"
    : "not ok 76 - Integer and Number require native numeric values\n";

my @numeric_warnings;
my $warning_free_numeric = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    local $SIG{__WARN__} = sub { push @numeric_warnings, @_ };
    dispatch ('not numeric') {
        on (Num()) { die 'wrong predicate result' }
        on (_) { 1 }
    }
};
print !$@ && $warning_free_numeric && !@numeric_warnings
    ? "ok 77 - Num rejects nonnumeric strings without warning\n"
    : "not ok 77 - Num rejects nonnumeric strings without warning\n";

my $local_predicate = eval q{
    use feature qw(dispatch_on signatures);
    no warnings 'experimental::signatures';
    use dispatch::Predicates;
    sub Int ($subject) { $subject eq 'local' }
    dispatch ('local') {
        on (Int()) { 1 }
        on (_) { 0 }
    }
};
print !$@ && $local_predicate
    ? "ok 78 - a local predicate shadows the imported predicate\n"
    : "not ok 78 - a local predicate shadows the imported predicate\n";

my $two_parameters = eval q{
    use feature qw(dispatch_on signatures);
    no warnings 'experimental::signatures';
    use dispatch::Predicates;
    sub Between ($subject, $low, $high) {
        $subject >= $low && $subject <= $high
    }
    dispatch (5) {
        on (Between(1, 10)) { 1 }
        on (_) { 0 }
    }
};
print !$@ && $two_parameters
    ? "ok 79 - predicate arguments follow the implicit subject\n"
    : "not ok 79 - predicate arguments follow the implicit subject\n";

my $dynamic_argument = eval q{
    use feature qw(dispatch_on signatures);
    no warnings 'experimental::signatures';
    use dispatch::Predicates;
    sub Between ($subject, $low) { $subject >= $low }
    my $low = 1;
    dispatch (5) { on (Between($low)) { 1 } }
};
print $@ =~ /predicate arguments must be constants or pinned values/
    ? "ok 80 - predicates reject unpinned lexical arguments\n"
    : "not ok 80 - predicates reject unpinned lexical arguments\n";

my $ordinary_predicate = eval q{
    use dispatch::Predicates;
    Int(1) && Num('1');
};
print !$@ && $ordinary_predicate
    ? "ok 81 - shared predicates are ordinary callable functions\n"
    : "not ok 81 - shared predicates are ordinary callable functions\n";

my $capture_assignment = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $captured;
    my $observed;
    dispatch (' 7 ') {
        on ($captured = Int()) { $observed = $captured }
        on (_) { 0 }
    }
    $observed;
};
print !$@ && defined($capture_assignment) && $capture_assignment eq ' 7 '
    ? "ok 82 - assignment capture does not normalize its subject\n"
    : "not ok 82 - assignment capture does not normalize its subject\n";

my $num_string = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('0007.0') { on (Num()) { 1 } on (_) { 0 } }
};
print !$@ && $num_string
    ? "ok 83 - Num accepts padded numeric strings\n"
    : "not ok 83 - Num accepts padded numeric strings\n";

my ($pin_hit, $pin_y) = (0, 7);
my $caret_pin = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $x = [ 7, 7, 7 ];
    dispatch ($x) {
        on ([^$pin_y, ^$pin_y, ^$pin_y]) { $pin_hit = 1; }
    }
    1;
};
print !$@ && $caret_pin && $pin_hit
    ? "ok 84 - caret pins an existing lexical\n"
    : "not ok 84 - caret pins an existing lexical\n";

my ($mixed_pin, $mixed_tail, $mixed_tail_result);
my $mixed_pin_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ([ 7, 4 ]) {
        on ([^$pin_y, $mixed_tail]) {
            $mixed_pin = 1;
            $mixed_tail_result = $mixed_tail;
        }
    }
    1;
};
print !$@ && $mixed_pin_ok && $mixed_pin && $mixed_tail_result == 4
    ? "ok 85 - caret pins can mix with captures\n"
    : "not ok 85 - caret pins can mix with captures\n";

my ($xor_left, $xor_right, $xor_seen) = (1, 2, 0);
my $guard_xor_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (0) {
        on (0 if (($xor_left ^ $xor_right) == 3)) { $xor_seen = 1; }
    }
    1;
};
print !$@ && $guard_xor_ok && $xor_seen
    ? "ok 86 - ordinary caret remains XOR in guards\n"
    : "not ok 86 - ordinary caret remains XOR in guards\n";

my ($snapshot_hit, $snapshot_y) = (0, 7);
my $snapshot_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ([ 7 ]) {
        on ([^$snapshot_y] if (($snapshot_y = 8) && 0)) { die 'wrong clause'; }
        on ([^$snapshot_y]) { $snapshot_hit = 1; }
    }
    1;
};
print !$@ && $snapshot_ok && !$snapshot_hit && $snapshot_y == 8
    ? "ok 87 - later clauses read the current pinned value\n"
    : "not ok 87 - later clauses read the current pinned value\n";

my $unbound_pin = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (1) { on (^$not_declared) { 1; } }
    1;
};
print $@ =~ /pinned pattern value must be an existing scalar lexical/
    ? "ok 88 - caret requires an existing lexical\n"
    : "not ok 88 - caret requires an existing lexical\n";

my ($constant_call_hit, $method_call_hit);
my $zero_arg_calls = eval q{
    use strict;
    use feature 'dispatch_on';
    use dispatch::Predicates;
    sub dispatch_pattern_value { 7 }
    {
        package CasePatternCallTest;
        sub value { 7 }
    }
    dispatch (7) {
        on (dispatch_pattern_value()) { $constant_call_hit = 1 }
    }
    dispatch (7) {
        on (CasePatternCallTest->value()) { $method_call_hit = 1 }
    }
    1;
};
print !$@ && $zero_arg_calls && $constant_call_hit && $method_call_hit
    ? "ok 89 - zero-argument pattern calls\n"
    : "not ok 89 - zero-argument pattern calls\n";

my $pattern_call_args = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    sub dispatch_pattern_value { 7 }
    dispatch (7) { on (dispatch_pattern_value(7)) { 1 } }
    1;
};
print $@ =~ /unsupported dispatch pattern call/
    ? "ok 90 - pattern calls reject arguments\n"
    : "not ok 90 - pattern calls reject arguments\n";

my $unsupported_pattern_expression = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $x = 7;
    dispatch (8) { on ($x + 1) { 1 } }
    1;
};
print $@ =~ /unsupported dispatch pattern expression/
    ? "ok 91 - unsupported pattern expressions are rejected\n"
    : "not ok 91 - unsupported pattern expressions are rejected\n";

my $call_inside_shape = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    sub dispatch_pattern_value { 7 }
    dispatch ([ 1, 7 ]) {
        on ([ 1, dispatch_pattern_value() ]) { 1 }
    }
    1;
};
print !$@ && $call_inside_shape
    ? "ok 92 - zero-argument calls work inside shapes\n"
    : "not ok 92 - zero-argument calls work inside shapes\n";

my @duplicate_case_warnings;
my ($duplicate_first, $duplicate_second) = (0, 0);
my $duplicate_constants;
{
    local $SIG{__WARN__} = sub { push @duplicate_case_warnings, @_ };
    $duplicate_constants = eval q{
        use feature 'dispatch_on';
        use dispatch::Predicates;
        dispatch (1) {
            on (1) { $duplicate_first = 1 }
            on (1) { $duplicate_second = 1 }
        }
        dispatch ('x') {
            on ('x') { 1 }
            on ('x') { 2 }
        }
        1;
    };
}
my $duplicate_warning_count = grep {
    /duplicate dispatch pattern constant (?:1|x) will never match/
} @duplicate_case_warnings;
my $duplicate_warning_values = grep {
    /constant 1/ && /constant x/
} join('', @duplicate_case_warnings);
print !$@ && $duplicate_constants && $duplicate_first == 1
    && !$duplicate_second && $duplicate_warning_count == 2
    && $duplicate_warning_values
    ? "ok 93 - duplicate constant patterns warn and retain first clause\n"
    : "not ok 93 - duplicate constant patterns warn and retain first clause\n";

my @mixed_duplicate_warnings;
my $mixed_duplicate_constants;
{
    local $SIG{__WARN__} = sub { push @mixed_duplicate_warnings, @_ };
    $mixed_duplicate_constants = eval q{
        use feature 'dispatch_on';
        use dispatch::Predicates;
        my $dynamic = 1;
        dispatch (1) {
            on (1) { 1 }
            on ($dynamic) { 2 }
            on (1) { 3 }
        }
        1;
    };
}
print !$@ && $mixed_duplicate_constants && @mixed_duplicate_warnings == 1
    && $mixed_duplicate_warnings[0] =~ /constant 1/
    ? "ok 94 - duplicate constants warn in mixed cases\n"
    : "not ok 94 - duplicate constants warn in mixed cases\n";

my $regex_open_capture;
my $regex_open_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ([ 'skip', 'target', 'tail' ]) {
        on ([ ..., /^(?<word>target)$/, ... ]) {
            $regex_open_capture = $word;
        }
    }
    1;
};
print !$@ && $regex_open_ok && $regex_open_capture eq 'target'
    ? "ok 95 - regex patterns search open arrays\n"
    : "not ok 95 - regex patterns search open arrays\n";

my $regex_localization = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    'outer' =~ /(?<outer>outer)/;
    my ($before_one, $before_named) = ($1, $+{outer});
    my ($inside_one, $inside_two, $inside_named);
    dispatch ('inner value') {
        on (/(?<inner>inner) (value)/) {
            ($inside_one, $inside_two, $inside_named) =
                ($1, $2, $+{inner});
        }
    }
    [ $before_one, $before_named, $inside_one, $inside_two,
      $inside_named, $1, $+{outer}, $-{outer}[0] ];
};
print !$@ && $regex_localization
    && $regex_localization->[0] eq 'outer'
    && $regex_localization->[1] eq 'outer'
    && $regex_localization->[2] eq 'inner'
    && $regex_localization->[3] eq 'value'
    && $regex_localization->[4] eq 'inner'
    && $regex_localization->[5] eq 'outer'
    && $regex_localization->[6] eq 'outer'
    && $regex_localization->[7] eq 'outer'
    ? "ok 96 - regex captures are localized to the dispatch\n"
    : "not ok 96 - regex captures are localized to the dispatch\n";

my $regex_code_block = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('foo') {
        on (/(?{ 1 })foo/) { 1; }
    }
    1;
};
print $@ && $@ =~ /regex code blocks are not supported in dispatch patterns/
    ? "ok 97 - regex code blocks are rejected\n"
    : "not ok 97 - regex code blocks are rejected\n";

my $unicode_regex = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $word = "caf\x{e9}";
    dispatch ($word) {
        on (/^caf\x{e9}$/) { 1 }
    }
    1;
};
print !$@ && $unicode_regex
    ? "ok 98 - regex patterns preserve Unicode behavior\n"
    : "not ok 98 - regex patterns preserve Unicode behavior\n";

my $byte_regex = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $word = pack 'C*', 99, 97, 102, 233;
    dispatch ($word) {
        on (/^caf\xE9$/) { 1 }
    }
    1;
};
print !$@ && $byte_regex
    ? "ok 99 - regex patterns preserve byte behavior\n"
    : "not ok 99 - regex patterns preserve byte behavior\n";

my $regex_open_hash_capture;
my $regex_open_hash_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ({ first => 'skip', second => 'target', third => 'tail' }) {
        on ({ second => /^(?<word>target)$/, ... }) {
            $regex_open_hash_capture = $word;
        }
    }
    1;
};
print !$@ && $regex_open_hash_ok && $regex_open_hash_capture eq 'target'
    ? "ok 100 - regex patterns search open hashes\n"
    : "not ok 100 - regex patterns search open hashes\n";

my $regex_tied;
tie $regex_tied, 'DispatchOn::RegexTie', 'target';
$DispatchOn::RegexTie::fetches = 0;
my $regex_tied_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ($regex_tied) {
        on (/^target$/) { 1 }
    }
    1;
};
print !$@ && $regex_tied_ok && $DispatchOn::RegexTie::fetches == 1
    ? "ok 101 - regex patterns fetch tied subjects once\n"
    : "not ok 101 - regex patterns fetch tied subjects once\n";

my $regex_overloaded = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (DispatchOn::Stringified->new('target')) {
        on (/^target$/) { 1 }
    }
    1;
};
print !$@ && $regex_overloaded
    ? "ok 102 - regex patterns use overloaded subjects\n"
    : "not ok 102 - regex patterns use overloaded subjects\n";

my $dynamic_regex = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $re = 'target';
    dispatch ('target') {
        on (/$re/) { 1 }
    }
    1;
};
print $@ =~ /dynamic regexes are only allowed as a guard condition/
    ? "ok 103 - dynamic regex patterns are rejected\n"
    : "not ok 103 - dynamic regex patterns are rejected\n";

my $pinned_dynamic_regex = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $re = 'target';
    dispatch ('target') {
        on (/$re/) { 1 }
    }
    1;
};
print $@ =~ /dynamic regexes are only allowed as a guard condition/
    ? "ok 104 - pinned dynamic regex patterns are rejected\n"
    : "not ok 104 - pinned dynamic regex patterns are rejected\n";

my ($wildcard_guard, $identity_guard);
my $guard_identity = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $subject = 'same';
    my $re = qr/^same$/;
    dispatch ($subject) {
        on (_ if $subject =~ $re) { $wildcard_guard = 1; }
    }
    dispatch ($subject) {
        on ($subject if $subject eq 'same') { $identity_guard = 1; }
    }
    1;
};
print !$@ && $guard_identity && $wildcard_guard && $identity_guard
    ? "ok 105 - guards work with wildcard and identity patterns\n"
    : "not ok 105 - guards work with wildcard and identity patterns\n";

my $false_identity_guard = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $subject = 'same';
    dispatch ($subject) {
        on ($subject if $subject eq 'different') { die 'wrong clause'; }
    }
    1;
};
print !$@ && $false_identity_guard
    ? "ok 106 - identity pattern still evaluates its guard\n"
    : "not ok 106 - identity pattern still evaluates its guard\n";

my ($object_x, $object_y);
my $object_hash_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $object_hash = bless { '$x' => 10, '$y' => 20 }, 'Point';
    dispatch ($object_hash) {
        on (Point { '$x' => $x, '$y' => $y }) {
            ($object_x, $object_y) = ($x, $y);
        }
    }
    1;
};
print !$@ && $object_hash_ok && $object_x == 10 && $object_y == 20
    ? "ok 107 - blessed hash objects destructure named fields\n"
    : "not ok 107 - blessed hash objects destructure named fields\n";

my $object_exact = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $object_hash = bless { '$x' => 10, '$y' => 20 }, 'Point';
    dispatch ($object_hash) {
        on (Point { '$x' => 10 }) { die 'extra field matched'; }
    }
    1;
};
print !$@ && $object_exact
    ? "ok 108 - object field patterns are exact by default\n"
    : "not ok 108 - object field patterns are exact by default\n";

my $object_open;
my $object_open_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $object_hash = bless { '$x' => 10, '$y' => 20 }, 'Point';
    dispatch ($object_hash) {
        on (Point { '$x' => $x, ... }) { $object_open = $x; }
    }
    1;
};
print !$@ && $object_open_ok && $object_open == 10
    ? "ok 109 - object field patterns accept a trailing ellipsis\n"
    : "not ok 109 - object field patterns accept a trailing ellipsis\n";

my ($object_first, $object_second);
my $object_array_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $object_array = bless [ 30, 40 ], 'Point';
    dispatch ($object_array) {
        on (Point [ $first, $second ]) {
            ($object_first, $object_second) = ($first, $second);
        }
    }
    1;
};
print !$@ && $object_array_ok && $object_first == 30 && $object_second == 40
    ? "ok 110 - blessed array objects destructure positional values\n"
    : "not ok 110 - blessed array objects destructure positional values\n";

my $object_wrong_class = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $other = bless { '$x' => 10, '$y' => 20 }, 'Other';
    dispatch ($other) {
        on (Point { '$x' => 10, '$y' => 20 }) { die 'wrong class matched'; }
    }
    1;
};
print !$@ && $object_wrong_class
    ? "ok 111 - object patterns check the class name\n"
    : "not ok 111 - object patterns check the class name\n";

my $object_scalar;
my $object_scalar_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $value = 70;
    my $object = bless \$value, 'Point';
    dispatch ($object) {
        on (Point \$captured) { $object_scalar = $captured; }
    }
    1;
};
print !$@ && $object_scalar_ok && $object_scalar == 70
    ? "ok 112 - blessed scalar references destructure their value\n"
    : "not ok 112 - blessed scalar references destructure their value\n";

my ($concat_first, $concat_second, $concat_multiple_result);
my $concat_multiple = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('aXbYbC') {
        on ('a' . $concat_first . 'b' . $concat_second . 'C') {
            $concat_multiple_result = "$concat_first/$concat_second";
        }
    }
    1;
};
print !$@ && $concat_multiple
    && $concat_multiple_result eq 'X/Yb'
    ? "ok 113 - concatenation supports multiple captures\n"
    : "not ok 113 - concatenation supports multiple captures\n";

my ($concat_empty_first, $concat_empty_last, $concat_empty_multiple_result);
my $concat_empty_multiple = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('a-b') {
        on ('a' . $concat_empty_first . '-' . $concat_empty_last) {
            $concat_empty_multiple_result =
                "$concat_empty_first/$concat_empty_last";
        }
    }
    1;
};
print !$@ && $concat_empty_multiple
    && $concat_empty_multiple_result eq '/b'
    ? "ok 114 - concatenation permits empty multiple captures\n"
    : "not ok 114 - concatenation permits empty multiple captures\n";

my $concat_adjacent = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('ab') {
        on ($concat_first . $concat_second) { 1 }
    }
    1;
};
print $@ =~ /captures must be separated by non-empty constant text/
    ? "ok 115 - adjacent concatenation captures are rejected\n"
    : "not ok 115 - adjacent concatenation captures are rejected\n";

my $concat_empty_separator = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('ab') {
        on ($concat_first . '' . $concat_second) { 1 }
    }
    1;
};
print $@ =~ /captures must be separated by non-empty constant text/
    ? "ok 116 - empty fragments do not separate captures\n"
    : "not ok 116 - empty fragments do not separate captures\n";

my $concat_repeated = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('a-b-c') {
        on ('a' . $concat_first . '-' . $concat_first . '-c') { 1 }
    }
    1;
};
print $@ =~ /duplicate capture \$concat_first in a dispatch-on clause/
    ? "ok 117 - repeated concatenation captures are rejected\n"
    : "not ok 117 - repeated concatenation captures are rejected\n";

my $concat_call = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    sub concat_value { 'x' }
    dispatch ('axb') {
        on ('a' . concat_value() . 'b') { 1 }
    }
    1;
};
print $@ =~ /unsupported dispatch pattern concatenation expression/
    ? "ok 118 - calls in concatenation patterns are rejected\n"
    : "not ok 118 - calls in concatenation patterns are rejected\n";

my $concat_arithmetic = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $offset = 1;
    dispatch ('a2b') {
        on ('a' . ($offset + 1) . 'b') { 1 }
    }
    1;
};
print $@ =~ /unsupported dispatch pattern concatenation expression/
    ? "ok 119 - arithmetic in concatenation patterns is rejected\n"
    : "not ok 119 - arithmetic in concatenation patterns is rejected\n";

my ($concat_caret_pin, $concat_caret_result);
my $concat_caret = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $fixed = 'X';
    dispatch ('aX-b') {
        on ('a' . ^$fixed . '-' . $concat_caret_pin) {
            $concat_caret_result = $concat_caret_pin;
        }
    }
    1;
};
print !$@ && $concat_caret && $concat_caret_result eq 'b'
    ? "ok 120 - concatenation supports caret-pinned boundaries\n"
    : "not ok 120 - concatenation supports caret-pinned boundaries\n";

my $concat_pin_repeat;
my $concat_pinned_multiple = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $fixed = 'X';
    dispatch ('aXbXc') {
        on ('a' . ^$fixed . 'b' . ^$fixed . 'c') {
            $concat_pin_repeat = 1;
        }
    }
    1;
};
print !$@ && $concat_pinned_multiple && $concat_pin_repeat
    ? "ok 121 - repeated pinned concatenation fragments are allowed\n"
    : "not ok 121 - repeated pinned concatenation fragments are allowed\n";

my $concat_overloaded_result;
my $concat_overloaded = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (DispatchOn::Stringified->new('aXb')) {
        on ('a' . $concat_overloaded_capture . 'b') {
            $concat_overloaded_result = $concat_overloaded_capture;
        }
    }
    1;
};
print !$@ && $concat_overloaded
    && $concat_overloaded_result eq 'X'
    ? "ok 122 - concatenation uses overloaded stringification\n"
    : "not ok 122 - concatenation uses overloaded stringification\n";

my ($native_x, $native_y, $native_class_result);
my $native_class_match = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    use experimental 'class';
    class NativePointCase {
        field $x :param;
        field $y :param;
    }
    my $point = NativePointCase->new(x => 10, y => 20);
    dispatch ($point) {
        on (NativePointCase {
            '$x' => $x,
            '$y' => $y,
        }) {
            ($native_x, $native_y) = ($x, $y);
            $native_class_result = 1;
        }
    }
    1;
};
print !$@ && $native_class_match && $native_class_result
    && $native_x == 10 && $native_y == 20
    ? "ok 123 - native class fields destructure directly\n"
    : "not ok 123 - native class fields destructure directly\n";

my $native_subclass_result = 0;
my $native_exact_class = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    use experimental 'class';
    class NativeSubCase :isa(NativePointCase) { }
    my $point = NativeSubCase->new(x => 10, y => 20);
    dispatch ($point) {
        on (NativePointCase { '$x' => 10, '$y' => 20 }) {
            $native_subclass_result = 1;
        }
    }
    1;
};
print !$@ && $native_exact_class && $native_subclass_result
    ? "ok 124 - native class patterns accept subclasses\n"
    : "not ok 124 - native class patterns accept subclasses\n";

my $pinned_identity_result = 0;
my $pinned_identity = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $wanted = DispatchOn::IdentityString->new;
    my $other = DispatchOn::IdentityString->new;
    dispatch ($other) {
        on (^$wanted) { $pinned_identity_result = 1; }
    }
    1;
};
print !$@ && $pinned_identity && !$pinned_identity_result
    ? "ok 125 - pinned references compare by identity\n"
    : "not ok 125 - pinned references compare by identity\n";

my $native_overload_result = 0;
my $native_overload = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    use experimental 'class';
    class NativeOverloadPointCase { field $x :param }
    my $point = NativeOverloadPointCase->new(
        x => DispatchOn::Stringified->new('same'));
    dispatch ($point) {
        on (NativeOverloadPointCase { '$x' => 'same' }) {
            $native_overload_result = 1;
        }
    }
    1;
};
print !$@ && $native_overload && $native_overload_result
    ? "ok 126 - nested overload is used for string patterns\n"
    : "not ok 126 - nested overload is used for string patterns\n";

my $native_tied_fetches = 0;
my $native_tied_result = 0;
my $native_tied = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    use experimental 'class';
    tie my $field, 'DispatchOn::Tie';
    class NativeTiedPointCase { field $x :param }
    my $point = NativeTiedPointCase->new(x => $field);
    dispatch ($point) {
        on (NativeTiedPointCase { '$x' => 7 }) {
            $native_tied_result = 1;
        }
    }
    1;
};
$native_tied_fetches = $DispatchOn::Tie::fetches;
print !$@ && $native_tied && $native_tied_result && $native_tied_fetches
    ? "ok 127 - tied nested values use normal read semantics\n"
    : "not ok 127 - tied nested values use normal read semantics\n";

my $native_missing_result = 0;
my $native_missing = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    use experimental 'class';
    class NativeMissingPointCase { field $x :param }
    my $point = NativeMissingPointCase->new(x => 10);
    dispatch ($point) {
        on (NativeMissingPointCase { '$missing' => 10 }) {
            $native_missing_result = 1;
        }
    }
    1;
};
print !$@ && $native_missing && !$native_missing_result
    ? "ok 128 - missing native fields are a non-match\n"
    : "not ok 128 - missing native fields are a non-match\n";

my ($defined_value, $defined_undef, $defined_binding, $defined_binding_seen);
my $defined_criterion = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (42) {
        on ($defined_binding = DefinedVal()) {
            $defined_value = 1;
            $defined_binding_seen = $defined_binding == 42;
        }
    }
    dispatch (undef) {
        on (DefinedVal()) { $defined_undef = 1 }
    }
    1;
};
print !$@ && $defined_criterion && $defined_value && !$defined_undef
    && $defined_binding_seen
    ? "ok 129 - DefinedVal matches and binds defined values\n"
    : "not ok 129 - DefinedVal matches and binds defined values\n";

my ($native_int_hit, $native_int_miss, $native_float_hit, $native_float_miss);
my $native_predicates = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (42) {
        on (Integer()) { $native_int_hit = 1 }
        on (_) { $native_int_miss = 1 }
    }
    dispatch (42.5) {
        on (Number()) { $native_float_hit = 1 }
        on (_) { $native_float_miss = 1 }
    }
    1;
};
print !$@ && $native_predicates && $native_int_hit && !$native_int_miss
    && $native_float_hit && !$native_float_miss
    ? "ok 130 - Integer and Number match native numeric kinds\n"
    : "not ok 130 - Integer and Number match native numeric kinds\n";

my ($typed_int_string, $typed_num_string);
my $native_predicates_reject_strings = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('42') {
        on (Integer()) { $typed_int_string = 1 }
        on (Number()) { $typed_num_string = 1 }
    }
    1;
};
print !$@ && $native_predicates_reject_strings
    && !$typed_int_string && !$typed_num_string
    ? "ok 131 - Integer and Number reject strings\n"
    : "not ok 131 - Integer and Number reject strings\n";

my $boolean_predicates = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    use builtin qw(true false);
    my ($strict_true, $strict_false, $truthy_string, $falsey_string);
    dispatch (true)  { on (True())  { $strict_true = 1 } }
    dispatch (false) { on (False()) { $strict_false = 1 } }
    dispatch ('yes') { on (True())  { $truthy_string = 1 } }
    dispatch ('')    { on (False()) { $falsey_string = 1 } }
    join '', map { $_ ? 1 : 0 }
        $strict_true, $strict_false, $truthy_string, $falsey_string;
};
print !$@ && $boolean_predicates eq '1111'
    ? "ok 132 - TRUE and FALSE use expression truth semantics\n"
    : "not ok 132 - TRUE and FALSE use expression truth semantics\n";

my $large_slurp_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my @value = (1, 2, 3..302);
    dispatch (\@value) {
        on ([1, 2, @rest]) { scalar(@rest) == 300 }
    }
};
print !$@ && $large_slurp_ok
    ? "ok 133 - array slurps can capture many elements\n"
    : "not ok 133 - array slurps can capture many elements\n";

my $large_slurp_miss = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my @value = (1, 2);
    dispatch (\@value) {
        on ([1, 2, @rest2]) { scalar(@rest2) == 0 }
        on (_) { 1 }
    }
};
print !$@ && $large_slurp_miss
    ? "ok 134 - array slurps capture empty tails\n"
    : "not ok 134 - array slurps capture empty tails\n";

my $direct_subject_capture = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $identity_subject = 42;
    dispatch ($identity_subject) {
        on ($identity_subject) { $identity_subject }
    }
};
print !$@ && defined($direct_subject_capture) && $direct_subject_capture == 42
    ? "ok 135 - bare direct subject name is a capture\n"
    : "not ok 135 - bare direct subject name is a capture\n";

my $implicit_subject_array_capture = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $identity_subject = [42];
    dispatch ($identity_subject) {
        on ([$identity_subject]) { $identity_subject }
    }
};
print !$@ && defined($implicit_subject_array_capture)
    && $implicit_subject_array_capture == 42
    ? "ok 136 - bare direct subject name captures inside an array\n"
    : "not ok 136 - bare direct subject name captures inside an array\n";

my $implicit_subject_hash_capture = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $identity_subject = { value => 42 };
    dispatch ($identity_subject) {
        on ({ value => $identity_subject, ... }) { $identity_subject }
    }
};
print !$@ && defined($implicit_subject_hash_capture)
    && $implicit_subject_hash_capture == 42
    ? "ok 137 - bare direct subject name captures inside a hash\n"
    : "not ok 137 - bare direct subject name captures inside a hash\n";

my $explicit_subject_pin_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $identity_subject = 42;
    dispatch ($identity_subject) {
        on ([ ^$identity_subject ]) { 1 }
    }
    1;
};
print !$@ && $explicit_subject_pin_ok
    ? "ok 138 - explicit subject pins remain valid\n"
    : "not ok 138 - explicit subject pins remain valid\n";

my ($hash_tail, $hash_tail_empty);
my $hash_slurps = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ({ fixed => 1, extra => 2, another => 3 }) {
        on ({ fixed => 1, %rest }) { $hash_tail = join ',', sort keys %rest }
    }
    dispatch ({ fixed => 1 }) {
        on ({ fixed => 1, %rest }) { $hash_tail_empty = scalar keys %rest }
    }
    1;
};
print !$@ && $hash_slurps && $hash_tail eq 'another,extra'
    ? "ok 139 - hash slurps capture remaining fields\n"
    : "not ok 139 - hash slurps capture remaining fields\n";
print !$@ && $hash_slurps && $hash_tail_empty == 0
    ? "ok 140 - hash slurps can be empty\n"
    : "not ok 140 - hash slurps can be empty\n";

my $hash_slurp_exact = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ({ fixed => 1, extra => 2 }) {
        on ({ fixed => 1 }) { die 'hash slurp was not required' }
        on (_) { 1 }
    }
};
print !$@ && $hash_slurp_exact
    ? "ok 141 - hash slurps permit otherwise-extra fields\n"
    : "not ok 141 - hash slurps permit otherwise-extra fields\n";

my $hash_slurp_placement = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ({ fixed => 1 }) {
        on ({ %rest, fixed => 1 }) { 1 }
    }
    1;
};
print $@ =~ /hash slurp must be the final pattern element/
    ? "ok 142 - hash slurp must be final\n"
    : "not ok 142 - hash slurp must be final\n";

my $hash_ellipsis_placement = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ({ fixed => 1 }) {
        on ({ ..., fixed => 1 }) { 1 }
    }
    1;
};
print $@ =~ /hash pattern ellipsis must be last/
    ? "ok 143 - hash ellipsis must be final\n"
    : "not ok 143 - hash ellipsis must be final\n";

my $hash_slurp_ellipsis = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ({ fixed => 1 }) {
        on ({ fixed => 1, ..., %rest }) { 1 }
    }
    1;
};
print $@ =~ /hash pattern ellipsis must be last/
    ? "ok 144 - hash slurp cannot combine with ellipsis\n"
    : "not ok 144 - hash slurp cannot combine with ellipsis\n";

my @rejected_hash_tails;
my $hash_tail_guard = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    for my $iteration (1, 2) {
        dispatch ({ fixed => 1, extra => $iteration }) {
            on ({ fixed => 1, %rest } if do {
                push @rejected_hash_tails, sub { $rest{extra} };
                0;
            }) { die 'wrong clause' }
            on (_) { 1 }
        }
    }
    1;
};
print !$@ && $hash_tail_guard && @rejected_hash_tails == 2
        && $rejected_hash_tails[0]->() == 1
        && $rejected_hash_tails[1]->() == 2
    ? "ok 145 - failed guard preserves an escaped hash-tail capture\n"
    : "not ok 145 - failed guard preserves an escaped hash-tail capture\n";

my $object_hash_tail;
my $object_hash_tail_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $object_hash = bless { '$x' => 10, extra => 20 }, 'Point';
    dispatch ($object_hash) {
        on (Point { '$x' => $x, %rest }) {
            $object_hash_tail = $rest{extra};
        }
    }
    1;
};
print !$@ && $object_hash_tail_ok && $object_hash_tail == 20
    ? "ok 146 - object hash patterns capture remaining fields\n"
    : "not ok 146 - object hash patterns capture remaining fields\n";

my $object_hash_tail_placement = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $object_hash = bless { '$x' => 10 }, 'Point';
    dispatch ($object_hash) {
        on (Point { %rest, '$x' => $x }) { 1 }
    }
    1;
};
print $@ =~ /object hash slurp must be the final pattern element/
    ? "ok 147 - object hash slurp must be final\n"
    : "not ok 147 - object hash slurp must be final\n";

my $hash_array_tail;
my $hash_array_tail_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ({ fixed => 1, extra => 20 }) {
        on ({ fixed => 1, @rest }) {
            $hash_array_tail = join ',', @rest;
        }
    }
    1;
};
print !$@ && $hash_array_tail_ok && $hash_array_tail eq 'extra,20'
    ? "ok 148 - hash patterns can capture remaining fields in an array\n"
    : "not ok 148 - hash patterns can capture remaining fields in an array\n";

my $array_hash_tail;
my $array_hash_tail_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ([ 'head', 'extra', 20 ]) {
        on ([ 'head', %tail ]) { $array_hash_tail = $tail{extra} }
    }
    1;
};
print !$@ && $array_hash_tail_ok && $array_hash_tail == 20
    ? "ok 149 - array patterns can capture remaining pairs in a hash\n"
    : "not ok 149 - array patterns can capture remaining pairs in a hash\n";

my ($odd_hash_tail_warning, $odd_hash_tail_value);
my $odd_hash_tail_ok = eval q{
    use warnings 'misc';
    local $SIG{__WARN__} = sub { $odd_hash_tail_warning .= $_[0] };
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ([ 'head', 'lonely' ]) {
        on ([ 'head', %tail ]) { $odd_hash_tail_value = $tail{lonely} }
    }
    1;
};
print !$@ && $odd_hash_tail_ok
        && $odd_hash_tail_warning =~ /Odd number of elements in hash assignment/
        && !defined $odd_hash_tail_value
    ? "ok 150 - odd array tails warn like hash assignment\n"
    : "not ok 150 - odd array tails warn like hash assignment\n";

my $reference_hash_tail_warning;
my $reference_hash_tail_ok = eval q{
    use warnings 'misc';
    local $SIG{__WARN__} = sub { $reference_hash_tail_warning .= $_[0] };
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ([ 'head', [] ]) {
        on ([ 'head', %tail ]) { 1 }
    }
    1;
};
print !$@ && $reference_hash_tail_ok
        && $reference_hash_tail_warning =~ /Reference found where even-sized list expected/
    ? "ok 151 - odd reference tails use hash-assignment warning\n"
    : "not ok 151 - odd reference tails use hash-assignment warning\n";

my $double_quoted_pattern;
my $double_quoted_pattern_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('foo bar') {
        on ("foo \\LBar\\E") { $double_quoted_pattern = 1 }
    }
    1;
};
print !$@ && $double_quoted_pattern_ok && $double_quoted_pattern
    ? "ok 152 - double-quoted constant patterns process case escapes\n"
    : "not ok 152 - double-quoted constant patterns process case escapes\n";

my $escaped_pattern_sigils;
my $escaped_pattern_sigils_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('$foo @bar') {
        on ("\\$foo \\@bar") { $escaped_pattern_sigils = 1 }
    }
    1;
};
print !$@ && $escaped_pattern_sigils_ok && $escaped_pattern_sigils
    ? "ok 153 - escaped sigils are literal in double-quoted patterns\n"
    : "not ok 153 - escaped sigils are literal in double-quoted patterns\n";

my @interpolated_pattern_vars = (
    q{on ("$foo")},
    q{on ("${foo}")},
    q{on ("@foo")},
    q{on ("@{foo}")},
);
my $interpolated_pattern_vars_rejected = 1;
for my $pattern (@interpolated_pattern_vars) {
    my $result = eval "use feature 'dispatch_on'; dispatch ('') { $pattern {} } 1";
    $interpolated_pattern_vars_rejected = 0
        unless $@ =~ /interpolated variables are not allowed in double-quoted dispatch patterns/;
}
print $interpolated_pattern_vars_rejected
    ? "ok 154 - scalar and array interpolation are forbidden in double quotes\n"
    : "not ok 154 - scalar and array interpolation are forbidden in double quotes\n";

my $interpolated_hash_element = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ({}) { on ({ "@{[ 'foo' ]}" => 1 }) {} }
    1;
};
print $@ =~ /interpolated variables are not allowed in double-quoted dispatch patterns/
    ? "ok 155 - expression interpolation is forbidden in double quotes\n"
    : "not ok 155 - expression interpolation is forbidden in double quotes\n";

my $ordinary_interpolation;
my $ordinary_interpolation_ok = eval q{
    my $foo = 'works';
    my $interpolated = "$foo";
    $ordinary_interpolation = $interpolated;
    1;
};
print !$@ && $ordinary_interpolation_ok && $ordinary_interpolation eq 'works'
    ? "ok 156 - ordinary double-quoted interpolation remains enabled\n"
    : "not ok 156 - ordinary double-quoted interpolation remains enabled\n";

my $concat_double_quoted_result;
my $concat_double_quoted_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('prefix value suffix') {
        on ("prefix " . $concat_double_quoted . " suffix") {
            $concat_double_quoted_result = $concat_double_quoted;
        }
    }
    1;
};
print !$@ && $concat_double_quoted_ok
        && $concat_double_quoted_result eq 'value'
    ? "ok 157 - constant double quotes compose with captures\n"
    : "not ok 157 - constant double quotes compose with captures\n";

my $subclass_object_pattern;
my $subclass_object_pattern_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    {
        package PatternParent;
        package PatternChild;
        our @ISA = ('PatternParent');
    }
    my $object = bless { value => 42 }, 'PatternChild';
    dispatch ($object) {
        on (PatternParent { value => 42 }) {
            $subclass_object_pattern = 1;
        }
    }
    1;
};
print !$@ && $subclass_object_pattern_ok && $subclass_object_pattern
    ? "ok 158 - object patterns accept subclasses\n"
    : "not ok 158 - object patterns accept subclasses\n";

my $overridden_isa_pattern;
my $overridden_isa_pattern_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    {
        package CustomIsa;
        sub isa { $_[1] eq 'VirtualParent' }
    }
    my $object = bless { value => 42 }, 'CustomIsa';
    dispatch ($object) {
        on (VirtualParent { value => 42 }) {
            $overridden_isa_pattern = 1;
        }
    }
    1;
};
print !$@ && $overridden_isa_pattern_ok && $overridden_isa_pattern
    ? "ok 159 - object patterns use the object's isa method\n"
    : "not ok 159 - object patterns use the object's isa method\n";

my $assigned_pattern_capture;
my $assigned_pattern_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $subject = [ 'foo', [ 'inner' ] ];
    dispatch ($subject) {
        on ([ "foo", $x = [ "inner" ] ]) {
            $assigned_pattern_capture = $x;
        }
    }
    1;
};
print !$@ && $assigned_pattern_ok
        && ref($assigned_pattern_capture) eq 'ARRAY'
        && $assigned_pattern_capture->[0] eq 'inner'
    ? "ok 160 - assignment captures a nested pattern value\n"
    : "not ok 160 - assignment captures a nested pattern value\n";

my $failed_assigned_pattern_clause = 0;
my $failed_assigned_pattern_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ([ 'foo', [ 'inner' ] ]) {
        on ([ 'foo', $captured = [ 'other' ] ]) {
            $failed_assigned_pattern_clause = 1;
        }
        on (_) { 1 }
    }
    1;
};
print !$@ && $failed_assigned_pattern_ok && !$failed_assigned_pattern_clause
    ? "ok 161 - failed assignment patterns do not enter their clause\n"
    : "not ok 161 - failed assignment patterns do not enter their clause\n";

my ($numeric_literal_hit, $string_literal_hit, $string_number_hit);
my $literal_comparisons = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('01') { on (1) { $numeric_literal_hit = 1 } }
    dispatch ('01') { on ('1') { $string_literal_hit = 1 } }
    dispatch (1)   { on ('1') { $string_number_hit = 1 } }
    1;
};
print !$@ && $literal_comparisons && $numeric_literal_hit
    && !$string_literal_hit && $string_number_hit
    ? "ok 162 - constants select numeric or string equality\n"
    : "not ok 162 - constants select numeric or string equality\n";

my $forced_numeric_constant;
my $forced_numeric_constant_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('01.100') {
        on (0 + '1.1') { $forced_numeric_constant = 1 }
    }
    1;
};
print !$@ && $forced_numeric_constant_ok && $forced_numeric_constant
    ? "ok 163 - zero plus forces numeric constant matching\n"
    : "not ok 163 - zero plus forces numeric constant matching\n";

my ($numeric_pin_hit, $string_pin_hit, $dualvar_pin_hit, $dualvar_pin_miss);
my $flag_typed_pins = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    use Scalar::Util 'dualvar';
    my $numeric_pin = 1;
    my $string_pin = '01';
    my $dualvar_pin = dualvar(1, '01');
    dispatch ('01') { on (^$numeric_pin) { $numeric_pin_hit = 1 } }
    dispatch (1)    { on (^$string_pin) { $string_pin_hit = 1 } }
    dispatch (1)    { on (^$dualvar_pin) { $dualvar_pin_miss = 1 } }
    dispatch ('01') { on (^$dualvar_pin) { $dualvar_pin_hit = 1 } }
    1;
};
print !$@ && $flag_typed_pins && $numeric_pin_hit && !$string_pin_hit
    && !$dualvar_pin_miss && $dualvar_pin_hit
    ? "ok 164 - pins use numeric-only flags and default ambiguous values to strings\n"
    : "not ok 164 - pins use numeric-only flags and default ambiguous values to strings\n";

my ($forced_numeric_pin_hit, $forced_numeric_pin_miss);
my $forced_numeric_pin = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $wanted = '01';
    dispatch (1) { on (0 + ^$wanted) { $forced_numeric_pin_hit = 1 } }
    dispatch (2) { on (0 + ^$wanted) { $forced_numeric_pin_miss = 1 } }
    1;
};
print !$@ && $forced_numeric_pin && $forced_numeric_pin_hit
    && !$forced_numeric_pin_miss
    ? "ok 165 - zero plus forces numeric pin matching\n"
    : "not ok 165 - zero plus forces numeric pin matching\n";

my $numeric_coercion_near_miss = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $wanted = 1;
    dispatch (1) { on (1 + ^$wanted) { 1 } }
    1;
};
print $@ =~ /unsupported dispatch pattern expression/
    ? "ok 166 - numeric coercion rejects other arithmetic\n"
    : "not ok 166 - numeric coercion rejects other arithmetic\n";

my ($folded_concat_left, $folded_concat_right);
my $folded_concat = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('foo X aYabZ suffix') {
        on ('foo ' . $folded_left . 'a' . '' . 'b'
               . $folded_right . ' suffix') {
            ($folded_concat_left, $folded_concat_right) =
                ($folded_left, $folded_right);
        }
    }
    1;
};
print !$@ && $folded_concat && $folded_concat_left eq 'X aY'
    && $folded_concat_right eq 'Z'
    ? "ok 167 - adjacent literal fragments form one concat boundary\n"
    : "not ok 167 - adjacent literal fragments form one concat boundary\n";

my $empty_concat_boundary = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('foo X Y bar') {
        on ('foo ' . $left . '' . $right . ' bar') { 1 }
    }
    1;
};
print $@ =~ /captures must be separated by non-empty constant text/
    ? "ok 168 - empty constant runs do not separate concat captures\n"
    : "not ok 168 - empty constant runs do not separate concat captures\n";

my $string_pin_overload_hit;
my $string_pin_overload = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $wanted = DispatchOn::Stringified->new('target');
    dispatch (DispatchOn::Stringified->new('target')) {
        on ('' . ^$wanted) { $string_pin_overload_hit = 1 }
    }
    1;
};
print !$@ && $string_pin_overload && $string_pin_overload_hit
    ? "ok 169 - empty concat stringifies an overloaded reference pin\n"
    : "not ok 169 - empty concat stringifies an overloaded reference pin\n";

my $numeric_overload_hit;
my $numeric_pin_overload = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    {
        package DispatchOn::NumericEquality;
        use overload '==' => sub { $_[0]{value} == $_[1] }, fallback => 1;
        sub new { bless { value => $_[1] }, $_[0] }
    }
    my $wanted = 1;
    dispatch (DispatchOn::NumericEquality->new(1)) {
        on (0 + ^$wanted) { $numeric_overload_hit = 1 }
    }
    1;
};
print !$@ && $numeric_pin_overload && $numeric_overload_hit
    ? "ok 170 - numeric pin matching uses overloaded equality\n"
    : "not ok 170 - numeric pin matching uses overloaded equality\n";

my ($numeric_match_warning, $numeric_match_hit);
my $numeric_match_no_warning = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $wanted = 1;
    local $SIG{__WARN__} = sub { $numeric_match_warning .= $_[0] };
    dispatch ('not numeric') {
        on (1) { $numeric_match_hit = 1 }
    }
    dispatch ('still not numeric') {
        on (^$wanted) { $numeric_match_hit = 1 }
    }
    1;
};
print !$@ && $numeric_match_no_warning && !$numeric_match_hit
        && !defined($numeric_match_warning)
    ? "ok 171 - numeric matching does not warn on nonnumeric strings\n"
    : "not ok 171 - numeric matching does not warn on nonnumeric strings\n";

my ($anonymous_subject, $anonymous_restored, $named_kept_default) = (0, 0, 0);
my $subject_variables = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ('inner') {
        on ('inner') { $anonymous_subject = $_ eq 'inner' }
    }
    $anonymous_restored = $_ eq 'outside';
    dispatch my $named_subject ('named') {
        on ('named') { $named_kept_default = $_ eq 'outside' }
    }
    1;
};
print !$@ && $subject_variables && $anonymous_subject && $anonymous_restored
    ? "ok 172 - anonymous dispatch localizes its subject in the default scalar\n"
    : "not ok 172 - anonymous dispatch localizes its subject in the default scalar\n";
print !$@ && $subject_variables && $named_kept_default && $_ eq 'outside'
    ? "ok 173 - named dispatch leaves the default scalar unchanged\n"
    : "not ok 173 - named dispatch leaves the default scalar unchanged\n";

my $old_case_as = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch (1 as $old_subject) { on (1) { 1 } }
};
print $@ ? "ok 174 - old dispatch subject as syntax is rejected\n"
         : "not ok 174 - old dispatch subject as syntax is rejected\n";
my ($anonymous_redo_calls, $anonymous_redo_value) = (0, undef);
my $anonymous_redo = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $evaluations = 0;
    dispatch (++$evaluations) {
        on (1) {
            $anonymous_redo_calls++;
            $_ = 2;
            redo if $anonymous_redo_calls == 1;
        }
        on (2) { $anonymous_redo_value = $_ }
    }
    $evaluations == 1;
};
print !$@ && $anonymous_redo && $anonymous_redo_calls == 1
        && $anonymous_redo_value == 2 && $_ eq 'outside'
    ? "ok 175 - redo rematches the current anonymous subject once\n"
    : "not ok 175 - redo rematches the current anonymous subject once\n";
