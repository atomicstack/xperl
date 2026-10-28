# Optional classification review. This module writes review artifacts only.
# Codex transport and JSON handling are shared with translation tooling.

package Diag::Review;
use strict;
use warnings;
use Getopt::Long ();
use File::Path   qw(make_path);
use File::Spec   ();
use Encode       ();

require './regen/diag_translate.pm';

# Require an explicit scope so a trial does not submit the entire catalog.
sub options {
    my ($arguments) = @_;
    my %options = ( batch_size => 30, codex => 'codex' );
    Getopt::Long::GetOptionsFromArray(
        $arguments,
        'review-diagnostics=s' => \$options{scope},
        'batch-size=i'         => \$options{batch_size},
        'max-batches=i'        => \$options{max_batches},
        'work-dir=s'           => \$options{work_dir},
        'model=s'              => \$options{model},
        'codex=s'              => \$options{codex},
        'dry-run'              => \$options{dry_run},
        'resume'               => \$options{resume},
    ) or die usage();
    die usage() if @$arguments || !defined $options{scope};
    die "--batch-size must be positive\n" unless $options{batch_size} > 0;
    die "--max-batches must be positive\n"
      if defined $options{max_batches} && $options{max_batches} < 1;
    die "review scope must be all or a diagnostic class\n"
      unless $options{scope} eq 'all'
      || $options{scope} =~ /\A(?:XPerl::Diagnostic::)?(?:Error|Warning|Note)(?:::[A-Za-z]\w*)*\z/;
    $options{scope} = "XPerl::Diagnostic::$options{scope}"
      unless $options{scope} eq 'all' || $options{scope} =~ /^XPerl::/;
    my $directory = $options{scope};
    $directory =~ s/::/-/g;
    $options{work_dir} ||= "diagnostic-review-$directory";
    $options{work_dir} = File::Spec->rel2abs( $options{work_dir} );
    return \%options;
}

sub usage {
    return
        "Usage: perl regen/diag.pl --review-diagnostics=Error::Format|all\n"
      . "  [--batch-size=30] [--max-batches=N] [--work-dir=DIR]\n"
      . "  [--model=MODEL] [--codex=PROGRAM] [--dry-run] [--resume]\n"
      . "Saves JSON recommendations only. Never updates the catalog or source files.\n";
}

# Use declared ancestry, rather than spelling alone, for class membership.
sub in_scope {
    my ( $class, $scope, $classes ) = @_;
    return 1 if $scope eq 'all';
    my %seen;
    while ( defined $class && length $class && !$seen{$class}++ ) {
        return 1 if $class eq $scope;
        $class = ( $classes->{$class} || {} )->{parent};
    }
    return 0;
}

# Include MANIFEST descriptions as evidence, not as a classification rule.
sub file_descriptions {
    my ($files) = @_;
    my %descriptions;
    for my $line ( split /\n/, Diag::Migration::read_source('MANIFEST') ) {
        my ( $file, $description ) = split /\t+/, $line, 2;
        $descriptions{$file} = $description if $files->{$file} && defined $description;
    }
    return \%descriptions;
}

# Shared wording is a merge candidate, not proof of identical contracts. Ignore
# parameter spelling so otherwise identical templates remain in the same family.
sub template_families {
    my ( $diagnostics, $selected, $classes ) = @_;
    my %selected = map { $_->{number} => 1 } @$selected;
    my %families;
    for my $diag (@$diagnostics) {
        my %seen;
        for my $case ( @{ Diag::Migration::template_cases( $diag, 'en' ) } ) {
            my $text = $case->{template};
            $text =~ s/%\{[A-Za-z_]\w*\}/%{parameter}/g;
            next if $seen{$text}++;
            push @{ $families{$text} },
              {
                number   => $diag->{number},
                code     => $diag->{code},
                class    => $classes->{ $diag->{code} },
                in_scope => $selected{ $diag->{number} } ? JSON::PP::true() : JSON::PP::false(),
              };
        }
    }
    return [
        map { +{ template => $_, members => $families{$_} } }
          grep {
            @{ $families{$_} } > 1 && grep { $_->{in_scope} }
              @{ $families{$_} }
          } sort keys %families
    ];
}

