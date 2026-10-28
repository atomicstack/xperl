#!./perl
BEGIN { @INC = -f './TestInit.pm' ? ('.') : ('..'); }
use TestInit qw(T);
use strict;
use warnings;
use utf8;
require './t/test.pl';
require './regen/diag.pl';
require './regen/diag_translate.pm';
require './regen/diag_word_translate.pm';
require Storable;
require Scalar::Util;
require File::Temp;
plan('no_plan');
our ( $CONF, $META );
do './diag_conf.pl' or die $@ || $!;
my $conf        = Storable::dclone($CONF);
my $diagnostics = Diag::Migration::diagnostics($conf);
my $data        = Storable::dclone( Diag::Words::catalog() );
my $directory   = File::Temp::tempdir( DIR => -d '../tmp' ? '../tmp' : '.', CLEANUP => 1 );
my $provenance  = "$directory/provenance.json";
my $options     = {
    language        => 'fr',
    mode            => 'repair',
    vocabulary      => 1,
    provenance_file => $provenance,
    conf            => $conf,
    diagnostics     => $diagnostics
};
{
    no warnings qw(redefine once);
    local *Diag::Words::catalog = sub { $data };
    my $contexts = Diag::Translation::Words::contexts( $conf, $diagnostics, $options );
    is( scalar @$contexts, 208, 'repair sees every untracked draft descriptive word' );
    my ($addition) = grep { $_->{code} eq 'add' } @$contexts;
    ok( $addition, 'operation identity names a word independently of diagnostic numbers' );
    {
        my $reordered = Diag::Translation::Words::contexts( $conf, [ reverse @$diagnostics ], $options );
        my ($context) = grep { $_->{code} eq 'add' } @$reordered;
        is(
            $context->{source_fingerprint},
            $addition->{source_fingerprint},
            'word provenance is independent of diagnostic enumeration order'
        );
    }
    {
        my ($consumer) = grep { $_->{number} == 1419 } @$diagnostics;
        local $consumer->{message_template}{fr} = 'A changed downstream sentence: %{target}, %{context}';
        my $changed = Diag::Translation::Words::contexts( $conf, $diagnostics, $options );
        my ($context) = grep { $_->{code} eq 'add' } @$changed;
        is(
            $context->{source_fingerprint},
            $addition->{source_fingerprint},
            'translated consumer wording cannot create a circular word dependency'
        );
    }
    {
        local $data->{languages}{en}{words}{add}{description} = 'Source-audited operation meaning.';
        my $changed = Diag::Translation::Words::contexts( $conf, $diagnostics, $options );
        my ($context) = grep { $_->{code} eq 'add' } @$changed;
        isnt(
            $context->{source_fingerprint},
            $addition->{source_fingerprint},
            'source meaning guidance contributes to word provenance'
        );
        is(
            $context->{english_word}{description},
            'Source-audited operation meaning.',
            'source guidance reaches the translation packet'
        );
    }
    ok( grep( $_ eq 'indefinite', @{ $addition->{required_forms} } ),
        'required forms union the actual sentence roles' );
    my $schema = Diag::Translation::response_schema( [$addition], $options );
    ok( $schema->{properties}{results}{items}{properties}{forms}, 'response schema describes forms explicitly' );
    my $prompt = Diag::Translation::prompt( [$addition], $options );
    my $packet = Diag::Translation::json()->decode( substr( $prompt, index( $prompt, "{\n" ) ) );
    is( scalar @{ $packet->{words} }, 1, 'batch sends its shared word once' );
    ok( scalar @{ $packet->{diagnostic_context} }, 'sentence context accompanies the word' );
    ok(
        !grep( exists $_->{operation_words}, @{ $packet->{diagnostic_context} } ),
        'sentence context does not duplicate the operation dictionary'
    );
    {
        my ($consumer)      = grep { $_->{number} == 1419 } @$diagnostics;
        my $context         = Diag::Translation::diagnostic_context( $conf, $consumer, 'fr', {} );
        my $sentence_prompt = Diag::Translation::prompt( [$context], { language => 'fr', mode => 'translate' } );
        like(
            $sentence_prompt,
            qr/null translation is intentional, not missing/,
            'sentence instructions distinguish literal and opaque words from missing translations'
        );
        like(
            $sentence_prompt,
            qr/only the form requested by its binding's rule/,
            'sentence instructions require forms by usage rather than the entire profile'
        );
    }
    my $word   = $data->{languages}{fr}{words}{add};
    my $result = {
        code         => 'add',
        forms        => [ map { { name => $_, value => $word->{forms}{$_} } } sort keys %{ $word->{forms} } ],
        tags         => [ map { { name => $_, value => $word->{tags}{$_} } } sort keys %{ $word->{tags} } ],
        changes      => [],
        requests     => [],
        review_notes => 'Checked the forms and tags.',
    };
    my $before = Diag::Translation::fingerprint($data);
    my ( $sets, $requests, $reviews, $fingerprints ) =
      Diag::Translation::accept_response( [$addition], { results => [$result] }, $diagnostics, $conf, 'fr', $options );
    is( scalar @$sets,                         1,       'typed vocabulary response validates' );
    is( Diag::Translation::fingerprint($data), $before, 'candidate validation does not mutate the loaded vocabulary' );
    my $document = {
        vocabulary_version  => 1,
        target_language     => 'fr',
        workflow            => 'repair',
        vocabulary_sets     => $sets,
        source_fingerprints => $fingerprints
    };
    my $bad = Storable::dclone($document);
    $bad->{vocabulary_sets}[0]{forms}[0]{name} = 'undeclared_form';
    eval { Diag::Translation::Words::import_document( $conf, $diagnostics, $bad, $provenance ) };
    like( $@, qr/undeclared form/, 'import rejects an undeclared word form' );
    is( Diag::Translation::fingerprint($data), $before, 'failed import leaves loaded data intact' );
    ok( !-e $provenance, 'failed import does not publish provenance' );
    $bad = Storable::dclone($document);
    $bad->{source_fingerprints}{add} = 'stale';
    eval { Diag::Translation::Words::import_document( $conf, $diagnostics, $bad, $provenance ) };
    like( $@, qr/source changed/, 'stale source is rejected before import' );
    $bad = Storable::dclone($document);
    push @{ $bad->{vocabulary_sets}[0]{forms} }, $bad->{vocabulary_sets}[0]{forms}[0];
    eval { Diag::Translation::Words::import_document( $conf, $diagnostics, $bad, $provenance ) };
    like( $@, qr/duplicate name/, 'duplicate form names are rejected' );
    my ($comma)         = grep { $_->{number} == 1406 } @$diagnostics;
    my $domain_identity = Scalar::Util::refaddr( $comma->{operation_words}{function}{operations} );
    my $catalog_before  = Diag::Translation::fingerprint( Diag::Migration::render_catalog($conf) );
    is( Diag::Translation::Words::import_document( $conf, $diagnostics, $document, $provenance ),
        1, 'valid draft vocabulary imports' );
    is( $data->{languages}{fr}{words}{add}{status}, 'draft', 'repair cannot claim linguistic review' );
    is( Scalar::Util::refaddr( $comma->{operation_words}{function}{operations} ),
        $domain_identity, 'import preserves shared operation-domain identity' );
    is( Diag::Translation::fingerprint( Diag::Migration::render_catalog($conf) ),
        $catalog_before, 'word-only repair leaves the diagnostic config byte-identical' );
    $contexts = Diag::Translation::Words::contexts( $conf, $diagnostics, $options );
    ok( !grep( $_->{code} eq 'add', @$contexts ), 'current repaired draft is not endlessly requeued' );
    my $saved = Diag::Translation::read_provenance($provenance);
    ok( $saved->{words}{fr}{add}{fingerprint}, 'word provenance has its own namespace' );
    my $review = { %$options, mode => 'review' };
    my ($review_context) =
      grep { $_->{code} eq 'add' } @{ Diag::Translation::Words::contexts( $conf, $diagnostics, $review ) };
    ( $sets, $requests, $reviews, $fingerprints ) =
      Diag::Translation::accept_response( [$review_context], { results => [$result] },
        $diagnostics, $conf, 'fr', $review );
    $document = {
        vocabulary_version  => 1,
        target_language     => 'fr',
        workflow            => 'review',
        reviewed            => JSON::PP::true(),
        vocabulary_sets     => $sets,
        source_fingerprints => $fingerprints
    };
    Diag::Translation::Words::import_document( $conf, $diagnostics, $document, $provenance );
    is(
        join( ',',
            map  { $_->{code} }
            grep { exists $_->{message_selectors} && ref( $_->{message_selectors} ) ne 'ARRAY' } @$diagnostics ),
        '',
        'publishing vocabulary changes preserves valid absent selector lists'
    );
    is( $data->{languages}{fr}{words}{add}{status}, 'reviewed', 'only the review workflow marks a word reviewed' );
    my $report = Diag::Translation::Words::audit_report( $conf, $diagnostics, $options );
    is( $report->{languages}[0]{totals}{unreviewed},    207, 'audit separates review status from runtime coverage' );
    is( $report->{languages}[0]{totals}{missing_words}, 0,   'complete vocabulary has no missing words' );
    my $text = Diag::Words::render_catalog($data);
    is( Diag::Migration::_readable_catalog_dump(q("\x{e9}")),
        qq("\x{e9}"), 'legacy Dumper hex escapes use the same readable catalog output' );
    {
        local $data->{languages}{fr}{words}{add}{forms}{default} = "\x{e9}";
        utf8::downgrade( $data->{languages}{fr}{words}{add}{forms}{default} );
        like( Diag::Words::render_catalog($data),
            qr/"default"\s*=>\s*"\x{e9}"/, 'Latin-1-representable characters are written as readable UTF-8 too' );
    }
    my $roundtrip = eval $text;
    die $@ if $@;
    is(
        Diag::Translation::fingerprint($roundtrip),
        Diag::Translation::fingerprint($data),
        'word config round-trip preserves every form, tag and rule'
    );
    {
        my $changes = Storable::dclone($document);
        $changes->{vocabulary_sets}[0]{changes} = [
            { kind => 'form', name => 'future_form' },
            { kind => 'tag',  name => 'agreement', values => ['plain'] },
            { kind => 'rule', name => 'reviewed_indefinite', form => 'indefinite', select => [] },
            {
                kind      => 'binding',
                code      => 'ERROR_MUTATION_LVALUE_TARGET_NOT_MODIFIABLE',
                parameter => 'target',
                rule      => 'reviewed_indefinite',
                selectors => []
            },
        ];
        my ( $candidate, $diags ) = Diag::Translation::Words::apply_document( $conf, $diagnostics, $changes, $data, 1 );
        ok( exists $candidate->{languages}{fr}{rules}{reviewed_indefinite},       'typed rule declaration validates' );
        ok( grep( $_ eq 'future_form', @{ $candidate->{languages}{fr}{forms} } ), 'typed form declaration validates' );
        is( $candidate->{languages}{fr}{tags}{agreement}[0], 'plain', 'typed tag declaration validates' );
        my ($lvalue) = grep { $_->{number} == 1419 } @$diags;
        is( $lvalue->{operation_words}{target}{rules}{fr},
            'reviewed_indefinite', 'typed binding selects a language-local rule' );
        ok(
            !exists $data->{languages}{fr}{rules}{reviewed_indefinite},
            'recommendation validation leaves live rules unchanged'
        );
    }
    {
        local $data->{languages}{fr}{words}{add}{forms}{indefinite};
        local $data->{languages}{fr}{words}{multiply}{forms}{indefinite};
        delete $data->{languages}{fr}{words}{add}{forms}{indefinite};
        delete $data->{languages}{fr}{words}{multiply}{forms}{indefinite};
        my ($lvalue) = grep { $_->{number} == 1419 } @$diagnostics;
        eval { main::validate_diagnostic( $conf, $lvalue ) };
        like( $@, qr/needs form indefinite/, 'ordinary generation remains strict about requested forms' );
        ok( eval { main::validate_diagnostic( $conf, $lvalue, 1 ); 1 }, 'maintenance can inspect incomplete forms' );
        my $missing = Diag::Translation::Words::contexts( $conf, $diagnostics, $options );
        my ($context) = grep { $_->{code} eq 'add' } @$missing;
        my ( $partial_sets, undef, undef, $sources ) =
          Diag::Translation::accept_response( [$context], { results => [$result] },
            $diagnostics, $conf, 'fr', $options );
        is( scalar @$partial_sets, 1, 'batch can repair one form while other words are incomplete' );
        my $partial_document = {
            vocabulary_version  => 1,
            target_language     => 'fr',
            workflow            => 'repair',
            vocabulary_sets     => $partial_sets,
            source_fingerprints => $sources
        };
        eval { Diag::Translation::Words::import_document( $conf, $diagnostics, $partial_document, $provenance ) };
        like( $@, qr/needs form indefinite/, 'final import rejects remaining incomplete dependencies' );
        ok(
            !exists $data->{languages}{fr}{words}{add}{forms}{indefinite},
            'failed final import does not publish a partial repair'
        );
        my $incomplete_response = Storable::dclone($result);
        $incomplete_response->{forms} = [ grep { $_->{name} ne 'indefinite' } @{ $incomplete_response->{forms} } ];
        eval {
            Diag::Translation::accept_response( [$context], { results => [$incomplete_response] },
                $diagnostics, $conf, 'fr', $options );
        };
        like( $@, qr/Incomplete returned forms/, 'an accepted word must itself provide every requested form' );
    }
    my $request = Storable::dclone($result);
    $request->{requests} = [
        {
            kind           => 'grammar',
            name           => 'genitive',
            proposed_value => 'genitive',
            justification  => 'The sentence requires a new form.',
            example        => 'of an operation'
        }
    ];
    ( $sets, $requests ) = Diag::Translation::accept_response( [$review_context], { results => [$request] },
        $diagnostics, $conf, 'fr', $review );
    is( scalar @$sets,     0, 'a grammar request does not silently modify a word' );
    is( scalar @$requests, 1, 'grammar request survives for manual follow-up' );

    # Keep the real batch/checkpoint code while replacing only the model transport.
    local *Diag::Translation::call_codex = sub {
        my ($prefix) = @_;
        open my $fh, '<:raw', "$prefix.prompt" or die $!;
        local $/;
        my $text = <$fh>;
        close $fh or die $!;
        my $payload = Diag::Translation::json()->decode( substr( $text, index( $text, "{\n" ) ) );
        return {
            results => [
                map {
                    my $item     = $_;
                    my $existing = $item->{existing_word};
                    +{
                        code  => $item->{code},
                        forms =>
                          [ map { { name => $_, value => $existing->{forms}{$_} } } sort keys %{ $existing->{forms} } ],
                        tags =>
                          [ map { { name => $_, value => $existing->{tags}{$_} } } sort keys %{ $existing->{tags} } ],
                        changes      => [],
                        requests     => [],
                        review_notes => 'Fixture review.'
                    }
                } @{ $payload->{words} }
            ]
        };
    };
    my $run_options = {
        %$review,
        batch_size  => 1,
        max_batches => 1,
        work_dir    => "$directory/run",
        output      => "$directory/result.json"
    };
    Diag::Translation::run( $conf, $diagnostics, $run_options );
    my $output = Diag::Translation::read_json( $run_options->{output} );
    is( scalar @{ $output->{vocabulary_sets} }, 1, 'shared runner saves typed vocabulary output' );
    ok( !exists $output->{template_sets}, 'vocabulary output is not confused with sentence sets' );
    my $checkpoint = Diag::Translation::read_json("$directory/run/checkpoint.json");
    ok( $checkpoint->{vocabulary}, 'checkpoint distinguishes word and sentence workflows' );
    $run_options->{resume} = 1;
    Diag::Translation::run( $conf, $diagnostics, $run_options );
    $output = Diag::Translation::read_json( $run_options->{output} );
    is( scalar @{ $output->{vocabulary_sets} }, 2, 'resume retains earlier words and processes the next batch' );
}
