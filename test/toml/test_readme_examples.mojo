"""Runs the examples from README.md and src/toml/README.md.

Documentation that has drifted is worse than none, so every snippet a reader
might copy is executed here.
"""

from std.testing import TestSuite, assert_equal, assert_raises

from json import dumps as json_dumps
from toml import TOMLDecodeError, dumps, loads


def test_package_docstring_example() raises:
    var doc = loads('name = "mojo"\ntags = ["fast", "safe"]\n')
    assert_equal(doc["name"].string(), "mojo")


def test_cross_format_example() raises:
    assert_equal(
        json_dumps(loads('name = "mojo"\ntags = ["fast", "safe"]\n')),
        '{"name": "mojo", "tags": ["fast", "safe"]}',
    )


def test_loading_example() raises:
    var doc = loads(
        'title = "example"\n'
        "\n"
        "[owner]\n"
        'name = "Tom"\n'
        "dob = 1979-05-27\n"
        "\n"
        "[servers.alpha]\n"
        'ip = "10.0.0.1"\n'
        "ports = [8001, 8002]\n"
    )
    assert_equal(doc["title"].string(), "example")
    assert_equal(doc["owner"]["name"].string(), "Tom")
    assert_equal(doc["servers"]["alpha"]["ports"][0].int(), 8001)
    # There is no date type, so the literal keeps its spelling.
    assert_equal(doc["owner"]["dob"].string(), "1979-05-27")


def test_error_message_example() raises:
    with assert_raises(
        contains="Cannot overwrite a value (at line 2, column 6)"
    ):
        _ = loads("a = 1\na = 2\n")


def test_dumping_options_example() raises:
    var doc = loads("a = [1, 2]\n")
    assert_equal(dumps(doc), "a = [\n    1,\n    2,\n]\n")
    assert_equal(dumps(doc, indent=2), "a = [\n  1,\n  2,\n]\n")
    assert_equal(
        dumps(loads('a = "one\\ntwo"\n'), multiline_strings=True),
        'a = """\none\ntwo"""\n',
    )


def test_dumping_shape_example() raises:
    # Insertion order is kept, scalars come before sections, and an empty
    # parent collapses into its child's header.
    assert_equal(dumps(loads("z = 1\na = 2\n")), "z = 1\na = 2\n")
    assert_equal(dumps(loads("[t]\nx = 1\ny = 2\n")), "[t]\nx = 1\ny = 2\n")
    assert_equal(dumps(loads("[a.b]\nc = 1\n")), "[a.b]\nc = 1\n")
    assert_equal(
        dumps(loads('[[p]]\nname = "A"\n')), 'p = [\n    { name = "A" },\n]\n'
    )


def test_dumping_rejects_a_non_table() raises:
    with assert_raises(contains="must be a table"):
        _ = dumps(loads("a = 1\n")["a"])


def test_strict_rules_example() raises:
    with assert_raises(contains="Cannot declare"):
        _ = loads("[a]\n[a]\n")
    with assert_raises(contains="immutable namespace"):
        _ = loads("a = { b = 1 }\na.c = 2\n")
    with assert_raises(contains="Cannot"):
        _ = loads("a = [1]\n[[a]]\n")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
