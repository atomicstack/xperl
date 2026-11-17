#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use strict;
use warnings;
use feature 'try';
use Config;
use JSON::PP ();

my ($die_line, $outer_line);
sub stack_inner {
    $die_line = __LINE__ + 1;
    die "stack test\n";
}
sub stack_outer {
    $outer_line = __LINE__ + 1;
    stack_inner(@_);
}

{
    package StackObject;
    use overload '""' => sub { die "argument stringification invoked\n" },
                 '0+' => sub { die "argument numeric overload invoked\n" },
                 fallback => 1;
    our $destroyed = 0;
    sub DESTROY { ++$destroyed }
}

my $hook_trace;
my $error;
{
    local $SIG{__EXCEPT__} = sub { $hook_trace = $_[0]->stack_trace };
    my $object = bless { password => 'hidden-object-value' }, 'StackObject';
    eval { stack_outer('hidden-string-value', 314159265, 2.5, undef, {}, [], $object) };
    $error = $@;
}
my $trace = $error->stack_trace;
is(join(',', map { $_->{function} } @$trace),
   'main::stack_inner,main::stack_outer,(eval)',
   'automatic capture stops at the innermost eval');
is($trace->[0]{file}, __FILE__, 'innermost frame records the source file');
is($trace->[0]{line}, $die_line, 'innermost frame records the failing line');
is($trace->[1]{line}, $outer_line, 'outer frame records its active call site');
is(join(',', sort keys %{$trace->[0]}), 'args,file,function,line',
   'frames contain only function, file, line and argument summaries');
is(join(',', @{$trace->[0]{args}}[0 .. 3]), 'STR,NUM,NUM,undef',
   'scalar arguments record their types without their values');
like($trace->[0]{args}[4], qr/\AHASH\(0x[0-9a-f]+\)\z/i,
     'hash references record type and address');
like($trace->[0]{args}[5], qr/\AARRAY\(0x[0-9a-f]+\)\z/i,
     'array references record type and address');
like($trace->[0]{args}[6], qr/\AStackObject=HASH\(0x[0-9a-f]+\)\z/i,
     'blessed references record class, type and address without overload');
is($StackObject::destroyed, 1, 'captured frames do not retain argument objects');
ok(eq_array([map { $_->{function} } @$hook_trace],
            [map { $_->{function} } @$trace]),
   'the exception hook sees the application stack captured before hooks');

my $json = $error->as_json;
unlike($json, qr/hidden-string-value|hidden-object-value|314159265/,
       'exception JSON contains no scalar or referent argument contents');
my $decoded = JSON::PP->new->decode($json);
is($decoded->{stack_trace}[0]{args}[0], 'STR',
   'whole-exception JSON includes stack argument summaries');
$trace->[0]{function} = 'changed';
$trace->[0]{args}[0] = 'changed';
is($error->stack_trace->[0]{function}, 'main::stack_inner',
   'stack accessor returns detached frame records');
is($error->stack_trace->[0]{args}[0], 'STR',
   'stack accessor returns detached argument arrays');

sub stack_rethrow {
    eval { stack_inner('private') };
    die $@;
}
eval { stack_rethrow() };
is(join(',', map { $_->{function} } @{$@->stack_trace}),
   'main::stack_inner,(eval)', 'rethrow does not implicitly extend the stack');

my ($before_extension, $extension_result, $extend_line);
sub stack_extend {
    eval { stack_inner('private') };
    my $caught = $@;
    $before_extension = $caught->stack_trace;
    $extend_line = __LINE__ + 1;
    $extension_result = $caught->extend_stack;
    die $caught;
}
eval { stack_extend() };
$error = $@;
is(overload::StrVal($extension_result), overload::StrVal($error),
   'extend_stack returns the same exception');
is(join(',', map { $_->{function} } @{$error->stack_trace}),
   'main::stack_inner,(eval),main::stack_extend,(eval)',
   'explicit extension appends the handler stack to the next eval');
is($error->stack_trace->[2]{line}, $extend_line,
   'extension records the handler location where it was requested');
is(JSON::PP->new->canonical->encode([@{$error->stack_trace}[0 .. 1]]),
   JSON::PP->new->canonical->encode($before_extension),
   'extension preserves the original captured frames');

sub stack_try {
    try { stack_inner('private') }
    catch ($caught) { return $caught }
}
$error = stack_try();
is(join(',', map { $_->{function} } @{$error->stack_trace}),
   'main::stack_inner,(try)', 'try is an automatic capture boundary');

sub stack_try_extend {
    try { stack_inner('private') }
    catch ($caught) { return $caught->extend_stack }
}
eval { $error = stack_try_extend() };
is(join(',', map { $_->{function} } @{$error->stack_trace}),
   'main::stack_inner,(try),main::stack_try_extend,(eval)',
   'extension from a catch handler records the enclosing context');

{
    package StackTiedScalar;
    our $fetches = 0;
    sub TIESCALAR { bless [], shift }
    sub FETCH { ++$fetches; die "scalar FETCH invoked\n" }
    sub STORE { }
}
sub stack_tied_scalar {
    tie $_[0], 'StackTiedScalar';
    die "tied scalar stack\n";
}
my $scalar = 'private';
eval { stack_tied_scalar($scalar) };
$error = $@;
is($StackTiedScalar::fetches, 0, 'capture does not FETCH a magical argument');
like($error->stack_trace->[0]{args}[0], qr/\/MG\z/,
     'magical scalar arguments have an MG marker');
