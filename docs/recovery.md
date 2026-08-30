# Disaster recovery

| Field | Value |
|---|---|
| Status | Durability posture and restore runbook for this cluster; pairs with [operations.md](operations.md) |
| Date | 2026-08-27 |

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

Verifiably safe to ignore in any backup plan: caches (next read re-hydrates; culling punches holes, never deletes files) and leases (swept after 300 s regardless). Everything else in this doc exists to protect row 1.

## 2. What survives what

| Disaster | Today | Once section 3 is in place |
|---|---|---|
| spark down, NVMe cache lost | survives (stateless beyond caches) | unchanged |
| `rm` of a model dir, bad download overwrite, engine writing garbage | **total, immediate, no undo** | rollback to last autosnap (minutes) |
| disk(s) beyond pool redundancy, pool destroyed | **total** | replica replay (hours) |
| NAS host dead | **total** | any ZFS box becomes the NAS from the replica |
| site loss (fire, theft, ransomware) | **total** | offsite copy |

One acknowledged-but-not-durable window exists that no snapshot closes: the NAS export is `async` ([operations.md](operations.md)), so the server replies to NFS writes before stable storage, and a NAS crash can lose the last few seconds of writes clients already saw succeed. The hourly snapshot protects what was persisted; it cannot recover bytes that never reached stable storage. A synced export would close the window at ingest-throughput cost; that trade is kept as-is on purpose (operations.md).

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

`scripts/nas/sanoid.conf` is the autosnap + autoprune policy (36 hourly, 30 daily, 3 monthly, `recursive = yes`). Weights are near-immutable and lz4-compressed, so snapshots cost almost nothing; tune counts to spare capacity, then re-copy the file. Recursive is a no-op while `tank/models` has only directories underneath ([operations.md](operations.md)); it is there so a later `zfs create tank/models/gguf` (or similar) is snapshotted without rewriting the backup job.

Replica onto a second machine or external disk (covers pool loss). The unit is a **pull on the replica host**, not a push from the NAS: NAS root must not hold a credential that can `zfs destroy` the copy that exists to survive NAS root. Edit `nas:tank/models` in `syncoid-models.service` to the SSH target for a dedicated replica user, then on that host:

```bash
systemctl daemon-reload
systemctl enable --now syncoid-models.timer
# optional: the same restore drill and hourly age check, with the replica
# dataset named so a stale pull fails the same way a dead sanoid.timer does
systemctl edit --full modelfs-drill.service      # set Environment=MF_DRILL_REPLICA=tank/models
systemctl edit --full modelfs-snap-age.service   # same Environment=
systemctl enable --now modelfs-drill.timer modelfs-snap-age.timer
```

