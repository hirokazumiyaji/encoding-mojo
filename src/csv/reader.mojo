"""The state machine CPython's `_csv` reader runs, character by character.

The states and their transitions are CPython's, including the parts that only
show up in malformed input: a quote in the middle of an unquoted field is
data, data after a closing quote joins the field, and a field left open at the
end of the text is returned as it stands unless the dialect is strict.

CPython feeds the machine one line at a time and signals the end of each with
a sentinel. A line ends at `LF`, at `CRLF`, or at a lone `CR`, which is how
Python splits a text stream opened with `newline=""`. The driver below splits
the same way, so the two agree on every document.
"""

from std.math import isinf, isnan

from .dialect import QUOTE_NONE, QUOTE_NONNUMERIC, Dialect
from .errors import CSVError
from .numbers import decimal_value, is_float_space

comptime _EOL = UInt32(0xFFFFFFFF)
"""Stands for the end of a line, which is not a character in the text."""

comptime _START_RECORD = 0
comptime _START_FIELD = 1
comptime _ESCAPED_CHAR = 2
comptime _IN_FIELD = 3
comptime _IN_QUOTED_FIELD = 4
comptime _ESCAPE_IN_QUOTED_FIELD = 5
comptime _QUOTE_IN_QUOTED_FIELD = 6
comptime _EAT_CRNL = 7
comptime _AFTER_ESCAPED_CRNL = 8

comptime _LF = UInt32(0x0A)
comptime _CR = UInt32(0x0D)
comptime _SPACE = UInt32(0x20)


def _append_utf8(mut out: List[UInt8], cp: UInt32):
    """Appends one codepoint to `out` as UTF-8.

    Args:
        out: The buffer to append to.
        cp: The codepoint to encode.
    """
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xF0 | (cp >> 18)))
        out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))


def _normalized(text: StringSlice) -> Optional[String]:
    """Rewrites a field into the ASCII number `atof` can read, or `None`.

    Python's `float` reaches wider than `atof` does in three ways, and all
    three are undone here: it strips Unicode whitespace from both ends, it
    takes any Unicode decimal digit, and it allows digit-grouping
    underscores between two digits.

    Args:
        text: The field's text.

    Returns:
        The same number written in ASCII, or `None` if a character rules it
        out on its own.
    """
    var bytes = text.as_bytes()
    var n = len(bytes)

    var start = 0
    while start < n:
        var cp: UInt32
        var width: Int
        cp, width = _decode(bytes, start)
        if not is_float_space(cp):
            break
        start += width
    var end = n
    while end > start:
        var back = end - 1
        while back > start and (bytes[back] & 0xC0) == 0x80:
            back -= 1
        var trailing = _decode(bytes, back)
        if not is_float_space(trailing[0]):
            break
        end = back

    var out = List[UInt8](capacity=end - start)
    var i = start
    var previous_digit = False
    while i < end:
        var cp: UInt32
        var width: Int
        cp, width = _decode(bytes, i)
        i += width
        if cp == 0x5F:  # _
            # A separator has to sit between two digits, and the one after it
            # is checked on the next turn of the loop.
            if not previous_digit or i >= end:
                return None
            if decimal_value(_decode(bytes, i)[0]) < 0:
                return None
            previous_digit = False
            continue
        var digit = decimal_value(cp)
        if digit >= 0:
            out.append(UInt8(0x30 + digit))
            previous_digit = True
            continue
        if cp >= 0x80:
            # Nothing else outside ASCII belongs in a float literal.
            return None
        out.append(UInt8(cp))
        previous_digit = False
    return String(unsafe_from_utf8=Span(out))


def _digits(bytes: Span[UInt8, _], start: Int) -> Int:
    """Counts the ASCII digits at `start`.

    Args:
        bytes: The text to scan.
        start: Where to start counting.

    Returns:
        How many digits run from `start`.
    """
    var i = start
    while i < len(bytes) and bytes[i] >= 0x30 and bytes[i] <= 0x39:
        i += 1
    return i - start


