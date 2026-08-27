# Disaster recovery

| Field | Value |
|---|---|
| Status | Durability posture and restore runbook for this cluster; pairs with [operations.md](operations.md) |
| Date | 2026-08-27 |

The origin (`tank/models` on the NAS) holds the **only copy** of every weight file. `unlink` and `rename` through the mount land there immediately ([architecture.md](architecture.md)), writes are NFS 1:1 with no write-back buffer, and nothing in this repo schedules a snapshot, a replica, or a restore. Until the schedule below exists, any disaster past "a cache was lost" costs the whole dataset.

---

## 1. State inventory

| Where | What | Class | Gone with its host? |
|---|---|---|---|
| `tank/models/hf,gguf,lora` | weights, adapters, HF hub caches | **authoritative, unique** | yes (NAS) |
| `tank/models/.cluster/*.json` | node leases | ephemeral, republish in 10 s | irrelevant |
| `/var/cache/modelfs` (sparks) | pieces, bitfields, `pin/` markers, `status.json` | pieces derived, culled anyway; pins are operator state | no for bytes: re-hydrates from origin. Pins die with the cache dir: re-run `modelfs pin` after any cache loss |
| `/var/cache/fscache` (desktop) | FS-Cache pages | derived | no |
| `/etc/modelfs.psk` (every node) | peer auth secret | regenerable | only with total site loss; regenerate with `openssl rand -hex 32` and redistribute to all nodes |
| `$HOME` HF token | hub auth | not on the origin | re-login |

Verifiably safe to ignore in any backup plan: caches (next read re-hydrates; culling punches holes, never deletes files) and leases (swept after 300 s regardless). Everything else in this doc exists to protect row 1.

## 2. What survives what

| Disaster | Today | Once section 3 is in place |
|---|---|---|
| spark down, NVMe cache lost | survives (stateless beyond caches) | unchanged |
| `rm` of a model dir, bad download overwrite, engine writing garbage | **total, immediate, no undo** | rollback to last autosnap (minutes) |
| disk(s) beyond pool redundancy, pool destroyed | **total** | replica replay (hours) |
| NAS host dead | **total** | any ZFS box becomes the NAS from the replica |
| site loss (fire, theft, ransomware) | **total** | offsite copy |

Realistic worst case is the third row of the first column, not hardware: one wrong `rm -rf` through `/models` deletes at disk speed and POSIX has no trash can. Snapshots are the soft-delete window.

## 3. Backups (set up once on the NAS)

Three layers, each covering a different disaster: local snapshots (deletions, corruption), a replica off the NAS (pool/host loss), an offsite copy (site loss). All commands assume the dataset layout in [operations.md](operations.md).

```bash
dnf install -y epel-release && dnf install -y sanoid   # sanoid ships syncoid
```

`/etc/sanoid/sanoid.conf`: tiered autosnap + autoprune in one place. Weights are near-immutable and lz4-compressed, so snapshots cost almost nothing; tune counts to spare capacity.

```ini
[tank/models]
        use_template = production

[template_production]
        hourly = 36
        daily = 30
        monthly = 3
        autosnap = yes
        autoprune = yes
```

```bash
systemctl enable --now sanoid.timer
```

Replica onto a second machine or external disk (covers pool loss; run as its own user/key so NAS root alone cannot destroy both copies, and `zfs hold` the monthlies on the target against ransomware):

```bash
syncoid tank/models backup@backup-host:tank/models    # from the NAS, via timer
```

Offsite: rotate a disk out weekly, or `syncoid` to a hosted ZFS box. The dataset is private; encrypt the transport or the target.

Failure visibility: a green exit code proves nothing. Give the timers teeth:

```ini
# /etc/systemd/system/sanoid.timer.d/fail.conf
[Unit]
# The target unit must exist on the NAS, or the failure notification has
# nowhere to go; name your existing email/webhook notifier if there is one.
OnFailure=notify-admin@%n.service
```

and treat these as alarms, not log noise: no new snapshot in the last hour
(the monthly drill enforces a coarser 25 h bound in section 6, so a dead
timer surfaces within one drill cycle at the latest), replica dataset size
frozen on a day with known downloads, drill log (section 6) stale.

The same drop-in belongs on whichever timer runs the `syncoid` replica above:
a replica that dies silently leaves section 5's pool-loss row depending on a
copy nobody knows stopped updating.

Before risky bulk work (`rm -rf` of an old model, big re-download with overwrite, moving datasets), take a named snapshot; it is the pre-run safety net POSIX does not give you:

```bash
zfs snapshot -r tank/models@pre-cleanup-$(date +%Y%m%d)
```

## 4. Restore procedures

In order of likelihood.

### A. A spark or its NVMe died

Nothing to restore. Rebuild per [architecture.md](architecture.md) (Run), remount the origin per [operations.md](operations.md), start `modelfs`. Cache warms on demand. Leases republish themselves; `--seed` bootstraps `.cluster` if it is empty. Re-apply any pins: the markers lived under `/var/cache/modelfs/pin/`, so without them the cull treats every previously pinned file as an ordinary LRU candidate. Before a planned cache wipe, `find /var/cache/modelfs/pin -type f` is the re-pin list; after an unplanned NVMe loss that list is gone with the disk.

### B. Files deleted or corrupted (point in time)

Stop engines reading those paths first: vLLM holds file handles, and copying under a live reader serves it torn bytes.

Clone the newest snapshot onto a mountpoint that is **not** the live export. `tank/models` is mounted at `/export/models` ([operations.md](operations.md)); a clone without `-o mountpoint=` inherits that path, so `cp` would read the still-mounted production tree rather than the snapshot.

