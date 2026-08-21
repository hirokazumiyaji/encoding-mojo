"""Tests for `dumps`.

Every expected string is what `tomli_w` 1.2.0 produces for the document
`tomllib` loads from the same text, so a case reads as a round trip: load the
TOML on the left, write it again, and get the text on the right.
"""

from std.testing import TestSuite, assert_equal, assert_raises

from json import loads as json_loads
from toml import dumps, loads


def _round(
    text: StringSlice,
    expected: StringSlice,
    *,
    multiline_strings: Bool = False,
    indent: Int = 4,
) raises:
    """Loads `text`, writes it again and compares with `expected`.

    Args:
        text: A TOML document to load.
        expected: What `tomli_w.dumps` produces for the loaded document.
        multiline_strings: Whether strings holding newlines may use `\"\"\"`.
        indent: Spaces per level inside a multi-line array.

    Raises:
        If loading or writing fails, or the output differs.
    """
    assert_equal(
        dumps(loads(text), multiline_strings=multiline_strings, indent=indent),
        expected,
        "dumping " + repr(String(text)),
    )


def test_dump_simple_table() raises:
    _round('a = 1\nb = "two"\n', 'a = 1\nb = "two"\n')


def test_dump_keeps_insertion_order() raises:
    _round("z = 1\na = 2\nm = 3\n", "z = 1\na = 2\nm = 3\n")


def test_dump_collapses_empty_parents() raises:
    _round("[a.b]\nc = 1\n", "[a.b]\nc = 1\n")


def test_dump_writes_a_lone_table() raises:
    _round("[t]\nx = 1\n", "[t]\nx = 1\n")


def test_dump_puts_scalars_before_tables() raises:
    _round("y = 2\n[t]\nx = 1\n", "y = 2\n\n[t]\nx = 1\n")


def test_dump_partly_collapsed_parent_keeps_its_header() raises:
    _round("[a]\nx = 1\n[a.b]\nc = 2\n", "[a]\nx = 1\n\n[a.b]\nc = 2\n")


def test_dump_arrays_are_always_multi_line() raises:
    _round("a = [1, 2, 3]\n", "a = [\n    1,\n    2,\n    3,\n]\n")


def test_dump_empty_array_stays_on_one_line() raises:
    _round("a = []\n", "a = []\n")


def test_dump_nested_arrays_indent_further() raises:
    _round(
        "a = [[1, 2], [3]]\n",
        (
            "a = [\n    [\n        1,\n        2,\n    ],\n    [\n        3,\n "
            "   ],\n]\n"
        ),
    )


def test_dump_short_array_of_tables_is_inline() raises:
    _round(
        '[[products]]\nname = "A"\n[[products]]\nname = "B"\n',
        'products = [\n    { name = "A" },\n    { name = "B" },\n]\n',
    )


def test_dump_array_of_tables_falls_back_to_sections() raises:
    _round("[[p]]\na = [1, 2]\n", "[[p]]\na = [\n    1,\n    2,\n]\n")


def test_dump_one_unsuitable_element_moves_them_all() raises:
    _round(
        "[[p]]\na = 1\n[[p]]\nb = [1, 2]\n",
        "[[p]]\na = 1\n\n[[p]]\nb = [\n    1,\n    2,\n]\n",
    )


def test_dump_long_inline_table_moves_to_sections() raises:
    # A rendered element wider than 100 characters is not inlined.
    _round(
        '[[p]]\nk = "' + "x" * 90 + '"\n',
        '[[p]]\nk = "' + "x" * 90 + '"\n',
    )
    _round(
        '[[p]]\nk = "' + "x" * 80 + '"\n',
        'p = [\n    { k = "' + "x" * 80 + '" },\n]\n',
    )


def test_dump_array_of_tables_inside_an_array_of_tables() raises:
    _round(
        "[[p]]\n[[p.q]]\nr = [1, 2]\n",
        "[[p]]\n\n[[p.q]]\nr = [\n    1,\n    2,\n]\n",
    )


def test_dump_empty_table() raises:
    _round("[empty_table]\n", "[empty_table]\n")


def test_dump_empty_document() raises:
    _round("", "")


def test_dump_inline_table_becomes_a_section() raises:
    _round('a = { b = 1, c = "x" }\n', '[a]\nb = 1\nc = "x"\n')


def test_dump_array_of_inline_tables_under_a_table() raises:
    _round("[a]\nb = [{ c = 1 }]\n", "[a]\nb = [\n    { c = 1 },\n]\n")


