#!/usr/bin/env bash
# Assert the pushed tag names the version in build.zig.zon, and print that
# version. .github/workflows/release.yml's three build/publish steps run this
# instead of each repeating the sed-and-compare recipe inline, where no gate
# could shellcheck or exercise it. scripts/check.sh reads the same version
# through zon_version in lib.sh, so the tag check and the changelog gate
# cannot be looking at different strings.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage_no_args "$@" <<'EOF'
Usage: ./scripts/check_release_tag.sh [TAG]

Fail unless TAG (or GITHUB_REF_NAME when no operand is given) is the
build.zig.zon version prefixed with "v"; print that version on success.
Run by .github/workflows/release.yml before a release is published.
EOF

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

tag="${1:-${GITHUB_REF_NAME:-}}"
[[ -n "${tag}" ]] || fail "no tag given and GITHUB_REF_NAME is unset"

version="$(zon_version)"
if [[ "${tag}" != "v${version}" ]]; then
    fail "tag ${tag} does not name build.zig.zon version v${version}"
fi
printf '%s\n' "${version}"
