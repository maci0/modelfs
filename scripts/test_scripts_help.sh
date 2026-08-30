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

# Every top-level scripts/*.sh and scripts/*.py is a contributor command
# and must answer --help. Discovered by glob so a new script is covered the
# moment it lands instead of needing its name added to a list that can be
# forgotten; lib.sh is the one exception (a sourced library, not a command).
# --help must start with "Usage:" on stdout with empty stderr; unknown
# arguments must exit 2 with Usage: on stderr so a missing handler that
# happens to finish inside the timeout still fails.
scripts=()
for s in scripts/*.sh scripts/*.py; do
    if [[ "${s}" != "scripts/lib.sh" ]]; then
        scripts+=("${s}")
    fi
done

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
