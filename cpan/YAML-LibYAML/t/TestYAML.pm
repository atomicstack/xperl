package TestYAML;
use lib 'inc';
use Test::Base -Base;
use if !$ENV{PERL_CORE}, 'blib';
use File::Path 'rmtree';
our @EXPORT = qw(rmtree);

no_diff;
delimiters ('===', '+++');
