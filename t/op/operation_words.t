#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use strict;
use warnings;
use utf8;
require B;
require Storable;
require JSON::PP;
use XPerl::DiagPack qw(all);

# The object retains English display values and independent numeric identity.
# Every requested language gets a fresh, temporary phrase view.
eval q{1 += 2;};
my $exception = ${^ERROR_OBJ};
my ($diagnostic) = grep { $_->number == 1419 } @{ $exception->contents };
ok( $diagnostic, 'real lvalue failure creates the vocabulary pilot diagnostic' );
my %params = map { $_->{name} => $_->{value} } @{ $diagnostic->params };
is( $params{target},            'constant item',          'canonical target display is retained' );
is( $params{context},           'addition (+)',           'canonical context display is retained' );
is( $params{target_operation},  1 + B::opnumber('const'), 'target identity is numeric' );
is( $params{context_operation}, 1 + B::opnumber('add'),   'context identity is numeric' );
ok( !defined $diagnostic->selector_key, 'identity does not occupy a selector field' );

sub snapshot {
    no warnings 'once';
    local $Storable::canonical = 1;
    return Storable::freeze( $_[0] );
}

my $before   = snapshot($diagnostic);
my %messages = (
    en => "Can't modify constant item in addition (+)",
    de => 'Kann ein konstantes Element in einer Addition (+) nicht ändern',
    es => 'No se puede modificar un elemento constante en una suma (+)',
    fr => 'Impossible de modifier un élément constant dans une addition (+)',
    is => 'Ekki er hægt að breyta fasta í samlagningu (+)',
    it => 'Impossibile modificare un elemento costante in un’addizione (+)',
    nl => 'Kan een constant element niet wijzigen in een optelling (+)',
    pt => 'Não é possível modificar um elemento constante em uma adição (+)',
);
for my $language (qw(fr en de is es it nl pt fr de en)) {
    my $message = $diagnostic->render_as_legacy($language);
    like( $message, qr/\A\Q$messages{$language}\E /, "$language uses its complete bound phrases" );
    is( snapshot($diagnostic), $before, "$language rendering leaves the object unchanged" );
}
is(
    $diagnostic->render_as_legacy('xx'),
    $diagnostic->render_as_legacy('en'),
    'unknown language retries the complete English rendering'
);
like( $exception->render_as_annotated('de'),
    qr/\Q$messages{de}\E/, 'annotated rendering uses the same word resolution' );

my $json       = JSON::PP->new->decode( $diagnostic->render_as_json );
my %serialized = map { $_->{name} => $_->{value} } @{ $json->{params} };
is( $serialized{target},           'constant item', 'standalone serialization retains canonical display data' );
is( $serialized{target_operation}, $params{target_operation}, 'standalone serialization retains identity' );
my @records = map { JSON::PP->new->decode($_) } grep { length } split /\n/, $exception->render('fr:legacy:JSON');
ok(
    scalar( grep { index( $_->{message}, $messages{fr} ) >= 0 } @records ),
    'JSON delivery envelopes contain translated human text'
);
is( snapshot($diagnostic), $before, 'structured rendering does not retain translated temporary values' );

for my $case (
    [ 0,                         'unknown extension text',      'unknown identity' ],
    [ 1 + B::opnumber('custom'), 'custom description Ω',        'custom identity' ],
    [ 1 + B::opnumber('prtf'),   'printf',                      'literal keyword' ],
    [ 999999,                    'out-of-range extension text', 'out-of-range identity' ],
  )
{
    my ( $identity, $text, $label ) = @$case;
    my $copy = Storable::dclone($diagnostic);
    for my $param ( @{ $copy->{params} } ) {
        $param->{value} = $identity if $param->{name} eq 'target_operation';
        $param->{value} = $text     if $param->{name} eq 'target';
    }
    like(
        $copy->render_as_legacy('fr'),
        qr/\AImpossible de modifier \Q$text\E dans une addition/,
        "$label passes through while the surrounding message translates"
    );
}

