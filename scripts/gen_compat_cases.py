#!/usr/bin/env python3
"""Regenerates `test/json/test_python_compat.mojo` from CPython's behaviour.

Every case is decided by running CPython's own `json` module here, so the
generated file is a differential test: it asserts that this library agrees with
the reference implementation on both successful decodes and error messages.

Run it after changing the case list:

```bash
python3 scripts/gen_compat_cases.py
```
"""

import json
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "test", "json", "test_python_compat.mojo")

# Inputs to compare. Anything CPython can decode is compared through `dumps`,
# and anything it rejects is compared through its error message.
INPUTS = [
    # Literals and numbers.
    "null", "true", "false", "0", "-0", "1", "-1", "42", "-42",
    "9223372036854775807", "-9223372036854775808",
    "0.0", "-0.0", "1.0", "-1.5", "0.1", "1e3", "1E3", "1e+3", "1e-3",
    "1.5e10", "-2.25e-8", "3.141592653589793", "1.7976931348623157e308",
    "2.2250738585072014e-308", "5e-324", "1e400", "-1e400",
    "0.30000000000000004", "123456789.123456789", "1000000000000000000000.0",
    "NaN", "Infinity", "-Infinity",
    # Strings.
    '""', '"a"', '"hello world"', '"tab\\there"', '"nl\\nhere"',
    '"quote\\"inside"', '"back\\\\slash"', '"solidus\\/here"',
    '"\\b\\f\\n\\r\\t"', '"\\u0000"', '"\\u001f"', '"\\u0020"', '"\\u007f"',
    '"\\u00e9"', '"\\u65e5\\u672c\\u8a9e"', '"\\ud83d\\ude00"',
    '"\\uffff"', '"mixed \\u00e9 text \\ud83d\\ude00 end"',
    '"日本語"', '"emoji 😀 here"', '"\\u0041\\u0042"',
    # Containers.
    "[]", "{}", "[1]", "[1,2,3]", '["a","b"]', "[[]]", "[[[[[]]]]]",
    "[null,true,false,1,1.5,\"s\",[],{}]",
    '{"a":1}', '{"a":1,"b":2}', '{"":1}', '{"a":{"b":{"c":1}}}',
    '{"a":[1,2],"b":{"c":[3,{"d":null}]}}',
    '{"a":1,"a":2}', '{"a":1,"b":2,"a":3}',
    '{"dup":1,"x":0,"dup":2,"y":0,"dup":3}',
    '  [ 1 , 2 ]  ', '\n{\n"a"\t:\r1\n}\n',
    '{"unicode key 日本語": "value"}',
    # Errors.
    "", "   ", "x", "'a'", "nul", "tru", "fals", "nan", "inf",
    "-", "+1", ".1", "1.", "1e", "1e+", "01", "00", "-01",
    "[", "]", "{", "}", "[,]", "[1,]", "[1 2]", "[1,2", "[1;2]",
    '{"a"', '{"a":}', '{"a":1,}', '{"a" 1}', '{1:2}', '{"a":1', '{,}',
    '"abc', '"a\nb"', '"a\\qb"', '"\\u12"', '"\\uZZZZ"', '"\\u"', '"\\"',
    "[1] 2", '{"a":1} {}', "1 2", "truefalse",
    "[[1],[2]] trailing",
]



def random_documents(count=80):
    """Builds pseudo-random documents that exercise every value shape."""
    rng = random.Random(20260820)
    words = ["", "a", "key", "日本語", "quote\"", "back\\slash", "tab\there",
             "nl\nhere", "\x00\x01\x1f", "emoji 😀", "\x7f del", "long " * 8]

    def scalar():
        kind = rng.randrange(7)
        if kind == 0:
            return None
        if kind == 1:
            return rng.random() < 0.5
        if kind == 2:
            return rng.randrange(-(2**62), 2**62)
        if kind == 3:
            return rng.uniform(-1e6, 1e6)
        if kind == 4:
            return rng.choice([0.0, -0.0, 1e-300, 1e300, 0.1, 1 / 3])
        if kind == 5:
            return rng.randrange(-9, 10)
        return rng.choice(words)

    def build(depth):
        if depth <= 0 or rng.random() < 0.45:
            return scalar()
        if rng.random() < 0.5:
            return [build(depth - 1) for _ in range(rng.randrange(4))]
        return {
            rng.choice(words) + str(rng.randrange(30)): build(depth - 1)
            for _ in range(rng.randrange(5))
        }

    out = []
    while len(out) < count:
        text = json.dumps(build(4), ensure_ascii=rng.random() < 0.5)
        if len(text) < 4000:
            out.append(text)
    return out


