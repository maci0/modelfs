#!/usr/bin/env bash
# Sourced by every script in this directory. Locates the project root by
# walking up for build.zig.zon, so no script hardcodes how deep below the
# root it sits, and names the one place run artifacts may be written.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [[ ! -f "${ROOT_DIR}/build.zig.zon" ]]; do
    if [[ "${ROOT_DIR}" == "/" || -z "${ROOT_DIR}" ]]; then
        echo "cannot find build.zig.zon above ${BASH_SOURCE[0]}" >&2
        exit 1
    fi
    _mf_parent="$(dirname "${ROOT_DIR}")"
    if [[ "${_mf_parent}" == "${ROOT_DIR}" ]]; then
        echo "cannot find build.zig.zon above ${BASH_SOURCE[0]}" >&2
        exit 1
    fi
    ROOT_DIR="${_mf_parent}"
done
unset _mf_parent

# shellcheck disable=SC2034 # used by the scripts that source this file
SCRIPTS_DIR="${ROOT_DIR}/scripts"

# Run artifacts (mount points, origins, caches, logs) go here, never /tmp:
# /tmp is tmpfs on these hosts, so a multi-gigabyte piece cache written there
# is charged to RAM and disappears on reboot. Gitignored.
# shellcheck disable=SC2034 # used by the scripts that source this file
SCRATCH_DIR="${ROOT_DIR}/.scratch"

# Environment namespaces: every MODELFS_* variable belongs to the modelfs
# binary alone, which refuses any other member of that prefix as a typo'd
# knob rather than silently dropping it. Harness knobs exported into this
# environment (test endpoints, drill paths) therefore live under MF_: an
# exported MODELFS_-spelled knob would make every modelfs invocation in these
# scripts die with "unknown environment variable" before its command ever
# ran. Current members: MF_TEST_HOST, MF_TEST_PORT (test_fault_tolerance.sh),
# MF_DRILL_LOG, MF_DRILL_LIVE, MF_DRILL_CLONE_MP, MF_DRILL_KEEP,
# MF_DRILL_MAX_SNAP_AGE, MF_DRILL_MAX_REPLICA_AGE, MF_DRILL_REPLICA,
# MF_DRILL_SCRATCH (dr_restore_drill.sh; --age-only is the hourly
# snapshot-age alarm), MF_DRILL_LOG_MAX_AGE (check_drill_log.sh),
# MF_NAS_DEST (install_nas_backup.sh), MF_OFFSITE_DATASET,
# MF_OFFSITE_MAX_AGE (check_offsite.sh), MF_RESTORE_FROM,
# MF_RESTORE_LOCAL_FROM, MF_RESTORE_MOUNTPOINT, MF_RESTORE_SHARENFS,
# MF_RESTORE_LOG (dr_pool_restore.sh), MF_HOTRELOAD_PORT
# (test_hot_reload.sh), MF_SYNCOID_SRC, MF_SYNCOID_DEST
# (nas/syncoid-models.service), MF_DRILL_DATASET (nas/modelfs-drill.service,
# nas/modelfs-snap-age.service).

# Dotted numeric compare: 0.16.1 >= 0.16.0, 3.12.4 >= 3.12, 0.15.99 < 0.16.0.
# Extra trailing components on cur count as 0 against a longer min.
version_ge() {
    awk -v cur="$1" -v min="$2" 'BEGIN {
        ncur = split(cur, c, /[^0-9]+/)
        nmin = split(min, t, /[^0-9]+/)
        for (i = 1; i <= nmin; i++) {
            ci = (i <= ncur) ? (c[i] + 0) : 0
            ti = t[i] + 0
            if (ci < ti) exit 1
            if (ci > ti) exit 0
        }
        exit 0
    }'
}

