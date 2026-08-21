"""Tests for `read_records` and `write_records`.

Every expected record is what CPython 3.11's `csv.DictReader` produces, and
every expected document what `csv.DictWriter` produces.
"""

from std.testing import TestSuite, assert_equal, assert_raises

from json import dumps
from serde import Value

from csv import Dialect, read_records, write_records


def _rendered(records: List[Value]) raises -> String:
    """Renders records as one compact JSON array.

    Args:
        records: The records to render.

    Returns:
        A string such as `[{"a":"1"}]`.

    Raises:
        If a record cannot be rendered.
    """
    var out = String("[")
    for i in range(len(records)):
        if i:
            out += ","
        out += dumps(records[i], separators=(",", ":"))
    out += "]"
    return out^


def test_reads_the_header() raises:
    assert_equal(_rendered(read_records("a,b\n1,2\n")), '[{"a":"1","b":"2"}]')


def test_short_record_is_padded() raises:
    assert_equal(_rendered(read_records("a,b\n1\n")), '[{"a":"1","b":""}]')
    assert_equal(
        _rendered(read_records("a,b\n1\n", restval="V")),
        '[{"a":"1","b":"V"}]',
    )


def test_long_record_keeps_the_surplus() raises:
    # Without a `restkey` the surplus is dropped, which is CPython's default.
    assert_equal(_rendered(read_records("a,b\n1,2,3\n")), '[{"a":"1","b":"2"}]')
    assert_equal(
        _rendered(read_records("a,b\n1,2,3\n", restkey="R")),
        '[{"a":"1","b":"2","R":["3"]}]',
    )


def test_fieldnames_may_be_given() raises:
    var names: List[String] = ["a", "b"]
    assert_equal(
        _rendered(read_records("1,2\n", fieldnames=names.copy())),
        '[{"a":"1","b":"2"}]',
    )


def test_blank_lines_are_skipped() raises:
    assert_equal(_rendered(read_records("a,b\n\n1,2\n")), '[{"a":"1","b":"2"}]')


def test_empty_document_has_no_records() raises:
    assert_equal(_rendered(read_records("")), "[]")
    assert_equal(_rendered(read_records("a,b\n")), "[]")


def test_writes_a_header_and_rows() raises:
    var names: List[String] = ["a", "b"]
    var records = read_records("a,b\n1,2\n")
    assert_equal(write_records(records, names), "a,b\r\n1,2\r\n")
    assert_equal(write_records(records, names, header=False), "1,2\r\n")


def test_missing_field_writes_restval() raises:
    var names: List[String] = ["a", "b"]
    var records = read_records("1\n", fieldnames=List[String]([String("a")]))
    assert_equal(write_records(records, names), "a,b\r\n1,\r\n")
    assert_equal(write_records(records, names, restval="X"), "a,b\r\n1,X\r\n")


def test_a_field_outside_fieldnames_is_an_error() raises:
    var names: List[String] = ["a", "b"]
    var records = read_records("a,c\n1,3\n")
    with assert_raises(contains="fields not in fieldnames: 'c'"):
        _ = write_records(records, names)
    assert_equal(
        write_records(records, names, extrasaction_raise=False),
        "a,b\r\n1,\r\n",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
