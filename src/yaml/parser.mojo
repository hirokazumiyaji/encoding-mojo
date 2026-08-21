"""The YAML parser.

A recursive-descent parser over the raw bytes. Block structure is driven by
column: every routine is told the indentation its parent occupies and decides
from the next content line whether it owns it. Flow collections recurse
independently, and scalars come in the five YAML flavours — plain, single
quoted, double quoted, literal and folded.

Values land in the same `_Tape` the JSON package uses, so a document loaded
here can be dumped as JSON without conversion.
"""

from std.memory import ArcPointer

from serde.tape import (
    MAX_DEPTH,
    _KIND_ARRAY,
    _KIND_NULL,
    _KIND_OBJECT,
    _KIND_STRING,
    _Node,
    _Tape,
    _reserve_extra,
)
from serde import EncodeOptions, write_value

from .errors import YAMLError
from .resolver import resolve_plain

comptime _TAB: UInt8 = 0x09
comptime _NEWLINE: UInt8 = 0x0A
comptime _RETURN: UInt8 = 0x0D
comptime _SPACE: UInt8 = 0x20
comptime _HASH: UInt8 = 0x23
comptime _PERCENT: UInt8 = 0x25
comptime _AMPERSAND: UInt8 = 0x26
comptime _SQUOTE: UInt8 = 0x27
comptime _STAR: UInt8 = 0x2A
comptime _PLUS: UInt8 = 0x2B
comptime _COMMA: UInt8 = 0x2C
comptime _DASH: UInt8 = 0x2D
comptime _DOT: UInt8 = 0x2E
comptime _COLON: UInt8 = 0x3A
comptime _LT: UInt8 = 0x3C
comptime _QUESTION: UInt8 = 0x3F
comptime _BANG: UInt8 = 0x21
comptime _DQUOTE: UInt8 = 0x22
comptime _BACKSLASH: UInt8 = 0x5C
comptime _LBRACKET: UInt8 = 0x5B
comptime _RBRACKET: UInt8 = 0x5D
comptime _LBRACE: UInt8 = 0x7B
comptime _RBRACE: UInt8 = 0x7D
comptime _PIPE: UInt8 = 0x7C
comptime _GT: UInt8 = 0x3E

comptime _CHOMP_CLIP = 0
comptime _CHOMP_STRIP = -1
comptime _CHOMP_KEEP = 1


@fieldwise_init
struct _Properties(Copyable, ImplicitlyCopyable, Movable):
    """The `&anchor` and `!tag` that may precede a node."""

    var anchor: String
    """The anchor name, empty when there is none."""

    var tag: String
    """The resolved tag, empty when there is none."""


