#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Running Fault Tolerance & Resilience Test Suite ==="

cd "${ROOT_DIR}"
zig build

MODELFS_BIN="${ROOT_DIR}/zig-out/bin/modelfs"

TEMP_DIR="$(mktemp -d /tmp/modelfs-fault-XXXXXX)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "${TEMP_DIR}"' EXIT

ORIGIN_DIR="${TEMP_DIR}/origin"
PSK_FILE="${TEMP_DIR}/modelfs.psk"
mkdir -p "${ORIGIN_DIR}"
echo "correct_psk_key_12345" > "${PSK_FILE}"
chmod 600 "${PSK_FILE}"

echo "=== Test 1: Invalid PSK Auth Rejection ==="
# Needs a live peer endpoint (e.g. started by run_cluster_e2e_9nodes.sh).
# Without one this is skipped loudly, never counted as a pass.
PEER_HOST="${MODELFS_TEST_HOST:-127.0.0.1}"
PEER_PORT="${MODELFS_TEST_PORT:-19081}"
python3 "${SCRIPT_DIR}/peer_auth_probe.py" "${PEER_HOST}" "${PEER_PORT}"

echo "=== Test 2: Expired Cluster Lease Marking ==="
# Write an expired lease file directly to .cluster, then require the peers
# command to report it as expired. cmdPeers prints via stderr, so merge 2>&1.
CLUSTER_DIR="${ORIGIN_DIR}/.cluster"
mkdir -p "${CLUSTER_DIR}"
EXPIRED_LEASE="${CLUSTER_DIR}/dead_node.json"
echo '{"id":"dead_node","until":100,"addrs":[{"ip":"127.0.0.1","port":19999,"mbps":1000}]}' > "${EXPIRED_LEASE}"

PEERS_OUT="$("${MODELFS_BIN}" peers --origin "${ORIGIN_DIR}" --psk "${PSK_FILE}" 2>&1)" || {
    echo "Error: peers command failed"
    exit 1
}
echo "${PEERS_OUT}"
echo "${PEERS_OUT}" | grep -q "dead_node" || { echo "Error: dead_node lease missing from peers output"; exit 1; }
if echo "${PEERS_OUT}" | grep "dead_node" | grep -q "expired"; then
    echo "✓ Expired lease correctly marked as expired"
else
    echo "Error: expired dead_node lease was not marked expired"
    exit 1
fi

echo "=== All Fault Tolerance Tests Passed Successfully ==="
