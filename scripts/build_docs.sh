#!/usr/bin/env bash
# Compile the docstrings under src/ into a Markdown API reference in docs/api/.
#
# `mojo doc` reads the docstrings and emits JSON; scripts/render_api_docs.py
# renders that JSON as Markdown. Pass --check to only validate the docstrings,
# which is what CI does on every push.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

check_only=0
if [ "${1:-}" = "--check" ]; then
    check_only=1
fi

# The Python checker needs no compiler, so it runs either way.
python3 scripts/check_docstrings.py src

if ! command -v mojo >/dev/null 2>&1; then
    if [ "$check_only" -eq 1 ]; then
        echo "mojo not on PATH; checked the docstrings only" >&2
        exit 0
    fi
    echo "mojo not on PATH; cannot generate the reference" >&2
    exit 1
fi

mkdir -p build/docs
jsons=()
for pkg in src/*/; do
    name="$(basename "$pkg")"
    [ -f "$pkg/__init__.mojo" ] || continue
    echo "== $name"
    mojo doc --diagnose-missing-doc-strings -I src -o "build/docs/$name.json" "$pkg"
    jsons+=("build/docs/$name.json")
done

if [ "$check_only" -eq 1 ]; then
    echo "docstrings compile cleanly"
    exit 0
fi

rm -rf docs/api
python3 scripts/render_api_docs.py "${jsons[@]}" -o docs/api --index
echo "API reference written to docs/api/"
