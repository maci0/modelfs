#!/usr/bin/env bash
# Regression tests for scripts/dr_restore_drill.sh, hold_monthlies.sh,
# check_drill_log.sh, check_offsite.sh, dr_pool_restore.sh, and
# install_nas_backup.sh. The real drill runs on the NAS against
# tank/models; this drives it through a stub zfs(8) that copies fixture
# trees in place of clone, so CI can fail a drill that would hash the
# live export against itself, bless an empty or lease-only snapshot,
# ignore a dead autosnap schedule, hold a replica with no snapshots,
# bless a stale offsite copy, or recv onto the live export.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage_no_args "$@" <<'EOF'
Usage: ./scripts/test_dr_restore_drill.sh

Restore-drill regressions against a stub zfs(8). Also run by check.sh.
EOF

mkdir -p "${SCRATCH_DIR}"

FAILS=0
fail() {
    echo "FAIL: $1" >&2
    FAILS=$((FAILS + 1))
}

pass() {
    echo "ok: $1"
}

TEMP="$(mktemp -d "${SCRATCH_DIR}/dr-test-XXXXXX")"
cleanup() {
    rm -rf "${TEMP}"
}
trap cleanup EXIT

STUB_BIN="${TEMP}/bin"
STUB_STATE="${TEMP}/stub"
mkdir -p "${STUB_BIN}" "${STUB_STATE}"

# Stub implements the zfs subcommands the drill calls. Clone copies
# STUB_SNAP_TREE to the requested mountpoint; without -o mountpoint= it
# inherits the live tree, which is the production bug this suite exists to
# catch if the drill ever drops that flag.
cat >"${STUB_BIN}/zfs" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
STATE="${STUB_STATE:?}"
# "${STATE}/env" and "${STATE}/clone" are written at runtime by this stub
# (and the test harness). They are not files in the repo, so the source
# directives below cannot be followed at lint time.
read_state() {
    # shellcheck source=/dev/null
    source "${STATE}/env"
}
write_clone() {
    printf 'CLONE_NAME=%q\nCLONE_MP=%q\nCLONE_MOUNTED=%q\n' "$1" "$2" "$3" >"${STATE}/clone"
}
clear_clone() {
    rm -f "${STATE}/clone"
    if [[ -n "${CLONE_MP:-}" && -d "${CLONE_MP}" && "${CLONE_MP}" != "${ORIGIN_MP}" ]]; then
        rm -rf "${CLONE_MP}"
    fi
}
sub="$1"
shift
case "${sub}" in
    list)
        read_state
        t=""
        dataset=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -H | -p)
                    shift
                    ;;
                -o | -s)
                    shift 2
                    ;;
                -t)
                    t="${2-}"
                    shift 2
                    ;;
                *)
                    dataset="$1"
                    shift
                    ;;
            esac
        done
        if [[ "${t}" == "snapshot" ]]; then
            if [[ "${dataset}" == "${ORIGIN}" ]]; then
                if [[ -n "${SNAP_NAME}" ]]; then
                    printf '%s\t%s\n' "${SNAP_NAME}" "${SNAP_CREATION}"
                fi
                exit 0
            fi
            if [[ -n "${REPLICA:-}" && "${dataset}" == "${REPLICA}" ]]; then
                if [[ -n "${REPLICA_SNAP:-}" ]]; then
                    printf '%s\t%s\n' "${REPLICA_SNAP}" "${REPLICA_CREATION}"
                fi
                exit 0
            fi
            exit 0
        fi
        if [[ "${dataset}" == "${ORIGIN}" ]]; then
            printf '%s\n' "${ORIGIN}"
            exit 0
        fi
        if [[ -n "${REPLICA:-}" && "${dataset}" == "${REPLICA}" ]]; then
            printf '%s\n' "${REPLICA}"
            exit 0
        fi
        if [[ -f "${STATE}/clone" ]]; then
            # shellcheck source=/dev/null
            source "${STATE}/clone"
            if [[ "${dataset}" == "${CLONE_NAME}" ]]; then
                printf '%s\n' "${CLONE_NAME}"
                exit 0
            fi
        fi
        exit 1
        ;;
    get)
        read_state
        prop=""
        dataset=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -H | -p)
                    shift
                    ;;
                -o)
                    shift 2
                    ;;
                *)
                    if [[ -z "${prop}" ]]; then
                        prop="$1"
                    else
                        dataset="$1"
                    fi
                    shift
                    ;;
            esac
        done
        case "${prop}" in
            mountpoint)
                if [[ "${dataset}" == "${ORIGIN}" ]]; then
                    printf '%s\n' "${ORIGIN_MP}"
                    exit 0
                fi
                if [[ -f "${STATE}/clone" ]]; then
                    # shellcheck source=/dev/null
                    source "${STATE}/clone"
                    if [[ "${dataset}" == "${CLONE_NAME}" ]]; then
                        printf '%s\n' "${CLONE_MP}"
                        exit 0
                    fi
                fi
                exit 1
                ;;
            mounted)
                if [[ -f "${STATE}/clone" ]]; then
                    # shellcheck source=/dev/null
                    source "${STATE}/clone"
                    if [[ "${dataset}" == "${CLONE_NAME}" ]]; then
                        printf '%s\n' "${CLONE_MOUNTED}"
                        exit 0
                    fi
                fi
                exit 1
                ;;
            *)
                echo "stub zfs: unsupported property ${prop}" >&2
                exit 1
                ;;
        esac
        ;;
    clone)
        read_state
        mp="${ORIGIN_MP}"
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -o)
                    kv="${2-}"
                    shift 2
                    case "${kv}" in
                        mountpoint=*)
                            mp="${kv#mountpoint=}"
                            ;;
                        *)
                            ;;
                    esac
                    ;;
                *)
                    break
                    ;;
            esac
        done
        snap="${1-}"
        clone="${2-}"
        [[ -n "${snap}" && -n "${clone}" ]] || exit 1
        [[ "${snap}" == "${SNAP_NAME}" ]] || exit 1
        mkdir -p "${mp}"
        if [[ -d "${SNAP_TREE}" ]]; then
            cp -a "${SNAP_TREE}/." "${mp}/"
        fi
        write_clone "${clone}" "${mp}" yes
        ;;
    destroy)
        read_state
        dataset="${1-}"
        if [[ -f "${STATE}/clone" ]]; then
            # shellcheck source=/dev/null
            source "${STATE}/clone"
            if [[ "${dataset}" == "${CLONE_NAME}" ]]; then
                clear_clone
                exit 0
            fi
        fi
        exit 1
        ;;
    unmount)
        read_state
        dataset="${1-}"
        if [[ -f "${STATE}/clone" ]]; then
            # shellcheck source=/dev/null
            source "${STATE}/clone"
            if [[ "${dataset}" == "${CLONE_NAME}" ]]; then
                write_clone "${CLONE_NAME}" "${CLONE_MP}" no
                exit 0
            fi
        fi
        exit 1
        ;;
    *)
        echo "stub zfs: unsupported subcommand ${sub}" >&2
        exit 1
        ;;
esac
STUB
chmod +x "${STUB_BIN}/zfs"

DRILL="${SCRIPTS_DIR}/dr_restore_drill.sh"
export STUB_STATE
export PATH="${STUB_BIN}:${PATH}"

write_env() {
    cat >"${STUB_STATE}/env" <<EOF
ORIGIN=$(printf '%q' "$1")
ORIGIN_MP=$(printf '%q' "$2")
SNAP_NAME=$(printf '%q' "$3")
SNAP_CREATION=$(printf '%q' "$4")
SNAP_TREE=$(printf '%q' "$5")
REPLICA=$(printf '%q' "${6-}")
REPLICA_SNAP=$(printf '%q' "${7-}")
REPLICA_CREATION=$(printf '%q' "${8-}")
EOF
}

