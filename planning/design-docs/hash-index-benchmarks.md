# XPerl hash index benchmarks

This compares XPerl's compact ordinary hashes using integer separate chaining
(SC) and open addressing (OA), with independent entry-array growth in both.
Both retain the pointer-based shared string table and the eight-key linear
path. The workloads use nine-byte ASCII string keys and 32-byte values.

At 300,000 entries, OA requests 15.6 percent less table storage.

Selected paired mean time changes at this size:

- fetch-random: 3.5 percent less elapsed time.
- fetch-shared: 15.2 percent less elapsed time.
- fetch-sequential: 8.5 percent more elapsed time.
- miss: 16.3 percent more elapsed time.
- churn: 5.2 percent more elapsed time.

## Builds and measurement

Run started: Mon Nov 16 23:25:53 2026 UTC. CPU: 11th Gen Intel(R) Core(TM) i7-1185G7 @ 3.00GHz; affinity: CPU 7.

SC: `4a2fa72700d8755929011ef7c8a371af8a7ed790`; `gcc` 13.3.0, `-O3`.

OA: `2b08eb49c5dabe48e5b6b844081746b4d5a533d5`; `gcc` 13.3.0, `-O3 -DPERL_HASH_INDEX_OA`.

XBench controls paired measurements using reported worker-loop durations.
OA is the measured case and SC is its paired baseline. Execution order
alternates. Each pair uses the same hash seed and operation count. Worker
startup, key preparation, warmup, and storage diagnostics are outside timing.
Pilots choose a common operation count lasting at least 0.1 seconds in both builds.

The primary estimate is paired mean OA minus SC time per operation. XBench targets
a maximum distance from this mean to either 95.0% bootstrap bound within 2.0%
of the SC pilot time. It collects at least 30 pairs, with limits of 120 pairs
or 60 seconds per case. Filtering is disabled. XStats supplies the intervals using
4,000 resamples. Every pilot and measured sample is retained.

Precision target met: **63/63** cases. Measured pairs per case: **30–94**.

The initial pass met its target in 61/63 cases. Longer-batch follow-ups are marked (R):

- 100000/fetch-shared: at least 40 pairs; pilots of at least 0.5 seconds; limits of 200 pairs or 180 seconds; `../tmp/hash-index-xbench-followups/100000-fetch-shared`.
- 300000/miss: at least 40 pairs; pilots of at least 0.5 seconds; limits of 200 pairs or 180 seconds; `../tmp/hash-index-xbench-followups/300000-miss`.

Precision met describes interval width, not a resolved advantage. A difference
interval containing zero does not establish a direction. Ratios below are
means of paired OA/SC elapsed-time ratios: below one favors OA. These differ
from the ratio of the separately reported per-build means. Intervals describe
observed batch variability on this machine. CPU frequency is uncontrolled,
and bootstrap coverage is affected by correlation and adaptive stopping.

## Initial populated storage

Requested bytes include index metadata, bucket slots, chain links, and the
allocated entry array, including unused capacity. Common HV bodies, key and
value allocations, and allocator rounding are additional. These snapshots
describe an incrementally populated hash before timed warmup; churn snapshots
are retained separately in raw data.

| Entries | SC bytes | OA bytes | OA change | Entry capacity in both | SC/OA index bytes per slot |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 8 | 128 | 128 | +0.0% | 8 | 0/0 |
| 16 | 358 | 340 | -5.0% | 18 | 1/1 |
| 100 | 2,333 | 2,468 | +5.8% | 121 | 1/2 |
| 1,000 | 24,150 | 21,924 | -9.2% | 1,113 | 2/2 |
| 10,000 | 219,124 | 198,420 | -9.4% | 10,352 | 2/2 |
| 100,000 | 3,458,616 | 2,976,612 | -13.9% | 120,501 | 4/4 |
| 300,000 | 9,451,912 | 7,980,964 | -15.6% | 367,737 | 4/4 |

