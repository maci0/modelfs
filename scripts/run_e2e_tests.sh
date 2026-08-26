#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== Building modelfs binary ==="
cd "${ROOT_DIR}"
zig build

MODELFS_BIN="${ROOT_DIR}/zig-out/bin/modelfs"

if [[ ! -x "${MODELFS_BIN}" ]]; then
    echo "Error: modelfs binary not found at ${MODELFS_BIN}"
    exit 1
fi

mkdir -p "${SCRATCH_DIR}"
TEMP_DIR="$(mktemp -d "${SCRATCH_DIR}/e2e-XXXXXX")"
trap 'rm -rf "${TEMP_DIR}"' EXIT

ORIGIN_DIR="${TEMP_DIR}/origin"
CACHE_DIR_1="${TEMP_DIR}/cache1"
CACHE_DIR_2="${TEMP_DIR}/cache2"
PSK_FILE="${TEMP_DIR}/modelfs.psk"

mkdir -p "${ORIGIN_DIR}" "${CACHE_DIR_1}" "${CACHE_DIR_2}"
echo "supersecretkey1234567890abcdef12345678" > "${PSK_FILE}"
chmod 600 "${PSK_FILE}"

echo "=== Test Case 1: CLI Help & Status ==="
"${MODELFS_BIN}" help > /dev/null
echo "✓ Help command succeeded"

# Status on uninitialized cache must report 'not running' AND exit nonzero.
# NB: status intentionally exits 1 here; capture instead of piping because
# `set -o pipefail` would turn that expected exit into a failed check.
STATUS_OUT="$("${MODELFS_BIN}" status --cache "${CACHE_DIR_1}" 2>&1)" && RC=0 || RC=$?
if [[ "${RC}" -eq 1 ]] && grep -q "not running" <<< "${STATUS_OUT}"; then
    echo "✓ Status on uninitialized cache reported correctly"
else
    echo "Error: expected exit 1 + 'not running' on uninitialized cache (got rc=${RC}): ${STATUS_OUT}"
    exit 1
fi

echo "=== Test Case 2: Pinning & Unpinning ==="
"${MODELFS_BIN}" pin "models/llama3.gguf" --origin "${ORIGIN_DIR}" --cache "${CACHE_DIR_1}" --psk "${PSK_FILE}"
if [[ -f "${CACHE_DIR_1}/pin/models/llama3.gguf" ]]; then
    echo "✓ Pin created pin sidecar file"
else
    echo "Error: pin file not created"
    exit 1
fi

"${MODELFS_BIN}" unpin "models/llama3.gguf" --origin "${ORIGIN_DIR}" --cache "${CACHE_DIR_1}" --psk "${PSK_FILE}"
if [[ ! -f "${CACHE_DIR_1}/pin/models/llama3.gguf" ]]; then
    echo "✓ Unpin removed pin sidecar file"
else
    echo "Error: pin file was not removed"
    exit 1
fi

echo "=== Test Case 3: Peer Discovery Listing ==="
# Lists leases from origin/.cluster; expired ones are marked, not served.
"${MODELFS_BIN}" peers --origin "${ORIGIN_DIR}" > /dev/null
echo "✓ Peer discovery command succeeded"

echo "=== All E2E Integration Tests Passed Successfully ==="
