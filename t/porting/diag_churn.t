#!./perl

BEGIN {
    @INC = -f './TestInit.pm' ? ('.') : ('..');
}
use TestInit qw(T);
use strict;
use warnings;
use charnames ':full';
require './t/test.pl';
require './regen/diag.pl';
require './regen/diag_translate.pm';
require './regen/diag_pack.pm';

{
    open my $perl_h, '<', 'perl.h' or die "Cannot read perl.h: $!";
    local $/;
    my $perl_h_source = <$perl_h>;
    close $perl_h or die "Cannot close perl.h: $!";
    like( $perl_h_source,
        qr/#define PERL_K_UNRELIABLE_READERS\s+\\\n\s+"Reader count sampled without its mutex; it may have changed: "/,
        'lock diagnostics describe the sampled reader count uncertainty in words' );
    unlike( $perl_h_source,
        qr/aTHX, mutex, "\?", \(mutex\)->readers_count/,
        'lock panic calls do not use a bare question mark for reader count uncertainty' );
    open my $perldiag_h, '<', 'perldiag.h'
      or die "Cannot read perldiag.h: $!";
    my $perldiag_h_source = <$perldiag_h>;
    close $perldiag_h or die "Cannot close perldiag.h: $!";
    like( $perldiag_h_source,
        qr/#define PERL_DIAG_FORMAT_ERROR_SYSTEM_PLATFORM_VMS_IDENTITY_RIGHTS_LIST_LENGTH_INCONSISTENT .*RIGHTSLIST byte lengths \(required=.*buffer=/,
        'VMS startup panic keeps an allocation-free labeled length format' );
}

plan('no_plan');

{
    my $opaque = { code => 'OPAQUE_BOUNDARY', number => 1, dynamic => 'text' };
    my $before = Diag::Translation::fingerprint($opaque);
    my $report = Diag::Translation::audit_report( {}, [$opaque], 'fr', { entries => {} } );
    is( $report->{languages}[0]{totals}{diagnostics}, 0, 'translation audit skips opaque text boundaries' );
    is( Diag::Translation::fingerprint($opaque),
        $before, 'translation audit does not create a template on an opaque boundary' );
}

{
    my $provenance_path = tempfile();
    my $original = { version => 1, entries => { fr => { OLD => { workflow => 'repair' } } } };
    Diag::Translation::write_json( $provenance_path, $original );
    my $staged = stage_repair_provenance($provenance_path);
    is( Diag::Translation::json()->encode( Diag::Translation::read_json($provenance_path) ),
        Diag::Translation::json()->encode($original),
        'staging repair provenance leaves the published file untouched' );
    my $updated = { version => 1, entries => { fr => { NEW => { workflow => 'repair' } } } };
    Diag::Translation::write_json( $staged, $updated );
    my $failed_publish = eval { publish_repair_provenance( "$staged.missing", $provenance_path ); 1 };
    ok( !$failed_publish, 'failed provenance publication reports an error' );
    is( Diag::Translation::json()->encode( Diag::Translation::read_json($provenance_path) ),
        Diag::Translation::json()->encode($original),
        'failed provenance publication leaves prior provenance intact' );
    ok( -e $staged, 'failed provenance publication retains the staged recovery file' );
    publish_repair_provenance( $staged, $provenance_path );
    is( Diag::Translation::json()->encode( Diag::Translation::read_json($provenance_path) ),
        Diag::Translation::json()->encode($updated),
        'repair provenance becomes visible only after explicit publication' );
    ok( !-e $staged, 'published repair provenance staging file is renamed away' );
    unlink $provenance_path or die "Cannot remove test provenance $provenance_path: $!\n";
}

our ( $CONF, $META );
do './diag_conf.pl';
die 'Cannot load the diagnostic catalog' unless ref($CONF) eq 'HASH';

{
    my $vocabulary = Diag::Words::catalog();
    ok( Diag::Words::validate($vocabulary), 'operation vocabulary validates against regen/opcodes' );
    ok( Diag::Words::literal_operation( $vocabulary, Diag::Words::source_words(), 'prtf' ),
        'internal prtf spelling still denotes the literal printf keyword' );
    ok( !Diag::Words::literal_operation( $vocabulary, Diag::Words::source_words(), 'schop' ),
        'scalar chop remains a descriptive phrase' );
    my ($diagnostic) = grep { $_->{number} == 1419 } @{ Diag::Migration::diagnostics($CONF) };
    my $context = Diag::Words::context( $diagnostic, 'fr' );
    my ($target) = grep { $_->{parameter} eq 'target' } @{ $context->{parameters} };
    my $addition = $context->{words}{add};
    is( scalar @{ $target->{operations} }, 121, 'word packet retains the independent target domain' );
    is( scalar @{ Diag::Migration::template_cases( $diagnostic, 'en' ) }, 1,
        'English lvalue message does not expand the opcode cross-product' );
    is( $addition->{english}, 'addition (+)', 'word context preserves the English operation description' );
    is( $addition->{translation}{forms}{default}, 'addition (+)', 'word context includes the target-language form' );
    is( $addition->{translation}{tags}{gender}, 'feminine', 'word context includes grammatical tags' );
    is( $addition->{translation}{status}, 'draft', 'initial vocabulary translations are explicitly drafts' );
    ok( $context->{runtime_substitution}, 'translation context identifies implemented runtime word substitution' );
    is( Diag::Words::resolve_word( $vocabulary, 'fr', 'add', 'gender' )->{selectors}{gender},
        'feminine', 'language rule maps a word tag to a selector value' );
    {
        local $vocabulary->{languages}{fr}{words}{multiply};
        delete $vocabulary->{languages}{fr}{words}{multiply};
        is( Diag::Words::resolve_word( $vocabulary, 'fr', 'multiply', 'gender' )->{selectors}{gender},
            '*', 'missing word uses this language rule fallback' );
        my $missing = Diag::Words::context( $diagnostic, 'fr' )->{words}{multiply};
        ok( !defined $missing->{translation}, 'missing translation is explicit rather than disguised as English' );
    }
    my $unknown = Diag::Words::context( $diagnostic, 'unknown_language' );
    is( scalar keys %{ $unknown->{rules} }, 0, 'unknown language does not borrow another language grammar' );

    my $snapshot = Diag::Translation::source_fingerprint( $CONF, $diagnostic, 'fr' );
    {
        local $addition->{translation}{tags}{gender} = 'masculine';
        isnt( Diag::Translation::source_fingerprint( $CONF, $diagnostic, 'fr' ), $snapshot,
            'changing a used word tag invalidates its translation fingerprint' );
    }
    {
        local $vocabulary->{languages}{de}{words}{add}{forms}{default} = 'different German wording';
        is( Diag::Translation::source_fingerprint( $CONF, $diagnostic, 'fr' ), $snapshot,
            'another language word change does not invalidate French' );
    }
    {
        local $vocabulary->{languages}{de}{rules}{operation_alias} = $vocabulary->{languages}{de}{rules}{operation};
        local $diagnostic->{operation_words}{target}{rules}{de} = 'operation_alias';
        is( Diag::Translation::source_fingerprint( $CONF, $diagnostic, 'fr' ), $snapshot,
            'another language rule binding does not invalidate French' );
    }
    {
        local $vocabulary->{languages}{fr}{forms} = [ @{ $vocabulary->{languages}{fr}{forms} }, 'unused_form' ];
        local $vocabulary->{languages}{fr}{words}{add}{forms}{unused_form} = 'unused phrase';
        is( Diag::Translation::source_fingerprint( $CONF, $diagnostic, 'fr' ), $snapshot,
            'unused word forms do not invalidate a sentence' );
    }
    {
        local $vocabulary->{languages}{fr}{words}{add}{status} = 'reviewed';
        is( Diag::Translation::source_fingerprint( $CONF, $diagnostic, 'fr' ), $snapshot,
            'linguistic review status is separate from source freshness' );
    }
    {
        local $vocabulary->{languages}{fr}{words}{add}{forms}{indefinite} = 'changed required phrase';
        isnt( Diag::Translation::source_fingerprint( $CONF, $diagnostic, 'fr' ), $snapshot,
            'a used word form invalidates its sentence' );
    }
    {
        my $coverage = Diag::Words::coverage( $diagnostic, 'fr' );
        ok( $coverage->{complete}, 'draft vocabulary still has complete runtime coverage' );
        ok( scalar @{ $coverage->{unreviewed_words} }, 'draft words remain visible as unreviewed' );
        local $vocabulary->{languages}{fr}{words}{add};
        delete $vocabulary->{languages}{fr}{words}{add};
        $coverage = Diag::Words::coverage( $diagnostic, 'fr' );
        ok( !$coverage->{complete}, 'missing vocabulary is not hidden by a translated sentence' );
        is( join( ',', @{ $coverage->{missing_words} } ), 'add', 'missing words are deduplicated across roles' );
    }
    {
        local $vocabulary->{languages}{fr}{words}{add}{forms}{indefinite};
        delete $vocabulary->{languages}{fr}{words}{add}{forms}{indefinite};
        my $coverage = Diag::Words::coverage( $diagnostic, 'fr' );
        ok( scalar @{ $coverage->{missing_forms} }, 'missing requested forms have separate coverage records' );
    }
    {
        local $vocabulary->{languages}{en}{words}{add}{forms}{default} = 'stale addition description';
        eval { Diag::Words::validate($vocabulary); 1 };
        like( $@, qr/stale English text/, 'changed source descriptions require a deliberate vocabulary update' );
    }
    {
        local $vocabulary->{languages}{fr}{words}{add}{form} = 'misspelled field';
        eval { Diag::Words::validate($vocabulary); 1 };
        like( $@, qr/unknown field form/, 'word field typos are rejected' );
    }
    {
        local $diagnostic->{operation_words}{target}{source} = 'missing_identity';
        eval { Diag::Words::validate_bindings($diagnostic); 1 };
        like( $@, qr/has no retained identity source/, 'word bindings require a retained identity source' );
    }
}

# Class assignments are computed from shipped inputs, including new codes.
# The planning workbooks are derived review reports, not regeneration inputs.
{
    my $fixture = churn_diagnostic( 'CLASS_MODEL_NEW_CODE', 65003, 'value' );
    my ($diagnostics) = churn_catalog($fixture);
    my $model = Diag::Classes::build_model(
        $diagnostics, $CONF->{diagnostic_classes},
        Perl::Regen::Warnings::tree(), Diag::Migration::read_source('warnings.h')
    );
    is( $model->{by_code}{CLASS_MODEL_NEW_CODE}{proposed_class}, 'XPerl::Diagnostic::Error',
        'new catalog codes receive a class without a workbook edit' );
    is( $model->{classes}{'XPerl::Diagnostic::Warning::IO::Pipe'}{parent},
        'XPerl::Diagnostic::Warning::IO', 'warning classes honor the warning hierarchy' );
    is( $model->{classes}{'XPerl::Diagnostic::Warning::IO::Pipe'}{warning_symbol}, 'WARN_PIPE',
        'dynamic warning lookup preserves the canonical category-to-class mapping' );
    is( $model->{classes}{'XPerl::Diagnostic::Warning'}{warning_symbol}, 'WARN_ALL',
        'category zero explicitly maps to the Warning root' );

    my $classes = {
        'XPerl::DiagGroup' => {},
        'XPerl::Diagnostic' => { parent => 'XPerl::DiagGroup' },
        'XPerl::Diagnostic::Leaf' => { parent => 'XPerl::Diagnostic', leaf_only => 1 },
        'XPerl::Diagnostic::Leaf::Child' => { parent => 'XPerl::Diagnostic::Leaf' },
    };
    Diag::Classes::validate_classes($classes);
    is( $classes->{'XPerl::Diagnostic::Leaf::Child'}{leaf_only}, 1,
        'leaf-only restrictions are inherited outside the Note family' );
    $classes->{'XPerl::Diagnostic::Leaf::Child'}{leaf_only} = 0;
    eval { Diag::Classes::validate_classes($classes); 1 };
    like( $@, qr/weakens an inherited leaf restriction/, 'subclasses cannot weaken leaf-only restrictions' );
    $classes->{'XPerl::Diagnostic::Leaf::Child'}{leaf_only} = 1;
    $classes->{'XPerl::Diagnostic::Leaf::Child'}{parent} = 'XPerl::Diagnostic::Missing';
    eval { Diag::Classes::validate_classes($classes); 1 };
    like( $@, qr/Unknown diagnostic class/, 'unknown class parents are rejected' );
    $classes->{'XPerl::Diagnostic::Leaf::Child'}{parent} = 'XPerl::Diagnostic::Leaf::Child';
    eval { Diag::Classes::validate_classes($classes); 1 };
    like( $@, qr/Diagnostic class cycle/, 'class inheritance cycles are rejected' );
    $diagnostics->[0]{class} = 'XPerl::Diagnostic::Missing';
    eval {
        Diag::Classes::build_model( $diagnostics, $CONF->{diagnostic_classes},
            Perl::Regen::Warnings::tree(), Diag::Migration::read_source('warnings.h') );
        1;
    };
    like( $@, qr/Unknown class .* for CLASS_MODEL_NEW_CODE/, 'unknown explicit classes do not autovivify' );
}

