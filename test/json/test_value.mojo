"""Tests for the `JSONValue` scalar surface."""

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from json import JSONType, JSONValue


def test_null_is_the_default_value() raises:
    var v = JSONValue()
    assert_true(v.is_null())
    assert_equal(v.type(), JSONType.NULL)


def test_null_from_none() raises:
    var v = JSONValue(None)
    assert_true(v.is_null())


def test_bool_values() raises:
    var t = JSONValue(True)
    var f = JSONValue(False)
    assert_equal(t.type(), JSONType.BOOL)
    assert_true(t.is_bool())
    assert_true(t.bool())
    assert_false(f.bool())


def test_int_values() raises:
    var v = JSONValue(42)
    assert_equal(v.type(), JSONType.INT)
    assert_true(v.is_int())
    assert_true(v.is_number())
    assert_false(v.is_float())
    assert_equal(v.int(), 42)
    assert_equal(JSONValue(-9223372036854775808).int(), -9223372036854775808)


def test_float_values() raises:
    var v = JSONValue(3.5)
    assert_equal(v.type(), JSONType.FLOAT)
    assert_true(v.is_float())
    assert_true(v.is_number())
    assert_false(v.is_int())
    assert_equal(v.float(), 3.5)


def test_number_widening() raises:
    # `float()` accepts ints, just like Python's `float(1)`.
    assert_equal(JSONValue(7).float(), 7.0)


def test_string_values() raises:
    var v = JSONValue("hello")
    assert_equal(v.type(), JSONType.STRING)
    assert_true(v.is_string())
    assert_equal(v.string(), "hello")


def test_wrong_accessor_raises() raises:
    with assert_raises(contains="not an int"):
        _ = JSONValue("hello").int()
    with assert_raises(contains="not a string"):
        _ = JSONValue(1).string()
    with assert_raises(contains="not a bool"):
        _ = JSONValue(1).bool()


def test_bool_is_not_an_int() raises:
    # Unlike Python, `True` is never reported as an int here: JSON keeps the
    # two literal forms distinct and `dumps` must round-trip them.
    assert_false(JSONValue(True).is_int())
    assert_false(JSONValue(1).is_bool())


def test_truthiness_follows_python() raises:
    assert_false(Bool(JSONValue()))
    assert_false(Bool(JSONValue(False)))
    assert_false(Bool(JSONValue(0)))
    assert_false(Bool(JSONValue(0.0)))
    assert_false(Bool(JSONValue("")))
    assert_true(Bool(JSONValue(True)))
    assert_true(Bool(JSONValue(1)))
    assert_true(Bool(JSONValue("x")))


def test_equality_is_structural() raises:
    assert_equal(JSONValue(1), JSONValue(1))
    assert_equal(JSONValue("a"), JSONValue("a"))
    assert_equal(JSONValue(), JSONValue())
    assert_true(JSONValue(1) != JSONValue(2))
    assert_true(JSONValue(1) != JSONValue("1"))
    assert_true(JSONValue(True) != JSONValue(1))


def test_int_float_equality_follows_python() raises:
    # Python: `1 == 1.0` is True.
    assert_equal(JSONValue(1), JSONValue(1.0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