```bash
SNAP=$(zfs list -H -p -t snapshot -o name -s creation tank/models | tail -n 1)
zfs clone -o mountpoint=/export/modelfs-recover "${SNAP}" tank/recover
cp -a /export/modelfs-recover/gguf/broken-model.gguf /export/models/gguf/
zfs unmount tank/recover && zfs destroy tank/recover
```

RPO equals the autosnap interval (1 h in the config above). After any copy-back that rewinds bytes, wipe node caches as in section C step 3: the stale-piece rule would otherwise keep serving pre-restore data.

### C. Pool or NAS dead

Order matters. The trap: node caches may hold pieces **newer** than the restored snapshot, and the stale-piece rule (cache keeps bytes until cull or size change, [architecture.md](architecture.md)) would serve post-rollback data over restored data.

```bash
# 1. Recreate the pool and export exactly as operations.md section 1
zfs create -o mountpoint=/export/models -o compression=lz4 \
  -o recordsize=1M -o atime=off -o xattr=sa -o relatime=off tank/models
zfs set sharenfs="..." tank/models

# 2. Replay the replica (latest snapshot first, then older increments)
zfs recv -Fs tank/models < latest.zfsstream

# 3. BEFORE any client remounts: wipe every derived cache,
#    sparks and desktop alike. Non-negotiable after a rollback.
rm -rf /var/cache/modelfs/*        # on every spark
rm -rf /var/cache/fscache/*        # on the desktop

# 4. Remount clients (fstab from operations.md), restart modelfs everywhere
modelfs status                     # pid + peers live again
head -c 16M /models/gguf/some-model.gguf > /dev/null   # smoke-read a real file from the mount
```

Verify against ground truth, not vibes: checksum a sampled file against the source it came from (HF etag or your own manifest) before declaring done. RTO is dominated by `zfs recv` throughput; measure it in the drill and keep the number here.

### D. Site loss

New hardware, then section C end to end, feeding `zfs recv` from the offsite copy instead of the local replica. Days, dominated by shipping hardware and streaming terabytes.

## 5. RPO / RTO summary

| Disaster | Mechanism | RPO | RTO |
|---|---|---|---|
| spark / cache loss | none needed | 0 | minutes |
| deletion, corruption | hourly autosnap | <= 1 h | minutes |
| pool loss | syncoid replica | <= 24 h | hours |
| NAS host death | replica + any ZFS box | <= 24 h | hours |
| site loss | offsite rotation | <= rotation period | days |

Without section 3, every row below the first is: RPO unbounded, RTO equals re-download time, and custom-trained adapters and conversions are gone permanently.

## 6. Prove it: monthly restore drill

A backup never restored is a hypothesis. Monthly, on the NAS:

```bash
./scripts/dr_restore_drill.sh tank/models
```

The script ([scripts/dr_restore_drill.sh](../scripts/dr_restore_drill.sh)) picks the newest snapshot by creation time (not name order, where hourly/daily/monthly suffixes would decide), clones it onto a mountpoint that is not the live export (sibling `modelfs-drill`, or `MF_DRILL_CLONE_MP`; a collision with the live tree fails the drill, because that path would checksum production against itself), diffs the restored tree against the live dataset (`MF_DRILL_LIVE` overrides that path; default is the dataset's mountpoint), and checksums one size-stable file on both sides before appending the log line that proves the drill ran. `.cluster` leases and the `.zfs` snapdir are skipped in the file count, the diff, and the sample: a snapshot of only heartbeats is "zero files" and fails. Drift inside the RPO window is counted, never failed; a size-stable file that hashes differently fails the drill, and so does an empty snapshot or a missing snapshot schedule: the "no snapshots" exit is the sanoid.timer alarm. The drill also fails when the newest snapshot is older than `MF_DRILL_MAX_SNAP_AGE` (default 25 h): snapshots that exist but stopped refreshing mean sanoid died after the last green drill, and restoring them would miss the RPO table claims. That age rides the log line as `snap_age_s`, so the RPO column above stays a measured number rather than an assumption. Exit status is the verdict; `MF_DRILL_KEEP=1` leaves the clone mounted for inspection and `MF_DRILL_LOG` relocates the artifact log from `/var/log/modelfs-drill.log`.

The pool-loss copy is not visible to a local `zfs list` when syncoid pushed it to another host. Run the same script on the replica host (or import the replica and set `MF_DRILL_REPLICA`), otherwise the log line records `replica=unchecked`. When `MF_DRILL_REPLICA` is set, a missing dataset, an empty snapshot list, or a replica older than `MF_DRILL_MAX_SNAP_AGE` fails the drill the same way a dead sanoid.timer does.

The timed clone is the measured restore rate that keeps the RTO row honest (elapsed from `/proc/uptime`, so an NTP step during the clone cannot log a negative RTO); the log line is the artifact proving the drill ran. Its stamp is UTC (`YYYY-MM-DDTHH:MM:SSZ`), so aging it does not depend on the NAS timezone or a DST fall-back. A snapshot whose ZFS creation is in the future of the host clock fails the drill (the RPO comparison cannot be trusted). Alert when the newest entry ages past 35 days. `scripts/test_dr_restore_drill.sh` (also run by `scripts/check.sh`) drives the drill through a stub `zfs` so a clone-onto-live or empty-snapshot false pass cannot ship.

## 7. Open questions (not answerable from this repo)

* Pool topology: mirror, raidz, or single disk? Single disk moves "disk death" into the pool-loss row.
* Is there a second machine or disk that can hold the replica? Section 3 assumes one; pick the target before enabling timers.
* Spare capacity for 69 snapshots at current and growing dataset size.
* Whether anything outside this repo backs up the NAS itself; if so, reconcile retention with sanoid's.
