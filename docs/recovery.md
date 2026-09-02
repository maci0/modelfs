# Disaster recovery

| Field | Value |
|---|---|
| Status | Durability posture and restore runbook for this cluster; pairs with [operations.md](operations.md) |
| Date | 2026-09-02 |

The origin (`tank/models` on the NAS) holds the **only copy** of every weight file. `unlink` and `rename` through the mount land there immediately ([architecture.md](architecture.md)), writes are NFS 1:1 with no write-back buffer, and the snapshot/replica/drill units in `scripts/nas/` do nothing until they are installed on the NAS (section 3). Until those timers are enabled, any disaster past "a cache was lost" costs the whole dataset.

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

Verifiably safe to ignore in any backup plan: caches (next read re-hydrates; culling punches holes, and `reapIdle` unlinks empty unpinned artifacts) and leases (swept after 300 s regardless). Everything else in this doc exists to protect row 1.

## 2. What survives what

| Disaster | Today | Once section 3 is in place |
|---|---|---|
| spark down, NVMe cache lost | survives (stateless beyond caches) | unchanged |
| `rm` of a model dir, bad download overwrite, engine writing garbage | **total, immediate, no undo** | rollback to last autosnap (minutes) |
| disk(s) beyond pool redundancy, pool destroyed | **total** | replica replay (hours) |
| NAS host dead | **total** | any ZFS box becomes the NAS from the replica |
| site loss (fire, theft, ransomware) | **total** | offsite copy |

One acknowledged-but-not-durable window exists that no snapshot closes. The NAS export is
`async` ([operations.md](operations.md)), so the server replies to NFS writes before stable
storage, and a NAS crash can lose the last few seconds of writes clients already saw succeed.

The hourly snapshot protects what was persisted; it cannot recover bytes that never reached
stable storage. A synced export would close the window at ingest-throughput cost, and that trade
is kept as-is on purpose.

Realistic worst case is the third row of the first column, not hardware: one wrong `rm -rf` through `/models` deletes at disk speed and POSIX has no trash can. Snapshots are the soft-delete window.

## 3. Backups (set up once on the NAS)

Three layers, each covering a different disaster: local snapshots (deletions, corruption), a replica off the NAS (pool/host loss), an offsite copy (site loss). Files live in [`scripts/nas/`](../scripts/nas/); [`scripts/install_nas_backup.sh`](../scripts/install_nas_backup.sh) copies them. All commands assume the dataset layout in [operations.md](operations.md).

```bash
dnf install -y epel-release && dnf install -y sanoid   # sanoid ships syncoid
# preview, then write (MF_NAS_DEST=/path prefixes the tree; default is /)
./scripts/install_nas_backup.sh
sudo ./scripts/install_nas_backup.sh --install
```

The installer does not start units. On the NAS, after `dnf install sanoid`:

```bash
systemctl daemon-reload
systemctl enable --now sanoid.timer sanoid-prune.timer
systemctl enable --now modelfs-drill.timer modelfs-drill-log.timer modelfs-snap-age.timer
```

### Layer 1: local snapshots

`scripts/nas/sanoid.conf` is the autosnap and autoprune policy: 36 hourly, 30 daily, 3 monthly,
`recursive = yes`. Weights are near-immutable and lz4-compressed, so snapshots cost almost
nothing; tune the counts to spare capacity, then re-copy the file.

Recursive is a no-op while `tank/models` has only directories underneath
([operations.md](operations.md)). It is there so a later `zfs create tank/models/gguf` is
snapshotted without rewriting the backup job. The replica pull (`syncoid --recursive`) and
`hold_monthlies.sh -r` follow the same growth, and the restore drill age-checks each child, so a
dataset the job never copied cannot look green.

### Layer 2: the replica (covers pool loss)

Onto a second machine or an external disk. The unit is a **pull on the replica host**, not a
push from the NAS: NAS root must not hold a credential that can `zfs destroy` the copy that
exists to survive NAS root.