# env + the drill binary, not a function: a function inside $(...) or ||
# disables set -e (SC2310) and would hide a crash inside the helper.
expect_ok() {
    local name="$1"
    local live="$2"
    local log="$3"
    shift 3
    local out rc
    rc=0
    out="$(env \
        MF_DRILL_LIVE="${live}" \
        MF_DRILL_LOG="${log}" \
        MF_DRILL_KEEP="" \
        "$@" \
        "${DRILL}" tank/models 2>&1)" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        fail "${name}: expected success, rc=${rc}: ${out}"
        return 0
    fi
    if ! grep -q "drill OK:" <<<"${out}"; then
        fail "${name}: missing drill OK in: ${out}"
        return 0
    fi
    pass "${name}"
}

expect_fail() {
    local name="$1"
    local needle="$2"
    local live="$3"
    local log="$4"
    shift 4
    local out rc
    rc=0
    out="$(env \
        MF_DRILL_LIVE="${live}" \
        MF_DRILL_LOG="${log}" \
        MF_DRILL_KEEP="" \
        "$@" \
        "${DRILL}" tank/models 2>&1)" || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        fail "${name}: expected failure, got success: ${out}"
        return 0
    fi
    if ! grep -q "${needle}" <<<"${out}"; then
        fail "${name}: expected '${needle}' in: ${out}"
        return 0
    fi
    pass "${name}"
}

NOW="$(date +%s)"
FRESH=$((NOW - 60))
STALE=$((NOW - 200000))

# --- 1. happy path: distinct clone mp, drift tolerated, largest file sampled
LIVE1="${TEMP}/live1"
SNAP1="${TEMP}/snap1"
mkdir -p "${LIVE1}/gguf" "${LIVE1}/.cluster" "${SNAP1}/gguf" "${SNAP1}/.cluster"
# 64-byte weight on both sides (stable). A larger file on both sides is the
# sample the sorter must pick over the tiny sidecar.
dd if=/dev/zero of="${SNAP1}/gguf/model.gguf" bs=4096 count=8 status=none
cp -a "${SNAP1}/gguf/model.gguf" "${LIVE1}/gguf/model.gguf"
echo tiny >"${SNAP1}/gguf/sidecar.txt"
echo tiny >"${LIVE1}/gguf/sidecar.txt"
echo lease-old >"${SNAP1}/.cluster/spark1.json"
echo lease-new >"${LIVE1}/.cluster/spark1.json"
echo 'only on live' >"${LIVE1}/gguf/new-after-snap.gguf"
LOG1="${TEMP}/drill1.log"
write_env tank/models "${LIVE1}" tank/models@autosnap_test "${FRESH}" "${SNAP1}"
expect_ok "happy path restores off the live tree" "${LIVE1}" "${LOG1}"
if [[ -f "${LOG1}" ]] && grep -q "sample=/gguf/model.gguf" "${LOG1}" && grep -q "replica=unchecked" "${LOG1}"; then
    pass "log records weight sample and replica=unchecked"
else
    fail "log missing sample or replica field: $(cat "${LOG1}" 2>/dev/null || true)"
fi
if [[ -f "${LOG1}" ]] && grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ' "${LOG1}"; then
    pass "log stamp is UTC Z-form"
else
    fail "log stamp is not UTC Z-form: $(cat "${LOG1}" 2>/dev/null || true)"
fi
# Clone must have been destroyed by the EXIT trap.
if [[ -f "${STUB_STATE}/clone" ]]; then
    fail "happy path left the clone dataset behind"
else
    pass "happy path destroyed the clone"
fi

# --- 2. no snapshots
LIVE2="${TEMP}/live2"
mkdir -p "${LIVE2}"
write_env tank/models "${LIVE2}" "" "${FRESH}" "${TEMP}/empty-snap"
# Override SNAP_NAME empty via env file: list -t snapshot prints a tab-only line
# if SNAP_NAME is empty. Force the stub to print nothing by using a snap name
# of empty string: printf '%s\t%s\n' "" epoch still prints a tab. Use a
# dedicated snaps-empty mode: SNAP_NAME empty and snap_creation 0, and tweak
# the stub to print nothing when SNAP_NAME is empty.
LOG2="${TEMP}/drill2.log"
write_env tank/models "${LIVE2}" "" "${FRESH}" "${TEMP}/nosnap"
expect_fail "no snapshots is an alarm" "no snapshots" "${LIVE2}" "${LOG2}"

# --- 3. stale snapshot
LIVE3="${TEMP}/live3"
SNAP3="${TEMP}/snap3"
mkdir -p "${LIVE3}/gguf" "${SNAP3}/gguf"
echo weight >"${SNAP3}/gguf/m.gguf"
cp -a "${SNAP3}/gguf/m.gguf" "${LIVE3}/gguf/m.gguf"
LOG3="${TEMP}/drill3.log"
write_env tank/models "${LIVE3}" tank/models@old "${STALE}" "${SNAP3}"
expect_fail "stale snapshot is an alarm" "past the" "${LIVE3}" "${LOG3}"

# 200000s-old snap: octal 0300000 is 98304 (would still fail); decimal
# 300000 is above the age, so a leading zero must not keep the alarm.
LOG3A="${TEMP}/drill3a.log"
write_env tank/models "${LIVE3}" tank/models@old "${STALE}" "${SNAP3}"
expect_ok "padded MF_DRILL_MAX_SNAP_AGE=0300000 is decimal" "${LIVE3}" "${LOG3A}" \
    MF_DRILL_MAX_SNAP_AGE=0300000
LOG3A2="${TEMP}/drill3a2.log"
write_env tank/models "${LIVE1}" tank/models@autosnap_test "${FRESH}" "${SNAP1}"
expect_fail "padded MF_DRILL_MAX_SNAP_AGE=08 is decimal not an octal abort" "past the" "${LIVE1}" "${LOG3A2}" \
    MF_DRILL_MAX_SNAP_AGE=08

# --- 3b. snapshot creation in the future of date +%s
LIVE3B="${TEMP}/live3b"
SNAP3B="${TEMP}/snap3b"
mkdir -p "${LIVE3B}/gguf" "${SNAP3B}/gguf"
echo weight >"${SNAP3B}/gguf/m.gguf"
cp -a "${SNAP3B}/gguf/m.gguf" "${LIVE3B}/gguf/m.gguf"
LOG3B="${TEMP}/drill3b.log"
FUTURE=$((NOW + 3600))
write_env tank/models "${LIVE3B}" tank/models@future "${FUTURE}" "${SNAP3B}"
expect_fail "future snapshot creation is an alarm" "in the future" "${LIVE3B}" "${LOG3B}"

# --- 4. empty snapshot (no files at all)
LIVE4="${TEMP}/live4"
SNAP4="${TEMP}/snap4"
mkdir -p "${LIVE4}/gguf" "${SNAP4}"
echo weight >"${LIVE4}/gguf/m.gguf"
LOG4="${TEMP}/drill4.log"
write_env tank/models "${LIVE4}" tank/models@empty "${FRESH}" "${SNAP4}"
expect_fail "empty snapshot is an alarm" "zero files" "${LIVE4}" "${LOG4}"

# --- 5. lease-only snapshot (the previous FILE_COUNT hole)
LIVE5="${TEMP}/live5"
SNAP5="${TEMP}/snap5"
mkdir -p "${LIVE5}/.cluster" "${SNAP5}/.cluster"
echo lease >"${SNAP5}/.cluster/spark1.json"
echo lease >"${LIVE5}/.cluster/spark1.json"
LOG5="${TEMP}/drill5.log"
write_env tank/models "${LIVE5}" tank/models@leases "${FRESH}" "${SNAP5}"
expect_fail "lease-only snapshot is an alarm" "zero files" "${LIVE5}" "${LOG5}"

