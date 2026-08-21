"""The module-level functions that mirror CPython's `json` package."""

from std.io.file import FileHandle
from std.memory import ArcPointer

from .decoder import parse_document
from .hooks import NoNumberHook, NoValueHook, NumberHook, ValueHook
from serde import EncodeOptions, Indent, write_value
from serde import Value as JSONValue


def dumps(
    value: JSONValue,
    *,
    var indent: Indent = Indent(None),
    var separators: Optional[Tuple[String, String]] = None,
    sort_keys: Bool = False,
    ensure_ascii: Bool = True,
    allow_nan: Bool = True,
) raises -> String:
    """Serializes `value` to a JSON string.

    The defaults match CPython's, including the `", "` and `": "` separators
    that make the default output *not* compact.

    Args:
        value: The value to serialize. Native Mojo values convert implicitly,
            so `dumps(1)` and `dumps("x")` both work.
        indent: `None` for one line, an `Int` for that many spaces per level,
            or a string used verbatim per level.
        separators: An explicit `(item_separator, key_separator)` pair.
        sort_keys: Whether to emit object members in sorted key order.
        ensure_ascii: Whether to escape non-ASCII codepoints as `\\uXXXX`.
        allow_nan: Whether to emit `NaN`, `Infinity` and `-Infinity` instead
            of raising for non-finite floats.

    Returns:
        The JSON text.

    Raises:
        If a non-finite float is encountered while `allow_nan` is False.
    """
    var opts = EncodeOptions(
        indent=indent^,
        separators=separators^,
        sort_keys=sort_keys,
        ensure_ascii=ensure_ascii,
        allow_nan=allow_nan,
    )
    var out = String()
    write_value(out, value._tape[], value._idx, opts)
    return out^


def loads[
    ParseInt: NumberHook = NoNumberHook,
    ParseFloat: NumberHook = NoNumberHook,
    ParseConstant: NumberHook = NoNumberHook,
    ObjectHook: ValueHook = NoValueHook,
](
    text: StringSlice, *, strict: Bool = True, allow_nan: Bool = True
) raises -> JSONValue:
    """Decodes a JSON document.

    Parameters:
        ParseInt: Replaces the value integer literals decode to, the way
            CPython's `parse_int` does.
        ParseFloat: Replaces the value float literals decode to.
        ParseConstant: Replaces the value `NaN`, `Infinity` and `-Infinity`
            decode to.
        ObjectHook: Replaces each decoded object, innermost first.

    Args:
        text: The document to decode.
        strict: Whether raw control characters inside strings are rejected,
            as CPython's `strict=True` does.
        allow_nan: Whether the non-standard `NaN`, `Infinity` and `-Infinity`
            literals are accepted, as CPython does by default.

    Returns:
        The decoded document.

    Raises:
        `JSONDecodeError` if the text is not valid JSON, or whatever a hook
        raises.
    """
    var parsed = parse_document[
        ParseInt, ParseFloat, ParseConstant, ObjectHook
    ](text.as_bytes(), strict=strict, allow_nan=allow_nan)
    var root = parsed.root
    return JSONValue(tape=ArcPointer(parsed^.take_tape()), idx=root)


def dump(
    value: JSONValue,
    mut file: Some[Writer],
    *,
    var indent: Indent = Indent(None),
    var separators: Optional[Tuple[String, String]] = None,
    sort_keys: Bool = False,
    ensure_ascii: Bool = True,
    allow_nan: Bool = True,
) raises:
    """Serializes `value` straight into `file`.

    Nothing is buffered in memory first, so a large document streams out as it
    is walked.

    Args:
        value: The value to serialize.
        file: The destination, such as a `FileHandle` or a `String`.
        indent: `None` for one line, an `Int` for that many spaces per level,
            or a string used verbatim per level.
        separators: An explicit `(item_separator, key_separator)` pair.
        sort_keys: Whether to emit object members in sorted key order.
        ensure_ascii: Whether to escape non-ASCII codepoints as `\\uXXXX`.
        allow_nan: Whether to emit `NaN`, `Infinity` and `-Infinity` instead
            of raising for non-finite floats.

    Raises:
        If a non-finite float is encountered while `allow_nan` is False.
    """
    var opts = EncodeOptions(
        indent=indent^,
        separators=separators^,
        sort_keys=sort_keys,
        ensure_ascii=ensure_ascii,
        allow_nan=allow_nan,
    )
    write_value(file, value._tape[], value._idx, opts)


