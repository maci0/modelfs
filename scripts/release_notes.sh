#!/usr/bin/env bash
# Print the CHANGELOG.md section for one released version, which is what
# .github/workflows/release.yml attaches as the release's notes. The awk was
# inline in the publish step, where no gate could exercise it: a heading
# shape that stopped matching would have published the wrong section, and
# only an empty result was caught. This is check_release_tag.sh's sibling on
# the same read of the same file, so the tag a release names, the manifest
# version it must equal, and the notes it publishes are one set of strings
# rather than three recipes in three files.
#
# Usage: ./scripts/release_notes.sh VERSION
# Exits 1 when VERSION has no section or its section has no body, so a
# caller writing the output cannot ship an empty release by accident.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
    cat <<'EOF'
Usage: ./scripts/release_notes.sh VERSION

Print the CHANGELOG.md section for VERSION (without its heading) to stdout.
Exit 1 if CHANGELOG.md has no section for VERSION or the section is empty.
Run by .github/workflows/release.yml to build the release notes.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
if [[ $# -ne 1 || "${1:-}" == -* || -z "${1:-}" ]]; then
    usage >&2
    exit 2
fi

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# The heading carries a release date, so match its prefix rather than the
# whole line, and stop at the next `## `: a version's notes are its own
# section, not everything under it.
notes="$(awk -v heading="## [${1}] - " '
    index($0, heading) == 1 { found = 1; next }
    found && /^## / { exit }
    found { print }
' "${ROOT_DIR}/CHANGELOG.md")"

# Command substitution has already dropped the trailing blank lines a
# section ends with, so a body of nothing but whitespace is the empty case.
[[ -n "${notes//[[:space:]]/}" ]] || fail "CHANGELOG.md has no notes for ${1}"
printf '%s\n' "${notes}"
