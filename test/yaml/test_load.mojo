"""Tests for `safe_load`.

Every expected value here is what PyYAML 6.0.1's `yaml.safe_load` produces for
the same input, rendered through `json.dumps` so one assertion covers the whole
document.
"""

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from json import dumps
from yaml import safe_load


def _check(text: StringSlice, expected: StringSlice) raises:
    """Loads `text` and compares its JSON rendering with `expected`.

    Args:
        text: The YAML document.
        expected: What PyYAML's `safe_load` produces, as compact JSON.

    Raises:
        If loading fails or the result differs.
    """
    assert_equal(
        dumps(safe_load(text), separators=(",", ":")),
        expected,
        "loading " + repr(String(text)),
    )


def test_simple_mapping() raises:
    _check("a: 1\nb: two\n", '{"a":1,"b":"two"}')


def test_simple_sequence() raises:
    _check("- 1\n- 2\n- 3\n", "[1,2,3]")


def test_nested_mappings() raises:
    _check("a:\n  b:\n    c: 1\n", '{"a":{"b":{"c":1}}}')


def test_sequence_under_mapping() raises:
    _check("a:\n  - 1\n  - 2\n", '{"a":[1,2]}')


def test_sequence_at_parent_indent() raises:
    # A block sequence may sit at the same column as the key that owns it.
    _check("a:\n- 1\n- 2\n", '{"a":[1,2]}')


def test_mapping_inside_sequence_entry() raises:
    _check("- a: 1\n  b: 2\n- c: 3\n", '[{"a":1,"b":2},{"c":3}]')


def test_nested_sequences() raises:
    _check("deep:\n  - - 1\n    - 2\n  - k: v\n", '{"deep":[[1,2],{"k":"v"}]}')


def test_comments_are_ignored() raises:
    _check(
        "key: # comment\n  value\n# full line\nother: 2\n",
        '{"key":"value","other":2}',
    )


def test_empty_values_are_null() raises:
    _check(
        "empty:\nnull_val: ~\nn2: null\n",
        '{"empty":null,"null_val":null,"n2":null}',
    )


def test_empty_document_is_null() raises:
    assert_true(safe_load("").is_null())
    assert_true(safe_load("# only a comment\n").is_null())


def test_booleans_follow_yaml_1_1() raises:
    _check(
        "t: true\nf: FALSE\ny: yes\nn: off\n",
        '{"t":true,"f":false,"y":true,"n":false}',
    )


def test_single_letters_are_not_booleans() raises:
    # PyYAML's bool pattern does not include bare `y` or `n`.
    _check("a: y\nb: n\n", '{"a":"y","b":"n"}')


def test_integer_forms() raises:
    _check(
        "i: 42\nneg: -17\noct: 017\nhex: 0xff\nbin: 0b101\nund: 1_000\n",
        '{"i":42,"neg":-17,"oct":15,"hex":255,"bin":5,"und":1000}',
    )


def test_yaml_1_1_has_no_0o_octal() raises:
    _check("oct: 0o17\n", '{"oct":"0o17"}')


def test_float_forms() raises:
    _check(
        "f1: 1.5\nf2: -1.0e+3\nf3: 1_000.5\n",
        '{"f1":1.5,"f2":-1000.0,"f3":1000.5}',
    )


def test_special_floats() raises:
    var doc = safe_load("inf: .inf\nninf: -.Inf\nnan: .NaN\n")
    assert_true(doc["inf"].float() > 1e308)
    assert_true(doc["ninf"].float() < -1e308)
    assert_true(doc["nan"].float() != doc["nan"].float())


def test_plain_scalars_stay_strings() raises:
    _check(
        "s: hello world\nu: 3 apples\nc: a:b\n",
        '{"s":"hello world","u":"3 apples","c":"a:b"}',
    )


def test_quoted_scalars() raises:
    _check("q: 'single ''quoted'''\n", '{"q":"single \'quoted\'"}')
    _check('d: "double \\"quoted\\" \\n"\n', '{"d":"double \\"quoted\\" \\n"}')


def test_quoted_scalars_are_never_resolved() raises:
    _check("a: '123'\nb: \"true\"\n", '{"a":"123","b":"true"}')


def test_double_quoted_escapes() raises:
    _check(
        'a: "\\t\\\\ \\u00e9 \\x41 \\U0001F600"\n',
        '{"a":"\\t\\\\ \\u00e9 A \\ud83d\\ude00"}',
    )


