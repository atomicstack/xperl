#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc(qw(. ../lib));
}

use dispatch::Predicates;

# Cross-feature regressions from the implementation/documentation review.
# Test observable results AND process status: a crash after printing the
# expected result must not pass. These regressions were originally failing;
# keep their expectations independent of the implementation being tested.
sub check_case {
    my ($name, $code, $expected) = @_;
    my $result = fresh_perl(
        "use strict; use warnings; use feature qw(dispatch_on say signatures); no warnings 'experimental::signatures'; use dispatch::Predicates;\n" . $code,
        {},
    );
    my $status = $?;
    is($result, $expected, $name);
    is($status, 0, "$name: clean exit");
}

# Every backend must implement the same source-order and comparison-mode rules.
# Select the mode before the subprocess compiles its cases.
for my $mode (qw(none array-linear array-binary hv auto)) {
    local $ENV{PERL_CONST_DISPATCH_STRATEGY} = $mode;
    check_case("$mode: literal kinds and defaults", q{
        for my $value (1, '1', '01', 7, '7') {
            dispatch ($value) {
                on ('1') { say 'string' }
                on (1)   { say 'number' }
                on (_)   { say 'default' }
            }
        }
        dispatch (undef) {
            on (0)     { say 'wrong' }
            on ('')    { say 'wrong' }
            on (undef) { say 'undef' }
        }
        dispatch (0) {
            on (undef) { say 'wrong' }
            on (0)     { say 'zero' }
        }
    }, "string\nstring\nnumber\ndefault\ndefault\nundef\nzero");

    check_case("$mode: warning-worthy coercions are non-matches", q{
        for my $value ('foo', '', undef) {
            dispatch ($value) {
                on (0)   { say 'zero' }
                on ('')  { say 'empty' }
                on (undef) { say 'undef' }
                on (_)   { say 'default' }
            }
        }
        for my $value ([undef], {x => undef}) {
            dispatch ($value) {
                on ([0])      { say 'wrong' }
                on ({x => ''}) { say 'wrong' }
                on (_)        { say 'shape default' }
            }
        }
    }, "default\nempty\nundef\nshape default\nshape default");

    check_case("$mode: an existing numeric cache avoids conversion rejection", q{
        use Scalar::Util qw(dualvar);
        my $value = dualvar(0, 'word');
        dispatch ($value) {
            on (0)      { say 'numeric cache' }
            on ('word') { say 'string value' }
            on (_)      { say 'default' }
        }
    }, 'numeric cache');

    check_case("$mode: pattern mode is independent of subject numeric caching", q{
        my $value = '1';
        my $number = 0 + $value;
        dispatch ($value) {
            on (1)   { say 'number' }
            on ('1') { say 'string' }
            on (_)   { say 'default' }
        }
    }, 'number');

    check_case("$mode: numeric lower/upper bounds and in-range misses", q{
        for my $value (1, 2, 3, 4, 5, 6, 7) {
            dispatch ($value) {
                on (2) { say 'two' }
                on (4) { say 'four' }
                on (6) { say 'six' }
                on (_) { say 'miss' }
            }
        }
    }, "miss\ntwo\nmiss\nfour\nmiss\nsix\nmiss");

    check_case("$mode: signed bounds preserve unsigned hits", q{
        my $maximum = ~0;
        my $literal = sprintf '%u', $maximum;
        my $matcher = eval 'sub { my ($value) = @_; dispatch ($value) {'
            . 'on (-1) { "negative" } on (' . $literal
            . ') { "unsigned" } on (_) { "miss" } } }';
        die $@ if $@;
        say $matcher->($_) for (-2, -1, 0, $maximum - 1, $maximum);
    }, "miss\nnegative\nmiss\nmiss\nunsigned");

    check_case("$mode: unsigned values exceed wholly negative bounds", q{
        dispatch (~0) {
            on (-4) { say 'wrong' }
            on (-1) { say 'wrong' }
            on (_) { say 'miss' }
        }
    }, 'miss');

    check_case("$mode: byte and UTF-8 representations compare by characters", q{
        my $text = chr(233);
        for (1 .. 2) {
            dispatch ($text) {
                on ("\x{e9}") { say 'hit' }
                on (_)        { say 'miss' }
            }
            utf8::upgrade($text);
        }
    }, "hit\nhit");

    check_case("$mode: byte mode compares raw encodings", q{
        my $text = chr(233);
        utf8::upgrade($text);
        my $encoded = $text;
        utf8::encode($encoded);
        use bytes;
        for my $value ($text, $encoded) {
            dispatch ($value) {
                on ("\xc3\xa9") { say 'hit' }
                on (_) { say 'miss' }
            }
        }
    }, "hit\nhit");

    check_case("$mode: scalar/list/void contexts inside a subroutine", q{
        sub context_name {
            return !defined(wantarray) ? 'void'
                 : wantarray ? 'list' : 'scalar';
        }
        sub selected {
            dispatch (1) { on (1) { context_name() } }
        }
        my $scalar = selected();
        my @list = selected();
        say "$scalar,@list";
        my $void;
        sub observe_void {
            $void = !defined(wantarray);
        }
        dispatch (1) { on (1) { observe_void() } }
        say $void ? 'void' : 'wrong';
    }, "scalar,list\nvoid");

    check_case("$mode: dispatch sizes and scalar domains", q{
        for my $size (1, 15, 16, 17, 65) {
            for my $kind (qw(integer float string)) {
                for my $default (0, 1) {
                    my @values = map {
                        $kind eq 'integer' ? 2 * $_
                      : $kind eq 'float'   ? 2 * $_ + 0.5
                      : sprintf 'key%04d', 2 * $_
                    } 1 .. $size;
                    my $source = 'sub { my ($value) = @_; dispatch ($value) {';
                    for my $index (0 .. $#values) {
                        my $literal = $kind eq 'string'
                            ? '"' . $values[$index] . '"' : $values[$index];
                        $source .= "on ($literal) { $index }";
                    }
                    $source .= 'on (_) { -1 }' if $default;
                    $source .= '} }';
                    my $matcher = eval $source;
                    die $@ if $@;
                    for my $index (0 .. $#values) {
                        my $got = $matcher->($values[$index]);
                        die "$kind/$size/$default hit $index"
                            unless defined($got) && $got == $index;
                    }
                    # Below minimum, between keys, and above maximum.
                    my @misses = $kind eq 'string'
                        ? ('key0000', 'key0003', 'key9999')
                        : $kind eq 'float' ? (0.5, 3.5, 2*$size + 2.5)
                        : (0, 3, 2*$size + 2);
                    for my $miss (@misses) {
                        my $got = $matcher->($miss);
                        die "$kind/$size/$default miss $miss"
                            unless $default ? defined($got) && $got == -1
                                            : !defined($got);
                    }
                }
            }
        }
        say 'all hits and misses correct';
    }, 'all hits and misses correct');
}