# --- 6. hash mismatch at the same size
LIVE6="${TEMP}/live6"
SNAP6="${TEMP}/snap6"
mkdir -p "${LIVE6}/gguf" "${SNAP6}/gguf"
printf 'AAAA' >"${SNAP6}/gguf/m.gguf"
printf 'BBBB' >"${LIVE6}/gguf/m.gguf"
LOG6="${TEMP}/drill6.log"
write_env tank/models "${LIVE6}" tank/models@bad "${FRESH}" "${SNAP6}"
expect_fail "content mismatch is an alarm" "hashes" "${LIVE6}" "${LOG6}"

# --- 7. size-changed file skipped; smaller stable file hashed
LIVE7="${TEMP}/live7"
SNAP7="${TEMP}/snap7"
mkdir -p "${LIVE7}/gguf" "${SNAP7}/gguf"
printf 'old-weight-xxxxx' >"${SNAP7}/gguf/growing.gguf"
printf 'old-weight-xxxxx-AND-MORE' >"${LIVE7}/gguf/growing.gguf"
printf 'stable-bytes' >"${SNAP7}/gguf/small.bin"
printf 'stable-bytes' >"${LIVE7}/gguf/small.bin"
LOG7="${TEMP}/drill7.log"
write_env tank/models "${LIVE7}" tank/models@grow "${FRESH}" "${SNAP7}"
expect_ok "size-changed file is skipped" "${LIVE7}" "${LOG7}"
if [[ -f "${LOG7}" ]] && grep -q "sample=/gguf/small.bin" "${LOG7}"; then
    pass "sampler hashed the size-stable file"
else
    fail "sampler did not pick small.bin: $(cat "${LOG7}" 2>/dev/null || true)"
fi

# --- 8. clone mountpoint colliding with live is refused before clone
LIVE8="${TEMP}/live8"
SNAP8="${TEMP}/snap8"
mkdir -p "${LIVE8}/gguf" "${SNAP8}/gguf"
echo weight >"${SNAP8}/gguf/m.gguf"
cp -a "${SNAP8}/gguf/m.gguf" "${LIVE8}/gguf/m.gguf"
LOG8="${TEMP}/drill8.log"
write_env tank/models "${LIVE8}" tank/models@ok "${FRESH}" "${SNAP8}"
expect_fail "clone mp colliding with live is refused" "collides with the live tree" \
    "${LIVE8}" "${LOG8}" MF_DRILL_CLONE_MP="${LIVE8}"

# --- 9. replica missing
LIVE9="${TEMP}/live9"
SNAP9="${TEMP}/snap9"
mkdir -p "${LIVE9}/gguf" "${SNAP9}/gguf"
echo weight >"${SNAP9}/gguf/m.gguf"
cp -a "${SNAP9}/gguf/m.gguf" "${LIVE9}/gguf/m.gguf"
LOG9="${TEMP}/drill9.log"
write_env tank/models "${LIVE9}" tank/models@ok "${FRESH}" "${SNAP9}"
expect_fail "missing replica dataset is an alarm" "replica dataset" \
    "${LIVE9}" "${LOG9}" MF_DRILL_REPLICA="tank/models-backup"

# --- 10. replica present and fresh
LIVE10="${TEMP}/live10"
SNAP10="${TEMP}/snap10"
mkdir -p "${LIVE10}/gguf" "${SNAP10}/gguf"
echo weight >"${SNAP10}/gguf/m.gguf"
cp -a "${SNAP10}/gguf/m.gguf" "${LIVE10}/gguf/m.gguf"
LOG10="${TEMP}/drill10.log"
write_env tank/models "${LIVE10}" tank/models@ok "${FRESH}" "${SNAP10}" \
    tank/models-backup tank/models-backup@ok "${FRESH}"
expect_ok "fresh replica is recorded" "${LIVE10}" "${LOG10}" MF_DRILL_REPLICA="tank/models-backup"
if [[ -f "${LOG10}" ]] && grep -q "replica=ok" "${LOG10}"; then
    pass "log records replica=ok"
else
    fail "log missing replica=ok: $(cat "${LOG10}" 2>/dev/null || true)"
fi

# --- 11. replica stale
LIVE11="${TEMP}/live11"
SNAP11="${TEMP}/snap11"
mkdir -p "${LIVE11}/gguf" "${SNAP11}/gguf"
echo weight >"${SNAP11}/gguf/m.gguf"
cp -a "${SNAP11}/gguf/m.gguf" "${LIVE11}/gguf/m.gguf"
LOG11="${TEMP}/drill11.log"
write_env tank/models "${LIVE11}" tank/models@ok "${FRESH}" "${SNAP11}" \
    tank/models-backup tank/models-backup@old "${STALE}"
expect_fail "stale replica is an alarm" "replica newest snapshot" \
    "${LIVE11}" "${LOG11}" MF_DRILL_REPLICA="tank/models-backup"

# --- 12. already-mounted leftover clone is refused
LIVE12="${TEMP}/live12"
SNAP12="${TEMP}/snap12"
mkdir -p "${LIVE12}/gguf" "${SNAP12}/gguf"
echo weight >"${SNAP12}/gguf/m.gguf"
cp -a "${SNAP12}/gguf/m.gguf" "${LIVE12}/gguf/m.gguf"
LOG12="${TEMP}/drill12.log"
write_env tank/models "${LIVE12}" tank/models@ok "${FRESH}" "${SNAP12}"
printf 'CLONE_NAME=%q\nCLONE_MP=%q\nCLONE_MOUNTED=%q\n' tank/drill "${TEMP}/leftover" yes >"${STUB_STATE}/clone"
expect_fail "mounted leftover clone is refused" "already exists and is mounted" \
    "${LIVE12}" "${LOG12}"
rm -f "${STUB_STATE}/clone"

# --- 13. unwritable artifact log fails before clone
LIVE13="${TEMP}/live13"
SNAP13="${TEMP}/snap13"
mkdir -p "${LIVE13}/gguf" "${SNAP13}/gguf"
echo weight >"${SNAP13}/gguf/m.gguf"
cp -a "${SNAP13}/gguf/m.gguf" "${LIVE13}/gguf/m.gguf"
LOG13="${TEMP}/readonly.log"
touch "${LOG13}"
chmod a-w "${LOG13}"
write_env tank/models "${LIVE13}" tank/models@ok "${FRESH}" "${SNAP13}"
expect_fail "unwritable log is an alarm" "cannot write the drill log" \
    "${LIVE13}" "${LOG13}"
chmod u+w "${LOG13}"

# --- 14. replica inside daily slack (26 h) is not an alarm
LIVE14="${TEMP}/live14"
SNAP14="${TEMP}/snap14"
mkdir -p "${LIVE14}/gguf" "${SNAP14}/gguf"
echo weight >"${SNAP14}/gguf/m.gguf"
cp -a "${SNAP14}/gguf/m.gguf" "${LIVE14}/gguf/m.gguf"
LOG14="${TEMP}/drill14.log"
REPLICA_26H=$((NOW - 93600))
write_env tank/models "${LIVE14}" tank/models@ok "${FRESH}" "${SNAP14}" \
    tank/models-backup tank/models-backup@ok "${REPLICA_26H}"
expect_ok "replica 26h old is inside the daily slack" "${LIVE14}" "${LOG14}" \
    MF_DRILL_REPLICA="tank/models-backup"

# --- --age-only: snapshot/replica freshness without clone or drill log
expect_age_ok() {
    local name="$1"
    local live="$2"
    local log="$3"
    shift 3
    local out rc
    rc=0
    out="$(env \
        MF_DRILL_LIVE="${live}" \
        MF_DRILL_LOG="${log}" \
        MF_DRILL_KEEP="" \
        "$@" \
        "${DRILL}" --age-only tank/models 2>&1)" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        fail "${name}: expected success, rc=${rc}: ${out}"
        return 0
    fi
    if ! grep -q "snap-age OK:" <<<"${out}"; then
        fail "${name}: missing snap-age OK in: ${out}"
        return 0
    fi
    if grep -q "drill OK:" <<<"${out}"; then
        fail "${name}: --age-only ran the clone: ${out}"
        return 0
    fi
    pass "${name}"
}

