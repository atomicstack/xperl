#!/usr/bin/env python3

"""Benchmark SciPy's current directed-SCC implementation.

The edge generator mirrors bench/graph-vs-xgraph.pl so the reported number is
directly comparable with the XGraph SCC rows in the README snapshot.
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


def scc_edge_specs(vertices: int, base_edges: list[tuple[int, int]]) -> list[tuple[int, int]]:
    edges = list(base_edges)
    seen = set(edges)
    block_size = 50
    for start in range(1, vertices + 1, block_size):
        end = min(vertices, start + block_size - 1)
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


def main() -> None:
    if VERTICES < 2:
        raise SystemExit("XGRAPH_BENCH_VERTICES must be at least 2")
    base_edges = edge_specs(VERTICES, EDGES)
    graph = make_graph(VERTICES, scc_edge_specs(VERTICES, base_edges))

    start = time.perf_counter()
    component_count = 0
    for _ in range(ITERATIONS):
        component_count, _labels = connected_components(
            graph, directed=True, connection="strong", return_labels=True
        )
    elapsed = time.perf_counter() - start

    import scipy

    print(f"scipy={scipy.__version__}")
    print(f"vertices={VERTICES} edges={EDGES} iterations={ITERATIONS}")
    print(f"scc_scipy {elapsed:.6f} seconds ({component_count} components)")


if __name__ == "__main__":
    main()
