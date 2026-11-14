#!./perl
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}
use strict;
use warnings;
use Scalar::Util ();
use XPerl::Diagnostic::Catalog;

my $definition = {
    namespace => 'CatalogTest',
    conditions => {
        EMPTY => {
            class => 'CatalogTest::Diagnostic::Empty',
            parent => 'XPerl::Diagnostic::Error::Numeric::Domain',
            severity => 'FATAL_ERROR',
            params => [{name => 'operation', type => 'text'}, {name => 'count', type => 'uv'}],
            templates => { en => 'No %{operation} for %{count} observations', de => 'Keine %{operation}: %{count}' },
        },
        CAUTION => {
            class => 'CatalogTest::Diagnostic::Caution',
            parent => 'XPerl::Diagnostic::Warning', severity => 'WARNING',
            params => [], templates => {en => 'Be careful'},
        },
        CONTEXT => {
            class => 'CatalogTest::Diagnostic::Context',
            parent => 'XPerl::Diagnostic::Note::Context', severity => 'NOTE',
            params => [{name => 'operation', type => 'text'}],
            templates => {en => 'During %{operation}'},
        },
    },
};
my $catalog = XPerl::Diagnostic::Catalog->_register($definition);
is(XPerl::Diagnostic::Catalog->_register($definition), $catalog,
    'identical declaration returns the registered catalog');
my $line = __LINE__ + 1;
my $diag = $catalog->diagnostic('EMPTY', operation => 'mean', count => 0);
is($diag->code, 'CatalogTest::EMPTY', 'module-qualified symbolic code');
ok(!defined $diag->number, 'no invented core number');
ok($diag->isa('XPerl::Diagnostic::Error::Numeric::Domain'), 'class inherits its declared domain');
is($diag->params->[0]{name}, 'operation', 'parameters keep declaration order');
is($diag->params->[1]{type}, 'uv', 'parameters keep declared types');
is($diag->location->{line}, $line, 'diagnostic captures the public caller');
like($diag->render_as_legacy('en'), qr/No mean for 0 observations/, 'English module template');
like($diag->render_as_legacy('de'), qr/Keine mean: 0/, 'explicit module translation');
like($diag->render_as_legacy('fr'), qr/No mean for 0 observations/, 'missing translation uses English');
my $annotated = XPerl::Exception->_new;
$annotated->append($diag);
like($annotated->render_as_annotated('de'), qr/Keine mean: 0/, 'annotated renderer uses module templates');
like($diag->as_json, qr/CatalogTest::EMPTY/, 'JSON retains the code');
like($diag->as_json, qr/"number":null/, 'JSON distinguishes module conditions from core IDs');
$definition->{conditions}{EMPTY}{templates}{en} = 'changed';
like($diag->render_as_legacy('en'), qr/No mean for 0 observations/, 'declaration changes do not affect captured templates');
eval { XPerl::Diagnostic::Catalog->_register($definition) };
like($@, qr/conflicting_definition/, 'conflicting registration is rejected');
my $copy = $diag->derive([]);
like($copy->render_as_legacy('de'), qr/Keine mean: 0/, 'derive retains the module descriptor');
eval { $catalog->{namespace} = 'changed' };
ok($@, 'catalog metadata is immutable');

