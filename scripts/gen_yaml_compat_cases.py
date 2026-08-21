#!/usr/bin/env python3
"""Regenerates `test/yaml/test_pyyaml_compat.mojo` from PyYAML's behaviour.

Every case is decided by running PyYAML here, so the generated file is a
differential test: it asserts that this library agrees with the reference
implementation on what a document loads to, on what it dumps back to, and on
which documents are rejected.

Run it after changing the case list:

```bash
python3 scripts/gen_yaml_compat_cases.py
```
"""

import datetime
import json
import os
import random

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "test", "yaml", "test_pyyaml_compat.mojo")

DOCUMENTS = [
    # Block structure.
    "a: 1\nb: 2\n",
    "- 1\n- 2\n",
    "a:\n  b:\n    c: d\n",
    "a:\n- 1\n- 2\n",
    "a:\n  - 1\n  - 2\n",
    "- a: 1\n  b: 2\n- 3\n",
    "- - 1\n  - 2\n- - 3\n",
    "outer:\n  inner:\n  - x: 1\n    y: 2\n  - z\n",
    "a: 1\n\n\nb: 2\n",
    "# lead\na: 1  # trail\n# tail\n",
    "empty:\nalso:\n",
    "a: {}\nb: []\n",
    # Scalars.
    "s: plain text\n",
    "s: 'single'\ns2: 'it''s'\n",
    's: "double"\ns2: "tab\\there"\ns3: "\\u00e9"\n',
    "n: null\nn2: ~\nn3: Null\n",
    "b: true\nb2: False\nb3: yes\nb4: OFF\n",
    "i: 0\ni2: -5\ni3: 0o17\ni4: 017\ni5: 0x1f\ni6: 0b11\ni7: 1_000\n",
    "f: 0.5\nf2: -1.5e+3\nf3: .inf\nf4: -.inf\n",
    "not_num: 1e3\nnot_num2: 0o17\nnot_num3: 08\n",
    "long: this is a fairly long plain scalar that keeps going\n",
    "folded: this spans\n  several lines\n  in one scalar\n",
    "blank_fold: one\n\n  two\n",
    "lit: |\n  a\n  b\n",
    "lit_strip: |-\n  a\n",
    "lit_keep: |+\n  a\n\n",
    "fold: >\n  a\n  b\n",
    "fold_more: >\n  a\n   indented\n  b\n",
    "lit_indent: |2\n   a\n",
    "empty_str: ''\n",
    "spaces: '  padded  '\n",
    # Flow.
    "a: [1, 2, 3]\n",
    "a: {x: 1, y: 2}\n",
    "a: [{b: 1}, [2, 3]]\n",
    "a: [\n  1,\n  2,\n]\n",
    "a: {x}\n",
    "a: [a:b]\n",
    # Anchors, aliases, merges, tags.
    "a: &x 1\nb: *x\n",
    "a: &x [1, 2]\nb: *x\n",
    "base: &b {x: 1, y: 2}\nd:\n  <<: *b\n  y: 3\n",
    "base: &b {x: 1}\nb2: &c {y: 2}\nd:\n  <<: [*b, *c]\n  z: 3\n",
    'a: !!str 1\nb: !!int "2"\nc: !!float "3"\nd: !!bool "yes"\ne: !!null ""\n',
    # Documents.
    "---\na: 1\n",
    "---\na: 1\n...\n",
    # Keys.
    "'q key': 1\n",
    '"d key": 1\n',
    "1: one\n",
    "true: t\n",
    "a b c: 1\n",
]

BAD = [
    "a: 1\n b: 2\n",
    "\ta: 1\n",
    "a: [1, 2\n",
    "a: {x: 1\n",
    "a: 'unterminated\n",
    'a: "unterminated\n',
    "a: *missing\n",
    'a: "\\q"\n',
    "a: b: c\n",
]


def random_documents(count=60):
    """Builds pseudo-random documents out of the shapes above."""
    rng = random.Random(20260821)
    keys = ["a", "b", "key", "long_key_name", "k1", "k2", "nested", "x"]
    scalars = [
        "plain", "with spaces", "123", "1.5", "true", "null", "yes", "0x10",
        "", "  padded ", "it's", 'say "hi"', "a: b", "a #b", "-x", "line\nbreak",
        "tab\there", "日本語", "#leading", "*star",
    ]

    def build(depth):
        r = rng.random()
        if depth <= 0 or r < 0.45:
            pick = rng.randrange(6)
            if pick == 0:
                return None
            if pick == 1:
                return rng.random() < 0.5
            if pick == 2:
                return rng.randrange(-1000, 1000)
            if pick == 3:
                return round(rng.uniform(-100, 100), 4)
            return rng.choice(scalars)
        if r < 0.72:
            return [build(depth - 1) for _ in range(rng.randrange(4))]
        return {
            rng.choice(keys) + str(rng.randrange(20)): build(depth - 1)
            for _ in range(rng.randrange(4))
        }

    out = []
    while len(out) < count:
        value = build(3)
        text = yaml.safe_dump(value, allow_unicode=rng.random() < 0.5)
        if len(text) < 3000:
            out.append(text)
    return out


