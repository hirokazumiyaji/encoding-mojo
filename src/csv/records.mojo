"""Reading and writing rows keyed by a header line.

These are CPython's `DictReader` and `DictWriter`. A record is a `Value`
object here rather than a Python dict, which keeps the keys in the order the
header gave them and lets a CSV file cross into the `json`, `yaml` and `toml`
packages without conversion.
"""

from std.memory import ArcPointer

from serde import Value

from .api import reader
from .dialect import Dialect
from .errors import CSVError
from .writer import _Writer


def read_records(
    text: StringSlice,
    dialect: Dialect = Dialect(),
    *,
    fieldnames: Optional[List[String]] = None,
    restkey: StringSlice = "",
    restval: StringSlice = "",
) raises -> List[Value]:
    """Reads a document into one object per record, keyed by the header.

    The first record names the fields unless `fieldnames` says otherwise, and
    a blank line is skipped rather than becoming an empty record, both of
    which are what `csv.DictReader` does. A short record is padded with
    `restval`; a long one puts the surplus fields in an array under `restkey`.

    Args:
        text: The document to read.
        dialect: The format parameters, `excel` by default.
        fieldnames: The field names, or `None` to take them from the first
            record.
        restkey: The key the surplus fields of a long record go under. An
            empty name drops them; CPython instead files them under the
            `None` key, which an object keyed by text has nowhere to put.
        restval: What a short record's missing fields hold.

    Returns:
        One object per record, in order.

    Raises:
        `CSVError` if a record is malformed and the dialect is strict.
    """
    var rows = reader(text, dialect)
    var names: List[String]
    var start: Int
    if fieldnames:
        names = fieldnames.value().copy()
        start = 0
    elif len(rows) == 0:
        return []
    else:
        names = rows[0].copy()
        start = 1

    var out = List[Value]()
    for index in range(start, len(rows)):
        ref row = rows[index]
        if len(row) == 0:
            # `DictReader` skips a blank line instead of yielding a record.
            continue
        var record = Value.object()
        for i in range(len(names)):
            if i < len(row):
                record[names[i]] = Value(row[i])
            else:
                record[names[i]] = Value(restval)
        if len(row) > len(names) and restkey.byte_length() > 0:
            var surplus = Value.array()
            for i in range(len(names), len(row)):
                surplus.append(row[i])
            record[restkey] = surplus^
        out.append(record^)
    return out^


def write_records(
    records: List[Value],
    fieldnames: List[String],
    dialect: Dialect = Dialect(),
    *,
    header: Bool = True,
    restval: StringSlice = "",
    extrasaction_raise: Bool = True,
) raises -> String:
    """Writes one record per object, in `fieldnames` order.

    Args:
        records: The records to write, each an object.
        fieldnames: The fields to write, in order.
        dialect: The format parameters, `excel` by default.
        header: Whether to write the field names as the first record, which
            is `DictWriter.writeheader()`.
        restval: What a record missing a field writes for it.
        extrasaction_raise: Whether a key outside `fieldnames` is an error,
            which is CPython's `extrasaction="raise"`. False ignores it.

    Returns:
        The CSV text.

    Raises:
        `CSVError` if a record carries a field outside `fieldnames` and
        `extrasaction_raise` is set, or if a record cannot be written.
    """
    var out = _Writer(dialect)
    if header:
        out.writerow(fieldnames)
    for record in records:
        if not record.is_object():
            raise CSVError(String("a record must be a table"))
        if extrasaction_raise:
            for name in record.keys():
                var known = False
                for i in range(len(fieldnames)):
                    if fieldnames[i] == name:
                        known = True
                        break
                if not known:
                    raise CSVError(
                        String(
                            "dict contains fields not in fieldnames: '",
                            name,
                            "'",
                        )
                    )
        var row = List[String](capacity=len(fieldnames))
        # `QUOTE_NONNUMERIC` leaves a number unquoted, and only the record
        # still knows which members were numbers once they are text.
        var numeric = List[Bool](capacity=len(fieldnames))
        for i in range(len(fieldnames)):
            if fieldnames[i] in record:
                ref value = record[fieldnames[i]]
                row.append(_field_text(value))
                numeric.append(value.is_number() or value.is_bool())
            else:
                row.append(String(restval))
                numeric.append(False)
        out._write(row, numeric)
    return out.text()


def _field_text(value: Value) raises -> String:
    """Renders one member of a record as a field.

    Args:
        value: The member to render.

    Returns:
        Its text, which for a string is the string itself and for a number
        or a boolean is what Python's `str` would give.

    Raises:
        If the value cannot be rendered.
    """
    if value.is_string():
        return value.string()
    if value.is_null():
        # CPython writes `None` as an empty field.
        return String()
    if value.is_bool():
        return String("True") if value.bool() else String("False")
    if value.is_int():
        return String(value.int())
    if value.is_float():
        return String(value.float())
    raise CSVError(String("a field cannot hold an array or a table"))
