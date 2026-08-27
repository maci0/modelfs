#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== 9-node cluster piece-exchange ==="

cd "${ROOT_DIR}"
require_fuse
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
