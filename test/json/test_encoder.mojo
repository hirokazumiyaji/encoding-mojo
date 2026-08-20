"""Tests for `dumps`.

Every expected string in this file is the exact output of the corresponding
CPython `json.dumps` call.
"""

from std.testing import TestSuite, assert_equal, assert_raises

from json import JSONValue, dumps


def test_dumps_scalars() raises:
    assert_equal(dumps(None), "null")
    assert_equal(dumps(True), "true")
    assert_equal(dumps(False), "false")
    assert_equal(dumps(1), "1")
    assert_equal(dumps(-17), "-17")
    assert_equal(dumps("hi"), '"hi"')


def test_dumps_floats_match_python_repr() raises:
    assert_equal(dumps(1.0), "1.0")
    assert_equal(dumps(0.1), "0.1")
    assert_equal(dumps(1e20), "1e+20")
    assert_equal(dumps(1.5e-9), "1.5e-09")


def test_dumps_non_finite_floats() raises:
    var nan = Float64("nan")
    var inf = Float64("inf")
    assert_equal(dumps(nan), "NaN")
    assert_equal(dumps(inf), "Infinity")
    assert_equal(dumps(-inf), "-Infinity")


def test_dumps_non_finite_floats_rejected_when_asked() raises:
    with assert_raises(contains="not JSON compliant"):
        _ = dumps(Float64("nan"), allow_nan=False)


def test_dumps_uses_pythons_default_separators() raises:
    # CPython's defaults are `', '` and `': '`, not the compact forms.
    var a = JSONValue.array()
    a.append(1)
    a.append(2)
    assert_equal(dumps(a), "[1, 2]")

    var o = JSONValue.object()
    o["a"] = 1
    o["b"] = 2
    assert_equal(dumps(o), '{"a": 1, "b": 2}')


def test_dumps_empty_containers() raises:
    assert_equal(dumps(JSONValue.array()), "[]")
    assert_equal(dumps(JSONValue.object()), "{}")


def test_dumps_compact_separators() raises:
    var o = JSONValue.object()
    var a = JSONValue.array()
    a.append(1)
    a.append(2)
    o["a"] = a
    assert_equal(dumps(o, separators=(",", ":")), '{"a":[1,2]}')


def test_dumps_indent_int() raises:
    var o = JSONValue.object()
    var a = JSONValue.array()
    a.append(1)
    a.append(2)
    o["a"] = a
    o["b"] = JSONValue.object()
    assert_equal(
        dumps(o, indent=2), '{\n  "a": [\n    1,\n    2\n  ],\n  "b": {}\n}'
    )


def test_dumps_indent_zero_still_breaks_lines() raises:
    var o = JSONValue.object()
    var a = JSONValue.array()
    a.append(1)
    o["a"] = a
    assert_equal(dumps(o, indent=0), '{\n"a": [\n1\n]\n}')


def test_dumps_indent_string() raises:
    var o = JSONValue.object()
    var a = JSONValue.array()
    a.append(1)
    o["a"] = a
    assert_equal(dumps(o, indent="\t"), '{\n\t"a": [\n\t\t1\n\t]\n}')


def test_dumps_sort_keys_uses_codepoint_order() raises:
    var o = JSONValue.object()
    o["b"] = 1
    o["a"] = 2
    o["C"] = 3
    assert_equal(dumps(o, sort_keys=True), '{"C": 3, "a": 2, "b": 1}')


def test_dumps_escapes() raises:
    assert_equal(dumps('a"b\\c\n\t\x00/'), '"a\\"b\\\\c\\n\\t\\u0000/"')


def test_dumps_does_not_escape_solidus() raises:
    # CPython leaves `/` alone even though the grammar allows escaping it.
    assert_equal(dumps("a/b"), '"a/b"')


def test_dumps_ensure_ascii_escapes_non_ascii() raises:
    assert_equal(dumps("á"), '"\\u00e1"')
    assert_equal(dumps("日本語"), '"\\u65e5\\u672c\\u8a9e"')


def test_dumps_ensure_ascii_uses_surrogate_pairs() raises:
    assert_equal(dumps("😀"), '"\\ud83d\\ude00"')


def test_dumps_without_ensure_ascii_passes_utf8_through() raises:
    assert_equal(dumps("日本語 😀", ensure_ascii=False), '"日本語 😀"')


def test_str_of_value_is_default_dumps() raises:
    var o = JSONValue.object()
    o["a"] = 1
    assert_equal(String(o), '{"a": 1}')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