struct _Parser(Movable):
    """One load of one byte stream."""

    var src: ImmSpan[UInt8, ImmUntrackedOrigin]
    """The bytes being parsed.

    The origin is untracked so the parser is not itself parameterized: its
    routines are mutually recursive across a dozen methods, and a generic
    struct made those elaborate as a dependency cycle. The caller keeps the
    source alive for the whole parse, so the view stays valid."""

    var pos: Int
    """The current read offset."""

    var line: Int
    """The one-based line the cursor is on."""

    var line_start: Int
    """The offset of the first byte of the current line."""

    var tape: _Tape
    """The document being built."""

    var anchors: Dict[String, UInt32]
    """Node index for each anchor seen so far, for aliases to point at."""

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
        self.anchors = {}

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
        """Returns the byte at `i`, or 0 past the end.

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
        """Returns the cursor's zero-based column.

        Returns:
            The column.
        """
        return self.pos - self.line_start

    def _error(self, var problem: String) -> YAMLError:
        """Builds an error located at the cursor.

        Args:
            problem: What went wrong.

        Returns:
            The error, ready to raise.
        """
        return YAMLError(problem^, self.line, self._column() + 1)

    @always_inline
    def _is_blank(self, b: UInt8) -> Bool:
        """Reports whether `b` is a space or a tab.

        Args:
            b: The byte to test.

        Returns:
            True for space and tab.
        """
        return b == _SPACE or b == _TAB

    @always_inline
    def _is_break(self, b: UInt8) -> Bool:
        """Reports whether `b` ends a line.

        Args:
            b: The byte to test.

        Returns:
            True for carriage return and line feed.
        """
        return b == _NEWLINE or b == _RETURN

    def _skip_blanks_inline(mut self):
        """Advances the cursor past spaces and tabs on the current line."""
        while not self._at_end() and self._is_blank(self._peek()):
            self.pos += 1

    def _at_comment(self) -> Bool:
        """Reports whether a comment starts at the cursor.

        A `#` only opens a comment at the start of a line or after whitespace,
        so `a#b` is a single plain scalar.

        Returns:
            True if the rest of the line is a comment.
        """
        if self._peek() != _HASH:
            return False
        return self.pos == self.line_start or self._is_blank(
            self._byte(self.pos - 1)
        )

    def _at_line_end(self) -> Bool:
        """Reports whether nothing but a comment remains on this line.

        Returns:
            True at end of input, at a line break, or at a comment.
        """
        return (
            self._at_end() or self._is_break(self._peek()) or self._at_comment()
        )

    def _consume_break(mut self):
        """Consumes one line ending and moves the line counter on."""
        if self._peek() == _RETURN:
            self.pos += 1
        if self._peek() == _NEWLINE:
            self.pos += 1
        self.line += 1
        self.line_start = self.pos

    def _skip_rest_of_line(mut self):
        """Discards the rest of the current line, including its ending."""
        while not self._at_end() and not self._is_break(self._peek()):
            self.pos += 1
        if not self._at_end():
            self._consume_break()

    def _find_content(mut self) raises -> Int:
        """Advances to the next content character and returns its column.

        Blank lines and comment-only lines are skipped. If the cursor already
        sits on content, it does not move.

        Returns:
            The column of the content, or -1 at end of input.

        Raises:
            `YAMLError` if a line is indented with a tab, which YAML forbids.
        """
        while True:
            var from_line_start = self.pos == self.line_start
            var saw_tab = False
            while not self._at_end() and self._is_blank(self._peek()):
                saw_tab = saw_tab or self._peek() == _TAB
                self.pos += 1
            if self._at_end():
                return -1
            if self._at_line_end():
                self._skip_rest_of_line()
                continue
            if from_line_start and saw_tab:
                raise self._error(
                    String("found a tab character where an indent is expected")
                )
            return self._column()

    def _at_document_marker(self) -> Bool:
        """Reports whether the cursor is on a `---` or `...` marker line.

        Returns:
            True if a document marker starts at column zero here.
        """
        if self._column() != 0:
            return False
        var b = self._peek()
        if b != _DASH and b != _DOT:
            return False
        if self._byte(self.pos + 1) != b or self._byte(self.pos + 2) != b:
            return False
        var after = self._byte(self.pos + 3)
        return (
            self.pos + 3 >= len(self.src)
            or self._is_blank(after)
            or self._is_break(after)
        )

    def _starts_block_entry(self) -> Bool:
        """Reports whether a `- ` block sequence entry starts at the cursor.

        Returns:
            True if the cursor is on a dash that opens an entry.
        """
        if self._peek() != _DASH:
            return False
        var after = self._byte(self.pos + 1)
        return (
            self.pos + 1 >= len(self.src)
            or self._is_blank(after)
            or self._is_break(after)
        )

    def _push_null(mut self) -> UInt32:
        """Appends an explicit null node.

        Returns:
            The index of the new node.
        """
        return self.tape.push(_Node.scalar(_KIND_NULL))

    # ===-------------------------------------------------------------------===#
    # Node properties
    # ===-------------------------------------------------------------------===#

    def _scan_name(mut self) -> String:
        """Reads an anchor or alias name at the cursor.

        Returns:
            The name, which ends at whitespace or a flow indicator.
        """
        var start = self.pos
        while not self._at_end():
            var b = self._peek()
            if (
                self._is_blank(b)
                or self._is_break(b)
                or b == _COMMA
                or b == _LBRACKET
                or b == _RBRACKET
                or b == _LBRACE
                or b == _RBRACE
            ):
                break
            self.pos += 1
        return String(unsafe_from_utf8=self.src[start : self.pos])

    def _parse_properties(mut self) raises -> _Properties:
        """Consumes any `&anchor` and `!tag` in front of a node.

        Returns:
            What was found, with empty strings for what was not.

        Raises:
            If an anchor or tag is malformed.
        """
        var props = _Properties(String(), String())
        while True:
            var b = self._peek()
            if b == _AMPERSAND:
                self.pos += 1
                props.anchor = self._scan_name()
                if props.anchor.byte_length() == 0:
                    raise self._error(String("expected an anchor name"))
            elif b == _BANG:
                self.pos += 1
                if self._peek() == _BANG:
                    self.pos += 1
                    props.tag = "!!" + self._scan_name()
                else:
                    props.tag = "!" + self._scan_name()
            else:
                return props^
            self._skip_blanks_inline()

    def _register_anchor(mut self, props: _Properties, node: UInt32):
        """Records `node` under the anchor in `props`, if there is one.

        Args:
            props: The properties parsed in front of the node.
            node: The node the anchor names.
        """
        if props.anchor.byte_length():
            self.anchors[props.anchor] = node

    # ===-------------------------------------------------------------------===#
    # Entry points
    # ===-------------------------------------------------------------------===#

    def parse_documents(mut self) raises -> List[UInt32]:
        """Parses every document in the stream.

        Returns:
            The root node of each document, in order.

        Raises:
            `YAMLError` if the stream is not valid YAML.
        """
        var roots = List[UInt32]()
        var saw_marker = False

        while True:
            var col = self._find_content()
            if col < 0:
                break
            if self._at_document_marker():
                var is_end = self._peek() == _DOT
                self.pos += 3
                if is_end:
                    self._skip_rest_of_line()
                    continue
                saw_marker = True
                self.anchors.clear()
                self._skip_blanks_inline()
                roots.append(self._parse_node(-1, 0))
                continue
            if roots and not saw_marker:
                raise self._error(String("expected a single document"))
            roots.append(self._parse_node(-1, 0))
            saw_marker = False

        if not roots:
            roots.append(self._push_null())
        return roots^

    # ===-------------------------------------------------------------------===#
    # Nodes
    # ===-------------------------------------------------------------------===#

    def _parse_node(
        mut self,
        parent_indent: Int,
        depth: Int,
        *,
        inline_after_key: Bool = False,
        allow_next_line: Bool = True,
        seq_entry: Bool = False,
    ) raises -> UInt32:
        """Parses one node, wherever it starts.

        This is the single recursive hub of the block parser: everything that
        needs a nested node — a mapping value, a sequence entry, a document
        root — calls it, and the collection routines call it back. Nesting
        depth travels as an argument rather than as parser state so that the
        recursion cycle stays exactly two functions long; a longer cycle makes
        the Mojo elaborator hang.

        Args:
            parent_indent: The column of the construct that owns this node. A
                multi-line plain scalar may not dedent to or past it, and a
                block collection on a later line must be indented past it.
            depth: How deeply nested this node is.
            inline_after_key: Whether the cursor follows a colon on the same
                line, where a block collection cannot start.
            allow_next_line: Whether the node may begin on a later line when
                nothing follows on this one.
            seq_entry: Whether this node belongs to a `-`, which cannot own a
                sequence sitting at the dash's own column.

        Returns:
            The index of the node.

        Raises:
            `YAMLError` if the node is malformed.
        """
        if depth > MAX_DEPTH:
            raise self._error(
                String("exceeded maximum nesting depth of ", MAX_DEPTH)
            )

        var same_line = inline_after_key
        self._skip_blanks_inline()

        if self._at_line_end():
            if not allow_next_line:
                return self._push_null()
            var found = self._find_content()
            if found < 0 or self._at_document_marker():
                return self._push_null()
            if seq_entry:
                if found <= parent_indent:
                    return self._push_null()
            elif found <= parent_indent:
                # A block sequence may sit at the same column as the key that
                # owns it, so that case falls through to the sequence branch
                # below. Anything else at or left of the parent belongs to the
                # parent, so this node is empty.
                if not (found == parent_indent and self._starts_block_entry()):
                    return self._push_null()
            same_line = False

        var col = self._column()

        if self._peek() == _STAR:
            self.pos += 1
            var name = self._scan_name()
            var target = self.anchors.get(name)
            if not target:
                raise self._error(String("found undefined alias '", name, "'"))
            return target.value()

        var props = self._parse_properties()
        if self._at_line_end():
            # Only properties on this line; the content follows below.
            var inner = self._parse_node(parent_indent, depth + 1)
            self._register_anchor(props, inner)
            return self._apply_tag(props, inner)

        var node: UInt32
        if not same_line and self._starts_block_entry():
            # A block sequence, inlined rather than delegated: keeping this
            # loop inside the hub holds the recursion cycle to two functions.
            node = self.tape.new_container(_KIND_ARRAY)
            while True:
                var at = self._find_content()
                if at != col or self._at_document_marker():
                    break
                if not self._starts_block_entry():
                    break
                self.pos += 1  # the dash
                var item = self._parse_node(col, depth + 1, seq_entry=True)
                self.tape.array_push(node, item)
        elif not same_line and self._looks_like_key():
            node = self._parse_block_mapping(col, depth)
        else:
            if same_line and self._looks_like_key():
                raise self._error(String("mapping values are not allowed here"))
            node = self._parse_scalar_node(parent_indent, props.tag, depth)

        self._register_anchor(props, node)
        return self._apply_tag(props, node)

    def _apply_tag(mut self, props: _Properties, node: UInt32) raises -> UInt32:
        """Re-types `node` according to an explicit tag, if there is one.

        Args:
            props: The properties parsed in front of the node.
            node: The node the tag applies to.

        Returns:
            The node, possibly replaced by a re-typed one.

        Raises:
            If the tag cannot be applied to this node.
        """
        if props.tag.byte_length() == 0:
            return node
        return self._retag(props.tag, node)

    # ===-------------------------------------------------------------------===#
    # Block collections
    # ===-------------------------------------------------------------------===#

    def _parse_block_mapping(
        mut self, indent: Int, depth: Int
    ) raises -> UInt32:
        """Parses a block mapping whose keys sit at column `indent`.

        Merge keys are collected as they are seen and applied first, so an
        explicit member always wins over a merged one — the order PyYAML
        produces.

        Args:
            indent: The column of the mapping's keys.
            depth: How deeply nested this mapping is.

        Returns:
            The index of the new mapping node.

        Raises:
            `YAMLError` if a member is malformed.
        """
        var keys = List[String]()
        var values = List[UInt32]()
        var merges = List[UInt32]()

        while True:
            var col = self._find_content()
            if col != indent or self._at_document_marker():
                break
            if self._starts_block_entry():
                break

            if self._peek() == _QUESTION and self._is_blank(
                self._byte(self.pos + 1)
            ):
                self.pos += 1
                var key_node = self._parse_node(indent, depth + 1)
                var explicit = self._key_text(key_node)
                var found = self._find_content()
                if found == indent and self._peek() == _COLON:
                    self.pos += 1
                    keys.append(explicit^)
                    values.append(
                        self._parse_node(
                            indent, depth + 1, inline_after_key=True
                        )
                    )
                else:
                    keys.append(explicit^)
                    values.append(self._push_null())
                continue

            var key_node = self._parse_key_node(indent, depth)
            self._skip_blanks_inline()
            if self._peek() != _COLON:
                raise self._error(String("could not find expected ':'"))
            self.pos += 1

            var value = self._parse_node(
                indent, depth + 1, inline_after_key=True
            )
            if self._is_merge_key(key_node):
                merges.append(value)
            else:
                keys.append(self._key_text(key_node))
                values.append(value)

        var node = self.tape.new_container(_KIND_OBJECT)
        for i in range(len(merges)):
            self._merge_into(node, merges[i])
        for i in range(len(keys)):
            self._put(node, keys[i], values[i])
        return node

    def _put(mut self, node: UInt32, key: StringSlice, value: UInt32):
        """Stores one member, replacing any earlier one with the same key.

        Args:
            node: The mapping node.
            key: The member name.
            value: The member's value node.
        """
        var pos = self.tape.find_member(node, key.as_bytes())
        if pos >= 0:
            var start = Int(self.tape.nodes[Int(node)].a)
            self.tape.kids[start + 2 * pos + 1] = value
            return
        var key_node = self.tape.push_string(key.as_bytes())
        self.tape.object_push(node, key_node, value)

    def _merge_into(mut self, node: UInt32, source: UInt32) raises:
        """Copies the members of `source` into `node`.

        Args:
            node: The mapping being built.
            source: A mapping, or a sequence of mappings, to merge in.

        Raises:
            If `source` is not a mapping or a sequence of mappings.
        """
        var kind = self.tape.nodes[Int(source)].kind
        if kind == _KIND_ARRAY:
            # PyYAML reverses a list of merge sources before applying it, so
            # the first mapping in the list wins over the later ones.
            var info = self.tape.nodes[Int(source)]
            for i in reversed(range(Int(info.b))):
                self._merge_into(node, self.tape.kids[Int(info.a) + i])
            return
        if kind != _KIND_OBJECT:
            raise self._error(
                String("expected a mapping or a list of mappings for merging")
            )
        var info = self.tape.nodes[Int(source)]
        for i in range(Int(info.b)):
            var key = self.tape.kids[Int(info.a) + 2 * i]
            var value = self.tape.kids[Int(info.a) + 2 * i + 1]
            var text = String(unsafe_from_utf8=self.tape.str_bytes(key))
            self._put(node, text, value)

    def _is_merge_key(self, node: UInt32) -> Bool:
        """Reports whether `node` is the `<<` merge key.

        Args:
            node: The key node.

        Returns:
            True if the key is exactly `<<`.
        """
        if self.tape.nodes[Int(node)].kind != _KIND_STRING:
            return False
        var bytes = self.tape.str_bytes(node)
        return len(bytes) == 2 and bytes[0] == _LT and bytes[1] == _LT

    def _key_text(mut self, node: UInt32) raises -> String:
        """Renders a key node as the text used to index the mapping.

        Mapping keys are always strings here, so a key that resolved to a
        number, a boolean or `null` is written the way JSON would write it.
        That keeps a loaded document indexable and dumpable as JSON.

        Args:
            node: The key node.

        Returns:
            The member name.

        Raises:
            If the key cannot be rendered.
        """
        if self.tape.nodes[Int(node)].kind == _KIND_STRING:
            return String(unsafe_from_utf8=self.tape.str_bytes(node))
        var out = String()
        write_value(
            out,
            self.tape,
            node,
            EncodeOptions(separators=(String(","), String(":"))),
        )
        return out^

    def _parse_key_node(mut self, indent: Int, depth: Int) raises -> UInt32:
        """Parses the key part of a block mapping member.

        Args:
            indent: The column of the mapping's keys.
            depth: How deeply nested the mapping is.

        Returns:
            The index of the key's node.

        Raises:
            `YAMLError` if the key is malformed.
        """
        var b = self._peek()
        if b == _SQUOTE:
            return self.tape.push_string(self._scan_single_quoted().as_bytes())
        if b == _DQUOTE:
            return self.tape.push_string(self._scan_double_quoted().as_bytes())
        if b == _LBRACKET or b == _LBRACE:
            return self._parse_flow_node(depth + 1)
        var text = self._scan_plain(indent, in_flow=False)
        return resolve_plain(self.tape, text)

    def _looks_like_key(mut self) -> Bool:
        """Reports whether the current line opens a block mapping member.

        Scans a candidate key and checks for the `:` that would follow it. The
        cursor is restored either way.

        Returns:
            True if an implicit key starts at the cursor.
        """
        var save_pos = self.pos
        var save_line = self.line
        var save_start = self.line_start
        var found = self._scan_key_candidate()
        self.pos = save_pos
        self.line = save_line
        self.line_start = save_start
        return found

    def _scan_key_candidate(mut self) -> Bool:
        """Advances over a possible implicit key and reports whether one is
        there.

        Returns:
            True if a `:` delimiter follows the candidate on this line.
        """
        var b = self._peek()
        if b == _QUESTION and self._is_blank(self._byte(self.pos + 1)):
            return True
        if b == _SQUOTE or b == _DQUOTE:
            if not self._skip_quoted_on_line(b):
                return False
        elif b == _LBRACKET or b == _LBRACE:
            if not self._skip_flow_on_line():
                return False
        else:
            while not self._at_end():
                var c = self._peek()
                if self._is_break(c):
                    return False
                if c == _COLON:
                    var after = self._byte(self.pos + 1)
                    if (
                        self.pos + 1 >= len(self.src)
                        or self._is_blank(after)
                        or self._is_break(after)
                    ):
                        return True
                if self._at_comment():
                    return False
                self.pos += 1
            return False
        self._skip_blanks_inline()
        if self._peek() != _COLON:
            return False
        var after = self._byte(self.pos + 1)
        return (
            self.pos + 1 >= len(self.src)
            or self._is_blank(after)
            or self._is_break(after)
        )

    def _skip_quoted_on_line(mut self, quote: UInt8) -> Bool:
        """Advances past a quoted scalar that must close on this line.

        Args:
            quote: The opening quote character.

        Returns:
            True if the scalar closed on this line.
        """
        self.pos += 1
        while not self._at_end():
            var c = self._peek()
            if self._is_break(c):
                return False
            if c == _BACKSLASH and quote == _DQUOTE:
                self.pos += 2
                continue
            if c == quote:
                if quote == _SQUOTE and self._byte(self.pos + 1) == _SQUOTE:
                    self.pos += 2
                    continue
                self.pos += 1
                return True
            self.pos += 1
        return False

    def _skip_flow_on_line(mut self) -> Bool:
        """Advances past a balanced flow collection on this line.

        Returns:
            True if the collection closed on this line.
        """
        var depth = 0
        while not self._at_end():
            var c = self._peek()
            if self._is_break(c):
                return False
            if c == _LBRACKET or c == _LBRACE:
                depth += 1
            elif c == _RBRACKET or c == _RBRACE:
                depth -= 1
                if depth == 0:
                    self.pos += 1
                    return True
            elif c == _SQUOTE or c == _DQUOTE:
                if not self._skip_quoted_on_line(c):
                    return False
                continue
            self.pos += 1
        return False

    # ===-------------------------------------------------------------------===#
    # Scalars
    # ===-------------------------------------------------------------------===#

    def _parse_scalar_node(
        mut self, parent_indent: Int, tag: StringSlice, depth: Int
    ) raises -> UInt32:
        """Parses a scalar or a flow collection at the cursor.

        Args:
            parent_indent: The column bounding how far a multi-line plain
                scalar may be dedented.
            tag: The explicit tag in front of the node, if any. A tagged plain
                scalar keeps its literal text so the tag decides its type,
                which is why `!!str 0x10` stays `"0x10"`.
            depth: How deeply nested this scalar is.

        Returns:
            The index of the new node.

        Raises:
            `YAMLError` if the scalar is malformed.
        """
        var b = self._peek()
        if b == _PIPE or b == _GT:
            var text = self._scan_block_scalar(b == _GT, parent_indent)
            return self.tape.push_string(text.as_bytes())
        if b == _SQUOTE:
            var text = self._scan_single_quoted()
            return self.tape.push_string(text.as_bytes())
        if b == _DQUOTE:
            var text = self._scan_double_quoted()
            return self.tape.push_string(text.as_bytes())
        if b == _LBRACKET or b == _LBRACE:
            return self._parse_flow_node(depth + 1)

        var text = self._scan_plain(parent_indent, in_flow=False)
        if tag.byte_length():
            return self.tape.push_string(text.as_bytes())
        return resolve_plain(self.tape, text)

    def _trimmed(self, start: Int, end: Int) -> StringSlice[ImmUntrackedOrigin]:
        """Returns `src[start:end]` without trailing spaces and tabs.

        Args:
            start: The first byte of the run.
            end: One past the last byte of the run.

        Returns:
            The trimmed slice.
        """
        var stop = end
        while stop > start and self._is_blank(self.src[stop - 1]):
            stop -= 1
        return StringSlice(unsafe_from_utf8=self.src[start:stop])

    def _scan_plain(
        mut self, parent_indent: Int, *, in_flow: Bool
    ) raises -> String:
        """Reads a plain scalar, folding any continuation lines.

        Args:
            parent_indent: The column a continuation line must exceed.
            in_flow: Whether the scalar sits inside a flow collection, where
                the flow indicators end it.

        Returns:
            The scalar's text.

        Raises:
            `YAMLError` if the scalar is malformed.
        """
        var folder = _Folder()
        while True:
            var start = self.pos
            while not self._at_end():
                var c = self._peek()
                if self._is_break(c) or self._at_comment():
                    break
                if in_flow and (
                    c == _COMMA
                    or c == _LBRACKET
                    or c == _RBRACKET
                    or c == _LBRACE
                    or c == _RBRACE
                ):
                    break
                if c == _COLON and self._colon_ends_plain(in_flow):
                    break
                self.pos += 1
            folder.add_line(self._trimmed(start, self.pos))

            var save_pos = self.pos
            var save_line = self.line
            var save_start = self.line_start
            self._skip_blanks_inline()
            if (
                self._at_comment()
                or self._at_end()
                or not self._is_break(self._peek())
            ):
                self.pos = save_pos
                self.line = save_line
                self.line_start = save_start
                break

            var breaks = 0
            while not self._at_end():
                if self._is_break(self._peek()):
                    self._consume_break()
                    breaks += 1
                    self._skip_blanks_inline()
                    continue
                break

            var stop = self._at_end() or self._at_comment()
            if not stop:
                if in_flow:
                    var c = self._peek()
                    stop = (
                        c == _COMMA
                        or c == _RBRACKET
                        or c == _RBRACE
                        or c == _LBRACKET
                        or c == _LBRACE
                    )
                else:
                    stop = (
                        self._column() <= parent_indent
                        or self._at_document_marker()
                        or self._starts_block_entry()
                        or self._looks_like_key()
                    )
            if stop:
                self.pos = save_pos
                self.line = save_line
                self.line_start = save_start
                break
            folder.add_breaks(breaks)

        return folder^.take()

    def _colon_ends_plain(self, in_flow: Bool) -> Bool:
        """Reports whether the colon at the cursor terminates a plain scalar.

        Args:
            in_flow: Whether the scalar sits inside a flow collection.

        Returns:
            True if the colon acts as a key delimiter rather than text.
        """
        var after = self._byte(self.pos + 1)
        if (
            self.pos + 1 >= len(self.src)
            or self._is_blank(after)
            or self._is_break(after)
        ):
            return True
        if in_flow:
            return after == _COMMA or after == _RBRACKET or after == _RBRACE
        return False

    def _scan_single_quoted(mut self) raises -> String:
        """Reads a single-quoted scalar, in which `''` means one quote.

        Returns:
            The scalar's text.

        Raises:
            `YAMLError` if the scalar never closes.
        """
        self.pos += 1
        var folder = _Folder()
        var line = List[UInt8]()
        while True:
            if self._at_end():
                raise self._error(
                    String(
                        "found unexpected end of stream while scanning a quoted"
                        " scalar"
                    )
                )
            var c = self._peek()
            if c == _SQUOTE:
                if self._byte(self.pos + 1) == _SQUOTE:
                    line.append(_SQUOTE)
                    self.pos += 2
                    continue
                self.pos += 1
                break
            if self._is_break(c):
                folder.add_line(_trim_trailing(Span(line)))
                line.clear()
                var breaks = 0
                while not self._at_end() and self._is_break(self._peek()):
                    self._consume_break()
                    breaks += 1
                    self._skip_blanks_inline()
                folder.add_breaks(breaks)
                continue
            line.append(c)
            self.pos += 1
        folder.add_line(StringSlice(unsafe_from_utf8=Span(line)))
        return folder^.take()

    def _scan_double_quoted(mut self) raises -> String:
        """Reads a double-quoted scalar, decoding its escapes.

        Returns:
            The scalar's text.

        Raises:
            `YAMLError` if the scalar never closes or holds a bad escape.
        """
        self.pos += 1
        var folder = _Folder()
        var line = List[UInt8]()
        while True:
            if self._at_end():
                raise self._error(
                    String(
                        "found unexpected end of stream while scanning a quoted"
                        " scalar"
                    )
                )
            var c = self._peek()
            if c == _DQUOTE:
                self.pos += 1
                break
            if c == _BACKSLASH:
                if self._is_break(self._byte(self.pos + 1)):
                    # An escaped line break joins the lines with nothing
                    # between them.
                    self.pos += 1
                    self._consume_break()
                    self._skip_blanks_inline()
                    continue
                self._decode_escape(line)
                continue
            if self._is_break(c):
                folder.add_line(_trim_trailing(Span(line)))
                line.clear()
                var breaks = 0
                while not self._at_end() and self._is_break(self._peek()):
                    self._consume_break()
                    breaks += 1
                    self._skip_blanks_inline()
                folder.add_breaks(breaks)
                continue
            line.append(c)
            self.pos += 1
        folder.add_line(StringSlice(unsafe_from_utf8=Span(line)))
        return folder^.take()

    def _decode_escape(mut self, mut out: List[UInt8]) raises:
        """Consumes one `\\`-escape and appends what it stands for.

        Args:
            out: The buffer collecting the current line's bytes.

        Raises:
            `YAMLError` if the escape is not one YAML defines.
        """
        var e = self._byte(self.pos + 1)
        self.pos += 2
        if e == 0x30:  # 0
            out.append(0)
        elif e == 0x61:  # a
            out.append(0x07)
        elif e == 0x62:  # b
            out.append(0x08)
        elif e == 0x74 or e == _TAB:  # t
            out.append(0x09)
        elif e == 0x6E:  # n
            out.append(0x0A)
        elif e == 0x76:  # v
            out.append(0x0B)
        elif e == 0x66:  # f
            out.append(0x0C)
        elif e == 0x72:  # r
            out.append(0x0D)
        elif e == 0x65:  # e
            out.append(0x1B)
        elif e == _SPACE or e == _DQUOTE or e == _BACKSLASH or e == 0x2F:
            out.append(e)
        elif e == 0x4E:  # N, next line
            out.append(0xC2)
            out.append(0x85)
        elif e == 0x5F:  # _, non-breaking space
            out.append(0xC2)
            out.append(0xA0)
        elif e == 0x4C:  # L, line separator
            _append_utf8(out, 0x2028)
        elif e == 0x50:  # P, paragraph separator
            _append_utf8(out, 0x2029)
        elif e == 0x78:  # x
            _append_utf8(out, self._read_hex(2))
        elif e == 0x75:  # u
            _append_utf8(out, self._read_hex(4))
        elif e == 0x55:  # U
            _append_utf8(out, self._read_hex(8))
        else:
            raise self._error(String("found unknown escape character"))

    def _read_hex(mut self, count: Int) raises -> Int:
        """Reads `count` hexadecimal digits.

        Args:
            count: How many digits the escape carries.

        Returns:
            The scalar value they encode.

        Raises:
            `YAMLError` if fewer digits are present or one is not hexadecimal.
        """
        if self.pos + count > len(self.src):
            raise self._error(
                String("expected ", count, " hexadecimal digits in an escape")
            )
        var value = 0
        for i in range(count):
            var b = self._byte(self.pos + i)
            var digit: Int
            if b >= 0x30 and b <= 0x39:
                digit = Int(b - 0x30)
            elif b >= 0x61 and b <= 0x66:
                digit = Int(b - 0x61) + 10
            elif b >= 0x41 and b <= 0x46:
                digit = Int(b - 0x41) + 10
            else:
                raise self._error(
                    String("expected a hexadecimal digit in an escape")
                )
            value = value * 16 + digit
        self.pos += count
        return value

    def _scan_block_scalar(
        mut self, folded: Bool, parent_indent: Int
    ) raises -> String:
        """Reads a `|` literal or `>` folded block scalar.

        Args:
            folded: Whether line breaks fold into spaces.
            parent_indent: The column of the construct that owns this scalar,
                used when the header states the indent explicitly.

        Returns:
            The scalar's text.

        Raises:
            `YAMLError` if the header is malformed.
        """
        self.pos += 1  # the indicator
        var chomp = _CHOMP_CLIP
        var explicit_indent = 0
        while not self._at_end():
            var b = self._peek()
            if b == _DASH:
                chomp = _CHOMP_STRIP
            elif b == _PLUS:
                chomp = _CHOMP_KEEP
            elif b >= 0x31 and b <= 0x39:
                explicit_indent = Int(b - 0x30)
            else:
                break
            self.pos += 1
        self._skip_blanks_inline()
        if not self._at_line_end():
            raise self._error(
                String(
                    "expected a comment or a line break in a block scalar"
                    " header"
                )
            )
        self._skip_rest_of_line()

        var content_indent = 0
        if explicit_indent:
            content_indent = max(parent_indent, 0) + explicit_indent
        else:
            # The indent is whatever the first non-empty line uses.
            var probe_pos = self.pos
            var probe_line = self.line
            var probe_start = self.line_start
            while not self._at_end():
                self._skip_blanks_inline()
                if self._at_end():
                    break
                if self._is_break(self._peek()):
                    self._consume_break()
                    continue
                content_indent = self._column()
                break
            self.pos = probe_pos
            self.line = probe_line
            self.line_start = probe_start
            if content_indent <= parent_indent:
                content_indent = parent_indent + 1

        var lines = List[String]()
        var more_indented = List[Bool]()
        while not self._at_end():
            var line_begin = self.pos
            self._skip_blanks_inline()
            var indent = self._column()
            if self._at_end():
                break
            if self._is_break(self._peek()):
                self.pos = line_begin
                self._skip_rest_of_line()
                lines.append(String())
                more_indented.append(False)
                continue
            if indent < content_indent:
                self.pos = line_begin
                break
            self.pos = line_begin + content_indent
            var start = self.pos
            while not self._at_end() and not self._is_break(self._peek()):
                self.pos += 1
            lines.append(String(unsafe_from_utf8=self.src[start : self.pos]))
            more_indented.append(indent > content_indent)
            if not self._at_end():
                self._consume_break()

        return _assemble_block(lines, more_indented, folded, chomp)

    # ===-------------------------------------------------------------------===#
    # Flow collections
    # ===-------------------------------------------------------------------===#

    def _skip_flow_space(mut self):
        """Advances past whitespace, line breaks and comments inside flow."""
        while not self._at_end():
            self._skip_blanks_inline()
            if self._at_comment():
                self._skip_rest_of_line()
                continue
            if self._is_break(self._peek()):
                self._consume_break()
                continue
            return

    def _parse_flow_node(mut self, depth: Int) raises -> UInt32:
        """Parses one node inside a flow collection.

        Args:
            depth: How deeply nested this node is.

        Returns:
            The index of the node.

        Raises:
            `YAMLError` if the node is malformed.
        """
        if depth > MAX_DEPTH:
            raise self._error(
                String("exceeded maximum nesting depth of ", MAX_DEPTH)
            )
        self._skip_flow_space()
        if self._peek() == _STAR:
            self.pos += 1
            var name = self._scan_name()
            var target = self.anchors.get(name)
            if not target:
                raise self._error(String("found undefined alias '", name, "'"))
            return target.value()

        var props = self._parse_properties()
        self._skip_flow_space()
        var b = self._peek()
        var node: UInt32
        if b == _LBRACKET:
            node = self._parse_flow_sequence(depth + 1)
        elif b == _LBRACE:
            node = self._parse_flow_mapping(depth + 1)
        elif b == _SQUOTE:
            var text = self._scan_single_quoted()
            node = self.tape.push_string(text.as_bytes())
        elif b == _DQUOTE:
            var text = self._scan_double_quoted()
            node = self.tape.push_string(text.as_bytes())
        else:
            var text = self._scan_plain(-1, in_flow=True)
            if props.tag.byte_length():
                node = self.tape.push_string(text.as_bytes())
            else:
                node = resolve_plain(self.tape, text)
        self._register_anchor(props, node)
        return self._apply_tag(props, node)

    def _parse_flow_sequence(mut self, depth: Int) raises -> UInt32:
        """Parses a `[...]` flow sequence.

        Returns:
            The index of the new sequence node.

        Raises:
            `YAMLError` if the sequence is malformed.
        """
        self.pos += 1  # the bracket
        var node = self.tape.new_container(_KIND_ARRAY)
        while True:
            self._skip_flow_space()
            if self._at_end():
                raise self._error(
                    String("expected ',' or ']', but found end of stream")
                )
            if self._peek() == _RBRACKET:
                self.pos += 1
                break
            var item = self._parse_flow_node(depth + 1)
            self._skip_flow_space()
            if self._peek() == _COLON and self._colon_ends_plain(True):
                # `[a: 1]` is a sequence holding a one-member mapping.
                self.pos += 1
                self._skip_flow_space()
                var value: UInt32
                if self._peek() == _COMMA or self._peek() == _RBRACKET:
                    value = self._push_null()
                else:
                    value = self._parse_flow_node(depth + 1)
                var pair = self.tape.new_container(_KIND_OBJECT)
                var key_text = self._key_text(item)
                self._put(pair, key_text, value)
                item = pair
                self._skip_flow_space()
            self.tape.array_push(node, item)
            if self._peek() == _COMMA:
                self.pos += 1
                continue
            if self._peek() == _RBRACKET:
                self.pos += 1
                break
            raise self._error(String("expected ',' or ']'"))
        return node

    def _parse_flow_mapping(mut self, depth: Int) raises -> UInt32:
        """Parses a `{...}` flow mapping.

        Returns:
            The index of the new mapping node.

        Raises:
            `YAMLError` if the mapping is malformed.
        """
        self.pos += 1  # the brace
        var keys = List[String]()
        var values = List[UInt32]()
        var merges = List[UInt32]()

        while True:
            self._skip_flow_space()
            if self._at_end():
                raise self._error(
                    String("expected ',' or '}', but found end of stream")
                )
            if self._peek() == _RBRACE:
                self.pos += 1
                break

            var key_node = self._parse_flow_node(depth + 1)
            self._skip_flow_space()
            var value: UInt32
            if self._peek() == _COLON:
                self.pos += 1
                self._skip_flow_space()
                if self._peek() == _COMMA or self._peek() == _RBRACE:
                    value = self._push_null()
                else:
                    value = self._parse_flow_node(depth + 1)
            else:
                value = self._push_null()

            if self._is_merge_key(key_node):
                merges.append(value)
            else:
                keys.append(self._key_text(key_node))
                values.append(value)

            self._skip_flow_space()
            if self._peek() == _COMMA:
                self.pos += 1
                continue
            if self._peek() == _RBRACE:
                self.pos += 1
                break
            raise self._error(String("expected ',' or '}'"))

        var node = self.tape.new_container(_KIND_OBJECT)
        for i in range(len(merges)):
            self._merge_into(node, merges[i])
        for i in range(len(keys)):
            self._put(node, keys[i], values[i])
        return node

    # ===-------------------------------------------------------------------===#
    # Tags
    # ===-------------------------------------------------------------------===#

    def _retag(mut self, tag: StringSlice, node: UInt32) raises -> UInt32:
        """Re-types `node` for one of the standard `!!` tags.

        Tags this library has no type for — `!!binary`, `!!timestamp`,
        `!!set`, `!!omap` and any application tag — leave the node alone.

        Args:
            tag: The tag as written.
            node: The node it applies to.

        Returns:
            The re-typed node.

        Raises:
            If the node cannot be read as the tag demands.
        """
        if tag == "!!str":
            if self.tape.nodes[Int(node)].kind == _KIND_STRING:
                return node
            var text = self._key_text(node)
            return self.tape.push_string(text.as_bytes())
        if tag == "!!null":
            return self._push_null()
        if tag == "!!bool" or tag == "!!int" or tag == "!!float":
            var text = self._key_text(node)
            var resolved = resolve_plain(self.tape, text)
            var kind = self.tape.nodes[Int(resolved)].kind
            if tag == "!!bool" and kind != 1:
                raise self._error(
                    String("could not read '", text, "' as a boolean")
                )
            if tag == "!!int" and kind != 2:
                raise self._error(
                    String("could not read '", text, "' as an integer")
                )
            if tag == "!!float":
                if kind == 2:
                    var whole = Float64(
                        Int64(self.tape.nodes[Int(resolved)].num)
                    )
                    return self.tape.push(
                        _Node.scalar(3, whole.to_bits[DType.uint64]())
                    )
                if kind != 3:
                    raise self._error(
                        String("could not read '", text, "' as a float")
                    )
            return resolved
        return node


struct _Folder(Movable):
    """Joins the lines of a multi-line scalar the way YAML folds them.

    A single line break becomes a space; `n` consecutive breaks become `n - 1`
    newlines, so one blank line between two lines yields exactly one newline.
    """

    var text: String
    """What has been folded so far."""

    var started: Bool
    """Whether any content line has been added yet."""

    var breaks: Int
    """Line breaks seen since the last content line."""

    def __init__(out self):
        """Creates an empty folder."""
        self.text = String()
        self.started = False
        self.breaks = 0

    def add_breaks(mut self, count: Int):
        """Records `count` line breaks before the next content line.

        Args:
            count: How many line breaks were consumed.
        """
        self.breaks += count

    def take(deinit self) -> String:
        """Consumes the folder and hands back what it built.

        Returns:
            The folded text.
        """
        return self.text^

    def add_line(mut self, line: StringSlice):
        """Appends one content line.

        Args:
            line: The line's text, already stripped of surrounding blanks.
        """
        if not self.started:
            self.text = String(line)
            self.started = True
            self.breaks = 0
            return
        if self.breaks == 1:
            self.text += " "
        elif self.breaks > 1:
            for _ in range(self.breaks - 1):
                self.text += "\n"
        self.text += line
        self.breaks = 0


def _trim_trailing[
    origin: ImmOrigin, //
](bytes: Span[UInt8, origin]) -> StringSlice[origin]:
    """Returns `bytes` without its trailing spaces and tabs.

    Only whitespace next to a line break is dropped when a scalar folds, so
    this is used where a line ends, never on the content as a whole: a quoted
    scalar keeps the blanks at the very start and end of its text.

    Parameters:
        origin: The origin of the bytes.

    Args:
        bytes: The line to trim.

    Returns:
        The trimmed text.
    """
    var stop = len(bytes)
    while stop > 0 and (bytes[stop - 1] == _SPACE or bytes[stop - 1] == _TAB):
        stop -= 1
    return StringSlice(unsafe_from_utf8=bytes[0:stop])


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


def _assemble_block(
    lines: List[String], more_indented: List[Bool], folded: Bool, chomp: Int
) -> String:
    """Joins a block scalar's lines and applies its chomping indicator.

    Args:
        lines: The content lines, already stripped of the block's indent.
        more_indented: Whether each line was indented past the block's indent,
            which stops folding across it.
        folded: Whether this is a `>` scalar rather than a `|` scalar.
        chomp: `-1` to strip trailing newlines, `1` to keep them all, `0` to
            keep exactly one.

    Returns:
        The scalar's text.
    """
    # Trailing empty lines belong to the chomping decision, not the content.
    var last = len(lines)
    while last > 0 and lines[last - 1].byte_length() == 0:
        last -= 1
    var trailing = len(lines) - last

    var out = String()
    var started = False
    var pending = 0
    for i in range(last):
        if lines[i].byte_length() == 0:
            pending += 1
            continue
        if not started:
            out += lines[i]
            started = True
        else:
            var keep_break = (
                not folded or more_indented[i] or more_indented[i - 1]
            )
            if pending == 0 and not keep_break:
                out += " "
            else:
                var count = max(pending, 1) if keep_break else pending
                for _ in range(count):
                    out += "\n"
            out += lines[i]
        pending = 0

    if not started:
        # Nothing but empty lines.
        if chomp == _CHOMP_KEEP:
            for _ in range(trailing):
                out += "\n"
        return out^

    if chomp == _CHOMP_STRIP:
        return out^
    if chomp == _CHOMP_KEEP:
        for _ in range(trailing + 1):
            out += "\n"
        return out^
    out += "\n"
    return out^