expect_age_fail() {
    local name="$1"
    local needle="$2"
    local live="$3"
    local log="$4"
    shift 4
    local out rc
    rc=0
    out="$(env \
        MF_DRILL_LIVE="${live}" \
        MF_DRILL_LOG="${log}" \
        MF_DRILL_KEEP="" \
        "$@" \
        "${DRILL}" --age-only tank/models 2>&1)" || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        fail "${name}: expected failure, got success: ${out}"
        return 0
    fi
    if ! grep -q "${needle}" <<<"${out}"; then
        fail "${name}: expected '${needle}' in: ${out}"
        return 0
    fi
    if grep -q "drill OK:" <<<"${out}"; then
        fail "${name}: --age-only ran the clone: ${out}"
        return 0
    fi
    pass "${name}"
}

LIVE15="${TEMP}/live15"
SNAP15="${TEMP}/snap15"
mkdir -p "${LIVE15}/gguf" "${SNAP15}/gguf"
echo weight >"${SNAP15}/gguf/m.gguf"
cp -a "${SNAP15}/gguf/m.gguf" "${LIVE15}/gguf/m.gguf"
LOG15="${TEMP}/drill15.log"
write_env tank/models "${LIVE15}" tank/models@ok "${FRESH}" "${SNAP15}"
expect_age_ok "age-only succeeds on a fresh snapshot" "${LIVE15}" "${LOG15}"
if [[ -f "${STUB_STATE}/clone" ]]; then
    fail "age-only left a clone dataset behind"
else
    pass "age-only did not clone"
fi
if [[ -s "${LOG15}" ]]; then
    fail "age-only appended the drill log: $(cat "${LOG15}" 2>/dev/null || true)"
else
    pass "age-only did not append the drill log"
fi

LOG15A="${TEMP}/drill15a.log"
write_env tank/models "${LIVE15}" tank/models@old "${STALE}" "${SNAP15}"
expect_age_fail "age-only stale snapshot is an alarm" "past the" "${LIVE15}" "${LOG15A}"

LOG15B="${TEMP}/drill15b.log"
write_env tank/models "${LIVE15}" "" "${FRESH}" "${TEMP}/nosnap-age"
expect_age_fail "age-only no snapshots is an alarm" "no snapshots" "${LIVE15}" "${LOG15B}"

LOG15C="${TEMP}/drill15c.log"
write_env tank/models "${LIVE15}" tank/models@ok "${FRESH}" "${SNAP15}"
expect_age_fail "age-only missing replica is an alarm" "replica dataset" \
    "${LIVE15}" "${LOG15C}" MF_DRILL_REPLICA="tank/models-backup"

LOG15D="${TEMP}/readonly-age.log"
touch "${LOG15D}"
chmod a-w "${LOG15D}"
write_env tank/models "${LIVE15}" tank/models@ok "${FRESH}" "${SNAP15}"
expect_age_ok "age-only does not need a writable drill log" "${LIVE15}" "${LOG15D}"
chmod u+w "${LOG15D}"

AGE_USAGE_RC=0
AGE_USAGE_OUT="$("${DRILL}" --age-only tank/models extra 2>&1)" || AGE_USAGE_RC=$?
if [[ "${AGE_USAGE_RC}" -ne 2 ]]; then
    fail "age-only extra operand: expected rc=2, got ${AGE_USAGE_RC}: ${AGE_USAGE_OUT}"
elif ! grep -q "Usage:" <<<"${AGE_USAGE_OUT}"; then
    fail "age-only extra operand missing Usage: ${AGE_USAGE_OUT}"
else
    pass "age-only extra operand is a usage error"
fi

# --- hold_monthlies.sh: monthly snapshots get modelfs-dr; already-held is ok
HOLD="${SCRIPTS_DIR}/hold_monthlies.sh"
HOLD_BIN="${TEMP}/holdbin"
HOLD_STATE="${TEMP}/holdstub"
mkdir -p "${HOLD_BIN}" "${HOLD_STATE}"
cat >"${HOLD_BIN}/zfs" <<'HOLDSTUB'
#!/usr/bin/env bash
set -euo pipefail
STATE="${HOLD_STATE:?}"
read_state() {
    # shellcheck source=/dev/null
    source "${STATE}/env"
}
sub="$1"
shift
case "${sub}" in
    list)
        read_state
        t=""
        dataset=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -H | -p)
                    shift
                    ;;
                -o | -s)
                    shift 2
                    ;;
                -t)
                    t="${2-}"
                    shift 2
                    ;;
                *)
                    dataset="$1"
                    shift
                    ;;
            esac
        done
        if [[ "${t}" == "snapshot" ]]; then
            if [[ "${dataset}" == "${ORIGIN}" && -f "${STATE}/snaps" ]]; then
                cat "${STATE}/snaps"
            fi
            exit 0
        fi
        if [[ "${dataset}" == "${ORIGIN}" ]]; then
            printf '%s\n' "${ORIGIN}"
            exit 0
        fi
        exit 1
        ;;
    hold)
        read_state
        tag="${1-}"
        snap="${2-}"
        [[ -n "${tag}" && -n "${snap}" ]] || exit 1
        mkdir -p "${STATE}/holds"
        if [[ "${HOLD_DENY:-}" == "${snap}" ]]; then
            echo "cannot hold snapshot '${snap}': permission denied" >&2
            exit 1
        fi
        if [[ -f "${STATE}/holds/${snap//\//_}" ]]; then
            echo "cannot hold snapshot '${snap}': tag already exists on this dataset" >&2
            exit 1
        fi
        printf '%s\n' "${tag}" >"${STATE}/holds/${snap//\//_}"
        exit 0
        ;;
    holds)
        read_state
        hflag=""
        snap=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -H)
                    hflag=1
                    shift
                    ;;
                *)
                    snap="$1"
                    shift
                    ;;
            esac
        done
        [[ -n "${snap}" ]] || exit 1
        holdf="${STATE}/holds/${snap//\//_}"
        if [[ -f "${holdf}" ]]; then
            tag="$(<"${holdf}")"
            if [[ -n "${hflag}" ]]; then
                printf '%s\t%s\t-\n' "${snap}" "${tag}"
            else
                printf '%s  %s  -\n' "${snap}" "${tag}"
            fi
        fi
        exit 0
        ;;
    *)
        echo "hold stub zfs: unsupported subcommand ${sub}" >&2
        exit 1
        ;;
esac
HOLDSTUB
chmod +x "${HOLD_BIN}/zfs"

write_hold_env() {
    local origin="$1"
    local deny="$2"
    shift 2
    printf 'ORIGIN=%q\nHOLD_DENY=%q\n' "${origin}" "${deny}" >"${HOLD_STATE}/env"
    : >"${HOLD_STATE}/snaps"
    local s
    for s in "$@"; do
        printf '%s\n' "${s}" >>"${HOLD_STATE}/snaps"
    done
}

rm -rf "${HOLD_STATE}/holds"
write_hold_env tank/models "" \
    tank/models@autosnap_h_hourly tank/models@autosnap_m_monthly
HOLD_OUT=""
HOLD_RC=0
HOLD_OUT="$(env HOLD_STATE="${HOLD_STATE}" PATH="${HOLD_BIN}:${PATH}" "${HOLD}" tank/models 2>&1)" || HOLD_RC=$?
if [[ "${HOLD_RC}" -ne 0 ]]; then
    fail "hold monthlies: expected success, rc=${HOLD_RC}: ${HOLD_OUT}"
