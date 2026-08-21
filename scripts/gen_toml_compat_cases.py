#!/usr/bin/env python3
"""Regenerates `test/toml/test_tomllib_compat.mojo` from the reference tools.

Every case is decided by running CPython's `tomllib` and `tomli_w` here, so the
generated file is a differential test: it asserts that this library agrees with
the reference implementations on what a document loads to, on what it writes
back to, and on which documents are rejected.

Run it after changing the case list:

```bash
python3 scripts/gen_toml_compat_cases.py
```
"""

import datetime
import json
import os
import random
import tomllib

import tomli_w

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "test", "toml", "test_tomllib_compat.mojo")

DOCUMENTS = [
    # Key/value basics.
    'key = "value"\n',
    "bare_key = 1\nbare-key = 2\n1234 = 3\n",
    '"quoted key" = 1\n\'literal key\' = 2\n"" = 3\n',
    '"\\u00e9" = 1\n"\\U0001F600" = 2\n',
    "a.b.c = 1\na.b.d = 2\n",
    'physical.color = "orange"\nphysical.shape = "round"\n',
    "x = 1 # trailing comment\n# whole line\n",
    "\n\n\na = 1\n\n\n",
    "a = 1\r\nb = 2\r\n",
    # Strings.
    'basic = "I\'m a string. \\"You can quote me\\". Name\\tJos\\u00E9\\nLocation\\tSF."\n',
    'esc = "\\b\\t\\n\\f\\r\\"\\\\"\n',
    'ml = """\nRoses are red\nViolets are blue"""\n',
    'ml_join = """\\\n  The quick brown \\\n  fox jumps over \\\n  the lazy dog.\\\n  """\n',
    'ml_quotes = """Here are two quotation marks: "". Simple enough."""\n',
    "lit = 'C:\\\\Users\\\\nodejs\\\\templates'\n",
    "lit_quote = 'Tom \"Dubs\" Preston-Werner'\n",
    "ml_lit = '''\nThe first newline is trimmed.\n   All other whitespace is preserved.\n'''\n",
    'empty1 = ""\nempty2 = \'\'\nempty3 = """"""\nempty4 = \'\'\'\'\'\'\n',
    'unicode = "\\u00e9\\u4e2d\\U0001F600"\n',
    # Integers.
    "a = 0\nb = +99\nc = -17\nd = 1_000\ne = 5_349_221\n",
    "hex1 = 0xDEADBEEF\nhex2 = 0xdead_beef\noct = 0o755\nbin = 0b1101_0110\n",
    "big = 9223372036854775807\nsmall = -9223372036854775808\n",
    # Floats.
    "f1 = 1.0\nf2 = 3.1415\nf3 = -0.01\nf4 = 5e+22\nf5 = 1e06\nf6 = -2E-2\n",
    "f7 = 6.626e-34\nf8 = 224_617.445_991_228\n",
    "z1 = 0.0\nz2 = +0.0\nz3 = -0.0\n",
    # Booleans.
    "t = true\nf = false\n",
    # Arrays.
    "a = [1, 2, 3]\n",
    'b = ["red", "yellow", "green"]\n',
    "c = [[1, 2], [3, 4, 5]]\n",
    'd = [ "all", \'strings\', """are the same""", \'\'\'type\'\'\' ]\n',
    "e = [ 0.1, 0.2, 0.5, 1, 2, 5 ]\n",
    'f = [ "Comma", "Trailing", ]\n',
    "g = [\n  1,\n  2, # comment\n]\n",
    "empty = []\nnested_empty = [[], []]\n",
    "mixed = [1, \"two\", true, [3], { a = 1 }]\n",
    # Tables.
    "[table]\n",
    '[table-1]\nkey1 = "some string"\nkey2 = 123\n\n[table-2]\nkey1 = "another"\nkey2 = 456\n',
    '[dog."tater.man"]\ntype.name = "pug"\n',
    "[a.b.c]\nx = 1\n",
    "[x.y.z.w]\n[x]\n",
    "[fruit]\napple.color = \"red\"\napple.taste.sweet = true\n",
    # Inline tables.
    'name = { first = "Tom", last = "Preston-Werner" }\n',
    "point = { x = 1, y = 2 }\n",
    'animal = { type.name = "pug" }\n',
    "empty_inline = {}\n",
    # Arrays of tables.
    '[[products]]\nname = "Hammer"\nsku = 738594937\n\n[[products]]\n\n[[products]]\nname = "Nail"\nsku = 284758393\n',
    '[[fruits]]\nname = "apple"\n\n[fruits.physical]\ncolor = "red"\nshape = "round"\n\n[[fruits.varieties]]\nname = "red delicious"\n\n[[fruits.varieties]]\nname = "granny smith"\n',
    "[[a]]\nx = [1, 2, 3]\n",
    # Long inline tables cross the width where `tomli_w` stops inlining.
    '[[p]]\nk = "%s"\n' % ("x" * 80),
    '[[p]]\nk = "%s"\n' % ("x" * 90),
    # Up to two quotes may sit against a multi-line closing delimiter.
    'a = """abc""""\n',
    'a = """abc"""""\n',
    "a = '''abc''''\n",
    "a = '''abc'''''\n",
    'a = """a""b"""\n',
    'a = """"""\nb = \'\'\'\'\'\'\n',
    # Escapes that name a real character, at both ends of the range.
    'a = "\\u0000"\nb = "\\uD7FF"\nc = "\\uE000"\nd = "\\U0010FFFF"\n',
    # Valid date and time literals live in `test_load.mojo`; `tomllib` builds
    # `datetime` objects for them, which have no counterpart to compare with.
    # Numbers at the edge of the signed 64-bit range.
    "a = 9223372036854775807\nb = -9223372036854775808\nc = 0x7FFFFFFFFFFFFFFF\n",
    # Strings that only a multi-line form can hold verbatim.
    'a = "line\\nbreak"\nb = "carriage\\r\\nreturn"\nc = "ctrl\\u0001char"\n',
    'a = "tab\\there"\nb = "del\\u007f"\n',
]

