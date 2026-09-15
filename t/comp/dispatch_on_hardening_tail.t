#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc( qw(. ../lib) );
}

use dispatch::Predicates;

plan(44);

require Scalar::Util;

fresh_perl_is(q{
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    eval q{dispatch (['a', 'b']) {
        on ([/(?<x>a)/, /(?<x>b)/]) { say "$x,$+{x}" }
    }};
    die $@ if $@;
    say scalar @warnings;
    say $warnings[0] =~ /Named capture 'x'.*only the first regex.*later captures are not visible.*line / ? 'diagnostic' : 'bad warning';
}, "a,b\n1\ndiagnostic", {},
    'separate regexes warn once and publish only the first lexical binding');

fresh_perl_is(q{
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    eval q{dispatch ('two') {
        on (/(?<num>one)|(?<num>two)/) { say "$num,$+{num}" }
    }};
    die $@ if $@;
    say scalar @warnings;
}, "two,two\n0", {},
    'duplicate names within one regex use the first participating capture');

fresh_perl_is(q{
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    eval q{dispatch (['a', 'b']) {
        on ([/(?:a|(?<x>z))/, /(?<x>b)/]) {
            say defined($x) ? 'wrong' : "undef,$+{x}";
        }
    }};
    die $@ if $@;
    say scalar @warnings;
}, "undef,b\n1", {},
    'first regex binding remains undef when its named group does not participate');

fresh_perl_is(q{
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    local $SIG{__WARN__} = sub { die @_ };
    eval q{dispatch ('a') {
        on (/(?<x>a)/) { say $x }
        on (/(?<x>b)/) { say $x }
    }};
    die $@ if $@;
}, 'a', {}, 'capture-name collision tracking is local to each clause');

fresh_perl_is(q{
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    eval q{
        use warnings FATAL => 'syntax';
        dispatch (['a', 'b']) {
            on ([/(?<x>a)/, /(?<x>b)/]) { say 'wrong' }
        }
    };
    say $@ =~ /Named capture 'x'/ ? 'fatal warning' : 'wrong';
}, 'fatal warning', {}, 'cross-regex capture warning obeys lexical warning policy');

fresh_perl_is(q{
    use utf8;
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    eval q{dispatch (['a', 'b']) {
        on ([/(?<prénom>a)/, /(?<prénom>b)/]) { say $prénom }
    }};
    die $@ if $@;
    say @warnings == 1 && $warnings[0] =~ /Named capture 'prénom'/
        ? 'UTF-8 name' : 'wrong';
}, "a\nUTF-8 name", {}, 'cross-regex warning preserves UTF-8 capture names');

fresh_perl_is(q{
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    our $calls = 0;
    package Key {
        use overload '""' => sub { ++$main::calls; 'x' };
    }
    my $key = bless {}, 'Key';
    dispatch ({x=>1,y=>2}) {
        on ({^$key=>1}) { say 'wrong exactness' }
        on (_) { say "miss,$calls" }
    }
}, 'miss,1', {}, 'runtime hash keys are stringified once per key requirement');

fresh_perl_is(q{
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    my @closures;
    for my $throws (0, 1) {
        eval {
            dispatch ([42, 43]) {
                on ([$x, @tail] if do {
                    push @closures, sub { ($x, @tail) };
                    die "guard error\n" if $throws;
                    0;
                }) { die 'wrong clause' }
                on (_) { }
            }
        };
        die $@ if $@ && $@ ne "guard error\n";
    }
    say join ',', $_->() for @closures;
}, "42,43\n42,43", {},
    'guard rejection and exceptions preserve escaped lexical bindings');

fresh_perl_is(q{
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    for my $shape ('{a=>1,a=>1}', '{1=>1,"1"=>1}',
                   '[{a=>1,a=>1}]', 'Point {a=>1,a=>1}') {
        eval 'dispatch ({a=>1,b=>2}) { on (' . $shape . ') { 1 } }';
        say $@ =~ /duplicate key .* in a dispatch hash pattern/
            ? 'rejected' : 'wrong result';
    }
}, "rejected\nrejected\nrejected\nrejected", {},
    'statically duplicate keys are rejected in plain and object hash shapes');

