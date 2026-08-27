#!/usr/bin/env bash
# Copy the NAS snapshot/replica/drill units from scripts/nas/ into a
# destination tree. Default is a dry-run (prints the plan, writes nothing).
# --install copies; MF_NAS_DEST relocates the root so tests can land files
# under .scratch and an operator can preview before writing to /.
# Never starts timers: the printed systemctl lines are the operator's.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

print_usage() {
    cat <<'EOF'
Usage: ./scripts/install_nas_backup.sh [--install]

Copy sanoid.conf, OnFailure drop-ins, the replica pull timer, and the
restore-drill timers from scripts/nas/ into MF_NAS_DEST (default /).
Without --install, print the plan and exit 0. Does not enable or start
any unit; run the printed systemctl lines on the NAS and replica host.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_usage
    exit 0
fi

INSTALL=0
if [[ $# -eq 1 && "$1" == "--install" ]]; then
    INSTALL=1
elif [[ $# -gt 0 ]]; then
    print_usage >&2
    exit 2
fi

NAS_DIR="${SCRIPTS_DIR}/nas"
DEST="${MF_NAS_DEST:-/}"
# A dest of / is the live NAS. Anything else is a prefix (tests, preview).
# Strip a trailing slash so joins stay single-slashed, except keep "/" itself.
if [[ "${DEST}" != "/" ]]; then
    DEST="${DEST%/}"
fi

copy_one() {
    local src="$1"
    local rel="$2"
    local dest_path
    if [[ "${DEST}" == "/" ]]; then
        dest_path="/${rel}"
    else
        dest_path="${DEST}/${rel}"
    fi
    if [[ "${INSTALL}" -eq 0 ]]; then
        echo "would copy ${src} -> ${dest_path}"
        return 0
    fi
    mkdir -p "$(dirname "${dest_path}")"
    cp -a "${src}" "${dest_path}"
    echo "copied ${dest_path}"
}

[[ -d "${NAS_DIR}" ]] || {
    echo "install FAIL: ${NAS_DIR} is missing" >&2
    exit 1
}

copy_one "${NAS_DIR}/sanoid.conf" "etc/sanoid/sanoid.conf"
copy_one "${NAS_DIR}/notify-admin@.service" "etc/systemd/system/notify-admin@.service"
copy_one "${NAS_DIR}/drop-ins/sanoid.service.d/fail.conf" "etc/systemd/system/sanoid.service.d/fail.conf"
copy_one "${NAS_DIR}/drop-ins/sanoid-prune.service.d/fail.conf" "etc/systemd/system/sanoid-prune.service.d/fail.conf"
copy_one "${NAS_DIR}/syncoid-models.service" "etc/systemd/system/syncoid-models.service"
copy_one "${NAS_DIR}/syncoid-models.timer" "etc/systemd/system/syncoid-models.timer"
copy_one "${NAS_DIR}/modelfs-drill.service" "etc/systemd/system/modelfs-drill.service"
copy_one "${NAS_DIR}/modelfs-drill.timer" "etc/systemd/system/modelfs-drill.timer"
copy_one "${NAS_DIR}/modelfs-drill-log.service" "etc/systemd/system/modelfs-drill-log.service"
copy_one "${NAS_DIR}/modelfs-drill-log.timer" "etc/systemd/system/modelfs-drill-log.timer"
copy_one "${SCRIPTS_DIR}/dr_restore_drill.sh" "usr/local/sbin/modelfs-restore-drill"
copy_one "${SCRIPTS_DIR}/check_drill_log.sh" "usr/local/sbin/modelfs-check-drill-log"
copy_one "${ROOT_DIR}/docs/recovery.md" "usr/local/share/doc/modelfs/recovery.md"

echo
echo "next, on the NAS (after dnf install sanoid and editing syncoid-models.service's SSH target on the replica host):"
echo "  systemctl daemon-reload"
echo "  systemctl enable --now sanoid.timer sanoid-prune.timer"
echo "  systemctl enable --now modelfs-drill.timer modelfs-drill-log.timer"
echo "next, on the replica host:"
echo "  systemctl enable --now syncoid-models.timer"
echo "  systemctl enable --now modelfs-drill.timer   # with MF_DRILL_REPLICA set"
echo "docs/recovery.md section 3 is the runbook; this script does not start units."
