"""Load and dump throughput for the fixtures under `bench/yaml/data`.

Run `python3 bench/yaml/gen_data.py` once to create the fixtures, then:

```bash
mojo run -I src bench/yaml/bench_yaml.mojo
```

`bench/yaml/bench_python.py` prints the same table for PyYAML.
"""

from std.io.file import open
from std.time import perf_counter_ns

from yaml import safe_dump, safe_load

comptime _FIXTURES = StaticString("config records")
comptime _WARMUP = 1
comptime _RUNS = 3


def _median(var samples: List[Int]) -> Int:
    """Returns the median of `samples`.

    Args:
        samples: The measurements, which are sorted in place.

    Returns:
        The median measurement.
    """
    sort(samples)
    return samples[len(samples) // 2]


def _pad(var text: String, width: Int) -> String:
    """Right-pads `text` with spaces to `width` bytes.

    Args:
        text: The text to pad.
        width: The target width.

    Returns:
        The padded text.
    """
    while text.byte_length() < width:
        text += " "
    return text^


def _report(label: StringSlice, name: StringSlice, nanos: Int, size: Int):
    """Prints one benchmark line.

    Args:
        label: The operation being measured.
        name: The fixture name.
        nanos: The median duration in nanoseconds.
        size: The document size in bytes.
    """
    var mib = Float64(size) / 1048576.0
    var seconds = Float64(nanos) / 1e9
    print(
        _pad(String(name), 10),
        _pad(String(label), 7),
        _pad(String(Float64(nanos) / 1e6), 10),
        " ms   ",
        _pad(String(mib / seconds), 10),
        " MiB/s",
        sep="",
    )


def main() raises:
    for name in _FIXTURES.split(" "):
        var path = "bench/yaml/data/" + name + ".yaml"
        var text: String
        with open(path, "r") as f:
            text = f.read()
        var size = text.byte_length()

        var load_samples = List[Int]()
        for i in range(_WARMUP + _RUNS):
            var start = perf_counter_ns()
            var doc = safe_load(text)
            var elapsed = perf_counter_ns() - start
            if i >= _WARMUP:
                load_samples.append(elapsed)
            if doc.is_null():
                print("unreachable")
        _report("load", name, _median(load_samples^), size)

        var doc = safe_load(text)
        var dump_samples = List[Int]()
        for i in range(_WARMUP + _RUNS):
            var start = perf_counter_ns()
            var out = safe_dump(doc)
            var elapsed = perf_counter_ns() - start
            if i >= _WARMUP:
                dump_samples.append(elapsed)
            if out.byte_length() == 0:
                print("unreachable")
        _report("dump", name, _median(dump_samples^), size)
