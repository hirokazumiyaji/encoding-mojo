# `yaml`

*English · [日本語](README.ja.md)*

A YAML loader and emitter in pure Mojo, built to match PyYAML's `safe_load`
and `safe_dump` — the same function names and keyword arguments, the same
implicit typing, and the same output bytes.

```mojo
from yaml import safe_dump, safe_load
```

Documents load into the `Value` type the [`json`](../json) package uses, so a
YAML document can be dumped as JSON without conversion:

```mojo
from json import dumps
from yaml import safe_load

print(dumps(safe_load("name: mojo\ntags: [fast, safe]\n")))
# {"name": "mojo", "tags": ["fast", "safe"]}
```

## Loading

```mojo
var doc = safe_load("""
name: mojo
version: 1.0
tags:
  - fast
  - safe
nested:
  key: value
""")

doc["name"].string()        # "mojo"
doc["version"].float()      # 1.0
doc["tags"][0].string()     # "fast"
len(doc["nested"])          # 1
```

`safe_load_all(text)` returns every document in a `---`-separated stream;
`safe_load` raises if the stream holds more than one, exactly as PyYAML does.

Supported: block and flow collections, plain, single-quoted, double-quoted,
literal (`|`) and folded (`>`) scalars with their chomping indicators and
explicit indent, comments, document markers, anchors and aliases — including
recursive ones such as `&a [1, *a]` — merge keys (`<<`), and the standard
`!!str`, `!!int`, `!!float`, `!!bool` and `!!null` tags.

A merge key only merges when it is written plain: `'<<': 1` is an ordinary
string key, and the emitter quotes a literal `<<` key so that it round-trips.

Failures raise a `YAMLError` naming the problem and the position:

```text
could not find expected ':'
  in "<unicode string>", line 2, column 6
```

## Implicit typing is YAML 1.1

PyYAML implements YAML 1.1, and this package matches it rather than YAML 1.2.
The differences bite in practice:

| Written  | Loads as       | Note |
|----------|----------------|------|
| `yes`, `off`, `on` | bool | 1.2 has only `true`/`false` |
| `017`    | `15`           | a leading zero means octal |
| `0o17`   | `"0o17"`       | 1.2's octal prefix is not a number in 1.1 |
| `1_000`  | `1000`         | digits may be grouped |
| `1e3`    | `"1e3"`        | an exponent needs an explicit sign, so this is a string |
| `1:30`   | `90`           | base 60; components after the first must be 0-59, so `1:60` is a string |
| `y`, `n` | `"y"`, `"n"`   | single letters are not booleans |

## Dumping

```mojo
safe_dump(doc)                            # block style, keys sorted
safe_dump(doc, sort_keys=False)           # insertion order
safe_dump(doc, indent=4)
safe_dump(doc, default_flow_style=True)   # {a: [1, 2]}
safe_dump(doc, allow_unicode=True)        # UTF-8 straight through
safe_dump(doc, explicit_start=True)       # leading ---
safe_dump_all(documents)                  # a --- separated stream
```

The defaults are PyYAML's, which means keys come out **sorted** and non-ASCII
comes out escaped. Scalars are written plain where that round-trips, single
quoted where it does not, and double quoted when they hold control characters
or escaped non-ASCII. Collections reached more than once get an `&idNNN`
anchor and later occurrences become `*idNNN`.

## Where it differs from PyYAML

- **Mapping keys are always strings.** PyYAML allows any hashable key; a
  `Value` mapping is keyed by text, so a key that resolved to a number,
  boolean or `null` is stored as the text JSON would write for it — `1`,
  `true`, `null`. Documents with non-string keys therefore load, but dump
  with those keys quoted.
- **No date, binary, set or ordered-map types.** `!!timestamp`, `!!binary`,
  `!!set`, `!!omap` and application tags leave their node as it was decoded,
  usually a string. Dates are still quoted when dumped so that reading the
  output back with PyYAML does not turn them into `datetime` objects.
- **Long lines are never wrapped.** PyYAML breaks lines near column 80; this
  emitter writes each scalar on one line. The output is valid YAML and loads
  identically, it is just wider.
- **`%YAML` and `%TAG` directives are not implemented.**
- Nesting is capped at `MAX_DEPTH` (1000) levels.

Everything else is checked against PyYAML by
`test/yaml/test_pyyaml_compat.mojo`, which is generated from PyYAML's actual
output — both what each document loads to and what that value dumps back to.
