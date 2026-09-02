#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage_no_args "$@" <<'EOF'
Usage: ./scripts/run_cluster_e2e_9nodes.sh

Nine FUSE-mounted instances exchanging pieces. Needs /dev/fuse and
fusermount3 (fuse3 / fuse package). See CONTRIBUTING.md.
EOF

echo "=== 9-node cluster piece-exchange ==="

cd "${ROOT_DIR}"
require_fuse
require_zig
require_python
zig build

MODELFS_BIN="${ROOT_DIR}/zig-out/bin/modelfs"

mkdir -p "${SCRATCH_DIR}"
TEMP_DIR="$(mktemp -d "${SCRATCH_DIR}/cluster9-XXXXXX")"

cleanup() {
    echo "Tearing down cluster processes and unmounting..."
    for m in "${TEMP_DIR}"/mount_*; do
        if [ -d "$m" ]; then
            fusermount3 -u "$m" 2>/dev/null || fusermount -u "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
        fi
    done
    local pids=()
    # || true: a jobs(1) failure must not abort teardown; the PIDs are
    # best-effort, so the substituted command's status is deliberately ignored.
    readarray -t pids < <(jobs -p || true)
    if ((${#pids[@]} > 0)); then
        kill "${pids[@]}" 2>/dev/null || true
    fi
    rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

ORIGIN_DIR="${TEMP_DIR}/origin"
PSK_FILE="${TEMP_DIR}/modelfs.psk"
NUM_NODES=9
FILE_SIZE_MB=64
PIECE_SIZE_MB=4
TOTAL_PIECES=$((FILE_SIZE_MB / PIECE_SIZE_MB))

mkdir -p "${ORIGIN_DIR}"
echo "clusterpsk_secret_key_1234567890" > "${PSK_FILE}"
chmod 600 "${PSK_FILE}"

echo "=== Step 1: Generating ${FILE_SIZE_MB}MB model file on NFS origin ==="
TEST_FILE="big_model.gguf"
dd if=/dev/urandom of="${ORIGIN_DIR}/${TEST_FILE}" bs=1M count="${FILE_SIZE_MB}" status=none

echo "Piece count: ${TOTAL_PIECES} pieces (${PIECE_SIZE_MB}MB per piece)"

BASE_PORT=19080

echo "=== Step 2: Spawning ${NUM_NODES} peer nodes ==="
for i in $(seq 1 "${NUM_NODES}"); do
    CACHE_DIR="${TEMP_DIR}/node_${i}_cache"
    MOUNT_DIR="${TEMP_DIR}/mount_${i}"
    mkdir -p "${CACHE_DIR}" "${MOUNT_DIR}"
    PORT=$((BASE_PORT + i))

    "${MODELFS_BIN}" mount "${MOUNT_DIR}" \
        --origin "${ORIGIN_DIR}" \
        --cache "${CACHE_DIR}" \
        --id "spark_${i}" \
        --listen "127.0.0.1:${PORT}" \
        --psk "${PSK_FILE}" \
        --piece "${PIECE_SIZE_MB}M" \
        --brun 10 \
        --bcull 5 \
        --bstop 2 \
        &
    echo "Spawned Node spark_${i} (Port ${PORT}, Mount ${MOUNT_DIR})"
done

echo "=== Step 3: Waiting for cluster peer lease publication ==="
# Each node publishes a lease at .cluster/<id>.json once it is up; poll for
# all NUM_NODES of them instead of sleeping a fixed two seconds, which races
# a loaded host and leaves the peers listing below half-empty. Bounded, so a
# daemon that died on startup fails loudly here rather than as a refused
# connection in the verifier.
LEASE_DEADLINE=$((SECONDS + 30))
while :; do
    leases=0
    for lease in "${ORIGIN_DIR}"/.cluster/*.json; do
        [[ -f "${lease}" ]] && leases=$((leases + 1))
    done
    if [[ "${leases}" -ge "${NUM_NODES}" ]]; then
        break
    fi
    if ((SECONDS >= LEASE_DEADLINE)); then
        echo "Error: only ${leases}/${NUM_NODES} peer leases published after 30s"
        exit 1
    fi
    sleep 0.5
done

echo "=== Step 4: Inspecting active cluster peers ==="
"${MODELFS_BIN}" peers --origin "${ORIGIN_DIR}" --psk "${PSK_FILE}"

echo "=== Step 5: multi-peer piece exchange ==="
# Pin first so a tight watermark cannot punch the just-filled bits before
# /have is asked. A FUSE read is what hydrates: /have snapshots live bits
# and does not fill, so listing leases plus probing empty bitmaps used to
# count as exchange.
for i in $(seq 1 "${NUM_NODES}"); do
    "${MODELFS_BIN}" pin "${TEST_FILE}" --cache "${TEMP_DIR}/node_${i}_cache"
done
# Node 1 fills from origin; node 2 should then take pieces from node 1.
# Remaining mounts read the same file so every node the verifier asks has
# bit i set, not an all-zero field of the right length.
for i in $(seq 1 "${NUM_NODES}"); do
    if ! cmp -s "${ORIGIN_DIR}/${TEST_FILE}" "${TEMP_DIR}/mount_${i}/${TEST_FILE}"; then
        echo "Error: mount_${i} read of ${TEST_FILE} does not match origin"
        exit 1
    fi
done
echo "✓ All ${NUM_NODES} mounts served ${TEST_FILE} matching origin"

# fills_peer rides status.json, rewritten each discovery tick (10s). Poll
# so a just-finished read is visible; 0 after that window means spark_2
# filled only from origin and P2P never ran.
PEER_FILL_DEADLINE=$((SECONDS + 15))
while :; do
    STATUS_OUT="$("${MODELFS_BIN}" status --cache "${TEMP_DIR}/node_2_cache" 2>/dev/null)" && STATUS_RC=0 || STATUS_RC=$?
    FILLS=0
    if [[ "${STATUS_RC}" -eq 0 ]]; then
        FILLS="$(python3 -c 'import json,sys; print(int(json.load(sys.stdin)["stats"]["fills_peer"]))' <<<"${STATUS_OUT}" 2>/dev/null || echo 0)"
    fi
    if [[ "${FILLS}" -gt 0 ]]; then
        echo "✓ Node spark_2 filled ${FILLS} piece(s) from peers"
        break
    fi
    if ((SECONDS >= PEER_FILL_DEADLINE)); then
        echo "Error: node spark_2 reported no peer fills; piece exchange did not happen"
        exit 1
    fi
    sleep 0.5
done

python3 "${SCRIPTS_DIR}/cluster_verify.py" \
    "${TEST_FILE}" \
    "${PSK_FILE}" \
    "${BASE_PORT}" \
    "${NUM_NODES}" \
    "${TOTAL_PIECES}"

echo "=== Step 6: Verifying node cache sizes & culling bounds ==="
for i in $(seq 1 "${NUM_NODES}"); do
    CACHE_DIR="${TEMP_DIR}/node_${i}_cache"
    # POSIX du -sk (KB): GNU-only -b fails outright on busybox, where the
    # fallback below would report 0 and silently skip the size assertion.
    USAGE_KB=$(du -sk "${CACHE_DIR}" 2>/dev/null | cut -f1 || echo "0")
    USAGE_MB=$((USAGE_KB / 1024))
    if [ "${USAGE_MB}" -gt "${FILE_SIZE_MB}" ]; then
        echo "Error: Node spark_${i} cache exceeds file size!"
        exit 1
    fi
    # du rounds to whole KB, so an exact fit is a legitimate pass; above the
    # bound already failed, so reaching this line always means within bounds.
    echo "✓ Node spark_${i} cache size (${USAGE_MB} MB) is within the ${FILE_SIZE_MB} MB bound"
done

echo "=== 9-node cluster piece-exchange passed ==="
