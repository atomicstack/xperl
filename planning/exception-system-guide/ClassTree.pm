package ClassTree;

use strict;
use warnings;
use utf8;
use charnames ':full';
use Exporter 'import';
use Cwd qw(getcwd);
use Encode qw(decode encode);
use File::Basename qw(dirname);
use File::Spec;
use JSON::PP ();
use POSIX qw(strftime);
use BenchUtils qw(absolute read_text write_text read_json write_json run source_info);
use SourceOwners qw(definition_index enclosing_definition);
our @EXPORT_OK = qw(read_rows english_templates template_cases source_contexts tree_data
    review_evidence render_class_tree);

sub read_rows {
    my ($path) = @_;
    my $text = decode('UTF-8', read_text($path));
    my (@records, @row);
    pos($text) = 0;
    while (pos($text) < length $text) {
        next if !@row && $text =~ /\G\r?\n/gc;
        my $field;
        if ($text =~ /\G"((?:[^"]|"")*)"(?=\t|\r?\n|\z)/gc) {
            $field = $1;
            $field =~ s/""/"/g;
        }
        elsif ($text =~ /\G([^"\t\r\n]*)(?=\t|\r?\n|\z)/gc) { $field = $1 }
        else { die "Invalid TSV in $path near ".pos($text)."\n" }
        push @row, $field;
        if ($text =~ /\G\t/gc) {
            push @row, '' if pos($text) == length $text;
            next if pos($text) < length $text;
        }
        else { $text =~ /\G\r?\n/gc }
        push @records, [@row];
        @row = ();
    }
    my $columns = shift @records or return [];
    return [map {
        my %row;
        @row{@$columns} = @$_;
        \%row;
    } @records];
}

sub english_templates {
    my ($planning) = @_;
    my $root = absolute("$planning/..");
    my $cwd = getcwd();
    chdir $root or die "Cannot chdir $root: $!\n";
    my $result = eval { load_templates("$root/diag_conf.pl") };
    my $error = $@;
    chdir $cwd or die "Cannot restore $cwd: $!\n";
    die $error if $error;
    return $result;
}

sub load_templates {

    our ($CONF, $META);
    my ($path) = @_;
    my $loaded = do $path;
    die $@ if $@;
    die "Cannot load $path: $!\n" unless defined $loaded;
    require './regen/diag_lib.pm';
    my $diagnostics = Diag::Migration::diagnostics($CONF);
    my $references = Diag::Migration::diagnostic_source_references($diagnostics);
    my %templates;
    for my $diag (@$diagnostics) {
        my $files = $references->{$diag->{code}} || {};
        $templates{$diag->{code}} = {
            templates => $diag->{message_template}{en},
            selectors => $diag->{message_selectors} || [],
            selector_details => [map {
                my $column = $_;
                my $definition = $diag->{selector_definitions}[$column];
                +{
                    name => $diag->{message_selectors}[$column],
                    source => $definition->{source} || $definition->{name},
                    values => Diag::Migration::selector_column_values($diag, $column),
                    plural => $definition->{plural} || '',
                    conditional => ref($definition->{values}) eq 'HASH' ? 1 : 0,
                }
            } 0 .. $#{ $diag->{message_selectors} || [] }],
            word_bindings => [map {
                my $name = $_;
                my $binding = $diag->{operation_words}{$name};
                my $vocabulary = Diag::Words::catalog();
                +{
                    name => $name, source => $binding->{source},
                    operations => $binding->{operations},
                    assert_unknown => $binding->{assert_unknown} ? 1 : 0,
                    selectors => $binding->{selectors},
                    rules => [map {
                        my $language = $_;
                        my $rule_name = $binding->{rules}{$language};
                        my $profile = $vocabulary->{languages}{$language};
                        my $rule = $profile->{rules}{$rule_name};
                        my ($example) = grep {exists $profile->{words}{$_}} @{$binding->{operations}};
                        +{language => $language, name => $rule_name, form => $rule->{form},
                          select => $rule->{select}, example => defined($example) ? {
                            operation => $example,
                            text => $profile->{words}{$example}{forms}{$rule->{form}}
                          } : undef}
                    } sort keys %{$binding->{rules}}],
                }
            } sort keys %{$diag->{operation_words} || {}}],
            source_files => [sort keys %$files],
            source_locations => {
                map { $_ => [map { 0 + $_ } sort { $a <=> $b } keys %{$files->{$_}}] } keys %$files
            },
        };

}
return \%templates;

}

sub template_cases {
    my ($value, $selectors, $path) = @_;
    $path ||= [];
    return [] if !defined($value) && !@$path;
    return [{selectors => [@$path], text => $value}] if defined($value) && !ref($value);
    die "English template must be a string or selector hash\n" unless ref($value) eq 'HASH';
    die "English template has more selector levels than its definition\n" if @$path >= @$selectors;
    my @cases;
    for my $key (sort { ($a eq '*') <=> ($b eq '*') || $a cmp $b } keys %$value) {
        push @cases, @{template_cases($value->{$key}, $selectors,
            [@$path, [$selectors->[@$path], $key]])};
    }
    return \@cases;
}

sub source_contexts {
    my ($planning, $entries, $radius) = @_;
    $radius //= 3;
    my %files;
    $files{$_} = 1 for map { @{$_->{source_files}} } values %$entries;
    my (%lines, %definitions);
    for my $name (keys %files) {
        my $text = decode('UTF-8', read_text("$planning/../$name"));
        $lines{$name} = [map { s/\r\z//r } split /\n/, $text, -1];
        $definitions{$name} = definition_index($text, $name);
    }
    for my $entry (values %$entries) {
        my @contexts;
        for my $name (sort keys %{$entry->{source_locations}}) {
            my $lines = $lines{$name};
            my @windows;
            for my $number (@{$entry->{source_locations}{$name}}) {
                my $start = $number > $radius ? $number - $radius : 1;
                my $end = $number + $radius < @$lines ? $number + $radius : scalar @$lines;
                if (@windows && $start <= $windows[-1][1] + 1) {
                    $windows[-1][1] = $end if $end > $windows[-1][1];
                    push @{$windows[-1][2]}, $number;
                }
                else { push @windows, [$start, $end, [$number]] }
            }
            for my $window (@windows) {
                my ($start, $end, $matches) = @$window;
                my (@owners, %seen);
                for my $number (@$matches) {
                    my $owner = enclosing_definition($definitions{$name}, $number);
                    my $key = "$owner->{kind}:$owner->{name}";
                    push @owners, $owner unless $seen{$key}++;
                }
                push @contexts, {file => $name, start => $start, matches => $matches,
                    lines => [@$lines[$start - 1 .. $end - 1]], owners => \@owners};
            }
        }
        $entry->{source_contexts} = \@contexts;
    }
}

sub tree_data {
    my ($planning) = @_;
    my $registry = read_rows("$planning/diagnostic-class-registry.tsv");
    my $assignments = read_rows("$planning/diagnostic-error-family-proposal.tsv");
    my $templates = english_templates($planning);
    source_contexts($planning, $templates);
    my (%classes, %codes);
    for my $row (@$registry) {
        $classes{$row->{class}} = {%$row, registered => JSON::PP::true};
    }
    for my $row (@$assignments) {
        die "Duplicate diagnostic code $row->{code}\n" if $codes{$row->{code}}++;
        my $entry = $templates->{$row->{code}} or die "Missing template $row->{code}\n";
        $row->{english_templates} = template_cases($entry->{templates}, $entry->{selectors});
        $row->{selectors} = $entry->{selector_details};
        $row->{$_} = $entry->{$_} for qw(word_bindings source_files source_locations source_contexts);
        my $name = $row->{recommendation};
        next if $name eq 'none' || exists $classes{$name};
        my ($parent) = split /; /, $row->{recommended_parents};
        die "Missing parent for $name\n" unless $parent =~ /^XPerl::/;
        $classes{$name} = {class => $name, parent => $parent, registered => JSON::PP::false,
            leaf_only => '0', warning_category => '-', source => 'classification proposal'};
    }
    for my $name (keys %classes) {
        my (%seen, $current);
        $current = $name;
        while (length $current) {
            die "Class ancestry cycle at $current\n" if $seen{$current}++;
            die "Unknown class ancestor $current\n" unless exists $classes{$current};
            $current = $classes{$current}{parent};
        }
    }
    my $root = absolute("$planning/..");
    $root = encode('UTF-8', $root) if utf8::is_utf8($root);
    $root =~ s{\\}{/}g if $^O =~ /\A(?:MSWin32|dos|os2)\z/;
    $root =~ s{([^A-Za-z0-9._~/:-])}{sprintf '%%%02X', ord($1)}ge;
    $root = "/$root" if $root =~ /^[A-Za-z]:/;
    return {classes => [map { $classes{$_} } sort keys %classes],
        diagnostics => $assignments, source_root => "file://$root"};
}

sub review_evidence {
    my ($planning, $source, $destination) = @_;
    my $packet = read_json($source);
    my %entries = map { $_->{code} => $_ } @{$packet->{diagnostics}};
    source_contexts($planning, \%entries);
    require SourceReference;
    SourceReference::add_reference_context($packet, $planning);
    my %assignments = map { $_->{code} => $_ }
        @{read_rows("$planning/diagnostic-error-family-proposal.tsv")};
    $_->{previous_review} = $assignments{$_->{code}} || {} for values %entries;
    $packet->{class_registry} = read_rows("$planning/diagnostic-class-registry.tsv");
    write_json($destination, $packet);
}

sub escape_html {
    my ($text) = @_;
    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    $text =~ s/"/&quot;/g;
    $text =~ s/'/&#x27;/g;
    return $text;
}

sub render_class_tree {
    my ($planning, $destination, $assets) = @_;
    my $data = tree_data($planning);
    my $root = absolute("$planning/..");
    my %inputs = map { $_ => 1 } ('diag_conf.pl', 'planning', 'regen/diag.pl', 'regen/diag_lib.pm');
    $inputs{$_} = 1 for map { @{$_->{source_files}} } @{$data->{diagnostics}};
    my $source = source_info($root);
    my $modified;
    if ($source->{revision}) {
        my $status = run(['git', '-C', $root, 'status', '--porcelain',
            '--untracked-files=normal', '--', sort keys %inputs]);
        $modified = length($status->{stdout}) ? JSON::PP::true : JSON::PP::false;
    }
    my $timestamp = strftime('%Y-%m-%dT%H:%M:%S+00:00', gmtime);
    $data->{generation} = {generated_at => $timestamp, commit => $source->{revision}, modified_inputs => $modified};
    my $revision = $source->{revision}
        ? 'Commit <code title="'.$source->{revision}.'">'.substr($source->{revision}, 0, 12).'</code>'
        : 'Commit unavailable (source export)';
    $revision .= ' · includes uncommitted input changes' if $modified;
    my $provenance = 'Generated <time datetime="'.$timestamp.'">'.$timestamp.'</time> · '.$revision;
    my $payload = JSON::PP->new->canonical->encode($data);
    $payload =~ s/</\\u003c/g;
    my %parts = (
        TITLE => escape_html('XPerl diagnostic class browser'),
        STYLES => decode('UTF-8', read_text("$assets/class-tree.css")),
        CONTROLLER => decode('UTF-8', read_text("$assets/class-tree.js")),
        DATA => $payload, GENERATION => $provenance,
    );
    my $page = decode('UTF-8', read_text("$assets/class-tree.html.in"));
    # Substitute once so diagnostic text cannot become another template marker.
    $page =~ s/__(TITLE|STYLES|DATA|CONTROLLER|GENERATION)__/$parts{$1}/ge;
    write_text($destination, encode('UTF-8', $page));
    print "Interactive hierarchy: $destination\n";
}

1;
