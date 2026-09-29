#!/usr/bin/env bash
# Single blocking gate for all static analysis: formatting, compile+unit tests,
# restore-drill stub, review-guide gates, vendored libfuse3 digests and extract,
# shell lint, Python lint, Python type check, CycloneDX inventory.
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
stub suite, vendored libfuse3 digests and extract, review-guide applicability
gates, shellcheck, ruff, mypy, sbom. Same command the CI `check` job runs.
Requires the pinned .venv from setup (python3/ruff/mypy inside .venv/bin,
interpreter matching .python-version).

Contributor commands (also listed by `zig build --help`; each script
answers --help):
  zig build                                 build the binary
  zig build fmt                             apply zig fmt
  .venv/bin/ruff format                     apply pinned ruff format
  zig build test                            unit tests
  zig build test -Dtest-filter=relOk        tests whose names contain this substring
  zig build test --watch                    rebuild and re-run on change
  zig build check                           this script
  zig build ci / ./scripts/ci.sh            every CI job (this, aarch64 cross, static, repro)
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
  ./scripts/dr_point_restore.sh SNAP --copy REL
                                           copy one path back from a known-good snapshot (--execute)
  ./scripts/dr_restore_drill.sh --age-only  alarm if newest snapshot is older than 25 h
  ./scripts/hold_monthlies.sh               hold monthly snapshots (syncoid ExecStartPost)
  ./scripts/install_nas_backup.sh           copy NAS snapshot/replica/drill units (dry-run by default)
  ./scripts/repro_check.sh                  two ReleaseFast builds, compare bytes
  ./scripts/build_static.sh <target>        static musl release build (also run by release.yml)
  ./scripts/package_release.sh --dist DIR   flatten, bundle licenses, checksum release assets
  ./scripts/check_release_tag.sh [TAG]      assert the tag names build.zig.zon's version (release.yml)

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
    fail "pinned .venv not found; install it with: uv venv .venv && uv pip install --python .venv/bin/python3 --require-hashes -r requirements-dev.lock.txt (see CONTRIBUTING.md)"
fi
export PATH="${venv_bin}:${PATH}"
for tool in python3 ruff mypy; do
    resolved="$(command -v "${tool}" || true)"
    case "${resolved}" in
        "${venv_bin}"/*) ;;
        *)
            fail "pinned .venv is missing ${tool}; install it with: uv venv .venv && uv pip install --python .venv/bin/python3 --require-hashes -r requirements-dev.lock.txt (see CONTRIBUTING.md)"
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
    fail "venv python is ${py_got}, want ${py_need} from .python-version; recreate with: uv venv .venv && uv pip install --python .venv/bin/python3 --require-hashes -r requirements-dev.lock.txt (see CONTRIBUTING.md)"
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

# Shell lint is the one analyzer this gate cannot pin by version: the tool
# comes from the package manager, and CI reads whatever the runner image
# ships. Its optional checks are named, not numbered, in .shellcheckrc, and
# a shellcheck that does not know a name ignores it: no warning, no error,
# that rule simply stays off while the gate reports a pass. Require that
# this shellcheck defines every name the config enables, so an older one
# fails here instead of linting less than CI does.
optional_checks="$(shellcheck --list-optional | sed -n 's/^name:[ \t]*//p')" \
    || fail "shellcheck --list-optional failed; install a newer shellcheck (see CONTRIBUTING.md)"
[[ -n "${optional_checks}" ]] \
    || fail "shellcheck --list-optional listed no checks; install a newer shellcheck (see CONTRIBUTING.md)"
enabled_optional="$(sed -n 's/^enable=//p' "${ROOT_DIR}/.shellcheckrc")" \
    || fail "cannot read the enable= checks from .shellcheckrc"
unknown_optional=""
while IFS= read -r opt; do
    [[ -n "${opt}" ]] || continue
    grep -qxF -- "${opt}" <<<"${optional_checks}" || unknown_optional="${unknown_optional} ${opt}"
