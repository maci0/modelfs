#!/usr/bin/env bash
# Cross-compile the spark-node binary the way CI's cross-aarch64 job does:
# aarch64-linux-gnu.2.39, ReleaseFast, vendored arm64 libfuse3. Extracts the
# committed .deb files first (scripts/extract_fuse3_arm64.sh). Both
# .github/workflows/ci.yml and scripts/ci.sh run this, so the flags cannot
# drift apart the way the old inlined extract recipe used to.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "${ROOT_DIR}"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: ./scripts/cross_aarch64.sh [--prefix DIR]

Cross-compile ReleaseFast aarch64 against the vendored arm64 libfuse3.
Extracts the committed .deb files into .scratch/fuse3-arm64 first.
Without --prefix the binary lands at zig-out/bin/modelfs; --prefix DIR
installs to DIR/bin/modelfs (used by scripts/ci.sh so a native zig-out/
is not replaced).
EOF
    exit 0
fi

PREFIX=""
if [[ $# -gt 0 ]]; then
    if [[ "$1" != "--prefix" || $# -ne 2 || -z "${2}" ]]; then
        echo "usage: ./scripts/cross_aarch64.sh [--prefix DIR]" >&2
        exit 2
    fi
    PREFIX="$2"
fi

command -v od >/dev/null 2>&1 || fail "od not found on PATH (used to assert the aarch64 ELF machine type)"
require_zig

"${SCRIPTS_DIR}/extract_fuse3_arm64.sh"
FUSE_INC="${SCRATCH_DIR}/fuse3-arm64/root/usr/include/fuse3"
FUSE_LIB="${SCRATCH_DIR}/fuse3-arm64/lib"
[[ -d "${FUSE_INC}" ]] || fail "missing ${FUSE_INC} after extract"
[[ -d "${FUSE_LIB}" ]] || fail "missing ${FUSE_LIB} after extract"

build_args=(
    zig build
    -Dtarget=aarch64-linux-gnu.2.39
    -Doptimize=ReleaseFast
    "-Dfuse-include=${FUSE_INC}"
    "-Dfuse-lib=${FUSE_LIB}"
)
if [[ -n "${PREFIX}" ]]; then
    build_args+=(--prefix "${PREFIX}")
    bin="${PREFIX}/bin/modelfs"
else
    bin="${ROOT_DIR}/zig-out/bin/modelfs"
fi

"${build_args[@]}"
[[ -f "${bin}" ]] || fail "cross-aarch64 produced no binary at ${bin}"
# shellcheck disable=SC2310 # assert_aarch64_elf returns explicitly, never relies on set -e
assert_aarch64_elf "${bin}" && elf_rc=0 || elf_rc=$?
[[ "${elf_rc}" -eq 0 ]] || fail "cross-aarch64 produced a binary that is not ARM aarch64: ${bin}"
echo "cross-aarch64: ELF 64-bit LSB aarch64 ${bin}"
