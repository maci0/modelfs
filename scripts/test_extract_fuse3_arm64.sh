#!/usr/bin/env bash
# Pins extract_fuse3_arm64.sh hermeticity: the committed .deb digests must
# match SHA256SUMS, a previous extract's leftover files must not survive,
# and the header/library layout scripts/cross_aarch64.sh consumes must exist.
set -euo pipefail
export LC_ALL=C
export TZ=UTC

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
# -L is true for a dangling link; -e follows it. A hardcoded soname left
# behind after a .deb refresh used to pass the extract suite and fail only
# in the aarch64 job.
[[ -e "${OUT}/lib/libfuse3.so" ]] || fail "dangling libfuse3.so linker symlink"
[[ -e "${OUT}/lib/libfuse3.so.3" ]] || fail "dangling libfuse3.so.3 soname symlink"

tool_path="${OUT}/tools-without-zstd"
missing_out="${OUT}/missing-tools"
mkdir -p "${tool_path}" "${missing_out}/root"
for tool in bash dirname sha256sum mkdir rm mktemp tar awk; do
    tool_bin="$(command -v "${tool}")"
    ln -s "${tool_bin}" "${tool_path}/${tool}"
done
tool_bin="$(type -P true)"
ln -s "${tool_bin}" "${tool_path}/ar"
printf 'preserve previous extract\n' >"${missing_out}/root/KEEP"
rc=0
PATH="${tool_path}" "${SCRIPTS_DIR}/extract_fuse3_arm64.sh" --out "${missing_out}" >"${OUT}/missing-tools.log" 2>&1 || rc=$?
[[ "${rc}" -eq 1 ]] || fail "missing zstd exited ${rc}, want 1"
output="$(cat "${OUT}/missing-tools.log")"
[[ "${output}" == *"need dpkg-deb, or binutils ar plus tar and zstd"* ]] || fail "missing zstd did not name the required tools: ${output}"
[[ -f "${missing_out}/root/KEEP" ]] || fail "missing tools destroyed the previous extract"
rm -rf "${tool_path}" "${missing_out}" "${OUT}/missing-tools.log"

echo "=== extract_fuse3_arm64 hermetic extract ok ==="

# Same ELF-machine gate scripts/cross_aarch64.sh runs after the link, so a
# wording change in file(1) cannot silently replace the byte check.
echo "=== aarch64 ELF header check ==="
elf_ok="${OUT}/fake-aarch64"
elf_x86="${OUT}/fake-x86_64"
elf_be="${OUT}/fake-be"
# 20-byte ELF prefix: magic, EI_CLASS, EI_DATA, pad to e_machine at 18.
printf '\177ELF\002\001\000\000\000\000\000\000\000\000\000\000\000\000\267\000' >"${elf_ok}"
printf '\177ELF\002\001\000\000\000\000\000\000\000\000\000\000\000\000\076\000' >"${elf_x86}"
printf '\177ELF\002\002\000\000\000\000\000\000\000\000\000\000\000\000\000\267' >"${elf_be}"
# shellcheck disable=SC2310 # assert_aarch64_elf returns explicitly, never relies on set -e
assert_aarch64_elf "${elf_ok}" && ok_rc=0 || ok_rc=$?
[[ "${ok_rc}" -eq 0 ]] || fail "assert_aarch64_elf rejected a 64-bit LE aarch64 header"
# shellcheck disable=SC2310 # assert_aarch64_elf returns explicitly, never relies on set -e
assert_aarch64_elf "${elf_x86}" 2>/dev/null && x86_rc=0 || x86_rc=$?
[[ "${x86_rc}" -ne 0 ]] || fail "assert_aarch64_elf accepted an x86_64 e_machine"
# shellcheck disable=SC2310 # assert_aarch64_elf returns explicitly, never relies on set -e
assert_aarch64_elf "${elf_be}" 2>/dev/null && be_rc=0 || be_rc=$?
[[ "${be_rc}" -ne 0 ]] || fail "assert_aarch64_elf accepted a big-endian ELF ident"
echo "=== aarch64 ELF header check ok ==="

# The static-release gate scripts/build_static.sh runs after the link.
# A header that is ET_DYN, the right machine, RELRO, and no DT_NEEDED but
# whose GNU_STACK is executable used to pass: the walk named PT_GNU_STACK
# and then asserted nothing about it.
echo "=== static ELF header check ==="
static_dir="${OUT}/static-elf"
mkdir -p "${static_dir}"
# Minimal ELF64 images, written by python3: ET_DYN, EM_X86_64, one DT_NULL,
# PT_GNU_RELRO, and a PT_GNU_STACK that is RW (good), RWE (ok), or absent
# (nostack).
python3 - "${static_dir}" <<'PY'
import struct
import sys
from pathlib import Path