{
    local ${^DIAG_RENDER} = 'fr:legacy';
    my @calls;
    local $SIG{__DIE__} = sub { push @calls, [@_] };
    eval q{1 += 2;};
    ok( @calls, 'legacy die hook is called for the pilot failure' );
    is( scalar @{ $calls[0] }, 1, 'legacy hook keeps its one-argument signature' );
    like( $calls[0][0], qr/\Q$messages{fr}\E/, 'legacy hook sees the resolved French text' );
}

# Related compiler failures share vocabulary without losing semantic cases.
my $words = do '../diag_op_conf.pl' or die $@ || $!;
for my $fixture (
    [ 1417, q{my %h; () = keys $h{foo=>};},                                                   'actual',  'helem' ],
    [ 1423, q{(\pos) = 42;},                                                                  'target',  'pos' ],
    [ 1424, q{\pos = 42;},                                                                    'target',  'pos' ],
    [ 1425, q{sub vocab_non_lvalue () { our ($a, $b); ($a, $b) } vocab_non_lvalue = (2, 3);}, 'context', 'sassign' ],
  )
{
    my ( $number, $source, $role, $operation ) = @$fixture;
    eval $source;
    my $error = ${^ERROR_OBJ};
    my ($item) = grep { $_->number == $number } @{ $error->contents };
    ok( $item, "$number is produced by real source" );
    next unless $item;
    my %values = map { $_->{name} => $_->{value} } @{ $item->params };
    is( $values{ $role . '_operation' }, 1 + B::opnumber($operation), "$number retains its numeric $role identity" );
    my $saved = snapshot($item);

    for my $language (qw(en de es fr is it nl pt ru uk)) {
        my $form =
            $language eq 'en'          ? 'default'
          : $number == 1417            ? ( $language eq 'fr'          ? 'indefinite' : 'default' )
          : $role eq 'context'         ? ( $language =~ /^(?:de|is)$/ ? 'dative'     : 'indefinite' )
          : $language =~ /^(?:de|is)$/ ? 'accusative'
          :                              'indefinite';
        if ( $language eq 'ru' || $language eq 'uk' ) {
            $form =
                $number == 1417    ? 'nominative'
              : $role eq 'context' ? ( $language eq 'ru' ? 'prepositional' : 'locative' )
              :                      'genitive';
        }
        my $phrase = $words->{languages}{$language}{words}{$operation}{forms}{$form};
        like( $item->render_as_legacy($language),
            qr/\Q$phrase\E/, "$number/$language resolves the $role in its requested form" );
        is( snapshot($item), $saved, "$number/$language keeps canonical data unchanged" );
    }
}

# The former expansion accidentally substituted C checker names into some
# arity messages. The vocabulary must use the captured operation description.
eval q{readpipe(1, 2)};
my ($arity) = grep { $_->number == 1405 } @{ ${^ERROR_OBJ}->contents };
ok( $arity, 'readpipe arity failure is catalogued' );
like(
    $arity->render_as_legacy('en'),
    qr/^Too many arguments for quoted execution/,
    'arity wording uses the operation description rather than its C checker'
);
unlike( $arity->render_as_legacy('en'), qr/ck_backtick/, 'arity wording does not expose internal checker names' );
eval q{sub vocab_named_callee ($) {} vocab_named_callee()};
my ($callee) = grep { $_->number == 1404 } @{ ${^ERROR_OBJ}->contents };
ok( $callee, 'user prototype arity failure is catalogued' );

for my $language (qw(en de es fr is it nl pt)) {
    like( $callee->render_as_legacy($language),
        qr/main::vocab_named_callee/, "$language retains a user-defined callee name" );
}

# Dynamic producers cross from canonical opcode names to the same numeric map.
require XS::APItest;
for my $name (qw(add aelem helem join seq sne custom yield)) {
    is(
        XS::APItest::diag_word_operation_identity($name),
        1 + B::opnumber($name),
        "$name converts to the numeric word identity"
    );
}
is( XS::APItest::diag_word_operation_identity(undef),           0, 'absent name uses identity zero' );
is( XS::APItest::diag_word_operation_identity('not_an_opcode'), 0, 'unknown name uses identity zero' );
is( XS::APItest::diag_word_operation_identity("add\0suffix"), 0, 'name conversion checks the complete counted string' );

