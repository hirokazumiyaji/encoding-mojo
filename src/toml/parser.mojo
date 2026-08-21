"""The TOML parser.

TOML is line-oriented and unambiguous, so the parser is a loop over statements
rather than a grammar walk: each line is either a table header or a key/value
pair. Only values recurse, and `_parse_value` handles arrays and inline tables
inside itself so that recursion is a single function calling itself — a longer
cycle makes the Mojo elaborator hang.

Values land in the same `_Tape` the json and yaml packages use, so a document
loaded here can be dumped as JSON or YAML without conversion.
"""

from std.collections import Set

from serde.tape import (
    MAX_DEPTH,
    _KIND_ARRAY,
    _KIND_BOOL,
    _KIND_FLOAT,
    _KIND_INT,
    _KIND_OBJECT,
    _KIND_STRING,
    _Node,
    _Tape,
)

from .errors import TOMLDecodeError

comptime _TAB: UInt8 = 0x09
comptime _NEWLINE: UInt8 = 0x0A
comptime _RETURN: UInt8 = 0x0D
comptime _SPACE: UInt8 = 0x20
comptime _HASH: UInt8 = 0x23
comptime _SQUOTE: UInt8 = 0x27
comptime _DQUOTE: UInt8 = 0x22
comptime _PLUS: UInt8 = 0x2B
comptime _COMMA: UInt8 = 0x2C
comptime _MINUS: UInt8 = 0x2D
comptime _DOT: UInt8 = 0x2E
comptime _COLON: UInt8 = 0x3A
comptime _EQUALS: UInt8 = 0x3D
comptime _LBRACKET: UInt8 = 0x5B
comptime _RBRACKET: UInt8 = 0x5D
comptime _BACKSLASH: UInt8 = 0x5C
comptime _LBRACE: UInt8 = 0x7B
comptime _RBRACE: UInt8 = 0x7D
comptime _UNDERSCORE: UInt8 = 0x5F

comptime _HEX_LOWER = StaticString("0123456789abcdef")

comptime _DIGITS = StaticString("0123456789")

comptime _ELEMENT = "e"
"""Tags a registry component that names one element of an array of tables.

Two `[[a]]` blocks each own their members, so the registry has to tell them
apart.
"""

comptime _KEY = "k"
"""Tags a registry component that names a key as the document wrote it.

A key may hold any character at all, including the `e` an element marker
starts with, so every component carries a tag saying which of the two it is.
"""


def _component(tag: StringSlice, text: StringSlice) -> String:
    """Builds one registry path component.

    Args:
        tag: `_KEY` or `_ELEMENT`.
        text: The key, or the element's index.

    Returns:
        The tagged component.
    """
    return String(tag, text)


def _append_int(mut out: String, value: Int):
    """Appends a small non-negative number without building a `String` for it.

    Args:
        out: The buffer to append to.
        value: The number to append.
    """
    if value >= 100:
        out += String(value)
        return
    if value >= 10:
        var hi = value // 10
        var lo = value % 10
        out += _DIGITS[byte = hi : hi + 1]
        out += _DIGITS[byte = lo : lo + 1]
        return
    out += _DIGITS[byte = value : value + 1]


def _append_encoded(mut out: String, component: StringSlice):
    """Appends one already-tagged component to a registry path.

    A key may hold any byte, a NUL included, so no separator is safe to join
    on. Writing each component's byte length in front of it is.

    Args:
        out: The path being built.
        component: The component to append.
    """
    _append_int(out, component.byte_length())
    out += ":"
    out += component


def _append_tagged(mut out: String, tag: StringSlice, text: StringSlice):
    """Tags a key or an element index and appends it to a registry path.

    Args:
        out: The path being built.
        tag: `_KEY` or `_ELEMENT`.
        text: The key, or the element's index.
    """
    _append_int(out, tag.byte_length() + text.byte_length())
    out += ":"
    out += tag
    out += text


@always_inline
def _is_digit(b: UInt8) -> Bool:
    """Reports whether `b` is an ASCII digit.

    Args:
        b: The byte to test.

    Returns:
        True for `0` through `9`.
    """
    return b >= 0x30 and b <= 0x39


@always_inline
def _is_bare_key_byte(b: UInt8) -> Bool:
    """Reports whether `b` may appear in an unquoted key.

    Args:
        b: The byte to test.

    Returns:
        True for letters, digits, `_` and `-`.
    """
    return (
        _is_digit(b)
        or (b >= 0x41 and b <= 0x5A)
        or (b >= 0x61 and b <= 0x7A)
        or b == _UNDERSCORE
        or b == _MINUS
    )


def _join(path: List[String]) -> String:
    """Renders a key path as one registry key.

    Args:
        path: The parts of the path.

    Returns:
        The parts joined by the registry separator.
    """
    var out = String()
    for i in range(len(path)):
        _append_encoded(out, path[i])
    return out^


@always_inline
def _is_control(b: UInt8) -> Bool:
    """Reports whether a byte is one TOML never allows raw.

    Args:
        b: The byte to test.

    Returns:
        True for `U+0000`-`U+001F` and `U+007F`, tab excepted. A line ending
        is included, because the contexts that allow one test for it first.
    """
    return (b < 0x20 and b != _TAB) or b == 0x7F


def _quote_byte(b: UInt8) -> String:
    """Renders a control byte the way Python's `repr` writes it.

    Args:
        b: The byte to render.

    Returns:
        The byte quoted, such as `'\\x01'` or `'\\r'`.
    """
    if b == _TAB:
        return String("'\\t'")
    if b == _NEWLINE:
        return String("'\\n'")
    if b == _RETURN:
        return String("'\\r'")
    var hi = Int(b >> 4)
    var lo = Int(b & 0xF)
    return String(
        "'\\x",
        _HEX_LOWER[byte = hi : hi + 1],
        _HEX_LOWER[byte = lo : lo + 1],
        "'",
    )


def _quote_one(key: StringSlice) -> String:
    """Renders one key the way `tomllib` names it in an error.

    Args:
        key: The key to render.

    Returns:
        The key in single quotes.
    """
    return String("'", key, "'")


def _quote_path(path: List[String]) -> String:
    """Renders a key path the way `tomllib` names it in an error.

    Args:
        path: The parts of the path.

    Returns:
        A Python tuple literal such as `('a', 'b')`.
    """
    var out = String("(")
    for i in range(len(path)):
        if i:
            out += ", "
        out += String("'", path[i], "'")
    if len(path) == 1:
        out += ","
    out += ")"
    return out^


