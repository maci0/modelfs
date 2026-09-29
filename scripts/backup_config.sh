#!/usr/bin/env bash
# Print the backup stack's effective configuration: the Environment= each
# installed unit would run with, unit file plus drop-in, and whether its
# timer is enabled. The dataset a backup points at (MF_SYNCOID_SRC,
# MF_DRILL_REPLICA, MF_OFFSITE_DATASET) is set on the host with
# `systemctl edit` and lives nowhere else: a replica or offsite host lost
# and rebuilt from this repo comes back with the shipped placeholders, and
# the pull then names a host nobody chose. Capture this output with the
# monthly drill log so the values survive the host they configure.
#
# Read-only: it opens no pool, writes no file, and never starts a unit.
# ROOT is the tree holding etc/systemd/system and etc/sanoid (default /,
# or a staged tree from install_nas_backup.sh --install).
set -euo pipefail

die() {
    echo "backup-config FAIL: $1" >&2
    exit 1
}

print_usage() {
    cat <<'EOF'
Usage: ./scripts/backup_config.sh [ROOT]

Print the ModelFS backup stack's effective configuration, the values that
exist only as systemd drop-ins on the running hosts: for every installed
unit, the Environment= lines systemd would run it with (unit file, then
each drop-in, later overriding earlier), and whether its timer is
enabled. ROOT is the tree holding etc/systemd/system and etc/sanoid
(default /). Lines reading

  MF_*=<placeholder>

are the shipped defaults, not a site value: set them with
`systemctl edit <unit>` and re-run. Exit 0 when the tree holds at least
one backup unit, 1 otherwise.
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

ROOT="${1:-/}"
if [[ "${ROOT}" != "/" ]]; then
    ROOT="${ROOT%/}"
    [[ -n "${ROOT}" ]] || ROOT="/"
fi
UNIT_DIR="${ROOT}/etc/systemd/system"
SANOID_CONF="${ROOT}/etc/sanoid/sanoid.conf"

[[ -d "${UNIT_DIR}" ]] || die "no unit directory at ${UNIT_DIR} (pass the root holding etc/systemd/system)"

# The placeholder syncoid-models.service ships. A pull still carrying it
# names no host: the unit would resolve "nas" from the replica's own ssh
# config, or fail, either way without recording which machine was chosen.
PLACEHOLDERS="nas:tank/models"

UNITS=(
    sanoid.service
    sanoid-prune.service
    syncoid-models.service
    modelfs-drill.service
    modelfs-drill-log.service
    modelfs-snap-age.service
    modelfs-offsite-age.service
)

# Environment= lines in systemd order: the unit file first, then each
# drop-in file sorted by name, a later assignment overriding an earlier
# one. Nothing is quoted out of the value; an unquoted value with a space
# is one systemd would split itself, and this prints what it reads.
effective_env() {
    local unit="$1" file line key
    local -A value=()
    local -a order=()
    for file in "${UNIT_DIR}/${unit}" "${UNIT_DIR}/${unit}.d/"*.conf; do
        [[ -r "${file}" ]] || continue
        while IFS= read -r line; do
            line="${line#"${line%%[![:space:]]*}"}"
            case "${line}" in
                Environment=*) ;;
                *) continue ;;
            esac
            line="${line#Environment=}"
            key="${line%%=*}"
            [[ -n "${key}" && "${line}" == *"="* ]] || continue
            if [[ -z "${value[${key}]+set}" ]]; then
                order+=("${key}")
            fi
            value["${key}"]="${line}"
        done <"${file}"
    done
    for key in "${order[@]}"; do
        printf '%s\n' "${value[${key}]}"
    done
}

# systemctl can only answer for this host; a staged tree has no systemd
# manager, so the enablement of a unit that was never started is unknown
# rather than reported as disabled.
timer_state() {
    local timer="$1"
    if [[ "${ROOT}" != "/" ]] || ! command -v systemctl >/dev/null 2>&1; then
        echo "unknown (no systemd manager for ${ROOT})"
        return 0
    fi
    systemctl is-enabled "${timer}" 2>/dev/null || echo "not enabled"
}

found=0
for unit in "${UNITS[@]}"; do
    if [[ ! -r "${UNIT_DIR}/${unit}" ]]; then
        continue
    fi
    found=1
    timer="${unit%.service}.timer"
    if [[ -r "${UNIT_DIR}/${timer}" ]]; then
        state="$(timer_state "${timer}")"
    else
        state="no timer"
    fi
    echo "${unit} timer=${timer} (${state})"
    env_out="$(effective_env "${unit}")"
    if [[ -z "${env_out}" ]]; then
        echo "  (no Environment=; this unit takes its dataset from the caller)"
        continue
    fi
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        case "${line}" in
            *="${PLACEHOLDERS}")
                echo "  ${line} PLACEHOLDER: not a site value; set it with 'systemctl edit ${unit}' (docs/recovery.md section 3)"
                ;;
            *)
                echo "  ${line}"
                ;;
        esac
    done <<<"${env_out}"
done

if [[ -r "${SANOID_CONF}" ]]; then
    echo "sanoid.conf ${SANOID_CONF}"
    # Dataset headers and the retention knobs beside them: the policy a
    # host's snapshots are actually taken under, which a re-install
    # preserves only because the installer never overwrites this file.
    awk '
        /^[[:space:]]*\[/ { section = $0 }
        /^[[:space:]]*(hourly|daily|weekly|monthly|recursive|autosnap|autoprune|use_template)[[:space:]]*=/ { print "  " section " " $0 }
    ' "${SANOID_CONF}"
fi

if [[ "${found}" -eq 0 ]]; then
    die "no ModelFS backup unit under ${UNIT_DIR}: run scripts/install_nas_backup.sh --install first"
fi

echo
echo "capture this with the drill log; the values it prints are the ones a rebuilt host needs"
