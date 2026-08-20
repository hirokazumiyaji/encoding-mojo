"""Runs the examples from README.md and src/json/README.md.

Documentation that has drifted is worse than none, so every snippet a reader
might copy is executed here.
"""

from std.testing import TestSuite, assert_equal, assert_true

from json import JSONType, JSONValue, dumps, loads


def test_root_readme_quick_start() raises:
    var doc = loads('{"name": "mojo", "tags": ["fast", "safe"]}')
    assert_equal(doc["name"].string(), "mojo")
    assert_equal(len(doc["tags"]), 2)

    doc["tags"].append("pure")
    assert_equal(
        dumps(doc, indent=2),
        '{\n  "name": "mojo",\n  "tags": [\n    "fast",\n    "safe",\n   '
        ' "pure"\n  ]\n}',
    )


def test_decoding_example() raises:
    var doc = loads('{"id": 7, "tags": ["a", "b"], "meta": null}')
    assert_equal(doc["id"].int(), 7)
    assert_equal(doc["tags"][0].string(), "a")
    assert_true(doc["meta"].is_null())
    assert_equal(len(doc), 3)
    assert_true("tags" in doc)


def test_encoding_options_example() raises:
    var doc = loads('{"id": 7, "tags": ["a", "b"], "meta": null}')
    assert_equal(dumps(doc), '{"id": 7, "tags": ["a", "b"], "meta": null}')
    assert_equal(dumps(doc, separators=(",", ":")), '{"id":7,"tags":["a","b"],"meta":null}')
    assert_equal(
        dumps(doc, sort_keys=True), '{"id": 7, "meta": null, "tags": ["a", "b"]}'
    )
    assert_equal(dumps(loads('{"a": [1]}'), indent="\t"), '{\n\t"a": [\n\t\t1\n\t]\n}')


def test_building_example() raises:
    var doc = JSONValue.object()
    doc["name"] = "mojo"
    doc["scores"] = JSONValue.array()
    for i in range(3):
        doc["scores"].append(i * i)
    assert_equal(dumps(doc), '{"name": "mojo", "scores": [0, 1, 4]}')


def test_iteration_example() raises:
    var doc = loads('{"tags": ["x", "y"]}')
    var joined = String()
    for tag in doc["tags"]:
        joined += tag.string()
    assert_equal(joined, "xy")

    var keys = String()
    for key in doc:
        keys += key.string()
        assert_true(doc[key.string()].is_array())
    assert_equal(keys, "tags")


def test_aliasing_example() raises:
    var doc = loads('{"tags": ["a"]}')
    var tags = doc["tags"]
    tags.append("new")
    assert_equal(len(doc["tags"]), 2)


def test_type_reflection_example() raises:
    assert_equal(loads("1").type(), JSONType.INT)
    assert_equal(loads("1.0").type(), JSONType.FLOAT)
    assert_equal(String(loads("[]").type()), "list")
    assert_equal(String(loads("{}").type()), "dict")
    assert_equal(String(loads("null").type()), "NoneType")
    assert_equal(dumps(loads("1")), "1")
    assert_equal(dumps(loads("1.0")), "1.0")


def test_documented_deviations() raises:
    # Integers wider than 64 bits widen to floats.
    var big = loads("123456789012345678901234567890")
    assert_true(big.is_float())

    # An unpaired surrogate escape decodes to U+FFFD.
    assert_equal(loads('"\\ud800"').string(), "�")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
