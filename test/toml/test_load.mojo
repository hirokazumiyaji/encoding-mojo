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


def test_datetime_forms_that_tomllib_accepts() raises:
    # Each of these loads in `tomllib`, so each has to load here too. The
    # generated suite cannot carry them: there is no `datetime` to compare to.
    _check(
        "a = 1979-05-27t07:32:00\nb = 1979-05-27 07:32:00\n",
        '{"a":"1979-05-27t07:32:00","b":"1979-05-27 07:32:00"}',
    )
    _check(
        "a = 1979-05-27T07:32:00z\nb = 1979-05-27T00:32:00-07:00\n",
        '{"a":"1979-05-27T07:32:00z","b":"1979-05-27T00:32:00-07:00"}',
    )
    _check(
        "a = 1979-05-27T00:32:00.999999+23:59\n",
        '{"a":"1979-05-27T00:32:00.999999+23:59"}',
    )
    _check(
        "a = 00:00:00.000001\nb = 23:59:59.9999999999\n",
        '{"a":"00:00:00.000001","b":"23:59:59.9999999999"}',
    )
    _check(
        "a = 2024-02-29\nb = 2000-02-29\nc = 1979-12-31\n",
        '{"a":"2024-02-29","b":"2000-02-29","c":"1979-12-31"}',
    )
    _check("a = [1979-05-27, 07:32:00]\n", '{"a":["1979-05-27","07:32:00"]}')
    # The space form only applies when a time really follows.
    _check("a = 1979-05-27 # not a time\n", '{"a":"1979-05-27"}')


def test_datetime_syntax_is_validated() raises:
    # There is no date type, but the literal still has to be a real date.
    with assert_raises(contains="Invalid date or datetime"):
        _ = loads("a = 2023-02-30\n")
    with assert_raises(contains="Invalid date or datetime"):
        _ = loads("a = 1900-02-29\n")
    with assert_raises(contains="Invalid value"):
        _ = loads("a = 2023-99-99\n")
    with assert_raises(contains="Invalid value"):
        _ = loads("a = 12:99:99\n")
    with assert_raises(contains="Expected newline"):
        _ = loads("a = 2023-01-01junk\n")


def test_escapes_must_name_a_scalar_value() raises:
    with assert_raises(
        contains="Escaped character is not a Unicode scalar value"
    ):
        _ = loads('a = "\\uD800"\n')
    with assert_raises(
        contains="Escaped character is not a Unicode scalar value"
    ):
        _ = loads('a = "\\U00110000"\n')
    _check('a = "\\uD7FF\\uE000"\n', '{"a":"\\ud7ff\\ue000"}')


def test_multiline_strings_may_end_with_quotes() raises:
    _check('a = """abc""""\n', '{"a":"abc\\""}')
    _check('a = """abc"""""\n', '{"a":"abc\\"\\""}')
    _check("a = '''abc''''\n", '{"a":"abc\'"}')
    _check("a = '''abc'''''\n", '{"a":"abc\'\'"}')
    with assert_raises(contains="Expected newline"):
        _ = loads('a = """abc""""""\n')


def test_a_value_cannot_be_reopened_as_a_table() raises:
    with assert_raises(contains="Cannot overwrite a value"):
        _ = loads("a = 1\na.b = 2\n")
    with assert_raises(contains="Cannot overwrite a value"):
        _ = loads("a = 1\n[a.b]\n")
    with assert_raises(contains="Cannot overwrite a value"):
        _ = loads("[a]\nb = 1\n[a.b]\n")
    with assert_raises(contains="Cannot declare"):
        _ = loads("a = [1]\n[a.b]\nc = 1\n")


def test_integers_outside_64_bits_are_rejected() raises:
    _check(
        "a = 9223372036854775807\nb = -9223372036854775808\n",
        '{"a":9223372036854775807,"b":-9223372036854775808}',
    )
    with assert_raises(contains="out of range"):
        _ = loads("a = 9223372036854775808\n")
    with assert_raises(contains="out of range"):
        _ = loads("a = -9223372036854775809\n")
    with assert_raises(contains="out of range"):
        _ = loads("a = 0xFFFFFFFFFFFFFFFF\n")


def test_separators_sit_between_digits_of_the_same_kind() raises:
    _check(
        "a = 1_0e2\nb = 1e1_0\nc = 0xf_f\n",
        '{"a":1000.0,"b":10000000000.0,"c":255}',
    )
    with assert_raises(contains="Invalid value"):
        _ = loads("a = 1_e2\n")
    with assert_raises(contains="Invalid value"):
        _ = loads("a = 1e_2\n")
    with assert_raises(contains="Invalid value"):
        _ = loads("a = 0x_1\n")