fresh_perl_is(q{
    use strict;
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    my ($a, $b) = ('x', 'x');
    for my $subject ({x=>1,y=>1}, {x=>1}, {x=>2}) {
        dispatch ($subject) {
            on ({^$a=>1,^$b=>1}) { say 'hit' }
            on (_) { say 'miss' }
        }
    }
}, "miss\nhit\nmiss", {},
    'runtime key collisions preserve exactness without duplicate-key errors');

fresh_perl_is(q{
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    my $key = 'x';
    dispatch ({x=>1,y=>2}) {
        on ({x=>1,^$key=>2,...}) { say 'wrong value constraint' }
        on ({x=>1,^$key=>1}) { say 'wrong exactness' }
        on ({x=>1,^$key=>1,...}) { say 'open hit' }
    }
}, 'open hit', {},
    'colliding literal and caret-pinned keys retain all value constraints');

fresh_perl_is(q{
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    my $calls = 0;
    sub key { ++$calls; 'x' }
    dispatch ({x=>1,y=>2}) {
        on ({key()=>1,key()=>1}) { say 'wrong exactness' }
        on (_) { say "miss,$calls" }
    }
}, 'miss,2', {}, 'runtime key-producing calls are evaluated once per key');

fresh_perl_is(q{
    use utf8;
    use strict;
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    dispatch (['a', 'b']) {
        on ([/(?<prénom>a)/, /(?<numéro>b)/]) { say "$prénom,$numéro" }
    }
}, 'a,b', {}, 'multiple regex captures preserve UTF-8 lexical names');

fresh_perl_is(q{
    use strict;
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    'outside' =~ /(outside)/;
    dispatch (['a', 'b']) {
        on ([/(?<first>a)/, /(?<second>b)/]) {
            say "$first,$second,$1";
        }
    }
    say $1;
}, "a,b,b\noutside", {},
    'each regex supplies its own named captures and restores outer matches');

fresh_perl_is(q{
    use strict;
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    dispatch (bless({name => 'Ada', code => '42'}, 'Person')) {
        on (Person {name => /(?<who>\w+)/, code => /(?<id>\d+)/}) {
            say "$who,$id";
        }
    }
}, 'Ada,42', {}, 'named regex captures traverse object field shapes');

fresh_perl_is(q{
    use strict;
    use feature qw(dispatch_on say class);
    use dispatch::Predicates;
    no warnings 'experimental::class';
    class Person { field $name :param; field $code :param }
    dispatch (Person->new(name => 'Ada', code => '42')) {
        on (Person {'$name' => /(?<who>\w+)/,
                       '$code' => /(?<id>\d+)/}) { say "$who,$id" }
    }
}, 'Ada,42', {}, 'named regex captures traverse native class fields');

fresh_perl_is(q{
    use strict;
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    dispatch (['a1', 'bad', 'a2', 'b2']) {
        on ([..., /a(?<first>\d)/, /b(?<second>\d)(?<extra>x)?/, ...]) {
            say "$first,$second," . (defined($extra) ? 'wrong' : 'undef');
        }
    }
}, '2,2,undef', {},
    'open-array retries discard tentative captures from each rejected candidate');

fresh_perl_is(q{
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    for my $n (63, 64, 65, 128, 256) {
        my $values = join ',', 1 .. $n;
        my $bindings = join ',', map { '$x' . $_ } 1 .. $n;
        for my $shape ($values, $bindings) {
            my $result = eval 'dispatch ([' . $values . ']) { on (['
                . $shape . ']) { "hit" } on (_) { "miss" } }';
            die $@ if $@;
            die 'wrong result' unless $result eq 'hit';
        }
    }
    say 'ok';
}, 'ok', {}, 'large arrays and capture sets have no 64-element limit');

