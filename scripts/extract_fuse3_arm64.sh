#!/usr/bin/env bash
# Single extractor for the vendored arm64 libfuse3 tree, used by CI's
# cross-aarch64 job and by local cross builds alike: the recipe used to live
# as three hand-synced copies (.github/workflows/ci.yml, README Build,
# .deps/fuse3-arm64/README.md) that could drift apart silently.
#
# Idempotent: safe to re-run after refreshing the .deb files; the lib/
# symlinks are replaced in place instead of dying on an existing link.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEB_DIR="${ROOT_DIR}/.deps/fuse3-arm64"

DEBS=(
    libfuse3-3_3.14.0-5build1_arm64.deb
    libfuse3-dev_3.14.0-5build1_arm64.deb
)

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

cd "${DEB_DIR}"

for deb in "${DEBS[@]}"; do
    # build.zig verifies the digests later, so only presence is checked here:
    # a missing file gets named now with where to re-fetch it (Provenance
    # section) instead of a bare dpkg-deb "No such file".
    [[ -f "${deb}" ]] || fail "${deb} missing in ${DEB_DIR}; re-download it per the Provenance section of ${DEB_DIR}/README.md"
done

extract_one() {
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "$1" root/
    elif command -v ar >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
        # A .deb is an ar archive whose data.tar.zst holds the filesystem;
        # this reproduces what dpkg-deb -x does on non-Debian hosts.
        local data_tar="data.tar.zst"
        ar x "$1" "${data_tar}"
        tar --zstd -xf "${data_tar}" -C root/
        rm "${data_tar}"
    else
        fail "need dpkg-deb, or binutils ar plus a zstd-capable tar, to extract $1"
    fi
}

mkdir -p root lib
for deb in "${DEBS[@]}"; do
    extract_one "${deb}"
done

# Convenience symlinks so -Dfuse-lib resolves libfuse3.so (-n replaces an
# existing link, so a re-run after a refresh cannot fail on it).
ln -sfn libfuse3.so.3 lib/libfuse3.so
ln -sfn ../root/lib/aarch64-linux-gnu/libfuse3.so.3.14.0 lib/libfuse3.so.3

echo "Extracted vendored arm64 libfuse3 into ${DEB_DIR}/{root,lib}"
