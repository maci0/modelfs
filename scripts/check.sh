#!/usr/bin/env bash
# Single blocking gate for all static analysis: formatting, compile+unit tests,
# restore-drill stub, vendored libfuse3 digests and extract, shell lint,
# Python lint, Python type check, CycloneDX inventory.
set -euo pipefail
export LC_ALL=C
export TZ=UTC

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "${ROOT_DIR}"

usage_no_args "$@" <<'EOF'
Usage: ./scripts/check.sh

The blocking static gate: zig fmt, changelog headings and tag links
versus build.zig.zon, unit tests, the restore-drill stub suite, vendored
libfuse3 digests and extract, shellcheck, ruff, mypy, sbom. Same
command the CI `check` job runs. Requires the pinned .venv from
setup.

Contributor commands (also listed by `zig build --help`; each script
answers --help):
  zig build                                 build the binary
  zig build fmt                             apply zig fmt
  zig build test                            unit tests
  zig build test -Dtest-filter=relOk        tests whose names contain this substring
  zig build test --watch                    rebuild and re-run on change
  zig build check                           this script
  zig build ci / ./scripts/ci.sh            every CI job (this, aarch64, repro)
  ./scripts/cross_aarch64.sh                aarch64 ReleaseFast (extracts vendored libfuse3)
  ./scripts/install_libfuse3_dev.sh         install libfuse3-dev via apt (CI setup; see CONTRIBUTING)
  ./scripts/run_e2e_tests.sh                CLI and peer protocol; no FUSE
  ./scripts/run_cluster_e2e_9nodes.sh       9 FUSE mounts (/dev/fuse + fusermount3)
  ./scripts/run_vm_cluster_e2e.sh           4 VMs (NFS origin + 3 clients) on libvirt/KVM
  ./scripts/test_fault_tolerance.sh         peer loss and lease expiry
  ./scripts/test_dr_restore_drill.sh        restore drill against stub zfs (also in this script)
  ./scripts/check_drill_log.sh              alarm if the monthly drill log is stale
  ./scripts/dr_restore_drill.sh --age-only  alarm if newest snapshot is older than 25 h
  ./scripts/hold_monthlies.sh               hold monthly snapshots (syncoid ExecStartPost)
  ./scripts/install_nas_backup.sh           copy NAS snapshot/replica/drill units (dry-run by default)
  ./scripts/repro_check.sh                  two ReleaseFast builds, compare bytes

Setup, once per clone: see CONTRIBUTING.md.
EOF

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# CI installs the pinned Python tooling into .venv and puts it on PATH
# before running this script. Refuse to stand in with PATH's ruff/mypy:
# those versions disagree with the lock and fail either here or only after
# push.
if [[ -d "${ROOT_DIR}/.venv/bin" ]]; then
    export PATH="${ROOT_DIR}/.venv/bin:${PATH}"
else
    fail "pinned .venv not found; install it with: uv venv .venv && uv pip install --require-hashes -r requirements-dev.lock.txt (see CONTRIBUTING.md)"
fi

# Name every missing tool at once instead of dying mid-gate on a bare
# "command not found"; CONTRIBUTING.md documents where each comes from.
missing=""
for tool in zig shellcheck ruff mypy python3 sha256sum; do
    command -v "${tool}" >/dev/null 2>&1 || missing="${missing} ${tool}"
done
if [[ -n "${missing}" ]]; then
    fail "required tools not found on PATH:${missing} -- see CONTRIBUTING.md (setup section)"
fi

# The venv on PATH must be the lockfile's ruff/mypy and the interpreter
# .python-version names. ruff's required-version also refuses a mismatch,
# but mypy has no equivalent, and a 3.13 venv would type-check a different
# stdlib than CI.
lock_pin() {
    local name="$1" ver
    ver="$(sed -n "s/^${name}==\\([^[:space:]\\\\;]*\\).*/\\1/p" "${ROOT_DIR}/requirements-dev.lock.txt")"
    if [[ -z "${ver}" || "${ver}" == *$'\n'* ]]; then
        fail "cannot read a single ${name}== pin from requirements-dev.lock.txt"
    fi
    printf '%s' "${ver}"
}
ruff_want="$(lock_pin ruff)"
ruff_have="$(ruff --version)"
if [[ "${ruff_have}" != "ruff ${ruff_want}" ]]; then
    fail "ruff is ${ruff_have}, lock pins ${ruff_want}; reinstall .venv from requirements-dev.lock.txt"
