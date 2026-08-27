#!/usr/bin/env bash
# Regression tests for scripts/dr_restore_drill.sh. The real drill runs on
# the NAS against tank/models; this drives it through a stub zfs(8) that
# copies fixture trees in place of clone, so CI can fail a drill that would
# hash the live export against itself, bless an empty or lease-only
# snapshot, or ignore a dead autosnap schedule.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
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

if [[ "${FAILS}" -ne 0 ]]; then
    echo "FAIL: ${FAILS} restore-drill stub test(s) failed" >&2
    exit 1
fi
echo "=== restore drill stub tests passed ==="