# Keep connected template families together, even when a family exceeds the
# target size. Stable numeric roots make batch order independent of hash order.
sub review_batches {
    my ( $entries, $families, $size ) = @_;
    my %parent = map { $_->{number} => $_->{number} } @$entries;
    my $root   = sub {
        my ($number) = @_;
        $number = $parent{$number} while $parent{$number} != $number;
        return $number;
    };
    for my $family (@$families) {
        my @members = grep { exists $parent{$_} } map { $_->{number} } @{ $family->{members} };
        next unless @members;
        my $leader = $root->( shift @members );
        for my $member (@members) {
            my $other = $root->($member);
            next if $other == $leader;
            my ( $first, $second ) = sort { $a <=> $b } ( $leader, $other );
            $parent{$second} = $first;
            $leader = $first;
        }
    }
    my %groups;
    push @{ $groups{ $root->( $_->{number} ) } }, $_ for @$entries;
    my ( @batches, @batch );
    for my $number ( sort { $a <=> $b } keys %groups ) {
        my $group = $groups{$number};
        if ( @batch && @batch + @$group > $size ) {
            push @batches, [@batch];
            @batch = ();
        }
        push @batch, @$group;
    }
    push @batches, [@batch] if @batch;
    return \@batches;
}

# Gather normalized catalog data without dropping selectors or compound inputs.
# The viewer supplies physical source spans and inferred enclosing definitions.
sub evidence_packet {
    my ( $conf, $diagnostics, $options ) = @_;
    my $model = Diag::Classes::build_model(
        $diagnostics,
        $conf->{diagnostic_classes},
        Perl::Regen::Warnings::tree(),
        Diag::Migration::read_source('warnings.h')
    );
    my %runtime_class = map { $_ => $model->{by_code}{$_}{proposed_class} } keys %{ $model->{by_code} };
    my @selected =
      grep { in_scope( $runtime_class{ $_->{code} }, $options->{scope}, $model->{classes} ) } @$diagnostics;
    die "No diagnostics in review scope $options->{scope}\n" unless @selected;
    my $references    = Diag::Migration::diagnostic_source_references( \@selected );
    my $documentation = Diag::Translation::documentation_index($conf);
    my ( @entries, %files );

    for my $diag (@selected) {
        my $locations = $references->{ $diag->{code} } || {};
        $files{$_} = 1 for keys %$locations;
        my %entry = map { exists $diag->{$_} ? ( $_ => $diag->{$_} ) : () }
          qw(number code macro severity kind description tags is_panic is_render params emit warning_categories
          counts_as_error variants compatibility message_template message_selectors selector_definitions);
        $entry{class} = $runtime_class{ $diag->{code} };
        my $context = Diag::Translation::diagnostic_context( $conf, $diag, 'en', $documentation );
        $entry{explanations}     = $context->{explanations};
        $entry{source_files}     = [ sort keys %$locations ];
        $entry{source_locations} = {
            map {
                $_ => [ map { 0 + $_ } sort { $a <=> $b } keys %{ $locations->{$_} } ]
            } keys %$locations
        };
        $entry{selector_domains} = [
            map {
                +{
                    name   => $diag->{message_selectors}[$_],
                    values => Diag::Migration::selector_column_values( $diag, $_ )
                }
            } 0 .. $#{ $diag->{message_selectors} || [] }
        ];
        push @entries, \%entry;
    }
    return {
        schema_version     => 1,
        scope              => $options->{scope},
        diagnostics        => \@entries,
        template_families  => template_families( $diagnostics, \@selected, \%runtime_class ),
        known_classes      => $model->{classes},
        known_tags         => $conf->{diagnostic_tags},
        catalog_identities => [ map { +{ number => $_->{number}, code => $_->{code} } } @$diagnostics ],
        file_descriptions  => file_descriptions( \%files ),
        subsystem_notes    => {
            'sv.c'       => 'SV implementation, printf conversion processing, and many unrelated value operations.',
            'pp_ctl.c'   => 'Control flow, eval, dispatch/on, exception delivery, and related runtime operations.',
            'regcomp*.c' => 'Regular expression compilation; inspect the actual producer contract.',
            'regexec.c'  => 'Regular expression execution, including internal invariant checks.',
        },
    };
}

