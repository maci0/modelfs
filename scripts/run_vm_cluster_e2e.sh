#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

usage_no_args "$@" <<'EOF'
Usage: ./scripts/run_vm_cluster_e2e.sh

Four-VM cluster end-to-end: one NFS server VM (the origin) plus three
modelfs client VMs exchanging pieces over libvirt's NAT network. This is
the topology the 9-node loopback test cannot exercise: a real NFS origin
on a separate machine, and real peer-to-peer piece transfers across a
network -- including piece-hash manifest publishing, verified peer fills,
modelfs verify, and the dupes scan.

Needs: passwordless sudo (libvirt system daemon), /dev/kvm (four VMs under
TCG are impractically slow), an x86_64 host (the pinned cloud image and
in-guest Zig toolchain are amd64/x86_64 only), cloud-image-utils
(cloud-localds), ssh, and outbound internet (cloud image download plus
in-VM apt for nfs-kernel-server / fuse3 / nfs-common). ~4 GB disk,
~6-10 minutes.
Run locally, not in CI (same as run_cluster_e2e_9nodes.sh).
EOF

echo "=== 4-VM cluster: NFS server + 3 modelfs clients ==="

cd "${ROOT_DIR}"

# --- prerequisites -----------------------------------------------------
for tool in qemu-img cloud-localds ssh scp virsh curl sha256sum tar git; do
    command -v "${tool}" >/dev/null 2>&1 || fail "missing tool: ${tool}"
done
sudo -n true 2>/dev/null || fail "passwordless sudo required (libvirt system daemon)"
if [[ ! -e /dev/kvm ]]; then
    fail "/dev/kvm not present: four VMs need KVM acceleration (TCG is impractically slow)"
fi
# The cloud image and the in-guest Zig toolchain below are pinned by
# digest to the amd64/x86_64 artifacts; an amd64 guest cannot boot on an
# aarch64 host, so refuse up front instead of failing ten minutes in.
HOST_ARCH="$(uname -m)"
if [[ "${HOST_ARCH}" != "x86_64" ]]; then
    fail "x86_64 host required: the pinned cloud image and Zig toolchain are amd64/x86_64 only"
fi

# --- topology ----------------------------------------------------------
NFS_VM="mfs-e2e-nfs"
C1_VM="mfs-e2e-c1"
C2_VM="mfs-e2e-c2"
C3_VM="mfs-e2e-c3"
VMS=( "${NFS_VM}" "${C1_VM}" "${C2_VM}" "${C3_VM}" )
NFS_IP="192.168.122.10"
C1_IP="192.168.122.11"
C2_IP="192.168.122.12"
C3_IP="192.168.122.13"
declare -A VM_IP=(
    ["${NFS_VM}"]="${NFS_IP}"
    ["${C1_VM}"]="${C1_IP}"
    ["${C2_VM}"]="${C2_IP}"
    ["${C3_VM}"]="${C3_IP}"
)
FILE_SIZE_MB=64
PIECE_SIZE_MB=4
TOTAL_PIECES=$((FILE_SIZE_MB / PIECE_SIZE_MB))

# Clobbering an existing domain would lose its disk state; refuse loudly.
for vm in "${VMS[@]}"; do
    if sudo virsh dominfo "${vm}" >/dev/null 2>&1; then
        fail "libvirt domain '${vm}' already exists; destroy and undefine it first"
    fi
done

# --- cloud image (cached across runs, checksum-verified every run) -----
IMG_DIR="${SCRATCH_DIR}/vmcluster-image"
IMG="${IMG_DIR}/noble-server-cloudimg-amd64.img"
mkdir -p "${IMG_DIR}"
if [[ ! -f "${IMG}" ]]; then
    echo "=== downloading Ubuntu 24.04 cloud image (cached at ${IMG}) ==="
    curl -fL -o "${IMG}.part" "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    mv "${IMG}.part" "${IMG}"
fi
EXPECTED_SHA256="d0fe84bb5f80853425fa6be28e2c106f30104c3cfe8611933f2e65c9b63f0e30"
echo "${EXPECTED_SHA256} *${IMG}" | sha256sum -c - >/dev/null \
    || fail "cloud image ${IMG} failed checksum; delete it to re-download"

