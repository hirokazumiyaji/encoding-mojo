"""Serialization of tape nodes back into YAML text.

The output follows PyYAML's `safe_dump`: block style, two-space indent, keys
sorted, non-ASCII escaped, and the same choice of plain, single-quoted or
double-quoted for every scalar. The differences are listed in the package
README — chiefly that long lines are never wrapped.
"""

from std.math import isinf, isnan

from serde.tape import (
    MAX_DEPTH,
    _KIND_ARRAY,
    _KIND_BOOL,
    _KIND_FLOAT,
    _KIND_INT,
    _KIND_NULL,
    _KIND_OBJECT,
    _KIND_STRING,
    _Node,
    _Tape,
)

from .errors import YAMLError
from .resolver import loads_as_string

comptime _HEX_UPPER = StaticString("0123456789ABCDEF")


struct EmitOptions(Copyable, ImplicitlyCopyable, Movable):
    """The knobs `safe_dump` exposes, resolved once."""

    var indent: Int
    """Spaces added for each level of block nesting."""

    var flow: Bool
    """Whether to write the whole document on one line in flow style."""

    var sort_keys: Bool
    """Whether mapping members are emitted in sorted key order."""

    var allow_unicode: Bool
    """Whether non-ASCII codepoints may be written verbatim."""

    var explicit_start: Bool
    """Whether to precede each document with `---`."""

    def __init__(
        out self,
        *,
        indent: Int = 2,
        default_flow_style: Bool = False,
        sort_keys: Bool = True,
        allow_unicode: Bool = False,
        explicit_start: Bool = False,
    ):
        """Records the requested settings.

        Args:
            indent: Spaces per level of block nesting.
            default_flow_style: Whether to emit flow style.
            sort_keys: Whether to sort mapping members by key.
            allow_unicode: Whether to write non-ASCII verbatim.
            explicit_start: Whether to precede each document with `---`.
        """
        self.indent = max(indent, 1)
        self.flow = default_flow_style
        self.sort_keys = sort_keys
        self.allow_unicode = allow_unicode
        self.explicit_start = explicit_start


struct _Anchors(Movable):
    """Tracks which containers a document reaches more than once.

    PyYAML gives every shared collection an `&idNNN` anchor and writes later
    occurrences as `*idNNN`; scalars are never anchored. Numbers are handed
    out in output order, which is what PyYAML does too.
    """

    var counts: List[Int]
    """How many times each node is reached from the document root."""

    var assigned: List[Int]
    """The anchor number given to each node, or 0 for none yet."""

    var next_id: Int
    """The last anchor number handed out."""

    def __init__(out self, size: Int):
        """Creates a table for a document with `size` nodes.

        Args:
            size: How many nodes the tape holds.
        """
        self.counts = List[Int](length=size, fill=0)
        self.assigned = List[Int](length=size, fill=0)
        self.next_id = 0

    def take(mut self, idx: UInt32) -> Int:
        """Reports what to write in front of the node at `idx`.

        Args:
            idx: The node about to be emitted.

        Returns:
            0 when the node needs no anchor, a positive number when it needs
            `&idNNN` because this is its first appearance, and the negation of
            its number when it should be written as `*idNNN` instead.
        """
        var i = Int(idx)
        if self.counts[i] <= 1:
            return 0
        if self.assigned[i] != 0:
            return -self.assigned[i]
        self.next_id += 1
        self.assigned[i] = self.next_id
        return self.next_id


def _anchor_name(number: Int) -> String:
    """Renders an anchor number the way PyYAML names them.

    Args:
        number: The anchor's number, counting from one.

    Returns:
        A name such as `id001`.
    """
    var digits = String(number)
    var out = String("id")
    for _ in range(max(3 - digits.byte_length(), 0)):
        out += "0"
    out += digits
    return out^


