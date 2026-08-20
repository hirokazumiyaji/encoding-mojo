#!/usr/bin/env python3
"""CPython's cost for the same document building as bench_build.mojo."""

import time

N = 200000


def main():
    start = time.perf_counter_ns()
    arr = []
    for i in range(N):
        arr.append(i)
    print("append ints   %.4f ms for %d values" % ((time.perf_counter_ns() - start) / 1e6, len(arr)))

    start = time.perf_counter_ns()
    obj = {}
    for i in range(N // 10):
        obj["key_" + str(i)] = i
    print("set members   %.4f ms for %d members" % ((time.perf_counter_ns() - start) / 1e6, len(obj)))


if __name__ == "__main__":
    main()