SKIP: {
    skip( 'fake model executable test requires a Unix process launcher', 68 ) if $^O eq 'MSWin32';
    require File::Temp;
    my $code = 'FAKE_TRANSLATION_DRIVER';
    my $second_code = 'FAKE_TRANSLATION_DRIVER_SECOND';
    my $definition = churn_diagnostic( $code, 65000, 'value' );
    my $second_definition = churn_diagnostic( $second_code, 65001, 'value' );
    my $fake_conf = {
        severities      => $CONF->{severities},
        exception_kinds => $CONF->{exception_kinds},
        languages       => $CONF->{languages},
        plural_rules    => $CONF->{plural_rules},
        documentation   => $CONF->{documentation},
        diagnostics     => {
            FATAL_ERROR => { CORE_RUNTIME => { $code => $definition, $second_code => $second_definition } },
        },
    };
    my $fake_diagnostics = Diag::Migration::diagnostics($fake_conf);
    my $selected_code = 'FAKE_TRANSLATION_SELECTOR';
    my $selected_definition = churn_diagnostic( $selected_code, 65002, 'value' );
    unshift @{ $selected_definition->{message}{args} }, {
        name => 'mode', type => 'text', format_str => 's', selector_values => [qw(alpha beta)],
    };
    $selected_definition->{message}{templates}{en} = {
        '*' => 'Value %{value}', alpha => 'Alpha %{value}', beta => 'Beta %{value}',
    };
    my $selected_conf = {
        %$fake_conf,
        diagnostics => { FATAL_ERROR => { CORE_RUNTIME => { $selected_code => $selected_definition } } },
    };
    my $selected_diagnostics = Diag::Migration::diagnostics($selected_conf);
    my $selected_diag = $selected_diagnostics->[0];
    my $producer_before = main::render_diag_helper($selected_diag);
    my $producer_signature_before = main::helper_signature($selected_diag);
    my $canonical_before = Diag::Migration::template_parameter_layout($selected_diag);
    my ( $english_display, $english_projection ) =
      Diag::Migration::template_case_parameter_layout( $selected_diag, 'Value %{value}' );
    my %foreign_templates = %{ $selected_diag->{message_template} };
    $foreign_templates{fr} = {
        '*' => 'Mot %{mode} %{value}',
        alpha => 'Alfa %{mode} %{value}',
        beta => 'Bêta %{mode} %{value}',
    };
    my %foreign_diag = ( %$selected_diag, message_template => \%foreign_templates );
    my $producer_after = main::render_diag_helper(\%foreign_diag);
    my $producer_signature_after = main::helper_signature(\%foreign_diag);
    my $canonical_after = Diag::Migration::template_parameter_layout(\%foreign_diag);
    my ( $foreign_display, $foreign_projection ) =
      Diag::Migration::template_case_parameter_layout(
        \%foreign_diag, 'Mot %{mode} %{value}' );
    is( $producer_after, $producer_before,
        'adding a foreign selector placeholder leaves generated producer capture unchanged' );
    is( $producer_signature_after, $producer_signature_before,
        'adding a foreign selector placeholder leaves producer names and parameter order unchanged' );
    is( join( ',', map { $_->{name} } @{ $canonical_after->{canonical_params} } ),
        join( ',', map { $_->{name} } @{ $canonical_before->{canonical_params} } ),
        'foreign placeholders leave the canonical captured schema unchanged' );
    is( join( ',', @$english_projection ), '1',
        'English display projection uses the canonical source index' );
    is( join( ',', @$foreign_projection ), '0,1',
        'foreign projection adds the selector source in canonical order' );
    is( join( ',', map { $_->{name} } @$english_display ), 'value',
        'English case keeps its own dense display parameters' );
    is( join( ',', map { $_->{name} } @$foreign_display ), 'mode,value',
        'foreign case displays the existing selector parameter when requested' );
    my $selected_context = Diag::Translation::diagnostic_context(
        $selected_conf, $selected_diagnostics->[0], 'fr', Diag::Translation::documentation_index($selected_conf)
    );
    my $directory = File::Spec->rel2abs( File::Temp::tempdir( DIR => '../tmp', CLEANUP => 1 ) );
    my $fake_model = "$directory/fake-model";
    my $resume_marker = "$directory/allow-exhausted-resume";
    open my $script, '>:raw', $fake_model or die "Cannot create fake model: $!\n";
    my $test_perl = File::Spec->rel2abs($^X);
    print {$script} <<"FAKE_MODEL";
#!$test_perl
use strict;
use warnings;
my \$output;
while (\@ARGV) {
    my \$argument = shift \@ARGV;
    \$output = shift \@ARGV if \$argument eq '--output-last-message';
}
if (\$output =~ /transport/) {
    print STDERR "fake transport failure\\n";
    exit 17;
}
# Consume the prompt before responding, as the real model process does.
# Exiting early races the parent's pipe writes under parallel test load.
while (<STDIN>) { }
open my \$response, '>:raw', \$output or die \$!;
if (\$output =~ /command-level|cleanup-error|generation-error|publication-error|import-error/) {
    print {\$response}
      '{"results":[{"code":"ERROR_INTERNAL_LOCALE_OPAQUE_FAILURE",'
      . '"cases":[{"selectors":[],"template":"Erro %{message}"}],'
      . '"requests":[],"review_notes":""}]}';
}
my \$response_code = \$output =~ /batch-000[2-9]/ ? '$second_code' : '$code';
if (\$output =~ /command-level|cleanup-error|generation-error|publication-error|import-error/) {
    # The command-level fixture response above is complete.
}
elsif (\$output =~ /requests/) {
    print {\$response}
      '{"results":[{"code":"' . \$response_code . '","cases":[],'
      . '"requests":[{"kind":"selector","name":"opcode",'
      . '"proposed_value":"new_value","justification":"a distinct case is required",'
      . '"example":"operation for new_value"}],"review_notes":""}]}';
}
elsif (\$output =~ /exhausted/ && \$output =~ /batch-000[2-9]/ && !-e '$resume_marker') {
    print {\$response} '{"results":[]}';
}
elsif (\$output =~ /retry/) {
    print {\$response}
      '{"results":[{"code":"' . \$response_code . '",'
      . '"cases":[{"selectors":[],"template":"Valeur \\u00e9 %{value}"}],'
      . '"requests":[],"review_notes":""}]}';
}
else {
    print {\$response} '{"results":[]}';
}
close \$response or die \$!;
FAKE_MODEL
    close $script or die "Cannot close fake model: $!\n";
    chmod 0755, $fake_model or die "Cannot make fake model executable: $!\n";
    my $options = {
        mode            => 'translate',
        language        => 'fr',
        work_dir        => "$directory/work",
        output          => "$directory/output.json",
        provenance_file => "$directory/provenance.json",
        codex           => $fake_model,
        batch_size      => 1,
        code            => $code,
    };
    my $runs = Diag::Translation::run( $fake_conf, $fake_diagnostics, $options );
    is( scalar @$runs, 1, 'translation driver completes through a fake model process' );
    ok( $runs->[0]{complete}, 'fake-process translation run reports completion' );
    is( Diag::Translation::read_json( $options->{output} )->{template_sets}[0]{cases}[0]{template},
        "Valeur \N{LATIN SMALL LETTER E WITH ACUTE} %{value}",
        'fake-process Unicode response is validated and saved by the driver' );
    ok( -e "$directory/work/batch-0001.response.json", 'rejected first response is retained' );
    ok( -e "$directory/work/batch-0001-retry-1.prompt", 'validation retry has a distinct prompt artifact' );
    open my $retry_prompt, '<:raw', "$directory/work/batch-0001-retry-1.prompt"
      or die "Cannot read retry prompt: $!\n";
    local $/;
    my $retry_text = <$retry_prompt>;
    close $retry_prompt or die "Cannot close retry prompt: $!\n";
    like( $retry_text, qr/"previous_validation_error"\s*:\s*"Missing Codex results/,
        'validation error feedback is included in the retry prompt' );
    my $context = Diag::Translation::diagnostic_context(
        $fake_conf, $fake_diagnostics->[0], 'fr', Diag::Translation::documentation_index($fake_conf)
    );
    my $import_diagnostics = Diag::Translation::json()->decode(
        Diag::Translation::json()->encode($fake_diagnostics)
    );
    my $failed_import_document = Diag::Translation::read_json( $options->{output} );
    $failed_import_document->{source_fingerprints}{$code} = 'obsolete';
    my $failed_import_path = "$directory/failed-import.json";
    Diag::Translation::write_json( $failed_import_path, $failed_import_document );
    my $import_provenance = "$directory/import-provenance.json";
    my $import_provenance_original = { version => 1, entries => { fr => { OLD => { workflow => 'repair' } } } };
    Diag::Translation::write_json( $import_provenance, $import_provenance_original );
    my $staged_import_provenance = stage_repair_provenance($import_provenance);
    my $imported = eval {
        load_translation_table( $fake_conf, $import_diagnostics, $failed_import_path,
            $staged_import_provenance );
        1;
    };
    ok( !$imported, 'stale source fingerprint fails translation import' );
    is( Diag::Translation::json()->encode( Diag::Translation::read_json($import_provenance) ),
        Diag::Translation::json()->encode($import_provenance_original),
        'failed import leaves published provenance unchanged' );
    ok( -e $staged_import_provenance, 'failed import retains staged provenance for recovery' );
    unlink $staged_import_provenance, $failed_import_path, $import_provenance
      or die "Cannot clean failed-import test files: $!\n";
    my $bad_placeholders = {
        results => [{ code => $code, cases => [{ selectors => [], template => 'Valeur %{missing}' }],
            requests => [], review_notes => '' }],
    };
    my $valid_placeholders = eval {
        Diag::Translation::accept_response( [ $context ], $bad_placeholders, $fake_diagnostics, $fake_conf, 'fr' );
        1;
    };
    ok( !$valid_placeholders, 'response with the wrong placeholder name is rejected' );
    my $duplicate_zero_selector = {
        results => [{ code => $code, cases => [
            { selectors => [], template => 'Valeur %{value}' },
            { selectors => [], template => 'Autre %{value}' },
        ], requests => [], review_notes => '' }],
    };
    my $valid_zero_selector = eval {
        Diag::Translation::accept_response( [ $context ], $duplicate_zero_selector, $fake_diagnostics,
            $fake_conf, 'fr' );
        1;
    };
    ok( !$valid_zero_selector, 'zero-selector response with multiple cases is rejected' );
    my $missing_result = eval {
        Diag::Translation::accept_response( [ $context ], { results => [] }, $fake_diagnostics,
            $fake_conf, 'fr' );
        1;
    };
    ok( !$missing_result && $@ =~ /Missing Codex results/,
        'response with missing diagnostic results is rejected' );
    my $duplicate_result = eval {
        Diag::Translation::accept_response(
            [ $context ],
            { results => [ map { { code => $code, cases => [], requests => [], review_notes => '' } } 1 .. 2 ] },
            $fake_diagnostics, $fake_conf, 'fr'
        );
        1;
    };
    ok( !$duplicate_result && $@ =~ /Unexpected or duplicate result/,
        'response with duplicate diagnostic results is rejected' );
    my $duplicate_pattern = eval {
        Diag::Translation::accept_response(
            [ $selected_context ],
            { results => [{
                code => $selected_code,
                cases => [
                    { selectors => ['alpha'], template => 'Premier %{value}' },
                    { selectors => ['alpha'], template => 'Autre %{value}' },
                    { selectors => ['*'], template => 'Valeur %{value}' },
                ],
                requests => [], review_notes => '',
            }] },
            $selected_diagnostics, $selected_conf, 'fr'
        );
        1;
    };
    ok( !$duplicate_pattern,
        'conflicting duplicate selector patterns are rejected before import' );

    my $request_options = {
        mode => 'translate', language => 'fr', work_dir => "$directory/requests",
        output => "$directory/request-output.json", provenance_file => "$directory/request-provenance.json",
        codex => $fake_model, batch_size => 1, code => $code,
    };
    my $request_error;
    eval { Diag::Translation::run( $fake_conf, $fake_diagnostics, $request_options ); 1 }
      or $request_error = "$@";
    like( $request_error, qr/manual selector changes/,
        'valid selector request stops for manual work without a validation retry' );
    ok( -e "$directory/requests/batch-0001.response.json", 'selector request response is retained' );
    ok( !-e "$directory/requests/batch-0001-retry-1.prompt",
        'selector request does not create a validation retry' );

    my $transport_options = {
        mode => 'translate', language => 'fr', work_dir => "$directory/transport",
        output => "$directory/transport-output.json", provenance_file => "$directory/transport-provenance.json",
        codex => $fake_model, batch_size => 1, code => $code,
    };
    my $transport_error;
    eval { Diag::Translation::run( $fake_conf, $fake_diagnostics, $transport_options ); 1 }
      or $transport_error = "$@";
    like( $transport_error, qr/batch failed.*batch-0001\.log/s,
        'process failure reports its original log path without validation retry' );
    ok( -e "$directory/transport/batch-0001.log", 'transport failure log is preserved' );
    ok( !-e "$directory/transport/batch-0001-retry-1.prompt",
        'transport failure does not create a validation retry' );

    my $dry_options = {
        mode => 'translate', language => 'fr', work_dir => "$directory/dry-run",
        output => "$directory/dry-output.json", codex => $fake_model,
        provenance_file => "$directory/dry-provenance.json",
        batch_size => 1, code => $code, dry_run => 1,
    };
    my $dry_runs = Diag::Translation::run( $fake_conf, $fake_diagnostics, $dry_options );
    ok( !$dry_runs->[0]{complete}, 'dry-run does not report a completed translation' );
    ok( -e "$directory/dry-run/batch-0001.prompt", 'dry-run prepares its prompt' );
    ok( !-e $dry_options->{output}, 'dry-run does not write a translation output' );

    my %repair_languages = map { $_ => $CONF->{languages}{$_} } qw(en fr it);
    my $all_conf = { %$fake_conf, languages => \%repair_languages };
    my $all_options = {
        mode            => 'repair',
        language        => 'all',
        work_dir        => "$directory/all",
        provenance_file => "$directory/all-provenance.json",
        codex           => $fake_model,
        batch_size      => 1,
        max_batches     => 1,
        code            => $code,
    };
    my $all_runs = Diag::Translation::run( $all_conf, $fake_diagnostics, $all_options );
    is( join( ',', map { $_->{language} } @$all_runs ), 'fr,it',
        'all-language repair runs languages in sorted order' );
    ok( $all_runs->[0]{complete} && $all_runs->[1]{complete},
        'max-batches is applied independently to each language' );
    isnt( $all_runs->[0]{output}, $all_runs->[1]{output},
        'all-language repair writes separate outputs' );
    for my $run (@$all_runs) {
        my $unrelated = "$run->{work_dir}/keep.txt";
        open my $keep, '>', $unrelated or die "Cannot create unrelated repair file: $!\n";
        print {$keep} "keep\n";
        close $keep or die "Cannot close unrelated repair file: $!\n";
        $run->{unrelated} = $unrelated;
    }
    Diag::Translation::cleanup_repairs($all_runs);
    ok( -e $_->{unrelated}, 'cleanup preserves unrelated work-directory files' ) for @$all_runs;

    my $resume_options = {
        mode            => 'translate',
        language        => 'fr',
        work_dir        => "$directory/resume",
        output          => "$directory/resume-output.json",
        provenance_file => "$directory/resume-provenance.json",
        codex           => $fake_model,
        batch_size      => 1,
        max_batches     => 1,
    };
    my $partial = Diag::Translation::run( $fake_conf, $fake_diagnostics, $resume_options );
    ok( !$partial->[0]{complete}, 'max-batches leaves a multi-batch run incomplete' );
    $resume_options->{resume} = 1;
    my $resume_checkpoint = "$resume_options->{work_dir}/checkpoint.json";
    my $saved_state = Diag::Translation::read_json($resume_checkpoint);
    delete @{$saved_state}{qw(model reasoning_effort)};
    Diag::Translation::write_json( $resume_checkpoint, $saved_state );
    my $legacy_error;
    eval { Diag::Translation::run( $fake_conf, $fake_diagnostics, $resume_options ); 1 }
      or $legacy_error = "$@";
    like( $legacy_error, qr/no recorded model and reasoning effort.*fresh --work-dir/s,
        'resume refuses a legacy checkpoint with an unknown execution profile' );
    $saved_state->{model} = 'gpt-6-luna';
    $saved_state->{reasoning_effort} = 'medium';
    Diag::Translation::write_json( $resume_checkpoint, $saved_state );
    $resume_options->{reasoning_effort} = 'high';
    my $profile_error;
    eval { Diag::Translation::run( $fake_conf, $fake_diagnostics, $resume_options ); 1 }
      or $profile_error = "$@";
    like( $profile_error, qr/Checkpoint model or reasoning effort differs.*fresh --work-dir/s,
        'resume refuses to combine batches from another execution profile' );
    $resume_options->{reasoning_effort} = 'medium';
    my $resumed = Diag::Translation::run( $fake_conf, $fake_diagnostics, $resume_options );
    ok( $resumed->[0]{complete}, 'resume processes the remaining batch' );
    is( scalar @{ Diag::Translation::read_json( $resume_options->{output} )->{template_sets} }, 2,
        'resume preserves the completed batch and adds the remaining translation' );
    ok( -e "$directory/resume/batch-0002-retry-1.prompt",
        'resumed retry artifacts continue at the next batch number' );

    my $exhausted_options = {
        mode => 'translate', language => 'fr', work_dir => "$directory/exhausted",
        output => "$directory/exhausted-output.json", provenance_file => "$directory/exhausted-provenance.json",
        codex => $fake_model, batch_size => 1,
    };
    my $exhausted_error;
    eval { Diag::Translation::run( $fake_conf, $fake_diagnostics, $exhausted_options ); 1 }
      or $exhausted_error = "$@";
    like( $exhausted_error, qr/batch-0002-retry-2\.response\.json/,
        'exhausted validation retries name the final response artifact' );
    is( scalar @{ Diag::Translation::read_json( $exhausted_options->{output} )->{template_sets} }, 1,
        'successful batch remains saved after the next batch exhausts retries' );
    open my $marker, '>', $resume_marker or die "Cannot create resume marker: $!\n";
    close $marker or die "Cannot close resume marker: $!\n";
    $exhausted_options->{resume} = 1;
    my $exhausted_resume = Diag::Translation::run( $fake_conf, $fake_diagnostics, $exhausted_options );
    ok( $exhausted_resume->[0]{complete}, 'run resumes after exhausted retries are corrected' );
    is( scalar @{ Diag::Translation::read_json( $exhausted_options->{output} )->{template_sets} }, 2,
        'resume retains the earlier success after exhausted retries' );

    my @watched_files = qw(diag_conf.pl perldiag.h perldiag_data.inc perldiag_helpers.inc);
    my $watched_hashes = sub {
        return join "\n", map {
            open my $fh, '<:raw', $_ or die "Cannot read $_: $!\n";
            local $/;
            $_ . '=' . sha256_hex(<$fh>);
        } @watched_files;
    };
    my $before_hash = $watched_hashes->();
    my $command_provenance = "$directory/command-provenance.json";
    my $command_original = { version => 1, entries => { pt => { OLD => { workflow => 'repair' } } } };
    Diag::Translation::write_json( $command_provenance, $command_original );

    # Supply the CLI repair cases with a missing target in memory. Their
    # publication checks must not depend on gaps in the shipped catalog.
    my $catalog_diagnostics = \&Diag::Migration::diagnostics;
    local *Diag::Migration::diagnostics;
    *Diag::Migration::diagnostics = sub {
        my $diagnostics = $catalog_diagnostics->(@_);
        for my $diag (@$diagnostics) {
            delete $diag->{message_template}{pt}
              if $diag->{code} eq 'ERROR_INTERNAL_LOCALE_OPAQUE_FAILURE';
        }
        return $diagnostics;
    };

    my @command_common = (
        '--repair-translations=pt', '--code=ERROR_INTERNAL_LOCALE_OPAQUE_FAILURE', '--batch-size=1',
        "--provenance-file=$command_provenance", "--codex=$fake_model",
    );
    {
        local @ARGV = ( @command_common, "--work-dir=$directory/command-level-dry", '--dry-run' );
        main();
    }
    ok( -e "$directory/command-level-dry/batch-0001.prompt",
        'command dry-run prepares work through the real CLI path' );
    ok( !-e "$directory/command-level-dry/perldiag_trans_pt_repair.json",
        'command dry-run does not publish a translation worksheet' );
    is( Diag::Translation::json()->encode( Diag::Translation::read_json($command_provenance) ),
        Diag::Translation::json()->encode($command_original),
        'command dry-run leaves published provenance unchanged' );
    {
        local @ARGV = ( @command_common, "--work-dir=$directory/command-level-no-import", '--no-import' );
        main();
    }
    ok( -e "$directory/command-level-no-import/perldiag_trans_pt_repair.json",
        'command no-import saves the completed translation worksheet' );
    is( Diag::Translation::json()->encode( Diag::Translation::read_json($command_provenance) ),
        Diag::Translation::json()->encode($command_original),
        'command no-import leaves published provenance unchanged' );
    is(
        $watched_hashes->(), $before_hash,
        'dry-run and no-import leave the catalog and generated files unchanged'
    );

    my $generation_provenance = "$directory/generation-error-provenance.json";
    Diag::Translation::write_json( $generation_provenance, $command_original );
    my $generation_error;
    {
        no warnings qw(redefine once);
        local *main::prepare_generation = sub { die "injected generation failure\n" };
        local @ARGV = (
            @command_common, "--work-dir=$directory/generation-error",
            "--output=$directory/generation-error-output.json",
            "--provenance-file=$generation_provenance",
        );
        eval { main(); 1 } or $generation_error = "$@";
    }
    like( $generation_error, qr/injected generation failure/,
        'command-level generation failure is reported before publication' );
    is( Diag::Translation::json()->encode( Diag::Translation::read_json($generation_provenance) ),
        Diag::Translation::json()->encode($command_original),
        'generation failure leaves published provenance unchanged' );
    ok( -e "$generation_provenance.repair-stage.$$",
        'generation failure retains staged provenance for recovery' );
    unlink "$generation_provenance.repair-stage.$$"
      or die "Cannot remove staged command test provenance: $!\n";
    is(
        $watched_hashes->(), $before_hash,
        'generation failure leaves catalog and generated files unchanged'
    );

    my $main_import_provenance = "$directory/import-error-provenance.json";
    Diag::Translation::write_json( $main_import_provenance, $command_original );
    my $prepare_after_import_error = 0;
    my $import_error;
    {
        no warnings qw(redefine once);
        no warnings 'once';
        local *main::load_translation_table = sub { die "injected import failure\n" };
        local *main::prepare_generation = sub { ++$prepare_after_import_error; return {} };
        local @ARGV = (
            @command_common, "--work-dir=$directory/import-error",
            "--output=$directory/import-error-output.json",
            "--provenance-file=$main_import_provenance",
        );
        eval { main(); 1 } or $import_error = "$@";
    }
    like( $import_error, qr/injected import failure/,
        'command-level import failure is reported before generation' );
    is( Diag::Translation::json()->encode( Diag::Translation::read_json($main_import_provenance) ),
        Diag::Translation::json()->encode($command_original),
        'import failure leaves published provenance unchanged' );
    ok( -e "$main_import_provenance.repair-stage.$$",
        'import failure retains staged provenance for recovery' );
    ok( -e "$directory/import-error/checkpoint.json",
        'import failure retains repair checkpoints' );
    is( $prepare_after_import_error, 0,
        'generation does not start after an import failure' );
    unlink "$main_import_provenance.repair-stage.$$"
      or die "Cannot remove staged import test provenance: $!\n";

    my $publication_provenance = "$directory/publication-error-provenance.json";
    Diag::Translation::write_json( $publication_provenance, $command_original );
    my $generated_attempts = 0;
    my $publication_error;
    {
        no warnings qw(redefine once);
        no warnings 'once';
        local *main::write_plain_output = sub { };
        local *main::write_generated_output = sub {
            die "injected generated publication failure\n" if ++$generated_attempts == 2;
        };
        local @ARGV = (
            @command_common, "--work-dir=$directory/publication-error",
            "--output=$directory/publication-error-output.json",
            "--provenance-file=$publication_provenance",
        );
        eval { main(); 1 } or $publication_error = "$@";
    }
    like( $publication_error, qr/injected generated publication failure/,
        'command-level generated publication failure is reported' );
    is( Diag::Translation::json()->encode( Diag::Translation::read_json($publication_provenance) ),
        Diag::Translation::json()->encode($command_original),
        'generated publication failure does not publish new provenance' );
    ok( -e "$publication_provenance.repair-stage.$$",
        'generated publication failure retains staged provenance' );
    ok( -e "$directory/publication-error/checkpoint.json",
        'generated publication failure retains repair checkpoints' );
    unlink "$publication_provenance.repair-stage.$$"
      or die "Cannot remove staged publication test provenance: $!\n";

    my $command_output = "$directory/command-level-output.json";
    my $command_success_provenance = "$directory/command-success-provenance.json";
    my $prepare_count = 0;
    my @plain_publications;
    my @generated_publications;
    {
        no warnings qw(redefine once);
        no warnings 'once';
        local *main::prepare_generation = sub {
            ++$prepare_count;
            return { documentation_path => 'pod/perldiag.pod' };
        };
        local *main::write_plain_output = sub { push @plain_publications, $_[0] };
        local *main::write_generated_output = sub { push @generated_publications, $_[0] };
        local @ARGV = (
            @command_common, "--work-dir=$directory/command-level-success",
            "--output=$command_output", "--provenance-file=$command_success_provenance", '--cleanup',
        );
        main();
    }
    is( $prepare_count, 1, 'completed command repairs prepare generation exactly once' );
    is( scalar @plain_publications, 2, 'completed command publishes both plain outputs once' );
    is( join( ',', sort @generated_publications ),
        join( ',', sort qw(perldiag.h perldiag_data.inc perldiag_helpers.inc perldiag_plural.inc) ),
        'completed command publishes each generated output once' );
    ok( -e $command_output, 'cleanup preserves a completed output outside the work directory' );
    ok( !-e "$directory/command-level-success/checkpoint.json",
        'cleanup runs after successful provenance and output publication' );
    ok( Diag::Translation::read_provenance($command_success_provenance)
            ->{entries}{pt}{ERROR_INTERNAL_LOCALE_OPAQUE_FAILURE},
        'successful command publication records the imported diagnostic' );
    is(
        $watched_hashes->(), $before_hash,
        'isolated publication callbacks leave source catalog files unchanged'
    );

    my $all_command_provenance = "$directory/all-command-provenance.json";
    Diag::Translation::write_json( $all_command_provenance, $command_original );
    my $all_prepare_count = 0;
    {
        no warnings qw(redefine once);
        no warnings 'once';
        local *main::prepare_generation = sub { ++$all_prepare_count; return {} };
        local *main::write_plain_output = sub { };
        local *main::write_generated_output = sub { };
        local @ARGV = (
            '--repair-translations=all', '--code=ERROR_INTERNAL_LOCALE_OPAQUE_FAILURE', '--batch-size=1',
            "--work-dir=$directory/command-level-all/./",
            "--provenance-file=$all_command_provenance", "--codex=$fake_model", '--cleanup',
        );
        main();
    }
    is( $all_prepare_count, 1,
        'completed all-language CLI repair regenerates the catalog exactly once' );
    ok( Diag::Translation::read_provenance($all_command_provenance)->{entries}{pt}{ERROR_INTERNAL_LOCALE_OPAQUE_FAILURE},
        'all-language CLI import publishes the language with repaired fallback' );
    ok( !-e "$directory/command-level-all/pt/checkpoint.json",
        'all-language cleanup handles custom directory spelling after publication' );
    is(
        $watched_hashes->(), $before_hash,
        'all-language command publication callbacks leave catalog inputs unchanged'
    );

    my $cleanup_directory = "$directory/cleanup-error";
    mkdir $cleanup_directory or die "Cannot create cleanup error fixture: $!\n";
    Diag::Translation::write_json(
        "$cleanup_directory/checkpoint.json",
        { mode => 'repair', target_language => 'fr' },
    );
    my $cleanup_artifact = "$cleanup_directory/batch-0001.prompt";
    open my $cleanup_file, '>', $cleanup_artifact or die "Cannot create cleanup artifact: $!\n";
    close $cleanup_file or die "Cannot close cleanup artifact: $!\n";
    chmod 0500, $cleanup_directory or die "Cannot restrict cleanup fixture: $!\n";
    my $cleanup_error = eval {
        Diag::Translation::cleanup_repairs([
            { work_dir => $cleanup_directory, output => "$directory/outside-output.json", language => 'fr' },
        ]);
        1;
    };
    my $cleanup_failure = "$@";
    chmod 0700, $cleanup_directory or die "Cannot restore cleanup fixture permissions: $!\n";
    ok( !$cleanup_error && $cleanup_failure =~ /Cannot remove repair artifact/,
        'cleanup reports an artifact removal failure' );
    ok( -e $cleanup_artifact, 'cleanup failure leaves the unremoved recovery artifact' );
    unlink $cleanup_artifact, "$cleanup_directory/checkpoint.json"
      or die "Cannot remove cleanup fixture files: $!\n";
    rmdir $cleanup_directory or die "Cannot remove cleanup fixture directory: $!\n";
}