struct _Parser(Movable):
    """One load of one byte stream."""

    var src: ImmSpan[UInt8, ImmUntrackedOrigin]
    """The bytes being parsed.

    The origin is untracked so the parser is not itself parameterized. The
    caller keeps the source alive for the whole parse."""

    var pos: Int
    """The current read offset."""

    var line: Int
    """The one-based line the cursor is on."""

    var line_start: Int
    """The offset of the first byte of the current line."""

    var tape: _Tape
    """The document being built."""

    var root: UInt32
    """The document's root table."""

    var current: UInt32
    """The table that key/value pairs currently land in."""

    var current_path: List[String]
    """The dotted path of `current`, as written, for error messages."""

    var registry_path: List[String]
    """The path of `current` in the definition registry.

    Each array-of-tables the path crosses contributes an element marker, so
    the members of one `[[a]]` block never collide with the next one's."""

    var registry_joined: String
    """`registry_path` already joined, so every key does not rejoin it."""

    var declared: Set[String]
    """Paths declared with `[table]` or `[[array]]`, which may not repeat."""

    var assigned: Set[String]
    """Paths given a value, which may not be overwritten."""

    var array_declared: Set[String]
    """Paths declared with `[[array]]`."""

    var dotted: Set[String]
    """Paths of tables built by a dotted key, which may not be declared later."""

    var closed: Set[String]
    """Paths of inline tables and static arrays, which may never be extended."""

    def __init__(out self, src: Span[UInt8, _]):
        """Prepares to parse `src`.

        Args:
            src: The document bytes, which must outlive the parser.
        """
        self.src = ImmSpan[UInt8, ImmUntrackedOrigin](
            unsafe_ptr=src.unsafe_ptr()
            .as_imm()
            .unsafe_origin_cast[ImmUntrackedOrigin](),
            length=len(src),
        )
        self.pos = 0
        self.line = 1
        self.line_start = 0
        self.tape = _Tape(capacity_hint=len(src))
        self.root = 0
        self.current = 0
        self.current_path = []
        self.registry_path = []
        self.registry_joined = String()
        self.declared = Set[String]()
        self.assigned = Set[String]()
        self.array_declared = Set[String]()
        self.dotted = Set[String]()
        self.closed = Set[String]()

    def take_tape(deinit self) -> _Tape:
        """Consumes the parser and hands back the tape it built.

        Returns:
            The loaded document's tape.
        """
        return self.tape^

    # ===-------------------------------------------------------------------===#
    # Character-level helpers
    # ===-------------------------------------------------------------------===#

    @always_inline
    def _at_end(self) -> Bool:
        """Reports whether the whole input has been consumed.

        Returns:
            True at end of input.
        """
        return self.pos >= len(self.src)

    @always_inline
    def _byte(self, i: Int) -> UInt8:
        """Returns the byte at `i`, or 0 outside the input.

        Args:
            i: The offset to read.

        Returns:
            The byte, or 0.
        """
        return self.src[i] if i < len(self.src) and i >= 0 else UInt8(0)

    @always_inline
    def _peek(self) -> UInt8:
        """Returns the byte at the cursor, or 0 past the end.

        Returns:
            The byte, or 0.
        """
        return self._byte(self.pos)

    @always_inline
    def _column(self) -> Int:
        """Returns the cursor's one-based column.

        Returns:
            The column.
        """
        return self.pos - self.line_start + 1

    def _error(self, var problem: String) -> TOMLDecodeError:
        """Builds an error located at the cursor.

        Args:
            problem: What went wrong.

        Returns:
            The error, ready to raise.
        """
        if self._at_end():
            return TOMLDecodeError(problem^, 0, 0)
        return TOMLDecodeError(problem^, self.line, self._column())

    def _skip_spaces(mut self):
        """Advances the cursor past spaces and tabs."""
        while not self._at_end():
            var b = self._peek()
            if b != _SPACE and b != _TAB:
                return
            self.pos += 1

    def _at_newline(self) -> Bool:
        """Reports whether a line ending starts at the cursor.

        TOML lines end with `LF` or `CRLF`; a carriage return on its own is
        an ordinary control character, illegal wherever one is.

        Returns:
            True if the cursor is on `\\n` or on `\\r\\n`.
        """
        var b = self._peek()
        if b == _NEWLINE:
            return True
        return b == _RETURN and self._byte(self.pos + 1) == _NEWLINE

    def _consume_newline(mut self):
        """Consumes one line ending and moves the line counter on."""
        if self._peek() == _RETURN and self._byte(self.pos + 1) == _NEWLINE:
            self.pos += 1
        if self._peek() == _NEWLINE:
            self.pos += 1
        self.line += 1
        self.line_start = self.pos

    def _skip_comment(mut self) raises:
        """Discards a comment, leaving the cursor on its line ending.

        Raises:
            If the comment holds a control character, which TOML allows only
            as an escape and only inside a string.
        """
        if self._peek() != _HASH:
            return
        self.pos += 1
        while not self._at_end() and not self._at_newline():
            var b = self._peek()
            if _is_control(b):
                raise self._error(
                    String("Found invalid character ", _quote_byte(b))
                )
            self.pos += 1

    def _skip_to_statement(mut self) raises:
        """Advances to the next statement, past blank lines and comments.

        Raises:
            If a comment on the way holds a control character.
        """
        while not self._at_end():
            self._skip_spaces()
            self._skip_comment()
            if self._at_end():
                return
            if self._at_newline():
                self._consume_newline()
                continue
            return

    def _expect_statement_end(mut self) raises:
        """Consumes the rest of a statement's line, which must be empty.

        Raises:
            If anything but a comment follows the statement.
        """
        self._skip_spaces()
        if self._at_end():
            return
        if self._peek() == _HASH:
            self._skip_comment()
        if self._at_end():
            return
        if self._at_newline():
            self._consume_newline()
            return
        raise self._error(
            String("Expected newline or end of document after a statement")
        )

    # ===-------------------------------------------------------------------===#
    # Definition registry
    # ===-------------------------------------------------------------------===#

    def _knows(self, registry: Set[String], key: String) -> Bool:
        """Reports whether `registry` already holds `key`.

        Args:
            registry: One of the parser's definition sets.
            key: The joined key path to look for.

        Returns:
            True if the path is present.
        """
        return key in registry

    def _frozen_prefix(self, path: List[String]) -> Int:
        """Returns how many leading parts of `path` name a closed table.

        An inline table is complete the moment it is written, so nothing may be
        added to it afterwards.

        Args:
            path: The full key path being written to.

        Returns:
            The length of the frozen prefix, or 0 if there is none.
        """
        var prefix = String()
        for length in range(len(path)):
            _append_encoded(prefix, path[length])
            if self._knows(self.closed, prefix):
                return length + 1
        return 0

    def _redefined_namespace(self, path: List[String]) -> Int:
        """Returns how far into `path` a header already claimed the namespace.

        A `[table]` or `[[array]]` header owns the table it names, so a later
        dotted key may not build the same one again. `tomllib` reports the
        shortest such prefix, which is what the first hit here is. Tables that
        a dotted key itself built are deliberately not in this test: two
        dotted keys in one section share their parents.

        Args:
            path: The key path being written, as the document wrote it.

        Returns:
            The number of key parts up to and including the claimed table, or
            -1 if the pair claims nothing.
        """
        if len(path) < 2:
            return -1
        var prefix = String(self.registry_joined)
        for i in range(len(path) - 1):
            _append_tagged(prefix, _KEY, path[i])
            if self._knows(self.declared, prefix) or self._knows(
                self.array_declared, prefix
            ):
                return i + 1
        return -1

    def _frozen_pair_prefix(self, path: List[String]) -> Bool:
        """Reports whether the key's parent namespace is already complete.

        Only the prefixes that reach into `path`, and stop short of its last
        part, can matter. A table header rejects a frozen prefix of
        `registry_path` before that table becomes the current one, and every
        `closed` entry added while it is current extends `registry_path`, so
        no prefix of it can become frozen underneath us. A path of one part
        therefore has nothing to test, which is the common case.

        Args:
            path: The key path being written, as the document wrote it.

        Returns:
            True if the pair would reach inside a table or array that was
            already written out in full.
        """
        if len(path) < 2:
            return False
        var prefix = String(self.registry_joined)
        for i in range(len(path) - 1):
            _append_tagged(prefix, _KEY, path[i])
            if self._knows(self.closed, prefix):
                return True
        return False

    # ===-------------------------------------------------------------------===#
    # Keys
    # ===-------------------------------------------------------------------===#

    def _parse_key_part(mut self) raises -> String:
        """Reads one part of a key, bare or quoted.

        Returns:
            The part's text.

        Raises:
            If no key starts at the cursor.
        """
        var b = self._peek()
        if b == _DQUOTE:
            return self._scan_basic_string(multiline=False)
        if b == _SQUOTE:
            return self._scan_literal_string(multiline=False)
        var start = self.pos
        while not self._at_end() and _is_bare_key_byte(self._peek()):
            self.pos += 1
        if self.pos == start:
            raise self._error(String("Invalid statement"))
        return String(unsafe_from_utf8=self.src[start : self.pos])

    def _parse_key_path(mut self) raises -> List[String]:
        """Reads a possibly dotted key.

        Returns:
            The parts of the key, outermost first.

        Raises:
            If the key is malformed.
        """
        var path = List[String]()
        while True:
            path.append(self._parse_key_part())
            self._skip_spaces()
            if self._peek() != _DOT:
                return path^
            self.pos += 1
            self._skip_spaces()

    # ===-------------------------------------------------------------------===#
    # Tables
    # ===-------------------------------------------------------------------===#

    def _child_table(
        mut self,
        table: UInt32,
        name: StringSlice,
        mut registry: List[String],
        *,
        access_arrays: Bool = True,
    ) raises -> UInt32:
        """Returns the child table called `name`, creating it if absent.

        An array of tables resolves to its last element, which is where a
        `[parent.child]` header appends, and contributes an element marker to
        the registry path so that each element keeps its own namespace.

        Args:
            table: The parent table.
            name: The child's name.
            registry: The registry path built so far, extended in place.
            access_arrays: Whether an array of tables resolves to its last
                element. Inside an inline table it does not, which is what
                keeps `{ a = [{}], a.b = 1 }` out.

        Returns:
            The child table's node index.

        Raises:
            If a value that is not a table already holds that name, so that
            `a = 1` followed by `a.b = 2` is rejected rather than writing
            through the integer.
        """
        registry.append(_component(_KEY, name))
        var at = self.tape.find_member(table, name.as_bytes())
        if at >= 0:
            var start = Int(self.tape.nodes[Int(table)].a)
            var child = self.tape.kids[start + 2 * at + 1]
            var kind = self.tape.nodes[Int(child)].kind
            if kind == _KIND_ARRAY and access_arrays:
                var info = self.tape.nodes[Int(child)]
                if info.b:
                    var last = self.tape.kids[Int(info.a) + Int(info.b) - 1]
                    if self.tape.nodes[Int(last)].kind != _KIND_OBJECT:
                        raise self._error(String("Cannot overwrite a value"))
                    registry.append(
                        _component(_ELEMENT, String(Int(info.b) - 1))
                    )
                    return last
                raise self._error(String("Cannot overwrite a value"))
            if kind != _KIND_OBJECT:
                raise self._error(String("Cannot overwrite a value"))
            return child
        var created = self.tape.new_container(_KIND_OBJECT)
        var key = self.tape.push_string(name.as_bytes())
        self.tape.object_push(table, key, created)
        return created

    def _parse_table_header(mut self) raises:
        """Reads a `[table]` or `[[array]]` header and moves the cursor into it.

        Raises:
            If the header is malformed or redefines something.
        """
        self.pos += 1  # the bracket
        var is_array = self._peek() == _LBRACKET
        if is_array:
            self.pos += 1
        self._skip_spaces()
        var path = self._parse_key_path()

        # Follow the path as far as the document already goes, creating and
        # writing nothing, so that the checks below see the registry path this
        # header lands on. A part naming something that is not a table stops
        # the walk, but is only reported after those checks, which is the
        # order `tomllib` applies them in.
        var probe = List[String]()
        var probe_table = self.root
        var walking = True
        var blocked = False
        for i in range(len(path) - 1):
            probe.append(_component(_KEY, path[i]))
            if not walking:
                continue
            var at = self.tape.find_member(probe_table, path[i].as_bytes())
            if at < 0:
                walking = False
                continue
            var start = Int(self.tape.nodes[Int(probe_table)].a)
            var child = self.tape.kids[start + 2 * at + 1]
            var kind = self.tape.nodes[Int(child)].kind
            if kind == _KIND_OBJECT:
                probe_table = child
                continue
            if kind == _KIND_ARRAY:
                var info = self.tape.nodes[Int(child)]
                if info.b:
                    var last = self.tape.kids[Int(info.a) + Int(info.b) - 1]
                    if self.tape.nodes[Int(last)].kind == _KIND_OBJECT:
                        probe.append(
                            _component(_ELEMENT, String(Int(info.b) - 1))
                        )
                        probe_table = last
                        continue
            walking = False
            blocked = True
        probe.append(_component(_KEY, path[len(path) - 1]))
        var joined = _join(probe)

        var frozen = self._frozen_prefix(probe)
        if is_array:
            if frozen:
                raise self._error(
                    String(
                        "Cannot mutate immutable namespace ", _quote_path(path)
                    )
                )
            if (
                self._knows(self.dotted, joined)
                or self._knows(self.declared, joined)
                or self._knows(self.assigned, joined)
            ):
                raise self._error(String("Cannot overwrite a value"))
        else:
            if (
                frozen
                or self._knows(self.dotted, joined)
                or self._knows(self.declared, joined)
                or self._knows(self.array_declared, joined)
            ):
                raise self._error(
                    String("Cannot declare ", _quote_path(path), " twice")
                )
            if self._knows(self.assigned, joined):
                raise self._error(String("Cannot overwrite a value"))
        if blocked:
            raise self._error(String("Cannot overwrite a value"))
        if is_array and walking:
            # An implicitly created table leaves no trace in the registries,
            # so the node itself has to be checked before appending to it.
            var at = self.tape.find_member(
                probe_table, path[len(path) - 1].as_bytes()
            )
            if at >= 0:
                var start = Int(self.tape.nodes[Int(probe_table)].a)
                var existing = self.tape.kids[start + 2 * at + 1]
                if self.tape.nodes[Int(existing)].kind != _KIND_ARRAY:
                    raise self._error(String("Cannot overwrite a value"))

        self._skip_spaces()
        if is_array:
            if (
                self._peek() != _RBRACKET
                or self._byte(self.pos + 1) != _RBRACKET
            ):
                raise self._error(
                    String(
                        "Expected ']]' at the end of an array-of-tables"
                        " declaration"
                    )
                )
            self.pos += 2
        else:
            if self._peek() != _RBRACKET:
                raise self._error(
                    String("Expected ']' at the end of a table declaration")
                )
            self.pos += 1

        var registry = List[String]()
        var table = self.root
        for i in range(len(path) - 1):
            table = self._child_table(table, path[i], registry)
        var last = path[len(path) - 1]

        if is_array:
            var at = self.tape.find_member(table, last.as_bytes())
            var array: UInt32
            if at >= 0:
                array = self.tape.kids[
                    Int(self.tape.nodes[Int(table)].a) + 2 * at + 1
                ]
            else:
                array = self.tape.new_container(_KIND_ARRAY)
                var key = self.tape.push_string(last.as_bytes())
                self.tape.object_push(table, key, array)
            var entry = self.tape.new_container(_KIND_OBJECT)
            self.tape.array_push(array, entry)
            self.current = entry
            self.array_declared.add(joined)
            registry.append(_component(_KEY, last))
            registry.append(
                _component(
                    _ELEMENT, String(Int(self.tape.nodes[Int(array)].b) - 1)
                )
            )
        else:
            self.current = self._child_table(table, last, registry)
            self.declared.add(_join(registry))

        self.current_path = path^
        self.registry_joined = _join(registry)
        self.registry_path = registry^

    # ===-------------------------------------------------------------------===#
    # Key/value pairs
    # ===-------------------------------------------------------------------===#

    def _parse_pair(mut self) raises:
        """Reads one `key = value` statement into the current table.

        Raises:
            If the statement is malformed or overwrites something.
        """
        var path = self._parse_key_path()
        self._skip_spaces()
        if self._peek() != _EQUALS:
            raise self._error(
                String("Expected '=' after a key in a key/value pair")
            )
        self.pos += 1
        self._skip_spaces()
        var value = self._parse_value(0)

        var joined = String(self.registry_joined)
        for i in range(len(path)):
            _append_tagged(joined, _KEY, path[i])

        var redefined = self._redefined_namespace(path)
        if redefined >= 0:
            # `tomllib` runs this before the frozen test and names the table
            # the header claimed, written the way the document wrote it.
            var claimed = List[String]()
            for i in range(len(self.current_path)):
                claimed.append(self.current_path[i])
            for i in range(redefined):
                claimed.append(path[i])
            raise self._error(
                String("Cannot redefine namespace ", _quote_path(claimed))
            )

        if self._frozen_pair_prefix(path):
            # `tomllib` names the key's parent here, written the way the
            # document wrote it, so the element markers stay out of it.
            var parent = List[String]()
            for i in range(len(self.current_path)):
                parent.append(self.current_path[i])
            for i in range(len(path) - 1):
                parent.append(path[i])
            raise self._error(
                String(
                    "Cannot mutate immutable namespace ", _quote_path(parent)
                )
            )
        if (
            self._knows(self.assigned, joined)
            or self._knows(self.declared, joined)
            or self._knows(self.array_declared, joined)
        ):
            raise self._error(String("Cannot overwrite a value"))

        var table = self.current
        if len(path) > 1:
            var walked = List[String]()
            for i in range(len(self.registry_path)):
                walked.append(self.registry_path[i])
            for i in range(len(path) - 1):
                table = self._child_table(table, path[i], walked)
                var prefix_key = _join(walked)
                if not self._knows(self.dotted, prefix_key):
                    self.dotted.add(prefix_key)

        var last = path[len(path) - 1]
        if self.tape.find_member(table, last.as_bytes()) >= 0:
            raise self._error(String("Cannot overwrite a value"))
        var key = self.tape.push_string(last.as_bytes())
        self.tape.object_push(table, key, value)
        self.assigned.add(joined)

        var kind = self.tape.nodes[Int(value)].kind
        if kind == _KIND_OBJECT or kind == _KIND_ARRAY:
            # An inline table or a static array is complete as written.
            self.closed.add(joined)

    # ===-------------------------------------------------------------------===#
    # Strings
    # ===-------------------------------------------------------------------===#

    def _read_hex(mut self, count: Int) raises -> Int:
        """Reads `count` hexadecimal digits of a `\\u` escape.

        Args:
            count: How many digits the escape carries.

        Returns:
            The scalar value they encode.

        Raises:
            If fewer digits are present or one is not hexadecimal.
        """
        if self.pos + count > len(self.src):
            raise self._error(String("Invalid escape sequence"))
        var value = 0
        for i in range(count):
            var b = self._byte(self.pos + i)
            var digit: Int
            if _is_digit(b):
                digit = Int(b - 0x30)
            elif b >= 0x61 and b <= 0x66:
                digit = Int(b - 0x61) + 10
            elif b >= 0x41 and b <= 0x46:
                digit = Int(b - 0x41) + 10
            else:
                raise self._error(String("Invalid escape sequence"))
            value = value * 16 + digit
        self.pos += count
        return value

    def _scalar_value(mut self, count: Int) raises -> Int:
        """Reads a `\\u` or `\\U` escape and checks it names a real character.

        Args:
            count: How many hexadecimal digits the escape carries.

        Returns:
            The codepoint it encodes.

        Raises:
            If the digits are malformed, or encode a surrogate or a value
            above U+10FFFF, neither of which is a Unicode scalar value.
        """
        var value = self._read_hex(count)
        if value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF):
            raise self._error(
                String("Escaped character is not a Unicode scalar value")
            )
        return value

    def _scan_basic_string(mut self, *, multiline: Bool) raises -> String:
        """Reads a `"` or `\"\"\"` string, decoding its escapes.

        Args:
            multiline: Whether the caller already knows this is a `\"\"\"`
                string. When False the opening delimiter is inspected, so a
                triple quote is still recognised.

        Returns:
            The string's text.

        Raises:
            If the string never closes or holds a bad escape.
        """
        var triple = multiline
        if (
            not multiline
            and self._byte(self.pos + 1) == _DQUOTE
            and self._byte(self.pos + 2) == _DQUOTE
        ):
            triple = True
        self.pos += 3 if triple else 1
        if triple and self._at_newline():
            # A newline immediately after the opening delimiter is trimmed.
            self._consume_newline()

        var out = List[UInt8]()
        while True:
            if self._at_end():
                raise self._error(String("Unterminated string"))
            var b = self._peek()
            if b == _DQUOTE:
                if not triple:
                    self.pos += 1
                    break
                if (
                    self._byte(self.pos + 1) == _DQUOTE
                    and self._byte(self.pos + 2) == _DQUOTE
                ):
                    self.pos += 3
                    # A run of four or five quotes ends the string too; the
                    # one or two beyond the delimiter belong to the value.
                    for _ in range(2):
                        if self._peek() != _DQUOTE:
                            break
                        out.append(_DQUOTE)
                        self.pos += 1
                    break
                out.append(b)
                self.pos += 1
                continue
            if triple and self._at_newline():
                self._consume_newline()
                out.append(_NEWLINE)
                continue
            if b == _BACKSLASH:
                self._decode_escape(out, triple)
                continue
            if _is_control(b):
                raise self._error(String("Illegal character ", _quote_byte(b)))
            out.append(b)
            self.pos += 1
        return String(unsafe_from_utf8=Span(out))

    def _decode_escape(mut self, mut out: List[UInt8], triple: Bool) raises:
        """Consumes one `\\`-escape and appends what it stands for.

        Args:
            out: The buffer collecting the string's bytes.
            triple: Whether this is a multi-line string, where a backslash at
                the end of a line swallows the break and the indent after it.

        Raises:
            If the escape is not one TOML defines.
        """
        var e = self._byte(self.pos + 1)
        if triple and (
            e == _NEWLINE or e == _RETURN or e == _SPACE or e == _TAB
        ):
            # A line-ending backslash trims the break and the whitespace round
            # it, so `"""a \<newline>  b"""` is `a b`.
            var probe = self.pos + 1
            while probe < len(self.src) and (
                self._byte(probe) == _SPACE or self._byte(probe) == _TAB
            ):
                probe += 1
            var saved = self.pos
            self.pos = probe
            if self._at_newline():
                self._consume_newline()
                while not self._at_end():
                    var c = self._peek()
                    if c == _SPACE or c == _TAB:
                        self.pos += 1
                    elif self._at_newline():
                        self._consume_newline()
                    else:
                        break
                return
            self.pos = saved
        self.pos += 2
        if e == 0x62:  # b
            out.append(0x08)
        elif e == 0x74:  # t
            out.append(0x09)
        elif e == 0x6E:  # n
            out.append(0x0A)
        elif e == 0x66:  # f
            out.append(0x0C)
        elif e == 0x72:  # r
            out.append(0x0D)
        elif e == _DQUOTE or e == _BACKSLASH:
            out.append(e)
        elif e == 0x75:  # u
            _append_utf8(out, self._scalar_value(4))
        elif e == 0x55:  # U
            _append_utf8(out, self._scalar_value(8))
        else:
            raise self._error(String("Invalid escape sequence"))

    def _scan_literal_string(mut self, *, multiline: Bool) raises -> String:
        """Reads a `\'` or `\'\'\'` string, which has no escapes.

        Args:
            multiline: Whether the caller already knows this is a `\'\'\'`
                string.

        Returns:
            The string's text, exactly as written.

        Raises:
            If the string never closes.
        """
        var triple = multiline
        if (
            not multiline
            and self._byte(self.pos + 1) == _SQUOTE
            and self._byte(self.pos + 2) == _SQUOTE
        ):
            triple = True
        self.pos += 3 if triple else 1
        if triple and self._at_newline():
            self._consume_newline()

        var start = self.pos
        var out = List[UInt8]()
        while True:
            if self._at_end():
                raise self._error(String("Unterminated string"))
            var b = self._peek()
            if b == _SQUOTE:
                if not triple:
                    self.pos += 1
                    break
                if (
                    self._byte(self.pos + 1) == _SQUOTE
                    and self._byte(self.pos + 2) == _SQUOTE
                ):
                    self.pos += 3
                    # A run of four or five apostrophes ends the string too;
                    # the extras belong to the value.
                    for _ in range(2):
                        if self._peek() != _SQUOTE:
                            break
                        out.append(_SQUOTE)
                        self.pos += 1
                    break
            if triple and self._at_newline():
                self._consume_newline()
                out.append(_NEWLINE)
                continue
            if _is_control(b):
                raise self._error(
                    String("Found invalid character ", _quote_byte(b))
                )
            out.append(b)
            self.pos += 1
        _ = start
        return String(unsafe_from_utf8=Span(out))

    # ===-------------------------------------------------------------------===#
    # Values
    # ===-------------------------------------------------------------------===#

    def _scan_value_token(mut self) -> Tuple[Int, Int]:
        """Advances past a bare value and returns its byte range.

        Returns:
            The start and end offsets of the token.
        """
        var start = self.pos
        while not self._at_end():
            var b = self._peek()
            if (
                b == _SPACE
                or b == _TAB
                or b == _NEWLINE
                or b == _RETURN
                or b == _COMMA
                or b == _RBRACKET
                or b == _RBRACE
                or b == _HASH
            ):
                break
            self.pos += 1
        return (start, self.pos)

    def _parse_value(mut self, depth: Int) raises -> UInt32:
        """Parses one value, recursing into arrays and inline tables.

        Both bracketed forms are handled inside this one function so that the
        recursion is a single function calling itself; a longer cycle makes the
        Mojo elaborator hang.

        Args:
            depth: How deeply nested this value is.

        Returns:
            The index of the new node.

        Raises:
            `TOMLDecodeError` if the value is malformed.
        """
        if depth > MAX_DEPTH:
            raise self._error(
                String("Exceeded maximum nesting depth of ", MAX_DEPTH)
            )
        var b = self._peek()

        if b == _DQUOTE:
            var text = self._scan_basic_string(multiline=False)
            return self.tape.push_string(text.as_bytes())
        if b == _SQUOTE:
            var text = self._scan_literal_string(multiline=False)
            return self.tape.push_string(text.as_bytes())

        if b == _LBRACKET:
            self.pos += 1
            var node = self.tape.new_container(_KIND_ARRAY)
            while True:
                self._skip_array_space()
                if self._at_end():
                    raise TOMLDecodeError(String("Unclosed array"), 0, 0)
                if self._peek() == _RBRACKET:
                    self.pos += 1
                    break
                var item = self._parse_value(depth + 1)
                self.tape.array_push(node, item)
                self._skip_array_space()
                if self._peek() == _COMMA:
                    self.pos += 1
                    continue
                if self._peek() == _RBRACKET:
                    self.pos += 1
                    break
                if self._at_end():
                    raise TOMLDecodeError(String("Unclosed array"), 0, 0)
                raise self._error(String("Unclosed array"))
            return node

        if b == _LBRACE:
            self.pos += 1
            var node = self.tape.new_container(_KIND_OBJECT)
            self._skip_spaces()
            if self._peek() == _RBRACE:
                self.pos += 1
                return node
            # An inline table keeps its own frozen set, exactly as `tomllib`
            # gives each one a fresh flag table: a member holding a table or
            # an array is complete as written and may not be reopened by a
            # later dotted key in the same braces.
            var frozen = Set[String]()
            while True:
                self._skip_spaces()
                var path = self._parse_key_path()
                self._skip_spaces()
                if self._peek() != _EQUALS:
                    raise self._error(
                        String("Expected '=' after a key in a key/value pair")
                    )
                self.pos += 1
                self._skip_spaces()
                var value = self._parse_value(depth + 1)

                var walked = String()
                for i in range(len(path)):
                    _append_tagged(walked, _KEY, path[i])
                    if walked in frozen:
                        raise self._error(
                            String(
                                "Cannot mutate immutable namespace ",
                                _quote_path(path),
                            )
                        )

                var table = node
                var ignored = List[String]()
                for i in range(len(path) - 1):
                    table = self._child_table(
                        table, path[i], ignored, access_arrays=False
                    )
                var last = path[len(path) - 1]
                if self.tape.find_member(table, last.as_bytes()) >= 0:
                    raise self._error(
                        String("Duplicate inline table key ", _quote_one(last))
                    )
                var key = self.tape.push_string(last.as_bytes())
                self.tape.object_push(table, key, value)
                var kind = self.tape.nodes[Int(value)].kind
                if kind == _KIND_OBJECT or kind == _KIND_ARRAY:
                    frozen.add(walked)
                self._skip_spaces()
                if self._peek() == _COMMA:
                    self.pos += 1
                    continue
                if self._peek() == _RBRACE:
                    self.pos += 1
                    break
                raise self._error(String("Unclosed inline table"))
            return node

        var stamp = _match_datetime(self.src, self.pos)
        if stamp > 0:
            # There is no date type here, so the literal is kept verbatim —
            # but only after its syntax and calendar date are checked.
            var text = StringSlice(
                unsafe_from_utf8=self.src[self.pos : self.pos + stamp]
            )
            if not _is_real_date(text):
                raise self._error(String("Invalid date or datetime"))
            self.pos += stamp
            return self.tape.push_string(text.as_bytes())

        var start, end = self._scan_value_token()
        if end == start:
            raise self._error(String("Invalid value"))
        var text = StringSlice(unsafe_from_utf8=self.src[start:end])
        return self._classify(text, start)

    def _skip_array_space(mut self) raises:
        """Advances past whitespace, line breaks and comments inside an array.

        Raises:
            If a comment on the way holds a control character.
        """
        while not self._at_end():
            var b = self._peek()
            if b == _SPACE or b == _TAB:
                self.pos += 1
            elif self._at_newline():
                self._consume_newline()
            elif b == _HASH:
                self._skip_comment()
            else:
                return

    def _classify(mut self, text: StringSlice, start: Int) raises -> UInt32:
        """Turns a bare token into a node.

        Args:
            text: The token, exactly as written.
            start: Where the token began, for error reporting.

        Returns:
            The index of the new node.

        Raises:
            If the token is not a value TOML defines.
        """
        if text == "true":
            return self.tape.push(_Node.scalar(_KIND_BOOL, 1))
        if text == "false":
            return self.tape.push(_Node.scalar(_KIND_BOOL, 0))

        var overflow = False
        var number = _parse_number(text, overflow)
        if number:
            var value = number.value()
            if value.is_float:
                return self.tape.push(
                    _Node.scalar(
                        _KIND_FLOAT, value.floating.to_bits[DType.uint64]()
                    )
                )
            return self.tape.push(
                _Node.scalar(_KIND_INT, UInt64(Int64(value.integer)))
            )

        self.pos = start
        if overflow:
            raise self._error(
                String("Integer is out of range for a signed 64-bit value")
            )
        raise self._error(String("Invalid value"))

    # ===-------------------------------------------------------------------===#
    # Entry point
    # ===-------------------------------------------------------------------===#

    def parse(mut self) raises -> UInt32:
        """Decodes the whole document.

        Returns:
            The index of the root table.

        Raises:
            `TOMLDecodeError` if the document is not valid TOML.
        """
        self.root = self.tape.new_container(_KIND_OBJECT)
        self.current = self.root
        while True:
            self._skip_to_statement()
            if self._at_end():
                break
            if self._peek() == _LBRACKET:
                self._parse_table_header()
            else:
                self._parse_pair()
            self._expect_statement_end()
        return self.root


