# `csv`

A CSV reader and writer in pure Mojo, running the same state machine CPython's
`_csv` does — character for character, including the parts that only show up
in malformed input.

```mojo
from csv import reader, writer
```

## Reading

```mojo
var rows = reader('name,city\n"Ada, L",London\n')

len(rows)              # 2
rows[1][0]             # "Ada, L"

for row in reader(text):
    print(row[0])
```

A row is a `List[String]`, and `reader` returns every row at once. `load(file)`
reads a whole file and does the same.

The awkward cases are CPython's, not a simplification of them:

| Input | Reads as |
|-------|----------|
| `a"b,c` | `['a"b', 'c']` — a quote away from the start of a field is data |
| `"ab"cd` | `['abcd']` — data after a closing quote joins the field |
| `"abc` | `['abc']` — an open quote runs to the end of the text |
| `a,b\r1,2` | two rows — a lone `CR` ends a record, as `LF` and `CRLF` do |
| `a,b\n\nc,d` | three rows, the middle one empty |

Under `strict` the two malformed ones — `"ab"cd` and `"abc` — raise instead,
with CPython's wording:

```text
',' expected after '"'
unexpected end of data
```

## Writing

```mojo
var out = writer()
out.writerow(["a", "b"])
out.writerows(rows)
print(out.text())

writes(rows)                # the same thing in one call
dump(rows, file)            # straight into a writer
```

A field is quoted only when its own characters demand it — the delimiter, a
carriage return, a newline, a character of the line terminator, or a quote
that gets doubled. A character that gets *escaped* does not force quotes,
which is why a field holding the escape character comes out escaped and bare.
A row of one empty field is written `""`, because bare it would read back as an
empty row.

## Dialects

CPython passes format parameters as loose keywords and lets a named dialect
fill in the rest. Here they are the fields of one struct:

```mojo
reader(text, Dialect(delimiter=";"))
reader(text, Dialect(quoting=QUOTE_NONE, escapechar="\\"))
writes(rows, unix())
```

`excel()` is the default; `excel_tab()` and `unix()` are the other two
CPython registers. `Dialect` takes `delimiter`, `quotechar`, `escapechar`,
`doublequote`, `skipinitialspace`, `lineterminator`, `quoting`, `strict` and
`field_size_limit`, with `QUOTE_MINIMAL`, `QUOTE_ALL`, `QUOTE_NONNUMERIC` and
`QUOTE_NONE` for the last. Any single character may be a delimiter, a quote or
an escape, `€` included.

## Records

`read_records` and `write_records` are `DictReader` and `DictWriter`. A record
is a `Value` — the type the `json`, `yaml` and `toml` packages share — so its
members keep the header's order and a CSV file crosses into those formats
without conversion:

```mojo
from json import dumps
from csv import read_records

print(dumps(read_records("a,b\n1,2\n")[0]))
# {"a": "1", "b": "2"}
```

A short record is padded with `restval`, a long one puts the surplus under
`restkey`, and a blank line is skipped rather than becoming an empty record.
A record keeps the types its members had, so `QUOTE_NONNUMERIC` writes a
number bare and quotes everything else, exactly as `DictWriter` does.

## Where it differs from CPython

- **A row is text.** `csv.reader` with `QUOTE_NONNUMERIC` puts `float` objects
  in the row; a row here holds strings, so the number is rendered straight
  back the way Python's `str` would write it and `1` reads as `1.0`. The
  conversion itself is Python's whole `float`, Unicode decimal digits and
  Unicode blanks included — `１２` is twelve — so a field that is not a number
  still raises `could not convert string to float: 'a'`.
- **`field_size_limit` is a dialect field**, not the global
  `csv.field_size_limit()` a whole program shares.
- **A long record's surplus fields are dropped** unless `restkey` names a
  place for them. CPython files them under the `None` key of the dict, which
  an object keyed by text has nowhere to put.
- **`Sniffer` and the dialect registry are not implemented.** There is no
  `register_dialect`; build a `Dialect` and pass it.
- **`quotechar=None` requires `QUOTE_NONE`.** CPython accepts the pair with
  any quoting as long as `quoting` is left out of the call, and rejects it the
  moment you pass `quoting` explicitly — an artifact of how it reads keywords
  that there is nothing to reproduce here.
- **The reader takes text, not a line iterator.** It splits lines exactly as
  Python does for a stream opened with `newline=""`, which is what makes the
  two agree; the one error that only a hand-built line iterator can provoke,
  `new-line character seen in unquoted field`, is therefore unreachable.

Everything else is checked against CPython by
`test/csv/test_python_compat.mojo`, which is generated from what `csv`
actually produces — both what each document reads to and what those rows write
back to, across fifteen dialects and roughly sixteen hundred combinations.

## Performance

Against CPython 3.11's `_csv`, which is written in C, on the fixtures in
`bench/csv`:

| Fixture | `reader` | `writer` |
|---------|----------|----------|
| plain (0.47 MiB) | 9.22 ms vs 9.51 ms — **1.0x** | 7.72 ms vs 9.21 ms — **1.2x** faster |
| quoted (0.42 MiB) | 5.91 ms vs 5.59 ms — **0.9x** | 6.04 ms vs 7.22 ms — **1.2x** faster |

Reading is at parity with the C implementation and writing is a little ahead.
Median of three runs on each side, taken back to back on an otherwise idle
4-core x86-64 Linux box — the machine has to be idle, because the two do not
lose the same amount to a busy one.

Reproduce with:

```bash
python3 bench/csv/gen_data.py
mojo run -I src bench/csv/bench_csv.mojo
python3 bench/csv/bench_python.py
```
