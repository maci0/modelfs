#!/usr/bin/env bash
# Monthly restore drill from docs/recovery.md section 6, as one runnable
# artifact instead of a paste-from-docs procedure: clone the newest snapshot,
# time the clone (the measured restore rate that keeps the RTO row honest),
# diff the restored tree against the live dataset, checksum a stable sample
# file both sides, and append the log line that proves the drill ran.
#
# Runs on the NAS (Rocky/RHEL, GNU coreutils), not on sparks or the desktop:
#   ./scripts/dr_restore_drill.sh [DATASET]      # default: tank/models
#
# Environment (deliberately not MODELFS_*: the daemon refuses any unknown
# MODELFS_* variable as a typo'd knob, so an exported drill setting would
# fail every modelfs command in the same shell):
#   MF_DRILL_LOG   artifact log path     (default /var/log/modelfs-drill.log)
#   MF_DRILL_LIVE  live tree to diff     (default: the dataset's mountpoint)
#   MF_DRILL_KEEP  set non-empty to keep the drill clone mounted for inspection
#   MF_DRILL_MAX_SNAP_AGE  seconds the newest snapshot may be old before
#                               the drill fails   (default 90000 = 25 h)
#
# Exit status is the drill verdict: 0 means the newest snapshot restored,
# mounted, and read back verified; anything else is an alarm, including
# "no snapshots exist" and "newest snapshot older than the age limit", which
# mean the backup schedule itself is dead or has silently stopped keeping
# restore points inside the RPO the recovery doc claims.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
mkdir -p "${SCRATCH_DIR}"

die() {
    echo "drill FAIL: $1" >&2
    exit 1
}

command -v zfs >/dev/null 2>&1 || die "zfs not found; this drill runs on the NAS"
[[ $# -le 1 ]] || die "usage: dr_restore_drill.sh [DATASET]"

DATASET="${1:-tank/models}"
LOG_FILE="${MF_DRILL_LOG:-/var/log/modelfs-drill.log}"

zfs list -H -o name "${DATASET}" >/dev/null 2>&1 \
    || die "dataset ${DATASET} does not exist on this host"

# Newest by creation time, not by name sort: hourly/daily/monthly suffixes
# would otherwise decide which snapshot a lexicographic tail picks. The
# creation stamp rides along (-p keeps it a parseable epoch) so the drill can
# refuse to bless a restore point too old for the RPO: snapshots existing but
# stale is how a dead sanoid.timer hides behind last month's green drill.
SNAP_LINE="$(zfs list -H -p -t snapshot -o name,creation -s creation "${DATASET}" | tail -n 1)"
SNAP="${SNAP_LINE%%$'\t'*}"
if [[ -z "${SNAP}" ]]; then
    die "no snapshots of ${DATASET}: sanoid.timer is down or was never enabled (docs/recovery.md section 3)"
fi
SNAP_CTIME="${SNAP_LINE##*$'\t'}"
NOW="$(date +%s)"
SNAP_AGE=$((NOW - SNAP_CTIME))
MAX_SNAP_AGE="${MF_DRILL_MAX_SNAP_AGE:-90000}"
case "${MAX_SNAP_AGE}" in
    '' | *[!0-9]*)
        die "MF_DRILL_MAX_SNAP_AGE must be a whole number of seconds, got '${MAX_SNAP_AGE}'"
        ;;
    *)
        ;;
esac
if [[ "${SNAP_AGE}" -gt "${MAX_SNAP_AGE}" ]]; then
    die "newest snapshot ${SNAP} is ${SNAP_AGE}s old, past the ${MAX_SNAP_AGE}s limit: the autosnap schedule stopped keeping restore points inside the claimed RPO (docs/recovery.md sections 3 and 5)"
fi
echo "drill: newest snapshot ${SNAP} (age ${SNAP_AGE}s)"

PARENT="${DATASET%/*}"
if [[ "${PARENT}" == "${DATASET}" ]]; then
    die "dataset must be nested (pool/data) to derive the clone name, got ${DATASET}"
fi
CLONE="${PARENT}/drill"

# A clone left over from a crashed run must go before we can reuse the name;
# refuse to destroy one that is still mounted, because that inspection is
# somebody's open investigation.
if zfs list -H -o name "${CLONE}" >/dev/null 2>&1; then
    CLONE_MOUNTED="$(zfs get -H -o value mounted "${CLONE}")"
    if [[ "${CLONE_MOUNTED}" == "yes" ]]; then
        die "${CLONE} already exists and is mounted; inspect and destroy it first"
    fi
    zfs destroy "${CLONE}" || die "stale ${CLONE} exists and could not be destroyed"
fi

cleanup() {
    if [[ -n "${MF_DRILL_KEEP:-}" ]]; then
        echo "drill: MF_DRILL_KEEP set, leaving ${CLONE} mounted for inspection"
        return 0
    fi
    if zfs list -H -o name "${CLONE}" >/dev/null 2>&1; then
        zfs unmount "${CLONE}" >/dev/null 2>&1 || true
        zfs destroy "${CLONE}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

LIVE="${MF_DRILL_LIVE:-$(zfs get -H -o value mountpoint "${DATASET}")}"
case "${LIVE}" in
    none | legacy | '-')
        die "dataset ${DATASET} has mountpoint '${LIVE}'; mount it or point MF_DRILL_LIVE at the live tree"
        ;;
    *)
        ;;
