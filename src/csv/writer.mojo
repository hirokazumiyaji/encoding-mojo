"""Rendering rows back into CSV text, the way CPython's `_csv` writer does.

A field is quoted only when its own characters say so, and the decision is
made while scanning it: the delimiter, a carriage return, a newline, a
character of the line terminator, or a quote that gets doubled all force
quotes, while a character that gets escaped does not. That is why a field
holding a backslash comes out escaped but unquoted when the backslash is the
escape character.

A carriage return and a newline are special whatever the line terminator is,
so a field holding one is quoted even when rows end with the other.
"""

from .dialect import QUOTE_ALL, QUOTE_NONE, QUOTE_NONNUMERIC, Dialect
from .errors import CSVError
from .reader import _append_utf8, _decode

comptime _NEED_ESCAPE = "need to escape, but no escapechar set"


def _terminator_extras(dialect: Dialect) -> List[UInt32]:
    """Returns the line-terminator characters that are not already special.

    A carriage return and a newline are special whatever the terminator is,
    so for the usual `CRLF` and `LF` this is empty and the writer never has
    to look at the terminator again.

    Args:
        dialect: The format parameters in force.

    Returns:
        The terminator's other characters, in order.
    """
    var out = List[UInt32]()
    var bytes = dialect.lineterminator.as_bytes()
    var i = 0
    while i < len(bytes):
        var cp: UInt32
        var width: Int
        cp, width = _decode(bytes, i)
        i += width
        if cp != 0x0A and cp != 0x0D:
            out.append(cp)
    return out^


struct _Writer(Movable):
    """Collects rows as CSV text."""

    var dialect: Dialect
    """The format parameters in force."""

    var out: String
    """Everything written so far."""

    def __init__(out self, dialect: Dialect):
        """Starts an empty document.

        Args:
            dialect: The format parameters to write with.
        """
        self.dialect = dialect
        self.out = String()

    def writerow(mut self, row: List[String]) raises:
        """Writes one record, terminator included.

        Args:
            row: The fields to write.

        Raises:
            `CSVError` if a field needs an escape and none is set, or if the
            record is a single empty field that cannot be quoted.
        """
        var numeric = List[Bool](length=len(row), fill=False)
        self._write(row, numeric)

    def _write(mut self, row: List[String], numeric: List[Bool]) raises:
        """Writes one record, knowing which fields came from numbers.

        The record is assembled on its own and appended in one go, so a field
        that cannot be written leaves the document exactly as it was — which
        is what CPython does when a row fails halfway.

        Args:
            row: The fields to write.
            numeric: Whether each field stands for a number, which is what
                `QUOTE_NONNUMERIC` leaves unquoted. All false for a row of
                plain text.

        Raises:
            `CSVError` if a field needs an escape and none is set, or if the
            record is a single empty field that cannot be quoted.
        """
        var d = self.dialect
        var line = String()
        var delimiter = _encoded(d.delimiter)
        var quote = _encoded(d.quotechar) if d.has_quotechar else String()
        var escape = _encoded(d.escapechar) if d.has_escapechar else String()
        var extras = _terminator_extras(d)

        for index in range(len(row)):
            if index:
                line += delimiter
            var quoted = d.quoting == QUOTE_ALL or (
                d.quoting == QUOTE_NONNUMERIC and not numeric[index]
            )
            var body = List[UInt8]()

            var bytes = row[index].as_bytes()
            var n = len(bytes)
            var run = 0
            var i = 0
            while i < n:
                var cp: UInt32
                var width: Int
                cp, width = _decode(bytes, i)

                var special = (
                    cp == d.delimiter
                    or (d.has_escapechar and cp == d.escapechar)
                    or (d.has_quotechar and cp == d.quotechar)
                    or cp == 0x0A
                    or cp == 0x0D
                )
                if not special:
                    for k in range(len(extras)):
                        if cp == extras[k]:
                            special = True
                            break
                if not special:
                    i += width
                    continue

                body.extend(bytes[run:i])
                var wants_escape = False
                if d.quoting == QUOTE_NONE:
                    wants_escape = True
                else:
                    if d.has_quotechar and cp == d.quotechar:
                        if d.doublequote:
                            body.extend(quote.as_bytes())
                        else:
                            wants_escape = True
                    elif d.has_escapechar and cp == d.escapechar:
                        wants_escape = True
                    if not wants_escape:
                        quoted = True
                if wants_escape:
                    if not d.has_escapechar:
                        raise CSVError(String(_NEED_ESCAPE))
                    body.extend(escape.as_bytes())
                body.extend(bytes[i : i + width])
                i += width
                run = i
            body.extend(bytes[run:n])

            if quoted:
                if not d.has_quotechar:
                    raise CSVError(String(_NEED_ESCAPE))
                line += quote
                line += StringSlice(unsafe_from_utf8=Span(body))
                line += quote
            else:
                line += StringSlice(unsafe_from_utf8=Span(body))

        if len(row) > 0 and line.byte_length() == 0:
            # One empty field on its own would read back as an empty record,
            # so it has to be written quoted.
            if d.quoting == QUOTE_NONE or not d.has_quotechar:
                raise CSVError(
                    String("single empty field record must be quoted")
                )
            line += quote
            line += quote
        line += d.lineterminator
        self.out += line

    def writerows(mut self, rows: List[List[String]]) raises:
        """Writes several records in order.

        Args:
            rows: The records to write.

        Raises:
            Whatever `writerow` raises.
        """
        for row in rows:
            self.writerow(row)

    def text(self) -> String:
        """Returns everything written so far.

        Returns:
            The CSV document.
        """
        return self.out.copy()


def _encoded(cp: UInt32) -> String:
    """Renders one codepoint as a string, once, for repeated appending.

    Args:
        cp: The codepoint to render.

    Returns:
        The character on its own.
    """
    var bytes = List[UInt8]()
    _append_utf8(bytes, cp)
    return String(unsafe_from_utf8=Span(bytes))
