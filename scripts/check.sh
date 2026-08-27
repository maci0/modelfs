#!/usr/bin/env bash
# Single blocking gate for all static analysis: formatting, compile+unit tests,
# restore-drill stub, vendored libfuse3 digests and extract, shell lint,
# Python lint, Python type check, CycloneDX inventory.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "${ROOT_DIR}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: ./scripts/check.sh

The blocking static gate: zig fmt, unit tests, the restore-drill stub
suite, vendored libfuse3 digests and extract, shellcheck, ruff, mypy,
sbom. Same command the CI `check` job runs. Requires the pinned .venv
from setup.

Contributor commands (also listed by `zig build --help`):
  zig build                                 build the binary
  zig build fmt                             apply zig fmt
  zig build test                            unit tests
  zig build test -Dtest-filter=relOk        tests whose names contain this substring
  zig build test --watch                    rebuild and re-run on change
  zig build check                           this script
  zig build ci / ./scripts/ci.sh            every CI job (this, aarch64, repro)
  ./scripts/cross_aarch64.sh                aarch64 ReleaseFast (extracts vendored libfuse3)
  ./scripts/run_e2e_tests.sh                CLI and peer protocol; no FUSE
  ./scripts/run_cluster_e2e_9nodes.sh       9 FUSE mounts (/dev/fuse + fusermount3)
  ./scripts/test_fault_tolerance.sh         peer loss and lease expiry
  ./scripts/test_dr_restore_drill.sh        restore drill against stub zfs (also in this script)
  ./scripts/repro_check.sh                  two ReleaseFast builds, compare bytes

Setup, once per clone: see CONTRIBUTING.md.
EOF
    exit 0
fi

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# CI installs the pinned Python tooling into .venv and puts it on PATH
# before running this script. Refuse to stand in with PATH's ruff/mypy:
# those versions disagree with the lock and fail either here or only after
# push.
if [[ -d "${ROOT_DIR}/.venv/bin" ]]; then
    export PATH="${ROOT_DIR}/.venv/bin:${PATH}"
else
    fail "pinned .venv not found; install it with: uv venv .venv && uv pip install --require-hashes -r requirements-dev.lock.txt (see CONTRIBUTING.md)"
fi

# Name every missing tool at once instead of dying mid-gate on a bare
# "command not found"; CONTRIBUTING.md documents where each comes from.
missing=""
for tool in zig shellcheck ruff mypy sha256sum; do
    command -v "${tool}" >/dev/null 2>&1 || missing="${missing} ${tool}"
done
if [[ -n "${missing}" ]]; then
    fail "required tools not found on PATH:${missing} -- see CONTRIBUTING.md (setup section)"
fi

# zig fmt does not consult build.zig.zon; catch an old toolchain here
# rather than as a later, less obvious compile failure.
min_zig="$(sed -n 's/^[[:space:]]*\.minimum_zig_version *= *"\([^"]*\)".*/\1/p' "${ROOT_DIR}/build.zig.zon")"
[[ -n "${min_zig}" ]] || fail "cannot read minimum_zig_version from build.zig.zon"
zig_ver="$(zig version)"
if ! awk -v cur="${zig_ver}" -v min="${min_zig}" 'BEGIN {
    ncur = split(cur, c, /[^0-9]+/)
    nmin = split(min, t, /[^0-9]+/)
    for (i = 1; i <= nmin; i++) {
        ci = (i <= ncur) ? (c[i] + 0) : 0
        ti = t[i] + 0
        if (ci < ti) exit 1
        if (ci > ti) exit 0
    }
    exit 0
}'; then
    fail "zig ${zig_ver} is older than minimum_zig_version ${min_zig} in build.zig.zon"
fi

echo "=== zig fmt --check ==="
zig fmt --check src/ build.zig build.zig.zon || fail "zig fmt --check reported unformatted files; fix with: zig build fmt"

echo "=== vendored fuse3 hashes ==="
(
    cd "${ROOT_DIR}/.deps/fuse3-arm64"
    sha256sum -c SHA256SUMS
) || fail "vendored libfuse3 sha256 mismatch; refresh per .deps/fuse3-arm64/README.md"

echo "=== shellcheck ==="
# Defect-oriented optional checks the tree already passes: every case
# statement must handle an unmatched input, bare [ $x ] conditions are
# ambiguous, which(1) is not portable, variables stay quoted even where
# currently safe, a suppressed `set -e` cannot silently downgrade error
# handling, an uppercase-looking assignment is always set before use, and
# a negated numeric comparison ([ ! "$x" -eq 1 ]) is written as its direct
# operator (-ne) so the tested condition is the one a reader sees, a
# return value swallowed by command/process substitution must be either
# propagated or explicitly dismissed with || true, like set -e suppression,
# and cat piped into a filter (which hides cat's exit status) is written as
# a direct redirect so a missing file cannot look like an empty stream.
# The style-only brace/double-bracket checks stay off: this tree does not
# follow those conventions.
shellcheck -o add-default-case,avoid-nullary-conditions,avoid-negated-conditions,deprecate-which,quote-safe-variables,check-set-e-suppressed,check-unassigned-uppercase,check-extra-masked-returns,useless-use-of-cat scripts/*.sh || fail "shellcheck reported violations"

# The NAS drill cannot run here (no zfs pool). The stub suite is what
# keeps a clone-onto-live or empty-snapshot false pass from shipping.
echo "=== restore drill (stub zfs) ==="
"${SCRIPTS_DIR}/test_dr_restore_drill.sh" || fail "restore drill stub tests failed"

# Digests first (coreutils only), then a full extract so a stale-tree or
# unpack-tool regression fails this gate instead of only the aarch64 job.
echo "=== vendored libfuse3 digests ==="
(
    cd "${ROOT_DIR}/.deps/fuse3-arm64"
    sha256sum -c SHA256SUMS
) || fail "vendored libfuse3 integrity check failed; refresh per .deps/fuse3-arm64/README.md"

echo "=== vendored libfuse3 extract ==="
"${SCRIPTS_DIR}/test_extract_fuse3_arm64.sh" || fail "vendored libfuse3 extract tests failed"

echo "=== ruff ==="
ruff check scripts/ || fail "ruff check reported violations"

echo "=== ruff format --check ==="
ruff format --check scripts/ || fail "ruff format --check reported unformatted files; fix with: ruff format scripts/"

echo "=== mypy ==="
mypy scripts/ || fail "mypy reported errors"

echo "=== sbom ==="
python3 "${SCRIPTS_DIR}/sbom.py" --check || fail "sbom.cdx.json is out of date; regenerate with: python3 scripts/sbom.py --write"

# Slowest step last: the linters above are instant, so a lint failure never
# pays for the full compile first.
echo "=== zig build test ==="
zig build test || fail "zig build test failed"

echo "=== All static analysis checks passed ==="
