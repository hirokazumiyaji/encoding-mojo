"""Serialization of tape nodes back into TOML text.

The output follows `tomli_w`: members keep the order they were inserted,
scalar keys come before the `[table]` sections of the same table, arrays are
always spread over several lines, and a short array of tables collapses into
an array of inline tables. The differences are listed in the package README.
"""

from std.math import isinf, isnan

from serde.tape import (
    MAX_DEPTH,
    _DEPTH_MESSAGE,
    _KIND_ARRAY,
    _KIND_BOOL,
    _KIND_FLOAT,
    _KIND_INT,
    _KIND_NULL,
    _KIND_OBJECT,
    _KIND_STRING,
    _Tape,
)

comptime _HEX_LOWER = StaticString("0123456789abcdef")

comptime _MAX_LINE = 100
"""The widest a rendered inline table may be before it becomes a section.

`tomli_w` measures the element as it would appear inside an array — its
indent, the table, and the trailing comma — and falls back to `[[name]]`
sections once that reaches past this many characters.
"""


struct EmitOptions(Copyable, ImplicitlyCopyable, Movable):
    """The knobs `dumps` exposes, resolved once."""

    var multiline: Bool
    """Whether a string holding a newline may be written with `\"\"\"`."""

    var indent: String
    """One level of indentation inside a multi-line array."""

    def __init__(
        out self, *, multiline_strings: Bool = False, indent: Int = 4
    ) raises:
        """Records the requested settings.

        Args:
            multiline_strings: Whether newlines may be written literally.
            indent: Spaces per level inside a multi-line array.

        Raises:
            If `indent` is negative.
        """
        if indent < 0:
            raise Error("Indent width must be non-negative")
        self.multiline = multiline_strings
        self.indent = String()
        for _ in range(indent):
            self.indent += " "


# ===-----------------------------------------------------------------------===#
# Scalars
# ===-----------------------------------------------------------------------===#


def _float_text(value: Float64) -> String:
    """Renders a float the way Python's `str` does.

    Args:
        value: The float to render.

    Returns:
        Its TOML spelling; non-finite values become `inf`, `-inf` or `nan`.
    """
    if isnan(value):
        return String("nan")
    if isinf(value):
        return String("inf") if value > 0 else String("-inf")
    return String(value)


def _write_u4(mut out: String, value: UInt8):
    """Appends `value` as a four-digit `\\u` escape.

    Args:
        out: The buffer to append to.
        value: The byte to escape.
    """
    out += "\\u00"
    var hi = Int(value >> 4)
    var lo = Int(value & 0xF)
    out += _HEX_LOWER[byte = hi : hi + 1]
    out += _HEX_LOWER[byte = lo : lo + 1]


def _write_string(
    mut out: String, bytes: Span[UInt8, _], allow_multiline: Bool
):
    """Appends a quoted TOML string.

    Only the characters a basic string cannot hold are escaped, which leaves
    tabs and every non-ASCII codepoint verbatim. When `allow_multiline` is set
    and the text holds a newline the whole scalar switches to `\"\"\"`, where
    line breaks are written as themselves and a CRLF pair collapses to one
    newline.

    Args:
        out: The buffer to append to.
        bytes: The string's UTF-8 bytes.
        allow_multiline: Whether `\"\"\"` may be used.
    """
    var n = len(bytes)
    var multiline = False
    if allow_multiline:
        for i in range(n):
            if bytes[i] == 0x0A:
                multiline = True
                break

    out += '"""\n' if multiline else '"'

    var i = 0
    var run_start = 0
    while i < n:
        var b = bytes[i]
        var width = 1
        var escape = String()
        if b == 0x09:
            i += 1
            continue
        elif b == 0x22:
            escape = String('\\"')
        elif b == 0x5C:
            escape = String("\\\\")
        elif b == 0x08:
            escape = String("\\b")
        elif b == 0x0C:
            escape = String("\\f")
        elif b == 0x0A:
            if not multiline:
                escape = String("\\n")
            else:
                i += 1
                continue
        elif b == 0x0D:
            if multiline and i + 1 < n and bytes[i + 1] == 0x0A:
                # A CRLF pair is normalized to a bare newline, which a
                # multi-line string then writes as itself.
                width = 2
                escape = String("\n")
            else:
                escape = String("\\r")
        elif b < 0x20 or b == 0x7F:
            _write_u4(escape, b)
        else:
            i += 1
            continue

        out += StringSlice(unsafe_from_utf8=bytes[run_start:i])
        out += escape
        i += width
        run_start = i

    out += StringSlice(unsafe_from_utf8=bytes[run_start:n])
    out += '"""' if multiline else '"'


