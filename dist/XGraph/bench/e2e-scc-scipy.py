#!/usr/bin/env python3

"""End-to-end SCC comparison workload for SciPy.

Each iteration constructs a fresh CSR graph, computes SCC labels, converts
those labels into the grouped component-list shape returned by XGraph, and
then releases the result.  CSR construction is intentionally inside the
timed region; the common edge list is prepared before timing starts.
"""

import os
import time

import numpy as np
from scipy.sparse import csr_array
from scipy.sparse.csgraph import connected_components


VERTICES = int(os.environ.get("XGRAPH_BENCH_VERTICES", "2000"))
EDGES = int(os.environ.get("XGRAPH_BENCH_EDGES", "10000"))
ITERATIONS = int(os.environ.get("XGRAPH_BENCH_ITERATIONS", "5"))


def edge_specs(vertices: int, wanted: int) -> list[tuple[int, int]]:
    edges: list[tuple[int, int]] = []
    seen: set[tuple[int, int]] = set()
    for source in range(1, vertices):
        if len(edges) == wanted:
            break
        target = source + 1
        edges.append((source, target))
        seen.add((source, target))

    state = 0x13579BDF
    while len(edges) < wanted:
        state = (1664525 * state + 1013904223) & 0xFFFFFFFF
        source = 1 + state % (vertices - 1)
        state = (1664525 * state + 1013904223) & 0xFFFFFFFF
        target = source + 1 + state % (vertices - source)
        edge = (source, target)
        if edge not in seen:
            seen.add(edge)
            edges.append(edge)
    return edges


def scc_edge_specs(
    vertices: int, base_edges: list[tuple[int, int]]
) -> list[tuple[int, int]]:
    edges = list(base_edges)
    seen = set(edges)
    for start in range(1, vertices + 1, 50):
        end = min(vertices, start + 49)
        for source in range(start, end):
            edge = (source + 1, source)
            if edge not in seen:
                seen.add(edge)
                edges.append(edge)
        edge = (end, start)
        if start != end and edge not in seen:
            seen.add(edge)
            edges.append(edge)
    return edges


def make_graph(vertices: int, edges: list[tuple[int, int]]) -> csr_array:
    rows = np.fromiter((source - 1 for source, _ in edges), dtype=np.int64)
    cols = np.fromiter((target - 1 for _, target in edges), dtype=np.int64)
    data = np.ones(len(edges), dtype=np.int8)
    return csr_array((data, (rows, cols)), shape=(vertices, vertices))


def grouped_components(labels: np.ndarray, count: int) -> list[list[int]]:
    components = [[] for _ in range(count)]
    for vertex, label in enumerate(labels, start=1):
        components[int(label)].append(vertex)
    components.sort(key=lambda members: members[0])
    return components


def main() -> None:
    if VERTICES < 2:
        raise SystemExit("XGRAPH_BENCH_VERTICES must be at least 2")
    if EDGES < 0 or EDGES > VERTICES * (VERTICES - 1) // 2:
        raise SystemExit("XGRAPH_BENCH_EDGES is out of range")
    if ITERATIONS <= 0:
        raise SystemExit("XGRAPH_BENCH_ITERATIONS must be positive")

    base_edges = edge_specs(VERTICES, EDGES)
    edges = scc_edge_specs(VERTICES, base_edges)
    start = time.perf_counter()
    sink = 0

    for _ in range(ITERATIONS):
        graph = make_graph(VERTICES, edges)
        count, labels = connected_components(
            graph, directed=True, connection="strong", return_labels=True
        )
        components = grouped_components(labels, count)
        sink += len(components)

        # Do not retain graph, labels, or grouped members between iterations.
        del components, labels, graph

    elapsed = time.perf_counter() - start
    print(
        f"scipy vertices={VERTICES} scc_edges={len(edges)} "
        f"iterations={ITERATIONS} components={sink} "
        f"total={elapsed:.6f} per_iteration={elapsed / ITERATIONS:.6f}"
    )


if __name__ == "__main__":
    main()