elif ! grep -q "hold OK: 1 monthly" <<<"${HOLD_OUT}"; then
    fail "hold monthlies missing one-monthly OK: ${HOLD_OUT}"
elif [[ ! -f "${HOLD_STATE}/holds/tank_models@autosnap_m_monthly" ]]; then
    fail "hold monthlies did not tag the monthly"
elif [[ -f "${HOLD_STATE}/holds/tank_models@autosnap_h_hourly" ]]; then
    fail "hold monthlies tagged an hourly snapshot"
else
    pass "hold monthlies tags only *_monthly"
fi

HOLD_OUT=""
HOLD_RC=0
HOLD_OUT="$(env HOLD_STATE="${HOLD_STATE}" PATH="${HOLD_BIN}:${PATH}" "${HOLD}" tank/models 2>&1)" || HOLD_RC=$?
if [[ "${HOLD_RC}" -ne 0 ]]; then
    fail "hold already-held: expected success, rc=${HOLD_RC}: ${HOLD_OUT}"
elif ! grep -q "already modelfs-dr" <<<"${HOLD_OUT}"; then
    fail "hold already-held missing already line: ${HOLD_OUT}"
else
    pass "hold already-held is success"
fi

rm -rf "${HOLD_STATE}/holds"
write_hold_env tank/models "" tank/models@autosnap_h_hourly
HOLD_OUT=""
HOLD_RC=0
HOLD_OUT="$(env HOLD_STATE="${HOLD_STATE}" PATH="${HOLD_BIN}:${PATH}" "${HOLD}" tank/models 2>&1)" || HOLD_RC=$?
if [[ "${HOLD_RC}" -ne 0 ]]; then
    fail "hold no-monthlies: expected success, rc=${HOLD_RC}: ${HOLD_OUT}"
elif ! grep -q "hold OK: 0 monthly" <<<"${HOLD_OUT}"; then
    fail "hold no-monthlies missing zero OK: ${HOLD_OUT}"
else
    pass "hold no-monthlies is success"
fi

rm -rf "${HOLD_STATE}/holds"
write_hold_env tank/models ""
HOLD_OUT=""
HOLD_RC=0
HOLD_OUT="$(env HOLD_STATE="${HOLD_STATE}" PATH="${HOLD_BIN}:${PATH}" "${HOLD}" tank/models 2>&1)" || HOLD_RC=$?
if [[ "${HOLD_RC}" -eq 0 ]]; then
    fail "hold no-snapshots: expected failure: ${HOLD_OUT}"
elif ! grep -q "no snapshots" <<<"${HOLD_OUT}"; then
    fail "hold no-snapshots missing message: ${HOLD_OUT}"
else
    pass "hold no-snapshots is an alarm"
fi

rm -rf "${HOLD_STATE}/holds"
write_hold_env tank/models tank/models@autosnap_m_monthly \
    tank/models@autosnap_m_monthly
HOLD_OUT=""
HOLD_RC=0
HOLD_OUT="$(env HOLD_STATE="${HOLD_STATE}" PATH="${HOLD_BIN}:${PATH}" "${HOLD}" tank/models 2>&1)" || HOLD_RC=$?
if [[ "${HOLD_RC}" -eq 0 ]]; then
    fail "hold denied: expected failure: ${HOLD_OUT}"
elif ! grep -q "cannot hold" <<<"${HOLD_OUT}"; then
    fail "hold denied missing cannot hold: ${HOLD_OUT}"
else
    pass "hold denied is an alarm"
fi

HOLD_OUT=""
HOLD_RC=0
HOLD_OUT="$(env HOLD_STATE="${HOLD_STATE}" PATH="${HOLD_BIN}:${PATH}" "${HOLD}" tank/missing 2>&1)" || HOLD_RC=$?
if [[ "${HOLD_RC}" -eq 0 ]]; then
    fail "hold missing dataset: expected failure: ${HOLD_OUT}"
elif ! grep -q "does not exist" <<<"${HOLD_OUT}"; then
    fail "hold missing dataset missing message: ${HOLD_OUT}"
else
    pass "hold missing dataset is an alarm"
fi

# --- check_drill_log.sh: the daily alarm for a missed monthly drill
CHECK_LOG="${SCRIPTS_DIR}/check_drill_log.sh"
expect_check() {
    local name="$1"
    local want_rc="$2"
    local needle="$3"
    shift 3
    local out rc
    rc=0
    out="$(env "$@" "${CHECK_LOG}" 2>&1)" || rc=$?
    if [[ "${rc}" -ne "${want_rc}" ]]; then
        fail "${name}: expected rc=${want_rc}, got ${rc}: ${out}"
        return 0
    fi
    if ! grep -q "${needle}" <<<"${out}"; then
        fail "${name}: expected '${needle}' in: ${out}"
        return 0
    fi
    pass "${name}"
}

expect_check "missing drill log is an alarm" 1 "is missing" \
    MF_DRILL_LOG="${TEMP}/no-such-drill.log"

: >"${TEMP}/empty-drill.log"
expect_check "empty drill log is an alarm" 1 "is empty" \
    MF_DRILL_LOG="${TEMP}/empty-drill.log"

echo "not-a-stamp tank/models@x ok" >"${TEMP}/bad-stamp.log"
expect_check "non-UTC stamp is an alarm" 1 "not a UTC stamp" \
    MF_DRILL_LOG="${TEMP}/bad-stamp.log"

FUTURE_STAMP="$(date -u -d "+2 hours" +%Y-%m-%dT%H:%M:%SZ)"
echo "${FUTURE_STAMP} tank/models@x ok snap_age_s=1 clone_s=0.1 drift=0 sample=/gguf/m.gguf replica=unchecked" \
    >"${TEMP}/future-drill.log"
expect_check "future drill log stamp is an alarm" 1 "in the future" \
    MF_DRILL_LOG="${TEMP}/future-drill.log"

STALE_STAMP="$(date -u -d "-40 days" +%Y-%m-%dT%H:%M:%SZ)"
echo "${STALE_STAMP} tank/models@x ok snap_age_s=1 clone_s=0.1 drift=0 sample=/gguf/m.gguf replica=unchecked" \
    >"${TEMP}/stale-drill.log"
expect_check "stale drill log is an alarm" 1 "has not succeeded recently" \
    MF_DRILL_LOG="${TEMP}/stale-drill.log"

FRESH_STAMP="$(date -u -d "-1 hour" +%Y-%m-%dT%H:%M:%SZ)"
echo "${FRESH_STAMP} tank/models@x ok snap_age_s=1 clone_s=0.1 drift=0 sample=/gguf/m.gguf replica=unchecked" \
    >"${TEMP}/fresh-drill.log"
expect_check "fresh drill log is ok" 0 "drill-log OK" \
    MF_DRILL_LOG="${TEMP}/fresh-drill.log"

expect_check "bad MF_DRILL_LOG_MAX_AGE is an alarm" 1 "whole number of seconds" \
    MF_DRILL_LOG="${TEMP}/fresh-drill.log" MF_DRILL_LOG_MAX_AGE="30d"

# Leading zeros are decimal seconds, not octal. 08 used to abort inside
# [[ -gt ]] ("value too great for base"). 0120 octal is 80, so a 90s-old
# log would fail that limit; decimal 120 keeps it fresh.
NINETY_STAMP="$(date -u -d "-90 seconds" +%Y-%m-%dT%H:%M:%SZ)"
echo "${NINETY_STAMP} tank/models@x ok snap_age_s=1 clone_s=0.1 drift=0 sample=/gguf/m.gguf replica=unchecked" \
    >"${TEMP}/ninety-drill.log"
expect_check "padded MF_DRILL_LOG_MAX_AGE=08 is decimal not an octal abort" 1 "has not succeeded recently" \
    MF_DRILL_LOG="${TEMP}/ninety-drill.log" MF_DRILL_LOG_MAX_AGE="08"
