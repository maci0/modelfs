#!/usr/bin/env bash
# Rebuild-and-compare proof of the release reproducibility documented in
# CONTRIBUTING ("Cutting a release"): builds the ReleaseFast binary twice
# from two independently named copies of the tracked sources, varying the
# timezone, locale, and SOURCE_DATE_EPOCH the second build sees, then fails
# unless both zig-out/bin/modelfs are byte-identical. CI runs this as its own
# job, so the claim stays enforced rather than merely documented.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

for tool in git zig sha256sum; do
    command -v "${tool}" >/dev/null 2>&1 || fail "${tool} not found on PATH"
done

BUILD_A="${SCRATCH_DIR}/repro-a"
BUILD_B="${SCRATCH_DIR}/repro-this-path-name-is-intentionally-much-longer-to-move-the-build-root"

cleanup() {
    rm -rf "${BUILD_A}" "${BUILD_B}"
}
trap cleanup EXIT

mkdir -p "${SCRATCH_DIR}"
rm -rf "${BUILD_A}" "${BUILD_B}"
mkdir -p "${BUILD_A}" "${BUILD_B}"

# Copy exactly what git tracks: local uncommitted edits ride along (the check
# tests current state), but build outputs and crash dumps cannot. A file still
# in the index but deleted from the worktree is skipped with a warning instead
# of failing the copy.
(
    cd "${ROOT_DIR}"
    git ls-files -z | tar --null --ignore-failed-read -T - -cf - | tar -xf - -C "${BUILD_A}"
    git ls-files -z | tar --null --ignore-failed-read -T - -cf - | tar -xf - -C "${BUILD_B}"
)

build_one() {
    # $1: tree root; remaining args: environment assignments for this build.
    # Each build gets its own cache dirs so neither can serve the other cached
    # results, and so an ambient ZIG_*_CACHE_DIR cannot make them share one.
    local dir="${1}"
    shift
    (
        cd "${dir}"
        env \
            ZIG_LOCAL_CACHE_DIR="${dir}/.zig-cache" \
            ZIG_GLOBAL_CACHE_DIR="${dir}/zig-global-cache" \
            "$@" \
            zig build -Doptimize=ReleaseFast
    )
}

echo "=== Build 1: short path, default TZ/locale ==="
build_one "${BUILD_A}"

echo "=== Build 2: long path, TZ=Asia/Tokyo, LC_ALL=C.UTF-8, fixed SOURCE_DATE_EPOCH ==="
build_one "${BUILD_B}" TZ=Asia/Tokyo LC_ALL=C.UTF-8 SOURCE_DATE_EPOCH=1234567890

BIN_A="${BUILD_A}/zig-out/bin/modelfs"
BIN_B="${BUILD_B}/zig-out/bin/modelfs"
[[ -f "${BIN_A}" ]] || fail "build 1 produced no binary at ${BIN_A}"
[[ -f "${BIN_B}" ]] || fail "build 2 produced no binary at ${BIN_B}"

sha256sum "${BIN_A}" "${BIN_B}"
if cmp -s "${BIN_A}" "${BIN_B}"; then
    echo "=== Reproducible: both builds produced byte-identical binaries ==="
else
    fail "the two builds differ in bytes; inspect with: diffoscope ${BIN_A} ${BIN_B}"
fi