Override `MF_SYNCOID_SRC` (default `nas:tank/models`) with a drop-in, so a later
`install_nas_backup.sh --install` cannot restore the placeholder. `systemctl edit` writes
`/etc/systemd/system/<unit>.d/override.conf`; `systemctl edit --full` would replace the unit
file the installer copies.

```bash
systemctl edit syncoid-models.service
# [Service]
# Environment=MF_SYNCOID_SRC=replica-user@nas:tank/models
systemctl daemon-reload
systemctl enable --now syncoid-models.timer
# optional: the same restore drill and hourly age check, with the replica
# dataset named so a stale pull fails the same way a dead sanoid.timer does
systemctl edit modelfs-drill.service      # Environment=MF_DRILL_REPLICA=tank/models
systemctl edit modelfs-snap-age.service   # same Environment=
systemctl enable --now modelfs-drill.timer modelfs-snap-age.timer
```

The unit passes `--recursive`, matching `sanoid.conf`. A later `zfs create tank/models/gguf` is
snapshotted on the NAS and must also land on the replica, or pool-loss restore silently drops
the new dataset.

**Holds.** `ExecStartPost` runs [`scripts/hold_monthlies.sh`](../scripts/hold_monthlies.sh)
(`modelfs-hold-monthlies`) to `zfs hold` every `*_monthly` snapshot of the dataset **and its
descendants** under the tag `modelfs-dr`, so a recursive destroy cannot take them without an
explicit `zfs release`. Already-held is success, since yesterday's pull tagged it. Any other
hold failure fails the unit: a green pull with no hold is not a replica that survives a
fat-finger `zfs destroy -r`. Zero snapshots at all also fails, because a replica of nothing
cannot be restored; zero monthlies among other snapshots is success until the first monthly
lands. Root on the replica host can still release and destroy. A second person, or a key that
cannot `zfs release`, is the remaining control, and is not in this repo.

**Unit hardening.** `TimeoutStartSec=infinity` on the syncoid and drill services, so a host
whose systemd still times out `Type=oneshot` at 90 s cannot kill a multi-hour recv or a
`diff -rq` of the live tree. Syncoid's SSH uses `BatchMode=yes` and `ConnectTimeout=30`, so a
missing host key or a blackholed NAS fails the unit (and fires `OnFailure=`) instead of hanging
until infinity. The ZFS units (`syncoid-models`, drill, snap-age, offsite-age) all
`Requires=zfs-import.target`, so a failed pool import does not start a oneshot that can only
fail. `notify-admin@.service` and the read-only age and log alarms are sandboxed
(`ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`, `NoNewPrivileges=yes`) but keep
`/dev` visible: `/dev/log` for the notifier, `/dev/zfs` for the age checks. Syncoid does not set
`ProtectHome=yes`, because its SSH key lives in `/root/.ssh`.

### Layer 3: offsite (covers site loss)

Rotate a disk out weekly, or `syncoid --recursive` to a hosted ZFS box. Same `--recursive` as
the local replica: child datasets must follow. The dataset is private, so encrypt the transport
or the target.

Verify the copy with [`scripts/check_offsite.sh`](../scripts/check_offsite.sh)
(`modelfs-check-offsite`) when the disk is attached, or enable `modelfs-offsite-age.timer` on a
hosted box that always holds the copy, setting `MF_OFFSITE_DATASET` through
`systemctl edit modelfs-offsite-age.service`. There is no live-NAS default on purpose: checking
`tank/models` on the NAS would bless production snapshots as the offsite copy. A newest snapshot
older than `MF_OFFSITE_MAX_AGE` (default 8 days, weekly plus slack) is the alarm, so a stopped
rotation is no longer silent until the next site-loss review.

### Failure visibility

A green timer only proves it fired. `OnFailure=notify-admin@%n.service` therefore sits on the
**services** (`sanoid.service`, `sanoid-prune.service`, `syncoid-models.service`,
`modelfs-drill.service`, `modelfs-drill-log.service`, `modelfs-snap-age.service`,
`modelfs-offsite-age.service`), not the timers: a drop-in on `sanoid.timer` would stay green
while `sanoid.service` failed to snapshot.

