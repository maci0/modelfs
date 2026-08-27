#!/usr/bin/env bash
# Debian/Ubuntu CI helper: install libfuse3 headers with retries for flaky
# apt mirrors. .github/workflows/ci.yml's check and reproducibility jobs
# both run this so the recipe cannot drift apart. Not a general provisioner
# (Fedora/RHEL: fuse3-devel; see CONTRIBUTING.md).
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: ./scripts/install_libfuse3_dev.sh

Install libfuse3-dev via apt-get, retrying a failed update/install up to
three times. Used by CI; locally, install libfuse3-dev / fuse3-devel from
your package manager (CONTRIBUTING.md).
EOF
    exit 0
fi
if [[ $# -gt 0 ]]; then
    echo "Usage: ./scripts/install_libfuse3_dev.sh" >&2
    exit 2
fi

command -v apt-get >/dev/null 2>&1 || {
    echo "FAIL: apt-get not found; this helper is Debian/Ubuntu CI only" >&2
    exit 1
}
command -v sudo >/dev/null 2>&1 || {
    echo "FAIL: sudo not found; cannot install libfuse3-dev" >&2
    exit 1
}

# Put DEBIAN_FRONTEND on the sudo command line: sudo resets the environment
# by default, so a step-level export never reaches apt and a tzdata/needrestart
# prompt would hang the job until timeout.
apt_cmd=(sudo -n env DEBIAN_FRONTEND=noninteractive apt-get)

ok=0
for attempt in 1 2 3; do
    if "${apt_cmd[@]}" update && "${apt_cmd[@]}" install -y --no-install-recommends libfuse3-dev; then
        ok=1
        break
    fi
    echo "apt-get failed (attempt ${attempt}/3); retrying" >&2
    sleep $((attempt * 5))
done
if [[ "${ok}" -ne 1 ]]; then
    echo "FAIL: could not install libfuse3-dev after 3 attempts" >&2
    exit 1
fi
