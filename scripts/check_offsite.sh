#!/usr/bin/env bash
# Freshness check for the site-loss copy of tank/models. Local snapshots
# and the replica already alarm on staleness (modelfs-snap-age.timer,
# MF_DRILL_REPLICA). A weekly disk rotation or hosted offsite box does
# not, so a stopped rotation is otherwise silent until the next
# site-loss review. Run this when the offsite disk is imported, or from
# modelfs-offsite-age.timer on a box that always holds the copy.
set -euo pipefail

die() {
    echo "offsite FAIL: $1" >&2
    exit 1
}

print_usage() {
    cat <<'EOF'
Usage: ./scripts/check_offsite.sh [DATASET]

Fail if the site-loss copy DATASET is missing, has no snapshots, or the
newest is older than MF_OFFSITE_MAX_AGE seconds (default 691200 = 8
days, weekly rotation plus slack). DATASET comes from the operand or
MF_OFFSITE_DATASET; there is no live-NAS default, because checking
tank/models on the NAS would bless production snapshots as the offsite
copy. Exit 0 means the copy is a usable site-loss restore point.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_usage
    exit 0
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" == -* ) ]]; then
    print_usage >&2
    exit 2
fi

DATASET="${1:-${MF_OFFSITE_DATASET:-}}"
if [[ -z "${DATASET}" ]]; then
    die "dataset required: pass DATASET or set MF_OFFSITE_DATASET (the offsite copy, not the live tank/models on the NAS)"
fi

command -v zfs >/dev/null 2>&1 || die "zfs not found; this runs against an imported offsite copy"

MAX_AGE="${MF_OFFSITE_MAX_AGE:-691200}"
case "${MAX_AGE}" in
    '' | *[!0-9]*)
        die "MF_OFFSITE_MAX_AGE must be a whole number of seconds, got '${MAX_AGE}'"
        ;;
    *)
        ;;
esac
# Digit-only is not enough: bash arithmetic treats a leading 0 as octal
# (MF_OFFSITE_MAX_AGE=08 aborts; =010 means 8 seconds). 10# forces
# decimal. 10 digits is ~317 years and stays inside signed 64-bit $(( )).
if [[ "${#MAX_AGE}" -gt 10 ]]; then
    die "MF_OFFSITE_MAX_AGE must be a whole number of seconds, got '${MAX_AGE}'"
fi
MAX_AGE=$((10#${MAX_AGE}))

zfs list -H -o name "${DATASET}" >/dev/null 2>&1 \
    || die "offsite dataset ${DATASET} does not exist (site-loss copy missing or not imported; docs/recovery.md section 3)"

SNAP_LINE="$(zfs list -H -p -t snapshot -o name,creation -s creation "${DATASET}" | tail -n 1)"
SNAP="${SNAP_LINE%%$'\t'*}"
if [[ -z "${SNAP}" ]]; then
    die "offsite ${DATASET} has no snapshots: the rotation or hosted pull never landed a restore point (docs/recovery.md section 3)"
fi
SNAP_CTIME="${SNAP_LINE##*$'\t'}"
case "${SNAP_CTIME}" in
    '' | *[!0-9]*)
        die "offsite newest snapshot creation is not an epoch second: ${SNAP_LINE}"
        ;;
    *)
        ;;
esac
NOW="$(date -u +%s)"
SNAP_AGE=$((NOW - SNAP_CTIME))
if [[ "${SNAP_AGE}" -lt 0 ]]; then
    die "offsite newest snapshot ${SNAP} has creation ${SNAP_CTIME} in the future of now ${NOW}: host clock and ZFS disagree"
fi
if [[ "${SNAP_AGE}" -gt "${MAX_AGE}" ]]; then
    die "offsite newest snapshot ${SNAP} is ${SNAP_AGE}s old, past the ${MAX_AGE}s limit: the site-loss copy stopped keeping restore points inside the claimed RPO (docs/recovery.md sections 3 and 5)"
fi
echo "offsite OK: ${SNAP} age ${SNAP_AGE}s"
