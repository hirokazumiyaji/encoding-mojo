# json-mojo

Pure-Mojo data-format libraries with Python-compatible APIs. `json` mirrors
CPython's `json` module, `yaml` mirrors PyYAML's `safe_load`/`safe_dump`, and
`toml` mirrors `tomllib` and `tomli_w`; `csv` can land beside them without
anything moving. Mojo's standard library ships none of these.

```mojo
from json import dumps, loads

var doc = loads('{"name": "mojo", "tags": ["fast", "safe"]}')
print(doc["name"].string())        # mojo
print(len(doc["tags"]))            # 2

doc["tags"].append("pure")
print(dumps(doc, indent=2))
```

Every package shares one document model, so values cross formats with no
conversion:

```mojo
from json import dumps
from toml import loads as toml_loads
from yaml import safe_load

print(dumps(safe_load("name: mojo\ntags: [fast, safe]\n")))
# {"name": "mojo", "tags": ["fast", "safe"]}

print(dumps(toml_loads('name = "mojo"\ntags = ["fast", "safe"]\n')))
# {"name": "mojo", "tags": ["fast", "safe"]}
```

## Status

| Package | State | Notes |
|---------|-------|-------|
| [`json`](src/json) | complete | Decoder, encoder, hooks and a mutable document model, checked against CPython's `json` |
| [`yaml`](src/yaml) | complete | Loader and emitter for the YAML 1.1 PyYAML implements, checked against PyYAML |
| [`toml`](src/toml) | complete | TOML 1.0.0 parser and writer, checked against `tomllib` and `tomli_w` |
| [`serde`](src/serde) | complete | The `Value` type and tape every package builds on |
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

And against PyYAML on the fixtures in `bench/yaml`:

| Fixture | `safe_load` | `safe_dump` |
|---------|-------------|-------------|
| config (0.20 MiB) | **61x** faster | **127x** faster |
| records (0.27 MiB) | **57x** faster | **128x** faster |

And against CPython's `tomllib` and `tomli_w` on the fixtures in `bench/toml`:

| Fixture | `loads` | `dumps` |
|---------|---------|---------|
| config (0.20 MiB) | **5.9x** faster | **9.5x** faster |
| records (0.33 MiB) | **6.2x** faster | **11.7x** faster |

Those YAML numbers are against PyYAML's pure-Python backend, which is what is
installed here. PyYAML also ships an optional C backend built on libyaml
(`CSafeLoader`); where that is available the gap is far smaller. The benchmark
script uses the C backend when it can and prints which one ran.

Reproduce with:

```bash
python3 bench/json/gen_data.py       # writes the fixtures once
mojo run -I src bench/json/bench_json.mojo
python3 bench/json/bench_python.py   # the same table for CPython

python3 bench/yaml/gen_data.py
mojo run -I src bench/yaml/bench_yaml.mojo
python3 bench/yaml/bench_python.py

python3 bench/toml/gen_data.py
mojo run -I src bench/toml/bench_toml.mojo
python3 bench/toml/bench_python.py
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
src/serde/           the shared Value type and its flat arena
src/json/            the json package
src/yaml/            the yaml package
src/toml/            the toml package
test/<name>/         each package's tests, one module per area
bench/<name>/        each package's benchmarks, plus the Python baseline
scripts/             test runner, package build, compat-case generators
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

`test/json/test_python_compat.mojo`, `test/yaml/test_pyyaml_compat.mojo` and
`test/toml/test_tomllib_compat.mojo` are generated, not hand-written: the
scripts below run several hundred documents through CPython's `json`, through
PyYAML, and through `tomllib`/`tomli_w`, and record what those produced, so
each suite is a differential test against the reference implementation rather
than against someone's reading of the spec. Add cases to the generators, not
to the generated files:

```bash
python3 scripts/gen_compat_cases.py
python3 scripts/gen_yaml_compat_cases.py
python3 scripts/gen_toml_compat_cases.py
```

The generators need `pyyaml` and `tomli_w` installed.

## License

MIT. See [LICENSE](LICENSE).