def count_references(
    tape: _Tape, idx: UInt32, mut counts: List[Int], depth: Int
) raises:
    """Counts how many times each node is reached from `idx`.

    Args:
        tape: The document to walk.
        idx: The node to start from.
        counts: One counter per node, updated in place.
        depth: How deeply nested this node is.

    Raises:
        `YAMLError` if the document nests deeper than `MAX_DEPTH`.
    """
    if depth > MAX_DEPTH:
        raise YAMLError(
            String("exceeded maximum nesting depth of ", MAX_DEPTH), 1, 1
        )
    counts[Int(idx)] += 1
    if counts[Int(idx)] > 1:
        return  # Already walked; walking again would loop on a cycle.
    var node = tape.nodes[Int(idx)]
    if node.kind == _KIND_ARRAY:
        for i in range(Int(node.b)):
            count_references(
                tape, tape.kids[Int(node.a) + i], counts, depth + 1
            )
    elif node.kind == _KIND_OBJECT:
        for i in range(Int(node.b)):
            count_references(
                tape, tape.kids[Int(node.a) + 2 * i + 1], counts, depth + 1
            )


def _spaces(count: Int) -> String:
    """Returns `count` spaces.

    Args:
        count: How many spaces to produce.

    Returns:
        The padding.
    """
    var out = String()
    for _ in range(count):
        out += " "
    return out^


def _float_text(value: Float64) -> String:
    """Renders a float the way PyYAML does.

    Args:
        value: The float to render.

    Returns:
        Its YAML spelling, with a mantissa that always carries a decimal point.
    """
    if isnan(value):
        return String(".nan")
    if isinf(value):
        return String(".inf") if value > 0 else String("-.inf")
    var text = String(value)
    var bytes = text.as_bytes()
    var has_dot = False
    var exponent = -1
    for i in range(len(bytes)):
        if bytes[i] == 0x2E:
            has_dot = True
        elif (bytes[i] | 0x20) == 0x65:
            exponent = i
    if has_dot or exponent < 0:
        return text^
    return String(
        text[byte=0:exponent], ".0", text[byte = exponent : len(bytes)]
    )


def _write_hex(mut out: String, value: Int, digits: Int):
    """Appends `value` as `digits` uppercase hexadecimal digits.

    Args:
        out: The buffer to append to.
        value: The value to render.
        digits: How many digits to write.
    """
    var shift = (digits - 1) * 4
    while shift >= 0:
        var nibble = (value >> shift) & 0xF
        out += _HEX_UPPER[byte = nibble : nibble + 1]
        shift -= 4


def _codepoint_at(bytes: Span[UInt8, _], i: Int) -> Tuple[Int, Int]:
    """Decodes the UTF-8 codepoint starting at `i`.

    Args:
        bytes: The text to read.
        i: The offset of the codepoint's first byte.

    Returns:
        The codepoint and how many bytes it occupied.
    """
    var b = bytes[i]
    if b < 0x80:
        return (Int(b), 1)
    var width: Int
    var value: Int
    if b < 0xE0:
        value = Int(b & 0x1F)
        width = 2
    elif b < 0xF0:
        value = Int(b & 0x0F)
        width = 3
    else:
        value = Int(b & 0x07)
        width = 4
    for k in range(1, width):
        value = (value << 6) | Int(bytes[i + k] & 0x3F)
    return (value, width)


def _needs_double_quotes(bytes: Span[UInt8, _], allow_unicode: Bool) -> Bool:
    """Reports whether a string can only be written double-quoted.

    Args:
        bytes: The string's UTF-8 bytes.
        allow_unicode: Whether non-ASCII may be written verbatim.

    Returns:
        True if the text holds something only `"..."` can express.
    """
    for i in range(len(bytes)):
        var b = bytes[i]
        if b == 0x0A:
            # Folding strips the blanks around a line break, so a break that
            # touches one can only survive inside double quotes.
            if i and (bytes[i - 1] == 0x20 or bytes[i - 1] == 0x09):
                return True
            if i + 1 < len(bytes) and (
                bytes[i + 1] == 0x20 or bytes[i + 1] == 0x09
            ):
                return True
            continue
        if b < 0x20 or b == 0x7F:
            return True
        if b >= 0x80 and not allow_unicode:
            return True
    return False


