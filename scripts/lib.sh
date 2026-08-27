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
# MF_DRILL_MAX_SNAP_AGE, MF_DRILL_REPLICA (dr_restore_drill.sh).

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