def _append_utf8(mut out: List[UInt8], cp: Int):
    """Appends one codepoint to `out` as UTF-8.

    Args:
        out: The buffer to append to.
        cp: The codepoint to encode.
    """
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xF0 | (cp >> 18)))
        out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))


def _two_digits(src: Span[UInt8, _], pos: Int, low: Int, high: Int) -> Bool:
    """Reports whether two digits at `pos` spell a number within a range.

    Args:
        src: The document bytes.
        pos: Where the pair starts.
        low: The smallest value accepted.
        high: The largest value accepted.

    Returns:
        True if both bytes are digits and the pair is in range.
    """
    if pos + 1 >= len(src):
        return False
    if not _is_digit(src[pos]) or not _is_digit(src[pos + 1]):
        return False
    var value = Int(src[pos] - 0x30) * 10 + Int(src[pos + 1] - 0x30)
    return value >= low and value <= high


def _match_time(src: Span[UInt8, _], pos: Int) -> Int:
    """Matches `HH:MM:SS` with an optional fraction.

    Args:
        src: The document bytes.
        pos: Where the time would start.

    Returns:
        Its length, or 0 if no time starts there.
    """
    if not _two_digits(src, pos, 0, 23):
        return 0
    if pos + 2 >= len(src) or src[pos + 2] != _COLON:
        return 0
    if not _two_digits(src, pos + 3, 0, 59):
        return 0
    if pos + 5 >= len(src) or src[pos + 5] != _COLON:
        return 0
    if not _two_digits(src, pos + 6, 0, 59):
        return 0
    var end = pos + 8
    if end < len(src) and src[end] == _DOT and _is_digit_at(src, end + 1):
        end += 1
        while end < len(src) and _is_digit(src[end]):
            end += 1
    return end - pos


