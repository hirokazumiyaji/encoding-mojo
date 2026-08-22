#!/usr/bin/env python3
"""Render the JSON `mojo doc` emits into browsable Markdown.

`mojo doc` compiles the docstrings in a package into one JSON document; it
does not render anything. This script turns that JSON into one Markdown page
per package, so `docs/api/` is a readable API reference that never drifts from
the source: every heading, signature and description below comes from a
docstring.

Usage:

    mojo doc -o build/docs/json.json -I src src/json
    python3 scripts/render_api_docs.py build/docs/json.json -o docs/api

`scripts/build_docs.sh` runs both steps for every package.

The JSON schema `mojo doc` emits is explicitly unstable, so every field is
read defensively: an unknown or missing key is skipped rather than fatal.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

#: How each declaration kind is labelled in a heading.
LABELS = {
    "alias": "alias",
    "field": "field",
    "function": "function",
    "module": "module",
    "package": "package",
    "struct": "struct",
    "trait": "trait",
}


def text(node: Any, *keys: str) -> str:
    """Reads the first non-empty string among `keys`.

    Args:
        node: The JSON object to read.
        keys: The keys to try, in order.

    Returns:
        The value found, stripped, or the empty string.
    """
    if not isinstance(node, dict):
        return ""
    for key in keys:
        value = node.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def items(node: Any, *keys: str) -> list[dict]:
    """Reads the first non-empty list among `keys`.

    Args:
        node: The JSON object to read.
        keys: The keys to try, in order.

    Returns:
        The list found, with non-object entries dropped.
    """
    if not isinstance(node, dict):
        return []
    for key in keys:
        value = node.get(key)
        if isinstance(value, list) and value:
            return [entry for entry in value if isinstance(entry, dict)]
    return []


def anchor(path: list[str]) -> str:
    """Builds the GitHub anchor for a heading.

    Args:
        path: The dotted name the heading shows.

    Returns:
        The `#fragment` the heading can be linked by.
    """
    slug = ".".join(path).lower()
    return "#" + "".join(c for c in slug.replace(".", "") if c.isalnum() or c == "-")


def body(node: dict) -> list[str]:
    """Renders a declaration's summary and description.

    Args:
        node: The declaration.

    Returns:
        The Markdown lines.
    """
    out: list[str] = []
    summary = text(node, "summary")
    description = text(node, "description")
    if description.startswith(summary):
        description = description[len(summary) :].strip()
    if summary:
        out += [summary, ""]
    if description:
        out += [description, ""]
    deprecated = text(node, "deprecated")
    if deprecated:
        out += [f"> **Deprecated.** {deprecated}", ""]
    constraints = text(node, "constraints")
    if constraints:
        out += [f"> **Constraints.** {constraints}", ""]
    return out


def table(rows: list[tuple[str, str, str]], heading: str, middle: str = "Type") -> list[str]:
    """Renders one name/type/description table.

    Args:
        rows: The name, type and description of each entry.
        heading: The table's title.
        middle: The heading of the middle column.

    Returns:
        The Markdown lines, or nothing when there are no rows.
    """
    if not rows:
        return []
    out = [f"**{heading}**", "", f"| Name | {middle} | Description |", "|---|---|---|"]
    for name, type_name, description in rows:
        cells = [
            f"`{name}`" if name else "",
            f"`{type_name}`" if type_name else "",
            description.replace("\n", " ").replace("|", "\\|"),
        ]
        out.append("| " + " | ".join(cells) + " |")
    return out + [""]


def render_overload(node: dict, path: list[str], level: int) -> list[str]:
    """Renders one function overload.

    Args:
        node: The overload.
        path: The dotted name it lives at.
        level: The Markdown heading level to use.

    Returns:
        The Markdown lines.
    """
    out: list[str] = []
    signature = text(node, "signature")
    if signature:
        out += ["```mojo", signature, "```", ""]
    out += body(node)

    out += table(
        [
            (text(p, "name"), text(p, "type"), text(p, "description"))
            for p in items(node, "parameters")
        ],
        "Parameters",
    )
    out += table(
        [
            (text(a, "name"), text(a, "type"), text(a, "description"))
            for a in items(node, "args", "arguments")
        ],
        "Arguments",
    )

    returns = text(node, "returns", "returnType")
    returns_doc = text(node, "returnsDoc", "returnDescription")
    if returns or returns_doc:
        suffix = f" — {returns_doc}" if returns_doc else ""
        out += [f"**Returns** `{returns or 'None'}`{suffix}", ""]
    raises_doc = text(node, "raisesDoc", "raisesDescription")
    if node.get("raises") or raises_doc:
        out += [f"**Raises** {raises_doc or 'Yes.'}", ""]
    return out


def render_function(node: dict, path: list[str], level: int) -> list[str]:
    """Renders a function and every overload it has.

    Args:
        node: The function declaration.
        path: The dotted name it lives at.
        level: The Markdown heading level to use.

    Returns:
        The Markdown lines.
    """
    name = text(node, "name")
    here = path + [name]
    out = ["#" * level + f" `{'.'.join(here)}`", ""]
    overloads = items(node, "overloads")
    if not overloads:
        return out + render_overload(node, here, level)
    for i, overload in enumerate(overloads):
        if len(overloads) > 1:
            out += [f"*Overload {i + 1} of {len(overloads)}*", ""]
        out += render_overload(overload, here, level)
    return out


def render_struct(node: dict, path: list[str], level: int) -> list[str]:
    """Renders a struct or trait, its fields, aliases and methods.

    Args:
        node: The struct or trait declaration.
        path: The dotted name it lives at.
        level: The Markdown heading level to use.

    Returns:
        The Markdown lines.
    """
    name = text(node, "name")
    here = path + [name]
    kind = LABELS.get(str(node.get("kind")), "struct")
    out = ["#" * level + f" `{'.'.join(here)}`", "", f"*{kind}*", ""]

    traits = [t for t in node.get("parentTraits", []) or [] if isinstance(t, str)]
    if traits:
        out += ["Implements " + ", ".join(f"`{t}`" for t in traits) + ".", ""]
    out += body(node)

    out += table(
        [
            (text(f, "name"), text(f, "type"), text(f, "summary") or text(f, "description"))
            for f in items(node, "fields")
        ],
        "Fields",
    )
    out += table(
        [
            (text(a, "name"), text(a, "value", "type"), text(a, "summary") or text(a, "description"))
            for a in items(node, "aliases")
        ],
        "Aliases",
        middle="Value",
    )

    for function in items(node, "functions"):
        out += render_function(function, here, level + 1)
    return out


def render_module(node: dict, path: list[str], level: int) -> list[str]:
    """Renders one module: its aliases, traits, structs and functions.

    Args:
        node: The module declaration.
        path: The dotted name it lives at.
        level: The Markdown heading level to use.

    Returns:
        The Markdown lines.
    """
    name = text(node, "name")
    here = path + [name] if name else path
    out = ["#" * level + f" `{'.'.join(here)}`", ""] + body(node)

    out += table(
        [
            (text(a, "name"), text(a, "value", "type"), text(a, "summary") or text(a, "description"))
            for a in items(node, "aliases")
        ],
        "Aliases",
        middle="Value",
    )
    for trait in items(node, "traits"):
        out += render_struct(trait, here, level + 1)
    for struct in items(node, "structs"):
        out += render_struct(struct, here, level + 1)
    for function in items(node, "functions"):
        out += render_function(function, here, level + 1)
    return out


def render_package(node: dict, path: list[str], level: int) -> list[str]:
    """Renders a package and everything under it.

    Args:
        node: The package declaration.
        path: The dotted name it lives at.
        level: The Markdown heading level to use.

    Returns:
        The Markdown lines.
    """
    name = text(node, "name")
    here = path + [name] if name else path
    out = ["#" * level + f" `{'.'.join(here)}`", ""] + body(node)

    contents = items(node, "modules") + items(node, "packages")
    if contents:
        out += ["**Contents**", ""]
        for child in contents:
            child_name = text(child, "name")
            out.append(f"- [`{child_name}`]({anchor(here + [child_name])})")
        out.append("")

    for child in items(node, "packages"):
        out += render_package(child, here, level + 1)
    for child in items(node, "modules"):
        out += render_module(child, here, level + 1)
    return out


def render(document: dict) -> str:
    """Renders one `mojo doc` JSON document.

    Args:
        document: The parsed JSON.

    Returns:
        The Markdown page.
    """
    decl = document.get("decl") if isinstance(document, dict) else None
    if not isinstance(decl, dict):
        decl = document if isinstance(document, dict) else {}

    header = [
        "<!-- Generated by scripts/build_docs.sh from the docstrings in src/."
        " Do not edit. -->",
        "",
    ]
    kind = str(decl.get("kind", "package"))
    if kind == "module":
        lines = render_module(decl, [], 1)
    else:
        lines = render_package(decl, [], 1)
    return "\n".join(header + lines).rstrip() + "\n"


def main(argv: list[str]) -> int:
    """Renders every JSON file named on the command line.

    Args:
        argv: The command-line arguments.

    Returns:
        The process exit status.
    """
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("inputs", nargs="+", type=Path, help="JSON from `mojo doc`")
    parser.add_argument(
        "-o", "--out", type=Path, default=Path("docs/api"), help="where to write"
    )
    parser.add_argument(
        "--index",
        action="store_true",
        help="also write an index page listing every rendered package",
    )
    options = parser.parse_args(argv)

    options.out.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    for source in options.inputs:
        try:
            document = json.loads(source.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            print(f"{source}: {error}", file=sys.stderr)
            return 1
        target = options.out / (source.stem + ".md")
        target.write_text(render(document), encoding="utf-8")
        written.append(target)
        print(f"wrote {target}")

    if options.index:
        lines = [
            "<!-- Generated by scripts/build_docs.sh. Do not edit. -->",
            "",
            "# API reference",
            "",
            "Compiled from the docstrings in `src/` by `scripts/build_docs.sh`.",
            "",
        ]
        for target in sorted(written):
            lines.append(f"- [`{target.stem}`]({target.name})")
        index = options.out / "README.md"
        index.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"wrote {index}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
