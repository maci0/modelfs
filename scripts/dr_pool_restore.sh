#!/usr/bin/env bash
# Pool-loss restore from docs/recovery.md procedure C, as one runnable
# artifact instead of a paste-from-docs procedure. Pulls tank/models onto
# DEST from the replica (syncoid, or zfs send | recv of a locally imported
# copy), sets the export properties from operations.md, and appends the
# timed log line that is the pool-loss RTO. Does not create the pool
# (vdev layout is site-specific) and does not wipe node caches (those are
# other hosts; the script prints the commands that must run before any
# client remounts).
#
# Default is a dry-run (prints the plan, writes nothing), matching
# install_nas_backup.sh. --execute performs the recv.
set -euo pipefail

die() {
    echo "pool-restore FAIL: $1" >&2
    exit 1
}

print_usage() {
    cat <<'EOF'
Usage: ./scripts/dr_pool_restore.sh [--execute] [--force] --from HOST:DATASET [DEST]
       ./scripts/dr_pool_restore.sh [--execute] [--force] --local-from DATASET [DEST]

Replay the pool-loss copy onto DEST (default tank/models). This is
docs/recovery.md procedure C. Without --execute, print the plan and
write nothing.

--from HOST:DATASET     syncoid pull from the replica host
--local-from DATASET    zfs send -R newest snapshot | zfs recv -Fs DEST
--force                 allow DEST that is currently mounted (otherwise refuse)
--execute               run the recv and set export properties

Does not create the pool. Does not wipe node caches: after a successful
recv, print the cache-wipe commands that must run before any client
remounts. Environment: MF_RESTORE_FROM, MF_RESTORE_LOCAL_FROM,
MF_RESTORE_MOUNTPOINT (default /export/models), MF_RESTORE_SHARENFS
(default operations.md flags), MF_RESTORE_LOG (default
/var/log/modelfs-pool-restore.log).
EOF
}