expect_check "padded MF_DRILL_LOG_MAX_AGE=0120 is 120 seconds, not octal 80" 0 "drill-log OK" \
    MF_DRILL_LOG="${TEMP}/ninety-drill.log" MF_DRILL_LOG_MAX_AGE="0120"
expect_check "overlong MF_DRILL_LOG_MAX_AGE is an alarm" 1 "whole number of seconds" \
    MF_DRILL_LOG="${TEMP}/fresh-drill.log" MF_DRILL_LOG_MAX_AGE="12345678901"

# --- install_nas_backup.sh: dry-run writes nothing; --install lands files under dest
INSTALLER="${SCRIPTS_DIR}/install_nas_backup.sh"
DRY_OUT=""
DRY_RC=0
DRY_OUT="$("${INSTALLER}" 2>&1)" || DRY_RC=$?
if [[ "${DRY_RC}" -ne 0 ]]; then
    fail "installer dry-run: expected success, rc=${DRY_RC}: ${DRY_OUT}"
elif ! grep -q "would copy" <<<"${DRY_OUT}"; then
    fail "installer dry-run missing 'would copy': ${DRY_OUT}"
elif ! grep -q "etc/sanoid/sanoid.conf" <<<"${DRY_OUT}"; then
    fail "installer dry-run missing sanoid.conf: ${DRY_OUT}"
elif ! grep -q "modelfs-snap-age.timer" <<<"${DRY_OUT}"; then
    fail "installer dry-run missing snap-age timer: ${DRY_OUT}"
elif ! grep -q "modelfs-hold-monthlies" <<<"${DRY_OUT}"; then
    fail "installer dry-run missing hold_monthlies: ${DRY_OUT}"
elif ! grep -q "modelfs-pool-restore" <<<"${DRY_OUT}"; then
    fail "installer dry-run missing pool-restore: ${DRY_OUT}"
elif ! grep -q "modelfs-check-offsite" <<<"${DRY_OUT}"; then
    fail "installer dry-run missing check-offsite: ${DRY_OUT}"
elif ! grep -q "modelfs-offsite-age.timer" <<<"${DRY_OUT}"; then
    fail "installer dry-run missing offsite-age timer: ${DRY_OUT}"
else
    pass "installer dry-run lists the NAS units"
fi

INSTALL_DEST="${TEMP}/nas-root"
INSTALL_OUT=""
INSTALL_RC=0
INSTALL_OUT="$(MF_NAS_DEST="${INSTALL_DEST}" "${INSTALLER}" --install 2>&1)" || INSTALL_RC=$?
if [[ "${INSTALL_RC}" -ne 0 ]]; then
    fail "installer --install: expected success, rc=${INSTALL_RC}: ${INSTALL_OUT}"
else
    missing=""
    for rel in \
        etc/sanoid/sanoid.conf \
        etc/systemd/system/notify-admin@.service \
        etc/systemd/system/sanoid.service.d/fail.conf \
        etc/systemd/system/sanoid-prune.service.d/fail.conf \
        etc/systemd/system/syncoid-models.service \
        etc/systemd/system/syncoid-models.timer \
        etc/systemd/system/modelfs-drill.service \
        etc/systemd/system/modelfs-drill.timer \
        etc/systemd/system/modelfs-drill-log.service \
        etc/systemd/system/modelfs-drill-log.timer \
        etc/systemd/system/modelfs-snap-age.service \
        etc/systemd/system/modelfs-snap-age.timer \
        etc/systemd/system/modelfs-offsite-age.service \
        etc/systemd/system/modelfs-offsite-age.timer \
        usr/local/sbin/modelfs-restore-drill \
        usr/local/sbin/modelfs-check-drill-log \
        usr/local/sbin/modelfs-hold-monthlies \
        usr/local/sbin/modelfs-pool-restore \
        usr/local/sbin/modelfs-check-offsite \
        usr/local/share/doc/modelfs/recovery.md; do
        if [[ ! -f "${INSTALL_DEST}/${rel}" ]]; then
            missing="${missing} ${rel}"
        fi
    done
    if [[ -n "${missing}" ]]; then
        fail "installer --install missing:${missing}"
    elif [[ ! -x "${INSTALL_DEST}/usr/local/sbin/modelfs-restore-drill" ]]; then
        fail "installer --install drill wrapper is not executable"
    elif ! grep -q "OnFailure=notify-admin@%n.service" \
        "${INSTALL_DEST}/etc/systemd/system/sanoid.service.d/fail.conf"; then
        fail "installer --install sanoid drop-in lost OnFailure"
    elif grep -q "OnFailure" "${INSTALL_DEST}/etc/systemd/system/modelfs-drill.timer"; then
        fail "installer --install put OnFailure on the drill timer (belongs on the service)"
    elif grep -q "OnFailure" "${INSTALL_DEST}/etc/systemd/system/modelfs-snap-age.timer"; then
        fail "installer --install put OnFailure on the snap-age timer (belongs on the service)"
    elif ! grep -q "TimeoutStartSec=infinity" \
        "${INSTALL_DEST}/etc/systemd/system/syncoid-models.service"; then
        fail "installer --install syncoid unit lost TimeoutStartSec=infinity"
    elif ! grep -q "BatchMode=yes" \
        "${INSTALL_DEST}/etc/systemd/system/syncoid-models.service"; then
        fail "installer --install syncoid unit lost SSH BatchMode"
    elif ! grep -q "Requires=zfs-import.target" \
        "${INSTALL_DEST}/etc/systemd/system/syncoid-models.service"; then
        fail "installer --install syncoid unit lost Requires=zfs-import.target"
    elif ! grep -q "Requires=zfs-import.target" \
        "${INSTALL_DEST}/etc/systemd/system/modelfs-drill.service"; then
        fail "installer --install drill unit lost Requires=zfs-import.target"
    elif ! grep -q "ProtectSystem=strict" \
        "${INSTALL_DEST}/etc/systemd/system/notify-admin@.service"; then
        fail "installer --install notify-admin unit lost ProtectSystem=strict"
    elif ! grep -q "RandomizedDelaySec=5min" \
        "${INSTALL_DEST}/etc/systemd/system/modelfs-drill-log.timer"; then
        fail "installer --install drill-log timer lost RandomizedDelaySec"
    elif ! grep -q "modelfs-hold-monthlies" \
        "${INSTALL_DEST}/etc/systemd/system/syncoid-models.service"; then
        fail "installer --install syncoid unit lost hold ExecStartPost"
    elif ! grep -q -- "--age-only" \
        "${INSTALL_DEST}/etc/systemd/system/modelfs-snap-age.service"; then
        fail "installer --install snap-age unit lost --age-only"
    elif [[ ! -x "${INSTALL_DEST}/usr/local/sbin/modelfs-hold-monthlies" ]]; then
        fail "installer --install hold wrapper is not executable"
    elif ! grep -q "recursive = yes" "${INSTALL_DEST}/etc/sanoid/sanoid.conf"; then
        fail "installer --install sanoid.conf lost recursive = yes"
    elif [[ ! -x "${INSTALL_DEST}/usr/local/sbin/modelfs-pool-restore" ]]; then
        fail "installer --install pool-restore wrapper is not executable"
    elif [[ ! -x "${INSTALL_DEST}/usr/local/sbin/modelfs-check-offsite" ]]; then
        fail "installer --install offsite wrapper is not executable"
    elif grep -q "OnFailure" "${INSTALL_DEST}/etc/systemd/system/modelfs-offsite-age.timer"; then
        fail "installer --install put OnFailure on the offsite-age timer (belongs on the service)"
    elif ! grep -q "OnFailure=notify-admin@%n.service" \
        "${INSTALL_DEST}/etc/systemd/system/modelfs-offsite-age.service"; then
        fail "installer --install offsite-age service lost OnFailure"
    else
        pass "installer --install lands units, wrappers, and the service OnFailure"
    fi
