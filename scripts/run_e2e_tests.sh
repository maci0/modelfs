#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage_no_args "$@" <<'EOF'
Usage: ./scripts/run_e2e_tests.sh

CLI and peer protocol end to end; no FUSE mount needed.
EOF

echo "=== Building modelfs binary ==="
cd "${ROOT_DIR}"
require_zig
zig build

MODELFS_BIN="${ROOT_DIR}/zig-out/bin/modelfs"

if [[ ! -x "${MODELFS_BIN}" ]]; then
    echo "Error: modelfs binary not found at ${MODELFS_BIN}" >&2
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
HELP_OUT="${TEMP_DIR}/help.out"
HELP_ERR="${TEMP_DIR}/help.err"

# --help is the documented help request: stdout, exit 0, nothing on stderr.
"${MODELFS_BIN}" --help >"${HELP_OUT}" 2>"${HELP_ERR}"
grep -q '^Usage:' "${HELP_OUT}" || {
    echo "Error: --help did not print Usage: on stdout" >&2
    exit 1
}
if [[ -s "${HELP_ERR}" ]]; then
    echo "Error: --help wrote to stderr" >&2
    cat "${HELP_ERR}" >&2
    exit 1
fi
echo "✓ Help command succeeded"

# No-args is a usage error (exit 2), one named line, not a help dump.
"${MODELFS_BIN}" >"${HELP_OUT}" 2>"${HELP_ERR}" && RC=0 || RC=$?
if [[ "${RC}" -ne 2 ]] || ! grep -q 'missing command' "${HELP_ERR}" || [[ -s "${HELP_OUT}" ]]; then
    echo "Error: expected exit 2 + 'missing command' on stderr for no-args (got rc=${RC})" >&2
    exit 1
fi
if grep -q '^Usage:' "${HELP_ERR}"; then
    echo "Error: no-args dumped Usage: (want one named line)" >&2
    exit 1
fi
echo "✓ No-args usage error is one named line"

"${MODELFS_BIN}" version >"${HELP_OUT}" 2>"${HELP_ERR}"
grep -q '^modelfs ' "${HELP_OUT}" || {
    echo "Error: version did not print on stdout" >&2
    exit 1
}
if [[ -s "${HELP_ERR}" ]]; then
    echo "Error: version wrote to stderr" >&2
    cat "${HELP_ERR}" >&2
    exit 1
fi
echo "✓ Version command succeeded"

# A failed stdout write must not look like success: monitors redirect
# `status` onto a path, and /dev/full is ENOSPC the way a full disk is.
if [[ -e /dev/full ]]; then
    "${MODELFS_BIN}" version >/dev/full 2>/dev/null && RC=0 || RC=$?
    if [[ "${RC}" -ne 1 ]]; then
        echo "Error: version to /dev/full should exit 1 (got rc=${RC})" >&2
        exit 1
    fi
    echo "✓ Stdout write failure exits 1"
fi

"${MODELFS_BIN}" frobnicate >"${HELP_OUT}" 2>"${HELP_ERR}" && RC=0 || RC=$?
if [[ "${RC}" -ne 2 ]] || ! grep -q 'unknown command' "${HELP_ERR}" || [[ -s "${HELP_OUT}" ]]; then
    echo "Error: expected exit 2 + 'unknown command' for a typo (got rc=${RC})" >&2
    exit 1
fi
echo "✓ Unknown command exits 2"

# Status on uninitialized cache must report 'not running' AND exit nonzero.
# NB: status intentionally exits 1 here; capture instead of piping because
# `set -o pipefail` would turn that expected exit into a failed check.
STATUS_OUT="$("${MODELFS_BIN}" status --cache "${CACHE_DIR_1}" 2>&1)" && RC=0 || RC=$?
if [[ "${RC}" -eq 1 ]] && grep -q "not running" <<< "${STATUS_OUT}"; then
    echo "✓ Status on uninitialized cache reported correctly"
else
    echo "Error: expected exit 1 + 'not running' on uninitialized cache (got rc=${RC}): ${STATUS_OUT}" >&2
    exit 1
fi

echo "=== Test Case 2: Pinning & Unpinning ==="
"${MODELFS_BIN}" pin "models/llama3.gguf" --origin "${ORIGIN_DIR}" --cache "${CACHE_DIR_1}" --psk "${PSK_FILE}"
if [[ -f "${CACHE_DIR_1}/pin/models/llama3.gguf" ]]; then
    echo "✓ Pin created pin sidecar file"
else
    echo "Error: pin file not created" >&2
    exit 1
fi

"${MODELFS_BIN}" unpin "models/llama3.gguf" --origin "${ORIGIN_DIR}" --cache "${CACHE_DIR_1}" --psk "${PSK_FILE}"
if [[ ! -f "${CACHE_DIR_1}/pin/models/llama3.gguf" ]]; then
    echo "✓ Unpin removed pin sidecar file"
else
    echo "Error: pin file was not removed" >&2
    exit 1
fi

echo "=== Test Case 3: Peer Discovery Listing ==="
# Lists leases from origin/.cluster; expired ones are marked, not served.
mkdir -p "${ORIGIN_DIR}/.cluster"
printf '%s\n' '{"id":"spark9","until":4102444800,"addrs":[]}' > "${ORIGIN_DIR}/.cluster/spark9.json"
printf '%s\n' '{"id":"old","until":1,"addrs":[]}' > "${ORIGIN_DIR}/.cluster/old.json"
PEERS_OUT="$("${MODELFS_BIN}" peers --origin "${ORIGIN_DIR}")"
if grep -q 'spark9 (until=4102444800, live)' <<< "${PEERS_OUT}" \
    && grep -q 'old (until=1, expired)' <<< "${PEERS_OUT}"; then
    echo "✓ Peer listing shows live and expired leases"
else
    echo "Error: unexpected peers output: ${PEERS_OUT}" >&2
    exit 1
fi

echo "=== All E2E Integration Tests Passed Successfully ==="
