#!/usr/bin/env bash
# Daily alarm for the monthly restore drill's artifact log. A green
# sanoid.timer or a clone that never appended a line is not proof the
# drill ran; this script fails when the newest UTC stamp in the log is
# missing, unparseable, in the future of the host clock, or older than
# MF_DRILL_LOG_MAX_AGE (default 35 days). Pair with the systemd unit in
# scripts/nas/modelfs-drill-log.service so a missed month pages.
#
# The record is a drill line, not the last non-empty line. The installer
# used to tell the operator to keep modelfs-backup-config's output in
# this same file, and that output's last line is prose, not a UTC stamp.
# Aging the newest non-empty line then fails every day until someone
# edits the log, which is how an alarm that pages constantly gets
# silenced. A line counts only when its first field is the UTC stamp the
# drill writes and the rest of the line contains " ok ".
set -euo pipefail

die() {
    echo "drill-log FAIL: $1" >&2
    exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: ./scripts/check_drill_log.sh

Fail if the restore-drill artifact log is missing, empty, unparseable,
stamped in the future, or older than MF_DRILL_LOG_MAX_AGE seconds
(default 3024000 = 35 days). MF_DRILL_LOG relocates the log (default
/var/log/modelfs-drill.log). A drill record is a line whose first
field is a UTC stamp and whose remainder contains " ok "; other lines
(an older backup-config capture appended to this file) are skipped.
Exit 0 means the newest such record is inside that window. A file whose
newest line is not a drill record still passes when an earlier record
is fresh.
EOF
    exit 0
fi
if [[ $# -gt 0 ]]; then
    echo "Usage: ./scripts/check_drill_log.sh" >&2
    exit 2
fi

LOG_FILE="${MF_DRILL_LOG:-/var/log/modelfs-drill.log}"
MAX_AGE="${MF_DRILL_LOG_MAX_AGE:-3024000}"
case "${MAX_AGE}" in
    '' | *[!0-9]*)
        die "MF_DRILL_LOG_MAX_AGE must be a whole number of seconds, got '${MAX_AGE}'"
        ;;
    *)
        ;;
esac
# Digit-only is not enough: bash [[ -gt ]] treats a leading 0 as octal
# (MF_DRILL_LOG_MAX_AGE=08 aborts "value too great for base"; =010 means
# 8 seconds). 10# forces decimal. 10 digits is ~317 years, above every
# age knob here, and stays inside signed 64-bit $(( )).
if [[ "${#MAX_AGE}" -gt 10 ]]; then
    die "MF_DRILL_LOG_MAX_AGE must be a whole number of seconds, got '${MAX_AGE}'"
fi
MAX_AGE=$((10#${MAX_AGE}))

if [[ ! -e "${LOG_FILE}" ]]; then
    die "drill log ${LOG_FILE} is missing: the monthly restore drill has never written an artifact (docs/recovery.md section 6)"
fi
if [[ ! -f "${LOG_FILE}" ]]; then
    die "drill log ${LOG_FILE} is not a regular file"
fi
if [[ ! -s "${LOG_FILE}" ]]; then
    die "drill log ${LOG_FILE} is empty: the monthly restore drill has no successful run recorded"
fi

# Newest drill record, not newest line. An older install told the
# operator to append backup_config.sh's capture here, and that capture
# ends in prose; treating that line as the record makes the daily alarm
# fail until an operator deletes it. A line counts only when it is the
# stamp-plus-" ok " record the drill appends.
LINE="$(awk '
    NF && $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ && index($0, " ok ") {
        line = $0
    }
    END { print line }
' "${LOG_FILE}")"
if [[ -z "${LINE}" ]]; then
    die "drill log ${LOG_FILE} has no drill record (a UTC stamp followed by \" ok \"): the monthly restore drill has no successful run recorded"
fi

STAMP="${LINE%% *}"
case "${STAMP}" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
        ;;
    *)
        die "newest drill record is not a UTC stamp (YYYY-MM-DDTHH:MM:SSZ): ${LINE}"
        ;;
esac

# GNU date is required: BSD/macOS date uses -j -f instead of -d and rejects
# %s. This host (Rocky/RHEL, Ubuntu CI) ships GNU date; probe early so a
# different host fails with a named fix instead of a cryptic parse error.
if ! date -u -d "1970-01-01T00:00:00Z" +%s >/dev/null 2>&1; then
    ver="$(date --version 2>/dev/null | head -1 || echo BSD date)"
    die "GNU date is required (need date -u -d and %s); this host has ${ver}"
fi
STAMP_EPOCH="$(date -u -d "${STAMP}" +%s)" || die "cannot parse stamp ${STAMP} as UTC"
NOW="$(date -u +%s)"
AGE=$((NOW - STAMP_EPOCH))
if [[ "${AGE}" -lt 0 ]]; then
    die "newest drill log stamp ${STAMP} is in the future of now ${NOW}: host clock and the log disagree"
fi
if [[ "${AGE}" -gt "${MAX_AGE}" ]]; then
    die "newest drill log entry is ${AGE}s old, past the ${MAX_AGE}s limit: the monthly restore drill has not succeeded recently (docs/recovery.md section 6)"
fi
echo "drill-log OK: ${STAMP} (${AGE}s ago)"
