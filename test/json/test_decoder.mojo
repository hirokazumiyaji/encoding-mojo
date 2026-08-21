"""Tests for `loads`.

Every error message in this file is the exact message CPython's
`json.JSONDecodeError` produces for the same input.
"""

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from json import JSONType, JSONValue, loads


def test_loads_literals() raises:
    assert_true(loads("null").is_null())
    assert_equal(loads("true").bool(), True)
    assert_equal(loads("false").bool(), False)


def test_loads_integers() raises:
    assert_equal(loads("0").int(), 0)
    assert_equal(loads("42").int(), 42)
    assert_equal(loads("-17").int(), -17)
    assert_equal(loads("-0").int(), 0)
    assert_equal(loads("9223372036854775807").int(), 9223372036854775807)
    assert_equal(loads("-9223372036854775808").int(), -9223372036854775808)
    assert_true(loads("1").is_int())


def test_loads_floats() raises:
    assert_equal(loads("1.5").float(), 1.5)
    assert_equal(loads("-0.25").float(), -0.25)
    assert_equal(loads("1e3").float(), 1000.0)
    assert_equal(loads("1E5").float(), 100000.0)
    assert_equal(loads("1e-3").float(), 0.001)
    assert_equal(loads("0.0").float(), 0.0)
    # `1E5` has an exponent, so CPython calls it a float even though it is
    # integral.
    assert_true(loads("1E5").is_float())
    assert_true(loads("0.0").is_float())


def test_loads_float_precision() raises:
    assert_equal(loads("0.1").float(), 0.1)
    assert_equal(loads("3.141592653589793").float(), 3.141592653589793)
    assert_equal(
        loads("2.2250738585072014e-308").float(), 2.2250738585072014e-308
    )


def test_loads_huge_exponent_is_infinity() raises:
    var v = loads("1e400").float()
    assert_true(v > 1e308)


def test_loads_strings() raises:
    assert_equal(loads('"hello"').string(), "hello")
    assert_equal(loads('""').string(), "")
    assert_equal(loads('"日本語"').string(), "日本語")


def test_loads_string_escapes() raises:
    assert_equal(loads('"a\\"b"').string(), 'a"b')
    assert_equal(loads('"a\\\\b"').string(), "a\\b")
    assert_equal(loads('"a\\/b"').string(), "a/b")
    assert_equal(loads('"\\b\\f\\n\\r\\t"').string(), "\x08\x0c\n\r\t")


def test_loads_unicode_escapes() raises:
    assert_equal(loads('"\\u0041"').string(), "A")
    assert_equal(loads('"\\u00e9"').string(), "é")
    assert_equal(loads('"\\u65e5\\u672c\\u8a9e"').string(), "日本語")


def test_loads_surrogate_pairs() raises:
    assert_equal(loads('"\\ud83d\\ude00"').string(), "😀")


def test_loads_empty_containers() raises:
    assert_equal(len(loads("[]")), 0)
    assert_true(loads("[]").is_array())
    assert_equal(len(loads("{}")), 0)
    assert_true(loads("{}").is_object())


def test_loads_array() raises:
    var v = loads("[1, 2, 3]")
    assert_equal(len(v), 3)
    assert_equal(v[0].int(), 1)
    assert_equal(v[2].int(), 3)


def test_loads_object() raises:
    var v = loads('{"a": 1, "b": "two"}')
    assert_equal(len(v), 2)
    assert_equal(v["a"].int(), 1)
    assert_equal(v["b"].string(), "two")


def test_loads_nested() raises:
    var v = loads('{"a": [1, {"b": [2, 3]}], "c": null}')
    assert_equal(v["a"][1]["b"][1].int(), 3)
    assert_true(v["c"].is_null())


def test_loads_deeply_nested() raises:
    var src = String("[" * 300) + String("]" * 300)
    var v = loads(src)
    var depth = 0
    var cur = v
    while len(cur) > 0:
        cur = cur[0]
        depth += 1
    assert_equal(depth, 299)


def test_loads_ignores_surrounding_whitespace() raises:
    var v = loads("  \t\r\n [ 1 , 2 ]  \n ")
    assert_equal(len(v), 2)


def test_loads_duplicate_keys_last_wins() raises:
    # CPython: `json.loads('{"a":1,"a":2}')` is `{'a': 2}`.
    var v = loads('{"a": 1, "a": 2}')
    assert_equal(len(v), 1)
    assert_equal(v["a"].int(), 2)