done <<<"${enabled_optional}"
[[ -z "${unknown_optional}" ]] \
    || fail "shellcheck on PATH does not define the optional checks${unknown_optional} enabled in .shellcheckrc; install a newer shellcheck (see CONTRIBUTING.md)"

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

# zig fmt does not consult build.zig.zon; catch an old toolchain here
# rather than as a later, less obvious compile failure.
require_zig

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
zon_ver="$(zon_version)"
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
    sha256sum -c SHA256SUMS || exit 1
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

# The shell in a workflow or a composite action is the same shell the gate
# lints everywhere else, and none of it lives under scripts/: the release
# publish job alone holds the awk, cmp, and gh recipe that decides what a
# release contains. Extract every `run:` value with scripts/ci_run_steps.awk
# and lint the result as one bash script. The step count is asserted against
# the number of `run:` keys, so an extractor that stopped matching fails
# here instead of reporting a pass having linted nothing.
# SC2154 and SC2312 are off for this pass alone: a step's `env:` and `with:`
# values (TAG, GITHUB_OUTPUT, the matrix target) are YAML keys, not shell,
# so they are in the workflow but not in the extracted body; and the release
# job's `test "$(modelfs version)" = ...` is an assertion that reads a
# command's output, which is what SC2312 flags.
echo "=== shellcheck (CI run steps) ==="
ci_shell_files=(.github/workflows/*.yml .github/actions/*/action.yml)
[[ "${#ci_shell_files[@]}" -gt 0 ]] || fail "no CI workflow or composite action files found"
ci_runs="$(awk '/^[[:space:]]*run:/ { n++ } END { print n + 0 }' "${ci_shell_files[@]}")"
[[ "${ci_runs}" -gt 0 ]] || fail "no CI run: steps found to lint"
ci_shell="$(awk -f "${SCRIPTS_DIR}/ci_run_steps.awk" "${ci_shell_files[@]}")"
ci_steps="$(awk '/^# modelfs-ci-run-step$/ { n++ } END { print n + 0 }' <<<"${ci_shell}")"
[[ "${ci_steps}" -eq "${ci_runs}" ]] \
    || fail "extracted ${ci_steps} CI run steps but the workflows declare ${ci_runs} (scripts/ci_run_steps.awk stopped matching)"
printf '%s\n' "${ci_shell}" | shellcheck -s bash -e SC2154,SC2312 - \
    || fail "shellcheck reported violations in the CI run steps"

# Properties of the harness itself, which no linter can see: a script that
# exports a MODELFS_-spelled knob, a unit that exports one, or a piece cache
# under /tmp passes shellcheck, ruff, and mypy while the modelfs calls in
# that shell die on an unknown environment variable, or a run artifact is
# charged to RAM. Check them here so a new script or unit is covered by
# default instead of by a reviewer's memory.
echo "=== harness policy ==="

