"""A fast, pure-Mojo JSON library with a CPython-compatible API.

```mojo
from json import dumps, loads

var doc = loads('{"name": "mojo", "tags": ["fast", "safe"]}')
print(doc["name"].string())
print(dumps(doc, indent=2))
```
"""

from .api import dumps, loads
from .errors import JSONDecodeError
from .encoder import Indent
from .tape import JSONType
from .value import JSONValue
