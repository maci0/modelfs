#!/usr/bin/env bash
# Monthly restore drill from docs/recovery.md section 6, as one runnable
# artifact instead of a paste-from-docs procedure: clone the newest snapshot
# onto a mountpoint that is not the live export, time the clone (procedure B
# CoW time; pool-loss RTO is the syncoid pull in recovery.md section 4C),
# diff the restored tree against
# the live dataset, checksum a stable sample file both sides, and append the
# log line that proves the drill ran.
#
# Runs on the NAS (Rocky/RHEL, GNU coreutils), not on sparks or the desktop:
#   ./scripts/dr_restore_drill.sh [DATASET]             # default: tank/models
#   ./scripts/dr_restore_drill.sh --age-only [DATASET]  # snapshot/replica
#                                                       # freshness only
#
# Environment (deliberately not MODELFS_*: the daemon refuses any unknown
# MODELFS_* variable as a typo'd knob, so an exported drill setting would
# fail every modelfs command in the same shell):
#   MF_DRILL_LOG       artifact log path     (default /var/log/modelfs-drill.log)
#   MF_DRILL_LIVE      live tree to diff     (default: the dataset's mountpoint)
#   MF_DRILL_CLONE_MP  clone mountpoint      (default: sibling modelfs-drill
#                       of the live tree, e.g. /export/modelfs-drill)
#   MF_DRILL_KEEP      set non-empty to keep the drill clone mounted for inspection
#   MF_DRILL_MAX_SNAP_AGE  seconds the newest snapshot may be old before
#                               the drill fails   (default 90000 = 25 h)
#   MF_DRILL_REPLICA   optional replica dataset on this host; when set, the
#                       drill also fails if that dataset is missing, has no
#                       snapshots, or is older than MF_DRILL_MAX_REPLICA_AGE
#                       (default 129600 = 36 h, a daily syncoid plus slack)
#   MF_DRILL_SCRATCH   temp dir for file lists (default: repo .scratch, or
#                       /var/tmp/modelfs-drill when this script is copied
#                       out of the tree)
#
# --age-only stops after those age checks (no clone, no drill log). The
# hourly modelfs-snap-age.timer runs that so a disabled sanoid.timer is
# an alarm within the 25 h bound instead of waiting for the next monthly
# clone. Exit status is the verdict: 0 means the newest snapshot restored
# (or, with --age-only, is inside the age bound), mounted off the live
# tree, and read back verified; anything else is an alarm, including "no
# snapshots exist" and "newest snapshot older than the age limit", which
# mean the backup schedule itself is dead or has silently stopped keeping
# restore points inside the RPO the recovery doc claims.
set -euo pipefail

die() {
    echo "drill FAIL: $1" >&2
    exit 1
}

# Answered before the zfs/scratch setup so --help works on machines that
# never run the drill (and so extra operands stay a usage error, exit 2,
# rather than a drill failure).
print_usage() {
    cat <<'EOF'
Usage: ./scripts/dr_restore_drill.sh [--age-only] [DATASET]

Monthly restore drill (docs/recovery.md section 6). Default DATASET is
tank/models. Exit 0 means the newest snapshot restored, mounted off the
live tree, and read back verified. --age-only checks snapshot (and
optional replica) age only: no clone, no drill log. That is the hourly
sanoid.timer-down alarm (modelfs-snap-age.timer).

Environment: MF_DRILL_LOG, MF_DRILL_LIVE, MF_DRILL_CLONE_MP, MF_DRILL_KEEP,
MF_DRILL_MAX_SNAP_AGE, MF_DRILL_REPLICA, MF_DRILL_MAX_REPLICA_AGE,
MF_DRILL_SCRATCH.
EOF
}

AGE_ONLY=0
DATASET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help)
            print_usage
            exit 0
            ;;
        --age-only)
            AGE_ONLY=1
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            print_usage >&2
            exit 2
            ;;
        *)
            if [[ -n "${DATASET}" ]]; then
                print_usage >&2
                exit 2
            fi
            DATASET="$1"
            shift
            ;;
    esac