def _is_plain_safe(bytes: Span[UInt8, _], in_flow: Bool) raises -> Bool:
    """Reports whether a string can be written without quotes.

    Args:
        bytes: The string's UTF-8 bytes.
        in_flow: Whether the scalar sits inside a flow collection, where the
            flow indicators would end it.

    Returns:
        True if the text is safe to write plain.

    Raises:
        Never; the signature matches its caller.
    """
    var n = len(bytes)
    if n == 0:
        return False
    if bytes[0] == _SPACE_BYTE or bytes[0] == _TAB_BYTE:
        return False
    if bytes[n - 1] == _SPACE_BYTE or bytes[n - 1] == _TAB_BYTE:
        return False

    var first = bytes[0]
    if (
        first == 0x23  # #
        or first == 0x2C  # ,
        or first == 0x5B  # [
        or first == 0x5D  # ]
        or first == 0x7B  # {
        or first == 0x7D  # }
        or first == 0x26  # &
        or first == 0x2A  # *
        or first == 0x21  # !
        or first == 0x7C  # |
        or first == 0x3E  # >
        or first == 0x27  # '
        or first == 0x22  # "
        or first == 0x25  # %
        or first == 0x40  # @
        or first == 0x60  # `
    ):
        return False
    if first == 0x2D or first == 0x3F or first == 0x3A:  # - ? :
        if n == 1 or bytes[1] == _SPACE_BYTE or bytes[1] == _TAB_BYTE:
            return False
    if n >= 3 and (
        (bytes[0] == 0x2D and bytes[1] == 0x2D and bytes[2] == 0x2D)
        or (bytes[0] == 0x2E and bytes[1] == 0x2E and bytes[2] == 0x2E)
    ):
        return False

    for i in range(n):
        var b = bytes[i]
        if b == 0x3A and (i + 1 == n or bytes[i + 1] == _SPACE_BYTE):
            return False
        if b == 0x23 and i > 0 and bytes[i - 1] == _SPACE_BYTE:
            return False
        if in_flow and (
            b == 0x2C or b == 0x5B or b == 0x5D or b == 0x7B or b == 0x7D
        ):
            return False
        if b == 0x0A:
            return False

    return loads_as_string(StringSlice(unsafe_from_utf8=bytes))


comptime _SPACE_BYTE: UInt8 = 0x20
comptime _TAB_BYTE: UInt8 = 0x09


def _single_quoted(bytes: Span[UInt8, _], continuation: Int) -> String:
    """Renders a string in single quotes.

    A line break becomes a blank line followed by the continuation indent,
    which is how YAML folding writes an embedded newline — and what PyYAML
    emits.

    Args:
        bytes: The string's UTF-8 bytes.
        continuation: The column continuation lines are indented to.

    Returns:
        The quoted text.
    """
    var pad = _spaces(continuation)
    var out = String("'")
    var i = 0
    while i < len(bytes):
        var b = bytes[i]
        if b == 0x27:
            out += "''"
            i += 1
        elif b == 0x0A:
            # A run of k line breaks folds back from k + 1 written ones.
            var run = 0
            while i < len(bytes) and bytes[i] == 0x0A:
                run += 1
                i += 1
            for _ in range(run + 1):
                out += "\n"
            out += pad
        else:
            out += StringSlice(unsafe_from_utf8=bytes[i : i + 1])
            i += 1
    out += "'"
    return out^