fresh_perl_is(q{
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    my $shape = join '.', map { ('"/"', '$x' . $_) } 1 .. 65;
    my $result = eval 'dispatch ("/v" x 65) { on (' . $shape
        . ') { $x1 . $x65 } on (_) { "miss" } }';
    die $@ if $@;
    say $result;
}, 'vv', {}, 'concatenations can capture more than 64 values');

fresh_perl_is(q{
    use strict;
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    my $shape = join '', map { '(?<x' . $_ . '>a)' } 1 .. 65;
    my $result = eval 'dispatch ("a" x 65) { on (/' . $shape
        . '/) { $x1 . $x65 } on (_) { "miss" } }';
    die $@ if $@;
    say $result;
}, 'aa', {}, 'regexes can bind more than 64 named captures');

fresh_perl_is(q{
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    use builtin qw(true false);
    my $one = 2; --$one;
    my $zero = 2; $zero -= 2;
    for my $v ($one, $zero, true, false) {
        dispatch ([$v]) {
            on ([true])  { say 'true' }
            on ([false]) { say 'false' }
            on (_)      { say 'not boolean' }
        }
    }
}, "not boolean\nnot boolean\ntrue\nfalse", {},
    'nested builtin boolean constants require actual boolean values');

fresh_perl_is(q{
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    my (@closures, @refs);
    for (1 .. 3) {
        dispatch ([$_]) {
            on ([$x]) {
                push @closures, sub { $x };
                push @refs, \$x;
            }
        }
    }
    say join ',', map { $_->() } @closures;
    say join ',', map { $$_ } @refs;
}, "1,2,3\n1,2,3", {},
    'escaped scalar bindings retain their values and iteration identity');

fresh_perl_is(q{
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    my @closures;
    for (1 .. 3) {
        dispatch ([$_, $_ + 1]) {
            on ([@tail]) { push @closures, sub { @tail } }
        }
    }
    say join ',', $_->() for @closures;
}, "1,2\n2,3\n3,4", {},
    'escaped slurp bindings retain their values and iteration identity');

{
    package DispatchOnHardeningTail::Destroyed;
    our $destroyed;
    sub DESTROY { $destroyed++ }
}

my ($rollback_value, $rollback_error);
my $exception_rollback_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    dispatch ([ 1, 2 ]) {
        on ([ $rollback_value, $other ] if die 'rollback guard') { 1 }
    }
    1;
};
$rollback_error = $@;
ok(!$exception_rollback_ok && $rollback_error =~ /rollback guard/
   && !defined($rollback_value),
   'bindings roll back when a guard throws');

my ($localized_before, $localized_inside, $localized_after);
my $localization_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    our $dispatch_on_local = 'outer';
    $localized_before = $dispatch_on_local;
    dispatch (1) {
        on (1) {
            local $dispatch_on_local = 'inner';
            $localized_inside = $dispatch_on_local;
        }
    }
    $localized_after = $dispatch_on_local;
    1;
};
ok(!$@ && $localization_ok && $localized_before eq 'outer'
   && $localized_inside eq 'inner' && $localized_after eq 'outer',
   'localization in a clause is restored normally');

my ($destroyed_inside, $destroyed_after);
sub destruction_probe {
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $value = bless {}, 'DispatchOnHardeningTail::Destroyed';
    my $weak = $value;
    Scalar::Util::weaken($weak);
    dispatch ($value) { on ($object = BlessedVal()) { $destroyed_inside = ref($object) } }
    undef $value;
    return !defined($weak);
}
my $destruction_ok = eval { destruction_probe() };
$destroyed_after = $DispatchOnHardeningTail::Destroyed::destroyed;
ok(!$@ && $destruction_ok && $destroyed_inside eq 'DispatchOnHardeningTail::Destroyed'
   && $destroyed_after,
   'captured objects are released after the dispatch scope ends');

sub exception_release_probe {
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $value = bless {}, 'DispatchOnHardeningTail::Destroyed';
    my $weak = $value;
    Scalar::Util::weaken($weak);
    eval {
        dispatch ($value) {
            on ($object = BlessedVal()) { die 'release from clause' }
        }
    };
    my $error = $@;
    undef $value;
    return $error, !defined($weak);
}
my ($exception_release_error, $exception_released) = exception_release_probe();
ok($exception_release_error =~ /release from clause/ && $exception_released,
   'captured objects are released when a clause dies');

