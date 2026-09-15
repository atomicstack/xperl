#!/perl -w
use strict;

# See "TESTING" in perlhack.pod for the instructions about where test files
# are located and which constructions should be avoided in the early tests.

# This regression tests ensures that the rules aren't accidentally overlooked.

BEGIN {
    chdir 't';
    require './test.pl';
}

plan('no_plan');

open my $fh, '<', '../MANIFEST' or die "Can't open MANIFEST: $!";

# Some tests in t/comp need to use require or use to get their job done:
my %exceptions = (
    filter_exception => "require './test.pl'",
    hints => "require './test.pl'",
    parser => 'use DieDieDie',
    parser_run => "require './test.pl'",
    proto => 'use strict',
    namespaces => qr/^\s*(?:use|require)\s+.*;\s*$/m,
    dispatch_on => qr/^\s*use (?:v5\.45\.3|strict|warnings[^;]*|overload[^;]*|Scalar::Util[^;]*|dispatch::Predicates|experimental 'class'|feature (?:'dispatch_on'|qw\(dispatch_on (?:namespaces|signatures)\))|builtin qw\(true false\));/m,
    dispatch_on_examples => qr/^\s*(?:require '\.\/test\.pl'|use (?:feature 'dispatch_on'|dispatch::Predicates|builtin qw\(true false\)));/m,
    dispatch_on_hardening => qr/^\s*(?:require (?:'\.\/test\.pl'|Scalar::Util)|use (?:feature 'dispatch_on'|dispatch::Predicates|overload[^;]*));/m,
    dispatch_on_hardening_tail => qr{
        ^\s*(?:
            require\s+(?:'\./test\.pl'|Scalar::Util)
            | use\s+(?:
                strict | utf8 | experimental\s+'class' | dispatch::Predicates | overload[^;]*
                | Scalar::Util[^;]*
                | warnings\s+FATAL\s*=>\s*'syntax'
                | feature\s+(?:'dispatch_on'|qw\(dispatch_on\s+say(?:\s+class)?\))
                | builtin\s+qw\(true\s+false\)
            )
        );
    }mx,
    dispatch_on_numeric => qr/^\s*(?:require '\.\/test\.pl'|use (?:strict|warnings|dispatch::Predicates|feature '(?:dispatch_on|signatures)'));/m,
    dispatch_on_threads => qr/^\s*(?:require '\.\/test\.pl'|use feature 'dispatch_on');/m,
    dispatch_on_review => qr{
        ^\s*(?:
            require\s+'\./test\.pl'
            | use\s+(?:
                generator | bytes | utf8 | feature\s+'class' | dispatch::Predicates | overload[^;]*
                | Scalar::Util[^;]*
                | builtin\s+qw\((?:weaken|true\s+false)\)
            )
        );
    }mx,
 );

while (my $file = <$fh>) {
    next unless $file =~ s!^t/!!;
    chomp $file;
    $file =~ s/\s+.*//;
    next unless $file =~ m!\.t$!;

    local $/;
    open my $t, '<', $file or die "Can't open $file: $!";
    # avoid PERL_UNICODE causing us to read non-UTF-8 files as UTF-8
    binmode $t;
    my $contents = <$t>;
    # Don't 'use' Test::* modules under 't/' --
    # but exclude this file from that test.
    unlike(
        $contents,
        qr/use\s+(?:Test::(?:Simple|More|Builder)|Test2)/,
        "$file doesn't use Test::Simple or Test::More"
    ) unless ($file =~ m|porting/test_bootstrap\.t|);
    next unless $file =~ m!^base/! or $file =~ m!^comp!;

    # Remove only the excepted constructions for the specific files.
    if ($file =~ m!comp/(.*)\.t! && $exceptions{$1}) {
	my $allowed = $exceptions{$1};
        if (ref $allowed) {
            $contents =~ s/$allowed//g;
        }
        else {
            $contents =~ s/\Q$allowed//gs;
        }
    }

    # All uses of use are allowed in t/comp/use.t
    unlike($contents, qr/^\s*use\s+/m, "$file doesn't use use")
	unless $file eq 'comp/use.t';
    # All uses of require are allowed in t/comp/require.t
    unlike($contents, qr/^\s*require\s+/m, "$file doesn't use require")
	unless $file eq 'comp/require.t'
}

# There are regression tests using test.pl that don't want PL_sawampersand
# set.  Or at least that was the case until PL_sawampersand was disabled
# and replaced with copy-on-write.

# We still allow PL_sawampersand to be enabled with
# -Accflags=-DPERL_SAWAMPERSAND, or with -DPERL_NO_COW, so its still worth
# checking.
# There's no portable, reliable way to check whether PL_sawampersand is
# set, so instead we just "grep $`|$&|$' test.pl"

{
    my $file = '';
    my $fh;
    if (ok(open(my $fh, '<', 'test.pl'), "opened test.pl")) {
	$file = do { local $/; <$fh> };
	$file //= '';
    }
    else {
	diag("error: $!");
    }
    ok(length($file) > 0, "read test.pl successfully");
    ok($file !~ /\$&/, 'Nothing in test.pl mentioned $&');
    ok($file !~ /\$`/, 'Nothing in test.pl mentioned $`');
    ok($file !~ /\$'/, 'Nothing in test.pl mentioned $\'');
}