def _double_quoted(bytes: Span[UInt8, _], allow_unicode: Bool) -> String:
    """Renders a string in double quotes, escaping what YAML requires.

    Args:
        bytes: The string's UTF-8 bytes.
        allow_unicode: Whether non-ASCII may be written verbatim.

    Returns:
        The quoted text.
    """
    var out = String('"')
    var i = 0
    while i < len(bytes):
        var b = bytes[i]
        if b == 0x22:
            out += '\\"'
        elif b == 0x5C:
            out += "\\\\"
        elif b == 0x00:
            out += "\\0"
        elif b == 0x07:
            out += "\\a"
        elif b == 0x08:
            out += "\\b"
        elif b == 0x09:
            out += "\\t"
        elif b == 0x0A:
            out += "\\n"
        elif b == 0x0B:
            out += "\\v"
        elif b == 0x0C:
            out += "\\f"
        elif b == 0x0D:
            out += "\\r"
        elif b == 0x1B:
            out += "\\e"
        elif b < 0x20 or b == 0x7F:
            out += "\\x"
            _write_hex(out, Int(b), 2)
        elif b < 0x80:
            out += StringSlice(unsafe_from_utf8=bytes[i : i + 1])
        else:
            var cp, width = _codepoint_at(bytes, i)
            if cp == 0x85:
                out += "\\N"
            elif cp == 0xA0:
                out += "\\_"
            elif cp == 0x2028:
                out += "\\L"
            elif cp == 0x2029:
                out += "\\P"
            elif allow_unicode:
                out += StringSlice(unsafe_from_utf8=bytes[i : i + width])
            elif cp < 0x100:
                out += "\\x"
                _write_hex(out, cp, 2)
            elif cp <= 0xFFFF:
                out += "\\u"
                _write_hex(out, cp, 4)
            else:
                out += "\\U"
                _write_hex(out, cp, 8)
            i += width
            continue
        i += 1
    out += '"'
    return out^


def scalar_text(
    tape: _Tape,
    idx: UInt32,
    opts: EmitOptions,
    continuation: Int,
    in_flow: Bool,
) raises -> String:
    """Renders one scalar node.

    Args:
        tape: The document to read from.
        idx: The index of the scalar node.
        opts: The active emitter options.
        continuation: The column a folded line continues at.
        in_flow: Whether the scalar sits inside a flow collection.

    Returns:
        The scalar's YAML spelling.

    Raises:
        Never; the signature matches its callers.
    """
    var node = tape.nodes[Int(idx)]
    if node.kind == _KIND_NULL:
        return String("null")
    if node.kind == _KIND_BOOL:
        return String("true") if node.num != 0 else String("false")
    if node.kind == _KIND_INT:
        return String(Int64(node.num))
    if node.kind == _KIND_FLOAT:
        return _float_text(Float64(from_bits=node.num))

    var bytes = tape.str_bytes(idx)
    if _needs_double_quotes(bytes, opts.allow_unicode):
        return _double_quoted(bytes, opts.allow_unicode)
    if _is_plain_safe(bytes, in_flow):
        return String(unsafe_from_utf8=bytes)
    return _single_quoted(bytes, continuation)


def _member_order(tape: _Tape, node: _Node, sort_keys: Bool) -> List[Int]:
    """Returns member positions, sorted by key when asked.

    Args:
        tape: The document to read from.
        node: The mapping node.
        sort_keys: Whether to sort.

    Returns:
        The positions to emit, in order.
    """
    var count = Int(node.b)
    var order = List[Int](capacity=count)
    for i in range(count):
        order.append(i)
    if not sort_keys:
        return order^
    for i in range(1, count):
        var cur = order[i]
        var j = i - 1
        while j >= 0:
            if not _key_greater(tape, node, order[j], cur):
                break
            order[j + 1] = order[j]
            j -= 1
        order[j + 1] = cur
    return order^


def _key_greater(tape: _Tape, node: _Node, left: Int, right: Int) -> Bool:
    """Compares two member keys lexicographically.

    Args:
        tape: The document to read from.
        node: The mapping node.
        left: The first member position.
        right: The second member position.

    Returns:
        True if the left key sorts after the right one.
    """
    var a = tape.str_bytes(tape.kids[Int(node.a) + 2 * left])
    var b = tape.str_bytes(tape.kids[Int(node.a) + 2 * right])
    var n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return a[i] > b[i]
    return len(a) > len(b)


