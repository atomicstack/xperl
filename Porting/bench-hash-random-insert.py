#!/usr/bin/env python3
"""Compare fresh hash constructions using many random key sets and value 1."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import statistics
import string
import subprocess
import sys


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def interval(values, seed):
    rng = random.Random(seed)
    samples = sorted(statistics.median(rng.choices(values, k=len(values)))
                     for _ in range(10000))
    return [samples[249], samples[9749]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', action='append', required=True, metavar='NAME=PERL')
    parser.add_argument('--baseline', default='blead')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sets', type=int, default=100)
    parser.add_argument('--keys', type=int, default=16)
    parser.add_argument('--repetitions', type=int, default=1000)
    parser.add_argument('--key-length', type=int, default=27)
    parser.add_argument('--trials', type=int, default=31)
    parser.add_argument('--seed', type=int, default=20261118)
    args = parser.parse_args()
    if min(args.sets, args.keys, args.repetitions, args.key_length, args.trials) < 1:
        parser.error('counts and key length must be positive')
    builds = {}
    for entry in args.build:
        name, separator, path = entry.partition('=')
        if not separator or not name or name in builds:
            parser.error('builds must have distinct names and use NAME=PERL')
        builds[name] = Path(path).resolve()
        if not builds[name].is_file():
            parser.error(f'Perl executable does not exist: {path}')
    if args.baseline not in builds:
        parser.error('baseline must name one of the builds')
    if args.sets * args.keys > len(string.ascii_letters + string.digits) ** args.key_length:
        parser.error('key space is too small for distinct keys')
    output = args.output.resolve()
    (output / 'datasets').mkdir(parents=True, exist_ok=True)
    worker = Path(__file__).with_suffix('.pl').resolve()
    config_code = 'print encode_json({map {$_=>$Config::Config{$_}} qw(cc gccversion optimize ccflags useithreads usemultiplicity)});'
    metadata = {
        'arguments': {**vars(args), 'output': str(output)},
        'worker': str(worker), 'worker_sha256': sha256(worker),
        'driver_sha256': sha256(Path(__file__)), 'python': sys.version,
        'cpu_affinity': sorted(os.sched_getaffinity(0)) if hasattr(os, 'sched_getaffinity') else None,
        'method': 'Each trial uses a new key corpus and fresh process per build. Each set is constructed repeatedly in a fresh hash with value 1. Timed regions include construction, destruction, loops, and scalar key counts.',
        'statistical_unit': 'one process batch; repeated constructions are not independent samples',
        'builds': {},
    }
    for name, perl in builds.items():
        config = subprocess.check_output([str(perl), f'-I{perl.parent / "lib"}',
                                          '-MConfig', '-MJSON::PP=encode_json', '-e', config_code], text=True)
        revision = subprocess.check_output(['git', '-C', str(perl.parent), 'rev-parse', 'HEAD'], text=True).strip()
        metadata['builds'][name] = {'perl': str(perl), 'sha256': sha256(perl),
                                  'revision': revision, 'config': json.loads(config)}
    (output / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    rng = random.Random(args.seed)
    alphabet = string.ascii_letters + string.digits
    rows = []
    with (output / 'raw.jsonl').open('w') as raw:
        for trial in range(1, args.trials + 1):
            seen = set()
            key_sets = []
            for _ in range(args.sets):
                keys = []
                while len(keys) < args.keys:
                    key = ''.join(rng.choices(alphabet, k=args.key_length))
                    if key not in seen:
                        seen.add(key)
                        keys.append(key)
                key_sets.append('\t'.join(keys))
            dataset = output / 'datasets' / f'{trial:03}.tsv'
            dataset.write_text('\n'.join(key_sets) + '\n', encoding='ascii')
            digest = sha256(dataset)
            hash_seed = f'0x{rng.getrandbits(64):016x}'
            order = list(builds)
            rng.shuffle(order)
            for rank, name in enumerate(order):
                perl = builds[name]
                env = os.environ.copy()
                for variable in ('PERL5LIB', 'PERL5OPT', 'PERL_HASH_LINEAR_MAX', 'PERL_HASH_SEED_DEBUG', 'PERL_PERTURB_KEYS'):
                    env.pop(variable, None)
                env['PERL_HASH_SEED'] = hash_seed
                result = subprocess.run([str(perl), f'-I{perl.parent / "lib"}', str(worker),
                                         str(dataset), str(args.sets), str(args.keys), str(args.repetitions)],
                                        env=env, text=True, capture_output=True, check=True)
                row = json.loads(result.stdout)
                expected = args.sets * args.keys * args.repetitions
                if row['checksum'] != expected or row['dataset_sha256'] != digest:
                    raise RuntimeError('worker result does not match its dataset')
                row.update(trial=trial, build=name, order=rank, hash_seed=hash_seed,
                           dataset=str(dataset))
                raw.write(json.dumps(row) + '\n')
                raw.flush()
                rows.append(row)
            print(f'{trial}/{args.trials} paired trial complete', flush=True)
    baseline = {r['trial']: r for r in rows if r['build'] == args.baseline}
    summary = []
    for name in builds:
        selected = [r for r in rows if r['build'] == name]
        ratios = [r['elapsed_seconds'] / baseline[r['trial']]['elapsed_seconds'] for r in selected]
        item = {'build': name, 'trials': len(selected),
                'median_ns_per_construction': statistics.median(r['ns_per_construction'] for r in selected),
                'paired_time_ratio_median': statistics.median(ratios),
                'paired_time_ratio_95_percent_interval': interval(ratios, args.seed),
                'paired_time_ratio_range': [min(ratios), max(ratios)]}
        summary.append(item)
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