def _match_datetime(src: Span[UInt8, _], pos: Int) -> Int:
    """Matches a TOML date, time or date-time at `pos`.

    The shapes accepted are the ones `tomllib` accepts, ranges included: a
    date is `YYYY-MM-DD` with a month of 01-12 and a day of 01-31, a time is
    `HH:MM:SS` with an optional fraction, and a date-time joins them with `T`,
    `t` or a space and may carry a `Z` or a `+HH:MM` offset. Whether the day
    actually exists in that month is left to `_is_real_date`.

    Args:
        src: The document bytes.
        pos: Where the literal would start.

    Returns:
        The length matched, or 0 if nothing here is a date or a time.
    """
    var is_date = (
        pos + 9 < len(src)
        and _is_digit(src[pos])
        and _is_digit(src[pos + 1])
        and _is_digit(src[pos + 2])
        and _is_digit(src[pos + 3])
        and src[pos + 4] == _MINUS
        and _two_digits(src, pos + 5, 1, 12)
        and src[pos + 7] == _MINUS
        and _two_digits(src, pos + 8, 1, 31)
    )
    if not is_date:
        return _match_time(src, pos)

    var end = pos + 10
    if end >= len(src):
        return end - pos
    var separator = src[end]
    if separator != 0x54 and separator != 0x74 and separator != _SPACE:
        return end - pos
    var time = _match_time(src, end + 1)
    if time == 0:
        # A date on its own, followed by whatever came after it.
        return end - pos
    end += 1 + time

    if end < len(src) and (src[end] == 0x5A or src[end] == 0x7A):  # Z, z
        return end + 1 - pos
    if (
        end + 5 < len(src)
        and (src[end] == _PLUS or src[end] == _MINUS)
        and _two_digits(src, end + 1, 0, 23)
        and src[end + 3] == _COLON
        and _two_digits(src, end + 4, 0, 59)
    ):
        return end + 6 - pos
    return end - pos


