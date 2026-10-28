#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use strict;
use warnings;
no warnings 'experimental::builtin';

require XPerl::Exception;
require XPerl::Diagnostic;
require B;

# Each descriptive target has a source example. These examples establish
# reachability, rather than limiting which future targets may be supported.
my $cases;
$cases = [
  [
    "add",
    "sub { no strict; no warnings;  (\$a + \$b) += 1 }",
    "addition (+)",
    "addition (+)"
  ],
  [
    "aeach",
    "sub { no strict; no warnings;  (each \@a) += 1 }",
    "each on array",
    "addition (+)"
  ],
  [
    "akeys",
    "sub { no strict; no warnings;  (keys \@a) += 1 }",
    "keys on array",
    "addition (+)"
  ],
  [
    "and",
    "sub { no strict; no warnings;  (\$a && \$b) += 1 }",
    "logical and (&&)",
    "addition (+)"
  ],
  [
    "anoncode",
    "sub { no strict; no warnings;  (sub {1}) += 1 }",
    "anonymous subroutine",
    "addition (+)"
  ],
  [
    "anonconst",
    "sub { no strict; no warnings;  (sub :const {\$a}) += 1 }",
    "anonymous constant",
    "addition (+)"
  ],
  [
    "anonhash",
    "sub { no strict; no warnings;  ({a=>\$a}) += 1 }",
    "anonymous hash ({})",
    "addition (+)"
  ],
  [
    "anonlist",
    "sub { no strict; no warnings;  ([\$a]) += 1 }",
    "anonymous array ([])",
    "addition (+)"
  ],
  [
    "anywhile",
    "sub { no strict; no warnings; use feature qw(keyword_any keyword_all); (any {\$a} \@a) += 1 }",
    "any/all iterator",
    "addition (+)"
  ],
  [
    "avalues",
    "sub { no strict; no warnings;  (values \@a) += 1 }",
    "values on array",
    "addition (+)"
  ],
  [
    "backtick",
    "sub { no strict; no warnings;  (qx[\$a]) += 1 }",
    "quoted execution (``, qx)",
    "addition (+)"
  ],
  [
    "bit_and",
    "sub { no strict; no warnings;  (\$a & \$b) += 1 }",
    "bitwise and (&)",
    "addition (+)"
  ],
  [
    "bit_or",
    "sub { no strict; no warnings;  (\$a | \$b) += 1 }",
    "bitwise or (|)",
    "addition (+)"
  ],
  [
    "bit_xor",
    "sub { no strict; no warnings;  (\$a ^ \$b) += 1 }",
    "bitwise xor (^)",
    "addition (+)"
  ],
  [
    "classname",
    "use experimental q[class]; class LvalueClassProbe { method example { __CLASS__ += 1 } }",
    "class name",
    "addition (+)"
  ],
  [
    "cmpchain_and",
    "sub { no strict; no warnings;  (\$a < \$b < \$c) += 1 }",
    "comparison chaining",
    "addition (+)"
  ],
  [
    "complement",
    "sub { no strict; no warnings;  (~\$a) += 1 }",
    "1's complement (~)",
    "addition (+)"
  ],
  [
    "concat",
    "sub { no strict; no warnings;  (\$a . \$b) += 1 }",
    "concatenation (.) or string",
    "addition (+)"
  ],
  [
    "const",
    "sub { no strict; no warnings;  (1) += 1 }",
    "constant item",
    "addition (+)"
  ],
  [
    "defined",
    "sub { no strict; no warnings;  (defined \$a) += 1 }",
    "defined operator",
    "addition (+)"
  ],
  [
    "divide",
    "sub { no strict; no warnings;  (\$a / \$b) += 1 }",
    "division (/)",
    "addition (+)"
  ],
  [
    "do_block",
    "sub { no strict; no warnings;  (do {\$a}) += 1 }",
    "do block",
    "addition (+)"
  ],
  [
    "dor",
    "sub { no strict; no warnings;  (\$a // \$b) += 1 }",
    "defined or (//)",
    "addition (+)"
  ],
  [
    "emptyavhv",
    "sub { no strict; no warnings;  ([]) += 1 }",
    "empty anon hash/array",
    "addition (+)"
  ],
  [
    "eq",
    "sub { no strict; no warnings;  (\$a == \$b) += 1 }",
    "numeric eq (==)",
    "addition (+)"
  ],
  [
    "equ",
    "sub { no strict; no warnings;  (\$a === \$b) += 1 }",
    "undef-aware numeric eq (===)",
    "addition (+)"
  ],
  [
    "flop",
    "sub { no strict; no warnings;  ((\$a..\$b)) += 1 }",
    "range (or flop)",
    "addition (+)"
  ],
  [
    "ge",
    "sub { no strict; no warnings;  (\$a >= \$b) += 1 }",
    "numeric ge (>=)",
    "addition (+)"
  ],
  [
    "gelem",
    "sub { no strict; no warnings;  (*x{SCALAR}) += 1 }",
    "glob elem",
    "addition (+)"
  ],
  [
    "grepwhile",
    "sub { no strict; no warnings;  (grep {\$a} \@a) += 1 }",
    "grep iterator",
    "addition (+)"
  ],
  [
    "gt",
    "sub { no strict; no warnings;  (\$a > \$b) += 1 }",
    "numeric gt (>)",
    "addition (+)"
  ],
  [
    "i_add",
    "sub { no strict; no warnings; use integer; (\$a + \$b) += 1 }",
    "integer addition (+)",
    "addition (+)"
  ],
  [
    "i_divide",
    "sub { no strict; no warnings; use integer; (\$a / \$b) += 1 }",
    "integer division (/)",
    "addition (+)"
  ],
  [
    "i_eq",
    "sub { no strict; no warnings; use integer; (\$a == \$b) += 1 }",
    "integer eq (==)",
    "addition (+)"
  ],
  [
    "i_equ",
    "sub { no strict; no warnings; use integer; (\$a === \$b) += 1 }",
    "undef-aware integer eq (===)",
    "addition (+)"
  ],
  [
    "i_ge",
    "sub { no strict; no warnings; use integer; (\$a >= \$b) += 1 }",
    "integer ge (>=)",
    "addition (+)"
  ],
  [
    "i_gt",
    "sub { no strict; no warnings; use integer; (\$a > \$b) += 1 }",
    "integer gt (>)",
    "addition (+)"
  ],
  [
    "i_le",
    "sub { no strict; no warnings; use integer; (\$a <= \$b) += 1 }",
    "integer le (<=)",
    "addition (+)"
  ],
  [
    "i_lt",
    "sub { no strict; no warnings; use integer; (\$a < \$b) += 1 }",
    "integer lt (<)",
    "addition (+)"
  ],
  [
    "i_modulo",
    "sub { no strict; no warnings; use integer; (\$a % \$b) += 1 }",
    "integer modulus (%)",
    "addition (+)"
  ],
  [
    "i_multiply",
    "sub { no strict; no warnings; use integer; (\$a * \$b) += 1 }",
    "integer multiplication (*)",
    "addition (+)"
  ],
  [
    "i_ncmp",
    "sub { no strict; no warnings; use integer; (\$a <=> \$b) += 1 }",
    "integer comparison (<=>)",
    "addition (+)"
  ],
  [
    "i_ne",
    "sub { no strict; no warnings; use integer; (\$a != \$b) += 1 }",
    "integer ne (!=)",
    "addition (+)"
  ],
  [
    "i_negate",
    "sub { no strict; no warnings; use integer; (-\$a) += 1 }",
    "integer negation (-)",
    "addition (+)"
  ],
  [
    "i_neu",
    "sub { no strict; no warnings; use integer; (\$a !== \$b) += 1 }",
    "undef-aware integer ne (!==)",
    "addition (+)"
  ],
  [
    "i_postdec",
    "sub { no strict; no warnings; use integer; (\$a--) += 1 }",
    "integer postdecrement (--)",
    "addition (+)"
  ],
  [
    "i_postinc",
    "sub { no strict; no warnings; use integer; (\$a++) += 1 }",
    "integer postincrement (++)",
    "addition (+)"
  ],
  [
    "i_predec",
    "sub { no strict; no warnings; use integer; (--\$a) += 1 }",
    "integer predecrement (--)",
    "addition (+)"
  ],
  [
    "i_preinc",
    "sub { no strict; no warnings; use integer; (++\$a) += 1 }",
    "integer preincrement (++)",
    "addition (+)"
  ],
  [
    "i_subtract",
    "sub { no strict; no warnings; use integer; (\$a - \$b) += 1 }",
    "integer subtraction (-)",
    "addition (+)"
  ],
  [
    "implements",
    "use experimental q[class]; role LvalueRoleProbe {} sub { my \$a; (\$a implements LvalueRoleProbe) += 1 }",
    "role composition test",
    "addition (+)"
  ],
  [
    "is_bool",
    "sub { no strict; no warnings;  (builtin::is_bool(\$a)) += 1 }",
    "boolean type test",
    "addition (+)"
  ],
  [
    "is_weak",
    "sub { no strict; no warnings;  (builtin::is_weak(\$a)) += 1 }",
    "weakref type test",
    "addition (+)"
  ],
  [
    "isa",
    "sub { no strict; no warnings; use feature q[isa]; (\$a isa X) += 1 }",
    "derived class test",
    "addition (+)"
  ],
  [
    "join",
    "sub { no strict; no warnings;  (join(\$a,\@a)) += 1 }",
    "join or string",
    "addition (+)"
  ],
  [
    "kvaslice",
    "sub { no strict; no warnings;  (%a[0]) += 1 }",
    "index/value array slice",
    "addition (+)"
  ],
  [
    "kvhslice",
    "sub { no strict; no warnings;  (%h{a}) += 1 }",
    "key/value hash slice",
    "addition (+)"
  ],
  [
    "le",
    "sub { no strict; no warnings;  (\$a <= \$b) += 1 }",
    "numeric le (<=)",
    "addition (+)"
  ],
  [
    "left_shift",
    "sub { no strict; no warnings;  (\$a << \$b) += 1 }",
    "left bitshift (<<)",
    "addition (+)"
  ],
  [
    "lslice",
    "sub { no strict; no warnings;  ((\$a, \$b)[0]) += 1 }",
    "list slice",
    "addition (+)"
  ],
  [
    "lt",
    "sub { no strict; no warnings;  (\$a < \$b) += 1 }",
    "numeric lt (<)",
    "addition (+)"
  ],
  [
    "mapwhile",
    "sub { no strict; no warnings;  (map {\$a} \@a) += 1 }",
    "map iterator",
    "addition (+)"
  ],
  [
    "match",
    "sub { no strict; no warnings;  (\$a =~ /a/) += 1 }",
    "pattern match (m//)",
    "addition (+)"
  ],
  [
    "modulo",
    "sub { no strict; no warnings;  (\$a % \$b) += 1 }",
    "modulus (%)",
    "addition (+)"
  ],
  [
    "multiply",
    "sub { no strict; no warnings;  (\$a * \$b) += 1 }",
    "multiplication (*)",
    "addition (+)"
  ],
  [
    "nbit_and",
    "sub { no strict; no warnings; use feature q[bitwise]; (\$a & \$b) += 1 }",
    "numeric bitwise and (&)",
    "addition (+)"
  ],
  [
    "nbit_or",
    "sub { no strict; no warnings; use feature q[bitwise]; (\$a | \$b) += 1 }",
    "numeric bitwise or (|)",
    "addition (+)"
  ],
  [
    "nbit_xor",
    "sub { no strict; no warnings; use feature q[bitwise]; (\$a ^ \$b) += 1 }",
    "numeric bitwise xor (^)",
    "addition (+)"
  ],
  [
    "ncmp",
    "sub { no strict; no warnings;  (\$a <=> \$b) += 1 }",
    "numeric comparison (<=>)",
    "addition (+)"
  ],
  [
    "ncomplement",
    "sub { no strict; no warnings; use feature q[bitwise]; (~\$a) += 1 }",
    "numeric 1's complement (~)",
    "addition (+)"
  ],
  [
    "ne",
    "sub { no strict; no warnings;  (\$a != \$b) += 1 }",
    "numeric ne (!=)",
    "addition (+)"
  ],
  [
    "negate",
    "sub { no strict; no warnings;  (-\$a) += 1 }",
    "negation (-)",
    "addition (+)"
  ],
  [
    "neu",
    "sub { no strict; no warnings;  (\$a !== \$b) += 1 }",
    "undef-aware numeric ne (!==)",
    "addition (+)"
  ],
  [
    "or",
    "sub { no strict; no warnings;  (\$a || \$b) += 1 }",
    "logical or (||)",
    "addition (+)"
  ],
  [
    "padav",
    "sub { no strict; no warnings; my (\$a,\$b,\$c); my (\@a,%h); (\@a) += 1 }",
    "private array",
    "addition (+)"
  ],
  [
    "padhv",
    "sub { no strict; no warnings; my (\$a,\$b,\$c); my (\@a,%h); (%h) += 1 }",
    "private hash",
    "addition (+)"
  ],
  [
    "postdec",
    "sub { no strict; no warnings;  (\$a--) += 1 }",
    "postdecrement (--)",
    "addition (+)"
  ],
  [
    "postinc",
    "sub { no strict; no warnings;  (\$a++) += 1 }",
    "postincrement (++)",
    "addition (+)"
  ],
  [
    "pow",
    "sub { no strict; no warnings;  (\$a ** \$b) += 1 }",
    "exponentiation (**)",
    "addition (+)"
  ],
  [
    "predec",
    "sub { no strict; no warnings;  (--\$a) += 1 }",
    "predecrement (--)",
    "addition (+)"
  ],
  [
    "preinc",
    "sub { no strict; no warnings;  (++\$a) += 1 }",
    "preincrement (++)",
    "addition (+)"
  ],
  [
    "prototype",
    "sub { no strict; no warnings;  (prototype \$a) += 1 }",
    "subroutine prototype",
    "addition (+)"
  ],
  [
    "qr",
    "sub { no strict; no warnings;  (qr[\$a]) += 1 }",
    "pattern quote (qr//)",
    "addition (+)"
  ],
  [
    "ref",
    "sub { no strict; no warnings;  (ref \$a) += 1 }",
    "reference-type operator",
    "addition (+)"
  ],
  [
    "ref_cmp",
    "sub { no strict; no warnings;  (ref \$a eq q[ARRAY]) += 1 }",
    "reference-type comparison",
    "addition (+)"
  ],
  [
    "refassign",
    "sub { no strict; no warnings; use feature q[refaliasing]; ((\\\$a = \$b)) += 1 }",
    "lvalue ref assignment",
    "addition (+)"
  ],
  [
    "refgen",
    "sub { no strict; no warnings;  (\\(\$a, \$b)) += 1 }",
    "reference constructor",
    "addition (+)"
  ],
  [
    "repeat",
    "sub { no strict; no warnings;  (\$a x \$b) += 1 }",
    "repeat (x)",
    "addition (+)"
  ],
  [
    "reset",
    "sub { no strict; no warnings;  (reset \$a) += 1 }",
    "symbol reset",
    "addition (+)"
  ],
  [
    "right_shift",
    "sub { no strict; no warnings;  (\$a >> \$b) += 1 }",
    "right bitshift (>>)",
    "addition (+)"
  ],
  [
    "rv2av",
    "sub { no strict; no warnings;  (\@a) += 1 }",
    "array dereference",
    "addition (+)"
  ],
  [
    "rv2gv",
    "sub { no strict; no warnings;  (*{\$a}) += 1 }",
    "ref-to-glob cast",
    "addition (+)"
  ],
  [
    "rv2hv",
    "sub { no strict; no warnings;  (%h) += 1 }",
    "hash dereference",
    "addition (+)"
  ],
  [
    "sbit_and",
    "sub { no strict; no warnings; use feature q[bitwise]; (\$a &. \$b) += 1 }",
    "string bitwise and (&.)",
    "addition (+)"
  ],
  [
    "sbit_or",
    "sub { no strict; no warnings; use feature q[bitwise]; (\$a |. \$b) += 1 }",
    "string bitwise or (|.)",
    "addition (+)"
  ],
  [
    "sbit_xor",
    "sub { no strict; no warnings; use feature q[bitwise]; (\$a ^. \$b) += 1 }",
    "string bitwise xor (^.)",
    "addition (+)"
  ],
  [
    "schomp",
    "sub { no strict; no warnings;  (chomp \$a) += 1 }",
    "scalar chomp",
    "addition (+)"
  ],
  [
    "schop",
    "sub { no strict; no warnings;  (chop \$a) += 1 }",
    "scalar chop",
    "addition (+)"
  ],
  [
    "scmp",
    "sub { no strict; no warnings;  (\$a cmp \$b) += 1 }",
    "string comparison (cmp)",
    "addition (+)"
  ],
  [
    "scomplement",
    "sub { no strict; no warnings; use feature q[bitwise]; (~. \$a) += 1 }",
    "string 1's complement (~)",
    "addition (+)"
  ],
  [
    "seq",
    "sub { no strict; no warnings;  (\$a eq \$b) += 1 }",
    "string eq",
    "addition (+)"
  ],
  [
    "sequ",
    "sub { no strict; no warnings;  (\$a equ \$b) += 1 }",
    "undef-aware string eq",
    "addition (+)"
  ],
  [
    "sge",
    "sub { no strict; no warnings;  (\$a ge \$b) += 1 }",
    "string ge",
    "addition (+)"
  ],
  [
    "sgt",
    "sub { no strict; no warnings;  (\$a gt \$b) += 1 }",
    "string gt",
    "addition (+)"
  ],
  [
    "sle",
    "sub { no strict; no warnings;  (\$a le \$b) += 1 }",
    "string le",
    "addition (+)"
  ],
  [
    "slt",
    "sub { no strict; no warnings;  (\$a lt \$b) += 1 }",
    "string lt",
    "addition (+)"
  ],
  [
    "smartmatch",
    "sub { no strict; no warnings;  (\$a ~~ \$b) += 1 }",
    "smart match",
    "addition (+)"
  ],
  [
    "sne",
    "sub { no strict; no warnings;  (\$a ne \$b) += 1 }",
    "string ne",
    "addition (+)"
  ],
  [
    "sneu",
    "sub { no strict; no warnings;  (\$a neu \$b) += 1 }",
    "undef-aware string ne",
    "addition (+)"
  ],
  [
    "srefgen",
    "sub { no strict; no warnings;  (\\\$a) += 1 }",
    "single ref constructor",
    "addition (+)"
  ],
  [
    "sselect",
    "sub { no strict; no warnings;  (select(\$a,\$b,\$c,0)) += 1 }",
    "select system call",
    "addition (+)"
  ],
  [
    "stringify",
    "sub { no strict; no warnings;  (qq[\$a]) += 1 }",
    "string",
    "addition (+)"
  ],
  [
    "subst",
    "sub { no strict; no warnings;  (\$a =~ s/a/b/) += 1 }",
    "substitution (s///)",
    "addition (+)"
  ],
  [
    "subtract",
    "sub { no strict; no warnings;  (\$a - \$b) += 1 }",
    "subtraction (-)",
    "addition (+)"
  ],
  [
    "trans",
    "sub { no strict; no warnings;  (\$a =~ tr/a/b/) += 1 }",
    "transliteration (tr///)",
    "addition (+)"
  ],
  [
    "transr",
    "sub { no strict; no warnings;  (\$a =~ tr/a/b/r) += 1 }",
    "transliteration (tr///)",
    "addition (+)"
  ],
  [
    "undef",
    "sub { undef = 1 }",
    "undef operator",
    "scalar assignment"
  ],
  [
    "unweaken",
    "sub { no strict; no warnings;  (builtin::unweaken(\$a)) += 1 }",
    "reference unweaken",
    "addition (+)"
  ],
  [
    "weaken",
    "sub { no strict; no warnings;  (builtin::weaken(\$a)) += 1 }",
    "reference weaken",
    "addition (+)"
  ],
  [
    "xor",
    "sub { no strict; no warnings;  (\$a xor \$b) += 1 }",
    "logical xor",
    "addition (+)"
  ],
  [
    "yield",
    "use generator; my \$g = gen { (yield 1) += 1 };",
    "yield values from a generator",
    "addition (+)"
  ]
];

my $metadata = builtin::get_diagnostic_data(1419);
is( scalar @{ $metadata->{selectors} }, 0,
    'operation identity does not consume a grammatical selector' );

for my $case (@$cases) {
    my ( $target_name, $source, $target, $context ) = @$case;
    eval $source;
    my $exception = ${^ERROR_OBJ};
    ok( $@, "$target_name example fails compilation" );
    my ($diagnostic) = ref($exception)
      ? grep { $_->number == 1419 } @{ $exception->contents }
      : ();
    ok( $diagnostic, "$target_name uses the modification target diagnostic" );
    next unless $diagnostic;

    my %params = map { $_->{name} => $_->{value} } @{ $diagnostic->params };
    if ($target_name eq 'do_block') {
        ok( $params{target_operation} > 0, 'do block retains its synthetic operation identity' );
    } else {
        is( $params{target_operation}, 1 + B::opnumber($target_name),
            "$target_name retains its operation identity" );
    }
    is( $params{target}, $target, "$target_name preserves its target text" );
    is( $params{context}, $context, "$target_name preserves its context" );
    like( $diagnostic->render_as_legacy('en'),
        qr/\ACan't modify \Q$target\E in \Q$context\E at /,
        "$target_name preserves its English wording" );
}

done_testing();
