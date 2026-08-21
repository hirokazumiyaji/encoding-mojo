"""The module-level functions that mirror PyYAML's `safe_*` API."""

from std.memory import ArcPointer

from serde import Value
from serde.tape import _Tape

from .emitter import EmitOptions, emit_document
from .errors import YAMLError
from .parser import _Parser


def safe_load(text: StringSlice) raises -> Value:
    """Loads a single YAML document.

    Args:
        text: The document to load.

    Returns:
        The loaded document, or `null` if the stream holds nothing.

    Raises:
        `YAMLError` if the text is not valid YAML, or if it holds more than
        one document — the same rule PyYAML's `safe_load` applies.
    """
    var parser = _Parser(text.as_bytes())
    var roots = parser.parse_documents()
    if len(roots) > 1:
        raise YAMLError(
            String("expected a single document in the stream"), 1, 1
        )
    var root = roots[0]
    return Value(tape=ArcPointer(parser^.take_tape()), idx=root)


def safe_load_all(text: StringSlice) raises -> List[Value]:
    """Loads every document in a YAML stream.

    Args:
        text: The stream to load.

    Returns:
        One value per document, in order.

    Raises:
        `YAMLError` if the text is not valid YAML.
    """
    var parser = _Parser(text.as_bytes())
    var roots = parser.parse_documents()
    var tape = ArcPointer(parser^.take_tape())
    var out = List[Value](capacity=len(roots))
    for i in range(len(roots)):
        out.append(Value(tape=tape, idx=roots[i]))
    return out^


def safe_dump(
    value: Value,
    *,
    indent: Int = 2,
    default_flow_style: Bool = False,
    sort_keys: Bool = True,
    allow_unicode: Bool = False,
    explicit_start: Bool = False,
) raises -> String:
    """Serializes one value as a YAML document.

    The defaults are PyYAML's: block style, a two-space indent, keys sorted,
    and non-ASCII escaped.

    Args:
        value: The value to serialize.
        indent: Spaces added for each level of block nesting.
        default_flow_style: Whether to write the document on one line in flow
            style.
        sort_keys: Whether mapping members are emitted in sorted key order.
        allow_unicode: Whether non-ASCII codepoints may be written verbatim
            instead of escaped.
        explicit_start: Whether to precede the document with `---`.

    Returns:
        The YAML text, ending in a newline.

    Raises:
        `YAMLError` if the document nests deeper than `MAX_DEPTH`.
    """
    var opts = EmitOptions(
        indent=indent,
        default_flow_style=default_flow_style,
        sort_keys=sort_keys,
        allow_unicode=allow_unicode,
        explicit_start=explicit_start,
    )
    var out = String()
    emit_document(out, value._tape[], value._idx, opts)
    return out^


def safe_dump_all(
    values: List[Value],
    *,
    indent: Int = 2,
    default_flow_style: Bool = False,
    sort_keys: Bool = True,
    allow_unicode: Bool = False,
    explicit_start: Bool = False,
) raises -> String:
    """Serializes several values as one multi-document YAML stream.

    Args:
        values: The documents to serialize, in order.
        indent: Spaces added for each level of block nesting.
        default_flow_style: Whether to write each document in flow style.
        sort_keys: Whether mapping members are emitted in sorted key order.
        allow_unicode: Whether non-ASCII codepoints may be written verbatim.
        explicit_start: Whether to precede every document with `---`, rather
            than only the ones that need a separator.

    Returns:
        The YAML text, ending in a newline.

    Raises:
        `YAMLError` if a document nests deeper than `MAX_DEPTH`.
    """
    var out = String()
    for i in range(len(values)):
        var opts = EmitOptions(
            indent=indent,
            default_flow_style=default_flow_style,
            sort_keys=sort_keys,
            allow_unicode=allow_unicode,
            explicit_start=explicit_start or i > 0,
        )
        emit_document(out, values[i]._tape[], values[i]._idx, opts)
    return out^
