#!./perl

# Opt-in regressions from the internals/design review.
# Run from the repository root with:
#   ./perl -Ilib planning/scripts/dispatch-on-review-open.pl
# The capture lifetime regression now passes; HV equality remains deferred.
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc(qw(. ../lib));
}

sub check_program {
    my ($name, $program, $expected) = @_;
    my $output = fresh_perl(
        'use strict; use warnings; use feature qw(dispatch_on say);'
            . $program,
        {},
    );
    my $status = $?;
    is($output, $expected, $name);
    is($status, 0, "$name: clean exit");
}

check_program('a pattern call cannot invalidate an earlier capture', q{
    my @values = (bless({}, 'Object'), 1);
    sub remove_first { shift @values; 1 }
    dispatch (\@values) {
        on ([RefVal($captured), remove_first()]) { say ref $captured }
    }
}, 'Object');

for my $mode (qw(none array-linear array-binary hv)) {
    local $ENV{PERL_CONST_DISPATCH_STRATEGY} = $mode;
    check_program("$mode: numeric equality across integer/float domains", q{
        for my $value (1.0, 1) {
            dispatch ($value) {
                on (1) { say 'one' }
                on (_) { say 'miss' }
            }
            dispatch ($value) {
                on (1.0) { say 'one' }
                on (_) { say 'miss' }
            }
        }
    }, "one\none\none\none");
}

done_testing();
