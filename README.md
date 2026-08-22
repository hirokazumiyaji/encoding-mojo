# encoding-mojo

*English · [日本語](README.ja.md)*

Data-format encoders and decoders for Mojo, in pure Mojo, with
Python-compatible APIs. Mojo's standard library ships none of these, so each
package here mirrors the Python module people already know: `json` mirrors
CPython's `json`, `yaml` mirrors PyYAML's `safe_load`/`safe_dump`, `toml`
mirrors `tomllib` and `tomli_w`, and `csv` mirrors CPython's `csv`.

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
from csv import read_records
from json import dumps
from toml import loads as toml_loads
from yaml import safe_load

print(dumps(safe_load("name: mojo\ntags: [fast, safe]\n")))
# {"name": "mojo", "tags": ["fast", "safe"]}

print(dumps(toml_loads('name = "mojo"\ntags = ["fast", "safe"]\n')))
# {"name": "mojo", "tags": ["fast", "safe"]}

print(dumps(read_records("name,tags\nmojo,fast\n")[0]))
# {"name": "mojo", "tags": "fast"}
```

## Packages

| Package | State | Notes |
|---------|-------|-------|
| [`json`](src/json) | complete | Decoder, encoder, hooks and a mutable document model, checked against CPython's `json` |
| [`yaml`](src/yaml) | complete | Loader and emitter for the YAML 1.1 PyYAML implements, checked against PyYAML |
| [`toml`](src/toml) | complete | TOML 1.0.0 parser and writer, checked against `tomllib` and `tomli_w` |
| [`csv`](src/csv) | complete | Reader and writer running CPython's own `_csv` state machine |
| [`serde`](src/serde) | complete | The `Value` type and tape every package builds on |

## Documentation

Each package has a hand-written guide, in English and Japanese, covering its
API surface with runnable examples:

| Package | Guide | ガイド |
|---------|-------|--------|
| `json` | [src/json/README.md](src/json/README.md) | [日本語](src/json/README.ja.md) |
| `yaml` | [src/yaml/README.md](src/yaml/README.md) | [日本語](src/yaml/README.ja.md) |
| `toml` | [src/toml/README.md](src/toml/README.md) | [日本語](src/toml/README.ja.md) |
| `csv` | [src/csv/README.md](src/csv/README.md) | [日本語](src/csv/README.ja.md) |
| `serde` | [src/serde/README.md](src/serde/README.md) | [日本語](src/serde/README.ja.md) |

The examples in those guides are executable. `test/json/test_readme_examples.mojo`
and its counterparts for `yaml`, `toml` and `csv` run every snippet a reader
might copy, so a guide that drifts from the code fails the build.

Alongside them, a full API reference is generated from the docstrings in
`src/` — every signature, argument, return value and raised error:

```bash
./scripts/build_docs.sh               # writes docs/api/*.md
./scripts/build_docs.sh --check       # only validate the docstrings
```

`mojo doc` compiles the docstrings into JSON and
`scripts/render_api_docs.py` renders that as Markdown, so the reference cannot
drift from the source. `docs/api/` is generated and not committed; CI rebuilds
it on every push and uploads it as an artifact.

`scripts/check_docstrings.py` is the compiler-free half of the same check. It
needs only Python, and it fails when a public declaration is missing its
docstring, an `Args:` or `Parameters:` entry, a `Returns:`, or a `Raises:`.

## Why it is fast

A parsed document is not a tree of individually allocated nodes. Every value
lives in one flat arena — a "tape" — of fixed-size nodes, plus one array of
child indices and one buffer of decoded string bytes. A document of `n` values
costs `O(1)` allocations instead of `O(n)`, and a `Value` is a 12-byte
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
| config (0.20 MiB) | **6.1x** faster | **10.0x** faster |
| records (0.33 MiB) | **6.5x** faster | **10.0x** faster |

And against CPython's `csv`, which unlike the two above is written in C, on
the fixtures in `bench/csv`:

| Fixture | `reader` | `writer` |
|---------|----------|----------|
| plain (0.47 MiB) | **1.0x** | **1.2x** faster |
| quoted (0.42 MiB) | **0.9x** | **1.2x** faster |

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

python3 bench/csv/gen_data.py
mojo run -I src bench/csv/bench_csv.mojo
python3 bench/csv/bench_python.py
```

## Install

The packages are plain Mojo source. Either point the compiler at `src`:

```bash
mojo run -I /path/to/encoding-mojo/src your_program.mojo
```

or precompile and depend on the package files:

```bash
./scripts/build_packages.sh          # writes build/json.mojoc and friends
mojo run -I build your_program.mojo
```

Requires the Mojo compiler (`pip install modular`); developed against Mojo 1.0.

## Repository layout

```
src/serde/           the shared Value type and its flat arena
src/json/            the json package
src/yaml/            the yaml package
src/toml/            the toml package
src/csv/             the csv package
test/<name>/         each package's tests, one module per area
bench/<name>/        each package's benchmarks, plus the Python baseline
docs/api/            the generated API reference (not committed)
scripts/             test runner, package build, doc build, compat-case generators
```

A new format package follows the same shape: `src/<name>/` with an
`__init__.mojo`, `test/<name>/test_*.mojo`, and `bench/<name>/` if it is worth
measuring. `scripts/run_tests.sh`, `scripts/build_packages.sh` and
`scripts/build_docs.sh` pick it up with no changes.

## Development

The library was written test-first, and the tests are the specification. Run
them all with:

```bash
./scripts/run_tests.sh               # or pass specific files
```

The `*_compat.mojo` suites are generated, not hand-written: the scripts below
run several thousand documents through CPython's `json` and `csv`, through
PyYAML, and through `tomllib`/`tomli_w`, and record what those produced, so
each suite is a differential test against the reference implementation rather
than against someone's reading of the spec. Add cases to the generators, not
to the generated files:

```bash
python3 scripts/gen_compat_cases.py
python3 scripts/gen_yaml_compat_cases.py
python3 scripts/gen_toml_compat_cases.py
python3 scripts/gen_csv_compat_cases.py
```

The generators need `pyyaml` and `tomli_w` installed.

Documentation is part of the build. Before sending a change, run:

```bash
python3 scripts/check_docstrings.py src   # no compiler needed
./scripts/build_docs.sh                   # the full mojo doc pass
```

New public declarations need a docstring with a summary, an entry for every
argument and parameter, and a `Returns:`/`Raises:` where they apply. When a
change alters what a package's README shows, update the Japanese README beside
it, and update `test/<name>/test_readme_examples.mojo` so the examples keep
running.

## License

MIT. See [LICENSE](LICENSE).
