"""A pure-Mojo TOML library with a `tomllib`-compatible API.

`loads` and `load` follow CPython's `tomllib`; `dumps` and `dump` follow
`tomli_w`, the reference writer, down to the output bytes.

```mojo
from toml import dumps, loads

var doc = loads('name = "mojo"\ntags = ["fast", "safe"]\n')
print(doc["name"].string())
print(dumps(doc))
```

Documents load into the same `Value` type the `json` and `yaml` packages use,
so a TOML document can be dumped as JSON or YAML without conversion.
"""

from serde import Value as TOMLValue
from serde import ValueType as TOMLType

from .api import dump, dumps, load, loads
from .errors import TOMLDecodeError
