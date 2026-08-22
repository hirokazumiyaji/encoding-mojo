#!/usr/bin/env python3
"""CPython on the same fixtures, for comparison with bench_csv.mojo.

CPython's `csv` reader and writer are written in C, so this is the same kind
of comparison the `json` benchmark makes rather than the pure-Python one the
`yaml` and `toml` benchmarks make.
"""

import csv
import io
import os
import statistics
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = ("plain", "quoted")
WARMUP = 1
RUNS = 3


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


def read_all(text):
    return list(csv.reader(io.StringIO(text, newline="")))


def write_all(rows):
    buf = io.StringIO(newline="")
    csv.writer(buf).writerows(rows)
    return buf.getvalue()


def main():
    print("backend: _csv (C)")
    for name in FIXTURES:
        path = os.path.join(HERE, "data", name + ".csv")
        with open(path, newline="") as fh:
            text = fh.read()
        size = len(text.encode())
        report(name, "read", measure(lambda: read_all(text)), size)
        rows = read_all(text)
        report(name, "write", measure(lambda: write_all(rows)), size)


if __name__ == "__main__":
    main()