# Every mktemp call lands in the scratch dir. The two exceptions write
# outside the repo by design: install_nas_backup.sh stages the unit copy
# beside its destination (an atomic rename needs the same filesystem) and
# run_vm_cluster_e2e.sh puts qemu disk images under libvirt's own directory.
# A bare mktemp template lands on tmpfs, where a multi-gigabyte piece cache
# is charged to RAM. The pattern matches any mktemp call whatever the flags
# are and in whatever order they appear, so `mktemp -p /var/lib/libvirt/
# images d-XXXXXX` and `mktemp "$tpl"` are judged on their template too,
# not only the flag-then-template spelling, and a call carrying no
# XXXXXX at all is judged as well: `mktemp -d` with no argument is the
# shortest way to the same tmpfs payload and cannot be caught by a pattern
# that requires a template. A `for tool in ... mktemp ...` list that builds
# a PATH for a preflight is the one line that names mktemp without calling
# it, and it is skipped as such.
unscoped_mktemp=""
for sh in "${sh_files[@]}"; do
    while IFS= read -r hit; do
        line="${hit#*:}"
        if [[ "${line}" == for\ *\ in\ * ]]; then
            continue
        fi
        if [[ "${line}" != *SCRATCH_DIR* && "${line}" != *dest_path* \
            && "${line}" != */var/lib/libvirt/images/* ]]; then
            unscoped_mktemp="${unscoped_mktemp} ${hit}"
        fi
    done < <(grep -nE '^[^#]*\bmktemp\b' "${sh}" || true)
done
[[ -z "${unscoped_mktemp}" ]] \
    || fail "mktemp without a SCRATCH_DIR template (tmpfs payload):${unscoped_mktemp//$'\n'/, }"

# The Python side of the same rule. tempfile's default directory is
# gettempdir(), which is /tmp on these hosts, so a mkdtemp or
# TemporaryDirectory without dir= puts a piece cache or a FUSE origin on
# tmpfs exactly as a bare `mktemp -d` does. run_benchmarks_and_plots.py
# names _SCRATCH and sbom.py names the repo scratch; a third script has to
# as well, and the check is what says so. A call split over several lines
# is read to its closing paren, so `dir=` on a continuation line counts.
unscoped_py_temp=""
for py in "${SCRIPTS_DIR}"/*.py; do
    [[ -e "${py}" ]] || continue
    # A named rc, not a masked one: an awk that failed to parse would
    # report nothing found, which is the same shape as a clean scan.
    py_rc=0
    py_hits="$(awk '
        # Read the whole file once, then walk it with an index, so a
        # multi-line call is read to its closing paren without consuming
        # the lines after it: a getline lookahead would swallow the next
        # tempfile call and miss it.
        { line[FNR] = $0 }
        END {
            i = 1
            while (i <= FNR) {
                text = line[i]
                if (text ~ /^[[:space:]]*#/) { i++; continue }
                if (text !~ /(^|[^A-Za-z0-9_])(mkdtemp|mkstemp|TemporaryDirectory|NamedTemporaryFile)\(/) { i++; continue }
                start = i
                depth = opens(text) - closes(text)
                while (depth > 0 && i < FNR) { i++; text = text " " line[i]; depth += opens(line[i]) - closes(line[i]) }
                if (text !~ /dir=/) { print FILENAME ":" start ":" line[start] }
                i++
            }
        }
        function opens(s) { return gsub(/\(/, "(", s) }
        function closes(s) { return gsub(/\)/, ")", s) }
    ' "${py}")" || py_rc=$?
    [[ "${py_rc}" -eq 0 ]] \
        || fail "the tempfile scan of ${py##*/} failed (rc=${py_rc}); the tmpfs-payload check did not run"
    [[ -z "${py_hits}" ]] || unscoped_py_temp="${unscoped_py_temp} ${py_hits}"
done
[[ -z "${unscoped_py_temp}" ]] \
    || fail "tempfile call without dir= (tmpfs payload):${unscoped_py_temp//$'\n'/, }"

# ROOT_DIR, SCRATCH_DIR, and SCRIPTS_DIR come from lib.sh and nowhere else,
# so a script that reads one without sourcing it resolves them to nothing. A
# script that reads none is exempt, but must be named here: an unnamed one
# is a script that hardcodes a repo-relative path or a scratch location, and
# naming it is a deliberate act.
no_lib_sh=(
    backup_config.sh
    check_drill_log.sh
    check_offsite.sh
    check_release_tag.sh
    dr_point_restore.sh
    dr_pool_restore.sh
    hold_monthlies.sh
    install_libfuse3_dev.sh
)
lib_sh_violations=""
unsourced=""
unnamed=""
for sh in "${sh_files[@]}"; do
    base="${sh##*/}"
    if [[ "${base}" == "lib.sh" ]]; then
        continue
    fi
    sources_lib_sh=0
    if grep -q 'lib\.sh' "${sh}"; then
        sources_lib_sh=1
    fi
    uses_lib_sh=0
    if grep -qE '(^|[^A-Za-z0-9_])(ROOT_DIR|SCRATCH_DIR|SCRIPTS_DIR)' "${sh}"; then
        uses_lib_sh=1
    fi
    listed=0
    for exempt in "${no_lib_sh[@]}"; do
        if [[ "${exempt}" == "${base}" ]]; then
            listed=1
        fi
    done
    if [[ "${uses_lib_sh}" -eq 1 && "${sources_lib_sh}" -eq 0 ]]; then
        unsourced="${unsourced} ${base}"
    fi
    if [[ "${uses_lib_sh}" -eq 0 && "${listed}" -eq 0 ]]; then
        unnamed="${unnamed} ${base}"
    fi
done
[[ -z "${unsourced}" ]] \
    || fail "scripts read ROOT_DIR/SCRATCH_DIR/SCRIPTS_DIR without sourcing lib.sh:${unsourced}"
[[ -z "${unnamed}" ]] \
    || fail "scripts using neither lib.sh nor a named exemption:${unnamed}; add the name to no_lib_sh in check.sh or source lib.sh"
for exempt in "${no_lib_sh[@]}"; do
    if [[ ! -e "${SCRIPTS_DIR}/${exempt}" ]]; then
        lib_sh_violations="${lib_sh_violations} ${exempt}"
    fi
done
[[ -z "${lib_sh_violations}" ]] \
    || fail "no_lib_sh in check.sh names scripts that no longer exist:${lib_sh_violations}"

# The daemon refuses any MODELFS_* name it does not document, so a unit or
# a harness that exports one makes every modelfs call in that environment
# fail before the command runs. Units also keep secrets off ExecStart: argv
# is world-readable through /proc/<pid>/cmdline.
nas_unit_violations=""
for unit in "${SCRIPTS_DIR}"/nas/*.service; do
    [[ -e "${unit}" ]] || continue
    if grep -qE '^[[:space:]]*Environment=.*MODELFS_' "${unit}"; then
        nas_unit_violations="${nas_unit_violations} ${unit##*/}:Environment=MODELFS_"
    fi
    if grep -qiE '^[[:space:]]*ExecStart=.*(psk|token|secret)' "${unit}"; then
        nas_unit_violations="${nas_unit_violations} ${unit##*/}:secret on ExecStart"
    fi
    if grep -qE '^[[:space:]]*(Environment|ExecStart)=.*[^A-Za-z0-9_]/tmp(/|[^A-Za-z0-9_])' "${unit}"; then
        nas_unit_violations="${nas_unit_violations} ${unit##*/}:/tmp payload"
    fi
