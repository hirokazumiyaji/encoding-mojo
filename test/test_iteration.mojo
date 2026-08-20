"""Tests for iterating arrays and objects, and for `load` / `dump`."""

from std.io.file import open
from std.os import remove
from std.tempfile import gettempdir
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from json import JSONValue, dump, dumps, load, loads


def test_iterate_array_yields_elements() raises:
    var v = loads("[10, 20, 30]")
    var total = 0
    for item in v:
        total += item.int()
    assert_equal(total, 60)


def test_iterate_empty_array() raises:
    var count = 0
    for _ in loads("[]"):
        count += 1
    assert_equal(count, 0)


def test_iterate_object_yields_keys() raises:
    # Python iterates a dict's keys; so does this.
    var v = loads('{"a": 1, "b": 2}')
    var seen = String()
    for key in v:
        seen += key.string()
    assert_equal(seen, "ab")


def test_iterate_scalar_raises() raises:
    with assert_raises(contains="is not iterable"):
        for _ in loads("1"):
            pass


def test_items() raises:
    var v = loads('{"a": 1, "b": 2}')
    var items = v.items()
    assert_equal(len(items), 2)
    assert_equal(items[0][0], "a")
    assert_equal(items[1][1].int(), 2)


def test_values() raises:
    var v = loads('{"a": 1, "b": 2}')
    var vals = v.values()
    assert_equal(len(vals), 2)
    assert_equal(vals[0].int(), 1)
    assert_equal(vals[1].int(), 2)


def _temp_path(name: StringSlice) raises -> String:
    """Builds a scratch file path under the system temporary directory.

    Args:
        name: The file name to use.

    Returns:
        The absolute path.

    Raises:
        If the system has no temporary directory.
    """
    var dir = gettempdir()
    if not dir:
        raise Error("no temporary directory available")
    return dir.value() + "/" + String(name)


def test_dump_and_load_round_trip() raises:
    var doc = loads('{"a": [1, 2], "b": "x"}')
    var path = _temp_path("json_mojo_round_trip.json")
    with open(path, "w") as f:
        dump(doc, f)
    with open(path, "r") as f:
        assert_equal(load(f), doc)
    remove(path)


def test_dump_honours_encoder_options() raises:
    var doc = loads('{"a": 1}')
    var path = _temp_path("json_mojo_indent.json")
    with open(path, "w") as f:
        dump(doc, f, indent=2)
    with open(path, "r") as f:
        assert_equal(f.read(), '{\n  "a": 1\n}')
    remove(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