fi

# --- check_offsite.sh: site-loss copy freshness
OFFSITE="${SCRIPTS_DIR}/check_offsite.sh"
OFFSITE_BIN="${TEMP}/offsitebin"
OFFSITE_STATE="${TEMP}/offsitestub"
mkdir -p "${OFFSITE_BIN}" "${OFFSITE_STATE}"
cat >"${OFFSITE_BIN}/zfs" <<'OFFSTUB'
#!/usr/bin/env bash
set -euo pipefail
STATE="${OFFSITE_STATE:?}"
read_state() {
    # shellcheck source=/dev/null
    source "${STATE}/env"
}
sub="$1"
shift
case "${sub}" in
    list)
        read_state
        t=""
        dataset=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -H | -p)
                    shift
                    ;;
                -o | -s)
                    shift 2
                    ;;
                -t)
                    t="${2-}"
                    shift 2
                    ;;
                *)
                    dataset="$1"
                    shift
                    ;;
            esac
        done
        if [[ "${t}" == "snapshot" ]]; then
            if [[ "${dataset}" == "${ORIGIN}" && -n "${SNAP_NAME:-}" ]]; then
                printf '%s\t%s\n' "${SNAP_NAME}" "${SNAP_CREATION}"
            fi
            exit 0
        fi
        if [[ "${dataset}" == "${ORIGIN}" ]]; then
            printf '%s\n' "${ORIGIN}"
            exit 0
        fi
        exit 1
        ;;
    *)
        echo "offsite stub zfs: unsupported subcommand ${sub}" >&2
        exit 1
        ;;
esac
OFFSTUB
chmod +x "${OFFSITE_BIN}/zfs"

write_offsite_env() {
    printf 'ORIGIN=%q\nSNAP_NAME=%q\nSNAP_CREATION=%q\n' "$1" "$2" "$3" >"${OFFSITE_STATE}/env"
}

expect_offsite() {
    local name="$1"
    local want_rc="$2"
    local needle="$3"
    shift 3
    local out rc
    rc=0
    out="$(env OFFSITE_STATE="${OFFSITE_STATE}" PATH="${OFFSITE_BIN}:${PATH}" "$@" 2>&1)" || rc=$?
    if [[ "${rc}" -ne "${want_rc}" ]]; then
        fail "${name}: expected rc=${want_rc}, got ${rc}: ${out}"
        return 0
    fi
    if ! grep -q "${needle}" <<<"${out}"; then
        fail "${name}: expected '${needle}' in: ${out}"
        return 0
    fi
    pass "${name}"
}

expect_offsite "offsite with no dataset is an alarm" 1 "dataset required" \
    "${OFFSITE}"

write_offsite_env tank/models-offsite tank/models-offsite@autosnap_ok "${FRESH}"
expect_offsite "missing offsite dataset is an alarm" 1 "does not exist" \
    "${OFFSITE}" tank/models

write_offsite_env tank/models-offsite "" "${FRESH}"
expect_offsite "offsite with no snapshots is an alarm" 1 "has no snapshots" \
    "${OFFSITE}" tank/models-offsite

OFFSITE_STALE=$((NOW - 800000))
write_offsite_env tank/models-offsite tank/models-offsite@old "${OFFSITE_STALE}"
expect_offsite "stale offsite snapshot is an alarm" 1 "past the" \
    "${OFFSITE}" tank/models-offsite

write_offsite_env tank/models-offsite tank/models-offsite@future "${FUTURE}"
expect_offsite "future offsite snapshot is an alarm" 1 "in the future" \
    "${OFFSITE}" tank/models-offsite

write_offsite_env tank/models-offsite tank/models-offsite@ok "${FRESH}"
expect_offsite "fresh offsite snapshot is ok" 0 "offsite OK" \
    "${OFFSITE}" tank/models-offsite

expect_offsite "padded MF_OFFSITE_MAX_AGE=08 is decimal not an octal abort" 1 "past the" \
    MF_OFFSITE_MAX_AGE=08 "${OFFSITE}" tank/models-offsite
expect_offsite "MF_OFFSITE_DATASET names the copy when no operand" 0 "offsite OK" \
    MF_OFFSITE_DATASET=tank/models-offsite "${OFFSITE}"
expect_offsite "bad MF_OFFSITE_MAX_AGE is an alarm" 1 "whole number of seconds" \
    MF_OFFSITE_MAX_AGE="8d" "${OFFSITE}" tank/models-offsite
expect_offsite "overlong MF_OFFSITE_MAX_AGE is an alarm" 1 "whole number of seconds" \
    MF_OFFSITE_MAX_AGE="12345678901" "${OFFSITE}" tank/models-offsite

# A 90s-old snap is stale under decimal 08 and fresh under decimal 0120
# (octal 0120 is 80, which would fail). Reuse NINETY from the log tests
# only as an age; here the snapshot creation is NOW-90.
NINETY_CTIME=$((NOW - 90))
write_offsite_env tank/models-offsite tank/models-offsite@ok "${NINETY_CTIME}"
expect_offsite "padded MF_OFFSITE_MAX_AGE=0120 is 120 seconds, not octal 80" 0 "offsite OK" \
    MF_OFFSITE_MAX_AGE=0120 "${OFFSITE}" tank/models-offsite

# --- dr_pool_restore.sh: procedure C as a dry-run-default command
RESTORE="${SCRIPTS_DIR}/dr_pool_restore.sh"
RESTORE_BIN="${TEMP}/restorebin"
RESTORE_STATE="${TEMP}/restorestub"
mkdir -p "${RESTORE_BIN}" "${RESTORE_STATE}"
cat >"${RESTORE_BIN}/zfs" <<'RESTUB'
#!/usr/bin/env bash
set -euo pipefail
STATE="${RESTORE_STATE:?}"
read_state() {
    # shellcheck source=/dev/null
    source "${STATE}/env"
    if [[ -f "${STATE}/runtime" ]]; then
        # shellcheck source=/dev/null
        source "${STATE}/runtime"
    fi
}
sub="$1"
shift
printf 'zfs %s %s\n' "${sub}" "$*" >>"${STATE}/commands.log"
case "${sub}" in
    list)
        read_state
        t=""
        dataset=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -H | -p)
                    shift
                    ;;
                -o | -s)
                    shift 2
                    ;;
                -t)
                    t="${2-}"
                    shift 2
                    ;;
                *)
                    dataset="$1"
                    shift
                    ;;
            esac
        done
        if [[ "${t}" == "snapshot" ]]; then
            if [[ "${dataset}" == "${LOCAL_FROM:-}" && -n "${LOCAL_SNAP:-}" ]]; then
                printf '%s\t%s\n' "${LOCAL_SNAP}" "${LOCAL_CREATION}"
            fi
            exit 0
        fi
        if [[ "${dataset}" == "${DEST:-}" && "${DEST_EXISTS:-0}" == "1" ]]; then
            printf '%s\n' "${DEST}"
            exit 0
        fi
        if [[ -n "${LOCAL_FROM:-}" && "${dataset}" == "${LOCAL_FROM}" ]]; then
            printf '%s\n' "${LOCAL_FROM}"
            exit 0
        fi
        exit 1
        ;;
    get)
        read_state
        prop=""
        dataset=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -H | -p)
                    shift
                    ;;
                -o)
                    shift 2
                    ;;
                *)
                    if [[ -z "${prop}" ]]; then
                        prop="$1"
                    else
                        dataset="$1"
                    fi
                    shift
                    ;;
            esac
        done
        case "${prop}" in
            mounted)
                if [[ "${dataset}" == "${DEST:-}" ]]; then
                    printf '%s\n' "${DEST_MOUNTED:-no}"
                    exit 0
                fi
                exit 1
                ;;
            mountpoint)
                if [[ "${dataset}" == "${DEST:-}" ]]; then
                    printf '%s\n' "${DEST_MP:-/export/models}"
                    exit 0
                fi
                exit 1
                ;;
            *)
                echo "restore stub zfs: unsupported property ${prop}" >&2
                exit 1
                ;;
        esac
        ;;
    send)
        echo SEND_STREAM
        exit 0
        ;;
    recv)
        cat >/dev/null
        printf 'DEST_EXISTS=1\nDEST_MOUNTED=yes\nDEST_MP=/export/models\n' >"${STATE}/runtime"
        exit 0
        ;;
    set)
        mp=""
        dest=""
        for arg in "$@"; do
            case "${arg}" in
                mountpoint=*)
                    mp="${arg#mountpoint=}"
                    ;;
                *=*)
                    ;;
                *)
                    dest="${arg}"
                    ;;
            esac
        done
        printf 'DEST_EXISTS=1\nDEST_MOUNTED=yes\nDEST_MP=%q\n' "${mp:-/export/models}" >"${STATE}/runtime"
        printf 'zfs set dest=%s mp=%s\n' "${dest}" "${mp}" >>"${STATE}/set.log"
        exit 0
        ;;
    *)
        echo "restore stub zfs: unsupported subcommand ${sub}" >&2
        exit 1
        ;;
