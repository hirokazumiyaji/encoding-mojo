"""The flat arena ("tape") that backs every parsed document.

A parsed document is *not* a tree of individually allocated nodes. Every value
lives in one `_Tape`: a `List[_Node]` for the values, a `List[UInt32]` for
container membership, and a `List[UInt8]` for decoded string bytes. A value is
then addressed by a single `UInt32` index into that tape.

This layout is what makes parsing fast: a document of `n` values costs `O(1)`
allocations instead of `O(n)`.
"""

from std.memory import unsafe_memcmp, unsafe_memcpy


# ===-----------------------------------------------------------------------===#
# Node kinds
# ===-----------------------------------------------------------------------===#

comptime _KIND_NULL: UInt8 = 0
comptime _KIND_BOOL: UInt8 = 1
comptime _KIND_INT: UInt8 = 2
comptime _KIND_FLOAT: UInt8 = 3
comptime _KIND_STRING: UInt8 = 4
comptime _KIND_ARRAY: UInt8 = 5
comptime _KIND_OBJECT: UInt8 = 6


@fieldwise_init
struct JSONType(Equatable, ImplicitlyCopyable, Movable, Writable):
    """The type tag of a `JSONValue`, mirroring the JSON data model.

    `INT` and `FLOAT` are distinct so that a document round-trips exactly:
    Python's `json` also gives back `1` for `"1"` and `1.0` for `"1.0"`.
    """

    var _kind: UInt8
    """The underlying discriminant."""

    comptime NULL = Self(_KIND_NULL)
    """The JSON `null` literal."""
    comptime BOOL = Self(_KIND_BOOL)
    """The JSON `true` and `false` literals."""
    comptime INT = Self(_KIND_INT)
    """A number written without a fraction or exponent part."""
    comptime FLOAT = Self(_KIND_FLOAT)
    """A number written with a fraction or exponent part."""
    comptime STRING = Self(_KIND_STRING)
    """A JSON string."""
    comptime ARRAY = Self(_KIND_ARRAY)
    """A JSON array."""
    comptime OBJECT = Self(_KIND_OBJECT)
    """A JSON object."""

    def __eq__(self, rhs: Self) -> Bool:
        """Compares two type tags.

        Args:
            rhs: The tag to compare against.

        Returns:
            True if both tags denote the same JSON type.
        """
        return self._kind == rhs._kind

    def __ne__(self, rhs: Self) -> Bool:
        """Compares two type tags for inequality.

        Args:
            rhs: The tag to compare against.

        Returns:
            True if the tags denote different JSON types.
        """
        return self._kind != rhs._kind

    def name(self) -> StaticString:
        """Returns the Python name of this type.

        Returns:
            One of `NoneType`, `bool`, `int`, `float`, `str`, `list`, `dict`.
        """
        if self._kind == _KIND_NULL:
            return "NoneType"
        if self._kind == _KIND_BOOL:
            return "bool"
        if self._kind == _KIND_INT:
            return "int"
        if self._kind == _KIND_FLOAT:
            return "float"
        if self._kind == _KIND_STRING:
            return "str"
        if self._kind == _KIND_ARRAY:
            return "list"
        return "dict"

    def write_to(self, mut writer: Some[Writer]):
        """Writes the Python name of this type.

        Args:
            writer: The writer to write to.
        """
        writer.write(self.name())


# ===-----------------------------------------------------------------------===#
# Tape
# ===-----------------------------------------------------------------------===#


@fieldwise_init
struct _Node(Copyable, ImplicitlyCopyable, Movable):
    """One value on the tape.

    The three integer fields are a hand-rolled union; which of them carry
    meaning depends on `kind`:

    | kind             | `a`              | `b`             | `cap`     | `num`      |
    |------------------|------------------|-----------------|-----------|------------|
    | NULL             | -                | -               | -         | -          |
    | BOOL             | -                | -               | -         | 0 or 1     |
    | INT              | -                | -               | -         | Int64 bits |
    | FLOAT            | -                | -               | -         | f64 bits   |
    | STRING           | offset in `buf`  | length in bytes | -         | -          |
    | ARRAY / OBJECT   | start in `kids`  | entry count     | slot cap  | -          |
    """

    var kind: UInt8
    """The node's discriminant, one of the `_KIND_*` constants."""
    var a: UInt32
    """Byte offset into the string buffer, or start index into `kids`."""
    var b: UInt32
    """String byte length, or number of entries in a container."""
    var cap: UInt32
    """Number of `kids` slots reserved for a container."""
    var num: UInt64
    """Raw bits of the numeric or boolean payload."""

    @staticmethod
    def scalar(kind: UInt8, num: UInt64 = 0) -> Self:
        """Builds a node with no tape-side storage.

        Args:
            kind: The node discriminant.
            num: The raw payload bits.

        Returns:
            The new node.
        """
        return Self(kind, 0, 0, 0, num)

    @staticmethod
    def string(offset: UInt32, length: UInt32) -> Self:
        """Builds a string node.

        Args:
            offset: Byte offset of the contents inside the tape buffer.
            length: Length of the contents in bytes.

        Returns:
            The new node.
        """
        return Self(_KIND_STRING, offset, length, 0, 0)

    @staticmethod
    def container(kind: UInt8, start: UInt32, count: UInt32, cap: UInt32) -> Self:
        """Builds an array or object node.

        Args:
            kind: Either `_KIND_ARRAY` or `_KIND_OBJECT`.
            start: Start index of the container's entries in `kids`.
            count: Number of elements (arrays) or members (objects).
            cap: Number of reserved slots in `kids`.

        Returns:
            The new node.
        """
        return Self(kind, start, count, cap, 0)


