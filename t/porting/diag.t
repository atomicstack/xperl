#!/usr/bin/perl

BEGIN {
    @INC = -f "./TestInit.pm" ? (".") : ("..");
}
use TestInit qw(T);
use strict;
use warnings;
use charnames ':full';
use Config;
require "./t/test.pl";
require "./regen/diag_lib.pm";

skip_all("Not all files are available during cross-compilation")
    if $Config{usecrosscompile};

my @files = @ARGV ? @ARGV : Diag::Migration::source_files();
our ( $CONF, $META );
do './diag_conf.pl';
my $conf = $CONF;
my $diagnostics= Diag::Migration::diagnostics($conf);
my @format_errors= map {
    my $error= Diag::Migration::format_error($_);
    defined $error ? "$_->{code}: $error" : ()
} @$diagnostics;
my %fixed;
for my $diag (@$diagnostics) {
    next unless exists $diag->{variants};
    my %bound;
    $bound{$_} = 1 for map { keys %{$_->{values}} } values %{$diag->{variants}};
    my (@positions, $position);
    $position = 0;
    for my $param (@{$diag->{params}}) {
        push @positions, [$position, $param->{name}] if $bound{$param->{name}};
        $position += @{$param->{inputs} || [$param]};
    }
    $fixed{$_} = \@positions for Diag::Migration::macro_name($diag),
        map { Diag::Migration::alias_macro_name($diag, $_) } @{$diag->{emit}{aliases} || []};
}
my $shared_names = join '|', map { quotemeta $_ } sort keys %fixed;
my $translation_probe = {
    number => 9001,
    code   => 'TRANSLATION_PROBE',
    params => [
        {
            name           => 'kind',
            type           => 'text',
            format_str     => 's',
            selector_values => [ 'array', 'hash' ],
        },
        { name => 'name', type => 'text', format_str => 's' },
    ],
    message_selectors => ['kind'],
    message_template  => {
        en => {
            array => 'Array %{name}',
            hash  => 'Hash %{name}',
        },
        fr => {
            array => 'Tableau %{name}',
            hash  => 'Table %{name}',
        },
    },
};
my $french_rows = Diag::Migration::translation_table_rows( [$translation_probe], 'fr' );
my $fallback_rows = Diag::Migration::translation_table_rows( [$translation_probe], 'de' );
plan(tests => 3 + scalar @files);
ok(!@format_errors,
    'diagnostic formatter types match their formats and templates are valid');
diag($_) for @format_errors;
is(
    join( '|', map { $_->{translation} } @$french_rows ),
    'Tableau %{name}|Table %{name}',
    'translation rows select language templates by selector value'
);
is(
    join( "\n", map {
        join( '|', $_->{selectors}{kind}, $_->{translation}, $_->{language}, $_->{translated} )
      } @$fallback_rows ),
    "array|Array %{name}|en|0\nhash|Hash %{name}|en|0",
    'translation rows show English text when the target language is missing'
);
for my $file (@files) {
    die "Refusing path outside this checkout: $file\n"
        if $file =~ m!(?:^/|(?:^|/)\.\.(?:/|$))!;
    my $source = Diag::Migration::read_source($file);
    my @unmanaged = grep {
        $_->{name} =~ /^PERL_DIAG_(?:LEGACY_|DYNAMIC_YYERROR)/
            || !Diag::Migration::api_boundary($file, $_, $source)
    } Diag::Migration::calls($source, Diag::Migration::emitter_names());
    my @fixed_text;
    if (length $shared_names) {
        for my $call (Diag::Migration::calls($source, qr/$shared_names/)) {
            for my $position (@{$fixed{$call->{name}}}) {
                my ($index, $name) = @$position;
                my $arg = $call->{args}[$index];
                push @fixed_text, [$call, $name]
                    if defined $arg && $arg =~ /\A\s*(?:"(?:\\.|[^"\\])*"\s*)+\z/s;
            }
        }
    }
    my $control_source = Diag::Migration::mask_noncode($source);
    $control_source =~ s{ "(?:\\.|[^"\\])*" | '(?:\\.|[^'\\])*' }
        { $& =~ s/[^\n]/ /gr }gsex;
    my @raw_recovery;
    while ($control_source =~ /\bYYERROR\s*;/g) {
        push @raw_recovery, 1 + (substr($control_source, 0, $-[0]) =~ tr/\n//);
    }
    ok(!@unmanaged && !@fixed_text && !@raw_recovery,
        "$file uses managed diagnostic emitters");
    for my $call (@unmanaged) {
        diag("unmanaged $call->{name} at $file line $call->{line}");
    }
    for my $item (@fixed_text) {
        my ($call, $name) = @$item;
        diag("fixed $name text in $call->{name} at $file line $call->{line}; use a configured variant");
    }
    diag("unmanaged YYERROR at $file line $_; use a configured parser action")
        for @raw_recovery;
}
