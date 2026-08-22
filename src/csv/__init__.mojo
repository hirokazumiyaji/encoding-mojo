"""A pure-Mojo CSV library with a `csv`-compatible reader and writer.

`reader` runs the same state machine CPython's `_csv` does, character for
character, and the writer produces the same bytes.

```mojo
from csv import reader

for row in reader("a,b\nc,d\n"):
    print(row[0])
```

CPython's loose `fmtparams` keywords are the fields of one `Dialect` here, so
`csv.reader(f, delimiter=";")` is `reader(text, Dialect(delimiter=";"))`.
"""

from .api import dump, load, reader, writer, writes
from .dialect import (
    FIELD_SIZE_LIMIT,
    QUOTE_ALL,
    QUOTE_MINIMAL,
    QUOTE_NONE,
    QUOTE_NONNUMERIC,
    Dialect,
    excel,
    excel_tab,
    unix,
)
from .errors import CSVError
from .records import read_records, write_records