def truncations(count=40):
    """Builds malformed inputs by cutting valid documents short."""
    rng = random.Random(7)
    seeds = [
        '{"a": [1, 2, {"b": null}], "c": "text"}',
        '[1, 2.5, true, null, {"k": "v"}]',
        '{"outer": {"inner": [1, [2, [3]]]}}',
        '"a string with \\u0041 escapes"',
        '["\\ud83d\\ude00", "\\u00e9", "plain"]',
        '{"a": 1e10, "b": -2.5e-3, "c": [true, false, null]}',
    ]
    out = []
    for _ in range(count):
        seed = rng.choice(seeds)
        out.append(seed[: rng.randrange(1, len(seed))])
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


def skip_reason(text):
    """Returns why a case cannot be compared, or None."""
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        return None
    try:
        rendered = json.dumps(value)
    except ValueError:
        return "not re-encodable"
    # Mojo strings are strictly UTF-8, so a lone surrogate cannot round-trip.
    try:
        rendered.encode()
    except UnicodeEncodeError:
        return "lone surrogate"
    # Integers wider than 64 bits become floats here.
    def oversized(node):
        if isinstance(node, bool):
            return False
        if isinstance(node, int):
            return not (-(2**63) <= node < 2**63)
        if isinstance(node, list):
            return any(oversized(x) for x in node)
        if isinstance(node, dict):
            return any(oversized(x) for x in node.values())
        return False

    if oversized(value):
        return "integer wider than 64 bits"
    return None


def main():
    cases = INPUTS + random_documents() + truncations()
    ok_cases = []
    err_cases = []
    for text in cases:
        reason = skip_reason(text)
        if reason:
            print("skipping %r: %s" % (text, reason))
            continue
        try:
            value = json.loads(text)
        except json.JSONDecodeError as exc:
            err_cases.append((text, str(exc)))
        else:
            ok_cases.append(
                (
                    text,
                    json.dumps(value),
                    json.dumps(value, separators=(",", ":")),
                    json.dumps(value, indent=2),
                    json.dumps(value, sort_keys=True),
                    json.dumps(value, ensure_ascii=False),
                )
            )

    lines = [
        '"""Differential tests against CPython\'s `json` module.',
        "",
        "Generated by `scripts/gen_compat_cases.py`, which runs every case",
        "through CPython and records what it produced. Do not edit by hand;",
        "add cases to the generator and re-run it.",
        '"""',
        "",
        "from std.testing import TestSuite, assert_equal, assert_raises",
        "",
        "from json import dumps, loads",
        "",
        "",
        "def _check(",
        "    text: StringSlice,",
        "    default: StringSlice,",
        "    compact: StringSlice,",
        "    indented: StringSlice,",
        "    sorted_keys: StringSlice,",
        "    unescaped: StringSlice,",
        ") raises:",
        '    """Checks one decodable document against CPython\'s output.',
        "",
        "    Args:",
        "        text: The document to decode.",
        "        default: What `json.dumps` produced with default options.",
        "        compact: What it produced with `separators=(',', ':')`.",
        "        indented: What it produced with `indent=2`.",
        "        sorted_keys: What it produced with `sort_keys=True`.",
        "        unescaped: What it produced with `ensure_ascii=False`.",
        "",
        "    Raises:",
        "        If any of the five renderings differs.",
        '    """',
        "    var doc = loads(text)",
        "    assert_equal(dumps(doc), default, String(text))",
        '    assert_equal(dumps(doc, separators=(",", ":")), compact, String(text))',
        "    assert_equal(dumps(doc, indent=2), indented, String(text))",
        "    assert_equal(dumps(doc, sort_keys=True), sorted_keys, String(text))",
        "    assert_equal(dumps(doc, ensure_ascii=False), unescaped, String(text))",
        "",
        "",
    ]

    per_test = 12
    for start in range(0, len(ok_cases), per_test):
        chunk = ok_cases[start : start + per_test]
        lines.append("def test_matches_cpython_%03d() raises:" % (start // per_test))
        for case in chunk:
            lines.append("    _check(")
            for field in case:
                lines.append("        %s," % mojo_str(field))
            lines.append("    )")
        lines.append("")
        lines.append("")

    for start in range(0, len(err_cases), per_test):
        chunk = err_cases[start : start + per_test]
        lines.append("def test_rejects_like_cpython_%03d() raises:" % (start // per_test))
        for text, message in chunk:
            lines.append("    with assert_raises(contains=%s):" % mojo_str(message))
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
        "wrote %s: %d decodable cases, %d rejected cases"
        % (os.path.relpath(OUT, os.path.join(HERE, "..")), len(ok_cases), len(err_cases))
    )


if __name__ == "__main__":
    main()