def load(
    file: FileHandle, *, strict: Bool = True, allow_nan: Bool = True
) raises -> JSONValue:
    """Reads a whole file and decodes it.

    Args:
        file: The file to read from, positioned at the start of the document.
        strict: Whether raw control characters inside strings are rejected.
        allow_nan: Whether `NaN`, `Infinity` and `-Infinity` are accepted.

    Returns:
        The decoded document.

    Raises:
        `JSONDecodeError` if the file does not hold valid JSON, or any error
        raised while reading it.
    """
    var text = file.read()
    return loads(text)


def loads[
    ParseInt: NumberHook = NoNumberHook,
    ParseFloat: NumberHook = NoNumberHook,
    ParseConstant: NumberHook = NoNumberHook,
    ObjectHook: ValueHook = NoValueHook,
](
    data: Span[UInt8, _], *, strict: Bool = True, allow_nan: Bool = True
) raises -> JSONValue:
    """Decodes a JSON document held as UTF-8 bytes.

    Parameters:
        ParseInt: Replaces the value integer literals decode to.
        ParseFloat: Replaces the value float literals decode to.
        ParseConstant: Replaces the value the non-standard constants decode to.
        ObjectHook: Replaces each decoded object, innermost first.

    Args:
        data: The document bytes.
        strict: Whether raw control characters inside strings are rejected.
        allow_nan: Whether `NaN`, `Infinity` and `-Infinity` are accepted.

    Returns:
        The decoded document.

    Raises:
        `JSONDecodeError` if the bytes are not valid JSON, or whatever a hook
        raises.
    """
    var parsed = parse_document[
        ParseInt, ParseFloat, ParseConstant, ObjectHook
    ](data, strict=strict, allow_nan=allow_nan)
    var root = parsed.root
    return JSONValue(tape=ArcPointer(parsed^.take_tape()), idx=root)


struct JSONEncoder(Copyable, ImplicitlyCopyable, Movable):
    """A reusable `dumps` configuration, like CPython's `json.JSONEncoder`.

    Building one resolves the separators once, so encoding many documents with
    the same settings does not redo that work:

    ```mojo
    var encoder = JSONEncoder(indent=2, sort_keys=True)
    for doc in documents:
        print(encoder.encode(doc))
    ```
    """

    var options: EncodeOptions
    """The resolved settings every call uses."""

    def __init__(
        out self,
        *,
        var indent: Indent = Indent(None),
        var separators: Optional[Tuple[String, String]] = None,
        sort_keys: Bool = False,
        ensure_ascii: Bool = True,
        allow_nan: Bool = True,
    ):
        """Creates an encoder with the given settings.

        Args:
            indent: `None` for one line, an `Int` for that many spaces per
                level, or a string used verbatim per level.
            separators: An explicit `(item_separator, key_separator)` pair.
            sort_keys: Whether to emit object members in sorted key order.
            ensure_ascii: Whether to escape non-ASCII codepoints.
            allow_nan: Whether to emit `NaN` and `Infinity` rather than raise.
        """
        self.options = EncodeOptions(
            indent=indent^,
            separators=separators^,
            sort_keys=sort_keys,
            ensure_ascii=ensure_ascii,
            allow_nan=allow_nan,
        )

    def encode(self, value: JSONValue) raises -> String:
        """Serializes `value` to a string.

        Args:
            value: The value to serialize.

        Returns:
            The JSON text.

        Raises:
            If a non-finite float is encountered while `allow_nan` is False.
        """
        var out = String()
        write_value(out, value._tape[], value._idx, self.options)
        return out^

    def write_into(self, mut writer: Some[Writer], value: JSONValue) raises:
        """Serializes `value` straight into `writer`.

        Args:
            writer: The destination, such as a `FileHandle` or a `String`.
            value: The value to serialize.

        Raises:
            If a non-finite float is encountered while `allow_nan` is False.
        """
        write_value(writer, value._tape[], value._idx, self.options)


