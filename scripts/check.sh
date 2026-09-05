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
versus build.zig.zon, src/root.zig imports, unit tests, the restore-drill
stub suite, vendored libfuse3 digests and extract, shellcheck, ruff, mypy,
sbom. Same command the CI `check` job runs. Requires the pinned .venv
from setup (python3/ruff/mypy inside .venv/bin, interpreter matching
.python-version).

Contributor commands (also listed by `zig build --help`; each script
answers --help):
  zig build                                 build the binary
  zig build fmt                             apply zig fmt
  ruff format                               apply ruff format
  zig build test                            unit tests
  zig build test -Dtest-filter=relOk        tests whose names contain this substring
  zig build test --watch                    rebuild and re-run on change
  zig build check                           this script
  zig build ci / ./scripts/ci.sh            every CI job (this, aarch64, repro)
  ./scripts/cross_aarch64.sh                aarch64 ReleaseFast (extracts vendored libfuse3)
  ./scripts/install_libfuse3_dev.sh         install libfuse3-dev via apt (CI setup; see CONTRIBUTING)
  ./scripts/run_e2e_tests.sh                CLI and peer protocol; no FUSE
  ./scripts/run_cluster_e2e_9nodes.sh       9 FUSE mounts (/dev/fuse + fusermount3)
  ./scripts/test_hot_reload.sh              modelfs update on a live mount (/dev/fuse + fusermount3)
  ./scripts/run_vm_cluster_e2e.sh           4 VMs (NFS origin + 3 clients) on libvirt/KVM
  ./scripts/test_fault_tolerance.sh         peer loss and lease expiry
  ./scripts/test_dr_restore_drill.sh        restore drill against stub zfs (also in this script)
  ./scripts/check_drill_log.sh              alarm if the monthly drill log is stale
  ./scripts/check_offsite.sh                alarm if the site-loss copy is missing or older than 8 days
  ./scripts/dr_pool_restore.sh              pool-loss recv (dry-run; --execute pulls from the replica)
  ./scripts/dr_restore_drill.sh --age-only  alarm if newest snapshot is older than 25 h
  ./scripts/hold_monthlies.sh               hold monthly snapshots (syncoid ExecStartPost)
  ./scripts/install_nas_backup.sh           copy NAS snapshot/replica/drill units (dry-run by default)
  ./scripts/repro_check.sh                  two ReleaseFast builds, compare bytes
build_static.sh <target>        static musl release build (also run by release.yml)

Setup, once per clone: see CONTRIBUTING.md.
EOF

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# CI installs the pinned Python tooling into .venv and puts it on PATH
# before running this script. Refuse to stand in with PATH's ruff/mypy:
# those versions disagree with the lock and fail either here or only after
# push. An empty directory (uv venv without the lock install) used to pass
# the existence check and then pick up the OS ruff/mypy/python3.
venv_bin="${ROOT_DIR}/.venv/bin"
if [[ ! -d "${venv_bin}" ]]; then
    fail "pinned .venv not found; install it with: uv venv .venv && uv pip install --require-hashes -r requirements-dev.lock.txt (see CONTRIBUTING.md)"
