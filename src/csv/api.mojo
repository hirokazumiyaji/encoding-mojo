"""The module-level functions that mirror CPython's `csv`."""

from std.io.file import FileHandle

from .dialect import Dialect
from .reader import _Parser
from .writer import _Writer


def reader(
    text: StringSlice, dialect: Dialect = Dialect()
) raises -> List[List[String]]:
    """Reads a whole CSV document.

    Args:
        text: The document to read.
        dialect: The format parameters, `excel` by default.

    Returns:
        One row of fields per record, in order.

    Raises:
        `CSVError` if a record is malformed and the dialect is strict, or if a
        field grows past the dialect's limit.
    """
    var parser = _Parser(dialect)
    return parser.run(text)


def load(
    file: FileHandle, dialect: Dialect = Dialect()
) raises -> List[List[String]]:
    """Reads a whole file as CSV.

    Args:
        file: The file to read from.
        dialect: The format parameters, `excel` by default.

    Returns:
        One row of fields per record, in order.

    Raises:
        `CSVError` if a record is malformed and the dialect is strict, or any
        error raised while reading the file.
    """
    var text = file.read()
    return reader(text, dialect)


def writer(dialect: Dialect = Dialect()) -> _Writer:
    """Opens a writer that collects rows as CSV text.

    Args:
        dialect: The format parameters, `excel` by default.

    Returns:
        A writer with `writerow`, `writerows` and `text`.
    """
    return _Writer(dialect)


def writes(
    rows: List[List[String]], dialect: Dialect = Dialect()
) raises -> String:
    """Writes every record and returns the document.

    Args:
        rows: The records to write.
        dialect: The format parameters, `excel` by default.

    Returns:
        The CSV text, each record ending with the dialect's terminator.

    Raises:
        `CSVError` if a field needs an escape and none is set, or if a record
        is a single empty field that cannot be quoted.
    """
    var out = _Writer(dialect)
    out.writerows(rows)
    return out.text()


def dump(
    rows: List[List[String]],
    mut file: Some[Writer],
    dialect: Dialect = Dialect(),
) raises:
    """Writes every record straight into `file`.

    Args:
        rows: The records to write.
        file: The writer to write to.
        dialect: The format parameters, `excel` by default.

    Raises:
        `CSVError` if a record cannot be written.
    """
    file.write_string(writes(rows, dialect))
