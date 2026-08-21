"""The format parameters a reader and a writer share.

CPython passes these as loose keyword arguments and lets a named dialect
supply the defaults. Here they are the fields of one struct, so
`csv.reader(f, delimiter=";")` becomes `reader(text, Dialect(delimiter=";"))`
and the three dialects CPython registers are the `excel`, `excel_tab` and
`unix` factories.
"""

from .errors import CSVError

comptime QUOTE_MINIMAL = 0
"""Quote only the fields that need it. The default."""

comptime QUOTE_ALL = 1
"""Quote every field."""

comptime QUOTE_NONNUMERIC = 2
"""Quote every field that is not a number.

On the way in this asks the reader to read unquoted fields as numbers, which
is the one place a `Dialect` changes what a field's text looks like.
"""

comptime QUOTE_NONE = 3
"""Never quote; reach for `escapechar` instead."""

comptime FIELD_SIZE_LIMIT = 131072
"""How many characters one field may hold, matching `csv.field_size_limit()`.

CPython keeps this in a module-level variable that `csv.field_size_limit()`
reads and writes. Here it is the default of a `Dialect` field, so a reader
that has to take a wider field says so locally instead of globally.
"""


def _one_character(name: StringSlice, text: StringSlice) raises -> UInt32:
    """Decodes a format parameter that must be exactly one character.

    Args:
        name: The parameter's name, for the error message.
        text: What the caller passed.

    Returns:
        The character's codepoint.

    Raises:
        If `text` is not exactly one character, with CPython's wording.
    """
    var bytes = text.as_bytes()
    var n = len(bytes)
    if n == 0:
        raise CSVError(String('"', name, '" must be a 1-character string'))
    var first = bytes[0]
    var width: Int
    var value: UInt32
    if first < 0x80:
        width = 1
        value = UInt32(first)
    elif first < 0xE0:
        width = 2
        value = UInt32(first & 0x1F)
    elif first < 0xF0:
        width = 3
        value = UInt32(first & 0x0F)
    else:
        width = 4
        value = UInt32(first & 0x07)
    if n != width:
        raise CSVError(String('"', name, '" must be a 1-character string'))
    for i in range(1, width):
        value = (value << 6) | UInt32(bytes[i] & 0x3F)
    return value


struct Dialect(Copyable, ImplicitlyCopyable, Movable):
    """One set of format parameters, resolved and validated once."""

    var delimiter: UInt32
    """The character that separates fields."""

    var quotechar: UInt32
    """The character that quotes a field, meaningful when `has_quotechar`."""

    var has_quotechar: Bool
    """Whether a quote character is set at all."""

    var escapechar: UInt32
    """The escape character, meaningful when `has_escapechar`."""

    var has_escapechar: Bool
    """Whether an escape character is set at all."""

    var doublequote: Bool
    """Whether a quote inside a quoted field is written as two."""

    var skipinitialspace: Bool
    """Whether spaces right after a delimiter are dropped."""

    var lineterminator: String
    """What the writer puts at the end of a row."""

    var quoting: Int
    """One of the `QUOTE_*` constants."""

    var strict: Bool
    """Whether a malformed record raises instead of being read as it stands."""

    var field_size_limit: Int
    """How many characters one field may hold before the reader gives up."""

    def __init__(out self):
        """Builds the `excel` dialect, which needs no validation.

        This is the default everywhere a dialect is optional, and the reason
        it exists apart from the keyword constructor is that Mojo cannot call
        a raising function to fill in a default argument.
        """
        self.delimiter = 0x2C  # ,
        self.quotechar = 0x22  # "
        self.has_quotechar = True
        self.escapechar = 0
        self.has_escapechar = False
        self.doublequote = True
        self.skipinitialspace = False
        self.lineterminator = String("\r\n")
        self.quoting = QUOTE_MINIMAL
        self.strict = False
        self.field_size_limit = FIELD_SIZE_LIMIT

    def __init__(
        out self,
        *,
        delimiter: StringSlice = ",",
        quotechar: Optional[String] = String('"'),
        escapechar: Optional[String] = None,
        doublequote: Bool = True,
        skipinitialspace: Bool = False,
        lineterminator: StringSlice = "\r\n",
        quoting: Int = QUOTE_MINIMAL,
        strict: Bool = False,
        field_size_limit: Int = FIELD_SIZE_LIMIT,
    ) raises:
        """Resolves one set of format parameters.

        The defaults are CPython's `excel` dialect.

        Args:
            delimiter: The one character that separates fields.
            quotechar: The one character that quotes a field, or `None`.
            escapechar: The one character that escapes the next one, or
                `None`.
            doublequote: Whether a quote inside a quoted field is doubled.
            skipinitialspace: Whether a space after a delimiter is dropped.
            lineterminator: What the writer ends a row with.
            quoting: One of the `QUOTE_*` constants.
            strict: Whether a malformed record raises.
            field_size_limit: How wide one field may be.

        Raises:
            `CSVError` if a parameter is not one CPython would accept.
        """
        self.delimiter = _one_character("delimiter", delimiter)
        if quotechar:
            self.quotechar = _one_character("quotechar", quotechar.value())
            self.has_quotechar = True
        else:
            self.quotechar = 0
            self.has_quotechar = False
        if escapechar:
            self.escapechar = _one_character("escapechar", escapechar.value())
            self.has_escapechar = True
        else:
            self.escapechar = 0
            self.has_escapechar = False
        self.doublequote = doublequote
        self.skipinitialspace = skipinitialspace
        self.lineterminator = String(lineterminator)
        if quoting < QUOTE_MINIMAL or quoting > QUOTE_NONE:
            raise CSVError(String('bad "quoting" value'))
        if not self.has_quotechar and quoting != QUOTE_NONE:
            raise CSVError(String("quotechar must be set if quoting enabled"))
        self.quoting = quoting
        self.strict = strict
        self.field_size_limit = field_size_limit

    def quotes(self) -> Bool:
        """Reports whether the quote character is live.

        Returns:
            True when a quote character is set and quoting is not
            `QUOTE_NONE`, which is the condition the reader tests before
            treating one as a quote rather than as data.
        """
        return self.has_quotechar and self.quoting != QUOTE_NONE


def excel() -> Dialect:
    """Builds CPython's `excel` dialect, which is the default.

    Returns:
        Comma separated, `"` quoted, CRLF terminated, minimally quoted.
    """
    return Dialect()


def excel_tab() raises -> Dialect:
    """Builds CPython's `excel-tab` dialect.

    Returns:
        The `excel` dialect with a tab delimiter.

    Raises:
        Never; the signature matches `Dialect.__init__`.
    """
    return Dialect(delimiter="\t")


def unix() raises -> Dialect:
    """Builds CPython's `unix` dialect.

    Returns:
        Comma separated, LF terminated, with every field quoted.

    Raises:
        Never; the signature matches `Dialect.__init__`.
    """
    return Dialect(lineterminator="\n", quoting=QUOTE_ALL)
