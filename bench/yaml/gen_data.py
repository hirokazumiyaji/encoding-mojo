#!/usr/bin/env python3
"""Generates the YAML fixtures the benchmarks read."""

import os
import random

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")

WORDS = (
    "mojo python parser emitter block flow scalar anchor alias document "
    "mapping sequence indent comment"
).split()


def config(rng, n=900):
    """Deeply nested mappings of short strings, like a service config."""
    return {
        "service_%d" % i: {
            "image": "registry.example.com/%s:%d" % (rng.choice(WORDS), rng.randrange(50)),
            "replicas": rng.randrange(1, 20),
            "enabled": rng.random() < 0.8,
            "env": {
                "KEY_%d" % j: " ".join(rng.choice(WORDS) for _ in range(3))
                for j in range(rng.randint(1, 5))
            },
            "ports": [rng.randrange(1024, 65535) for _ in range(rng.randint(1, 4))],
            "notes": None,
        }
        for i in range(n)
    }


def records(rng, n=2500):
    """A long sequence of flat records."""
    return [
        {
            "id": rng.randrange(10**9),
            "name": " ".join(rng.choice(WORDS) for _ in range(rng.randint(2, 6))),
            "score": round(rng.uniform(0, 100), 3),
            "active": rng.random() < 0.5,
            "tags": [rng.choice(WORDS) for _ in range(rng.randint(0, 4))],
        }
        for _ in range(n)
    ]


def main():
    os.makedirs(DATA, exist_ok=True)
    rng = random.Random(20260821)
    for name, builder in (("config", config), ("records", records)):
        path = os.path.join(DATA, name + ".yaml")
        with open(path, "w") as fh:
            yaml.safe_dump(builder(rng), fh)
        print("%-9s %8.2f MiB  %s" % (name, os.path.getsize(path) / 1048576, path))


if __name__ == "__main__":
    main()