The eight-entry case uses linear storage and has no bucket index.

At larger sizes, the previous partly coupled OA policy happened to leave less
entry slack at some sampled counts. Independent growth can therefore increase
OA storage relative to that policy. Matching capacities makes the SC/OA
comparison easier to interpret; it does not minimize every allocation.

## Paired mean time ratios

Ratios above one mean OA takes longer. Construction includes destruction of
each newly populated hash. A churn operation deletes and reinserts a key.
Iteration measures each visited entry. Fetches use byte-string queries except
`fetch-shared`, whose query scalars hold shared keys. The query-only control
loops over query lengths without looking up a hash entry.

| Entries | fetch-random | fetch-shared | fetch-sequential | miss | exists | iterate | construct | churn | query-only |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 8 | 0.995 | 0.996 | 1.004 | 0.992 | 0.999 | 1.008 | 1.019 | 0.984 | 1.006 |
| 16 | 0.982 | 1.010 | 0.952 | 1.041 | 0.989 | 1.008 | 0.985 | 1.070 | 0.988 |
| 100 | 0.989 | 0.997 | 0.990 | 1.042 | 1.000 | 1.007 | 1.009 | 1.098 | 0.997 |
| 1,000 | 1.047 | 1.043 | 1.046 | 1.085 | 1.046 | 1.020 | 1.035 | 1.096 | 0.975 |
| 10,000 | 1.062 | 1.080 | 1.047 | 1.143 | 1.072 | 1.015 | 1.056 | 1.136 | 0.978 |
| 100,000 | 0.969 | 0.937 (R) | 0.977 | 1.088 | 0.947 | 1.019 | 0.969 | 0.968 | 0.983 |
| 300,000 | 0.965 | 0.848 | 1.085 | 1.163 (R) | 0.900 | 1.011 | 0.990 | 1.052 | 0.987 |

## Detailed estimates at 300,000 entries

| Operation | SC mean ns/op | OA mean ns/op | OA minus SC ns/op | Difference 95% interval | Pairs | Stop |
| --- | ---: | ---: | ---: | --- | ---: | --- |
| fetch-random | 584.53 | 563.54 | -20.99 | [-29.373, -12.686] | 30 | precision |
| fetch-shared | 499.94 | 423.03 | -76.91 | [-86.389, -67.851] | 30 | precision |
| fetch-sequential | 123.31 | 133.60 | +10.29 | [8.099, 12.627] | 33 | precision |
| miss | 131.83 | 153.10 | +21.27 | [18.531, 24.036] | 40 | precision |
| exists | 447.62 | 402.65 | -44.97 | [-50.717, -39.101] | 30 | precision |
| iterate | 91.91 | 92.91 | +1.00 | [-0.234, 2.227] | 30 | precision |
| construct | 392.07 | 387.34 | -4.72 | [-12.307, 2.982] | 46 | precision |
| churn | 821.92 | 864.19 | +42.28 | [33.148, 51.359] | 30 | precision |
| query-only | 22.69 | 22.36 | -0.33 | [-0.750, 0.102] | 55 | precision |

## Reproduction and artifacts

Run `planning/scripts/bench-hash-index-xbench.pl` from the SC build with its
core library path, selecting the independent OA build with `--oa`. The
protocol and options are described in [the XBench plan](../xbench.md).

`metadata.json` records source revisions, compiler settings, affinity,
executable hashes, and driver and worker hashes. `raw.jsonl` preserves complete
worker diagnostics, timings, seeds, and phases. `summary.jsonl` preserves each
XBench result, its settings, sample arrays, precision status, and stop reason.

These artifacts and generated figures are in the workspace
`tmp/hash-index-xbench/` directory. The earlier fixed-count screening runs are
in `tmp/hash-index-comparison/` and `tmp/hash-index-independent-comparison/`.
Their paired medians use a different estimator and are kept separate.
