#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    require Config;
    skip_all('no fork') unless $Config::Config{d_fork};
}

use v5.36;
use File::Path ();
use File::Spec;

# the script "make" generated from utils/xperl-repl.PL
my $script = '../utils/xperl-repl';
ok(-f $script, "$script exists") or BAIL_OUT("$script is missing: run make");

my $tmp = File::Spec->rel2abs(tempfile());
File::Path::make_path("$tmp/lib", "$tmp/home");
END { File::Path::remove_tree($tmp) if defined $tmp }

# keep the user's own rc and history files out of it
local $ENV{HOME} = "$tmp/home";
delete local $ENV{XPERL_REPL_RC};
delete local $ENV{XPERL_REPL_HISTORY};

sub write_file ($file, $text) {
    open my $fh, '>', $file or die "$file: $!";
    print {$fh} $text;
    close $fh or die "$file: $!";
}

sub slurp ($file) {
    open my $fh, '<', $file or die "$file: $!";
    local $/;
    return scalar <$fh>;
}

# run the script with @$args and $stdin; returns stdout, stderr, exit status
sub run_cli ($args, $stdin) {
    write_file("$tmp/stdin", $stdin);
    my $pid = open(my $fh, '-|') // die "fork: $!";
    if (!$pid) {
        open STDIN,  '<', "$tmp/stdin"  or die "stdin: $!";
        open STDERR, '>', "$tmp/stderr" or die "stderr: $!";
        exec $^X, '-I../lib', $script, @$args or die "exec: $!";
    }
    my $out = do { local $/; <$fh> } // '';
    close $fh;
    my $status = $? & 127 ? 128 + ($? & 127) : $? >> 8;    # as a shell reports it
    return ($out, slurp("$tmp/stderr"), $status);
}

my ($o, $e, $s) = run_cli(['-e', '1 + 1'], '');
is($o, "2\n", '-e is evaluated');
is($s, 0, 'exit status 0 at end of input');
is($e, '', 'nothing on stderr');

($o) = run_cli(['-e', 'my $x = 2', '-e', '$x * 3'], '');
is($o, "2\n6\n", '-e lines share the session');

($o) = run_cli(['-M', 'List::Util=sum', '-e', 'sum(1,2,3)'], '');
is($o, "6\n", '-M imports into the session');

($o) = run_cli(['-MList::Util=sum,max', '-e', 'max(1,5,3)'], '');
is($o, "5\n", '-MModule=a,b imports a list');

write_file("$tmp/lib/Tq.pm", "package Tq; sub v { 'tq' } 1;\n");
($o) = run_cli(['-I', "$tmp/lib", '-M', 'Tq', '-e', 'Tq::v()'], '');
is($o, qq{"tq"\n}, '-I adds to @INC');

write_file("$tmp/s.pl", "my \$f = 5;\n\$f + 1\n");
($o) = run_cli(["$tmp/s.pl"], '');
is($o, "6\n", 'file evaluated as one input');

write_file("$tmp/end.pl", "my \$g = 2;\n\$g * 4\n__END__\n\n=head1 NAME\n\nnot code\n");
($o, $e) = run_cli(["$tmp/end.pl"], '');
is($o, "8\n", 'a file is evaluated up to __END__, as perl does');
is($e, '', 'without complaint');
write_file("$tmp/data.pl", "7 * 6\n__DATA__\nraw\n");
($o) = run_cli(["$tmp/data.pl"], '');
is($o, "42\n", 'and up to __DATA__');

($o, $e) = run_cli(['-e', 'if (1) {'], '');
like($e, qr/^compile error: /, 'an incomplete -e is an error, not a continuation');

($o) = run_cli([], "3 * 3\n");
is($o, "9\n", 'stdin pipe, no prompts');

($o) = run_cli(['-e', 'my $y = 4'], "\$y + 1\n");
is($o, "4\n5\n", 'stdin continues the -e session');