def _is_real_date(text: StringSlice) -> Bool:
    """Reports whether a matched literal names a day that exists.

    Args:
        text: The literal, already known to have the right shape.

    Returns:
        True unless the day is past the end of its month.
    """
    var b = text.as_bytes()
    if len(b) < 10 or b[4] != _MINUS:
        return True  # A bare time has no calendar date to check.
    var year = (
        Int(b[0] - 0x30) * 1000
        + Int(b[1] - 0x30) * 100
        + Int(b[2] - 0x30) * 10
        + Int(b[3] - 0x30)
    )
    var month = Int(b[5] - 0x30) * 10 + Int(b[6] - 0x30)
    var day = Int(b[8] - 0x30) * 10 + Int(b[9] - 0x30)

    if year == 0:
        # `datetime.date` starts at year 1, so `tomllib` rejects `0000-01-01`.
        return False

    var length: Int
    if month == 2:
        var leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0
        length = 29 if leap else 28
    elif month == 4 or month == 6 or month == 9 or month == 11:
        length = 30
    else:
        length = 31
    return day <= length


@always_inline
def _is_digit_at(src: Span[UInt8, _], pos: Int) -> Bool:
    """Reports whether `src` holds a digit at `pos`.

    Args:
        src: The document bytes.
        pos: The offset to test.

    Returns:
        True if the offset is in range and holds `0`-`9`.
    """
    return pos < len(src) and _is_digit(src[pos])


