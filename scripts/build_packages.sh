#!/usr/bin/env bash
# Precompile every package under src/ into build/<name>.mojoc.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p build

for pkg in src/*/; do
    name="$(basename "$pkg")"
    [ -f "$pkg/__init__.mojo" ] || continue
    echo "== $name"
    mojo precompile -I src -o "build/$name.mojoc" "$pkg"
done

echo "packages written to build/"
