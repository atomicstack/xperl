#!./perl
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}
use strict;
use warnings;
local ${^DIAG_RENDER} = 'en:annotated';
require XPerl::DiagPack::EN;
is(${^DIAG_RENDER}, 'en:annotated', 'loading a pack does not select its language or style');
my $metadata = XPerl::DiagPack::EN->metadata;
is($metadata->{language}, 'en', 'the English pack reports its language');
is($metadata->{abi_version}, 5, 'the pack uses the validated descriptor ABI');
my $diagnostic = XPerl::Diagnostic->_new({
    code => 'ERROR_USER_TEXT', number => 2438, kind => 'USER_RUNTIME',
    severity => 'FATAL_ERROR',
    params => [{name=>'text', type=>'text', value=>"pack body\n"}],
});
is(XPerl::DiagPack::EN->render($diagnostic), "pack body\n", 'a pack renders the diagnostic body directly');
{
    use diagpack 'en';
    eval { die "lexical capture\n" };
    isa_ok(${^ERROR_OBJ}, 'XPerl::Exception', 'lexical selection preserves canonical capture');
    like(${^ERROR_OBJ}->render('en:legacy'), qr/lexical capture/, 'explicit rendering accepts the captured diagnostic');
}
require XPerl::DiagPack;
ok(grep($_ eq 'en', XPerl::DiagPack::_installed_languages()), 'the loader discovers the installed English capability');
done_testing();
