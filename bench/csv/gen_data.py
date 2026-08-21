#!/usr/bin/env python3
"""Generates the CSV fixtures the benchmarks read."""

import csv
import io
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")

WORDS = (
    "mojo python reader writer field record quote escape delimiter dialect "
    "header column row parser"
).split()


def plain(rng, n=12000):
    """Narrow rows of short unquoted fields, the common shape."""
    rows = [["id", "name", "score", "active", "tag"]]
    for i in range(n):
        rows.append(
            [
                str(rng.randrange(10**9)),
                "%s_%d" % (rng.choice(WORDS), rng.randrange(1000)),
                "%.3f" % rng.uniform(0, 100),
                "true" if rng.random() < 0.5 else "false",
                rng.choice(WORDS),
            ]
        )
    return rows


def quoted(rng, n=6000):
    """Wider rows where most fields need quotes."""
    rows = [["id", "title", "note", "tags"]]
    for i in range(n):
        rows.append(
            [
                str(i),
                "%s, %s" % (rng.choice(WORDS), rng.choice(WORDS)),
                'he said "%s" and\nthen left' % rng.choice(WORDS),
                ";".join(rng.choice(WORDS) for _ in range(rng.randint(1, 4))),
            ]
        )
    return rows


def main():
    os.makedirs(DATA, exist_ok=True)
    rng = random.Random(20260821)
    for name, builder in (("plain", plain), ("quoted", quoted)):
        path = os.path.join(DATA, name + ".csv")
        buf = io.StringIO(newline="")
        writer = csv.writer(buf)
        writer.writerows(builder(rng))
        with open(path, "w", newline="") as fh:
            fh.write(buf.getvalue())
        print(
            "%-9s %8.2f MiB  %s"
            % (name, os.path.getsize(path) / 1048576, path)
        )


if __name__ == "__main__":
    main()