check_case('nested constants preserve the scalar kind', q{
    for my $value ([1], ['1'], {x => 1}, {x => '1'}) {
        dispatch ($value) {
            on (['1'])   { say 'array string' }
            on ([1])     { say 'array number' }
            on ({x=>'1'}) { say 'hash string' }
            on ({x=>1})   { say 'hash number' }
        }
    }
}, "array string\narray string\nhash string\nhash string");

check_case('numeric strings: padding, whitespace, exponents and invalid text', q{
    for my $value ('7', '0007', ' 7 ', '-0', '7.0', '1e3', '.5', 'A', '') {
        dispatch ($value) {
            on ($original = Int())   { say "integer:$original" }
            on ($original = Num()) { say "float:$original" }
            on (_)                  { say 'neither' }
        }
    }
}, "integer:7\ninteger:0007\ninteger: 7 \ninteger:-0\ninteger:7.0\n"
   . "integer:1e3\nfloat:.5\nneither\nneither");

check_case('value predicates distinguish undef, scalars and references', q{
    for my $value (undef, '', 0, '0', [], {}, sub {}, bless({}, 'Object')) {
        dispatch ($value) {
            on (BlessedVal()) { say 'object' }
            on (RefVal()) { say 'reference' }
            on (DefinedVal()) { say 'defined scalar' }
            on (NonRefVal()) { say 'undefined scalar' }
        }
    }
}, "undefined scalar\ndefined scalar\ndefined scalar\ndefined scalar\n"
   . "reference\nreference\nreference\nobject");

check_case('boolean values and ordinary truth values remain distinct', q{
    use builtin qw(true false);
    for my $value (true, false, undef, '', '0', 0, 'yes', [], 1 < 2) {
        dispatch ($value) {
            on (true)  { say 'boolean true' }
            on (false) { say 'boolean false' }
            on (True())  { say 'truthy' }
            on (False()) { say 'falsey' }
        }
    }
}, "boolean true\nboolean false\nfalsey\nfalsey\nfalsey\nfalsey\n"
   . "truthy\ntruthy\nboolean true");

