#!/usr/bin/env python3
"""Check that every public declaration under src/ carries a complete docstring.

`mojo doc --diagnose-missing-doc-strings` is the authority, but it needs the
Mojo compiler. This checker needs only Python, so it runs in an editor, in a
pre-commit hook, and in CI before the compiler is installed.

It requires, for every public declaration:

* a docstring whose first line is a summary;
* an `Args:` entry for every argument, and a `Parameters:` entry for every
  compile-time parameter;
* a `Returns:` section when the declaration returns something;
* a `Raises:` section when the declaration is declared `raises`;
* a docstring on every public struct field and struct-level alias.

Usage:

    python3 scripts/check_docstrings.py [path ...]

Paths default to `src`. Exits non-zero, listing every gap, when anything is
undocumented.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

#: Declarations that introduce a documented entity.
DECL = re.compile(
    r"^(?P<indent>[ ]*)"
    r"(?P<kw>fn|def|struct|trait|alias|var)[ ]+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
)

#: Names that are documented by the language, not by the author.
EXEMPT_ARGS = frozenset({"self", "out self"})

#: The Google-style headings a Mojo docstring may use.
SECTION = re.compile(r"^(Args|Parameters|Returns|Raises|Constraints|Notes|Examples):$")


def is_public(name: str) -> bool:
    """Reports whether `name` appears in generated documentation.

    Dunder methods do, even though they start with an underscore; a single
    leading underscore marks something internal.

    Args:
        name: The declared name.

    Returns:
        True when the declaration is part of the public API.
    """
    if name.startswith("__") and name.endswith("__"):
        return True
    return not name.startswith("_")


@dataclass
class Problem:
    """One documentation gap, rendered as a compiler-style diagnostic."""

    path: Path
    line: int
    what: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: {self.what}"


@dataclass
class Source:
    """A Mojo file split into lines, with string literals masked out."""

    path: Path
    lines: list[str]
    #: True where the line lies inside a triple-quoted literal.
    in_string: list[bool] = field(default_factory=list)
    #: Index of the first line of the triple-quoted literal that opens on this
    #: line, mapped to the index just past its last line.
    literals: dict[int, int] = field(default_factory=dict)

    @classmethod
    def read(cls, path: Path) -> "Source":
        """Reads `path` and records where its triple-quoted literals are.

        Args:
            path: The file to read.

        Returns:
            The parsed source.
        """
        lines = path.read_text(encoding="utf-8").splitlines()
        source = cls(path=path, lines=lines, in_string=[False] * len(lines))
        i = 0
        while i < len(lines):
            stripped = lines[i].strip()
            for quote in ('"""', "'''"):
                if not stripped.startswith(quote):
                    continue
                body = stripped[len(quote):]
                end = i
                if not body.endswith(quote) or len(stripped) < 2 * len(quote):
                    end = i + 1
                    while end < len(lines) and quote not in lines[end]:
                        source.in_string[end] = True
                        end += 1
                source.literals[i] = min(end + 1, len(lines))
                i = end
                break
            i += 1
        return source


def signature_end(source: Source, start: int) -> int:
    """Finds the last line of the declaration that begins at `start`.

    Args:
        source: The file being read.
        start: The line the declaration starts on.

    Returns:
        The index of its final line.
    """
    depth = 0
    i = start
    while i < len(source.lines):
        line = source.lines[i]
        depth += line.count("(") - line.count(")")
        depth += line.count("[") - line.count("]")
        if depth <= 0:
            return i
        i += 1
    return len(source.lines) - 1


def docstring_at(source: Source, line: int) -> list[str] | None:
    """Returns the docstring that starts on `line`, if there is one.

    Args:
        source: The file being read.
        line: The line just past a declaration's signature.

    Returns:
        The docstring's lines with the quotes stripped, or None.
    """
    if line >= len(source.lines) or line not in source.literals:
        return None
    end = source.literals[line]
    body = "\n".join(source.lines[line:end])
    body = body.strip()
    for quote in ('"""', "'''"):
        if body.startswith(quote):
            body = body[len(quote):]
            if body.endswith(quote):
                body = body[: -len(quote)]
            return body.splitlines()
    return None


def sections(doc: list[str]) -> dict[str, list[str]]:
    """Splits a docstring into its Google-style sections.

    Args:
        doc: The docstring's lines.

    Returns:
        Section name mapped to the entry names it documents.
    """
    found: dict[str, list[str]] = {}
    current: str | None = None
    indent = 0
    for raw in doc:
        stripped = raw.strip()
        match = SECTION.match(stripped)
        if match:
            current = match.group(1)
            found.setdefault(current, [])
            indent = len(raw) - len(raw.lstrip())
            continue
        if current is None or not stripped:
            continue
        here = len(raw) - len(raw.lstrip())
        if here <= indent:
            current = None
            continue
        entry = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*:", stripped)
        if entry and here == indent + 4:
            found[current].append(entry.group(1))
    return found


def split_params(text: str) -> list[str]:
    """Splits an argument or parameter list on its top-level commas.

    Args:
        text: The contents of the brackets, without the brackets.

    String literals are respected, so a default such as `delimiter = ","` does
    not split the entry it belongs to.

    Returns:
        One string per declared entry.
    """
    parts: list[str] = []
    depth = 0
    quote = ""
    escaped = False
    current = ""
    for char in text:
        if quote:
            current += char
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = ""
            continue
        if char in "\"'":
            quote = char
            current += char
            continue
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        if char == "," and depth == 0:
            parts.append(current)
            current = ""
            continue
        current += char
    if current.strip():
        parts.append(current)
    return parts