sub array_binding_release_probe {
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $value = bless {}, 'DispatchOnHardeningTail::Destroyed';
    my $weak = $value;
    my $subject = [ $value ];
    Scalar::Util::weaken($weak);
    dispatch ($subject) {
        on ([ $captured ]) { 1 }
    }
    undef $subject;
    undef $value;
    return !defined($weak);
}
ok(array_binding_release_probe(),
   'captured objects in aggregate bindings are released at dispatch exit');

sub returned_binding_survives_cleanup {
    use feature 'dispatch_on';
    use dispatch::Predicates;
    my $value = bless {}, 'DispatchOnHardeningTail::Destroyed';
    my $weak = $value;
    Scalar::Util::weaken($weak);
    my $result = do {
        dispatch ($value) {
            on ($object = BlessedVal()) { $object }
        }
    };
    undef $value;
    my $ok = ref($result) eq 'DispatchOnHardeningTail::Destroyed'
        && defined($weak);
    undef $result;
    return $ok && !defined($weak);
}
ok(returned_binding_survives_cleanup(),
   'dispatch cleanup does not invalidate a value returned by a clause');

my ($nested_result, $nested_outer_result);
my $nested_case_ok = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    $nested_result = do { dispatch ([ 1, 2 ]) {
        on ([ 1, $x ]) {
            dispatch ($x) { on (2) { 'inner' } }
        }
    } };
    $nested_outer_result = do { dispatch (1) { on (1) { 'outer' } } };
    1;
};
ok(!$@ && $nested_case_ok && $nested_result eq 'inner'
   && $nested_outer_result eq 'outer',
   'nested dispatches restore the parent dispatch state');

for my $target (qw(x px)) {
    my $program = q{
        use strict;
        use feature qw(dispatch_on say);
        use dispatch::Predicates;
        use experimental 'class';
        class Position {
            field $x :param;
            field $y :param;
        }
        dispatch (Position->new(x => 3, y => 4)) {
            on (Position { '$x' => $TARGET, '$y' => $other }
                   if $TARGET == 3 && $other == 4) {
                say "$TARGET,$other";
            }
        }
    };
    $program =~ s/TARGET/$target/g;
    fresh_perl_is($program, '3,4', {},
        "native class fields bind implicit target \$$target in guard and body");
}

fresh_perl_is(q{
    use strict;
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    my ($x, $y) = ('outer x', 'outer y');
    my $point = bless { x => 3, y => 4 }, 'Point';
    dispatch ($point) {
        on (Point { 'x' => $x, 'y' => $y } if $x == 3) {
            say "$x,$y";
        }
    }
    say "$x,$y";
}, "3,4\nouter x,outer y", {},
    'class-qualified captures shadow rather than overwrite outer lexicals');

fresh_perl_is(q{
    use strict;
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    my $record = bless {
        child => bless({ values => [3, 4, 5] }, 'Child'),
    }, 'Record';
    dispatch ($record) {
        on (Record {
            'child' => Child { 'values' => [$head, @tail] },
        } if $head == 3 && @tail == 2) {
            say "$head:@tail";
        }
    }
}, '3:4 5', {},
    'nested object shapes expose scalar and array captures to the clause');

fresh_perl_is(q{
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    use experimental 'class';
    class Position {
        field $x :param;
        field $y :param;
    }
    dispatch (Position->new(x => 3, y => 4)) {
        on (Position { '$x' => $x, '$y' => $y }) {
            say "position: $x, $y";
        }
    }
}, 'position: 3, 4', {},
    'native captures named after fields do not select class field pad entries');

fresh_perl_is(q{
    use strict;
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    my $wanted = 'ok';
    my $value = 'outside';
    my $record = bless { status => 'ok', value => 3 }, 'Record';
    dispatch ($record) {
        on (Record { 'status' => $wanted, 'value' => $value }
               if $value == 4) { die 'wrong guard' }
        on (Record { 'status' => ^$wanted, 'value' => $value = Int() }
               if $value == 3) { say $value }
    }
    say "$wanted,$value";
}, "3\nok,outside", {},
    'object pins and typed captures retain scope across a failed guard');

