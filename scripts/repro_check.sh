#!/usr/bin/env bash
# Rebuild-and-compare proof of the release reproducibility documented in
# CONTRIBUTING ("Cutting a release"): for every shipped build recipe, builds
# the ReleaseFast binary twice from two independently named copies of the
# tracked sources, varying the timezone, locale, and SOURCE_DATE_EPOCH the
# second build sees, then fails unless both binaries are byte-identical.
# The recipes are the host glibc build and the two musl static single-file
# release targets (--fuse-static compiles the vendored libfuse3 in), so the
# claim stays enforced for exactly the artifacts releases ship rather than
# merely documented. CI runs this as its own job.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage_no_args "$@" <<'EOF'
Usage: ./scripts/repro_check.sh

For each shipped build recipe (host glibc, x86_64-linux-musl static,
aarch64-linux-musl static): two ReleaseFast builds from differently named
trees (TZ/locale varied); fails unless the binaries are byte-identical.
Same recipes as CI's reproducibility job. See CONTRIBUTING.md (Cutting a
release).
EOF

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

require_zig
for tool in git sha256sum; do
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
# of failing the copy. The vendored libfuse3 static source ships tracked, so
# the -Dfuse-static recipe works from these copies.
(
    cd "${ROOT_DIR}"
    git ls-files -z | tar --null --ignore-failed-read -T - -cf - | tar -xf - -C "${BUILD_A}"
    git ls-files -z | tar --null --ignore-failed-read -T - -cf - | tar -xf - -C "${BUILD_B}"
)

# One build leg: $1 tree root, $2 cache tag (every leg gets its own cache
# dirs so no leg can serve another cached results, and so an ambient
# ZIG_*_CACHE_DIR cannot make them share one), then environment assignments,
# then `--`, then the zig build arguments.
build_one() {
    local dir="$1" cache_tag="$2"
    shift 2
    local env_args=()
    while [[ "${1:-}" != "--" ]]; do
        env_args+=("$1")
        shift
    done
    shift
    (
        cd "${dir}"
        env \
            ZIG_LOCAL_CACHE_DIR="${dir}/.zig-cache-${cache_tag}" \
            ZIG_GLOBAL_CACHE_DIR="${dir}/zig-global-cache" \
            "${env_args[@]}" \
            "$@"
    )
}

# One full comparison: two legs, byte-compare. $1 label, remaining: the zig
# build arguments both legs share (after their `--` marker in build_one).
run_repro() {
    local label="$1"
    shift
    echo "=== [${label}] Build 1: short path, default TZ/locale ==="
    build_one "${BUILD_A}" "${label}" -- zig build -Doptimize=ReleaseFast "$@"
    echo "=== [${label}] Build 2: long path, TZ=Asia/Tokyo, LC_ALL=C.UTF-8, fixed SOURCE_DATE_EPOCH ==="
    build_one "${BUILD_B}" "${label}" -- env TZ=Asia/Tokyo LC_ALL=C.UTF-8 SOURCE_DATE_EPOCH=1234567890 zig build -Doptimize=ReleaseFast "$@"

    local bin_a="${BUILD_A}/zig-out/bin/modelfs" bin_b="${BUILD_B}/zig-out/bin/modelfs"
    [[ -f "${bin_a}" ]] || fail "[${label}] build 1 produced no binary at ${bin_a}"
    [[ -f "${bin_b}" ]] || fail "[${label}] build 2 produced no binary at ${bin_b}"

    sha256sum "${bin_a}" "${bin_b}"
    if cmp -s "${bin_a}" "${bin_b}"; then
        echo "=== [${label}] Reproducible: both builds produced byte-identical binaries ==="
    else
        fail "[${label}] the two builds differ in bytes; inspect with: diffoscope ${bin_a} ${bin_b}"
    fi
}

# The shipped build recipes, in release order. The musl recipes are the
# static single-file release targets; their bytes must not depend on the
# build tree any more than the host build's.
run_repro "host-glibc" --
run_repro "x86_64-linux-musl" -- -Dtarget=x86_64-linux-musl -Dfuse-static
run_repro "aarch64-linux-musl" -- -Dtarget=aarch64-linux-musl -Dfuse-static
