#!/usr/bin/env bash
# Single blocking gate for all static analysis: formatting, compile+unit tests,
# shell lint, Python lint, Python type check.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

echo "=== zig fmt --check ==="
zig fmt --check src/ build.zig || fail "zig fmt --check reported unformatted files"

echo "=== shellcheck ==="
shellcheck scripts/*.sh || fail "shellcheck reported violations"

echo "=== ruff ==="
ruff check scripts/ || fail "ruff reported violations"

echo "=== ruff format --check ==="
ruff format --check scripts/ || fail "ruff format reported unformatted files"

echo "=== mypy ==="
mypy scripts/ || fail "mypy reported errors"

# Slowest step last: the linters above are instant, so a lint failure never
# pays for the full compile first.
echo "=== zig build test ==="
zig build test || fail "zig build test failed"

echo "=== All static analysis checks passed ==="
