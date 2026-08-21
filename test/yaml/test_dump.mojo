"""Tests for `safe_dump`.

Every expected string is what PyYAML 6.0.1's `yaml.safe_dump` produces for the
same value, with the exceptions the package README lists.
"""

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from yaml import safe_dump, safe_dump_all, safe_load, safe_load_all


def _round(text: StringSlice, expected: StringSlice) raises:
    """Loads `text`, dumps it again and compares with `expected`.

    Args:
        text: A YAML document to load.
        expected: What PyYAML's `safe_dump` produces for the loaded value.

    Raises:
        If loading or dumping fails, or the output differs.
    """
    assert_equal(
        safe_dump(safe_load(text)), expected, "dumping " + String(text)
    )


def test_dump_simple_mapping() raises:
    _round("a: 1\nb: two\n", "a: 1\nb: two\n")


def test_dump_sorts_keys_by_default() raises:
    _round("z: 1\na: 2\nm: 3\n", "a: 2\nm: 3\nz: 1\n")


def test_dump_keeps_order_when_asked() raises:
    assert_equal(
        safe_dump(safe_load("z: 1\na: 2\n"), sort_keys=False), "z: 1\na: 2\n"
    )


def test_dump_simple_sequence() raises:
    _round("- 1\n- 2\n- 3\n", "- 1\n- 2\n- 3\n")


def test_dump_nested_mappings() raises:
    _round("a:\n  b:\n    c: 1\n", "a:\n  b:\n    c: 1\n")


def test_dump_sequence_under_key_is_not_indented() raises:
    # PyYAML puts a block sequence at its key's own column.
    _round("a:\n  - 1\n  - 2\n", "a:\n- 1\n- 2\n")


def test_dump_mapping_inside_sequence() raises:
    _round("- a: 1\n  b: 2\n- c: 3\n", "- a: 1\n  b: 2\n- c: 3\n")


def test_dump_nested_sequence() raises:
    _round(
        "deep:\n  - - 1\n    - 2\n  - k: v\n", "deep:\n- - 1\n  - 2\n- k: v\n"
    )


def test_dump_indent_option() raises:
    var doc = safe_load("a:\n  b: 1\n")
    assert_equal(safe_dump(doc, indent=4), "a:\n    b: 1\n")
    assert_equal(
        safe_dump(safe_load("- - 1\n  - 2\n"), indent=4), "-   - 1\n    - 2\n"
    )


def test_dump_scalars() raises:
    _round("empty:\nt: true\nf: false\n", "empty: null\nf: false\nt: true\n")


def test_dump_floats() raises:
    _round("f: 1.5\n", "f: 1.5\n")
    _round("f: 1.0\n", "f: 1.0\n")
    _round("f: -2.5\n", "f: -2.5\n")
    _round("big: 1.0e+20\n", "big: 1.0e+20\n")
    _round("small: 1.0e-20\n", "small: 1.0e-20\n")
    _round("i: .inf\nn: -.inf\nx: .nan\n", "i: .inf\nn: -.inf\nx: .nan\n")


def test_dump_quotes_only_when_needed() raises:
    _round(
        "s: hello\nn: '123'\ny: 'yes'\ncolon: 'a: b'\nhash: 'a #b'\n",
        "colon: 'a: b'\nhash: 'a #b'\nn: '123'\ns: hello\ny: 'yes'\n",
    )


def test_dump_leaves_inner_punctuation_plain() raises:
    _round(
        'a: x:y\nb: a#b\nc: it\'s\nd: say "hi"\ne: -x\nf: ?x\n',
        'a: x:y\nb: a#b\nc: it\'s\nd: say "hi"\ne: -x\nf: ?x\n',
    )


def test_dump_quotes_leading_indicators() raises:
    _round(
        "a: '- x'\nb: '#x'\nc: '*x'\nd: '&x'\ne: '!x'\nf: '|x'\ng: '>x'\n",
        "a: '- x'\nb: '#x'\nc: '*x'\nd: '&x'\ne: '!x'\nf: '|x'\ng: '>x'\n",
    )


def test_dump_quotes_strings_that_would_resolve() raises:
    _round(
        "a: 'null'\nb: '~'\nc: '0x10'\nd: '.inf'\ne: '1:30'\nf: '2020-01-01'\n",
        "a: 'null'\nb: '~'\nc: '0x10'\nd: '.inf'\ne: '1:30'\nf: '2020-01-01'\n",
    )


def test_dump_quotes_empty_and_padded_strings() raises:
    _round("a: ''\nb: ' x'\nc: 'x '\n", "a: ''\nb: ' x'\nc: 'x '\n")


def test_dump_double_quotes_control_characters() raises:
    _round('a: "a\\tb"\n', 'a: "a\\tb"\n')
    _round('a: "a\\x01b"\n', 'a: "a\\x01b"\n')


def test_dump_escapes_non_ascii_by_default() raises:
    _round('u: "\\u65e5\\u672c\\u8a9e"\n', 'u: "\\u65E5\\u672C\\u8A9E"\n')
    _round('e: "\\U0001F600"\n', 'e: "\\U0001F600"\n')


def test_dump_allow_unicode() raises:
    assert_equal(
        safe_dump(safe_load("u: 日本語\n"), allow_unicode=True), "u: 日本語\n"
    )


def test_dump_multi_line_string() raises:
    _round("multi: |\n  line1\n  line2\n", "multi: 'line1\n\n  line2\n\n  '\n")


def test_dump_empty_collections() raises:
    _round("a: []\nb: {}\n", "a: []\nb: {}\n")


def test_dump_top_level_scalar_gets_an_end_marker() raises:
    assert_equal(safe_dump(safe_load("scalar\n")), "scalar\n...\n")
    assert_equal(safe_dump(safe_load("42\n")), "42\n...\n")
    assert_equal(safe_dump(safe_load("")), "null\n...\n")


def test_dump_flow_style() raises:
    assert_equal(
        safe_dump(safe_load("a:\n  - 1\n  - 2\n"), default_flow_style=True),
        "{a: [1, 2]}\n",
    )


def test_dump_explicit_start() raises:
    assert_equal(
        safe_dump(safe_load("a: 1\n"), explicit_start=True), "---\na: 1\n"
    )


def test_dump_all() raises:
    var docs = safe_load_all("a: 1\n---\nb: 2\n")
    assert_equal(safe_dump_all(docs), "a: 1\n---\nb: 2\n")


def test_load_all_reads_every_document() raises:
    var docs = safe_load_all("---\na: 1\n---\nb: 2\n---\n- 3\n")
    assert_equal(len(docs), 3)
    assert_equal(docs[0]["a"].int(), 1)
    assert_equal(docs[2][0].int(), 3)


def test_round_trip_through_our_own_output() raises:
    var text = (
        "name: mojo\n"
        "tags:\n"
        "- fast\n"
        "- safe\n"
        "nested:\n"
        "  a: 1\n"
        "  b:\n"
        "  - x: 1\n"
        "    y: 2\n"
        "quoted: 'yes'\n"
    )
    var doc = safe_load(text)
    assert_equal(safe_load(safe_dump(doc)), doc)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