for my $values ({operation => 'mean'}, {operation => 'mean', count => -1},
                {operation => 'mean', count => '0'}, {operation => [], count => 0}) {
    eval { $catalog->_capture('EMPTY', $values, __FILE__, __LINE__) };
    ok($@, 'invalid typed parameters are rejected');
}
eval { $catalog->diagnostic('UNKNOWN') };
like($@, qr/unknown_condition/, 'unknown condition is rejected');
my $exception = $catalog->exception('EMPTY', operation => 'mean', count => 0);
ok(!defined $exception->origin, 'construction does not invent a throw');
my ($caught, @hooks);
{
    local $SIG{__EXCEPT__} = sub { push @hooks, ['except', $_[0]] };
    local $SIG{__DIE__} = sub { push @hooks, ['die', ${^CUR_ERROR_OBJ}] };
    eval { $catalog->emit('EMPTY', operation => 'mean', count => 0) };
    $caught = $@;
}
ok(ref($caught) && $caught->isa('XPerl::Exception'), 'emit delivers a structured exception');
is($hooks[0][0], 'except', 'canonical hook runs first');
is($hooks[1][0], 'die', 'legacy fatal hook runs next');
is($hooks[0][1], $caught, 'canonical hook receives the caught object');
is($hooks[1][1], $caught, 'legacy hook exposes the same canonical object');
ok(defined $caught->origin, 'emit records its first origin');
my $origin = $caught->origin;
my $context = $catalog->diagnostic('CONTEXT', operation => 'bootstrap');
$caught->append($context);
eval { die $caught };
is($@, $caught, 'rethrow preserves exception identity');
is($caught->origin->{line}, $origin->{line}, 'context does not replace the first origin');
ok($caught->contains($context), 'rethrow retains the appended context');
my $note = $catalog->diagnostic('CONTEXT', operation => 'bootstrap');
eval { $note->append($diag) };
ok($@, 'module context notes remain leaf-only');
my @warnings;
{
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    $catalog->emit('CAUTION');
}
is(scalar @warnings, 1, 'warning condition follows warning delivery');
like($warnings[0], qr/Be careful/, 'warning renders its module template');

my $lexical;
{
    use diagpack 'de';
    $lexical = $catalog->diagnostic('EMPTY', operation => 'mean', count => 0);
}
like($lexical->render, qr/Keine mean: 0/, 'module diagnostic retains the caller lexical language');
like($lexical->render_as_legacy('en'), qr/No mean for 0 observations/,
    'explicit language overrides the captured lexical choice');
my $numeric = $catalog->diagnostic('EMPTY', operation => 'mean', count => Scalar::Util::dualvar(0, 'wrong'));
like($numeric->render, qr/for 0 observations/, 'typed numeric capture discards unrelated dualvar text');

my $sequence = 0;
sub fresh_definition {
    my $namespace = 'CatalogValidation' . ++$sequence;
    return {
        namespace => $namespace,
        conditions => {TEST => {
            class => $namespace . '::Diagnostic::Test',
            parent => 'XPerl::Diagnostic::Error::Numeric',
            severity => 'FATAL_ERROR', params => [], templates => {en => 'Test'},
        }},
    };
}
for my $change (
    sub { $_[0]{'namespace|conditions'} = 1 },
    sub { $_[0]{"namespace\0junk"} = 1 },
    sub { $_[0]{namespace} = 'XPerl' },
    sub { $_[0]{conditions} = {} },
    sub { $_[0]{conditions}{TEST}{class} = 'Elsewhere::Diagnostic::Test' },
    sub { $_[0]{conditions}{TEST}{parent} = 'XPerl::Diagnostic::Warning' },
    sub { $_[0]{conditions}{TEST}{params} = [{}] },
    sub { $_[0]{conditions}{TEST}{params} = [{name => 'x', type => 'object'}] },
    sub { $_[0]{conditions}{TEST}{templates} = {de => 'Test'} },
    sub { $_[0]{conditions}{TEST}{templates}{en} = '%{unknown}' },
    sub { $_[0]{conditions}{TEST}{templates}{en} = '%{unfinished' },
    sub { $_[0]{conditions}{TEST}{templates}{en} = "bad\0text" },
) {
    my $definition = fresh_definition();
    $change->($definition);
    eval { XPerl::Diagnostic::Catalog->_register($definition) };
    ok($@ && $@->has_diagnostic('ERROR_DIAGNOSTIC_API_CATALOG_INVALID'),
        'invalid declaration produces a catalog validation diagnostic');
}
{
    package CatalogPredeclared::Diagnostic::Test;
    our @ISA = ('XPerl::Diagnostic::Error::Numeric');
}
my $predeclared = fresh_definition();
$predeclared->{namespace} = 'CatalogPredeclared';
$predeclared->{conditions}{TEST}{class} = 'CatalogPredeclared::Diagnostic::Test';
my $predeclared_catalog = XPerl::Diagnostic::Catalog->_register($predeclared);
ok($predeclared_catalog->diagnostic('TEST')->isa('XPerl::Diagnostic::Error::Numeric'),
    'matching predeclared class ancestry is accepted');

