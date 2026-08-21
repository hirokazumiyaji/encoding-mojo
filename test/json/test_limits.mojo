"""Tests for the nesting limit that keeps recursive walks from overflowing.

The parser is iterative, but `dumps` and structural equality walk a document
recursively, so a document that nests deeper than the limit — or one made
cyclic by aliasing a value into its own subtree — has to be rejected rather
than crash the process.
"""

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from json import MAX_DEPTH, JSONValue, dumps, loads


def test_self_referencing_object_is_rejected() raises:
    var doc = JSONValue.object()
    doc["self"] = doc
    with assert_raises(contains="Circular reference detected"):
        _ = dumps(doc)


def test_self_referencing_array_is_rejected() raises:
    var arr = JSONValue.array()
    arr.append(arr)
    with assert_raises(contains="Circular reference detected"):
        _ = dumps(arr)


def test_indirect_cycle_is_rejected() raises:
    var outer = JSONValue.object()
    var inner = JSONValue.array()
    outer["inner"] = inner
    outer["inner"].append(outer)
    with assert_raises(contains="Circular reference detected"):
        _ = dumps(outer)


def test_cycle_does_not_hang_equality() raises:
    var a = JSONValue.object()
    a["self"] = a
    var b = JSONValue.object()
    b["self"] = b
    # Structural equality cannot decide this, but it must terminate.
    assert_false(a == b)


def test_parser_rejects_nesting_past_the_limit() raises:
    var src = String("[" * (MAX_DEPTH + 1)) + String("]" * (MAX_DEPTH + 1))
    with assert_raises(contains="Exceeded maximum nesting depth"):
        _ = loads(src)


def test_deepest_allowed_nesting_round_trips() raises:
    var src = String("[" * MAX_DEPTH) + String("]" * MAX_DEPTH)
    var doc = loads(src)
    assert_equal(dumps(doc), src)


def test_grafting_a_cycle_is_rejected() raises:
    var cyclic = JSONValue.array()
    cyclic.append(cyclic)
    # Copying into a different document walks the same subtree.
    var other = JSONValue.array()
    with assert_raises(contains="Circular reference detected"):
        other.append(cyclic)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
