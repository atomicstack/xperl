package SourceReference;

use strict;
use warnings;
use utf8;
use Encode qw(decode encode);
use Digest::SHA qw(sha256_hex);
use BenchUtils qw(read_text read_json write_json source_info);
use SourceOwners qw(definition_index enclosing_definition);
use ClassTree qw(english_templates);

sub checked_note {
    my ($note, $hash) = @_;
    return {status => 'unreviewed'} unless $note && %$note;
    return {%$note, status => ($note->{source_sha256} // '') eq $hash
        ? 'focused-source-review' : 'stale'};
}

# Index only catalog references. Lexical ownership and optional reviewed
# notes do not establish a call graph or prove that a reference emits an error.
sub build_index {
    my ($planning, $notes_path) = @_;
    my $root = "$planning/..";
    my $entries = english_templates($planning);
    my $notes = -e $notes_path ? read_json($notes_path) : {files => {}};
    my %manifest;
    for my $line (split /\n/, decode('UTF-8', read_text("$root/MANIFEST"))) {
        my ($file, $description) = split /\t/, $line, 2;
        next unless defined $description;
        $description =~ s/^\s+|\s+$//g;
        $manifest{$file} = $description;
    }
    my %references;
    for my $code (keys %$entries) {
        my $locations = $entries->{$code}{source_locations};
        for my $file (keys %$locations) {
            push @{$references{$file}}, map { [$_, $code] } @{$locations->{$file}};
        }
    }
    my %files;
    for my $file (sort keys %references) {
        my $bytes = read_text("$root/$file");
        my $text = decode('UTF-8', $bytes);
        my @lines = split /\n/, $text, -1;
        my $definitions = definition_index($text, $file);
        my $file_notes = $notes->{files}{$file} || {};
        my (%functions, @unresolved);
        for my $match (sort { $a->[0] <=> $b->[0] || $a->[1] cmp $b->[1] } @{$references{$file}}) {
            my ($line, $code) = @$match;
            my $owner = enclosing_definition($definitions, $line);
            if (!length $owner->{name}) {
                push @unresolved, {line => $line, code => $code};
                next;
            }
            my ($span) = sort { ($a->{end} - $a->{start}) <=> ($b->{end} - $b->{start}) }
                grep { $_->{name} eq $owner->{name} && $_->{kind} eq $owner->{kind}
                    && $_->{start} <= $line && $line <= $_->{end} } @$definitions;
            my $key = join ':', @$span{qw(kind name start)};
            if (!exists $functions{$key}) {
                my $hash = sha256_hex(encode('UTF-8', join "\n", @lines[$span->{start} - 1 .. $span->{end} - 1]));
                $functions{$key} = {%$span, source_sha256 => $hash,
                    review => checked_note($file_notes->{functions}{$span->{name}}, $hash), references => []};
            }
            push @{$functions{$key}{references}}, {line => $line, code => $code};
        }
        my $hash = sha256_hex($bytes);
        $files{$file} = {manifest_description => $manifest{$file} // '', source_sha256 => $hash,
            review => checked_note($file_notes->{review}, $hash),
            functions => [sort { $a->{name} cmp $b->{name} || $a->{start} <=> $b->{start} } values %functions],
            unresolved_references => \@unresolved};
    }
    return {schema_version => 1, source_revision => source_info($root)->{revision},
        scope => 'Catalog references in scanned core and extension sources; not a complete call graph.', files => \%files};
}

sub render_overview {
    my ($index) = @_;
    my @lines = ('DIAGNOSTIC PRODUCER REFERENCE', '=============================', '',
        'Function names are inferred without preprocessing. References can be emitters,',
        'forwarders, framework checks or test fixtures. They are not all error conditions.',
        'Only focused-source-review descriptions have been checked against source.',
        'Unreviewed and stale entries require investigation. No call graph is inferred.', '');
    for my $file (sort keys %{$index->{files}}) {
        my $entry = $index->{files}{$file};
        push @lines, "$file — $entry->{manifest_description}", '  File notes: '.$entry->{review}{status};
        push @lines, '  '.$entry->{review}{summary} if $entry->{review}{summary};
        for my $function (@{$entry->{functions}}) {
            push @lines, "  $function->{name} [$function->{kind}, $function->{start}-$function->{end}; $function->{review}{status}]";
            push @lines, '    '.$function->{review}{summary} if $function->{review}{summary};
            my %codes;
            push @{$codes{$_->{code}}}, $_->{line} for @{$function->{references}};
            push @lines, "    $_  \@ ".join(', ', @{$codes{$_}}) for sort keys %codes;
        }
        push @lines, "  [enclosing definition unresolved] $_->{code} \@ $_->{line}"
            for @{$entry->{unresolved_references}};
        push @lines, '';
    }
    return join "\n", @lines;
}

sub prompt_note {
    my ($review) = @_;
    return {status => $review->{status} // 'unreviewed'} unless $review->{status} eq 'focused-source-review';
    return {map { $_ => $review->{$_} } grep { $_ ne 'source_sha256' } keys %$review};
}

sub add_reference_context {
    my ($packet, $planning) = @_;
    my $path = "$planning/diagnostic-source-context.json";
    if (!-e $path) {
        $packet->{source_reference} = {status => 'not generated'};
        return;
    }
    my $index = read_json($path);
    my %owners;
    for my $diagnostic (@{$packet->{diagnostics}}) {
        for my $context (@{$diagnostic->{source_contexts}}) {
            $owners{$context->{file}} ||= {};
            for my $owner (@{$context->{owners}}) {
                $owners{$context->{file}}{"$owner->{kind}:$owner->{name}"} = 1 if length $owner->{name};
            }
        }
    }
    my %selected;
    for my $file (sort keys %owners) {
        my $entry = $index->{files}{$file};
        if (!$entry) {
            $selected{$file} = {status => 'not indexed'};
            next;
        }
        if (sha256_hex(read_text("$planning/../$file")) ne $entry->{source_sha256}) {
            $selected{$file} = {status => 'stale; regenerate source reference before relying on descriptions'};
            next;
        }
        $selected{$file} = {review => prompt_note($entry->{review}), functions => {map {
            $_->{name} => prompt_note($_->{review})
        } grep { $owners{$file}{"$_->{kind}:$_->{name}"} } @{$entry->{functions}}}};
    }
    $packet->{source_reference} = {files => \%selected};
}

1;
