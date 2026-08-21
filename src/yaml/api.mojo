"""The module-level functions that mirror PyYAML's `safe_*` API."""

from std.memory import ArcPointer

from serde import Value
from serde.tape import _Tape

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
