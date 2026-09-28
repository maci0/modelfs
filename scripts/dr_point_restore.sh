#!/usr/bin/env bash
# Point-in-time copy-back from docs/recovery.md procedure B, as one
# runnable artifact instead of a paste-from-docs procedure. Clones a
# KNOWN-GOOD snapshot onto a throwaway dataset, copies the named paths
# back over the live export, and verifies each one byte for byte.
#
# The snapshot is always named by the operator. The newest snapshot is
# the wrong default for a corruption or deletion incident: every snapshot
# taken after the bad write preserves the damage too.
#
# Default is a dry-run (prints the plan, writes nothing), matching
# install_nas_backup.sh and dr_pool_restore.sh. --execute performs the
# copy-back.
set -euo pipefail

die() {
    echo "point-restore FAIL: $1" >&2
    exit 1
}

print_usage() {
    cat <<'EOF'
Usage: ./scripts/dr_point_restore.sh [OPTIONS] SNAPSHOT --copy RELPATH...

Restore RELPATHs from a known-good SNAPSHOT of DATASET over the live
export. This is docs/recovery.md procedure B. Without --execute, print
the plan and write nothing.

SNAPSHOT              full snapshot name, DATASET@snap (no newest-pick)
--copy RELPATH        path under the dataset root to restore; repeatable
--dataset DATASET     dataset holding SNAPSHOT (default tank/models)
--live PATH           live export mountpoint (default /export/models)
--clone DATASET       throwaway clone dataset (default tank/recover)
--clone-mp PATH       clone mountpoint (default /export/modelfs-recover)
--execute             run the copy-back

Fence the clients first: the script stops no daemon, unmounts nothing,
and cannot tell whether a reader is still attached to /export/models.
The clone is left mounted on success; destroy it by hand, and run
procedure C step 3 (node cache wipe) before reopening clients.
EOF
}

EXECUTE=0
DATASET="${MF_POINT_DATASET:-tank/models}"
LIVE="${MF_POINT_LIVE:-/export/models}"
CLONE="${MF_POINT_CLONE:-tank/recover}"
CLONE_MP="${MF_POINT_CLONE_MP:-/export/modelfs-recover}"
SNAPSHOT=""
COPY_PATHS=()

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
        --copy)
            [[ $# -ge 2 ]] || die "--copy needs a path argument"
            COPY_PATHS+=("$2")
            shift 2
            ;;
        --dataset | --live | --clone | --clone-mp)
            [[ $# -ge 2 ]] || die "$1 needs a value argument"
            case "$1" in
                --dataset) DATASET="$2" ;;
                --live) LIVE="$2" ;;
                --clone) CLONE="$2" ;;
                --clone-mp) CLONE_MP="$2" ;;
                *)
                    die "unknown option $1"
                    ;;
            esac
            shift 2
            ;;
        -*)
            print_usage >&2
            exit 2
            ;;
        *)
            [[ -z "${SNAPSHOT}" ]] || die "more than one snapshot given: ${SNAPSHOT} and $1"
            SNAPSHOT="$1"
            shift
            ;;
    esac
done

command -v zfs >/dev/null 2>&1 || die "zfs not found; this runs on the NAS"