def flow_text(
    tape: _Tape,
    idx: UInt32,
    opts: EmitOptions,
    mut anchors: _Anchors,
    depth: Int,
) raises -> String:
    """Renders a value in flow style, on one line.

    Args:
        tape: The document to read from.
        idx: The index of the value.
        opts: The active emitter options.
        anchors: The anchor table for this document.
        depth: How deeply nested this value is.

    Returns:
        The flow spelling.

    Raises:
        `YAMLError` if the value nests deeper than `MAX_DEPTH`.
    """
    if depth > MAX_DEPTH:
        raise YAMLError(
            String("exceeded maximum nesting depth of ", MAX_DEPTH), 1, 1
        )
    var node = tape.nodes[Int(idx)]
    var is_container = node.kind == _KIND_ARRAY or node.kind == _KIND_OBJECT
    var prefix = String()
    if is_container:
        var mark = anchors.take(idx)
        if mark < 0:
            return String("*", _anchor_name(-mark))
        if mark > 0:
            prefix = String("&", _anchor_name(mark), " ")

    if node.kind == _KIND_ARRAY:
        var out = String(prefix, "[")
        for i in range(Int(node.b)):
            if i:
                out += ", "
            out += flow_text(
                tape, tape.kids[Int(node.a) + i], opts, anchors, depth + 1
            )
        out += "]"
        return out^
    if node.kind == _KIND_OBJECT:
        var order = _member_order(tape, node, opts.sort_keys)
        var out = String(prefix, "{")
        for i in range(Int(node.b)):
            if i:
                out += ", "
            var pos = order[i]
            out += scalar_text(
                tape, tape.kids[Int(node.a) + 2 * pos], opts, 0, True
            )
            out += ": "
            out += flow_text(
                tape,
                tape.kids[Int(node.a) + 2 * pos + 1],
                opts,
                anchors,
                depth + 1,
            )
        out += "}"
        return out^
    return scalar_text(tape, idx, opts, 0, True)


def _is_block_collection(node: _Node) -> Bool:
    """Reports whether a node is a collection that gets its own block.

    Args:
        node: The node to test.

    Returns:
        True for non-empty arrays and objects; an empty one is written inline
        as `[]` or `{}`.
    """
    return (
        node.kind == _KIND_ARRAY or node.kind == _KIND_OBJECT
    ) and node.b != 0


