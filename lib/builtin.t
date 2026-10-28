#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use v5.36;
no warnings 'experimental::builtin';
use Config;

package FetchStoreCounter {
    sub TIESCALAR($class, @args) { bless \@args, $class }

    sub FETCH($self)    { $self->[0]->$*++ }
    sub STORE($self, $) { $self->[1]->$*++ }
}

# booleans
{
    use builtin qw( true false is_bool );

    ok(true, 'true is true');
    ok(!false, 'false is false');

    ok(is_bool(true), 'true is bool');
    ok(is_bool(false), 'false is bool');
    ok(!is_bool(undef), 'undef is not bool');
    ok(!is_bool(1), '1 is not bool');
    ok(!is_bool(""), 'empty is not bool');

    my $truevar  = (5 == 5);
    my $falsevar = (5 == 6);

    ok(is_bool($truevar), '$truevar is bool');
    ok(is_bool($falsevar), '$falsevar is bool');

    ok(is_bool(is_bool(true)), 'is_bool true is bool');
    ok(is_bool(is_bool(123)),  'is_bool false is bool');

    # Invokes magic

    tie my $tied, FetchStoreCounter => (\my $fetchcount, \my $storecount);

    my $_dummy = is_bool($tied);
    is($fetchcount, 1, 'is_bool() invokes FETCH magic');

    $tied = is_bool(false);
    is($storecount, 1, 'is_bool() invokes STORE magic');

    is(prototype(\&builtin::is_bool), '$', 'is_bool prototype');
}

# float constants
{
    use builtin qw( inf nan );

    if ($Config{d_double_has_inf}) {
        ok(inf, 'inf is true');
        ok(inf > 1E10, 'inf is bigger than 1E10');
        ok(inf == inf, 'inf is equal to inf');
        ok(inf == inf + 1, 'inf is equal to inf + 1');

        # Invoke the real XSUB
        my $inf = ( \&builtin::inf )->();
        ok($inf == $inf + 1, 'inf returned by real xsub');
    } else {
        is(eval { inf }, undef, 'inf throws');
        my $e = $@;
        like($e, qr/^builtin::inf not implemented at/, 'inf fails with correct error');
    }

    if ($Config{d_double_has_nan}) {
        ok(nan != nan, 'NaN is not equal to NaN');

        my $nan = ( \&builtin::nan )->();
        ok($nan != $nan, 'NaN returned by real xsub');
    } else {
        is(eval { nan }, undef, 'nan throws');
        my $e = $@;
        like($e, qr/^builtin::nan not implemented at/, 'nan fails with correct error');
    }
}

# weakrefs
{
    use builtin qw( is_weak weaken unweaken );

    my $arr = [];
    my $ref = $arr;

    ok(!is_weak($ref), 'ref is not weak initially');

    weaken($ref);
    ok(is_weak($ref), 'ref is weak after weaken()');

    unweaken($ref);
    ok(!is_weak($ref), 'ref is not weak after unweaken()');

    weaken($ref);
    undef $arr;
    is($ref, undef, 'ref is now undef after arr is cleared');

    is(prototype(\&builtin::weaken), '$', 'weaken prototype');
    is(prototype(\&builtin::unweaken), '$', 'unweaken prototype');
    is(prototype(\&builtin::is_weak), '$', 'is_weak prototype');
}

# reference queries
{
    use builtin qw( refaddr reftype blessed );

    my $arr = [];
    my $obj = bless [], "Object";

    is(refaddr($arr),        $arr+0, 'refaddr yields same as ref in numeric context');
    is(refaddr("not a ref"), undef,  'refaddr yields undef for non-reference');

    is(reftype($arr),        "ARRAY", 'reftype yields type string');
    is(reftype($obj),        "ARRAY", 'reftype yields basic container type for blessed object');
    is(reftype("not a ref"), undef,   'reftype yields undef for non-reference');

    # GH #24634: refaddr and reftype weren't invoking set magic
    # on TARG, and TARG could be some lvalue with magic.
    #
    # The test here:
    # - $1 implements read-only-ness in its magic so if set
    # magic is called it throws an exception.
    # - $result is my, so TARGMY optimization should apply
    # which makes the the assigned to variable the TARG of the OP,
    # and
    # - $result is an alias to $1 so $1's magic should be invoked
    # when it is assigned to, throwing an exception.
    #
    # Before the fix the assignments weren't throwing exceptions
    for my $result ($1) {
        my $y = 1; # no constant folding
        ok(!eval { $result = reftype($y); 1 },
           "magic called for TARGMY reftype");
        ok(!eval { $result = refaddr($y); 1 },
           "magic called for TARGMY refaddr");
    }

    is(blessed($arr), undef, 'blessed yields undef for non-object');
    is(blessed($obj), "Object", 'blessed yields package name for object');

    # blessed() as a boolean
    is(blessed($obj) ? "YES" : "NO", "YES", 'blessed in boolean context still works');

    # blessed() appears false as a boolean on package "0"
    is(blessed(bless [], "0") ? "YES" : "NO", "NO", 'blessed in boolean context handles "0" cornercase');

    is(prototype(\&builtin::blessed), '$', 'blessed prototype');
    is(prototype(\&builtin::refaddr), '$', 'refaddr prototype');
    is(prototype(\&builtin::reftype), '$', 'reftype prototype');
}