[[ -n "${SNAPSHOT}" ]] || die "a snapshot name is required: procedure B restores from a snapshot you inspected, not the newest one (docs/recovery.md procedure B)"
[[ "${SNAPSHOT}" == "${DATASET}@"* ]] || die "snapshot ${SNAPSHOT} is not of ${DATASET} (expected ${DATASET}@...)"
[[ "${SNAPSHOT}" != *"@"*"/"*"@"* ]] || die "snapshot ${SNAPSHOT} looks like a child dataset; clone that child directly, a parent clone does not contain it"
[[ "${SNAPSHOT}" != *"#"* ]] || die "snapshot ${SNAPSHOT} is a clone-holder name, not a snapshot"
[[ ${#COPY_PATHS[@]} -gt 0 ]] || die "no --copy path given: there is nothing to restore, and a blanket overwrite of the dataset is not this procedure"

for rel in "${COPY_PATHS[@]}"; do
    [[ -n "${rel}" ]] || die "--copy path is empty"
    [[ "${rel}" != /* ]] || die "--copy path ${rel} is absolute; give it relative to the dataset root"
    case "${rel}" in
        .. | ../* | */../* | */..)
            die "--copy path ${rel} escapes the dataset root"
            ;;
        *)
            ;;
    esac
    [[ "${rel}" != *$'\n'* ]] || die "--copy path contains a newline"
done

zfs list -H -t snapshot -o name "${SNAPSHOT}" >/dev/null 2>&1 \
    || die "snapshot ${SNAPSHOT} does not exist (docs/recovery.md procedure B lists the candidates first)"

# Refuse a clone dataset or mountpoint that already exists: a leftover
# from an earlier attempt is a restore point of its own, and reusing it
# silently restores whatever it was cloned from.
if zfs list -H -o name "${CLONE}" >/dev/null 2>&1; then
    die "clone dataset ${CLONE} already exists: inspect it and destroy it explicitly, do not reuse it (docs/recovery.md procedure B)"
fi
if [[ -e "${CLONE_MP}" ]]; then
    die "clone mountpoint ${CLONE_MP} already exists: a restore path that predates this run is not this run's clone"
fi
[[ -d "${LIVE}" ]] || die "live export ${LIVE} is not a directory: is the origin mounted?"

# Cloning onto (or inside) the live export would checksum production
# against itself, the exact false pass the monthly drill refuses.
case "${CLONE_MP}" in
    "${LIVE}" | "${LIVE}/"*)
        die "clone mountpoint ${CLONE_MP} is the live export ${LIVE}: restore would compare the live tree against itself"
        ;;
    *)
        ;;
esac
case "${LIVE}" in
    "${CLONE_MP}" | "${CLONE_MP}/"*)
        die "live export ${LIVE} is inside the clone mountpoint ${CLONE_MP}: the live tree would be shadowed by the clone"
        ;;
    *)
        ;;
esac

PRESERVE="${DATASET}@pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"

echo "point-restore plan (docs/recovery.md procedure B)"
echo "  restore from : ${SNAPSHOT}"
echo "  live export  : ${LIVE}"
echo "  clone        : ${CLONE} at ${CLONE_MP} (readonly, unshared)"
echo "  preserve     : zfs snapshot -r ${PRESERVE}"
for rel in "${COPY_PATHS[@]}"; do
    echo "  copy back    : ${rel}"
done
if [[ "${EXECUTE}" -ne 1 ]]; then
    echo "  dry run; pass --execute to run it"
    exit 0
fi

echo "point-restore: clients must already be fenced (recovery.md procedure B, first paragraph)"
zfs snapshot -r "${PRESERVE}" || die "could not preserve the current state at ${PRESERVE}; copy-back is refused without a pre-restore snapshot"
echo "point-restore: preserved the pre-restore state at ${PRESERVE}"

zfs clone -o mountpoint="${CLONE_MP}" -o readonly=on -o sharenfs=off -o sharesmb=off \
    "${SNAPSHOT}" "${CLONE}" \
    || die "clone of ${SNAPSHOT} onto ${CLONE} failed; ${PRESERVE} still holds the pre-restore state"
[[ -d "${CLONE_MP}" ]] || die "clone ${CLONE} did not appear at ${CLONE_MP}"
if [[ "${CLONE_MP}" == "${LIVE}" || "${LIVE}" == "${CLONE_MP}"/* ]]; then
    die "clone ${CLONE} mounted at ${CLONE_MP}, which shadows the live export ${LIVE}"
fi

for rel in "${COPY_PATHS[@]}"; do
    src="${CLONE_MP}/${rel}"
    dst="${LIVE}/${rel}"
    [[ -f "${src}" ]] || die "${rel} is not a file in ${SNAPSHOT}: nothing to restore for that path"
    [[ -d "${dst%/*}" ]] || die "destination directory $(dirname -- "${dst}") does not exist under ${LIVE}"
    cp -a "${src}" "${dst}" || die "copy of ${rel} back to the live export failed"
    sync -f "${dst}" || die "could not flush ${rel} to stable storage; the async export window (recovery.md section 2) applies"
    cmp "${src}" "${dst}" || die "restored ${rel} does not match ${SNAPSHOT}"
    echo "point-restore: restored ${rel} (verified against ${SNAPSHOT})"
done

echo "point-restore OK: ${#COPY_PATHS[@]} path(s) restored from ${SNAPSHOT}"
echo "  inspect the clone, then: zfs unmount ${CLONE_MP} && zfs destroy -r ${CLONE}"
echo "  and before reopening clients, run recovery.md procedure C step 3 (node cache wipe)"
echo "  the pre-restore snapshot is ${PRESERVE}"
