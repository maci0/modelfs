#!/usr/bin/env bash
# Reproduce every CI job locally as one step: the static gate, the aarch64
# cross compile, and the byte-identical rebuild proof. Same recipes as
# .github/workflows/ci.yml; the cross artifact lands under .scratch so a
# native zig-out/bin/modelfs is not replaced.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "${ROOT_DIR}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: ./scripts/ci.sh

Run every CI job locally (check, aarch64 cross-compile, reproducibility).
See CONTRIBUTING.md and `zig build --help` for the rest of the contributor
commands. Daily loop is ./scripts/check.sh; this is the pre-push full gate.
EOF
    exit 0
fi

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

command -v zig >/dev/null 2>&1 || fail "zig not found on PATH -- see CONTRIBUTING.md (setup section)"

echo "=== CI job: check ==="
"${SCRIPTS_DIR}/check.sh"

echo "=== CI job: cross-aarch64 ==="
"${SCRIPTS_DIR}/extract_fuse3_arm64.sh"
CROSS_PREFIX="${SCRATCH_DIR}/cross-aarch64"
rm -rf "${CROSS_PREFIX}"
mkdir -p "${SCRATCH_DIR}"
"${SCRIPTS_DIR}/cross_aarch64.sh" --prefix "${CROSS_PREFIX}"

echo "=== CI job: reproducibility ==="
"${SCRIPTS_DIR}/repro_check.sh"

echo "=== All CI jobs passed locally ==="
