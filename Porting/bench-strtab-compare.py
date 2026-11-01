#!/usr/bin/env python3
"""Compare PL_strtab fill and teardown costs between Perl builds."""

import argparse
import csv
import hashlib
import json
import os
import random
import statistics
import subprocess
import time
from pathlib import Path


STAT_NAMES = ["live", "capacity", "tombstones", "slot_size", "metadata_bytes",
              "index_requested_bytes", "probe_max", "probe_total"]


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def median(values):
    return statistics.median(values) if values else None


def value_range(values):
    return [min(values), max(values)] if values else [None, None]


def git_info(directory):
    try:
        revision = subprocess.check_output(
            ["git", "-C", str(directory), "rev-parse", "HEAD"],
            text=True, stderr=subprocess.DEVNULL).strip()
        dirty = bool(subprocess.check_output(
            ["git", "-C", str(directory), "status", "--porcelain"],
            text=True, stderr=subprocess.DEVNULL).strip())
        return {"revision": revision, "dirty": dirty}
    except (OSError, subprocess.CalledProcessError):
        return {"revision": None, "dirty": None}


def perl_info(perl):
    try:
        output = subprocess.check_output(
            [str(perl), "-V:version", "-V:archname", "-V:cc", "-V:optimize"],
            text=True, stderr=subprocess.STDOUT)
        return output.splitlines()
    except (OSError, subprocess.CalledProcessError) as error:
        return [f"unavailable: {error}"]


