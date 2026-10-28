#!/usr/bin/perl

# Bootstrap the declarative documentation from a saved perldiag.pod. Normal
# regeneration reads the imported data, never the generated POD file.

use strict;
use warnings;
use Data::Dumper;
require './regen/diag_lib.pm';
require './regen/diag_pod.pm';

my ($source, $target) = @ARGV;
$source = 'pod/perldiag.pod' unless defined $source;
$target = 'diag_pod.pl' unless defined $target;
die "Usage: $0 [source.pod [target.pl]]\n" if @ARGV > 2;
die "Refusing to replace $target\n" if -e $target;
my $pod = Diag::Migration::read_source($source);
my $data = Diag::Documentation::import_pod($pod);
die "diagnostic documentation import changed bytes\n"
    unless Diag::Documentation::render($data) eq $pod;
open my $out, '>', $target or die "Can't write $target: $!\n";
print {$out} "# Diagnostic documentation data. Edit here and run perl regen/diag.pl.\n\nreturn ",
    Data::Dumper->new([$data])->Terse(1)->Indent(1)->Sortkeys(1)->Useqq(1)->Dump;
close $out or die "Can't close $target: $!\n";
my $headings = 0;
for my $entry (@{$data->{entries}}) {
    $headings += @{$entry->{headings}};
}
print "$headings headings in ", scalar(@{$data->{entries}}), " shared explanations imported into $target\n";