# --- scratch -----------------------------------------------------------
TEMP_DIR="$(mktemp -d "${SCRATCH_DIR}/vmcluster-e2e-XXXXXX")"
# VM disks and seed ISOs go under /var/lib/libvirt/images (the standard
# pool): qemu runs as libvirt-qemu, which cannot traverse a user home
# under /home. Work files (keys, seed inputs) stay in the maci-owned
# TEMP_DIR above.
DISK_DIR="$(sudo -n mktemp -d /var/lib/libvirt/images/mfs-e2e-XXXXXX)"
# mktemp creates 0700 root; qemu runs as libvirt-qemu, so the dir must be
# traversable (the files inside are 0644 root-owned, which qemu can read).
sudo chmod 0755 "${DISK_DIR}"
SSH_KEY="${TEMP_DIR}/vmkey"
PSK_FILE="${TEMP_DIR}/modelfs.psk"
PSK_VALUE="clusterpsk_secret_key_1234567890"
echo "${PSK_VALUE}" > "${PSK_FILE}"
chmod 600 "${PSK_FILE}"

cleanup() {
    echo "=== tearing down VMs ==="
    for vm in "${VMS[@]}"; do
        sudo virsh destroy "${vm}" >/dev/null 2>&1 || true
        sudo virsh undefine "${vm}" >/dev/null 2>&1 || true
    done
    sudo rm -rf "${DISK_DIR}"
    rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N "" -f "${SSH_KEY}"
PUBKEY="$(cat "${SSH_KEY}.pub")"

# Ensure the libvirt default NAT network exists and is up (creates it on a
# host where libvirt was never used).
if ! sudo virsh net-info default >/dev/null 2>&1; then
    sudo virsh net-define /dev/stdin >/dev/null <<'EOF'
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp><range start='192.168.122.2' end='192.168.122.254'/></dhcp>
  </ip>
</network>
EOF
    sudo virsh net-start default >/dev/null
    sudo virsh net-autostart default >/dev/null
fi

# --- one disk + cloud-init seed per VM ---------------------------------
# user-data: default cloud user, our key, the VM's packages; the NFS VM
# additionally exports /export/models to the 192.168.122.0/24 fabric.
# network-config: static fabric address so the script knows every IP, with
# the NAT gateway as default route (in-VM apt works, and all VMs see each
# other -- one NIC is both the cluster fabric and the internet path).
make_vm() {
    local name="$1" ip="$2" mac="$3" packages="$4"
    local disk="${DISK_DIR}/${name}.qcow2"
    local seed="${DISK_DIR}/${name}-seed.iso"
    local ud="${TEMP_DIR}/${name}-user-data"
    local nc="${TEMP_DIR}/${name}-network-config"
    sudo qemu-img create -f qcow2 -b "${DISK_DIR}/base.img" -F qcow2 "${disk}" 6G >/dev/null
    {
        echo "#cloud-config"
        echo "hostname: ${name}"
        echo "users:"
        echo "  - default"
        echo "ssh_authorized_keys:"
        echo "  - ${PUBKEY}"
        echo "package_update: true"
        echo "packages:"
        for p in ${packages}; do echo "  - ${p}"; done
        if [[ "${name}" == "${NFS_VM}" ]]; then
            cat <<'RUNC'
runcmd:
  - mkdir -p /export/models
  - chown ubuntu:ubuntu /export/models
  - printf '/export/models 192.168.122.0/24(rw,sync,no_subtree_check,no_root_squash)\n' > /etc/exports
  - exportfs -a
  - systemctl enable --now nfs-server
RUNC
        fi
    } > "${ud}"
    {
        echo "version: 2"
        echo "ethernets:"
        echo "  id0:"
        echo "    match:"
        echo "      macaddress: \"${mac}\""
        echo "    dhcp4: false"
        echo "    addresses: [${ip}/24]"
        echo "    routes:"
        echo "      - to: default"
        echo "        via: 192.168.122.1"
        echo "    nameservers:"
        echo "      addresses: [192.168.122.1]"
    } > "${nc}"
    sudo cloud-localds -N "${nc}" "${seed}" "${ud}" >/dev/null
    sudo virt-install --connect qemu:///system \
        --name "${name}" --memory 2048 --vcpus 2 --osinfo ubuntu24.04 --import \
        --disk "path=${disk},format=qcow2,bus=virtio" \
        --disk "path=${seed},device=cdrom" \
        --network "network=default,model=virtio,mac=${mac}" \
        --noautoconsole --noreboot >/dev/null
}

echo "=== creating 4 VM disks and cloud-init seeds ==="
# The base image is the qcow2 backing file for every VM disk; a copy
# under the pool keeps libvirt-qemu from needing access into .scratch.
sudo cp "${IMG}" "${DISK_DIR}/base.img"
make_vm "${NFS_VM}" "${NFS_IP}" "52:54:00:4d:46:50" "nfs-kernel-server libfuse3-dev curl xz-utils"
make_vm "${C1_VM}" "${C1_IP}" "52:54:00:4d:46:51" "fuse3 libfuse3-3 nfs-common curl"
make_vm "${C2_VM}" "${C2_IP}" "52:54:00:4d:46:52" "fuse3 libfuse3-3 nfs-common curl"
make_vm "${C3_VM}" "${C3_IP}" "52:54:00:4d:46:53" "fuse3 libfuse3-3 nfs-common curl"

echo "=== booting 4 VMs (KVM) ==="
for vm in "${VMS[@]}"; do
    sudo virsh start "${vm}" >/dev/null
done

# --- wait for SSH (bounded; cloud-init then finishes in the background) --
SSH_READY_DEADLINE=$((SECONDS + 180))
for vm in "${VMS[@]}"; do
    while ! ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${VM_IP[$vm]}" true 2>/dev/null; do
        if ((SECONDS >= SSH_READY_DEADLINE)); then
            echo "Error: ${vm} never became reachable over SSH" >&2
            exit 1
        fi
        sleep 2
    done
    echo "✓ ${vm} up"
done

# cloud-init installs packages and (on the NFS VM) sets up the export;
# wait for it to finish so the checks below see a fully provisioned guest.
for vm in "${VMS[@]}"; do
    if ! timeout 300 ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${VM_IP[$vm]}" "cloud-init status --wait >/dev/null 2>&1"; then
        echo "Error: cloud-init did not finish on ${vm}" >&2
        exit 1
    fi
done

echo "=== provisioning ==="
if ! ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${NFS_IP}" "systemctl is-active nfs-server"; then
    echo "Error: NFS server not active on ${NFS_VM}" >&2
    exit 1
fi
echo "✓ NFS server active"

echo "=== building modelfs inside the NFS VM (matches Ubuntu 24.04 fuse3) ==="
# A host-built binary links the host's libfuse3 soname (e.g. .so.4 on
# Arch/CachyOS), which Ubuntu 24.04's libfuse3-3 (.so.3) does not provide.
# Build inside the VM against noble's libfuse3-dev instead: the e2e then
# exercises the same binary configuration the production sparks run.
# Copy exactly the tracked sources (git ls-files, same recipe as
# repro_check.sh) so .zig-cache / host objects cannot ride along, fetch
# zig at minimum_zig_version (sha256-verified), ReleaseFast.
zig_ver="$(sed -n 's/^[[:space:]]*\.minimum_zig_version *= *"\([^"]*\)".*/\1/p' "${ROOT_DIR}/build.zig.zon")"
[[ -n "${zig_ver}" ]] || fail "cannot read minimum_zig_version from build.zig.zon"
# sha256 of the official x86_64-linux tarball for that version; bump with
# minimum_zig_version. A version bump that leaves this digest in place
# fails sha256sum -c instead of running an unverified compiler.
zig_sha256="70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00"
(
    cd "${ROOT_DIR}"
    git ls-files -z | tar --null --ignore-failed-read -T - -czf -
) | ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${NFS_IP}" "mkdir -p /home/ubuntu/src && tar xzf - -C /home/ubuntu/src"
zig_cmd="test -x /home/ubuntu/zig/zig || { mkdir -p /home/ubuntu/zig && curl -fSL -o /home/ubuntu/zig/zig.tar.xz https://ziglang.org/download/${zig_ver}/zig-x86_64-linux-${zig_ver}.tar.xz && echo '${zig_sha256}  /home/ubuntu/zig/zig.tar.xz' | sha256sum -c - && tar -xJ --strip-components=1 -f /home/ubuntu/zig/zig.tar.xz -C /home/ubuntu/zig && rm /home/ubuntu/zig/zig.tar.xz; }"
if ! ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${NFS_IP}" "${zig_cmd}"; then
    echo "Error: could not fetch zig ${zig_ver} into the NFS VM" >&2
    exit 1
fi
build_cmd="cd /home/ubuntu/src && PATH=/home/ubuntu/zig:\$PATH zig build -Doptimize=ReleaseFast"
if ! ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${NFS_IP}" "${build_cmd}"; then
    echo "Error: modelfs build failed inside the NFS VM" >&2
    exit 1
fi
# Share the binary over the origin mount so every client picks it up.
publish_cmd="mkdir -p /export/models/.build && cp /home/ubuntu/src/zig-out/bin/modelfs /export/models/.build/modelfs && chmod 755 /export/models/.build/modelfs"
if ! ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${NFS_IP}" "${publish_cmd}"; then
    echo "Error: could not place the built binary on the origin" >&2
    exit 1
fi
echo "✓ modelfs built in-VM and shared via the NFS origin"

for vm in "${C1_VM}" "${C2_VM}" "${C3_VM}"; do
    ip="${VM_IP[$vm]}"
    if ! ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${ip}" "test -e /dev/fuse && command -v fusermount3"; then
        echo "Error: ${vm} missing /dev/fuse or fusermount3" >&2
        exit 1
    fi
    scp -q -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "${PSK_FILE}" "ubuntu@${ip}:modelfs.psk"
    if ! ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${ip}" "chmod 600 modelfs.psk && mkdir -p cache"; then
        echo "Error: ${vm} could not stage the modelfs.psk" >&2
        exit 1
    fi
    # The origin is real NFS from the separate NFS VM: mount it, then prove
    # the mount is NFS before any daemon starts.
    mount_cmd="sudo mkdir -p /net/origin /models && sudo chown ubuntu:ubuntu /models && sudo mount -t nfs ${NFS_IP}:/export/models /net/origin"
    if ! ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${ip}" "${mount_cmd}"; then
        echo "Error: ${vm} could not mount the NFS origin" >&2
        exit 1
    fi
    fstype="$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${ip}" "findmnt -n -o FSTYPE /net/origin")"
    if [[ "${fstype}" != "nfs"* ]]; then
        echo "Error: ${vm} origin ${fstype} is not NFS" >&2
        exit 1
    fi
    # The binary is built inside the NFS VM and shared over the origin
    # mount (see "building modelfs" above); copy it off the NFS tree now
    # that the mount is up.
    if ! ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${ip}" "cp /net/origin/.build/modelfs modelfs && chmod +x modelfs"; then
        echo "Error: ${vm} could not fetch the built modelfs binary" >&2
        exit 1
    fi
    echo "✓ ${vm} provisioned (origin is ${fstype})"
done



echo "=== starting modelfs on the 3 clients ==="
declare -A CLIENT_ID=( ["${C1_VM}"]="spark1" ["${C2_VM}"]="spark2" ["${C3_VM}"]="spark3" )
for vm in "${C1_VM}" "${C2_VM}" "${C3_VM}"; do
    ip="${VM_IP[$vm]}"
    id="${CLIENT_ID[$vm]}"
    daemon_cmd="nohup /home/ubuntu/modelfs mount /models --origin /net/origin --cache /home/ubuntu/cache --id ${id} --piece ${PIECE_SIZE_MB}M --psk /home/ubuntu/modelfs.psk </dev/null >/home/ubuntu/modelfs.log 2>&1 &"
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${ip}" "${daemon_cmd}"
done

echo "=== waiting for 3 cluster leases on the NFS origin ==="
LEASE_DEADLINE=$((SECONDS + 45))
while :; do
    leases="$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${NFS_IP}" "ls /export/models/.cluster/*.json 2>/dev/null | wc -l")"
    if [[ "${leases}" -ge 3 ]]; then
        break
    fi
    if ((SECONDS >= LEASE_DEADLINE)); then
        echo "Error: only ${leases}/3 peer leases published; dumping client state" >&2
        for vm in "${C1_VM}" "${C2_VM}" "${C3_VM}"; do
            ip="${VM_IP[$vm]}"
            echo "--- ${vm} (${ip}) ---" >&2
            ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${ip}" \
                "pgrep -af modelfs; echo '--- log ---'; tail -30 /home/ubuntu/modelfs.log 2>/dev/null; echo '--- mount ---'; mount | grep -E '/net/origin|/models' || true; echo '--- origin ---'; ls -la /net/origin/.cluster 2>/dev/null || true" >&2
        done
        exit 1
    fi
    sleep 1
done
echo "✓ all 3 clients published leases on the NFS origin"

echo "=== cluster peers from client 1 ==="
PEERS_OUT="$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${C1_IP}" "/home/ubuntu/modelfs peers --origin /net/origin --psk /home/ubuntu/modelfs.psk")"
echo "${PEERS_OUT}"
PEER_ROWS="$(grep -c "spark" <<<"${PEERS_OUT}" || true)"
if [[ "${PEER_ROWS}" -lt 3 ]]; then
    echo "Error: peers listing shows ${PEER_ROWS}/3 nodes" >&2
    exit 1
