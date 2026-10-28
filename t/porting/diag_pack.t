#!./perl

BEGIN {
    @INC = -f './TestInit.pm' ? ('.') : ('..');
}
use TestInit qw(T);
use strict;
use warnings;
use utf8;
use charnames ':full';
require './t/test.pl';
require './regen/diag.pl';
require './regen/diag_pack.pm';

our ( $CONF, $META );
do './diag_conf.pl';
die 'Cannot load the diagnostic catalog' unless ref($CONF) eq 'HASH';

require File::Path;
require File::Temp;
require Storable;

my @all_languages      = sort keys %{ $CONF->{languages} };
my @source_diagnostics = grep { $_->{number} == 2479 || $_->{number} == 2127 } @{ Diag::Migration::diagnostics($CONF) };
my $base_diagnostics   = Storable::dclone( \@source_diagnostics );
my $changed_diagnostics = Storable::dclone( \@source_diagnostics );
my ($changed_plural)    = grep { $_->{number} == 2479 } @$changed_diagnostics;
my ($changed_words)     = grep { $_->{number} == 2127 } @$changed_diagnostics;

$changed_plural->{message_template}{de}{21}        = 'Einundzwanzig Diagnoseelemente wurden ausgelassen';
$changed_words->{operation_words}{arg1}{rules}{de} = 'stage4_gender';
$changed_words->{message_template}{de}             = {
    epicene => 'Neue Form für %{arg1}',
    '*'     => 'Allgemeine Form für %{arg1}',
};

sub ordered_output {
    my ($diagnostics) = @_;
    my @table = sort { $a->{code} cmp $b->{code} } @$diagnostics;
    my %index;
    @index{ map { $_->{code} } @table } = 1 .. @table;
    my $layouts = build_selector_layouts($diagnostics);
    my %warning_categories =
      map { $_ => 1 } Diag::Migration::read_source('warnings.h') =~ /^#define\s+(WARN_\w+)\s+\d+/mg;
    my $helpers = build_helpers( $diagnostics, \%warning_categories );
    return {
        diagnostics => $diagnostics,
        table       => \@table,
        layouts     => $layouts,
        header      => render_header( $diagnostics, \@table, \%index, $helpers, \%warning_categories, $layouts ),
        helpers     => render_helpers($helpers),
    };
}

sub generate_all_packs {
    my ( $output, $root ) = @_;
    File::Path::make_path("$root/ext");
    Diag::Pack::generate( \@all_languages, $output->{diagnostics},
        $output->{table}, $output->{layouts}, $CONF->{languages}, $CONF->{plural_rules}, $root );
}

sub selector_layout_signature {
    my ($layouts) = @_;
    return join "\n", map {
        my $layout = $layouts->{$_};
        join "\t", $_,
          map { join ':', $_->{owner_number}, $_->{owner_column}, $_->{domain_id}, @{ $_->{values} } }
          @{ $layout->{domains} || [] };
    } sort keys %$layouts;
}

sub read_raw {
    my ($path) = @_;
    open my $file, '<:raw', $path or die "Cannot read generated pack file $path: $!\n";
    local $/;
    my $text = <$file>;
    close $file or die "Cannot close generated pack file $path: $!\n";
    return $text;
}

my $base_output = ordered_output($base_diagnostics);
is(
    selector_layout_signature( build_selector_layouts( [ reverse @$base_diagnostics ] ) ),
    selector_layout_signature( $base_output->{layouts} ),
    'canonical selector domains do not depend on caller diagnostic order'
);
my $base_root   = File::Spec->rel2abs( File::Temp::tempdir( DIR => '../tmp', CLEANUP => 1 ) );
generate_all_packs( $base_output, $base_root );

my $dump_diagnostics = Storable::dclone($base_diagnostics);
my ($dump_plural) = grep { $_->{number} == 2479 } @$dump_diagnostics;
$dump_plural->{message_template}{en}{0}  = 'English exact zero';
$dump_plural->{message_template}{fr}{21} = 'French exact twenty-one';
my $dump_output = ordered_output($dump_diagnostics);
my $dump_root   = File::Spec->rel2abs( File::Temp::tempdir( DIR => '../tmp', CLEANUP => 1 ) );
File::Path::make_path("$dump_root/ext");
Diag::Pack::generate( ['fr'], $dump_diagnostics, $dump_output->{table}, $dump_output->{layouts},
    $CONF->{languages}, $CONF->{plural_rules}, $dump_root );
