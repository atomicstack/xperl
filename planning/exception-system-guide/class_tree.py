"""Build a self-contained class browser from the classification reports."""

import csv
from datetime import datetime, timezone
import html
import json
from pathlib import Path
import re
import subprocess

from source_owners import definition_index, enclosing_definition


def read_rows(path):
    """Read a report without interpreting its classification fields."""
    with path.open(encoding='utf-8', newline='') as source:
        return list(csv.DictReader(source, delimiter='\t'))


def english_templates(planning):
    """Read named English templates through Perl rather than parsing Perl source."""
    program = r'''
        our ($CONF, $META);
        my $path = shift @ARGV;
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
        print JSON::PP->new->utf8->canonical->encode(\%templates);
    '''
    result = subprocess.run(
        ['perl', '-MJSON::PP', '-Mcharnames=:full', '-e', program,
         str((planning.parent / 'diag_conf.pl').resolve())],
        check=True, capture_output=True, encoding='utf-8', cwd=planning.parent)
    return json.loads(result.stdout)


def template_cases(value, selectors, path=()):
    """Flatten selector branches for display, retaining each named selector choice."""
    if value is None and not path:
        return []
    if isinstance(value, str):
        return [{'selectors': list(path), 'text': value}]
    if not isinstance(value, dict):
        raise ValueError('English template must be a string or selector hash')
    depth = len(path)
    if depth >= len(selectors):
        raise ValueError('English template has more selector levels than its definition')
    cases = []
    for key in sorted(value, key=lambda key: (key == '*', key)):
        cases.extend(template_cases(
            value[key], selectors, path + ((selectors[depth], key),)))
    return cases


def source_contexts(planning, entries, radius=3):
    """Read referenced files once and merge overlapping context windows."""
    files = {name for entry in entries.values() for name in entry['source_files']}
    lines_by_file, definitions_by_file = {}, {}
    for name in files:
        text = (planning.parent / name).read_bytes().decode('utf-8', errors='replace')
        lines_by_file[name] = [line.rstrip('\r') for line in text.split('\n')]
        definitions_by_file[name] = definition_index(text, name)
    for entry in entries.values():
        contexts = []
        for name, numbers in sorted(entry['source_locations'].items()):
            lines = lines_by_file[name]
            windows = []
            for number in numbers:
                start, end = max(1, number - radius), min(len(lines), number + radius)
                if windows and start <= windows[-1][1] + 1:
                    windows[-1][1] = max(windows[-1][1], end)
                    windows[-1][2].append(number)
                else:
                    windows.append([start, end, [number]])
            for start, end, matches in windows:
                owners = []
                for number in matches:
                    owner = enclosing_definition(definitions_by_file[name], number)
                    if owner not in owners:
                        owners.append(owner)
                contexts.append(dict(file=name, start=start, matches=matches,
                                     lines=lines[start - 1:end], owners=owners))
        entry['source_contexts'] = contexts


