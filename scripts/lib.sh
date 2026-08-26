#!/usr/bin/env bash
# Sourced by every script in this directory. Locates the project root by
# walking up for build.zig.zon, so no script hardcodes how deep below the
# root it sits, and names the one place run artifacts may be written.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [[ ! -f "${ROOT_DIR}/build.zig.zon" ]]; do
    if [[ "${ROOT_DIR}" == "/" ]]; then
        echo "cannot find build.zig.zon above ${BASH_SOURCE[0]}" >&2
        exit 1
    fi
    ROOT_DIR="$(dirname "${ROOT_DIR}")"
done

# shellcheck disable=SC2034 # used by the scripts that source this file
SCRIPTS_DIR="${ROOT_DIR}/scripts"

# Run artifacts (mount points, origins, caches, logs) go here, never /tmp:
# /tmp is tmpfs on these hosts, so a multi-gigabyte piece cache written there
# is charged to RAM and disappears on reboot. Gitignored.
# shellcheck disable=SC2034 # used by the scripts that source this file
SCRATCH_DIR="${ROOT_DIR}/.scratch"
