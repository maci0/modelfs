#!/usr/bin/env bash
# Pins extract_fuse3_arm64.sh hermeticity: the committed .deb digests must
# match SHA256SUMS, a previous extract's leftover files must not survive,
# and the header/library layout scripts/cross_aarch64.sh consumes must exist.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "${ROOT_DIR}"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

usage_no_args "$@" <<'EOF'
Usage: ./scripts/test_extract_fuse3_arm64.sh

Hermeticity checks for the vendored arm64 libfuse3 extractor.
EOF

OUT="${SCRATCH_DIR}/extract-fuse3-test"
rm -rf "${OUT}"
mkdir -p "${OUT}/root/leftover-from-previous-extract"
echo stale >"${OUT}/root/STALE"
echo stale >"${OUT}/root/leftover-from-previous-extract/STALE"

"${SCRIPTS_DIR}/extract_fuse3_arm64.sh" --out "${OUT}"

[[ ! -e "${OUT}/root/STALE" ]] || fail "stale file survived extract into ${OUT}/root"
[[ ! -e "${OUT}/root/leftover-from-previous-extract" ]] || fail "stale directory survived extract into ${OUT}/root"
[[ -f "${OUT}/root/usr/include/fuse3/fuse.h" ]] || fail "missing fuse.h after extract"
[[ -L "${OUT}/lib/libfuse3.so" ]] || fail "missing libfuse3.so linker symlink"
[[ -L "${OUT}/lib/libfuse3.so.3" ]] || fail "missing libfuse3.so.3 soname symlink"

echo "=== extract_fuse3_arm64 hermetic extract ok ==="