def emit_block(
    mut out: String,
    tape: _Tape,
    idx: UInt32,
    opts: EmitOptions,
    mut anchors: _Anchors,
    indent: Int,
    depth: Int,
    first_inline: Bool,
) raises:
    """Writes a non-empty collection in block style.

    Mappings and sequences share one routine, and it recurses into itself for
    every child, so the recursion is a single function — a longer cycle makes
    the Mojo elaborator hang.

    Args:
        out: The buffer to append to.
        tape: The document to read from.
        idx: The index of the collection.
        opts: The active emitter options.
        anchors: The anchor table for this document.
        indent: The column this collection's lines start at.
        depth: How deeply nested this collection is.
        first_inline: Whether the caller has already written the prefix for
            the first line, as happens after a `- `.

    Raises:
        `YAMLError` if the document nests deeper than `MAX_DEPTH`.
    """
    if depth > MAX_DEPTH:
        raise YAMLError(
            String("exceeded maximum nesting depth of ", MAX_DEPTH), 1, 1
        )
    var node = tape.nodes[Int(idx)]
    var pad = _spaces(indent)

    if node.kind == _KIND_OBJECT:
        var order = _member_order(tape, node, opts.sort_keys)
        for i in range(Int(node.b)):
            var pos = order[i]
            if i or not first_inline:
                out += pad
            out += scalar_text(
                tape,
                tape.kids[Int(node.a) + 2 * pos],
                opts,
                indent + opts.indent,
                False,
            )
            out += ":"
            var value = tape.kids[Int(node.a) + 2 * pos + 1]
            var child = tape.nodes[Int(value)]
            if _is_block_collection(child):
                var mark = anchors.take(value)
                if mark < 0:
                    out += String(" *", _anchor_name(-mark), "\n")
                    continue
                if mark > 0:
                    out += String(" &", _anchor_name(mark))
                out += "\n"
                # A nested mapping steps in; a sequence stays at the key's own
                # column, which is how PyYAML lays them out.
                var inner = (
                    indent + opts.indent if child.kind
                    == _KIND_OBJECT else indent
                )
                emit_block(
                    out, tape, value, opts, anchors, inner, depth + 1, False
                )
            else:
                out += " "
                out += _leaf_text(
                    tape, value, opts, anchors, indent + opts.indent
                )
                out += "\n"
        return

    for i in range(Int(node.b)):
        if i or not first_inline:
            out += pad
        out += "-"
        var item = tape.kids[Int(node.a) + i]
        var child = tape.nodes[Int(item)]
        if _is_block_collection(child):
            var mark = anchors.take(item)
            if mark < 0:
                out += String(" *", _anchor_name(-mark), "\n")
                continue
            if mark > 0:
                # The anchor takes the dash's line; the block follows below.
                out += String(" &", _anchor_name(mark), "\n")
                emit_block(
                    out,
                    tape,
                    item,
                    opts,
                    anchors,
                    indent + opts.indent,
                    depth + 1,
                    False,
                )
                continue
            out += _spaces(opts.indent - 1)
            emit_block(
                out,
                tape,
                item,
                opts,
                anchors,
                indent + opts.indent,
                depth + 1,
                True,
            )
        else:
            out += " "
            out += _leaf_text(tape, item, opts, anchors, indent + opts.indent)
            out += "\n"


def _leaf_text(
    tape: _Tape,
    idx: UInt32,
    opts: EmitOptions,
    mut anchors: _Anchors,
    continuation: Int,
) raises -> String:
    """Renders a value that fits on one line.

    Args:
        tape: The document to read from.
        idx: The index of the value.
        opts: The active emitter options.
        anchors: The anchor table for this document.
        continuation: The column a folded line continues at.

    Returns:
        The value's spelling: a scalar, or `[]`/`{}` for an empty collection.

    Raises:
        `YAMLError` if the value nests too deeply.
    """
    var node = tape.nodes[Int(idx)]
    if node.kind == _KIND_ARRAY or node.kind == _KIND_OBJECT:
        return flow_text(tape, idx, opts, anchors, 0)
    return scalar_text(tape, idx, opts, continuation, False)


def emit_document(
    mut out: String, tape: _Tape, idx: UInt32, opts: EmitOptions
) raises:
    """Writes one whole document, trailing newline included.

    Args:
        out: The buffer to append to.
        tape: The document to read from.
        idx: The index of the document's root.
        opts: The active emitter options.

    Raises:
        `YAMLError` if the document nests deeper than `MAX_DEPTH`.
    """
    if opts.explicit_start:
        out += "---\n"

    var anchors = _Anchors(len(tape.nodes))
    count_references(tape, idx, anchors.counts, 0)

    var node = tape.nodes[Int(idx)]
    if not opts.flow and _is_block_collection(node):
        var mark = anchors.take(idx)
        if mark > 0:
            out += String("&", _anchor_name(mark), "\n")
        emit_block(out, tape, idx, opts, anchors, 0, 0, False)
        return
    if node.kind != _KIND_ARRAY and node.kind != _KIND_OBJECT:
        # A top-level scalar folds its continuation lines to one indent step.
        var only = scalar_text(tape, idx, opts, opts.indent, False)
        var bare = only.byte_length() != 0 and not (
            only.as_bytes()[0] == 0x27 or only.as_bytes()[0] == 0x22
        )
        out += only
        out += "\n"
        if bare:
            # A plain scalar leaves the document open-ended, so PyYAML — and
            # this emitter — closes it explicitly.
            out += "...\n"
        return
    var text = flow_text(tape, idx, opts, anchors, 0)
    out += text
    out += "\n"