my @invalid_cleanup = qw(--repair-translations=fr --cleanup --dry-run);
my $cleanup_options = eval { Diag::Translation::options( \@invalid_cleanup ); 1 };
ok( !$cleanup_options && $@ =~ /--cleanup requires importing a completed repair run/,
    'cleanup rejects dry-run mode during option validation' );
my @invalid_no_import = qw(--translate=fr --no-import);
my $no_import_options = eval { Diag::Translation::options( \@invalid_no_import ); 1 };
ok( !$no_import_options && $@ =~ /--no-import and --cleanup require --repair-translations/,
    'no-import rejects non-repair modes during option validation' );

my @default_profile = qw(--translate=fr);
my $default_profile = Diag::Translation::options( \@default_profile );
is( $default_profile->{model}, 'gpt-6-luna', 'translation defaults to the Luna model' );
is( $default_profile->{reasoning_effort}, 'medium', 'translation defaults to medium reasoning effort' );
my @bad_effort = qw(--translate=fr --reasoning-effort=turbo);
my $bad_effort = eval { Diag::Translation::options( \@bad_effort ); 1 };
ok( !$bad_effort && $@ =~ /Reasoning effort must be one of/,
    'translation rejects an unsupported reasoning effort' );
my @profile_args = qw(--translate=fr --model=gpt-6.1-sol --reasoning-effort=high);
my $profile_options = Diag::Translation::options( \@profile_args );
my @codex_command = Diag::Translation::codex_command(
    'batch', { %$profile_options, work_dir => 'work', codex => 'codex' }
);
is( join( "\0", @codex_command[ 0 .. 2 ] ), join( "\0", 'codex', 'exec', '--sandbox' ),
    'Codex command builder keeps its executable and exec prefix' );