done
if [[ $# -gt 0 ]]; then
    print_usage >&2
    exit 2
fi
DATASET="${DATASET:-tank/models}"

# Repo runs keep using .scratch via lib.sh. A copy at /usr/local/sbin
# (scripts/install_nas_backup.sh) has no build.zig.zon above it, so
# MF_DRILL_SCRATCH or /var/tmp/modelfs-drill stands in; never /tmp
# (tmpfs on these hosts).
if [[ -n "${MF_DRILL_SCRATCH:-}" ]]; then
    SCRATCH_DIR="${MF_DRILL_SCRATCH}"
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/lib.sh" ]]; then
    # shellcheck source=scripts/lib.sh
    source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
else
    SCRATCH_DIR="/var/tmp/modelfs-drill"
fi
mkdir -p "${SCRATCH_DIR}" || die "cannot create scratch dir ${SCRATCH_DIR}"
command -v zfs >/dev/null 2>&1 || die "zfs not found; this drill runs on the NAS"
# GNU findutils/coreutils are required for the sampler below: find -printf,
# sort -z, and stat -c are not in BusyBox/BSD. This host (Rocky/RHEL NAS)
# ships GNU; probe early so a different host fails with a named fix.
if ! find / -maxdepth 0 -printf '' >/dev/null 2>&1; then
    # shellcheck disable=SC2185
    find_ver="$(find --version 2>/dev/null | head -1 || echo non-GNU find)"
    die "GNU find is required (need find -printf); this host has ${find_ver}"
fi
sort_help="$(sort --help 2>/dev/null || true)"
if [[ "${sort_help}" != *-z* ]]; then
    die "GNU sort is required (need sort -z)"
fi
if ! stat -c %s / >/dev/null 2>&1; then
    die "GNU stat is required (need stat -c %s)"
fi

LOG_FILE="${MF_DRILL_LOG:-/var/log/modelfs-drill.log}"
# A restore with no writable artifact is not a drill. Fail before clone
# so an unwritable /var/log does not spend minutes proving a snapshot
# we then cannot record. `touch` is not enough: the owner can update
# timestamps on a mode-000 file they own, and the append would then
# fail after the clone. Opening for append is the write we need.
# --age-only does not append the log (that would make check_drill_log.sh
# treat a freshness check as a restore), so skip this gate there.
if [[ "${AGE_ONLY}" -eq 0 ]]; then
    : >>"${LOG_FILE}" || die "cannot write the drill log ${LOG_FILE}"
fi

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
case "${SNAP_CTIME}" in
    '' | *[!0-9]*)
        die "newest snapshot creation is not an epoch second: ${SNAP_LINE}"
        ;;
    *)
        ;;
esac
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
# Digit-only is not enough: bash [[ -gt ]] treats a leading 0 as octal
# (MF_DRILL_MAX_SNAP_AGE=08 aborts; =010 means 8 seconds). 10# forces
# decimal. 10 digits is ~317 years and stays inside signed 64-bit $(( )).
if [[ "${#MAX_SNAP_AGE}" -gt 10 ]]; then
    die "MF_DRILL_MAX_SNAP_AGE must be a whole number of seconds, got '${MAX_SNAP_AGE}'"
fi
MAX_SNAP_AGE=$((10#${MAX_SNAP_AGE}))
MAX_REPLICA_AGE="${MF_DRILL_MAX_REPLICA_AGE:-129600}"
case "${MAX_REPLICA_AGE}" in
    '' | *[!0-9]*)
        die "MF_DRILL_MAX_REPLICA_AGE must be a whole number of seconds, got '${MAX_REPLICA_AGE}'"
        ;;
    *)
        ;;
esac
if [[ "${#MAX_REPLICA_AGE}" -gt 10 ]]; then
    die "MF_DRILL_MAX_REPLICA_AGE must be a whole number of seconds, got '${MAX_REPLICA_AGE}'"