@fieldwise_init
struct _Number(Copyable, ImplicitlyCopyable, Movable):
    """A parsed numeric literal, integer or float."""

    var is_float: Bool
    """Whether the literal carried a fraction, an exponent or was non-finite."""

    var integer: Int
    """The value, when this is an integer."""

    var floating: Float64
    """The value, when this is a float."""


def _strip_underscores(
    text: StringSlice, hexadecimal: Bool
) -> Optional[String]:
    """Removes the digit-grouping underscores TOML allows.

    Args:
        text: The literal to clean.
        hexadecimal: Whether `a`-`f` count as digits, which they do only in a
            `0x` literal. Everywhere else `1_e2` and `1e_2` are malformed,
            because a separator must sit between two decimal digits.

    Returns:
        The literal without underscores, or `None` if one sits anywhere other
        than between two digits.
    """
    var bytes = text.as_bytes()
    var kept = List[UInt8](capacity=len(bytes))
    for i in range(len(bytes)):
        if bytes[i] != _UNDERSCORE:
            kept.append(bytes[i])
            continue
        if i == 0 or i + 1 == len(bytes):
            return None
        var before = bytes[i - 1]
        var after = bytes[i + 1]
        if hexadecimal:
            if not _is_hex_digit(before) or not _is_hex_digit(after):
                return None
        elif not _is_digit(before) or not _is_digit(after):
            return None
    return String(unsafe_from_utf8=Span(kept))


