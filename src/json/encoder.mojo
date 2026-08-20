"""Serialization of tape nodes back into JSON text.

The output is byte-for-byte compatible with CPython's `json.dumps` for every
option this module exposes, including the default separators (`", "` and
`": "`), `ensure_ascii` escaping with surrogate pairs, `NaN`/`Infinity`
spelling, and `indent` layout.
"""

from std.math import isinf, isnan

from .tape import (
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


# ===-----------------------------------------------------------------------===#
# Options
# ===-----------------------------------------------------------------------===#


struct Indent(Copyable, ImplicitlyCopyable, Movable):
    """The `indent` argument of `dumps`.

    Accepts the same shapes CPython does: `None` for a single line, an `Int`
    for that many spaces per level, or a string used verbatim per level.
    """

    var text: String
    """The literal text repeated once per nesting level."""

    var enabled: Bool
    """Whether pretty-printing is on at all."""

    @implicit
    def __init__(out self, value: NoneType):
        """Disables pretty printing.

        Args:
            value: Always `None`.
        """
        self.text = String()
        self.enabled = False

    @implicit
    def __init__(out self, spaces: Int):
        """Indents each level by `spaces` spaces.

        CPython treats `indent=0` as "newlines but no indentation", which this
        reproduces.

        Args:
            spaces: The number of spaces per nesting level.
        """
        self.text = String(" ") * spaces
        self.enabled = True

    @implicit
    def __init__(out self, text: StringLiteral):
        """Indents each level with `text`.

        Args:
            text: The literal indent for one nesting level.
        """
        self = Self(StringSlice(text))

    @implicit
    def __init__(out self, text: StringSlice):
        """Indents each level with `text`.

        Args:
            text: The literal indent for one nesting level.
        """
        self.text = String(text)
        self.enabled = True


struct EncodeOptions(Copyable, ImplicitlyCopyable, Movable):
    """The fully resolved set of knobs used while writing a document."""

    var item_sep: String
    """Written between array elements and between object members."""

    var key_sep: String
    """Written between an object key and its value."""

    var indent: Indent
    """The pretty-printing indent, if any."""

    var sort_keys: Bool
    """Whether object members are emitted in sorted key order."""

    var ensure_ascii: Bool
    """Whether non-ASCII codepoints are escaped as `\\uXXXX`."""

    var allow_nan: Bool
    """Whether `NaN` and `Infinity` may be emitted instead of raising."""

    def __init__(
        out self,
        *,
        var indent: Indent = Indent(None),
        var separators: Optional[Tuple[String, String]] = None,
        sort_keys: Bool = False,
        ensure_ascii: Bool = True,
        allow_nan: Bool = True,
    ):
        """Resolves the user-facing arguments into concrete separators.

        Args:
            indent: The pretty-printing indent.
            separators: An explicit `(item_sep, key_sep)` pair.
            sort_keys: Whether to sort object keys.
            ensure_ascii: Whether to escape non-ASCII codepoints.
            allow_nan: Whether to allow `NaN` and `Infinity`.
        """
        if separators:
            var seps = separators.take()
            self.item_sep = seps[0]
            self.key_sep = seps[1]
        elif indent.enabled:
            # CPython drops the trailing space from the item separator when
            # indenting, because a newline follows it anyway.
            self.item_sep = String(",")
            self.key_sep = String(": ")
        else:
            self.item_sep = String(", ")
            self.key_sep = String(": ")
        self.indent = indent^
        self.sort_keys = sort_keys
        self.ensure_ascii = ensure_ascii
        self.allow_nan = allow_nan


# ===-----------------------------------------------------------------------===#
# Scalars
# ===-----------------------------------------------------------------------===#

comptime _HEX_DIGITS = StaticString("0123456789abcdef")


@always_inline
def _needs_escape(b: UInt8, ensure_ascii: Bool) -> Bool:
    """Reports whether a byte cannot be copied to the output verbatim.

    Args:
        b: The byte to test.
        ensure_ascii: Whether non-ASCII bytes must be escaped too.

    Returns:
        True if the byte needs an escape sequence.
    """
    # CPython's ensure_ascii keeps `0x20 <= c < 0x7f` verbatim, so DEL is
    # escaped along with everything non-ASCII.
    return b < 0x20 or b == 0x22 or b == 0x5C or (ensure_ascii and b >= 0x7F)


def _write_hex4(mut writer: Some[Writer], value: UInt32):
    """Writes a `\\uXXXX` escape for a BMP scalar value.

    Args:
        writer: The writer to write to.
        value: The value to escape, which must fit in 16 bits.
    """
    writer.write_string("\\u")
    var shift = 12
    while shift >= 0:
        var nibble = Int((value >> UInt32(shift)) & 0xF)
        writer.write_string(_HEX_DIGITS[byte = nibble : nibble + 1])
        shift -= 4


def _write_escaped(
    mut writer: Some[Writer], bytes: Span[UInt8, _], ensure_ascii: Bool
):
    """Writes `bytes` as a quoted, escaped JSON string.

    Runs of ordinary characters are copied in one go, so a string with no
    escapes costs a single `write_string` call.

    Args:
        writer: The writer to write to.
        bytes: The UTF-8 contents of the string.
        ensure_ascii: Whether to escape non-ASCII codepoints as `\\uXXXX`.
    """
    writer.write_string('"')
    var n = len(bytes)
    var run_start = 0
    var i = 0
    while i < n:
        var b = bytes[i]
        if not _needs_escape(b, ensure_ascii):
            i += 1
            continue

        if i > run_start:
            writer.write_string(
                StringSlice(unsafe_from_utf8=bytes[run_start:i])
            )

        if b == 0x22:
            writer.write_string('\\"')
            i += 1
        elif b == 0x5C:
            writer.write_string("\\\\")
            i += 1
        elif b == 0x08:
            writer.write_string("\\b")
            i += 1
        elif b == 0x0C:
            writer.write_string("\\f")
            i += 1
        elif b == 0x0A:
            writer.write_string("\\n")
            i += 1
        elif b == 0x0D:
            writer.write_string("\\r")
            i += 1
        elif b == 0x09:
            writer.write_string("\\t")
            i += 1
        elif b < 0x80:
            # A control character, or DEL under `ensure_ascii`.
            _write_hex4(writer, UInt32(b))
            i += 1
        else:
            # A non-ASCII codepoint under `ensure_ascii`. Decode it so we can
            # emit `\uXXXX`, using a surrogate pair beyond the BMP exactly as
            # CPython does.
            var cp: UInt32
            var width: Int
            if b < 0xE0:
                cp = (UInt32(b) & 0x1F) << 6
                width = 2
            elif b < 0xF0:
                cp = (UInt32(b) & 0x0F) << 12
                width = 3
            else:
                cp = (UInt32(b) & 0x07) << 18
                width = 4
            for k in range(1, width):
                cp |= (UInt32(bytes[i + k]) & 0x3F) << UInt32(
                    (width - 1 - k) * 6
                )
            if cp > 0xFFFF:
                var v = cp - 0x10000
                _write_hex4(writer, 0xD800 + (v >> 10))
                _write_hex4(writer, 0xDC00 + (v & 0x3FF))
            else:
                _write_hex4(writer, cp)
            i += width
        run_start = i

    if n > run_start:
        writer.write_string(StringSlice(unsafe_from_utf8=bytes[run_start:n]))
    writer.write_string('"')


def _write_float(
    mut writer: Some[Writer], value: Float64, allow_nan: Bool
) raises:
    """Writes a float using CPython's `repr` spelling.

    Args:
        writer: The writer to write to.
        value: The float to write.
        allow_nan: Whether non-finite values are permitted.

    Raises:
        If the value is not finite and `allow_nan` is False.
    """
    if isnan(value):
        if not allow_nan:
            raise Error("Out of range float values are not JSON compliant: nan")
        writer.write_string("NaN")
    elif isinf(value):
        if not allow_nan:
            raise Error(
                "Out of range float values are not JSON compliant: ",
                "inf" if value > 0 else "-inf",
            )
        writer.write_string("Infinity" if value > 0 else "-Infinity")
    else:
        writer.write(value)


# ===-----------------------------------------------------------------------===#
# Documents
# ===-----------------------------------------------------------------------===#


def _write_newline_indent(
    mut writer: Some[Writer], opts: EncodeOptions, depth: Int
):
    """Writes a newline followed by `depth` levels of indentation.

    Args:
        writer: The writer to write to.
        opts: The active encoder options.
        depth: The nesting depth to indent to.
    """
    writer.write_string("\n")
    for _ in range(depth):
        writer.write_string(opts.indent.text)


def _sorted_member_order(tape: _Tape, node: _Node) -> List[Int]:
    """Returns member positions ordered by key, comparing keys as byte strings.

    Args:
        tape: The tape holding the object.
        node: The object node.

    Returns:
        The member positions in sorted order.
    """
    var count = Int(node.b)
    var order = List[Int](capacity=count)
    for i in range(count):
        order.append(i)

    # Objects are small in practice, so an insertion sort beats setting up a
    # comparison-function-driven sort and it keeps ties in insertion order.
    for i in range(1, count):
        var cur = order[i]
        var cur_key = tape.str_bytes(tape.kids[Int(node.a) + 2 * cur])
        var j = i - 1
        while j >= 0:
            var other_key = tape.str_bytes(
                tape.kids[Int(node.a) + 2 * order[j]]
            )
            if not _bytes_greater(other_key, cur_key):
                break
            order[j + 1] = order[j]
            j -= 1
        order[j + 1] = cur
    return order^


def _bytes_greater(a: Span[UInt8, _], b: Span[UInt8, _]) -> Bool:
    """Compares two byte spans lexicographically.

    Args:
        a: The left span.
        b: The right span.

    Returns:
        True if `a` sorts after `b`.
    """
    var n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return a[i] > b[i]
    return len(a) > len(b)


def write_value(
    mut writer: Some[Writer],
    tape: _Tape,
    idx: UInt32,
    opts: EncodeOptions,
    depth: Int = 0,
) raises:
    """Writes the value at `idx` and everything below it.

    Args:
        writer: The writer to write to.
        tape: The document to read from.
        idx: The index of the value to write.
        opts: The active encoder options.
        depth: The current nesting depth, used for indentation.

    Raises:
        If a non-finite float is encountered and `allow_nan` is False.
    """
    var node = tape.nodes[Int(idx)]
    var kind = node.kind

    if kind == _KIND_NULL:
        writer.write_string("null")
    elif kind == _KIND_BOOL:
        writer.write_string("true" if node.num != 0 else "false")
    elif kind == _KIND_INT:
        writer.write(Int64(node.num))
    elif kind == _KIND_FLOAT:
        _write_float(writer, Float64(from_bits=node.num), opts.allow_nan)
    elif kind == _KIND_STRING:
        _write_escaped(writer, tape.str_bytes(idx), opts.ensure_ascii)
    elif kind == _KIND_ARRAY:
        var count = Int(node.b)
        if count == 0:
            writer.write_string("[]")
            return
        writer.write_string("[")
        for i in range(count):
            if i:
                writer.write_string(opts.item_sep)
            if opts.indent.enabled:
                _write_newline_indent(writer, opts, depth + 1)
            write_value(
                writer, tape, tape.kids[Int(node.a) + i], opts, depth + 1
            )
        if opts.indent.enabled:
            _write_newline_indent(writer, opts, depth)
        writer.write_string("]")
    else:
        var count = Int(node.b)
        if count == 0:
            writer.write_string("{}")
            return
        writer.write_string("{")
        var order = _sorted_member_order(
            tape, node
        ) if opts.sort_keys else List[Int]()
        for i in range(count):
            var pos = order[i] if opts.sort_keys else i
            if i:
                writer.write_string(opts.item_sep)
            if opts.indent.enabled:
                _write_newline_indent(writer, opts, depth + 1)
            var key = tape.kids[Int(node.a) + 2 * pos]
            _write_escaped(writer, tape.str_bytes(key), opts.ensure_ascii)
            writer.write_string(opts.key_sep)
            write_value(
                writer,
                tape,
                tape.kids[Int(node.a) + 2 * pos + 1],
                opts,
                depth + 1,
            )
        if opts.indent.enabled:
            _write_newline_indent(writer, opts, depth)
        writer.write_string("}")


def write_default(mut writer: Some[Writer], tape: _Tape, idx: UInt32):
    """Writes a value with CPython's default `dumps` options.

    This is the non-raising path used by `JSONValue.write_to`, so it always
    permits `NaN` and `Infinity`.

    Args:
        writer: The writer to write to.
        tape: The document to read from.
        idx: The index of the value to write.
    """
    try:
        write_value(writer, tape, idx, EncodeOptions())
    except:
        pass
