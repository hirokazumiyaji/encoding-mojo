# `toml`

A TOML 1.0.0 parser and writer in pure Mojo, built to match the reference
Python implementations: `loads`/`load` follow CPython's `tomllib`, and
`dumps`/`dump` follow [`tomli_w`](https://pypi.org/project/tomli-w/), down to
the output bytes.

```mojo
from toml import dumps, loads
```

Documents load into the `Value` type the [`json`](../json) and
[`yaml`](../yaml) packages use, so a TOML document can be dumped as JSON
without conversion:

```mojo
from json import dumps as json_dumps
from toml import loads

print(json_dumps(loads('name = "mojo"\ntags = ["fast", "safe"]\n')))
# {"name": "mojo", "tags": ["fast", "safe"]}
```

## Loading

```mojo
var doc = loads("""
title = "example"

[owner]
name = "Tom"
dob = 1979-05-27

[servers.alpha]
ip = "10.0.0.1"
ports = [8001, 8002]
""")

doc["title"].string()               # "example"
doc["owner"]["name"].string()       # "Tom"
doc["servers"]["alpha"]["ports"][0].int()   # 8001
```

`load(file)` reads a whole file and decodes it.

Supported: bare, quoted and dotted keys; basic, literal and both multi-line
string forms with every escape TOML defines; decimal, hexadecimal, octal and
binary integers with `_` separators; floats including `inf` and `nan`;
booleans; arrays, inline tables, `[table]` headers and `[[array of table]]`
headers; comments; and CRLF line endings.

The rules that make TOML strict are enforced too: a key cannot be defined
twice, a `[table]` cannot be declared twice or after a dotted key already
built it, an inline table can never be extended, and a statically defined
array can never be appended to.

Failures raise a `TOMLDecodeError` naming the problem and the position, in the
same shape `tomllib` uses:

```text
Cannot overwrite a value (at line 2, column 6)
```

## Dumping

```mojo
dumps(doc)                             # tomli_w's defaults
dumps(doc, indent=2)                   # narrower arrays
dumps(doc, multiline_strings=True)     # """ ... """ for strings with newlines
dump(doc, file)                        # straight into a writer
```

The output is `tomli_w`'s: members keep the order they were inserted rather
than being sorted, the scalar keys of a table come before its `[sub.table]`
sections, an empty parent table collapses into its child's header, arrays are
always spread over several lines with a trailing comma, and an array of tables
is written as an array of inline tables unless one of them would be wider than
100 characters or hold a line break — then it becomes `[[name]]` sections.

The document handed to `dumps` must be a table; anything else raises.

## Where it differs from `tomllib`

- **No date or time types.** `tomllib` returns `datetime`, `date` and `time`
  objects; a `Value` has no such type, so `dob = 1979-05-27` loads as the
  string `"1979-05-27"` with its literal spelling preserved. The syntax is
  still validated, and dumping writes the value back as a quoted string, so a
  round trip through this package turns a date into a string.
- **Integers are 64-bit.** TOML requires at least a signed 64-bit range;
  a literal outside it is rejected rather than promoted.
- **`loads` takes text, not bytes.** `tomllib.load` reads a binary file
  because it decodes UTF-8 itself; here the file is read as text first.
- Nesting is capped at `MAX_DEPTH` (1000) levels.

Everything else is checked against the reference by
`test/toml/test_tomllib_compat.mojo`, which is generated from what `tomllib`
and `tomli_w` actually produce — both what each document loads to and what
that value writes back to.

## Performance

Against CPython 3.11's `tomllib` (a pure-Python parser) and `tomli_w` on the
fixtures in `bench/toml`:

| Fixture | `loads` | `dumps` |
|---------|---------|---------|
| config (0.20 MiB) | **5.9x** faster | **9.5x** faster |
| records (0.33 MiB) | **6.2x** faster | **11.7x** faster |

Reproduce with:

```bash
python3 bench/toml/gen_data.py
mojo run -I src bench/toml/bench_toml.mojo
python3 bench/toml/bench_python.py
```