struct _Tape(Movable, Deinitable):
    """The flat arena that stores every node of one document."""

    var nodes: List[_Node]
    """Every value in the document, in creation order. Index 0 is the root."""

    var kids: List[UInt32]
    """Container membership. An array of `n` elements occupies `n` consecutive
    slots holding node indices; an object of `n` members occupies `2 * n` slots
    holding alternating key and value node indices."""

    var buf: List[UInt8]
    """Decoded UTF-8 bytes for every string node, concatenated."""

    def __init__(out self):
        """Creates an empty tape. No allocation happens until the first push."""
        self.nodes = []
        self.kids = []
        self.buf = []

    def __init__(out self, *, capacity_hint: Int):
        """Creates an empty tape sized for a document of roughly `capacity_hint`
        bytes.

        Args:
            capacity_hint: The length in bytes of the source document.
        """
        # Rules of thumb from typical documents: one node per ~16 source bytes
        # and string payloads a little under half the source size. Overshooting
        # costs memory, undershooting costs a `realloc`, so these are
        # deliberately conservative.
        self.nodes = List[_Node](capacity=max(8, capacity_hint // 16))
        self.kids = List[UInt32](capacity=max(8, capacity_hint // 24))
        self.buf = List[UInt8](capacity=max(8, capacity_hint // 4))

    @always_inline
    def push(mut self, node: _Node) -> UInt32:
        """Appends a node and returns its index.

        Args:
            node: The node to append.

        Returns:
            The index of the freshly appended node.
        """
        var idx = UInt32(len(self.nodes))
        self.nodes.append(node)
        return idx

    def push_bytes(mut self, bytes: Span[UInt8, _]) -> UInt32:
        """Copies `bytes` into the string buffer and returns their offset.

        Args:
            bytes: The UTF-8 bytes to store.

        Returns:
            The byte offset of the copy inside the tape buffer.
        """
        var offset = UInt32(len(self.buf))
        var n = len(bytes)
        if n:
            self.buf.resize(unsafe_uninit_length=len(self.buf) + n)
            unsafe_memcpy(
                dest=self.buf.unsafe_ptr().unsafe_offset(Int(offset)),
                src=bytes.unsafe_ptr(),
                count=n,
            )
        return offset

    def push_string(mut self, bytes: Span[UInt8, _]) -> UInt32:
        """Appends a string node whose contents are a copy of `bytes`.

        Args:
            bytes: The UTF-8 bytes of the string.

        Returns:
            The index of the new node.
        """
        var offset = self.push_bytes(bytes)
        return self.push(_Node.string(offset, UInt32(len(bytes))))

    @always_inline
    def str_bytes(self, idx: UInt32) -> Span[UInt8, origin_of(self.buf)]:
        """Returns the stored bytes of the string node at `idx`.

        Args:
            idx: The index of a `_KIND_STRING` node.

        Returns:
            A view over the node's bytes inside the tape buffer.
        """
        var node = self.nodes[Int(idx)]
        return Span(self.buf)[Int(node.a) : Int(node.a) + Int(node.b)]

    # ===-------------------------------------------------------------------===#
    # Containers
    # ===-------------------------------------------------------------------===#

    @always_inline
    def slots_per_entry(self, idx: UInt32) -> Int:
        """Returns how many `kids` slots one entry of a container occupies.

        Args:
            idx: The index of a container node.

        Returns:
            2 for objects (key and value), 1 for arrays.
        """
        return 2 if self.nodes[Int(idx)].kind == _KIND_OBJECT else 1

    def reserve_slots(mut self, idx: UInt32, needed: Int):
        """Makes sure the container at `idx` owns at least `needed` slots.

        Containers behave like vectors inside the shared `kids` array: they
        grow geometrically, extending in place when they already own the tail
        of the array and relocating to the end otherwise. Relocating strands
        the old slots, which is why the parser sizes containers exactly and
        only interactive building ever pays for growth.

        Args:
            idx: The index of a container node.
            needed: The number of slots the container must own.
        """
        var node = self.nodes[Int(idx)]
        if Int(node.cap) >= needed:
            return

        var new_cap = max(4, Int(node.cap) * 2)
        if new_cap < needed:
            new_cap = needed
        var used = Int(node.b) * self.slots_per_entry(idx)
        var end = len(self.kids)

        if Int(node.a) + Int(node.cap) == end:
            # The container already ends at the tail of `kids`; just extend it.
            self.kids.resize(end + new_cap - Int(node.cap), 0)
        else:
            self.kids.resize(end + new_cap, 0)
            for i in range(used):
                self.kids[end + i] = self.kids[Int(node.a) + i]
            node.a = UInt32(end)
        node.cap = UInt32(new_cap)
        self.nodes[Int(idx)] = node

    def new_container(mut self, kind: UInt8) -> UInt32:
        """Appends an empty array or object node.

        Args:
            kind: Either `_KIND_ARRAY` or `_KIND_OBJECT`.

        Returns:
            The index of the new node.
        """
        return self.push(_Node.container(kind, 0, 0, 0))

    def array_push(mut self, idx: UInt32, child: UInt32):
        """Appends `child` to the array at `idx`.

        Args:
            idx: The index of an array node.
            child: The index of the value to append.
        """
        var count = Int(self.nodes[Int(idx)].b)
        self.reserve_slots(idx, count + 1)
        var node = self.nodes[Int(idx)]
        self.kids[Int(node.a) + count] = child
        node.b = UInt32(count + 1)
        self.nodes[Int(idx)] = node

    def object_push(mut self, idx: UInt32, key: UInt32, value: UInt32):
        """Appends the member `key: value` to the object at `idx`.

        The key is not checked for duplicates; callers that need CPython's
        "last one wins" behaviour go through `find_member` first.

        Args:
            idx: The index of an object node.
            key: The index of the member's key, which must be a string node.
            value: The index of the member's value.
        """
        var count = Int(self.nodes[Int(idx)].b)
        self.reserve_slots(idx, 2 * (count + 1))
        var node = self.nodes[Int(idx)]
        self.kids[Int(node.a) + 2 * count] = key
        self.kids[Int(node.a) + 2 * count + 1] = value
        node.b = UInt32(count + 1)
        self.nodes[Int(idx)] = node

    def find_member(self, idx: UInt32, key: Span[UInt8, _]) -> Int:
        """Returns the position of the member named `key`, or -1.

        Args:
            idx: The index of an object node.
            key: The key to look for.

        Returns:
            The zero-based member position, or -1 when the key is absent.
        """
        var node = self.nodes[Int(idx)]
        for i in range(Int(node.b)):
            if _bytes_equal(self.str_bytes(self.kids[Int(node.a) + 2 * i]), key):
                return i
        return -1

    def remove_entry(mut self, idx: UInt32, pos: Int):
        """Removes the entry at member/element position `pos`.

        Args:
            idx: The index of a container node.
            pos: The zero-based position to remove.
        """
        var node = self.nodes[Int(idx)]
        var width = self.slots_per_entry(idx)
        var used = Int(node.b) * width
        for i in range((pos + 1) * width, used):
            self.kids[Int(node.a) + i - width] = self.kids[Int(node.a) + i]
        node.b -= 1
        self.nodes[Int(idx)] = node

    def graft(mut self, src: _Tape, src_idx: UInt32) -> UInt32:
        """Deep-copies the subtree at `src_idx` of `src` into this tape.

        Args:
            src: The tape to copy from. Must not be this tape.
            src_idx: The root of the subtree to copy.

        Returns:
            The index of the copied root in this tape.
        """
        var node = src.nodes[Int(src_idx)]

        if node.kind == _KIND_STRING:
            return self.push_string(src.str_bytes(src_idx))

        if node.kind != _KIND_ARRAY and node.kind != _KIND_OBJECT:
            return self.push(node)

        # Children have to be materialised before the parent, because the
        # parent's slot range must be contiguous and children may themselves
        # append to `kids`.
        var width = 2 if node.kind == _KIND_OBJECT else 1
        var count = Int(node.b)
        var copied = List[UInt32](capacity=count * width)
        for i in range(count):
            if width == 2:
                copied.append(
                    self.push_string(src.str_bytes(src.kids[Int(node.a) + 2 * i]))
                )
            copied.append(self.graft(src, src.kids[Int(node.a) + width * i + width - 1]))

        var start = UInt32(len(self.kids))
        self.kids.extend(copied^)
        return self.push(
            _Node.container(node.kind, start, UInt32(count), UInt32(count * width))
        )


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