my $config_index;
for my $index ( 0 .. $#codex_command - 1 ) {
    $config_index = $index if $codex_command[$index] eq '--config';
}
is( $codex_command[ $config_index + 1 ], 'model_reasoning_effort="high"',
    'Codex command sets the selected reasoning effort explicitly' );
my $timing_state = {
    batch_timings => [
        { model => 'gpt-6-luna', reasoning_effort => 'low', seconds => 10, cases => 10 },
        { model => 'gpt-6-luna', reasoning_effort => 'medium', seconds => 30, cases => 10 },
        { model => 'gpt-6.1-sol', reasoning_effort => 'high', seconds => 100, cases => 10 },
    ],
};
my ( $medium_estimate, $medium_samples ) = Diag::Translation::estimated_seconds(
    $timing_state, { model => 'gpt-6-luna', reasoning_effort => 'medium' }, 10
);
is( $medium_estimate, 30, 'timing estimates use only samples at the selected reasoning effort' );
is( $medium_samples, 1, 'timing samples at other efforts and models are excluded' );

my $default_hvname = {
    name       => 'role',
    type       => 'text',
    format_str => 'PERL_HvNAMEf_DEFAULT',
    pass       => 'PERL_HvNAMEfARG_DEFAULT',
    default    => '"(unknown)"',
};
ok( helper_parameter_eligible($default_hvname),
    'prefixed HvNAME default format remains eligible for a shared helper' );
my ( $default_format, $default_value ) = parameter_formatting(
    $default_hvname, ['ma_role'], { shared_helper => 1, default_argument => 'ma_default' }
);
is( $default_value, '&ma_default',
    'prefixed HvNAME default pass selects the helper fallback argument' );
like( $default_format, qr/PERL_HvNAMEf_DEFAULT/,
    'prefixed HvNAME default format reaches the family formatter' );

# New diagnostic numbers append even when their codes sort before older ones.
sub churn_diagnostic {
    my ( $code, $number, $name ) = @_;

    return {
        code     => $code,
        number   => $number,
        kind     => 'CORE_RUNTIME',
        severity => 'FATAL_ERROR',
        message  => {
            templates => { en => "Value %{$name}" },
            args      => [ { name => $name, type => 'text', format_str => 's' } ],
        },
        emit => { api => 'CROAK' },
    };
}

# Render an isolated fixture without publishing or editing the real catalog.
sub churn_catalog {
    my (@definitions) = @_;
    @definitions =
      map { +{ %$_, message => { %{ $_->{message} } }, emit => { %{ $_->{emit} } } } } @definitions;
    my $conf = {
        severities      => $CONF->{severities},
        exception_kinds => $CONF->{exception_kinds},
        diagnostics     => {
            FATAL_ERROR => { CORE_RUNTIME => { map { $_->{code} => $_ } @definitions } },
        },
    };
    my $diagnostics = Diag::Migration::diagnostics($conf);
    my @table       = sort { $a->{code} cmp $b->{code} } @$diagnostics;
    my %index;
    @index{ map { $_->{code} } @table } = 1 .. @table;

    return ( $diagnostics, \@table, \%index );
}

sub churn_data {
    my ( $diagnostics, $table, $index ) = churn_catalog(@_);
    my $class_model = Diag::Classes::build_model(
        $diagnostics, $CONF->{diagnostic_classes},
        Perl::Regen::Warnings::tree(), Diag::Migration::read_source('warnings.h')
    );
    return render_data( $diagnostics, $table, $index, build_selector_layouts($diagnostics),
        $CONF->{languages}, $CONF->{plural_rules}, $class_model );
}

sub churn_pack_data {
    my ( $language,    @definitions ) = @_;
    my ( $diagnostics, $table )       = churn_catalog(@definitions);
    my $selector_layouts = build_selector_layouts($diagnostics);
    my $language_layouts =
      build_language_selector_layouts( $diagnostics, $language, $selector_layouts, Diag::Words::catalog() );
    my $template_analysis = build_template_analysis($diagnostics);
    my $words             = Diag::Words::compile( $diagnostics, undef, { $language => $language_layouts } );
    return Diag::Pack::_render_data(
        $diagnostics,       $table, $language, $selector_layouts, $language_layouts,
        $CONF->{languages}, $CONF->{plural_rules}, $template_analysis, $words
    );
}

sub churn_header {
    my ( $diagnostics, $table, $index ) = churn_catalog(@_);
    return render_header( $diagnostics, $table, $index, build_helpers( $diagnostics, {} ), {} );
}

sub churn_array {
    my ( $source, $name ) = @_;
    my ($body) = $source =~ /^static const \w+ \Q$name\E\[\] = \{\n(.*?)^\};/ms;
    die "Missing generated array $name" unless defined $body;
    return $body;
}

for my $wide_position ( 0 .. 2 ) {
    my @names = qw(first second third);
    splice @names, $wide_position, 1, 'wide';
    my $layout_fixture = {
        code                => "WIDE_POSITION_$wide_position",
        message_selectors   => \@names,
        selector_definitions => [
            map { { name => $_, wide => $_ eq 'wide' ? 1 : undef } } @names
        ],
    };
    my $layout = Diag::Migration::selector_packed_layout($layout_fixture);
    is( $layout->{shifts}[$wide_position], 48,
        "wide selector at position $wide_position uses the top two packed bytes" );
}

my $two_wide = {
    code => 'TWO_WIDE_FIXTURE',
    message_selectors => [qw(first second)],
    selector_definitions => [ { name => 'first', wide => 1 }, { name => 'second', wide => 1 } ],
};
eval { Diag::Migration::selector_packed_layout($two_wide) };
like( $@, qr/more than one wide selector/, 'two wide selector fields are rejected' );
my $wide_plus_seven = {
    code => 'TOO_MANY_WIDE_FIXTURE',
    message_selectors => [qw(wide one two three four five six seven)],
    selector_definitions => [
        { name => 'wide', wide => 1 },
        map { { name => $_ } } qw(one two three four five six seven),
    ],
};
eval { Diag::Migration::selector_packed_layout($wide_plus_seven) };
like( $@, qr/more than seven selectors/, 'a wide selector cannot be combined with seven narrow fields' );
my $eight_narrow = {
    code => 'EIGHT_NARROW_FIXTURE',
    message_selectors => [qw(one two three four five six seven eight)],
    selector_definitions => [ map { { name => $_ } } qw(one two three four five six seven eight) ],
};
eval { Diag::Migration::selector_packed_layout($eight_narrow) };
like( $@, qr/more than seven selectors/, 'eight narrow selector fields are rejected' );
my $seven_narrow = {
    code => 'SEVEN_NARROW_FIXTURE',
    message_selectors => [qw(one two three four five six seven)],
    selector_definitions => [ map { { name => $_ } } qw(one two three four five six seven) ],
};
my $seven_layout = Diag::Migration::selector_packed_layout($seven_narrow);
is( join( ',', @{ $seven_layout->{shifts} } ), '0,8,16,24,32,40,48',
    'narrow-only diagnostics keep the seven-byte layout' );
my @six_narrow_names = qw(one two three four five six);
my $max_wide_layout = Diag::Migration::selector_packed_layout(
    {
        code => 'MAXIMUM_WIDE_FIXTURE',
        message_selectors => [ 'wide', @six_narrow_names ],
        selector_definitions => [
            { name => 'wide', wide => 1 }, map { { name => $_ } } @six_narrow_names,
        ],
    }
);
is( join( ',', @{ $max_wide_layout->{shifts} } ), '48,0,8,16,24,32,40',
    'six narrow selectors fit beside one wide selector' );
my $wide_plural_layout = Diag::Migration::selector_packed_layout(
    {
        code => 'WIDE_PLURAL_FIXTURE',
        message_selectors => [ 'wide', 'count' ],
        selector_definitions => [
            { name => 'wide', wide => 1 }, { name => 'count', plural => 'cardinal' },
        ],
    }
);
is( join( ',', @{ $wide_plural_layout->{shifts} } ), '48,0',
    'a plural selector can remain adjacent to a wide selector' );