fi
echo "✓ peers listing shows ${PEER_ROWS} nodes"

echo "=== generating ${FILE_SIZE_MB} MB model on the NFS origin ==="
dd_cmd="dd if=/dev/urandom of=/export/models/big.gguf bs=1M count=${FILE_SIZE_MB} status=none"
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${NFS_IP}" "${dd_cmd}"

echo "=== client 1 reads the model (fills from NFS origin) ==="
if ! ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${C1_IP}" "cmp /models/big.gguf /net/origin/big.gguf"; then
    echo "Error: client 1 read of big.gguf does not match the origin" >&2
    exit 1
fi
echo "✓ client 1 served big.gguf matching origin"

echo "=== waiting for the piece-hash manifest on the origin ==="
MANIFEST_DEADLINE=$((SECONDS + 30))
while :; do
    manifests="$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${NFS_IP}" "ls /export/models/.cluster/manifests/ 2>/dev/null | wc -l")"
    if [[ "${manifests}" -ge 1 ]]; then
        break
    fi
    if ((SECONDS >= MANIFEST_DEADLINE)); then
        echo "Error: no piece-hash manifest published after 30s" >&2
        exit 1
    fi
    sleep 1
done
echo "✓ piece-hash manifest published by client 1 (${manifests} file(s))"

