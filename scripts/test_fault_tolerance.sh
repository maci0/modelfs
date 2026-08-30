#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage_no_args "$@" <<'EOF'
Usage: ./scripts/test_fault_tolerance.sh

Peer-auth rejection and expired-lease listing. The auth check skips
loudly unless a peer is listening (MF_TEST_HOST / MF_TEST_PORT, default
127.0.0.1:19081). See CONTRIBUTING.md.
EOF

echo "=== Fault tolerance tests ==="

cd "${ROOT_DIR}"
require_zig
zig build

MODELFS_BIN="${ROOT_DIR}/zig-out/bin/modelfs"

mkdir -p "${SCRATCH_DIR}"
TEMP_DIR="$(mktemp -d "${SCRATCH_DIR}/fault-XXXXXX")"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "${TEMP_DIR}"' EXIT

ORIGIN_DIR="${TEMP_DIR}/origin"
PSK_FILE="${TEMP_DIR}/modelfs.psk"
mkdir -p "${ORIGIN_DIR}"
echo "correct_psk_key_12345" > "${PSK_FILE}"
chmod 600 "${PSK_FILE}"

echo "=== Test 1: Invalid PSK Auth Rejection ==="
# Needs a live peer endpoint (e.g. started by run_cluster_e2e_9nodes.sh).
# Without one this is skipped loudly, never counted as a pass.
# Harness knobs stay outside the MODELFS_ namespace: the daemon refuses any
# unknown MODELFS_* variable as a typo'd knob, so exporting one of these
# would fail every modelfs invocation in the same shell.
PEER_HOST="${MF_TEST_HOST:-127.0.0.1}"
PEER_PORT="${MF_TEST_PORT:-19081}"
python3 "${SCRIPTS_DIR}/peer_auth_probe.py" "${PEER_HOST}" "${PEER_PORT}"

echo "=== Test 2: Expired Cluster Lease Marking ==="
# Write an expired lease file directly to .cluster, then require the peers
# command to report it as expired. The listing goes to stdout; 2>&1 keeps
# any warnings in the same capture.
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