# created_as_...
{
    use builtin qw( created_as_string created_as_number );

    # some literal constants
    ok(!created_as_string(undef), 'undef created as !string');
    ok(!created_as_number(undef), 'undef created as !number');

    ok( created_as_string("abc"), 'abc created as string');
    ok(!created_as_number("abc"), 'abc created as number');

    ok(!created_as_string(123),   '123 created as !string');
    ok( created_as_number(123),   '123 created as !number');

    ok(!created_as_string(1.23),   '1.23 created as !string');
    ok( created_as_number(1.23),   '1.23 created as !number');

    ok(!created_as_string([]),    '[] created as !string');
    ok(!created_as_number([]),    '[] created as !number');

    ok(!created_as_string(builtin::true), 'true created as !string');
    ok(!created_as_number(builtin::true), 'true created as !number');

    ok(builtin::is_bool(created_as_string(0)), 'created_as_string returns bool');
    ok(builtin::is_bool(created_as_number(0)), 'created_as_number returns bool');

    # variables
    my $just_pv = "def";
    ok( created_as_string($just_pv), 'def created as string');
    ok(!created_as_number($just_pv), 'def created as number');

    my $just_iv = 456;
    ok(!created_as_string($just_iv), '456 created as string');
    ok( created_as_number($just_iv), '456 created as number');

    my $just_nv = 4.56;
    ok(!created_as_string($just_nv), '456 created as string');
    ok( created_as_number($just_nv), '456 created as number');

    # variables reused
    my $originally_pv = "1";
    my $pv_as_iv = $originally_pv + 0;
    ok( created_as_string($originally_pv), 'PV reused as IV created as string');
    ok(!created_as_number($originally_pv), 'PV reused as IV created as !number');
    ok(!created_as_string($pv_as_iv), 'New number from PV created as !string');
    ok( created_as_number($pv_as_iv), 'New number from PV created as number');

    my $originally_iv = 1;
    my $iv_as_pv = "$originally_iv";
    ok(!created_as_string($originally_iv), 'IV reused as PV created as !string');
    ok( created_as_number($originally_iv), 'IV reused as PV created as number');
    ok( created_as_string($iv_as_pv), 'New string from IV created as string');
    ok(!created_as_number($iv_as_pv), 'New string from IV created as !number');

    my $originally_nv = 1.1;
    my $nv_as_pv = "$originally_nv";
    ok(!created_as_string($originally_nv), 'NV reused as PV created as !string');
    ok( created_as_number($originally_nv), 'NV reused as PV created as number');
    ok( created_as_string($nv_as_pv), 'New string from NV created as string');
    ok(!created_as_number($nv_as_pv), 'New string from NV created as !number');

    # magic
    local $1;
    "hello" =~ m/(.*)/;
    ok(created_as_string($1), 'magic string');

    is(prototype(\&builtin::created_as_string), '$', 'created_as_string prototype');
    is(prototype(\&builtin::created_as_number), '$', 'created_as_number prototype');
}

# stringify
{
    use builtin qw( stringify );

    is(stringify("abc"), "abc", 'stringify a plain string');
    is(stringify(123),   "123", 'stringify a number');

    my $aref = [];
    is(stringify($aref), "$aref", 'stringify an array ref');

    use builtin qw( created_as_string );
    ok(!ref stringify($aref),               'stringified arrayref is not a ref');
    ok(created_as_string(stringify($aref)), 'stringified arrayref is created as string');

    package WithOverloadedStringify {
        use overload '""' => sub { return "STRING" };
    }

    is(stringify(bless [], "WithOverloadedStringify"), "STRING", 'stringify invokes "" overload');
}

# ceil, floor
{
    use builtin qw( ceil floor );

    cmp_ok(ceil(1.5), '==', 2, 'ceil(1.5) == 2');
    cmp_ok(floor(1.5), '==', 1, 'floor(1.5) == 1');

    # Invokes magic

    tie my $tied, FetchStoreCounter => (\my $fetchcount, \my $storecount);

    my $_dummy = ceil($tied);
    is($fetchcount, 1, 'ceil() invokes FETCH magic');

    $tied = ceil(1.1);
    is($storecount, 1, 'ceil() TARG invokes STORE magic');

    $fetchcount = $storecount = 0;
    tie $tied, FetchStoreCounter => (\$fetchcount, \$storecount);

    $_dummy = floor($tied);
    is($fetchcount, 1, 'floor() invokes FETCH magic');

    $tied = floor(1.1);
    is($storecount, 1, 'floor() TARG invokes STORE magic');

    is(prototype(\&builtin::ceil), '$', 'ceil prototype');
    is(prototype(\&builtin::floor), '$', 'floor prototype');
}

# imports are lexical; should not be visible here
{
    my $ok = eval 'true()'; my $e = $@;
    ok(!$ok, 'true() not visible outside of lexical scope');
    like($e, qr/^Undefined subroutine &main::true called at /, 'failure from true() not visible');
}

# lexical imports work fine in a variety of situations
{
    sub regularfunc {
        use builtin 'true';
        return true;
    }
    ok(regularfunc(), 'true in regular sub');

    my sub lexicalfunc {
        use builtin 'true';
        return true;
    }
    ok(lexicalfunc(), 'true in lexical sub');

    my $coderef = sub {
        use builtin 'true';
        return true;
    };
    ok($coderef->(), 'true in anon sub');

    sub recursefunc {
        use builtin 'true';
        return recursefunc() if @_;
        return true;
    }
    ok(recursefunc("rec"), 'true in self-recursive sub');

    my sub recurselexicalfunc {
        use builtin 'true';
        return __SUB__->() if @_;
        return true;
    }
    ok(recurselexicalfunc("rec"), 'true in self-recursive lexical sub');

    my $recursecoderef = sub {
        use builtin 'true';
        return __SUB__->() if @_;
        return true;
    };
    ok($recursecoderef->("rec"), 'true in self-recursive anon sub');
}

