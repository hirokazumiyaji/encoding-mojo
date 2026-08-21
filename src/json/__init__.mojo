"""A fast, pure-Mojo JSON library with a CPython-compatible API.

```mojo
from json import dumps, loads

var doc = loads('{"name": "mojo", "tags": ["fast", "safe"]}')
print(doc["name"].string())
print(dumps(doc, indent=2))
```
"""

from serde import Indent, MAX_DEPTH
from serde import Value as JSONValue
from serde import ValueType as JSONType

from .api import JSONDecoder, JSONEncoder, dump, dumps, load, loads
from .errors import JSONDecodeError
from .hooks import NoNumberHook, NoValueHook, NumberHook, ValueHook