def test_multi_line_plain_scalar_folds() raises:
    _check(
        "multi: this is\n  a folded\n  plain scalar\n",
        '{"multi":"this is a folded plain scalar"}',
    )


def test_flow_collections() raises:
    _check(
        "flow: [1, 2, {a: b}]\nfmap: {x: 1, y: [2, 3]}\n",
        '{"flow":[1,2,{"a":"b"}],"fmap":{"x":1,"y":[2,3]}}',
    )


def test_empty_flow_collections() raises:
    _check("a: []\nb: {}\n", '{"a":[],"b":{}}')


def test_literal_block_scalar() raises:
    _check("lit: |\n  line1\n  line2\n", '{"lit":"line1\\nline2\\n"}')


def test_folded_block_scalar() raises:
    _check("fold: >\n  word1\n  word2\n", '{"fold":"word1 word2\\n"}')


def test_block_scalar_chomping() raises:
    _check("keep: |+\n  a\n\n", '{"keep":"a\\n\\n"}')
    _check("strip: |-\n  b\n", '{"strip":"b"}')


def test_anchors_and_aliases() raises:
    _check("anchor: &a value\nref: *a\n", '{"anchor":"value","ref":"value"}')


def test_anchor_on_a_collection() raises:
    _check("base: &b [1, 2]\nsame: *b\n", '{"base":[1,2],"same":[1,2]}')


def test_merge_key() raises:
    _check(
        "base: &b {x: 1}\nderived:\n  <<: *b\n  y: 2\n",
        '{"base":{"x":1},"derived":{"x":1,"y":2}}',
    )


def test_quoted_keys() raises:
    _check("'quoted key': v\n", '{"quoted key":"v"}')


def test_document_markers() raises:
    _check("---\na: 1\n", '{"a":1}')
    _check("---\na: 1\n...\n", '{"a":1}')


def test_multiple_documents_rejected_by_safe_load() raises:
    with assert_raises(contains="expected a single document"):
        _ = safe_load("---\na: 1\n---\nb: 2\n")


def test_quoted_merge_key_is_an_ordinary_key() raises:
    # Only a *plain* `<<` merges; quoting it makes it an ordinary string key.
    _check("'<<': 1\n", '{"<<":1}')
    _check('"<<": 1\n', '{"<<":1}')
    _check("{'<<': 1}\n", '{"<<":1}')


def test_recursive_anchor_on_a_sequence() raises:
    # PyYAML registers an anchor before parsing the collection it names, so a
    # collection may alias itself.
    var doc = safe_load("&a [1, *a]\n")
    assert_equal(len(doc), 2)
    assert_equal(doc[0].int(), 1)
    assert_equal(doc[1][0].int(), 1)


def test_recursive_anchor_on_a_mapping() raises:
    var doc = safe_load("&a {self: *a}\n")
    assert_equal(len(doc), 1)
    assert_equal(len(doc["self"]["self"]["self"]), 1)


def test_recursive_anchor_inside_a_document() raises:
    var doc = safe_load("a: &x [1, *x]\n")
    assert_equal(doc["a"][1][0].int(), 1)


def test_sexagesimal_components_must_be_in_range() raises:
    _check(
        "a: 1:59\nb: 1:30\nc: 1:0\nd: 1:00\n", '{"a":119,"b":90,"c":60,"d":60}'
    )
    # A component above 59, three digits, or a leading zero on the first part
    # all leave the scalar a string.
    _check(
        "a: 1:60\nb: 1:99\nc: 1:005\nd: 0:30\ne: 01:30\n",
        '{"a":"1:60","b":"1:99","c":"1:005","d":"0:30","e":"01:30"}',
    )
    _check("a: 12:34:56\nb: 1_0:30\nc: -1:30\n", '{"a":45296,"b":630,"c":-90}')


def test_sexagesimal_floats() raises:
    _check(
        "a: 1:30.5\nb: 0:30.5\nc: 1:2:3.5\n", '{"a":90.5,"b":30.5,"c":3723.5}'
    )
    _check("a: 1:60.5\n", '{"a":"1:60.5"}')


def test_inline_block_sequence_after_a_key_is_rejected() raises:
    with assert_raises(contains="sequence entries are not allowed here"):
        _ = safe_load("a: - b\n")
    # A dash that is not followed by a space is just a plain scalar.
    _check("a: -b\n", '{"a":"-b"}')


def test_standard_tags() raises:
    _check('a: !!str 123\nb: !!int "42"\n', '{"a":"123","b":42}')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