def named(entries: list[str]) -> list[str]:
    """Extracts the documented names from declared argument entries.

    Args:
        entries: One string per declared argument or parameter.

    Returns:
        The names Mojo expects a docstring entry for.
    """
    names: list[str] = []
    for entry in entries:
        text = entry.strip()
        if not text or text in {"*", "/", "//"}:
            continue
        text = text.lstrip("*")
        # Drop convention keywords: `var x: T`, `mut x: T`, `out x: T`, ...
        head = text.split(":", 1)[0].strip()
        words = head.split()
        if not words:
            continue
        name = words[-1]
        if name in EXEMPT_ARGS or name == "self":
            continue
        if name.startswith("_"):
            continue
        names.append(name)
    return names


def group(text: str, start: int) -> tuple[str, int] | None:
    """Reads the balanced bracket group that opens at `start`.

    Args:
        text: The signature to scan.
        start: The index of the opening bracket.

    Returns:
        The group's contents and the index just past its closing bracket, or
        None when `start` does not open a group.
    """
    pairs = {"(": ")", "[": "]"}
    open_char = text[start] if start < len(text) else ""
    close_char = pairs.get(open_char)
    if close_char is None:
        return None
    depth = 0
    for i in range(start, len(text)):
        if text[i] == open_char:
            depth += 1
        elif text[i] == close_char:
            depth -= 1
            if depth == 0:
                return text[start + 1 : i], i + 1
    return None


def signature_parts(signature: str, name: str) -> tuple[str, str, str]:
    """Splits a signature into its parameter list, argument list and tail.

    Only the brackets that follow the declared name are read, so a return type
    such as `-> List[String]` is never mistaken for a parameter list.

    Args:
        signature: The declaration, joined onto one line.
        name: The declared name.

    Returns:
        The parameters, the arguments, and everything after them.
    """
    match = re.search(rf"\b(?:fn|def)\s+{re.escape(name)}\b", signature)
    at = match.end() if match else len(signature)
    parameters = ""
    arguments = ""
    if at < len(signature) and signature[at] == "[":
        read = group(signature, at)
        if read is not None:
            parameters, at = read
    if at < len(signature) and signature[at] == "(":
        read = group(signature, at)
        if read is not None:
            arguments, at = read
    return parameters, arguments, signature[at:]


def check_callable(
    source: Source, start: int, end: int, name: str, doc: list[str]
) -> list[Problem]:
    """Checks one `fn` or `def` against its docstring.

    Args:
        source: The file being read.
        start: The line the signature starts on.
        end: The line the signature ends on.
        name: The declared name.
        doc: The docstring's lines.

    Returns:
        Every gap found.
    """
    problems: list[Problem] = []
    signature = " ".join(line.strip() for line in source.lines[start : end + 1])
    parameter_text, argument_text, tail = signature_parts(signature, name)
    parameters = named(split_params(parameter_text))
    args = named(split_params(argument_text))
    found = sections(doc)

    for label, declared in (("Args", args), ("Parameters", parameters)):
        documented = found.get(label, [])
        for entry in declared:
            if entry not in documented:
                problems.append(
                    Problem(source.path, start + 1, f"{name}: {label} missing `{entry}`")
                )
        for entry in documented:
            if entry not in declared:
                problems.append(
                    Problem(
                        source.path, start + 1, f"{name}: {label} documents unknown `{entry}`"
                    )
                )

    returns = "->" in tail and "-> None" not in tail
    if returns and "Returns" not in found:
        problems.append(Problem(source.path, start + 1, f"{name}: missing `Returns:`"))
    if "raises" in tail.split("->")[0] and "Raises" not in found:
        problems.append(Problem(source.path, start + 1, f"{name}: missing `Raises:`"))
    return problems


def check_file(path: Path) -> list[Problem]:
    """Checks every public declaration in one file.

    Args:
        path: The file to check.

    Returns:
        Every gap found.
    """
    source = Source.read(path)
    problems: list[Problem] = []

    if not source.literals.get(0):
        problems.append(Problem(path, 1, "module: missing docstring"))

    struct_body: int | None = None
    body_end: int | None = None
    i = 0
    while i < len(source.lines):
        if source.in_string[i] or i in source.literals:
            i = source.literals.get(i, i + 1)
            continue
        match = DECL.match(source.lines[i])
        if not match:
            i += 1
            continue
        indent = len(match.group("indent"))
        kw, name = match.group("kw"), match.group("name")

        if body_end is not None and indent >= body_end:
            i += 1
            continue
        body_end = None
        if struct_body is not None and indent < struct_body:
            struct_body = None

        if kw in {"struct", "trait"}:
            struct_body = indent + 4
        elif kw in {"fn", "def"}:
            body_end = indent + 4
        elif kw == "var" and struct_body is None:
            i += 1
            continue

        if not is_public(name):
            i += 1
            continue

        end = signature_end(source, i)
        doc = docstring_at(source, end + 1)
        if doc is None:
            problems.append(Problem(path, i + 1, f"{kw} {name}: missing docstring"))
        elif not doc[0].strip() and not any(line.strip() for line in doc[:2]):
            problems.append(Problem(path, i + 1, f"{kw} {name}: docstring has no summary"))
        elif kw in {"fn", "def"}:
            problems.extend(check_callable(source, i, end, name, doc))
        i = end + 1

    return problems


def main(argv: list[str]) -> int:
    """Checks every file named on the command line.

    Args:
        argv: The paths to check; `src` when empty.

    Returns:
        The process exit status.
    """
    roots = [Path(arg) for arg in argv] or [Path("src")]
    files: list[Path] = []
    for root in roots:
        files.extend(sorted(root.rglob("*.mojo")) if root.is_dir() else [root])

    problems: list[Problem] = []
    for path in files:
        problems.extend(check_file(path))

    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} documentation gap(s) in {len(files)} file(s)")
        return 1
    print(f"every public declaration in {len(files)} file(s) is documented")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