`ExecStartPost` in that unit runs [`scripts/hold_monthlies.sh`](../scripts/hold_monthlies.sh) (`modelfs-hold-monthlies`) to `zfs hold` every `*_monthly` snapshot (`modelfs-dr`) so a recursive destroy cannot take them without an explicit `zfs release`. Already-held is success (yesterday's pull tagged it). Any other hold failure fails the unit: a green pull with no hold is not a replica that survives a fat-finger `zfs destroy -r`. Root on the replica host can still release-and-destroy; a second person or a key that cannot `zfs release` is the remaining control, and is not in this repo. `TimeoutStartSec=infinity` is set on the syncoid and drill services so a host whose systemd still times out Type=oneshot at 90 s cannot kill a multi-hour recv or a `diff -rq` of the live tree.

Offsite: rotate a disk out weekly, or `syncoid` to a hosted ZFS box. The dataset is private; encrypt the transport or the target. Verify the copy's freshness on the same cadence — `zfs list -t snapshot -o name,creation tank/models` on the rotated disk or hosted box, comparing the newest creation to the RPO column. Unlike the local and replica layers, this one has no timer or age alarm in this repo; a stopped rotation is silent until the next site-loss review (section 8).

Failure visibility: a green timer only proves it fired. `OnFailure=notify-admin@%n.service` sits on the **services** (`sanoid.service`, `sanoid-prune.service`, `syncoid-models.service`, `modelfs-drill.service`, `modelfs-drill-log.service`, `modelfs-snap-age.service`), not the timers. A drop-in on `sanoid.timer` would stay green while `sanoid.service` failed to snapshot. Disabling `sanoid.timer` never fails `sanoid.service` at all, so `modelfs-snap-age.timer` (hourly) runs `modelfs-restore-drill --age-only`: newest snapshot older than `MF_DRILL_MAX_SNAP_AGE` (default 25 h) is the alarm. `notify-admin@.service` logs to syslog (`modelfs-backup`); replace ExecStart with the site mailer or webhook when one exists.

Treat these as alarms, not log noise: no new snapshot inside 25 h (`modelfs-snap-age.timer`; the monthly clone is the restore proof, not the schedule watchdog), replica newest snapshot older than 36 h (daily pull plus slack; `MF_DRILL_MAX_REPLICA_AGE`, set `MF_DRILL_REPLICA` on the replica host), `modelfs-check-drill-log` failing (log missing, empty, or older than 35 days).

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

Section 3's replica is a syncoid pull on the replica host, not a stream file. Replay from that host (or from a locally imported replica dataset). `latest.zfsstream` is not an artifact this repo produces.

```bash
# 1. Recreate the pool (vdevs: see open questions). syncoid creates
#    tank/models; do not pre-create it. Properties are set after the pull
#    so they match operations.md section 1 regardless of the replica's.
zpool create tank ...

# 2. Pull onto the new NAS from the replica host (SSH target as in
#    syncoid-models.service, reversed). Time this; it is the pool-loss RTO.
time syncoid --no-privilege-elevation --force-delete replica-host:tank/models tank/models
zfs set mountpoint=/export/models compression=lz4 recordsize=1M \
  atime=off xattr=sa relatime=off \
  sharenfs="rw,async,no_root_squash,no_subtree_check" tank/models

#    If the replica is already imported on this box instead of remote:
#    time zfs send -R tank/models-backup@<newest> | zfs recv -Fs tank/models
#    then the same zfs set ... tank/models

# 3. BEFORE any client remounts: wipe every derived cache,
#    sparks and desktop alike. Non-negotiable after a rollback.
rm -rf /var/cache/modelfs/*        # on every spark
rm -rf /var/cache/fscache/*        # on the desktop

# 4. Remount clients (fstab from operations.md), restart modelfs everywhere
modelfs status                     # pid + peers live again
head -c 16M /models/gguf/some-model.gguf > /dev/null   # smoke-read a real file from the mount
```

Verify against ground truth: checksum a sampled file against the source it came from (HF etag or your own manifest) before declaring done. RTO for this row is `zfs send`/`syncoid` wall time, not the snapshot-clone `clone_s` the monthly drill records (that clone is CoW and does not move the dataset). Fill the number in after the first timed pull; until then the table says "hours".

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

The async-export window (section 2) is not a row here: it is a NAS crash losing acknowledged writes up to the txg interval, and no snapshot RPO recovers bytes that never reached stable storage.

Without section 3 installed and enabled (not merely present in this repo), every row below the first is: RPO unbounded, RTO equals re-download time, and custom-trained adapters and conversions are gone permanently.

## 6. Prove it: monthly restore drill

A backup never restored is a hypothesis. Monthly, on the NAS:

```bash
./scripts/dr_restore_drill.sh tank/models
```

The script ([scripts/dr_restore_drill.sh](../scripts/dr_restore_drill.sh)) picks the newest snapshot by creation time (not name order, where hourly/daily/monthly suffixes would decide), clones it onto a mountpoint that is not the live export (sibling `modelfs-drill`, or `MF_DRILL_CLONE_MP`; a collision with the live tree fails the drill, because that path would checksum production against itself), diffs the restored tree against the live dataset (`MF_DRILL_LIVE` overrides that path; default is the dataset's mountpoint), and checksums one size-stable file on both sides before appending the log line that proves the drill ran. `.cluster` leases and the `.zfs` snapdir are skipped in the file count, the diff, and the sample: a snapshot of only heartbeats is "zero files" and fails. Drift inside the RPO window is counted, never failed; a size-stable file that hashes differently fails the drill, and so does an empty snapshot or a missing snapshot schedule: the "no snapshots" exit is the sanoid.timer alarm. The drill also fails when the newest snapshot is older than `MF_DRILL_MAX_SNAP_AGE` (default 25 h): snapshots that exist but stopped refreshing mean sanoid died after the last green drill, and restoring them would miss the RPO table claims. That age rides the log line as `snap_age_s`, so the RPO column above stays a measured number rather than an assumption. The same age check is `--age-only` (no clone, no log line; a freshness check is not a restore) and is what `modelfs-snap-age.timer` runs hourly, so a disabled `sanoid.timer` pages within 25 h instead of waiting for the next monthly clone. Exit status is the verdict; `MF_DRILL_KEEP=1` leaves the clone mounted for inspection and `MF_DRILL_LOG` relocates the artifact log from `/var/log/modelfs-drill.log`.

The pool-loss copy is not visible to a local `zfs list` when syncoid pulled it to another host. Run the same script on the replica host (or import the replica and set `MF_DRILL_REPLICA`), otherwise the log line records `replica=unchecked`. When `MF_DRILL_REPLICA` is set, a missing dataset, an empty snapshot list, or a replica older than `MF_DRILL_MAX_REPLICA_AGE` (default 36 h, a daily pull plus slack) fails the drill the same way a dead sanoid.timer does. The primary snapshot age bound stays `MF_DRILL_MAX_SNAP_AGE` (default 25 h) so an hourly autosnap that died overnight still fails on the NAS.

`clone_s` is snapshot-clone time for procedure B (CoW, seconds), recorded from `/proc/uptime` so an NTP step during the clone cannot log a negative number. It is not the pool-loss RTO; that is the timed `syncoid`/`zfs send` in procedure C. The log line is the artifact proving the drill ran. Its stamp is UTC (`YYYY-MM-DDTHH:MM:SSZ`), so aging it does not depend on the NAS timezone or a DST fall-back. A snapshot whose ZFS creation is in the future of the host clock fails the drill (the RPO comparison cannot be trusted). `scripts/check_drill_log.sh` (and `modelfs-drill-log.timer`, daily) fails when that newest stamp is missing, empty, unparseable, in the future, or older than 35 days (`MF_DRILL_LOG_MAX_AGE`); that is the alarm, not a grep someone might remember to run. `scripts/test_dr_restore_drill.sh` (also run by `scripts/check.sh`) drives the drill, `--age-only`, `hold_monthlies.sh`, and the log checker through a stub `zfs` so a clone-onto-live, empty-snapshot, stale-log, or swallowed-hold false pass cannot ship.

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
* Timed pool-loss RTO (`syncoid` wall time at current dataset size). `clone_s` in the drill log is not that number.
* Whether `notify-admin@.service` has been replaced with a mailer, or still only writes syslog.
* Offsite-copy freshness: the local (snap-age) and replica (`MF_DRILL_REPLICA`) layers alarm on staleness, but the offsite rotation has no equivalent check in this repo; whether anything outside it alarms on a stopped rotation.