# Describe the intended taxonomy explicitly. Existing assignments are evidence,
# not constraints: isolated renames cannot repair inconsistent branch boundaries.
sub instructions {
    return <<'TEXT';
Review this Perl diagnostic batch. Return only JSON matching the supplied schema.
This is an assessment, not an implementation. Do not edit files, run commands,
compile, run tests, or apply recommendations. The packet contains source evidence.

First assess the hierarchy for this subject, then classify each diagnostic.
Follow file/subsystem -> function/callers -> operation/failed predicate ->
parameters/selectors/templates -> proposed class/code/tags. Investigate any
disagreement. Check the whole group, including outliers and related entries
outside the batch; individual high confidence does not verify the whole family.
Grouping comes first, class naming second, code renaming last. Keep existing
identifiers when the grouping remains uncertain and put possible names in
followups. Never make a group look established by mechanically prefixing it.
Current codes, classes, tags and previous reviews are provisional. They were
partly inferred from English text and must not override evidence from producers.
A file is a clue, not proof. Shared files contain unrelated features. Snippets
may be incomplete and enclosing function names are lexical inferences. If the
contract cannot be established, choose investigate and explain what is missing.

Code naming:
- UPPER_SNAKE_CASE; describe the actual subject and failing condition.
- Prefer a consistent subject/condition vocabulary across related diagnostics.
- Distinguish Perl report format/formline from printf conversions and diagnostic
  template rendering. Distinguish dispatch/on shapes from regular expressions.
- Preferred regex vocabulary: Regexp, matching Perl's REGEXP reference type;
  CharClass, not CharacterClass. Where justified, use Regexp::CharClass::Extended.
  After grouping is settled, use the full semantic family prefix, for example
  Error::IO::InplaceEdit -> ERROR_IO_INPLACE_EDIT_<FAILURE>. Earlier CC/ECC
  shorthand proposals do not override this full-prefix convention.
  Apply the same spellings under Internal and Warning subject branches. Propose
  migrations from existing names; do not change warning category identifiers.
- Name the failure, not merely its consequence: CANNOT_RENAME_SKIPPING became
  ERROR_IO_INPLACE_EDIT_CANNOT_CREATE_BACKUP after inspecting rename/link paths.
  Skipping can
  remain in the message/data. Preserve consequences in names only when needed
  to distinguish the actual diagnostic contract.
- Preserve good existing names and groupings. Justify each change, not cosmetic
  churn or blind prefixing. Do not encode transient implementation details.
- Stable diagnostic numbers never change. Do not rewrite message text.

Class hierarchy:
- Build useful isa groupings around coherent user-visible subjects/contracts.
- Give each proposed branch an inclusion rule and an exclusion rule. Avoid vague
  Misc/Other buckets, one class per code, redundant levels, or empty abstractions.
- Preserve useful established branches, including Error::Strict::Vars. Warning
  category policy is independent of class assignment; honor useful warning
  vocabulary without changing enablement, severity or delivery.
- Internal/panic failures belong under Error::Internal with subject branches.
  Internal means a broken core/API invariant, not merely code that lives in C.
- Use XPerl::Diagnostic::Error, Warning, or Note ancestry as appropriate. Render
  and panic are independent flags; do not create dedicated Render/Panic trees.
- Suggest new or reorganized branches when justified, rather than forcing every
  diagnostic into the existing hodgepodge. Include parent and membership rules.
- Return class_reviews for existing branches whose boundaries you reviewed,
  with proposed parent, definition, inclusion and exclusion rules. Return new
  branches in new_classes. These are proposals, not modifications to the registry.
- Review only this batch's members. Flag wider impacts and neighboring classes
  needing review, rather than claiming global consistency from a partial batch.

Tags:
- Choose subject and condition tags useful for search and future regrouping.
- Reassess EVERY existing tag against producer evidence. Existing tags are not
  presumed correct. Repeated execution or a no-progress condition does not
  establish recursion. Remove tags that describe the wrong mechanism.
- Reuse accurate existing tags. Declare and justify new tags. Remove misleading
  tags. Avoid generic tags that add no information or encode the current class.

For each diagnostic return the original number/code, status, recommended code,
class and complete tag list, confidence, producer evidence and rationale.
Use status reviewed for completed assessments, whether fields change or not.
The script computes keep/change and a field-by-field change list from your data.
Keep recommendations unchanged for investigate/split/merge statuses; describe the
required work in questions. A merge/split is a proposal, never an identity edit.
Shared template families are explicit merge candidates. Compare producer contracts,
inputs, selectors, severity and delivery before proposing a merge. Out-of-scope
members are context only; request follow-up rather than returning extra results.
new_classes and class_reviews are disjoint: class_reviews names existing classes
only; newly proposed branches belong solely in new_classes.
Reconcile related names and classes across the batch before returning results.
TEXT
}

