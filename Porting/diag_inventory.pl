#!/usr/bin/perl

# Inventory diagnostic calls with the same lexer used by the bulk converter.

use strict;
use warnings;
require './regen/diag_lib.pm';
my $macros = Diag::Migration::format_macros();
my $constants = Diag::Migration::format_constants();
my %entries;
for my $file (@ARGV ? @ARGV : Diag::Migration::source_files()) {
    die "Refusing path outside this checkout: $file\n" if $file =~ m!(?:^/|(?:^|/)\.\.(?:/|$))!;
    my $source = Diag::Migration::read_source($file);
    my %file_constants = (%$constants, %{Diag::Migration::local_format_constants($source)});
    for my $call (Diag::Migration::calls($source, Diag::Migration::emitter_names())) {
        next if Diag::Migration::api_boundary($file, $call, $source);
        (my $emitter = $call->{name}) =~ s/^(?:PERL_DIAG_LEGACY_|Perl_)//;
        my ($expr, @values) = @{$call->{args}};
        my $category = '';
        $expr =~ s/^aTHX_\s*// if $call->{name} =~ /^Perl_/;
        # Warning categories precede the message format.
        if ($emitter =~ /^(?:(?:ck_)?warner|fatal_warner)/) {
            $category = $expr;
            $category =~ s/\s+/ /g;
            ($expr, @values) = @values;
        }
        $expr = Diag::Migration::resolve_format($expr, \%file_constants);
        my $parsed = Diag::Migration::parse_format($expr, \@values, $macros);
        my $type = !$parsed ? 'dynamic-or-unsupported'
            : !@{$parsed->{params}} ? 'literal'
            : (grep { $_->{inputs} } @{$parsed->{params}}) ? 'compound-format'
            : 'simple-format';
        my $text = $parsed ? $parsed->{message_template}{en} : $expr;
        $text =~ s/\n/\\n/g;
        $text =~ s/\t/\\t/g;
        my $key = join "\0", $emitter, $type, $text, $category;
        my $entry = $entries{$key} ||= { emitter => $emitter, type => $type,
            text => $text, category => $category, locations => [] };
        push @{$entry->{locations}}, "$file:$call->{line}";
    }
}
print "emitter\tcount\ttype\ttemplate\tcategory\tsources\n";
for my $entry (sort {
    @{$b->{locations}} <=> @{$a->{locations}}
        || $a->{emitter} cmp $b->{emitter} || $a->{text} cmp $b->{text}
} values %entries) {
    print join("\t", $entry->{emitter}, scalar @{$entry->{locations}},
        $entry->{type}, $entry->{text}, $entry->{category}, @{$entry->{locations}}), "\n";
}
