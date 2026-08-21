"""Tests for `loads`.

Every expected value here is what CPython 3.11's `tomllib.loads` produces for
the same input, rendered through `json.dumps` so one assertion covers the whole
document.
"""

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from json import dumps
from toml import loads


def _check(text: StringSlice, expected: StringSlice) raises:
    """Loads `text` and compares its JSON rendering with `expected`.

    Args:
        text: The TOML document.
        expected: What `tomllib.loads` produces, as compact JSON.

    Raises:
        If loading fails or the result differs.
    """
    assert_equal(
        dumps(loads(text), separators=(",", ":")),
        expected,
        "loading " + repr(String(text)),
    )


def test_key_value_pairs() raises:
    _check('key = "value"\n', '{"key":"value"}')
    _check(
        "a = 1\nb = 2.5\nc = true\nd = false\n",
        '{"a":1,"b":2.5,"c":true,"d":false}',
    )


def test_integer_forms() raises:
    _check(
        "i1 = 0\ni2 = -17\ni3 = +99\ni4 = 1_000\n",
        '{"i1":0,"i2":-17,"i3":99,"i4":1000}',
    )
    _check(
        "h = 0xDEADBEEF\no = 0o755\nb = 0b1010\n",
        '{"h":3735928559,"o":493,"b":10}',
    )


def test_float_forms() raises:
    _check(
        "f1 = 1.0\nf2 = -0.01\nf3 = 5e+22\nf4 = 6.626e-34\n",
        '{"f1":1.0,"f2":-0.01,"f3":5e+22,"f4":6.626e-34}',
    )
    _check("f5 = 224_617.445_991_228\n", '{"f5":224617.445991228}')


def test_special_floats() raises:
    var doc = loads("a = inf\nb = -inf\nc = nan\n")
    assert_true(doc["a"].float() > 1e308)
    assert_true(doc["b"].float() < -1e308)
    assert_true(doc["c"].float() != doc["c"].float())


def test_basic_strings() raises:
    _check(
        's = "basic \\"quoted\\" \\n\\t"\n', '{"s":"basic \\"quoted\\" \\n\\t"}'
    )
    _check(
        'e = "\\u00e9 \\U0001F600 \\\\ \\b\\f/"\n',
        '{"e":"\\u00e9 \\ud83d\\ude00 \\\\ \\b\\f/"}',
    )


def test_literal_strings() raises:
    _check("s = 'literal \\n no escape'\n", '{"s":"literal \\\\n no escape"}')


def test_multi_line_basic_strings() raises:
    _check('s = """\nmulti\nline\n"""\n', '{"s":"multi\\nline\\n"}')
    _check('s = """line \\\n  continued"""\n', '{"s":"line continued"}')


def test_multi_line_literal_strings() raises:
    _check("s = '''raw\nmulti'''\n", '{"s":"raw\\nmulti"}')


def test_arrays() raises:
    _check(
        'arr = [1, 2, 3]\nempty = []\nnested = [[1, 2], ["a"]]\n',
        '{"arr":[1,2,3],"empty":[],"nested":[[1,2],["a"]]}',
    )
    _check("multi = [\n  1,\n  2,\n]\n", '{"multi":[1,2]}')


def test_inline_tables() raises:
    _check('inline = { a = 1, b = "two" }\n', '{"inline":{"a":1,"b":"two"}}')
    _check("empty = {}\n", '{"empty":{}}')


def test_tables() raises:
    _check("[table]\nkey = 1\n", '{"table":{"key":1}}')
    _check("[a.b.c]\nkey = 1\n", '{"a":{"b":{"c":{"key":1}}}}')
    _check(
        "top = 0\n[t1]\nx = 1\n[t2]\ny = 2\n",
        '{"top":0,"t1":{"x":1},"t2":{"y":2}}',
    )


def test_arrays_of_tables() raises:
    _check(
        '[[products]]\nname = "A"\n[[products]]\nname = "B"\n',
        '{"products":[{"name":"A"},{"name":"B"}]}',
    )
    _check(
        '[[fruit]]\nname = "apple"\n[fruit.geometry]\nshape = "round"\n',
        '{"fruit":[{"name":"apple","geometry":{"shape":"round"}}]}',
    )


def test_dotted_keys() raises:
    _check('a.b.c = 1\nd."e.f" = 2\n', '{"a":{"b":{"c":1}},"d":{"e.f":2}}')


def test_key_forms() raises:
    _check("'literal key' = 2\n", '{"literal key":2}')
    _check('"quoted key" = 1\n', '{"quoted key":1}')
    _check(
        "bare_key = 1\nbare-key = 2\n1234 = 3\n",
        '{"bare_key":1,"bare-key":2,"1234":3}',
    )


def test_comments() raises:
    _check("# comment\nkey = 1 # trailing\n", '{"key":1}')
    _check("\n\n# only comments\n\n", "{}")


def test_empty_document() raises:
    _check("", "{}")


def test_datetimes_stay_strings() raises:
    # `tomllib` builds `datetime` objects; there is no such type here, so the
    # literal is kept verbatim.
    _check(
        "d1 = 1979-05-27T07:32:00Z\nd2 = 1979-05-27\nd3 = 07:32:00\n",
        '{"d1":"1979-05-27T07:32:00Z","d2":"1979-05-27","d3":"07:32:00"}',
    )


def test_errors() raises:
    with assert_raises(contains="Expected '=' after a key in a key/value pair"):
        _ = loads("key\n")
    with assert_raises(contains="Invalid value"):
        _ = loads("key =\n")
    with assert_raises(contains="Invalid statement"):
        _ = loads("= 1\n")
    with assert_raises(contains="Cannot overwrite a value"):
        _ = loads("a = 1\na = 2\n")
    with assert_raises(contains="Unclosed array"):
        _ = loads("a = [1, 2\n")
    with assert_raises(contains="Unclosed inline table"):
        _ = loads("a = {b = 1\n")
    with assert_raises(
        contains="Expected ']' at the end of a table declaration"
    ):
        _ = loads("[a\n")
    with assert_raises(
        contains="Expected newline or end of document after a statement"
    ):
        _ = loads("a = 1 2\n")


def test_error_positions() raises:
    with assert_raises(contains="(at line 2, column 6)"):
        _ = loads("a = 1\na = 2\n")
    with assert_raises(contains="(at line 1, column 1)"):
        _ = loads("= 1\n")


def test_table_redefinition_is_rejected() raises:
    with assert_raises(contains="Cannot declare"):
        _ = loads("[a]\n[a]\n")
    with assert_raises(contains="Cannot declare"):
        _ = loads("a.b = 1\n[a]\n")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
