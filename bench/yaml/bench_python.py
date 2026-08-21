#!/usr/bin/env python3
"""PyYAML on the same fixtures, for comparison with bench_yaml.mojo.

PyYAML ships an optional C backend (`CSafeLoader`, built against libyaml). It
is used when available, and the header says which backend ran, because the two
are far apart in speed.
"""

import os
import statistics
import time

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = ("config", "records")
WARMUP = 1
RUNS = 3

Loader = getattr(yaml, "CSafeLoader", yaml.SafeLoader)
Dumper = getattr(yaml, "CSafeDumper", yaml.SafeDumper)


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
    print("backend: %s / %s" % (Loader.__name__, Dumper.__name__))
    for name in FIXTURES:
        path = os.path.join(HERE, "data", name + ".yaml")
        with open(path) as fh:
            text = fh.read()
        size = len(text.encode())
        report(name, "load", measure(lambda: yaml.load(text, Loader=Loader)), size)
        doc = yaml.load(text, Loader=Loader)
        report(name, "dump", measure(lambda: yaml.dump(doc, Dumper=Dumper)), size)


if __name__ == "__main__":
    main()