sub object_schema {
    my ($properties) = @_;
    return {
        type                 => 'object',
        additionalProperties => JSON::PP::false(),
        properties           => $properties,
        required             => [ sort keys %$properties ]
    };
}

# Keep the machine response small and separate proposals from supporting facts.
sub response_schema {
    my ($batch) = @_;
    my $string  = { type => 'string' };
    my $strings = { type => 'array', items => $string };
    my $result  = object_schema(
        {
            number        => { type => 'integer', enum => [ map { 0 + $_->{number} } @$batch ] },
            original_code => { type => 'string',  enum => [ map { $_->{code} } @$batch ] },
            status        => { type => 'string',  enum => [qw(reviewed investigate split merge)] },
            code          => $string,
            class         => $string,
            tags          => $strings,
            confidence    => { type => 'string', enum => [qw(high medium low)] },
            evidence      => $strings,
            rationale     => $string,
            questions     => $strings,
        }
    );
    my $class = object_schema(
        {
            name        => $string,
            parent      => $string,
            description => $string,
            includes    => $string,
            excludes    => $string
        }
    );
    my $tag = object_schema( { name => $string, description => $string } );
    return object_schema(
        {
            hierarchy_assessment => $string,
            diagnostics          => { type => 'array', items => $result },
            new_classes          => { type => 'array', items => $class },
            class_reviews        => { type => 'array', items => $class },
            new_tags             => { type => 'array', items => $tag },
            followups            => $strings,
        }
    );
}