def _is_python_float(text: StringSlice) -> Bool:
    """Reports whether Python's `float` would accept this text.

    Mojo's `atof` takes shapes Python does not, `+2+2` among them, so the
    grammar is checked here rather than left to the conversion.

    Args:
        text: The text to check, already normalized to ASCII.

    Returns:
        True if the text is a float literal Python would read.
    """
    var bytes = text.as_bytes()
    var n = len(bytes)
    var i = 0
    if i < n and (bytes[i] == 0x2B or bytes[i] == 0x2D):  # + -
        i += 1
    if i == n:
        return False

    var rest = StringSlice(unsafe_from_utf8=bytes[i:n]).lower()
    if rest == "inf" or rest == "infinity" or rest == "nan":
        return True

    var before = _digits(bytes, i)
    i += before
    var after = 0
    if i < n and bytes[i] == 0x2E:  # .
        i += 1
        after = _digits(bytes, i)
        i += after
    if before == 0 and after == 0:
        return False
    if i < n and (bytes[i] | 0x20) == 0x65:  # e
        i += 1
        if i < n and (bytes[i] == 0x2B or bytes[i] == 0x2D):
            i += 1
        var exponent = _digits(bytes, i)
        if exponent == 0:
            return False
        i += exponent
    return i == n


def _float_text(text: StringSlice) raises -> String:
    """Reads a field as a number and renders it the way Python's `str` does.

    CPython hands the field to `float()` and puts the number in the row. A row
    here is text, so the number goes back to text immediately — which still
    normalizes it, so `1` reads as `1.0`.

    Args:
        text: The field's text.

    Returns:
        The number, rendered.

    Raises:
        `ValueError` with CPython's wording if the text is not a number.
    """
    var bad = String("could not convert string to float: '", text, "'")
    var cleaned = _normalized(text)
    if not cleaned:
        raise Error(bad)
    var digits = cleaned.value()
    if not _is_python_float(digits):
        raise Error(bad)
    var value: Float64
    try:
        value = atof(digits)
    except:
        raise Error(bad)
    if isnan(value):
        return String("nan")
    if isinf(value):
        return String("inf") if value > 0 else String("-inf")
    return String(value)