EXECUTE=0
FORCE=0
FROM=""
LOCAL_FROM=""
DEST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help)
            print_usage
            exit 0
            ;;
        --execute)
            EXECUTE=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --from)
            if [[ $# -lt 2 ]]; then
                print_usage >&2
                exit 2
            fi
            FROM="$2"
            shift 2
            ;;
        --local-from)
            if [[ $# -lt 2 ]]; then
                print_usage >&2
                exit 2
            fi
            LOCAL_FROM="$2"
            shift 2
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
            if [[ -n "${DEST}" ]]; then
                print_usage >&2
                exit 2
            fi
            DEST="$1"
            shift
            ;;
    esac
done
if [[ $# -gt 0 ]]; then
    print_usage >&2
    exit 2
fi

FROM="${FROM:-${MF_RESTORE_FROM:-}}"
LOCAL_FROM="${LOCAL_FROM:-${MF_RESTORE_LOCAL_FROM:-}}"
DEST="${DEST:-tank/models}"
MOUNTPOINT="${MF_RESTORE_MOUNTPOINT:-/export/models}"
SHARENFS="${MF_RESTORE_SHARENFS:-rw,async,no_root_squash,no_subtree_check}"
LOG_FILE="${MF_RESTORE_LOG:-/var/log/modelfs-pool-restore.log}"

if [[ -n "${FROM}" && -n "${LOCAL_FROM}" ]]; then
    die "pass only one of --from or --local-from"
fi
if [[ -z "${FROM}" && -z "${LOCAL_FROM}" ]]; then
    die "replica source required: --from HOST:DATASET or --local-from DATASET (docs/recovery.md procedure C)"
fi

PARENT="${DEST%/*}"
if [[ "${PARENT}" == "${DEST}" || -z "${PARENT}" ]]; then
    die "destination must be nested (pool/data), got ${DEST}"
fi
case "${MOUNTPOINT}" in
    none | legacy | '-' | '')
        die "MF_RESTORE_MOUNTPOINT '${MOUNTPOINT}' is not a usable path"
        ;;
    *)
        ;;
esac

command -v zfs >/dev/null 2>&1 || die "zfs not found; this restore runs on the replacement NAS"

# A recv onto a mounted dest is --force-delete of the live export.
# Procedure C assumes a newly created pool where DEST does not exist yet.
if zfs list -H -o name "${DEST}" >/dev/null 2>&1; then
    DEST_MOUNTED="$(zfs get -H -o value mounted "${DEST}")" \
        || die "cannot read mounted property of ${DEST}"
    if [[ "${DEST_MOUNTED}" == "yes" && "${FORCE}" -eq 0 ]]; then
        die "destination ${DEST} is mounted; refusing to replace a live dataset (pass --force if this box is the replacement NAS)"
    fi
fi

SOURCE_LABEL=""
SEND_SNAP=""
if [[ -n "${LOCAL_FROM}" ]]; then
    if [[ "${LOCAL_FROM}" == "${DEST}" ]]; then
        die "--local-from ${LOCAL_FROM} is DEST; that cannot rebuild a dead pool"
    fi
    zfs list -H -o name "${LOCAL_FROM}" >/dev/null 2>&1 \
        || die "local replica ${LOCAL_FROM} does not exist on this host"
    SNAP_LINE="$(zfs list -H -p -t snapshot -o name,creation -s creation "${LOCAL_FROM}" | tail -n 1)"
    SEND_SNAP="${SNAP_LINE%%$'\t'*}"
    if [[ -z "${SEND_SNAP}" ]]; then
        die "local replica ${LOCAL_FROM} has no snapshots: nothing to recv (docs/recovery.md section 3)"
    fi
    SOURCE_LABEL="local:${SEND_SNAP}"
else
    SOURCE_LABEL="syncoid:${FROM}"
fi

print_plan() {
    echo "pool-restore plan:"
    echo "  dest        ${DEST}"
    echo "  source      ${SOURCE_LABEL}"
    echo "  mountpoint  ${MOUNTPOINT}"
    echo "  sharenfs    ${SHARENFS}"
    if [[ -n "${LOCAL_FROM}" ]]; then
        echo "  recv        zfs send -R ${SEND_SNAP} | zfs recv -Fs ${DEST}"
    else
        echo "  recv        syncoid --no-privilege-elevation --force-delete ${FROM} ${DEST}"
    fi
    echo "  then        zfs set mountpoint=${MOUNTPOINT} compression=lz4 recordsize=1M atime=off xattr=sa relatime=off sharenfs=${SHARENFS} ${DEST}"
    echo "  log         ${LOG_FILE}"
    echo "without --execute this script writes nothing"
}

if [[ "${EXECUTE}" -eq 0 ]]; then
    print_plan
    exit 0
fi

: >>"${LOG_FILE}" || die "cannot write the restore log ${LOG_FILE}"

print_cache_wipe() {
    echo "next, BEFORE any client remounts (docs/recovery.md procedure C step 3):"
    echo "  rm -rf /var/cache/modelfs/*        # on every spark"
    echo "  rm -rf /var/cache/fscache/*        # on the desktop"
    echo "then remount clients (fstab from operations.md) and: modelfs status"
}

# CLOCK_BOOTTIME via /proc/uptime, not date +%s: an NTP step during a
# multi-hour recv would otherwise log a negative or huge RTO. Suspend
# time counts, which is what recovery.md's pool-loss RTO row wants.
T0="$(awk '{print $1}' /proc/uptime)"
if [[ -n "${LOCAL_FROM}" ]]; then
    zfs send -R "${SEND_SNAP}" | zfs recv -Fs "${DEST}" \
        || die "zfs send/recv from ${SEND_SNAP} to ${DEST} failed"
else
    command -v syncoid >/dev/null 2>&1 \
        || die "syncoid not found; install sanoid (docs/recovery.md section 3) or use --local-from"
    syncoid --no-privilege-elevation --force-delete "${FROM}" "${DEST}" \
        || die "syncoid pull from ${FROM} to ${DEST} failed"
fi
T1="$(awk '{print $1}' /proc/uptime)"
ELAPSED="$(awk -v a="${T0}" -v b="${T1}" 'BEGIN { printf "%.1f", (b - a < 0) ? 0 : b - a }')"

# Properties after the pull so they match operations.md regardless of
# what the replica carried (it is not the NFS export).
zfs set "mountpoint=${MOUNTPOINT}" compression=lz4 recordsize=1M \
    atime=off xattr=sa relatime=off \
    "sharenfs=${SHARENFS}" "${DEST}" \
    || die "zfs set of export properties on ${DEST} failed"

GOT_MP="$(zfs get -H -o value mountpoint "${DEST}")" \
    || die "cannot read mountpoint of ${DEST} after zfs set"
if [[ "${GOT_MP}" != "${MOUNTPOINT}" ]]; then
    die "destination ${DEST} mountpoint is ${GOT_MP}, expected ${MOUNTPOINT}"
fi

STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "${STAMP} ${DEST} ok recv_s=${ELAPSED} source=${SOURCE_LABEL}" >>"${LOG_FILE}"
echo "pool-restore OK: ${DEST} from ${SOURCE_LABEL} in ${ELAPSED}s (recorded in ${LOG_FILE})"
print_cache_wipe
