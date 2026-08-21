"""Tests for the decoder hooks that customise how literals and objects decode.

These are the Mojo counterparts of CPython's `parse_int`, `parse_float`,
`parse_constant` and `object_hook`. They are compile-time type parameters
rather than runtime callables, so the default path costs nothing.
"""

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from json import JSONValue, NumberHook, ValueHook, dumps, loads


struct KeepLiteral(NumberHook):
    """Keeps a numeric literal as the exact text it was written with."""

    @staticmethod
    def call(text: String) raises -> JSONValue:
        """Returns the literal unchanged, as a JSON string.

        Args:
            text: The literal as it appeared in the document.

        Returns:
            The literal as a string value.
        """
        return JSONValue(text)


struct RejectConstant(NumberHook):
    """Refuses the non-standard `NaN` and `Infinity` literals."""

    @staticmethod
    def call(text: String) raises -> JSONValue:
        """Always raises.

        Args:
            text: The constant that was found.

        Returns:
            Never returns.

        Raises:
            Always.
        """
        raise Error("refusing constant ", text)


struct UppercaseKeys(ValueHook):
    """Rewrites every object so its keys are uppercase."""

    @staticmethod
    def call(value: JSONValue) raises -> JSONValue:
        """Returns a copy of `value` with uppercased keys.

        Args:
            value: The object that was just decoded.

        Returns:
            The rewritten object.
        """
        var out = JSONValue.object()
        for key in value:
            out[key.string().upper()] = value[key.string()]
        return out^


struct CountingHook(ValueHook):
    """Replaces every object with its member count."""

    @staticmethod
    def call(value: JSONValue) raises -> JSONValue:
        """Returns how many members `value` has.

        Args:
            value: The object that was just decoded.

        Returns:
            The member count as an integer value.
        """
        return JSONValue(len(value))


def test_parse_int_hook_keeps_oversized_integers_exact() raises:
    # The documented deviation is that integers wider than 64 bits widen to
    # floats. `ParseInt` is the way out: keep the literal instead.
    var v = loads[ParseInt=KeepLiteral]("123456789012345678901234567890")
    assert_true(v.is_string())
    assert_equal(v.string(), "123456789012345678901234567890")


def test_parse_int_hook_sees_every_integer() raises:
    var v = loads[ParseInt=KeepLiteral]("[1, -2, 30]")
    assert_equal(dumps(v), '["1", "-2", "30"]')


def test_parse_float_hook_sees_only_floats() raises:
    var v = loads[ParseFloat=KeepLiteral]("[1, 1.5, 2e3]")
    assert_equal(dumps(v), '[1, "1.5", "2e3"]')


def test_parse_constant_hook_can_reject_nan() raises:
    with assert_raises(contains="refusing constant NaN"):
        _ = loads[ParseConstant=RejectConstant]("NaN")
    with assert_raises(contains="refusing constant -Infinity"):
        _ = loads[ParseConstant=RejectConstant]("[-Infinity]")


def test_object_hook_rewrites_objects() raises:
    var v = loads[ObjectHook=UppercaseKeys]('{"a": 1, "b": {"c": 2}}')
    assert_equal(dumps(v), '{"A": 1, "B": {"C": 2}}')


def test_object_hook_runs_innermost_first() raises:
    # CPython calls `object_hook` as each object completes, so an inner object
    # has already been replaced by the time its parent is handed over.
    var v = loads[ObjectHook=CountingHook]('{"a": {"x": 1, "y": 2}, "b": 3}')
    assert_equal(dumps(v), "2")


def test_object_hook_leaves_arrays_alone() raises:
    var v = loads[ObjectHook=CountingHook]('[{"a": 1}, 2, "three"]')
    assert_equal(dumps(v), '[1, 2, "three"]')


def test_hooks_do_not_change_the_default_path() raises:
    assert_equal(dumps(loads('{"a": [1, 1.5]}')), '{"a": [1, 1.5]}')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
