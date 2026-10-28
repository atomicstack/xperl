#!./perl -w

use strict;
use warnings;
use utf8;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP;
use Digest::SHA qw(sha256_hex);

BEGIN {
    push @INC, '.' if -f './TestInit.pm';
    push @INC, '..' if -f '../TestInit.pm';
}
use TestInit qw(T);
require './t/test.pl';
plan('no_plan');

my $root = 'lib/unicore/cldr';
my $table = "$root/plural.pl";
our $CLDR_DATA;
my $loaded = do "./$table";
ok($loaded, 'generated table loads') or diag($@ || $!);
my $data = $CLDR_DATA;
is($data->{version}{cldr}, '49', 'CLDR version is recorded');
is($data->{version}{package}, '49.0.0', 'package version is recorded');
is($data->{version}{unicode}, '16.0.0', 'package Unicode version is recorded');
open my $version_fh, '<:raw', "$root/version" or die $!;
is(do { local $/; <$version_fh> }, "49\n", 'release pin matches CLDR metadata');
close $version_fh;
is(scalar keys %{$data->{cardinal}{locales}}, 225, 'cardinal locale count');
is(scalar keys %{$data->{cardinal}{rules}}, 39, 'cardinal rule set count');
is(scalar keys %{$data->{ordinal}{locales}}, 109, 'ordinal locale count');
is(scalar keys %{$data->{ordinal}{rules}}, 28, 'ordinal rule set count');
is(scalar keys %{$data->{plural_parents}{cardinal}}, 11,
    'cardinal parent exceptions are limited to regional differences');
is(scalar keys %{$data->{plural_parents}{ordinal}}, 0,
    'ordinal rules need no regional parent exceptions');
is($data->{plural_parents}{cardinal}{'pt-AO'}, 'pt-PT',
    'Portuguese regional parent points to pt-PT');
ok(!exists $data->{plural_parents}{cardinal}{'pt-BR'},
    'pt-BR uses ordinary subtag fallback');
ok(!exists $data->{cardinal}{locales}{'pt-BR'}
        && exists $data->{cardinal}{locales}{pt},
    'pt-BR resolves to the explicit pt rule after subtag removal');
ok(!exists $data->{plural_parents}{cardinal}{'en-AU'},
    'redundant English parent is omitted');
is($data->{provenance}{plural_parent_source}{path},
    'supplemental/parentLocales.json', 'source path is recorded');
is($data->{provenance}{plural_parent_source}{sha256},
    'e6d0da73b9e49dec3d9b94ed0bc16e7704b2efb769b7094c9c238cd654afb191',
    'source hash is recorded');

my $pt = $data->{cardinal}{rules}{$data->{cardinal}{locales}{pt}};
my $pt_pt = $data->{cardinal}{rules}{$data->{cardinal}{locales}{'pt-PT'}};
is($pt->{one}{condition}, 'i = 0..1', 'pt treats zero as one');
is($pt_pt->{one}{condition}, 'i = 1 and v = 0',
    'pt-PT does not treat zero as one');

my $ar_rules = $data->{cardinal}{rules}
    {$data->{cardinal}{locales}{ar}};
is($ar_rules->{few}{condition}, 'n % 100 = 3..10',
    'condition expression is retained');
is(join(' ', @{$ar_rules->{few}{integer_samples}{values}}),
    '3~10 103~110 1003', 'plain integer sample bounds keep exact text');
is($ar_rules->{few}{decimal_samples_text},
    '3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 103.0, 1003.0, …',
    'decimal sample text is retained');
ok($ar_rules->{few}{integer_samples}{infinite},
    'integer sample ellipsis is retained as a non-exhaustive marker');

my $cs_rules = $data->{cardinal}{rules}
    {$data->{cardinal}{locales}{cs}};
is($cs_rules->{many}{condition}, 'v != 0',
    'decimal-only category keeps its condition');
is($cs_rules->{many}{decimal_samples_text},
    '0.0~1.5, 10.0, 100.0, 1000.0, 10000.0, 100000.0, 1000000.0, …',
    'decimal-only category keeps its decimal samples');
is(scalar @{$cs_rules->{many}{integer_samples}{values}}, 0,
    'decimal-only category has no integer samples');

