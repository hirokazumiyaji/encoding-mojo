"""Throughput for building a document value by value.

```bash
mojo run -I src bench/json/bench_build.mojo
```

`bench/json/bench_build.py` prints the same numbers for CPython.
"""

from std.time import perf_counter_ns

from json import JSONValue, dumps

comptime _N = 200000


def main() raises:
    var start = perf_counter_ns()
    var arr = JSONValue.array()
    for i in range(_N):
        arr.append(i)
    var elapsed = perf_counter_ns() - start
    print("append ints  ", Float64(elapsed) / 1e6, "ms for", len(arr), "values")

    start = perf_counter_ns()
    var obj = JSONValue.object()
    for i in range(_N // 10):
        obj["key_" + String(i)] = i
    elapsed = perf_counter_ns() - start
    print("set members  ", Float64(elapsed) / 1e6, "ms for", len(obj), "members")
