#!/usr/bin/env bash
# Single blocking gate for all static analysis: formatting, compile+unit tests,
# shell lint, Python lint, Python type check.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

# CI installs the pinned Python tooling into .venv and puts it on PATH before
# running this script; do the same locally so a created-but-not-activated
# .venv is still what checks run with, matching CI exactly.
if [[ -d "${ROOT_DIR}/.venv/bin" ]]; then
    export PATH="${ROOT_DIR}/.venv/bin:${PATH}"
else
    # CI always runs the requirements-dev.lock.txt versions; without .venv,
    # PATH's ruff/mypy stand in and their rules can drift from the gate, so
    # name the substitution instead of letting it surface as an after-push
    # failure.
    echo "WARN: .venv not found; running whatever ruff/mypy is on PATH, which may differ from the versions pinned in requirements-dev.lock.txt" >&2
    echo "WARN: setup: uv venv .venv && uv pip install --require-hashes -r requirements-dev.lock.txt" >&2
fi

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# Name every missing tool at once instead of dying mid-gate on a bare
# "command not found"; CONTRIBUTING.md documents where each comes from.
missing=""
for tool in zig shellcheck ruff mypy; do
    command -v "${tool}" >/dev/null 2>&1 || missing="${missing} ${tool}"
done
if [[ -n "${missing}" ]]; then
    fail "required tools not found on PATH:${missing} -- see CONTRIBUTING.md (setup section)"
fi

echo "=== zig fmt --check ==="
zig fmt --check src/ build.zig build.zig.zon || fail "zig fmt --check reported unformatted files"

echo "=== shellcheck ==="
# Defect-oriented optional checks the tree already passes: every case
# statement must handle an unmatched input, bare [ $x ] conditions are
# ambiguous, which(1) is not portable, variables stay quoted even where
# currently safe, a suppressed `set -e` cannot silently downgrade error
# handling, an uppercase-looking assignment is always set before use, and
# a negated numeric comparison ([ ! "$x" -eq 1 ]) is written as its direct
# operator (-ne) so the tested condition is the one a reader sees, and a
# return value swallowed by command/process substitution must be either
# propagated or explicitly dismissed with || true, like set -e suppression.
# The style-only brace/double-bracket checks stay off: this tree does not
# follow those conventions.
shellcheck -o add-default-case,avoid-nullary-conditions,avoid-negated-conditions,deprecate-which,quote-safe-variables,check-set-e-suppressed,check-unassigned-uppercase,check-extra-masked-returns scripts/*.sh || fail "shellcheck reported violations"

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
