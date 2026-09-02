#!/usr/bin/env bash
# Pin the `modelfs update` contract on a live mount: the process image is
# replaced without unmounting, an fd opened before the swap keeps reading
# the right bytes across it, the peer port is never rebound, and a second
# update works on the image the first one produced.
#
# Needs /dev/fuse and fusermount3, so it runs locally rather than in CI
# (same reason run_cluster_e2e_9nodes.sh does).
set -euo pipefail
export LC_ALL=C
export TZ=UTC

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage_no_args "$@" <<'EOF'
Usage: ./scripts/test_hot_reload.sh

Mount modelfs on a scratch origin, hold a file open, run `modelfs update`,
and assert the mount never dropped: same pid, same peer port, the held fd
reads the right bytes on both sides of the swap, and namespace operations
still work afterwards. MF_HOTRELOAD_PORT overrides the peer port (19556).
EOF

cd "${ROOT_DIR}"

PORT="${MF_HOTRELOAD_PORT:-19556}"
W="${SCRATCH_DIR}/hot-reload"
MNT="${W}/mnt"
LOG="${W}/daemon.log"
BIN="${W}/out/bin/modelfs"
daemon_pid=""

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

cleanup() {
    if [[ -n "${daemon_pid}" ]] && kill -0 "${daemon_pid}" 2>/dev/null; then
        kill -TERM "${daemon_pid}" 2>/dev/null || true
        for _ in $(seq 40); do
            if ! kill -0 "${daemon_pid}" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        kill -KILL "${daemon_pid}" 2>/dev/null || true
    fi
    fusermount3 -u "${MNT}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_fuse
require_zig
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum not found on PATH (coreutils)"

# Own prefix, so a native harness run does not replace a cross-compiled
# zig-out/ someone is holding on to.
zig build --prefix "${W}/out" >/dev/null

rm -rf "${W}/origin" "${W}/cache" "${MNT}"
mkdir -p "${W}/origin/sub" "${W}/cache" "${MNT}"
# Several pieces at the mount's piece size, so the held fd spans a piece
# boundary and the read after the swap has to hydrate, not just replay.
head -c 5000000 /dev/urandom > "${W}/origin/model.bin"
echo hello > "${W}/origin/sub/note.txt"
printf 'hot-reload-psk\n' > "${W}/psk"
chmod 600 "${W}/psk"

port_open() {
    (exec 9<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null
}

status_pid() {
    sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "${W}/cache/status.json"
}

mount_is_up() {
    grep -q " ${MNT} " /proc/self/mounts
}

# shellcheck disable=SC2310 # port_open is a probe; its status is the answer
if port_open; then
    fail "port ${PORT} is already in use (set MF_HOTRELOAD_PORT)"
fi

"${BIN}" mount "${MNT}" --origin "${W}/origin" --cache "${W}/cache" \
    --psk "${W}/psk" --listen "${PORT}" --piece 1048576 > "${LOG}" 2>&1 &
daemon_pid=$!

for _ in $(seq 100); do
    if [[ -f "${W}/cache/status.json" ]]; then
        break
    fi
    sleep 0.1
done
[[ -f "${W}/cache/status.json" ]] || fail "daemon never published status.json (see ${LOG})"

note="$(< "${MNT}/sub/note.txt")"
[[ "${note}" == "hello" ]] || fail "mount does not serve the origin"

pid_before="$(status_pid)"
[[ "${pid_before}" == "${daemon_pid}" ]] || fail "status.json names pid ${pid_before}, daemon is ${daemon_pid}"

dd if="${W}/origin/model.bin" bs=1M count=1 status=none | sha256sum | cut -d' ' -f1 > "${W}/want.before"
dd if="${W}/origin/model.bin" bs=1M skip=1 status=none | sha256sum | cut -d' ' -f1 > "${W}/want.after"

rm -f "${W}/held.ready" "${W}/held.go" "${W}/held.before" "${W}/held.after"
# An fd opened before the update and read after it: the whole point of the
# handover is that this reader never sees an error or a wrong byte.
(
    exec 3< "${MNT}/model.bin"
    dd bs=1M count=1 <&3 status=none | sha256sum | cut -d' ' -f1 > "${W}/held.before"
    : > "${W}/held.ready"
    while [[ ! -f "${W}/held.go" ]]; do
        sleep 0.1
    done
    dd bs=1M status=none <&3 | sha256sum | cut -d' ' -f1 > "${W}/held.after"
) &
holder=$!

for _ in $(seq 100); do
    if [[ -f "${W}/held.ready" ]]; then
        break
    fi
    sleep 0.1
done
[[ -f "${W}/held.ready" ]] || fail "reader never opened the held fd"

held_before="$(< "${W}/held.before")"
want_before="$(< "${W}/want.before")"
[[ "${held_before}" == "${want_before}" ]] || fail "read before the update returned the wrong bytes"

"${BIN}" update --cache "${W}/cache" || fail "modelfs update exited nonzero"

: > "${W}/held.go"
wait "${holder}" || fail "the held reader exited nonzero across the update"
held_after="$(< "${W}/held.after")"
want_after="$(< "${W}/want.after")"
[[ "${held_after}" == "${want_after}" ]] || fail "read through the held fd after the update returned the wrong bytes"

kill -0 "${daemon_pid}" 2>/dev/null || fail "the daemon exited during the update"
pid_after="$(status_pid)"
[[ "${pid_after}" == "${pid_before}" ]] || fail "pid changed across the update; the image was not replaced in place"
grep -q "attached to the FUSE connection" "${LOG}" || fail "no replacement image attached (see ${LOG})"
# ps has to keep naming the mount: an operator looking for the daemon after
# an update finds a process whose argv still says which mount it serves.
grep -qa -- "${MNT}" "/proc/${daemon_pid}/cmdline" || fail "post-update argv no longer names ${MNT}"
# shellcheck disable=SC2310 # port_open is a probe; its status is the answer
port_open || fail "peer port ${PORT} stopped accepting across the update"

note="$(< "${MNT}/sub/note.txt")"
[[ "${note}" == "hello" ]] || fail "mount stopped serving after the update"
mkdir "${MNT}/after" || fail "mkdir failed after the update"
echo swapped > "${MNT}/after/f.txt" || fail "write failed after the update"
body="$(< "${MNT}/after/f.txt")"
[[ "${body}" == "swapped" ]] || fail "read-back failed after the update"
mv "${MNT}/after/f.txt" "${MNT}/after/g.txt" || fail "rename failed after the update"
body="$(< "${MNT}/after/g.txt")"
[[ "${body}" == "swapped" ]] || fail "read after rename failed"
rm "${MNT}/after/g.txt" || fail "unlink failed after the update"
rmdir "${MNT}/after" || fail "rmdir failed after the update"

# The second update runs against an image that was itself attached, so it
# proves the captured FUSE_INIT survives the round trip through the state
# blob rather than only the first exec.
"${BIN}" update --cache "${W}/cache" || fail "second modelfs update exited nonzero"
note="$(< "${MNT}/sub/note.txt")"
[[ "${note}" == "hello" ]] || fail "mount stopped serving after the second update"
pid_after="$(status_pid)"
[[ "${pid_after}" == "${pid_before}" ]] || fail "pid changed across the second update"

# A replaced image never called fuse_session_mount, so its teardown rides on
# the auto_unmount helper the original mount left behind.
kill -TERM "${daemon_pid}"
for _ in $(seq 100); do
    if ! kill -0 "${daemon_pid}" 2>/dev/null; then
        break
    fi
    sleep 0.1
done
if kill -0 "${daemon_pid}" 2>/dev/null; then
    fail "daemon did not exit on SIGTERM after the handover"
fi
daemon_pid=""
for _ in $(seq 100); do
    # shellcheck disable=SC2310 # mount_is_up is a probe; its status is the answer
    if ! mount_is_up; then
        break
    fi
    sleep 0.1
done
# shellcheck disable=SC2310 # mount_is_up is a probe; its status is the answer
if mount_is_up; then
    fail "mount survived the daemon; auto_unmount did not fire after the handover"
fi

echo "hot reload: image replaced twice with no unmount, held fd intact, peer port kept"
