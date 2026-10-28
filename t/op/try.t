#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    require Config;
}

use strict;
use warnings;
use feature 'try';
require overload;

{
    my $x;
    try {
        $x .= "try";
    }
    catch ($e) {
        $x .= "catch";
    }
    is($x, "try", 'successful try/catch runs try but not catch');
}

{
    my $x;
    my $caught;
    try {
        $x .= "try";
        die "Oopsie\n";
    }
    catch ($e) {
        $x .= "catch";
        $caught = $e;
        is($@, "", '$@ is empty within catch block');
    }
    is($x, "trycatch", 'die in try runs catch block');
    is($caught, "Oopsie\n", 'catch block saw exception value');
}

{
    my ( $caught_value, $caught_exception );
    try { die "structured failure\n" }
    catch ( $value, $exception ) {
        $caught_value= $value;
        $caught_exception= $exception;
    }
    is( ref($caught_value), 'XPerl::Exception',
        'two-value catch exposes the structured scalar exception' );
    is( ref($caught_exception), 'XPerl::Exception',
        'two-value catch exposes the canonical exception' );
    is( overload::StrVal($caught_value), overload::StrVal($caught_exception),
        'the scalar compatibility value is the canonical exception' );
}

{
    my $thrown= bless {}, 'TryCatch::Error';
    my ( $caught_value, $caught_exception );
    try { die $thrown }
    catch ( $value, $exception ) {
        $caught_value= $value;
        $caught_exception= $exception;
    }
    ok( $caught_value == $thrown,
        'two-value catch preserves a thrown reference identity' );
    is( ref($caught_value), 'TryCatch::Error',
        'two-value catch preserves a thrown reference class' );
    is( ref($caught_exception), 'XPerl::Exception',
        'two-value catch exposes the structured reference exception' );
}

{
    eval { die "saved before nested catches\n" };
    my $saved_error= $@;
    my $saved_exception= ${^ERROR_OBJ};
    my $outer_reference= bless {}, 'TryCatch::OuterError';
    my $inner_reference= [];

    try { die $outer_reference }
    catch ( $outer_value, $outer_exception ) {
        ok( $outer_value == $outer_reference,
            'outer catch keeps the reference compatibility value' );
        is( $outer_exception->contents->[0]->code,
            'ERROR_USER_REFERENCE',
            'outer catch exposes its canonical structured exception' );
        ok( !defined ${^ERROR_OBJ},
            'catch localizes the canonical error object' );

        try { die $inner_reference }
        catch ( $inner_value, $inner_exception ) {
            ok( $inner_value == $inner_reference,
                'nested catch keeps its reference compatibility value' );
            is( ref($inner_exception), 'XPerl::Exception',
                'nested catch exposes its canonical structured exception' );
        }

        is( $@, '', 'nested catch restores the enclosing catch value' );
        ok( !defined ${^ERROR_OBJ},
            'nested catch restores the enclosing canonical error state' );
    }

    is( overload::StrVal($@), overload::StrVal($saved_error),
        'nested catches restore the error value from before the outer catch' );
    ok( overload::StrVal(${^ERROR_OBJ})
        eq overload::StrVal($saved_exception),
        'nested catches restore the canonical object from before the outer catch'
    );
}

# return inside try {} makes containing function return
{
    sub f
    {
        try {
            return "return inside try";
        }
        catch ($e) { }
        return "return from func";
    }
    is(f(), "return inside try", 'return inside try');
}

# wantarray inside try
{
    my $context;
    sub whatcontext
    {
        try {
            $context = wantarray ? "list" :
                defined wantarray ? "scalar" : "void";
        }
        catch ($e) { }
    }

    whatcontext();
    is($context, "void", 'sub {try} in void');

    my $scalar = whatcontext();
    is($context, "scalar", 'sub {try} in scalar');

    my @array = whatcontext();
    is($context, "list", 'sub {try} in list');
}

# Loop controls inside try {} do not emit warnings
{
    my $warnings = "";
    local $SIG{__WARN__} = sub { $warnings .= $_[0] };

    {
        try {
            last;
        }
        catch ($e) { }
    }

    {
        try {
            next;
        }
        catch ($e) { }
    }

    my $count = 0;
    {
        try {
            $count++;
            redo if $count < 2;
        }
        catch ($e) { }
    }

    is($warnings, "", 'No warnings emitted by next/last/redo inside try');

    $warnings = "";

    LOOP_L: {
        try {
            last LOOP_L;
        }
        catch ($e) { }
    }

    LOOP_N: {
        try {
            next LOOP_N;
        }
        catch ($e) { }
    }

    $count = 0;
    LOOP_R: {
        try {
            $count++;
            redo LOOP_R if $count < 2;
        }
        catch ($e) { }
    }

    is($warnings, "", 'No warnings emitted by next/last/redo LABEL inside try');
}

# try/catch should localise $@
{
    eval { die "Value before\n"; };

    try { die "Localized value\n" } catch ($e) {}

    is($@, "Value before\n", 'try/catch localized $@');
}

# try/catch is not confused by false values
{
    my $caught;
    try {
        die 0;
    }
    catch ($e) {
        $caught++;
    }

    ok( $caught, 'catch{} sees a false exception' );
}

# try/catch is not confused by always-false objects
{
    my $caught;
    try {
        die FALSE->new;
    }
    catch ($e) {
        $caught++;
    }

    ok( $caught, 'catch{} sees a false-overload exception object' );

    {
        package FALSE;
        use overload 'bool' => sub { 0 };
        sub new { bless [], shift }
    }
}