fi
mypy_want="$(lock_pin mypy)"
mypy_have="$(mypy --version)"
case "${mypy_have}" in
    "mypy ${mypy_want}" | "mypy ${mypy_want} "*) ;;
    *)
        fail "mypy is ${mypy_have}, lock pins ${mypy_want}; reinstall .venv from requirements-dev.lock.txt"
        ;;
esac
py_want="$(tr -d '[:space:]' < "${ROOT_DIR}/.python-version")"
[[ -n "${py_want}" ]] || fail "empty .python-version"
py_have="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
if [[ "${py_have}" != "${py_want}" ]]; then
    fail "python ${py_have} != .python-version ${py_want}"
fi

# zig fmt does not consult build.zig.zon; catch an old toolchain here
# rather than as a later, less obvious compile failure.
min_zig="$(sed -n 's/^[[:space:]]*\.minimum_zig_version *= *"\([^"]*\)".*/\1/p' "${ROOT_DIR}/build.zig.zon")"
[[ -n "${min_zig}" ]] || fail "cannot read minimum_zig_version from build.zig.zon"
zig_ver="$(zig version)"
if ! awk -v cur="${zig_ver}" -v min="${min_zig}" 'BEGIN {
    ncur = split(cur, c, /[^0-9]+/)
    nmin = split(min, t, /[^0-9]+/)
    for (i = 1; i <= nmin; i++) {
        ci = (i <= ncur) ? (c[i] + 0) : 0
        ti = t[i] + 0
        if (ci < ti) exit 1
        if (ci > ti) exit 0
    }
    exit 0
}'; then
    fail "zig ${zig_ver} is older than minimum_zig_version ${min_zig} in build.zig.zon"
fi

# Instant, and must run before any suite: a missing --help handler used to
# start e2e / FUSE / ReleaseFast work. timeout is the safety net if a handler
# regresses (the test also rejects output that is not usage).
echo "=== script --help ==="
"${SCRIPTS_DIR}/test_scripts_help.sh" || fail "contributor script --help handlers failed"

echo "=== zig fmt --check ==="
zig fmt --check src/ build.zig build.zig.zon || fail "zig fmt --check reported unformatted files; fix with: zig build fmt"

# ## [Name] is a release to changelog readers and tools. Dated notes nest
# as ### under a version so they are not read as one (CONTRIBUTING.md).
# Footer [name]: links are the compare/tag URLs; a heading without one
# cannot be fetched. README/SECURITY.md/THREAT_MODEL.md name the current
# tag so a cut cannot leave those sentences on the previous release.
echo "=== changelog headings ==="
zon_ver="$(sed -n 's/^[[:space:]]*\.version *= *"\([^"]*\)".*/\1/p' "${ROOT_DIR}/build.zig.zon")"
[[ -n "${zon_ver}" ]] || fail "cannot read .version from build.zig.zon"
saw_unreleased=0
saw_current=0
first_h2=""
versions=()
while IFS= read -r line; do
    case "${line}" in
        '## [Unreleased]')
            if [[ -z "${first_h2}" ]]; then
                first_h2="Unreleased"
            fi
            if [[ "${saw_unreleased}" -eq 1 ]]; then
                fail "CHANGELOG.md has more than one ## [Unreleased]"
            fi
            saw_unreleased=1
            ;;
        '## ['*)
            name="${line#\#\# \[}"
            name="${name%%]*}"
            if [[ -z "${first_h2}" ]]; then
                first_h2="${name}"
            fi
            if [[ ! "${name}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.]+)*$ ]]; then
                fail "changelog heading is not Unreleased or semver: ${line}"
            fi
            case "${line}" in
                "## [${name}] - "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
                    ;;
                *)
                    fail "changelog version heading must be ## [x.y.z] - YYYY-MM-DD: ${line}"
                    ;;
            esac
            if [[ "${name}" == "${zon_ver}" ]]; then
                saw_current=1
            fi
            versions+=("${name}")
            ;;
        *)
            ;;
    esac
done < "${ROOT_DIR}/CHANGELOG.md"
[[ "${saw_unreleased}" -eq 1 ]] || fail "CHANGELOG.md missing ## [Unreleased]"
[[ "${first_h2}" == "Unreleased" ]] || fail "CHANGELOG.md first ## heading must be [Unreleased] (got ${first_h2:-none})"
[[ "${saw_current}" -eq 1 ]] || fail "CHANGELOG.md missing ## [${zon_ver}] (build.zig.zon .version)"

if ! grep -q '^\[Unreleased\]:' "${ROOT_DIR}/CHANGELOG.md"; then
    fail "CHANGELOG.md missing [Unreleased] link"
fi
if ! grep '^\[Unreleased\]:' "${ROOT_DIR}/CHANGELOG.md" | grep -Fq "v${zon_ver}"; then
    fail "CHANGELOG.md [Unreleased] compare link must name v${zon_ver}"
fi
if [[ "${#versions[@]}" -gt 0 ]]; then
    for ver in "${versions[@]}"; do
        if ! grep -q "^\[${ver}\]:" "${ROOT_DIR}/CHANGELOG.md"; then
            fail "CHANGELOG.md missing [${ver}] link"
        fi
    done
fi

for f in README.md SECURITY.md docs/THREAT_MODEL.md; do
    if ! grep -Fq "v${zon_ver}" "${ROOT_DIR}/${f}"; then
        fail "${f} does not mention v${zon_ver} (build.zig.zon .version)"
    fi
done

echo "=== vendored fuse3 hashes ==="
(
    cd "${ROOT_DIR}/.deps/fuse3-arm64"
    sha256sum -c SHA256SUMS
) || fail "vendored libfuse3 sha256 mismatch; refresh per .deps/fuse3-arm64/README.md"

echo "=== shellcheck ==="
# Optional checks live in .shellcheckrc so a glob of every scripts/**/*.sh
# matches this gate. Recurse: scripts/*.sh would skip a nested script.
# The style-only brace/double-bracket checks stay off: this tree does
# not follow those conventions.
shopt -s globstar nullglob
sh_files=(scripts/**/*.sh)
shopt -u nullglob
[[ "${#sh_files[@]}" -gt 0 ]] || fail "no shell scripts found under scripts/"
shellcheck "${sh_files[@]}" || fail "shellcheck reported violations"

# The NAS drill cannot run here (no zfs pool). The stub suite is what
# keeps a clone-onto-live or empty-snapshot false pass from shipping.
echo "=== restore drill (stub zfs) ==="
"${SCRIPTS_DIR}/test_dr_restore_drill.sh" || fail "restore drill stub tests failed"

# Digests already checked above (coreutils only). The extract suite
# re-verifies them before unpack so a stale-tree or unpack-tool regression
# fails this gate instead of only the aarch64 job.
echo "=== vendored libfuse3 extract ==="
"${SCRIPTS_DIR}/test_extract_fuse3_arm64.sh" || fail "vendored libfuse3 extract tests failed"

echo "=== ruff ==="
# No path: pyproject.toml is in ruff's default set, and a Python file
# outside scripts/ cannot skip the gate. Matches a bare `ruff check`.
ruff check || fail "ruff check reported violations"

echo "=== ruff format --check ==="
ruff format --check || fail "ruff format --check reported unformatted files; fix with: ruff format"

echo "=== mypy ==="
# files = ["scripts"] in pyproject.toml, so a bare `mypy` matches this gate.
mypy || fail "mypy reported errors"

echo "=== sbom ==="
python3 "${SCRIPTS_DIR}/sbom.py" --self-test || fail "sbom self-test failed"
python3 "${SCRIPTS_DIR}/sbom.py" --check || fail "sbom.cdx.json is out of date; regenerate with: python3 scripts/sbom.py --write"

# Slowest step last: the linters above are instant, so a lint failure never
# pays for the full compile first.
echo "=== zig build test ==="
zig build test || fail "zig build test failed"

echo "=== All static analysis checks passed ==="
