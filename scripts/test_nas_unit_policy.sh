#!/usr/bin/env bash
# Pin the NAS unit policy check.sh runs: no MODELFS_ knob, no secret on
# ExecStart, no /tmp payload in any shipped systemd unit -- and, since
# install_nas_backup.sh also ships and installs nas/drop-ins/**/*.conf, in
# any drop-in either. A drop-in is the file `systemctl edit` writes, so an
# override lands there at least as easily as in the unit it overrides.
#
# The scan is read out of check.sh rather than restated here, so this test
# cannot pass against a copy of the rule that has since been narrowed: the
# block between the two markers is executed verbatim, against a scratch
# copy of scripts/nas/ the cases below plant into.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "${ROOT_DIR}"

usage_no_args "$@" <<'EOF'
Usage: ./scripts/test_nas_unit_policy.sh

Assert check.sh's NAS unit policy scan covers nas/*.service and
nas/drop-ins/*/*.conf, and flags a MODELFS_ knob, a secret on
ExecStart, or a /tmp payload in either. Also run by check.sh.
EOF

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

check_sh="${SCRIPTS_DIR}/check.sh"
[[ -f "${check_sh}" ]] || fail "cannot find ${check_sh}"

# The scan lives inline in the gate between two marker comments. Extracting
# it by marker is what keeps one implementation: check.sh runs the block and
# this test runs the same bytes, so narrowing the glob in one place fails
# here instead of silently testing a rule the gate no longer applies.
scan_body="$(sed -n '/^# nas-unit-policy: scan start$/,/^# nas-unit-policy: scan end$/p' "${check_sh}")"
[[ -n "${scan_body}" ]] || fail "check.sh has no nas-unit-policy scan markers to extract"

# The block is written to a file rather than piped on stdin: `source
# /dev/stdin` while the script itself arrives on stdin is one stream, and the
# two would read each other.
scan_file="${SCRATCH_DIR}/nas-unit-policy-scan.sh"
printf '%s\n' "${scan_body}" >"${scan_file}"
trap 'rm -f "${scan_file}"; rm -rf "${SCRATCH_DIR}"/nas-unit-policy.*' EXIT

# One case: $1 is a case tree holding a nas/ directory. Prints the violation
# string the scan produced, or nothing on a clean tree. The block is run in a
# subshell with SCRIPTS_DIR pointed at $1 (the block globs ${SCRIPTS_DIR}/nas)
# and nas_unit_violations printed at the end, so one implementation serves
# both the gate and these cases.
#
# A nonzero exit is an error in the extracted block (a syntax error, a
# reference the block does not have), not a case outcome: bash -c's status
# is the block's, and the block always ends in 0. Report it rather than
# letting a broken block read as a clean tree.
run_case() {
    local out rc=0
    out="$(SCRIPTS_DIR="$1" bash -c '
        set -euo pipefail
        source "$1"
        printf "%s" "${nas_unit_violations}"
    ' _ "${scan_file}" 2>&1)" || rc=$?
    [[ "${rc}" -eq 0 ]] || fail "the NAS unit policy scan exited ${rc} on $1: ${out}"
    printf '%s' "${out}"
}

# Build a scratch nas/ tree seeded with the shipped units and drop-ins, so
# every case starts from what actually ships and adds exactly one thing.
# Sets case_tree (a global, not an echo) so the case name reaches the mktemp
# template -- every scratch dir carries SCRATCH_DIR, and the case name makes
# a leftover tree readable instead of an anonymous suffix.
new_case_tree() {
    case_tree="$(mktemp -d "${SCRATCH_DIR}/nas-unit-policy.$1.XXXXXX")"
    cp -R "${SCRIPTS_DIR}/nas" "${case_tree}/nas"
}

mkdir -p "${SCRATCH_DIR}"

# The real gate passes: the shipped units and drop-ins carry no MODELFS_
# knob, no secret, and no /tmp payload.
new_case_tree shipped
shipped="$(run_case "${case_tree}")"
[[ -z "${shipped}" ]] || fail "the shipped NAS units and drop-ins violate the policy: ${shipped}"

# A drop-in that exports a MODELFS_ knob must be caught. This is the case
# the pre-widened glob missed: nas/drop-ins/**/*.conf is not a *.service.
new_case_tree knob
printf '[Service]\nEnvironment=MODELFS_PSK_VALUE=leaked\n' \
    >"${case_tree}/nas/drop-ins/sanoid.service.d/knob.conf"
knob_out="$(run_case "${case_tree}")"
[[ "${knob_out}" == *Environment=MODELFS_* ]] \
    || fail "a MODELFS_ knob in a drop-in was not flagged (scan said: '${knob_out}')"

# ...and an indented one, because a drop-in written by a paste may indent.
new_case_tree knob-indent
mkdir -p "${case_tree}/nas/drop-ins/syncoid-models.service.d"
printf '[Service]\n  Environment=MODELFS_LOG_DIR=/var/log/modelfs\n' \
    >"${case_tree}/nas/drop-ins/syncoid-models.service.d/override.conf"
knob_indent_out="$(run_case "${case_tree}")"
[[ "${knob_indent_out}" == *Environment=MODELFS_* ]] \
    || fail "an indented MODELFS_ knob in a drop-in was not flagged (scan said: '${knob_indent_out}')"

# A secret on ExecStart in a drop-in is the same class: argv is
# world-readable through /proc/<pid>/cmdline.
new_case_tree secret
printf '[Service]\nExecStart=/bin/logger --token=abc123\n' \
    >"${case_tree}/nas/drop-ins/sanoid.service.d/secret.conf"
secret_out="$(run_case "${case_tree}")"
[[ "${secret_out}" == *secret\ on\ ExecStart* ]] \
    || fail "a secret on a drop-in ExecStart was not flagged (scan said: '${secret_out}')"

# A /tmp payload in a drop-in is charged to RAM, same as a bare mktemp.
new_case_tree tmp
printf '[Service]\nEnvironment=MF_DRILL_SCRATCH=/tmp/modelfs-drill\n' \
    >"${case_tree}/nas/drop-ins/sanoid.service.d/tmp.conf"
tmp_out="$(run_case "${case_tree}")"
[[ "${tmp_out}" == */tmp\ payload* ]] \
    || fail "a /tmp payload in a drop-in was not flagged (scan said: '${tmp_out}')"

# The unit side must still be covered: narrowing the glob to drop-ins only
# would pass every case above.
new_case_tree unit
printf '[Service]\nEnvironment=MODELFS_LOG_DIR=/var/log/modelfs\n' \
    >"${case_tree}/nas/probe.service"
unit_out="$(run_case "${case_tree}")"
[[ "${unit_out}" == *Environment=MODELFS_* ]] \
    || fail "a MODELFS_ knob in a .service was not flagged (scan said: '${unit_out}')"

# /var/tmp is not /tmp: the shipped drill scratch lives there and must pass.
new_case_tree vartmp
printf '[Service]\nEnvironment=MF_DRILL_SCRATCH=/var/tmp/modelfs-drill\n' \
    >"${case_tree}/nas/drop-ins/sanoid.service.d/vartmp.conf"
vartmp_out="$(run_case "${case_tree}")"
[[ -z "${vartmp_out}" ]] \
    || fail "/var/tmp was treated as a /tmp payload: ${vartmp_out}"

echo "=== NAS unit policy ok ==="
