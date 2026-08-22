"""Reading a field as a number the way Python's `float` does.

`QUOTE_NONNUMERIC` asks the reader to hand each unquoted field to `float()`,
so this is where that conversion lives. Two parts of `float()` are wider than
they look: it strips Unicode whitespace, not only blanks, and it accepts any
Unicode decimal digit, so `１２` is twelve and `١.٢` is one point two.

The two tables below were generated from CPython 3.11's own answers: the digit
blocks are every codepoint whose `unicodedata.category` is `Nd` and whose
`unicodedata.decimal` is zero — 66 runs of ten — and the whitespace set is
every codepoint `str.isspace` accepts that `float` also strips, which leaves
out the four information separators.
"""

from std.math import isinf, isnan

comptime _DIGIT_BLOCKS = StaticString(
    "0000300006600006F00007C00009660009E6000A66000AE6000B66000BE6000C66"
    "000CE6000D66000DE6000E50000ED0000F200010400010900017E00018100019460"
    "019D0001A80001A90001B50001BB0001C40001C5000A62000A8D000A90000A9D000"
    "A9F000AA5000ABF000FF100104A0010D300110660110F00111360111D00112F0011"
    "4500114D00116500116C00117300118E0011950011C50011D50011DA0016A60016A"
    "C0016B5001D7CE01D7D801D7E201D7EC01D7F601E14001E2F001E95001FBF0"
)
"""The first codepoint of every run of ten Unicode decimal digits.

Each run is exactly ten consecutive codepoints, so the digit's value is its
offset from the start of its run. Six hexadecimal characters per entry.
"""

comptime _DIGIT_BLOCK_COUNT = 66
"""How many runs `_DIGIT_BLOCKS` holds."""


def _hex_at(text: StringSlice, start: Int, width: Int) -> UInt32:
    """Reads `width` hexadecimal characters as a number.

    Args:
        text: The table to read from.
        start: The offset of the first character.
        width: How many characters to read.

    Returns:
        The value they spell.
    """
    var bytes = text.as_bytes()
    var value = UInt32(0)
    for i in range(start, start + width):
        var b = bytes[i]
        if b <= 0x39:
            value = (value << 4) | UInt32(b - 0x30)
        else:
            value = (value << 4) | UInt32((b | 0x20) - 0x61 + 10)
    return value


def decimal_value(cp: UInt32) -> Int:
    """Returns the value of a Unicode decimal digit, or -1.

    Args:
        cp: The codepoint to look up.

    Returns:
        0 to 9 for a decimal digit, -1 for anything else. A Roman numeral or
        a superscript is not one, which is what `float` decides too.
    """
    if cp >= 0x30 and cp <= 0x39:
        return Int(cp - 0x30)
    if cp < 0x660:
        return -1
    var low = 0
    var high = _DIGIT_BLOCK_COUNT - 1
    while low <= high:
        var mid = (low + high) // 2
        var start = _hex_at(_DIGIT_BLOCKS, mid * 6, 6)
        if cp < start:
            high = mid - 1
        elif cp > start + 9:
            low = mid + 1
        else:
            return Int(cp - start)
    return -1


def is_float_space(cp: UInt32) -> Bool:
    """Reports whether `float` would strip this character from either end.

    Args:
        cp: The codepoint to test.

    Returns:
        True for the whitespace `float` skips. The four information
        separators are `str.isspace` characters that `float` does not take,
        so they are absent.
    """
    if cp < 0x80:
        return (cp >= 0x09 and cp <= 0x0D) or cp == 0x20
    if cp == 0x85 or cp == 0xA0 or cp == 0x1680:
        return True
    if cp >= 0x2000 and cp <= 0x200A:
        return True
    return (
        cp == 0x2028
        or cp == 0x2029
        or cp == 0x202F
        or cp == 0x205F
        or cp == 0x3000
    )
