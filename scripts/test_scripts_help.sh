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

expect_version_ge() {
    local rc=0
    # shellcheck disable=SC2310 # version_ge is a pure awk compare; it never relies on set -e
    version_ge "$1" "$2" && rc=0 || rc=$?
    [[ "${rc}" -eq "$3" ]] || fail "version_ge $1 >= $2 exited ${rc}, want $3"
}
expect_version_ge 0.16.0 0.16.0 0
expect_version_ge 0.16.1 0.16.0 0
expect_version_ge 0.16.0 0.16 0
expect_version_ge 3.12.0 3.12 0
expect_version_ge 3.14.7 3.12 0
expect_version_ge 0.15.99 0.16.0 1
expect_version_ge 3.11.9 3.12 1

expect_zig_version() {
    local version="$1" want="$2" output rc=0
    set +e
    output="$(
        set -e
        zig() {
            [[ "$#" -eq 1 && "$1" == version ]] || exit 99
            printf '%s\n' "${version}"
        }
        require_zig 2>&1
    )"
    rc=$?
    set -e
    [[ "${rc}" -eq "${want}" ]] || fail "require_zig ${version} exited ${rc}, want ${want}"
    if [[ "${want}" -eq 0 ]]; then
        [[ -z "${output}" ]] || fail "require_zig wrote output for the pinned compiler"
    else
        [[ "${output}" == *"does not match minimum_zig_version"* ]] || fail "require_zig omitted the exact pin diagnostic"
    fi
}
zig_pin="$(sed -n 's/^[[:space:]]*\.minimum_zig_version *= *"\([^"]*\)".*/\1/p' build.zig.zon)"
[[ -n "${zig_pin}" ]] || fail "missing Zig pin"
expect_zig_version "${zig_pin}" 0
expect_zig_version 0.0.0 1
expect_zig_version 999.0.0 1
expect_zig_version "${zig_pin}-dev.1" 1
expect_zig_version "" 1

expect_release_tag() {
    local tag="$1" want="$2" output rc=0 operand_rc=0 operand_output
    # The operand form is the one release.yml runs
    # (`check_release_tag.sh "${TAG}"`) and the one the environment form
    # below cannot stand in for: an operand-taking script that refused its
    # own documented operand passed every case here.
    operand_output="$("${SCRIPTS_DIR}/check_release_tag.sh" "${tag}" 2>&1)" || operand_rc=$?
    # The 2>&1 belongs inside the substitution: a redirection on the
    # assignment itself is applied after the command substitution has
    # already run, so its stderr would go to the gate's own stderr.
    output="$(GITHUB_REF_NAME="${tag}" "${SCRIPTS_DIR}/check_release_tag.sh" 2>&1)" || rc=$?
    if [[ "${want}" -eq 0 ]]; then
        [[ "${operand_rc}" -eq 0 ]] || fail "check_release_tag.sh ${tag} (operand) exited ${operand_rc}, want 0: ${operand_output}"
        [[ "${operand_output}" == "${zon_pin}" ]] || fail "check_release_tag.sh ${tag} (operand) printed '${operand_output}', want ${zon_pin}"
    else
        [[ "${operand_rc}" -ne 0 ]] || fail "check_release_tag.sh ${tag} (operand) was accepted"
        [[ "${operand_output}" == *"${zon_pin}"* ]] || fail "check_release_tag.sh ${tag} (operand) omitted the manifest version: ${operand_output}"
    fi
    if [[ "${want}" -eq 0 ]]; then
        [[ "${rc}" -eq 0 ]] || fail "check_release_tag.sh ${tag} exited ${rc}, want 0: ${output}"
        [[ "${output}" == "${zon_pin}" ]] || fail "check_release_tag.sh ${tag} printed '${output}', want ${zon_pin}"
    else
        [[ "${rc}" -ne 0 ]] || fail "check_release_tag.sh accepted ${tag}"
        [[ "${output}" == *"${zon_pin}"* ]] || fail "check_release_tag.sh ${tag} omitted the manifest version: ${output}"
    fi
}
zon_pin="$(zon_version)"
expect_release_tag "v${zon_pin}" 0
expect_release_tag "0.20.0-is-not-the-tag" 1
expect_release_tag "v${zon_pin}-rc1" 1
expect_release_tag "release-${zon_pin}" 1

# The release's notes are the CHANGELOG.md section the tag named, and the
# publish step is the only consumer. An extraction that ran past its own
# section, or matched none, published notes nothing else checked.
notes_body="$("${SCRIPTS_DIR}/release_notes.sh" "${zon_pin}")"
[[ "${notes_body}" == *"- "* ]] || fail "release_notes.sh ${zon_pin} printed no entry: ${notes_body}"
[[ "${notes_body}" != *"## ["* ]] || fail "release_notes.sh ${zon_pin} ran past its own section: ${notes_body}"
# The next heading down is another version's, and its first entry line must
# not be in this version's notes.
next_heading="$(awk -v pin="## [${zon_pin}] - " 'index($0, pin) == 1 { found = 1; next } found && /^## \[/ { print; exit }' CHANGELOG.md)"
next_ver="${next_heading#\#\# \[}"
next_ver="${next_ver%%\]*}"
[[ "${next_ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "cannot read the version after ${zon_pin}: ${next_heading}"
next_entry="$(sed -n "/^## \[${next_ver}\] - /,/^## /p" CHANGELOG.md | grep -m1 '^- ')"
[[ -n "${next_entry}" ]] || fail "${next_ver} has no entry line to keep out of ${zon_pin}'s notes"
[[ "${notes_body}" != *"${next_entry}"* ]] || fail "release_notes.sh ${zon_pin} includes ${next_ver}'s entry"
notes_rc=0
notes_out="$("${SCRIPTS_DIR}/release_notes.sh" "${zon_pin}-is-not-a-version" 2>&1)" || notes_rc=$?
[[ "${notes_rc}" -ne 0 ]] || fail "release_notes.sh accepted ${zon_pin}-is-not-a-version"
[[ "${notes_out}" == *"${zon_pin}-is-not-a-version"* ]] || fail "release_notes.sh omitted the version it could not find: ${notes_out}"

expect_fuse_helper() {
    local helper="$1" output rc=0 bin
    mkdir -p "${SCRATCH_DIR}"
    bin="$(mktemp -d "${SCRATCH_DIR}/fuse-preflight.XXXXXX")"
    ln -s "${BASH}" "${bin}/${helper}"
    set +e
    output="$(
        export PATH="${bin}"
        require_fuse 2>&1
    )"
    rc=$?
    set -e
    if [[ "${helper}" == fusermount ]]; then
        local python benchmark_output benchmark_rc=0
        python="$(command -v python3)"
        benchmark_output="$(timeout 2 env PATH="${bin}" "${python}" "${SCRIPTS_DIR}/run_benchmarks_and_plots.py" 2>&1)" || benchmark_rc=$?
        rm -rf "${bin}"
        [[ "${benchmark_rc}" -eq 1 ]] || fail "benchmark preflight accepted legacy fusermount"
        [[ "${benchmark_output}" == *"no fusermount3 helper on PATH"* ]] || fail "benchmark preflight omitted fusermount3 install hint"
    else
        rm -rf "${bin}"
    fi
    if [[ "${helper}" == fusermount ]]; then
        [[ "${rc}" -eq 1 ]] || fail "require_fuse accepted legacy fusermount"
        [[ "${output}" == *"no fusermount3 helper on PATH"* ]] || fail "require_fuse omitted fusermount3 install hint"
    elif [[ -e /dev/fuse ]]; then
        [[ "${rc}" -eq 0 && -z "${output}" ]] || fail "require_fuse rejected fusermount3"
    else
        [[ "${rc}" -eq 1 && "${output}" == *"/dev/fuse is missing"* ]] || fail "require_fuse omitted missing device"
        [[ "${output}" != *"no fusermount3 helper"* ]] || fail "require_fuse missed fusermount3"
    fi
}
expect_fuse_helper fusermount
expect_fuse_helper fusermount3

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

zig() { exit 99; }

expect_static_args() {
    local want="$1" rc=0 output
    shift
    (
        export -f zig
        timeout 2 "${SCRIPTS_DIR}/build_static.sh" "$@"
    ) >"${help_out}" 2>"${help_err}" || rc=$?
    [[ "${rc}" -eq "${want}" ]] || fail "build_static.sh $* exited ${rc}, want ${want}"
    if [[ "${want}" -eq 0 ]]; then
        [[ ! -s "${help_err}" ]] || fail "build_static.sh $* wrote to stderr"
        output="$(cat "${help_out}")"
        [[ "${output}" == Usage:* ]] || fail "build_static.sh $* omitted stdout usage"
    else
        [[ ! -s "${help_out}" ]] || fail "build_static.sh $* wrote to stdout"
        output="$(cat "${help_err}")"
        [[ "${output}" == Usage:* ]] || fail "build_static.sh $* omitted stderr usage"
    fi
}

for target in x86_64-linux-musl aarch64-linux-musl; do
    expect_static_args 2 "${target}" --not-a-flag
    expect_static_args 2 "${target}" extra
    expect_static_args 2 "${target}" --prefix
    expect_static_args 2 "${target}" --prefix ""
    expect_static_args 2 "${target}" --prefix "${SCRATCH_DIR}/unused" extra
    expect_static_args 2 "${target}" --help extra
    expect_static_args 0 "${target}" --help
    expect_static_args 0 "${target}" -h
done

echo "=== script --help ok ==="
