# json-mojo

Pure-Mojo data-format libraries with CPython-compatible APIs. The first one is
`json`; the layout is a monorepo so `toml`, `yaml` and `csv` can land beside it
without anything moving. Mojo's standard library ships none of these.

```mojo
from json import dumps, loads

var doc = loads('{"name": "mojo", "tags": ["fast", "safe"]}')
print(doc["name"].string())        # mojo
print(len(doc["tags"]))            # 2

doc["tags"].append("pure")
print(dumps(doc, indent=2))
```

## Status

| Package | State | Notes |
|---------|-------|-------|
| [`json`](src/json) | complete | Decoder, encoder, hooks and a mutable document model, checked against CPython's `json` |
| `toml`  | planned | |
| `yaml`  | planned | |
| `csv`   | planned | |

## Why it is fast

A parsed document is not a tree of individually allocated nodes. Every value
lives in one flat arena — a "tape" — of fixed-size nodes, plus one array of
child indices and one buffer of decoded string bytes. A document of `n` values
costs `O(1)` allocations instead of `O(n)`, and a `JSONValue` is a 12-byte
reference-counted handle into that arena.

On top of that: strings are scanned 32 bytes at a time with SIMD and copied in
one `memcpy` when they hold no escapes; numbers accumulate a mantissa during the
same scan and finish with one exactly-rounded multiply; and objects past 16
members get a hash index so lookups never degrade into a scan.

Measured against CPython 3.11's C-accelerated `json` on the fixtures in
`bench/json` (median of 5 runs, 4-core x86-64 Linux):

| Fixture | Shape | `loads` | `dumps` |
|---------|-------|---------|---------|
| twitter (0.47 MiB) | string-heavy | **1.5x** faster | **2.1x** faster |
| canada (0.73 MiB) | float-heavy | **3.2x** faster | **2.0x** faster |
| catalog (0.93 MiB) | object-heavy | **2.1x** faster | **3.0x** faster |

Reproduce with:

```bash
python3 bench/json/gen_data.py       # writes the fixtures once
mojo run -I src bench/json/bench_json.mojo
python3 bench/json/bench_python.py   # the same table for CPython
```

## Install

The packages are plain Mojo source. Either point the compiler at `src`:

```bash
mojo run -I /path/to/json-mojo/src your_program.mojo
```

or precompile and depend on the package file:

```bash
./scripts/build_packages.sh          # writes build/json.mojoc
mojo run -I build your_program.mojo
```

Requires the Mojo compiler (`pip install modular`); developed against Mojo 1.0.

## Repository layout

```
src/json/            the json package
test/json/           its tests, one module per area
bench/json/          its benchmarks, plus the CPython baseline
scripts/             test runner, package build, compat-case generator
```

A new format package follows the same shape: `src/<name>/` with an
`__init__.mojo`, `test/<name>/test_*.mojo`, and `bench/<name>/` if it is worth
measuring. `scripts/run_tests.sh` and `scripts/build_packages.sh` pick it up
with no changes.

## Development

The library was written test-first, and the tests are the specification. Run
them all with:

```bash
./scripts/run_tests.sh               # or pass specific files
```

`test/json/test_python_compat.mojo` is generated, not hand-written:
`scripts/gen_compat_cases.py` runs several hundred documents through CPython's
own `json` and records what it produced, so the suite is a differential test
against the reference implementation rather than against someone's reading of
the spec. Add cases to the generator, not to the generated file:

```bash
python3 scripts/gen_compat_cases.py
```

## License

MIT. See [LICENSE](LICENSE).
