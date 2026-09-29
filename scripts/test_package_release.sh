#!/usr/bin/env bash
# Pins package_release.sh's two properties: the release job can be re-run
# after a partial pass, and a dist an earlier pass already flattened must
# package to the same digests rather than fail on the moved artifacts; and
# the archive it writes is normalized, which is asserted from the bytes of
# the tarball and gzip stream rather than from the script's own comments.
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

Re-run checks for the release packaging script, and assert the archive
metadata (mode, owner, mtime, gzip timestamp) is normalized.
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

# The archive's metadata is the whole reason the tarball can be
# deterministic, and the two runs above share an environment: they would
# agree even if package_release.sh shipped the checkout's mtimes, the
# packing user's uid, and a gzip header timestamp. Read the metadata back
# off the bytes instead of taking the header comment's word for it.
tarball="${DIST}/modelfs-licenses.tar.gz"
gzip_mtime="$(od -An -t x1 -j 4 -N 4 "${tarball}" | tr -d '[:space:]')"
[[ "${gzip_mtime}" == "00000000" ]] \
    || fail "gzip header MTIME bytes are ${gzip_mtime}, not 00000000; -n was dropped from the gzip step"
# tar -tv output: mode, owner/group, size, date, time, then the name.
# A named rc, not a masked one: a tar that failed would list nothing and
# leave the loop below with no entry to complain about.
listing_rc=0
listing="$(tar --numeric-owner --utc --full-time -tvf "${tarball}")" || listing_rc=$?
[[ "${listing_rc}" -eq 0 ]] || fail "cannot list ${tarball} (rc=${listing_rc}); the metadata checks did not run"
[[ -n "${listing}" ]] || fail "${tarball} has no entries; it would ship no licenses"
while IFS= read -r line; do
    read -r perm owner _size date time name <<<"${line}"
    [[ "${perm}" == "-rw-r--r--" && "${owner}" == "0/0" \
        && "${date}" == "1970-01-01" && "${time}" == "00:00:00" ]] \
        || fail "archive entry is not mode 0644, uid/gid 0, mtime 0: ${line}"
    [[ "${name}" == "${line##* }" ]] || fail "could not read the name off archive entry: ${line}"
done <<<"${listing}"

# A second pack of the same inputs into a differently named dist, with the
# timezone and collation moved and a restrictive umask: the release
# workflow's packers are not the contributors running this suite, and
# package_release.sh's own LC_ALL=C/TZ=UTC exports are the only thing
# standing between a Tokyo runner and a different archive. The listing
# above already pins mtime, mode, and owner, so what this leg adds is
# byte-equality of the whole asset set under a foreign environment.
ALT="${SCRATCH_DIR}/package-release-test/another-dist-name"
mkdir -p "${ALT}/rel-x86_64-linux-musl" "${ALT}/rel-aarch64-linux-musl" "${ALT}/rel-sparks"
printf 'x86\n' >"${ALT}/rel-x86_64-linux-musl/modelfs-x86_64-linux-musl"
printf 'aarch64\n' >"${ALT}/rel-aarch64-linux-musl/modelfs-aarch64-linux-musl"
printf 'sparks\n' >"${ALT}/rel-sparks/modelfs"
(
    umask 077
    TZ=Asia/Tokyo LC_ALL=C.UTF-8 SOURCE_DATE_EPOCH=1700000000 \
        "${SCRIPTS_DIR}/package_release.sh" --dist "${ALT}"
) >"${SCRATCH_DIR}/package-release-test/run-alt.log"
for asset in modelfs-x86_64-linux-musl modelfs-aarch64-linux-musl modelfs-aarch64-linux-gnu; do
    cmp -s "${DIST}/${asset}" "${ALT}/${asset}" \
        || fail "${asset} differs between two packs of the same input"
done
# SOURCE_DATE_EPOCH is honored, so that leg's tarball is deliberately not
# the first leg's; it must still be the same three binaries. Leaving it
# unset, the varied environment alone is what must not move a byte.
(
    umask 077
    TZ=Asia/Tokyo LC_ALL=C.UTF-8 \
        "${SCRIPTS_DIR}/package_release.sh" --dist "${ALT}"
) >"${SCRATCH_DIR}/package-release-test/run-alt2.log"
cmp -s "${tarball}" "${ALT}/modelfs-licenses.tar.gz" \
    || fail "modelfs-licenses.tar.gz changed with TZ, LC_ALL, or umask; the archive metadata is not fully normalized"
cmp -s "${DIST}/SHA256SUMS" "${ALT}/SHA256SUMS" \
    || fail "SHA256SUMS changed with TZ, LC_ALL, or umask"

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