Disabling `sanoid.timer` never fails `sanoid.service` at all. That is what
`modelfs-snap-age.timer` covers, running `modelfs-restore-drill --age-only` every hour of
uptime rather than `OnCalendar=hourly`.

The three age watchdogs (`modelfs-snap-age.timer`, `modelfs-drill-log.timer`,
`modelfs-offsite-age.timer`) use `OnBootSec`/`OnUnitActiveSec`, so a DST spring-forward cannot
skip a local hour and a fall-back doubled hour cannot leave a 2 h hole; `Persistent=` is
OnCalendar-only, so those units fire again after reboot through `OnBootSec`. The replica pull
and monthly clone stay calendar events pinned to UTC (`OnCalendar=daily UTC`,
`OnCalendar=monthly UTC`), so a host timezone cannot move them.

`notify-admin@.service` logs to syslog under `modelfs-backup`. Replace its `ExecStart` with the
site mailer or webhook when one exists.

These four are alarms, not log noise:

| Alarm | Threshold | Unit |
|---|---|---|
| No new snapshot on the NAS | 25 h (`MF_DRILL_MAX_SNAP_AGE`) | `modelfs-snap-age.timer`. The monthly clone is the restore proof, not the schedule watchdog |
| Replica newest snapshot stale | 36 h, a daily pull plus slack (`MF_DRILL_MAX_REPLICA_AGE`) | the drill, with `MF_DRILL_REPLICA` set on the replica host |
| Drill log missing, empty, or stale | 35 days | `modelfs-check-drill-log` |
| Offsite newest snapshot stale | 8 days, weekly rotation plus slack | `modelfs-check-offsite` |

Before risky bulk work (`rm -rf` of an old model, big re-download with overwrite, moving datasets), take a named snapshot; it is the pre-run safety net POSIX does not give you:

```bash
zfs snapshot -r tank/models@pre-cleanup-$(date +%Y%m%d)
```

## 4. Restore procedures

In order of likelihood.

### A. A spark or its NVMe died

Nothing to restore. Rebuild the node per the [README](../README.md) quickstart, remount the
origin per [operations.md](operations.md), and start `modelfs`. The cache warms on demand and
leases republish themselves; `--seed` bootstraps `.cluster` if it is empty.

Re-apply any pins. The markers lived under `/var/cache/modelfs/pin/`, so without them the cull
treats every previously pinned file as an ordinary LRU candidate. Before a *planned* cache wipe,
`find /var/cache/modelfs/pin -type f` is the re-pin list; after an unplanned NVMe loss that list
is gone with the disk.

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

Section 3's replica is a syncoid pull on the replica host, not a stream file, so replay from
that host or from a locally imported replica dataset. `latest.zfsstream` is not an artifact this
repo produces.

[`scripts/dr_pool_restore.sh`](../scripts/dr_pool_restore.sh) (`modelfs-pool-restore`) does the
recv, the property set, and the monthly hold. It is dry-run by default; `--execute` pulls.

* `--from` is a `--recursive` syncoid with `BatchMode=yes` and `ConnectTimeout=30`, the same
  fail-closed SSH as the daily pull. `--local-from` is `zfs send -R`, already recursive.
* Holds do not travel with the stream, so after a successful recv the script holds monthlies on
  DEST the same way the replica's `ExecStartPost` does.
* It refuses a mounted DEST unless `--force`, so it cannot `--force-delete` the live export by
  accident.
* It does **not** create the pool, because vdev layout is site-specific, and does not wipe node
  caches, which live on other hosts.