my $ru_rules = $data->{cardinal}{rules}
    {$data->{cardinal}{locales}{ru}};
is($ru_rules->{other}{condition}, '',
    'other category can contain decimal samples and no condition');
is($ru_rules->{other}{decimal_samples_text},
    '0.0~1.5, 10.0, 100.0, 1000.0, 10000.0, 100000.0, 1000000.0, …',
    'other category keeps decimal-only samples');

my @compact;
my @plain;
for my $id (keys %{$data->{cardinal}{rules}}) {
    for my $category (keys %{$data->{cardinal}{rules}{$id}}) {
        push @compact, @{$data->{cardinal}{rules}{$id}{$category}
            {integer_samples}{compact}};
        push @plain, @{$data->{cardinal}{rules}{$id}{$category}
            {integer_samples}{values}};
    }
}
ok(scalar @compact, 'compact integer samples are kept in a separate field');
ok(!(grep { /[cCeE]/ } @plain), 'compact samples are not plain integer samples');

{
    local $ENV{PERL5LIB} = '';
    local $ENV{PERL5OPT} = '';
    is(system('perl', 'Porting/update_cldr.pl', '--check'), 0,
        'retained inputs match generated table');
}

my $tmp = tempdir('cldr-import-XXXXXX', DIR => '../tmp', CLEANUP => 1);
my $good_output = File::Spec->catdir($tmp, 'good-output');
make_path($good_output);
{
    local $ENV{PERL5LIB} = '';
    local $ENV{PERL5OPT} = '';
    is(system('perl', 'Porting/update_cldr.pl', '--source-dir', $root,
        '--output-dir', $good_output), 0, 'local package import succeeds');
}
open my $generated_fh, '<:raw', $table or die $!;
my $retained_table = do { local $/; <$generated_fh> };
close $generated_fh;
open my $imported_fh, '<:raw', "$good_output/plural.pl" or die $!;
is(do { local $/; <$imported_fh> }, $retained_table,
    'source import reproduces the retained generated table');
close $imported_fh;
open $version_fh, '<:raw', "$good_output/version" or die $!;
is(do { local $/; <$version_fh> }, "49\n", 'source import writes the release pin');
close $version_fh;

my $regional_source = File::Spec->catdir($tmp, 'regional-source');
my $status;
my $regional_supplemental = copy_cldr_source($root, $regional_source);
my $parent_path = File::Spec->catfile($regional_supplemental, 'parentLocales.json');
my $parent_document = {
    supplemental => {
        version => { _cldrVersion => '49', _unicodeVersion => '16.0.0' },
        parentLocales => {
            parentLocale => {
                'pt-AO' => 'pt',
                'pt' => 'pt-PT',
                'en-AU' => 'en-001',
                'zz-AO' => 'zz-PT',
            },
            plurals => { 'pt-AO' => 'pt-PT' },
        },
    },
};
my $parent_source_hash = sha256_hex(write_json($parent_path, $parent_document));
my $regional_output = File::Spec->catdir($tmp, 'regional-output');
make_path($regional_output);
{
    local $ENV{PERL5LIB} = '';
    local $ENV{PERL5OPT} = '';
    $status = system('perl', 'Porting/update_cldr.pl', '--source-dir',
        $regional_source, '--output-dir', $regional_output);
}
is($status, 0, 'full parentLocales source is filtered');
my $regional_loaded = do "./$regional_output/plural.pl";
ok($regional_loaded, 'filtered parent table loads') or diag($@ || $!);
my $regional_data = $CLDR_DATA->{plural_parents};
is(scalar keys %{$regional_data->{cardinal}}, 1,
    'only the cardinal rule-changing parent is retained');
is($regional_data->{cardinal}{'pt-AO'}, 'pt-PT',
    'plural-specific parent overrides the general parent');
is(scalar keys %{$regional_data->{ordinal}}, 0,
    'parent with unchanged ordinal rules is omitted');
ok(!exists $regional_data->{cardinal}{'pt'},
    'locale with its own rule row is omitted');
ok(!exists $regional_data->{cardinal}{'en-AU'},
    'parent with the same rule as subtag fallback is omitted');