for my $criterion (qw(Integer Number)) {
    my $text = $criterion eq 'Integer' ? '1' : '1.5';
    check_case("$criterion: strings stay strings after numeric use", '
        my $value = "' . $text . '";
        my $number = 0 + $value;
        dispatch ($value) {
            on (' . $criterion . '()) { say "wrong" }
            on (_) { say "string" }
        }
    ', 'string');
}

check_case('nested predicate capture fetches its tied source once', q{
    package Changing {
        sub TIESCALAR { bless [0], shift }
        sub FETCH { ++$_[0][0] == 1 ? 1 : 'changed' }
    }
    my @values = (0);
    tie $values[0], 'Changing';
    dispatch (\@values) {
        on ([$captured = Int()]) { say $captured }
    }
    say tied($values[0])->[0];
}, "1\n1");

check_case('user guard reads remain separate from matcher reads', q{
    package Changing {
        sub TIESCALAR { bless [0], shift }
        sub FETCH { ++$_[0][0] }
    }
    my $value;
    tie $value, 'Changing';
    dispatch ($value) {
        on (1 if $value == 2) { say $value }
    }
    say tied($value)->[0];
}, "3\n3");

check_case('sparse slots match undef without filling source holes', q{
    my @values;
    $values[2] = 1;
    dispatch (\@values) {
        on ([undef, undef, 1]) { say 'hit' }
        on (_) { say 'miss' }
    }
    say exists($values[0]) || exists($values[1]) ? 'filled' : 'sparse';
}, "hit\nsparse");

check_case('sparse tail captures preserve length and undef values', q{
    my @values;
    $values[2] = 1;
    dispatch (\@values) {
        on ([@tail]) {
            say join ',', map { defined($_) ? $_ : 'undef' } @tail;
        }
        on (_) { say 'miss' }
    }
    say exists($values[0]) ? 'filled' : 'sparse';
}, "undef,undef,1\nsparse");

check_case('open searches may start at a sparse undef slot', q{
    my @values;
    $values[2] = 'end';
    dispatch (\@values) {
        on ([..., undef, 'end', ...]) { say 'hit' }
        on (_) { say 'miss' }
    }
}, 'hit');

for my $shape ('{a}', '{$key=>1}', '{a=>...}') {
    check_case("malformed hash shape $shape is rejected at compile time", '
        my $compiled = eval q{sub {
            dispatch ({a=>1}) { on (' . $shape . ') { 1 } }
        }};
        say $@ && !$compiled ? "rejected" : "accepted";
    ', 'rejected');
}

for my $shape ('[1,...,2]', '[@rest,1]', '[@first,@second]',
               '[@rest:-1]', 'constant(1)',
               'Strict(Num())', 'Strict(Int())', 'Strict(Number())',
               'Between($low)', 'NumEq($target)') {
    check_case("unsupported shape $shape is rejected before execution", '
        sub constant { 1 }
        sub Between ($subject, $bound) { $subject >= $bound }
        my $low = 1;
        my $compiled = eval q{sub {
            dispatch ([]) { on (' . $shape . ') { 1 } }
        }};
        say $@ && !$compiled ? "rejected" : "accepted";
    ', 'rejected');
}

check_case('slurps capture the complete remaining tail', q{
    for my $subject ([1], [1,2], [1,2,3], [1,2,3,4]) {
        dispatch ($subject) {
            on ([1,@tail]) { say join ',', @tail }
        }
    }
}, "\n2\n2,3\n2,3,4");

check_case('scalar-reference shapes do not try to copy CODE bodies', q{
    dispatch (sub {}) {
        on (\$value) { say 'wrong' }
        on (_) { say 'not a scalar reference' }
    }
}, 'not a scalar reference');

check_case('nested reference shapes bind the scalar referent', q{
    my $number = 42;
    my $reference = \$number;
    dispatch (\$reference) {
        on (\\\\$value) { say $value }
    }
}, '42');

for my $upgrade_subject (0, 1) {
    check_case("concat preserves character semantics, upgrade=$upgrade_subject", '
        my $subject = chr(233) . "tail";
        my $prefix = chr(233);
        utf8::upgrade(' . ($upgrade_subject ? '$subject' : '$prefix') . ');
        dispatch ($subject) {
            on (^$prefix . $suffix) { say $suffix }
            on (_) { say "miss" }
        }
    ', 'tail');
}

check_case('concat does not implicitly stringify a numeric subject', q{
    for my $subject (123, '123') {
        dispatch ($subject) {
            on ('1' . $tail) { say "tail=$tail" }
            on (_) { say 'not a string' }
        }
    }
}, "not a string\ntail=23");

check_case('ordinary scope exit releases a dispatch subject', q{
    use builtin qw(weaken);
    my $weak;
    {
        my $subject = bless {}, 'Lifetime';
        $weak = $subject;
        weaken($weak);
        dispatch ($subject) { on (_) { } }
    }
    say defined($weak) ? 'retained' : 'released';
}, 'released');

check_case('native field view is released when field matching throws', q{
    use feature 'class';
    no warnings 'experimental::class';
    use builtin qw(weaken);
    package Throws {
        use overload '""' => sub { die "field error\n" }, fallback => 1;
    }
    class Holder { field $value :param }
    my $weak;
    {
        my $value = bless {}, 'Throws';
        $weak = $value;
        weaken($weak);
        my $subject = Holder->new(value => $value);
        eval { dispatch ($subject) { on (Holder {'$value'=>'text'}) { } } };
        die 'wrong exception' unless $@ eq "field error\n";
        # Isolate the field-view leak from the separate subject ownership bug.
        undef $subject;
        undef $value;
    }
    say defined($weak) ? 'retained' : 'released';
}, 'released');

check_case('generator suspension preserves a clause binding', q{
    use generator;
    my $process = gen {
        dispatch (['ok', 42]) {
            on (['ok', $number]) {
                yield $number;
                yield $number + 1;
            }
        }
    };
    say $process->();
    say $process->();
    my @end = $process->();
    say scalar @end;
}, "42\n43\n0");

check_case('named dispatch subjects and direct pins do not require namespaces', q{
    my ($subject, $wanted, $calls) = ('outer', 'ok', 0);
    my $version = ++$calls + 2;
    dispatch my $subject (['ok', 3]) {
        on ([^$wanted, ^$version]) { say join ',', @$subject }
    }
    say "$subject,$wanted,$calls";
}, "ok,3\nouter,ok,1");

check_case('later clauses read current direct pins', q{
    my $wanted = 1;
    dispatch ([1]) {
        on ([^$wanted] if do { $wanted = 2; 0 }) { die 'wrong clause' }
        on ([^$wanted]) { say 'stale pin matched' }
    }
    say $wanted;
}, "2");

check_case('recursive clauses keep bindings independent', q{
    sub descend {
        my ($depth) = @_;
        dispatch ([$depth]) {
            on ([$number] if $number > 0) {
                my $inner = descend($number - 1);
                return "$number:$inner:$number";
            }
            on ([0]) { return 'zero' }
        }
    }
    say descend(2);
}, '2:1:zero:1:2');

check_case('guard suspension preserves tentative captures', q{
    use generator;
    my $process = gen {
        dispatch ([7]) {
            on ([$number] if yield($number)) { yield $number + 1 }
            on (_) { yield 'default' }
        }
    };
    say $process->();
    say $process->(1);
    my @end = $process->();
    say scalar @end;
}, "7\n8\n0");

check_case('false resumption of a generator guard selects the next clause', q{
    use generator;
    my $process = gen {
        dispatch ([7]) {
            on ([$number] if yield($number)) { yield 'wrong' }
            on ([$other]) { yield $other + 2 }
        }
    };
    say $process->();
    say $process->(0);
    my @end = $process->();
    say scalar @end;
}, "7\n9\n0");

check_case('closures from repeated slurp matches retain independent tails', q{
    my @closures;
    for my $value ([1, 2], [3, 4]) {
        dispatch ($value) {
            on ([$first, @tail]) { push @closures, sub { ($first, @tail) } }
        }
    }
    say join ',', $_->() for @closures;
}, "1,2\n3,4");

check_case('regex captures restore after an exception from a guard', q{
    'outer' =~ /(?<outside>outer)/;
    eval {
        dispatch ('inner') {
            on (/(?<inside>inner)/ if die "guard error\n") { }
        }
    };
    die 'wrong exception' unless $@ eq "guard error\n";
    say "$1,$+{outside}";
}, 'outer,outer');

check_case('regex backtracking publishes captures from the winning candidate', q{
    dispatch (['a1', 'bad', 'a2', 'b2']) {
        on ([..., /a(?<first>\d)/, /b(?<second>\d)/, ...]) {
            say "$first,$second,$1";
        }
    }
}, '2,2,2');

check_case('concat byte captures do not retain a partial UTF-8 flag', q{
    my $text = chr(233);
    utf8::upgrade($text);
    use bytes;
    dispatch ($text) {
        on ("\xc3" . $tail) {
            say unpack('H*', $tail);
            say utf8::is_utf8($tail) ? 'wrong flag' : 'bytes';
        }
    }
}, "a9\nbytes");

check_case('concat calls subject and pinned stringification only once', q{
    package Text {
        our $calls = 0;
        use overload '""' => sub { ++$calls; $_[0][0] }, fallback => 1;
    }
    my $subject = bless ['prefix_tail'], 'Text';
    my $prefix = bless ['prefix_'], 'Text';
    dispatch ($subject) {
        on (^$prefix . $tail) { say $tail }
    }
    say $Text::calls;
}, "tail\n2");

check_case('computed scalar values use the same kind rules as literals', q{
    sub text { '1' }
    sub number { 1 }
    for my $value (1, '1') {
        dispatch ($value) {
            on (text()) { say 'string' }
            on (number()) { say 'number' }
        }
    }
}, "number\nstring");

for my $qualifier ('', 'Box ') {
    check_case("${qualifier}hash shapes distinguish missing keys from undef", q{
        package Values {
            our ($exists, $fetches) = (0, 0);
            sub TIEHASH { bless {}, shift }
            sub EXISTS { ++$exists; $_[1] eq 'present' }
            sub FETCH { ++$fetches; undef }
            sub FIRSTKEY { 'present' }
            sub NEXTKEY { undef }
        }
        tie my %values, 'Values';
        my $subject = bless \%values, 'Box';
    } . '
        dispatch ($subject) {
            on (' . $qualifier . '{missing=>undef,...}) { say "wrong" }
            on (_) { say "absent" }
        }
        dispatch ($subject) {
            on (' . $qualifier . '{missing=>undef}) { say "wrong" }
            on (_) { say "absent" }
        }
        dispatch ($subject) {
            on (' . $qualifier . '{present=>undef,...}) { say "present" }
        }
        dispatch ($subject) {
            on (' . $qualifier . '{present=>undef}) { say "present" }
        }
        say "$Values::exists,$Values::fetches";
    ', "absent\nabsent\npresent\npresent\n4,2");
}

check_case('false guard advances clauses rather than restarting open search', q{
    my @seen;
    dispatch ([1, 2, 3]) {
        on ([..., $item, ...] if do { push @seen, $item; $item == 2 }) {
            say 'wrong retry';
        }
        on (_) { say 'next clause' }
    }
    say join ',', @seen;
}, "next clause\n1");

check_case('recursive regex shapes follow ordinary regex capture behavior', q{
    my (@ordinary, @shapes);
    sub ordinary {
        my ($n) = @_;
        "$n" =~ /(?<digits>\d+)/;
        my $digits = $+{digits};
        ordinary($n - 1) if $n;
        push @ordinary, "$digits,$1";
    }
    sub shaped {
        my ($n) = @_;
        dispatch ("$n") {
            on (/(?<digits>\d+)/) {
                shaped($n - 1) if $n;
                push @shapes, "$digits,$1";
            }
        }
    }
    ordinary(2);
    shaped(2);
    say join(';', @ordinary) eq join(';', @shapes) ? 'same' : 'different';
}, 'same');

check_case('tail bindings copy source slots in both directions', q{
    my $source = [1, 2, 3];
    my $saved;
    dispatch ($source) {
        on ([1, @tail]) {
            $tail[0] = 20;
            $source->[2] = 30;
            say join ',', @tail;
            say join ',', @$source;
            $saved = sub { join ',', @tail };
            delete $tail[1];
        }
    }
    @$source = (9);
    say $saved->();
}, "20,3\n1,2,30\n20");

check_case('tail copies preserve reference identity without slot aliases', q{
    my $object = bless { value => 1 }, 'Box';
    my $source = [$object];
    dispatch ($source) {
        on ([@tail]) {
            say $tail[0] == $object ? 'same object' : 'wrong';
            $tail[0]{value} = 2;
            $tail[0] = undef;
            say $source->[0]{value};
        }
    }
}, "same object\n2");

check_case('tail copies fetch tied elements once and do not retain magic', q{
    package Values {
        our ($fetches, $stores) = (0, 0);
        sub TIEARRAY { bless {}, shift }
        sub FETCHSIZE { 2 }
        sub FETCH { ++$fetches; $_[1] + 10 }
        sub STORE { ++$stores }
    }
    tie my @source, 'Values';
    dispatch (\@source) {
        on ([@tail]) {
            say join ',', @tail;
            say join ',', @tail;
            $tail[0] = 99;
        }
    }
    say "$Values::fetches,$Values::stores";
}, "10,11\n10,11\n2,0");

check_case('a false guard cannot modify source slots through its tail', q{
    my $source = [1, 2];
    dispatch ($source) {
        on ([@tail] if do { $tail[0] = 99; 0 }) { say 'wrong' }
        on ([1, 2]) { say 'unchanged' }
    }
}, 'unchanged');

check_case('pinned equality distinguishes undef from empty strings', q{
    for my $pair ([undef, ''], ['', undef], ['a', 'b'],
                 [undef, undef], ['', ''], [0, '0']) {
        my ($pin, $subject) = @$pair;
        dispatch ($subject) {
            on (^$pin) { say 'equal' }
            on (_) { say 'different' }
        }
        dispatch ($subject) {
            on (^$pin) { say 'equal' }
            on (_) { say 'different' }
        }
    }
    dispatch (undef) {
        on (undef) { say 'literal undef' }
    }
}, join("\n", (('different') x 6), (('equal') x 6), 'literal undef'));

check_case('pattern callbacks cannot destroy retained captures', q{
    package Box { sub DESTROY { } }
    my @values = (bless({}, 'Box'), 1);
    sub remove_first { delete $values[0]; 1 }
    dispatch (\@values) {
        on ([$captured = RefVal(), remove_first()]) { say ref $captured }
    }
}, 'Box');

check_case('pattern calls retain the current scalar and nested container', q{
    my @values = ([1, 2]);
    sub remove_container { $values[0] = undef; 1 }
    dispatch (\@values) {
        on ([[remove_container(), 2]]) { say 'hit' }
        on (_) { say 'miss' }
    }
}, 'hit');

check_case('exception releases captures retained before a callback', q{
    package Box {
        our $destroyed = 0;
        sub DESTROY { ++$destroyed }
    }
    my @values = (bless({}, 'Box'), 1);
    sub fail { delete $values[0]; die "expected\n" }
    eval {
        dispatch (\@values) {
            on ([$captured = RefVal(), fail()]) { say 'wrong' }
        }
    };
    say $@ eq "expected\n" ? 'caught' : 'wrong error';
    say $Box::destroyed;
}, "caught\n1");

check_case('open arrays check literal anchors before fetching captures', q{
    package Values {
        our @reads;
        sub TIEARRAY { bless {}, shift }
        sub FETCHSIZE { 3 }
        sub FETCH { push @reads, $_[1]; (10, 20, 42)[$_[1]] }
    }
    tie my @values, 'Values';
    dispatch (\@values) {
        on ([..., $x, 42, ...]) { say $x }
    }
    say join ',', @Values::reads;
}, "20\n1,2,1");

check_case('literal failure skips pattern calls and capture-only reads', q{
    sub unexpected { die 'must not call' }
    dispatch ([1, 9]) {
        on ([unexpected(), 7]) { say 'wrong' }
        on (_) { say 'miss' }
    }
    package Values {
        sub TIEARRAY { bless {}, shift }
        sub FETCHSIZE { 2 }
        sub FETCH { die 'capture fetched' if $_[1] == 0; 9 }
    }
    tie my @values, 'Values';
    dispatch (\@values) {
        on ([$x, 7]) { say 'wrong' }
        on (_) { say 'miss' }
    }
}, "miss\nmiss");

check_case('nested captures wait for outer constraints', q{
    package Values {
        sub TIEARRAY { bless {}, shift }
        sub FETCHSIZE { 1 }
        sub FETCH { die 'nested capture fetched' }
    }
    tie my @values, 'Values';
    sub reject { 0 }
    dispatch ([\@values, 1]) {
        on ([[$x], reject()]) { say 'wrong' }
        on (_) { say 'miss' }
    }
}, 'miss');

check_case('constraint observations are reused when publishing captures', q{
    package Values {
        our $reads = 0;
        sub TIEARRAY { bless {}, shift }
        sub FETCHSIZE { 2 }
        sub FETCH { ++$reads; 12 }
    }
    tie my @values, 'Values';
    dispatch (\@values) {
        on ([$x = Int(), $y = Int()] if $x == $y) { say $x }
    }
    say $Values::reads;
}, "12\n2");

check_case('literal hash constraints precede capture-only fetches', q{
    package Values {
        our @reads;
        sub TIEHASH { bless {}, shift }
        sub EXISTS { 1 }
        sub FETCH { push @reads, $_[1]; $_[1] eq 'tag' ? 'yes' : 12 }
    }
    tie my %values, 'Values';
    dispatch (\%values) {
        on ({ value => $x, tag => 'yes', ... }) { say $x }
    }
    say join ',', @Values::reads;
}, "12\ntag,value");

check_case('owner grows across rejected pinned candidates', q{
    my @values = (1 .. 1001);
    my $last = 1001;
    dispatch (\@values) {
        on ([..., $x = Int(), ^$last, ...]) { say $x }
    }
}, '1000');

check_case('wildcards do not fetch array elements', q{
    package Values {
        sub TIEARRAY { bless {}, shift }
        sub FETCHSIZE { 2 }
        sub FETCH { die 'wildcard fetched' if $_[1] == 0; 42 }
    }
    tie my @values, 'Values';
    dispatch (\@values) { on ([_, 42]) { say 'hit' } }
}, 'hit');

check_case('retained constraints observe in-place changes but survive deletion', q{
    my @values = (1, 1, 2);
    sub change { $values[0] = 2; 1 }
    dispatch (\@values) {
        on ([$x = Int(), change(), 2]) { say $x }
    }
}, '2');

check_case('array candidates do not chase callback appends', q{
    my @values = (1, 2);
    our $calls = 0;
    sub extend { ++$calls; push @values, 99; 99 }
    dispatch (\@values) {
        on ([..., extend(), ...]) { say 'wrong' }
        on (_) { say 'miss' }
    }
    say $calls;
}, "miss\n2");

check_case('callback exceptions after owned regex and concat captures unwind', q{
    sub fail { die "expected\n" }
    for (1 .. 20) {
        eval {
            dispatch (['abc', 'prefix_tail', 1]) {
                on ([/(?<word>abc)/, 'prefix_' . $tail, fail()]) {
                    die 'wrong';
                }
            }
        };
        die 'wrong error' unless $@ eq "expected\n";
    }
    say 'caught';
}, 'caught');

check_case('many deferred captures use independent metadata and grow safely', q{
    my $pattern = join ',', map { '$v' . $_ } 1 .. 100;
    my $code = 'dispatch ([1 .. 100]) { on ([' . $pattern
        . ']) { say $v1 + $v100 } }';
    eval $code;
    die $@ if $@;
}, '101');

check_case('duplicate regex names select source order across scheduling ranks', q{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    eval q{
        dispatch (['a', ['b']]) {
            on ([/(?<x>a)/, [/(?<x>b)/]]) { say "$x,$+{x}" }
        }
    };
    die $@ if $@;
    say @warnings == 1
        && $warnings[0] =~ /only the first regex maps/ ? 'warned' : 'wrong warning';
}, "a,a\nwarned");

check_case('nonparticipating first regex capture survives reordered execution', q{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    eval q{
        dispatch (['a', ['b']]) {
            on ([/(?:a|(?<x>z))/, [/(?<x>b)/]]) {
                say defined($x) ? 'wrong' : 'undef';
            }
        }
    };
    die $@ if $@;
    say scalar @warnings;
}, "undef\n1");

check_case('reordered regex names preserve original capture across candidates', q{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    eval q{
        dispatch (['no', ['b'], 'a', ['b']]) {
            on ([..., /(?<x>a)/, [/(?<x>b)/], ...]) { say $x }
        }
    };
    die $@ if $@;
    say scalar @warnings;
}, "a\n1");

check_case('scalar equality matrix uses pinned-value comparison modes', q{
    use Scalar::Util qw(looks_like_number);
    my $array = [];
    my $hash = {};
    my @values = (undef, '', 0, '0', 1, '1', 'word', $array, $hash);
    no warnings 'numeric';
    for my $i (0 .. $#values) {
        my $a = $values[$i];
        for my $b (@values) {
            my $expected = !defined($a) || !defined($b)
                ? !defined($a) && !defined($b)
                : ref($a) || ref($b)
                    ? ref($a) && ref($b) && $a == $b
                    : ($i == 2 || $i == 4)
                        ? looks_like_number($a) && looks_like_number($b)
                            && $a == $b
                        : $a eq $b;
            my $actual = do { dispatch ($b) {
                on (^$a) { 1 } on (_) { 0 }
            } };
            die 'caret mismatch' if !!$actual != !!$expected;
            my $pinned = do { dispatch ($b) {
                on (^$a) { 1 } on (_) { 0 }
            } };
            die 'pinned mismatch' if !!$pinned != !!$expected;
        }
    }
    say '81 pairs';
}, '81 pairs');

check_case('shape call failures propagate exception objects unchanged', q{
    my $error = bless {}, 'Failure';
    sub fail { die $error }
    eval { dispatch ([1]) { on ([fail()]) { die 'wrong' } } };
    say ref($@) eq 'Failure' && $@ == $error ? 'same exception' : 'wrong';
}, 'same exception');

for my $qualifier ('', 'Box ') {
    check_case("${qualifier}hash wildcard checks presence without fetching", q{
        package Values {
            our $exists = 0;
            sub TIEHASH { bless {}, shift }
            sub EXISTS { ++$exists; $_[1] eq 'present' }
            sub FETCH { die 'wildcard fetched' }
        }
        tie my %values, 'Values';
        my $subject = bless \%values, 'Box';
    } . '
        dispatch ($subject) {
            on (' . $qualifier . '{present => _, ...}) { say "hit" }
        }
        dispatch ($subject) {
            on (' . $qualifier . '{absent => _, ...}) { say "wrong" }
            on (_) { say "miss" }
        }
        say $Values::exists;
    ', "hit\nmiss\n2");
}

check_case('empty shapes distinguish container kinds and reject contents', q{
    for my $v ([], {}, [undef], {a => undef}, undef, '', 0, sub {}) {
        dispatch ($v) {
            on ([]) { say 'array' }
            on ({}) { say 'hash' }
            on (_)  { say 'miss' }
        }
    }
}, "array\nhash\n" . join("\n", ('miss') x 6));

check_case('empty shapes nest and participate in open-array searches', q{
    dispatch ([1, [[], {}], 2]) {
        on ([..., [[], {}], ...]) { say 'nested' }
    }
    dispatch ({a => [], b => {}}) {
        on ({a => [], b => {}}) { say 'fields' }
    }
    dispatch ([]) {
        on ([] if 0) { say 'wrong' }
        on ([])     { say 'guard' }
    }
}, "nested\nfields\nguard");

check_case('class-qualified empty shapes require the exact class and kind', q{
    for my $v (bless([], 'Box'), bless({}, 'Box'),
               bless([1], 'Box'), bless({a => 1}, 'Box'),
               bless([], 'Other'), [], {}) {
        dispatch ($v) {
            on (Box []) { say 'array' }
            on (Box {}) { say 'hash' }
            on (_)      { say 'miss' }
        }
    }
}, "array\nhash\n" . join("\n", ('miss') x 5));

check_case('empty native-class shapes use the field view', q{
    use feature 'class';
    no warnings 'experimental::class';
    class Empty {}
    class Full { field $x = 1; }
    dispatch (Empty->new) {
        on (Empty {}) { say 'empty' }
    }
    dispatch (Full->new) {
        on (Full {}) { say 'wrong' }
        on (_)       { say 'full' }
    }
}, "empty\nfull");

check_case('empty tied shapes inspect size or keys but never fetch values', q{
    {
        package Array;
        sub TIEARRAY { bless [$_[1]], $_[0] }
        sub FETCHSIZE { $_[0][0] }
        sub FETCH { die 'unexpected array FETCH' }
        package Hash;
        sub TIEHASH { bless [$_[1]], $_[0] }
        sub FIRSTKEY { $_[0][0] ? 'key' : undef }
        sub NEXTKEY { undef }
        sub FETCH { die 'unexpected hash FETCH' }
    }
    for my $size (0, 1) {
        tie my @a, 'Array', $size;
        tie my %h, 'Hash', $size;
        for my $v (\@a, \%h) {
            dispatch ($v) {
                on ([]) { say 'array' }
                on ({}) { say 'hash' }
                on (_)  { say 'full' }
            }
        }
    }
}, "array\nhash\nfull\nfull");

check_case('empty shape constraints skip unrelated capture fetches', q{
    { package Value; sub TIEARRAY { bless {}, shift }
      sub FETCHSIZE { 2 }
      sub FETCH { die 'capture fetched' if $_[1] == 0; [1] } }
    tie my @values, 'Value';
    dispatch (\@values) {
        on ([$x, []]) { say 'wrong' }
        on (_)       { say 'miss' }
    }
}, 'miss');

check_case('duplicate capture declarations are rejected across shape kinds', q{
    for my $shape (
        '[$x, $x]',
        '[$x, "x" . $x]',
        '["x" . $x, $x]',
        '{a => $x, b => [$x]}',
        '[$x = RefVal(), $x]',
        '[$x = BlessedVal(), $x = BlessedVal()]',
        '[$x = DefinedVal(), $x = DefinedVal()]',
        '[$x = Int(), $x = Number()]',
        '[[ @tail ], [ @tail ]]',
        '[Box {a => $x}, Box {b => $x}]',
    ) {
        eval 'dispatch ([]) { on (' . $shape . ') { die "executed" } }';
        die "wrong error: $@" unless
            $@ =~ /duplicate capture [\$\@](?:x|tail) in a dispatch-on clause/;
        say 'rejected';
    }
}, join("\n", ('rejected') x 10));

check_case('pins, guards, and separate clauses can reuse variable names', q{
    my $x = 'a';
    dispatch (['a', 'b']) {
        on ([^$x, $x]) { say "with,$x" }
    }
    dispatch (['a', 'a']) {
        on ([^$x, ^$x]) { say 'caret' }
    }
    dispatch (['a', 'a']) {
        on ([$x, $y] if $x eq $y) { say "$x,$x" }
    }
    dispatch (['b']) {
        on ([$x] if 0) { say 'wrong' }
        on ([$x])      { say $x }
    }
}, "with,b\ncaret\na,a\nb");

check_case('duplicate captures report the name and offending source line', q{
    use utf8;
    eval qq{#line 40 "duplicate-shape"
dispatch ([]) {
    on ([\$résultat,
            \$résultat]) { }
}};
    die "wrong diagnostic: $@" unless
        $@ =~ /duplicate capture \$résultat in a dispatch-on clause at duplicate-shape line 42/;
    say 'located';
}, 'located');

check_case('scalar and array captures with the same basename are distinct', q{
    dispatch ([1, 2, 3]) {
        on ([$items, @items]) { say "$items:@items" }
    }
}, '1:2 3');

done_testing();