# Named preflight for scripts that invoke `zig build`: a missing toolchain
# otherwise dies as bash "command not found" with no pointer at setup.
# The version floor is minimum_zig_version in build.zig.zon, the same pin
# CI installs; an older zig used to fail later as a compile error.
require_zig() {
    if ! command -v zig >/dev/null 2>&1; then
        echo "cannot run: zig not found on PATH -- see CONTRIBUTING.md (setup section)" >&2
        exit 1
    fi
    local min_zig zig_ver
    min_zig="$(sed -n 's/^[[:space:]]*\.minimum_zig_version *= *"\([^"]*\)".*/\1/p' "${ROOT_DIR}/build.zig.zon")"
    if [[ -z "${min_zig}" ]]; then
        echo "cannot read minimum_zig_version from build.zig.zon" >&2
        exit 1
    fi
    zig_ver="$(zig version)"
    local ge_rc=0
    # shellcheck disable=SC2310 # version_ge is a pure awk compare; it never relies on set -e
    version_ge "${zig_ver}" "${min_zig}" && ge_rc=0 || ge_rc=$?
    if [[ "${ge_rc}" -ne 0 ]]; then
        echo "cannot run: zig ${zig_ver} is older than minimum_zig_version ${min_zig} in build.zig.zon" >&2
        exit 1
    fi
}

# Named preflight for harnesses that run the repo's Python CLIs. The floor
# is .python-version (the same pin CI installs); an older interpreter used
# to die as a SyntaxError inside 3.10+ type hints. A newer system python is
# fine here; scripts/check.sh is the one that pins the venv to that series.
require_python() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "cannot run: python3 not found on PATH -- see CONTRIBUTING.md (setup section)" >&2
        exit 1
    fi
    local min_py py_ver
    min_py="$(tr -d '[:space:]' < "${ROOT_DIR}/.python-version")"
    if [[ -z "${min_py}" ]]; then
        echo "cannot read .python-version" >&2
        exit 1
    fi
    py_ver="$(python3 -c 'import sys; print("%d.%d.%d" % (sys.version_info[0], sys.version_info[1], sys.version_info[2]))')" || {
        echo "cannot run: python3 is not a working interpreter -- see CONTRIBUTING.md (setup section)" >&2
        exit 1
    }
    local ge_rc=0
    # shellcheck disable=SC2310 # version_ge is a pure awk compare; it never relies on set -e
    version_ge "${py_ver}" "${min_py}" && ge_rc=0 || ge_rc=$?
    if [[ "${ge_rc}" -ne 0 ]]; then
        echo "cannot run: python3 ${py_ver} is older than ${min_py} in .python-version -- see CONTRIBUTING.md (setup section)" >&2
        exit 1
    fi
}

# Usage text is read from stdin so each script keeps its own --help body.
# -h/--help prints it on stdout and exits 0; any other argument prints it
# on stderr and exits 2, so `./scripts/foo.sh --help` cannot start a build,
# a FUSE mount, or a test run.
usage_no_args() {
    local text
    text="$(cat)" || exit 1
    if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
        printf '%s\n' "${text}"
        exit 0
    fi
    if [[ $# -gt 0 ]]; then
        printf '%s\n' "${text}" >&2
        exit 2
    fi
}

# FUSE-mounting harnesses call this before spawning daemons so a missing
# /dev/fuse or helper fails with a named install hint instead of nine
# "fusermount: mount failed" lines after the cluster is already half up.
require_fuse() {
    local problems=()
    if [[ ! -e /dev/fuse ]]; then
        problems+=("/dev/fuse is missing")
    fi
    if command -v fusermount3 >/dev/null 2>&1 || command -v fusermount >/dev/null 2>&1; then
        :
    else
        problems+=("no fusermount3/fusermount helper on PATH")
    fi
    if ((${#problems[@]} > 0)); then
        local joined
        joined="$(printf '%s; ' "${problems[@]}")"
        echo "cannot run: ${joined%; } -- this suite mounts a live FUSE filesystem (install fuse3 / fuse; see CONTRIBUTING.md)" >&2
        exit 1
    fi
}

# True when path is a 64-bit little-endian ELF with e_machine EM_AARCH64.
# Reads header bytes (POSIX od) instead of file(1) text, which changes
# across GNU file versions, locales, and busybox. Does not rely on set -e
# (callers use the status in &&/||).
assert_aarch64_elf() {
    local bin="$1" ident machine
    ident="$(od -An -t x1 -N 6 "${bin}")" || return 1
    ident="${ident//[[:space:]]/}"
    ident="$(printf '%s' "${ident}" | tr '[:upper:]' '[:lower:]')"
    machine="$(od -An -t x1 -N 2 -j 18 "${bin}")" || return 1
    machine="${machine//[[:space:]]/}"
    machine="$(printf '%s' "${machine}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${ident}" != "7f454c460201" ]]; then
        echo "not a 64-bit little-endian ELF: ${bin} (e_ident ${ident})" >&2
        return 1
    fi
    if [[ "${machine}" != "b700" ]]; then
        echo "not ARM aarch64 (e_machine ${machine}, want b700): ${bin}" >&2
        return 1
    fi
    return 0
}

# True when path is a fully static 64-bit little-endian ELF of the given
# machine ("3e00" = x86-64, "b700" = aarch64): ET_DYN (static-PIE, the
# release binaries keep ASLR), a program header table with no PT_INTERP, a
# dynamic table with no DT_NEEDED, and a PT_GNU_RELRO entry. Reads raw
# header bytes (POSIX od) like assert_aarch64_elf, not file(1) text. Does
# not rely on set -e (callers use the status in &&/||).
assert_static_elf() {
    local bin="$1" machine_want="$2"
    local ident etype machine phoff phentsize phnum i off ptype saw_relro=0 saw_interp=0 saw_dyn=0 dyn_off dtag
    ident="$(od -An -t x1 -N 6 "${bin}")" || return 1
    ident="$(printf '%s' "${ident}" | tr -d '[:space:]')"
    if [[ "${ident}" != "7f454c460201" ]]; then
        echo "not a 64-bit little-endian ELF: ${bin} (e_ident ${ident})" >&2
        return 1
    fi
    etype="$(od -An -t x1 -N 2 -j 16 "${bin}")" || return 1
    etype="$(printf '%s' "${etype}" | tr -d '[:space:]')"
    if [[ "${etype}" != "0300" ]]; then
        echo "not ET_DYN static-PIE: ${bin} (e_type ${etype})" >&2
        return 1
    fi
    machine="$(od -An -t x1 -N 2 -j 18 "${bin}")" || return 1
    machine="$(printf '%s' "${machine}" | tr -d '[:space:]')"
    if [[ "${machine}" != "${machine_want}" ]]; then
        echo "wrong machine (e_machine ${machine}, want ${machine_want}): ${bin}" >&2
        return 1
    fi
    phoff="$(od -An -t u8 -j 32 -N 8 "${bin}")" || return 1
    phoff="${phoff//[[:space:]]/}"
    phentsize="$(od -An -t u2 -j 54 -N 2 "${bin}")" || return 1
    phentsize="${phentsize//[[:space:]]/}"
    phnum="$(od -An -t u2 -j 56 -N 2 "${bin}")" || return 1
    phnum="${phnum//[[:space:]]/}"
    for ((i = 0; i < phnum; i++)); do
        off=$(( phoff + i * phentsize ))
        ptype="$(od -An -t x1 -j "${off}" -N 4 "${bin}")" || return 1
        ptype="$(printf '%s' "${ptype}" | tr -d '[:space:]')"
        case "${ptype}" in
            03000000) saw_interp=1 ;;
            52e57464) saw_relro=1 ;;
            02000000)
                saw_dyn=1
                dyn_off="$(od -An -t u8 -j $(( off + 8 )) -N 8 "${bin}")" || return 1
                dyn_off="${dyn_off//[[:space:]]/}"
                ;;
            *)
                # PT_NULL / PT_LOAD / PT_GNU_STACK / the rest: nothing to
                # assert on here, the RELRO and INTERP cases above are the
                # whole check.
                ;;
        esac
    done
    if [[ ${saw_interp} -ne 0 ]]; then
        echo "not static: PT_INTERP present (dynamically linked) : ${bin}" >&2
        return 1
    fi
    if [[ ${saw_dyn} -eq 0 ]]; then
        echo "no PT_DYNAMIC; cannot verify no DT_NEEDED: ${bin}" >&2
        return 1
    fi
    if [[ ${saw_relro} -eq 0 ]]; then
        echo "static ELF without PT_GNU_RELRO: ${bin}" >&2
        return 1
    fi
    # The dynamic table holds 16-byte entries (d_tag, d_val) and ends at
    # DT_NULL (0). DT_NEEDED is tag 1; a static binary must name no library.
    for ((i = 0; i < 4096; i++)); do
        dtag="$(od -An -t u8 -j $(( dyn_off + i * 16 )) -N 8 "${bin}")" || return 1
        dtag="${dtag//[[:space:]]/}"
        [[ "${dtag}" == "0" ]] && break
        if [[ "${dtag}" == "1" ]]; then
            echo "not static: DT_NEEDED present in the dynamic table: ${bin}" >&2
            return 1
        fi
    done
    if [[ "${dtag:-}" != "0" ]]; then
        echo "dynamic table has no DT_NULL within 4096 entries: ${bin}" >&2
        return 1
    fi
    return 0
}
