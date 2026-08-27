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
# MF_DRILL_SCRATCH (dr_restore_drill.sh), MF_DRILL_LOG_MAX_AGE
# (check_drill_log.sh), MF_NAS_DEST (install_nas_backup.sh).

# Named preflight for scripts that invoke `zig build`: a missing toolchain
# otherwise dies as bash "command not found" with no pointer at setup.
require_zig() {
    if command -v zig >/dev/null 2>&1; then
        return 0
    fi
    echo "cannot run: zig not found on PATH -- see CONTRIBUTING.md (setup section)" >&2
    exit 1
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