{
    use builtin qw( true false );

    my $val = true;
    cmp_ok($val, $_, !!1, "true is equivalent to !!1 by $_") for qw( eq == );
    cmp_ok($val, $_,  !0, "true is equivalent to  !0 by $_") for qw( eq == );

    $val = false;
    cmp_ok($val, $_, !!0, "false is equivalent to !!0 by $_") for qw( eq == );
    cmp_ok($val, $_,  !1, "false is equivalent to  !1 by $_") for qw( eq == );
}

# indexed
{
    use builtin qw( indexed );

    # We don't have Test::More's is_deeply here

    ok(eq_array([indexed], [] ),
        'indexed on empty list');

    ok(eq_array([indexed "A"], [0, "A"] ),
        'indexed on singleton list');

    ok(eq_array([indexed "X" .. "Z"], [0, "X", 1, "Y", 2, "Z"] ),
        'indexed on 3-item list');

    my @orig = (1..3);
    $_++ for indexed @orig;
    ok(eq_array(\@orig, [1 .. 3]), 'indexed copies values, does not alias');

    {
        my $ok = 1;
        foreach my ($len, $s) (indexed "", "x", "xx") {
            length($s) == $len or undef $ok;
        }
        ok($ok, 'indexed operates nicely with multivar foreach');
    }

    {
        my %hash = indexed "a" .. "e";
        ok(eq_hash(\%hash, { 0 => "a", 1 => "b", 2 => "c", 3 => "d", 4 => "e" }),
            'indexed can be used to create hashes');
    }

    {
        no warnings 'scalar';

        my $count = indexed 'i', 'ii', 'iii', 'iv';
        is($count, 8, 'indexed in scalar context yields size of list it would return');
    }

    is(prototype(\&builtin::indexed), '@', 'indexed prototype');
}

# indexed + foreach loop optimisation appears transparent
{
    my @output;
    my @input = qw( zero one two three four five );

    foreach my ( $idx, $val ) ( builtin::indexed @input ) {
        push @output, "[$idx]=$val";
    }

    ok(eq_array(\@output, [qw( [0]=zero [1]=one [2]=two [3]=three [4]=four [5]=five )] ),
        'foreach + builtin::indexed ARRAY' );

    undef @output;

    use builtin qw( indexed );

    foreach my ( $idx, $val ) ( indexed @input ) {
        push @output, "[$idx]=$val";
    }

    ok(eq_array(\@output, [qw( [0]=zero [1]=one [2]=two [3]=three [4]=four [5]=five )] ),
        'foreach + imported indexed ARRAY' );

    undef @output;

    foreach my ( $idx, $val ) ( builtin::indexed qw( six seven eight nine ) ) {
        push @output, "[$idx]=$val";
    }

    ok(eq_array(\@output, [qw( [0]=six [1]=seven [2]=eight [3]=nine )] ),
        'foreach + builtin::indexed LIST' );
}

# Vanilla trim tests
{
    use builtin qw( trim );

    is(trim("    Hello world!   ")      , "Hello world!"  , 'trim spaces');
    is(trim("\tHello world!\t")         , "Hello world!"  , 'trim tabs');
    is(trim("\n\n\nHello\nworld!\n")    , "Hello\nworld!" , 'trim \n');
    is(trim("\t\n\n\nHello world!\n \t"), "Hello world!"  , 'trim all three');
    is(trim("Perl")                     , "Perl"          , 'trim nothing');
    is(trim('')                         , ""              , 'trim empty string');

    is(prototype(\&builtin::trim), '$', 'trim prototype');
}

TODO: {
    my $warn = '';
    local $SIG{__WARN__} = sub { $warn .= join "", @_; };

    is(builtin::trim(undef), "", 'trim undef');
    like($warn    , qr/^Use of uninitialized value in subroutine entry at/,
         'trim undef triggers warning');
    local $main::TODO = "Currently uses generic value for the name of non-opcode builtins";
    like($warn    , qr/^Use of uninitialized value in trim at/,
         'trim undef triggers warning using actual name of builtin');
}

# Fancier trim tests against a regexp and unicode
{
    use builtin qw( trim );
    my $nbsp = chr utf8::unicode_to_native(0xA0);

    is(trim("   \N{U+2603}       "), "\N{U+2603}", 'trim with unicode content');
    is(trim("\N{U+2029}foobar\x{2028} "), "foobar",
            'trim with unicode whitespace');
    is(trim("$nbsp foobar$nbsp    "), "foobar", 'trim with latin1 whitespace');
}

# Test on a magical fetching variable
{
    use builtin qw( trim );

    my $str3 = "   Hello world!\t";
    $str3 =~ m/(.+Hello)/;
    is(trim($1), "Hello", "trim on a magical variable");
}

# Inplace edit, my, our variables
{
    use builtin qw( trim );

    my $str4 = "\t\tHello world!\n\n";
    $str4 = trim($str4);
    is($str4, "Hello world!", "trim on an inplace variable");

    our $str2 = "\t\nHello world!\t  ";
    is(trim($str2), "Hello world!", "trim on an our \$var");
}

