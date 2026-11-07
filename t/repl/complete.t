#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use v5.36;
use XPerl::REPL;
use XPerl::REPL::Input;
use XPerl::REPL::Complete;

sub is_deeply ($got, $expected, $name = undef) {
    is(join(' ', @$got), join(' ', @$expected), $name);
}

# complete(), checking that every word has a kind
my @KINDS = qw(command scalar array hash key package sub method keyword builtin hint);
sub checked ($repl, $buffer, $cursor) {
    my ($words, $start, $kinds) = XPerl::REPL::Complete::complete($repl, $buffer, $cursor);
    is(scalar @{ $kinds // [] }, scalar @$words, "kinds for every word of \"$buffer\"");
    my %known = map { $_ => 1 } @KINDS;
    ok(!grep({ !$known{$_} } @{ $kinds // [] }), "only known kinds for \"$buffer\"");
    return ($words, $start, $kinds);
}

open my $sink, '>', \my $results;
my $repl = XPerl::REPL->new(input => XPerl::REPL::Input::List->new(lines => []), out => $sink, err => \*STDERR);
$repl->step("my \$alpha = 1; my \@alist = (1); my %amap = (); 1\n");
$repl->step("package Zoo::Keeper; sub feed {} our \$count = 0; package main; 1\n");
$repl->step("package Zoo::Head; our \@ISA = ('Zoo::Keeper'); sub hire {} package main; 1\n");
my ($c, $s) = checked($repl, ':he', 3);
is_deeply($c, [':help']); is($s, 0);
($c, $s) = checked($repl, 'say $al', 7);
is_deeply($c, ['$alist', '$alpha'], 'lexicals, sorted'); is($s, 4);
($c) = checked($repl, '$am', 3); is_deeply($c, ['$amap'], 'hash completes from $ sigil as $amap (for $amap{)');
($c) = checked($repl, '@al', 3); is_deeply($c, ['@alist'], 'array sigil');
($c) = checked($repl, 'Zoo::K', 6); is_deeply($c, ['Zoo::Keeper']);
($c) = checked($repl, 'Zoo::Keeper::f', 14); is_deeply($c, ['Zoo::Keeper::feed']);
($c) = checked($repl, '$Zoo::Keeper::c', 15); is_deeply($c, ['$Zoo::Keeper::count'], 'package variable');
($c) = checked($repl, 'Zoo::Keeper->fe', 15); is_deeply($c, ['feed'], 'methods on class');
($c) = checked($repl, 'Zoo::Head->', 11); is_deeply($c, ['feed', 'hire'], 'inherited methods');
$repl->step("my \$zk = bless {}, 'Zoo::Keeper'\n");
($c) = checked($repl, '$zk->fe', 7); is_deeply($c, ['feed'], 'methods on object lexical');
($c) = checked($repl, 'whil', 4); is_deeply($c, ['while'], 'keyword');
($c) = checked($repl, 'ref', 3); ok((grep { $_ eq 'refaddr' } @$c), 'builtin');
($c) = checked($repl, 'xyzzy', 5); is_deeply($c, [], 'nothing');
($c) = checked($repl, 'say $alpha; whil', 16); is_deeply($c, ['while'], 'completes the word at the cursor only');
($c, $s) = checked($repl, 'whil; 1', 4); is_deeply($c, ['while'], 'text after the cursor is ignored'); is($s, 0);

# package main, the default package (t/test.pl defines subs there too,
# such as which_perl, so keyword tests above use "whil")
$repl->step("sub main_sub { 1 } our \$gcount = 1; our \@glist = (); 1\n");
($c) = checked($repl, 'main_s', 6); is_deeply($c, ['main_sub'], 'sub in main');
($c) = checked($repl, '$gco', 4); is_deeply($c, ['$gcount'], 'package scalar in main');
($c) = checked($repl, '@gli', 4); is_deeply($c, ['@glist'], 'package array in main');

# sources in spec order: package subs before keywords and builtins
$repl->step("sub printer { 1 } 1\n");
($c) = checked($repl, 'prin', 4); is_deeply($c, ['printer', 'print', 'printf'], 'subs before keywords');

# hash keys from live data, walking subscript chains
$repl->step(q{my %h = (alpha => 1, 'with space' => 2, "q'uote" => 3, beta => { inner => 1, in2 => [ { deep => 1 } ] }); my $r = \%h; our %pkgh = (pk => 1); my $s = 'str'; 1} . "\n");
sub keys_for ($text) { return checked($repl, $text, length $text) }
($c, $s) = keys_for('$h{'); is_deeply($c, ['alpha', 'beta', "'q\\'uote'", "'with space'"], 'hash keys, non-barewords single-quoted'); is($s, 3);
($c, $s) = keys_for('$h{al'); is_deeply($c, ['alpha'], 'hash keys by prefix'); is($s, 3);
($c, $s) = keys_for(q[$h{'wi]); is_deeply($c, ["'with space'"], 'typed single quote'); is($s, 3, 'start at the quote');
($c, $s) = keys_for(q[$h{"wi]); is_deeply($c, ['"with space"'], 'typed double quote'); is($s, 3);
($c) = keys_for('$r->{be'); is_deeply($c, ['beta'], 'hashref in a scalar');
($c) = keys_for('$h{beta}{in'); is_deeply($c, ['in2', 'inner'], 'nested hash');
($c) = keys_for('$r->{beta}->{in2}[0]{d'); is_deeply($c, ['deep'], 'chain through an array');
($c) = keys_for('$h{beta}{nope}{'); is_deeply($c, [], 'missing step');
($c) = keys_for('$s->{'); is_deeply($c, [], 'not a hashref');
($c) = keys_for('$pkgh{p'); is_deeply($c, ['pk'], 'package hash');
($c) = keys_for('$main::pkgh{p'); is_deeply($c, ['pk'], 'qualified package hash');
($c) = keys_for('$h{wh'); is_deeply($c, [], 'keys win over keywords');
($c, $s) = keys_for('$h{a}->'); is_deeply($c, [], 'no keys after a trailing arrow'); is($s, 7);
($c) = keys_for('%h{'); is_deeply($c, [], 'no keys for a key/value slice');

# array indexes: one candidate, the range of the live array's indexes
# ("0..$#array"), from the index typed so far when there is one
$repl->step(q{$h{b} = [10, 20]; my @ten = (1) x 12; my $ar = \@ten; my @none; 1} . "\n");
($c, $s) = keys_for('$h{b}['); is_deeply($c, ['0..1'], 'the index range of a nested array'); is($s, 6);
($c, $s) = keys_for('$h{beta}{in2}['); is_deeply($c, ['0'], 'a one-element array: its only index');
($c, $s) = keys_for('$ten['); is_deeply($c, ['0..11'], 'lexical array');
($c, $s) = keys_for('$ten[3'); is_deeply($c, ['3..11'], 'from the typed index'); is($s, 5);
($c) = keys_for('$ten[11'); is_deeply($c, ['11'], 'the typed index is the last');
($c) = keys_for('$ten[12'); is_deeply($c, [], 'past the end');
($c) = keys_for('$none['); is_deeply($c, [], 'an empty array');
($c) = keys_for('$ar->['); is_deeply($c, ['0..11'], 'array ref');
($c) = keys_for('$h{b}->['); is_deeply($c, ['0..1'], 'with an arrow');
($c) = keys_for('$h{alpha}['); is_deeply($c, [], 'not an array');
($c) = keys_for('$h{$k}['); is_deeply($c, [], 'variable subscript: nothing');
($c) = keys_for('$r->{beta}{in2}[0]{'); is_deeply($c, ['deep'], 'hash keys after an index still work');
is_deeply(kinds_of('$h{b}['), ['hint'], 'an index range is a hint');
{
    my ($w, $st, $k) = keys_for('$ten[3');
    is(join('|', @$w, $st, @$k), '3..11|5|hint', '$ten[3: the range, the start, the hint kind');
}

# a tied scalar on the way would run user code (FETCH): the walk stops
$repl->step(q{package DieTie { sub TIESCALAR { bless {}, shift } sub FETCH { die "FETCH ran\n" } } my %th = (a => 1); tie $th{t}, q(DieTie); tie my $ts, q(DieTie); my @ta = (1); tie $ta[0], q(DieTie); 1} . "\n");
for my $text ('$ts->{', '$th{t}{', '$ta[0]{') {
    my @got = eval { keys_for($text) };
    is($@, '', "$text: no user code runs");
    is_deeply($got[0] // ['died'], [], "$text: no candidates");
}

# subscripts that are not literals: no keys, and no keywords either
($c, $s) = keys_for('$h{$k}{wh'); is_deeply($c, [], 'variable subscript'); is($s, 9);
($c) = keys_for('$h{ beta }{wh'); is_deeply($c, [], 'spaced subscript');
($c) = keys_for('$r->meth->{wh'); is_deeply($c, [], 'subscript after a method call');
($c) = keys_for('$h[0]{wh'); is_deeply($c, [], 'after a missing array element');
($c) = keys_for('if (1) {whil'); is_deeply($c, ['while'], 'a block still completes keywords');

# package names and symbols after a trailing ::, and a typed package name
# that is complete descends into it
$repl->step("use Data::Dumper (); 1\n");
($c, $s) = keys_for('Data::'); is_deeply($c, ['Data::Dumper'], 'a trailing :: lists the packages under it'); is($s, 0);
($c, $s) = keys_for('Data::Dumper::'); ok((grep { $_ eq 'Data::Dumper::Dumper' } @$c), 'and the subs in it'); is($s, 0);
($c, $s) = keys_for('$Data::Dumper::'); ok((grep { $_ eq '$Data::Dumper::Indent' } @$c), 'and its package variables after a sigil'); is($s, 0);
($c, $s) = keys_for(''); is_deeply($c, [], 'an empty buffer completes nothing');
($c, $s) = keys_for('Data'); is_deeply($c, ['Data::'], 'a complete package name descends with ::'); is($s, 0);
($c) = keys_for('Zoo::K'); is_deeply($c, ['Zoo::Keeper'], 'a partial package name has no ::');
($c) = keys_for('Zoo::Keeper'); is_deeply($c, ['Zoo::Keeper::'], 'a complete nested package name descends');
($c) = keys_for('Zoo::Keeper::'); ok((grep { $_ eq 'Zoo::Keeper::feed' } @$c), 'then lists its subs');
($c) = keys_for('Nonexistent::'); is_deeply($c, [], 'an unknown package lists nothing');
ok(!exists $main::{'Nonexistent::'}, 'and is not created');
($c) = keys_for('Nonexisten'); is_deeply($c, [], 'so it is not offered afterwards');
$repl->step("sub Zoo::Keeper { 1 } 1\n");
($c) = keys_for('Zoo::Keeper'); is_deeply($c, ['Zoo::Keeper', 'Zoo::Keeper::'], 'a name that is a sub and a package offers both');
# kinds by source
sub kinds_of ($text) { return (checked($repl, $text, length $text))[2] }
is_deeply(kinds_of(':he'), ['command'], 'command kind');
is_deeply(kinds_of('$al'), [qw(array scalar)], 'lexicals by what they name: $alist is an array, $alpha a scalar');
is_deeply(kinds_of('$am'), ['hash'], 'a hash offered as $amap is a hash');
is_deeply(kinds_of('@al'), ['array'], 'array sigil');
is_deeply(kinds_of('$h{al'), ['key'], 'hash keys');
is_deeply(kinds_of('Data::'), ['package'], 'package names');
is_deeply(kinds_of('Zoo::Keeper::f'), ['sub'], 'package subs');
is_deeply(kinds_of('$Zoo::Keeper::c'), ['scalar'], 'package scalar');
is_deeply(kinds_of('$zk->fe'), ['method'], 'methods');
is_deeply(kinds_of('whil'), ['keyword'], 'keywords');
{
    my ($w, undef, $k) = checked($repl, 'ref', 3);
    my %kind; @kind{@$w} = @$k;
    is($kind{refaddr}, 'builtin', 'builtin:: functions are builtins');
    is($kind{ref}, 'keyword', 'and ref a keyword');
}
done_testing;