def unsupported(value, depth=0):
    """Returns why a loaded value cannot be compared, or None."""
    if depth > 20:
        return "too deep"
    if isinstance(value, (datetime.date, datetime.datetime, bytes, set)):
        return "no Mojo type for %s" % type(value).__name__
    if isinstance(value, list):
        for item in value:
            reason = unsupported(item, depth + 1)
            if reason:
                return reason
        return None
    if isinstance(value, dict):
        seen = set()
        for key, item in value.items():
            if not isinstance(key, str):
                # Mapping keys are always strings here, so a key of another
                # type would dump differently from PyYAML.
                return "non-string key"
            if key in seen:
                return "duplicate key"
            seen.add(key)
            reason = unsupported(item, depth + 1)
            if reason:
                return reason
        return None
    if isinstance(value, float) and value != value:
        return "NaN does not compare equal"
    return None


def mojo_str(text):
    """Renders `text` as a Mojo string literal."""
    out = ['"']
    for ch in text:
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif ord(ch) < 0x20 or ord(ch) == 0x7F:
            out.append("\\x%02x" % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def main():
    good = []
    for text in DOCUMENTS + random_documents():
        try:
            value = yaml.safe_load(text)
        except yaml.YAMLError:
            print("skipping (PyYAML rejects it): %r" % text)
            continue
        reason = unsupported(value)
        if reason:
            print("skipping (%s): %r" % (reason, text[:40]))
            continue
        try:
            loaded = json.dumps(value, separators=(",", ":"), allow_nan=False)
        except ValueError as exc:
            print("skipping (%s): %r" % (exc, text[:40]))
            continue
        good.append((text, loaded, yaml.safe_dump(value)))

    bad = []
    for text in BAD:
        try:
            yaml.safe_load(text)
        except yaml.YAMLError:
            bad.append(text)
        else:
            print("skipping (PyYAML accepts it): %r" % text)

    lines = [
        '"""Differential tests against PyYAML.',
        "",
        "Generated by `scripts/gen_yaml_compat_cases.py`, which runs every case",
        "through PyYAML and records what it produced. Do not edit by hand; add",
        "cases to the generator and re-run it.",
        '"""',
        "",
        "from std.testing import TestSuite, assert_equal, assert_raises",
        "",
        "from json import dumps",
        "from yaml import safe_dump, safe_load",
        "",
        "",
        "def _check(text: StringSlice, loaded: StringSlice, dumped: StringSlice) raises:",
        '    """Checks one document against PyYAML.',
        "",
        "    Args:",
        "        text: The document to load.",
        "        loaded: What `yaml.safe_load` produced, as compact JSON.",
        "        dumped: What `yaml.safe_dump` produced for that value.",
        "",
        "    Raises:",
        "        If loading or dumping differs from PyYAML.",
        '    """',
        "    var doc = safe_load(text)",
        '    assert_equal(dumps(doc, separators=(",", ":")), loaded, String(text))',
        "    assert_equal(safe_dump(doc), dumped, String(text))",
        "",
        "",
    ]

    per_test = 8
    for start in range(0, len(good), per_test):
        lines.append("def test_matches_pyyaml_%03d() raises:" % (start // per_test))
        for text, loaded, dumped in good[start : start + per_test]:
            lines.append("    _check(")
            for field in (text, loaded, dumped):
                lines.append("        %s," % mojo_str(field))
            lines.append("    )")
        lines.append("")
        lines.append("")

    for start in range(0, len(bad), per_test):
        lines.append("def test_rejects_like_pyyaml_%03d() raises:" % (start // per_test))
        for text in bad[start : start + per_test]:
            lines.append("    with assert_raises():")
            lines.append("        _ = safe_load(%s)" % mojo_str(text))
        lines.append("")
        lines.append("")

    lines.append("def main() raises:")
    lines.append("    TestSuite.discover_tests[__functions_in_module()]().run()")
    lines.append("")

    with open(OUT, "w") as fh:
        fh.write("\n".join(lines))
    os.system("mojo format -q %s >/dev/null 2>&1" % OUT)
    print(
        "wrote %s: %d comparable documents, %d rejected"
        % (os.path.relpath(OUT, os.path.join(HERE, "..")), len(good), len(bad))
    )


if __name__ == "__main__":
    main()
