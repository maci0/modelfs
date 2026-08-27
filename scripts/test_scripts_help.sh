#!/usr/bin/env bash
# Pin that documented contributor scripts answer --help (and refuse unknown
# arguments) instead of starting a build, a FUSE mount, or a test run.
# ./scripts/run_e2e_tests.sh --help used to execute the whole suite.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage_no_args "$@" <<'EOF'
Usage: ./scripts/test_scripts_help.sh

Assert every documented contributor script prints usage on --help and
refuses unknown arguments. Also run by check.sh.
EOF

cd "${ROOT_DIR}"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

command -v timeout >/dev/null 2>&1 || fail "timeout not found on PATH (coreutils)"

# Scripts listed by ./scripts/check.sh --help, plus extract/install (same
# pattern) and this file. Output must start with "Usage:" so a missing
# handler that happens to finish inside the timeout still fails.
scripts=(
    scripts/check.sh
    scripts/ci.sh
    scripts/cross_aarch64.sh
    scripts/extract_fuse3_arm64.sh
    scripts/install_libfuse3_dev.sh
    scripts/repro_check.sh
    scripts/run_cluster_e2e_9nodes.sh
    scripts/run_e2e_tests.sh
    scripts/test_dr_restore_drill.sh
    scripts/test_extract_fuse3_arm64.sh
    scripts/test_fault_tolerance.sh
    scripts/test_scripts_help.sh
)

for s in "${scripts[@]}"; do
    path="${ROOT_DIR}/${s}"
    [[ -x "${path}" ]] || fail "${s} is not executable"
    out=""
    rc=0
    out="$(timeout 2 "${path}" --help 2>&1)" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        fail "${s} --help exited ${rc}"
    fi
    case "${out}" in
        Usage:*)
            ;;
        *)
            fail "${s} --help did not print Usage: (got: ${out})"
            ;;
    esac
    rc=0
    timeout 2 "${path}" --not-a-flag >/dev/null 2>&1 || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        fail "${s} accepted an unknown argument"
    fi
    if [[ "${rc}" -eq 124 ]]; then
        fail "${s} --not-a-flag did not exit before timeout (started work?)"
    fi
done

echo "=== script --help ok ==="
