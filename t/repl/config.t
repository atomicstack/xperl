#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use v5.36;
use XPerl::REPL::Config;

use Data::Dumper ();
sub is_deeply {
    my ($got, $expected, $name) = @_;
    local $Data::Dumper::Sortkeys = 1;
    local $Data::Dumper::Useqq    = 1;
    local $Data::Dumper::Indent   = 1;
    local $Data::Dumper::Terse    = 1;
    @_ = (Data::Dumper::Dumper($got), Data::Dumper::Dumper($expected), $name);
    goto &is;
}

my %defaults = (
    inc => [], modules => [], code => [], rc => undef, no_rc => 0, color => 'auto',
    out => undef, render => undef, version => 0, help => 0, file => undef,
    prompt => undef, continuation => undef,
);
my $o = XPerl::REPL::Config::parse_argv([qw(-I lib -M Foo -e 1 -e 2 --color=never --out json file.pl)]);
is_deeply($o, { %defaults, inc => ['lib'], modules => ['Foo'], code => [1, 2], color => 'never', out => 'json', file => 'file.pl' }, 'perl-style options and a file');
is_deeply(XPerl::REPL::Config::parse_argv([qw(-Ilib -MFoo=bar -e1)]),
          { %defaults, inc => ['lib'], modules => ['Foo=bar'], code => [1] }, 'bundled -Ilib -MFoo -e1');
is_deeply(XPerl::REPL::Config::parse_argv([]), \%defaults, 'defaults');
is(XPerl::REPL::Config::parse_argv(['--no-rc'])->{no_rc}, 1, '--no-rc');
is(XPerl::REPL::Config::parse_argv([qw(--rc x)])->{rc}, 'x', '--rc file');
is(XPerl::REPL::Config::parse_argv(['--version'])->{version}, 1, '--version');
is(XPerl::REPL::Config::parse_argv(['--help'])->{help}, 1, '--help');
is(XPerl::REPL::Config::parse_argv([qw(--render annotated)])->{render}, 'annotated', '--render');
is(XPerl::REPL::Config::parse_argv(['--prompt', '%p> '])->{prompt}, '%p> ', '--prompt');
is(XPerl::REPL::Config::parse_argv(['--continuation', '~ '])->{continuation}, '~ ', '--continuation');
{
  my @w; local $SIG{__WARN__} = sub { push @w, @_ };
  eval { XPerl::REPL::Config::parse_argv(['--bogus']) };
  like($@, qr/^usage: xperl-repl /m, 'bad option dies with usage');
  like($@, qr/bogus/, 'naming the option');
  is(scalar @w, 0, 'without warning on the side');
}
eval { XPerl::REPL::Config::parse_argv(['--color=sometimes']) };
like($@, qr/^usage: xperl-repl /m, 'bad --color value dies with usage');
eval { XPerl::REPL::Config::parse_argv([qw(a.pl b.pl)]) };
like($@, qr/^usage: xperl-repl /m, 'more than one file dies with usage');
like(XPerl::REPL::Config::usage(), qr/^usage: xperl-repl \[-I dir\]/, 'usage text');
like(XPerl::REPL::Config::version_text(), qr/^xperl-repl \S+ \(xperl \S+, perl v5\.\d+\.\d+\)\n\z/, 'version text');

is(XPerl::REPL::Config::rc_path({HOME => '/h'}), '/h/.xperl/replrc', 'rc path under HOME');
is(XPerl::REPL::Config::rc_path({HOME => '/h', XPERL_REPL_RC => '/x/rc'}), '/x/rc', 'XPERL_REPL_RC override');
is(XPerl::REPL::Config::history_path({HOME => '/h'}), '/h/.xperl/repl_history', 'history path under HOME');
is(XPerl::REPL::Config::history_path({HOME => '/h', XPERL_REPL_HISTORY => '/x/h'}), '/x/h', 'XPERL_REPL_HISTORY override');

sub level (%a) { XPerl::REPL::Config::color_level(is_tty => 1, option => 'auto', %a) }
is(level(option => 'never', env => {TERM => 'xterm-256color'}), 0, '--color=never');
is(level(env => {NO_COLOR => 1, TERM => 'xterm-256color'}), 0, 'NO_COLOR');
is(level(is_tty => 0, env => {TERM => 'xterm-256color'}), 0, 'not a tty');
is(level(env => {COLORTERM => 'truecolor', TERM => 'xterm'}), 'rgb', 'COLORTERM truecolor');
is(level(env => {COLORTERM => '24bit', TERM => 'xterm'}), 'rgb', 'COLORTERM 24bit');
is(level(env => {TERM => 'xterm-256color'}), 256, 'TERM 256color');
is(level(env => {TERM_PROGRAM => 'Apple_Terminal', TERM => 'xterm'}), 256, 'Apple_Terminal');
is(level(env => {TERM_PROGRAM => 'iTerm.app', TERM => 'xterm'}), 256, 'known terminal program');
is(level(env => {TERM => 'xterm'}), 16, 'plain TERM');
is(level(env => {TERM => 'dumb'}), 0, 'dumb terminal');
is(level(env => {}), 0, 'TERM unset');
is(level(option => 'always', env => {TERM => 'dumb'}), 16, 'always never below 16');
is(level(option => 'always', is_tty => 0, env => {TERM => 'xterm-256color'}), 256, 'always ignores the tty test');
done_testing;