echo "=== clients 2 and 3 read the model (verified peer fills from client 1) ==="
for vm in "${C2_VM}" "${C3_VM}"; do
    ip="${VM_IP[$vm]}"
    if ! ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${ip}" "cmp /models/big.gguf /net/origin/big.gguf"; then
        echo "Error: ${vm} read of big.gguf does not match the origin" >&2
        exit 1
    fi
    echo "✓ ${vm} served big.gguf matching origin"
done

echo "=== verifying peer piece exchange over the network ==="
PEER_FILL_DEADLINE=$((SECONDS + 20))
while :; do
    STATUS_OUT="$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${C2_IP}" "/home/ubuntu/modelfs status --cache /home/ubuntu/cache 2>/dev/null || true")"
    FILLS_PEER="$(python3 -c 'import json,sys; print(int(json.load(sys.stdin)["stats"]["fills_peer"]))' <<<"${STATUS_OUT}" 2>/dev/null || echo 0)"
    if [[ "${FILLS_PEER}" -gt 0 ]]; then
        echo "✓ client 2 filled ${FILLS_PEER} piece(s) from peers (not origin)"
        break
    fi
    if ((SECONDS >= PEER_FILL_DEADLINE)); then
        echo "Error: client 2 reported no peer fills; dumping cluster state" >&2
        for vm in "${C1_VM}" "${C2_VM}" "${C3_VM}"; do
            ip="${VM_IP[$vm]}"
            echo "--- ${vm} (${ip}) status ---" >&2
            ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${ip}" \
                "/home/ubuntu/modelfs status --cache /home/ubuntu/cache 2>/dev/null || echo 'no status'; echo '--- log ---'; tail -20 /home/ubuntu/modelfs.log 2>/dev/null; echo '--- cache ---'; du -sk /home/ubuntu/cache 2>/dev/null || true" >&2
        done
        echo "--- client 1 /have bitmap for big.gguf ---" >&2
        # Read the token on the guest into a 0600 header file; curl takes
        # -H @file so the bearer is not on curl's argv. Expanding
        # Authorization: Bearer $(cat …psk) into -H used to leak it through
        # /proc/<pid>/cmdline (world-readable on the guest, as the ssh
        # command string is on this host).
        have_cmd="printf \"Authorization: Bearer %s\\n\" \"\$(cat /home/ubuntu/modelfs.psk)\" > /home/ubuntu/have.hdr && chmod 600 /home/ubuntu/have.hdr && curl -s -D - -o /dev/null -H @/home/ubuntu/have.hdr \"http://127.0.0.1:18080/have?path=big.gguf\" | head -8; echo; curl -s -H @/home/ubuntu/have.hdr \"http://127.0.0.1:18080/have?path=big.gguf\" | xxd | head -5; rm -f /home/ubuntu/have.hdr"
        ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${C1_IP}" "${have_cmd}" >&2
        exit 1
    fi
    sleep 1
