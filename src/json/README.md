# `json`

A JSON decoder, encoder and document model in pure Mojo, built to match
CPython's `json` module — the same function names and keyword arguments, the
same output bytes, and the same error messages.

```mojo
from json import JSONType, JSONValue, dump, dumps, load, loads
```

## Decoding

```mojo
var doc = loads('{"id": 7, "tags": ["a", "b"], "meta": null}')

doc["id"].int()            # 7
doc["tags"][0].string()    # "a"
doc["meta"].is_null()      # True
len(doc)                   # 3
"tags" in doc              # True
```

`loads(text, *, strict=True, allow_nan=True)` takes any `StringSlice`.
`load(file, ...)` reads a `FileHandle` first.

Failures raise a `JSONDecodeError` whose message is CPython's, down to the
position:

```text
Expecting ',' delimiter: line 1 column 8 (char 7)
```

## Encoding

```mojo
dumps(doc)                              # {"id": 7, "tags": ["a", "b"], "meta": null}
dumps(doc, indent=2)                    # pretty, two spaces per level
dumps(doc, indent="\t")                 # pretty, one tab per level
dumps(doc, separators=(",", ":"))       # compact
dumps(doc, sort_keys=True)              # members in codepoint order
dumps(doc, ensure_ascii=False)          # UTF-8 straight through
dumps(doc, allow_nan=False)             # raise instead of writing NaN
```

The defaults are CPython's, so `dumps` puts a space after `,` and `:` unless
you ask for something else. `dump(value, file, ...)` writes into any `Writer` —
a `FileHandle`, a `String`, anything — without buffering the whole document
first. `String(value)` and `print(value)` use the default options.

## Building documents

```mojo
var doc = JSONValue.object()
doc["name"] = "mojo"
doc["scores"] = JSONValue.array()
for i in range(3):
    doc["scores"].append(i * i)
```

`append` and `__setitem__` take `Int`, `Float64`, `Bool`, `StringSlice`, `None`
and `JSONValue`. Arrays support `append`, `extend`, `pop`, `clear`, negative
indexing and item assignment; objects support `get`, `keys`, `values`, `items`,
`pop`, `clear` and `in`.

Iterating follows Python: arrays yield elements, objects yield keys.

```mojo
for tag in doc["tags"]:
    print(tag.string())

for key in doc:
    print(key.string(), "=", doc[key.string()])
```

## Value semantics

A `JSONValue` is a reference-counted handle on a shared document, so
`doc["a"]` aliases `doc` exactly like Python's `dict` and `list` do:

```mojo
var tags = doc["tags"]
tags.append("new")
len(doc["tags"])      # includes "new"
```

The one place this differs from Python: inserting a value that belongs to a
*different* document deep-copies it, because a value cannot span two arenas.
Inserting one from the same document aliases it, as Python would.

`__eq__` compares structurally, numbers compare across `int` and `float`
(`1 == 1.0`, as in Python), and object comparison ignores member order.

## Type reflection

`value.type()` returns a `JSONType` — `NULL`, `BOOL`, `INT`, `FLOAT`, `STRING`,
`ARRAY` or `OBJECT` — which prints as the matching Python type name. The
`is_null`, `is_bool`, `is_int`, `is_float`, `is_number`, `is_string`,
`is_array`, `is_object` and `is_container` predicates cover the same ground.

`INT` and `FLOAT` stay distinct so documents round-trip: `loads("1")` is an int
and `loads("1.0")` is a float, and `dumps` writes each back the way it came.
Unlike Python, `True` is never reported as an int, so `dumps` can tell the two
literals apart.

## Where it differs from CPython

Three deliberate deviations, all of them forced by Mojo's types:

- **Integers wider than 64 bits become floats.** CPython keeps them exact with
  arbitrary-precision integers; there is no such type here.
- **Unpaired surrogate escapes decode to U+FFFD.** CPython can hold a lone
  surrogate in a `str`; Mojo strings are strictly UTF-8, so `"\ud800"` becomes
  the replacement character.
- **Numbers with more than 19 significant digits may round differently.** They
  are normalized to a 19-digit mantissa and an exponent before conversion,
  which is exact for every value a `Float64` can represent distinctly (17
  digits suffice) but can differ by one unit in the last place for longer
  literals.

Not implemented: the `object_hook`, `object_pairs_hook`, `parse_float`,
`parse_int` and `parse_constant` callbacks, and the `skipkeys` and `default`
arguments to `dumps`. Nesting is capped at 1000 levels, near where CPython
raises `RecursionError`.

Everything else is checked against CPython by
`test/json/test_python_compat.mojo`, which is generated from CPython's actual
output rather than written by hand.
