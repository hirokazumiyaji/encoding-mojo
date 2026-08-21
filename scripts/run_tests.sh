#!/usr/bin/env bash
# Run every Mojo test module under test/.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

failed=0
files=("$@")
if [ ${#files[@]} -eq 0 ]; then
    mapfile -t files < <(find test -name 'test_*.mojo' | sort)
fi

for f in "${files[@]}"; do
    echo "== $f"
    if ! mojo run -I src "$f"; then
        failed=1
    fi
done

if [ "$failed" -ne 0 ]; then
    echo "FAILED"
    exit 1
fi
echo "ALL TESTS PASSED"