struct _Parser(Movable):
    """One run of the reader over one document."""

    var dialect: Dialect
    """The format parameters in force."""

    var state: Int
    """Which of the `_*` states the machine is in."""

    var field: List[UInt8]
    """The field being built, as UTF-8."""

    var field_length: Int
    """How many characters the field holds, which is what the limit counts."""

    var numeric: Bool
    """Whether the open field started unquoted under `QUOTE_NONNUMERIC`."""

    var row: List[String]
    """The record being built."""

    var rows: List[List[String]]
    """Every record read so far."""

    def __init__(out self, dialect: Dialect):
        """Starts a run.

        Args:
            dialect: The format parameters to read with.
        """
        self.dialect = dialect
        self.state = _START_RECORD
        self.field = []
        self.field_length = 0
        self.numeric = False
        self.row = []
        self.rows = []

    def _add_run(mut self, run: Span[UInt8, _]) raises:
        """Appends a run of ordinary characters to the open field.

        Args:
            run: The bytes to append, none of which is special here.

        Raises:
            If the field would grow past the dialect's limit.
        """
        var added = 0
        for i in range(len(run)):
            # Continuation bytes belong to a character already counted.
            if (run[i] & 0xC0) != 0x80:
                added += 1
        if self.field_length + added > self.dialect.field_size_limit:
            raise CSVError(
                String(
                    "field larger than field limit (",
                    self.dialect.field_size_limit,
                    ")",
                )
            )
        self.field.extend(run)
        self.field_length += added

    def _add(mut self, cp: UInt32) raises:
        """Appends one character to the open field.

        Args:
            cp: The character to append.

        Raises:
            If the field would grow past the dialect's limit.
        """
        if self.field_length >= self.dialect.field_size_limit:
            raise CSVError(
                String(
                    "field larger than field limit (",
                    self.dialect.field_size_limit,
                    ")",
                )
            )
        _append_utf8(self.field, cp)
        self.field_length += 1

    def _save_field(mut self) raises:
        """Closes the open field and puts it on the record.

        Raises:
            If `QUOTE_NONNUMERIC` is in force and the field is not a number.
        """
        var text = StringSlice(unsafe_from_utf8=Span(self.field))
        if self.numeric:
            self.numeric = False
            self.row.append(_float_text(text))
        else:
            self.row.append(String(text))
        self.field.clear()
        self.field_length = 0

    def _save_row(mut self):
        """Closes the record being built."""
        self.rows.append(self.row^)
        self.row = []

    def _process(mut self, var cp: UInt32) raises:
        """Feeds one character, or `_EOL`, to the machine.

        Args:
            cp: The character, or `_EOL` at the end of a line.

        Raises:
            `CSVError` if the record is malformed and the dialect is strict,
            or if a field grows past the limit.
        """
        var d = self.dialect
        while True:
            if self.state == _START_RECORD:
                if cp == _EOL:
                    return
                if cp == _LF or cp == _CR:
                    self.state = _EAT_CRNL
                    return
                self.state = _START_FIELD
                continue

            if self.state == _START_FIELD:
                if cp == _LF or cp == _CR or cp == _EOL:
                    self._save_field()
                    self.state = _START_RECORD if cp == _EOL else _EAT_CRNL
                elif d.quotes() and cp == d.quotechar:
                    self.state = _IN_QUOTED_FIELD
                elif d.has_escapechar and cp == d.escapechar:
                    self.state = _ESCAPED_CHAR
                elif cp == _SPACE and d.skipinitialspace:
                    pass
                elif cp == d.delimiter:
                    self._save_field()
                else:
                    if d.quoting == QUOTE_NONNUMERIC:
                        self.numeric = True
                    self._add(cp)
                    self.state = _IN_FIELD
                return

            if self.state == _ESCAPED_CHAR:
                if cp == _LF or cp == _CR:
                    self._add(cp)
                    self.state = _AFTER_ESCAPED_CRNL
                    return
                if cp == _EOL:
                    cp = _LF
                self._add(cp)
                self.state = _IN_FIELD
                return

            if self.state == _AFTER_ESCAPED_CRNL:
                if cp == _EOL:
                    return
                self.state = _IN_FIELD
                continue

            if self.state == _IN_FIELD:
                if cp == _LF or cp == _CR or cp == _EOL:
                    self._save_field()
                    self.state = _START_RECORD if cp == _EOL else _EAT_CRNL
                elif d.has_escapechar and cp == d.escapechar:
                    self.state = _ESCAPED_CHAR
                elif cp == d.delimiter:
                    self._save_field()
                    self.state = _START_FIELD
                else:
                    self._add(cp)
                return

            if self.state == _IN_QUOTED_FIELD:
                if cp == _EOL:
                    pass
                elif d.has_escapechar and cp == d.escapechar:
                    self.state = _ESCAPE_IN_QUOTED_FIELD
                elif d.quotes() and cp == d.quotechar:
                    self.state = (
                        _QUOTE_IN_QUOTED_FIELD if d.doublequote else _IN_FIELD
                    )
                else:
                    self._add(cp)
                return

            if self.state == _ESCAPE_IN_QUOTED_FIELD:
                if cp == _EOL:
                    cp = _LF
                self._add(cp)
                self.state = _IN_QUOTED_FIELD
                return

            if self.state == _QUOTE_IN_QUOTED_FIELD:
                if d.quoting != QUOTE_NONE and cp == d.quotechar:
                    self._add(cp)
                    self.state = _IN_QUOTED_FIELD
                elif cp == d.delimiter:
                    self._save_field()
                    self.state = _START_FIELD
                elif cp == _LF or cp == _CR or cp == _EOL:
                    self._save_field()
                    self.state = _START_RECORD if cp == _EOL else _EAT_CRNL
                elif not d.strict:
                    self._add(cp)
                    self.state = _IN_FIELD
                else:
                    raise CSVError(
                        String(
                            "'",
                            _character(d.delimiter),
                            "' expected after '",
                            _character(d.quotechar),
                            "'",
                        )
                    )
                return

            # _EAT_CRNL
            if cp == _LF or cp == _CR:
                return
            if cp == _EOL:
                self.state = _START_RECORD
                return
            raise CSVError(
                String(
                    "new-line character seen in unquoted field - do you need"
                    " to open the file in universal-newline mode?"
                )
            )

    def run(mut self, text: StringSlice) raises -> List[List[String]]:
        """Reads a whole document.

        Args:
            text: The document to read.

        Returns:
            One row of fields per record.

        Raises:
            `CSVError` if a record is malformed and the dialect is strict, or
            if a field grows past the limit.
        """
        var d = self.dialect
        # A run of ordinary bytes can be copied without decoding, but only
        # when every character the machine reacts to is ASCII: a byte of a
        # multi-byte character is then never one of them.
        var ascii_specials = (
            d.delimiter < 0x80
            and (not d.has_quotechar or d.quotechar < 0x80)
            and (not d.has_escapechar or d.escapechar < 0x80)
        )
        var field_stop = UInt8(d.delimiter) if ascii_specials else 0x80
        var quoted_stop = UInt8(
            d.quotechar
        ) if ascii_specials and d.has_quotechar else UInt8(0x80)
        var escape_stop = UInt8(
            d.escapechar
        ) if ascii_specials and d.has_escapechar else UInt8(0x80)

        var bytes = text.as_bytes()
        var n = len(bytes)
        var i = 0
        while i < n:
            # One line, ending at LF, CRLF or a lone CR, terminator included.
            while i < n:
                if ascii_specials and (
                    self.state == _IN_FIELD or self.state == _IN_QUOTED_FIELD
                ):
                    var stop = (
                        field_stop if self.state == _IN_FIELD else quoted_stop
                    )
                    var j = i
                    while j < n:
                        var b = bytes[j]
                        if b < 0x80 and (
                            b == stop
                            or b == escape_stop
                            or b == 0x0A
                            or b == 0x0D
                        ):
                            break
                        j += 1
                    if j > i:
                        self._add_run(bytes[i:j])
                        i = j
                        continue

                var cp: UInt32
                var width: Int
                cp, width = _decode(bytes, i)
                i += width
                self._process(cp)
                if cp == _LF:
                    break
                if cp == _CR:
                    if i < n and bytes[i] == 0x0A:
                        self._process(_LF)
                        i += 1
                    break
            self._process(_EOL)
            if self.state == _START_RECORD:
                self._save_row()

        if self.field_length != 0 or self.state == _IN_QUOTED_FIELD:
            if self.dialect.strict:
                raise CSVError(String("unexpected end of data"))
            self._save_field()
            self._save_row()
        var out = self.rows^
        self.rows = []
        return out^


def _decode(bytes: Span[UInt8, _], i: Int) -> Tuple[UInt32, Int]:
    """Decodes the UTF-8 codepoint starting at `i`.

    Args:
        bytes: The text to read.
        i: The offset of the codepoint's first byte.

    Returns:
        The codepoint and how many bytes it occupied.
    """
    var b = bytes[i]
    if b < 0x80:
        return (UInt32(b), 1)
    var width: Int
    var value: UInt32
    if b < 0xE0:
        value = UInt32(b & 0x1F)
        width = 2
    elif b < 0xF0:
        value = UInt32(b & 0x0F)
        width = 3
    else:
        value = UInt32(b & 0x07)
        width = 4
    if i + width > len(bytes):
        return (UInt32(b), 1)
    for k in range(1, width):
        value = (value << 6) | UInt32(bytes[i + k] & 0x3F)
    return (value, width)


def _character(cp: UInt32) -> String:
    """Renders one codepoint as text, for an error message.

    Args:
        cp: The codepoint to render.

    Returns:
        The character on its own.
    """
    var out = List[UInt8]()
    _append_utf8(out, cp)
    return String(unsafe_from_utf8=Span(out))
