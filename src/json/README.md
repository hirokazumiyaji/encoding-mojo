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

`loads(text, *, strict=True, allow_nan=True)` takes a `StringSlice` or UTF-8
bytes, the way CPython's takes `str` or `bytes`. `load(file, ...)` reads a
`FileHandle` first.

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
`update`, `setdefault`, `pop`, `clear` and `in`.

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

## Reusable settings

`JSONEncoder` and `JSONDecoder` hold a configuration so it is resolved once
rather than per call, mirroring CPython's classes of the same names:

```mojo
var encoder = JSONEncoder(indent=2, sort_keys=True)
for doc in documents:
    print(encoder.encode(doc))

var decoder = JSONDecoder(strict=False)
var parsed = decoder.decode(text)
```

`encoder.write_into(writer, value)` streams instead of returning a `String`.

`decoder.raw_decode(text, idx)` decodes one value and reports where it ended,
which is how you read documents concatenated in one buffer:

```mojo
var text = String('{"a":1}{"b":2}')
var first, after = JSONDecoder().raw_decode(text)
var second, _ = JSONDecoder().raw_decode(text, after)
```

Like CPython's, it does not skip whitespace before the value, and it leaves
trailing whitespace unconsumed.

## Hooks

`parse_int`, `parse_float`, `parse_constant` and `object_hook` are here, but as
compile-time type parameters rather than runtime callables — Mojo cannot put a
function in an `Optional`. A hook is a type implementing `NumberHook` or
`ValueHook`:

```mojo
from json import JSONValue, NumberHook, loads


struct KeepLiteral(NumberHook):
    @staticmethod
    def call(text: String) raises -> JSONValue:
        return JSONValue(text)


# Integers wider than 64 bits normally widen to floats; this keeps them exact.
var doc = loads[ParseInt=KeepLiteral]("123456789012345678901234567890")
```

`ObjectHook` is a `ValueHook` called as each object completes, innermost first,
and is handed a standalone document it may keep or mutate freely. Leaving a
hook at its default costs nothing: the decoder branches on the type at compile
time, so the unused path is never emitted.

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

The first two have an escape hatch: a `ParseInt` or `ParseFloat` hook that
returns the literal as a string keeps any value exactly, and `ParseConstant`
can reject what you do not want to accept.

Three CPython arguments are absent because they cannot mean anything here.
`skipkeys` skips dict keys that are not strings or numbers, but a JSON object's
keys are always strings. `default` supplies a fallback for objects that are not
serializable, but every value a `JSONValue` can hold already is.
`object_pairs_hook` exists in CPython mainly to preserve member order or spot
duplicate keys, both of which this library does on its own.

## Limits

Containers may nest up to `MAX_DEPTH` (1000) levels. The parser is iterative
and could go deeper, but `dumps`, structural equality and cross-document
copying all walk a document recursively, so anything deeper would overflow the
machine stack; CPython gives up at a comparable depth with `RecursionError`.

The same limit doubles as cycle detection. Values alias each other within a
document, so a value spliced into its own subtree is reachable:

```mojo
var doc = JSONValue.object()
doc["self"] = doc
_ = dumps(doc)     # raises: Circular reference detected, or nesting deeper...
```

Everything else is checked against CPython by
`test/json/test_python_compat.mojo`, which is generated from CPython's actual
output rather than written by hand.
