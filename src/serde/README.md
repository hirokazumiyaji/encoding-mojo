# `serde`

The document model every format in this repository shares.

A `Value` is `null`, a bool, a number, a string, a sequence or a mapping — the
intersection of what JSON, YAML, TOML and CSV describe. Because there is one
model rather than one per format, values cross formats with no conversion:

```mojo
from json import dumps
from yaml import safe_load

print(dumps(safe_load("name: mojo\ntags: [fast, safe]\n")))
# {"name": "mojo", "tags": ["fast", "safe"]}
```

## The tape

Values do not live in a tree of individually allocated nodes. Every value in a
document lives in one flat arena — a "tape" — made of three arrays:

| Array   | Holds |
|---------|-------|
| `nodes` | one 24-byte record per value: a kind tag and a small union |
| `kids`  | container membership: element indices for arrays, alternating key and value indices for objects |
| `buf`   | the decoded bytes of every string, concatenated |

A document of `n` values therefore costs `O(1)` allocations to build rather
than `O(n)`, and a `Value` is a 12-byte reference-counted handle: the tape plus
one index. Copying a `Value` is a refcount bump, which is what gives Python's
reference semantics — `doc["a"]` shares storage with `doc`, so mutating one
mutates the other.

Objects past 16 members get a hash index, stored in a fourth arena and
described by the object node's otherwise unused numeric field, so lookups never
degrade into a scan.

## What lives here

- `Value` — the handle, with the full Python-style container API.
- `ValueType` — the type tag, which prints as the matching Python type name.
- `MAX_DEPTH` — the nesting limit every recursive walk respects. It also
  serves as cycle detection: values may alias each other within a document, so
  a value spliced into its own subtree is only detectable by noticing that a
  walk never ends.
- The JSON text writer, because JSON is the canonical text form of the model
  and `Value.write_to` needs it. Every format's values therefore print the
  same way.

Most users reach this package through [`json`](../json) or [`yaml`](../yaml)
rather than directly. `json.JSONValue` and `json.JSONType` are aliases for
`Value` and `ValueType`.
