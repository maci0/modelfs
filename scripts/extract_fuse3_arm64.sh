#!/usr/bin/env bash
# Single extractor for the vendored arm64 libfuse3 tree, used by
# scripts/cross_aarch64.sh (and so by CI's cross-aarch64 job and
# scripts/ci.sh): verifies the committed .deb digests, wipes the output
# directory, then unpacks. Output is .scratch/fuse3-arm64 by default so a
# previous extract cannot leave stale headers or mutate .deps/.
#
# The extractor prefers dpkg-deb (Debian-family). Other distros: a .deb is
# an ar archive whose data.tar.zst holds the filesystem, unpacked with
# binutils ar plus zstd (or tar --zstd).
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: ./scripts/extract_fuse3_arm64.sh [--out DIR]

Verify the vendored arm64 libfuse3 .deb digests (SHA256SUMS) and extract
them. Without --out the tree lands at .scratch/fuse3-arm64/{root,lib},
which scripts/cross_aarch64.sh consumes. --out DIR must not be / .
EOF
}

ORIG_PWD="$(pwd)"
OUT="${SCRATCH_DIR}/fuse3-arm64"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -gt 0 ]]; then
    if [[ "$1" != "--out" || $# -ne 2 || -z "${2}" ]]; then
        usage >&2
        exit 2
    fi
    OUT="$2"
fi

if [[ "${OUT}" != /* ]]; then
    OUT="${ORIG_PWD}/${OUT}"
fi
OUT="${OUT%/}"
[[ -n "${OUT}" && "${OUT}" != "/" ]] || fail "refusing --out '${OUT}'"

DEB_DIR="${ROOT_DIR}/.deps/fuse3-arm64"
SUMS="${DEB_DIR}/SHA256SUMS"

command -v sha256sum >/dev/null 2>&1 || fail "sha256sum not found on PATH"

[[ -f "${SUMS}" ]] || fail "${SUMS} missing; it is the digest list for the vendored .deb files"

# Fail on a drifted or truncated .deb before unpacking anything.
(
    cd "${DEB_DIR}"
    sha256sum -c SHA256SUMS
) || fail "vendored libfuse3 digest mismatch; refresh per ${DEB_DIR}/README.md"

extract_one() {
    local deb_path="${DEB_DIR}/$1"
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "${deb_path}" "${OUT}/root/"
        return 0
    fi
    if command -v ar >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
        # A .deb is an ar archive whose data.tar.zst holds the filesystem.
        # Unpack in scratch, not next to the tracked .deb files: ar writes
        # members into cwd, and a killed extract used to leave a committable
        # data.tar.zst under .deps/fuse3-arm64/.
        local data_tar="data.tar.zst" tmp
        mkdir -p "${SCRATCH_DIR}"
        tmp="$(mktemp -d "${SCRATCH_DIR}/deb-XXXXXX")"
        if ! (
            cd "${tmp}"
            ar x "${deb_path}" "${data_tar}"
            # Prefer the zstd binary; GNU tar 1.31+ also understands --zstd
            # on hosts that ship the flag but not a zstd executable on PATH.
            if command -v zstd >/dev/null 2>&1; then
                zstd -dc "${data_tar}" | tar -xf - -C "${OUT}/root/"
            else
                tar_help="$(tar --help 2>/dev/null || true)"
                if [[ "${tar_help}" == *--zstd* ]]; then
                    tar --zstd -xf "${data_tar}" -C "${OUT}/root/"
                else
                    exit 1
                fi
            fi
        ); then
            rm -rf "${tmp}"
            fail "failed to extract $1 via ar/tar (need zstd or tar --zstd)"
        fi
        rm -rf "${tmp}"
        return 0
    fi
    fail "need dpkg-deb, or binutils ar plus zstd (or tar --zstd), to extract $1"
}

# Wipe first: overlaying a new extract onto a previous tree would keep
# headers and examples the newer .deb no longer ships. ${OUT:?} so an
# empty expansion cannot become rm -rf /lib.
rm -rf "${OUT:?}/root" "${OUT:?}/lib"
mkdir -p "${OUT}/root" "${OUT}/lib"

names="$(awk 'NF >= 2 && $1 !~ /^#/ { print $2 }' "${SUMS}")" || fail "cannot parse ${SUMS}"
[[ -n "${names}" ]] || fail "${SUMS} lists no files"
extracted=0
while IFS= read -r filename; do
    filename="${filename#\*}"
    [[ -n "${filename}" ]] || continue
    extract_one "${filename}"
    extracted=$((extracted + 1))
done <<<"${names}"
[[ "${extracted}" -gt 0 ]] || fail "${SUMS} lists no files"

# Convenience symlinks so -Dfuse-lib resolves libfuse3.so (-n replaces an
# existing link, so a re-run after a refresh cannot fail on it).
ln -sfn libfuse3.so.3 "${OUT}/lib/libfuse3.so"
ln -sfn ../root/lib/aarch64-linux-gnu/libfuse3.so.3.14.0 "${OUT}/lib/libfuse3.so.3"

echo "Extracted vendored arm64 libfuse3 into ${OUT}/{root,lib}"
