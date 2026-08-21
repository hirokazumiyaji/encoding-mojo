"""The error raised when a document cannot be loaded."""


struct YAMLError(Copyable, ImplicitlyCopyable, Movable, Writable):
    """A syntax or semantic error in a YAML document.

    Formats itself the way PyYAML does, naming what went wrong and pointing at
    the line and column where it was found:

    ```text
    could not find expected ':'
      in "<unicode string>", line 2, column 6
    ```
    """

    var problem: String
    """What went wrong."""

    var line: Int
    """The one-based line number of the offending character."""

    var column: Int
    """The one-based column number of the offending character."""

    def __init__(out self, var problem: String, line: Int, column: Int):
        """Records a failure at a position.

        Args:
            problem: What went wrong.
            line: The one-based line number.
            column: The one-based column number.
        """
        self.problem = problem^
        self.line = line
        self.column = column

    def write_to(self, mut writer: Some[Writer]):
        """Writes the PyYAML-style message.

        Args:
            writer: The writer to write to.
        """
        writer.write(
            self.problem,
            '\n  in "<unicode string>", line ',
            self.line,
            ", column ",
            self.column,
        )
