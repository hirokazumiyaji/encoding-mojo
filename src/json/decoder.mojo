"""The JSON parser.

The parser is a single pass over the input bytes with an explicit stack, so
nesting depth costs heap space rather than call frames and a pathological
document cannot overflow the machine stack.

Parsed values are appended to a `_Tape` as they are completed. Container
membership is staged on a `values` stack; when a `]` or `}` closes a container
its children are already the top entries of that stack, so they move into the
tape's child array as one contiguous run.
"""

from std.bit import count_trailing_zeros
from std.collections.string import atof
from std.memory import pack_bits

from .errors import JSONDecodeError
from .tape import (
    _reserve_extra,
    _KIND_ARRAY,
    _KIND_BOOL,
    _KIND_FLOAT,
    _KIND_INT,
    _KIND_NULL,
    _KIND_OBJECT,
    _KIND_STRING,
    _Node,
    _Tape,
    _bytes_equal,
)

comptime MAX_DEPTH = 1000
"""How deeply containers may nest before decoding gives up.

The parser itself is iterative and could go deeper, but a document this deep
cannot be walked recursively afterwards (by `dumps`, for instance), and CPython
raises `RecursionError` at a comparable depth.
"""

comptime _SCAN_WIDTH = 32
"""How many bytes the string scanner examines per SIMD step."""

comptime _TAB: UInt8 = 0x09
comptime _NEWLINE: UInt8 = 0x0A
comptime _RETURN: UInt8 = 0x0D
comptime _SPACE: UInt8 = 0x20
comptime _QUOTE: UInt8 = 0x22
comptime _PLUS: UInt8 = 0x2B
comptime _COMMA: UInt8 = 0x2C
comptime _MINUS: UInt8 = 0x2D
comptime _DOT: UInt8 = 0x2E
comptime _ZERO: UInt8 = 0x30
comptime _NINE: UInt8 = 0x39
comptime _COLON: UInt8 = 0x3A
comptime _BACKSLASH: UInt8 = 0x5C
comptime _LBRACKET: UInt8 = 0x5B
comptime _RBRACKET: UInt8 = 0x5D
comptime _LBRACE: UInt8 = 0x7B
comptime _RBRACE: UInt8 = 0x7D


comptime _MANTISSA_ROOM: UInt64 = (UInt64.MAX - 9) // 10
"""Largest mantissa that can still absorb one more decimal digit."""

comptime _EXACT_MANTISSA: UInt64 = UInt64(1) << 53
"""Mantissas below this are exactly representable as a `Float64`."""

comptime _POW10 = SIMD[DType.float64, 32](
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7,
    1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15,
    1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
)
"""Powers of ten up to 10^22, the largest one exactly representable."""


@always_inline
def _pow10(exponent: Int) -> Float64:
    """Returns `10 ** exponent` for an exponent in `[0, 22]`.

    Args:
        exponent: The power to raise ten to.

    Returns:
        The exact power of ten.
    """
    return materialize[_POW10]()[exponent]


@always_inline
def _is_digit(b: UInt8) -> Bool:
    """Reports whether `b` is an ASCII digit.

    Args:
        b: The byte to test.

    Returns:
        True for `0` through `9`.
    """
    return b >= _ZERO and b <= _NINE


@always_inline
def _hex_value(b: UInt8) -> Int:
    """Decodes one hexadecimal digit.

    Args:
        b: The byte to decode.

    Returns:
        The digit's value, or -1 if `b` is not a hexadecimal digit.
    """
    if b >= _ZERO and b <= _NINE:
        return Int(b - _ZERO)
    if b >= 0x61 and b <= 0x66:  # a-f
        return Int(b - 0x61) + 10
    if b >= 0x41 and b <= 0x46:  # A-F
        return Int(b - 0x41) + 10
    return -1


comptime _HASH_THRESHOLD = 8
"""Object size at which duplicate-key detection switches to a hash table.

Below this, a linear scan over the keys already staged is cheaper than hashing
every key. Above it the scan would be quadratic, which is ruinous for the
thousand-key objects real documents contain.
"""