ok(!exists $regional_data->{cardinal}{'zz-AO'},
    'parent without an explicit rule target is omitted');
is($CLDR_DATA->{provenance}{plural_parent_source}{sha256},
    $parent_source_hash, 'full parentLocales source hash is preserved');

my $parent_sentinel = 'existing generated output';
open my $regional_fh, '>:raw', "$regional_output/plural.pl" or die $!;
print {$regional_fh} $parent_sentinel;
close $regional_fh;
$parent_document->{supplemental}{version}{_cldrVersion} = '48';
write_json($parent_path, $parent_document);
{
    local $ENV{PERL5LIB} = '';
    local $ENV{PERL5OPT} = '';
    $status = system('perl', 'Porting/update_cldr.pl', '--source-dir',
        $regional_source, '--output-dir', $regional_output);
}
ok($status != 0, 'parentLocales version mismatch is rejected');
open $regional_fh, '<:raw', "$regional_output/plural.pl" or die $!;
is(do { local $/; <$regional_fh> }, $parent_sentinel,
    'parentLocales version mismatch leaves output unchanged');
close $regional_fh;

my $bad_source = File::Spec->catdir($tmp, 'source');
my $bad_supplemental = File::Spec->catdir($bad_source, 'supplemental');
my $bad_output = File::Spec->catdir($tmp, 'output');
make_path($bad_supplemental, $bad_output);
for my $file (qw(package.json LICENSE)) {
    copy("$root/$file", "$bad_source/$file") or die "copy $file: $!";
}
for my $file (qw(plurals.json ordinals.json)) {
    copy("$root/$file", "$bad_supplemental/$file") or die "copy $file: $!";
}
copy("$root/pluralParents.json", "$bad_source/pluralParents.json") or die "copy parents: $!";
mutate_json("$bad_supplemental/plurals.json", sub {
    $_[0]{supplemental}{version}{_cldrVersion} = '48';
});
my $sentinel = 'do not replace on validation error';
open my $out_fh, '>', "$bad_output/plural.pl" or die $!;
print {$out_fh} $sentinel;
close $out_fh;
{
    local $ENV{PERL5LIB} = '';
    local $ENV{PERL5OPT} = '';
    $status = system('perl', 'Porting/update_cldr.pl', '--source-dir',
        $bad_source, '--output-dir', $bad_output);
}
ok($status != 0, 'mixed-version supplemental input is rejected');
open $out_fh, '<', "$bad_output/plural.pl" or die $!;
is(do { local $/; <$out_fh> }, $sentinel,
    'invalid source leaves existing output unchanged');
close $out_fh;

my $bad_category_source = File::Spec->catdir($tmp, 'bad-category-source');
my $bad_category_supplemental = File::Spec->catdir($bad_category_source, 'supplemental');
make_path($bad_category_supplemental);
for my $file (qw(package.json LICENSE)) {
    copy("$root/$file", "$bad_category_source/$file") or die "copy $file: $!";
}
for my $file (qw(plurals.json ordinals.json)) {
    copy("$root/$file", "$bad_category_supplemental/$file") or die "copy $file: $!";
}
copy("$root/pluralParents.json", "$bad_category_source/pluralParents.json")
    or die "copy parents: $!";
mutate_json("$bad_category_supplemental/plurals.json", sub {
    my $rules = $_[0]{supplemental}{'plurals-type-cardinal'}{en};
    $rules->{'pluralRule-count-invalid'} = $rules->{'pluralRule-count-one'};
});
my $bad_category_output = File::Spec->catdir($tmp, 'bad-category-output');
make_path($bad_category_output);
open $out_fh, '>', "$bad_category_output/plural.pl" or die $!;
print {$out_fh} $sentinel;
close $out_fh;
{
    local $ENV{PERL5LIB} = '';
    local $ENV{PERL5OPT} = '';
    $status = system('perl', 'Porting/update_cldr.pl', '--source-dir',
        $bad_category_source, '--output-dir', $bad_category_output);
}
ok($status != 0, 'unknown plural category is rejected');
open $out_fh, '<', "$bad_category_output/plural.pl" or die $!;
is(do { local $/; <$out_fh> }, $sentinel,
    'invalid category leaves existing output unchanged');