done

echo "=== integrity held across the cluster ==="
for vm in "${C1_VM}" "${C2_VM}" "${C3_VM}"; do
    ip="${VM_IP[$vm]}"
    STATUS_OUT="$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${ip}" "/home/ubuntu/modelfs status --cache /home/ubuntu/cache 2>/dev/null || true")"
    VERIFY_FAIL="$(python3 -c 'import json,sys; print(int(json.load(sys.stdin)["stats"]["fill_err_verify"]))' <<<"${STATUS_OUT}" 2>/dev/null || echo n/a)"
    SERVE_FAIL="$(python3 -c 'import json,sys; print(int(json.load(sys.stdin)["stats"]["serve_verify_fail"]))' <<<"${STATUS_OUT}" 2>/dev/null || echo n/a)"
    if [[ "${VERIFY_FAIL}" != "0" || "${SERVE_FAIL}" != "0" ]]; then
        echo "Error: ${vm} integrity counters nonzero (fill_err_verify=${VERIFY_FAIL}, serve_verify_fail=${SERVE_FAIL})" >&2
        exit 1
    fi
    echo "✓ ${vm} fill_err_verify=0 serve_verify_fail=0"
done

echo "=== modelfs verify on client 2 (cached pieces vs origin manifest) ==="
VERIFY_OUT="$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${C2_IP}" "/home/ubuntu/modelfs verify big.gguf --origin /net/origin --cache /home/ubuntu/cache")"
echo "${VERIFY_OUT}"
if ! grep -q "0 mismatch(es)" <<<"${VERIFY_OUT}"; then
    echo "Error: modelfs verify reported mismatches on client 2" >&2
    exit 1