my $malformed = $diag->derive([]);
my $empty = {};
Internals::SvREADONLY(%$empty, 1);
$malformed->{_module_descriptor} = $empty;
like($malformed->render, qr/Invalid module diagnostic data/,
    'malformed readonly descriptors have a bounded render fallback');

{
    local @INC = (sub { die 'Unexpected implicit module load' });
    like($diag->render_as_legacy('de'), qr/Keine mean: 0/, 'rendering uses retained definitions without loading modules');
    like($diag->as_json, qr/CatalogTest::EMPTY/, 'serialization needs no implicit module load');
}
{
    local $SIG{__EXCEPT__} = sub { $_[0]->append($diag) };
    local $SIG{__WARN__} = sub { die 'Promoted warnings must not visit the warning hook' };
    eval { $catalog->emit('CAUTION') };
    ok(ref($@) && $@->has_diagnostic('CatalogTest::EMPTY'),
        'the canonical hook can promote a module warning');
}
{
    my $cycle = fresh_definition();
    $cycle->{namespace} = 'CatalogCycle';
    $cycle->{conditions}{TEST}{class} = 'CatalogCycle::Diagnostic::Child';
    $cycle->{conditions}{TEST}{parent} = 'CatalogCycle::Diagnostic::Parent';
    {
        package CatalogCycle::Diagnostic::Child;
        our @ISA;
        package CatalogCycle::Diagnostic::Parent;
        our @ISA = ('CatalogCycle::Diagnostic::Child', 'XPerl::Diagnostic::Error');
    }
    eval { XPerl::Diagnostic::Catalog->_register($cycle) };
    like($@, qr/inheritance_cycle/, 'cyclic ancestry is rejected before mutation');
    is(scalar @CatalogCycle::Diagnostic::Child::ISA, 0, 'failed registration preserves ancestry');
}

{
    package CatalogJoint::Diagnostic::A;
    our @ISA;
    package CatalogJoint::Diagnostic::B;
    our @ISA;
    package CatalogJoint::Diagnostic::P1;
    our @ISA = ('CatalogJoint::Diagnostic::B', 'XPerl::Diagnostic::Error');
    package CatalogJoint::Diagnostic::P2;
    our @ISA = ('CatalogJoint::Diagnostic::A', 'XPerl::Diagnostic::Error');
}
my $joint = {namespace => 'CatalogJoint', conditions => {}};
for my $pair (['A', 'P1'], ['B', 'P2']) {
    my ($class, $parent) = @$pair;
    $joint->{conditions}{$class} = {
        class => "CatalogJoint::Diagnostic::$class",
        parent => "CatalogJoint::Diagnostic::$parent",
        severity => 'FATAL_ERROR', params => [], templates => {en => 'Test'},
    };
}
eval { XPerl::Diagnostic::Catalog->_register($joint) };
like($@, qr/existing_descendants/, 'joint ancestry changes are rejected before mutation');
is(scalar @CatalogJoint::Diagnostic::A::ISA, 0, 'first rejected ancestry is unchanged');
is(scalar @CatalogJoint::Diagnostic::B::ISA, 0, 'second rejected ancestry is unchanged');

SKIP: {
    require Config;
    skip 'Perl has no ithreads', 2 unless $Config::Config{useithreads};
    require threads;
    my $thread = threads->create(sub {
        my $copy = $catalog->diagnostic('EMPTY', operation => 'mean', count => 0);
        return [$copy->code, $copy->render_as_legacy('de')];
    });
    my $result = $thread->join;
    is($result->[0], 'CatalogTest::EMPTY', 'catalog and descriptors survive interpreter cloning');
    like($result->[1], qr/Keine mean: 0/, 'cloned module diagnostic renders');
}

done_testing;
