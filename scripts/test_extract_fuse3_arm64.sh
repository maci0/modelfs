#!/usr/bin/env bash
# Pins extract_fuse3_arm64.sh hermeticity: the committed .deb digests must
# match SHA256SUMS, a previous extract's leftover files must not survive,
# and the header/library layout scripts/cross_aarch64.sh consumes must exist.
set -euo pipefail

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

fixture="$(mktemp -d "${SCRATCH_DIR}/fuse-manifest-test.XXXXXX")"
trap 'rm -rf "${fixture}"' EXIT
cp "${ROOT_DIR}/build.zig" "${ROOT_DIR}/build.zig.zon" "${fixture}/"
rc=0
zig build test --build-file "${fixture}/build.zig" -Dfuse-static >"${fixture}/missing-manifest.log" 2>&1 || rc=$?
[[ "${rc}" -ne 0 ]] || fail "static build accepted a missing manifest"
output="$(cat "${fixture}/missing-manifest.log")"
[[ "${output}" == *"cannot read .deps/libfuse3-3.16.2/SHA256SUMS: FileNotFound"* ]] || fail "static build did not reject the missing manifest: ${output}"

echo "=== static libfuse3 manifest required ==="