my $template_dump_path = "$dump_root/templates.tsv";
write_template_dump( $dump_diagnostics, $template_dump_path );
my $template_dump        = read_raw($template_dump_path);
my ($french_language_id) = $template_dump =~ /^# language (0x[0-9a-f]+)=fr$/m;
my $dump_number          = sprintf '0x%x', $dump_plural->{number};
my ($french_exact_key) =
  $template_dump =~ /^\Q$french_language_id\E\t\Q$dump_number\E\t(0x[0-9a-f]+)\tFrench exact twenty-one$/m;
my $french_data = read_raw("$dump_root/ext/XPerl-DiagPack-FR/FR_data.inc");
my ($compiled_exact_id) =
  $french_data =~ /#define PERL_DIAG_PLURAL_SELECTOR_fr_2479_0\(n\) \\\n\s+\(\(n\) == UINT64_C\(21\) \? \(IV\)(\d+) :/;
ok( defined($french_exact_key),  'template dump includes the French exact-count case' );
ok( defined($compiled_exact_id), 'French pack compiles its local exact-count ID' );
is( hex( substr( $french_exact_key, 2 ) ),
    $compiled_exact_id, 'French template dump key matches the pack-local exact-count ID' );
isnt( $dump_output->{layouts}{ $dump_plural->{code} }{ids}[0]{21},
    $compiled_exact_id, 'foreign exact counts distinguish global and French-local plural IDs' );

my $word_data = Diag::Words::catalog();
my $german    = $word_data->{languages}{de};
local $german->{tags}{gender}         = [ @{ $german->{tags}{gender} }, 'epicene' ];
local $german->{rules}{stage4_gender} = {
    form   => 'dative',
    select => { conjunction => { tag => 'gender', fallback => '*' } },
};
local $german->{words}{eq}{forms}{dative} = 'eine eigensinnige Gleichheit';
local $german->{words}{eq}{tags}{gender}  = 'epicene';

my $word_domains = Diag::Words::rule_selector_domains( $changed_words, $word_data );
for my $definition ( @{ $changed_words->{selector_definitions} } ) {
    next unless $definition->{operation_word};
    $definition->{values} = $word_domains->{ $definition->{name} };
}
my $changed_output = ordered_output($changed_diagnostics);
my $changed_root   = File::Spec->rel2abs( File::Temp::tempdir( DIR => '../tmp', CLEANUP => 1 ) );
generate_all_packs( $changed_output, $changed_root );

is( $changed_output->{header}, $base_output->{header}, 'German plural cases and tags leave producer enums unchanged' );
is(
    $changed_output->{helpers},
    $base_output->{helpers},
    'German plural cases and tags leave producer helper bodies unchanged'
);

my $german_before = "$base_root/ext/XPerl-DiagPack-DE/DE_data.inc";
my $german_after  = "$changed_root/ext/XPerl-DiagPack-DE/DE_data.inc";
my $before_text   = read_raw($german_before);
my $after_text    = read_raw($german_after);
isnt( $after_text, $before_text, 'adding a German exact count and grammatical tag changes German generated data' );
like(
    $after_text,
    qr/Einundzwanzig Diagnoseelemente wurden ausgelassen/,
    'German pack contains the new exact-count case'
);
like( $after_text, qr/eigensinnige Gleichheit/, 'German pack contains the new grammatical word form' );
unlike( $before_text, qr/eigensinnige Gleichheit/, 'baseline German pack has no unrequested form' );
like( $after_text, qr/Language-scoped rendered data SHA-256:/, 'German pack records its rendered-data digest' );

for my $language ( grep { $_ ne 'de' } @all_languages ) {
    my $uppercase = uc $language;
    for my $file ( "${uppercase}_data.inc", "$uppercase.xs", "$uppercase.pm", 'Makefile.PL' ) {
        my $first  = "$base_root/ext/XPerl-DiagPack-$uppercase/$file";
        my $second = "$changed_root/ext/XPerl-DiagPack-$uppercase/$file";
        is( read_raw($second), read_raw($first), "$language $file including provenance remains byte-identical" );
    }
}

done_testing();
