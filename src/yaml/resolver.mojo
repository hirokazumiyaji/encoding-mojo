"""Implicit type resolution for plain scalars.

PyYAML implements YAML 1.1, whose type patterns differ from YAML 1.2 in ways
that matter: `yes` and `off` are booleans, a leading `0` means octal, `0o17` is
*not* a number, digits may be grouped with underscores, and an exponent needs
an explicit sign, so `1e3` is a string. This module reproduces PyYAML's
resolver exactly.
"""

from serde.tape import (
    _KIND_BOOL,
    _KIND_FLOAT,
    _KIND_INT,
    _KIND_NULL,
    _Node,
    _Tape,
)


@always_inline
def _is_digit(b: UInt8) -> Bool:
    """Reports whether `b` is an ASCII digit.

    Args:
        b: The byte to test.

    Returns:
        True for `0` through `9`.
    """
    return b >= 0x30 and b <= 0x39


def _matches(text: StringSlice, *options: StaticString) -> Bool:
    """Reports whether `text` equals one of `options`.

    Args:
        text: The text to test.
        options: The spellings to accept.

    Returns:
        True if any option matches exactly.
    """
    for i in range(len(options)):
        if text == options[i]:
            return True
    return False


def _strip_underscores(text: StringSlice) -> String:
    """Removes the digit-grouping underscores YAML 1.1 allows in numbers.

    Args:
        text: The literal to clean.

    Returns:
        The literal with every `_` removed.
    """
    var bytes = text.as_bytes()
    var kept = List[UInt8](capacity=len(bytes))
    for i in range(len(bytes)):
        if bytes[i] != 0x5F:
            kept.append(bytes[i])
    return String(unsafe_from_utf8=Span(kept))


def _parse_sign(text: StringSlice) -> Tuple[Bool, StringSlice[text.origin]]:
    """Splits an optional leading sign off a numeric literal.

    Args:
        text: The literal.

    Returns:
        Whether the literal was negative, and the rest of it.
    """
    var bytes = text.as_bytes()
    if len(bytes) and (bytes[0] == 0x2B or bytes[0] == 0x2D):
        return (bytes[0] == 0x2D, text[byte = 1 : text.byte_length()])
    return (False, text[byte = 0 : text.byte_length()])


def _digits_in_base(text: StringSlice, base: Int) -> Optional[Int]:
    """Parses `text` as an unsigned integer in `base`.

    Args:
        text: The digits, already free of underscores.
        base: The radix, 2, 8, 10 or 16.

    Returns:
        The value, or `None` if `text` is empty or has a digit out of range.
    """
    var bytes = text.as_bytes()
    if len(bytes) == 0:
        return None
    var value = 0
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
        value = value * base + digit
    return value


def _resolve_int(text: StringSlice) -> Optional[Int]:
    """Applies PyYAML's YAML 1.1 integer patterns.

    Args:
        text: The plain scalar.

    Returns:
        The integer it denotes, or `None` if it denotes something else.
    """
    var negative, rest = _parse_sign(text)
    var cleaned = _strip_underscores(rest)
    var n = cleaned.byte_length()
    if n == 0:
        return None
    var b0 = cleaned.as_bytes()[0]
    var b1 = cleaned.as_bytes()[1] if n > 1 else UInt8(0)

    var magnitude: Optional[Int]
    if n > 2 and b0 == 0x30 and (b1 | 0x20) == 0x78:  # 0x
        magnitude = _digits_in_base(cleaned[byte=2:n], 16)
    elif n > 2 and b0 == 0x30 and (b1 | 0x20) == 0x62:  # 0b
        magnitude = _digits_in_base(cleaned[byte=2:n], 2)
    elif n > 1 and b0 == 0x30:
        # A leading zero means octal in YAML 1.1; `0o17` is not a number at all.
        magnitude = _digits_in_base(cleaned[byte=1:n], 8)
    elif _sexagesimal_parts(cleaned) > 1:
        magnitude = _resolve_sexagesimal_int(cleaned)
    else:
        if n > 1 and b0 == 0x30:
            return None
        magnitude = _digits_in_base(cleaned, 10)

    if not magnitude:
        return None
    return -magnitude.value() if negative else magnitude.value()


def _sexagesimal_parts(text: StringSlice) -> Int:
    """Counts the colon-separated parts of a base-60 literal.

    Args:
        text: The literal, without a sign.

    Returns:
        How many parts it has, or 0 if it is not base-60 at all.
    """
    var bytes = text.as_bytes()
    if len(bytes) == 0:
        return 0
    var parts = 1
    for i in range(len(bytes)):
        if bytes[i] == 0x3A:
            parts += 1
        elif not _is_digit(bytes[i]) and bytes[i] != 0x2E:
            return 0
    return parts


