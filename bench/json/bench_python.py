#!/usr/bin/env python3
"""CPython's `json` on the same fixtures, for comparison with bench_json.mojo."""

import json
import os
import statistics
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = ("twitter", "canada", "catalog")
WARMUP = 2
RUNS = 5


def measure(fn):
    samples = []
    for i in range(WARMUP + RUNS):
        start = time.perf_counter_ns()
        fn()
        elapsed = time.perf_counter_ns() - start
        if i >= WARMUP:
            samples.append(elapsed)
    return statistics.median(samples)


def report(name, label, nanos, size):
    mib = size / 1048576
    print(
        "%-10s%-7s%8.4f ms  %8.4f MiB/s"
        % (name, label, nanos / 1e6, mib / (nanos / 1e9))
    )


def main():
    for name in FIXTURES:
        path = os.path.join(HERE, "data", name + ".json")
        with open(path) as fh:
            text = fh.read()
        size = len(text.encode())
        report(name, "parse", measure(lambda: json.loads(text)), size)
        doc = json.loads(text)
        report(
            name,
            "dumps",
            measure(lambda: json.dumps(doc, separators=(",", ":"))),
            size,
        )


if __name__ == "__main__":
    main()
