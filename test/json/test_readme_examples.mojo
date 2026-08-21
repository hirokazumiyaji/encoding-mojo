"""Runs the examples from README.md and src/json/README.md.

Documentation that has drifted is worse than none, so every snippet a reader
might copy is executed here.
"""

from std.testing import TestSuite, assert_equal, assert_true

from json import (
    JSONDecoder,
    JSONEncoder,
    JSONType,
    JSONValue,
    NumberHook,
    dumps,
    loads,
)


struct KeepLiteral(NumberHook):
    """The `ParseInt` example from src/json/README.md."""

    @staticmethod
    def call(text: String) raises -> JSONValue:
        """Keeps a numeric literal as the text it was written with.

        Args:
            text: The literal as it appeared in the document.

        Returns:
            The literal as a string value.
        """
        return JSONValue(text)


def test_root_readme_quick_start() raises:
    var doc = loads('{"name": "mojo", "tags": ["fast", "safe"]}')
    assert_equal(doc["name"].string(), "mojo")
    assert_equal(len(doc["tags"]), 2)

    doc["tags"].append("pure")
    assert_equal(
        dumps(doc, indent=2),
        (
            '{\n  "name": "mojo",\n  "tags": [\n    "fast",\n    "safe",\n   '
            ' "pure"\n  ]\n}'
        ),
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
    assert_equal(
        dumps(doc, separators=(",", ":")),
        '{"id":7,"tags":["a","b"],"meta":null}',
    )
    assert_equal(
        dumps(doc, sort_keys=True),
        '{"id": 7, "meta": null, "tags": ["a", "b"]}',
    )
    assert_equal(
        dumps(loads('{"a": [1]}'), indent="\t"), '{\n\t"a": [\n\t\t1\n\t]\n}'
    )


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


def test_reusable_settings_example() raises:
    var encoder = JSONEncoder(indent=2, sort_keys=True)
    var doc = loads('{"b": 1, "a": 2}')
    assert_equal(encoder.encode(doc), '{\n  "a": 2,\n  "b": 1\n}')

    var decoder = JSONDecoder(strict=False)
    assert_equal(decoder.decode('"a\nb"').string(), "a\nb")


def test_raw_decode_example() raises:
    var text = String('{"a":1}{"b":2}')
    var first, after = JSONDecoder().raw_decode(text)
    var second, _ = JSONDecoder().raw_decode(text, after)
    assert_equal(dumps(first), '{"a": 1}')
    assert_equal(dumps(second), '{"b": 2}')


def test_hook_example() raises:
    var doc = loads[ParseInt=KeepLiteral]("123456789012345678901234567890")
    assert_equal(doc.string(), "123456789012345678901234567890")


def test_cycle_example() raises:
    var doc = JSONValue.object()
    doc["self"] = doc
    var rejected = False
    try:
        _ = dumps(doc)
    except:
        rejected = True
    assert_true(rejected)


def test_documented_deviations() raises:
    # Integers wider than 64 bits widen to floats.
    var big = loads("123456789012345678901234567890")
    assert_true(big.is_float())

    # An unpaired surrogate escape decodes to U+FFFD.
    assert_equal(loads('"\\ud800"').string(), "�")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