def review_evidence(source, destination):
    """Enrich a review packet using the same source ownership and snippets as the UI."""

    planning = Path(__file__).resolve().parent.parent
    packet = json.loads(Path(source).read_text(encoding='utf-8'))
    entries = {entry['code']: entry for entry in packet['diagnostics']}
    source_contexts(planning, entries)
    from source_reference import add_reference_context
    add_reference_context(packet, planning)
    assignments = {row['code']: row for row in read_rows(
        planning / 'diagnostic-error-family-proposal.tsv')}
    for entry in entries.values():
        entry['previous_review'] = assignments.get(entry['code'], {})
    packet['class_registry'] = read_rows(planning / 'diagnostic-class-registry.tsv')
    Path(destination).write_text(json.dumps(packet, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def tree_data(planning):
    """Join class ancestry with reviewed assignments and preserve runtime differences."""
    registry = read_rows(planning / 'diagnostic-class-registry.tsv')
    assignments = read_rows(planning / 'diagnostic-error-family-proposal.tsv')
    templates = english_templates(planning)
    source_contexts(planning, templates)
    for row in assignments:
        entry = templates[row['code']]
        row['english_templates'] = template_cases(entry['templates'], entry['selectors'])
        row['selectors'] = entry['selector_details']
        row['word_bindings'] = entry['word_bindings']
        row['source_files'] = entry['source_files']
        row['source_locations'] = entry['source_locations']
        row['source_contexts'] = entry['source_contexts']
    classes = {row['class']: dict(row, registered=True) for row in registry}

    for row in assignments:
        name = row['recommendation']
        if name == 'none' or name in classes:
            continue
        parent = row['recommended_parents'].split('; ')[0]
        if not parent.startswith('XPerl::'):
            raise ValueError(f'Missing parent for {name}')
        classes[name] = dict(
            **{'class': name}, parent=parent, registered=False,
            leaf_only='0', warning_category='-', source='classification proposal')

    for name in classes:
        seen = set()
        current = name
        while current:
            if current in seen:
                raise ValueError(f'Class ancestry cycle at {current}')
            if current not in classes:
                raise ValueError(f'Unknown class ancestor {current}')
            seen.add(current)
            current = classes[current]['parent']

    if len({row['code'] for row in assignments}) != len(assignments):
        raise ValueError('Duplicate diagnostic codes in classification report')
    return {'classes': list(classes.values()), 'diagnostics': assignments,
            'source_root': planning.parent.resolve().as_uri()}


def generation_info(planning, data):
    """Identify the checkout and input changes represented by this snapshot."""
    inputs = {'diag_conf.pl', 'planning', 'regen/diag.pl', 'regen/diag_lib.pm'}
    for diagnostic in data['diagnostics']:
        inputs.update(diagnostic['source_files'])
    result = {'generated_at': datetime.now(timezone.utc).isoformat(timespec='seconds'),
              'commit': None, 'modified_inputs': None}
    try:
        result['commit'] = subprocess.run(
            ['git', 'rev-parse', '--verify', 'HEAD'], cwd=planning.parent,
            check=True, capture_output=True, encoding='utf-8').stdout.strip()
        status = subprocess.run(
            ['git', 'status', '--porcelain', '--untracked-files=normal', '--', *sorted(inputs)],
            cwd=planning.parent, check=True, capture_output=True, encoding='utf-8')
        result['modified_inputs'] = bool(status.stdout)
    except (OSError, subprocess.CalledProcessError):
        # Source exports can render the browser without a Git checkout.
        result['commit'] = None
    return result


def render_class_tree(planning, destination, assets):
    """Embed data, styles and the controller; opening the file needs no server."""
    data = tree_data(planning)
    data['generation'] = generation_info(planning, data)
    generation = data['generation']
    timestamp = html.escape(generation['generated_at'])
    commit = generation['commit']
    revision = (f'Commit <code title="{html.escape(commit)}">{html.escape(commit[:12])}</code>'
                if commit else 'Commit unavailable (source export)')
    if generation['modified_inputs']:
        revision += ' · includes uncommitted input changes'
    provenance = f'Generated <time datetime="{timestamp}">{timestamp}</time> · {revision}'
    payload = json.dumps(data, ensure_ascii=False).replace('<', '\\u003c')
    styles = (assets / 'class-tree.css').read_text(encoding='utf-8')
    controller = (assets / 'class-tree.js').read_text(encoding='utf-8')
    title = 'XPerl diagnostic class browser'
    page = '''<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>__STYLES__</style>
<header>
  <div class="eyebrow">XPerl · diagnostics</div>
  <h1>Class browser</h1>
  <p class="generation-info">__GENERATION__</p>
  <p>Explore the classification tree. Select a class or diagnostic for details.</p>
  <div class="category-legend" aria-label="Entry colors">
    <span class="warning">● Warnings</span><span class="error">● Errors</span>
    <span class="internal">● Internal errors</span>
  </div>
  <div class="controls">
    <label class="search-label">Search classes, codes, templates or tags
      <input id="search" type="search" placeholder="e.g. Unicode, GOTO, subject:rng" autocomplete="off">
    </label>
    <label>Show
      <select id="filter">
        <option value="all">All entries</option>
        <option value="internal">Internal</option>
        <option value="panic">Panic</option>
        <option value="render">Render-only</option>
      </select>
    </label>
    <button id="expand" type="button">Expand all</button>
    <button id="collapse" type="button">Collapse all</button>
    <button id="reset" type="button">Reset view</button>
    <label class="check"><input id="empty" type="checkbox"> Show empty classes</label>
  </div>
  <div class="summary"><span id="counts" role="status" aria-live="polite"></span>
    <span>← → open / close · ↑ ↓ navigate · Home / End jump</span></div>
</header>
<main>
  <section class="tree-panel" aria-label="Class hierarchy">
    <ul id="tree" role="tree" aria-label="Diagnostic classes and codes"></ul>
    <p id="no-results" hidden>No matching entries. Try a shorter search or a different filter.</p>
  </section>
  <aside id="details" aria-label="Selected item details">
    <h2>Select an item</h2>
    <p>The tree shows primary inheritance. Additional proposed parents appear here.</p>
    <p>Internal failures live under <code>Error::Internal</code>. Render is a flag,
    not a separate class family. Render-only entries format values without creating
    a diagnostic instance.</p>
  </aside>
</main>
<noscript>This class browser requires JavaScript. The text report is available in planning/diagnostic-error-family-proposal.tsv.</noscript>
<script id="tree-data" type="application/json">__DATA__</script>
<script>__CONTROLLER__</script>
</html>
'''
    # Substitute once so data cannot accidentally become a template marker.
    parts = {
        '__TITLE__': html.escape(title), '__STYLES__': styles,
        '__DATA__': payload, '__CONTROLLER__': controller,
        '__GENERATION__': provenance,
    }
    page = re.sub(r'__(?:TITLE|STYLES|DATA|CONTROLLER|GENERATION)__', lambda match: parts[match[0]], page)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(page, encoding='utf-8')
    print(f'Interactive hierarchy: {destination}', flush=True)


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--review-evidence', nargs=2, metavar=('INPUT', 'OUTPUT'))
    mode.add_argument('--output', type=Path, metavar='HTML')
    arguments = parser.parse_args()
    if arguments.review_evidence:
        review_evidence(*arguments.review_evidence)
    else:
        assets = Path(__file__).resolve().parent
        render_class_tree(assets.parent, arguments.output.resolve(), assets)
