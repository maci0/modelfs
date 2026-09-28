#!/usr/bin/env bash
# Arrange and checksum the release assets in a directory, deterministically.
# .github/workflows/release.yml's publish job runs this instead of inlining
# the tar and sha256sum recipes in YAML, where no gate could shellcheck them
# or exercise them. Three steps, in this order:
#
#   1. flatten the rel-<target>/ directories the upload/download artifact
#      steps produce into one directory, giving each binary its release name
#   2. build modelfs-licenses.tar.gz from the tracked license and NOTICE
#      files, with normalized archive metadata
#   3. write SHA256SUMS over every asset, in a fixed order
#
# The tarball is deterministic: entries sorted by name, mtime pinned,
# uid/gid 0, and a gzip stream carrying no name or timestamp. SOURCE_DATE_EPOCH
# is honored when set (reproducible-builds.org) and falls back to 0, so the
# archive is byte-identical either way rather than tracking checkout mtimes.
# The binary step does not touch the binaries themselves; the release
# workflow runs the host-arch one as a smoke test after this.
set -euo pipefail
export LC_ALL=C
export TZ=UTC

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "${ROOT_DIR}"

usage() {
    cat <<'EOF'
Usage: ./scripts/package_release.sh --dist DIR

Flatten the rel-<target>/ artifact directories into DIR under their release
names, write DIR/modelfs-licenses.tar.gz with normalized metadata, and
write DIR/SHA256SUMS over every asset in a fixed order. Deterministic: two
runs over the same inputs produce byte-identical outputs, and a rerun over
a dist an earlier pass already flattened converges on the same digests
instead of failing on the moved artifacts.

Called by .github/workflows/release.yml. Run it after the build jobs have
uploaded their artifacts, before `gh release create`.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
if [[ $# -ne 2 || "$1" != "--dist" || -z "$2" || "${2:0:1}" == "-" ]]; then
    usage >&2
    exit 2
fi

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

DIST="$2"
[[ -d "${DIST}" ]] || fail "--dist ${DIST} is not a directory"

# The rel- prefix keeps the artifact directories from colliding with the
# binaries' own names on upload. Flatten to the release names below; the
# sparks artifact is a single file named just "modelfs", so it is renamed
# here too.
mv_dist() {
    local from="$1" to="$2"
    if [[ ! -e "${from}" ]]; then
        # A rerun over an already-flattened dist: the artifact was moved by
        # an earlier pass that then failed before publishing, and the
        # destination it produced is the one this run would have written.
        # Treating the missing source as fatal would make the step
        # un-rerunnable, which is the case the release job hits when a
        # re-run resumes after the upload step succeeded.
        [[ -e "${to}" ]] || fail "missing release artifact ${from}"
        echo "already flattened ${to}"
        return 0
    fi
    mv -f -- "${from}" "${to}"
}
mv_dist "${DIST}/rel-x86_64-linux-musl/modelfs-x86_64-linux-musl" "${DIST}/modelfs-x86_64-linux-musl"
mv_dist "${DIST}/rel-aarch64-linux-musl/modelfs-aarch64-linux-musl" "${DIST}/modelfs-aarch64-linux-musl"
mv_dist "${DIST}/rel-sparks/modelfs" "${DIST}/modelfs-aarch64-linux-gnu"
for rel_dir in rel-x86_64-linux-musl rel-aarch64-linux-musl rel-sparks; do
    # Only the directories this run emptied: a rerun over a dist whose
    # rel-* directories an earlier pass already removed has nothing to
    # remove, and rmdir on a missing path is an error under set -e.
    [[ -d "${DIST}/${rel_dir}" ]] || continue
    rmdir "${DIST}/${rel_dir}" \
        || fail "could not remove the emptied ${rel_dir} directory under ${DIST}"
done

# Every third-party license the shipped binary and its static inputs carry.
# A path added here is bundled; a license added to the tree is not, so this
# list is the one place to update when vendored input changes.
licenses=(
    LICENSE
    .deps/libfuse3-3.16.2/LICENSE
    .deps/libfuse3-3.16.2/LGPL2.txt
    .deps/libfuse3-3.16.2/GPL2.txt
    .deps/libfuse3-3.16.2/README.md
    .deps/fuse3-arm64/NOTICE
    .deps/fuse3-arm64/copyright
    .deps/fuse3-arm64/README.md
)
for f in "${licenses[@]}"; do
    [[ -f "${f}" ]] || fail "license file ${f} is missing; it cannot be bundled"
done

# gzip reads the tar from a pipe, so it already records no name and no
# timestamp; -n states that intent rather than relying on it.
tar --format=gnu --sort=name --mtime="@${SOURCE_DATE_EPOCH:-0}" --owner=0 --group=0 \
    --numeric-owner --mode=0644 -cf - "${licenses[@]}" \
    | gzip -n >"${DIST}/modelfs-licenses.tar.gz"

# Written fresh so a leftover file from an earlier layout cannot leave a
# stale digest line in the published list. LC_ALL=C is exported above: the
# glob expands in collation order, and a locale-dependent order would make
# the SHA256SUMS bytes themselves differ between runners.
rm -f "${DIST}/SHA256SUMS"
(
    cd "${DIST}"
    # Includes modelfs-licenses.tar.gz, so the lines name exactly the
    # assets a downloader sees.
    sha256sum modelfs-*
) >"${DIST}/SHA256SUMS"
cat "${DIST}/SHA256SUMS"
# upload-artifact does not promise to preserve the executable bit, so set it
# on every binary rather than assuming it survived the round trip.
chmod +x "${DIST}"/modelfs-x86_64-linux-musl "${DIST}"/modelfs-aarch64-linux-musl \
    "${DIST}"/modelfs-aarch64-linux-gnu
echo "packaged release assets in ${DIST}"