@always_inline
def _is_hex_digit(b: UInt8) -> Bool:
    """Reports whether `b` is a hexadecimal digit.

    Args:
        b: The byte to test.

    Returns:
        True for `0`-`9`, `a`-`f` and `A`-`F`.
    """
    return (
        _is_digit(b) or (b >= 0x61 and b <= 0x66) or (b >= 0x41 and b <= 0x46)
    )


def _digits_in_base(
    text: StringSlice, base: Int, mut overflow: Bool
) -> Optional[UInt64]:
    """Parses `text` as an unsigned integer in `base`.

    Args:
        text: The digits, already free of underscores.
        base: The radix, 2, 8, 10 or 16.
        overflow: Set when the digits are a number but one too large to hold,
            so the caller can say so instead of calling the literal invalid.

    Returns:
        The value, or `None` if `text` is empty, holds a digit out of range,
        or does not fit in 64 bits.
    """
    var bytes = text.as_bytes()
    if len(bytes) == 0:
        return None
    var radix = UInt64(base)
    var limit = UInt64.MAX
    var value = UInt64(0)
    for i in range(len(bytes)):
        var b = bytes[i]
        var digit: Int
        if _is_digit(b):
            digit = Int(b - 0x30)
        elif b >= 0x61 and b <= 0x66:
            digit = Int(b - 0x61) + 10
        elif b >= 0x41 and b <= 0x46:
            digit = Int(b - 0x41) + 10
        else:
            return None
        if digit >= base:
            return None
        if value > (limit - UInt64(digit)) // radix:
            overflow = True
            return None
        value = value * radix + UInt64(digit)
    return value