write_file("$tmp/rc", "\$REPL->out('json'); my \$fromrc = 1;\n");
($o) = run_cli(['--rc', "$tmp/rc", '-e', '[$fromrc]'], '');
like($o, qr/^\[\n/, 'rc file configures and defines');

($o) = run_cli(['--rc', "$tmp/rc", '--no-rc', '-e', '1'], '');
is($o, "1\n", '--no-rc');

($o) = run_cli(['--rc', "$tmp/rc", '--out', 'plain', '-e', '[$fromrc]'], '');
like($o, qr/^ARRAY\(/, 'command line options win over the rc file');

# prompts: without a terminal none are drawn, :prompt shows the setting
($o, $e) = run_cli(['--prompt', 'X%n> ', '--continuation', '~ ', '-e', ':prompt', '-e', ':continuation', '-e', '1'], '');
is($o, "X%n> \n~ \n1\n", '--prompt and --continuation, no prompt echoed without a terminal');
is($e, '', 'without errors');
write_file("$tmp/prompt.rc", "\$REPL->prompt('%p> ');\n");
($o) = run_cli(['--rc', "$tmp/prompt.rc", '-e', ':prompt'], '');
is($o, "%p> \n", 'the rc file sets the prompt');
($o) = run_cli(['--rc', "$tmp/prompt.rc", '--prompt', 'Y> ', '-e', ':prompt'], '');
is($o, "Y> \n", '--prompt wins over the rc file');

{
    local $ENV{XPERL_REPL_RC} = "$tmp/rc";
    ($o) = run_cli(['-e', '[1]'], '');
    like($o, qr/^\[\n/, 'env override');
}

mkdir "$tmp/home/.xperl";
write_file("$tmp/home/.xperl/replrc", "1 = = 2;\n");
($o, $e, $s) = run_cli(['-e', '7'], '');
like($e, qr/^compile error: /, 'errors in the rc file are rendered');
is($o, "7\n", 'and do not stop startup');
unlink "$tmp/home/.xperl/replrc";

SKIP: {
    require POSIX;
    my $old = POSIX::setlocale(POSIX::LC_CTYPE());
    my $have = POSIX::setlocale(POSIX::LC_CTYPE(), 'en_US.UTF-8');
    POSIX::setlocale(POSIX::LC_CTYPE(), $old);
    skip 'no en_US.UTF-8 locale', 9 unless $have;
    local $ENV{LC_ALL} = 'en_US.UTF-8';
    ($o, $e) = run_cli(['-e', qq{length "\xce\xbb"}], '');
    is($o, "1\n", 'in a UTF-8 locale -e code is characters');
    ($o, $e) = run_cli(['-e', 'say "\x{263a}"'], '');
    is($o, "\xe2\x98\xba\n!!1\n", 'and output is encoded');
    unlike($e, qr/Wide character/, 'without a wide character warning');
    ($o, $e) = run_cli([], "length \"\xce\xbb\"\n");
    is($o, "1\n", 'standard input is decoded');
    # files are read like the terminal: as characters, as under use utf8
    write_file("$tmp/lambda.pl", qq{print "\xce\xbb\\n"; ()\n});
    write_file("$tmp/lambda.rc", qq{print "\xce\xbb\\n";\n});
    ($o, $e) = run_cli(["$tmp/lambda.pl"], '');
    is(unpack('H*', $o), 'cebb0a', 'a script file is decoded, then encoded once on output');
    ($o, $e) = run_cli(['--rc', "$tmp/lambda.rc"], '');
    is(unpack('H*', $o), 'cebb0a', 'so is the rc file');
    is($e, '', 'without warnings');
    local $ENV{LC_ALL} = 'C';
    ($o, $e) = run_cli(['-e', qq{length "\xce\xbb"}], '');
    is($o, "2\n", 'in the C locale it is bytes');
    ($o, $e) = run_cli(["$tmp/lambda.pl"], '');
    is(unpack('H*', $o), 'cebb0a', 'and a script file prints its bytes unchanged');
}

# rc file and -M inputs are not numbered; -e and a file are
write_file("$tmp/rc2", "my \$fromrc2 = 1;\n");
($o, $e) = run_cli(['--rc', "$tmp/rc2", '-M', 'List::Util=sum', '-e', 'die "x"'], ":history\n");
like($e, qr/^error: x at input 1 line 1\.$/m, 'the first -e is input 1 after an rc file and -M');
is($o, qq{1> die "x"\n}, ':history agrees');
write_file("$tmp/rc3", "1 = = 2;\n");
($o, $e) = run_cli(['--rc', "$tmp/rc3", '-e', '1'], '');
like($e, qr/^compile error: syntax error at rc file line 1, near "= ="$/m, 'an rc file error names the rc file');
($o, $e) = run_cli(['-M', 'No::Such::Module', '-e', '1'], '');
like($e, qr/^compile error: Can't locate No\/Such\/Module\.pm in \@INC.* at -M No::Such::Module line 1\./m, 'a -M error names the module');
is($o, "1\n", 'and the -e after it is still evaluated');
unlike($e, qr/xperl-repl/, 'no generated file names');

# SIGINT during a startup input interrupts that input only
($o, $e, $s) = run_cli(['--out', 'plain',
    '-e', 'package SI { use overload q{""} => sub { kill INT => $$; sleep 2; "x" } } bless {}, "SI"',
    '-e', '7'], '');
like($e, qr/^interrupted$/m, 'SIGINT while a -e result renders is reported as interrupted');
is($o, "7\n", 'the next -e runs');
is($s, 0, 'and the process exits 0');

($o, $e, $s) = run_cli(['--version'], '');
like($o, qr/^xperl-repl \d/, '--version');
is($s, 0, '--version exits 0');

($o, $e, $s) = run_cli(['--help'], '');
like($o, qr/^usage: xperl-repl /, '--help');
is($s, 0, '--help exits 0');

($o, $e, $s) = run_cli(['--bogus'], '');
like($e, qr/usage/, 'a bad option prints the usage');
isnt($s, 0, 'and fails');

($o, $e, $s) = run_cli(['-e', 'exit 3'], '');
is($s, 3, 'exit in user code exits the process');

done_testing();