# return from try is correct even for :lvalue subs
#   https://github.com/Perl/perl5/issues/18553
{
    my $scalar;
    sub fscalar :lvalue
    {
        try { return $scalar }
        catch ($e) { }
    }

    fscalar = 123;
    is($scalar, 123, 'try { return } in :lvalue sub in scalar context' );

    my @array;
    sub flist :lvalue
    {
        try { return @array }
        catch ($e) { }
    }

    (flist) = (4, 5, 6);
    ok(eq_array(\@array, [4, 5, 6]), 'try { return } in :lvalue sub in list context' );
}

# try as final expression yields correct value
{
    my $scalar = do {
        try { 123 }
        catch ($e) { 456 }
    };
    is($scalar, 123, 'do { try } in scalar context');

    my @list = do {
        try { 1, 2, 3 }
        catch ($e) { 4, 5, 6 }
    };
    ok(eq_array(\@list, [1, 2, 3]), 'do { try } in list context');

    # Regression test related to
    #   https://github.com/Perl/perl5/issues/18855
    $scalar = do {
        try { my $x = 123; 456 }
        catch ($e) { 789 }
    };
    is($scalar, 456, 'do { try } with multiple statements');
}

# catch as final expression yields correct value
{
    my $scalar = do {
        try { die "Oops" }
        catch ($e) { 456 }
    };
    is($scalar, 456, 'do { try/catch } in scalar context');

    my @list = do {
        try { die "Oops" }
        catch ($e) { 4, 5, 6 }
    };
    ok(eq_array(\@list, [4, 5, 6]), 'do { try/catch } in list context');

    # Regression test 
    #   https://github.com/Perl/perl5/issues/18855
    $scalar = do {
        try { die "Oops" }
        catch ($e) { my $x = 123; "result" }
    };
    is($scalar, "result", 'do { try/catch } with multiple statements');
}

my $program = $0;
$program =~ s/\.dp$//; # running under 'cd t; ./TEST -deparse'

# try{} blocks should be invisible to caller()
{
    my $caller;
    sub A { $caller = sprintf "%s (%s line %d)", (caller 1)[3,1,2]; }

    sub B {
        try { A(); }
        catch ($e) {}
    }

    my $LINE = __LINE__+1;
    B();

    is($caller, "main::B ($program line $LINE)", 'try {} block is invisible to caller()');
}

# try/catch/finally

# experimental warnings
{
    my $warnings;
    BEGIN { $SIG{__WARN__} = sub { $warnings .= shift; }; }

    my $lfinally = __LINE__; $lfinally += 7;
    try {
        1;  # empty line to make line numbers match when being deparsed
    }
    catch ($e) {
        1;  # empty line to make line numbers match when being deparsed
    }
    finally {
        1;  # empty line to make line numbers match when being deparsed
    }

    is($warnings, "try/catch/finally is experimental at $program line $lfinally.\n",
        'compiletime warnings');
    BEGIN { undef $SIG{__WARN__}; }
}

no warnings 'experimental::try';

{
    my $x;
    try {
        $x .= "try";
    }
    catch ($e) {
        $x .= "catch";
    }
    finally {
        $x .= "finally";
    }
    is($x, "tryfinally", 'successful try/catch/finally runs try+finally but not catch');
}

{
    my $x;
    try {
        $x .= "try";
        die "Oopsie\n";
    }
    catch ($e) {
        $x .= "catch";
    }
    finally {
        $x .= "finally";
    }
    is($x, "trycatchfinally", 'try/catch/finally runs try+catch+finally on failure');
}

{
    my $finally_invoked;
    sub ff
    {
        try {
            return "return inside try+finally";
        }
        catch ($e) {}
        finally { $finally_invoked++; "last value" }
        return "return from func";
    }
    is(ff(), "return inside try+finally", 'return inside try+finally');
    ok($finally_invoked, 'finally block still invoked for side-effects');
}

# Variant of GH#23604
{
    my $ok;
    try {
        # nothing
    }
    catch ($e) {}
    finally {
        try {
            die "Ignore this error\n"
        }
        catch ($e) {}

        $ok = "ok";
    }

    is($ok, "ok", 'try{die} inside try/finally does not stop runloop');
}

# Nicer compiletime errors
{
    my $e;

    $e = defined eval 'try { A() } catch { B() }; 1;' ? undef : $@;
    like($e, qr/^catch block requires a \(VAR\) at /,
        'Parse error for catch without (VAR)');
}

# Adapted from GH#19240 as per GH#24825
{
  our $gotostr;
  sub gotofoo {
    try { }
    catch ($e) { }
    finally {
      goto ham;
      $gotostr .= "peas\n";
      ham:
      $gotostr .= "ham\n";
    }
    $gotostr .= "uh oh\n";
  }

  gotofoo();
  is($gotostr, "ham\nuh oh\n", 'goto within finally block, with trailing code present');

  # With a twist: hopefully a +1 context level
  sub goto2foo {
    try {}
    catch ($e) { }
    finally {
      if ($gotostr) {
        $gotostr .= "pineapple\n";
        goto ham;
        $gotostr .= "peas\n";
      } else {
        ham:
        $gotostr .= "poppedecorn\n";
      }
    }
    $gotostr .= "spam\n";
  }

  goto2foo();
  is($gotostr, "ham\nuh oh\npineapple\npoppedecorn\nspam\n",
          'goto deep within finally block, with trailing code present');
}

done_testing;
