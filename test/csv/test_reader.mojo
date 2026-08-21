"""Tests for `reader`.

Every expected row here is what CPython 3.11's `csv.reader` produces for the
same text, read from a `StringIO` opened with `newline=""` so that the csv
state machine sees the line endings as written.
"""

from std.testing import TestSuite, assert_equal, assert_raises

from csv import (
    QUOTE_ALL,
    QUOTE_NONE,
    QUOTE_NONNUMERIC,
    Dialect,
    excel_tab,
    reader,
    unix,
)


def _render(rows: List[List[String]]) -> String:
    """Renders rows the way `repr` would in Python, for one assertion.

    Args:
        rows: The rows to render.

    Returns:
        A string such as `[['a', 'b'], ['1', '2']]`.
    """
    var out = String("[")
    for i in range(len(rows)):
        if i:
            out += ", "
        out += "["
        for j in range(len(rows[i])):
            if j:
                out += ", "
            out += "'" + rows[i][j] + "'"
        out += "]"
    out += "]"
    return out^


def _check(text: StringSlice, expected: StringSlice) raises:
    """Reads `text` and compares the rows with `expected`.

    Args:
        text: The CSV document.
        expected: What `csv.reader` produces, rendered like Python's `repr`.

    Raises:
        If reading fails or the rows differ.
    """
    assert_equal(
        _render(reader(text)), expected, "reading " + repr(String(text))
    )


def _check_with(
    text: StringSlice, dialect: Dialect, expected: StringSlice
) raises:
    """Reads `text` with `dialect` and compares the rows with `expected`.

    Args:
        text: The CSV document.
        dialect: The format parameters to read with.
        expected: What `csv.reader` produces, rendered like Python's `repr`.

    Raises:
        If reading fails or the rows differ.
    """
    assert_equal(
        _render(reader(text, dialect)),
        expected,
        "reading " + repr(String(text)),
    )


def test_plain_rows() raises:
    _check("a,b,c\n1,2,3\n", "[['a', 'b', 'c'], ['1', '2', '3']]")


def test_last_row_needs_no_terminator() raises:
    _check("a,b\n1,2", "[['a', 'b'], ['1', '2']]")


def test_empty_document() raises:
    _check("", "[]")


def test_blank_line_is_an_empty_row() raises:
    _check("a,b\n\nc,d\n", "[['a', 'b'], [], ['c', 'd']]")
    _check("\r\n\r\n", "[[], []]")


def test_line_endings() raises:
    _check("a,b\r\n1,2\r\n", "[['a', 'b'], ['1', '2']]")
    _check("a,b\r1,2\r", "[['a', 'b'], ['1', '2']]")
    _check("a\r\rb\n", "[['a'], [], ['b']]")
    _check("a\n\rb\n", "[['a'], [], ['b']]")
    _check("a\r", "[['a']]")


def test_quoted_fields() raises:
    _check('"a","b"\n', "[['a', 'b']]")
    _check('"a,b",c\n', "[['a,b', 'c']]")
    _check('"a\nb",c\n', "[['a\nb', 'c']]")
    _check('"a\rb"\n', "[['a\rb']]")
    _check('"a\r\nb"\n', "[['a\r\nb']]")
    _check('"a\r\rb"\n', "[['a\r\rb']]")
    _check('""\n', "[['']]")


def test_doubled_quotes() raises:
    _check('"a""b"\n', "[['a\"b']]")
    _check('""""\n', "[['\"']]")


def test_quotes_that_are_not_quoting() raises:
    # A quote away from the start of a field is ordinary data.
    _check('a"b,c\n', "[['a\"b', 'c']]")
    _check('ab"c"d\n', "[['ab\"c\"d']]")
    # Data after a closing quote joins the same field.
    _check('"ab"cd\n', "[['abcd']]")


def test_unterminated_quote_runs_to_the_end() raises:
    _check('"abc\n', "[['abc\n']]")
    _check('"a', "[['a']]")


def test_empty_fields() raises:
    _check(",,\n", "[['', '', '']]")
    _check("a,b,\n", "[['a', 'b', '']]")
    _check(',""\n', "[['', '']]")


def test_spaces_are_data_by_default() raises:
    _check("a, b\n", "[['a', ' b']]")
    _check(" \n", "[[' ']]")
    _check('a, "b"\n', "[['a', ' \"b\"']]")


def test_skipinitialspace() raises:
    var d = Dialect(skipinitialspace=True)
    _check_with("a, b\n", d, "[['a', 'b']]")
    _check_with('a, "b"\n', d, "[['a', 'b']]")


def test_other_delimiters() raises:
    _check_with("a\tb\n", excel_tab(), "[['a', 'b']]")
    _check_with("a;b\n", Dialect(delimiter=";"), "[['a', 'b']]")
    # A delimiter may be any single character, not only an ASCII one.
    _check_with('a€"b€c"\n', Dialect(delimiter="€"), "[['a', 'b€c']]")


def test_escapechar() raises:
    var d = Dialect(escapechar="\\")
    _check_with("a\\,b,c\n", d, "[['a,b', 'c']]")
    _check_with('"a\\"b",c\n', d, "[['a\"b', 'c']]")


def test_doublequote_off() raises:
    _check_with('"a""b"\n', Dialect(doublequote=False), "[['a\"b\"']]")
    _check_with(
        '"a\\"b"\n',
        Dialect(doublequote=False, escapechar="\\"),
        "[['a\"b']]",
    )


def test_quote_none_reads_quotes_as_data() raises:
    _check_with('a,"b"\n', Dialect(quoting=QUOTE_NONE), "[['a', '\"b\"']]")


def test_quote_all_changes_nothing_on_the_way_in() raises:
    _check_with('a,"b"\n', unix(), "[['a', 'b']]")
    _check_with('a,"b"\n', Dialect(quoting=QUOTE_ALL), "[['a', 'b']]")


def test_quote_nonnumeric_reads_numbers() raises:
    # CPython turns an unquoted field into a float; there is no such type in
    # a row of text, so the float is rendered the way Python's `str` would.
    var d = Dialect(quoting=QUOTE_NONNUMERIC)
    _check_with('1,"a"\n', d, "[['1.0', 'a']]")
    _check_with("2.5,-3e2\n", d, "[['2.5', '-300.0']]")
    _check_with(',""\n', d, "[['', '']]")
    with assert_raises(contains="could not convert string to float: 'a'"):
        _ = reader("a,b\n", d)


def test_control_characters_are_data() raises:
    _check("a\x00b,c\n", "[['a\x00b', 'c']]")


def test_strict_rejects_data_after_a_closing_quote() raises:
    with assert_raises(contains="',' expected after '\"'"):
        _ = reader('"a"b,c\n', Dialect(strict=True))


def test_strict_rejects_an_unterminated_quote() raises:
    with assert_raises(contains="unexpected end of data"):
        _ = reader('"a', Dialect(strict=True))
    with assert_raises(contains="unexpected end of data"):
        _ = reader('"a\n', Dialect(strict=True))
    # A field that simply ran to the end of the text is fine.
    _check_with("a", Dialect(strict=True), "[['a']]")


def test_field_size_limit() raises:
    with assert_raises(contains="field larger than field limit"):
        _ = reader("aaaaaa\n", Dialect(field_size_limit=3))
    _check_with("aaa\n", Dialect(field_size_limit=3), "[['aaa']]")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
