# XPerl hash index benchmarks

This compares XPerl's compact ordinary hashes using integer separate chaining
(SC) and open addressing (OA), with independent entry-array growth in both.
Both retain the pointer-based shared string table and the eight-key linear
path. The workloads use nine-byte ASCII string keys and 32-byte values.

At 300,000 entries, OA requests 15.6 percent less table storage.

Selected paired mean time changes at this size:

- fetch-random: 4.1 percent less elapsed time.
- fetch-shared: 10.3 percent less elapsed time.
- fetch-sequential: 8.5 percent more elapsed time.
- miss: 12.1 percent more elapsed time.
- churn: 3.8 percent more elapsed time.

## Builds and measurement

Run started: Tue Nov 17 13:58:33 2026 UTC. CPU: 11th Gen Intel(R) Core(TM) i7-1185G7 @ 3.00GHz; affinity: CPU 7.

SC: `7dfe51b0a2694d3b1c70ad5c244347b96f279e5f`; `gcc` 13.3.0, `-O3`.

OA: `56947482898c16cce03f195dd2dd0a953daaa59b`; `gcc` 13.3.0, `-O3 -DPERL_HASH_INDEX_OA`.

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

Precision target met: **56/63** cases. Measured pairs per case: **30–120**.

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
| 100 | 2,333 | 2,212 | -5.2% | 121 | 1/1 |
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
| 8 | 0.996 | 0.999 | 1.002* | 1.025 | 0.989 | 1.018 | 1.009 | 0.985 | 1.011 |
| 16 | 0.997 | 0.950 | 0.972 | 0.984 | 1.005 | 0.996 | 0.974 | 1.023 | 0.993 |
| 100 | 0.969 | 0.984 | 0.968 | 1.050 | 0.990 | 1.008 | 0.965 | 1.049 | 1.013 |
| 1,000 | 1.073 | 1.067 | 1.052 | 1.113 | 1.053 | 1.001 | 1.001 | 1.046 | 1.008 |
| 10,000 | 1.051 | 1.066 | 1.042 | 1.167 | 1.053 | 1.009 | 1.020 | 1.108 | 0.996 |
| 100,000 | 0.960 | 0.961* | 0.987 | 1.095* | 0.931 | 1.005* | 0.927* | 0.946* | 0.987 |
| 300,000 | 0.959 | 0.897 | 1.085 | 1.121* | 0.897 | 0.999 | 0.959 | 1.038 | 1.007 |

An asterisk marks a case that stopped without meeting the precision target.

## Detailed estimates at 300,000 entries

| Operation | SC mean ns/op | OA mean ns/op | OA minus SC ns/op | Difference 95% interval | Pairs | Stop |
| --- | ---: | ---: | ---: | --- | ---: | --- |
| fetch-random | 586.10 | 562.22 | -23.88 | [-26.904, -21.025] | 30 | precision |
| fetch-shared | 488.67 | 437.82 | -50.85 | [-58.388, -41.379] | 33 | precision |
| fetch-sequential | 121.37 | 131.63 | +10.25 | [8.776, 11.759] | 30 | precision |
| miss | 137.60 | 153.56 | +15.96 | [13.264, 18.089] | 52 | max_seconds (unmet) |
| exists | 454.16 | 406.93 | -47.23 | [-55.156, -39.269] | 30 | precision |
| iterate | 96.23 | 96.07 | -0.16 | [-1.696, 1.335] | 30 | precision |
| construct | 399.99 | 383.22 | -16.78 | [-22.678, -10.404] | 30 | precision |
| churn | 821.12 | 852.04 | +30.92 | [26.795, 35.325] | 30 | precision |
| query-only | 22.16 | 22.31 | +0.14 | [-0.094, 0.408] | 30 | precision |

## Reproduction and artifacts

Run `planning/scripts/bench-hash-index-xbench.pl` from the SC build with its
core library path, selecting the independent OA build with `--oa`. The
protocol and options are described in [the XBench plan](../xbench.md).

`metadata.json` records source revisions, compiler settings, affinity,
executable hashes, and driver and worker hashes. `raw.jsonl` preserves complete
worker diagnostics, timings, seeds, and phases. `summary.jsonl` preserves each
XBench result, its settings, sample arrays, precision status, and stop reason.

These artifacts and generated figures are in the workspace
`tmp/hash-final-comparison-20261117/` directory.
The earlier fixed-count screening runs are in
`tmp/hash-index-comparison/` and `tmp/hash-index-independent-comparison/`.
Their paired medians use a different estimator and are kept separate.