struct JSONDecoder(Copyable, ImplicitlyCopyable, Movable):
    """A reusable `loads` configuration, like CPython's `json.JSONDecoder`.

    Hooks are compile-time parameters rather than fields, because Mojo cannot
    store a function in a struct field the way Python stores a callable.
    """

    var strict: Bool
    """Whether raw control characters inside strings are rejected."""

    var allow_nan: Bool
    """Whether `NaN`, `Infinity` and `-Infinity` are accepted."""

    def __init__(out self, *, strict: Bool = True, allow_nan: Bool = True):
        """Creates a decoder with the given settings.

        Args:
            strict: Whether raw control characters inside strings are rejected.
            allow_nan: Whether the non-standard literals are accepted.
        """
        self.strict = strict
        self.allow_nan = allow_nan

    def decode[
        ParseInt: NumberHook = NoNumberHook,
        ParseFloat: NumberHook = NoNumberHook,
        ParseConstant: NumberHook = NoNumberHook,
        ObjectHook: ValueHook = NoValueHook,
    ](self, text: StringSlice) raises -> JSONValue:
        """Decodes a document with this decoder's settings.

        Parameters:
            ParseInt: Replaces the value integer literals decode to.
            ParseFloat: Replaces the value float literals decode to.
            ParseConstant: Replaces the value the constants decode to.
            ObjectHook: Replaces each decoded object, innermost first.

        Args:
            text: The document to decode.

        Returns:
            The decoded document.

        Raises:
            `JSONDecodeError` if the text is not valid JSON, or whatever a
            hook raises.
        """
        return loads[ParseInt, ParseFloat, ParseConstant, ObjectHook](
            text, strict=self.strict, allow_nan=self.allow_nan
        )

    def raw_decode[
        ParseInt: NumberHook = NoNumberHook,
        ParseFloat: NumberHook = NoNumberHook,
        ParseConstant: NumberHook = NoNumberHook,
        ObjectHook: ValueHook = NoValueHook,
    ](self, text: StringSlice, idx: Int = 0) raises -> Tuple[JSONValue, Int]:
        """Decodes one value starting at `idx` and reports where it ended.

        Use this to read documents concatenated in one buffer, or to leave
        trailing content for someone else to parse. Like CPython's
        `raw_decode`, it does not skip whitespace before the value — a value
        has to start exactly at `idx` — and the returned offset is the byte
        just past the value, with any trailing whitespace left unconsumed.

        Parameters:
            ParseInt: Replaces the value integer literals decode to.
            ParseFloat: Replaces the value float literals decode to.
            ParseConstant: Replaces the value the constants decode to.
            ObjectHook: Replaces each decoded object, innermost first.

        Args:
            text: The buffer to read from.
            idx: Where the value starts.

        Returns:
            The decoded value and the offset just past it.

        Raises:
            `JSONDecodeError` if no complete value starts at `idx`, or
            whatever a hook raises.
        """
        var parsed = parse_document[
            ParseInt, ParseFloat, ParseConstant, ObjectHook
        ](
            text.as_bytes(),
            strict=self.strict,
            allow_nan=self.allow_nan,
            start=idx,
            single_value=True,
        )
        var root = parsed.root
        var end = parsed.end
        return (JSONValue(tape=ArcPointer(parsed^.take_tape()), idx=root), end)