BAD = [
    "= 1\n",
    "a =\n",
    "a = 1\nb\n",
    "a = 1 2\n",
    "a = 1\na = 2\n",
    "[a]\n[a]\n",
    "a.b = 1\n[a]\n",
    "[a]\nb = 1\n[a.b]\nc = 2\n",
    "a = [1, 2\n",
    "a = { b = 1\n",
    "a = { b = 1, }\n",
    "a = { b = 1\nc = 2 }\n",
    'a = "unterminated\n',
    "a = 'unterminated\n",
    'a = "bad \\escape"\n',
    'a = "\\u00"\n',
    "a = 01\n",
    "a = 1.\n",
    "a = .1\n",
    "a = 1__0\n",
    "a = 0x\n",
    "a = truthy\n",
    "[]\n",
    "[a.]\n",
    "[[a]\n",
    "a = 1\n[[a]]\n",
    "[a]\n[[a]]\n",
    "a = { b = 1 }\n[a.c]\nd = 2\n",
    "a = [1]\n[[a]]\n",
    "a = \"\\x7f\"\n",
    # An escape must name a Unicode scalar value.
    'a = "\\uD800"\n',
    'a = "\\uDFFF"\n',
    'a = "\\U00110000"\n',
    'a = "\\UFFFFFFFF"\n',
    # A value that is not a table cannot be opened as one.
    "a = 1\na.b = 2\n",
    "a = 1\n[a.b]\n",
    'a = "x"\na.b = 2\n',
    "a = [1]\n[a.b]\nc = 1\n",
    "a = [{ b = 1 }]\n[a.c]\nd = 1\n",
    "a = []\n[a.b]\nc = 1\n",
    "a = 1\n[[a]]\n",
    "[a]\nb = 1\n[a.b]\n",
    # Date and time literals are validated in full.
    "a = 2023-99-99\n",
    "a = 12:99:99\n",
    "a = 2023-01-01junk\n",
    "a = 2023-02-30\n",
    "a = 2023-02-29\n",
    "a = 1900-02-29\n",
    "a = 2023-04-31\n",
    "a = 24:00:00\n",
    "a = 07:32\n",
    "a = 1979-05-27T07:32:00+25:00\n",
    "a = 1979-05-27T\n",
    # A separator sits between two digits of the same kind.
    "a = 1_e2\n",
    "a = 1e_2\n",
    "a = 1._0\n",
    "a = 0x_1\n",
    "a = 0b_1\n",
    "a = 1_.0\n",
    # A radix prefix is lower case and never signed.
    "a = 0X1\n",
    "a = 0O17\n",
    "a = 0B1\n",
    "a = +0x1\n",
    "a = -0x1\n",
    # Six quotes do not close a multi-line string.
    'a = """abc""""""\n',
    "a = '''abc''''''\n",
]


def random_documents(count=60):
    """Builds pseudo-random documents out of the shapes above."""
    rng = random.Random(20260821)
    keys = ["a", "b", "key", "long_key_name", "k1", "nested", "x", "with space", ""]
    scalars = [
        "plain", "with spaces", "123", "1.5", "true", "", "  padded ",
        "it's", 'say "hi"', "line\nbreak", "tab\there", "\u65e5\u672c\u8a9e",
        "ctrl\u0001char", "crlf\r\nhere", "back\\slash",
    ]

    def build(depth, allow_table=True):
        r = rng.random()
        if depth <= 0 or r < 0.45:
            pick = rng.randrange(5)
            if pick == 0:
                return rng.random() < 0.5
            if pick == 1:
                return rng.randrange(-1000, 1000)
            if pick == 2:
                return round(rng.uniform(-100, 100), 4)
            return rng.choice(scalars)
        if r < 0.72:
            return [build(depth - 1) for _ in range(rng.randrange(4))]
        if not allow_table:
            return [build(depth - 1) for _ in range(rng.randrange(4))]
        return {
            rng.choice(keys) + str(rng.randrange(20)): build(depth - 1)
            for _ in range(rng.randrange(4))
        }

    out = []
    guard = 0
    while len(out) < count and guard < count * 40:
        guard += 1
        value = {
            rng.choice(keys) + str(rng.randrange(20)): build(3)
            for _ in range(rng.randrange(1, 5))
        }
        try:
            text = tomli_w.dumps(value, multiline_strings=rng.random() < 0.5)
        except (TypeError, ValueError):
            continue
        try:
            tomllib.loads(text)
        except tomllib.TOMLDecodeError:
            continue
        if len(text) < 3000:
            out.append(text)
    return out