fi
MAX_REPLICA_AGE=$((10#${MAX_REPLICA_AGE}))
# ZFS creation is an epoch second. A negative age is a snapshot from the
# future of this host's clock (NTP stepped back, or the pool's clock was
# ahead when the snap was taken): the RPO comparison cannot be trusted, and
# bash `[[ negative -gt MAX ]]` would pass it as fresh.
if [[ "${SNAP_AGE}" -lt 0 ]]; then
    die "newest snapshot ${SNAP} has creation ${SNAP_CTIME} in the future of now ${NOW}: host clock and ZFS disagree"
fi
if [[ "${SNAP_AGE}" -gt "${MAX_SNAP_AGE}" ]]; then
    die "newest snapshot ${SNAP} is ${SNAP_AGE}s old, past the ${MAX_SNAP_AGE}s limit: the autosnap schedule stopped keeping restore points inside the claimed RPO (docs/recovery.md sections 3 and 5)"
fi
echo "drill: newest snapshot ${SNAP} (age ${SNAP_AGE}s)"

# Optional pool-loss copy on this host. A remote syncoid target is not
# visible to local `zfs list`; run this same script there, or import the
# replica, rather than treating a missing local dataset as "replica is fine".
REPLICA_STATUS="unchecked"
if [[ -n "${MF_DRILL_REPLICA:-}" ]]; then
    zfs list -H -o name "${MF_DRILL_REPLICA}" >/dev/null 2>&1 \
        || die "replica dataset ${MF_DRILL_REPLICA} does not exist (pool-loss copy missing; docs/recovery.md section 3)"
    REPLICA_LINE="$(zfs list -H -p -t snapshot -o name,creation -s creation "${MF_DRILL_REPLICA}" | tail -n 1)"
    REPLICA_SNAP="${REPLICA_LINE%%$'\t'*}"
    if [[ -z "${REPLICA_SNAP}" ]]; then
        die "replica ${MF_DRILL_REPLICA} has no snapshots: syncoid is down or was never enabled (docs/recovery.md section 3)"
    fi
    REPLICA_CTIME="${REPLICA_LINE##*$'\t'}"
    case "${REPLICA_CTIME}" in
        '' | *[!0-9]*)
            die "replica newest snapshot creation is not an epoch second: ${REPLICA_LINE}"
            ;;
        *)
            ;;
    esac
    REPLICA_AGE=$((NOW - REPLICA_CTIME))
    if [[ "${REPLICA_AGE}" -lt 0 ]]; then
        die "replica newest snapshot ${REPLICA_SNAP} has creation ${REPLICA_CTIME} in the future of now ${NOW}: host clock and ZFS disagree"
    fi
    if [[ "${REPLICA_AGE}" -gt "${MAX_REPLICA_AGE}" ]]; then
        die "replica newest snapshot ${REPLICA_SNAP} is ${REPLICA_AGE}s old, past the ${MAX_REPLICA_AGE}s limit: the replica schedule stopped keeping restore points inside the claimed RPO (docs/recovery.md sections 3 and 5)"
    fi
    REPLICA_STATUS="ok"
    echo "drill: replica ${MF_DRILL_REPLICA} newest ${REPLICA_SNAP} (age ${REPLICA_AGE}s)"
fi

# Hourly freshness alarm: the monthly clone is the restore proof, this
# is the "sanoid.timer was disabled" alarm that cannot wait 30 days.
if [[ "${AGE_ONLY}" -eq 1 ]]; then
    echo "snap-age OK: ${SNAP} age ${SNAP_AGE}s replica=${REPLICA_STATUS}"
    exit 0
fi

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

# A clone inherits the origin's mountpoint. tank/models is /export/models, so
# `zfs clone SNAP tank/drill` would report that same path, and every diff and
# checksum below would run against the live export: a green drill that never
# restored anything. Force a distinct mountpoint (sibling modelfs-drill, or
# MF_DRILL_CLONE_MP) and refuse to proceed if it still collides.
if [[ -n "${MF_DRILL_CLONE_MP:-}" ]]; then
    CLONE_MP_WANT="${MF_DRILL_CLONE_MP}"
else
    CLONE_MP_WANT="$(dirname "${LIVE}")/modelfs-drill"
fi
case "${CLONE_MP_WANT}" in
    none | legacy | '-' | '')
        die "clone mountpoint '${CLONE_MP_WANT}' is not a usable path"
        ;;
    *)
        ;;
esac
if [[ "${CLONE_MP_WANT}" == "${LIVE}" ]]; then
    die "clone mountpoint ${CLONE_MP_WANT} collides with the live tree; the drill would hash production against itself"
fi