def test_dump_floats_use_python_repr() raises:
    _round(
        (
            "a = 1.0\nb = 1e20\nc = inf\nd = -inf\ne = nan\nf = 0.5\ng ="
            " -0.0\nh = 1e-20\ni = 3.14\n"
        ),
        (
            "a = 1.0\nb = 1e+20\nc = inf\nd = -inf\ne = nan\nf = 0.5\ng ="
            " -0.0\nh = 1e-20\ni = 3.14\n"
        ),
    )


def test_dump_integers() raises:
    _round(
        "a = 0\nb = -1\nc = 9223372036854775807\nd = -9223372036854775808\n",
        "a = 0\nb = -1\nc = 9223372036854775807\nd = -9223372036854775808\n",
    )


def test_dump_booleans() raises:
    _round("t = true\nf = false\n", "t = true\nf = false\n")


def test_dump_escapes_only_what_it_must() raises:
    # A tab is legal inside a basic string, so it is written as itself.
    _round(
        (
            'a = "line\\nbreak"\nb = "quote\\"here"\nc = "tab\\there"\nd ='
            ' "back\\\\slash"\ne = "\\u0000\\u0001\\u007f"\n'
        ),
        (
            'a = "line\\nbreak"\nb = "quote\\"here"\nc = "tab\there"\nd ='
            ' "back\\\\slash"\ne = "\\u0000\\u0001\\u007f"\n'
        ),
    )


def test_dump_writes_non_ascii_verbatim() raises:
    _round('f = "unicode: é 中"\n', 'f = "unicode: é 中"\n')


def test_dump_quotes_keys_only_when_needed() raises:
    _round(
        (
            'bare_key = 1\nbare-key2 = 2\n1234 = 3\n"with space" ='
            ' 4\n"with.dot" = 5\n"" = 6\n"é" = 7\n'
        ),
        (
            'bare_key = 1\nbare-key2 = 2\n1234 = 3\n"with space" ='
            ' 4\n"with.dot" = 5\n"" = 6\n"é" = 7\n'
        ),
    )


def test_dump_quotes_table_names_when_needed() raises:
    _round('["a b"]\nc = 1\n', '["a b"]\nc = 1\n')
    _round('["a.b"]\nc = 1\n', '["a.b"]\nc = 1\n')


def test_dump_multiline_strings_are_opt_in() raises:
    _round('a = "line\\nbreak"\n', 'a = "line\\nbreak"\n')
    _round(
        'a = "line\\nbreak"\n',
        'a = """\nline\nbreak"""\n',
        multiline_strings=True,
    )


def test_dump_multiline_still_escapes_quotes() raises:
    _round(
        'a = "he said \\"hi\\"\\nbye"\n',
        'a = """\nhe said \\"hi\\"\nbye"""\n',
        multiline_strings=True,
    )


def test_dump_multiline_keeps_a_trailing_newline() raises:
    _round('a = "x\\n"\n', 'a = """\nx\n"""\n', multiline_strings=True)


def test_dump_multiline_escapes_control_characters() raises:
    _round(
        'a = "a\\u0001b\\nc"\n',
        'a = """\na\\u0001b\nc"""\n',
        multiline_strings=True,
    )


def test_dump_multiline_needs_a_newline_to_apply() raises:
    _round('a = "plain"\n', 'a = "plain"\n', multiline_strings=True)


def test_dump_multiline_normalizes_crlf() raises:
    _round('a = "x\\r\\ny"\n', 'a = """\nx\ny"""\n', multiline_strings=True)


def test_dump_indent_width_is_configurable() raises:
    _round("a = [1, 2]\n", "a = [\n  1,\n  2,\n]\n", indent=2)
    _round("a = [1, 2]\n", "a = [\n1,\n2,\n]\n", indent=0)


def test_dump_rejects_a_negative_indent() raises:
    with assert_raises(contains="Indent width must be non-negative"):
        _ = dumps(loads("a = 1\n"), indent=-1)


def test_dump_dates_round_trip_as_text() raises:
    # There is no date type on the tape, so a date-time keeps its literal
    # spelling and is written back as a string.
    _round("a = 1979-05-27T07:32:00Z\n", 'a = "1979-05-27T07:32:00Z"\n')


def test_dump_rejects_a_non_table_document() raises:
    with assert_raises(contains="must be a table"):
        _ = dumps(json_loads("[1, 2]"))


def test_dump_rejects_null() raises:
    with assert_raises(
        contains="Object of type 'NoneType' is not TOML serializable"
    ):
        _ = dumps(json_loads('{"a": null}'))
    with assert_raises(
        contains="Object of type 'NoneType' is not TOML serializable"
    ):
        _ = dumps(json_loads('{"a": [null]}'))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