@fieldwise_init
struct _Frame(Copyable, ImplicitlyCopyable, Movable):
    """One open container while parsing."""

    var is_object: Bool
    """Whether the container is an object rather than an array."""

    var stack_base: Int
    """Where this container's staged children start on the value stack."""

    var htab_base: Int
    """Start of this object's slots in the shared hash area."""

    var htab_cap: Int
    """Number of slots this object owns, always a power of two, 0 if none."""


@always_inline
def _hash_bytes(bytes: Span[UInt8, _]) -> UInt64:
    """Hashes a key with FNV-1a.

    Args:
        bytes: The key's bytes.

    Returns:
        The hash.
    """
    var h: UInt64 = 0xCBF29CE484222325
    for i in range(len(bytes)):
        h = (h ^ UInt64(bytes[i])) * 0x100000001B3
    return h


struct _Parser[origin: ImmOrigin](Movable):
    """A single decoding run over one document."""

    var src: Span[UInt8, Self.origin]
    """The bytes being decoded."""

    var pos: Int
    """The current read offset."""

    var tape: _Tape
    """The document being built."""

    var values: List[UInt32]
    """Completed node indices not yet claimed by their parent container."""

    var frames: List[_Frame]
    """The chain of containers currently open."""

    var htab: List[UInt32]
    """Open-addressing hash slots for large objects, one region per frame.

    A slot holds a member position plus one, so zero means empty. Regions are
    stacked: only the innermost object is ever probed, and its region is always
    on top, so growing it is a push and closing it is a pop."""

    var strict: Bool
    """Whether raw control characters inside strings are rejected."""

    var allow_nan: Bool
    """Whether `NaN`, `Infinity` and `-Infinity` are accepted."""

    def __init__(
        out self, src: Span[UInt8, Self.origin], *, strict: Bool, allow_nan: Bool
    ):
        """Prepares to decode `src`.

        Args:
            src: The document bytes.
            strict: Whether to reject raw control characters in strings.
            allow_nan: Whether to accept the non-standard number literals.
        """
        self.src = src
        self.pos = 0
        self.tape = _Tape(capacity_hint=len(src))
        self.values = []
        self.frames = []
        self.htab = []
        self.strict = strict
        self.allow_nan = allow_nan

    # ===-------------------------------------------------------------------===#
    # Primitives
    # ===-------------------------------------------------------------------===#

    @always_inline
    def _at_end(self) -> Bool:
        """Reports whether the whole document has been consumed.

        Returns:
            True if there are no bytes left.
        """
        return self.pos >= len(self.src)

    @always_inline
    def _byte(self, i: Int) -> UInt8:
        """Reads a byte the caller has already proved is in range.

        Args:
            i: The offset to read.

        Returns:
            The byte at `i`.
        """
        return self.src.unsafe_ptr()[unsafe_offset=i]

    def _scan_string(self, start: Int) -> Int:
        """Finds the next byte inside a string that needs attention.

        Args:
            start: Where to start scanning.

        Returns:
            The offset of the first quote, backslash or control character at or
            after `start`, or the end of input if there is none.
        """
        var n = len(self.src)
        var ptr = self.src.unsafe_ptr()
        var i = start
        while i + _SCAN_WIDTH <= n:
            var chunk = ptr.unsafe_offset(i).unsafe_load[width=_SCAN_WIDTH]()
            var hits = (
                chunk.eq(_QUOTE) | chunk.eq(_BACKSLASH) | chunk.lt(UInt8(0x20))
            )
            var bits = pack_bits(hits)
            if bits:
                return i + Int(count_trailing_zeros(bits))
            i += _SCAN_WIDTH
        while i < n:
            var b = ptr[unsafe_offset=i]
            if b == _QUOTE or b == _BACKSLASH or b < 0x20:
                return i
            i += 1
        return n

    @always_inline
    def _peek(self) -> UInt8:
        """Returns the byte at the cursor without consuming it.

        Returns:
            The current byte, or 0 at end of input.
        """
        return self._byte(self.pos) if self.pos < len(self.src) else UInt8(0)

    def _error(self, var msg: String, pos: Int) -> JSONDecodeError:
        """Builds a decode error located at `pos`.

        Args:
            msg: What the decoder expected.
            pos: The byte offset to report.

        Returns:
            The error, ready to raise.
        """
        return JSONDecodeError(msg^, self.src, pos)

    @always_inline
    def _skip_whitespace(mut self):
        """Advances the cursor past JSON whitespace."""
        var n = len(self.src)
        while self.pos < n:
            var b = self._byte(self.pos)
            if b != _SPACE and b != _TAB and b != _NEWLINE and b != _RETURN:
                return
            self.pos += 1

    def _match_keyword(mut self, word: StaticString) -> Bool:
        """Consumes `word` if it appears at the cursor.

        Args:
            word: The literal to match.

        Returns:
            True if the literal was consumed.
        """
        var bytes = word.as_bytes()
        if self.pos + len(bytes) > len(self.src):
            return False
        if not _bytes_equal(
            self.src[self.pos : self.pos + len(bytes)], bytes
        ):
            return False
        self.pos += len(bytes)
        return True

    # ===-------------------------------------------------------------------===#
    # Strings
    # ===-------------------------------------------------------------------===#

    def _parse_string(mut self) raises -> UInt32:
        """Parses the string at the cursor and appends it to the tape.

        Returns:
            The index of the new string node.

        Raises:
            If the string is unterminated or contains an invalid escape.
        """
        var quote_start = self.pos
        self.pos += 1  # the opening quote
        var n = len(self.src)
        var run_start = self.pos

        # Fast path: scan 32 bytes at a time for the closing quote and copy the
        # whole string in one go. Only a backslash forces the slow,
        # byte-at-a-time path.
        var i = run_start
        while True:
            i = self._scan_string(i)
            if i >= n:
                raise self._error(
                    String("Unterminated string starting at"), quote_start
                )
            var b = self._byte(i)
            if b == _QUOTE:
                self.pos = i + 1
                return self.tape.push_string(self.src[run_start:i])
            if b == _BACKSLASH:
                break
            if self.strict:
                raise self._error(String("Invalid control character at"), i)
            i += 1  # a control character, which non-strict mode keeps verbatim

        # Slow path: decode escapes straight into the tape's byte buffer so no
        # intermediate allocation is needed.
        var offset = UInt32(len(self.tape.buf))
        _reserve_extra(self.tape.buf, i - run_start)
        self.tape.buf.extend(self.src[run_start:i])
        self.pos = i

        while True:
            if self.pos >= n:
                raise self._error(
                    String("Unterminated string starting at"), quote_start
                )
            var b = self._byte(self.pos)
            if b == _QUOTE:
                self.pos += 1
                break
            if b == _BACKSLASH:
                self._decode_escape()
                continue
            if b < 0x20 and self.strict:
                raise self._error(String("Invalid control character at"), self.pos)

            # Copy the run of ordinary bytes up to the next escape or quote.
            var start = self.pos
            var j = self._scan_string(start)
            while j < n and self._byte(j) < 0x20 and not self.strict:
                j = self._scan_string(j + 1)
            _reserve_extra(self.tape.buf, j - start)
            self.tape.buf.extend(self.src[start:j])
            self.pos = j

        var length = UInt32(len(self.tape.buf)) - offset
        return self.tape.push(_Node.string(offset, length))

    def _decode_escape(mut self) raises:
        """Consumes one `\\`-escape and appends its bytes to the tape buffer.

        Raises:
            If the escape is not one JSON defines.
        """
        var esc_start = self.pos
        if self.pos + 1 >= len(self.src):
            raise self._error(String("Invalid \\escape"), esc_start)
        var e = self._byte(self.pos + 1)
        self.pos += 2

        if e == _QUOTE:
            self.tape.buf.append(_QUOTE)
        elif e == _BACKSLASH:
            self.tape.buf.append(_BACKSLASH)
        elif e == 0x2F:  # /
            self.tape.buf.append(0x2F)
        elif e == 0x62:  # b
            self.tape.buf.append(0x08)
        elif e == 0x66:  # f
            self.tape.buf.append(0x0C)
        elif e == 0x6E:  # n
            self.tape.buf.append(0x0A)
        elif e == 0x72:  # r
            self.tape.buf.append(0x0D)
        elif e == 0x74:  # t
            self.tape.buf.append(0x09)
        elif e == 0x75:  # u
            var cp = self._read_hex4(esc_start + 1)
            if cp >= 0xD800 and cp <= 0xDBFF:
                # A high surrogate: pair it with the low surrogate that must
                # follow to recover an astral codepoint.
                if (
                    self.pos + 1 < len(self.src)
                    and self._byte(self.pos) == _BACKSLASH
                    and self._byte(self.pos + 1) == 0x75
                ):
                    var pair_start = self.pos
                    self.pos += 2
                    var low = self._read_hex4(pair_start + 1)
                    if low >= 0xDC00 and low <= 0xDFFF:
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00)
                    else:
                        # Not a low surrogate after all; both halves are
                        # unpaired.
                        self._append_utf8(_REPLACEMENT)
                        cp = low if not _is_surrogate(low) else _REPLACEMENT
                else:
                    cp = _REPLACEMENT
            elif cp >= 0xDC00 and cp <= 0xDFFF:
                cp = _REPLACEMENT
            self._append_utf8(cp)
        else:
            raise self._error(String("Invalid \\escape"), esc_start)

    def _read_hex4(mut self, marker_pos: Int) raises -> Int:
        """Reads the four hexadecimal digits of a `\\uXXXX` escape.

        Args:
            marker_pos: The offset of the `u`, which is where CPython reports
                a malformed escape.

        Returns:
            The scalar value the digits encode.

        Raises:
            If fewer than four hexadecimal digits follow.
        """
        if self.pos + 4 > len(self.src):
            raise self._error(String("Invalid \\uXXXX escape"), marker_pos)
        var value = 0
        for k in range(4):
            var digit = _hex_value(self._byte(self.pos + k))
            if digit < 0:
                raise self._error(String("Invalid \\uXXXX escape"), marker_pos)
            value = value * 16 + digit
        self.pos += 4
        return value

    def _append_utf8(mut self, cp: Int):
        """Appends one codepoint to the tape buffer as UTF-8.

        Args:
            cp: The codepoint to encode.
        """
        if cp < 0x80:
            self.tape.buf.append(UInt8(cp))
        elif cp < 0x800:
            self.tape.buf.append(UInt8(0xC0 | (cp >> 6)))
            self.tape.buf.append(UInt8(0x80 | (cp & 0x3F)))
        elif cp < 0x10000:
            self.tape.buf.append(UInt8(0xE0 | (cp >> 12)))
            self.tape.buf.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
            self.tape.buf.append(UInt8(0x80 | (cp & 0x3F)))
        else:
            self.tape.buf.append(UInt8(0xF0 | (cp >> 18)))
            self.tape.buf.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
            self.tape.buf.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
            self.tape.buf.append(UInt8(0x80 | (cp & 0x3F)))

    # ===-------------------------------------------------------------------===#
    # Numbers
    # ===-------------------------------------------------------------------===#

    def _parse_number(mut self) raises -> UInt32:
        """Parses the number at the cursor and appends it to the tape.

        The accepted grammar is CPython's: an optional `-`, then `0` or a
        digit sequence not starting with `0`, then an optional fraction and an
        optional exponent. A trailing `.` or `e` that is not followed by digits
        simply ends the number, which is why `loads("1.")` reports extra data
        rather than a malformed number.

        Digits are accumulated into a 64-bit mantissa during the single scan,
        so the common case needs no second pass and no `strtod` call.

        Returns:
            The index of the new number node.

        Raises:
            If no number starts at the cursor.
        """
        var start = self.pos
        var n = len(self.src)
        var negative = False

        if self._byte(self.pos) == _MINUS:
            negative = True
            self.pos += 1

        if self.pos >= n or not _is_digit(self._byte(self.pos)):
            self.pos = start
            raise self._error(String("Expecting value"), start)

        var mantissa: UInt64 = 0
        var exp10 = 0
        var inexact = False

        if self._byte(self.pos) == _ZERO:
            self.pos += 1
        else:
            while self.pos < n and _is_digit(self._byte(self.pos)):
                if mantissa <= _MANTISSA_ROOM:
                    mantissa = mantissa * 10 + UInt64(self._byte(self.pos) - _ZERO)
                else:
                    # The mantissa is full; keep the magnitude by counting the
                    # remaining digits as an exponent.
                    inexact = True
                    exp10 += 1
                self.pos += 1

        var is_float = False
        if (
            self.pos + 1 < n
            and self._byte(self.pos) == _DOT
            and _is_digit(self._byte(self.pos + 1))
        ):
            is_float = True
            self.pos += 1
            while self.pos < n and _is_digit(self._byte(self.pos)):
                if mantissa <= _MANTISSA_ROOM:
                    mantissa = mantissa * 10 + UInt64(self._byte(self.pos) - _ZERO)
                    exp10 -= 1
                else:
                    inexact = True
                self.pos += 1

        if self.pos < n and (self._byte(self.pos) | 0x20) == 0x65:  # e or E
            var probe = self.pos + 1
            var exp_negative = False
            if probe < n and (self._byte(probe) == _PLUS or self._byte(probe) == _MINUS):
                exp_negative = self._byte(probe) == _MINUS
                probe += 1
            if probe < n and _is_digit(self._byte(probe)):
                is_float = True
                self.pos = probe
                var magnitude = 0
                while self.pos < n and _is_digit(self._byte(self.pos)):
                    if magnitude < 0x10000:
                        magnitude = magnitude * 10 + Int(self._byte(self.pos) - _ZERO)
                    self.pos += 1
                exp10 += -magnitude if exp_negative else magnitude

        if not is_float and not inexact:
            var limit = UInt64(1) << 63
            if mantissa < limit or (negative and mantissa == limit):
                var signed = -Int64(mantissa) if negative else Int64(mantissa)
                return self.tape.push(_Node.scalar(_KIND_INT, UInt64(signed)))

        var value: Float64
        if not inexact and mantissa < _EXACT_MANTISSA and -22 <= exp10 <= 22:
            # Both the mantissa and the power of ten are exactly representable,
            # so a single multiply or divide rounds once and lands on the same
            # double `strtod` would produce.
            var scaled = Float64(mantissa)
            if exp10 >= 0:
                scaled *= _pow10(exp10)
            else:
                scaled /= _pow10(-exp10)
            value = -scaled if negative else scaled
        else:
            # Too many digits, or an exponent outside the exactly representable
            # range: fall back to a correctly rounded general conversion. This
            # is also where an integer too large for 64 bits widens to a float,
            # which CPython would have kept exact as a big integer.
            value = atof(StringSlice(unsafe_from_utf8=self.src[start : self.pos]))

        return self.tape.push(
            _Node.scalar(_KIND_FLOAT, value.to_bits[DType.uint64]())
        )

    # ===-------------------------------------------------------------------===#
    # Values
    # ===-------------------------------------------------------------------===#

    def _parse_scalar(mut self) raises -> UInt32:
        """Parses one non-container value at the cursor.

        Returns:
            The index of the new node.

        Raises:
            If no value starts at the cursor.
        """
        var b = self._peek()

        if b == _QUOTE:
            return self._parse_string()
        if b == _MINUS or _is_digit(b):
            if b == _MINUS and self.allow_nan and self._peek_at(1) == 0x49:  # I
                var start = self.pos
                self.pos += 1
                if self._match_keyword("Infinity"):
                    return self.tape.push(
                        _Node.scalar(
                            _KIND_FLOAT,
                            Float64("-inf").to_bits[DType.uint64](),
                        )
                    )
                self.pos = start
            return self._parse_number()
        if b == 0x74:  # t
            if self._match_keyword("true"):
                return self.tape.push(_Node.scalar(_KIND_BOOL, 1))
        elif b == 0x66:  # f
            if self._match_keyword("false"):
                return self.tape.push(_Node.scalar(_KIND_BOOL, 0))
        elif b == 0x6E:  # n
            if self._match_keyword("null"):
                return self.tape.push(_Node.scalar(_KIND_NULL))
        elif self.allow_nan and b == 0x4E:  # N
            if self._match_keyword("NaN"):
                return self.tape.push(
                    _Node.scalar(_KIND_FLOAT, Float64("nan").to_bits[DType.uint64]())
                )
        elif self.allow_nan and b == 0x49:  # I
            if self._match_keyword("Infinity"):
                return self.tape.push(
                    _Node.scalar(_KIND_FLOAT, Float64("inf").to_bits[DType.uint64]())
                )

        raise self._error(String("Expecting value"), self.pos)

    @always_inline
    def _peek_at(self, offset: Int) -> UInt8:
        """Returns the byte `offset` positions ahead of the cursor.

        Args:
            offset: How far ahead to look.

        Returns:
            The byte, or 0 past the end of input.
        """
        var i = self.pos + offset
        return self._byte(i) if i < len(self.src) else UInt8(0)

    def _close_container(mut self) raises:
        """Turns the innermost open container into a tape node.

        Raises:
            Never; the signature matches the rest of the parser.
        """
        var frame = self.frames.pop()
        if frame.htab_cap:
            self.htab.shrink(frame.htab_base)
        var slots = len(self.values) - frame.stack_base
        var count = slots // 2 if frame.is_object else slots
        var start = UInt32(len(self.tape.kids))
        _reserve_extra(self.tape.kids, slots)
        for i in range(slots):
            self.tape.kids.append(self.values[frame.stack_base + i])
        self.values.shrink(frame.stack_base)
        var kind = _KIND_OBJECT if frame.is_object else _KIND_ARRAY
        self.values.append(
            self.tape.push(
                _Node.container(kind, start, UInt32(count), UInt32(slots))
            )
        )

    def _dedupe_last_member(mut self):
        """Applies CPython's duplicate-key rule to the member just completed.

        A repeated key keeps the position of its first appearance but takes the
        latest value, exactly like assigning into a Python dict.
        """
        var depth = len(self.frames) - 1
        var base = self.frames[depth].stack_base
        var end = len(self.values) - 2
        var members = (end - base) // 2

        if members < _HASH_THRESHOLD and self.frames[depth].htab_cap == 0:
            var key = self.values[end]
            var i = base
            while i < end:
                if _bytes_equal(
                    self.tape.str_bytes(self.values[i]),
                    self.tape.str_bytes(key),
                ):
                    self.values[i + 1] = self.values[end + 1]
                    self.values.shrink(end)
                    return
                i += 2
            return

        if self.frames[depth].htab_cap == 0:
            self._build_hash_index(depth, members)
        elif (members + 1) * 4 > self.frames[depth].htab_cap * 3:
            self._build_hash_index(depth, members)

        var found = self._probe_insert(depth, members)
        if found >= 0:
            self.values[base + 2 * found + 1] = self.values[end + 1]
            self.values.shrink(end)

    def _build_hash_index(mut self, depth: Int, members: Int):
        """Rebuilds the innermost object's hash region, doubling its capacity.

        Args:
            depth: The index of the frame in `frames`.
            members: How many members are already staged.
        """
        var old_base = self.frames[depth].htab_base
        if self.frames[depth].htab_cap:
            self.htab.shrink(old_base)

        var cap = 16
        while cap * 3 <= (members + 1) * 4:
            cap *= 2
        var base = len(self.htab)
        _reserve_extra(self.htab, cap)
        for _ in range(cap):
            self.htab.append(0)
        self.frames[depth].htab_base = base
        self.frames[depth].htab_cap = cap

        var stack_base = self.frames[depth].stack_base
        for i in range(members):
            var key = self.values[stack_base + 2 * i]
            var slot = Int(_hash_bytes(self.tape.str_bytes(key))) & (cap - 1)
            while self.htab[base + slot] != 0:
                slot = (slot + 1) & (cap - 1)
            self.htab[base + slot] = UInt32(i + 1)

    def _probe_insert(mut self, depth: Int, members: Int) -> Int:
        """Looks the newest key up, inserting it when it is new.

        Args:
            depth: The index of the frame in `frames`.
            members: How many members precede the one being inserted.

        Returns:
            The position of the earlier member with the same key, or -1.
        """
        var base = self.frames[depth].htab_base
        var cap = self.frames[depth].htab_cap
        var stack_base = self.frames[depth].stack_base
        var key = self.values[len(self.values) - 2]
        var key_bytes = self.tape.str_bytes(key)
        var slot = Int(_hash_bytes(key_bytes)) & (cap - 1)

        while True:
            var entry = self.htab[base + slot]
            if entry == 0:
                self.htab[base + slot] = UInt32(members + 1)
                return -1
            var pos = Int(entry) - 1
            if _bytes_equal(
                self.tape.str_bytes(self.values[stack_base + 2 * pos]),
                key_bytes,
            ):
                return pos
            slot = (slot + 1) & (cap - 1)

    def take_tape(deinit self) -> _Tape:
        """Consumes the parser and hands back the tape it built.

        Returns:
            The decoded document's tape.
        """
        return self.tape^

    def parse(mut self) raises -> UInt32:
        """Decodes the whole document.

        Returns:
            The index of the root node.

        Raises:
            `JSONDecodeError` if the document is not valid JSON.
        """
        self._skip_whitespace()

        while True:
            # --- a value is expected here ---
            var b = self._peek()
            if b == _LBRACKET or b == _LBRACE:
                if len(self.frames) >= MAX_DEPTH:
                    raise self._error(
                        String(
                            "Exceeded maximum nesting depth of ", MAX_DEPTH
                        ),
                        self.pos,
                    )
                var is_object = b == _LBRACE
                self.pos += 1
                self.frames.append(_Frame(is_object, len(self.values), 0, 0))
                self._skip_whitespace()

                if is_object:
                    if self._peek() == _RBRACE:
                        self.pos += 1
                        self._close_container()
                    else:
                        self._parse_member()
                        continue
                else:
                    if self._peek() == _RBRACKET:
                        self.pos += 1
                        self._close_container()
                    else:
                        continue
            else:
                self.values.append(self._parse_scalar())

            # --- a value has just been completed ---
            while True:
                if not self.frames:
                    self._skip_whitespace()
                    if not self._at_end():
                        raise self._error(String("Extra data"), self.pos)
                    return self.values[0]

                var frame = self.frames[len(self.frames) - 1]
                if frame.is_object:
                    self._dedupe_last_member()
                self._skip_whitespace()
                var closer = _RBRACE if frame.is_object else _RBRACKET
                var next = self._peek()

                if next == closer:
                    self.pos += 1
                    self._close_container()
                    continue
                if next != _COMMA:
                    raise self._error(
                        String("Expecting ',' delimiter"), self.pos
                    )
                self.pos += 1
                self._skip_whitespace()
                if frame.is_object:
                    self._parse_member()
                break

    def _parse_member(mut self) raises:
        """Parses one `"key": value` pair into the innermost object.

        Raises:
            If the key is not a quoted string, or the colon is missing.
        """
        if self._peek() != _QUOTE:
            raise self._error(
                String("Expecting property name enclosed in double quotes"),
                self.pos,
            )
        self.values.append(self._parse_string())
        self._skip_whitespace()
        if self._peek() != _COLON:
            raise self._error(String("Expecting ':' delimiter"), self.pos)
        self.pos += 1
        self._skip_whitespace()


