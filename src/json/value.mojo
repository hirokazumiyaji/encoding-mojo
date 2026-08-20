"""The public `JSONValue` type.

A `JSONValue` is a reference-counted handle on a `_Tape` plus the index of one
node inside it, so it is 12 bytes wide and copying one is a refcount bump.
That also gives Python's reference semantics for free: `doc["a"]` shares the
tape with `doc`, so mutating one mutates the other.
"""

from std.memory import ArcPointer

from .encoder import write_default
from .tape import (
    JSONType,
    MAX_DEPTH,
    _KIND_ARRAY,
    _KIND_BOOL,
    _KIND_FLOAT,
    _KIND_INT,
    _KIND_NULL,
    _KIND_OBJECT,
    _KIND_STRING,
    _Node,
    _Tape,
    _bytes_equal,
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
    SizedRaising,
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
    def __init__(out self, value: NoneType._mlir_type):
        """Creates a JSON `null` from the `None` literal.

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
        self = Self._scalar(
            _Node.scalar(_KIND_BOOL, UInt64(1) if value else UInt64(0))
        )

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
        self = Self._scalar(
            _Node.scalar(_KIND_FLOAT, value.to_bits[DType.uint64]())
        )

    @implicit
    def __init__(out self, value: StringLiteral):
        """Creates a JSON string from a literal.

        Args:
            value: The text to store.
        """
        self = Self(StringSlice(value))

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
    # Containers
    # ===-------------------------------------------------------------------===#

    @staticmethod
    def array() -> Self:
        """Creates an empty JSON array.

        Returns:
            A new empty array.
        """
        var tape = _Tape()
        var idx = tape.new_container(_KIND_ARRAY)
        return Self(tape=ArcPointer(tape^), idx=idx)

    @staticmethod
    def object() -> Self:
        """Creates an empty JSON object.

        Returns:
            A new empty object.
        """
        var tape = _Tape()
        var idx = tape.new_container(_KIND_OBJECT)
        return Self(tape=ArcPointer(tape^), idx=idx)

    def __len__(self) raises -> Int:
        """Returns the Python `len()` of this value.

        Returns:
            The number of elements of an array, members of an object, or
            codepoints of a string.

        Raises:
            If this value is a scalar, mirroring Python's `TypeError`.
        """
        var node = self._node()
        if node.kind == _KIND_ARRAY or node.kind == _KIND_OBJECT:
            return Int(node.b)
        if node.kind == _KIND_STRING:
            return _count_codepoints(self._tape[].str_bytes(self._idx))
        raise Error("object of type '", self.type(), "' has no len()")

    def _adopt(self, value: Self) raises -> UInt32:
        """Returns an index in *this* document for `value`.

        Values already living in this document are aliased, so inserting one
        gives Python's reference semantics. Values from another document are
        deep-copied, because a `JSONValue` cannot span two tapes.

        Args:
            value: The value to place into this document.

        Returns:
            The node index to store.

        Raises:
            If copying the value would recurse past `MAX_DEPTH`.
        """
        if self._tape.__is__(value._tape):
            return value._idx
        return self._tape[].graft(value._tape[], value._idx)

    def _new_scalar(self, node: _Node) raises -> UInt32:
        """Appends a scalar node to this value's own document.

        Args:
            node: The node to append.

        Returns:
            The index of the new node.

        Raises:
            Never; the signature matches its callers.
        """
        return self._tape[].push(node)

    def append(self, value: Int) raises:
        """Appends an integer to this array.

        Args:
            value: The integer to append.

        Raises:
            If this value is not an array.
        """
        self._expect(_KIND_ARRAY, "append")
        var child = self._new_scalar(
            _Node.scalar(_KIND_INT, UInt64(Int64(value)))
        )
        self._tape[].array_push(self._idx, child)

    def append(self, value: Float64) raises:
        """Appends a float to this array.

        Args:
            value: The float to append.

        Raises:
            If this value is not an array.
        """
        self._expect(_KIND_ARRAY, "append")
        var child = self._new_scalar(
            _Node.scalar(_KIND_FLOAT, value.to_bits[DType.uint64]())
        )
        self._tape[].array_push(self._idx, child)

    def append(self, value: Bool) raises:
        """Appends a boolean to this array.

        Args:
            value: The boolean to append.

        Raises:
            If this value is not an array.
        """
        self._expect(_KIND_ARRAY, "append")
        var child = self._new_scalar(
            _Node.scalar(_KIND_BOOL, UInt64(1) if value else UInt64(0))
        )
        self._tape[].array_push(self._idx, child)

    def append(self, value: NoneType) raises:
        """Appends `null` to this array.

        Args:
            value: Always `None`.

        Raises:
            If this value is not an array.
        """
        self._expect(_KIND_ARRAY, "append")
        var child = self._new_scalar(_Node.scalar(_KIND_NULL))
        self._tape[].array_push(self._idx, child)

    def append(self, value: NoneType._mlir_type) raises:
        """Appends `null` to this array.

        This exact overload keeps `arr.append(None)` unambiguous: without it
        the literal could convert either to `NoneType` or to a `JSONValue`.

        Args:
            value: Always `None`.

        Raises:
            If this value is not an array.
        """
        self.append(NoneType(value))

    def append(self, value: StringSlice) raises:
        """Appends a string to this array.

        Args:
            value: The text to append.

        Raises:
            If this value is not an array.
        """
        self._expect(_KIND_ARRAY, "append")
        var child = self._tape[].push_string(value.as_bytes())
        self._tape[].array_push(self._idx, child)

    def append(self, value: StringLiteral) raises:
        """Appends a string literal to this array.

        Args:
            value: The text to append.

        Raises:
            If this value is not an array.
        """
        self.append(StringSlice(value))

    def append(self, var value: Self) raises:
        """Appends `value` to this array.

        Args:
            value: The value to append. Native Mojo values convert implicitly,
                so `arr.append(1)` and `arr.append("x")` both work.

        Raises:
            If this value is not an array.
        """
        self._expect(_KIND_ARRAY, "append")
        var child = self._adopt(value)
        self._tape[].array_push(self._idx, child)

    def extend(self, values: Self) raises:
        """Appends every element of the array `values` to this array.

        Args:
            values: The array whose elements are appended.

        Raises:
            If either value is not an array.
        """
        self._expect(_KIND_ARRAY, "extend")
        if not values.is_array():
            raise Error("can only extend a JSON array with another array")
        for i in range(len(values)):
            self.append(values[i])

    def pop(self) raises -> Self:
        """Removes and returns the last element of this array.

        Returns:
            The removed element.

        Raises:
            If this value is not an array, or the array is empty.
        """
        return self.pop(-1)

    def pop(self, index: Int) raises -> Self:
        """Removes and returns the element at `index`.

        Args:
            index: The position to remove, negative counting from the end.

        Returns:
            The removed element.

        Raises:
            If this value is not an array, or the index is out of range.
        """
        self._expect(_KIND_ARRAY, "pop")
        var pos = self._checked_index(index)
        var removed = self._tape[].kids[Int(self._node().a) + pos]
        self._tape[].remove_entry(self._idx, pos)
        return Self(tape=self._tape, idx=removed)

    def pop(self, key: StringSlice) raises -> Self:
        """Removes the member named `key` and returns its value.

        Args:
            key: The member to remove.

        Returns:
            The removed value.

        Raises:
            If this value is not an object, or the key is absent.
        """
        self._expect(_KIND_OBJECT, "pop")
        var pos = self._tape[].find_member(self._idx, key.as_bytes())
        if pos < 0:
            raise Error("KeyError: '", key, "'")
        var removed = self._tape[].kids[Int(self._node().a) + 2 * pos + 1]
        self._tape[].remove_entry(self._idx, pos)
        return Self(tape=self._tape, idx=removed)

    def clear(self) raises:
        """Removes every element or member from this container.

        Raises:
            If this value is not an array or an object.
        """
        if not self.is_container():
            raise Error("'", self.type(), "' object has no attribute 'clear'")
        var node = self._node()
        node.b = 0
        node.num = 0  # Any hash index described by `num` is now stale.
        self._tape[].nodes[Int(self._idx)] = node

    def keys(self) raises -> List[String]:
        """Returns this object's keys in insertion order.

        Returns:
            The member names.

        Raises:
            If this value is not an object.
        """
        self._expect(_KIND_OBJECT, "keys")
        var node = self._node()
        var out = List[String](capacity=Int(node.b))
        for i in range(Int(node.b)):
            out.append(
                String(
                    unsafe_from_utf8=self._tape[].str_bytes(
                        self._tape[].kids[Int(node.a) + 2 * i]
                    )
                )
            )
        return out^

    def values(self) raises -> List[Self]:
        """Returns this object's values in insertion order.

        Returns:
            The member values.

        Raises:
            If this value is not an object.
        """
        self._expect(_KIND_OBJECT, "values")
        var node = self._node()
        var out = List[Self](capacity=Int(node.b))
        for i in range(Int(node.b)):
            out.append(
                Self(
                    tape=self._tape,
                    idx=self._tape[].kids[Int(node.a) + 2 * i + 1],
                )
            )
        return out^

    def items(self) raises -> List[Tuple[String, Self]]:
        """Returns this object's members in insertion order.

        Returns:
            The `(key, value)` pairs.

        Raises:
            If this value is not an object.
        """
        self._expect(_KIND_OBJECT, "items")
        var node = self._node()
        var out = List[Tuple[String, Self]](capacity=Int(node.b))
        for i in range(Int(node.b)):
            out.append(
                (
                    String(
                        unsafe_from_utf8=self._tape[].str_bytes(
                            self._tape[].kids[Int(node.a) + 2 * i]
                        )
                    ),
                    Self(
                        tape=self._tape,
                        idx=self._tape[].kids[Int(node.a) + 2 * i + 1],
                    ),
                )
            )
        return out^

    # Not a conformance to `Iterable`: that trait's `__iter__` cannot raise,
    # and iterating a scalar has to fail the way Python's `TypeError` does.
    # A `for` loop only needs the method to exist.
    def __iter__(self) raises -> _JSONIter:
        """Iterates this container, following Python's rules.

        Arrays yield their elements and objects yield their keys, as JSON
        string values.

        Returns:
            An iterator over the container.

        Raises:
            If this value is not an array or an object.
        """
        if not self.is_container():
            raise Error("'", self.type(), "' object is not iterable")
        return _JSONIter(self, 0, Int(self._node().b))

    def update(self, other: Self) raises:
        """Copies every member of `other` into this object.

        An existing key keeps its position and takes the new value, exactly
        like Python's `dict.update`.

        Args:
            other: The object to copy members from.

        Raises:
            If either value is not an object.
        """
        self._expect(_KIND_OBJECT, "update")
        if not other.is_object():
            raise Error("can only update a JSON object with another object")
        for pair in other.items():
            self[pair[0]] = pair[1]

    def setdefault(self, key: StringSlice, var default: Self) raises -> Self:
        """Returns the member named `key`, inserting `default` if it is absent.

        Args:
            key: The member name.
            default: The value to insert when the key is missing.

        Returns:
            A handle on the member's value, which is live: mutating it mutates
            this object.

        Raises:
            If this value is not an object.
        """
        self._expect(_KIND_OBJECT, "setdefault")
        var pos = self._tape[].find_member(self._idx, key.as_bytes())
        if pos >= 0:
            return Self(
                tape=self._tape,
                idx=self._tape[].kids[Int(self._node().a) + 2 * pos + 1],
            )
        self[key] = default^
        return self[key]

    def get(self, key: StringSlice) -> Optional[Self]:
        """Looks up a member without raising, like Python's `dict.get`.

        Args:
            key: The member name.

        Returns:
            The member's value, or `None` if this value is not an object or
            has no such member.
        """
        if not self.is_object():
            return None
        var pos = self._tape[].find_member(self._idx, key.as_bytes())
        if pos < 0:
            return None
        return Self(
            tape=self._tape,
            idx=self._tape[].kids[Int(self._node().a) + 2 * pos + 1],
        )

    def __contains__(self, key: StringSlice) -> Bool:
        """Reports whether this object has a member named `key`.

        Args:
            key: The member name.

        Returns:
            True if the member exists.
        """
        if not self.is_object():
            return False
        return self._tape[].find_member(self._idx, key.as_bytes()) >= 0

    def __getitem__(self, index: Int) raises -> Self:
        """Returns the array element at `index`.

        Args:
            index: The position, negative counting from the end.

        Returns:
            A handle on the element.

        Raises:
            If this value is not an array, or the index is out of range.
        """
        if not self.is_array():
            raise Error("'", self.type(), "' object is not subscriptable")
        var pos = self._checked_index(index)
        return Self(
            tape=self._tape, idx=self._tape[].kids[Int(self._node().a) + pos]
        )

    def __getitem__(self, key: StringSlice) raises -> Self:
        """Returns the object member named `key`.

        Args:
            key: The member name.

        Returns:
            A handle on the member's value.

        Raises:
            If this value is not an object, or the key is absent.
        """
        if not self.is_object():
            raise Error("'", self.type(), "' object is not subscriptable")
        var pos = self._tape[].find_member(self._idx, key.as_bytes())
        if pos < 0:
            raise Error("KeyError: '", key, "'")
        return Self(
            tape=self._tape,
            idx=self._tape[].kids[Int(self._node().a) + 2 * pos + 1],
        )

    def __setitem__(self, index: Int, var value: Self) raises:
        """Replaces the array element at `index`.

        Args:
            index: The position, negative counting from the end.
            value: The replacement value.

        Raises:
            If this value is not an array, or the index is out of range.
        """
        if not self.is_array():
            raise Error(
                "'", self.type(), "' object does not support item assignment"
            )
        var pos = self._checked_index(index)
        var child = self._adopt(value)
        self._tape[].kids[Int(self._node().a) + pos] = child

    def __setitem__(self, key: StringSlice, var value: Self) raises:
        """Sets the object member named `key`.

        An existing member keeps its position and gets the new value, exactly
        like assigning into a Python dict.

        Args:
            key: The member name.
            value: The value to store.

        Raises:
            If this value is not an object.
        """
        if not self.is_object():
            raise Error(
                "'", self.type(), "' object does not support item assignment"
            )
        var child = self._adopt(value)
        var pos = self._tape[].find_member(self._idx, key.as_bytes())
        if pos >= 0:
            self._tape[].kids[Int(self._node().a) + 2 * pos + 1] = child
            return
        var key_idx = self._tape[].push_string(key.as_bytes())
        self._tape[].object_push(self._idx, key_idx, child)

    def _expect(self, kind: UInt8, method: StaticString) raises:
        """Raises unless this value has the given kind.

        Args:
            kind: The required node kind.
            method: The name of the calling method, used in the message.

        Raises:
            If this value has a different kind.
        """
        if self._kind() != kind:
            raise Error(
                "'", self.type(), "' object has no attribute '", method, "'"
            )

    def _checked_index(self, index: Int) raises -> Int:
        """Resolves a possibly negative index against this container's length.

        Args:
            index: The index to resolve.

        Returns:
            The non-negative position.

        Raises:
            If the index is out of range.
        """
        var count = Int(self._node().b)
        var pos = index + count if index < 0 else index
        if pos < 0 or pos >= count:
            raise Error("list index out of range")
        return pos

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


def _nodes_equal(
    lhs: _Tape, li: UInt32, rhs: _Tape, ri: UInt32, depth: Int = 0
) -> Bool:
    """Compares the subtrees rooted at `li` and `ri`.

    Args:
        lhs: The tape holding the left subtree.
        li: The index of the left root node.
        rhs: The tape holding the right subtree.
        ri: The index of the right root node.
        depth: The current recursion depth.

    Returns:
        True if the two subtrees are structurally equal. Subtrees nesting
        deeper than `MAX_DEPTH` — which is what a cycle looks like from here —
        are reported as unequal rather than compared forever.
    """
    if depth > MAX_DEPTH:
        return False
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
                lhs,
                lhs.kids[Int(a.a) + i],
                rhs,
                rhs.kids[Int(b.a) + i],
                depth + 1,
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
                if not _nodes_equal(
                    lhs, lv, rhs, rhs.kids[Int(b.a) + 2 * j + 1], depth + 1
                ):
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


def _count_codepoints(bytes: Span[UInt8, _]) -> Int:
    """Counts the Unicode codepoints in valid UTF-8.

    Args:
        bytes: The UTF-8 bytes to measure.

    Returns:
        The number of codepoints, matching Python's `len()` on a `str`.
    """
    var count = 0
    for i in range(len(bytes)):
        # Continuation bytes are 0b10xxxxxx; every other byte starts a
        # codepoint.
        if (bytes[i] & 0xC0) != 0x80:
            count += 1
    return count


struct _JSONIter(Copyable, ImplicitlyCopyable, Iterator, Movable):
    """Iterates an array's elements or an object's keys."""

    comptime Element = JSONValue
    """What `__next__` yields."""

    var _value: JSONValue
    """The container being iterated. Holding it keeps the document alive."""

    var _index: Int
    """The next position to yield."""

    var _length: Int
    """The container's length, captured when iteration started."""

    def __init__(out self, value: JSONValue, index: Int, length: Int):
        """Starts an iteration.

        Args:
            value: The container to iterate.
            index: The position to start from.
            length: The number of positions to yield.
        """
        self._value = value
        self._index = index
        self._length = length

    def __next__(mut self) raises StopIteration -> JSONValue:
        """Yields the next element or key.

        Returns:
            An array element, or an object key as a JSON string.

        Raises:
            StopIteration when the container is exhausted.
        """
        if self._index >= self._length:
            raise StopIteration()
        var node = self._value._node()
        var stride = 2 if node.kind == _KIND_OBJECT else 1
        var child = self._value._tape[].kids[Int(node.a) + stride * self._index]
        self._index += 1
        return JSONValue(tape=self._value._tape, idx=child)

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        """Reports how many elements remain.

        Returns:
            The exact number of remaining elements, as both bounds.
        """
        var remaining = self._length - self._index
        return (remaining, Optional(remaining))