def _is_bare_key(bytes: Span[UInt8, _]) -> Bool:
    """Reports whether a key can be written without quotes.

    Args:
        bytes: The key's UTF-8 bytes.

    Returns:
        True if the key is non-empty and made only of `A-Za-z0-9-_`.
    """
    if len(bytes) == 0:
        return False
    for i in range(len(bytes)):
        var b = bytes[i]
        var ok = (
            (b >= 0x41 and b <= 0x5A)
            or (b >= 0x61 and b <= 0x7A)
            or (b >= 0x30 and b <= 0x39)
            or b == 0x2D
            or b == 0x5F
        )
        if not ok:
            return False
    return True


def _write_key(mut out: String, bytes: Span[UInt8, _]):
    """Appends one key part, quoted only if it has to be.

    Args:
        out: The buffer to append to.
        bytes: The key's UTF-8 bytes.
    """
    if _is_bare_key(bytes):
        out += StringSlice(unsafe_from_utf8=bytes)
    else:
        _write_string(out, bytes, False)


def _key_text(tape: _Tape, idx: UInt32) -> String:
    """Renders one key part on its own.

    Args:
        tape: The document to read from.
        idx: The index of the key's string node.

    Returns:
        The key as it appears in the output.
    """
    var out = String()
    _write_key(out, tape.str_bytes(idx))
    return out^


# ===-----------------------------------------------------------------------===#
# Values
# ===-----------------------------------------------------------------------===#


def _write_literal(
    mut out: String,
    tape: _Tape,
    idx: UInt32,
    opts: EmitOptions,
    nest_level: Int,
    depth: Int,
) raises:
    """Appends a value in the form it takes on the right of an `=`.

    Arrays always spread over several lines and tables stay inline, which is
    what `tomli_w` does for anything that is not promoted to a section.

    Args:
        out: The buffer to append to.
        tape: The document to read from.
        idx: The index of the value to write.
        opts: The active options.
        nest_level: How many arrays enclose this value, which sets the indent
            its elements are written at.
        depth: The current nesting depth.

    Raises:
        If the value cannot be written as TOML, or the walk runs deeper than
        `MAX_DEPTH`.
    """
    if depth > MAX_DEPTH:
        raise Error(_DEPTH_MESSAGE)
    var node = tape.nodes[Int(idx)]
    var kind = node.kind

    if kind == _KIND_NULL:
        raise Error("Object of type 'NoneType' is not TOML serializable")
    elif kind == _KIND_BOOL:
        out += "true" if node.num != 0 else "false"
    elif kind == _KIND_INT:
        out += String(Int64(node.num))
    elif kind == _KIND_FLOAT:
        out += _float_text(Float64(from_bits=node.num))
    elif kind == _KIND_STRING:
        _write_string(out, tape.str_bytes(idx), opts.multiline)
    elif kind == _KIND_ARRAY:
        var count = Int(node.b)
        if count == 0:
            out += "[]"
            return
        out += "[\n"
        for i in range(count):
            for _ in range(nest_level + 1):
                out += opts.indent
            _write_literal(
                out,
                tape,
                tape.kids[Int(node.a) + i],
                opts,
                nest_level + 1,
                depth + 1,
            )
            out += ",\n"
        for _ in range(nest_level):
            out += opts.indent
        out += "]"
    else:
        var count = Int(node.b)
        if count == 0:
            out += "{}"
            return
        out += "{ "
        for i in range(count):
            if i > 0:
                out += ", "
            _write_key(out, tape.str_bytes(tape.kids[Int(node.a) + 2 * i]))
            out += " = "
            # `tomli_w` renders an inline table's members from scratch, so a
            # nested array indents from the left margin again.
            _write_literal(
                out,
                tape,
                tape.kids[Int(node.a) + 2 * i + 1],
                opts,
                0,
                depth + 1,
            )
        out += " }"


def _is_array_of_tables(tape: _Tape, idx: UInt32) -> Bool:
    """Reports whether a value is a non-empty array of tables.

    Args:
        tape: The document to read from.
        idx: The index of the value to test.

    Returns:
        True if every element is a table and there is at least one.
    """
    var node = tape.nodes[Int(idx)]
    if node.kind != _KIND_ARRAY or node.b == 0:
        return False
    for i in range(Int(node.b)):
        var child = tape.kids[Int(node.a) + i]
        if tape.nodes[Int(child)].kind != _KIND_OBJECT:
            return False
    return True