def _signed(
    magnitude: Optional[UInt64], negative: Bool, mut overflow: Bool
) -> Optional[_Number]:
    """Applies a sign to a magnitude, rejecting what 64 bits cannot hold.

    Args:
        magnitude: The digits' value, or `None` if they were not a number.
        negative: Whether the literal carried a `-`.
        overflow: Set when the magnitude is past the signed 64-bit range.

    Returns:
        The integer, or `None` if there is none to make.
    """
    if not magnitude:
        return None
    var value = magnitude.value()
    if negative:
        if value > UInt64(1) << 63:
            overflow = True
            return None
        if value == UInt64(1) << 63:
            return _Number(False, Int(Int64.MIN), 0)
        return _Number(False, -Int(value), 0)
    if value > UInt64(Int64.MAX):
        overflow = True
        return None
    return _Number(False, Int(value), 0)


def _parse_number(
    text: StringSlice, mut overflow: Bool
) raises -> Optional[_Number]:
    """Parses a bare token as a TOML number.

    Args:
        text: The token, exactly as written.
        overflow: Set when the token is an integer too large for 64 bits, so
            the caller can report that rather than calling it invalid.

    Returns:
        The number it denotes, or `None` if it is not one.

    Raises:
        Never; the signature matches its caller.
    """
    var bytes = text.as_bytes()
    if len(bytes) == 0:
        return None

    var negative = False
    var body_start = 0
    if bytes[0] == _PLUS or bytes[0] == _MINUS:
        negative = bytes[0] == _MINUS
        body_start = 1
    var body = text[byte = body_start : len(bytes)]

    if body == "inf":
        var value = Float64("-inf") if negative else Float64("inf")
        return _Number(True, 0, value)
    if body == "nan":
        return _Number(True, 0, Float64("nan"))

    var raw = body.as_bytes()
    var prefixed = (
        len(raw) > 1
        and raw[0] == 0x30
        and (raw[1] == 0x78 or raw[1] == 0x6F or raw[1] == 0x62)  # x, o, b
    )
    if prefixed and body_start != 0:
        # `+0x1` is not a TOML integer; only the decimal form takes a sign.
        return None
    var cleaned_opt = _strip_underscores(body, prefixed and raw[1] == 0x78)
    if not cleaned_opt:
        return None
    var cleaned = cleaned_opt.value()
    var n = cleaned.byte_length()
    if n == 0:
        return None

    var first = cleaned.as_bytes()[0]
    var second = cleaned.as_bytes()[1] if n > 1 else UInt8(0)
    if first == 0x30 and n > 1 and second == 0x78:  # 0x
        return _signed(
            _digits_in_base(cleaned[byte=2:n], 16, overflow), negative, overflow
        )
    if first == 0x30 and n > 1 and second == 0x6F:  # 0o
        return _signed(
            _digits_in_base(cleaned[byte=2:n], 8, overflow), negative, overflow
        )
    if first == 0x30 and n > 1 and second == 0x62:  # 0b
        return _signed(
            _digits_in_base(cleaned[byte=2:n], 2, overflow), negative, overflow
        )

    var has_dot = False
    var has_exponent = False
    for i in range(n):
        var b = cleaned.as_bytes()[i]
        if b == _DOT:
            has_dot = True
        elif (b | 0x20) == 0x65 and i > 0:
            has_exponent = True

    if not has_dot and not has_exponent:
        # A leading zero is only allowed on its own, so `01` is not a number.
        if n > 1 and first == 0x30:
            return None
        return _signed(
            _digits_in_base(cleaned, 10, overflow), negative, overflow
        )

    if not _is_valid_float(cleaned):
        return None
    var value = atof(cleaned)
    return _Number(True, 0, -value if negative else value)


def _is_valid_float(text: StringSlice) -> Bool:
    """Checks the shape of a decimal float literal.

    TOML wants digits on both sides of the point and at least one digit in the
    exponent, so `1.` and `.5` and `1e` are not floats.

    Args:
        text: The literal, without a sign or underscores.

    Returns:
        True if the literal is a well-formed float.
    """
    var bytes = text.as_bytes()
    var i = 0
    var digits = 0
    while i < len(bytes) and _is_digit(bytes[i]):
        digits += 1
        i += 1
    if digits == 0:
        return False
    if digits > 1 and bytes[0] == 0x30:
        return False
    if i < len(bytes) and bytes[i] == _DOT:
        i += 1
        var fraction = 0
        while i < len(bytes) and _is_digit(bytes[i]):
            fraction += 1
            i += 1
        if fraction == 0:
            return False
    if i < len(bytes):
        if (bytes[i] | 0x20) != 0x65:
            return False
        i += 1
        if i < len(bytes) and (bytes[i] == _PLUS or bytes[i] == _MINUS):
            i += 1
        var exponent = 0
        while i < len(bytes) and _is_digit(bytes[i]):
            exponent += 1
            i += 1
        if exponent == 0:
            return False
    return i == len(bytes)
