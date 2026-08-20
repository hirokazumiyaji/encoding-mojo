"""A fast, pure-Mojo JSON library with a CPython-compatible API.

```mojo
from json import dumps, loads

var doc = loads('{"name": "mojo", "tags": ["fast", "safe"]}')
print(doc["name"].string())
print(dumps(doc, indent=2))
```
"""

from .api import JSONDecoder, JSONEncoder, dump, dumps, load, loads
from .errors import JSONDecodeError
from .hooks import NoNumberHook, NoValueHook, NumberHook, ValueHook
from .encoder import Indent
from .tape import MAX_DEPTH, JSONType
from .value import JSONValue
