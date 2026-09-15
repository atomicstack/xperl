#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc( qw(. ../lib) );
}

plan(4);

# This is one small program, rather than a collection of isolated parser
# checks.  One dispatch classifies a mixed stream whose values have different
# shapes.  More-specific clauses come before broader open shapes.
sub same_array {
    my ($got, $expected) = @_;
    return 0 unless @$got == @$expected;
    for my $i (0 .. $#$got) {
        return 0 unless defined($got->[$i]) && defined($expected->[$i])
            ? $got->[$i] eq $expected->[$i]
            : !defined($got->[$i]) && !defined($expected->[$i]);
    }
    return 1;
}

my ($showcase_ok, $showcase_error) = (0, '');
my $showcase_ran = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    use builtin qw(true false);

    my $showcase_pin = '__not_in_examples__';
    my ($showcase_status, $showcase_code) = ('ok', 200);

    sub classify {
        my ($value) = @_;

        dispatch my $subject ($value) {
            # Scalar shapes and scalar concatenation.
            on (^$showcase_pin)                { 'pinned value' }
            on (undef)                         { 'undefined' }
            on (0)                             { 'zero' }
            on (42 if $subject > 40)           { 'guard accepted 42' }
            on (42)                            { 'the number 42' }
            on ('guarded' if $subject eq 'not guarded')
                                                  { 'guard should not pass' }
            on ('guarded')                     { 'guard fell through' }
            on ('plain')                       { 'the string plain' }
            on (/^user: (?<regex_user>\w+)$/)  { "regex <$regex_user/$1/$+{regex_user}>" }
            on ('prefix_' . $inner . '_suffix'){ "inside <$inner>" }
            on ('prefix_' . $suffix)           { "suffix <$suffix>" }
            on ($prefix . '_suffix')           { "prefix <$prefix>" }

            # Nested arrays, open arrays, and array slurps.
            on ([ 'point', $x, $y ])           { "point ($x,$y)" }
            on ([ { name => $first },
                     { name => $second } ])       { "nested <$first/$second>" }
            on ([ ..., 'foo_' . $inside . '_bar', ... ])
                                                  { "floating <$inside>" }
            on ([ 'pair', $head, @tail ])    { "pair <$head;" . join(',', @tail) . '>' }
            on ([ { kind => 'point', x => $x, y => $y }, ... ])
                                                  { "point record ($x,$y)" }
            on ([ 0, ... ])                    { 'array starts with <0>' }
            on ([ ..., $last ])                { "ends <\$last=$last>" }

            # Hash shapes, including caret-pinned and open hashes.
            on ({ kind => 'point',
                     x => $x, y => $y })          { "point hash ($x,$y)" }
            on ({ status => ^$showcase_status,
                     code => ^$showcase_code })   { 'pinned status' }
            on ({ status => 'ok',
                     code => $code, ... })        { "open status <$code>" }
            on ({ status => $status, ... })    { "any status <$status>" }
            on ({ kind => 'user',
                     name => $name, ... })        { "user <$name>" }

            # Type criteria, guards, references, and the wildcard default.
            on ($object = BlessedVal())            { 'object ' . ref($object) }
            on ($reference = RefVal())            { 'reference ' . ref($reference) }
            on ($scalar = NonRefVal()
                   if $scalar eq 'plain scalar')  { 'plain scalar' }
            on (_)                             { "unknown <$subject>" }
        }
    }

    my @values = (
    undef,
    0,
    42,
    'guarded',
    'plain',
    'user: Ada',
    '__not_in_examples__',
    'prefix_middle_suffix',
    'prefix_tail',
    'head_suffix',
    [ 'point', 3, 4 ],
    [ { name => 'first' }, { name => 'second' } ],
    [ 'before', 'foo_middle_bar', 'after' ],
    [ 'pair', 'left', 'middle', 'right' ],
    [ 0, 8, 9 ],
    [ 'tail', 8, 9 ],
    [ { kind => 'point', x => 8, y => 13 }, { extra => 1 } ],
    { kind => 'point', x => 3, y => 4 },
    { status => 'ok', code => 200 },
    { status => 'ok', code => 201, detail => 'created' },
    { status => 'queued', id => 10 },
    { kind => 'user', name => 'Ada', active => true },
    bless({}, 'Example::Widget'),
    \ 'an ordinary scalar reference',
    'plain scalar',
        'something else',
    );

    my @got = map { classify($_) } @values;
    my @expected = (
        'undefined',
        'zero',
        'guard accepted 42',
        'guard fell through',
        'the string plain',
        'regex <Ada/Ada/Ada>',
        'pinned value',
        'inside <middle>',
        'suffix <tail>',
        'prefix <head>',
        'point (3,4)',
        'nested <first/second>',
        'floating <middle>',
        'pair <left;middle,right>',
        'array starts with <0>',
        'ends <$last=9>',
        'point record (8,13)',
        'point hash (3,4)',
        'pinned status',
        'open status <201>',
        'any status <queued>',
        'user <Ada>',
        'object Example::Widget',
        'reference SCALAR',
        'plain scalar',
        'unknown <something else>',
    );
    $showcase_ok = same_array(\@got, \@expected);
    1;
};
$showcase_error = $@ unless $showcase_ran;
diag $showcase_error unless $showcase_ran;
ok($showcase_ran && $showcase_ok,
    'one dispatch classifies a mixed stream of scalar and structured values');

my ($boolean_ok, $boolean_error) = (0, '');
my $boolean_ran = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    use builtin qw(true false);
    $boolean_ok = same_array(
        [
            do { dispatch (true) { on (true) { 'true' } on (false) { 'false' } } },
            do { dispatch (false) { on (true) { 'true' } on (false) { 'false' } } },
            do { dispatch ('0') { on (True()) { 'true' } on (False()) { 'false' } } },
            do { dispatch ('yes') { on (true) { 'boolean' } on (True()) { 'truthy' } } },
        ],
        [ 'true', 'false', 'false', 'truthy' ],
    );
    1;
};
$boolean_error = $@ unless $boolean_ran;
diag $boolean_error unless $boolean_ran;
ok($boolean_ran && $boolean_ok,
    'lowercase boolean values and uppercase truth tests are distinct');

my ($subject_expression_ok, $subject_expression_error) = (0, '');
my $subject_expression_ran = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    $subject_expression_ok = do { dispatch (int('12')) {
        on (12) { 'integer' }
        on (_)  { 'other' }
    } } eq 'integer';
    1;
};
$subject_expression_error = $@ unless $subject_expression_ran;
diag $subject_expression_error unless $subject_expression_ran;
ok($subject_expression_ran && $subject_expression_ok,
    'dispatch accepts ordinary Perl expressions as subjects');

my ($empty_ok, $empty_error) = (0, '');
my $empty_ran = eval q{
    use feature 'dispatch_on';
    use dispatch::Predicates;
    $empty_ok = !defined(do { dispatch ('not listed') { on (1) { 'wrong' } } });
    1;
};
$empty_error = $@ unless $empty_ran;
diag $empty_error unless $empty_ran;
ok($empty_ran && $empty_ok,
    'a dispatch with no matching clause returns undef');
