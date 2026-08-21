"""A pure-Mojo YAML library with a PyYAML-compatible API.

```mojo
from yaml import safe_dump, safe_load

var doc = safe_load("name: mojo\ntags: [fast, safe]\n")
print(doc["name"].string())
print(safe_dump(doc))
```

Documents load into the same `Value` type the `json` package uses, so a YAML
document can be dumped as JSON without conversion.
"""

from serde import Value as YAMLValue
from serde import ValueType as YAMLType

from .api import safe_dump, safe_dump_all, safe_load, safe_load_all
from .emitter import EmitOptions
from .errors import YAMLError
