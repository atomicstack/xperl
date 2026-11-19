#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin, "$FindBin::Bin/../../Porting";
use SourceOwners qw(definition_index enclosing_definition);
use ClassTree qw(template_cases);
use SourceReference;
use BenchUtils qw(write_text);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Test::More;

my $source = <<'C';
#define TEST(x) do { \
    pretend(x); \
} while (0)
static int actual(int x) {
    const char *s = "not_a_function() { }";
    /* another_fake() { } */
    if (x) { return x; }
    return 0;
}
PP(pp_sample) {
    return 1;
}
static void unfinished(void) {
C
my $definitions = definition_index($source, 'fixture.c');
is_deeply(enclosing_definition($definitions, 2), {name => 'TEST', kind => 'macro'}, 'continued macro owns its body');
is_deeply(enclosing_definition($definitions, 7), {name => 'actual', kind => 'function'}, 'control flow and masked strings do not replace the enclosing function');
is_deeply(enclosing_definition($definitions, 11), {name => 'pp_sample', kind => 'function'}, 'PP wrapper exposes its opcode name');
is_deeply(enclosing_definition($definitions, 13), {name => '', kind => 'undetermined'}, 'unterminated definitions are not assigned to later lines');
my $xs = "void\nexample(int n)\n    CODE:\n        n++;\n\nMODULE = Demo PACKAGE = Demo\n";
is_deeply(enclosing_definition(definition_index($xs, 'fixture.xs'), 4),
    {name => 'example', kind => 'XS function'}, 'XS sections identify the enclosing XSUB');
is_deeply(enclosing_definition(definition_index($xs, 'fixture.xs'), 6),
    {name => '', kind => 'undetermined'}, 'a real MODULE directive ends the preceding XSUB');
is_deeply(template_cases({z => 'last', '*' => 'default', a => 'first'}, ['choice']), [
    {selectors => [['choice', 'a']], text => 'first'},
    {selectors => [['choice', 'z']], text => 'last'},
    {selectors => [['choice', '*']], text => 'default'},
], 'template selectors retain their names and put the default branch last');
my $valid = eval { template_cases({a => undef}, ['choice']); 1 };
ok(!$valid, 'an undefined selector branch is rejected');
is(SourceReference::checked_note({source_sha256 => 'old'}, 'new')->{status}, 'stale', 'changed sources invalidate review claims');
is(SourceReference::checked_note({source_sha256 => 'same'}, 'same')->{status}, 'focused-source-review', 'matching sources retain review provenance');
my $temporary = tempdir(CLEANUP => 1);
write_text("$temporary/rows.tsv", "code\tclass\na\tA\n\nb\tB\n");
is(scalar @{ClassTree::read_rows("$temporary/rows.tsv")}, 2, 'blank report lines do not become empty assignments');
SKIP: {
    skip 'byte-valued Unix filesystem path check', 2 if $^O =~ /\A(?:MSWin32|dos|os2)\z/;
    for my $case (["caf\xc3\xa9", 'caf%C3%A9'], ['back\\slash', 'back%5Cslash']) {
        my $root = "$temporary/$case->[0]";
        make_path("$root/planning");
        write_text("$root/planning/diagnostic-class-registry.tsv", "class\tparent\nXPerl::Root\t\n");
        write_text("$root/planning/diagnostic-error-family-proposal.tsv", "code\trecommendation\n");
        no warnings 'redefine';
        local *ClassTree::english_templates = sub { {} };
        local *ClassTree::source_contexts = sub {};
        like(ClassTree::tree_data("$root/planning")->{source_root}, qr{/\Q$case->[1]\E\z},
            'source links preserve and encode Unix filesystem bytes');
    }
}
done_testing();
