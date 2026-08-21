"""Compile-time hooks that customise how a document decodes.

These are the counterparts of CPython's `parse_int`, `parse_float`,
`parse_constant` and `object_hook`. Mojo cannot store a function in an
`Optional`, so a hook is a *type* implementing a trait and is passed as a
compile-time parameter:

```mojo
from json import JSONValue, NumberHook, loads


struct KeepLiteral(NumberHook):
    @staticmethod
    def call(text: String) raises -> JSONValue:
        return JSONValue(text)


var doc = loads[ParseInt=KeepLiteral]("123456789012345678901234567890")
```

Leaving a hook at its default costs nothing: the decoder branches on the type
at compile time, so the unused path — and the `String` it would have had to
build — is never emitted.
"""

from serde import Value as JSONValue


trait NumberHook:
    """Decides what a numeric literal decodes to.

    Implement this to keep values the built-in decoder cannot represent, such
    as integers wider than 64 bits, by returning the literal as a string.
    """

    @staticmethod
    def call(text: String) raises -> JSONValue:
        """Converts one literal.

        Args:
            text: The literal exactly as it appeared in the document, sign
                included.

        Returns:
            The value to store in its place.

        Raises:
            To reject the literal, which surfaces as a decode failure.
        """
        ...


trait ValueHook:
    """Decides what a decoded object becomes.

    Called as each object completes, innermost first, so nested objects have
    already been through the hook by the time their parent is handed over.
    """

    @staticmethod
    def call(value: JSONValue) raises -> JSONValue:
        """Converts one object.

        Args:
            value: The object that was just decoded. It is a standalone
                document, so keeping or mutating it is safe.

        Returns:
            The value to store in its place.

        Raises:
            To reject the object, which surfaces as a decode failure.
        """
        ...


struct NoNumberHook(NumberHook):
    """The default `NumberHook`: decode numbers normally."""

    @staticmethod
    def call(text: String) raises -> JSONValue:
        """Never called; the decoder skips this hook at compile time.

        Args:
            text: Unused.

        Returns:
            Null.

        Raises:
            Never.
        """
        return JSONValue()


struct NoValueHook(ValueHook):
    """The default `ValueHook`: keep objects as they were decoded."""

    @staticmethod
    def call(value: JSONValue) raises -> JSONValue:
        """Never called; the decoder skips this hook at compile time.

        Args:
            value: Unused.

        Returns:
            The value unchanged.

        Raises:
            Never.
        """
        return value
