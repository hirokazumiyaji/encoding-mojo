"""The module-level functions that mirror CPython's `json` package."""

from std.memory import ArcPointer

from .decoder import parse_document
from .encoder import EncodeOptions, Indent, write_value
from .value import JSONValue


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


def loads(
    text: StringSlice, *, strict: Bool = True, allow_nan: Bool = True
) raises -> JSONValue:
    """Decodes a JSON document.

    Args:
        text: The document to decode.
        strict: Whether raw control characters inside strings are rejected,
            as CPython's `strict=True` does.
        allow_nan: Whether the non-standard `NaN`, `Infinity` and `-Infinity`
            literals are accepted, as CPython does by default.

    Returns:
        The decoded document.

    Raises:
        `JSONDecodeError` if the text is not valid JSON.
    """
    var parsed = parse_document(
        text.as_bytes(), strict=strict, allow_nan=allow_nan
    )
    var root = parsed.root
    return JSONValue(tape=ArcPointer(parsed^.take_tape()), idx=root)
