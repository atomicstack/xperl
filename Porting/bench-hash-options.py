#!/usr/bin/env python3
"""Compare selectable ordinary-hash policies with checked, paired trials.

See hash-options-benchmark.pod for the manifest and workload definitions.
"""

import argparse
import csv
import hashlib
import json
import os
import platform
import random
import statistics
import subprocess
import time
from pathlib import Path


SEEDS = [0x13579BDF2468ACE0, 0xFEDCBA9876543210, 0x0123456789ABCDEF]
SIZES = [*range(11), 16, 32, 64, 256, 4096, 65536, 131072]
WORKLOADS = ["insert", "assign", "presized", "hit", "random-hit", "miss",
             "mixed", "constant-hit", "replace", "delete", "churn",
             "transitions", "keys", "values", "each"]


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def cases(operations, extra_sizes=()):
    result = []

    def add(workload, n, length=9, **extra):
        result.append(dict(workload=workload, n=n, key_length=length,
                           operations=operations, **extra))

    for n in SIZES:
        for work in WORKLOADS:
            add(work, n)
    for n in (1, 4, 8, 64, 4096):
        for work in WORKLOADS:
            add(work, n, 128)
    for n in (4, 8, 64, 4096, 65536):
        for work in ("keys-holes", "values-holes", "each-holes"):
            add(work, n)
    for n in (0, 1, 2, 3, 4, 5, 8, 9, 64):
        add("many-live", n)
    for n in (8, 64):
        for work in ("hit", "miss", "delete", "churn"):
            add(work, n, distribution="collision")
    # Reservations make the adaptive 8/16/32-bit boundaries exact, rather
    # than guessing them from the live count after geometric growth.
    for reserve in (255, 256, 65535, 65536):
        add("random-hit", 64, reserve=reserve)
    for n in sorted(set(extra_sizes) - set(SIZES)):
        for work in WORKLOADS:
            add(work, n)
    expanded = []
    for case in result:
        for stored in ("interned", "private"):
            queries = ("plain", "interned") if case["workload"] in (
                "hit", "random-hit", "miss", "mixed") else (
                    "constant" if case["workload"] == "constant-hit" else "none",)
            for query in queries:
                expanded.append(dict(case, stored_keys=stored, query_keys=query))
    for i, case in enumerate(expanded):
        case["id"] = i
    return expanded


def quick_case(case):
    work, n = case["workload"], case["n"]
    if case.get("reserve") or case.get("distribution"):
        return False
    if case["key_length"] == 128:
        return work == "random-hit" and n == 8
    return ((work == "random-hit" and n in (1, 2, 4, 5, 8, 9, 256, 65536))
            or (work == "insert" and n in (2, 3, 4, 8, 9))
            or (work in ("miss", "churn") and n in (4, 8)))


def quick_variant(variant, baseline):
    policy = (variant["width"], variant["linear_max"], variant["min_alloc"])
    return variant["name"] == baseline or policy in (
        ("adaptive", 0, 2), ("adaptive", 4, 2), ("adaptive", 8, 2),
        (32, 4, 2), ("adaptive", 4, 4))


def reusable_rows(source, metadata):
    previous = json.loads((source / "metadata.json").read_text())
    for field in ("worker_sha256", "cpu", "seeds", "platform", "machine", "cpu_info"):
        if previous[field] != metadata[field]:
            raise RuntimeError(f"cannot reuse samples with different {field}")
    old_variants = {v["name"]: v for v in previous["manifest"]["variants"]}
    for variant in metadata["manifest"]["variants"]:
        name = variant["name"]
        if name in old_variants and (old_variants[name] != variant
                or previous["binaries"].get(name) != metadata["binaries"][name]):
            raise RuntimeError(f"cannot reuse samples from a different build: {name}")
        if (previous.get("compat", {}).get(name)
                != metadata.get("compat", {}).get(name)):
            raise RuntimeError(f"cannot reuse different benchmark helpers: {name}")
    old_cases = {c["id"]: c for c in previous["cases"]}
    wanted = {c["id"]: c for c in metadata["cases"]}
    for case_id, case in wanted.items():
        if case_id in old_cases and old_cases[case_id] != case:
            raise RuntimeError(f"cannot reuse a different workload: {case_id}")
    selected = []
    for line in (source / "raw.jsonl").read_text().splitlines():
        row = json.loads(line)
        if (row["case"]["id"] in wanted and row["variant"] in metadata["binaries"]
                and row["trial"] < metadata["trials"]):
            selected.append(dict(row, reused_from=str(source)))
    return selected


