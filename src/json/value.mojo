"""The public `JSONValue` type.

A `JSONValue` is a reference-counted handle on a `_Tape` plus the index of one
node inside it, so it is 12 bytes wide and copying one is a refcount bump.
That also gives Python's reference semantics for free: `doc["a"]` shares the
tape with `doc`, so mutating one mutates the other.
"""

from std.memory import ArcPointer, unsafe_memcmp

from .encoder import write_default
from .tape import (
    JSONType,
    _KIND_ARRAY,
    _KIND_BOOL,
    _KIND_FLOAT,
    _KIND_INT,
    _KIND_NULL,
    _KIND_OBJECT,
    _KIND_STRING,
    _Node,
    _Tape,
)


# ===-----------------------------------------------------------------------===#
# JSONValue
# ===-----------------------------------------------------------------------===#


struct JSONValue(
    Boolable,
    Copyable,
    Equatable,
    ImplicitlyCopyable,
    Movable,
    Writable,
):
    """A single JSON value: `null`, a bool, a number, a string, an array or an
    object.

    A `JSONValue` is a handle into a shared document, so copies are cheap and
    alias each other exactly like Python's `dict` and `list` do:

    ```mojo
    from json import loads

    var doc = loads('{"a": [1, 2]}')
    var a = doc["a"]        # shares storage with `doc`
    a.append(3)
    print(doc)              # {"a": [1, 2, 3]}
    ```
    """

    var _tape: ArcPointer[_Tape]
    """The document this value belongs to."""

    var _idx: UInt32
    """The index of this value's node inside the document."""

    # ===-------------------------------------------------------------------===#
    # Life cycle
    # ===-------------------------------------------------------------------===#

    def __init__(out self, *, tape: ArcPointer[_Tape], idx: UInt32):
        """Wraps an existing tape node. Internal.

        Args:
            tape: The document that owns the node.
            idx: The node index.
        """
        self._tape = tape
        self._idx = idx

    def __init__(out self):
        """Creates a JSON `null`."""
        self = Self._scalar(_Node.scalar(_KIND_NULL))

    @implicit
    def __init__(out self, value: NoneType):
        """Creates a JSON `null`.

        Args:
            value: Always `None`.
        """
        self = Self()

    @implicit
    def __init__(out self, value: Bool):
        """Creates a JSON boolean.

        Args:
            value: The boolean to store.
        """
        self = Self._scalar(_Node.scalar(_KIND_BOOL, UInt64(1) if value else UInt64(0)))

    @implicit
    def __init__(out self, value: Int):
        """Creates a JSON integer.

        Args:
            value: The integer to store.
        """
        self = Self._scalar(_Node.scalar(_KIND_INT, UInt64(Int64(value))))

    @implicit
    def __init__(out self, value: Float64):
        """Creates a JSON float.

        Args:
            value: The float to store.
        """
        self = Self._scalar(_Node.scalar(_KIND_FLOAT, value.to_bits[DType.uint64]()))

    @implicit
    def __init__(out self, value: StringSlice):
        """Creates a JSON string.

        Args:
            value: The text to store.
        """
        var tape = _Tape()
        var idx = tape.push_string(value.as_bytes())
        self._tape = ArcPointer(tape^)
        self._idx = idx

    @staticmethod
    def _scalar(node: _Node) -> Self:
        """Creates a one-node document holding `node`.

        Args:
            node: The node to store.

        Returns:
            A handle on the new document.
        """
        var tape = _Tape()
        var idx = tape.push(node)
        return Self(tape=ArcPointer(tape^), idx=idx)

    # ===-------------------------------------------------------------------===#
    # Introspection
    # ===-------------------------------------------------------------------===#

    @always_inline
    def _node(self) -> _Node:
        """Returns a copy of this value's node.

        Returns:
            The node.
        """
        return self._tape[].nodes[Int(self._idx)]

    @always_inline
    def _kind(self) -> UInt8:
        """Returns this value's raw discriminant.

        Returns:
            One of the `_KIND_*` constants.
        """
        return self._node().kind

    def type(self) -> JSONType:
        """Returns the JSON type of this value.

        Returns:
            The type tag.
        """
        return JSONType(self._kind())

    def is_null(self) -> Bool:
        """Reports whether this value is JSON `null`.

        Returns:
            True if the value is `null`.
        """
        return self._kind() == _KIND_NULL

    def is_bool(self) -> Bool:
        """Reports whether this value is a JSON boolean.

        Returns:
            True if the value is `true` or `false`.
        """
        return self._kind() == _KIND_BOOL

    def is_int(self) -> Bool:
        """Reports whether this value is a JSON integer.

        Returns:
            True if the value is an integer. Booleans are not integers here,
            unlike in Python, so that `dumps` round-trips them.
        """
        return self._kind() == _KIND_INT

    def is_float(self) -> Bool:
        """Reports whether this value is a JSON float.

        Returns:
            True if the value was written with a fraction or exponent.
        """
        return self._kind() == _KIND_FLOAT

    def is_number(self) -> Bool:
        """Reports whether this value is any JSON number.

        Returns:
            True for both integers and floats.
        """
        var k = self._kind()
        return k == _KIND_INT or k == _KIND_FLOAT

    def is_string(self) -> Bool:
        """Reports whether this value is a JSON string.

        Returns:
            True if the value is a string.
        """
        return self._kind() == _KIND_STRING

    def is_array(self) -> Bool:
        """Reports whether this value is a JSON array.

        Returns:
            True if the value is an array.
        """
        return self._kind() == _KIND_ARRAY

    def is_object(self) -> Bool:
        """Reports whether this value is a JSON object.

        Returns:
            True if the value is an object.
        """
        return self._kind() == _KIND_OBJECT

    def is_container(self) -> Bool:
        """Reports whether this value is an array or an object.

        Returns:
            True for arrays and objects.
        """
        var k = self._kind()
        return k == _KIND_ARRAY or k == _KIND_OBJECT

    # ===-------------------------------------------------------------------===#
    # Scalar accessors
    # ===-------------------------------------------------------------------===#

    def bool(self) raises -> Bool:
        """Returns the stored boolean.

        Returns:
            The boolean payload.

        Raises:
            If this value is not a JSON boolean.
        """
        var node = self._node()
        if node.kind != _KIND_BOOL:
            raise Error("JSON value is not a bool, it is ", self.type())
        return node.num != 0

    def int(self) raises -> Int:
        """Returns the stored integer.

        Returns:
            The integer payload.

        Raises:
            If this value is not a JSON integer.
        """
        var node = self._node()
        if node.kind != _KIND_INT:
            raise Error("JSON value is not an int, it is ", self.type())
        return Int(Int64(node.num))

    def float(self) raises -> Float64:
        """Returns the stored number as a float.

        Integers widen to floats, matching Python's `float(1) == 1.0`.

        Returns:
            The numeric payload as a float.

        Raises:
            If this value is not a JSON number.
        """
        var node = self._node()
        if node.kind == _KIND_FLOAT:
            return Float64(from_bits=node.num)
        if node.kind == _KIND_INT:
            return Float64(Int64(node.num))
        raise Error("JSON value is not a float, it is ", self.type())

    def string(self) raises -> String:
        """Returns a copy of the stored string.

        Returns:
            The decoded text.

        Raises:
            If this value is not a JSON string.
        """
        if self._kind() != _KIND_STRING:
            raise Error("JSON value is not a string, it is ", self.type())
        return String(unsafe_from_utf8=self._tape[].str_bytes(self._idx))

    # ===-------------------------------------------------------------------===#
    # Trait implementations
    # ===-------------------------------------------------------------------===#

    def __bool__(self) -> Bool:
        """Reports the Python truthiness of this value.

        `null`, `false`, `0`, `0.0`, `""`, `[]` and `{}` are falsey; everything
        else is truthy.

        Returns:
            The truthiness of the value.
        """
        var node = self._node()
        if node.kind == _KIND_NULL:
            return False
        if node.kind == _KIND_BOOL or node.kind == _KIND_INT:
            return node.num != 0
        if node.kind == _KIND_FLOAT:
            return Float64(from_bits=node.num) != 0.0
        # Strings, arrays and objects are falsey exactly when empty.
        return node.b != 0

    def __eq__(self, rhs: Self) -> Bool:
        """Compares two values structurally.

        Numbers compare across `int` and `float` the way Python does, so
        `1 == 1.0`, but a boolean never equals a number.

        Args:
            rhs: The value to compare against.

        Returns:
            True if both values are equal.
        """
        return _nodes_equal(self._tape[], self._idx, rhs._tape[], rhs._idx)

    def __ne__(self, rhs: Self) -> Bool:
        """Compares two values structurally for inequality.

        Args:
            rhs: The value to compare against.

        Returns:
            True if the values differ.
        """
        return not (self == rhs)

    def write_to(self, mut writer: Some[Writer]):
        """Writes this value as compact JSON.

        Args:
            writer: The writer to write to.
        """
        write_default(writer, self._tape[], self._idx)