# CLOCK_BOOTTIME via /proc/uptime, not date +%s: an NTP step or admin
# clock set during a multi-minute clone would otherwise log a negative or
# huge RTO. Suspend time counts, which is what recovery.md's RTO row wants.
T0="$(awk '{print $1}' /proc/uptime)"
zfs clone -o "mountpoint=${CLONE_MP_WANT}" "${SNAP}" "${CLONE}" || die "zfs clone of ${SNAP} failed"
CLONE_MP="$(zfs get -H -o value mountpoint "${CLONE}")"
if [[ "${CLONE_MP}" == "${LIVE}" ]]; then
    die "clone ${CLONE} mounted at the live tree ${LIVE}; restore is unproven"
fi
if [[ ! -d "${CLONE_MP}" ]]; then
    die "clone ${CLONE} did not appear at its mountpoint ${CLONE_MP}"
fi
T1="$(awk '{print $1}' /proc/uptime)"
ELAPSED="$(awk -v a="${T0}" -v b="${T1}" 'BEGIN { printf "%.1f", (b - a < 0) ? 0 : b - a }')"
echo "drill: cloned to ${CLONE_MP} in ${ELAPSED}s (recorded in the log; snapshot-clone time, not pool-loss recv)"

# Payload files only: .cluster leases republish every 10 s and are not the
# dataset, and .zfs is the snapshot directory (visible when snapdir=visible).
# Counting either would let a snapshot of only leases pass as a restore.
FILE_LIST="$(mktemp "${SCRATCH_DIR}/dr-files-XXXXXX")"
find "${CLONE_MP}" \( -name .cluster -o -name .zfs \) -prune -o -type f -print >"${FILE_LIST}" ||
    die "find failed under ${CLONE_MP}"
FILE_COUNT="$(wc -l <"${FILE_LIST}" | tr -d ' ')"
rm -f "${FILE_LIST}"
if [[ "${FILE_COUNT}" -eq 0 ]]; then
    die "snapshot contains zero files; restoring it recovers nothing"
fi

# Snapshot-vs-live differences are expected within the RPO window (up to an
# hour of writes behind the newest autosnap): counted and logged, never a
# failure. A diff that crashes (exit code 2+) is a failure. Lease files and
# the snapdir are excluded so drift reflects model bytes, not heartbeats.
DRIFT_LINES="$(mktemp "${SCRATCH_DIR}/drift-XXXXXX")"
DIFF_RC=0
diff -rq --exclude=.cluster --exclude=.zfs "${CLONE_MP}" "${LIVE}" >"${DRIFT_LINES}" 2>&1 || DIFF_RC=$?
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
    # NUL records of "size<TAB>path", largest first. GNU find/sort: this
    # drill runs on the NAS. find's exit is checked instead of masked, and
    # the loop keeps running in this shell so the SAMPLE_* assignments
    # survive it.
    CANDIDATES="$(mktemp "${SCRATCH_DIR}/dr-candidates-XXXXXX")"
    find "${CLONE_MP}" \( -name .cluster -o -name .zfs \) -prune -o -type f -size +"${MIN_BYTES}"c -printf '%s\t%p\0' >"${CANDIDATES}.raw" ||
        die "find failed under ${CLONE_MP}"
    sort -z -nr -o "${CANDIDATES}" "${CANDIDATES}.raw" || die "sort of sample candidates failed"
    rm -f "${CANDIDATES}.raw"
    while IFS=$'\t' read -r -d '' sz f; do
        [[ -n "${f}" ]] || continue
        SAMPLE_LIVE_SZ="$(stat -c %s "${LIVE}${f#"${CLONE_MP}"}" 2>/dev/null || echo -1)"
        if [[ "${sz}" == "${SAMPLE_LIVE_SZ}" && "${sz}" -gt 0 ]]; then
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

# UTC, second precision, trailing Z: lexicographically sortable and the
# same on every host, unlike `date -Is` which is local time with a DST
# offset (fall-back 01:30 happens twice; string sort then disagrees with
# instant order).
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "${STAMP} ${SNAP} ok snap_age_s=${SNAP_AGE} clone_s=${ELAPSED} drift=${DRIFT} sample=${SAMPLE_REL} replica=${REPLICA_STATUS}" >>"${LOG_FILE}"
echo "drill OK: ${SNAP} restored and verified (${FILE_COUNT} files, drift ${DRIFT} lines, sample sha256 match on ${SAMPLE_REL})"
echo "drill log line appended to ${LOG_FILE}; alert when its newest entry ages past 35 days (docs/recovery.md section 6)"