fi
echo "✓ client 2 cache verifies clean"

echo "=== modelfs dupes --all from client 1 (whole manifest store) ==="
DUPES_OUT="$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${C1_IP}" "/home/ubuntu/modelfs dupes --all --origin /net/origin")"
echo "${DUPES_OUT}"
if ! grep -q "scanned 1 manifest(s), ${TOTAL_PIECES} piece(s) total" <<<"${DUPES_OUT}"; then
    echo "Error: dupes --all did not scan the expected single manifest" >&2
    exit 1
fi
echo "✓ dupes --all scanned the published manifest"

echo "=== cache bounds ==="
for vm in "${C1_VM}" "${C2_VM}" "${C3_VM}"; do
    ip="${VM_IP[$vm]}"
    du_out="$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes "ubuntu@${ip}" "du -sk /home/ubuntu/cache 2>/dev/null | cut -f1")"
    usage_mb=$((du_out / 1024))
    if [[ "${usage_mb}" -gt "${FILE_SIZE_MB}" ]]; then
        echo "Error: ${vm} cache (${usage_mb} MB) exceeds the ${FILE_SIZE_MB} MB file" >&2
        exit 1
    fi
    echo "✓ ${vm} cache ${usage_mb} MB within the ${FILE_SIZE_MB} MB bound"
done

echo "=== 4-VM NFS + 3-client cluster e2e passed ==="
