"""The document model every format in this repository shares.

A `Value` is `null`, a bool, a number, a string, a sequence or a mapping — the
intersection of what JSON, YAML, TOML and CSV describe. Because the model is
shared, values move between formats without conversion:

```mojo
from json import dumps
from yaml import safe_load

print(dumps(safe_load("name: mojo\ntags: [fast, safe]")))
```

Values live in a flat arena (a "tape") rather than a tree of individually
allocated nodes, so a document costs `O(1)` allocations to build and a `Value`
is a 12-byte reference-counted handle into it.
"""

from .json_text import EncodeOptions, Indent, write_default, write_value
from .tape import (
    MAX_DEPTH,
    ValueType,
    _Node,
    _Tape,
    _bytes_equal,
    _reserve_extra,
)
from .value import Value
