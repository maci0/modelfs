# ZFS + NFS + FS-Cache

| Field | Value |
|---|---|
| Status | Ops runbook for this cluster; pairs with [peer-cache.md](peer-cache.md) |
| Date | 2026-08-22 |

NAS (Rocky/RHEL) exports `tank/models`. Desktop (Arch/Cachy) mounts it at `/models` with `cachefilesd`. Sparks (Ubuntu/DGX) mount it at `/net/192.168.0.100/models` **without** `fsc`; `modelfs` FUSE owns `/models`. UID **1000**, mode **755**.

```mermaid
flowchart LR
  NAS["Rocky NAS :2049"] --> spark["Ubuntu/DGX sparks"]
  NAS --> desk["Arch/Cachy desktop"]
```

---

## 1. NAS (Rocky)

```bash
dnf install -y nfs-utils
systemctl enable --now nfs-server rpcbind

zfs create -o mountpoint=/export/models -o compression=lz4 \
  -o recordsize=1M -o atime=off -o xattr=sa -o relatime=off tank/models

# Linux sharenfs = exports(5) flags, not Solaris rw=host
zfs set sharenfs="rw,async,no_root_squash,no_subtree_check" tank/models
exportfs -v
showmount -e localhost

firewall-cmd --permanent --add-service={nfs,rpc-bind,mountd}
firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=192.168.0.0/24 service name=nfs accept'
firewall-cmd --reload
```

`*` on `showmount` is world-writable as root. The rich rule limits NFS to `192.168.0.0/24`. Or `sharenfs=off` and `/etc/exports`:

```
/export/models  192.168.0.0/24(rw,async,no_root_squash,no_subtree_check)
```

`ss -lntp | grep 2049` on the client-facing NIC. SELinux `EACCES`: `setsebool -P nfs_export_all_rw 1`. `dedup=off`. LoRAs share one base; copies use `cp --reflink=auto`.

---

## 2. Clients

### Desktop (Arch/Cachy): NFS at `/models` + cachefilesd

```bash
pacman -S nfs-utils
paru -S cachefilesd
modprobe cachefiles
systemctl enable --now nfs-client.target cachefilesd
```

```
# /etc/fstab
192.168.0.100:/export/models  /models  nfs  vers=4.2,nconnect=8,rsize=1048576,wsize=1048576,soft,timeo=30,retrans=2,noatime,nosharecache,fsc,_netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=15  0  0
```

### Sparks (Ubuntu/DGX): NFS origin, no fsc

`modelfs` replaces cachefilesd. Origin must not use `fsc`.

```bash
apt-get install -y nfs-common fuse3
```

```
# /etc/fstab
192.168.0.100:/export/models  /net/192.168.0.100/models  nfs4  vers=4.2,nconnect=8,rsize=1048576,wsize=1048576,soft,timeo=30,retrans=2,noatime,nosharecache,_netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=15  0  0
```

```bash
sudo mkdir -p /net/192.168.0.100/models /models /var/cache/modelfs
sudo chown 1000:1000 /net/192.168.0.100/models /models /var/cache/modelfs
```

Then [peer-cache.md](peer-cache.md). No autofs package; `/net/...` is just a directory name.

`soft` + `nofail` + automount: boot cannot hang. `hard` waits forever. `timeo` is tenths of a second.

On the **origin** (desktop `/models` or spark `/net/.../models`), after it is mounted:

```bash
chown 1000:1000 /net/192.168.0.100/models   # or /models on desktop
chmod 755 /net/192.168.0.100/models
mkdir -p /net/192.168.0.100/models/hf/{hub,datasets,xet} \
         /net/192.168.0.100/models/gguf /net/192.168.0.100/models/lora
chown -R 1000:1000 /net/192.168.0.100/models/hf \
                   /net/192.168.0.100/models/gguf \
                   /net/192.168.0.100/models/lora
```

Download as uid 1000, not sudo. `nobody:nobody`: `sysctl -w nfs.nfs4_disable_idmapping=1`.

Desktop: `pgrep -a cachefilesd` must show a process. `findmnt /models | grep fsc`. Default `dir /var/cache/fscache`. `iflag=direct` skips FS-Cache. Cull is LRU at ~7% free.

Mount stuck: `umount -l` the mountpoint. `timeout 5 bash -c "echo >/dev/tcp/192.168.0.100/2049"` (firewall) vs `timeout 10 showmount -e 192.168.0.100`.

---

## 3. Hugging Face

```
/models/hf/hub         HF_HUB_CACHE
/models/hf/datasets    HF_DATASETS_CACHE
/models/hf/xet         HF_XET_CACHE
/models/gguf/          llama.cpp
/models/lora/          adapters
```

On sparks those paths are the FUSE `/models` (bytes from NVMe/peers/NFS). On the desktop they are the NFS mount.

Token stays in `$HOME`. Triton / inductor / CUDA / vLLM compile caches stay local.

`/etc/profile.d/models-hf.sh` (systemd needs the same `Environment=`):

```bash
export HF_HUB_CACHE=/models/hf/hub
export HF_DATASETS_CACHE=/models/hf/datasets
export HF_XET_CACHE=/models/hf/xet
export HF_HUB_ENABLE_HF_TRANSFER=1
export LLAMA_CACHE=/models/gguf
export TRITON_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/triton"
export TORCHINDUCTOR_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/torchinductor"
```

Do **not** set `XDG_CACHE_HOME=/models`; that dumps pip and browsers onto NFS. llama.cpp `-hf` uses **`LLAMA_CACHE`**, not `HF_HUB_CACHE` (default is `~/.cache/llama.cpp`).

```bash
source /etc/profile.d/models-hf.sh

# llama.cpp: download into LLAMA_CACHE then run
llama-cli -hf bartowski/Llama-3.2-3B-Instruct-GGUF:Q8_0
llama-server -hf bartowski/Llama-3.2-3B-Instruct-GGUF:Q8_0
llama-server --cache-list    # what is already in LLAMA_CACHE

# or a normal file (also via hf)
hf download bartowski/Llama-3.2-3B-Instruct-GGUF --include '*Q8_0*.gguf' --local-dir /models/gguf/llama-3.2-3b
llama-server -m /models/gguf/llama-3.2-3b/*.Q8_0.gguf

hf download meta-llama/Meta-Llama-3-70B-Instruct
vllm serve meta-llama/Meta-Llama-3-70B-Instruct
```

One node downloads a repo at a time. Docker/enroot: `-e` those vars, bind `/models`.

---

## 4. Failures

| Symptom | Cause |
|---|---|
| boot hang | missing `nofail`/`automount`, or `hard` |
| `active (exited)` cachefilesd | Ubuntu `RUN=no` |
| every read hits NAS | no `fsc` or daemon dead |
| cannot write | not uid 1000, or sudo-created files |
| `nobody:nobody` | idmap; disable nfs4 idmapping |
| NAS down | `soft` → `EIO`; automount waits ≤15s |
