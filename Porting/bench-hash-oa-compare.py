#!/usr/bin/env python3
"""Run paired, randomized Perl hash benchmark trials and summarize them."""

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


DEFAULT_SIZES = [*range(1, 33), 128, 1000, 10000, 100000, 1000000]
DEFAULT_WORKLOADS = ["hit", "miss", "insert", "delete", "churn",
                     "random-hit", "keys", "values", "each", "keys-holes", "values-holes",
                     "each-holes", "presized", "highholes",
                     "tombstonechurn", "growth-index", "growth-entry"]


def perl_info(perl):
    cwd = Path(perl).resolve().parent
    version = subprocess.check_output([perl, "-Ilib", "-e", "print $^V"],
                                      cwd=cwd, text=True).strip()
    config = subprocess.check_output(
        [perl, "-Ilib", "-MConfig", "-e",
         'print join("\\n", map { "$_=$Config::Config{$_}" } qw(cc ccflags optimize gccversion useithreads))'],
        cwd=cwd, text=True)
    return {"version": version, **dict(line.split("=", 1) for line in config.splitlines())}


def source_info(root):
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=root, text=True).strip()
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
                           stdout=output, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        path.unlink(missing_ok=True)
        return {"path": None, "bytes": None, "sha256": None,
                "kind": "unavailable-no-git-source-tree"}
    data = path.read_bytes()
    return {"path": str(path), "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest()}


def run_worker(perl, script, workload, size, seed, query_seed,
               is_candidate=False, linear_max=None):
    env = os.environ.copy()
    env["PERL_HASH_SEED"] = f"0x{seed:016x}"
    env.pop("PERL_HASH_LINEAR_MAX", None)
    if is_candidate and linear_max is not None:
        env["PERL_HASH_LINEAR_MAX"] = str(linear_max)
    cwd = Path(perl).resolve().parent
    command = [str(Path(perl).resolve()), "-Ilib", str(script), "--worker",
               workload, str(size), str(query_seed)]
    start = time.monotonic()
    result = subprocess.run(command, cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    elapsed = time.monotonic() - start
    if result.returncode:
        raise RuntimeError(f"worker failed {command}:\n{result.stderr}")
    row = next(csv.reader([result.stdout.strip()]))
    fields = ["workload", "n", "repetitions", "operations", "measurement_groups",
              "elapsed_seconds", "seconds_per_batch", "seconds_per_operation",
              "peak_rss_kb", "current_rss_kb", "final_keys", "live", "index_capacity",
              "entry_capacity", "tombstones", "requested_bytes", "allocator_bytes",
              "metadata_bytes", "index_bytes", "entry_bytes", "entry_used",
              "entry_spare", "free_list_length", "index_empty", "index_deleted",
              "probe_total", "probe_max", "probe_mean", "result_signature", "status",
              "event_start_live", "event_index_transitions", "event_entry_transitions",
              "event_validation"]
    if len(row) != len(fields):
        raise RuntimeError(f"unexpected worker CSV ({len(row)} fields): {result.stdout!r}")
    data = dict(zip(fields, row))
    float_fields = {"elapsed_seconds", "seconds_per_batch", "seconds_per_operation", "probe_mean"}
    for field in fields[1:]:
        if data[field] != "":
            if field in {"result_signature", "status", "event_index_transitions",
                         "event_entry_transitions", "event_validation", "event_start_live"}:
                pass
            elif field in float_fields:
                data[field] = float(data[field])
            else:
                data[field] = int(data[field])
    data["worker_wall_seconds"] = elapsed
    return data


def summarize(raw):
    groups = {}
    for row in raw:
        key = (row["workload"], row["n"])
        groups.setdefault(key, []).append(row)
    summary = []
    for (workload, n), rows in sorted(groups.items()):
        by_trial = {}
        for row in rows:
            by_trial.setdefault(row["trial"], {})[row["build"]] = row
        ratios = []
        for pair in by_trial.values():
            a, b = pair.get("baseline"), pair.get("candidate")
            if a and b and a["status"] == "supported" and b["status"] == "supported" \
                    and a["seconds_per_operation"] and b["seconds_per_operation"]:
                same_event = workload not in {"growth-index", "growth-entry"} or \
                    a.get("event_start_live") == b.get("event_start_live")
                if same_event:
                    ratios.append(a["seconds_per_operation"] / b["seconds_per_operation"])
        baseline = [r for r in rows if r["build"] == "baseline" and r["status"] == "supported"]
        candidate = [r for r in rows if r["build"] == "candidate" and r["status"] == "supported"]
        summary.append({
            "workload": workload, "n": n, "paired_trials": len(ratios),
            "median_speedup_baseline_over_candidate": statistics.median(ratios) if ratios else None,
            "speedup_min": min(ratios) if ratios else None,
            "speedup_max": max(ratios) if ratios else None,
            "baseline_ns_per_op_median": median_field(baseline, "seconds_per_operation") * 1e9 if baseline else None,
            "candidate_ns_per_op_median": median_field(candidate, "seconds_per_operation") * 1e9 if candidate else None,
            "baseline_requested_bytes_median": median_field(baseline, "requested_bytes"),
            "baseline_requested_bytes_per_live": median_normalized(baseline, "requested_bytes"),
            "baseline_allocator_bytes_median": median_field(baseline, "allocator_bytes"),
            "baseline_allocator_bytes_per_live": median_normalized(baseline, "allocator_bytes"),
            "baseline_peak_rss_kb_median": median_field(baseline, "peak_rss_kb"),
            "baseline_peak_rss_bytes_per_live": median_normalized(baseline, "peak_rss_kb", 1024),
            "baseline_current_rss_kb_median": median_field(baseline, "current_rss_kb"),
            "baseline_current_rss_bytes_per_live": median_normalized(baseline, "current_rss_kb", 1024),
            "candidate_requested_bytes_median": median_field(candidate, "requested_bytes"),
            "candidate_requested_bytes_per_live": median_normalized(candidate, "requested_bytes"),
            "candidate_allocator_bytes_median": median_field(candidate, "allocator_bytes"),
            "candidate_allocator_bytes_per_live": median_normalized(candidate, "allocator_bytes"),
            "candidate_peak_rss_kb_median": median_field(candidate, "peak_rss_kb"),
            "candidate_peak_rss_bytes_per_live": median_normalized(candidate, "peak_rss_kb", 1024),
            "candidate_current_rss_kb_median": median_field(candidate, "current_rss_kb"),
            "candidate_current_rss_bytes_per_live": median_normalized(candidate, "current_rss_kb", 1024),
            "candidate_supported_trials": len(candidate),
            "growth_events_comparable": (len(ratios) if workload in {"growth-index", "growth-entry"} else None),
        })
    return summary


def median_field(rows, field):
    values = [r[field] for r in rows if r.get(field) not in (None, "")]
    return statistics.median(values) if values else None


def median_normalized(rows, field, scale=1):
    values = [r[field] * scale / r["live"] for r in rows
              if r.get(field) not in (None, "") and r.get("live")]
    return statistics.median(values) if values else None


def cpu_model():
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.lower().startswith("model name"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor()


def parse_sizes(value):
    sizes = []
    for item in value.split(","):
        item = item.strip()
        if not item:
            continue
        match = re.fullmatch(r"(\d+)(?:\.\.|-)(\d+)", item)
        if match:
            first, last = map(int, match.groups())
            sizes.extend(range(first, last + 1))
        else:
            sizes.append(int(item))
    return sizes


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--baseline", required=True, help="absolute path to baseline perl")
    ap.add_argument("--candidate", required=True, help="absolute path to candidate perl")
    ap.add_argument("--outputdir", required=True)
    ap.add_argument("--trials", type=int, default=7)
    ap.add_argument("--sizes", default=",".join(map(str, DEFAULT_SIZES)),
                    help="comma-separated sizes or inclusive ranges such as 1-32")
    ap.add_argument("--workloads", default=",".join(DEFAULT_WORKLOADS))
    ap.add_argument("--seed", type=int, default=20261031)
    ap.add_argument("--linear-max", type=int, choices=(0, 2, 4, 8),
                    help="set candidate PERL_HASH_LINEAR_MAX; omitted means unset")
    args = ap.parse_args()
    output = Path(args.outputdir).resolve()
    output.mkdir(parents=True, exist_ok=True)
    sizes = parse_sizes(args.sizes)
    workloads = [x for x in args.workloads.split(",") if x]
    script = Path(__file__).resolve().with_name("bench-hash-oa.pl")
    builds = {"baseline": Path(args.baseline).resolve(),
              "candidate": Path(args.candidate).resolve()}
    patch_metadata = {}
    build_metadata = {}
    for name, path in builds.items():
        patch = save_source_patch(path.parent, output / "source-patches" / f"{name}.diff")
        patch_metadata[name] = {**patch,
                                "path": (str(Path("source-patches") / f"{name}.diff")
                                         if patch["path"] else None)}
        build_metadata[name] = {"perl": str(path),
                                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                                **perl_info(str(path)), **source_info(path.parent)}
    meta = {"created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "seed": args.seed, "trials": args.trials, "sizes": sizes,
            "workloads": workloads, "script": str(script),
            "kernel": platform.platform(), "machine": platform.machine(),
            "cpu": cpu_model(), "python": sys.version,
            "worker": {"path": str(script),
                       "sha256": hashlib.sha256(script.read_bytes()).hexdigest()},
            "driver": {"path": str(Path(__file__).resolve()),
                       "sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()},
            "source_patches": patch_metadata, "builds": build_metadata,
            "runtime_environment": {
                "baseline_PERL_HASH_LINEAR_MAX": "unset",
                "candidate_PERL_HASH_LINEAR_MAX": args.linear_max}}
    with (output / "metadata.json").open("w") as f:
        json.dump(meta, f, indent=2, sort_keys=True)
        f.write("\n")
    raw = []
    raw_file = (output / "raw.csv").open("w", newline="")
    writer = None
    order_rng = random.Random(args.seed)
    for trial in range(args.trials):
        for workload in workloads:
            for size in sizes:
                pair_seed = order_rng.getrandbits(64)
                query_seed = order_rng.getrandbits(32)
                order = ["baseline", "candidate"]
                order_rng.shuffle(order)
                pair = {}
                for run_order, build in enumerate(order, 1):
                    row = run_worker(str(builds[build]), script, workload, size,
                                     pair_seed, query_seed,
                                     is_candidate=(build == "candidate"),
                                     linear_max=args.linear_max)
                    row.update(build=build, trial=trial + 1, run_order=run_order,
                               hash_seed=f"0x{pair_seed:016x}", query_seed=query_seed,
                               linear_max=(args.linear_max if build == "candidate" else ""))
                    pair[build] = row
                    raw.append(row)
                    if writer is None:
                        writer = csv.DictWriter(raw_file, fieldnames=sorted(row))
                        writer.writeheader()
                    writer.writerow(row)
                    raw_file.flush()
                if not workload.startswith("growth-") and workload not in {"growth-index", "growth-entry"}:
                    if pair["baseline"]["final_keys"] != pair["candidate"]["final_keys"]:
                        raise RuntimeError(f"final key count differs for {workload}/{size}/trial {trial + 1}")
                    if pair["baseline"].get("result_signature") != pair["candidate"].get("result_signature"):
                        raise RuntimeError(f"result signature differs for {workload}/{size}/trial {trial + 1}")
                print(f"{trial + 1}/{args.trials} {workload}/{size} done", file=sys.stderr)
    raw_file.close()
    with (output / "summary.json").open("w") as f:
        json.dump(summarize(raw), f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