# Void wording has a distinct English form without duplicating its sentence.
my $void;
{
    local $SIG{__EXCEPT__} = sub { $void = $_[0] };
    local $SIG{__WARN__}   = sub { };
    eval q{use warnings 'void'; time < 2; 1;};
}
ok( $void, 'a comparison in void context produces its warning' );
like(
    ( $void ? $void->render_as_legacy('en') : '' ),
    qr/Useless use of numeric less-than \(<\) in void context/,
    'English void word form preserves its existing less-than label'
);

# Case forms are selected independently for both operation roles.
for my $language (qw(ru uk)) {
    my $profile      = $words->{languages}{$language};
    my $target       = $profile->{words}{const}{forms}{accusative};
    my $context_form = $language eq 'ru' ? 'prepositional' : 'locative';
    my $context      = $profile->{words}{add}{forms}{$context_form};
    my $text         = $diagnostic->render_as_legacy($language);
    like( $text, qr/\Q$target\E/,  "$language resolves the accusative target" );
    like( $text, qr/\Q$context\E/, "$language resolves the context case" );
    ok( utf8::is_utf8($text), "$language rendering retains Unicode characters" );
    is( snapshot($diagnostic), $before, "$language does not mutate canonical values" );
    my @localized = map { JSON::PP->new->decode($_) }
      grep { length } split /\n/, $exception->render("$language:legacy:JSON");
    ok( scalar( grep { index( $_->{message}, $target ) >= 0 } @localized ),
        "$language JSON includes the resolved human text" );
    like( $callee->render_as_legacy($language),
        qr/main::vocab_named_callee/, "$language preserves user-defined function names" );
}

# Numeric bases select whole sentences rather than English adjectives.
for my $fixture (
    [ 'binary',           sub { oct('0b2') },                "Illegal binary digit '2' ignored",       2116 ],
    [ 'octal',            sub { oct('09') },                 "Illegal octal digit '9' ignored",        2116 ],
    [ 'hexadecimal',      sub { hex('z') },                  "Illegal hexadecimal digit 'z' ignored",  2116 ],
    [ 'runtime overflow', sub { hex( 'f' x 100 ) },          'Integer overflow in hexadecimal number', 2117 ],
    [ 'literal overflow', sub { eval '0x' . ( 'f' x 100 ) }, 'Integer overflow in hexadecimal number', 2117 ],
  )
{
    my ( $label, $produce, $english, $number ) = @$fixture;
    my @captured;
    {
        local $SIG{__EXCEPT__} = sub { push @captured, $_[0] };
        local $SIG{__WARN__}   = sub { };
        $produce->();
    }
    my ($item) = grep { $_->number == $number } map { @{ $_->contents } } @captured;
    ok( $item, "$label produces the catalogued radix warning" );
    next unless $item;
    like( $item->render_as_legacy('en'), qr/^\Q$english\E/, "$label preserves English wording" );
    ok(
        scalar( grep { $_->{name} eq 'radix' } @{ $item->params } ),
        "$label retains the selector source independently of display slots"
    );
    for my $language (qw(ru uk)) {
        unlike(
            $item->render_as_legacy($language),
            qr/Illegal|Integer overflow|hexadecimal|binary|octal/,
            "$label/$language does not leak an English radix fragment"
        );
    }
}

