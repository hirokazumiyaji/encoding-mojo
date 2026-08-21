"""The error raised when a document cannot be decoded."""


struct JSONDecodeError(Copyable, ImplicitlyCopyable, Movable, Writable):
    """A syntax error in a JSON document.

    Formats itself exactly like CPython's `json.JSONDecodeError`, so a caught
    error reads the same in both languages:

    ```text
    Expecting ',' delimiter: line 1 column 8 (char 7)
    ```
    """

    var msg: String
    """What the decoder expected, without any position information."""

    var pos: Int
    """The zero-based byte offset of the offending character."""

    var lineno: Int
    """The one-based line number of `pos`."""

    var colno: Int
    """The one-based column number of `pos`, counted in bytes."""

    def __init__(out self, var msg: String, doc: Span[UInt8, _], pos: Int):
        """Locates `pos` within `doc` and records the failure.

        Args:
            msg: What the decoder expected.
            doc: The document being decoded.
            pos: The byte offset of the offending character.
        """
        self.msg = msg^
        self.pos = pos
        var line_start = 0
        var lineno = 1
        for i in range(min(pos, len(doc))):
            if doc[i] == 0x0A:
                lineno += 1
                line_start = i + 1
        self.lineno = lineno
        self.colno = pos - line_start + 1

    def write_to(self, mut writer: Some[Writer]):
        """Writes the CPython-compatible message.

        Args:
            writer: The writer to write to.
        """
        writer.write(
            self.msg,
            ": line ",
            self.lineno,
            " column ",
            self.colno,
            " (char ",
            self.pos,
            ")",
        )
