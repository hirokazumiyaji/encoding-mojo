#!/usr/bin/env python3
"""Generates the TOML fixtures the benchmarks read."""

import os
import random

import tomli_w

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")

WORDS = (
    "mojo python parser writer table array inline dotted document "
    "key value literal comment section"
).split()


def config(rng, n=900):
    """Nested tables of short values, like a workspace manifest."""
    return {
        "package_%d" % i: {
            "name": "%s-%d" % (rng.choice(WORDS), rng.randrange(50)),
            "version": "%d.%d.%d" % (rng.randrange(9), rng.randrange(20), rng.randrange(20)),
            "enabled": rng.random() < 0.8,
            "weight": round(rng.uniform(0, 100), 4),
            "features": [rng.choice(WORDS) for _ in range(rng.randint(0, 4))],
            "env": {
                "KEY_%d" % j: " ".join(rng.choice(WORDS) for _ in range(3))
                for j in range(rng.randint(1, 5))
            },
        }
        for i in range(n)
    }


def records(rng, n=2500):
    """A long array of tables of flat records."""
    return {
        "record": [
            {
                "id": rng.randrange(10**9),
                "name": " ".join(rng.choice(WORDS) for _ in range(rng.randint(2, 6))),
                "score": round(rng.uniform(0, 100), 3),
                "active": rng.random() < 0.5,
                "tags": [rng.choice(WORDS) for _ in range(rng.randint(1, 4))],
            }
            for _ in range(n)
        ]
    }


def main():
    os.makedirs(DATA, exist_ok=True)
    rng = random.Random(20260821)
    for name, builder in (("config", config), ("records", records)):
        path = os.path.join(DATA, name + ".toml")
        with open(path, "wb") as fh:
            tomli_w.dump(builder(rng), fh)
        print("%-9s %8.2f MiB  %s" % (name, os.path.getsize(path) / 1048576, path))


if __name__ == "__main__":
    main()