my $wide_plural_diag = churn_diagnostic( 'WIDE_WITH_PLURAL_FIXTURE', 9104, 'value' );
$wide_plural_diag->{message}{args} = [
    { name => 'wide_kind', type => 'text', format_str => 's' },
    { name => 'count', type => 'uv', format_str => 'UVuf' },
    { name => 'value', type => 'text', format_str => 's' },
];
$wide_plural_diag->{message}{selectors} = [
    { name => 'wide_kind', source => 'wide_kind', values => ['large'], wide => 1 },
    { name => 'count', source => 'count', plural => 'cardinal' },
];
$wide_plural_diag->{message}{templates}{en} = {
    '*' => { one => 'One %{value}', '*' => '%{count} values %{value}' },
};
my $wide_plural_data = churn_data($wide_plural_diag);
like( $wide_plural_data,
    qr/\{\s+"wide_kind",\s+\d+,\s+perl_diag_selector_domain_9104_0_id,[^\n]*1,\s+16,\s+48,/,
    'generated wide descriptor uses the top U16 field beside a plural selector' );
like( $wide_plural_data,
    qr/\{\s+"count",\s+1,\s+0,[^\n]*6,\s+8,\s+0,\s+"cardinal"/,
    'generated plural descriptor uses a local domain at shift zero' );
like( $wide_plural_data,
    qr/Perl_diag_plural_selector_en_9104_1\(pTHX_ U16 language, UV n\)/,
    'plural resolution remains generated when a wide selector is present' );

my @wide_values = map { sprintf 'v%05d', $_ } 1 .. 65535;
my $wide_diag = churn_diagnostic( 'WIDE_SELECTOR_FIXTURE', 9102, 'value' );
$wide_diag->{message}{args} = [
    { name => 'selector', type => 'text', format_str => 's' },
    { name => 'value', type => 'text', format_str => 's' },
];
$wide_diag->{message}{selectors} = [
    { name => 'selector', source => 'selector', values => [qw(alpha beta)], wide => 1 },
];
Diag::Migration::normalize_diagnostic_schema($wide_diag);
my $wide_canonical = Diag::Migration::canonical_diagnostic_schema($wide_diag);
is( $wide_canonical->{message}{selectors}[0]{wide}, 1,
    'canonical translation schema preserves the wide selector declaration' );

my $nested_wide = churn_diagnostic( 'NESTED_WIDE_SELECTOR_FIXTURE', 9105, 'value' );
$nested_wide->{message}{args} = [
    { name => 'context', type => 'text', format_str => 's', selector_values => [qw(none operation)] },
    { name => 'operation_selector', type => 'text', format_str => 's', internal => 1 },
    { name => 'value', type => 'text', format_str => 's' },
];
$nested_wide->{message}{selectors} = [
    { name => 'context', source => 'context', values => [qw(none operation)] },
    { name => 'operation', source => 'operation_selector', values => [qw(add)], wide => 1 },
];
Diag::Migration::normalize_diagnostic_schema($nested_wide);
my $nested_canonical = Diag::Migration::canonical_diagnostic_schema($nested_wide);
is( join( ',', map { $_->{name} } @{ $nested_canonical->{message}{selectors} } ),
    'context,operation', 'canonical schema retains selector order before a nested wide selector' );
my $nested_reload = churn_diagnostic( 'NESTED_WIDE_SELECTOR_FIXTURE', 9105, 'value' );
$nested_reload->{message} = $nested_canonical->{message};
Diag::Migration::normalize_diagnostic_schema($nested_reload);
is( join( ',', @{ $nested_reload->{message_selectors} } ), 'context,operation',
    'wide selector nesting round-trips through the canonical catalog schema' );

my $wide_fingerprint = Diag::Translation::source_fingerprint(
    { languages => {}, plural_rules => {} }, $wide_diag, 'fr'
);
{
    local $wide_diag->{selector_definitions}[0]{wide} = 0;
    isnt( Diag::Translation::source_fingerprint(
            { languages => {}, plural_rules => {} }, $wide_diag, 'fr'
        ), $wide_fingerprint,
        'translation provenance fingerprints the selector field width' );
}
$wide_diag = churn_diagnostic( 'WIDE_SELECTOR_FIXTURE', 9102, 'value' );
$wide_diag->{message}{args} = [
    { name => 'selector', type => 'text', format_str => 's' },
    { name => 'narrow', type => 'text', format_str => 's' },
    { name => 'value', type => 'text', format_str => 's' },
];
$wide_diag->{message}{selectors} = [
    { name => 'selector', source => 'selector', values => \@wide_values, wide => 1 },
    { name => 'narrow', source => 'narrow', values => [qw(n0 n1)] },
];
$wide_diag->{message}{templates}{en} = {
    '*' => { '*' => 'Wildcard %{selector} %{value}' },
    v00255 => { '*' => 'Value 255 %{selector} %{value}' },
    v00256 => {
        '*'  => 'Value 256 %{selector} %{value}',
        n0   => 'Value 256 n0 %{selector} %{value}',
    },
    v00257 => { '*' => 'Value 257 %{selector} %{value}' },
    v00511 => { '*' => 'Value 511 %{selector} %{value}' },
    v00512 => { '*' => 'Value 512 %{selector} %{value}' },
    v65535 => { '*' => 'Value 65535 %{selector} %{value}' },
};
my $wide_data = churn_data($wide_diag);
like( $wide_data, qr/UINT64_C\(\s*0x00ff000000000000\)/,
    'wide value ID 255 occupies the low octet of the top U16 field' );
like( $wide_data, qr/UINT64_C\(\s*0x0100000000000000\)/,
    'wide value ID 256 is packed as the exact 0x0100 top field' );
like( $wide_data, qr/UINT64_C\(\s*0x0100000000000001\)/,
    'wide values combine with a narrow selector in its mapped low byte' );
like( $wide_data, qr/UINT64_C\(\s*0x0101000000000000\)/,
    'wide value ID 257 differs from exact ID 256 in the second octet' );
like( $wide_data, qr/UINT64_C\(\s*0x01ff000000000000\)/,
    'wide value ID 511 preserves both packed octets' );
like( $wide_data, qr/UINT64_C\(\s*0x0200000000000000\)/,
    'wide value ID 512 carries into the high packed octet' );
like( $wide_data, qr/UINT64_C\(\s*0xffff000000000000\)/,
    'wide value ID 65535 uses the maximum U16 value without truncation' );
like( $wide_data, qr/\{\s+"selector",\s+0,\s+perl_diag_selector_domain_9102_0_id,[^\n]*65535,\s+16,\s+48,/,
    'generated wide descriptor records its full domain count, width, and packed shift' );
like( $wide_data, qr/\{\s+"narrow",\s+1,\s+perl_diag_selector_domain_9102_1_id,[^\n]*2,\s+8,\s+0,/,
    'generated narrow descriptor keeps its relative order and mapped shift' );
my $expected_wide_key_order =
  '0x0100000000000001,0x00ff000000000000,0x0100000000000000,0x0101000000000000,'
  . '0x01ff000000000000,0x0200000000000000,0xffff000000000000,0x0000000000000000';
my @wide_key_order = $wide_data =~
  /^\s*\{\s+perl_diag_wide_selector_fixture_number,\s+UINT64_C\(\s*(0x[0-9a-f]+|0)\),/mg;
is( join( ',', @wide_key_order ), $expected_wide_key_order,
    'case order uses logical specificity then the full packed numeric key' );

my @too_many_wide_values = ( @wide_values, 'v99999' );
my $overflow_layout = {
    code => 'WIDE_OVERFLOW_FIXTURE',
    number => 9103,
    message_selectors => ['selector'],
    selector_definitions => [
        { name => 'selector', source => 'selector', values => \@too_many_wide_values, wide => 1 },
    ],
    params => [ { name => 'selector' } ],
};
eval { build_selector_layouts( [$overflow_layout] ) };
like( $@, qr/more than 65535 values/, 'a wide selector with 65,536 values is rejected' );

my $render_format = churn_diagnostic( 'BOOTSTRAP_FORMAT', 9001, 'value' );
$render_format->{emit} =
  { api => 'RENDER', format_macro => 'PERL_DIAG_FORMAT_BOOTSTRAP_FORMAT', format_macro_chunks => 1 };
my $render_header = churn_header($render_format);
like(
    $render_header,
    qr/^#define PERL_DIAG_FORMAT_BOOTSTRAP_FORMAT "Value %" "s"$/m,
    'render-only entries expose a catalog-derived static format for constrained output'
);
like(
    $render_header,
    qr/^#define PERL_DIAG_FORMAT_BOOTSTRAP_FORMAT_TEXT_0 "Value "$/m,
    'allocation-free output derives literal pieces from the complete template'
);
like(
    $render_header,
    qr/^#define PERL_DIAG_FORMAT_BOOTSTRAP_FORMAT_TEXT_1 ""$/m,
    'literal pieces retain an empty trailing segment'
);
$render_format->{message}{templates}{en} = '%%{literal} %{value} %%';
my $escaped_render_header = churn_header($render_format);
like(
    $escaped_render_header,
    qr/^#define PERL_DIAG_FORMAT_BOOTSTRAP_FORMAT_TEXT_0 "%\{literal\} "$/m,
    'literal chunks preserve escaped placeholder-shaped text'
);
like(
    $escaped_render_header,
    qr/^#define PERL_DIAG_FORMAT_BOOTSTRAP_FORMAT_TEXT_1 " %"$/m,
    'allocation-free literal chunks contain single percent characters'
);
like(
    $render_header,
    qr/^#define PERL_FORMAT_BOOTSTRAP_FORMAT\(language, values\)/m,
    'the static format retains the ordinary render-only interface'
);

my $aligned_rows  = render_struct_rows( [ [ 1, 'x' ], [ 1234, 'abcd' ] ] );
my @aligned_lines = split /\n/, $aligned_rows;
is( index( $aligned_lines[0], 'x' ), index( $aligned_lines[1], 'abcd' ), 'text columns start at the same position' );
is(
    index( $aligned_lines[0], '1,' ) + 2,
    index( $aligned_lines[1], '1234,' ) + 5,
    'numeric columns align to the right edge of the longest cell'
);
like( $aligned_lines[0], qr/1, {2}x/, 'numeric commas retain two trailing spaces' );
is( render_struct_rows( [] ), '', 'an empty initializer list renders no rows' );
my $compact_rows = render_struct_rows( [ [ 1, 'x' ] ] );
is( index( $compact_rows, 'x' ), 10, 'the formatter uses only the cell width and separator spacing' );
my $enum_rows = render_enum_rows(
    [ [ 'FIRST', 0 ], [ 'SECOND_WITH_A_LONG_IMPLICIT_NAME', '' ], [ 'THIRD', 'FIRST + 2' ], [ 'FOURTH', 12345 ] ] );
like( $enum_rows, qr/^    FIRST\s+=\s+0,/m, 'enum assignments use aligned columns' );
like(
    $enum_rows,
    qr/^    SECOND_WITH_A_LONG_IMPLICIT_NAME,$/m,
    'implicit enum values remain unpadded despite their longer names'
);
like( $enum_rows, qr/^    THIRD\s+=\s+FIRST \+ 2,/m, 'enum expressions use the same formatter' );
like( $enum_rows, qr/^    FOURTH\s+=\s+12345,/m,     'enum numeric values use the same formatter' );
my @enum_lines = split /\n/, $enum_rows;
is(
    index( $enum_lines[0], '=' ),
    index( $enum_lines[2], '=' ),
    'only explicit enum assignments set the left-column width'
);
my $column_error;
eval { numeric_columns( [ ['value'], [ 'another', 'cell' ] ] ); 1 } or $column_error = $@;
like( $column_error, qr/inconsistent generated column count/, 'the formatter rejects inconsistent row column counts' );
my $constant_rows = render_constant_definitions(
    [
        [ 'static const char short_name[]',  '"short"' ],
        [ 'static const char longer_name[]', '"a much longer literal"' ],
    ]
);
my @constant_lines = split /\n/, $constant_rows;
is(
    index( $constant_lines[0], '=' ),
    index( $constant_lines[1], '=' ),
    'constant definitions align their assignment operators'
);
like( $constant_lines[0], qr/"short";$/, 'constant literals are not padded before the semicolon' );
my @wrap_values    = map { "diag_selector_value$_" } 1 .. 12;
my $wrapped_values = wrap_initializer_values( \@wrap_values );
my @wrapped_names  = $wrapped_values =~ /diag_selector_value[0-9]+/g;
is( join( ' ', @wrapped_names ), join( ' ', @wrap_values ), 'wrapped initializers preserve value order' );
ok( !grep( { length($_) > 100 } split /\n/, $wrapped_values ), 'initializer lines fit within 100 columns' );
is( wrap_initializer_values( [] ), '', 'an empty value list emits no initializer text' );

my $first  = churn_diagnostic( 'Z_OLD', 10, 'first' );
my $second = churn_diagnostic( 'M_OLD', 20, 'second' );
my $added  = churn_diagnostic( 'A_NEW', 30, 'third' );
my $before = churn_data( $first, $second );
my $after  = churn_data( $first, $second, $added );

my $before_pairs = churn_array( $before, 'perl_diag_param_metadata' );
my $after_pairs  = churn_array( $after,  'perl_diag_param_metadata' );
like( $before_pairs, qr/"first".*"second"/s, 'parameter definitions follow diagnostic numbers' );
is( substr( $after_pairs, 0, length $before_pairs ),
    $before_pairs, 'a new alphabetically earlier code preserves existing parameter definitions' );

my @before_ids = churn_array( $before, 'perl_diag_param_ids' ) =~ /\b(\d+)\s*,/g;
my @after_ids  = churn_array( $after,  'perl_diag_param_ids' ) =~ /\b(\d+)\s*,/g;
is(
    join( ',', @after_ids[ 0 .. $#before_ids ] ),
    join( ',', @before_ids ),
    'a new diagnostic preserves existing parameter-ID lists'
);
is( scalar @after_ids, scalar(@before_ids) + 1, 'the new parameter ID is appended' );

my @packed_input = (
    { diagnostic => { code => 'LONG', number => 10 },      ids => [ 1, 2, 3, 4 ] },
    { diagnostic => { code => 'TIE_LATE', number => 30 },  ids => [ 7, 8, 9, 10 ] },
    { diagnostic => { code => 'TIE_EARLY', number => 20 }, ids => [ 5, 6, 7, 8 ] },
    { diagnostic => { code => 'DUP', number => 40 },       ids => [ 1, 2, 3, 4 ] },
    { diagnostic => { code => 'MIDDLE', number => 50 },    ids => [ 2, 3 ] },
    { diagnostic => { code => 'PREFIX', number => 60 },    ids => [ 1, 2 ] },
    { diagnostic => { code => 'APPEND', number => 70 },    ids => [ 11, 12 ] },
    { diagnostic => { code => 'EMPTY', number => 80 },     ids => [] },
);
my ( $packed_ids, $packed_offsets ) = pack_metadata_id_sequences( \@packed_input );
is(
    join( ',', @$packed_ids ),
    '0,1,2,3,4,5,6,7,8,7,8,9,10,11,12',
    'longest parameter lists pack first with number-ordered ties'
);
is( $packed_offsets->{LONG}{offset},      1,  'a new list starts after reserved zero' );
is( $packed_offsets->{DUP}{offset},       1,  'duplicate lists reuse the existing span' );
is( $packed_offsets->{MIDDLE}{offset},    2,  'contained lists reuse an interior span' );
is( $packed_offsets->{PREFIX}{offset},    1,  'contained prefixes reuse their span' );
is( $packed_offsets->{TIE_EARLY}{offset}, 5,  'equal length lists order by diagnostic number' );
is( $packed_offsets->{TIE_LATE}{offset},  9,  'later equal length lists follow earlier ones' );
is( $packed_offsets->{APPEND}{offset},    13, 'unmatched lists append to the shared stream' );
is( $packed_offsets->{EMPTY}{offset},     0,  'empty lists use reserved offset zero' );
is( $packed_offsets->{EMPTY}{count},      0,  'empty lists have zero parameters' );
my ( $packed_ids_again, $packed_offsets_again ) = pack_metadata_id_sequences( \@packed_input );
is( join( ',', @$packed_ids_again ), join( ',', @$packed_ids ), 'packing is deterministic' );
is(
    join( ';', map { join ',', $_, @{ $packed_offsets->{$_} }{qw(offset count)} } sort keys %$packed_offsets ),
    join( ';',
        map { join ',', $_, @{ $packed_offsets_again->{$_} }{qw(offset count)} } sort keys %$packed_offsets_again ),
    'packed offsets are deterministic'
);

my @input_diags = (
    { code => 'INPUT_LONG',   number => 9106 },
    { code => 'INPUT_REUSE',  number => 9107 },
    { code => 'INPUT_SUFFIX', number => 9108 },
    { code => 'INPUT_EMPTY',  number => 9109 },
);
my $input_analysis = {
    INPUT_LONG => {
        parameters => {
            captured_params => [
                {
                    name   => 'joined',
                    type   => 'text',
                    inputs => [ { name => 'length', type => 'iv' }, { name => 'text', type => 'text' } ],
                },
                { name => 'suffix', type => 'text', inputs => [ { name => 'text', type => 'text' } ] },
            ],
        },
    },
    INPUT_REUSE => {
        parameters => {
            captured_params => [
                {
                    name   => 'joined',
                    type   => 'text',
                    inputs => [ { name => 'length', type => 'iv' }, { name => 'text', type => 'text' } ],
                },
                { name => 'suffix', type => 'text', inputs => [ { name => 'text', type => 'text' } ] },
            ],
        },
    },
    INPUT_SUFFIX => {
        parameters => {
            captured_params =>
              [ { name => 'suffix', type => 'text', inputs => [ { name => 'text', type => 'text' } ] }, ],
        },
    },
    INPUT_EMPTY => { parameters => { captured_params => [] } },
};
my ( $input_metadata, $input_ranges, $input_offsets ) = collect_input_metadata( \@input_diags, $input_analysis );
is( scalar @$input_metadata,                3, 'repeated compound raw-input rows share direct metadata spans' );
is( join( ',', @{ $input_metadata->[1] } ), 'length,iv', 'compound input order starts with its length' );
is( join( ',', @{ $input_metadata->[2] } ), 'text,text', 'compound input order retains its text value' );
is( scalar @$input_ranges,                  3,     'repeated parameter-range sequences share direct metadata spans' );
is( join( ',', @{ $input_ranges->[1] } ),   '1,2', 'compound input range points to both raw inputs' );
is( join( ',', @{ $input_ranges->[2] } ),   '2,1', 'contained raw-input sequence points to its shared row' );
is(
    $input_offsets->{INPUT_LONG}{offset},
    $input_offsets->{INPUT_REUSE}{offset},
    'diagnostics with the same parameter layout share their input-range span'
);
is( $input_offsets->{INPUT_SUFFIX}{offset}, 2, 'a contained diagnostic range reuses the suffix of a packed span' );
is( $input_offsets->{INPUT_EMPTY}{offset},  0, 'a diagnostic with no parameters uses the reserved zero offset' );
is( $input_offsets->{INPUT_EMPTY}{count},   0, 'a diagnostic with no parameters adds no range rows' );

like( churn_array( $after, 'perl_diag_param_ids' ),
    qr/^ {7}0,/m, 'the reserved parameter ID uses a four-character field' );
like(
    churn_array( $after, 'perl_diag_param_ids' ),
    qr/^ {7}1, {4}2, {4}3,/m,
    'parameter IDs are left padded to four characters'
);
my $literal = churn_diagnostic( 'LITERAL', 40, 'unused' );
$literal->{message} = { templates => { en => 'Literal' }, args => [] };
my $literal_ids = churn_array( churn_data($literal), 'perl_diag_param_ids' );
like(
    $literal_ids,
    qr/\A    \/\* index 0 means no parameter metadata \*\/\n {7}0,\n\z/,
    'a parameter-free catalog emits only the reserved ID'
);

for my $code (qw(Z_OLD M_OLD)) {
    my ($old_row) = $before =~ /^(\s*\{ "\Q$code\E", .*),$/m;
    my ($new_row) = $after  =~ /^(\s*\{ "\Q$code\E", .*),$/m;
    ok( defined($old_row) && defined($new_row), "$code has metadata in both fixtures" );
    is( $new_row, $old_row, "$code retains its parameter offset and count" );
}

my $metadata = churn_array( $after, 'perl_diag_metadata' );
like( $metadata, qr/"A_NEW".*"M_OLD".*"Z_OLD"/s, 'metadata keeps its code-sorted lookup order' );

my $before_header = churn_header( $first, $second );
my $after_header  = churn_header( $first, $second, $added );
like( $before_header, qr/enum perl_diag_index \{\n    perl_diag_index_none\s+=\s+0,/, 'the index enum reserves zero' );
unlike( $after_header, qr/^#define perl_diag_\w+_idx/m, 'diagnostic indexes are enum constants' );
like(
    $after_header,
    qr/perl_diag_a_new_idx,\n    perl_diag_m_old_idx,\n    perl_diag_z_old_idx,/,
    'implicit enum indexes retain metadata code order'
);

for my $code (qw(M_OLD Z_OLD)) {
    my $lower_code = lc $code;
    my ($old_line) = $before_header =~ /^(\s*perl_diag_\Q$lower_code\E_idx,)$/m;
    my ($new_line) = $after_header  =~ /^(\s*perl_diag_\Q$lower_code\E_idx,)$/m;
    is( $new_line, $old_line, "$code index declaration has no renumbering churn" );
}

my $before_cases = churn_array( $before, 'perl_diag_template_cases_en' );
my $after_cases  = churn_array( $after,  'perl_diag_template_cases_en' );
like(
    $after,
    qr/enum \{\n\s+perl_diag_template_no_template\s+=\s+0,\n\};/,
    'the reserved template offset has a shared name'
);
like(
    $after_cases,
    qr/\A    \/\* offset 0 means no template \*\/\n    \{\s+0,\s+UINT64_C\(\s*0\),\s+NULL,\s+0,\s+0\s+\},/,
    'template offset zero contains null data'
);
like(
    $after,
qr/perl_diag_template_start_en_10\s+=\s+1,\n    perl_diag_template_start_en_20,\n    perl_diag_template_start_en_30,\n    perl_diag_template_end_en,\n/,
    'single-row templates use implicit enum increments after reserved zero'
);
$before_cases =~ s/^.*terminates the last diagnostic's rows.*\n//m;
is( substr( $after_cases, 0, length $before_cases ),
    $before_cases, 'a new alphabetically earlier code preserves existing translation rows' );
like(
    $after_cases,
    qr/\{\s+perl_diag_z_old_number,.*\{\s+perl_diag_m_old_number,.*\{\s+perl_diag_a_new_number,/s,
    'translation rows use stable diagnostic numbers in number order'
);

my $large_number = churn_data( churn_diagnostic( 'WIDE_NUMBER', 70000, 'wide' ) );
like(
    $large_number,
    qr/\{\s+perl_diag_wide_number_number,\s+UINT64_C/,
    'translation row identity is not limited to a U16 metadata index'
);
like(
    churn_header( churn_diagnostic( 'WIDE_NUMBER', 70000, 'wide' ) ),
    qr/perl_diag_wide_number_number\s+=\s+70000,/,
    'symbolic diagnostic numbers preserve the stable catalog number'
);

for my $code (qw(M_OLD Z_OLD)) {
    my $lower_code = lc $code;
    my ($old_line) = $before_header =~ /^(\s*perl_diag_\Q$lower_code\E_number\s+=\s+\d+,)$/m;
    my ($new_line) = $after_header  =~ /^(\s*perl_diag_\Q$lower_code\E_number\s+=\s+\d+,)$/m;
    ok( defined($old_line), "$code has a symbolic catalog number" );
    is( $new_line, $old_line, "$code catalog number is stable after an insertion" );
}

my $selected = churn_diagnostic( 'Z_SELECTED', 10, 'value' );
unshift @{ $selected->{message}{args} },
  {
    name            => 'mode',
    type            => 'text',
    format_str      => 's',
    selector_values => [qw(one two)],
  };
$selected->{message}{templates}{en} = { '*' => 'Mode %{value}' };
my $selected_before = churn_data( $selected, $second, $added );
my $selected_more   = {
    %$selected,
    message => {
        %{ $selected->{message} }, templates => { en => { one => 'One %{value}', '*' => 'Mode %{value}' } },
    },
};
my $selected_after = churn_data( $selected_more, $second, $added );
is(
    churn_array( $selected_after,  'perl_diag_templates_en' ),
    churn_array( $selected_before, 'perl_diag_templates_en' ),
    'adding an earlier translation case preserves all symbolic lookup rows'
);
like(
    $selected_after,
    qr/perl_diag_template_start_en_20\s+=\s+perl_diag_template_start_en_10 \+ 2,/,
    'multiple template rows require an explicit offset increment'
);
my ($old_offset) = $selected_before =~ /^(\s*perl_diag_template_start_en_30(?:\s+= [^\n]+)?,)$/m;
my ($new_offset) = $selected_after  =~ /^(\s*perl_diag_template_start_en_30(?:\s+= [^\n]+)?,)$/m;
is( $new_offset, $old_offset, 'a changed case count does not renumber offsets beyond its immediate successor' );

my $another_selector = churn_diagnostic( 'A_SELECTED', 40, 'other' );
unshift @{ $another_selector->{message}{args} },
  {
    name            => 'mode',
    type            => 'text',
    format_str      => 's',
    selector_values => [qw(alpha beta)],
  };
$another_selector->{message}{templates}{en} = { '*' => 'Other %{other}' };
$another_selector->{message}{templates}{de} = { '*' => 'Other %{other}' };
my $new_domain = churn_data( $selected, $second, $added, $another_selector );
like(
    $new_domain,
    qr/perl_diag_selector_values_[a-z]+_10_0\[\]\s+= \{\s+"one",\s+"two",\s+\};/,
    'selector value arrays contain strings in their configured order'
);
unlike( $new_domain, qr/diag_selector_one/, 'selector strings need no symbolic aliases' );

my $conditional_selector = {
    message_selectors => [ 'mode', 'kind' ],
    params            => [
        { name => 'mode', selector_values => [ 'alpha', 'zeta' ] },
        { name => 'kind', selector_values => { zeta => ['zulu'], alpha => ['beta'] } },
    ],
};
is( join( ' ', @{ Diag::Migration::selector_values_for( $conditional_selector, 1, ['*'] ) } ),
    'beta zulu', 'wildcard selector domains traverse branches in sorted key order' );

my $shared = churn_diagnostic( 'SHARED_TEXT', 50, 'value' );
$shared->{message}{templates} = { en => 'Shared %{value}', fr => 'Shared %{value}' };
my $duplicate = churn_diagnostic( 'DUPLICATE_TEXT', 60, 'other' );
$duplicate->{message}{templates}{en} = 'Shared %{other}';
my $shared_data = churn_data( $shared, $duplicate );
my @texts       = $shared_data =~ /^static const char (perl_diag_template_text_[0-9a-f]+)\[\]\s+= "Shared %1\$s";$/gm;
is( scalar @texts, 1, 'identical English positional text is shared across diagnostics' );
my @references = $shared_data =~
  /\{\s+perl_diag_(?:shared_text|duplicate_text)_number,\s+UINT64_C\(\s*0\),\s+(perl_diag_template_text_[0-9a-f]+),\s+1,\s+\d+\s+\}/g;
is( scalar @references,       2,                              'English template cases reference the shared text' );
is( join( ',', @references ), join( ',', ( $texts[0] ) x 2 ), 'English cases use the same constant' );
my $shared_fr_data = churn_pack_data( 'fr', $shared, $duplicate );
my @french_references = $shared_fr_data =~
  /\{\s+perl_diag_(?:shared_text|duplicate_text)_number,\s+UINT64_C\(\s*0\),\s+(perl_diag_template_text_[0-9a-f]+),\s+1,\s+\d+\s+\}/g;
is( scalar @french_references, 1, 'the French pack emits its own translated case' );
is( $french_references[0], $texts[0], 'identical English and French pack text shares its digest name' );
is( $texts[0],                'perl_diag_template_text_' . substr( sha256_hex('Shared %1$s'), 0, 8 ), 'names use SHA-256 prefixes' );

my $collisions = template_text_names(
    {
        first  => '12345678aa' . ( '0' x 54 ),
        second => '12345678ab' . ( '0' x 54 ),
        third  => '12345678b' . ( '0' x 55 ),
    }
);
is( $collisions->{first},  'perl_diag_template_text_12345678aa', 'hash prefixes extend repeatedly until distinct' );
is( $collisions->{second}, 'perl_diag_template_text_12345678ab', 'both colliding prefixes extend' );
is( $collisions->{third},  'perl_diag_template_text_12345678b',  'a resolved prefix needs no further digits' );
my $collision_error;
eval { template_text_names( { first => '0' x 64, second => '0' x 64 } ); 1 }
  or $collision_error = $@;
like( $collision_error, qr/same SHA-256 digest/, 'a full SHA-256 collision stops generation' );

my @sort_templates =
  ( 'zebra %{value}', '(Apple %{value})', 'a-B %{value}', '%{value} Banana', 'apple %{value}', 'Apple %{value}' );
my @sort_diagnostics;

for my $index ( 0 .. $#sort_templates ) {
    my $diag = churn_diagnostic( "SORT_$index", 70 + $index, 'value' );
    $diag->{message}{templates}{en} = $sort_templates[$index];
    push @sort_diagnostics, $diag;
}
my $sorted_data  = churn_data(@sort_diagnostics);
my @sorted_texts = $sorted_data =~ /^static const char perl_diag_template_text_[0-9a-f]+\[\]\s+= "([^"\n]*)";$/gm;
is(
    join( '\n', @sorted_texts ),
    join( '\n', '%1$s Banana', '(Apple %1$s)', 'a-B %1$s', 'Apple %1$s', 'apple %1$s', 'zebra %1$s' ),
    'templates use case-insensitive text order with original text breaking ties'
);

my $missing_plural_rule = churn_diagnostic( 'MISSING_PLURAL_RULE', 9002, 'value' );
$missing_plural_rule->{message}{templates}{zz} = 'Unknown language %{value}';
eval { churn_pack_data( 'zz', $missing_plural_rule ) };
like(
    $@,
    qr/language zz has no CARDINAL plural rule/,
    'new catalog languages require explicit configured plural rules'
);
my $plural_dispatch = churn_data($render_format);
like(
    $plural_dispatch,
    qr/\(language\) == perl_diag_lang_en \? PERL_DIAG_PLURAL_CARDINAL_en\(n\) :/,
    'cardinal dispatch is generated from the catalog language registry'
);
like(
    $plural_dispatch,
    qr/\(language\) == perl_diag_lang_en \? PERL_DIAG_PLURAL_ORDINAL_en\(n\) :/,
    'ordinal dispatch uses the same language registry'
);

my $automatic_plural = churn_diagnostic( 'AUTOMATIC_PLURAL', 9004, 'value' );
push @{ $automatic_plural->{message}{args} },
  { name => 'n',        type => 'uv', format_str => 'UVuf' },
  { name => 'position', type => 'uv', format_str => 'UVuf' };
$automatic_plural->{message}{selectors} = [
    { name => 'quantity', source => 'n',        plural => 'cardinal' },
    { name => 'rank',     source => 'position', plural => 'ordinal' },
];
$automatic_plural->{message}{templates} = {
    en => {
        '0' => { any => 'No %{value}' },
        one => { one => 'First %{value}', '*' => 'One %{value}' },
        any => 'Several %{value}',
    },
    fr => { '21' => { '3' => 'Exact %{value}' }, other => 'Autres %{value}', '*' => 'Valeurs %{value}' },
};
my ($automatic_diag) = @{ ( churn_catalog($automatic_plural) )[0] };
is( scalar Diag::Migration::format_error($automatic_diag),
    undef, 'cardinal and ordinal selectors can share a diagnostic with language-specific cases' );
is(
    join( ',', @{ Diag::Migration::selector_values_for( $automatic_diag, 0, [] ) } ),
    'zero,one,two,few,many,other,0,21',
    'plural domain combines all standard forms with exact counts from every language'
);
is(
    join( ',', @{ Diag::Migration::selector_values_for( $automatic_diag, 1, [] ) } ),
    'zero,one,two,few,many,other,3',
    'each plural selector collects its own exact numbers across nested branches'
);
my $automatic_layout = Diag::Migration::template_parameter_layout($automatic_diag);
my ($automatic_display_params) = Diag::Migration::template_case_parameter_layout(
    $automatic_diag, 'Several %{value}' );
is( join( ',', map { $_->{name} } @$automatic_display_params ),
    'value', 'plural source counts need not be display parameters' );
is( join( ',', map { $_->{name} } @{ $automatic_layout->{canonical_params} } ),
    'value,n,position', 'plural sources stay in declared capture order' );
is( $automatic_layout->{stored_count}, 3, 'undisplayed plural sources remain available for later rendering' );
my $automatic_canonical = Diag::Migration::canonical_diagnostic_schema($automatic_diag);
is( $automatic_canonical->{message}{selectors}[1]{plural},
    'ordinal', 'normalization preserves the plural kind and source' );
ok( exists $automatic_canonical->{message}{templates}{en}{'*'}, 'any normalizes to the wildcard spelling' );
my $automatic_data = churn_pack_data( 'fr', $automatic_plural );
like(
    $automatic_data,
    qr/\(n\) == UINT64_C\(21\) \? \(IV\)7 :/,
    'per-language plural callbacks map exact counts to local selector IDs'
);
like(
    $automatic_data,
    qr/PERL_STATIC_INLINE IV\nPerl_diag_plural_selector_fr_9004_0[\s\S]*?return PERL_DIAG_PLURAL_SELECTOR_fr_9004_0\(n\);/,
    'plural callback resolves exact counts in its language-local domain'
);
like(
    $automatic_data,
    qr/PERL_DIAG_PLURAL_ORDINAL_fr\(n\)/,
    'ordinal selector macros fall back to the language ordinal rule'
);
unlike( $automatic_data, qr/^#define (?:PLURAL_|DIAG_PLURAL_)/m, 'plural macro names use the PERL namespace' );
like(
    $automatic_data,
    qr/"quantity",\s+1,.*Perl_diag_plural_selector_fr_9004_0/,
    'cardinal metadata refers to the retained count slot'
);
like(
    $automatic_data,
    qr/"rank",\s+2,.*Perl_diag_plural_selector_fr_9004_1/,
    'ordinal metadata refers to its independent count slot'
);
{
    is(
        Diag::Migration::apply_translation_sets(
            [$automatic_diag],
            {
                target_language => 'fr',
                template_sets   => [
                    {
                        code         => 'AUTOMATIC_PLURAL',
                        number       => 9004,
                        source_cases => Diag::Migration::template_cases( $automatic_diag, 'en' ),
                        cases        => [
                            { selectors => [ '42',  'any' ], template => 'Exact %{value}' },
                            { selectors => [ 'any', 'any' ], template => 'Autres %{value}' },
                        ],
                    }
                ],
            }
        ),
        1,
        'translation import accepts a new exact count and the any fallback'
    );
    is(
        join( ',', @{ Diag::Migration::selector_values_for( $automatic_diag, 0, [] ) } ),
        'zero,one,two,few,many,other,0,42',
        'the shared domain reflects imported exact cases and removes obsolete ones'
    );
    ok( Diag::Migration::template_cases( $automatic_diag, 'fr' ),
        'selector ID caching does not retain a stale plural domain after import' );
}
eval { Diag::Migration::normalize_template_wildcards( { any => 'A', '*' => 'B' } ) };
like( $@, qr/both any and \* fallbacks/, 'duplicate fallback spellings are rejected' );
{
    local $automatic_diag->{selector_definitions}[0]{plural} = 'fractional';
    like(
        scalar Diag::Migration::format_error($automatic_diag),
        qr/invalid plural kind/,
        'unknown plural kinds are rejected'
    );
}
{
    local $automatic_diag->{params}[1]{type}       = 'iv';
    local $automatic_diag->{params}[1]{format_str} = 'IVdf';
    like(
        scalar Diag::Migration::format_error($automatic_diag),
        qr/simple unsigned integer/,
        'signed plural sources are rejected rather than silently converted'
    );
}

# Numeric labels use the existing selector matcher. They are plain strings,
# distinct from grammatical categories and the wildcard fallback.
my $plural_cases = churn_diagnostic( 'PLURAL_CASES', 9003, 'value' );
unshift @{ $plural_cases->{message}{args} },
  {
    name            => 'form',
    type            => 'text',
    format_str      => 's',
    selector_values => [qw(0 21 zero one two few many other)],
  };
$plural_cases->{message}{templates} = {
    en => { '0'  => 'No values',      one => 'One %{value}',      '*' => 'Values %{value}' },
    fr => { '21' => 'Exact %{value}', one => 'Singular %{value}', '*' => 'Plural %{value}' },
};
my ($plural_diag) = @{ ( churn_catalog($plural_cases) )[0] };
my $english_cases = Diag::Migration::template_cases( $plural_diag, 'en' );
my $french_cases  = Diag::Migration::template_cases( $plural_diag, 'fr' );
is( Diag::Migration::_matching_template_case( $plural_diag, $english_cases, ['0'] )->{template},
    'No values', 'bare numeric zero matches an exact selector case' );
is(
    Diag::Migration::_matching_template_case( $plural_diag, $french_cases, ['21'] )->{template},
    'Exact %{value}',
    'bare numeric 21 matches an exact selector case'
);
is(
    Diag::Migration::_matching_template_case( $plural_diag, $english_cases, ['other'] )->{template},
    'Values %{value}',
    'other falls through to a wildcard where no category case exists'
);
is(
    Diag::Migration::_matching_template_case( $plural_diag, $french_cases, ['one'] )->{template},
    'Singular %{value}',
    'languages use different cases from the shared selector domain'
);
like(
    churn_data($plural_cases),
    qr/"0", "21", "few", "many", "one", "other", "two", "zero"/,
    'ordinary selector labels remain strings independent of local plural domains'
);

{
    my $rules         = { cardinal_rule_1 => '"one"', ordinal_rule_1 => '"other"' };
    my $configuration = { en              => { cardinal => 'cardinal_rule_1', ordinal => 'ordinal_rule_1' } };
    is( language_plural_rule( $configuration, $rules, 'en', 'CARDINAL' ),
        'cardinal_rule_1', 'language resolves its shared rule reference' );
    $configuration->{en}{cardinal} = 'cardinal_rule_99';
    eval { language_plural_rule( $configuration, $rules, 'en', 'CARDINAL' ) };
    like( $@, qr/references unknown CARDINAL plural rule/, 'unknown rule references are rejected' );
    $configuration->{en}{cardinal} = 'ordinal_rule_1';
    eval { language_plural_rule( $configuration, $rules, 'en', 'CARDINAL' ) };
    like( $@, qr/wrong plural rule kind/, 'cardinal and ordinal references cannot be interchanged' );
    eval { validate_plural_expression( 'cardinal_rule_1', '"invalid"' ) };
    like( $@, qr/invalid plural expression/, 'unknown plural categories are rejected' );
    eval { validate_plural_rule( 'cardinal_rule_1', { forms => ['one'], expression => '"other"' } ) };
    like( $@, qr/invalid plural form declaration/, 'rule forms must describe their expression' );
    eval { validate_plural_rule( 'cardinal_rule_1', { forms => ['*'], expression => '"other"' } ) };
    like( $@, qr/invalid plural form declaration/, 'a wildcard is not a grammatical form' );
    eval { validate_plural_rule( 'cardinal_rule_1', { forms => ['0'], expression => '"other"' } ) };
    like( $@, qr/invalid plural form declaration/, 'an exact numeric case is not a grammatical form' );
}

{
    my $audit_diag = {
        code => 'TRANSLATION_AUDIT_FIXTURE', number => 9100,
        params => [
            { name => 'kind', type => 'text', format_str => 's', selector_values => [qw(alpha beta)] },
            { name => 'value', type => 'text', format_str => 's' },
        ],
        message_selectors => ['kind'],
        selector_definitions => [
            { name => 'kind', source => 'kind', values => [qw(alpha beta)] },
        ],
        message_template => {
            en => { alpha => 'English alpha %{value}', beta => 'English beta %{value}' },
            fr => { '*' => 'French %{value}' },
        },
    };
    my $audit_conf = { languages => {}, plural_rules => {} };
    my $empty_provenance = { version => 1, entries => {} };
    my $audit = Diag::Translation::audit_diagnostic(
        $audit_conf, $audit_diag, 'fr', $empty_provenance
    );
    is( $audit->{coverage}{domain_cases}, 2,
        'translation audit measures the diagnostic selector domain' );
    is( $audit->{coverage}{fallback_cases}, 0,
        'one target wildcard provides effective coverage for all source cases' );
    is( $audit->{provenance}, 'untracked',
        'historical translations without provenance are reported as untracked' );
    $audit_diag->{message_template}{fr} = { alpha => 'Français %{value}' };
    $audit = Diag::Translation::audit_diagnostic(
        $audit_conf, $audit_diag, 'fr', $empty_provenance
    );
    is( $audit->{coverage}{fallback_cases}, 1,
        'translation audit identifies only selector cases that use English fallback' );
    is( $audit->{fallback_cases}[0]{effective_language}, 'en',
        'translation audit names the fallback language for a missing effective case' );
    my $repair_contexts = Diag::Translation::select_contexts(
        $audit_conf, [ $audit_diag ],
        { mode => 'repair', language => 'fr', provenance_file => tempfile() },
    );
    is( scalar @$repair_contexts, 1,
        'repair mode selects diagnostics with actual target-language fallback' );
    my $has_repair_reason = grep { $_ eq 'missing_effective_coverage' }
      @{ $repair_contexts->[0]{repair_reasons} };
    ok( $has_repair_reason, 'repair batch context names its coverage gap' );
    my $merged_repair_cases = Diag::Translation::preserve_repair_cases(
        {
            repair_reasons => ['missing_effective_coverage'],
            source_cases => [
                { selectors => ['alpha'], template => 'English alpha %{value}' },
                { selectors => ['beta'], template => 'English beta %{value}' },
            ],
            existing_cases => [
                { selectors => ['alpha'], template => 'Bonne traduction %{value}' },
                { selectors => ['beta'], template => 'English beta %{value}' },
            ],
        },
        [ { selectors => ['*'], template => 'Texte de secours %{value}' } ],
    );
    is( scalar @$merged_repair_cases, 2,
        'targeted repair keeps good cases and leaves an English-looking phrase for review' );
    is( $merged_repair_cases->[1]{template}, 'Bonne traduction %{value}',
        'targeted repair preserves the existing good translation leaf' );

    $audit_diag->{message_template}{fr} = { '*' => 'French %{value}' };
    my $fingerprint = Diag::Translation::source_fingerprint(
        $audit_conf, $audit_diag, 'fr'
    );
    $audit_diag->{message_template}{fr}{'*'} = 'Texte français %{value}';
    is( Diag::Translation::source_fingerprint( $audit_conf, $audit_diag, 'fr' ),
        $fingerprint, 'target wording is excluded from the source dependency fingerprint' );
    $audit_diag->{message_template}{en}{alpha} = 'Changed English %{value}';
    isnt( Diag::Translation::source_fingerprint( $audit_conf, $audit_diag, 'fr' ),
        $fingerprint, 'English source changes make dependent provenance stale' );

    my $plural_diag = {
        code => 'TRANSLATION_PLURAL_AUDIT_FIXTURE', number => 9101,
        params => [ { name => 'count', type => 'uv', format_str => 'UVuf' } ],
        message_selectors => ['count'],
        selector_definitions => [
            { name => 'count', source => 'count', plural => 'cardinal' },
        ],
        message_template => {
            en => { one => 'One item', '*' => '%{count} items' },
            fr => { one => 'Un élément', '*' => '%{count} éléments' },
        },
    };
    my $plural_conf = {
        languages => {
            en => { cardinal => 'cardinal_rule_1' },
            fr => { cardinal => 'cardinal_rule_2' },
        },
        plural_rules => {
            cardinal_rule_1 => { forms => [qw(one other)], expression => '(n) == 1 ? "one" : "other"' },
            cardinal_rule_2 => { forms => [qw(one other)], expression => '(n) <= 1 ? "one" : "other"' },
        },
    };
    my $plural_fallback_diag = {
        %$plural_diag,
        code => 'TRANSLATION_PLURAL_FALLBACK_FIXTURE', number => 9103,
        message_template => {
            en => { one => 'English singular', '*' => 'English common' },
            fr => { other => 'Texte pluriel' },
        },
    };
    my $plural_fallback_audit = Diag::Translation::audit_diagnostic(
        $plural_conf, $plural_fallback_diag, 'fr', $empty_provenance
    );
    my ($one_fallback) = grep {
        $_->{selectors}{count} eq 'one'
    } @{ $plural_fallback_audit->{fallback_cases} };
    is( scalar @{ $one_fallback->{fallback_candidates} }, 2,
        'plural fallback audit maps target categories through the English rule' );
    is( join( '|', sort map { $_->{template} } @{ $one_fallback->{fallback_candidates} } ),
        'English common|English singular',
        'plural fallback audit reports every English case reachable from target counts' );
    my $plural_fingerprint = Diag::Translation::source_fingerprint(
        $plural_conf, $plural_diag, 'fr'
    );
    $plural_diag->{message_template}{fr}{'0'} = 'Aucun élément';
    isnt( Diag::Translation::source_fingerprint( $plural_conf, $plural_diag, 'fr' ),
        $plural_fingerprint, 'target exact-number overrides are fingerprinted' );
    $plural_fingerprint = Diag::Translation::source_fingerprint(
        $plural_conf, $plural_diag, 'fr'
    );
    $plural_diag->{message_template}{de} = { '21' => 'Einundzwanzig Elemente' };
    is( Diag::Translation::source_fingerprint( $plural_conf, $plural_diag, 'fr' ),
        $plural_fingerprint,
        'unrelated-language exact overrides do not stale target provenance' );
    $plural_conf->{plural_rules}{cardinal_rule_2}{expression} = 'changed rule';
    isnt( Diag::Translation::source_fingerprint( $plural_conf, $plural_diag, 'fr' ),
        $plural_fingerprint, 'language plural-rule changes make provenance stale' );
    my $plural_import_document = {
        target_language => 'fr', workflow => 'repair', reviewed => 0,
        template_sets => [ {
            code => $plural_diag->{code}, number => $plural_diag->{number},
            source_cases => Diag::Migration::template_cases( $plural_diag, 'en' ),
            cases => Diag::Migration::template_cases( $plural_diag, 'fr' ),
        } ],
    };
    $plural_import_document->{source_fingerprints} = {
        $plural_diag->{code} => Diag::Translation::source_fingerprint(
            $plural_conf, $plural_diag, 'fr'
        ),
    };
    my $plural_provenance_path = tempfile();
    is( Diag::Translation::record_import(
            $plural_conf, [ $plural_diag ], $plural_import_document, $plural_provenance_path
        ), 1, 'repair import records plural selector dependencies' );
    my $plural_provenance = Diag::Translation::read_provenance($plural_provenance_path);
    is( Diag::Translation::provenance_status(
            $plural_provenance, $plural_conf, $plural_diag, 'fr'
        ), 'current', 'plural repair provenance starts source-current' );
    $plural_conf->{plural_rules}{cardinal_rule_2}{expression} = 'changed again';
    is( Diag::Translation::provenance_status(
            $plural_provenance, $plural_conf, $plural_diag, 'fr'
        ), 'stale', 'a later plural-rule change makes repair provenance stale' );
    unlink $plural_provenance_path
      or die "Cannot remove plural provenance $plural_provenance_path: $!\n";

    my $import_diag = {
        code => 'TRANSLATION_PROVENANCE_FIXTURE', number => 9102,
        params => [ { name => 'value', type => 'text', format_str => 's' } ],
        message_selectors => [], selector_definitions => [],
        message_template => {
            en => 'English %{value}',
            fr => 'Français %{value}',
        },
    };
    my $import_conf = { languages => {}, plural_rules => {} };
    my $repair_document = {
        target_language => 'fr', workflow => 'repair', reviewed => 0,
        template_sets => [ {
            code => $import_diag->{code}, number => $import_diag->{number},
            source_cases => Diag::Migration::template_cases( $import_diag, 'en' ),
            cases => [ { selectors => [], template => 'Français %{value}' } ],
        } ],
    };
    Diag::Migration::apply_translation_sets( [ $import_diag ], $repair_document );
    $repair_document->{source_fingerprints} = {
        $import_diag->{code} => Diag::Translation::source_fingerprint(
            $import_conf, $import_diag, 'fr'
        ),
    };
    my $repair_provenance_path = tempfile();
    is( Diag::Translation::record_import(
            $import_conf, [ $import_diag ], $repair_document, $repair_provenance_path
        ), 1, 'repair imports record validated per-diagnostic source fingerprints' );
    my $repair_provenance = Diag::Translation::read_provenance($repair_provenance_path);
    is( $repair_provenance->{entries}{fr}{ $import_diag->{code} }{workflow},
        'repair', 'repair provenance keeps its workflow origin' );
    ok( !$repair_provenance->{entries}{fr}{ $import_diag->{code} }{reviewed},
        'repair provenance does not claim linguistic review' );
    my $repair_audit = Diag::Translation::audit_diagnostic(
        $import_conf, $import_diag, 'fr', $repair_provenance
    );
    is( $repair_audit->{provenance}, 'current',
        'a repaired translation is source-current after import' );
    is( $repair_audit->{provenance_workflow}, 'repair',
        'translation audit reports the repair workflow' );
    ok( !$repair_audit->{reviewed},
        'translation audit reports that repair output is unreviewed' );
    open my $repair_before_fh, '<:raw', $repair_provenance_path
      or die "Cannot read repair provenance $repair_provenance_path: $!\n";
    local $/;
    my $repair_before = <$repair_before_fh>;
    close $repair_before_fh
      or die "Cannot close repair provenance $repair_provenance_path: $!\n";
    is( Diag::Translation::record_import(
            $import_conf, [ $import_diag ], $repair_document, $repair_provenance_path
        ), 1, 'repeated repair import remains accepted' );
    open my $repair_after_fh, '<:raw', $repair_provenance_path
      or die "Cannot read repair provenance $repair_provenance_path: $!\n";
    my $repair_after = <$repair_after_fh>;
    close $repair_after_fh
      or die "Cannot close repair provenance $repair_provenance_path: $!\n";
    is( $repair_after, $repair_before,
        'repeated repair import is idempotent' );
    my $repair_output_path = tempfile();
    my $repair_checkpoint_path = tempfile();
    Diag::Translation::save_progress(
        $repair_checkpoint_path,
        {
            completed => {
                $import_diag->{code} => {
                    template_set => $repair_document->{template_sets}[0],
                    source_fingerprint => $repair_document->{source_fingerprints}{
                        $import_diag->{code}
                    },
                },
            },
        },
        { language => 'fr', mode => 'repair', output => $repair_output_path },
    );
    my $saved_repair_output = Diag::Translation::read_json($repair_output_path);
    is( $saved_repair_output->{workflow}, 'repair',
        'repair output records its workflow origin' );
    ok( !$saved_repair_output->{reviewed},
        'repair output keeps linguistic review unset' );
    unlink $repair_output_path, $repair_checkpoint_path
      or die "Cannot remove test repair output: $!\n";

    my $review_document = {
        target_language => 'fr', reviewed => 1,
        template_sets => [ {
            code => $import_diag->{code}, number => $import_diag->{number},
            source_cases => Diag::Migration::template_cases( $import_diag, 'en' ),
            cases => [ { selectors => [], template => 'Français %{value}' } ],
        } ],
    };
    Diag::Migration::apply_translation_sets( [ $import_diag ], $review_document );
    $review_document->{source_fingerprints} = {
        $import_diag->{code} => Diag::Translation::source_fingerprint(
            $import_conf, $import_diag, 'fr'
        ),
    };
    my $unicode_json = Diag::Translation::json()->encode(
        { template => 'Texte français : élément' }
    );
    is( Diag::Translation::json()->decode($unicode_json)->{template},
        'Texte français : élément', 'translation JSON keeps Unicode intact' );
    my $provenance_path = tempfile();
    is( Diag::Translation::record_import(
            $import_conf, [ $import_diag ], $review_document, $provenance_path
        ), 1, 'reviewed imports record per-diagnostic source fingerprints' );
    my $import_provenance = Diag::Translation::read_provenance($provenance_path);
    is( Diag::Translation::provenance_status(
            $import_provenance, $import_conf, $import_diag, 'fr'
        ), 'current', 'reviewed import provenance is current after import' );
    $import_diag->{message_template}{en} = 'Changed source %{value}';
    eval {
        Diag::Translation::record_import(
            $import_conf, [ $import_diag ], $review_document, $provenance_path
        );
    };
    like( $@, qr/source or selector schema changed/,
        'reviewed imports reject source snapshots that have become stale' );
    is( Diag::Translation::provenance_status(
            $import_provenance, $import_conf, $import_diag, 'fr'
        ), 'stale', 'source changes are reported stale after import' );
    is( Diag::Translation::provenance_status(
            $repair_provenance, $import_conf, $import_diag, 'fr'
        ), 'stale', 'source changes make earlier repair provenance stale' );
    $repair_document->{template_sets}[0]{source_cases} =
      Diag::Migration::template_cases( $import_diag, 'en' );
    $repair_document->{source_fingerprints}{ $import_diag->{code} } =
      Diag::Translation::source_fingerprint( $import_conf, $import_diag, 'fr' );
    is( Diag::Translation::record_import(
            $import_conf, [ $import_diag ], $repair_document, $repair_provenance_path
        ), 1, 'a repaired stale translation refreshes its source fingerprint' );
    $repair_provenance = Diag::Translation::read_provenance($repair_provenance_path);
    is( Diag::Translation::provenance_status(
            $repair_provenance, $import_conf, $import_diag, 'fr'
        ), 'current', 'refreshed repair provenance is current' );
    ok( !$repair_provenance->{entries}{fr}{ $import_diag->{code} }{reviewed},
        'refreshing repair provenance does not mark it reviewed' );
    unlink $repair_provenance_path
      or die "Cannot remove test provenance $repair_provenance_path: $!\n";

    my $technical_diag = {
        code => 'TRANSLATION_TECHNICAL_TEXT_FIXTURE', number => 9104,
        params => [ { name => 'value', type => 'text', format_str => 's' } ],
        message_selectors => [], selector_definitions => [],
        message_template => {
            en => 'Set %{value} when a switch is active',
            fr => 'Set %{value} when a switch is active',
        },
    };
    my $technical_fingerprint = Diag::Translation::source_fingerprint(
        $import_conf, $technical_diag, 'fr'
    );
    my $technical_provenance = {
        version => 1,
        entries => {
            fr => {
                $technical_diag->{code} => {
                    fingerprint => $technical_fingerprint,
                    workflow => 'repair', reviewed => JSON::PP::false(),
                },
            },
        },
    };
    my $technical_provenance_path = tempfile();
    Diag::Translation::write_json( $technical_provenance_path, $technical_provenance );
    my $technical_contexts = Diag::Translation::select_contexts(
        $import_conf, [ $technical_diag ],
        { mode => 'repair', language => 'fr', provenance_file => $technical_provenance_path },
    );
    is( scalar @$technical_contexts, 0,
        'current provenance prevents requeueing unchanged English-looking text' );
    unlink $technical_provenance_path
      or die "Cannot remove test provenance $technical_provenance_path: $!\n";
    unlink $provenance_path or die "Cannot remove test provenance $provenance_path: $!\n";
}