def test_loads_many_keys() raises:
    var src = String("{")
    for i in range(200):
        if i:
            src += ","
        src += '"k' + String(i) + '":' + String(i)
    src += "}"
    var v = loads(src)
    assert_equal(len(v), 200)
    assert_equal(v["k199"].int(), 199)


def test_loads_accepts_nan_and_infinity() raises:
    assert_true(loads("NaN").float() != loads("NaN").float())
    assert_true(loads("Infinity").float() > 1e308)
    assert_true(loads("-Infinity").float() < -1e308)


def test_loads_rejects_nan_when_asked() raises:
    with assert_raises(contains="Expecting value"):
        _ = loads("NaN", allow_nan=False)


def test_error_expecting_value() raises:
    with assert_raises(contains="Expecting value: line 1 column 1 (char 0)"):
        _ = loads("")
    with assert_raises(contains="Expecting value: line 1 column 3 (char 2)"):
        _ = loads("  ")
    with assert_raises(contains="Expecting value: line 1 column 1 (char 0)"):
        _ = loads("x")
    with assert_raises(contains="Expecting value: line 1 column 1 (char 0)"):
        _ = loads("'a'")
    with assert_raises(contains="Expecting value: line 1 column 1 (char 0)"):
        _ = loads("nul")
    with assert_raises(contains="Expecting value: line 1 column 1 (char 0)"):
        _ = loads("-")
    with assert_raises(contains="Expecting value: line 1 column 1 (char 0)"):
        _ = loads(".1")
    with assert_raises(contains="Expecting value: line 1 column 2 (char 1)"):
        _ = loads("[")
    with assert_raises(contains="Expecting value: line 1 column 4 (char 3)"):
        _ = loads("[1,]")
    with assert_raises(contains="Expecting value: line 1 column 6 (char 5)"):
        _ = loads('{"a":}')


def test_error_extra_data() raises:
    with assert_raises(contains="Extra data: line 1 column 5 (char 4)"):
        _ = loads("[1] 2")
    with assert_raises(contains="Extra data: line 1 column 2 (char 1)"):
        _ = loads("01")
    with assert_raises(contains="Extra data: line 1 column 2 (char 1)"):
        _ = loads("1.")
    with assert_raises(contains="Extra data: line 1 column 2 (char 1)"):
        _ = loads("1e")


def test_error_expecting_delimiters() raises:
    with assert_raises(
        contains="Expecting ':' delimiter: line 1 column 5 (char 4)"
    ):
        _ = loads('{"a"')
    with assert_raises(
        contains="Expecting ':' delimiter: line 1 column 6 (char 5)"
    ):
        _ = loads('{"a" 1}')
    with assert_raises(
        contains="Expecting ',' delimiter: line 1 column 4 (char 3)"
    ):
        _ = loads("[1 2]")
    with assert_raises(
        contains="Expecting ',' delimiter: line 1 column 5 (char 4)"
    ):
        _ = loads("[1,2")
    with assert_raises(
        contains="Expecting ',' delimiter: line 1 column 7 (char 6)"
    ):
        _ = loads('{"a":1')


def test_error_expecting_property_name() raises:
    var msg = "Expecting property name enclosed in double quotes"
    with assert_raises(contains=msg + ": line 1 column 2 (char 1)"):
        _ = loads("{")
    with assert_raises(contains=msg + ": line 1 column 2 (char 1)"):
        _ = loads("{1:2}")
    with assert_raises(contains=msg + ": line 1 column 8 (char 7)"):
        _ = loads('{"a":1,}')


def test_error_string_problems() raises:
    with assert_raises(
        contains="Unterminated string starting at: line 1 column 1 (char 0)"
    ):
        _ = loads('"abc')
    with assert_raises(
        contains="Invalid control character at: line 1 column 3 (char 2)"
    ):
        _ = loads('"a\nb"')
    with assert_raises(contains="Invalid \\escape: line 1 column 3 (char 2)"):
        _ = loads('"a\\qb"')
    with assert_raises(
        contains="Invalid \\uXXXX escape: line 1 column 3 (char 2)"
    ):
        _ = loads('"\\u12"')
    with assert_raises(
        contains="Invalid \\uXXXX escape: line 1 column 3 (char 2)"
    ):
        _ = loads('"\\uZZZZ"')


def test_error_line_and_column_track_newlines() raises:
    with assert_raises(contains="line 4 column 2 (char 9)"):
        _ = loads('\n{"a"\n:\n1')


def test_non_strict_mode_allows_control_characters() raises:
    assert_equal(loads('"a\nb"', strict=False).string(), "a\nb")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
