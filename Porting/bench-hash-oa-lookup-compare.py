#!/usr/bin/env python3
"""Paired fixed-count lookup benchmarks for ordinary Perl hashes."""

import argparse
import csv
import hashlib
import json
import os
import platform
import random
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path


WORKER_FIELDS = [
    "mode", "n", "lookups", "elapsed_seconds", "ns_per_lookup", "sum",
    "final_keys", "result_sha256", "memory_available", "requested_bytes", "index_bytes",
    "entry_bytes", "hv_size", "hv_body_size", "arena_backed",
    "index_capacity", "index_width", "slot_size", "hash_bytes",
    "entry_index_bytes", "allocator_bytes", "live", "entry_capacity",
    "current_rss_kb", "warmup_seconds", "process_cpu_seconds",
    "cpu_freq_before_khz", "cpu_freq_after_khz",
]


def parse_sizes(value):
    sizes = []
    for part in value.split(","):
        part = part.strip()
        if not part:
            continue
        match = re.fullmatch(r"(\d+)(?:-|\.\.)(\d+)", part)
        if match:
            first, last = map(int, match.groups())
            if first > last:
                raise ValueError(f"descending size range: {part}")
            sizes.extend(range(first, last + 1))
        else:
            sizes.append(int(part))
    if not sizes or min(sizes) < 0:
        raise ValueError("sizes must be a nonempty list of nonnegative integers")
    if len(set(sizes)) != len(sizes):
        raise ValueError("sizes must not contain duplicates")
    return sizes


def perl_info(perl):
    cwd = Path(perl).resolve().parent
    version = subprocess.check_output(
        [perl, "-Ilib", "-e", "print $^V"], cwd=cwd, text=True).strip()
    config = subprocess.check_output(
        [perl, "-Ilib", "-MConfig", "-e",
         'print join("\\n", map { "$_=$Config::Config{$_}" } '
         'qw(cc ccflags optimize gccversion useithreads))'],
        cwd=cwd, text=True)
    return {"version": version,
            **dict(line.split("=", 1) for line in config.splitlines())}


def source_info(root):
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=root, text=True,
                                       stderr=subprocess.DEVNULL).strip()
    try:
        return {"revision": git("rev-parse", "HEAD"),
                "dirty": bool(git("status", "--porcelain")),
                "source_kind": "git-checkout"}
    except (subprocess.CalledProcessError, FileNotFoundError):
        return {"revision": None, "dirty": None,
                "source_kind": "archived-build-without-git-metadata",
                "note": "binary hash identifies this build; source diff unavailable"}