def test_radix_prefixes_are_lower_case_and_unsigned() raises:
    with assert_raises(contains="Invalid value"):
        _ = loads("a = 0X1\n")
    with assert_raises(contains="Invalid value"):
        _ = loads("a = 0O17\n")
    with assert_raises(contains="Invalid value"):
        _ = loads("a = 0B1\n")
    with assert_raises(contains="Invalid value"):
        _ = loads("a = +0x1\n")


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


def test_raw_control_characters_are_rejected() raises:
    with assert_raises(contains="Illegal character '\\x01'"):
        _ = loads('a = "x\x01y"\n')
    with assert_raises(contains="Illegal character '\\x7f'"):
        _ = loads('a = "x\x7fy"\n')
    with assert_raises(contains="Found invalid character '\\x01'"):
        _ = loads("a = 'x\x01y'\n")
    with assert_raises(contains="Illegal character '\\x01'"):
        _ = loads('a = """x\x01y"""\n')
    with assert_raises(contains="Found invalid character '\\x7f'"):
        _ = loads("a = '''x\x7fy'''\n")
    with assert_raises(contains="Illegal character '\\x01'"):
        _ = loads('"x\x01y" = 1\n')
    with assert_raises(contains="Found invalid character '\\x01'"):
        _ = loads("# c\x01omment\na = 1\n")
    # A tab is the exception TOML makes.
    _check('a = "x\ty"\n', '{"a":"x\\ty"}')
    _check("a = 'x\ty'\n", '{"a":"x\\ty"}')


def test_a_bare_carriage_return_is_not_a_line_ending() raises:
    _check("a = 1\r\nb = 2\r\n", '{"a":1,"b":2}')
    _check("# c\r\na = 1\r\n", '{"a":1}')
    _check('a = """x\r\ny"""\n', '{"a":"x\\ny"}')
    with assert_raises(contains="Expected newline"):
        _ = loads("a = 1\rb = 2\n")
    with assert_raises(contains="Illegal character '\\r'"):
        _ = loads('a = """x\ry"""\n')
    with assert_raises(contains="Found invalid character '\\r'"):
        _ = loads("# c\rb = 2\n")
    with assert_raises(contains="Expected newline"):
        _ = loads("[t]\ra = 1\n")


def test_year_zero_is_not_a_date() raises:
    with assert_raises(contains="Invalid date or datetime"):
        _ = loads("a = 0000-01-01\n")
    with assert_raises(contains="Invalid date or datetime"):
        _ = loads("a = 0000-01-01T00:00:00\n")
    _check("a = 0001-01-01\n", '{"a":"0001-01-01"}')


def test_array_of_tables_needs_an_array() raises:
    # An implicitly created table leaves no trace in the registries, so the
    # node itself has to be checked before appending to it.
    with assert_raises(contains="Cannot overwrite a value"):
        _ = loads("[a.b]\nx = 1\n[[a]]\n")
    with assert_raises(contains="Cannot overwrite a value"):
        _ = loads("[a]\nx = 1\n[[a]]\n")
    _check("[[a]]\n[[a]]\n", '{"a":[{},{}]}')


def test_an_inline_table_member_is_complete_as_written() raises:
    with assert_raises(contains="Cannot mutate immutable namespace ('a', 'b')"):
        _ = loads("x = { a = {}, a.b = 1 }\n")
    with assert_raises(contains="Cannot mutate immutable namespace ('a', 'y')"):
        _ = loads("x = { a = [{ x = 1 }], a.y = 2 }\n")
    with assert_raises(contains="Cannot mutate immutable namespace ('a',)"):
        _ = loads("x = { a = {}, a = 1 }\n")
    with assert_raises(contains="Duplicate inline table key 'a'"):
        _ = loads("x = { a = 1, a = 2 }\n")
    with assert_raises(contains="Cannot overwrite a value"):
        _ = loads("x = { a = 1, a.b = 2 }\n")
    # Each set of braces keeps its own bookkeeping.
    _check("x = { a.b = 1, a.c = 2 }\n", '{"x":{"a":{"b":1,"c":2}}}')
    _check(
        "x = { y = {}, z = { y = { a = 1 } } }\n",
        '{"x":{"y":{},"z":{"y":{"a":1}}}}',
    )


def test_registry_paths_survive_awkward_keys() raises:
    # A key may hold any character, so the definition registry can neither
    # join paths on a separator byte nor tag a component with a bare prefix.
    _check('"a\\u0000b" = 1\na.b = 2\n', '{"a\\u0000b":1,"a":{"b":2}}')
    _check('"ke" = 1\n"k" = {}\n', '{"ke":1,"k":{}}')
    _check('"e0" = 1\n[["e"]]\n', '{"e0":1,"e":[{}]}')
    _check(
        '[["a\\u0000b"]]\nx = 1\n[["a"]]\n',
        '{"a\\u0000b":[{"x":1}],"a":[{}]}',
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
