"""Tests for arrays and objects: building, reading and mutating them."""

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from json import JSONType, JSONValue


def test_empty_array() raises:
    var a = JSONValue.array()
    assert_equal(a.type(), JSONType.ARRAY)
    assert_true(a.is_array())
    assert_equal(len(a), 0)
    assert_false(Bool(a))


def test_empty_object() raises:
    var o = JSONValue.object()
    assert_equal(o.type(), JSONType.OBJECT)
    assert_true(o.is_object())
    assert_equal(len(o), 0)
    assert_false(Bool(o))


def test_len_of_scalars_raises() raises:
    # Python raises `TypeError: object of type 'int' has no len()`.
    with assert_raises(contains="has no len()"):
        _ = len(JSONValue(1))


def test_len_of_string_counts_codepoints() raises:
    assert_equal(len(JSONValue("hello")), 5)
    assert_equal(len(JSONValue("日本語")), 3)


def test_array_append_native_types() raises:
    var a = JSONValue.array()
    a.append(1)
    a.append(2.5)
    a.append(True)
    a.append("x")
    a.append(None)
    assert_equal(len(a), 5)
    assert_equal(a[0].int(), 1)
    assert_equal(a[1].float(), 2.5)
    assert_equal(a[2].bool(), True)
    assert_equal(a[3].string(), "x")
    assert_true(a[4].is_null())


def test_array_append_grows_past_initial_capacity() raises:
    var a = JSONValue.array()
    for i in range(100):
        a.append(i)
    assert_equal(len(a), 100)
    for i in range(100):
        assert_equal(a[i].int(), i)


def test_array_negative_indexing() raises:
    var a = JSONValue.array()
    a.append(1)
    a.append(2)
    a.append(3)
    assert_equal(a[-1].int(), 3)
    assert_equal(a[-3].int(), 1)


def test_array_index_out_of_range() raises:
    var a = JSONValue.array()
    a.append(1)
    with assert_raises(contains="list index out of range"):
        _ = a[1]
    with assert_raises(contains="list index out of range"):
        _ = a[-2]


def test_array_setitem() raises:
    var a = JSONValue.array()
    a.append(1)
    a.append(2)
    a[0] = 99
    a[-1] = "last"
    assert_equal(a[0].int(), 99)
    assert_equal(a[1].string(), "last")


def test_array_pop_and_clear() raises:
    var a = JSONValue.array()
    a.append(1)
    a.append(2)
    a.append(3)
    assert_equal(a.pop().int(), 3)
    assert_equal(a.pop(0).int(), 1)
    assert_equal(len(a), 1)
    a.clear()
    assert_equal(len(a), 0)


def test_nested_array() raises:
    var inner = JSONValue.array()
    inner.append(1)
    var outer = JSONValue.array()
    outer.append(inner)
    outer.append(2)
    assert_equal(len(outer), 2)
    assert_equal(outer[0][0].int(), 1)


def test_object_set_and_get() raises:
    var o = JSONValue.object()
    o["a"] = 1
    o["b"] = "two"
    assert_equal(len(o), 2)
    assert_equal(o["a"].int(), 1)
    assert_equal(o["b"].string(), "two")


def test_object_overwrites_existing_key() raises:
    var o = JSONValue.object()
    o["a"] = 1
    o["a"] = 2
    assert_equal(len(o), 1)
    assert_equal(o["a"].int(), 2)


def test_object_missing_key_raises() raises:
    var o = JSONValue.object()
    with assert_raises(contains="KeyError: 'nope'"):
        _ = o["nope"]


def test_object_contains() raises:
    var o = JSONValue.object()
    o["a"] = 1
    assert_true("a" in o)
    assert_false("b" in o)


def test_object_get_with_default() raises:
    var o = JSONValue.object()
    o["a"] = 1
    assert_equal(o.get("a").value().int(), 1)
    assert_false(Bool(o.get("b")))


def test_object_pop_and_clear() raises:
    var o = JSONValue.object()
    o["a"] = 1
    o["b"] = 2
    assert_equal(o.pop("a").int(), 1)
    assert_equal(len(o), 1)
    assert_false("a" in o)
    assert_true("b" in o)
    o.clear()
    assert_equal(len(o), 0)


def test_object_keys_preserve_insertion_order() raises:
    var o = JSONValue.object()
    o["z"] = 1
    o["a"] = 2
    o["m"] = 3
    var keys = o.keys()
    assert_equal(len(keys), 3)
    assert_equal(keys[0], "z")
    assert_equal(keys[1], "a")
    assert_equal(keys[2], "m")


def test_nested_object() raises:
    var o = JSONValue.object()
    var inner = JSONValue.object()
    inner["x"] = 1
    o["inner"] = inner
    assert_equal(o["inner"]["x"].int(), 1)


def test_containers_share_storage_like_python() raises:
    # `doc["a"]` is a handle on the same document, so mutating it is visible
    # through `doc` — the same aliasing Python's dict and list give you.
    var doc = JSONValue.object()
    doc["a"] = JSONValue.array()
    var a = doc["a"]
    a.append(1)
    assert_equal(len(doc["a"]), 1)


def test_container_equality() raises:
    var a = JSONValue.array()
    a.append(1)
    var b = JSONValue.array()
    b.append(1)
    assert_equal(a, b)
    b.append(2)
    assert_true(a != b)


def test_object_equality_ignores_order() raises:
    var x = JSONValue.object()
    x["a"] = 1
    x["b"] = 2
    var y = JSONValue.object()
    y["b"] = 2
    y["a"] = 1
    assert_equal(x, y)


def test_indexing_a_scalar_raises() raises:
    with assert_raises(contains="not subscriptable"):
        _ = JSONValue(1)[0]
    with assert_raises(contains="not subscriptable"):
        _ = JSONValue(1)["k"]


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
