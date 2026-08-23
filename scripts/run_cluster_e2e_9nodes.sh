#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "================================================================="
echo "=== 9-Node Cluster Performance & Block Exchange E2E Benchmark ==="
echo "================================================================="

cd "${ROOT_DIR}"
zig build

MODELFS_BIN="${ROOT_DIR}/zig-out/bin/modelfs"

TEMP_DIR="$(mktemp -d /tmp/modelfs-cluster9-XXXXXX)"

cleanup() {
    echo "Tearing down cluster processes and unmounting..."
    for m in "${TEMP_DIR}"/mount_*; do
        if [ -d "$m" ]; then
            fusermount3 -u "$m" 2>/dev/null || fusermount -u "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
        fi
    done
    local pids=()
    readarray -t pids < <(jobs -p)
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

ORIGIN_HASH="$(sha256sum "${ORIGIN_DIR}/${TEST_FILE}" | cut -d' ' -f1)"
echo "Origin file SHA256: ${ORIGIN_HASH}"
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
sleep 2

echo "=== Step 4: Inspecting active cluster peers ==="
"${MODELFS_BIN}" peers --origin "${ORIGIN_DIR}" --psk "${PSK_FILE}"

echo "=== Step 5: Executing multi-peer piece exchange benchmark ==="
python3 "${SCRIPT_DIR}/cluster_verify.py" \
    "${ORIGIN_DIR}/${TEST_FILE}" \
    "${TEST_FILE}" \
    "${PSK_FILE}" \
    "${BASE_PORT}" \
    "${NUM_NODES}" \
    "${TOTAL_PIECES}"

echo "=== Step 6: Verifying node cache sizes & culling bounds ==="
for i in $(seq 1 "${NUM_NODES}"); do
    CACHE_DIR="${TEMP_DIR}/node_${i}_cache"
    USAGE_BYTES=$(du -sb "${CACHE_DIR}" 2>/dev/null | cut -f1 || echo "0")
    USAGE_MB=$((USAGE_BYTES / 1024 / 1024))
    echo "Node spark_${i} Cache Size: ${USAGE_MB} MB (Original file size: ${FILE_SIZE_MB} MB)"
    if [ "${USAGE_MB}" -gt "${FILE_SIZE_MB}" ]; then
        echo "Error: Node spark_${i} cache exceeds file size!"
        exit 1
    fi
    if [ "${USAGE_MB}" -lt "${FILE_SIZE_MB}" ]; then
        echo "✓ Node spark_${i} cache size (${USAGE_MB} MB) is smaller than full file (${FILE_SIZE_MB} MB)"
    fi
done

echo "================================================================="
echo "=== 9-Node Cluster Performance Benchmark Passed Successfully ==="
echo "================================================================="
