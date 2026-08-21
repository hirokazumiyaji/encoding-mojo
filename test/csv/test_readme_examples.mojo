"""Runs the examples from README.md and src/csv/README.md.

Documentation that has drifted is worse than none, so every snippet a reader
might copy is executed here.
"""

from std.testing import TestSuite, assert_equal, assert_raises

from json import dumps
from serde import Value

from csv import (
    QUOTE_NONE,
    Dialect,
    read_records,
    reader,
    unix,
    writer,
    writes,
)


def test_reading_example() raises:
    var rows = reader('name,city\n"Ada, L",London\n')
    assert_equal(len(rows), 2)
    assert_equal(rows[1][0], "Ada, L")


def test_awkward_cases_table() raises:
    assert_equal(reader('a"b,c\n')[0][0], 'a"b')
    assert_equal(reader('a"b,c\n')[0][1], "c")
    assert_equal(reader('"ab"cd\n')[0][0], "abcd")
    assert_equal(reader('"abc')[0][0], "abc")
    assert_equal(len(reader("a,b\r1,2")), 2)
    assert_equal(len(reader("a,b\n\nc,d")), 3)
    assert_equal(len(reader("a,b\n\nc,d")[1]), 0)


def test_strict_wording() raises:
    with assert_raises(contains="',' expected after '\"'"):
        _ = reader('"a"b,c\n', Dialect(strict=True))
    with assert_raises(contains="unexpected end of data"):
        _ = reader('"abc', Dialect(strict=True))


def test_writing_example() raises:
    var out = writer()
    out.writerow(["a", "b"])
    assert_equal(out.text(), "a,b\r\n")
    assert_equal(writes([["a", "b"]]), "a,b\r\n")
    # A row of one empty field is written quoted.
    assert_equal(writes([["".copy()]]), '""\r\n')
    # An escaped character does not force quotes.
    assert_equal(writes([["a\\b"]], Dialect(escapechar="\\")), "a\\\\b\r\n")


def test_dialect_examples() raises:
    assert_equal(reader("a;b\n", Dialect(delimiter=";"))[0][1], "b")
    assert_equal(
        reader('a,"b"\n', Dialect(quoting=QUOTE_NONE, escapechar="\\"))[0][1],
        '"b"',
    )
    assert_equal(writes([["a", "b"]], unix()), '"a","b"\n')
    # Any single character may be a delimiter.
    assert_equal(reader("a€b\n", Dialect(delimiter="€"))[0][1], "b")


def test_records_example() raises:
    assert_equal(dumps(read_records("a,b\n1,2\n")[0]), '{"a": "1", "b": "2"}')


def test_documented_deviations() raises:
    from csv import QUOTE_NONNUMERIC

    # A number read under QUOTE_NONNUMERIC comes back as Python would print it.
    assert_equal(reader("1\n", Dialect(quoting=QUOTE_NONNUMERIC))[0][0], "1.0")
    with assert_raises(contains="could not convert string to float: 'a'"):
        _ = reader("a\n", Dialect(quoting=QUOTE_NONNUMERIC))
    # `field_size_limit` belongs to the dialect.
    with assert_raises(contains="field larger than field limit"):
        _ = reader("aaaa\n", Dialect(field_size_limit=2))
    # `quotechar=None` needs QUOTE_NONE.
    with assert_raises(contains="quotechar must be set if quoting enabled"):
        _ = Dialect(quotechar=None)
    var d = Dialect(quotechar=None, quoting=QUOTE_NONE)
    assert_equal(reader('a,"b"\n', d)[0][1], '"b"')


def test_root_readme_cross_format_example() raises:
    assert_equal(
        dumps(read_records("name,tags\nmojo,fast\n")[0]),
        '{"name": "mojo", "tags": "fast"}',
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
