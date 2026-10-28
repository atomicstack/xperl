"""Build and select source context for diagnostic classification reviews."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
from source_owners import definition_index, enclosing_definition


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8'))


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def checked_note(note, source_hash):
    """Preserve review claims only while their recorded source still matches."""
    if not note:
        return {'status': 'unreviewed'}
    result = dict(note)
    result['status'] = ('focused-source-review' if note.get('source_sha256') == source_hash else 'stale')
    return result


def build_index(planning, notes_path):
    """Inventory references, not every function; semantic notes are separate inputs."""
    from class_tree import english_templates

    root = planning.parent
    entries = english_templates(planning)
    notes = read_json(notes_path) if notes_path.exists() else {'files': {}}
    manifest = {}
    for line in (root / 'MANIFEST').read_text().split('\n'):
        parts = line.split('\t', 1)
        if len(parts) == 2:
            manifest[parts[0]] = parts[1].strip()
    references = {}
    for code, entry in entries.items():
        for filename, numbers in entry['source_locations'].items():
            for number in numbers:
                references.setdefault(filename, []).append((number, code))
    files = {}
    for filename, matches in sorted(references.items()):
        data = (root / filename).read_bytes()
        text = data.decode('utf-8', errors='replace')
        lines = text.split('\n')
        definitions = definition_index(text, filename)
        file_notes = notes.get('files', {}).get(filename, {})
        functions = {}
        unresolved = []
        for number, code in sorted(matches):
            owner = enclosing_definition(definitions, number)
            if not owner['name']:
                unresolved.append({'line': number, 'code': code})
                continue
            spans = [d for d in definitions if d['name'] == owner['name'] and d['kind'] == owner['kind']
                     and d['start'] <= number <= d['end']]
            span = min(spans, key=lambda d: d['end'] - d['start'])
            key = (span['kind'], span['name'], span['start'])
            if key not in functions:
                source_hash = digest('\n'.join(lines[span['start'] - 1:span['end']]).encode('utf-8'))
                note = file_notes.get('functions', {}).get(span['name'])
                functions[key] = dict(span, source_sha256=source_hash,
                                      review=checked_note(note, source_hash), references=[])
            functions[key]['references'].append({'line': number, 'code': code})
        files[filename] = {
            'manifest_description': manifest.get(filename, ''),
            'source_sha256': digest(data),
            'review': checked_note(file_notes.get('review'), digest(data)),
            'functions': sorted(functions.values(), key=lambda d: (d['name'], d['start'])),
            'unresolved_references': unresolved,
        }
    revision = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root, check=True,
                              capture_output=True, text=True).stdout.strip()
    return {'schema_version': 1, 'source_revision': revision,
            'scope': 'Catalog references in scanned core and extension sources; not a complete call graph.',
            'files': files}


def render_overview(index):
    """Keep file/function/code relationships readable without source snippets."""
    lines = ['DIAGNOSTIC PRODUCER REFERENCE', '=============================', '',
             'Function names are inferred without preprocessing. References can be emitters,',
             'forwarders, framework checks or test fixtures. They are not all error conditions.',
             'Only focused-source-review descriptions have been checked against source.',
             'Unreviewed and stale entries require investigation. No call graph is inferred.', '']
    for filename, entry in index['files'].items():
        lines.append(filename + ' — ' + entry['manifest_description'])
        review = entry['review']
        lines.append('  File notes: ' + review['status'])
        if review.get('summary'):
            lines.append('  ' + review['summary'])
        for function in entry['functions']:
            lines.append(f"  {function['name']} [{function['kind']}, {function['start']}-{function['end']}; "
                         f"{function['review']['status']}]")
            if function['review'].get('summary'):
                lines.append('    ' + function['review']['summary'])
            by_code = {}
            for ref in function['references']:
                by_code.setdefault(ref['code'], []).append(str(ref['line']))
            for code, numbers in sorted(by_code.items()):
                lines.append('    ' + code + '  @ ' + ', '.join(numbers))
        for ref in entry['unresolved_references']:
            lines.append(f"  [enclosing definition unresolved] {ref['code']} @ {ref['line']}")
        lines.append('')
    return '\n'.join(lines)


def prompt_note(review):
    """Send semantic content, not bookkeeping or an unverified review claim."""
    if review.get('status') != 'focused-source-review':
        return {'status': review.get('status', 'unreviewed')}
    return {key: value for key, value in review.items() if key != 'source_sha256'}


def add_reference_context(packet, planning):
    """Select relevant notes once per file/function; the complete index stays local."""
    path = planning / 'diagnostic-source-context.json'
    if not path.exists():
        packet['source_reference'] = {'status': 'not generated'}
        return
    index = read_json(path)
    owners = {}
    for diagnostic in packet['diagnostics']:
        for context in diagnostic['source_contexts']:
            for owner in context['owners']:
                if owner['name']:
                    owners.setdefault(context['file'], set()).add((owner['kind'], owner['name']))
            owners.setdefault(context['file'], set())
    selected = {}
    for filename, wanted in sorted(owners.items()):
        entry = index['files'].get(filename)
        if not entry:
            selected[filename] = {'status': 'not indexed'}
            continue
        if digest((planning.parent / filename).read_bytes()) != entry['source_sha256']:
            selected[filename] = {'status': 'stale; regenerate source reference before relying on descriptions'}
            continue
        selected[filename] = {
            'review': prompt_note(entry['review']),
            'functions': {f['name']: prompt_note(f['review']) for f in entry['functions']
                          if (f['kind'], f['name']) in wanted},
        }
    packet['source_reference'] = {'files': selected}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--notes', type=Path)
    parser.add_argument('--output', type=Path)
    arguments = parser.parse_args()
    planning = Path(__file__).resolve().parent.parent
    notes = arguments.notes or planning / 'diagnostic-source-notes.json'
    output = arguments.output or planning / 'diagnostic-source-context.json'
    index = build_index(planning, notes)
    write_json(output, index)
    overview = output.with_suffix('.txt')
    overview.write_text(render_overview(index), encoding='utf-8')
    functions = sum(len(f['functions']) for f in index['files'].values())
    reviewed = sum(f['review']['status'] == 'focused-source-review'
                   for entry in index['files'].values() for f in entry['functions'])
    print(f'{len(index["files"])} files, {functions} function/macro spans; {reviewed} have current focused reviews')
    print(output)
    print(overview)


if __name__ == '__main__':
    main()