done
[[ -z "${nas_unit_violations}" ]] \
    || fail "NAS unit policy (harness knobs stay MF_, no secret on ExecStart, no /tmp payload):${nas_unit_violations}"

# lib.sh's comment block is the one list of harness knobs; the daemon's
# prefix is the other. A new MF_ knob that is not listed there is a knob
# nobody has checked against the daemon, so fail until the list catches up.
documented_mf="$(sed -n '/^# Environment namespaces/,/^$/p' "${SCRIPTS_DIR}/lib.sh" \
    | grep -oE 'MF_[A-Z0-9_]+' | sort -u)"
read_mf="$({ grep -rhoE '\$\{?MF_[A-Z0-9_]+' "${sh_files[@]}" || true; grep -rhoE 'MF_[A-Z0-9_]+=' "${sh_files[@]}" || true; } \
    | grep -oE 'MF_[A-Z0-9_]+' | sort -u)"
undocumented_mf="$(comm -23 <(printf '%s\n' "${read_mf}") <(printf '%s\n' "${documented_mf}") | tr '\n' ' ')"
[[ -z "${undocumented_mf}" ]] \
    || fail "MF_ knobs read under scripts/ but absent from the lib.sh member list:${undocumented_mf}"

# .env.example is the operator's copy of the MODELFS_ namespace, and the
# daemon refuses any name outside it. A knob added to env_knobs without a
# line here is documented only in README and the threat model, and a name
# left in the example after it leaves the table is copied verbatim into a
# deployment, where the very next modelfs call dies on the typo refusal.
# Both directions are checked, so the example and the table cannot drift.
env_example="${ROOT_DIR}/.env.example"
knob_mf="$(sed -n '/^const env_knobs/,/^};/p' src/main.zig \
    | grep -oE 'MODELFS_[A-Z0-9_]+' | sort -u)"
