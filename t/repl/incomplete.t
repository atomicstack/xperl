#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use v5.36;
use XPerl::REPL::Evaluator;

# every diagnostic in the exception tree, depth first
sub all_diags ($e) {
    my @found;
    my @pending = @{ $e->contents };
    while (my $d = shift @pending) {
        push @found, $d;
        unshift @pending, @{ $d->contents };
    }
    return @found;
}

my $ev = XPerl::REPL::Evaluator->new;
my %cases = (
  'if (1) {'            => 'ERROR_SYNTAX_DELIMITER_UNCLOSED_STRUCTURE',
  'sub foo {'           => 'ERROR_SYNTAX_DELIMITER_UNCLOSED_STRUCTURE',
  'print "abc'          => 'ERROR_SYNTAX_QUOTED_STRING_TERMINATOR_MISSING',
  'my $y = <<EOT'       => 'ERROR_SYNTAX_QUOTED_STRING_TERMINATOR_MISSING',
  'my $y = <<"EOT'      => 'ERROR_SYNTAX_QUOTED_STRING_HEREDOC_QUOTED_DELIMITER_UNTERMINATED',
  '$_ =~ /abc'          => 'ERROR_SYNTAX_QUOTED_STRING_REGEXP_UNTERMINATED',
  '$_ =~ s/a'           => 'ERROR_SYNTAX_QUOTED_STRING_SUBSTITUTION_PATTERN_UNTERMINATED',
  '$_ =~ s/a/'          => 'ERROR_SYNTAX_QUOTED_STRING_SUBSTITUTION_REPLACEMENT_UNTERMINATED',
  '$_ =~ tr/a'          => 'ERROR_SYNTAX_QUOTED_STRING_TRANSLITERATION_SEARCH_UNTERMINATED',
  '$_ =~ tr/a/'         => 'ERROR_SYNTAX_QUOTED_STRING_TRANSLITERATION_REPLACEMENT_UNTERMINATED',
  'my @f = <foo'        => 'ERROR_SYNTAX_QUOTED_STRING_ANGLE_UNTERMINATED',
  'my @f = <a<b>'       => 'ERROR_SYNTAX_QUOTED_STRING_ANGLE_GLOB_UNTERMINATED',
  'my @a = (1,'         => 'ERROR_SYNTAX_INVALID',
  '1 +'                 => 'ERROR_SYNTAX_INVALID',
  'foo('                => 'ERROR_SYNTAX_INVALID',
);
for my $src (sort keys %cases) {
  my $r = $ev->evaluate($src, 1);
  is($r->kind, 'incomplete', "incomplete: $src");
  ok((grep { $_->code eq $cases{$src} } all_diags($r->exception)), "code $cases{$src} present for $src");
}
for my $src ('1 +', 'my @a = (1,') {
  my ($d) = grep { $_->code eq 'ERROR_SYNTAX_INVALID' } all_diags($ev->evaluate($src, 1)->exception);
  is($d->location->{parser_context}, 'eof', "parser_context is eof for $src");
}
is($ev->evaluate('1 = = 2', 2)->kind, 'compile_error', 'real syntax error is not incomplete');
is($ev->evaluate('if (1) { 1 } }', 3)->kind, 'compile_error', 'unmatched right curly is an error');
is($ev->evaluate("if (1) {\n 42\n}", 4)->kind, 'ok', 'joined input completes');
my $e = $ev->evaluate("1\n__END__\n2", 5);
is($e->kind, 'compile_error', '__END__ is rejected, not incomplete');
like($e->exception->render, qr/__END__ is not allowed in repl input/);
is($ev->evaluate("1\n__DATA__", 6)->kind, 'compile_error', '__DATA__ rejected too');
like($ev->evaluate('if (1) {', 7)->exception->render, qr/^Missing right curly .* at xperl-repl-end-input%207 line 1,/,
     'an error found at end of input points at the last input line (the renderer shows input 7)');
like($ev->evaluate("if (1) {\n 1;", 8)->exception->render, qr/ at xperl-repl-end-input%208 line 2,/,
     'last line of a multi-line input');
# __END__/__DATA__ end the source wherever a statement can start, and so
# do ^D and ^Z: never report such input as incomplete
for my $src ("1; __END__", "1; __DATA__\nx", "{ 1 } __END__", "1;\n  __END__", "1; \cD", "1; \cZ 2", "\cD") {
  (my $shown = $src) =~ s/([\cD\cZ\n])/sprintf '\\x%02x', ord $1/ge;
  is($ev->evaluate($src, 9)->kind, 'compile_error', "source end rejected: $shown");
}
is($ev->evaluate('"x__END__"', 10)->kind, 'ok', '__END__ inside a word or string is fine');

# perl reports a syntax error at a ";" in string source "at EOF", so an
# eof ERROR_SYNTAX_INVALID only means unfinished input when it is found
# past the user's text
for my $src ('1 +;', 'my $x = ;', '"a" . ;', "1 +;\n2", "foo(;\n") {
  (my $shown = $src) =~ s/\n/\\n/g;
  is($ev->evaluate($src, 11)->kind, 'compile_error', "an operator before ';' is an error: $shown");
}
for my $src ('my @a = (1,', "foo(\n", "my \$h = foo(1,\n  2,") {
  (my $shown = $src) =~ s/\n/\\n/g;
  is($ev->evaluate($src, 12)->kind, 'incomplete', "still incomplete: $shown");
}
like($ev->evaluate('1 +', 13)->exception->render, qr/ at xperl-repl-end-input%2013 line 1, at EOF/,
     'a forced unfinished input still reports its own last line');
done_testing;
