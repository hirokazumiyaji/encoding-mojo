"""Tests for the remaining module-level surface: byte input, dict-parity
mutation, and the reusable encoder and decoder objects."""

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from json import JSONDecoder, JSONEncoder, JSONValue, dumps, loads


def test_loads_accepts_bytes() raises:
    # CPython's `json.loads` takes `bytes` as well as `str`.
    var raw = String('{"a": [1, 2]}')
    var doc = loads(raw.as_bytes())
    assert_equal(doc["a"][1].int(), 2)


def test_loads_bytes_reports_errors_the_same_way() raises:
    var raw = String("[1 2]")
    with assert_raises(
        contains="Expecting ',' delimiter: line 1 column 4 (char 3)"
    ):
        _ = loads(raw.as_bytes())


def test_object_update() raises:
    var o = JSONValue.object()
    o["a"] = 1
    o["b"] = 2
    var other = JSONValue.object()
    other["b"] = 20
    other["c"] = 30
    o.update(other)
    assert_equal(len(o), 3)
    assert_equal(o["a"].int(), 1)
    assert_equal(o["b"].int(), 20)
    assert_equal(o["c"].int(), 30)
    # Updating keeps the original position of an existing key, like Python.
    assert_equal(o.keys()[1], "b")


def test_object_setdefault() raises:
    var o = JSONValue.object()
    o["a"] = 1
    assert_equal(o.setdefault("a", 99).int(), 1)
    assert_equal(o.setdefault("b", 99).int(), 99)
    assert_equal(len(o), 2)
    assert_equal(o["b"].int(), 99)


def test_setdefault_returns_a_live_handle() raises:
    var o = JSONValue.object()
    var arr = o.setdefault("items", JSONValue.array())
    arr.append(1)
    assert_equal(len(o["items"]), 1)


def test_encoder_reuses_its_settings() raises:
    var encoder = JSONEncoder(indent=2, sort_keys=True)
    var doc = loads('{"b": 1, "a": [2]}')
    assert_equal(encoder.encode(doc), '{\n  "a": [\n    2\n  ],\n  "b": 1\n}')
    # Reusing it gives the same answer.
    assert_equal(encoder.encode(doc), encoder.encode(doc))


def test_encoder_matches_dumps() raises:
    var doc = loads('{"a": [1, "x"], "b": null}')
    assert_equal(JSONEncoder().encode(doc), dumps(doc))
    assert_equal(
        JSONEncoder(separators=(",", ":")).encode(doc),
        dumps(doc, separators=(",", ":")),
    )


def test_encoder_writes_into_a_writer() raises:
    var out = String("prefix ")
    JSONEncoder(separators=(",", ":")).write_into(out, loads("[1,2]"))
    assert_equal(out, "prefix [1,2]")


def test_decoder_reuses_its_settings() raises:
    var decoder = JSONDecoder(strict=False)
    assert_equal(decoder.decode('"a\nb"').string(), "a\nb")
    assert_equal(decoder.decode('"c\nd"').string(), "c\nd")


def test_decoder_matches_loads() raises:
    assert_equal(JSONDecoder().decode('{"a": 1}'), loads('{"a": 1}'))
    with assert_raises(contains="Expecting value"):
        _ = JSONDecoder(allow_nan=False).decode("NaN")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