# ===-----------------------------------------------------------------------===#
# Structural comparison
# ===-----------------------------------------------------------------------===#


def _bytes_equal(a: Span[UInt8, _], b: Span[UInt8, _]) -> Bool:
    """Compares two byte spans.

    Args:
        a: The first span.
        b: The second span.

    Returns:
        True if both spans have the same length and contents.
    """
    if len(a) != len(b):
        return False
    if len(a) == 0:
        return True
    return unsafe_memcmp(a.unsafe_ptr(), b.unsafe_ptr(), len(a)) == 0


def _nodes_equal(
    lhs: _Tape, li: UInt32, rhs: _Tape, ri: UInt32
) -> Bool:
    """Compares the subtrees rooted at `li` and `ri`.

    Args:
        lhs: The tape holding the left subtree.
        li: The index of the left root node.
        rhs: The tape holding the right subtree.
        ri: The index of the right root node.

    Returns:
        True if the two subtrees are structurally equal.
    """
    var a = lhs.nodes[Int(li)]
    var b = rhs.nodes[Int(ri)]

    # Numbers compare across int/float, everything else needs matching kinds.
    if a.kind != b.kind:
        var a_num = a.kind == _KIND_INT or a.kind == _KIND_FLOAT
        var b_num = b.kind == _KIND_INT or b.kind == _KIND_FLOAT
        if not (a_num and b_num):
            return False
        return _as_float(a) == _as_float(b)

    if a.kind == _KIND_NULL:
        return True
    if a.kind == _KIND_BOOL or a.kind == _KIND_INT:
        return a.num == b.num
    if a.kind == _KIND_FLOAT:
        return Float64(from_bits=a.num) == Float64(from_bits=b.num)
    if a.kind == _KIND_STRING:
        return _bytes_equal(lhs.str_bytes(li), rhs.str_bytes(ri))

    if a.b != b.b:
        return False

    if a.kind == _KIND_ARRAY:
        for i in range(Int(a.b)):
            if not _nodes_equal(
                lhs, lhs.kids[Int(a.a) + i], rhs, rhs.kids[Int(b.a) + i]
            ):
                return False
        return True

    # Objects are order-insensitive, like Python dicts.
    for i in range(Int(a.b)):
        var lk = lhs.kids[Int(a.a) + 2 * i]
        var lv = lhs.kids[Int(a.a) + 2 * i + 1]
        var found = False
        for j in range(Int(b.b)):
            var rk = rhs.kids[Int(b.a) + 2 * j]
            if _bytes_equal(lhs.str_bytes(lk), rhs.str_bytes(rk)):
                if not _nodes_equal(lhs, lv, rhs, rhs.kids[Int(b.a) + 2 * j + 1]):
                    return False
                found = True
                break
        if not found:
            return False
    return True


@always_inline
def _as_float(node: _Node) -> Float64:
    """Reads a numeric node as a float.

    Args:
        node: An `INT` or `FLOAT` node.

    Returns:
        The numeric payload as a float.
    """
    if node.kind == _KIND_FLOAT:
        return Float64(from_bits=node.num)
    return Float64(Int64(node.num))