fresh_perl_is(q{
    use strict;
    use utf8;
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    for (1 .. 3) {
        dispatch ([bless({ value => $_ }, 'Record')]) {
            on ([Record { 'value' => $résultat }]) {
                say $résultat;
            }
        }
    }
}, "1\n2\n3", {},
    'object captures nested in arrays preserve UTF-8 names and repeated use');

fresh_perl_is(q{
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    for (1 .. 100) {
        eval q{
            dispatch ([1, /(?<x>one)/]) {
                on ([1, /(?<y>one)/]) { 1 }
            }
            this is not valid Perl;
        };
        die 'pattern cleanup did not preserve the compile failure'
            unless $@;
    }
    say 'ok';
}, 'ok', {},
    'compiled pattern ownership is released when a later compile error discards the optree');

fresh_perl_is(q{
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    for (1 .. 3) {
        my $result = eval q{
            dispatch ([]) {
                on ([1, @rest]) { die 'tail too short' }
                on (_) { 'miss' }
            }
        };
        die $@ if $@;
        say $result;
    }
}, "miss\nmiss\nmiss", {},
    'freeing a slurp pattern releases its capture state');

fresh_perl_is(q{
    use strict;
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    {
        package TiedPoint;
        sub TIEHASH { bless { values => $_[1] }, $_[0] }
        sub FETCH { $_[0]{values}{$_[1]} }
        sub EXISTS { exists $_[0]{values}{$_[1]} }
        sub FIRSTKEY { my $self = shift; keys %{ $self->{values} }; each %{ $self->{values} } }
        sub NEXTKEY { each %{ $_[0]{values} } }
    }
    tie my %fields, 'TiedPoint', { x => 3 };
    my $point = bless \%fields, 'Point';
    dispatch ($point) {
        on (Point { x => $x }) { say $x }
    }
}, '3', {}, 'class-qualified shapes read tied blessed hash fields');

fresh_perl_is(q{
    use strict;
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    {
        package FieldString;
        use overload '""' => sub { $_[0]{value} }, fallback => 1;
    }
    my $point = bless {
        value => bless({ value => 'target' }, 'FieldString'),
    }, 'Point';
    dispatch ($point) {
        on (Point { value => 'target' }) { say 'stringified field' }
    }
}, 'stringified field', {},
    'object field patterns use overload only for string-valued fields');

fresh_perl_is(q{
    use strict;
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    use Scalar::Util qw(refaddr);
    my $child = { value => 7 };
    my $point = bless { child => $child }, 'Point';
    dispatch ($point) {
        on (Point { child => $captured = RefVal() }) {
            say refaddr($captured) == refaddr($child)
                ? 'same reference' : 'wrong reference';
        }
    }
}, 'same reference', {},
    'object field reference captures preserve identity');

fresh_perl_is(q{
    use strict;
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    my $point = bless { value => 7 }, 'Point';
    my ($captured, $error);
    {
        local $@;
        eval {
            dispatch ($point) {
                on (Point { value => $captured }) {
                    $point->{value} = 8;
                    die 'mutation must not fail' unless $point->{value} == 8;
                }
            }
        };
        $error = $@;
    }
    say !$error && $point->{value} == 8
        ? 'mutated safely' : 'mutation failed';
}, 'mutated safely', {},
    'mutating an object after a capture remains caller-controlled');

fresh_perl_is(q{
    use strict;
    use feature qw(dispatch_on say);
    use dispatch::Predicates;
    my $point = bless { value => 3 }, 'Point';
    dispatch ($point) {
        on (Point { value => $value } if $value == 4) {
            die 'failed guard selected';
        }
        on (Point { value => $fallback }) {
            say "fallback=$fallback";
        }
    }
}, 'fallback=3', {},
    'object captures roll back after a failed guard');