# Lexical export
{
    my $name;
    BEGIN {
        use builtin qw( export_lexically );

        $name = "message";
        export_lexically $name => sub { "Hello, world" };
    }

    is(message(), "Hello, world", 'Lexically exported sub is callable');
    ok(!__PACKAGE__->can("message"), 'Exported sub is not visible via ->can');

    is($name, "message", '$name argument was not modified by export_lexically');

    our ( $scalar, @array, %hash );
    BEGIN {
        use builtin qw( export_lexically );

        export_lexically
            '$SCALAR' => \$scalar,
            '@ARRAY'  => \@array,
            '%HASH'   => \%hash;
    }

    $::scalar = "value";
    is($SCALAR, "value", 'Lexically exported scalar is accessible');

    @::array = ('a' .. 'e');
    is(scalar @ARRAY, 5, 'Lexically exported array is accessible');

    %::hash = (key => "val");
    is($HASH{key}, "val", 'Lexically exported hash is accessible');
}

# load_module
{
    use builtin qw( load_module );
    use feature qw( try );
    my ($ok, $e);

    # Can't really test this sans string eval, as it's a compilation error:
    eval 'load_module();';
    $e = $@;
    ok($e, 'load_module(); fails');
    like($e, qr/^Not enough arguments for builtin::load_module at/, 'load_module(); fails with correct error');
    eval 'load_module;';
    $e = $@;
    ok($e, 'load_module; fails');
    like($e, qr/^Not enough arguments for builtin::load_module at/, 'load_module; fails with correct error');

    # Failure to load module croaks
    try {
        load_module(undef);
    } catch ($e) {
        ok($e, 'load_module(undef) fails');
        like($e, qr/^Usage: builtin::load_module\(defined string\)/, 'load_module(undef) fails with correct error');
    };
    try {
        load_module(\"Foo");
    } catch ($e) {
        ok($e, 'load_module(\"Foo") fails');
        like($e, qr/^Usage: builtin::load_module\(defined string\)/, 'load_module(\"Foo") fails with correct error');
    };
    try {
        load_module(["Foo"]);
    } catch ($e) {
        ok($e, 'load_module(["Foo"]) fails');
        like($e, qr/^Usage: builtin::load_module\(defined string\)/, 'load_module(["Foo"]) fails with correct error');
    };
    try {
        load_module('5.36');
    }
    catch ($e) {
        ok($e, 'load_module("5.36") fails');
        like($e, qr/^Can't locate 5[.]36[.]pm in \@INC/, 'load_module("5.36") fails with correct error');
    };
    try {
        load_module('v5.36');
    }
    catch ($e) {
        ok($e, 'load_module("v5.36") fails');
        like($e, qr/^Can't locate v5[.]36[.]pm in \@INC/, 'load_module("v5.36") fails with correct error');
    };
    try {
        load_module("Dies");
        fail('load_module("Dies") succeeded!');
    }
    catch ($e) {
        ok($e, 'load_module("Dies") fails');
        like($e, qr/^Can't locate Dies[.]pm in \@INC/, 'load_module("Dies") fails with correct error');
    }
    my $module_name = 'Dies';
    try {
        load_module($module_name);
        fail('load_module($module_name) $module_name=Dies succeeded!');
    }
    catch ($e) {
        ok($e, 'load_module($module_name) $module_name=Dies fails');
        like($e, qr/^Can't locate Dies[.]pm in \@INC/, 'load_module($module_name) $module_name=Dies fails with correct error');
    }
    $module_name =~ m!(\w+)!;
    try {
        load_module($1);
        fail('load_module($1) from $module_name=Dies succeeded!');
    }
    catch ($e) {
        ok($e, 'load_module($1) from $module_name=Dies fails');
        like($e, qr/^Can't locate Dies[.]pm in \@INC/, 'load_module($1) from $module_name=Dies fails with correct error');
    }
    "Dies" =~ m!(\w+)!;
    try {
        load_module($1);
        fail('load_module($1) from "Dies" succeeded!');
    }
    catch ($e) {
        ok($e, 'load_module($1) from "Dies" fails');
        like($e, qr/^Can't locate Dies[.]pm in \@INC/, 'load_module($1) from "Dies" fails with correct error');
    }

    # Loading module goes well
    my $ret;
    try {
        $ret = load_module("strict");
        pass('load_module("strict") worked');
        is($ret, "strict", 'load_module("strict") returned "strict"');
    }
    catch ($e) {
        fail('load_module("strict") errored: ' . $e);
    }
    $module_name = 'strict';
    try {
        $ret = load_module($module_name);
        pass('load_module($module_name) $module_name=strict worked');
        is($ret, "strict", 'load_module($module_name) returned "strict"');
    }
    catch ($e) {
        fail('load_module($module_name) $module_name=strict errored: ' . $e);
    }
    $module_name =~ m!(\w+)!;
    try {
        $ret = load_module($1);
        pass('load_module($1) from $module_name=strict worked');
        is($ret, "strict", 'load_module($1) from $module_name=strict returned "strict"');
    }
    catch ($e) {
        fail('load_module($1) from $module_name=strict errored: ' . $e);
    }
    "strict" =~ m!(\w+)!;
    try {
        $ret = load_module($1);
        pass('load_module($1) from "strict" worked');
        is($ret, "strict", 'load_module($1) from "strict" returned "strict"');
    }
    catch ($e) {
        fail('load_module($1) from "strict" errored: ' . $e);
    }

    # Slightly more complex, based on tie
    {
        package BuiltinTestTie {
            sub TIESCALAR {
                bless $_[1], $_[0];
            }
            sub FETCH {
                ${$_[0]}
            }
        }
        my $x;
        tie my $y, BuiltinTestTie => \$x;
        $x = "strict";
        try {
            $ret = load_module($y);
            pass('load_module($y) from $y tied to $x=strict worked');
            is($ret, "strict", 'load_module($y) from $y tied to $x=strict worked and returned "strict"');
        }
        catch ($e) {
            fail('load_module($y) from $y tied to $x=strict failed: ' . $e);
        };
    }

    # Can be used to import a symbol to the current namespace, too:
    {
        my $aref = [];
        my $aref_stringified = "$aref";
        my $got = eval '
            BEGIN {
                load_module("builtin")->import("stringify");
            }
            stringify($aref);
        ';
        if (my $error = $@) {
            fail('load_module("builtin")->import("stringify") failed: ' . $error);
        }
        is($got, $aref_stringified, 'load_module("builtin")->import("stringify") works, stringifying $aref');
    }
}

# version bundles
{
    use builtin ':5.39';
    ok(true, 'true() is available from :5.39 bundle');

    # parse errors
    foreach my $bundle (qw( :x :5.x :5.36x :5.36.1000 :5.1000 :5.36.1.2 ),
                        ":  +5.+39", ":  +5.+40. -10", ": 5.40", ":5 .40", ":5.+40",
                        ":5.40 .0", ":5.40.-10", ":5.40\0") {
        (my $pretty_bundle = $bundle) =~ s/([^[:print:]])/ sprintf("\\%o", ord $1) /ge;
        ok(!defined eval "use builtin '$bundle';", $pretty_bundle.' is invalid bundle');
        like($@, qr/^Invalid version bundle "\Q$pretty_bundle\E" at /);
    }
}

# github #21981
{
    fresh_perl_is(<<'EOS', "", {}, "github 21981: panic in intro_my");
use B;
BEGIN { B::save_BEGINs; }
use v5.39;
EOS
}

# github #22542
{
    # some of these functions don't error at this point, but they might be updated
    # and see the same problem we fix here
    for my $func (qw(is_bool is_weak blessed refaddr reftype ceil floor is_tainted
                     trim stringify created_as_string created_as_number)) {
        my $arg =
          $func =~ /ceil|floor|created_as/ ? "1.1" :
          $func =~ /(^ref|blessed|is_weak)/ ? "\\1" : '"abc"';
        fresh_perl_is(<<"EOS", "ok", {}, "goto $func");
no warnings "experimental";
sub f { goto &builtin::$func }
f($arg);
print "ok";
EOS
    }
}

# github #22784
{
    use builtin qw( trim );
    sub f { 0+trim($_[0]) }
    is(f(4), 4, "populate TARG.iv");
    is(f(123), 123, "check TARG.IOK is reset properly");
}

# github #24302
{
    use builtin qw( created_as_number );
    package HekifiedConstantKeys {
        sub TIEHASH {  bless {}, shift; }
        sub STORE {
            my ($hash, $key, $value) = @_;
            $hash->{$key} = ($key == 123 && created_as_number($key))
                             ? $value : undef;
        }
        sub CLEAR {}
        sub FETCH { return $_[0]{$_[1]} }
    }
    tie my %h, 'HekifiedConstantKeys';
    %h = (123 => 456);
    is($h{123}, 456, "Numerical OP_CONST SVs in hash init are created_as_number() when hekified");
}

# compiled diagnostic catalog lookup
{
    use XPerl::DiagPack qw(all);
    use builtin qw(get_diagnostic_data);

    my $by_code = get_diagnostic_data('ERROR_CALL_BINDING_TYPE_EXPRESSION_TYPE_MISMATCH');
    my $by_number = get_diagnostic_data(1417);
    is($by_code->{number}, 1417, 'diagnostic lookup accepts a code');
    is($by_number->{code}, 'ERROR_CALL_BINDING_TYPE_EXPRESSION_TYPE_MISMATCH', 'diagnostic lookup accepts a number');
    is($by_code->{severity}, 'FATAL_ERROR', 'diagnostic lookup returns severity');
    is($by_code->{kind}, 'CORE_COMPILE', 'diagnostic lookup returns kind');
    ok($by_code->{counts_as_error}, 'diagnostic lookup returns the error count flag');
    is($by_code->{selectors}[0]{name}, 'expected_kind',
       'diagnostic lookup returns selector definitions');
    is($by_code->{selectors}[0]{value_width}, 8,
       'diagnostic lookup reports the packed selector value width');
    is($by_code->{parameter_layout}{captured_parameter_count}, 7,
       'diagnostic lookup identifies captured parameter count');
    is($by_code->{parameter_layout}{stored_parameter_count}, 7,
       'diagnostic lookup identifies retained parameter count');
    my $selector_only = get_diagnostic_data('ERROR_TYPE_UNINITIALIZED_REFERENCE_VALUE_REQUIRED');
    is($selector_only->{parameter_layout}{captured_parameter_count}, 1,
       'selector-only diagnostic sources remain captured parameters');
    is($selector_only->{parameter_layout}{stored_parameter_count}, 1,
       'selector-only diagnostic sources remain stored parameters');
    is(join(',', @{$selector_only->{parameter_layout}{selector_only_parameters}}), 'kind',
       'diagnostic lookup names selector-only inputs');

    for my $case (
        [ 1183, 'ERROR_IO_LAYER_BYTE_OPERATION_ON_UTF8_HANDLE',               'arg1' ],
        [ 2128, 'WARNING_SYNTAX_CONTROL_TRANSFER_PRECEDENCE',              'arg1' ],
        [ 2223, 'WARNING_IO_DIRECTORY_OPERATION_ON_FILEHANDLE',    'arg1,arg2' ],
        [ 2224, 'WARNING_IO_DIRECTORY_OPERATION_ON_INVALID_HANDLE', 'arg1,arg2' ],
      )
    {
        my ( $number, $code, $expected_parameters ) = @$case;
        my $data = get_diagnostic_data($number);
        is( $data->{code}, $code,
            "$code catalog lookup keeps its diagnostic identity" );
        is( scalar @{ $data->{selectors} }, 0,
            "$code does not use a selector for literal operation names" );
        is( join( ',', map { $_->{name} } @{ $data->{parameters} } ),
            $expected_parameters,
            "$code keeps operation and handle values as parameters" );
    }

    my $french = $by_code->{translations}{fr};
    ok($french && @{$french->{cases}}, 'diagnostic lookup returns actual French cases');
    my ($array_case) = grep {
        my %criteria = map { $_->{selector} => $_->{value} }
          @{$_->{selector_criteria}};
        $criteria{expected_kind} eq 'array_ref'
    } @{$french->{cases}};
    ok($array_case, 'translation case retains its selector criteria');
    ok(utf8::is_utf8($array_case->{template}),
       'translated catalog templates are returned as UTF-8 strings');
    require JSON::PP;
    my $json = JSON::PP->new->utf8;
    is($json->decode($json->encode($array_case->{template})),
       $array_case->{template}, 'translated UTF-8 template survives a JSON round trip');

    my $plural = get_diagnostic_data(2217);
    is($plural->{selectors}[0]{plural_kind}, 'cardinal',
       'diagnostic lookup identifies the cardinal selector');
    my $has_exact_zero = grep { $_ eq '0' }
      @{$plural->{selectors}[0]{exact_numeric_values}};
    ok($has_exact_zero,
       'diagnostic lookup keeps exact zero distinct from plural categories');
    my $multiple = get_diagnostic_data('WARNING_UTF8_SEQUENCE_TOO_SHORT');
    is(scalar @{$multiple->{selectors}}, 2,
       'diagnostic lookup returns multiple ordered selectors');
    is(join(',', map { $_->{name} } @{$multiple->{selectors}}),
       'available_bytes,context',
       'UTF-8 diagnostic preserves plural and context independently of word identity');

    for my $case (
        [ 2165, 'Implicit use of @_ in %{arg1} with signatured subroutine is experimental' ],
        [ 2127, 'Possible precedence problem between ! and %{arg1}' ],
        [ 2146, '$[ used in %{arg1} (did you mean $] ?)' ],
      )
    {
        my ( $number, $template ) = @$case;
        my $data = get_diagnostic_data($number);
        is(
            join( ',', map { $_->{name} } @{ $data->{selectors} } ),
            $number == 2127 ? 'operator_conjunction' : '',
            "$number keeps only the language-owned grammar selector"
        );
        if ( $number == 2127 ) {
            is( join( ',', @{ $data->{selectors}[0]{values} } ),
                'a,ac', 'lookup exposes Welsh conjunction values rather than opcode names' );
            is( $data->{selectors}[0]{source},
                'arg1_operation', 'the grammar selector resolves from the retained operation identity' );
        }
        my $cases = $data->{translations}{en}{cases};
        is( scalar @$cases,        1,         "$number shares one English sentence across operations" );
        is( $cases->[0]{template}, $template, "$number preserves its parameterized English sentence" );
        is( join( ',', @{ $cases->[0]{template_parameters} } ), 'arg1', "$number displays its operation phrase" );
        ok(
            ( grep { $_ eq 'arg1_operation' } @{ $cases->[0]{retained_only_parameters} } ),
            "$number retains numeric identity separately from its phrase"
        );
        is( scalar @{ $data->{translations}{fr}{cases} }, 1, "$number shares the French sentence across operations" );
    }

    my $bizarre_copy = get_diagnostic_data('ERROR_INTERNAL_SCALAR_COPY_SOURCE_NOT_SCALAR_IN_OPERATION');
    is(scalar @{$bizarre_copy->{selectors}}, 0, 'copy operation identity does not consume a selector');
    is(scalar @{$bizarre_copy->{translations}{en}{cases}}, 1, 'copy wording uses shared operation words');
    is($bizarre_copy->{translations}{en}{cases}[0]{template}, 'Bizarre copy of %{arg2} in %{arg3}',
       'copy failure keeps its complete parameterized English sentence');

    for my $code (qw(ERROR_CALL_BINDING_ARITY_TOO_FEW_ARGUMENTS ERROR_CALL_BINDING_ARITY_TOO_MANY_ARGUMENTS)) {
        my $data = get_diagnostic_data($code);
        my $cases = $data->{translations}{en}{cases};
        is(scalar @$cases, 1, "$code shares one sentence with operation vocabulary");
        is(scalar @{$data->{selectors}}, 0, "$code does not spend selector fields on word identity");
        is($cases->[0]{template},
           $code eq 'ERROR_CALL_BINDING_ARITY_TOO_FEW_ARGUMENTS'
             ? 'Not enough arguments for %{name}' : 'Too many arguments for %{name}',
           "$code preserves its parameterized English sentence");
        is(join(',', @{$cases->[0]{template_parameters}}), 'name',
           "$code renders its displayed callee parameter");
        ok((grep { $_ eq 'name_operation' } @{$cases->[0]{retained_only_parameters}}),
           "$code retains numeric identity independently of displayed text");
    }

    my $wide_locale = get_diagnostic_data('WARNING_LOCALE_WIDE_CHARACTER_UNDER_BYTE_CTYPE');
    is(scalar @{$wide_locale->{selectors}}, 0, 'wide locale word identity is independent of selectors');
    is(scalar @{$wide_locale->{translations}{en}{cases}}, 1, 'wide locale warning has one shared sentence');
    is($wide_locale->{translations}{en}{cases}[0]{template},
       'Wide character (U+%{arg1}) in %{arg2} under a non-UTF-8 locale',
       'wide locale warning keeps its complete parameterized English sentence');

    for my $case (
        [ 'WARNING_UTF8_SURROGATE_CASE_MAPPING_RETURNS_SURROGATE_UNCHANGED',
          'Operation "%{arg1}" returns its argument for UTF-16 surrogate U+%{arg2}' ],
        [ 'WARNING_UTF8_NON_UNICODE_CASE_MAPPING_RETURNS_SUPER_UNCHANGED',
          'Operation "%{arg1}" returns its argument for non-Unicode code point 0x%{arg2}' ],
    ) {
        my ($code, $template) = @$case;
        my $data = get_diagnostic_data($code);
        is(scalar @{$data->{selectors}}, 0, "$code keeps word identity outside selectors");
        is(scalar @{$data->{translations}{en}{cases}}, 1, "$code uses one shared sentence");
        is($data->{translations}{en}{cases}[0]{template}, $template,
           "$code preserves its parameterized English sentence");
    }

    my $malformed = get_diagnostic_data('WARNING_UTF8_TRUNCATED_SEQUENCE_IN_OPERATION');
    is(scalar @{$malformed->{selectors}}, 0, 'truncated UTF-8 warning does not spend a selector on words');
    is(scalar @{$malformed->{translations}{en}{cases}}, 1, 'truncated UTF-8 warning has one sentence');
    is($malformed->{translations}{en}{cases}[0]{template},
       'Malformed UTF-8 character (unexpected end of string) in %{operation}',
       'truncated UTF-8 warning retains its parameterized English sentence');

    my $wide_character = get_diagnostic_data('ERROR_UNICODE_WIDE_CHARACTER_BYTE_CONVERSION_FAILED_IN_OPERATION');
    is(scalar @{$wide_character->{selectors}}, 0, 'wide-character word identity does not consume a selector');
    is(scalar @{$wide_character->{translations}{en}{cases}}, 1, 'wide-character fatal uses one shared sentence');
    is($wide_character->{translations}{en}{cases}[0]{template}, 'Wide character in %{arg1}',
       'wide-character fatal preserves its parameterized English sentence');

    my $non_continuation = get_diagnostic_data('WARNING_UTF8_TWO_BYTE_SEQUENCE_CONTINUATION_INVALID');
    is(join(',', map { $_->{name} } @{$non_continuation->{selectors}}), 'context',
       'non-continuation warning retains context independently of word identity');
    is(scalar @{$non_continuation->{translations}{en}{cases}}, 2,
       'non-continuation warning has only the two meaningful context cases');
    ok((grep { $_->{template} =~ /%\{operation\}/ } @{$non_continuation->{translations}{en}{cases}}),
       'non-continuation context sentence uses the displayed word parameter');

    my @void_semantic_values = qw(
      anonymous_array anonymous_hash constant constant_undef literal
      negative_pattern_binding non_destructive_substitution
      non_destructive_transliteration variable
    );
    for my $code (qw(WARNING_VOID_USELESS_EXPRESSION_PV WARNING_VOID_USELESS_EXPRESSION_SV)) {
        my $data = get_diagnostic_data($code);
        my $values = $data->{selectors}[0]{values};
        is(scalar @$values, 10, "$code retains semantic selectors and the explicit time override");
        my %value = map { $_ => 1 } @$values;
        ok($value{$_}, "$code retains semantic selector $_") for @void_semantic_values;
        ok($value{time}, "$code permits the existing French time override");
        ok(!$value{add}, "$code uses numeric word identity for addition");
        my $english = $data->{translations}{en}{cases};
        is(scalar @$english, 9, "$code has semantic cases and one word-based fallback");
        my ($fallback) = grep { $_->{selector_criteria}[0]{value} eq '*' } @$english;
        is($fallback->{template}, 'Useless use of %{arg1} in void context',
           "$code preserves the English fallback sentence");
        my %french = map { $_->{selector_criteria}[0]{value} => $_->{template} }
          @{$data->{translations}{fr}{cases}};
        ok(!exists $french{add}, "$code French addition uses shared words");
        is($french{time}, 'Utilisation inutile de la fonction time en contexte void',
           "$code keeps the literal keyword override");
    }

    for my $case (
        [ 1576, 'param_count', 'constructor parameter count' ],
        [ 2367, 'bad_count', 'locale character count' ],
        [ 2483, 'error_count', 'role composition error count' ],
        [ 1548, 'error_count', 'compilation error count' ],
    ) {
        my ( $number, $name, $description ) = @$case;
        my $data = get_diagnostic_data($number);
        ok( ( grep { $_->{name} eq $name } @{ $data->{parameters} } ),
            "diagnostic lookup exposes $description" );
    }

    my $zero_parameters = get_diagnostic_data(1055);
    is(scalar @{$zero_parameters->{parameters}}, 0,
       'diagnostic lookup handles zero-parameter diagnostics');
    is(scalar @{$zero_parameters->{translations}{en}{cases}[0]{template_parameters}}, 0,
       'zero-parameter cases have an empty template parameter list');

    my $strict_subs = get_diagnostic_data('ERROR_STRICT_SUBS_BAREWORD_FORBIDDEN');
    is($strict_subs->{class}, 'XPerl::Diagnostic::Error::Strict::Subs',
       'catalog lookup exposes the reviewed strict-subs class');
    my $global_symbol = get_diagnostic_data(
        'ERROR_STRICT_VARS_GLOBAL_SYMBOL_REQUIRES_EXPLICIT_PACKAGE_NAME');
    is($global_symbol->{class}, 'XPerl::Diagnostic::Error::Strict::Vars',
       'catalog lookup exposes the reviewed strict-vars class');
    ok(!$strict_subs->{leaf_only},
       'catalog lookup exposes container capability');
    for my $case (
        [ 2177, 'Severe::Debugging', 'WARN_DEBUGGING' ],
        [ 2178, 'Severe::Debugging', 'WARN_DEBUGGING' ],
        [ 2133, 'Misc',              'WARN_MISC' ],
        [ 2185, 'Misc',              'WARN_MISC' ],
        [ 2189, 'Misc',              'WARN_MISC' ],
        [ 2190, 'Overflow',          'WARN_OVERFLOW' ],
        [ 2218, 'Misc',              'WARN_MISC' ],
        [ 2241, 'Misc',              'WARN_MISC' ],
        [ 2242, 'Misc',              'WARN_MISC' ],
    ) {
        my ($number, $category_class, $category) = @$case;
        my $data = get_diagnostic_data($number);
        is($data->{class}, "XPerl::Diagnostic::Warning::$category_class",
           "diagnostic $number follows its warning control group");
        is($data->{category_policy}, "fixed: $category",
           "diagnostic $number retains its warning control policy");
    }

    my $location_formatter = get_diagnostic_data(2631);
    is($location_formatter->{code}, 'NOTE_CONTEXT_LOCATION',
       'source and parser locations share the retained formatter number');
    is(join(',', map { $_->{name} } @{$location_formatter->{selectors}}),
       'context,style', 'location style and parser context are independent selectors');
    is(get_diagnostic_data(2635), undef,
       'the absorbed parser-location formatter number remains reserved');

    my $omission = get_diagnostic_data('NOTE_OMISSION_NAMED_PARAMETER_DIAGNOSTICS');
    is($omission->{class}, 'XPerl::Diagnostic::Note::Omission',
       'catalog lookup matches the named-parameter omission class');
    ok($omission->{leaf_only},
       'named-parameter omission records remain leaves');

    my $dynamic_warning = get_diagnostic_data('WARNING_IO_OPERATION_ON_CLOSED_OR_UNOPENED_HANDLE');
    ok($dynamic_warning->{dynamic_category},
       'catalog lookup distinguishes runtime warning categories');
    like($dynamic_warning->{category_policy}, qr/runtime category.*LCA/,
         'catalog lookup describes runtime warning LCA classification');

    my $composed = get_diagnostic_data(2232);
    my ($property) = grep { $_->{name} eq 'property' } @{ $composed->{parameters} };
    is(
        join( ',', map { $_->{name} } @{ $property->{inputs} } ),
        'property_length,property_text',
        'diagnostic lookup distinguishes semantic parameters from raw C inputs'
    );
    is(
        join( ',', map { "$_->{name}:$_->{type}" } @{ $property->{inputs} } ),
        'property_length:iv,property_text:text',
        'diagnostic lookup preserves compound raw-input names and types'
    );

    my $escaped_percent = get_diagnostic_data(1242);
    like($escaped_percent->{translations}{fr}{cases}[0]{template}, qr/%%/,
         'named template reconstruction preserves escaped percent signs');

    is(get_diagnostic_data(0), undef, 'catalog number zero is not an entry');
    is(get_diagnostic_data('not_a_diagnostic'), undef,
       'unknown diagnostic codes return undef');
    is(get_diagnostic_data('-1'), undef, 'negative numeric strings are malformed');
    is(get_diagnostic_data(1.5), undef, 'fractional numeric inputs are malformed');
    is(get_diagnostic_data([]), undef, 'reference identifiers return undef');

    my $independent = get_diagnostic_data(1417);
    $by_code->{parameters}[0]{name} = 'caller mutation';
    is($independent->{parameters}[0]{name}, 'number',
       'each lookup returns fresh nested metadata');

    package DiagnosticCatalogMagic {
        sub TIESCALAR { bless { value => $_[1], fetches => 0 }, $_[0] }
        sub FETCH { $_[0]{fetches}++; $_[0]{value} }
        sub STORE { die 'diagnostic lookup must not store its argument' }
    }
    tie my $identifier, 'DiagnosticCatalogMagic', '1417';
    my $magical = get_diagnostic_data($identifier);
    is($magical->{code}, 'ERROR_CALL_BINDING_TYPE_EXPRESSION_TYPE_MISMATCH', 'magical identifiers are supported');
    is(tied($identifier)->{fetches}, 1, 'magical identifier is fetched once');

    my ($exception_calls, $warning_calls) = (0, 0);
    {
        local $SIG{__EXCEPT__} = sub { $exception_calls++ };
        local $SIG{__WARN__} = sub { $warning_calls++ };
        get_diagnostic_data('ERROR_CALL_BINDING_TYPE_EXPRESSION_TYPE_MISMATCH');
    }
    is($exception_calls, 0, 'catalog lookup does not emit a diagnostic');
    is($warning_calls, 0, 'catalog lookup does not invoke warning hooks');
    is(prototype(\&builtin::get_diagnostic_data), '$',
       'catalog lookup has a unary builtin prototype');
}

# vim: tabstop=4 shiftwidth=4 expandtab autoindent softtabstop=4

done_testing();