[[ -n "${knob_mf}" ]] \
    || fail "no MODELFS_ knob read out of the env_knobs table in src/main.zig"
example_mf="$(grep -oE 'MODELFS_[A-Z0-9_]+' "${env_example}" | sort -u)"
undocumented_knob="$(comm -23 <(printf '%s\n' "${knob_mf}") <(printf '%s\n' "${example_mf}") | tr '\n' ' ')"
[[ -z "${undocumented_knob}" ]] \
    || fail "MODELFS_ knobs in env_knobs but absent from .env.example:${undocumented_knob}"
stale_knob="$(comm -13 <(printf '%s\n' "${knob_mf}") <(printf '%s\n' "${example_mf}") | tr '\n' ' ')"
[[ -z "${stale_knob}" ]] \
    || fail ".env.example documents MODELFS_ names the daemon refuses:${stale_knob}"

# AGENTS.md says every review prompt under docs/review-guides/ names its own
# applicability gate, so a prompt aimed at another tree skips instead of
# reporting on code it does not own. A guide without one is a prompt that runs
# everywhere; check it here so a new guide is covered by the gate rather than
# by a reviewer's memory.
echo "=== review guide applicability gates ==="
shopt -s nullglob
guide_files=(docs/review-guides/*.md)
shopt -u nullglob
[[ "${#guide_files[@]}" -gt 0 ]] || fail "no review guides under docs/review-guides/"
ungated_guides=""
for guide in "${guide_files[@]}"; do
    grep -qi 'applicability gate' "${guide}" \
        || ungated_guides="${ungated_guides} ${guide##*/}"
done
[[ -z "${ungated_guides}" ]] \
    || fail "review guide without an applicability gate:${ungated_guides}"

# The NAS drill cannot run here (no zfs pool). The stub suite is what
# keeps a clone-onto-live or empty-snapshot false pass from shipping.
echo "=== restore drill (stub zfs) ==="
"${SCRIPTS_DIR}/test_dr_restore_drill.sh" || fail "restore drill stub tests failed"

# Digests already checked above (coreutils only). The extract suite
# re-verifies them before unpack so a stale-tree or unpack-tool regression
# fails this gate instead of only the aarch64 job.
echo "=== vendored libfuse3 extract ==="
"${SCRIPTS_DIR}/test_extract_fuse3_arm64.sh" || fail "vendored libfuse3 extract tests failed"

# The release job is re-runnable, so the packaging step has to be too.
echo "=== release packaging rerun ==="
"${SCRIPTS_DIR}/test_package_release.sh" || fail "release packaging rerun tests failed"

echo "=== ruff ==="
# No path: pyproject.toml is in ruff's default set, and a Python file
# outside scripts/ cannot skip the gate. Matches a bare `ruff check`.
ruff check || fail "ruff check reported violations"

echo "=== ruff format --check ==="
ruff format --check || fail "ruff format --check reported unformatted files; fix with: .venv/bin/ruff format"

echo "=== mypy ==="
mypy || fail "mypy reported errors"

echo "=== sbom ==="
python3 "${SCRIPTS_DIR}/sbom.py" --self-test || fail "sbom self-test failed"
python3 "${SCRIPTS_DIR}/sbom.py" --check || fail "sbom.cdx.json is out of date; regenerate with: python3 scripts/sbom.py --write"

# Slowest step last: the linters above are instant, so a lint failure never
# pays for the full compile first.
echo "=== zig build test ==="
zig build test || fail "zig build test failed"

echo "=== All static analysis checks passed ==="