esac
RESTUB
chmod +x "${RESTORE_BIN}/zfs"
cat >"${RESTORE_BIN}/syncoid" <<'SYNSTUB'
#!/usr/bin/env bash
set -euo pipefail
STATE="${RESTORE_STATE:?}"
printf '%s\n' "$*" >"${STATE}/syncoid.args"
printf 'DEST_EXISTS=1\nDEST_MOUNTED=yes\nDEST_MP=/export/models\n' >"${STATE}/runtime"
exit 0
SYNSTUB
chmod +x "${RESTORE_BIN}/syncoid"

write_restore_env() {
    cat >"${RESTORE_STATE}/env" <<EOF
DEST=$(printf '%q' "$1")
DEST_EXISTS=$(printf '%q' "$2")
DEST_MOUNTED=$(printf '%q' "$3")
DEST_MP=$(printf '%q' "$4")
LOCAL_FROM=$(printf '%q' "${5-}")
LOCAL_SNAP=$(printf '%q' "${6-}")
LOCAL_CREATION=$(printf '%q' "${7-}")
EOF
    rm -f "${RESTORE_STATE}/runtime" "${RESTORE_STATE}/commands.log" \
        "${RESTORE_STATE}/syncoid.args" "${RESTORE_STATE}/set.log"
}

expect_restore() {
    local name="$1"
    local want_rc="$2"
    local needle="$3"
    shift 3
    local out rc
    rc=0
    out="$(env RESTORE_STATE="${RESTORE_STATE}" PATH="${RESTORE_BIN}:${PATH}" "$@" 2>&1)" || rc=$?
    if [[ "${rc}" -ne "${want_rc}" ]]; then
        fail "${name}: expected rc=${want_rc}, got ${rc}: ${out}"
        return 0
    fi
    if ! grep -q "${needle}" <<<"${out}"; then
        fail "${name}: expected '${needle}' in: ${out}"
        return 0
    fi
    pass "${name}"
}

write_restore_env tank/models 0 no /export/models
expect_restore "pool restore dry-run --from prints the plan" 0 "without --execute" \
    "${RESTORE}" --from replica-host:tank/models
if [[ -f "${RESTORE_STATE}/syncoid.args" ]]; then
    fail "pool restore dry-run invoked syncoid"
else
    pass "pool restore dry-run did not invoke syncoid"
fi

expect_restore "pool restore with no source is an alarm" 1 "replica source required" \
    "${RESTORE}" tank/models

expect_restore "pool restore with both sources is an alarm" 1 "only one of" \
    "${RESTORE}" --from replica-host:tank/models --local-from tank/models-backup

expect_restore "pool restore dest must be nested" 1 "must be nested" \
    "${RESTORE}" --from replica-host:tank/models models

write_restore_env tank/models 1 yes /export/models
expect_restore "pool restore refuses a mounted dest" 1 "is mounted" \
    "${RESTORE}" --from replica-host:tank/models

expect_restore "pool restore dry-run --force on mounted dest prints the plan" 0 "without --execute" \
    "${RESTORE}" --force --from replica-host:tank/models

write_restore_env tank/models 0 no /export/models \
    tank/models-backup tank/models-backup@autosnap_ok "${FRESH}"
expect_restore "pool restore dry-run --local-from names the newest snap" 0 "zfs send -R tank/models-backup@autosnap_ok" \
    "${RESTORE}" --local-from tank/models-backup

write_restore_env tank/models 0 no /export/models tank/models-backup "" "${FRESH}"
expect_restore "pool restore --local-from with no snapshots is an alarm" 1 "has no snapshots" \
    "${RESTORE}" --local-from tank/models-backup

write_restore_env tank/models 0 no /export/models tank/models tank/models@snap "${FRESH}"
expect_restore "pool restore --local-from DEST is an alarm" 1 "is DEST" \
    "${RESTORE}" --local-from tank/models

RLOG="${TEMP}/pool-restore.log"
write_restore_env tank/models 0 no /export/models
expect_restore "pool restore --execute --from pulls and sets properties" 0 "pool-restore OK" \
    MF_RESTORE_LOG="${RLOG}" "${RESTORE}" --execute --from replica-host:tank/models
if [[ ! -f "${RESTORE_STATE}/syncoid.args" ]]; then
    fail "pool restore --execute --from did not invoke syncoid"
elif ! grep -q -- "--force-delete replica-host:tank/models tank/models" "${RESTORE_STATE}/syncoid.args"; then
    fail "pool restore syncoid args: $(cat "${RESTORE_STATE}/syncoid.args" 2>/dev/null || true)"
elif [[ ! -f "${RESTORE_STATE}/set.log" ]]; then
    fail "pool restore --execute --from did not zfs set"
elif ! grep -q "mp=/export/models" "${RESTORE_STATE}/set.log"; then
    fail "pool restore zfs set lost mountpoint: $(cat "${RESTORE_STATE}/set.log" 2>/dev/null || true)"
elif [[ ! -f "${RLOG}" ]] || ! grep -q "recv_s=" "${RLOG}"; then
    fail "pool restore log missing recv_s: $(cat "${RLOG}" 2>/dev/null || true)"
elif ! grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ' "${RLOG}"; then
    fail "pool restore log stamp is not UTC Z-form: $(cat "${RLOG}" 2>/dev/null || true)"
else
    pass "pool restore --execute --from recorded syncoid, properties, and recv_s"
fi

RLOG2="${TEMP}/pool-restore-local.log"
write_restore_env tank/models 0 no /export/models \
    tank/models-backup tank/models-backup@autosnap_ok "${FRESH}"
expect_restore "pool restore --execute --local-from send/recv" 0 "cache/modelfs" \
    MF_RESTORE_LOG="${RLOG2}" "${RESTORE}" --execute --local-from tank/models-backup
if [[ -f "${RESTORE_STATE}/syncoid.args" ]]; then
    fail "pool restore --local-from invoked syncoid"
elif [[ ! -f "${RESTORE_STATE}/set.log" ]]; then
    fail "pool restore --local-from did not zfs set"
elif ! grep -q "zfs send" "${RESTORE_STATE}/commands.log" || ! grep -q "zfs recv" "${RESTORE_STATE}/commands.log"; then
    fail "pool restore --local-from missing send/recv: $(cat "${RESTORE_STATE}/commands.log" 2>/dev/null || true)"
else
    pass "pool restore --execute --local-from used send/recv and printed the cache wipe"
fi

if [[ "${FAILS}" -ne 0 ]]; then
    echo "FAIL: ${FAILS} restore-drill stub test(s) failed" >&2
    exit 1
fi
echo "=== restore drill stub tests passed ==="