def summarize(rows, output, baseline):
    grouped = {}
    references = {}
    for row in rows:
        key = row["case"]["id"]
        grouped.setdefault((key, row["variant"]), []).append(row)
        if row["variant"] == baseline:
            references[(key, row["trial"])] = row
    summary = []
    for (case_id, variant), samples in sorted(grouped.items()):
        ratios = []
        for sample in samples:
            reference = references.get((case_id, sample["trial"]))
            if reference:
                ratios.append(reference["ns_per_operation"] / sample["ns_per_operation"])
        times = [s["ns_per_operation"] for s in samples]
        case = samples[0]["case"]
        before = samples[0]["before"]
        summary.append(dict(case_id=case_id, variant=variant,
            workload=case["workload"], n=case["n"], key_length=case["key_length"],
            stored_keys=case["stored_keys"], query_keys=case["query_keys"],
            distribution=case.get("distribution", "ordinary"), reserve=case.get("reserve", 0),
            samples=len(samples), ns_median=statistics.median(times),
            ns_min=min(times), ns_max=max(times),
            speedup_median=statistics.median(ratios) if ratios else None,
            speedup_min=min(ratios) if ratios else None, speedup_max=max(ratios) if ratios else None,
            linear=before["linear"], width=before["index_width"],
            entry_capacity=before["entry_capacity"], table_bytes=before["table_bytes"],
            allocator_bytes=before["allocator_bytes"],
            retained_rss_kb_median=statistics.median(
                s["case"].get("retained_rss_kb", s["rss_kb"].get("VmRSS", 0)) for s in samples)))
    if summary:
        temporary = output / "summary.csv.tmp"
        with temporary.open("w") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(summary[0]))
            writer.writeheader()
            writer.writerows(summary)
        temporary.replace(output / "summary.csv")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--profile", choices=("quick", "full"), default="quick")
    parser.add_argument("--trials", type=int, help="default: 3 for quick, 5 for full")
    parser.add_argument("--operations", type=int, default=200000)
    parser.add_argument("--cpu", type=int, required=True)
    parser.add_argument("--reuse", type=Path, help="reuse matching samples from a previous result directory")
    parser.add_argument("--variants", help="comma-separated variant names; keep the baseline")
    parser.add_argument("--sizes", help="comma-separated key counts; full profile permits additional sizes")
    parser.add_argument("--key-lengths", help="comma-separated key lengths within the selected profile")
    parser.add_argument("--workloads", help="comma-separated workloads within the selected profile")
    parser.add_argument("--smoke", action="store_true", help="check every worker branch before a full run")
    args = parser.parse_args()
    if args.trials is None:
        args.trials = 3 if args.profile == "quick" else 5
    if args.trials < 1 or args.operations < 1:
        parser.error("trials and operations must be positive")
    manifest = json.loads(args.manifest.read_text())
    variants = manifest["variants"]
    if len({v["name"] for v in variants}) != len(variants):
        parser.error("variant names must be unique")
    baseline = manifest["baseline"]
    if baseline not in {v["name"] for v in variants}:
        parser.error("baseline must name a variant")
    if args.variants:
        names = set(args.variants.split(","))
        unknown = names - {v["name"] for v in variants}
        if unknown:
            parser.error(f"unknown variants: {sorted(unknown)}")
        if baseline not in names:
            parser.error("--variants must include the baseline")
        variants = [v for v in variants if v["name"] in names]
    elif args.profile == "quick" and not args.smoke:
        variants = [v for v in variants if quick_variant(v, baseline)]
    manifest = dict(manifest, variants=variants)
    os.sched_setaffinity(0, {args.cpu})
    worker = Path(__file__).with_suffix(".pl").resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    sizes = None
    if args.sizes:
        try:
            sizes = {int(n) for n in args.sizes.split(",")}
        except ValueError:
            parser.error("--sizes must contain comma-separated integers")
        if min(sizes) < 0:
            parser.error("--sizes must be nonnegative")
    workloads = cases(args.operations, sizes or ())
    if args.smoke:
        workloads = [dict(case, operations=1000) for case in workloads
                     if case["n"] in (0, 2, 4) and case["key_length"] == 9]
    elif args.profile == "quick":
        workloads = [case for case in workloads if quick_case(case)]
    if sizes is not None:
        workloads = [case for case in workloads if case["n"] in sizes]
    if args.key_lengths:
        try:
            lengths = {int(n) for n in args.key_lengths.split(",")}
        except ValueError:
            parser.error("--key-lengths must contain comma-separated integers")
        if min(lengths) < 1:
            parser.error("--key-lengths must be positive")
        workloads = [case for case in workloads if case["key_length"] in lengths]
    if args.workloads:
        names = set(args.workloads.split(","))
        workloads = [case for case in workloads if case["workload"] in names]
    if not workloads:
        parser.error("no cases match the requested filters")
    metadata = dict(manifest=manifest, worker_sha256=sha256(worker),
        driver_sha256=sha256(__file__), cases=workloads, trials=args.trials,
        seeds=SEEDS, cpu=args.cpu, platform=platform.platform(),
        machine=platform.machine(), cpu_info=[line for line in Path("/proc/cpuinfo").read_text().splitlines()
            if line.startswith(("model name", "vendor_id", "cpu family", "model\t", "stepping"))],
        binaries={v["name"]: sha256(v["perl"]) for v in variants}, profile=args.profile,
        compat={v["name"]: {name: sha256(Path(v["compat"]) / name) for name in (
            "HashOptionsCompat.xs", "blib/lib/HashOptionsCompat.pm", "blib/arch/auto/HashOptionsCompat/HashOptionsCompat.so")}
            for v in variants if v.get("compat")})
    reused = []
    if args.reuse:
        source = args.reuse.resolve()
        if source == output:
            parser.error("--reuse must name a different result directory")
        reused = reusable_rows(source, metadata)
        metadata["reuse"] = dict(path=str(source),
            metadata_sha256=sha256(source / "metadata.json"),
            raw_sha256=sha256(source / "raw.jsonl"), samples=len(reused))
    metadata_path = output / "metadata.json"
    if metadata_path.exists():
        if json.loads(metadata_path.read_text()) != metadata:
            raise RuntimeError("output directory belongs to a different experiment")
    else:
        metadata_path.write_text(json.dumps(metadata, indent=2) + "\n")
    rows = []
    raw = output / "raw.jsonl"
    if raw.exists():
        rows = [json.loads(line) for line in raw.read_text().splitlines()]
    completed = {(r["trial"], r["case"]["id"], r["variant"]) for r in rows}
    additions = []
    for row in reused:
        identity = (row["trial"], row["case"]["id"], row["variant"])
        if identity not in completed:
            additions.append(row)
            completed.add(identity)
    rows.extend(additions)
    signatures = {}
    for row in rows:
        identity = (row["trial"], row["case"]["id"])
        if signatures.setdefault(identity, row["result_sha256"]) != row["result_sha256"]:
            raise RuntimeError(f"reused results differ between variants: {identity}")
    schedule = [(trial, case) for trial in range(args.trials) for case in workloads]
    random.Random(20261113).shuffle(schedule)
    rng = random.Random(20261114)
    total = len(schedule) * len(variants)
    start = time.monotonic()
    print(f"{len(workloads)} cases, {len(variants)} variants, {args.trials} trials: {total} workers", flush=True)
    with raw.open("a", buffering=1) as handle:
        for row in additions:
            handle.write(json.dumps(row, separators=(",", ":")) + "\n")
        if additions:
            summarize(rows, output, baseline)
            print(f"Reused {len(additions)} samples; {total - len(completed)} remain", flush=True)
        for trial, template in schedule:
            order = list(variants)
            rng.shuffle(order)
            for variant in order:
                identity = (trial, template["id"], variant["name"])
                if identity in completed:
                    continue
                case = dict(template, query_seed=SEEDS[trial % len(SEEDS)] & 0x7fffffff)
                case["expect_width"] = 4 if variant["width"] == 32 else "adaptive"
                case["expect_linear_limit"] = variant["linear_max"]
                case["expect_min_alloc"] = variant["min_alloc"]
                env = os.environ.copy()
                for key in ("PERL5OPT", "PERL5LIB", "PERL_HASH_SEED_DEBUG"):
                    env.pop(key, None)
                env["PERL_HASH_LINEAR_MAX"] = str(variant["linear_max"])
                env["PERL_HASH_SEED"] = f"0x{SEEDS[trial % len(SEEDS)]:016x}"
                env["PERL_PERTURB_KEYS"] = "0"
                perl = Path(variant["perl"]).resolve()
                command = [str(perl), "-Ilib"]
                if variant.get("compat"):
                    compat = Path(variant["compat"])
                    command.extend(["-I" + str(compat / "blib/lib"),
                                    "-I" + str(compat / "blib/arch"), "-MHashOptionsCompat"])
                command.extend([str(worker), json.dumps(case)])
                process = subprocess.run(command,
                    cwd=perl.parent, env=env, text=True, capture_output=True)
                if process.returncode or process.stderr:
                    raise RuntimeError(f"worker {identity} failed: {process.stderr}\n{process.stdout}")
                row = json.loads(process.stdout)
                signature_key = (trial, template["id"])
                signature = signatures.setdefault(signature_key, row["result_sha256"])
                if signature != row["result_sha256"]:
                    raise RuntimeError(f"result differs between variants: {identity}")
                row.update(variant=variant["name"], trial=trial,
                           hash_seed=env["PERL_HASH_SEED"], cpu=args.cpu)
                rows.append(row)
                handle.write(json.dumps(row, separators=(",", ":")) + "\n")
                completed.add(identity)
            if len(rows) % (11 * 5) < len(variants):
                summarize(rows, output, baseline)
                print(f"{len(completed)}/{total} complete; {time.monotonic()-start:.1f}s elapsed", flush=True)
    summarize(rows, output, baseline)
    print(f"Complete: {output / 'summary.csv'}", flush=True)


if __name__ == "__main__":
    main()
