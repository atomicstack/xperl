#!/usr/bin/perl

use 5.014;
use strict;
use warnings;
use FindBin;
use File::Spec;
use File::Path qw(make_path);
use Getopt::Long qw(GetOptions);
use Pod::Simple::XHTML;

my $output;
GetOptions('output=s' => \$output) && defined $output
    or die "Usage: perl Porting/render_except_docs.pl --output DIRECTORY\n";

my $root = File::Spec->catdir($FindBin::Bin, '..');
my $assets = File::Spec->catdir($FindBin::Bin, 'exception-docs');
my %pages = (
    (map { $_ => "pod/$_.pod" }
        qw(perlexcept perlexcephack perldiag perlvar perlsyn perlguts
           perlinterp perlhack perlhacktips)),
    (map { $_ => 'lib/' . s{::}{/}gr . '.pm' }
        qw(XPerl::Exception XPerl::Diagnostic XPerl::DiagGroup
           XPerl::DiagPack diagpack builtin warnings)),
);
my %captions = (
    containment => 'Inheritance and containment are separate relationships',
    construction => 'Catalog inputs, generated code, and runtime responsibilities',
    delivery => 'One delivery episode, from accumulation to disposition',
    hooks => 'Hook emissions and failures remain inside the delivery episode',
    rendering => 'Language choice and complete-message fallback',
    engines => 'Registered engines, captured engines, and independent plural queries',
);

sub read_file {
    my ($path) = @_;
    open my $in, '<:encoding(UTF-8)', $path or die "$path: $!\n";
    local $/;
    return <$in>;
}

sub write_file {
    my ($path, $text) = @_;
    open my $out, '>:encoding(UTF-8)', $path or die "$path: $!\n";
    print {$out} $text or die "$path: $!\n";
    close $out or die "$path: $!\n";
}

sub escape_html {
    my ($text) = @_;
    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    $text =~ s/"/&quot;/g;
    return $text;
}

sub page_file {
    my ($name) = @_;
    $name =~ s/::/-/g;
    return "$name.html";
}

{
    package ExceptDocs::XHTML;
    use parent 'Pod::Simple::XHTML';

    sub resolve_pod_page_link {
        my ($self, $to, $section) = @_;
        if (defined $to && exists $pages{$to}) {
            my $anchor = defined $section
                ? '#' . $self->idify($self->encode_entities($section), 1)
                : '';
            return main::page_file($to) . $anchor;
        }
        return $self->SUPER::resolve_pod_page_link($to, $section);
    }
}

make_path($output);
write_file(File::Spec->catfile($output, 'style.css'),
           read_file(File::Spec->catfile($assets, 'style.css')));

my %diagrams;
for my $name (sort keys %captions) {
    my $source = File::Spec->catfile($assets, "$name.dot");
    open my $dot, '-|', 'dot', '-Tsvg', $source
        or die "Cannot run Graphviz dot: $!\n";
    binmode $dot, ':encoding(UTF-8)';
    my $svg = do { local $/; <$dot> };
    close $dot or die "Graphviz failed for $source\n";
    $svg =~ s/\A.*?(?=<svg\s)//s;
    $svg =~ /<svg\s/ or die "Graphviz returned no SVG for $source\n";
    write_file(File::Spec->catfile($output, "$name.svg"), $svg);

    # Inline diagrams share a document, so Graphviz IDs need local prefixes.
    $svg =~ s/\bid="([^"]+)"/id="$name-$1"/g;
    $svg =~ s/((?:xlink:)?href="#)([^"]+)"/$1$name-$2"/g;
    $svg =~ s/<svg\s/<svg role="img" aria-labelledby="$name-caption" /;
    $diagrams{$name} = '<figure class="diagram">' . $svg
        . '<figcaption id="' . $name . '-caption">'
        . escape_html($captions{$name}) . ' &middot; <a href="' . $name
        . '.svg">Open full size</a></figcaption></figure>';
}

my $nav = '<nav aria-label="Manuals"><a href="index.html">Exception docs</a>'
    . '<a href="perlexcept.html">Perl programs</a>'
    . '<a href="perlexcephack.html">Internals</a></nav>';
for my $name (sort keys %pages) {
    my $source = $pages{$name};
    my $title = escape_html($name);
    my $parser = ExceptDocs::XHTML->new;
    $parser->html_header('<!doctype html><html lang="en"><head>'
        . '<meta charset="utf-8"><meta name="viewport" '
        . 'content="width=device-width, initial-scale=1">'
        . '<title>' . $title . '</title><link rel="stylesheet" href="style.css">'
        . '</head><body>' . $nav . '<main><p class="source">Generated from '
        . escape_html($source) . '</p>');
    $parser->html_footer('</main></body></html>');
    $parser->index(1);
    $parser->anchor_items(1);
    $parser->perldoc_url_prefix('https://perldoc.perl.org/');
    $parser->perldoc_url_postfix('');
    my $html;
    $parser->output_string(\$html);
    $parser->parse_file(File::Spec->catfile($root, split m{/}, $source));
    $parser->any_errata_seen and die "POD errors in $source\n";
    $html =~ s{(<ul id="index">.*?</ul>)(\s*<h1)}{
        '<details class="toc"><summary>On this page</summary>' . $1
            . '</details>' . $2
    }se;
    $html =~ s{<!--\s*diagram:([a-z]+)\s*-->}{
        $diagrams{$1} // die "Unknown diagram $1 in $source\n"
    }ge;
    write_file(File::Spec->catfile($output, page_file($name)), $html);
}

my $index = '<!doctype html><html lang="en"><head><meta charset="utf-8">'
    . '<meta name="viewport" content="width=device-width, initial-scale=1">'
    . '<title>Structured exceptions</title>'
    . '<link rel="stylesheet" href="style.css"></head><body>' . $nav
    . '<main><h1>Structured exceptions</h1>'
    . '<p>Illustrated manuals for the current XPerl development tree.</p>'
    . '<div class="manuals"><article><h2><a href="perlexcept.html">'
    . 'Writing Perl programs</a></h2><p>Catch and inspect exceptions, use '
    . 'hooks, select languages, and choose text or structured output.</p></article>'
    . '<article><h2><a href="perlexcephack.html">Working on the internals</a>'
    . '</h2><p>Catalogs, capture, ownership, delivery, engine contracts, '
    . 'fallback, generated data, and verification.</p></article></div>'
    . '<h2>Reference pages</h2><ul>';
for my $name (sort grep { !/^perlexcep/ } keys %pages) {
    $index .= '<li><a href="' . page_file($name) . '">'
        . escape_html($name) . '</a></li>';
}
$index .= '</ul><p>Text is generated from the source POD. Diagrams are '
    . 'generated from Porting/exception-docs/*.dot. Bundled pages and diagrams '
    . 'work offline; links to other Perl manuals use perldoc.perl.org.</p>'
    . '</main></body></html>';
write_file(File::Spec->catfile($output, 'index.html'), $index);
print "Wrote illustrated manuals to $output/index.html\n";

__END__

=head1 NAME

render_except_docs.pl - Generate illustrated HTML exception manuals

=head1 SYNOPSIS

    perl Porting/render_except_docs.pl --output ../tmp/exception-docs

=head1 DESCRIPTION

Run with the environment Perl. Requires Pod::Simple::XHTML and Graphviz
C<dot>. Reads the source-tree POD and the adjacent F<exception-docs/>
assets. Writes an HTML bundle with inline SVG, a stylesheet, and local
reference pages to the specified directory. No network access is needed.
Generated HTML is a review artifact, not another source for the prose.

=cut
