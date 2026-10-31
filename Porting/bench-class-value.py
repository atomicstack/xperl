#!/usr/bin/env python3
"""Run isolated, randomized class/Moo/bless comparisons; preserve raw JSONL."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import sys
import time


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--perl', default=str(root / 'perl'), help='interpreter executable')
    parser.add_argument('--core-lib', help='matching core lib directory (default: next to interpreter)')
    parser.add_argument('-I', '--include', action='append', default=[], help='extra module directory; repeatable')
    parser.add_argument('--output', required=True, type=Path, help='new output directory')
    parser.add_argument('--models', default='class,moo-perl,moo-xs,bless,bless-checked')
    parser.add_argument('--fields', default='2,8,32')
    parser.add_argument('--reads', default='1,10,100')
    parser.add_argument('--cases', default='construct,retain,access,internal,create_access,create_internal')
    parser.add_argument('--initialization', choices=['required', 'defaults'], default='required')
    parser.add_argument('--repeats', type=int, default=7)
    parser.add_argument('--seconds', type=float, default=0.2, help='target measured seconds per sample')
    parser.add_argument('--timeout', type=float, default=30, help='hard limit in seconds per worker')
    parser.add_argument('--memory-counts', default='10000,50000,100000')
    parser.add_argument('--memory-repeats', type=int, default=3)
    parser.add_argument('--cpu', type=int, help='pin all worker processes to this logical CPU')
    parser.add_argument('--seed', type=int, default=20261030)
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    if args.repeats < 1 or args.memory_repeats < 1 or args.seconds <= 0 or args.timeout <= 0:
        parser.error('repeats, seconds, and timeout must be positive')
    models = args.models.split(',')
    fields = [int(x) for x in args.fields.split(',')]
    reads = [int(x) for x in args.reads.split(',')]
    counts = sorted(set(int(x) for x in args.memory_counts.split(',') if x))
    if not fields or min(fields) < 1 or max(fields) > 256 or not reads or min(reads) < 1:
        parser.error('fields must be 1..256 and reads must be positive')
    if counts and (min(counts) < 1 or len(counts) < 2):
        parser.error('supply at least two positive memory populations, or an empty string to skip')
    cases = args.cases.split(',')
    if set(cases) - {'construct', 'retain', 'access', 'internal', 'create_access', 'create_internal'}:
        parser.error('unknown timing case')
    exe = Path(args.perl).resolve()
    core_lib = Path(args.core_lib).resolve() if args.core_lib else exe.parent / 'lib'
    includes = [str(Path(p).resolve()) for p in args.include]
    worker = root / 'Porting/bench-class-value.pl'
    prefix = [str(exe), '-I' + str(core_lib)] + ['-I' + p for p in includes] + [str(worker)]
    if args.cpu is not None:
        if not hasattr(os, 'sched_setaffinity'):
            parser.error('--cpu requires sched_setaffinity')
        os.sched_setaffinity(0, {args.cpu})
    env = os.environ.copy()
    for key in ('PERL5OPT', 'PERL5LIB', 'PERLLIB'):
        env.pop(key, None)
    env.update(PERL_HASH_SEED='0', PERL_PERTURB_KEYS='0')
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    config = vars(args).copy()
    config['output'] = str(out)
    config.update(executable=str(exe), core_lib=str(core_lib), includes=includes,
                  platform=platform.platform(), executable_sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),
                  worker_sha256=hashlib.sha256(worker.read_bytes()).hexdigest(),
                  start_time=time.strftime('%Y-%m-%dT%H:%M:%S%z'))
    try:
        config['runner_git_head'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
        config['runner_git_status'] = subprocess.check_output(['git', 'status', '--short'], cwd=root, text=True)
        (out / 'working-tree.patch').write_bytes(subprocess.check_output(['git', 'diff'], cwd=root))
    except subprocess.CalledProcessError:
        pass
    if Path('/proc/cpuinfo').exists():
        config['cpu_info'] = sorted(set(line.strip() for line in Path('/proc/cpuinfo').read_text().splitlines()
                                       if line.startswith(('model name', 'Hardware'))))
    (out / 'config.json').write_text(json.dumps(config, indent=2) + '\n')
    (out / worker.name).write_bytes(worker.read_bytes())
    (out / Path(__file__).name).write_bytes(Path(__file__).read_bytes())
    rows = []

    def run(model, fields, case='check', reads=1, iterations=0, phase='check', repeat=0):
        command = prefix + ['--model', model, '--fields', str(fields), '--case', case,
                            '--reads', str(reads), '--iterations', str(iterations), '--initialization', args.initialization]
        started = time.monotonic()
        try:
            proc = subprocess.run(command, env=env, text=True, capture_output=True, timeout=args.timeout)
        except subprocess.TimeoutExpired as error:
            (out / 'failure.json').write_text(json.dumps({'command': command, 'error': str(error)}, indent=2))
            raise RuntimeError(f'{model}/{fields}/{case} exceeded {args.timeout}s; worker killed') from error
        if proc.returncode or proc.stderr:
            (out / 'failure.json').write_text(json.dumps({'command': command, 'status': proc.returncode,
                'stdout': proc.stdout, 'stderr': proc.stderr}, indent=2))
            raise RuntimeError(f'{model}/{fields}/{case} failed; see {out}/failure.json')
        row = json.loads(proc.stdout)
        row.update(phase=phase, repeat=repeat, process_seconds=time.monotonic() - started)
        rows.append(row)
        with (out / 'samples.jsonl').open('a') as handle:
            handle.write(json.dumps(row) + '\n')
        return row

    for model in models:
        for field_count in fields:
            result = run(model, field_count)
            print(f'checked {model}, fields={field_count}, XS reader={result["accessor_xs"]}', flush=True)
            source = subprocess.check_output(prefix + ['--model', model, '--fields', str(field_count), '--source', '--initialization', args.initialization], env=env)
            (out / f'model-{model}-{field_count}.pl').write_bytes(source)
    if args.check_only:
        return
    jobs = [(m, f, c, r) for m in models for f in fields for c in cases
            for r in ([1] if c in ('construct', 'retain') else reads)]
    rng = random.Random(args.seed)
    rng.shuffle(jobs)
    sizes = {}
    for index, job in enumerate(jobs):
        n = 1000
        cap = 50000 if job[2] == 'retain' else 10000000
        for _ in range(4):
            row = run(*job, iterations=n, phase='calibrate')
            if row['seconds'] >= 0.01 or n == cap:
                break
            n = min(cap, n * max(2, min(20, int(0.012 / max(row['seconds'], 1e-9)))))
        sizes[job] = min(cap, max(1, int(n * args.seconds / max(row['seconds'], 1e-9))))
        if (index + 1) % 25 == 0:
            print(f'calibrated {index + 1}/{len(jobs)} cases', flush=True)
    for repeat in range(args.repeats):
        rng.shuffle(jobs)
        for job in jobs:
            run(*job, iterations=sizes[job], phase='timing', repeat=repeat)
        print(f'timing round {repeat + 1}/{args.repeats}', flush=True)
    memory_jobs = [(m, f, n) for m in models for f in fields for n in counts]
    for repeat in range(args.memory_repeats):
        rng.shuffle(memory_jobs)
        for m, f, n in memory_jobs:
            run(m, f, case='memory', iterations=n, phase='memory', repeat=repeat)
        if memory_jobs:
            print(f'memory round {repeat + 1}/{args.memory_repeats}', flush=True)
    with (out / 'timing.csv').open('w') as handle:
        writer = csv.writer(handle)
        writer.writerow(['model', 'fields', 'case', 'reads', 'iterations', 'median_ns_per_iteration',
                         'min_ns', 'max_ns', 'median_absolute_deviation_ns', 'samples'])
        for job in sorted(jobs):
            vals = [r['seconds'] * 1e9 / r['iterations'] for r in rows
                    if r['phase'] == 'timing' and (r['model'], r['fields'], r['case'], r['reads']) == job]
            median = statistics.median(vals)
            writer.writerow([*job, sizes[job], median, min(vals), max(vals),
                             statistics.median(abs(v - median) for v in vals), len(vals)])
    with (out / 'memory.csv').open('w') as handle:
        writer = csv.writer(handle)
        writer.writerow(['model', 'fields', 'population', 'median_rss_delta', 'median_bytes_per_object'])
        for m, f, n in sorted(memory_jobs):
            vals = [r['rss_delta'] for r in rows if r['phase'] == 'memory'
                    and (r['model'], r['fields'], r['iterations']) == (m, f, n)]
            median = statistics.median(vals)
            writer.writerow([m, f, n, median, median / n])
    with (out / 'memory-slopes.csv').open('w') as handle:
        writer = csv.writer(handle)
        writer.writerow(['model', 'fields', 'min_population', 'max_population', 'resident_bytes_per_object'])
        if counts:
            for m in models:
                for f in fields:
                    medians = [statistics.median(r['rss_delta'] for r in rows if r['phase'] == 'memory'
                               and (r['model'], r['fields'], r['iterations']) == (m, f, n)) for n in (counts[0], counts[-1])]
                    writer.writerow([m, f, counts[0], counts[-1], (medians[1] - medians[0]) / (counts[-1] - counts[0])])
    print(f'Completed. Raw samples and CSV summaries: {out}', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
