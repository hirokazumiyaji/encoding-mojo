#!/usr/bin/env python3
"""CPython on the same fixtures, for comparison with bench_toml.mojo.

Loading uses the standard library's `tomllib`, whose parser is pure Python.
Writing uses `tomli_w`, the reference this library's `dumps` matches.
"""

import os
import statistics
import time
import tomllib

import tomli_w

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = ("config", "records")
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


def main():
    print("backend: tomllib / tomli_w")
    for name in FIXTURES:
        path = os.path.join(HERE, "data", name + ".toml")
        with open(path) as fh:
            text = fh.read()
        size = len(text.encode())
        report(name, "load", measure(lambda: tomllib.loads(text)), size)
        doc = tomllib.loads(text)
        report(name, "dump", measure(lambda: tomli_w.dumps(doc)), size)


if __name__ == "__main__":
    main()
