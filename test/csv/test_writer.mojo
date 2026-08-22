"""Tests for `writer`.

Every expected string is what CPython 3.11's `csv.writer` produces for the
same rows, written into a `StringIO` opened with `newline=""`.
"""

from std.testing import TestSuite, assert_equal, assert_raises

from csv import (
    QUOTE_ALL,
    QUOTE_NONE,
    QUOTE_NONNUMERIC,
    Dialect,
    excel_tab,
    unix,
    writer,
    writes,
)


def _check(rows: List[List[String]], expected: StringSlice) raises:
    """Writes `rows` and compares the text with `expected`.

    Args:
        rows: The records to write.
        expected: What `csv.writer` produces.

    Raises:
        If writing fails or the text differs.
    """
    assert_equal(writes(rows), expected)


def _check_with(
    rows: List[List[String]], dialect: Dialect, expected: StringSlice
) raises:
    """Writes `rows` with `dialect` and compares the text with `expected`.

    Args:
        rows: The records to write.
        dialect: The format parameters to write with.
        expected: What `csv.writer` produces.

    Raises:
        If writing fails or the text differs.
    """
    assert_equal(writes(rows, dialect), expected)


def test_plain_rows() raises:
    _check([["a", "b"], ["1", "2"]], "a,b\r\n1,2\r\n")


def test_empty_row() raises:
    _check([List[String]()], "\r\n")


def test_a_single_empty_field_is_quoted() raises:
    # Without the quotes the row would read back as an empty row.
    _check([["".copy()]], '""\r\n')
    _check([["", ""]], ",\r\n")


def test_quotes_only_what_needs_it() raises:
    _check([["a,b", "c"]], '"a,b",c\r\n')
    _check([['a"b']], '"a""b"\r\n')
    _check([["a\nb"]], '"a\nb"\r\n')
    _check([["a\rb"]], '"a\rb"\r\n')
    _check([['"']], '""""\r\n')
    _check([[" a"]], " a\r\n")


def test_quote_all() raises:
    _check_with([["a", "1"]], Dialect(quoting=QUOTE_ALL), '"a","1"\r\n')


def test_quote_none_needs_an_escapechar() raises:
    with assert_raises(contains="need to escape, but no escapechar set"):
        _ = writes([["a,b"]], Dialect(quoting=QUOTE_NONE))
    _check_with(
        [["a,b"]],
        Dialect(quoting=QUOTE_NONE, escapechar="\\"),
        "a\\,b\r\n",
    )
    _check_with(
        [["a\nb"]],
        Dialect(quoting=QUOTE_NONE, escapechar="\\"),
        "a\\\nb\r\n",
    )
    _check_with(
        [['a"b']],
        Dialect(quoting=QUOTE_NONE, escapechar="\\"),
        'a\\"b\r\n',
    )
    # The escape character escapes itself.
    _check_with(
        [["a\\b"]],
        Dialect(quoting=QUOTE_NONE, escapechar="\\"),
        "a\\\\b\r\n",
    )


def test_quote_none_cannot_write_a_single_empty_field() raises:
    with assert_raises(contains="single empty field record must be quoted"):
        _ = writes([["".copy()]], Dialect(quoting=QUOTE_NONE))


def test_doublequote_off_needs_an_escapechar() raises:
    with assert_raises(contains="need to escape, but no escapechar set"):
        _ = writes([['a"b']], Dialect(doublequote=False))
    _check_with(
        [['a"b']],
        Dialect(doublequote=False, escapechar="\\"),
        'a\\"b\r\n',
    )


def test_escapechar_is_escaped_inside_a_quoted_field() raises:
    _check_with([["a\\b"]], Dialect(escapechar="\\"), "a\\\\b\r\n")
    # Doubling still wins over escaping when both are available.
    _check_with([['a"b,c']], Dialect(escapechar="\\"), '"a""b,c"\r\n')


def test_lineterminator() raises:
    _check_with([["a"]], Dialect(lineterminator="\n"), "a\n")
    _check_with([["a", "b"]], unix(), '"a","b"\n')
    _check_with([["a", "b"]], excel_tab(), "a\tb\r\n")
    # Any character of the terminator forces quotes.
    _check_with([["a|b"]], Dialect(lineterminator="|"), '"a|b"|')
    _check_with([["a|b"]], Dialect(lineterminator="|!"), '"a|b"|!')
    # A terminator of LF alone still quotes a field holding CR.
    _check_with([["a\rb"]], Dialect(lineterminator="\n"), '"a\rb"\n')


def test_other_delimiters() raises:
    _check_with([["a", "b"]], Dialect(delimiter="\t"), "a\tb\r\n")
    _check_with([["a,b"]], Dialect(quotechar="'"), "'a,b'\r\n")
    _check_with([["a", "b€c"]], Dialect(delimiter="€"), 'a€"b€c"\r\n')


def test_quote_nonnumeric_quotes_everything_here() raises:
    # A row is text, so every field is a non-number as far as the writer can
    # tell, which is what CPython does with a row of strings too.
    _check_with([["a", "1"]], Dialect(quoting=QUOTE_NONNUMERIC), '"a","1"\r\n')


def test_writer_accumulates() raises:
    var w = writer()
    w.writerow(["a", "b"])
    w.writerow(["1", "2"])
    assert_equal(w.text(), "a,b\r\n1,2\r\n")


def test_writerows() raises:
    var w = writer(unix())
    w.writerows([["a"], ["b"]])
    assert_equal(w.text(), '"a"\n"b"\n')


def test_a_failed_row_leaves_the_document_alone() raises:
    # CPython assembles the record before touching the output, so a field it
    # cannot write does not leave half a row behind.
    var w = writer(Dialect(doublequote=False))
    with assert_raises(contains="need to escape, but no escapechar set"):
        w.writerow(["ok", 'bad"'])
    assert_equal(w.text(), "")
    w.writerow(["next"])
    assert_equal(w.text(), "next\r\n")


def test_carriage_returns_may_be_dialect_characters() raises:
    _check_with([["a", "b"]], Dialect(delimiter="\n"), "a\nb\r\n")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
