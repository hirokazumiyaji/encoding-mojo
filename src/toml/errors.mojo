"""The error raised when a document cannot be decoded."""


struct TOMLDecodeError(Copyable, ImplicitlyCopyable, Movable, Writable):
    """A syntax or semantic error in a TOML document.

    Formats itself the way CPython's `tomllib.TOMLDecodeError` does:

    ```text
    Cannot overwrite a value (at line 2, column 6)
    ```
    """

    var problem: String
    """What went wrong."""

    var line: Int
    """The one-based line number, or 0 at the end of the document."""

    var column: Int
    """The one-based column number, or 0 at the end of the document."""

    def __init__(out self, var problem: String, line: Int, column: Int):
        """Records a failure at a position.

        Args:
            problem: What went wrong.
            line: The one-based line number, or 0 for end of document.
            column: The one-based column number, or 0 for end of document.
        """
        self.problem = problem^
        self.line = line
        self.column = column

    def write_to(self, mut writer: Some[Writer]):
        """Writes the message in `tomllib`'s format.

        Args:
            writer: The writer to write to.
        """
        writer.write(self.problem)
        if self.line == 0:
            writer.write(" (at end of document)")
        else:
            writer.write(" (at line ", self.line, ", column ", self.column, ")")
