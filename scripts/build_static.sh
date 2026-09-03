#!/usr/bin/env bash
# Build one static single-file release binary: the daemon plus the vendored
# libfuse3 (.deps/libfuse3-3.16.2) on a musl libc, fully linked -- no
# interpreter, no shared libraries, ASLR kept via static-PIE. The
# .github/workflows/release.yml matrix runs this for both targets on every
# v* tag; locally it needs only zig on PATH.
# usage: build_static.sh <x86_64-linux-musl|aarch64-linux-musl> [--prefix DIR]
set -euo pipefail
export LC_ALL=C
export TZ=UTC

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "${ROOT_DIR}"

usage() {
    cat <<'EOF'
Usage: ./scripts/build_static.sh <x86_64-linux-musl|aarch64-linux-musl> [--prefix DIR]

Build a ReleaseFast single-file static binary for one musl target
(-Dfuse-static compiles the vendored libfuse3 in; see
.deps/libfuse3-3.16.2/README.md). The ELF is then asserted static
(no PT_INTERP, no DT_NEEDED), static-PIE, RELRO-protected, and of the
requested machine. Without --prefix the binary lands at zig-out/bin/modelfs
(replacing whatever target was built last); --prefix DIR installs to
DIR/bin/modelfs -- the release workflow always passes it so the two matrix
legs cannot clobber each other, and a native zig-out/ build survives.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

target="${1:-}"
prefix=""
if [[ "${2:-}" == "--prefix" ]]; then
    if [[ -z "${3:-}" || "${3:0:1}" == "-" ]]; then
        usage >&2
        echo "--prefix needs a directory argument" >&2
        exit 2
    fi
    prefix="${3}"
fi

case "${target}" in
    x86_64-linux-musl) arch=x86_64 machine=3e00 ;;
    aarch64-linux-musl) arch=aarch64 machine=b700 ;;
    *)
        usage >&2
        echo "unsupported target '${target}': this project ships static musl x86_64 and aarch64 only" >&2
        exit 2
        ;;
esac

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

command -v zig >/dev/null || fail "zig not on PATH (minimum_zig_version in build.zig.zon is the toolchain pin)"

flags=(-Dtarget="${target}" -Doptimize=ReleaseFast -Dfuse-static)
if [[ -n "${prefix}" ]]; then
    flags+=(--prefix "${prefix}")
    bin="${prefix}/bin/modelfs"
else
    bin="zig-out/bin/modelfs"
fi

echo "=== static build ${target} ==="
zig build "${flags[@]}"

# shellcheck disable=SC2310 # assert_static_elf returns explicitly, never relies on set -e
assert_static_elf "${bin}" "${machine}" && elf_rc=0 || elf_rc=$?
if [[ ${elf_rc} -ne 0 ]]; then
    fail "static ELF verification failed for ${target}"
fi

size="$(stat -c%s "${bin}")"
echo "static binary: ${bin} (${size} bytes)"
if [[ -n "${prefix}" ]]; then
    cp "${bin}" "${prefix}/modelfs-${arch}-linux-musl"
    echo "release artifact: ${prefix}/modelfs-${arch}-linux-musl"
fi