# Validate semantics as well as the transport schema. A malformed response is
# retained on disk for inspection but never published as accepted advice.
sub validate_response {
    my ( $response, $batch, $packet ) = @_;
    die "Review response is not an object\n" unless ref($response) eq 'HASH';
    for my $field (qw(diagnostics new_classes class_reviews new_tags followups)) {
        die "Review response lacks $field array\n" unless ref( $response->{$field} ) eq 'ARRAY';
    }
    die "Review response lacks hierarchy assessment\n"
      unless defined $response->{hierarchy_assessment} && !ref( $response->{hierarchy_assessment} );
    my %classes = %{ $packet->{known_classes} };
    for my $class ( @{ $response->{new_classes} } ) {
        die "Invalid proposed class\n"
          unless ref($class) eq 'HASH'
          && ( $class->{name} || '' ) =~ /\AXPerl::Diagnostic::(?:Error|Warning|Note)(?:::[A-Z][A-Za-z0-9]*)+\z/
          && !exists $classes{ $class->{name} };
        $classes{ $class->{name} } = $class;
    }
    my %reviewed;
    for my $class ( @{ $response->{class_reviews} } ) {
        die "Unknown or duplicate reviewed class\n"
          unless ref($class) eq 'HASH'
          && exists $packet->{known_classes}{ $class->{name} || '' }
          && !$reviewed{ $class->{name} }++;
        $classes{ $class->{name} } = $class;
    }
    for my $class ( @{ $response->{new_classes} }, @{ $response->{class_reviews} } ) {
        for my $field (qw(name parent description includes excludes)) {
            die "Proposed class lacks $field\n"
              unless defined $class->{$field} && !ref( $class->{$field} ) && length $class->{$field};
        }
        die "Unknown proposed class parent\n" unless exists $classes{ $class->{parent} || '' };
        my %seen;
        my $name = $class->{name};
        while ( defined $name && length $name ) {
            die "Proposed class ancestry cycle at $name\n" if $seen{$name}++;
            $name = ( $classes{$name} || {} )->{parent};
        }
    }
    my %tags = %{ $packet->{known_tags}{definitions} || {} };
    for my $tag ( @{ $response->{new_tags} } ) {
        die "Invalid proposed tag\n"
          unless ref($tag) eq 'HASH'
          && ( $tag->{name} || '' ) =~ /\A[a-z][a-z0-9_]*:[a-z][a-z0-9_]*\z/
          && !exists $tags{ $tag->{name} }
          && length( $tag->{description} || '' );
        $tags{ $tag->{name} } = $tag->{description};
    }
    my %expected   = map { $_->{number} => $_ } @$batch;
    my %identities = map { $_->{code}   => $_->{number} } @{ $packet->{catalog_identities} };
    my %proposed;
    for my $result ( @{ $response->{diagnostics} } ) {
        die "Invalid review recommendation\n" unless ref($result) eq 'HASH';
        my $original = delete $expected{ $result->{number} || '' };
        die "Unexpected or duplicate reviewed number\n" unless $original;
        die "Review changed original identity\n"        unless ( $result->{original_code} || '' ) eq $original->{code};
        my $code = $result->{code} || '';
        die "Invalid or duplicate recommended code $code\n"
          unless $code =~ /\A[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*\z/ && !$proposed{$code}++;
        die "Recommended code $code already belongs to another diagnostic\n"
          if exists $identities{$code} && $identities{$code} != $original->{number};
        die "Unknown recommended class\n" unless exists $classes{ $result->{class} || '' };
        die "Invalid recommended tags\n"  unless ref( $result->{tags} ) eq 'ARRAY';
        my %seen;
        die "Unknown or duplicate recommended tag\n"
          if grep { ref($_) || !exists $tags{$_} || $seen{$_}++ } @{ $result->{tags} };
        die "Invalid review status for $original->{code}\n"
          unless ( $result->{status} || '' ) =~ /\A(?:reviewed|investigate|split|merge)\z/;
        die "Invalid review confidence\n" unless ( $result->{confidence} || '' ) =~ /\A(?:high|medium|low)\z/;

        for my $field (qw(evidence questions)) {
            die "Invalid $field list\n"
              unless ref( $result->{$field} ) eq 'ARRAY'
              && !grep { !defined($_) || ref($_) } @{ $result->{$field} };
        }
        die "Recommendation requires rationale and producer evidence\n"
          unless length( $result->{rationale} || '' ) && @{ $result->{evidence} };
        my %changes;
        for my $field (qw(code class tags)) {
            my $before = $original->{$field};
            my $after  = $result->{$field};
            my $equal =
              $field eq 'tags'
              ? Diag::Translation::fingerprint( [ sort @{ $before || [] } ] ) eq
              Diag::Translation::fingerprint( [ sort @$after ] )
              : $before eq $after;
            $changes{$field} = { from => $before, to => $after } unless $equal;
        }
        die "Unresolved $result->{status} recommendation for $original->{code} changes "
          . join( ', ', sort keys %changes )
          . "; retain original fields and explain in questions\n"
          if $result->{status} ne 'reviewed' && %changes;

        # Derive bookkeeping from the actual fields rather than asking the
        # model for a redundant and sometimes contradictory keep/change choice.
        $result->{changes}  = \%changes;
        $result->{decision} = $result->{status} eq 'reviewed' ? ( %changes ? 'change' : 'keep' ) : $result->{status};
    }
    die "Review omitted diagnostics: " . join( ', ', sort keys %expected ) . "\n" if %expected;
    return $response;
}

# Keep the complete evidence on disk, but do not send duplicate registry rows
# or unrelated identity lists. Validation still checks against the full catalog.
sub batch_context {
    my ( $packet, $batch ) = @_;
    my %input = %$packet;
    delete @input{qw(catalog_identities class_registry)};
    my %numbers = map { $_->{number} => 1 } @$batch;
    $input{diagnostics} = [
        map {
            my %entry     = %$_;
            my $templates = $entry{message_template} || {};
            $entry{translation_languages} = [ sort keys %$templates ];
            $entry{message_template}      = { en => $templates->{en} };
            \%entry;
        } @$batch
    ];
    if ( $packet->{source_reference}{files} ) {
        my %wanted;
        for my $diagnostic (@$batch) {
            for my $context ( @{ $diagnostic->{source_contexts} } ) {
                $wanted{ $context->{file} } ||= {};
                $wanted{ $context->{file} }{ $_->{name} } = 1 for @{ $context->{owners} };
            }
        }
        my %files;
        for my $file ( sort keys %wanted ) {
            my $reference = $packet->{source_reference}{files}{$file} || next;
            my %entry     = %$reference;
            $entry{functions} = {
                map  { $_ => $reference->{functions}{$_} }
                grep { $wanted{$file}{$_} } sort keys %{ $reference->{functions} || {} }
            };
            $files{$file} = \%entry;
        }
        $input{source_reference} = { files => \%files };
    }
    $input{template_families} = [
        grep {
            grep { $numbers{ $_->{number} } }
              @{ $_->{members} }
        } @{ $packet->{template_families} }
    ];
    return \%input;
}

# Retry schema-valid but inconsistent advice without silently changing the
# recommendations. Every attempted response and validation error is retained.
sub reviewed_response {
    my ( $prefix, $batch, $packet, $options ) = @_;
    my $input = batch_context( $packet, $batch );
    my $last_error;
    for my $attempt ( 0 .. 2 ) {
        my $path = $attempt ? "$prefix-retry-$attempt" : $prefix;
        Diag::Translation::write_json( "$path.input.json",  $input );
        Diag::Translation::write_json( "$path.schema.json", response_schema($batch) );
        my $prompt_bytes = Diag::Translation::json()->pretty(0)->encode($input);
        Diag::Translation::write_bytes( "$path.prompt", $prompt_bytes );
        print "Prepared $path.prompt (" . scalar(@$batch) . " diagnostics)\n";
        printf "Request size: %.1f KiB prompt, %.1f KiB response schema\n",
          length($prompt_bytes) / 1024, ( -s "$path.schema.json" ) / 1024;
        return if $options->{dry_run};
        my $response =
          -e "$path.response.json" && $options->{resume}
          ? Diag::Translation::read_json("$path.response.json")
          : Diag::Translation::call_codex( $path, $options, 60 );
        my $valid = eval { validate_response( $response, $batch, $packet ); 1 };
        return $response if $valid;
        $last_error = $@ || "Invalid classification response\n";
        Diag::Translation::write_bytes( "$path.validation-error.txt", Encode::encode( 'UTF-8', $last_error ) );
        print "Review validation failed: $last_error";
        $input->{correction} = {
            error             => $last_error,
            previous_response => $response,
            instruction       =>
              'Correct the response while retaining valid recommendations. Follow the response contract exactly.',
        };
    }
    die "Review response remains invalid after correction attempts: $last_error";
}

# Snapshots bind resumed batches to the same catalog, source evidence and policy.
# No path from this driver writes catalog data or invokes regeneration.
sub run {
    my ( $conf, $diagnostics, $options ) = @_;
    local $| = 1;
    my $directory = $options->{work_dir};
    die "$directory already exists; use --resume or choose a new --work-dir\n"
      if -e $directory && !$options->{resume};
    make_path($directory);
    my $packet   = evidence_packet( $conf, $diagnostics, $options );
    my $source   = File::Spec->catfile( $directory, 'catalog-evidence.candidate.json' );
    my $enriched = File::Spec->catfile( $directory, 'source-evidence.candidate.json' );
    Diag::Translation::write_json( $source, $packet );
    my @enrich =
      ( 'python3', '-B', 'planning/exception-system-guide/class_tree.py', '--review-evidence', $source, $enriched );
    system(@enrich) == 0 or die "Cannot collect viewer evidence; requires Python 3 and planning viewer sources\n";
    $packet = Diag::Translation::read_json($enriched);
    $packet->{review_policy} = instructions();
    my $fingerprint = Diag::Translation::fingerprint(
        {
            packet          => $packet,
            batch_size      => $options->{batch_size},
            response_schema => response_schema( $packet->{diagnostics} ),
        }
    );
    my $snapshot = File::Spec->catfile( $directory, 'snapshot.json' );

    if ( -e $snapshot ) {
        die "Review inputs changed; choose a new --work-dir\n"
          unless Diag::Translation::read_json($snapshot)->{fingerprint} eq $fingerprint;
    }
    for my $pair ( [ $source, 'catalog-evidence.json' ], [ $enriched, 'source-evidence.json' ] ) {
        my $destination = File::Spec->catfile( $directory, $pair->[1] );
        rename $pair->[0], $destination or die "Cannot publish $destination: $!\n";
    }
    Diag::Translation::write_json( $snapshot, { fingerprint => $fingerprint, batch_size => $options->{batch_size} } );
    my $entries        = delete $packet->{diagnostics};
    my $batches        = review_batches( $entries, $packet->{template_families}, $options->{batch_size} );
    my $selected_count = scalar @$entries;
    my @results;
    my $batch_number = 0;
    my $launched     = 0;
    print "$selected_count diagnostics in "
      . scalar(@$batches)
      . " template-related batches; recommendations only, no source changes\n";

    for my $batch (@$batches) {
        my $prefix   = File::Spec->catfile( $directory, sprintf 'batch-%04d', ++$batch_number );
        my $accepted = "$prefix.recommendations.json";
        if ( -e $accepted && $options->{resume} ) {
            push @results, validate_response( Diag::Translation::read_json($accepted), $batch, $packet );
            print "Retained reviewed batch $batch_number\n";
            next;
        }
        last if defined $options->{max_batches} && $launched >= $options->{max_batches};
        ++$launched;
        print "Batch $batch_number exceeds the target size to keep a template family together\n"
          if @$batch > $options->{batch_size};
        my $response = reviewed_response( $prefix, $batch, $packet, $options );
        next if $options->{dry_run};
        Diag::Translation::write_json( $accepted, $response );
        push @results, $response;
        print "Saved validated recommendations for batch $batch_number\n";
    }
    my $output         = File::Spec->catfile( $directory, 'recommendations.json' );
    my $reviewed_count = 0;
    $reviewed_count += @{ $_->{diagnostics} } for @results;
    Diag::Translation::write_json(
        $output,
        {
            schema_version     => 1,
            source_fingerprint => $fingerprint,
            scope              => $options->{scope},
            model              => $options->{model} || 'configured',
            selected_count     => $selected_count,
            reviewed_count     => $reviewed_count,
            complete           => $reviewed_count == $selected_count ? JSON::PP::true() : JSON::PP::false(),
            review_batches     => \@results
        }
    );
    print "Recommendations: $output\nNo catalog, generated files, or producers were changed.\n";
}

1;