# Welsh requests a soft-mutated context and keeps its unmutated target phrase.
eval q{1 .= "x";};
my $welsh_exception = ${^ERROR_OBJ};
my ($welsh_lvalue) = grep { $_->number == 1419 } @{ $welsh_exception->contents };
ok( $welsh_lvalue, 'concatenation produces the real Welsh lvalue fixture' );
if ($welsh_lvalue) {
    my $profile = $words->{languages}{cy};
    my $phrase  = $profile->{words}{concat}{forms}{soft_mutation};
    my $base    = $profile->{words}{concat}{forms}{default};
    isnt( $phrase, $base, 'Welsh concatenation has an observable mutation' );
    my $saved = snapshot($welsh_lvalue);
    my $text  = $welsh_lvalue->render_as_legacy('cy');
    like( $text, qr/\Q$phrase\E/, 'Welsh context requests the mutated phrase' );
    unlike( $text, qr/\Q$base\E/, 'Welsh context does not use the base phrase' );
    like( $text, qr/\Q$profile->{words}{const}{forms}{default}\E/, 'Welsh target uses its independent default form' );
    is( snapshot($welsh_lvalue), $saved, 'Welsh mutation does not alter canonical data' );
    my @envelopes = map { JSON::PP->new->decode($_) }
      grep { length } split /\n/, $welsh_exception->render('cy:legacy:JSON');
    ok( scalar( grep { index( $_->{message}, $phrase ) >= 0 } @envelopes ),
        'Welsh JSON contains the same mutated human phrase' );
}

# A word tag feeds an ordinary grammatical selector without opcode expansion.
for my $fixture (
    [ q{no warnings; use warnings 'precedence'; my $a = 1; my $x = !$a == 1; 1;},       'eq' ],
    [ q{no warnings; use warnings 'precedence'; my $a = 1; my $x = !$a eq 1; 1;},       'seq' ],
    [ q{no warnings; use warnings 'precedence'; my $a = 1; my $x = !$a =~ s/1/2/r; 1;}, 'subst' ],
  )
{
    my ( $source, $operation ) = @$fixture;
    my @captured;
    {
        local $SIG{__EXCEPT__} = sub { push @captured, $_[0] };
        local $SIG{__WARN__}   = sub { };
        eval $source;
    }
    my ($item) = grep { $_->number == 2127 } map { @{ $_->contents } } @captured;
    ok( $item, "$operation produces a real precedence warning" );
    next unless $item;
    my $phrase      = $words->{languages}{cy}{words}{$operation}{forms}{after_and};
    my $conjunction = $words->{languages}{cy}{words}{$operation}{tags}{conjunction};
    my $saved       = snapshot($item);
    like(
        $item->render_as_legacy('cy'),
        qr/! \Q$conjunction\E \Q$phrase\E/,
        "$operation resolves the Welsh conjunction phrase"
    );
    ok(
        !grep( { $_->{name} eq 'operator_conjunction' } @{ $item->params } ),
        "$operation does not store the language-selected grammar value"
    );
    is( snapshot($item), $saved, "$operation grammar selection keeps canonical values" );
}

# Revisit every language on one nested tree to catch retained render state.
{
    my $parent = Storable::dclone($diagnostic);
    my $child  = Storable::dclone($welsh_lvalue);
    $parent->append($child);
    my $tree = XPerl::Exception->_new();
    $tree->append($parent);
    my $saved = snapshot($tree);
    my %first;
    my @languages = sort keys %{ $words->{languages} };

    for my $language ( @languages, reverse @languages ) {
        my $legacy = $tree->render_as_legacy($language);
        ok( length($legacy), "$language renders the nested vocabulary tree" );
        if ( exists $first{$language} ) {
            is( $legacy, $first{$language}, "$language repeats its original rendering after other languages" );
        }
        $first{$language} = $legacy;
        my $annotated = $tree->render_as_annotated($language);
        like( $annotated, qr/#1419/, "$language annotated tree retains diagnostic identity" );
        my @json = map { JSON::PP->new->decode($_) }
          grep { length } split /\n/, $tree->render("$language:legacy:JSON");
        ok(
            @json && !grep( { !length( $_->{message} ) } @json ),
            "$language JSON groups contain translated human messages"
        );
        my @dumper = grep { length } split /\n/, $tree->render("$language:legacy:Dumper");
        ok(
            @dumper && !grep( { $_ !~ /["']message["']\s*=>/ } @dumper ),
            "$language Dumper groups contain human messages"
        );
        is( snapshot($tree), $saved, "$language render modes leave the complete nested tree unchanged" );
    }
    is( $tree->render_as_legacy('xx'), $first{en}, 'nested language fallback repeats the complete English tree' );
}

done_testing();