fi
export PATH="${venv_bin}:${PATH}"
for tool in python3 ruff mypy; do
    resolved="$(command -v "${tool}" || true)"
    case "${resolved}" in
        "${venv_bin}"/*) ;;
        *)
            fail "pinned .venv is missing ${tool}; install it with: uv venv .venv && uv pip install --require-hashes -r requirements-dev.lock.txt (see CONTRIBUTING.md)"
            ;;
    esac
done

# Same series CI's setup-uv installs from .python-version. A 3.13 venv
# would type-check with mypy python_version=3.12 but run the scripts on a
# different stdlib than the check job.
py_want="$(tr -d '[:space:]' < "${ROOT_DIR}/.python-version")"
[[ -n "${py_want}" ]] || fail "empty .python-version"
py_need="$(awk -v v="${py_want}" 'BEGIN { n = split(v, a, /[^0-9]+/); if (n < 2) exit 1; print a[1] "." a[2] }')" \
    || fail "cannot parse .python-version (${py_want})"
py_got="$(python3 -c 'import sys; print("%d.%d" % (sys.version_info[0], sys.version_info[1]))')" \
    || fail "venv python3 is not a working interpreter"
if [[ "${py_got}" != "${py_need}" ]]; then
    fail "venv python is ${py_got}, want ${py_need} from .python-version; recreate with: uv venv .venv && uv pip install --require-hashes -r requirements-dev.lock.txt (see CONTRIBUTING.md)"
fi

# Name every missing tool at once instead of dying mid-gate on a bare
# "command not found"; CONTRIBUTING.md documents where each comes from.
missing=""
for tool in zig shellcheck ruff mypy python3 sha256sum timeout; do
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
ge_rc=0
# shellcheck disable=SC2310 # version_ge is a pure awk compare; it never relies on set -e
version_ge "${zig_ver}" "${min_zig}" && ge_rc=0 || ge_rc=$?
if [[ "${ge_rc}" -ne 0 ]]; then
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
# Version headings after Unreleased must be unique and strictly descending
# so a cut cannot insert 0.5.1 above 0.6.0 or repeat a tag. Footer [name]:
# links are the compare/tag URLs; a heading without one cannot be fetched.
# README/SECURITY.md/threat-model.md name the current tag so a cut cannot
# leave those sentences on the previous release.
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

# Sets changelog_lt to 0 when $1 < $2 as x.y.z (pre-release/build suffix
# ignored), else 1. A result variable rather than the function's exit
# status: invoking it in `if`/`||` would suppress set -e inside the body
# (SC2310). 10# so a leading-zero patch cannot parse as octal.
changelog_ver_lt_set() {
    changelog_lt=1
    local a="${1%%[+]*}"
    a="${a%%-*}"
    local b="${2%%[+]*}"
    b="${b%%-*}"
    local a1 a2 a3 rest b1 b2 b3
    IFS=. read -r a1 a2 a3 rest <<<"${a}"
    IFS=. read -r b1 b2 b3 rest <<<"${b}"
    : "${rest}"
    a1="${a1:-0}"
    a2="${a2:-0}"
    a3="${a3:-0}"
    b1="${b1:-0}"
    b2="${b2:-0}"
    b3="${b3:-0}"
    if ((10#$a1 < 10#$b1)); then changelog_lt=0; return; fi
    if ((10#$a1 > 10#$b1)); then return; fi
    if ((10#$a2 < 10#$b2)); then changelog_lt=0; return; fi
    if ((10#$a2 > 10#$b2)); then return; fi
    if ((10#$a3 < 10#$b3)); then changelog_lt=0; return; fi
}
changelog_ver_lt_set "0.4.0" "0.5.0"
[[ "${changelog_lt}" -eq 0 ]] || fail "changelog_ver_lt_set 0.4.0 < 0.5.0"
changelog_ver_lt_set "0.3.1" "0.3.0"
[[ "${changelog_lt}" -ne 0 ]] || fail "changelog_ver_lt_set 0.3.1 < 0.3.0 should be false"
changelog_ver_lt_set "0.5.0" "0.5.0"
[[ "${changelog_lt}" -ne 0 ]] || fail "changelog_ver_lt_set equal should be false"
if [[ "${#versions[@]}" -gt 0 ]]; then
    prev=""
    for ver in "${versions[@]}"; do
        if [[ -n "${prev}" ]]; then
            changelog_ver_lt_set "${ver}" "${prev}"
            [[ "${changelog_lt}" -eq 0 ]] || fail "CHANGELOG.md versions must be strictly descending: ${prev} then ${ver}"
        fi
        prev="${ver}"
    done
fi

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

for f in README.md SECURITY.md docs/threat-model.md; do
    if ! grep -Fq "v${zon_ver}" "${ROOT_DIR}/${f}"; then
        fail "${f} does not mention v${zon_ver} (build.zig.zon .version)"
    fi
done

# A new src/*.zig is invisible to `zig build test` until root.zig imports
# it (CONTRIBUTING.md). Discover by glob so a forgotten import fails this
# gate instead of shipping with its tests never run. c.zig is the translate-c
# re-export, wired as a build-system module, not this aggregator.
echo "=== src modules in root.zig ==="
shopt -s nullglob
src_mods=(src/*.zig)
shopt -u nullglob
[[ "${#src_mods[@]}" -gt 0 ]] || fail "no Zig sources under src/"
missing_mods=""
for srcf in "${src_mods[@]}"; do
    base="${srcf##*/}"
    case "${base}" in
        root.zig | c.zig) continue ;;
        *)
            if ! grep -Fq "@import(\"${base}\")" src/root.zig; then
                missing_mods="${missing_mods} ${base}"
            fi
            ;;
    esac
done
if [[ -n "${missing_mods}" ]]; then
    fail "src/root.zig does not import:${missing_mods} -- zig build test will not run that file's tests (see CONTRIBUTING.md)"
fi

echo "=== vendored fuse3 hashes ==="
(
    cd "${ROOT_DIR}/.deps/fuse3-arm64"
    sha256sum -c SHA256SUMS
) || fail "vendored libfuse3 sha256 mismatch; refresh per .deps/fuse3-arm64/README.md"

echo "=== vendored libfuse3 static-source hashes ==="
(
    cd "${ROOT_DIR}/.deps/libfuse3-3.16.2"
    sha256sum -c SHA256SUMS
    # Two-way coverage: build.zig's digest check only validates files the
    # sums LIST; this catches a file added to the tree but omitted from the
    # sums (it would otherwise compile into the release binary unchecked).
    listed="$(grep -c '^[0-9a-f]\{64\}' SHA256SUMS)"
    present="$(find . -type f ! -name SHA256SUMS | wc -l)"
    if [ "${listed}" -ne "${present}" ]; then
        echo "SHA256SUMS lists ${listed} files but the tree holds ${present}; regenerate per README.md" >&2
        exit 1
    fi
) || fail "vendored libfuse3 static-source integrity failed; refresh per .deps/libfuse3-3.16.2/README.md"

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
