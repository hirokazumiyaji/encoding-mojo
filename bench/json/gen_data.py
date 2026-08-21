#!/usr/bin/env python3
"""Generates the JSON fixtures the benchmarks read.

The three shapes stress different parts of a parser: `twitter` is
string-heavy, `canada` is float-heavy, and `catalog` is object-heavy.
"""

import json
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")

WORDS = (
    "mojo python parser tape simd unicode benchmark throughput latency "
    "allocation arena document encoder decoder"
).split()


def twitter(rng, n=1200):
    """Short strings, nested objects, a few numbers and booleans."""
    return {
        "statuses": [
            {
                "id": rng.randrange(10**17),
                "text": " ".join(rng.choice(WORDS) for _ in range(rng.randint(5, 25))),
                "truncated": rng.random() < 0.1,
                "user": {
                    "id": rng.randrange(10**9),
                    "screen_name": "user_%d" % i,
                    "followers_count": rng.randrange(100000),
                    "verified": rng.random() < 0.05,
                    "description": " ".join(
                        rng.choice(WORDS) for _ in range(rng.randint(0, 12))
                    ),
                },
                "entities": {
                    "hashtags": [rng.choice(WORDS) for _ in range(rng.randint(0, 4))],
                    "urls": [],
                },
                "lang": rng.choice(["en", "ja", "fr", "de"]),
                "retweet_count": rng.randrange(5000),
            }
            for i in range(n)
        ]
    }


def canada(rng, n=40000):
    """Almost nothing but floats, in deeply nested arrays."""
    return {
        "type": "FeatureCollection",
        "features": [
            {
                "type": "Feature",
                "properties": {"name": "Canada"},
                "geometry": {
                    "type": "Polygon",
                    "coordinates": [
                        [
                            [
                                round(rng.uniform(-141.0, -52.0), 4),
                                round(rng.uniform(41.0, 83.0), 4),
                            ]
                            for _ in range(n)
                        ]
                    ],
                },
            }
        ],
    }


def catalog(rng, n=4000):
    """Many small objects keyed by numeric-looking strings."""
    return {
        "events": {
            str(100000 + i): {
                "id": 100000 + i,
                "name": " ".join(rng.choice(WORDS) for _ in range(3)),
                "subTopicIds": [rng.randrange(100000) for _ in range(rng.randint(1, 6))],
                "topicIds": [rng.randrange(100000) for _ in range(rng.randint(1, 4))],
                "logo": None,
                "seatCategories": [
                    {"areas": [{"areaId": rng.randrange(500)}], "seatCategoryId": j}
                    for j in range(rng.randint(1, 3))
                ],
            }
            for i in range(n)
        },
        "areaNames": {str(i): "Area %d" % i for i in range(200)},
    }


def main():
    os.makedirs(DATA, exist_ok=True)
    rng = random.Random(20260820)
    for name, builder in (("twitter", twitter), ("canada", canada), ("catalog", catalog)):
        path = os.path.join(DATA, name + ".json")
        with open(path, "w") as fh:
            json.dump(builder(rng), fh, separators=(",", ":"))
        print("%-10s %8.2f MiB  %s" % (name, os.path.getsize(path) / 1048576, path))


if __name__ == "__main__":
    main()