def unsupported(value, depth=0):
    """Returns why a loaded value cannot be compared, or None."""
    if depth > 20:
        return "too deep"
    if isinstance(value, (datetime.date, datetime.datetime, datetime.time)):
        return "no Mojo type for %s" % type(value).__name__
    if isinstance(value, list):
        for item in value:
            reason = unsupported(item, depth + 1)
            if reason:
                return reason
        return None
    if isinstance(value, dict):
        for item in value.values():
            reason = unsupported(item, depth + 1)
            if reason:
                return reason
        return None
    if isinstance(value, float) and value != value:
        return "NaN does not compare equal"
    return None


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


def main():
    good = []
    for text in DOCUMENTS + random_documents():
        try:
            value = tomllib.loads(text)
        except tomllib.TOMLDecodeError:
            print("skipping (tomllib rejects it): %r" % text[:40])
            continue
        reason = unsupported(value)
        if reason:
            print("skipping (%s): %r" % (reason, text[:40]))
            continue
        try:
            loaded = json.dumps(value, separators=(",", ":"), allow_nan=False)
        except ValueError as exc:
            print("skipping (%s): %r" % (exc, text[:40]))
            continue
        good.append(
            (
                text,
                loaded,
                tomli_w.dumps(value),
                tomli_w.dumps(value, multiline_strings=True),
            )
        )

    bad = []
    for text in BAD:
        try:
            tomllib.loads(text)
        except tomllib.TOMLDecodeError:
            bad.append(text)
        else:
            print("skipping (tomllib accepts it): %r" % text)

    lines = [
        '"""Differential tests against `tomllib` and `tomli_w`.',
        "",
        "Generated by `scripts/gen_toml_compat_cases.py`, which runs every case",
        "through the reference implementations and records what they produced.",
        "Do not edit by hand; add cases to the generator and re-run it.",
        '"""',
        "",
        "from std.testing import TestSuite, assert_equal, assert_raises",
        "",
        "from json import dumps as json_dumps",
        "from toml import dumps, loads",
        "",
        "",
        "def _check(",
        "    text: StringSlice,",
        "    loaded: StringSlice,",
        "    dumped: StringSlice,",
        "    multiline: StringSlice,",
        ") raises:",
        '    """Checks one document against the reference implementations.',
        "",
        "    Args:",
        "        text: The document to load.",
        "        loaded: What `tomllib.loads` produced, as compact JSON.",
        "        dumped: What `tomli_w.dumps` produced for that value.",
        "        multiline: What `tomli_w.dumps` produced with",
        "            `multiline_strings=True`.",
        "",
        "    Raises:",
        "        If loading or writing differs from the reference.",
        '    """',
        "    var doc = loads(text)",
        "    assert_equal(",
        '        json_dumps(doc, separators=(",", ":")), loaded, String(text)',
        "    )",
        "    assert_equal(dumps(doc), dumped, String(text))",
        "    assert_equal(",
        "        dumps(doc, multiline_strings=True), multiline, String(text)",
        "    )",
        "",
        "",
    ]

    per_test = 8
    for start in range(0, len(good), per_test):
        lines.append(
            "def test_matches_tomllib_%03d() raises:" % (start // per_test)
        )
        for case in good[start : start + per_test]:
            lines.append("    _check(")
            for field in case:
                lines.append("        %s," % mojo_str(field))
            lines.append("    )")
        lines.append("")
        lines.append("")

    for start in range(0, len(bad), per_test):
        lines.append(
            "def test_rejects_like_tomllib_%03d() raises:" % (start // per_test)
        )
        for text in bad[start : start + per_test]:
            lines.append("    with assert_raises():")
            lines.append("        _ = loads(%s)" % mojo_str(text))
        lines.append("")
        lines.append("")

    lines.append("def main() raises:")
    lines.append("    TestSuite.discover_tests[__functions_in_module()]().run()")
    lines.append("")

    with open(OUT, "w") as fh:
        fh.write("\n".join(lines))
    os.system("mojo format -q %s >/dev/null 2>&1" % OUT)
    print(
        "wrote %s: %d comparable documents, %d rejected"
        % (os.path.relpath(OUT, os.path.join(HERE, "..")), len(good), len(bad))
    )


if __name__ == "__main__":
    main()