comptime _REPLACEMENT = 0xFFFD
"""The codepoint substituted for an unpaired surrogate escape.

CPython can hold a lone surrogate in a `str`; Mojo strings are strictly UTF-8,
so the closest faithful decoding is U+FFFD REPLACEMENT CHARACTER.
"""


@always_inline
def _is_surrogate(cp: Int) -> Bool:
    """Reports whether `cp` is in the UTF-16 surrogate range.

    Args:
        cp: The codepoint to test.

    Returns:
        True for U+D800 through U+DFFF.
    """
    return cp >= 0xD800 and cp <= 0xDFFF


struct ParsedDocument(Movable):
    """A decoded document: the tape and the index of its root node."""

    var tape: _Tape
    """The tape holding every decoded value."""

    var root: UInt32
    """The index of the document's root node."""

    def __init__(out self, var tape: _Tape, root: UInt32):
        """Stores a decoded document.

        Args:
            tape: The tape holding every decoded value.
            root: The index of the root node.
        """
        self.tape = tape^
        self.root = root

    def take_tape(deinit self) -> _Tape:
        """Consumes the document and hands back its tape.

        Returns:
            The tape holding every decoded value.
        """
        return self.tape^


def parse_document(
    src: Span[UInt8, _], *, strict: Bool, allow_nan: Bool
) raises -> ParsedDocument:
    """Decodes `src` into a fresh tape.

    Args:
        src: The document bytes.
        strict: Whether to reject raw control characters in strings.
        allow_nan: Whether to accept `NaN`, `Infinity` and `-Infinity`.

    Returns:
        The tape and the index of its root node.

    Raises:
        `JSONDecodeError` if the document is not valid JSON.
    """
    var parser = _Parser(src, strict=strict, allow_nan=allow_nan)
    var root = parser.parse()
    return ParsedDocument(parser^.take_tape(), root)
