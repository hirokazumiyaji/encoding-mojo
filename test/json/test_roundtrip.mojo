"""Round-trip tests: `loads(dumps(v)) == v` over a range of documents."""

from std.testing import TestSuite, assert_equal, assert_true

from json import JSONValue, dumps, loads


def _assert_round_trips(text: StringSlice) raises:
    """Checks that decoding, encoding and decoding again is stable.

    Args:
        text: The JSON document to check.

    Raises:
        If the document does not survive the round trip.
    """
    var once = loads(text)
    var twice = loads(dumps(once))
    assert_equal(once, twice, "round trip changed " + String(text))
    assert_equal(dumps(once), dumps(twice))


def test_round_trip_scalars() raises:
    _assert_round_trips("null")
    _assert_round_trips("true")
    _assert_round_trips("false")
    _assert_round_trips("0")
    _assert_round_trips("-1234567890123")
    _assert_round_trips("1.25")
    _assert_round_trips("1e-300")
    _assert_round_trips('"plain"')


def test_round_trip_strings_with_escapes() raises:
    _assert_round_trips('"quote:\\" backslash:\\\\ newline:\\n tab:\\t"')
    _assert_round_trips('"control:\\u0000\\u001f"')
    _assert_round_trips('"日本語 emoji:\\ud83d\\ude00"')


def test_round_trip_containers() raises:
    _assert_round_trips("[]")
    _assert_round_trips("{}")
    _assert_round_trips("[[[[[1]]]]]")
    _assert_round_trips('{"a": {"b": {"c": [1, 2, {"d": null}]}}}')


def test_round_trip_mixed_document() raises:
    _assert_round_trips(
        '{"id": 12345, "name": "Ada Lovelace", "active": true, "score": 99.5,'
        ' "tags": ["math", "computing"], "address": {"city": "London",'
        ' "zip": null}, "history": [[1, 2], [3, 4]]}'
    )


def test_round_trip_preserves_int_float_distinction() raises:
    assert_equal(dumps(loads("1")), "1")
    assert_equal(dumps(loads("1.0")), "1.0")
    assert_equal(dumps(loads("1e2")), "100.0")


def test_round_trip_through_pretty_printing() raises:
    var doc = loads('{"a": [1, {"b": 2}], "c": "d"}')
    var pretty = dumps(doc, indent=4)
    assert_equal(loads(pretty), doc)


def test_round_trip_without_ensure_ascii() raises:
    var doc = loads('"日本語 😀"')
    assert_equal(loads(dumps(doc, ensure_ascii=False)), doc)


def test_built_document_round_trips() raises:
    var doc = JSONValue.object()
    doc["nums"] = JSONValue.array()
    for i in range(10):
        doc["nums"].append(i * i)
    doc["nested"] = JSONValue.object()
    doc["nested"]["deep"] = "value"
    assert_equal(loads(dumps(doc)), doc)
    assert_equal(
        dumps(doc),
        (
            '{"nums": [0, 1, 4, 9, 16, 25, 36, 49, 64, 81], "nested":'
            ' {"deep": "value"}}'
        ),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