close $out_fh;

my $check_output = File::Spec->catdir($tmp, 'check');
make_path($check_output);
for my $file (qw(package.json LICENSE plurals.json ordinals.json)) {
    copy("$root/$file", "$check_output/$file") or die "copy $file: $!";
}
copy("$root/pluralParents.json", "$check_output/pluralParents.json")
    or die "copy parents: $!";
copy("$root/version", "$check_output/version") or die "copy version: $!";
open $out_fh, '>', "$check_output/plural.pl" or die $!;
print {$out_fh} $sentinel;
close $out_fh;
open $version_fh, '>', "$check_output/version" or die $!;
print {$version_fh} "48\n";
close $version_fh;
{
    local $ENV{PERL5LIB} = '';
    local $ENV{PERL5OPT} = '';
    $status = system('perl', 'Porting/update_cldr.pl', '--check',
        '--output-dir', $check_output);
}
ok($status != 0, 'check mode rejects a release pin mismatch');
open $out_fh, '<', "$check_output/plural.pl" or die $!;
is(do { local $/; <$out_fh> }, $sentinel,
    'release pin mismatch leaves output unchanged');
close $out_fh;
open $version_fh, '>', "$check_output/version" or die $!;
print {$version_fh} "49\n";
close $version_fh;

my $wide = '184467440737095516160';
my $precision_source = File::Spec->catdir($tmp, 'precision-source');
my $precision_supplemental = copy_cldr_source($root, $precision_source);
mutate_json("$precision_supplemental/plurals.json", sub {
    $_[0]{supplemental}{'plurals-type-cardinal'}{en}
        {'pluralRule-count-one'} = "n = 1 \@integer $wide";
});
my $precision_output = File::Spec->catdir($tmp, 'precision-output');
make_path($precision_output);
{
    local $ENV{PERL5LIB} = '';
    local $ENV{PERL5OPT} = '';
    $status = system('perl', 'Porting/update_cldr.pl', '--source-dir',
        $precision_source, '--output-dir', $precision_output);
}
is($status, 0, 'large decimal strings import successfully');
my $precision_table = "./$precision_output/plural.pl";
my $precision_loaded = do $precision_table;
ok($precision_loaded, 'synthetic precision table loads') or diag($@ || $!);
my $precision_data = $CLDR_DATA;
is($precision_data->{cardinal}{rules}
        {$precision_data->{cardinal}{locales}{en}}{one}
        {integer_samples}{values}[0], $wide,
    'integer sample larger than UV_MAX keeps its exact decimal value');
sub mutate_json {
    my ($path, $change) = @_;
    open my $fh, '<:raw', $path or die $!;
    my $data = decode_json(do { local $/; <$fh> });
    close $fh;
    $change->($data);
    open $fh, '>:raw', $path or die $!;
    print {$fh} JSON::PP->new->canonical->utf8->encode($data);
    close $fh;
}

sub write_json {
    my ($path, $data) = @_;
    my $bytes = JSON::PP->new->canonical->pretty->utf8->encode($data);
    open my $fh, '>:raw', $path or die $!;
    print {$fh} $bytes;
    close $fh;
    return $bytes;
}

sub copy_cldr_source {
    my ($root, $source) = @_;
    my $supplemental = File::Spec->catdir($source, 'supplemental');
    make_path($supplemental);
    for my $file (qw(package.json LICENSE)) {
        copy("$root/$file", "$source/$file") or die "copy $file: $!";
    }
    for my $file (qw(plurals.json ordinals.json)) {
        copy("$root/$file", "$supplemental/$file") or die "copy $file: $!";
    }
    copy("$root/pluralParents.json", "$source/pluralParents.json")
        or die "copy parents: $!";
    return $supplemental;
}
{
    local $ENV{PERL5LIB} = '';
    local $ENV{PERL5OPT} = '';
    $status = system('perl', 'Porting/update_cldr.pl', '--check',
        '--output-dir', $check_output);
}
ok($status != 0, 'check mode detects a generated table mismatch');
open $out_fh, '<', "$check_output/plural.pl" or die $!;
is(do { local $/; <$out_fh> }, $sentinel,
    'check mode leaves mismatched output unchanged');
close $out_fh;