```bash
# 1. Recreate the pool (vdevs: see open questions). syncoid creates
#    tank/models; do not pre-create it. Properties are set after the pull
#    so they match operations.md section 1 regardless of the replica's.
zpool create tank ...

# 2. Pull onto the new NAS from the replica host (SSH target as in
#    syncoid-models.service, reversed). Preview, then execute. recv_s in
#    /var/log/modelfs-pool-restore.log is the pool-loss RTO.
./scripts/dr_pool_restore.sh --from replica-host:tank/models
sudo ./scripts/dr_pool_restore.sh --execute --from replica-host:tank/models

#    If the replica is already imported on this box instead of remote:
#    ./scripts/dr_pool_restore.sh --local-from tank/models-backup
#    sudo ./scripts/dr_pool_restore.sh --execute --local-from tank/models-backup

# 3. BEFORE any client remounts: wipe every derived cache,
#    sparks and desktop alike. Non-negotiable after a rollback.
#    The restore script reprints these commands after a successful recv.
rm -rf /var/cache/modelfs/*        # on every spark
rm -rf /var/cache/fscache/*        # on the desktop

# 4. Remount clients (fstab from operations.md), restart modelfs everywhere
modelfs status                     # pid + peers live again
head -c 16M /models/gguf/some-model.gguf > /dev/null   # smoke-read a real file from the mount
```

Verify against ground truth: checksum a sampled file against the source it came from (HF etag or your own manifest) before declaring done. RTO for this row is `recv_s` from the restore log, not the snapshot-clone `clone_s` the monthly drill records (that clone is CoW and does not move the dataset). Fill the number in after the first timed pull; until then the table says "hours".

### D. Site loss

New hardware, then section C end to end, feeding the offsite copy into `dr_pool_restore.sh --local-from` (imported disk) or `--from` (hosted box) instead of the local replica. Confirm the copy is inside the 8-day bound with `check_offsite.sh` before the recv. Days, dominated by shipping hardware and streaming terabytes.

## 5. RPO / RTO summary

| Disaster | Mechanism | RPO | RTO |
|---|---|---|---|
| spark / cache loss | none needed | 0 | minutes |
| deletion, corruption | hourly autosnap | <= 1 h | minutes |
| pool loss | syncoid replica | <= 24 h | hours |
| NAS host death | replica + any ZFS box | <= 24 h | hours |
| site loss | offsite rotation | <= rotation period | days |

The async-export window (section 2) is not a row here: it is a NAS crash losing acknowledged writes up to the txg interval, and no snapshot RPO recovers bytes that never reached stable storage.

Without section 3 installed and enabled (not merely present in this repo), every row below the first is: RPO unbounded, RTO equals re-download time, and custom-trained adapters and conversions are gone permanently.

## 6. Prove it: monthly restore drill

A backup never restored is a hypothesis. Monthly, on the NAS:

```bash
./scripts/dr_restore_drill.sh tank/models
```

### What the drill does

[`scripts/dr_restore_drill.sh`](../scripts/dr_restore_drill.sh) picks the newest snapshot by
**creation time**, not name order, where hourly/daily/monthly suffixes would decide. It then:

1. Clones it onto a mountpoint that is not the live export (sibling `modelfs-drill`, or
   `MF_DRILL_CLONE_MP`). A collision with the live tree fails the drill, because that path would
   checksum production against itself.
