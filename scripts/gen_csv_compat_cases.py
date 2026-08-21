#!/usr/bin/env python3
"""Regenerates `test/csv/test_python_compat.mojo` from CPython's `csv`.

Every case is decided by running CPython here, so the generated file is a
differential test: it asserts that this library agrees with the reference
implementation on what a document reads to, on what those rows write back to,
and on which documents are rejected.

Run it after changing the case list:

```bash
python3 scripts/gen_csv_compat_cases.py
```
"""

import csv
import io
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "test", "csv", "test_python_compat.mojo")

CR = "\r"
LF = "\n"
TAB = "\t"

# Each dialect is (mojo expression, csv keyword arguments).
DIALECTS = [
    ("Dialect()", {}),
    ("excel_tab()", {"delimiter": "\t"}),
    ("unix()", {"lineterminator": "\n", "quoting": csv.QUOTE_ALL}),
    ('Dialect(delimiter=";")', {"delimiter": ";"}),
    ('Dialect(delimiter="|")', {"delimiter": "|"}),
    ("Dialect(skipinitialspace=True)", {"skipinitialspace": True}),
    ('Dialect(quotechar="\'")', {"quotechar": "'"}),
    ('Dialect(escapechar="\\\\")', {"escapechar": "\\"}),
    ("Dialect(doublequote=False)", {"doublequote": False}),
    (
        'Dialect(doublequote=False, escapechar="\\\\")',
        {"doublequote": False, "escapechar": "\\"},
    ),
    (
        'Dialect(quoting=QUOTE_NONE, escapechar="\\\\")',
        {"quoting": csv.QUOTE_NONE, "escapechar": "\\"},
    ),
    ("Dialect(quoting=QUOTE_ALL)", {"quoting": csv.QUOTE_ALL}),
    ('Dialect(lineterminator="\\n")', {"lineterminator": "\n"}),
    ('Dialect(delimiter="\\u20ac")', {"delimiter": "€"}),
    (
        "Dialect(quoting=QUOTE_NONNUMERIC)",
        {"quoting": csv.QUOTE_NONNUMERIC},
    ),
]

DOCUMENTS = [
    # Shapes.
    "a,b,c\n1,2,3\n",
    "a,b\n1,2",
    "",
    "\n",
    "\n\n",
    "a,b\n\nc,d\n",
    ",,\n",
    "a,b,\n",
    ",a\n",
    "a\n",
    # Line endings.
    "a,b\r\n1,2\r\n",
    "a,b\r1,2\r",
    "a\r\rb\n",
    "a\n\rb\n",
    "a\r",
    "a\n\r\n",
    "\r\n\r\n",
    # Quotes.
    '"a","b"\n',
    '"a,b",c\n',
    '"a\nb",c\n',
    '"a\rb"\n',
    '"a\r\nb"\n',
    '"a\r\rb"\n',
    '""\n',
    '"a""b"\n',
    '""""\n',
    '"""a"""\n',
    'a"b,c\n',
    'ab"c"d\n',
    '"ab"cd\n',
    '"abc\n',
    '"a',
    '"a"\n"b"\n',
    ',""\n',
    '"",\n',
    '" a ",b\n',
    # Whitespace.
    "a, b\n",
    " \n",
    'a, "b"\n',
    "  a  ,  b  \n",
    "\ta\t,b\n",
    # Delimiters and escapes.
    "a;b\n",
    "a|b\n",
    "a\tb\n",
    "a\\,b,c\n",
    '"a\\"b",c\n',
    "a\\\nb\n",
    "a\\",
    "a\\\\b\n",
    "'a,b',c\n",
    "a€b\n",
    'a€"b€c"\n',
    # Odd but legal bytes.
    "a\x00b,c\n",
    "a\x01b,c\n",
    "café,日本語\n",
    "é\"a\",b\n",
    # Numbers, for the dialect that reads unquoted fields as floats.
    "1,2.5\n-3e2,1_0\n",
    '1,"a"\n',
    "0,00,1e400,inf,nan\n",
    " 1 ,+2\n",
    ".5,5.\n",
    ',""\n',
    "1,\n",
    # Longer documents.
    "id,name,note\n1,alice,\"says \"\"hi\"\"\"\n2,bob,\"two\nlines\"\n3,carol,\n",
    "a,b\r\nc,d\n\ne,f\r",
]

BAD_STRICT = [
    '"a"b,c\n',
    '"a',
    '"a\n',
    '"a"x\n',
]


def rows_of(text, kw):
    """Returns CPython's rows, or None if it rejects the document."""
    try:
        return [
            [x if isinstance(x, str) else str(x) for x in row]
            for row in csv.reader(io.StringIO(text, newline=""), **kw)
        ]
    except Exception:
        return None


def written(rows, kw):
    """Returns what CPython writes for `rows`, or None if it refuses."""
    buf = io.StringIO(newline="")
    try:
        writer = csv.writer(buf, **kw)
        for row in rows:
            writer.writerow(row)
    except Exception:
        return None
    return buf.getvalue()


