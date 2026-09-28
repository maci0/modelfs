#!/usr/bin/env bash
# Pins package_release.sh's re-run property: the release job can be re-run
# after a partial pass, and a dist an earlier pass already flattened must
# package to the same digests rather than fail on the moved artifacts.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "${ROOT_DIR}"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

usage_no_args "$@" <<'EOF'
Usage: ./scripts/test_package_release.sh

Re-run checks for the release packaging script.
EOF

DIST="${SCRATCH_DIR}/package-release-test/dist"
rm -rf "${SCRATCH_DIR}/package-release-test"
mkdir -p "${DIST}/rel-x86_64-linux-musl" "${DIST}/rel-aarch64-linux-musl" "${DIST}/rel-sparks"
printf 'x86\n' >"${DIST}/rel-x86_64-linux-musl/modelfs-x86_64-linux-musl"
printf 'aarch64\n' >"${DIST}/rel-aarch64-linux-musl/modelfs-aarch64-linux-musl"
printf 'sparks\n' >"${DIST}/rel-sparks/modelfs"

"${SCRIPTS_DIR}/package_release.sh" --dist "${DIST}" >"${SCRATCH_DIR}/package-release-test/run1.log"
cp "${DIST}/SHA256SUMS" "${SCRATCH_DIR}/package-release-test/sums1"

# Second execution over the same dist: the rel-* sources are gone, so this
# is the pass that used to abort with "missing release artifact".
"${SCRIPTS_DIR}/package_release.sh" --dist "${DIST}" >"${SCRATCH_DIR}/package-release-test/run2.log"
cmp -s "${SCRATCH_DIR}/package-release-test/sums1" "${DIST}/SHA256SUMS" \
    || fail "a rerun produced different digests than the first run"

for asset in modelfs-x86_64-linux-musl modelfs-aarch64-linux-musl modelfs-aarch64-linux-gnu modelfs-licenses.tar.gz; do
    [[ -f "${DIST}/${asset}" ]] || fail "rerun left ${asset} missing"
    [[ -x "${DIST}/${asset}" ]] || [[ "${asset}" == "modelfs-licenses.tar.gz" ]] \
        || fail "rerun left ${asset} without the executable bit"
done
[[ ! -d "${DIST}/rel-sparks" ]] || fail "rerun left the emptied rel-sparks directory"

# A genuinely absent artifact must still fail: converging on an already
# flattened name is not a licence to publish a dist that never had one.
mv "${DIST}/modelfs-aarch64-linux-gnu" "${SCRATCH_DIR}/package-release-test/held"
rc=0
"${SCRIPTS_DIR}/package_release.sh" --dist "${DIST}" >"${SCRATCH_DIR}/package-release-test/run3.log" 2>&1 || rc=$?
[[ "${rc}" -eq 1 ]] || fail "a dist missing an artifact exited ${rc}, want 1"
grep -q 'missing release artifact' "${SCRATCH_DIR}/package-release-test/run3.log" \
    || fail "a dist missing an artifact did not name it; see ${SCRATCH_DIR}/package-release-test/run3.log"
mv "${SCRATCH_DIR}/package-release-test/held" "${DIST}/modelfs-aarch64-linux-gnu"

rm -rf "${SCRATCH_DIR}/package-release-test"

echo "=== package_release rerun ok ==="