esac
[[ -d "${LIVE}" ]] || die "live tree ${LIVE} is not a directory"

T0="$(date +%s.%N)"
zfs clone "${SNAP}" "${CLONE}" || die "zfs clone of ${SNAP} failed"
CLONE_MP="$(zfs get -H -o value mountpoint "${CLONE}")"
if [[ ! -d "${CLONE_MP}" ]]; then
    die "clone ${CLONE} did not appear at its mountpoint ${CLONE_MP}"
fi
T1="$(date +%s.%N)"
ELAPSED="$(awk -v a="${T0}" -v b="${T1}" 'BEGIN { printf "%.1f", b - a }')"
echo "drill: cloned to ${CLONE_MP} in ${ELAPSED}s (recorded in the log; this number keeps recovery.md's RTO row honest)"

# The clone must hold data at all: an empty snapshot passing this drill would
# prove only that zfs clone works, not that anything would survive a restore.
FILE_COUNT="$(find "${CLONE_MP}" -type f | wc -l)"
if [[ "${FILE_COUNT}" -eq 0 ]]; then
    die "snapshot contains zero files; restoring it recovers nothing"
fi

# Snapshot-vs-live differences are expected within the RPO window (up to an
# hour of writes behind the newest autosnap): counted and logged, never a
# failure. A diff that crashes (exit code 2+) is a failure.
DRIFT_LINES="$(mktemp "${SCRATCH_DIR}/drift-XXXXXX")"
DIFF_RC=0
diff -rq "${CLONE_MP}" "${LIVE}" >"${DRIFT_LINES}" 2>&1 || DIFF_RC=$?
case "${DIFF_RC}" in
    0 | 1)
        ;;
    *)
        die "diff between clone and live tree failed (rc=${DIFF_RC}); kept output in ${DRIFT_LINES}"
        ;;
esac
DRIFT="$(wc -l <"${DRIFT_LINES}" | tr -d ' ')"
rm -f "${DRIFT_LINES}"

# Ground truth beyond directory equality: hash one stable file in both trees.
# The sampler walks the biggest files first (weights are the payload worth
# proving) and skips any whose size changed since the snapshot, so a download
# that landed after the autosnap makes the drill skip it rather than fail;
# a size-stable file that hashes differently IS a restore failure. Success is
# communicated by setting SAMPLE_REL, not by return status, so the caller's
# checks stay plain commands under set -e.
pick_sample() {
    MIN_BYTES="$1"
    SAMPLE_PATH=""
    SAMPLE_REL=""
    # find runs into a file rather than a process substitution: its exit
    # status is checked instead of masked, and the loop keeps running in this
    # shell so the SAMPLE_* assignments survive it.
    CANDIDATES="$(mktemp "${SCRATCH_DIR}/dr-candidates-XXXXXX")"
    find "${CLONE_MP}" -type f -size +"${MIN_BYTES}"c -print0 >"${CANDIDATES}" ||
        die "find failed under ${CLONE_MP}"
    while IFS= read -r -d '' f; do
        SAMPLE_CLONE_SZ="$(stat -c %s "${f}")"
        SAMPLE_LIVE_SZ="$(stat -c %s "${LIVE}${f#"${CLONE_MP}"}" 2>/dev/null || echo -1)"
        if [[ "${SAMPLE_CLONE_SZ}" == "${SAMPLE_LIVE_SZ}" && "${SAMPLE_CLONE_SZ}" -gt 0 ]]; then
            SAMPLE_PATH="${f}"
            SAMPLE_REL="${f#"${CLONE_MP}"}"
            break
        fi
    done <"${CANDIDATES}"
    rm -f "${CANDIDATES}"
}

pick_sample 67108864
if [[ -z "${SAMPLE_REL}" ]]; then
    pick_sample 1
fi
if [[ -z "${SAMPLE_REL}" ]]; then
    die "no size-stable file in the clone to checksum against the live tree"
fi

HASH_CLONE="$(sha256sum "${SAMPLE_PATH}" | awk '{print $1}')"
HASH_LIVE="$(sha256sum "${LIVE}${SAMPLE_REL}" | awk '{print $1}')"
if [[ "${HASH_CLONE}" != "${HASH_LIVE}" ]]; then
    die "restored ${SAMPLE_REL} hashes ${HASH_CLONE} but the live copy hashes ${HASH_LIVE}: the snapshot did not faithfully capture this file"
fi

touch "${LOG_FILE}" || die "cannot write the drill log ${LOG_FILE}"
STAMP="$(date -Is)"
echo "${STAMP} ${SNAP} ok snap_age_s=${SNAP_AGE} clone_s=${ELAPSED} drift=${DRIFT} sample=${SAMPLE_REL}" >>"${LOG_FILE}"
echo "drill OK: ${SNAP} restored and verified (${FILE_COUNT} files, drift ${DRIFT} lines, sample sha256 match on ${SAMPLE_REL})"
echo "drill log line appended to ${LOG_FILE}; alert when its newest entry ages past 35 days (docs/recovery.md section 6)"
