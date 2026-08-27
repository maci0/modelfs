#!/usr/bin/env bash
# Hold every *_monthly snapshot of DATASET with tag modelfs-dr so a
# recursive zfs destroy cannot take them without an explicit zfs release.
# Already-held is success (the previous pull tagged it). Any other hold
# failure is an alarm: the pool-loss copy's fat-finger hold is missing.
# Invoked as ExecStartPost from scripts/nas/syncoid-models.service.
set -euo pipefail

die() {
    echo "hold FAIL: $1" >&2
    exit 1
}

print_usage() {
    cat <<'EOF'
Usage: ./scripts/hold_monthlies.sh [DATASET]

Hold every *_monthly snapshot of DATASET (default tank/models) with
tag modelfs-dr. Already-held is success. Any other hold failure exits 1.
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

TAG="modelfs-dr"
DATASET="${1:-tank/models}"
command -v zfs >/dev/null 2>&1 || die "zfs not found; this runs on the replica host"

zfs list -H -o name "${DATASET}" >/dev/null 2>&1 \
    || die "dataset ${DATASET} does not exist on this host"

LIST="$(zfs list -H -t snapshot -o name "${DATASET}")" || die "cannot list snapshots of ${DATASET}"
HELD=0
while IFS= read -r snap; do
    [[ -n "${snap}" ]] || continue
    case "${snap}" in
        *_monthly)
            # Tag already present is the rerun case (yesterday's
            # ExecStartPost). Any other hold error is real.
            rc=0
            out="$(zfs hold "${TAG}" "${snap}" 2>&1)" || rc=$?
            if [[ "${rc}" -eq 0 ]]; then
                echo "hold: ${snap} ${TAG}"
            elif zfs holds -H "${snap}" | awk -F '\t' -v tag="${TAG}" '$2 == tag { found=1 } END { exit !found }'; then
                echo "hold: ${snap} already ${TAG}"
            else
                echo "hold FAIL: ${out}" >&2
                die "cannot hold ${snap}"
            fi
            HELD=$((HELD + 1))
            ;;
        *)
            ;;
    esac
done <<<"${LIST}"
echo "hold OK: ${HELD} monthly snapshot(s) of ${DATASET} tagged ${TAG}"