dest = Path(sys.argv[1])
PT_DYNAMIC, PT_GNU_STACK, PT_GNU_RELRO = 2, 0x6474E551, 0x6474E552
PF_R, PF_W, PF_X = 4, 2, 1


def image(phnum: int, stack_flags: int) -> bytes:
    phoff, phentsize = 64, 56
    dyn_off = phoff + 3 * phentsize
    elf = bytearray(dyn_off + 16)
    elf[0:16] = b"\x7fELF\x02\x01\x01" + bytes(9)
    struct.pack_into("<HHIQQQIHHHHHH", elf, 16, 3, 0x3E, 1, 0, phoff, 0, 0, 64, phentsize, phnum, 0, 0, 0)

    def phdr(index: int, p_type: int, p_flags: int, p_offset: int, p_filesz: int) -> None:
        struct.pack_into("<IIQQQQQQ", elf, phoff + index * phentsize, p_type, p_flags, p_offset, p_offset, p_offset, p_filesz, p_filesz, 8)

    phdr(0, PT_GNU_RELRO, PF_R, 0, 0)
    phdr(1, PT_DYNAMIC, PF_R | PF_W, dyn_off, 16)
    if phnum > 2:
        phdr(2, PT_GNU_STACK, stack_flags, 0, 0)
    return bytes(elf)


(dest / "good").write_bytes(image(3, PF_R | PF_W))
(dest / "ok").write_bytes(image(3, PF_R | PF_W | PF_X))
(dest / "nostack").write_bytes(image(2, 0))
PY
# shellcheck disable=SC2310 # assert_static_elf returns explicitly, never relies on set -e
assert_static_elf "${static_dir}/good" 3e00 && static_ok_rc=0 || static_ok_rc=$?
[[ "${static_ok_rc}" -eq 0 ]] || fail "assert_static_elf rejected a static-PIE with a non-executable stack"
# shellcheck disable=SC2310 # assert_static_elf returns explicitly, never relies on set -e
assert_static_elf "${static_dir}/ok" 3e00 >"${static_dir}/exec.log" 2>&1 && static_exec_rc=0 || static_exec_rc=$?
[[ "${static_exec_rc}" -ne 0 ]] || fail "assert_static_elf accepted an executable PT_GNU_STACK"
exec_log="$(cat "${static_dir}/exec.log")"
grep -q 'executable stack' <<<"${exec_log}" \
    || fail "an executable stack was not named: ${exec_log}"
# shellcheck disable=SC2310 # assert_static_elf returns explicitly, never relies on set -e
assert_static_elf "${static_dir}/nostack" 3e00 >"${static_dir}/nostack.log" 2>&1 && static_nostack_rc=0 || static_nostack_rc=$?
[[ "${static_nostack_rc}" -ne 0 ]] || fail "assert_static_elf accepted an image with no PT_GNU_STACK"
nostack_log="$(cat "${static_dir}/nostack.log")"
grep -q 'without PT_GNU_STACK' <<<"${nostack_log}" \
    || fail "a missing stack segment was not named: ${nostack_log}"
echo "=== static ELF header check ok ==="

fixture="$(mktemp -d "${SCRATCH_DIR}/fuse-manifest-test.XXXXXX")"
trap 'rm -rf "${fixture}"' EXIT
cp "${ROOT_DIR}/build.zig" "${ROOT_DIR}/build.zig.zon" "${fixture}/"
rc=0
zig build test --build-file "${fixture}/build.zig" -Dfuse-static >"${fixture}/missing-manifest.log" 2>&1 || rc=$?
[[ "${rc}" -ne 0 ]] || fail "static build accepted a missing manifest"
output="$(cat "${fixture}/missing-manifest.log")"
[[ "${output}" == *"cannot read .deps/libfuse3-3.16.2/SHA256SUMS: FileNotFound"* ]] || fail "static build did not reject the missing manifest: ${output}"

echo "=== static libfuse3 manifest required ==="

pin="$(sed -n 's/^[[:space:]]*\.minimum_zig_version *= *"\([^"]*\)".*/\1/p' "${fixture}/build.zig.zon")"
[[ -n "${pin}" ]] || fail "missing Zig version pin"
sed 's/^\([[:space:]]*\.minimum_zig_version *= *\)"[^"]*"/\1"0.0.0"/' "${ROOT_DIR}/build.zig.zon" >"${fixture}/build.zig.zon"
rc=0
zig build test --build-file "${fixture}/build.zig" -Dfuse-static >"${fixture}/wrong-toolchain.log" 2>&1 || rc=$?
[[ "${rc}" -ne 0 ]] || fail "build accepted a compiler other than the pinned version"
output="$(cat "${fixture}/wrong-toolchain.log")"
[[ "${output}" == *"use the Zig version pinned by minimum_zig_version in build.zig.zon"* ]] || fail "build did not reject the wrong compiler: ${output}"

echo "=== exact Zig toolchain required ==="
