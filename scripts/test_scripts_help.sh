#!/usr/bin/env bash
# Pin that documented contributor scripts answer --help (and refuse unknown
# arguments) instead of starting a build, a FUSE mount, or a test run.
# ./scripts/run_e2e_tests.sh --help used to execute the whole suite.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage_no_args "$@" <<'EOF'
Usage: ./scripts/test_scripts_help.sh

Assert every documented contributor script prints Usage: on stdout for
--help/-h (exit 0) and on stderr for unknown arguments (exit 2). Also
run by check.sh.
EOF

cd "${ROOT_DIR}"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

command -v timeout >/dev/null 2>&1 || fail "timeout not found on PATH (coreutils)"

# Scripts listed by ./scripts/check.sh --help, plus extract/install, the
# Python CLIs (including the peer_ping library's direct-invocation
# handler), the restore drill, and this file. --help must start with
# "Usage:" on stdout with empty stderr; unknown arguments must exit 2
# with Usage: on stderr so a missing handler that happens to finish
# inside the timeout still fails.
scripts=(
    scripts/check.sh
    scripts/check_drill_log.sh
    scripts/ci.sh
    scripts/cluster_verify.py
    scripts/cross_aarch64.sh
    scripts/dr_restore_drill.sh
    scripts/extract_fuse3_arm64.sh
    scripts/hold_monthlies.sh
    scripts/install_libfuse3_dev.sh
    scripts/install_nas_backup.sh
    scripts/peer_auth_probe.py
    scripts/peer_ping.py
    scripts/repro_check.sh
    scripts/run_benchmarks_and_plots.py
    scripts/run_cluster_e2e_9nodes.sh
    scripts/run_e2e_tests.sh
    scripts/sbom.py
    scripts/test_dr_restore_drill.sh
    scripts/test_extract_fuse3_arm64.sh
    scripts/test_fault_tolerance.sh
    scripts/test_scripts_help.sh
)

mkdir -p "${SCRATCH_DIR}"
help_out="${SCRATCH_DIR}/scripts-help.out"
help_err="${SCRATCH_DIR}/scripts-help.err"

for s in "${scripts[@]}"; do
    path="${ROOT_DIR}/${s}"
    [[ -x "${path}" ]] || fail "${s} is not executable"
    for flag in --help -h; do
        rc=0
        timeout 2 "${path}" "${flag}" >"${help_out}" 2>"${help_err}" || rc=$?
        if [[ "${rc}" -ne 0 ]]; then
            fail "${s} ${flag} exited ${rc}"
        fi
        out="$(cat "${help_out}")"
        case "${out}" in
            Usage:*)
                ;;
            *)
                fail "${s} ${flag} did not print Usage: on stdout (got: ${out})"
                ;;
        esac
        if [[ -s "${help_err}" ]]; then
            fail "${s} ${flag} wrote to stderr"
        fi
    done
    rc=0
    timeout 2 "${path}" --not-a-flag >"${help_out}" 2>"${help_err}" || rc=$?
    if [[ "${rc}" -ne 2 ]]; then
        fail "${s} --not-a-flag exited ${rc}, want 2"
    fi
    if [[ -s "${help_out}" ]]; then
        fail "${s} --not-a-flag wrote to stdout"
    fi
    err="$(cat "${help_err}")"
    case "${err}" in
        Usage:*)
            ;;
        *)
            fail "${s} --not-a-flag did not print Usage: on stderr (got: ${err})"
            ;;
    esac
done

echo "=== script --help ok ==="