def save_source_patch(root, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with path.open("wb") as output:
            subprocess.run(["git", "diff", "HEAD", "--binary"], cwd=root,
                           stdout=output, stderr=subprocess.DEVNULL, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        path.unlink(missing_ok=True)
        return {"path": None, "bytes": None, "sha256": None,
                "kind": "unavailable-no-git-source-tree"}
    data = path.read_bytes()
    return {"path": str(path), "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(), "kind": "git-diff"}


def run_worker(perl, worker, mode, n, lookups, hash_seed, query_seed,
               is_candidate=False, linear_max=None, warmup_seconds=0.0,
               cpu=None):
    env = os.environ.copy()
    env["PERL_HASH_SEED"] = f"0x{hash_seed:016x}"
    env.pop("PERL_HASH_LINEAR_MAX", None)
    if is_candidate and linear_max is not None:
        env["PERL_HASH_LINEAR_MAX"] = str(linear_max)
    command = [str(Path(perl).resolve()), "-Ilib", str(worker),
               mode, str(n), str(lookups), str(query_seed),
               str(warmup_seconds), "" if cpu is None else str(cpu)]
    start = time.monotonic()
    preexec_fn = None
    if cpu is not None and hasattr(os, "sched_setaffinity"):
        preexec_fn = lambda: os.sched_setaffinity(0, {cpu})
    result = subprocess.run(command, cwd=Path(perl).resolve().parent, env=env,
                            text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, preexec_fn=preexec_fn)
    wall = time.monotonic() - start
    if result.returncode:
        raise RuntimeError(f"worker failed {command}:\n{result.stderr}")
    if result.stderr:
        raise RuntimeError(f"worker wrote to stderr {command}:\n{result.stderr}")
    fields = next(csv.reader([result.stdout.strip()]))
    if len(fields) != len(WORKER_FIELDS):
        raise RuntimeError(f"unexpected worker CSV ({len(fields)} fields): "
                           f"{result.stdout!r}")
    row = dict(zip(WORKER_FIELDS, fields))
    int_fields = set(WORKER_FIELDS) - {
        "mode", "result_sha256", "elapsed_seconds", "ns_per_lookup", "current_rss_kb",
        "warmup_seconds", "process_cpu_seconds", "cpu_freq_before_khz",
        "cpu_freq_after_khz",
    }
    for field in int_fields:
        row[field] = int(row[field]) if row[field] != "" else None
    for field in ("elapsed_seconds", "ns_per_lookup"):
        row[field] = float(row[field])
    row["current_rss_kb"] = (int(row["current_rss_kb"])
                              if row["current_rss_kb"] else None)
    row["process_cpu_seconds"] = (float(row["process_cpu_seconds"])
                                   if row["process_cpu_seconds"] else None)
    row["warmup_seconds"] = float(row["warmup_seconds"])
    for field in ("cpu_freq_before_khz", "cpu_freq_after_khz"):
        row[field] = int(row[field]) if row[field] else None
    row["worker_wall_seconds"] = wall
    return row


def median_field(rows, field):
    values = [row[field] for row in rows if row.get(field) is not None]
    return statistics.median(values) if values else None


def median_per_live(rows, field, scale=1):
    values = [row[field] * scale / row["live"] for row in rows
              if row.get(field) is not None and row.get("live")]
    return statistics.median(values) if values else None


def median_total_bytes(rows):
    totals = [row["requested_bytes"] + row["hv_size"] + row["hv_body_size"]
              for row in rows
              if all(row.get(field) is not None
                     for field in ("requested_bytes", "hv_size", "hv_body_size"))]
    return statistics.median(totals) if totals else None


def summarize(raw, sizes):
    summary = []
    for n in sizes:
        pairs = {}
        for row in raw:
            if row["n"] == n and row["mode"] == "hit":
                pairs.setdefault(row["trial"], {})[row["build"]] = row
        ratios = [pair["baseline"]["ns_per_lookup"] /
                  pair["candidate"]["ns_per_lookup"]
                  for pair in pairs.values()]
        base = [pair["baseline"] for pair in pairs.values()]
        candidate = [pair["candidate"] for pair in pairs.values()]
        control = [row for row in raw if row["n"] == n and row["mode"] == "control"]
        baseline_control = [row for row in control
                            if row["build"] == "baseline-control"]
        candidate_control = [row for row in control
                             if row["build"] == "candidate-control"]
        summary.append({
            "n": n,
            "paired_trials": len(ratios),
            "baseline_ns_per_lookup_median": median_field(base, "ns_per_lookup"),
            "candidate_ns_per_lookup_median": median_field(candidate, "ns_per_lookup"),
            "speedup_baseline_over_candidate_median": statistics.median(ratios),
            "speedup_min": min(ratios),
            "speedup_max": max(ratios),
            "control_ns_per_lookup_median": median_field(control, "ns_per_lookup"),
            "baseline_control_ns_per_lookup_median": median_field(
                baseline_control, "ns_per_lookup"),
            "candidate_control_ns_per_lookup_median": median_field(
                candidate_control, "ns_per_lookup"),
            "baseline_memory_available": bool(base and base[0]["memory_available"]),
            "candidate_memory_available": bool(candidate and candidate[0]["memory_available"]),
            "baseline_requested_bytes_median": median_field(base, "requested_bytes"),
            "candidate_requested_bytes_median": median_field(candidate, "requested_bytes"),
            "baseline_total_bytes_including_hv_median": median_total_bytes(base),
            "candidate_total_bytes_including_hv_median": median_total_bytes(candidate),
            "baseline_allocator_bytes_median": median_field(base, "allocator_bytes"),
            "candidate_allocator_bytes_median": median_field(candidate, "allocator_bytes"),
            "baseline_current_rss_kb_median": median_field(base, "current_rss_kb"),
            "candidate_current_rss_kb_median": median_field(candidate, "current_rss_kb"),
            "baseline_requested_bytes_per_live": median_per_live(base, "requested_bytes"),
            "candidate_requested_bytes_per_live": median_per_live(candidate, "requested_bytes"),
        })
    return summary


def cpu_model():
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.lower().startswith("model name"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, help="path to original Perl executable")
    parser.add_argument("--candidate", required=True, help="path to candidate Perl executable")
    parser.add_argument("--outputdir", required=True)
    parser.add_argument("--trials", type=int, default=7)
    parser.add_argument("--lookups", type=int, default=1_000_000)
    parser.add_argument("--sizes", default="0-9",
                        help="comma-separated sizes or ranges; default is 0 through 9")
    parser.add_argument("--seed", type=int, default=20261031)
    parser.add_argument("--linear-max", type=int, choices=(0, 2, 4, 8),
                        help="set PERL_HASH_LINEAR_MAX for candidate; unset by default")
    parser.add_argument("--warmup-seconds", type=float, default=0.0,
                        help="run the timed lookup loop before measurement")
    parser.add_argument("--cpu", type=int,
                        help="pin each worker to this CPU when affinity is supported")
    args = parser.parse_args()
    if args.trials < 1 or args.lookups < 1 or args.warmup_seconds < 0:
        parser.error("--trials and --lookups must be positive; warmup must be nonnegative")
    try:
        sizes = parse_sizes(args.sizes)
    except ValueError as error:
        parser.error(str(error))
    output = Path(args.outputdir).resolve()
    output.mkdir(parents=True, exist_ok=True)
    worker = Path(__file__).resolve().with_name("bench-hash-oa-lookup.pl")
    builds = {"baseline": Path(args.baseline).resolve(),
              "candidate": Path(args.candidate).resolve()}
    patch_metadata = {}
    build_metadata = {}
    for name, path in builds.items():
        patch = save_source_patch(path.parent, output / "source-patches" / f"{name}.diff")
        patch_metadata[name] = {**patch,
                                "path": (str(Path("source-patches") / f"{name}.diff")
                                         if patch["path"] else None)}
        build_metadata[name] = {
            "perl": str(path),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            **perl_info(str(path)), **source_info(path.parent),
        }
    metadata = {
        "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "seed": args.seed, "trials": args.trials, "lookups_per_trial": args.lookups,
        "sizes": sizes, "query_cycle_small_hashes": 1024,
        "larger_hash_queries": "shuffle full key set before timing",
        "n_zero_behavior": "empty hash; repeated unsuccessful lookups",
        "runtime_environment": {
            "baseline_PERL_HASH_LINEAR_MAX": "unset",
            "candidate_PERL_HASH_LINEAR_MAX": args.linear_max,
        },
        "measurement": {
            "warmup_seconds": args.warmup_seconds,
            "pinned_cpu": args.cpu,
            "allowed_cpus": (sorted(os.sched_getaffinity(0))
                             if hasattr(os, "sched_getaffinity") else None),
            "frequency_sampling": "per-worker before/after timed section when available",
            "process_cpu_clock": "CLOCK_PROCESS_CPUTIME_ID when available",
        },
        "kernel": platform.platform(), "machine": platform.machine(),
        "cpu": cpu_model(), "python": sys.version,
        "worker": {"path": str(worker),
                   "sha256": hashlib.sha256(worker.read_bytes()).hexdigest()},
        "driver": {"path": str(Path(__file__).resolve()),
                   "sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()},
        "source_patches": patch_metadata, "builds": build_metadata,
    }
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2,
                                                        sort_keys=True) + "\n")

    rng = random.Random(args.seed)
    raw = []
    fields = ["trial", "build", "run_order", "hash_seed", "query_seed",
              *WORKER_FIELDS, "worker_wall_seconds", "linear_max"]
    with (output / "raw.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for trial in range(1, args.trials + 1):
            for n in sizes:
                hash_seed = rng.getrandbits(64)
                query_seed = rng.getrandbits(32)
                order = ["baseline", "candidate"]
                control_order = ["baseline-control", "candidate-control"]
                rng.shuffle(order)
                rng.shuffle(control_order)
                pair = {}
                for run_order, build in enumerate(order, 1):
                    row = run_worker(
                        str(builds[build]), worker, "hit", n, args.lookups,
                        hash_seed, query_seed, is_candidate=build == "candidate",
                        linear_max=args.linear_max,
                        warmup_seconds=args.warmup_seconds, cpu=args.cpu)
                    row.update(trial=trial, build=build, run_order=run_order,
                               hash_seed=f"0x{hash_seed:016x}", query_seed=query_seed,
                               linear_max=(args.linear_max if build == "candidate" else ""))
                    pair[build] = row
                    raw.append(row)
                    writer.writerow(row)
                    stream.flush()
                if pair["baseline"]["sum"] != pair["candidate"]["sum"]:
                    raise RuntimeError(f"lookup checksum mismatch at N={n}, trial={trial}")
                if pair["baseline"]["final_keys"] != pair["candidate"]["final_keys"]:
                    raise RuntimeError(f"final key count mismatch at N={n}, trial={trial}")
                if pair["baseline"]["result_sha256"] != pair["candidate"]["result_sha256"]:
                    raise RuntimeError(f"hash contents differ at N={n}, trial={trial}")
                for run_order, control_build in enumerate(control_order, 3):
                    build = control_build.removesuffix("-control")
                    control = run_worker(
                        str(builds[build]), worker, "control", n, args.lookups,
                        hash_seed, query_seed, is_candidate=build == "candidate",
                        linear_max=args.linear_max,
                        warmup_seconds=args.warmup_seconds, cpu=args.cpu)
                    control.update(trial=trial, build=control_build,
                                   run_order=run_order,
                                   hash_seed=f"0x{hash_seed:016x}", query_seed=query_seed,
                                   linear_max=(args.linear_max if build == "candidate" else ""))
                    raw.append(control)
                    writer.writerow(control)
                    stream.flush()
                print(f"{trial}/{args.trials} flat lookup N={n} done", file=sys.stderr)
    (output / "summary.json").write_text(
        json.dumps(summarize(raw, sizes), indent=2) + "\n")


if __name__ == "__main__":
    main()
