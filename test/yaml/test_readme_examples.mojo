"""Runs the examples from README.md and src/yaml/README.md.

Documentation that has drifted is worse than none, so every snippet a reader
might copy is executed here.
"""

from std.testing import TestSuite, assert_equal, assert_true

from json import dumps
from yaml import safe_dump, safe_dump_all, safe_load, safe_load_all


def test_root_readme_cross_format_example() raises:
    assert_equal(
        dumps(safe_load("name: mojo\ntags: [fast, safe]\n")),
        '{"name": "mojo", "tags": ["fast", "safe"]}',
    )


def test_loading_example() raises:
    var doc = safe_load(
        "name: mojo\n"
        "version: 1.0\n"
        "tags:\n"
        "  - fast\n"
        "  - safe\n"
        "nested:\n"
        "  key: value\n"
    )
    assert_equal(doc["name"].string(), "mojo")
    assert_equal(doc["version"].float(), 1.0)
    assert_equal(doc["tags"][0].string(), "fast")
    assert_equal(len(doc["nested"]), 1)


def test_yaml_1_1_typing_table() raises:
    assert_equal(safe_load("v: yes\n")["v"].bool(), True)
    assert_equal(safe_load("v: off\n")["v"].bool(), False)
    assert_equal(safe_load("v: 017\n")["v"].int(), 15)
    assert_equal(safe_load("v: 0o17\n")["v"].string(), "0o17")
    assert_equal(safe_load("v: 1_000\n")["v"].int(), 1000)
    assert_equal(safe_load("v: 1e3\n")["v"].string(), "1e3")
    assert_equal(safe_load("v: 1:30\n")["v"].int(), 90)
    assert_equal(safe_load("v: y\n")["v"].string(), "y")
    assert_equal(safe_load("v: n\n")["v"].string(), "n")


def test_dumping_options_example() raises:
    var doc = safe_load("a:\n  - 1\n  - 2\n")
    assert_equal(safe_dump(doc), "a:\n- 1\n- 2\n")
    assert_equal(safe_dump(doc, default_flow_style=True), "{a: [1, 2]}\n")
    assert_equal(safe_dump(doc, explicit_start=True), "---\na:\n- 1\n- 2\n")
    assert_equal(
        safe_dump(safe_load("b: 1\na: 2\n"), sort_keys=False), "b: 1\na: 2\n"
    )
    assert_equal(
        safe_dump(safe_load("u: 日本語\n"), allow_unicode=True), "u: 日本語\n"
    )


def test_anchors_are_emitted_for_shared_collections() raises:
    var doc = safe_load("a: &x [1, 2]\nb: *x\n")
    assert_equal(safe_dump(doc), "a: &id001\n- 1\n- 2\nb: *id001\n")


def test_documented_deviations() raises:
    # Mapping keys are always strings.
    assert_true("1" in safe_load("1: one\n"))
    # A timestamp stays a string, and is quoted on the way out so PyYAML does
    # not turn it back into a date.
    assert_equal(safe_load("d: 2020-01-01\n")["d"].string(), "2020-01-01")
    assert_equal(safe_dump(safe_load("d: 2020-01-01\n")), "d: '2020-01-01'\n")


def test_load_all_and_dump_all() raises:
    var docs = safe_load_all("a: 1\n---\nb: 2\n")
    assert_equal(len(docs), 2)
    assert_equal(safe_dump_all(docs), "a: 1\n---\nb: 2\n")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
