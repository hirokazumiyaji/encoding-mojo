"""The error raised when a CSV document cannot be read or written."""


struct CSVError(Copyable, ImplicitlyCopyable, Movable, Writable):
    """A malformed record, or a format that cannot be written.

    This is CPython's `csv.Error`, and carries the same wording:

    ```text
    ',' expected after '"'
    ```
    """

    var message: String
    """What went wrong."""

    def __init__(out self, var message: String):
        """Records a failure.

        Args:
            message: What went wrong.
        """
        self.message = message^

    def write_to(self, mut writer: Some[Writer]):
        """Writes the message.

        Args:
            writer: The writer to write to.
        """
        writer.write(self.message)
