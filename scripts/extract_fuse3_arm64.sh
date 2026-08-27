#!/usr/bin/env bash
# Single extractor for the vendored arm64 libfuse3 tree, used by CI's
# cross-aarch64 job and by local cross builds alike: the recipe used to live
# as three hand-synced copies (.github/workflows/ci.yml, README Build,
# .deps/fuse3-arm64/README.md) that could drift apart silently.
#
# Idempotent: safe to re-run after refreshing the .deb files; the lib/
# symlinks are replaced in place instead of dying on an existing link.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
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
    elif command -v ar >/dev/null 2>&1 && command -v tar >/dev/null 2>&1 && command -v zstd >/dev/null 2>&1; then
        # A .deb is an ar archive whose data.tar.zst holds the filesystem;
        # this reproduces what dpkg-deb -x does on non-Debian hosts.
        # Unpack in scratch, not next to the tracked .deb files: ar writes
        # members into cwd, and a killed extract used to leave a committable
        # data.tar.zst under .deps/fuse3-arm64/.
        local data_tar="data.tar.zst" tmp
        mkdir -p "${SCRATCH_DIR}"
        tmp="$(mktemp -d "${SCRATCH_DIR}/deb-XXXXXX")"
        if ! (
            cd "${tmp}"
            ar x "${DEB_DIR}/$1" "${data_tar}"
            # GNU tar 1.31+ understands --zstd; older tar still works when the
            # zstd binary is on PATH (Arch, Rocky, and similar without dpkg).
            if command -v zstd >/dev/null 2>&1; then
                zstd -dc "${data_tar}" | tar -xf - -C "${DEB_DIR}/root/"
            else
                tar_help="$(tar --help 2>/dev/null || true)"
                if [[ "${tar_help}" == *--zstd* ]]; then
                    tar --zstd -xf "${data_tar}" -C "${DEB_DIR}/root/"
                else
                    exit 1
                fi
            fi
        ); then
            rm -rf "${tmp}"
            fail "failed to extract $1 via ar/tar"
        fi
        rm -rf "${tmp}"
    else
        fail "need dpkg-deb, or binutils ar plus zstd (or tar --zstd), to extract $1"
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