untie $scalar;

{
    package StackTiedHash;
    sub TIEHASH { bless [], shift }
    sub FETCH { die "hash FETCH invoked\n" }
}
tie my %magical, 'StackTiedHash';
eval { stack_inner(\%magical) };
$error = $@;
like($error->stack_trace->[0]{args}[0], qr/\AHASH\(0x[0-9a-f]+\)\/MG\z/i,
     'magic on a reference target is marked without fetching it');

{
    package StackTiedArgs;
    our $fetches = 0;
    sub TIEARRAY { bless [], shift }
    sub FETCHSIZE { ++$fetches; die "argument array FETCHSIZE invoked\n" }
}
sub stack_tied_args {
    tie @_, 'StackTiedArgs';
    die "tied argument array stack\n";
}
eval { stack_tied_args('private') };
$error = $@;
is($StackTiedArgs::fetches, 0, 'capture does not inspect a tied argument array');
is(join(',', @{$error->stack_trace->[0]{args}}), '@_/MG',
   'a tied argument array has an opaque magic marker');

sub stack_shifted {
    shift;
    die "shifted stack\n";
}
eval { stack_shifted('removed-private-value', 23) };
is(join(',', @{$@->stack_trace->[0]{args}}), 'NUM',
   'capture reads live arguments after shift without traversing retired slots');

sub stack_recursive {
    return stack_recursive($_[0] - 1) if $_[0];
    die "recursive stack\n";
}
eval { stack_recursive(3) };
is(scalar(grep { $_->{function} eq 'main::stack_recursive' } @{$@->stack_trace}),
   4, 'recursive calls retain their distinct frames');

sub stack_sort { die "sort stack\n" }
eval { my @sorted = sort stack_sort (3, 2, 1) };
is($@->stack_trace->[0]{function}, 'main::stack_sort',
   'multicall callbacks can capture their frame safely');

format STACK_TRACE_FORMAT =
@*
do { die "format stack\n" }
.
{
    local $~ = 'STACK_TRACE_FORMAT';
    eval { write };
    $error = $@;
}
is($error->stack_trace->[0]{function}, 'main::STACK_TRACE_FORMAT',
   'format execution records its function frame');

my $empty = XPerl::Exception->_new;
ok(!defined($empty->stack_trace), 'unthrown exceptions have no captured stack');
ok(!defined(JSON::PP->new->decode($empty->as_json)->{stack_trace}),
   'unthrown exception JSON has a null stack');

{
    use feature 'signatures';
    sub stack_signature ($text, $number) { die "signature stack\n" }
}
eval { stack_signature('private', 17) };
is(join(',', @{$@->stack_trace->[0]{args}}), 'STR,NUM',
   'signature calls retain anonymous argument information');

eval 'my $x = ;';
ok(ref($@) && ref($@->stack_trace) eq 'ARRAY',
   'compilation failures capture stack data');

my $required_file = tempfile();
open my $module, '>', $required_file or die "open: $!";
print {$module} "package StackRequired;\nsub fail { die qq(require stack\\n) }\nfail();\n1;\n";
close $module or die "close: $!";
eval { require "./$required_file" };
$error = $@;
like("$error", qr/require stack/, 'required module throws the expected error');
is(join(',', map { $_->{function} } @{$error->stack_trace}),
   'StackRequired::fail,(require),(eval)',
   'require remains visible while capture continues to the application eval');

my $broken_file = tempfile();
open $module, '>', $broken_file or die "open: $!";
print {$module} 'my $x = ;', "\n";
close $module or die "close: $!";
eval { require "./$broken_file" };
$error = $@;
is(join(',', map { $_->{function} } @{$error->stack_trace}),
   '(require),(eval)',
   'compilation failure in require captures its boundary before unwinding');

my $edited_file = tempfile();
open $module, '>', $edited_file or die "open: $!";
print {$module} "sub StackEdited::fail { die qq(edited stack\\n) }\nStackEdited::fail();\n1;\n";
close $module or die "close: $!";
{
    my $edited = 0;
    local $SIG{__EXCEPT__} = sub {
        delete $_[0]{stack_trace}[0] unless $edited++;
    };
    eval { require "./$edited_file" };
    $error = $@;
}
ok(ref($error) && !defined($error->stack_trace->[0]),
   'require propagation tolerates a hook removing a captured frame');

my $warning_trace;
sub stack_warning { warn "warning stack\n" }
{
    local $SIG{__EXCEPT__} = sub { $warning_trace = $_[0]->stack_trace };
    local $SIG{__WARN__} = sub { };
    stack_warning('private');
}
is(join(',', map { $_->{function} } @$warning_trace),
   'main::stack_warning,main', 'warning capture reaches main without an eval');

SKIP: {
    skip('requires threads', 2) unless $Config{useithreads};
    require threads;
    eval { stack_inner('private') };
    my $source = $@;
    my $worker = threads->create(sub {
        my ($original) = @_;
        my $before = join(',', map { $_->{function} } @{$original->stack_trace});
        eval { stack_outer('thread') };
        return [$before, join(',', map { $_->{function} } @{$@->stack_trace})];
    }, $source);
    my $result = $worker->join;
    is($result->[0], 'main::stack_inner,(eval)',
       'thread cloning preserves captured frame metadata');
    is($result->[1], 'main::stack_inner,main::stack_outer,(eval)',
       'a cloned interpreter captures its own new exception frames');
}

done_testing();