def _fits_inline(tape: _Tape, idx: UInt32, opts: EmitOptions) raises -> Bool:
    """Reports whether a table is small enough to sit inside an array.

    Args:
        tape: The document to read from.
        idx: The index of the table to measure.
        opts: The active options.

    Returns:
        True if the rendered element stays on one line and within
        `_MAX_LINE` characters.

    Raises:
        If the table cannot be written as TOML.
    """
    var rendered = String(opts.indent)
    _write_literal(rendered, tape, idx, opts, 0, 0)
    rendered += ","

    var bytes = rendered.as_bytes()
    var width = 0
    for i in range(len(bytes)):
        if bytes[i] == 0x0A:
            return False
        # Continuation bytes belong to a codepoint that was already counted.
        if (bytes[i] & 0xC0) != 0x80:
            width += 1
    return width <= _MAX_LINE


# ===-----------------------------------------------------------------------===#
# Tables
# ===-----------------------------------------------------------------------===#


def _write_table(
    mut out: String,
    tape: _Tape,
    idx: UInt32,
    opts: EmitOptions,
    name: String,
    inside_aot: Bool,
    depth: Int,
) raises:
    """Appends one table and every table below it.

    Args:
        out: The buffer to append to.
        tape: The document to read from.
        idx: The index of the table to write.
        opts: The active options.
        name: The dotted name this table is reached by, empty at the root.
        inside_aot: Whether this table is one element of an array of tables.
        depth: The current nesting depth.

    Raises:
        If a value cannot be written as TOML, or the walk runs deeper than
        `MAX_DEPTH`.
    """
    if depth > MAX_DEPTH:
        raise Error(_DEPTH_MESSAGE)
    var node = tape.nodes[Int(idx)]

    # Alternating key and value indices for the members written as `k = v`.
    var literals = List[UInt32]()
    # The tables written as their own block, the dotted name each one is
    # written under, and whether it is one element of an array of tables.
    var sections = List[UInt32]()
    var section_names = List[String]()
    var section_aot = List[Bool]()

    for i in range(Int(node.b)):
        var key = tape.kids[Int(node.a) + 2 * i]
        var value = tape.kids[Int(node.a) + 2 * i + 1]
        var kind = tape.nodes[Int(value)].kind

        var promote = kind == _KIND_OBJECT
        var elements = List[UInt32]()
        if not promote and _is_array_of_tables(tape, value):
            var child = tape.nodes[Int(value)]
            var all_fit = True
            for j in range(Int(child.b)):
                var element = tape.kids[Int(child.a) + j]
                elements.append(element)
                if all_fit and not _fits_inline(tape, element, opts):
                    all_fit = False
            promote = not all_fit
            if not promote:
                elements.clear()

        if not promote:
            literals.append(key)
            literals.append(value)
            continue

        var display = _key_text(tape, key)
        if name.byte_length() > 0:
            display = name + "." + display
        if len(elements) == 0:
            sections.append(value)
            section_names.append(display)
            section_aot.append(False)
        else:
            for j in range(len(elements)):
                sections.append(elements[j])
                section_names.append(display)
                section_aot.append(True)

    var written = False
    var has_literals = len(literals) > 0
    var has_sections = len(sections) > 0
    if inside_aot or (
        name.byte_length() > 0 and (has_literals or not has_sections)
    ):
        written = True
        if inside_aot:
            out += "[[" + name + "]]\n"
        else:
            out += "[" + name + "]\n"

    if has_literals:
        written = True
        for i in range(0, len(literals), 2):
            _write_key(out, tape.str_bytes(literals[i]))
            out += " = "
            _write_literal(out, tape, literals[i + 1], opts, 0, depth + 1)
            out += "\n"

    for i in range(len(sections)):
        if written:
            out += "\n"
        else:
            written = True
        _write_table(
            out,
            tape,
            sections[i],
            opts,
            section_names[i],
            section_aot[i],
            depth + 1,
        )


def emit_document(
    tape: _Tape, root: UInt32, opts: EmitOptions
) raises -> String:
    """Renders a whole document.

    Args:
        tape: The document to read from.
        root: The index of the document's root table.
        opts: The active options.

    Returns:
        The TOML text, ending with a newline unless the document is empty.

    Raises:
        If the root is not a table, if a value cannot be written as TOML, or
        if the document nests deeper than `MAX_DEPTH`.
    """
    if tape.nodes[Int(root)].kind != _KIND_OBJECT:
        raise Error("A TOML document must be a table at the top level")
    var out = String()
    _write_table(out, tape, root, opts, String(), False, 0)
    return out^
