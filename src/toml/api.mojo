"""The module-level functions that mirror CPython's `tomllib`."""

from std.io.file import FileHandle
from std.memory import ArcPointer

from serde import Value

from .emitter import EmitOptions, emit_document
from .errors import TOMLDecodeError
from .parser import _Parser


def loads(text: StringSlice) raises -> Value:
    """Decodes a TOML document.

    Args:
        text: The document to decode.

    Returns:
        The decoded document, always a table.

    Raises:
        `TOMLDecodeError` if the text is not valid TOML.
    """
    var parser = _Parser(text.as_bytes())
    var root = parser.parse()
    return Value(tape=ArcPointer(parser^.take_tape()), idx=root)


def load(file: FileHandle) raises -> Value:
    """Reads a whole file and decodes it.

    Args:
        file: The file to read from.

    Returns:
        The decoded document.

    Raises:
        `TOMLDecodeError` if the file does not hold valid TOML, or any error
        raised while reading it.
    """
    var text = file.read()
    return loads(text)


def dumps(
    value: Value, *, multiline_strings: Bool = False, indent: Int = 4
) raises -> String:
    """Serializes a table to a TOML string.

    Args:
        value: The document to serialize, which must be a table.
        multiline_strings: Whether a string holding a newline may be written
            with `\"\"\"` instead of a `\\n` escape.
        indent: Spaces per level inside a multi-line array.

    Returns:
        The TOML text, ending with a newline unless the table is empty.

    Raises:
        If `value` is not a table, if it holds something TOML cannot express,
        or if `indent` is negative.
    """
    var opts = EmitOptions(multiline_strings=multiline_strings, indent=indent)
    return emit_document(value._tape[], value._idx, opts)


def dump(
    value: Value,
    mut file: Some[Writer],
    *,
    multiline_strings: Bool = False,
    indent: Int = 4,
) raises:
    """Serializes a table straight into `file`.

    Args:
        value: The document to serialize, which must be a table.
        file: The writer to write to.
        multiline_strings: Whether a string holding a newline may be written
            with `\"\"\"` instead of a `\\n` escape.
        indent: Spaces per level inside a multi-line array.

    Raises:
        If `value` is not a table, if it holds something TOML cannot express,
        or if `indent` is negative.
    """
    file.write_string(
        dumps(value, multiline_strings=multiline_strings, indent=indent)
    )