def _resolve_sexagesimal_int(text: StringSlice) -> Optional[Int]:
    """Parses a base-60 integer such as `1:30`.

    Args:
        text: The literal, without a sign or underscores.

    Returns:
        The value, or `None` if a part is out of range.
    """
    var value = 0
    var part = 0
    var seen = False
    var bytes = text.as_bytes()
    for i in range(len(bytes)):
        if bytes[i] == 0x3A:
            if not seen:
                return None
            value = value * 60 + part
            part = 0
            seen = False
        elif _is_digit(bytes[i]):
            part = part * 10 + Int(bytes[i] - 0x30)
            seen = True
        else:
            return None
    if not seen:
        return None
    return value * 60 + part


def _resolve_float(text: StringSlice) raises -> Optional[Float64]:
    """Applies PyYAML's YAML 1.1 float patterns.

    Args:
        text: The plain scalar.

    Returns:
        The float it denotes, or `None` if it denotes something else.

    Raises:
        Never; the signature matches its caller.
    """
    var negative, rest = _parse_sign(text)

    if _matches(rest, ".inf", ".Inf", ".INF"):
        return Float64("-inf") if negative else Float64("inf")
    if _matches(text, ".nan", ".NaN", ".NAN"):
        return Float64("nan")

    var cleaned = _strip_underscores(rest)
    var n = cleaned.byte_length()
    if n == 0:
        return None

    # Base-60 with a fraction, such as `1:30.5`.
    if _sexagesimal_parts(cleaned) > 1:
        var dot = -1
        for i in range(n):
            if cleaned.as_bytes()[i] == 0x2E:
                dot = i
                break
        if dot < 0:
            return None
        var whole = _resolve_sexagesimal_int(cleaned[byte=0:dot])
        if not whole:
            return None
        var fraction = atof(String("0", cleaned[byte=dot:n]))
        var value = Float64(whole.value()) + fraction
        return -value if negative else value

    # The general form needs a `.`; without one, `1e3` is a string in YAML 1.1.
    var seen_dot = False
    var seen_digit = False
    var i = 0
    while i < n:
        var b = cleaned.as_bytes()[i]
        if _is_digit(b):
            seen_digit = True
        elif b == 0x2E:
            if seen_dot:
                return None
            seen_dot = True
        elif (b | 0x20) == 0x65:  # e or E
            break
        else:
            return None
        i += 1
    if not seen_dot or not seen_digit:
        return None

    if i < n:
        # An exponent, which YAML 1.1 requires to carry an explicit sign.
        i += 1
        var sign = cleaned.as_bytes()[i] if i < n else UInt8(0)
        if i >= n or (sign != 0x2B and sign != 0x2D):
            return None
        i += 1
        if i >= n:
            return None
        while i < n:
            if not _is_digit(cleaned.as_bytes()[i]):
                return None
            i += 1

    var value = atof(cleaned)
    return -value if negative else value


def resolve_plain(mut tape: _Tape, text: StringSlice) raises -> UInt32:
    """Appends the value a plain scalar denotes, applying YAML 1.1 rules.

    Args:
        tape: The tape to append to.
        text: The scalar, exactly as written.

    Returns:
        The index of the new node.

    Raises:
        Never; the signature matches its callers.
    """
    if text.byte_length() == 0 or _matches(text, "~", "null", "Null", "NULL"):
        return tape.push(_Node.scalar(_KIND_NULL))

    if _matches(
        text, "true", "True", "TRUE", "yes", "Yes", "YES", "on", "On", "ON"
    ):
        return tape.push(_Node.scalar(_KIND_BOOL, 1))
    if _matches(
        text, "false", "False", "FALSE", "no", "No", "NO", "off", "Off", "OFF"
    ):
        return tape.push(_Node.scalar(_KIND_BOOL, 0))

    var first = text.as_bytes()[0]
    if _is_digit(first) or first == 0x2B or first == 0x2D or first == 0x2E:
        var as_int = _resolve_int(text)
        if as_int:
            return tape.push(
                _Node.scalar(_KIND_INT, UInt64(Int64(as_int.value())))
            )
        var as_float = _resolve_float(text)
        if as_float:
            return tape.push(
                _Node.scalar(
                    _KIND_FLOAT, as_float.value().to_bits[DType.uint64]()
                )
            )

    return tape.push_string(text.as_bytes())