def summarize(rows, sizes):
    summary = []
    for n in sizes:
        for mode in ("lastowner", "secondowner"):
            for build in ("baseline", "candidate"):
                group = [row for row in rows if row["n"] == n
                         and row["mode"] == mode and row["build"] == build]
                for phase in ("first_round", "reused_rounds"):
                    selected = [row for row in group
                                if (row["round"] == 1) == (phase == "first_round")]
                    if not selected:
                        continue
                    fill = [float(row["fill_ns_per_key"]) for row in selected]
                    teardown = [float(row["teardown_ns_per_key"]) for row in selected]
                    item = {
                        "n": n, "mode": mode, "build": build, "phase": phase,
                        "fill_median_ns_per_key": median(fill),
                        "fill_range_ns_per_key": value_range(fill),
                        "teardown_median_ns_per_key": median(teardown),
                        "teardown_range_ns_per_key": value_range(teardown),
                    }
                    for stage in ("after_fill", "after_clear"):
                        for name in ("capacity", "tombstones", "live"):
                            values = [int(row[f"{stage}_{name}"]) for row in selected
                                      if row[f"{stage}_{name}"] != ""]
                            if values:
                                item[f"{stage}_{name}_median"] = median(values)
                    summary.append(item)

                # Each process contributes one complete-cycle average. This
                # includes every fill and clear in that process's run.
                by_trial = {}
                for row in group:
                    by_trial.setdefault(row["trial"], []).append(row)
                cycle = []
                for trial_rows in by_trial.values():
                    total = sum(float(row["fill_s"]) + float(row["teardown_s"])
                                for row in trial_rows)
                    keys = sum(int(row["n"]) for row in trial_rows)
                    cycle.append(total * 1e9 / keys if keys else 0)
                summary.append({
                    "n": n, "mode": mode, "build": build,
                    "phase": "full_cycle_per_trial_average",
                    "trials": len(cycle),
                    "median_ns_per_key": median(cycle),
                    "range_ns_per_key": value_range(cycle),
                })
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True,
                        help="baseline Perl executable")
    parser.add_argument("--candidate", type=Path, required=True,
                        help="candidate Perl executable")
    parser.add_argument("--lib-baseline", type=Path,
                        help="core lib directory (defaults beside baseline)")
    parser.add_argument("--lib-candidate", type=Path,
                        help="core lib directory (defaults beside candidate)")
    parser.add_argument("--outdir", type=Path, required=True,
                        help="directory for metadata, raw CSV, and summaries")
    parser.add_argument("--sizes", default="100000,1000000",
                        help="comma-separated number of distinct keys")
    parser.add_argument("--rounds-100k", type=int, default=20,
                        help="fill/clear cycles per process for sizes up to 100000")
    parser.add_argument("--rounds-1m", type=int, default=5,
                        help="fill/clear cycles per process for larger sizes")
    parser.add_argument("--trials", type=int, default=5,
                        help="paired fresh-process trials per size and ownership mode")
    parser.add_argument("--seed", default="0x123456789abcdef0",
                        help="PERL_HASH_SEED shared by both builds")
    args = parser.parse_args()

    baseline = args.baseline.resolve()
    candidate = args.candidate.resolve()
    libs = {
        "baseline": (args.lib_baseline or baseline.parent / "lib").resolve(),
        "candidate": (args.lib_candidate or candidate.parent / "lib").resolve(),
    }
    worker = Path(__file__).with_name("bench-strtab.pl").resolve()
    for path in (baseline, candidate, libs["baseline"], libs["candidate"], worker):
        if not path.exists():
            parser.error(f"path does not exist: {path}")
    sizes = [int(value) for value in args.sizes.split(",")]
    if not sizes or any(value <= 0 for value in sizes):
        parser.error("--sizes must contain positive integers")
    if args.trials <= 0 or args.rounds_100k <= 0 or args.rounds_1m <= 0:
        parser.error("trials and round counts must be positive")

    args.outdir.mkdir(parents=True, exist_ok=True)
    metadata = {
        "baseline": str(baseline), "candidate": str(candidate),
        "lib_baseline": str(libs["baseline"]), "lib_candidate": str(libs["candidate"]),
        "worker": str(worker), "worker_sha256": sha256(worker),
        "driver": str(Path(__file__).resolve()), "driver_sha256": sha256(Path(__file__).resolve()),
        "baseline_sha256": sha256(baseline), "candidate_sha256": sha256(candidate),
        "baseline_perl_config": perl_info(baseline),
        "candidate_perl_config": perl_info(candidate),
        "repository": git_info(Path(__file__).resolve().parent.parent),
        "sizes": sizes, "rounds_100k": args.rounds_100k,
        "rounds_1m": args.rounds_1m, "trials": args.trials, "seed": args.seed,
        "modes": ["lastowner", "secondowner"],
        "key_pattern": "strtab-bench-TRIAL-key-INDEX",
        "timed_regions": ["target hash fill", "undef %target teardown"],
        "full_cycle_average": "mean of (fill + clear) ns per inserted key across all process rounds",
        "statistics": "PL_strtab slots and requested index bytes sampled outside timers; RSS is whole-process",
        "started_unix": time.time(),
    }
    (args.outdir / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")

    rng = random.Random(20261103)
    rows = []
    fieldnames = ["trial", "order", "build", "mode", "n", "round",
                  "fill_s", "teardown_s", "fill_ns_per_key", "teardown_ns_per_key",
                  "unique_hek_allocations", "rss_after_fill_kib", "rss_after_clear_kib"]
    for stage in ("before_fill", "after_fill", "after_clear"):
        fieldnames.extend(f"{stage}_{name}" for name in STAT_NAMES)

    with (args.outdir / "raw.csv").open("w", newline="") as raw:
        writer = csv.DictWriter(raw, fieldnames=fieldnames)
        writer.writeheader()
        raw.flush()
        for trial in range(1, args.trials + 1):
            for n in sizes:
                rounds = args.rounds_100k if n <= 100000 else args.rounds_1m
                for mode in ("lastowner", "secondowner"):
                    order = [("baseline", baseline), ("candidate", candidate)]
                    if rng.getrandbits(1):
                        order.reverse()
                    for rank, (build, perl) in enumerate(order):
                        env = os.environ.copy()
                        env.update(PERL_HASH_SEED=args.seed, PERL_PERTURB_KEYS="0")
                        proc = subprocess.run(
                            [str(perl), f"-I{libs[build]}", str(worker), mode,
                             str(n), str(rounds), str(trial)],
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env=env, check=False)
                        if proc.returncode:
                            raise RuntimeError(f"{perl} {mode}/{n} failed: {proc.stderr}")
                        lines = proc.stdout.splitlines()
                        if not lines or not lines[-1].startswith("CHECK\t"):
                            raise RuntimeError(f"incomplete worker result: {proc.stdout[-200:]}")
                        meta = lines[0].split("\t")
                        if len(meta) != 1 + 6 + 16 or meta[0] != "META":
                            raise RuntimeError(f"unexpected worker metadata: {lines[0]!r}")
                        if meta[1] != mode or int(meta[2]) != n or int(meta[3]) != rounds:
                            raise RuntimeError(f"worker parameters differ: {lines[0]!r}")
                        round_lines = [line.split("\t") for line in lines[1:-1]]
                        if len(round_lines) != rounds:
                            raise RuntimeError(f"expected {rounds} rounds, got {len(round_lines)}")
                        check = lines[-1].split("\t")
                        expected_sum = rounds * n * (n - 1) // 2
                        if int(check[1]) != expected_sum or int(check[2]) != 0:
                            raise RuntimeError(f"worker checksum failed: {lines[-1]!r}")
                        if mode == "secondowner" and int(check[3]) != n:
                            raise RuntimeError(f"keeper hash lost keys: {lines[-1]!r}")

                        for parts in round_lines:
                            if len(parts) != 32 or parts[0] != "ROUND":
                                raise RuntimeError(f"unexpected round record: {parts!r}")
                            fill_s, teardown_s = float(parts[2]), float(parts[3])
                            before, filled, cleared = parts[6:14], parts[14:22], parts[22:30]
                            row = {
                                "trial": trial, "order": rank, "build": build,
                                "mode": mode, "n": n, "round": int(parts[1]),
                                "fill_s": fill_s, "teardown_s": teardown_s,
                                "fill_ns_per_key": fill_s * 1e9 / n,
                                "teardown_ns_per_key": teardown_s * 1e9 / n,
                                "unique_hek_allocations": n if mode == "lastowner" else 0,
                                "rss_after_fill_kib": parts[30],
                                "rss_after_clear_kib": parts[31],
                            }
                            for stage, values in (("before_fill", before),
                                                  ("after_fill", filled),
                                                  ("after_clear", cleared)):
                                row.update({f"{stage}_{name}": value
                                            for name, value in zip(STAT_NAMES, values)})
                            writer.writerow(row)
                            raw.flush()
                            rows.append(row)

    summary = summarize(rows, sizes)
    (args.outdir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    for item in summary:
        if item["phase"] != "full_cycle_per_trial_average":
            continue
        print(f"N={item['n']} {item['mode']} {item['build']} full-cycle "
              f"median {item['median_ns_per_key']:.1f} ns/key "
              f"range {item['range_ns_per_key'][0]:.1f}.."
              f"{item['range_ns_per_key'][1]:.1f}")


if __name__ == "__main__":
    main()