2. Diffs the restored tree against the live dataset (`MF_DRILL_LIVE` overrides that path;
   default is the dataset's mountpoint).
3. Checksums one size-stable file on both sides.
4. Appends the log line that proves the drill ran.

`.cluster` leases and the `.zfs` snapdir are skipped in the file count, the diff, and the
sample, so a snapshot of only heartbeats counts as zero files and fails.

Exit status is the verdict. `MF_DRILL_KEEP=1` leaves the clone mounted for inspection, and
`MF_DRILL_LOG` relocates the artifact log from `/var/log/modelfs-drill.log`.

### What fails it

* A size-stable file that hashes differently. Drift inside the RPO window is counted, never
  failed.
* An empty snapshot, or no snapshots at all: that exit is the `sanoid.timer` alarm.
* A newest snapshot older than `MF_DRILL_MAX_SNAP_AGE` (default 25 h). Snapshots that exist but
  stopped refreshing mean sanoid died after the last green drill, and restoring them would miss
  the RPO table's claims. That age rides the log line as `snap_age_s`, so the RPO column stays a
  measured number rather than an assumption.
* A child dataset under `tank/models` (none today, but a later `zfs create`) with no snapshot or
  one past the same 25 h bound: sanoid recursive stopped covering it. The parent clone is the
  restore proof for today's directory layout; children are the growth alarm.
* A snapshot whose ZFS creation time is in the future of the host clock, since the RPO
  comparison cannot then be trusted.

`--age-only` runs just the age check: no clone, no log line, because a freshness check is not a
restore. That is what `modelfs-snap-age.timer` runs every hour of uptime, so a disabled
`sanoid.timer` pages within 25 h instead of waiting for the next monthly clone.

### Checking the replica too

The pool-loss copy is invisible to a local `zfs list` when syncoid pulled it to another host.
Run the same script on the replica host, or import the replica and set `MF_DRILL_REPLICA`;
otherwise the log line records `replica=unchecked`.

With `MF_DRILL_REPLICA` set, a missing dataset, an empty snapshot list, or a replica older than
`MF_DRILL_MAX_REPLICA_AGE` (default 36 h, a daily pull plus slack) fails the drill the same way
a dead `sanoid.timer` does. The primary bound stays `MF_DRILL_MAX_SNAP_AGE` (25 h), so an hourly
autosnap that died overnight still fails on the NAS.

### The log line, and what checks it

`clone_s` is the snapshot-clone time for procedure B: CoW, so seconds. It is recorded from
`/proc/uptime` so an NTP step during the clone cannot log a negative number, and it is **not**
the pool-loss RTO, which is the timed `syncoid`/`zfs send` in procedure C.

The stamp is UTC (`YYYY-MM-DDTHH:MM:SSZ`), so aging it does not depend on the NAS timezone or a
DST fall-back. [`scripts/check_drill_log.sh`](../scripts/check_drill_log.sh), and
`modelfs-drill-log.timer` every 24 h of uptime, fails when that newest stamp is missing, empty,
unparseable, in the future, or older than 35 days (`MF_DRILL_LOG_MAX_AGE`). That is the alarm,
rather than a grep someone might remember to run.

[`scripts/test_dr_restore_drill.sh`](../scripts/test_dr_restore_drill.sh), also run by
`scripts/check.sh`, drives the drill, `--age-only`, `hold_monthlies.sh`, the log checker,
`check_offsite.sh`, and `dr_pool_restore.sh` through a stub `zfs`, so a clone-onto-live,
empty-snapshot, uncovered-child-dataset, stale-log, swallowed-hold, empty-replica,
stale-offsite, or live-dataset-recv false pass cannot ship.

## 7. Incident access

Restore does not need the cluster PSK (that secret is regenerable; see the inventory). It does need, during the incident:

* NAS root (or a role that can `zfs clone` / `zfs recv` / `zfs set sharenfs`)
* On the replica host: the dedicated syncoid user's key, which must live **on the replica host**, not on the NAS
* The `modelfs-dr` hold tag if a monthly must be rolled back (`zfs release modelfs-dr SNAP` then clone)
* Client fstab and uid 1000 from [operations.md](operations.md), to remount after procedure C

If those keys exist only on the dead NAS, procedure C is blocked. Copy the replica-host key off the NAS before the first incident.

## 8. Open questions (not answerable from this repo)

* Pool topology: mirror, raidz, or single disk? Single disk moves "disk death" into the pool-loss row. Procedure C's `zpool create` needs this answer.
* Is there a second machine or disk that can hold the replica? Section 3 assumes one; pick the SSH target in `syncoid-models.service` before enabling that timer.
* Spare capacity for 69 snapshots at current and growing dataset size.
* Whether anything outside this repo backs up the NAS itself; if so, reconcile retention with sanoid's.
* Timed pool-loss RTO (`recv_s` in `/var/log/modelfs-pool-restore.log` after the first `--execute`). `clone_s` in the drill log is not that number.
* Whether `notify-admin@.service` has been replaced with a mailer, or still only writes syslog.
* Offsite-copy freshness: `check_offsite.sh` and `modelfs-offsite-age.timer` exist in this repo; whether the weekly timer is enabled on a hosted box, or the script is run by hand when the rotated disk is attached, is site-specific.
