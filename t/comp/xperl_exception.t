#!./perl

print "1..13\n";

print XPerl::Exception->can('_new')  ? "ok 1\n" : "not ok 1\n";
print XPerl::Diagnostic->can('_new') ? "ok 2\n" : "not ok 2\n";
print !exists $INC{'XPerl/Exception.pm'}
  && !exists $INC{'XPerl/Diagnostic.pm'} ? "ok 3\n" : "not ok 3\n";

my $diagnostic = XPerl::Diagnostic->_new(
    {
        code   => 'TEST',
        params => [
            {
                name  => 'text',
                type  => 'text',
                value => "test text\n",
            },
        ],
        location => {},
    }
);
my $exception = XPerl::Exception->_new();
$exception->append($diagnostic);
print $exception->contents->[0]->code eq 'TEST'     ? "ok 4\n" : "not ok 4\n";
print $exception->render('legacy') eq "test text\n" ? "ok 5\n" : "not ok 5\n";
print "$exception" eq "test text\n"                 ? "ok 6\n" : "not ok 6\n";

eval q{my $value = ;};
print ref($@) eq 'XPerl::Exception'
  && $@->contents->[0]->code eq 'ERROR_SYNTAX_INVALID' ? "ok 7\n" : "not ok 7\n";

my $diagnostic_json = $diagnostic->as_json;
print $diagnostic_json =~ /"schema":"xperl\.diagnostic\.v2"/
  && $diagnostic_json  =~ /"code":"TEST"/ ? "ok 8\n" : "not ok 8\n";
my $exception_json = $exception->as_json;
print $exception_json =~ /"schema":"xperl\.exception\.v2"/
  && $exception_json  =~ /"contents":\[/ ? "ok 9\n" : "not ok 9\n";
my $record = $exception->render('json');
print $record =~ /"schema":"xperl\.diagnostic-group\.v2"/
  && $record eq $exception->render('JSONL')
  && !exists $INC{'JSON/PP.pm'} ? "ok 10\n" : "not ok 10\n";

print $diagnostic->render_as_json eq $diagnostic_json ? "ok 11\n" : "not ok 11\n";
my $dumped = eval $diagnostic->render_as_dumper;
print !$@ && $dumped->{code} eq 'TEST' ? "ok 12\n" : "not ok 12\n";
print !exists $INC{'Data/Dumper.pm'}   ? "ok 13\n" : "not ok 13\n";
