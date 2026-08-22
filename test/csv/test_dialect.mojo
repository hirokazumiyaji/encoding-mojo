"""Tests for `Dialect`, which is where CPython's `fmtparams` live here.

Every rejection carries the wording CPython 3.11 uses for the same mistake.
"""

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from csv import (
    FIELD_SIZE_LIMIT,
    QUOTE_ALL,
    QUOTE_MINIMAL,
    QUOTE_NONE,
    QUOTE_NONNUMERIC,
    Dialect,
    excel,
    excel_tab,
    unix,
)


def test_excel_is_the_default() raises:
    var d = excel()
    assert_equal(d.delimiter, UInt32(0x2C))
    assert_equal(d.quotechar, UInt32(0x22))
    assert_true(d.has_quotechar)
    assert_true(not d.has_escapechar)
    assert_true(d.doublequote)
    assert_true(not d.skipinitialspace)
    assert_equal(d.lineterminator, "\r\n")
    assert_equal(d.quoting, QUOTE_MINIMAL)
    assert_true(not d.strict)
    assert_equal(d.field_size_limit, FIELD_SIZE_LIMIT)
    # The keyword constructor with no arguments builds the same thing.
    assert_equal(Dialect().delimiter, d.delimiter)


def test_the_other_registered_dialects() raises:
    assert_equal(excel_tab().delimiter, UInt32(0x09))
    assert_equal(excel_tab().lineterminator, "\r\n")
    assert_equal(unix().lineterminator, "\n")
    assert_equal(unix().quoting, QUOTE_ALL)


def test_a_parameter_must_be_one_character() raises:
    with assert_raises(contains='"delimiter" must be a 1-character string'):
        _ = Dialect(delimiter="ab")
    with assert_raises(contains='"delimiter" must be a 1-character string'):
        _ = Dialect(delimiter="")
    with assert_raises(contains='"quotechar" must be a 1-character string'):
        _ = Dialect(quotechar="ab")
    with assert_raises(contains='"escapechar" must be a 1-character string'):
        _ = Dialect(escapechar="ab")
    # One character, not one byte.
    assert_equal(Dialect(delimiter="€").delimiter, UInt32(0x20AC))


def test_quoting_must_name_a_mode() raises:
    with assert_raises(contains='bad "quoting" value'):
        _ = Dialect(quoting=9)
    with assert_raises(contains='bad "quoting" value'):
        _ = Dialect(quoting=-1)


def test_no_quotechar_needs_quote_none() raises:
    with assert_raises(contains="quotechar must be set if quoting enabled"):
        _ = Dialect(quotechar=None)
    with assert_raises(contains="quotechar must be set if quoting enabled"):
        _ = Dialect(quotechar=None, quoting=QUOTE_NONNUMERIC)
    var d = Dialect(quotechar=None, quoting=QUOTE_NONE)
    assert_true(not d.has_quotechar)
    assert_true(not d.quotes())


def test_quotes_reports_whether_a_quote_is_live() raises:
    assert_true(Dialect().quotes())
    assert_true(not Dialect(quoting=QUOTE_NONE).quotes())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