def random_documents(count=55):
    """Builds pseudo-random documents out of the pieces above."""
    rng = random.Random(20260821)
    pieces = [
        "a", "b", "", " ", "  x  ", '"q"', '"a,b"', '"a""b"', '"a\nb"',
        '"a\rb"', 'x"y', '"ab"cd', "a\\b", "a\\", "\\", "'q'", ";", "|",
        "\t", "café", "€", "\x00", "1", "2.5", "-3e2", "inf",
        '""', '"', "a b", ",", "日本",
    ]
    enders = ["\n", "\r\n", "\r", ""]
    out = []
    seen = set()
    guard = 0
    while len(out) < count and guard < count * 40:
        guard += 1
        lines = []
        for _ in range(rng.randrange(1, 5)):
            fields = [rng.choice(pieces) for _ in range(rng.randrange(0, 4))]
            lines.append(rng.choice([",", ";", "|", "\t"]).join(fields))
        text = ""
        for line in lines:
            text += line + rng.choice(enders)
        if text in seen:
            continue
        seen.add(text)
        out.append(text)
    return out


def mojo_str(text):
    """Renders `text` as a Mojo string literal."""
    out = ['"']
    for ch in text:
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif ord(ch) < 0x20 or ord(ch) == 0x7F:
            out.append("\\x%02x" % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def render(rows):
    """Renders rows the way the generated `_render` helper does."""
    return (
        "["
        + ", ".join(
            "[" + ", ".join("'" + f + "'" for f in row) + "]" for row in rows
        )
        + "]"
    )


def main():
    cases = []
    skipped = 0
    for text in DOCUMENTS + random_documents():
        for expr, kw in DIALECTS:
            rows = rows_of(text, kw)
            if rows is None:
                skipped += 1
                continue
            if any("'" in field for row in rows for field in row):
                # The rendering below quotes fields with `'`.
                skipped += 1
                continue
            out = written(rows, kw)
            if out is None:
                skipped += 1
                continue
            cases.append((text, expr, render(rows), out))

    bad = []
    for text in BAD_STRICT:
        try:
            list(csv.reader(io.StringIO(text, newline=""), strict=True))
        except csv.Error:
            bad.append(text)
        else:
            print("skipping (CPython accepts it under strict): %r" % text)

    lines = [
        '"""Differential tests against CPython\'s `csv`.',
        "",
        "Generated by `scripts/gen_csv_compat_cases.py`, which runs every case",
        "through CPython and records what it produced. Do not edit by hand;",
        "add cases to the generator and re-run it.",
        '"""',
        "",
        "from std.testing import TestSuite, assert_equal, assert_raises",
        "",
        "from csv import (",
        "    QUOTE_ALL,",
        "    QUOTE_NONE,",
        "    QUOTE_NONNUMERIC,",
        "    Dialect,",
        "    excel_tab,",
        "    reader,",
        "    unix,",
        "    writes,",
        ")",
        "",
        "",
        "def _render(rows: List[List[String]]) -> String:",
        '    """Renders rows the way Python\'s `repr` would.',
        "",
        "    Args:",
        "        rows: The rows to render.",
        "",
        "    Returns:",
        "        A string such as `[['a', 'b']]`.",
        '    """',
        '    var out = String("[")',
        "    for i in range(len(rows)):",
        "        if i:",
        '            out += ", "',
        '        out += "["',
        "        for j in range(len(rows[i])):",
        "            if j:",
        '                out += ", "',
        "            out += \"'\" + rows[i][j] + \"'\"",
        '        out += "]"',
        '    out += "]"',
        "    return out^",
        "",
        "",
        "def _check(",
        "    text: StringSlice,",
        "    dialect: Dialect,",
        "    rows: StringSlice,",
        "    written: StringSlice,",
        ") raises:",
        '    """Checks one document against CPython.',
        "",
        "    Args:",
        "        text: The document to read.",
        "        dialect: The format parameters to read and write with.",
        "        rows: What `csv.reader` produced, rendered.",
        "        written: What `csv.writer` produced for those rows.",
        "",
        "    Raises:",
        "        If reading or writing differs from CPython.",
        '    """',
        "    var parsed = reader(text, dialect)",
        "    assert_equal(_render(parsed), rows, String(text))",
        "    assert_equal(writes(parsed, dialect), written, String(text))",
        "",
        "",
    ]

    per_test = 6
    for start in range(0, len(cases), per_test):
        lines.append(
            "def test_matches_python_%03d() raises:" % (start // per_test)
        )
        for text, expr, rows, out in cases[start : start + per_test]:
            lines.append("    _check(")
            lines.append("        %s," % mojo_str(text))
            lines.append("        %s," % expr)
            lines.append("        %s," % mojo_str(rows))
            lines.append("        %s," % mojo_str(out))
            lines.append("    )")
        lines.append("")
        lines.append("")

    for start in range(0, len(bad), per_test):
        lines.append(
            "def test_strict_rejects_like_python_%03d() raises:"
            % (start // per_test)
        )
        for text in bad[start : start + per_test]:
            lines.append("    with assert_raises():")
            lines.append(
                "        _ = reader(%s, Dialect(strict=True))" % mojo_str(text)
            )
        lines.append("")
        lines.append("")

    lines.append("def main() raises:")
    lines.append("    TestSuite.discover_tests[__functions_in_module()]().run()")
    lines.append("")

    with open(OUT, "w") as fh:
        fh.write("\n".join(lines))
    os.system("mojo format -q %s >/dev/null 2>&1" % OUT)
    print(
        "wrote %s: %d comparable cases, %d rejected, %d skipped"
        % (
            os.path.relpath(OUT, os.path.join(HERE, "..")),
            len(cases),
            len(bad),
            skipped,
        )
    )


if __name__ == "__main__":
    main()
