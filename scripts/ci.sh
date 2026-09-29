#!/usr/bin/env bash
# Reproduce every CI job locally as one step: the static gate, the aarch64
# cross compile, this host's static musl leg, and the byte-identical rebuild
# proof. Same recipes as .github/workflows/ci.yml; the cross and static
# artifacts land under .scratch so a native zig-out/bin/modelfs is not
# replaced. The static job's other leg is CI's other architecture, so a host
# runs the leg it can execute.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "${ROOT_DIR}"

usage_no_args "$@" <<'EOF'
Usage: ./scripts/ci.sh

Run every CI job locally (check, aarch64 cross-compile, this host's static
musl build and smoke run, reproducibility).
See CONTRIBUTING.md and `zig build --help` for the rest of the contributor
commands. Daily loop is ./scripts/check.sh; this is the pre-push full gate.
EOF

require_zig

echo "=== CI job: check ==="
"${SCRIPTS_DIR}/check.sh"

echo "=== CI job: cross-aarch64 ==="
CROSS_PREFIX="${SCRATCH_DIR}/cross-aarch64"
rm -rf "${CROSS_PREFIX}"
mkdir -p "${SCRATCH_DIR}"
"${SCRIPTS_DIR}/cross_aarch64.sh" --prefix "${CROSS_PREFIX}"

echo "=== CI job: static-linux (this host) ==="
host_arch="$(uname -m)"
case "${host_arch}" in
    x86_64) static_target=x86_64-linux-musl ;;
    aarch64 | arm64) static_target=aarch64-linux-musl ;;
    *) static_target="" ;;
esac
if [[ -z "${static_target}" ]]; then
    echo "skip: ${host_arch} is not a shipped static musl target (x86_64, aarch64)"
else
    STATIC_PREFIX="${SCRATCH_DIR}/static"
    rm -rf "${STATIC_PREFIX}"
    zig build test -Dtarget="${static_target}" -Doptimize=ReleaseFast -Dfuse-static
    "${SCRIPTS_DIR}/build_static.sh" "${static_target}" --prefix "${STATIC_PREFIX}"
    # The ELF asserts read program and dynamic headers, so they pass on a
    # binary that links and then cannot start. `version` exits 0 without
    # touching /dev/fuse, the origin, or the network.
    "${STATIC_PREFIX}/modelfs-${static_target}" version
fi

echo "=== CI job: reproducibility ==="
"${SCRIPTS_DIR}/repro_check.sh"

echo "=== All CI jobs passed locally ==="
