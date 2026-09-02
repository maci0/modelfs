# Changelog

## [Unreleased]

Work since `v0.5.0`. Upgrading a node or a script written against that tag:
start at **Upgrade from v0.5.0** below. The binary still prints `0.5.0`
until the next tag.

### FUSE unlink retry of a gone file is success - 2026-09-02
- **`Store.unlinkOrigin` treats ENOENT as success.** `mkdir` of an existing
  directory and `rmdir` of a gone directory already converged so a FUSE
  retry after a lost reply did not fail `EEXIST`/`ENOENT`; `unlink` still
  returned the origin errno, so the same retry failed `ENOENT` after the
  file was already gone. A directory at that name stays `EISDIR`. Cache
  identity still drops on every call, including the already-gone retry,
  so a same-size recreate cannot serve the deleted file's bytes.

### Peer goodput samples ignore sub-resolution clock ticks - 2026-09-02
- **A piece fetch whose elapsed time is 1 ns no longer records ~10 PB/s.** `rangeBps` already returned 0 for a same-ns tick (which pulled the EWMA toward a dead path). A 1 ns tick on a 16 MiB piece is finite (~1.7e16 B/s) and pulled the EWMA the other way, so `pickBest` stuck on that path until tens of real samples decayed it. Samples above 1 TB/s now keep the prior, like a non-positive interval.


### Upgrade from v0.5.0 - 2026-09-02

CLI, peer-HTTP, FUSE, and monitor changes that will surprise a node still
running the tagged binary, or a script written against it. A mixed fleet
with `v0.5.0` peers still fills: those fetchers already send `piece=N` on
`/stage` and only probe `/stage` when `X-Stage` is advertised. No on-disk
format change. Details stay in the entries below. These are CLI, peer-HTTP,
and default-behavior changes: the next tag is a minor, not a patch
(CONTRIBUTING).

- **`modelfs verify` and `modelfs dupes` refuse a file or unreachable `--origin`** (exit 1). `dupes --all` used to treat a regular file as an empty scan and exit 0.
- **Every `MODELFS_*` value is trimmed of surrounding whitespace**; whitespace-only counts as unset (defaults apply), except a whitespace-only `MODELFS_PSK_VALUE` which is still refused as empty.
- **`modelfs dupes` counts each shared digest once**, not once per repeated occurrence in a file.
- **`/stage` missing, malformed, or over-wide `piece` is 400** before origin or cache, matching a missing `Range` on `/data`. A request that never named a piece can no longer 404 on an absent path.
- **A `/have` bitmap that would exceed 16 MiB replies 500** without opening a cache entry. Fetchers already refused that body.
- **A 501 from `/stage` does not increment `http_5xx`.** HTTP-only nodes no longer look failing on that gauge; 500 and 502 still feed it. Monitors alerting on `http_5xx` for capability probes must treat 501 separately if they still care.
- **Origin I/O failures return the libc errno** (FUSE replies and `noteOriginIo` used to report EPERM because the wrappers passed through libc's `-1`).
- **A FIFO at a model path fails ESPIPE on read and ENXIO on write** (used to hang the FUSE worker until a counterpart appeared).
- **U+180F and U+1BCA0..U+1BCA3 in paths are refused**, matching the rest of Default_Ignorable.
- **`modelfs peers` exits 1 when `origin/.cluster` is unreadable** (EIO, ENOTDIR, EACCES). A missing `.cluster` is still an empty cluster (exit 0). An origin I/O failure used to print `no cluster leases` and exit 0.

### Idle origin outages and metadata failures reach the tick line - 2026-09-02
- **Lease publish and unreadable `.cluster` walks raise `origin_down`.** Discovery already wrote the origin every 10 s, but a node with no FUSE traffic left `origin_down` at 0 until the first getattr. `tickCluster` feeds the publish/refresh errno into `Store.noteOriginIo`. Write/rename and walk failures are edge-triggered (one warn, then `lease publish recovered` / `cluster leases recovered`) so a dead NFS cannot warn every tick.
- **`lease_err` and `meta_err` ride status.json and the tick line.** `lease_err` counts failed lease publishes (the idle-node origin-down heartbeat). `meta_err` counts getattr/open/readdir EIO/ESTALE/ETIMEDOUT so an `ls` storm during an outage does not look like a slow-but-healthy `md_us` interval.
- **`/ping` is no longer timed in `http_nanos`.** It stays uncounted in `http_ok`. Timing it made a health-check poll fire an otherwise-idle tick line of zeros (`http_us` 0 over a zero denominator).
- **Three `expectedHash` tests pass the `now_ms` argument.** They still used the two-arg form, so `zig build test` failed to compile.

### /stage backoff TTL starts at the failure, not the attempt - 2026-09-02
- **A failed `/stage` is marked down from the instant it returns.** `fetchFromCands` used to stamp `Catalog.noteStageDown` with the clock sample taken before `fetchPieceStaged`. That function's dial/head budget is 15 s + 10 s against a 2 s TTL, so a blackholed `/stage` left `expires_ms` in the past and every later piece of the same file retried the extra round trip. Fast 501s still get the same 2 s window.

### Warm FUSE reads skip origin getattr; cull samples a bounded LRU set - 2026-09-02
- **A FUSE read of a live cache entry no longer stats the origin.** `fileForRead` reuses the entry `open`/`getattr` already reconciled; a getattr RTT on every 128 KiB read made the warm NVMe path pay NFS. Size changes through the mount still update the entry in place. An external origin rewrite is visible on the next open (NFS close-to-open). A cold read (no live entry, or after `reapIdle` dropped it) still stats origin.
- **`cullOne` keeps a 32-oldest idle sample instead of sorting every idle file.** Punching one piece used to allocate and pin the whole live map. Equal-recency ties still break by rel bytes. `Bitfield.allSet` checks a covered span word-at-a-time so `rangeFilled` and write-through retries do not walk each bit; `containsControl` skips leading printable-ASCII 8-byte words; a manifest load reserves hash-map capacity once.

### Same-size rewrite ignores a stale piece-hash manifest - 2026-09-02
- **A piece-hash manifest carries the origin identity (mtime/ino) of the file it describes.** After a same-size rewrite, `expectedHash` reloaded the previous object's hashes from `.cluster/manifests/<hex>` (keyed only by path and size), so a peer still holding the old pieces could pass verification and land as the new file. The optional 24-byte trailer is the same layout as the sidecar identity; older manifests omit it and keep their prior behavior until the next publish. A manifest whose identity does not match this node's origin stat is ignored and retried, the same as a missing artifact.

### CLI help and harness stderr - 2026-09-02
- **`modelfs help` lists `dupes --all` as its own usage line.** The previous `dupes <relpath>... [--all]` form implied `--all` could combine with a path list; that combination is refused (exit 2). `--advertise` is documented as repeatable, matching `--seed`. Argument-parse OOM exits 1, not 2: usage errors stay 2.
- **Harness `Error:` lines go to stderr.** `run_e2e_tests.sh`, `run_cluster_e2e_9nodes.sh`, `run_vm_cluster_e2e.sh`, and `test_fault_tolerance.sh` printed failures on stdout, so a redirected run hid the reason.

### Replica pull fails closed on SSH and a failed ZFS import - 2026-09-02
- **Syncoid's SSH no longer waits forever on a prompt.** `TimeoutStartSec=infinity` plus an interactive host-key or password prompt left the daily pull hung until an operator killed it, so `OnFailure=` never fired. The unit now passes `BatchMode=yes` and `ConnectTimeout=30` through `--sshoption`, `Requires=zfs-import.target` (with `Wants=network-online.target`) so a failed pool import does not still start the oneshot, and `notify-admin@.service` is sandboxed. The monthly drill and hourly snap-age units require the same import target; the drill log is created with `UMask=0077`; the daily drill-log timer has the same `RandomizedDelaySec` the other timers already used.
- **The 4-VM cluster e2e fetches the checksummed 24.04 release image.** It downloaded `noble/current` (a moving daily) and then checked the digest of `ubuntu-24.04-server-cloudimg-amd64.img` from the 20260826 release, so a first-time download after Ubuntu rotated `current` failed checksum and "delete it to re-download" still fetched the daily. The URL is now that dated release; a stale cached daily is replaced once. The local PSK file is mode 600 like the other harnesses, and a libvirt `default` network this script creates keeps DHCP out of the static `.10-.13` range.

### /stage window and origin manifest fuzz seeds reach the decode path - 2026-09-02
- **The `/stage` window and piece-hash manifest fuzz corpora now use `fuzzcorpus.entry` framing.** `Smith.slice` reads a u32 length prefix; the raw codec bytes were consumed as that prefix, so a well-formed window or `MFSM` blob never decoded during corpus replay. Truncated, empty, over-long, and structurally corrupt seeds now sit next to a clean one; a decoded manifest re-encodes to the same blob.

### Peer HTTP dispatch test counts both 405s - 2026-09-02
- **The peer HTTP dispatch unit test accepts two 405s before the unauthenticated requests.** The CR/LF method case already asserted `http_405 == 2`; the later auth-before-method check still expected 1, so `zig build test` failed on a correct setup.

### check.sh refuses an empty venv and a forgotten src/root.zig import - 2026-09-02
- **`scripts/check.sh` no longer treats a created-but-empty `.venv` as the pinned toolchain.** `uv venv` without the lock install left ruff/mypy/python3 resolving to whatever the OS shipped, which is the PATH stand-in the gate exists to refuse. It now requires those three binaries inside `.venv/bin` and that `python3` matches `.python-version` (the same series CI's setup-uv installs). A new `src/*.zig` other than `c.zig` that is not imported from `src/root.zig` fails the gate instead of silently dropping its tests. Harnesses that run the repo's Python CLIs (`test_fault_tolerance.sh`, `run_cluster_e2e_9nodes.sh`) name a too-old interpreter against that same pin instead of dying as a SyntaxError.

### IPv4 bind/accept/connect use std.c instead of glibc sockaddr unions - 2026-09-02
- **Peer sockets no longer go through glibc's `__SOCKADDR_ARG` union.** `bind`, `connect`, `accept4`, and `getsockname` used translate-c's `.__sockaddr__` field, which musl headers (and a glibc field-name change) do not export. They now call `std.c` the same way `sys.errno` already uses `std.c._errno` instead of glibc `__errno_location`. `sys.bind` and `sys.getsockname` are the shared wrappers.

### CLI verify and dupes name cache and origin artifacts through Store - 2026-09-02
- **`modelfs verify` reads the sidecar grid through `Store.sidecarPieceSize`.** It used to join `cache/meta/<rel>.pieces` and parse the `MFS1` header itself, duplicating the layout `Store.cacheMetaPath` already owns. A mismatched `--piece` still follows the daemon's recorded grid (`piece.sidecarPieceSize`).
- **`modelfs dupes` names manifests through `Store.manifestPath` / `manifestsDirPath`.** The CLI no longer reconstructs `.cluster/manifests` joins. Pin, verify, and dupes share one mount-prefix strip and path gate (`mountRel`, then `relOk` / `relIsCluster`).

### Pool-loss restore is a command, and offsite age is an alarm - 2026-09-02
- **Procedure C is no longer a paste-block.** `scripts/dr_pool_restore.sh` (`modelfs-pool-restore`) pulls `tank/models` from the replica (`--from` syncoid, or `--local-from` `zfs send -R | zfs recv -Fs`), sets the operations.md export properties, and records `recv_s` in `/var/log/modelfs-pool-restore.log` as the pool-loss RTO. Dry-run by default; `--execute` runs the recv. A mounted DEST is refused without `--force`, so it cannot `--force-delete` the live export by accident. It does not create the pool and does not wipe node caches; after a successful recv it prints the cache-wipe commands that must run before any client remounts.
- **A stopped offsite rotation is a named alarm.** `scripts/check_offsite.sh` (`modelfs-check-offsite`) fails when the site-loss copy is missing, has no snapshots, or is older than `MF_OFFSITE_MAX_AGE` (default 8 days). There is no live-NAS default dataset: checking `tank/models` on the NAS would bless production as the offsite copy. `modelfs-offsite-age.timer` is weekly and stays off until a hosted box sets `MF_OFFSITE_DATASET`; a rotated disk runs the script when attached.
- **A replica with no snapshots is a failed hold.** `hold_monthlies.sh` still treats "hourlies only" as success (the first month has no `*_monthly`), but an empty snapshot list now fails the syncoid `ExecStartPost`: a green pull of nothing cannot survive `zfs destroy -r`.

### Extract linker symlinks follow the unpacked libfuse3 soname - 2026-09-02
- **`extract_fuse3_arm64.sh` points `libfuse3.so.3` at the shared object the `.deb` actually unpacked.** The path used to hardcode `3.14.0`; a SHA256SUMS refresh would leave a dangling linker symlink that `test_extract_fuse3_arm64.sh` still accepted (`-L` is true for a broken link). The suite now also requires the targets to resolve (`-e`).

### VM e2e dump keeps the PSK off curl argv - 2026-09-02
- **The 4-VM cluster failure dump no longer puts the bearer token on curl's command line.** Expanding `Authorization: Bearer $(cat …psk)` into `curl -H` leaked the shared secret through `/proc/<pid>/cmdline` on the guest. The dump now writes a 0600 header file and passes `curl -H @file`. The local PSK file is also `chmod 600` before scp, matching the other harnesses, and the client VMs install `curl` so the dump is present when peer fills fail.

### Stale same-size manifests cannot resurrect wiped hashes - 2026-09-02
- **`Store.tryLoadManifest` drops a load that raced a wipe and ignores a manifest older than the entry's origin identity.** A same-size rewrite (newer mtime or different ino) already cleared marks and hashes, but the origin read sits outside `file.mu`; merging afterwards reinstalled the previous object's digests (the blob still names the same `file_size`), so a peer fill could admit pre-rewrite bytes. The load now samples `writes` before the origin read and refuses a manifest whose mtime predates `Cached.origin_id`.

### Ship ELF pins PIC, no RPATH, and a frozen build-id; VM e2e matches ReleaseFast - 2026-09-02
- **The shipped image now pins PIC, refuses DT_RPATH/DT_RUNPATH, and freezes `--build-id=none`.** `exe.pie` already produced an ET_DYN, but PIC was left to the compiler default, `-Dfuse-lib` could have become a runtime search path (baking the build-host extract dir into the spark binary), and a CLI `--build-id=uuid` would have made two builds of the same tree disagree. `checkHardenedElf` now fails those dynamic tags the same way it already fails a non-PIE or lazy-binding link. `scripts/check.sh` and `scripts/cross_aarch64.sh` pin `LC_ALL=C`/`TZ=UTC`; `require_zig` enforces `minimum_zig_version` so an old toolchain dies at the script preflight instead of as a compile error.
- **The 4-VM cluster e2e builds the ReleaseFast image from tracked sources.** It used to `tar` the whole worktree (so a host `.zig-cache` could ride into the guest) and `zig build` Debug, while claiming to match the spark deploy. It now packs `git ls-files` like `repro_check.sh`, fetches the tarball named by `build.zig.zon`'s `minimum_zig_version`, and compiles `-Doptimize=ReleaseFast`.

### /have refuses bitmaps larger than the fetch body bound - 2026-09-02
- **A `/have` whose piece bitmap would exceed 16 MiB replies 500 before opening a cache entry.** Fetchers already refuse that body (`max_have_body_bytes`); serving it allocated the whole field (up to 512 MiB at `--piece 1` on a large sparse file) for a reply no peer would accept.

### Origin and cache joins refuse a traversal rel - 2026-09-02
- **`Store.originPath` and the cache-subdir join refuse a rel that fails `relOk`.** Empty rel still names the origin or cache subdir root (FUSE `/`); anything else that would join `..` into those trees now fails closed at the join, matching the FUSE/peer/CLI gates.

### Env whitespace trim and origin directory gate on verify/dupes - 2026-09-02
- **Every `MODELFS_*` value is trimmed of surrounding whitespace.** An EnvironmentFile trailing space or a copied path with a newline used to become the path (`MODELFS_ORIGIN=/nas/models ` failed later as "not reachable"; `MODELFS_ID=spark1 ` published a different cluster id). Empty or whitespace-only now counts as unset, matching an empty export. `MODELFS_PSK_VALUE` is the exception: a whitespace-only inline secret is still refused as empty rather than falling through to the PSK file. `--seed` trims the same way `--advertise` already trimmed each address.
- **`modelfs verify` and `modelfs dupes` refuse a file or unreachable `--origin`.** `dupes --all` used to treat a regular file at `--origin` as an empty scan and exit 0. Mount and peers already had the directory gate; `resolveOriginDir` is the shared check.

### FUSE rmdir retry of a gone directory is success - 2026-09-02
- **`Store.rmdirOrigin` treats ENOENT as success.** `mkdir` of an existing
  directory already converged so a FUSE retry after a lost reply did not
  fail `EEXIST`; `rmdir` still returned the origin errno, so the same retry
  failed `ENOENT` after the directory was already gone. A non-directory at
  that name stays `ENOTDIR`, a non-empty directory `ENOTEMPTY`. `rmdir` of
  the mount root (FUSE "/") is `EBUSY` so it cannot delete the origin
  export. `mf_rmdir` calls the helper, matching `mf_mkdir`.
- **Peer dispatch test counts both 405s after the CR/LF method case.** The
  unauthenticated-POST assertion still expected `http_405 == 1` after a
  second authenticated 405 was added, so `zig build test` failed on that
  case. It now expects 2, matching the POST and CR/LF method refusals.

### The Python gate pins ruff and mypy to the lockfile versions - 2026-09-02
- **ruff and mypy are exact pins.** `requirements-dev.txt` named a range
  (`mypy>=2.1,<3`, `ruff>=0.16,<0.17`) while the lock held 2.3.1 / 0.16.4, so
  `uv pip compile` could float a newer 0.16 without a bounds-file change, and
  ruff's `required-version` accepted any 0.16.x. Both files now pin the lock
  versions; `scripts/sbom.py` refuses a range or a bounds/lock mismatch;
  `scripts/check.sh` fails if the venv's ruff, mypy, or Python disagree with
  those pins and `.python-version`.

### Same-size origin rewrites drop cache marks - 2026-09-02
- **A newer origin mtime or a different inode at the same path wipes piece marks and trusted hashes**, the way a size change already did. Size-only reconciliation kept the previous object's pieces after a same-size rewrite (another node's FUSE write, or a direct origin write), so FUSE reads and `/have`/`/data` could serve the old bytes. An older mtime on the same inode is treated as NFS attribute lag after this node's own write, not a rewrite. The identity is an optional trailer on `meta/*.pieces`, so a restart still sees it; older sidecars without a trailer keep their prior behavior until the next save.
- **Manifest load no longer replaces a hash this node already recorded** from an origin fill or write-through. Origin bytes stay the trust root for that piece; a later or stale same-size manifest fills only the gaps.

### Manifest retry and down-list overflow run on injected instants - 2026-09-02
- **`Store.expectedHash` takes the caller's monotonic-ms instant** so a
  transient manifest miss retries when that sample crosses
  `manifest_retry_at`, not when the wall clock does. `tryLoadManifest`
  stamps the next attempt from the same sample. Tests drive the miss,
  the still-too-soon lookup, and the due load with virtual instants and
  no sleep. The same-size rewrite and local-hash-keep cases pass that
  instant too.
- **`noteStageDown` overflow evicts expired lines by soonest expiry then
  (ip, port)**, and `noteProbeDown`/`noteFetchDown` overflow evicts the
  (ip, port)-least line, so have_mu lock order cannot choose the casualty.
  Live stage-down backoffs are still not dropped to admit a new failure.
  `fetchFromCands` stamps a staged-fetch failure with the walk's clock
  sample instead of a second read.

### Mongolian FVS4 and shorthand format controls no longer pass the path and echo gates - 2026-09-02
- **U+180F and U+1BCA0..U+1BCA3 in paths are refused.** `relOk` and `discover.printable` already refused Default_Ignorable including U+180B..U+180E, but a planted path `gguf/model\u180F.bin` or lease id `spark1\u1BCA0` still echoed as the unadorned name. Those sequences are refused now; incomplete encodings and visible neighbours in the same UTF-8 blocks (U+1810, U+1BC9F) stay legal display text.

### `modelfs dupes` counts each shared digest once - 2026-09-02
- **`modelfs dupes` reports each digest shared between two files once.**
  A file that repeats the same piece hash (padding, duplicated tensors)
  used to increment the "shared digest(s)" count once per occurrence,
  so two copies of a padded GGUF could report more shared digests than
  distinct hashes they actually have in common. Aligned overlap and
  byte-identical detection are unchanged.

### Peer 405 and dupes logs withhold control bytes - 2026-09-02
- **The 405 journal line and `modelfs dupes --all` skip-warns no longer echo
  attacker-chosen tokens verbatim.** A PSK holder could put CR/LF or a
  terminal escape in the request-line method, and an origin writer could
  plant the same in a `.cluster/manifests/` file name; both now go through
  `discover.displayName` the way lease names already do. The 405 reply and
  the dupes scan are unchanged.

### Staged-piece pool reuses consumed slots - 2026-09-02
- **The in-memory `/stage` pool treats `fake_cap` as concurrent occupancy.**
  Consumed windows were tombstoned but `stage` still keyed off the array
  length, so the 16th successful stage exhausted the pool for the rest of
  the process. Tombstones are reused; a live window still occupies its
  slot until `read` or `release`. A length-mismatch `read` consumes the
  slot too, so a failed fetch cannot pin the cap until exit.

### Python and shell gates cover the config file and nested scripts - 2026-09-02
- **ruff no longer ignores `write-whole-file`.** The scripts already use
  `Path.write_text`, so that ignore was silencing a rule that no longer
  fired. Ignore selectors are rule names rather than codes, type-checking
  imports stay flagged even when a runtime sibling exists, and `ruff check`
  / `ruff format --check` run with no path so `pyproject.toml` and a Python
  module outside `scripts/` cannot skip the gate. mypy lists `redundant-cast`
  next to the other default-off extras `--strict` already turns on.
- **shellcheck walks every `scripts/**/*.sh`**, so a nested script cannot
  skip the top-level `scripts/*.sh` glob.

### Origin I/O failures keep their errno; FIFOs cannot hang a worker - 2026-09-02
- **`preadAll`, `pwriteAll`, and `writeAll` return `-errno`.** libc returns
  `-1` and sets `errno`; these wrappers used to pass that `-1` through, so
  every caller that treats a negative as an errno (FUSE replies,
  `noteOriginIo`, journal lines) reported EPERM and never classified
  EIO/ESTALE/ETIMEDOUT as an origin outage. `sendfileAll` already returned
  `-errno`. A bad-fd test pins EBADF.
- **Origin data-plane opens take `O_NONBLOCK`**, matching lease reads and
  `opendirNoFollow`. A FIFO planted at a model path used to hang
  `originPread`/`originPwrite`, `mf_create`, and `mf_truncate` until a
  counterpart appeared. `readFileAllocNoFollowOpenErrno` and the nofollow
  write helpers get the same flag so a FIFO sidecar, manifest, or lease
  staging name cannot wedge a fill or the discovery thread. A FIFO at a
  model path now fails ESPIPE on read and ENXIO on write.
- **Failure paths that used to stay silent now log:** a piece-manifest path
  that does not fit, a disk-punch fstat or unusable size, a `/have` or
  `/data` header send that dies before the body, a staged-fetch first
  failure (same edge trigger as `/have` and `/data` downs), and a
  `getifaddrs` failure at start (it no longer reads as "no NICs"). A
  length-mismatch staged read frees the pool slot instead of pinning it.
- **`connectInWithIo` restores the caller's flags on every path.** A failed
  connect or poll used to leave `O_NONBLOCK` set, so a later blocking read
  on that fd would return EAGAIN instead of honoring `SO_RCVTIMEO`.

### Peer /stage matches /have and /data - 2026-09-02
- **`/stage` required `piece=N` is gated like `/data` Range.** Missing,
  malformed, or over-wide `piece` answers 400 before any origin or cache
  touch, the same order a missing Range uses, so an absent path cannot
  404 a request that never named a piece. Past-EOF piece indexes stay 400
  after the origin stat, as before.
- **A 501 from `/stage` does not increment `http_5xx`.** It is a
  capability answer (this node has no data-plane backend); counting it
  made an HTTP-only node look failing. 500 and 502 still feed the gauge.
- **The status table names `piece` as a 400 cause** and lists it with the
  other unsigned-decimal wire integers. The routing-contract fuzz oracles
  now treat `/stage` as a routed path.

## [0.5.0] - 2026-08-31

Observability release on top of 0.4.0: the FUSE metadata handlers and the
`/ping` probe now carry latency counters, non-GET peer requests are counted
and logged instead of being silently refused, and the dial timeout runs on
the injected `std.Io` clock so a simulator can drive expiry. A
`_FORTIFY_SOURCE` define that broke every optimized build is reverted, and
the NAS drill scripts probe for the GNU tools they need. status.json stats
gain four keys (`getattr_nanos`, `open_nanos`, `statfs_nanos`, `http_405`)
and the `tick:` line two fields (`http405`, `md_us`); no wire or on-disk
changes, so upgrading from v0.4.0 is a rebuild and restart. Monitors
parsing the tick line by field position must be updated; parsing by name
is unaffected.

### Metadata handlers report their latency - 2026-08-31
- **`getattr_nanos`, `open_nanos`, and `statfs_nanos` count wall time inside
  `mf_getattr`, `mf_open`, and `mf_statfs`.** Every FUSE request traverses
  getattr, so before this the only latency signal (`rd_us`/`wr_us`) could
  answer "data reads got slow" while a metadata storm stayed invisible. They
  publish in status.json through `Stats.Snap` like every other counter.
- **The `tick:` line gains `md_us`**, the interval total (not a mean: the
  handlers count wall time, not calls) of those three. A tick fires whenever
  any counter moves, so without the field a metadata-only interval logged a
  line of zeros.

### Non-GET peer requests are counted and named - 2026-08-31
- **`http_405` counts every request the peer server refuses for method**, and
  the first one per `auth_warn_min_gap_ms` window logs the method and source
  address. The 405 reply itself is unchanged. Deduplication mirrors the 401
  path: the counter keeps the exact total, the journal keeps one line, so a
  probing campaign is neither silent nor a flood.
- **`/ping` handler time lands in `http_nanos`.** `http_ok` counts only
  data-plane replies, so a fleet that can answer nothing but the liveness
  probe used to look healthy in the serve-latency average.

### Dial timeout runs on the injected clock - 2026-08-31
- **`sys.connectInWithIo` takes the `std.Io` the caller already holds** and
  measures the connect budget with `sys.monoMs` instead of a direct
  `clock_gettime`. `peer.dial` passes its `io`, so a simulated clock drives
  dial expiry the way it drives every other timeout here. `connectIn` stays
  as the non-simulated wrapper.

### Release builds compile again; host-tool probes - 2026-08-31
- **`_FORTIFY_SOURCE=2` is gone from the `translate-c` step.** It broke every
  `-Doptimize=Release*` build: the define makes glibc expose
  `__builtin_object_size` overloads whose `diagnose_if` bodies translate-c
  reports as errors, and only above `-O0`, so a Debug `zig build test` stayed
  green while the release build failed. It guarded nothing either, that step
  translates headers and compiles no C. `build.zig` carries the reason so it
  is not re-added.
- **`dr_restore_drill.sh` and `check_drill_log.sh` probe for GNU tools before
  using them** (`find -printf`, `sort -z`, `stat -c`, `date -u -d` with
  `%s`), each failing with the named requirement. On a BusyBox or BSD host
  these used to fail deep in the drill with a parse error.
- **`lib.sh` no longer uses `${var,,}`**, so `assert_aarch64_elf` runs under
  a shell without bash 4 parameter-expansion case conversion.

### Python gate takes preview ruff rules and leftover mypy extras - 2026-08-30
- **ruff now enables preview so a new 0.16 defect prefix cannot stay off.** The tree already
  passes the preview correctness and security groups; formatter preview stays off (it would
  reformat dict literals). Named ignores cover the preview nits this tree does not pass
  (`DOC`, `RUF105`, `FURB103`/`FURB113`, `PLR0914`, `PLC1901`, `S404`). The benchmark
  driver uses pathlib, so the per-file PTH exceptions are gone.
- **mypy follows untyped imports and incomplete stubs**, and pins `platform = "linux"` so a
  missing stub cannot silently become Any and the check matches the only OS these scripts run
  on.

## [0.4.0] - 2026-08-30

Feature release on top of 0.3.1: a 4-VM libvirt cluster e2e harness, peer
`/have` probe failures now name the failing peer in the journal, `modelfs
dupes <relpath>...` reports an empty result on stdout like `--all` does,
and the aarch64 cross-build compiles again. Docs gain a DR async-export
window, the offsite freshness procedure, and corrected env-var scopes. No
wire or on-disk changes; upgrading from v0.3.1 is a rebuild and restart.

### CLI help derives the default peer port from the shared constant - 2026-08-30
- **`modelfs help` no longer hardcodes 18080 in the `--listen` line.** The
  usage text formats the default from `proto.default_port` -- the same
  constant every parse path reads -- so a future port change cannot leave
  the help text describing a default the daemon no longer uses.

### Env docs: MODELFS_ID mount-only scope, log-ceiling coverage - 2026-08-30
- **`modelfs help` now marks `MODELFS_ID` as mount only**, like `--id`
  (outside mount the env var is deliberately ignored while the flag is
  refused, and the help's "set the same values as their flags" read as if
  they shared one scope).
- **architecture.md now lists verify and dupes among the commands
  `MODELFS_LOG` / `--log` move the ceiling for** -- the shared argument
  parser applies both knobs on every command, and README already named all
  seven; the env paragraph said only mount, status, peers, pin, and unpin.

### aarch64 cross-build compiles again - 2026-08-30
- **The `-Dtarget=aarch64-linux-gnu.2.39` deploy build no longer fails.**
  `build.zig` requested stack probing (`stack_check`) unconditionally, but
  Zig 0.16 implements it only for the x86 family, so every aarch64
  cross-compile died with "the selected target does not support stack
  checking" -- the exact ABI the Sparks deploy. Stack canaries stay on for
  every target; probes now follow the compiler's supported set, so native
  x86_64 ships unchanged and the cross build is green again.

### DR docs: async-export window and offsite freshness - 2026-08-30
- **`docs/recovery.md` now discloses the one acknowledged-but-not-durable
  window the posture claims were missing.** The NAS export is `async`, so
  a NAS crash can lose acknowledged writes up to the txg interval, and no
  snapshot RPO recovers bytes that never reached stable storage; the note
  cross-references the kept-as-is caveat in operations.md.
- **The offsite layer gets a freshness procedure and an explicit gap.**
  Section 3 adds the `zfs list -t snapshot` check for the rotated disk or
  hosted box, and section 8 records that the offsite rotation -- unlike
  the local and replica layers -- has no timer or age alarm in this repo.

### `modelfs dupes` empty report rides stdout like `--all` - 2026-08-30
- **`modelfs dupes <relpath>...` now prints "no manifests to compare" on
  stdout** when no listed path has a piece-hash manifest, matching
  `modelfs dupes --all`'s empty-store report, so a pipe sees the result;
  the per-path "no piece-hash manifest" diagnostics stay on stderr.

### Peer probe failures log the failing peer - 2026-08-30
- **A `/have` probe failure now names the peer.** Probe failures (dead
  peer, PSK drift, timeout, malformed reply) used to bump only the
  `probe_err` tick counter, so a cluster silently degrading to NFS-only
  left no journal line explaining which peer was down. `Catalog` tracks
  probe-down peers and the first failure since the peer answered logs
  `peer <ip>:<port> /have probe failed ... with the error class; the next
  success (a healthy 404 counts) logs recovery, and repeats ride the
  counter -- a dead fleet cannot flood the journal.

### 4-VM cluster e2e and a manifest-load retry fix - 2026-08-29
- **`scripts/run_vm_cluster_e2e.sh` boots a real cluster: one NFS server VM
  plus three modelfs client VMs** on libvirt/KVM (the topology the 9-node
  loopback test cannot exercise). It builds modelfs inside the NFS VM
  against Ubuntu 24.04's libfuse3 (a host-built binary links the host's
  soname), exports the origin over NFS, and verifies the full story across
  a real network: leases on the NFS origin, peers discovery, client 1
  origin-fills and publishes the piece-hash manifest, clients 2-3
  peer-fill verified against it, `modelfs verify` clean, `dupes --all`
  scans the manifest, integrity counters zero, cache bounds held. Needs
  sudo, /dev/kvm, and cloud-image-utils; run locally like the 9-node
  suite (CONTRIBUTING "End-to-end suites").
- **A reader that missed a freshly published manifest now retries.** A
  transient manifest-load failure (an NFS negative cache can hide the
  writer's just-published manifest, or a torn publish is being rewritten)
  used to disable peer fills for the entry's lifetime -- the reader
  origin-filled everything. `Store` now retries a transient absence after
  `manifest_retry_ms` (3 s; a field, shrunk in tests), which the VM e2e
  surfaced and now pins.

### `modelfs dupes --all`, verify reporting, doc dates - 2026-08-29
- **`modelfs dupes --all --origin PATH` scans the whole manifest store**
  (no positional paths): total manifests/pieces, byte-identical pairs, and
  pairs sharing any digest -- the aggregate duplicate telemetry the dedup
  decision needs without naming files (manifests are keyed by
  `blake3(rel)` hex). Missing manifests dir is an empty scan, not an error;
  `--all` is refused on every other command.
- **`modelfs verify` now says when there was nothing to verify against**:
  a marked file with no trusted hashes reports "(no trusted hashes: no
  manifest or nothing cached)" instead of silently printing zero checked.

## [0.3.1] - 2026-08-29

Patch release on top of 0.3.0: a piece that fails at-rest verification now
self-heals instead of failing every serve until a cull or a manual
`modelfs verify`, a peer whose staged data plane fails is backed off rather
than re-probed per piece, and operations gains an integrity runbook. No
wire, on-disk, or CLI changes; upgrading from v0.3.0 is a rebuild and
restart.

## [0.3.0] - 2026-08-29

Third tagged release. Piece integrity ships and closes threat-model gap R2:
every admitted piece records a blake3 digest, peer fills verify before
admit, cached bytes verify before every `/data` serve, and piece-hash
manifests on the origin make the fleet's peer fills verifiable (`modelfs
verify` audits the cache on demand). The peer transport grows a negotiated
staged (RDMA) data-plane seam (`/stage` + `X-Stage`, backend-gated and
HTTP-fallback by construction), and `modelfs dupes` turns the dedup
roadmap into measured telemetry. Upgrading from `v0.2.0`: start at
**Upgrade from v0.2.0** below.

### Upgrade from v0.2.0 - 2026-08-28
- **Files without a piece-hash manifest now fill from origin only.** The R2
  fix refuses unverifiable peer fills: a file written before this version
  (or outside modelfs) has no manifest, so its fills stay origin-only until
  one exists -- the first node that fully origin-reads it publishes one on
  close. Re-ingest (rewrite once) to restore P2P immediately; manifest-
  bearing files are unaffected.
- **The peer wire is additive; a mixed fleet interoperates.** The new
  `/stage` endpoint and `X-Stage` header are additive: v0.2.0 nodes answer
  `/stage` with 404 (unknown route) and never advertise `X-Stage`, so
  v0.3.0 fetchers fall back to `/data` exactly as designed.
- **status.json stats gain `fill_err_verify` and `serve_verify_fail`.**
  Additive keys; consumers that print the stats object pick them up
  automatically.
- **Serving nodes rehash cached pieces before every `/data` reply**
  (verify-before-serve). The serving node's per-piece CPU cost rises by one
  blake3 pass; the tick line's `serve_verify_fail` names any piece refused.
- **New commands:** `modelfs verify <rel> --origin PATH` (at-rest cache
  audit) and `modelfs dupes <rel>... --origin PATH` (manifest overlap
  scan). No on-disk format change: the piece sidecar is untouched.

### Piece integrity: blake3 verify-before-admit and -serve, origin piece-hash manifests, `modelfs verify` - 2026-08-28
- **Peer-served bytes are now verified before they enter the cache (closes threat-model gap R2).** Every admitted piece -- origin fill, write-through, or peer fill -- records a blake3 digest (`Store.Cached.hashes`); a peer fill is only attempted when a trusted digest exists (origin manifest, origin fill, or this node's own write), and fetched bytes that fail verification are discarded unmarked and refilled from origin (`hydratePiece` src/fuse_fs.zig, new `fill_err_verify` counter). A node that wrote or fully read a file publishes its digests as a piece-hash manifest on the origin at close (`mf_release` + `Store.publishManifest`, under `.cluster/manifests/<blake3(rel)>`), and readers load it lazily as the trust reference (`expectedHash`); the manifest codec is a fuzzed hand parser like the sidecar.
- **Cached bytes are re-verified before every `/data` serve.** `verifyRange` in src/peer.zig hashes each covered piece from the cache and refuses to stream a mismatch (500 + new `serve_verify_fail` counter), so at-rest corruption (hole zeros, bit rot) is caught at the fleet-propagation point instead of being re-served; `modelfs verify <rel> --origin PATH` rehashes a whole file's cached pieces against the manifest and clears mismatched marks, daemon-less like `pin`.
- **Digests ride the tick line and status.json** (`fill_err_verify`, `serve_verify_fail`), and are dropped together with the marks on size change, distrust, and forget (`Store.clearHashes`). The sidecar bitfield format is unchanged; no wire or on-disk format break. Files with no manifest (written outside modelfs, or pre-upgrade caches) fill from origin only, and their legacy cached pieces serve unverified until a manifest exists -- the documented residual (docs/THREAT_MODEL.md, docs/design.md §14).

### Staged (RDMA) peer data plane: transport seam and /stage protocol - 2026-08-28
- **The peer transport grows a negotiated data-plane seam** (`src/rdma.zig`, design.md §15): a node whose backend can stage advertises `X-Stage: 1` on `/have`, and a fetching node then stages one piece at a time via `GET /stage?path=..&piece=N` -- the serving side hydrates, at-rest-verifies, registers the bytes, and replies with a 52-byte window (`len`/`rkey`/`addr` + advisory digest) that the fetching side's backend reads. Any `/stage` failure falls back to the existing `/data` path on the same peer, and a fleet without verbs never pays the probe (the capability rides the have-cache line, `Catalog.haveStage`).
- **The shipped backend is null**: production behavior is byte-identical to the HTTP-only tree; the in-memory fake backend exists so the full pipeline (staging, window codec, staged fetch, per-piece fallback) runs under `zig build test`. The verbs tail (libibverbs QP setup, `ibv_reg_mr`, the RDMA Read, the buffer-release handshake, RoCE fabric tuning) is deliberately not written as untestable C interop -- the interface it fills is `rdma.Backend.stage/read/release`, and the design, failure modes, and the 200G NVMe/verification ceilings are in design.md §15.
- **The dedup roadmap is now telemetry-gated, and the telemetry ships as `modelfs dupes`.** `modelfs dupes <rel>... --origin PATH` compares piece-hash manifests across paths (it reads manifests only, never model bytes) and reports aligned overlap (what a same-size re-export would share), shared digests, shifted overlap (the only overlap CDC could recover), and byte-identical pairs. design.md §14 now marks Level 2 (CAS blob store) **shelved** -- the staged data plane made transfer dedup moot, and a CAS rewrite would fight the path-keyed integrity layer -- and Level 3 (CDC) **dormant** with the same telemetry as its trigger.

## [0.2.0] - 2026-08-27

Second tagged release. Recovery gets fail-closed alarms (hourly snapshot
age, held monthly replicas, a daily drill-log check), the FUSE layer falls
back to the origin when the local cache cannot store a piece, origin
symlink races are closed with `O_NOFOLLOW`, and the CLI grows `--log` plus
usage errors that name what is missing. Upgrading from `v0.1.0`: start at
**Upgrade from v0.1.0** below.

### Hydrate-discard test raced its own hydrator - 2026-08-27
- **`hydratePiece fails closed when write generation keeps discarding fills` failed about two runs in three.** It read `rc` before joining the hydrator thread, so an unfinished fill read as a successful one, and it waited on "piece 0 is claimed" instead of the generation stamped on the claim, which cannot tell the first claim from the retry's. The wait now matches the claim generation and reacquires `content_mu` around a parked hydrator, and the assertions run after the join.

### Hourly snapshot-age alarm and replica hold fail-closed - 2026-08-27
- **A disabled `sanoid.timer` is an hourly alarm, not a 30-day wait.** `OnFailure=` on `sanoid.service` never fires if the timer is stopped, so the monthly restore drill was the only check that the newest snapshot was still inside the 25 h RPO bound. `modelfs-restore-drill --age-only` stops after that check (no clone, no drill log), `modelfs-snap-age.timer` runs it hourly, and `scripts/test_dr_restore_drill.sh` pins stale/missing/replica-missing failures plus "did not clone or append the log".
- **A green syncoid pull with no `zfs hold` is now a failed unit.** `ExecStartPost` used `zfs hold ... || true`, so a permission error or a missing `modelfs-dr` tag still looked like a replica that would survive `zfs destroy -r`. `scripts/hold_monthlies.sh` holds every `*_monthly` snapshot, treats already-held as success, and fails the unit on any other hold error. `TimeoutStartSec=infinity` is set on the syncoid and drill services so a 90 s Type=oneshot default cannot kill a multi-hour recv or a `diff -rq` of the live tree. `sanoid.conf` sets `recursive = yes` so a later child dataset is snapshotted without rewriting the backup job.

### Upgrade notes match the tagged status.json - 2026-08-27
- **Upgrade from v0.1.0 no longer claims `now_s` shipped in the tag.** Tagged `status.json` published `id`, `pid`, `uptime_s`, `peers`, `piece`, `inflight`, `cache_free_pct`, and `stats` only. `now_s`, `mono_s`, and `origin_down` are new on this tree; a leftover without stamps still parses (pid check only). `mkdir` of an existing directory through the mount is success (was EEXIST); a write whose `close` fails is an error (v0.1.0 reported success after pwrite).
- **The changelog gate pins compare/tag links and the current-tag sentences.** `scripts/check.sh` requires `[Unreleased]` first, dated `## [x.y.z] - YYYY-MM-DD` headings, a footer link per heading, the Unreleased compare URL to name `v<version>`, and README.md / SECURITY.md / docs/THREAT_MODEL.md to mention that tag. CONTRIBUTING's cut-a-release steps name those files and the 0.y.z bump rule (a CLI, peer-wire, on-disk, or default-behavior break is a minor, not a patch).

### Origin symlink races - 2026-08-27
- **chmod, origin statvfs, and directory opens no longer follow a raced symlink.** Those ops used to lstat then chmod/statvfs/opendir, so a co-tenant could swap the name to a link in the window and have the daemon chmod an arbitrary file, `df` the host root, list a client-local directory through the mount, or (for `.cluster`) parse and sweep names under the target. They now open `O_NOFOLLOW` (`sys.chmod` via `O_PATH`+`fchmodat`, `sys.statvfsNoFollow`, `sys.opendirNoFollow`) and return `ELOOP`. Lease walks and the disk-cull directory scan use the same open.

### CLI usage errors and stdout writes - 2026-08-27
- **No-args is one named line.** `modelfs` with no operands dumped the full help blob on stderr (exit 2), the only usage error that did not name what was missing. It now matches the unknown-command channel.
- **A failed stdout write is exit 1.** Help, version, status JSON, peer listings, and pin confirmations swallowed `WriteFailed` (ENOSPC, EPIPE, EIO: the runtime ignores SIGPIPE), so `modelfs version >/dev/full` and a monitor redirecting `status` onto a full disk returned 0 after dropping the payload.
- **`--log` is documented on the commands that parse it.** Help text said "every command"; `help`/`version` are answered before flag scanning, so `modelfs version --log err` is still "takes no arguments". The line now names mount/status/peers/pin/unpin.
- **`scripts/peer_ping.py` answers `--help` and refuses unknown arguments** (exit 2). The file is a library imported by the benchmark driver and cluster verifier, but it is executable: invoking it used to exit 0 with no output.
- **Python argparse helpers print `Usage:`** like the shell scripts. `scripts/test_scripts_help.sh` now requires `--help` on stdout, unknown flags on stderr with exit 2, and covers `-h` plus `peer_ping.py`.

### FUSE origin fallback and cluster piece-exchange - 2026-08-27
- **A FUSE miss no longer fails EIO when the local cache cannot store the piece.** `readServed` already degraded a failed cache pread to origin, but `mf_open` refused the file and `mf_read` returned the hydration errno, so a full or broken cache disk was a total outage while NFS still had the bytes. Open warmup is best-effort like create; a miss that cannot pwrite the hole serves that read from the origin and leaves the piece unmarked.
- **The 9-node cluster script actually exchanges pieces.** `run_cluster_e2e_9nodes.sh` listed leases and probed `/have` without reading through any mount, so an empty bitmap of the right length counted as piece exchange. It now `cmp`s the origin file through each mount, requires a peer-tier fill on a second node, and `cluster_verify.py` checks that bit `i` is set on the node it asks about that piece.

### CLI log flag and helper usage - 2026-08-27
- **`--log` is the flag `MODELFS_LOG` always claimed to have.** Help, README, architecture.md, and the threat model said an explicit flag wins over `MODELFS_LOG`, but no flag existed, so a cron'd `status` could only quiet the journal by exporting a shell-wide variable. `--log err|warn|info|debug` is accepted on every command, `--log=VALUE` too, and it wins over the environment the same way `--origin` wins over `MODELFS_ORIGIN`. A bad value names the knob (`--log verbose` / `MODELFS_LOG verbose`).
- **Contributor Python CLIs and the restore drill answer `--help` without starting work.** `run_benchmarks_and_plots.py --help` ran the FUSE preflight before argparse, so a host without `/dev/fuse` never saw usage. Argument parsing now happens first; a failed `zig build` inside that driver prints on stderr. `dr_restore_drill.sh` treated a dash-prefixed token as a dataset name (so `--not-a-flag` started a drill); unknown flags now exit 2 with `Usage:`. Helper usage lines that mixed `usage:` and `Usage:` now match `Usage:`. `scripts/test_scripts_help.sh` covers the Python CLIs and the drill script.

### NAS backup units and drill-log alarm - 2026-08-27
- **Pool-loss restore no longer points at a stream file this repo never writes.** Procedure C said `zfs recv -Fs tank/models < latest.zfsstream` while section 3's backup is a syncoid replica; following the runbook after a dead NAS dead-ended. It now pulls with `syncoid --force-delete` from the replica host (or `zfs send -R | zfs recv -Fs` from a locally imported replica) and sets the export properties after the dataset exists.
- **Backup and drill schedules are files, not paste-blocks.** `scripts/nas/` holds `sanoid.conf`, the replica **pull** timer (runs on the replica host so NAS root cannot destroy both copies), monthly drill and daily drill-log timers, and `OnFailure=` drop-ins on the **services** (a drop-in on `sanoid.timer` stayed green while `sanoid.service` failed to snapshot). `scripts/install_nas_backup.sh` copies them (dry-run by default; `--install` writes; `MF_NAS_DEST` prefixes the tree). `notify-admin@.service` logs a syslog line until a site mailer replaces it. The replica unit `zfs hold`s monthly snapshots.
- **A missed monthly drill is a daily alarm.** "Alert when the log ages past 35 days" was prose. `scripts/check_drill_log.sh` fails on a missing, empty, unparseable, future, or too-old log stamp; `modelfs-drill-log.timer` runs it. The drill now fails before clone if the artifact log is unwritable, uses `MF_DRILL_MAX_REPLICA_AGE` (default 36 h) so a daily syncoid is not a 25 h false alarm, and runs from `/usr/local/sbin` without the repo (scratch falls back to `/var/tmp/modelfs-drill`).
- **operations.md's NAS setup now requires the recovery timers.** Scrub and smartd were the only scheduled NAS jobs in the ops runbook, so a reader who never opened recovery.md brought up an origin with no snapshot.

### Upgrade from v0.1.0 - 2026-08-27

CLI, peer-wire, FUSE, and on-disk changes that will surprise a node still
running the tagged binary, or a script written against it. A mixed
fleet with `v0.1.0` peers still fills: those servers already send
`Content-Range` on every 206. A `status.json` they wrote still
parses: the tag never published `now_s`, `mono_s`, or `origin_down`,
so without a stamp `modelfs status` uses the pid check only. Details
stay in the entries below.

- **`modelfs status` exits 1** on a leftover or wedged `status.json` (was 0 with the stale document printed).
- **Unauthenticated peer requests, including POST, are 401** (was 405 before the token was checked).
- **An origin path too long to name is 400**, not 502.
- **`Content-Length` and `X-Piece-Size` are unsigned decimal digits**; a signed or grouped length is refused. **`/data` fetches require a matching `Content-Range`.**
- **Origin, cache, `status.json`, and `.cluster` lease opens use `O_NOFOLLOW`.** Hugging Face hub-cache snapshot trees will not serve through the mount; `hf download --local-dir` writes regular files.
- **Cache data files are 0600** (were 0644); leftover 0644 files are tightened on the next open. `data/`/`meta/`/`pin/` are 0700; leftover 0755 dirs are tightened on the next `ensureLayout`. `meta/*.pieces` and `pin/` markers are 0600.
- **`status.json` is 0600** (was 0644); leftover 0644 files are tightened on the next publish.
- **Peer `/have` and `/data`, and `modelfs pin`, refuse `.cluster` paths** (were served or pinned as origin-relative names).
- **`--kernel-cache` enables the kernel page cache** (the flag used to leave `kernel_cache` off).
- **Mount refuses** `--listen`/`--advertise`/`--seed` port 0, `--advertise`/`--seed` `0.0.0.0` and `255.255.255.255`, origin overlapping the cache, `MODELFS_PSK_VALUE` combined with `--psk`/`MODELFS_PSK`, empty `--origin`/`--cache`/`--psk` or mount directory, a regular file at `--origin`/`--cache`/the mountpoint, and a whitespace-only `MODELFS_PSK_VALUE` (surrounding whitespace is now trimmed like the PSK file).
- **Usage errors print one named line** (no help dump).
- **Harness and drill knobs are `MF_TEST_*` / `MF_DRILL_*`** (were `MODELFS_TEST_*` / `MODELFS_DRILL_*`).
- **U+2028 / U+2029 and bidi format controls in paths are refused.**
- **Zero-width format controls, variation selectors, and BOM in paths are refused.**
- **Soft hyphen, combining grapheme joiner, Hangul fillers, tags, and VS17-256 in paths are refused.**
- **A world-readable PSK file is refused** (was a warning). Group-readable still warns.
- **Mount refuses to start if core dumps cannot be disabled** after the PSK is loaded.
- **`mkdir` of an existing directory through the mount is success** (was EEXIST). A non-directory at that name is still EEXIST.
- **A write whose `close` fails is an error** (NFS delayed-write). v0.1.0 reported success after a successful pwrite even when close failed.

### Changes

- **Daemon composition teardown lives on `State`**: mount shutdown used to live in `main.zig` next to CLI parsing, and tests deinit'ed the cache and catalog by hand (one even constructed `State` field-by-field and poked `Server.store`). `State.deinit` is the pair of `State.init`: it stops workers, drains inflight peer handlers, and releases the store and catalog. The libfuse session entry (`fuse_fs.run`) sits next to `ops()`, so the CLI no longer speaks libfuse types. Mount-time `disableCoreDumps` / `scrubPskEnv` moved out of `sys.zig` (syscall wrappers, no policy beyond EINTR retry) into `cmdMount`.
- **Operator docs match intake and PSK setup:** README no longer claims GitHub private vulnerability reporting is live (SECURITY.md is the intake; that feature is off). The PSK quickstart generates once and copies the same file; regenerating per node would desync the fleet. `sys.zig` is the syscall layer (CLOEXEC, owner-only writes, core-dump disable, PSK env scrub), not "no policy beyond EINTR retry". `MODELFS_ID` is mount-only like `--id`; `modelfs pin`/`unpin` both refuse `.cluster`; `modelfs status` as another uid is EACCES, not "not running".

- **A FUSE read no longer hangs when local writes keep discarding piece fills**: `hydratePiece` retried unbounded after `completeFill` dropped a claim whose write generation had moved, so a file being overwritten stalled the FUSE worker. One origin retry is recovery; a second discard returns EIO so the client retries instead of hanging or serving hole zeros.
- **A zero-duration piece fetch no longer pulls path goodput toward 0 B/s**: `rangeBps` already returned 0 when the clock did not advance (same-ns sample on a tiny `--piece`), but `Catalog.updateGoodput` treated that as a real 0 B/s observation and pulled the EWMA 30% toward zero; Inf/NaN would have poisoned `pickBest` the same way. Those samples are skipped.
- **Drill age knobs are decimal even with a leading zero**: bash `[[ -gt ]]` treats `08` as invalid octal (abort) and `010` as 8. `MF_DRILL_LOG_MAX_AGE`, `MF_DRILL_MAX_SNAP_AGE`, and `MF_DRILL_MAX_REPLICA_AGE` now force base 10, and a digit run longer than 10 is refused so `$(( ))` cannot wrap.
- **Leftover world-listable cache dirs and 0644 sidecars/pins are owner-only**: `ensureLayout` created `data/`/`meta/`/`pin/` at 0700 but left an existing 0755 dir alone, so a node upgraded from a pre-0700 daemon still let any local uid `ls` which weights were cached or pinned. Layout now fchmods those three roots to 0700 through an `O_DIRECTORY|O_NOFOLLOW` fd. `meta/*.pieces` and `pin/` markers are created 0600 (`writeFileOwnerOnly` / `writeFileOwnerOnlyDurable`); leftover 0644 files tighten on the next write, matching cache data and `status.json`.
- **The CycloneDX inventory records GitHub Action licenses and commit hashes, and the Zig pin**: `scripts/sbom.py` used an unanchored `.version` match that also hit `.minimum_zig_version`, so reordering those fields in `build.zig.zon` would stamp the toolchain version onto the application component. The parser now matches a whole identifier (the same line-anchored rule `scripts/check.sh` uses). Each `uses:` pin carries SPDX (LICENSE at that commit) and a SHA-1/SHA-256 hash; a new action without an `_SPDX` entry fails generation. `minimum_zig_version` is inventoried as `pkg:github/ziglang/zig`. SHA256SUMS parsing rejects uppercase hex and duplicate names, and listed `.deb` files must exist on disk.

- **Cache size changes take the content lock, and a shrink bumps the write generation**: `mf_truncate`, `Store.reconcileSize`, and `cacheFill`'s external-shrink path took only `file.mu` while `copyIntoCache` / `completeFill` hold `content_mu` across pwrite then mark. An ftruncate in that window cut the just-written bytes, and a shrink that left `writes` unchanged let a fill claimed against the old generation mark pre-shrink bytes on the new field. All three now take `content_mu` then `file.mu` (the same order as `punchPiece`); shrink bumps `writes` and cuts the cache fd like reconcile. A failed bitfield alloc in `mf_truncate` uses `truncateCacheFd` so it cannot ftruncate under a peer `/data` sendfile.
- **The CycloneDX inventory now carries SPDX licenses, GitHub Actions, and a lock-line gate**: `sbom.cdx.json` omitted licenses on every component, skipped the SHA-pinned workflow actions, and dropped unrecognized lock lines instead of failing, so a URL-dep or `uses: org/repo@vN` would not show up. `scripts/sbom.py` records SPDX ids (failing closed on a new lock package without one), lists each unique `uses:` commit, refuses a moving tag, and requires every bounds-file name to appear in the lock. `--self-test` pins those parsers; `check.sh` runs it before `--check`.
- **design.md records the decisions the code actually shipped**: Frontend is superseded (FUSE `direct_io`, not passthrough), Transport/Auth/Kubernetes sit in the decision table instead of leftover open questions, and section 12 points at those rows.
- **Zero-width format controls, variation selectors, and BOM no longer pass the path and echo gates**: `relOk` and `discover.printable` already refused C0/DEL, UTF-8 C1, U+2028/U+2029, and bidi format controls, but a planted path `gguf/model\u200B.bin` or lease id `spark1\u200B` still echoed as the unadorned name, as did U+200C/U+200D, U+2060..U+2064, U+206A..U+206F, U+FE00..U+FE0F, and a leading U+FEFF. Those sequences are refused now; incomplete encodings and visible punctuation in the same UTF-8 blocks (U+2010 hyphen, NBSP, emoji without a selector) stay legal display text.
- **Soft hyphen, CGJ, Hangul fillers, tags, and VS17-256 no longer pass the path and echo gates**: the previous Default_Ignorable pass covered BMP variation selectors and zero-width format controls, but a planted path `gguf/model\u00AD.bin` or lease id `spark1\uE0100` still echoed as the unadorned name, as did U+034F, U+115F/U+1160/U+3164/U+FFA0, U+180B..U+180E, U+1D173..U+1D17A, and U+E0000..U+E0FFF (tags and VS17-256). Those sequences are refused now; incomplete encodings and visible neighbours in the same UTF-8 blocks (U+00AC, U+180A, U+FFFC) stay legal display text.
- **Peer status-line matching and leftover `status.json` parsing are now fuzzed**: `httpStatusIs` is asserted against an independent 3-digit oracle in the extractor harness so a `2000`/`200OK`/`4040` reply cannot silently match `200`/`404` again, and `cmdStatus`'s liveness parse plus `statusAgeSecs` fail closed on arbitrary leftover documents including hostile i64 stamps.
- **Enumeration order no longer decides membership, probes, or cache eviction**: `Catalog.refresh` sorts live paths by (peer id, ip, port) so lease-directory readdir cannot choose snapshot or probe-group order; `groupPathsByPeerId` sorts the outer list by peer id the same way; `leaseAddrs` and `localIpv4` sort by ip then port so the published lease is a function of the NIC set, not `getifaddrs` or `--advertise` flag order. Have-cache overflow still prefers expired lines then soonest expiry, but equal TTL (concurrent `/have` probes of one fill share one clock sample) now breaks by (rel, ip, port) instead of which worker locked `have_mu` first. `reapIdle` unlinks equally idle empty entries by rel, matching `cullOne`. `sweepLeases` unlinks stale claims in filename order so a crash mid-sweep cannot leave an NFS-readdir remainder; `modelfs peers` sorts each lease's addresses by ip then port like the published document; unknown `MODELFS_*` typos name the lexicographically first offender, not HashMap iteration order.
- **Python and shell analysis take every stable extra the tree already passes**: ruff selects `ALL` so a new defect prefix cannot stay off by omission (CLI `print`, formatter-owned trailing commas, pydocstyle, copyright headers, and the benchmark driver's remaining `os.path` calls are the documented exceptions). mypy now also runs `local_partial_types` plus PreciseTupleTypes and InlineTypedDict. `.shellcheckrc` carries the optional checks so a bare `shellcheck scripts/*.sh` matches the gate.
- **A FUSE write-through retry no longer bumps the write generation**: `copyIntoCache` of bytes that already fully cover marked pieces re-pwrites the same range but skips the generation bump and sidecar rewrite, so a lost-reply retry matches one copy instead of invalidating in-flight fills of other pieces. A failed copy still bumps and unmarks. `mkdir` of a path that already exists as a directory is success (`Store.mkdirOrigin`), the FUSE retry after a lost reply; a non-directory at that name is still EEXIST. `sys.mkdirAll` treats EEXIST as success only when the name is a directory (a file is ENOTDIR, a symlink ELOOP).
- **`zig build` compiles again**: the mount path logged a no-arg `std.log.err` after a failed `disableCoreDumps`, which Zig 0.16 rejects (`expected 2 argument(s), found 1`). Unit tests never reached that function (lazy analysis: `main` is not referenced from the test binary), so `zig build test` stayed green. The aarch64 ship-binary check now reads ELF `e_machine` instead of `file(1)` text: GNU file's "ARM aarch64" wording varies by version and locale, so a correct `aarch64-linux-gnu.2.39` binary could fail `scripts/cross_aarch64.sh` on a host CI does not run. `zig build` fails non-Linux targets with a named message instead of falling into missing fuse headers or glibc sockaddr unions. Vendored `.deb` files are `binary` in `.gitattributes` so a CRLF checkout cannot invalidate SHA256SUMS. `sys.errno` uses libc `_errno` (the pointer Zig ships for every Linux ABI) rather than the glibc `__errno_location` name translate-c exports.
- **`status.json` is owner-only (0600)**: it used to be created 0644 at the cache root, so any local uid that could search `/var/cache/modelfs` read pid, peer count, cache fill, and `origin_down`. New publishes are 0600; leftover 0644 files are tightened on the next tick (`writeFileOwnerOnly` in src/sys.zig).
- **Peer `/have`/`/data` and `modelfs pin` hide `.cluster`**: FUSE already answered ENOENT/EPERM for the lease directory, but a PSK holder could `GET /data?path=.cluster/<id>.json` and hydrate lease JSON into the piece cache, and `modelfs pin .cluster/...` would mark those names. Both now refuse (`relIsCluster` in src/discover.zig); a model named `.clusterfoo` is still reachable.
- **Origin writes fail when `close` fails after a successful pwrite**: NFS reports delayed write errors on close. `originPwrite`, `writeFile*` (lease/status/sidecar staging), and FUSE create/truncate now return that errno instead of reporting success over missing bytes. Linux `EINTR` on close is treated as success (the descriptor is already gone).
- **Documented contributor scripts answer `--help` instead of starting work**: `run_e2e_tests.sh`, `run_cluster_e2e_9nodes.sh`, `test_fault_tolerance.sh`, `test_dr_restore_drill.sh`, and `repro_check.sh` ignored `-h`/`--help` and ran the suite (nine FUSE mounts, two ReleaseFast rebuilds). They now print usage and refuse unknown arguments, matching `check.sh` / `ci.sh`. README points at CONTRIBUTING.md for clone setup. `scripts/test_scripts_help.sh` pins the handlers in the gate.
- **A failed write-through copy drops overlapping piece marks**: `copyIntoCache` used to bump the write generation (so peer fills take the origin) but leave already-filled bits set when the cache pwrite or open failed. Local reads and `/have` then served pre-write cache bytes after origin already held the new ones. Overlapping pieces are unmarked and the sidecar is saved; `punchPiece` takes the same content lock as the copy so a cull cannot hole a piece between that pwrite and its mark.
- **`zig build test` now links the shipped binary and checks its ELF hardening**: the test binary does not reference `pub fn main`, so a `std.log.err` call in `cmdMount` with no args tuple compiled in the gate and failed only on `zig build -Doptimize=ReleaseFast`. The test step now depends on the executable, `cmdMount` passes `.{}`, stack probes are pinned on in every optimize mode like the canaries already were (`stack_check`, same ReleaseFast default-off as `stack_protector`), and CheckObject fails the build unless the image is a PIE with full RELRO, BIND_NOW, and a non-executable stack.
- **SECURITY.md names GitHub private vulnerability reporting as intended, not enabled**: that feature is off on the repository, so there is no private inbox. docs/THREAT_MODEL.md matches, and records the local-user surface (cache dirs 0700, origin statvfs/chmod/readdir lstat+ELOOP, disk-cull of dot-prefixed names, owner-only `status.json`).
- **Origin stat, pread, and pwrite raise `origin_down`**: FUSE getattr/open/read/write already called `noteOriginIo`; a fill or peer `/have`/`/data` hydration that hit EIO/ESTALE/ETIMEDOUT after a successful stat (or with no local FUSE traffic) left `status.json` at 0. `statOrigin`/`originPread`/`originPwrite` now share `noteOriginIo`, so an NFS outage on any origin data path is visible without a later getattr.
- **Peer fetch warns name a timed-out dial as `ConnectTimeout`**: a spent or elapsed connect budget used to surface as `error.Connect`, so a blackholed peer looked like a refused port. Same split `readHeadFull` already makes for `HeadTimeout`.
- **A sidecar path that does not fit no longer skips `distrust`'s live mark wipe**: returning before the lock left in-memory bits set after a write whose size could not be observed. The sidecar unlink is still skipped when the path cannot be named; the live entry's marks drop either way.
- **`disableCoreDumps` logs if `setrlimit` fails**: a crash could still write the cluster PSK and the journal said nothing. Punch of a live piece whose cache fd cannot be opened, and a disk-only punch whose data file open fails for a reason other than ENOENT, also warn instead of returning false with no line.
- **`MODELFS_PSK_VALUE` trims surrounding whitespace like the PSK file**: an EnvironmentFile newline or a copied secret with a trailing space used to start the daemon then 401 every peer (`bearerOk` trims the received token but hashes the stored secret verbatim). Whitespace-only values are empty and refused. `ensureDirReal` now refuses a regular file at the cache or mountpoint with "not a directory" instead of a later ENOTDIR from layout mkdir. `--advertise`/`--seed` refuse `0.0.0.0` and `255.255.255.255` (`isDialableHost`); parseV4 admits them because inet_pton does, but neither is a unicast address a peer can dial. Auto-detect skips them too. An empty mount directory is refused at parse.

- **Healthy `/have` 404s are cached for the same 2 s TTL as hits**: a sequential fill used to re-dial every peer that already answered "not cached here" on every 16 MiB piece. Connection failures stay uncached so a down peer is still retried on the next piece. Once every live peer has a cache line, `fillFromPeers` skips the catalog snapshot and probe threads (`Catalog.collectCachedCands`).
- **`reapIdle` no longer holds the store lock across pin stats and bitfield scans**: the same split `cullOne` already made. Idle emptiness uses `lastSet` (returns on the first set bit) instead of counting every bit with `filled()`.
- **CI pins the Python interpreter and uv, and the libfuse3-dev apt retry lives in one script**: setup-uv installed latest uv and did not pass `.python-version` into `python-version`, and the uv cache key ignored that file, so a pin bump could restore a venv built for the previous interpreter. The check job now reads `.python-version` into setup-uv, keys the cache on it, and `[tool.uv] required-version` in pyproject.toml is the uv range setup-uv already looks for. The duplicated apt retry in the check and reproducibility jobs is `scripts/install_libfuse3_dev.sh` (DEBIAN_FRONTEND on the sudo command line, because sudo resets the environment).
- **Origin sizes that do not fit `off_t` fail the op instead of wrapping into piece math**: NFS fattr is u64, so a size of 2^63 or more shows up as a negative `st_size`. `@intCast` into cache/piece arithmetic panicked in safe builds and became a multi-exabyte bitfield in ReleaseFast (`st_size = -1` is 2^64-1 bytes). Negative sizes now fail closed (FUSE EIO, peer 502, cull skip). I/O wrappers return `EFBIG` for offsets that do not fit `off_t` rather than truncating into a kernel syscall.
- **Tick-line per-op averages divide by the time unit first**: `count * ns_per_us` of a u64 counter overflows the divisor (panic in safe builds, wrapped `rd_us`/`http_us` in ReleaseFast). Same integer mean, no intermediate multiply.
- **Bidi format controls no longer pass the path and echo gates**: `relOk` and `discover.printable` already refused C0/DEL, UTF-8 C1, and U+2028/U+2029, but a planted path `gguf/a\u202Egnp.bin` or lease name carrying U+200E/U+200F, U+202A..U+202E, U+2066..U+2069, or U+061C still echoed into the journal and `modelfs peers`, spoofing the displayed identity. Those sequences are refused now; incomplete encodings stay legal display noise.
- **A world-readable PSK file is refused at load**: group/other bits used to warn and continue, so a `0644` `/etc/modelfs.psk` let any local user steal the cluster credential. Other bits now fail the mount; group-readable still warns. The check uses the fstat of the fd that was read, not a later path-stat.
- **Mount fails if core dumps cannot be disabled**: `setrlimit(RLIMIT_CORE, 0)` failure used to be ignored after the PSK was in memory, so a crash could still dump the secret. The mount now exits instead.

- **Disk culling visits cache files whose names start with a dot**: `walkData` skipped every readdir name with a leading `.`, which hid `.` and `..` but also `.hidden.gguf` and `dir/.cache/w.bin` -- paths `relOk` admits. After a restart those files never became disk-cull victims, so they filled the cache filesystem past the watermarks. Only `.` and `..` are skipped now.
- **Nested `pin/` and `meta/` directories are owner-only (0700)**: `data/` nested parents already used 0700, but `setPin` and sidecar saves created `pin/gguf` and `meta/gguf` as 0755, so a local user blocked by origin modes could list which nested weights were pinned or cached. All cache-tree mkdirs share `cache_dir_mode`.
- **Origin outages are visible from `modelfs status` and from getattr/open**: `origin_down` rides status.json (1 while an EIO/ESTALE/ETIMEDOUT origin op has not recovered). FUSE getattr and open now raise the same edge-triggered journal (`origin stat failed` / `origin recovered`) that read and write already did, so an NFS outage during `ls` is no longer silent until a read fails.
- **Peer-serve latency is on the tick line**: `/have` and `/data` accumulate `http_nanos`; the tick line publishes `http_us`, the serving-side twin of `rd_us`.
- **Cluster membership changes reach the journal**: losing or gaining peers logs `cluster peers N -> M` even when no counters moved, so an idle node that goes peerless is visible without waiting for the next fill. A `.cluster` path that does not fit PATH_MAX now warns like a missing directory instead of freezing the peer list silently. Accept-loop recovery logs `accept recovered` after a failure run.

- **`/have` probes one address walk per peer, not every path**: architecture.md's miss sequence said GET /have went to all paths. `probeCandidates` walks one best-first address list per `peer id` (a dead preferred NIC falls through to that node's remaining interfaces) and `pickBest` breaks score ties by ip then port so lease `getifaddrs` order cannot pick the winner. `modelfs help` states that a defaulted `--advertise` port follows `--listen`.
- **`./scripts/check.sh` includes the restore-drill stub and the SBOM check**: README's Tests comment and the script's `--help` summary omitted them while CONTRIBUTING and the script body already ran both.
- **Peer reply status codes are exactly three digits, and a 206 body's length must match its Content-Range**: prefix matching `"HTTP/1.1 200"` also accepted `2000` and `200OK`, and `4040` counted as a healthy `/have` miss. The fetch client now requires RFC 9110 `3DIGIT` after `HTTP/1.1`, treats an advertised `X-Piece-Size: 0` as a bad grid (absence is still unknown), and refuses a 206 whose `Content-Length` disagrees with the selected Content-Range window so a short body cannot be marked filled under the requested piece bounds.

- **Unauthenticated peer requests always get 401**: a POST (or any non-GET) without a valid bearer used to answer `405 Allow: GET` before the token was consulted, so a scanner learned the listener was a GET-only peer service. Auth now runs first; 405 is only for an authenticated client using the wrong method. docs/THREAT_MODEL.md matches that order.
- **Peer reply lengths are decimal digits, like Range**: `Content-Length` and `X-Piece-Size` used `parseInt`, which accepts a leading `+` and interior `_` that RFC 9110 `1*DIGIT` and the Range parser both refuse. A signed or grouped length is now `BadContentLength` / `BadPieceSize` so a body cannot be sized differently from a Range the same peer sent. Missing or empty `path` on `/have` and `/data` stays 400, now named in the architecture status table.
- **A crashing daemon no longer dumps the cluster PSK**: mount sets `RLIMIT_CORE` to zero after loading the secret, wipes `MODELFS_PSK_VALUE` from the environment so the `auto_unmount` helper cannot inherit it, and `secureZero`s the in-memory copy on teardown.
- **Cache data files are owner-only (0600)**: they used to be created 0644, so a local user blocked by origin modes and FUSE `default_permissions` could still read cached weights from `/var/cache/modelfs/data`. New files are 0600, leftover 0644 files are tightened on the next open, and `data/`/`meta/`/`pin/` are created 0700.
- **The Python and shell gates now run bandit, future-annotation, stub, and useless-cat checks**: ruff's S/FA/PYI groups and shellcheck `useless-use-of-cat` were off while the rest of the gate was already strict. Probe scripts share an http(s)-only opener, and a failed `/ping` or empty `/have` is an explicit exit so `python -O` cannot skip it.
- **Peer fetch warns name a timed-out head as `HeadTimeout`**: `/have` and `/data` client paths collapsed every `readHeadFull` failure into `error.Head`, so a deadline abort looked like a truncated request. The wrappers now keep `HeadTimeout` and `HeadTooBig`.
- **A `/have` or `/data` header that cannot be formatted replies 500**: those paths dropped the connection with no status and no journal line, so the fetching peer retried while this node looked idle.
- **Cull punch failures reach the journal**: `punchPiece` and `punchDisk` returned false on `fallocate` failure with no line, so a cache fs that cannot hole-punch filled up with only `culled=0` on the tick line.
- **Sidecar save and cache open failures that previously returned false with no line now warn**: `saveBits` path-too-long, FUSE `open` cache-entry OOM, fill-claim OOM, and cache `open`/`ftruncate` errno. A post-write fallback no longer claims "stat failed" when `get()` was what failed. Peer origin hydration distinguishes a short pread from an errno, matching the FUSE fill path.
- **A truncate that cannot allocate the new bitfield no longer keeps pre-truncate marks**: origin is already the new length; leaving filled bits at the old size let a concurrent read serve cache bytes past the new EOF.

- **Python gate tooling no longer pulls matplotlib**: the lock installed numpy, pillow, fonttools, and the rest of that tree so mypy could type-check the benchmark plotter, and every CI job paid for it. Figures are SVG written with the stdlib; `requirements-dev.txt` is ruff and mypy only.
- **Vendored libfuse3 hashes live in one file and are checked before unpack**: extract used to test only that the `.deb` files exist; `build.zig` and the README each copied the digests. `.deps/fuse3-arm64/SHA256SUMS` is the list extract verifies, `build.zig` reads, and `check.sh` checks. NOTICE and the Debian copyright file sit beside the debs.
- **A CycloneDX inventory is generated from the lock and the vendored debs**: `scripts/sbom.py` writes `sbom.cdx.json`; `check.sh` fails if it drifted.
- **The peer request fuzz corpus compiles again**: two C1-path seeds were both named `seed_req_c1_path`, so `zig build test` died with a duplicate struct member. The CSI-shaped seed is `seed_req_c1_csi_path`.
- **Mount fails fast on silent misconfiguration**: `--listen`/`--advertise`/`--seed` port 0 used to bind (or publish) an undialable address while the lease still said `:0`; origin overlapping the cache wrote piece files onto the shared store; `MODELFS_PSK_VALUE` plus `--psk` or `MODELFS_PSK` silently preferred the env secret; empty `--origin`/`--cache`/`--psk` failed later as "not reachable"; and an over-long `MODELFS_PSK_VALUE` started the daemon then failed every peer head. Each is refused at parse or load with a named message. `modelfs help`, README, docs/architecture.md, and docs/THREAT_MODEL.md match.
- **`--advertise` is the lease address list, not extra addresses**: `modelfs help` called them extra, which reads as additive on top of auto-detected NICs. A non-empty `--advertise` replaces that list; with no qualifying NIC the lease publishes 127.0.0.1. `--seed` applies while `.cluster` has no live lease, not only when the directory is empty. README and architecture.md match.
- **Unicode line/paragraph separators no longer pass the path and echo gates**: `relOk` and `discover.printable` already refused C0/DEL and UTF-8 C1 so a planted name could not inject into the journal or a terminal, but U+2028/U+2029 (the remaining Unicode line terminators) still passed. A peer path `gguf/a\u2028ERROR.bin` or a lease id `spark1\u2028ERROR forged` would split a log line or `modelfs peers` listing. Both gates now refuse those sequences; incomplete encodings stay legal display noise, matching a trailing 0xC2.
- **`--kernel-cache` actually enables the kernel page cache**: `mf_init`
  hardcoded `kernel_cache = 0`, so the flag only flipped `direct_io` off
  (mmap could succeed) while the page cache stayed disabled. It now
  mirrors `direct_io`, which is the UMA-RAM tradeoff the flag documents.
- **`modelfs status` no longer treats a leftover `status.json` as live**: a
  document naming an exited pid, or whose `now_s` is more than 120 s old,
  now exits 1 instead of printing the stale artifact. `now_s` is optional
  so a leftover from `v0.1.0` still parses; without it only the pid check
  runs. Saturation at the 16-handler cap is visible as `http_dropped` /
  `httpdrop` on the tick line and in the document.
- **`modelfs status` no longer flaps on an NTP step.** The wedge gate compared `now_s` (CLOCK_REALTIME) to the CLI's wall clock, so a forward jump of more than 120 s retired a ticking mount until the next discovery tick, and a backward jump kept a hung daemon looking live. `statusJson` now publishes `mono_s` (CLOCK_MONOTONIC, comparable across processes on that machine); `cmdStatus` prefers it and saturates the age subtract so a hostile i64-min stamp cannot overflow. Wall-clock `now_s` remains for operators and as the fallback for older artifacts.
- **`modelfs status` retires a leftover `status.json` after reboot.** CLOCK_MONOTONIC resets, so a previous-boot `mono_s` is larger than now; saturating `now - stamp` read as age 0 and, with pid reuse, served a crash leftover as live. Age is the absolute monotonic gap, so a future or previous-boot stamp is stale.
- **Lease sweep ages files on the origin's clock.** `sweepLeases` compared NFS mtimes to the node's CLOCK_REALTIME, so a NAS five minutes behind the sparks made every live peer look idle and unlinked their leases. The cutoff is this node's own lease mtime on that filesystem (fallback: the caller's wall instant when we have no lease file).
- **Restore drill fails a snapshot whose ZFS creation is in the future of the host clock.** A backward NTP step made `SNAP_AGE` negative, which passed the RPO check as if the snapshot were fresh.
- **Restore-drill log stamps are UTC, and clone elapsed time ignores wall-clock jumps.** `date -Is` wrote local time with a DST offset, so lexicographic order of the log disagreed with instant order around fall-back, and `date +%s.%N` around the clone would log a negative or huge RTO if NTP stepped. New lines use `YYYY-MM-DDTHH:MM:SSZ`; clone duration is `/proc/uptime` (CLOCK_BOOTTIME).
- **Origin, cache, status.json, and lease opens do not follow a planted symlink**:
  `originPread` / `originPwrite`, cache data opens, `cmdStatus`'s
  `status.json` read, and `cmdPeers` lease reads use `O_NOFOLLOW`,
  so a symlink at a model path, a leftover status artifact, or a
  `.cluster` lease name fails closed (`ELOOP`) instead of serving
  the link's target. Weight files on the origin must be regular files: a
  Hugging Face hub-cache snapshot tree (symlinks into `blobs/`) will not
  serve through the mount; `hf download --local-dir` (the llama.cpp
  example in operations.md) writes regular files.
- **A path too long to name under the origin answers 400, not 502**:
  `replyOriginStat` treated `ENAMETOOLONG` as an origin failure, which
  fed `http_5xx` and sent peers retrying every node for a request that
  can never succeed.
- **The test binary compiles again**: the status.json rename-failure test
  called `status_file`, which is not in scope in `fuse_fs.zig`, and the
  cold-sidecar wipe test called `sys.monoSec()` without the `std.Io` the
  function takes. `zig build test` failed to compile. The former uses
  `Store.cacheStatusPath` like the sibling liveness test; the latter
  passes `std.testing.io`.
- **Vendored arm64 libfuse3 extraction is hermetic**: digests live in `.deps/fuse3-arm64/SHA256SUMS` (the one list `build.zig` and the extractor both check), the extractor verifies them before unpack, wipes the output directory so a previous extract cannot leave stale headers, and writes under `.scratch/fuse3-arm64/` instead of mutating `.deps/`. The `ar` fallback no longer requires a `zstd` binary when `tar --zstd` is available. `scripts/cross_aarch64.sh` runs the extractor, so CI and `scripts/ci.sh` no longer duplicate that step; `scripts/check.sh` checks the digests and a stale-tree extract.
- **A stale cache sidecar no longer survives a cold size change**: `Store.get` on a miss used to load an empty field when the on-disk sidecar's piece or file size did not match, but left that sidecar on disk. After a restart, a file restored to the previous length decoded the old marks and could serve pre-truncate bytes (or hole zeros) as current. The miss path now persists the wipe the live-entry path already did. `create` (`O_TRUNC`) and `truncate` with no live entry also `distrust` the path, matching the identity drop unlink and rename already perform.
- **A local write is no longer clobbered by a racing peer fill**: `copyIntoCache` and `completeFill` now serialize on the cache fd, and a fill claimed before the write is dropped if the entry's write generation moved. Miss hydrations on a node that has written the path go to the origin rather than peers, so a subsequent miss cannot resurrect pre-write peer bytes as the writer's own read.
- **Peer `/data` fetches require `Content-Range` to match the request**: the 206 body was accepted on `Content-Length` alone, so a same-sized window at a different offset (or a 200 of the file prefix) would be marked filled. The client now requires a 206 whose `Content-Range` start is the requested start and whose end is at most the requested end (EOF clamp). `v0.1.0` servers already send that header on every 206, so a mixed fleet still fills; replies that omit it or advertise a different window are what fail.
- **The aarch64 cross-compile recipe lives in one script**: CI's `cross-aarch64` job and `scripts/ci.sh` each inlined `zig build -Dtarget=aarch64-linux-gnu.2.39 -Doptimize=ReleaseFast` plus the vendored fuse paths and an ELF-machine check (`grep -q` in CI, a named `file` case in ci.sh). They now both run `scripts/cross_aarch64.sh`, so a flag edit cannot pass CI while failing a local pre-push (or the reverse). README, docs/architecture.md, and the vendored fuse README call the same script.
- **NAS firewall no longer opens NFS to the world**: operations.md's `--add-service={nfs,rpc-bind,mountd}` allowed those services from every source in the default zone, so the LAN rich rule was a no-op despite the comment claiming it limited NFS to `192.168.0.0/24`. Only the source-filtered rich rules remain.
- **CI runners match the spark OS, and apt flakes retry**: jobs pin `ubuntu-24.04` instead of `ubuntu-latest`, checkout does not persist credentials into `.git/config`, and the libfuse3-dev install retries three times. `minimum_zig_version` remains the toolchain CI installs; CONTRIBUTING no longer claims a parallel 0.16.0 pin.
- **Peer listen and cache fds are close-on-exec.** `bindAll` opens the listen socket before `fuse_main`, and `auto_unmount` keeps a fusermount helper for the life of the mount; without `SOCK_CLOEXEC`/`O_CLOEXEC` that helper inherited the port (and later cache fds), so `Server.stop` could not release it and a restart failed to bind. `sys.socket`, `sys.accept`, and `sys.open` set the flag. Lease and `status.json` staging files are unlinked when the write or rename fails, so a retrying tick cannot pin a leftover `.tmp` by refreshing its mtime past `sweepLeases`.
- **A node serving pieces is visible in status.json**: peer HTTP only counted failures (`http_5xx`, `http_unauthorized`, `http_malformed`, `http_dropped`), so a busy serving node was indistinguishable from an idle one. Accepted `/have` 200 and `/data` 206 replies now increment `http_ok`, and their Content-Length increments `bytes_to_peer` (`serve_mib` on the tick line). `/ping` stays uncounted. Origin hydrations done to satisfy a peer fetch feed `fills_origin` / `fill_err_origin` / `fill_err_cache` like the FUSE path already did, so "why is this node hitting NFS" is answerable when the work is for the fleet.
- **FUSE origin outages leave a journal line**: `mf_read` counted origin-stat failures in `reads_err` but logged nothing, so an NFS outage showed up as a rising error rate with an empty journal. The first infrastructure failure (EIO/ESTALE/ETIMEDOUT, not ENOENT) now logs path and errno; later ones stay counted-only until recovery logs `origin recovered` (`Store.noteOriginIo`). Write failures share the same edge. Cache-entry OOM on read warns like the peer-HTTP twin.
- **Write latency and cache warmth ride the tick line**: `wr_us` is the per-write average over the interval (origin NFS stall), and `reads_warm` counts fully-cached FUSE reads so hit rate is `reads_warm / reads_ok`.
- **Long options accept `--name=VALUE`**: `--origin=/nas/models` (and the same form on every other value flag) was an unknown flag; both `--name VALUE` and `--name=VALUE` now parse. Boolean flags with an attached payload (`--detach=true`) are refused with a named message and exit 2.
- **`help`/`version` honor `-h`/`--help`**: the help text promised every command accepts those flags, but `modelfs version --help` exited 2 because extras were refused before any flag scan. Global help/version flags on those commands now succeed; a real extra still exits 2.
- **Usage errors are one named line, not a help dump**: missing operands, extra positionals, and a missing `--origin` printed the full usage blob through the logger prefix; they now match the unknown-flag channel (plain stderr, `see 'modelfs help'`). `--advertise` trims spaces in comma-separated lists. A refused pin path is rejected before cache dirs are created. Helper scripts send errors to stderr and answer `--help`.

- **`--seed HOST` no longer depends on a non-loopback IPv4 address being configured**: `resolveIpv4` used `getaddrinfo` with `AI_ADDRCONFIG`, which glibc treats as "no IPv4" when the only IPv4 address is loopback, so a hostname seed failed on a loopback-only or IPv6-first host. Numeric quads now go through `inet_pton` (and spellings `inet_pton` refuses, like leading zeros, are not re-parsed by `getaddrinfo`); name lookup drops `AI_ADDRCONFIG` because `AF_INET` already restricts the family.
- **Durable sidecar writes retry `fsync` EINTR correctly**: the raw `linux.fsync` return is a `usize` with `-errno` in the high bits, which does not fit `i32`, so the EINTR compare would panic in safe builds and skip the retry in ReleaseFast. The write uses libc `fsync` like the rest of `sys.zig`.
- **Interface flags and hole-punch mode bits come from the libc headers** instead of copied Linux constants. The arm64 libfuse3 extractor falls back to the `zstd` binary when `tar --zstd` is missing, so a non-Debian host without GNU tar 1.31+ can still unpack the vendored debs.

- **The contributor gate no longer pretends PATH ruff/mypy can stand in for the lock**: without `.venv`, `scripts/check.sh` warned and continued, then mypy died on a missing matplotlib stub (or, with a different ruff, only after push). It now fails immediately with the uv install line; `minimum_zig_version` is checked before `zig fmt` so an old toolchain is named rather than formatting under the wrong rules.
- **Every CI job is one local command**: `./scripts/ci.sh` (also `zig build ci`) runs the check gate, the aarch64 cross-compile into `.scratch/cross-aarch64` so it does not replace a native `zig-out/bin/modelfs`, and `repro_check.sh`. `zig build fmt` applies the same paths `check.sh` verifies. `./scripts/check.sh --help` lists the rest.
- **The documented `-Dtest-filter=store` loop was not a module filter**: Zig matches test *names*, so that example skipped most of `store.zig`. Docs now use a name fragment (`relOk`), and `src/root.zig` states that a new file's tests are invisible until imported there.
- **The 9-node cluster harness names a missing FUSE device or helper** before spawning daemons, the same preflight the benchmark script already had.
- **Sequential piece fills no longer copy `/have` bitmaps per piece**: `Catalog.haveHas` tests the one needed bit under the cache lock, so a TTL hit skips the `bytesLen(pieces)` allocation `haveGet` used to take on every 16 MiB of a sequential model read.
- **Sidecar saves encode onto the stack**: `Bitfield.encodeTo` writes the on-disk blob into a caller buffer, and `Store.saveBits` uses a 16 KiB stack slot (heap only past a 2 TiB file at the default piece size) instead of heap-allocating a copy of bits the entry already holds, once per hydrated piece.
- **Warm FUSE reads skip per-piece lock traffic**: `mf_read` checks covered bits under the size-sample lock via `Store.rangeFilled`, so a fully-cached range does not bounce `file.mu` again in `ensureRange`/`hasPiece`.

### Restore drill clones off the live export - 2026-08-27
- **The monthly restore drill no longer checksums the live export against itself.** `zfs clone` of `tank/models` inherits `mountpoint=/export/models`, so the drill's clone and the production tree were the same path: a green log line proved `diff` and `sha256sum` of a directory with itself, not a restore. The clone now always gets a distinct mountpoint (sibling `modelfs-drill`, overridable with `MF_DRILL_CLONE_MP`), and a collision with the live tree fails the drill. Restore procedure B in recovery.md had the same trap (`/tank/recover` is not where a clone of `/export/models` lands) and now uses `-o mountpoint=` plus the newest snapshot by creation time, and it stops engines before the copy.
- **A snapshot of only `.cluster` leases no longer counts as a restore.** File count, sample checksum, and the clone-vs-live diff skip `.cluster` and `.zfs`, so the drill has to read a real weight file. Sample pick walks largest-first as the comment already claimed.
- **The drill has a CI-runnable test, and an optional replica gate.** `scripts/test_dr_restore_drill.sh` drives it through a stub `zfs` with fixture trees (success with drift, empty, lease-only, stale, hash mismatch, size-changed skip, mountpoint collision, replica missing/fresh/stale) and `scripts/check.sh` runs it. `MF_DRILL_REPLICA` fails the drill when the pool-loss copy is missing or stale; without it the log line records `replica=unchecked` so an unproven replica is visible.

### Config pass - 2026-08-26
- **Harness and drill environment knobs no longer squat on the daemon's `MODELFS_` namespace**: `test_fault_tolerance.sh` read `MODELFS_TEST_HOST`/`MODELFS_TEST_PORT` and `dr_restore_drill.sh` read `MODELFS_DRILL_LOG/LIVE/KEEP`, but every `modelfs` invocation refuses any unknown `MODELFS_*` variable as a typo'd knob, so exporting one of these settings (the natural way to keep it for a session) made every command in that shell exit 2 with "unknown environment variable". They are renamed to `MF_TEST_*` and `MF_DRILL_*`; recovery.md's drill section matches.
- **The log level is runtime configuration, not a compile-time constant**: verbosity was fixed at info inside `main.zig`, so quieting a cron'd `status` loop or debugging a misbehaving mount meant a rebuild. `MODELFS_LOG` (`err`, `warn`, `info` default, `debug`) moves the ceiling for every command; values outside that set are refused at startup like any other malformed knob, and an empty value counts as unset. Documented in `modelfs help`, README, docs/architecture.md, and docs/THREAT_MODEL.md.

### Restore drill staleness alarm - 2026-08-26
- **A dead autosnap schedule no longer passes the restore drill.** The drill
  only failed when a dataset had no snapshots at all, so sanoid dying after a
  green drill left the newest restore point aging silently past the RPO table's
  claims while the next monthly run still logged "ok". It now reads the newest
  snapshot's creation stamp, fails when it is older than
  `MF_DRILL_MAX_SNAP_AGE` (default 25 h: catches an hourly schedule that
  stopped without false-alarming daily-only datasets), and records the true age
  in the log line as `snap_age_s`, making the recovery doc's RPO column a
  measured number instead of an assumption.

### Build review pass 2 - 2026-08-26
- **A 4 MB core dump of the test binary is out of the tree**: `vgcore.3049480`, an ELF core from a crashed `modelfs-test` run, was committed by accident and shipped inside the repo forever after. Deleted, and `.gitignore` now rejects crash dumps (`vgcore.*`, `core`, `core.*`) so the next failed test run cannot be committed either.
- **Reproducible release builds are now enforced, not just claimed**: CONTRIBUTING promised byte-identical ReleaseFast binaries across path/host/locale/timezone and asked for a manual double-build check that nobody had to run. The new `scripts/repro_check.sh` does it mechanically (two cold builds of the tracked sources from differently named trees, second one under `TZ=Asia/Tokyo`, `LC_ALL=C.UTF-8`, fixed `SOURCE_DATE_EPOCH`; each with its own Zig cache; fails with a diffoscope pointer if the bytes differ), CI runs it as a blocking `reproducibility` job on every PR, and README/CONTRIBUTING point at the script instead of prose instructions.

### CLI review pass 3 - 2026-08-26
- **A regular file at `--origin` is refused instead of silently misbehaving**: both `mount` and `peers` gated only on reachability, which a file satisfies, so the mount proceeded past the origin check (mountpoint and cache layout created, peer port bound) while every lookup died ENOTDIR behind the NFS fallback, and `peers` reported a healthy empty cluster for a path that can never hold `.cluster` leases. Both commands now require the origin to be an existing directory right after the realpath gate (named message, exit 1, nothing created), matching the documented contract ("any POSIX dir"); `modelfs help` says "Existing".

## [0.1.0] - 2026-08-26

First tagged release. It mounts `/models` over FUSE on every node, serves reads
from a local NVMe piece cache, falls back to a cluster peer over plaintext HTTP
with `sendfile` and then to the NFS origin, and writes through the origin first.
Membership is lease files on the origin, authentication is one shared PSK, and
eviction follows cachefilesd-shaped watermarks. Tested on two DGX Spark nodes
against a ZFS/NFS NAS; the sections below are the passes that got it here.

Changes made for the tag itself:

- **The PSK cannot be passed on the command line.** `--psk-value` is gone:
  argv is world-readable through `/proc/<pid>/cmdline` for the daemon's whole
  lifetime, so the warning it printed was papering over a leak. The file
  (`--psk FILE`, default `/etc/modelfs.psk`) and `MODELFS_PSK_VALUE` remain,
  the second readable only by the process owner and root.
- **The test binary compiles again.** `src/peer.zig` called `corpusEntry`,
  which had been renamed to `fuzzcorpus.entry`, so `zig build test` failed to
  compile and every suite behind it was unrunnable. 173 tests pass.
- **The static analysis gate passes again.** `scripts/dr_restore_drill.sh`
  masked three command exit statuses (a `date` inside `awk` arguments, `find`
  in a process substitution, a `date` inside the log line), which shellcheck
  rejects under the option set `scripts/check.sh` enables.
- **Scripts find the project root by walking up for `build.zig.zon`** instead
  of counting directories back from their own path, through the new
  `scripts/lib.sh` they all source.
- **Run artifacts stay on disk.** The e2e, cluster, fault-tolerance, and
  benchmark harnesses created their mounts, caches, and origins under `/tmp`,
  which is tmpfs: a piece cache written there is charged to RAM and competes
  with the throughput being measured. They use gitignored `.scratch/` now.
- **The threat model points at symbols rather than line numbers.** All 139
  `src/file.zig:NNN` references had drifted, several by more than 150 lines.
- **A punch test no longer depends on the host's uptime.** It stamped the
  cache entry with a virtual 40_000 but asked for the punch at
  `sys.monoSec()`, so the piece read as too recently accessed on any host up
  for less than 11 hours: green on a long-running desktop, red in CI.
- **`AGENTS.md`** records the layout, the gates, and the constraints that are
  specific to this tree.

### Recovery review pass 2 - 2026-08-26
- **The restore drill is now an artifact, not a paste-block**: docs/recovery.md section 6 carried the monthly procedure as inline commands a reader had to retype (with a name-sorted snapshot pick that hourly/daily/monthly suffixes could fool, and no cleanup if any step died mid-way). New `scripts/dr_restore_drill.sh` runs the drill as one command: newest snapshot by creation time, timed clone, diff against the live tree with in-RPO-window drift counted instead of failed, sha256 of a size-stable file on both sides, clone destroyed through an EXIT trap, and the log line that proves the drill ran. An empty snapshot, a hash mismatch, and "no snapshots at all" (the sanoid.timer-down alarm) each fail with their own named message; exit status is the verdict. Verified against a stub `zfs` with fixture trees: drift tolerated, changed files skipped by the sampler, mismatch/empty/no-snapshot failures, and post-run cleanup all pinned.
- **The recovery doc's example snapshot name now matches what sanoid actually creates** (`autosnap_2026-08-25_00:00:02_hourly`, not the fictional `autosnap-..._00.00.02`), so a copy-pasted restore command does not dead-end on a name that never exists.

### DX review pass 2 - 2026-08-26
- **Running the documented benchmark command no longer dirties the tree**: README listed `python3 scripts/run_benchmarks_and_plots.py` under Tests, but every run re-measures the local machine and overwrote four tracked files (`docs/benchmarks.md` plus three figures), so a contributor following the documented loop got review noise or, worse, committed laptop numbers as cluster results. The script now writes to gitignored `.scratch/benchmarks/` by default and only touches `docs/` with `--update-docs`; README says which command regenerates the tracked report.

### Infra review pass - 2026-08-26
- **The vendored arm64 libfuse3 recipe lives in exactly one place**: the extraction steps (extract both `.deb`s into `root/`, recreate the two `lib/` symlinks) existed as three hand-synced copies in `.github/workflows/ci.yml`'s cross-aarch64 job, README's Build section, and `.deps/fuse3-arm64/README.md`, so an edit to one silently diverged from the others. They all now run the new `scripts/extract_fuse3_arm64.sh`, which is idempotent (symlink replacement instead of a failing `ln -s` on re-run after a refresh), names the missing `.deb` with where to re-fetch it instead of a bare extraction error, and falls back to `ar` + zstd-capable `tar` on hosts without dpkg (previously documented only as prose in the .deps README).

### CLI review pass 2 - 2026-08-26
- **The suite compiles again**: the idempotency pass's "write-through copied twice" test called `Store.copyIntoCache` with a fourth argument the function has never taken, so `zig build test` failed at compile time for every change since. The three call sites now match the real signature; the twice-versus-once assertions are unchanged.
- **A flag missing its value names where to look next**: `--origin` with nothing after it printed only "--origin needs a value"; like the unknown-flag message, it now points at `'modelfs help'` (still exit 2).
- **Every mention of the environment variables lists all five**: README, docs/architecture.md, and docs/THREAT_MODEL.md enumerated `MODELFS_ORIGIN/CACHE/PSK/ID` but omitted `MODELFS_PSK_VALUE`, which the CLI applies and `modelfs help` documents; the inline-secret env spelling was invisible everywhere but the help text.

### Build review pass - 2026-08-26
- **The same tree now builds to the same bytes**: ReleaseFast artifacts carried DWARF debug info whose `DW_AT_comp_dir` records the absolute build directory, so two machines (or two checkouts) produced different binaries from identical source. Non-Debug builds are now stripped (`build.zig` sets `strip` for every optimize mode except Debug), which removes the leak and shrinks the shipped binary; Debug development keeps full symbols. Verified by building from two different directories with different `TZ`, `LC_ALL`, and `SOURCE_DATE_EPOCH`: both `zig-out/bin/modelfs` copies hash identically.
- **The daemon image finally gets ASLR and canaries in every mode**: Zig linked an ET_EXEC non-PIE binary by default, so the long-lived networked process ran at a fixed load address (`exe.pie = true` fixes that), and stack protection defaults off in ReleaseFast/ReleaseSmall (`stack_protector = true` on the executable and test modules pins it on everywhere). Full RELRO, BIND_NOW, and the non-executable stack were already Zig defaults and stay.
- **CI's cross-compile gate now exercises the codegen that ships**: `cross-aarch64` compiled in Debug mode while README documents `-Doptimize=ReleaseFast` for deployment, so optimization-dependent breakage would have passed CI unnoticed. The job now cross-compiles ReleaseFast.

### Release process review pass - 2026-08-26
- **Cutting the first release no longer relies on memory**: every mechanic existed (`build.zig.zon`'s `.version` is the single source `modelfs version` prints through `build_options`, its semver shape pinned by test; the `[Unreleased]` note already said the first tag regroups these entries under its version), but no document tied them together, so manifest, changelog, and tag could drift apart at the first cut. CONTRIBUTING.md gained the four-step release procedure (bump the manifest, regroup covered entries under the version, tag `v<version>` exactly matching the manifest, confirm the built binary answers with it) and now states that CI builds with exactly 0.16.0 while `minimum_zig_version` is only the floor.
- **CONTRIBUTING's changelog guidance matches how entries are actually added**: it pointed behavior changes at an `[Unreleased]` subsection nobody uses; each change set in practice adds its own dated section, all unreleased until the first tag. The instruction now says that.
- **The changelog consumers pull is titled like one**: `build.zig.zon` `.paths` ships CHANGELOG.md inside the package tarball, but its header still read "Changelog & Autoresearch Notebook"; it is just "# Changelog" now, with the early autoresearch session notes kept as history below.

### DX review pass - 2026-08-26
- **A fresh clone compiles and tests again**: the idempotency pass added a write-through idempotency test calling `copyIntoCache` with the old four-argument signature (trailing `null`) that the concurrency pass had already reduced to three arguments, so `zig build test`, `./scripts/check.sh`, and CI failed to compile on every clean checkout. The three calls dropped the stale argument; no assertion changed.
- **A single module's tests no longer cost the whole suite**: `zig build test` always built and ran all 128 tests (~40 s of run time alone), so contributors batched changes. `build.zig` now takes `-Dtest-filter=<substring>` (wired to the test runner's native filter), making `zig build test -Dtest-filter=piece` a seconds-long loop; documented in README and CONTRIBUTING.
- **The most common first-build failure now names its fix**: without libfuse3 headers, `zig build` died inside translate-c with a clang "file not found" buried in compile noise and no hint about packages or escape hatches. A build.zig preflight fails early with "libfuse3 headers not found at <path>: install libfuse3-dev / fuse3-devel, or pass -Dfuse-include=<dir>".
- **Local checks run with exactly what CI runs**: CI installs the pinned Python tooling into `.venv` and puts it on PATH; locally, `scripts/check.sh` used whatever ruff/mypy happened to be on PATH, so a created-but-not-activated `.venv` silently checked with unpinned versions and failures surfaced only after push. check.sh now prepends `.venv/bin` when it exists, matching CI's environment without requiring activation.
- **The contributor path is written down**: no CONTRIBUTING existed, so setup knowledge lived in README plus tribal memory. CONTRIBUTING.md now documents only verified-runnable commands: setup (pinned tooling via uv), the single gate (`./scripts/check.sh`, same as CI), the edit-test loop, the e2e suites' hardware requirements, and PR expectations.

### CLI review pass - 2026-08-26
- **`peers` no longer reports a typo'd origin as an empty cluster**: an unreachable `--origin` fell into the missing-`.cluster` branch and exited 0 with "no cluster leases", indistinguishable from a healthy empty cluster. The same reachability gate `mount` applies to `--origin` now runs first (exit 1, "origin ... is not reachable"); an existing origin without `.cluster` yet still lists as empty with exit 0.
- **`MODELFS_ID` follows the `--id` flag's mount-only scope**: the flag was refused on status/peers/pin (`--piece`-style accepted-and-nothing rejection), but the ambient env source was applied to every command, so a shell-wide invalid value failed unrelated commands with BadId while a valid one was silently ignored. Env application is now mount-scoped like the flag; both sources answer to the same validation gate.
- **Help documents the `-f` short form** (parsed since the start, never listed next to `--foreground`) **and `-V/--version`** alongside the `-h/--help` note.
- **Bare global forms refuse extra arguments**: `modelfs help junk` / `modelfs version junk` exited 0 while dropping the extras, unlike every other subcommand's strict positional shape; both now exit 2 with usage.
- **`--listen` is validated at the flag like its sibling value flags**: a malformed spec (`--listen abc:def`) was only rejected after the mountpoint, cache, and PSK had already been set up, and as exit 1 (runtime class) instead of the exit 2 every other malformed value gets; worse, a bare word (`--listen spark1`) or empty value was accepted-and-defaulted, silently mounting on 18080 while the caller believes their spec took effect. The port is now parsed where the flag is read (named message, exit 2, no side effects); `PORT`, `[HOST]:PORT`, and `:PORT` forms keep working, since only the port was ever consumed (binding stays wildcard).
- **A typo'd subcommand can no longer succeed by carrying `-h`**: `modelfs frobnicate -h` printed the help text and exited 0, because `-h` preempted command dispatch inside the argument scan; only the bare form (`modelfs frobnicate`) was refused. parseArgs now rejects unknown command words before any flag handling (same named message, exit 2), so scripts keying on the exit code no longer read a misspelled invocation as success; `-V/--version` on an unknown command gets the same verdict. Dispatch's trailing unknown-command branch became unreachable by construction, with the refusal owned by the single knownCommand list both paths share.

### Release review pass - 2026-08-26
- **The release state is now stated instead of implied**: the changelog grouped everything by dated review pass with no version anchor, so nothing distinguished released change from work-in-progress even though `build.zig.zon` has declared `0.1.0` since the initial commit and no tag exists. An `[Unreleased]` section now says exactly that up front, README points at it, and the compatibility surfaces this pass verified stay as they are: cache sidecars are self-describing (`MFS1` magic plus piece and file size in `src/piece.zig`, stale sidecars reset rather than misread), mixed piece-size fleets degrade to origin traffic via `X-Piece-Size` (`docs/architecture.md`), lease JSON tolerates unknown fields for forward compatibility, and `modelfs version` reads the one declared version through build options with its semver shape pinned by test.
- **Security reports finally have a route**: the vulnerability-handling gap docs/THREAT_MODEL.md flagged ("no SECURITY.md, no disclosed contact, no supported-versions statement") is closed with SECURITY.md: GitHub private vulnerability reporting instead of public issues, an honest supported-version statement (nothing released; fixes land on main; pin a commit hash), and what happens after a report. THREAT_MODEL.md now cites it instead of reporting the gap.
- **The Zig package tarball ships its license and changelog**: `build.zig.zon` `.paths` listed source, README, and docs but not LICENSE or CHANGELOG.md, so a consumer pulling this as a package dependency got neither the GPL text that governs it nor the notes describing what they pulled. Both are included now.

### Resource review pass - 2026-08-26
- **`/have` answers are now bounded at bitmap scale, not body-allocation scale**: `fetchHave` honored a peer-chosen `Content-Length` up to the generic 512 MiB body cap, and a successful probe is then cached by `havePut` (32 entries), so one broken or hostile peer could turn every piece-miss probe into a half-gigabyte allocation with copies pinned in the probe cache. A truthful `/have` body is a piece bitmap (`bytesLen(pieces)`, KiB-scale for any real model), so the fetch client now refuses declarations above 16 MiB (2^27 pieces, a 2 PiB file at the default grid) before allocating, with its own named cap next to the existing body bound. Covered at the parser seam: one byte past the bound fails `BodyTooLarge` at parse time, small bodies keep parsing as every sibling test pins.
- **Lifecycle audit, no other findings**: every acquisition site was traced to release on all exit paths and found sound; recorded so future passes leave them alone. Sockets: listener fds close in `stop()` on both success and bind-failure paths, accepted fds close in the handler defer behind the 16-slot inflight claim, client dials close on connect failure and after body settle, and head/body reads carry total-time budgets so a dribbling peer cannot pin a slot. Threads: accept loops are joined via `serve()`, probe workers joined and inline-drained on spawn failure, detached connection handlers are tracked by `http_inflight` and drained (bounded) at shutdown, with leak-not-free documented for a wedged handler. Memory bounds: `store.files` entries are reaped when idle and empty and transitively when culling punches their last piece, the probe cache evicts at its cap, lease `.tmp` staging files and stale leases are swept by mtime, and `status.json.tmp` is a single overwritten name. External claims: origin-side lease files carry a publish-tick heartbeat and expire through the sweep.

### Functional review pass - 2026-08-25
- **Peer `/data` answers 404 for non-regular files, like `/have` already did**: `serveData` skipped the regular-file gate its sibling has, so a directory at the requested path passed the range checks with its directory `st_size`, created a bogus cache entry, and hydration's pread on the dir fd turned the request into a 502 Bad Gateway plus a `fill_err_origin` bump -- one resource state answering two different statuses across endpoints, and the documented table ("404: the origin has no regular file at path") violated. The gate now sits before any cache work; covered end to end next to the existing `/have` directory case.
- **Mount-only flags are refused on status/peers/pin, as the help text always claimed**: every flag was parsed for every command, so `status --detach`, `peers --piece 4M`, or `pin x --id n1` exited 0 while silently doing nothing. Each mount-only option (`--piece`, watermarks, socket/detach/id knobs) is now rejected at parse with a named message and exit 2; the shared `--origin`/`--cache`/`--psk` values stay legal everywhere (the e2e suites pass them to pin and peers). Positional shapes now follow the Usage lines too (`mount a b`, `unpin a b`, and `status junk` used to drop the extras silently).
- **Help text updated to match the enforced surface** (shared flags tolerated, mount-only refused), so the documented contract and the parser agree.

### API review pass - 2026-08-25
- **Unknown peer paths now answer 404 consistently**: routing ran after path-parameter decoding, so `GET /nope` answered 400 Bad Request while `GET /nope?path=x.bin` answered 404 Not Found; one resource state had two answers depending on the query string. Dispatch now happens before any input decoding, and only `/have`/`/data` pay for it. Covered end to end (bare path, valid query, bad escape, traversal attempt behind an unknown path).
- **405 responses name their method**: a non-GET request was refused with a bare status line; RFC 9110 §15.5.5 requires `Allow`, and without it a probing client has no way to learn the API shape. The refusal now carries `Allow: GET`.
- **Success replies are typed like their siblings already were**: `/have` sent `Content-Type: application/octet-stream` but the `/data` 206 and the `/ping` body went out untyped. Both now declare theirs (`application/octet-stream`, `text/plain`), so ordinary HTTP clients can tell bytes from text.
- **The wire contract is written down**: docs/architecture.md gained the per-endpoint status-code table (200/206/400/401/404/405/416/500/502 with the exact trigger each maps to) plus the framing guarantees (`Content-Length` always present, `Connection: close`, empty error bodies), matching what the tests pin.

### Observability review pass - 2026-08-25
- **Read latency is now measurable**: rates and byte totals existed, but nothing answered "reads got slow". `mf_read` accumulates wall time (`read_nanos`) and piece fills accumulate claim-through-cache-write stall by tier (`fill_peer_nanos` / `fill_origin_nanos`); the tick line publishes per-op averages (`rd_us`, `fill_ms peer/nfs`) and status.json the lifetime totals. Warm reads pay two clock reads.
- **Origin outages no longer hide from the read error counter**: `mf_read` counted only cache-read failures, so an NFS outage failing every uncached read left `reads_err` flat while clients saw an EIO storm. Service-side failures (origin stat failure, entry OOM, hydration failure) now count; caller misuse (traversal paths, bad offsets, EISDIR) deliberately stays uncounted so the rate tracks service health.
- **Silent degradation to NFS-only is now visible**: `/have` probe failures (dead peer, PSK drift, partition) were swallowed and every fill quietly fell through to the origin tier. A 404 is a healthy peer answering "not cached here", so it now surfaces as its own `error.PeerMiss` and is excluded; everything else counts in `probe_err` (tick line + status.json). This exposed that the traversal test's pre-encoded `%2e%2e` case was never refused at the boundary: the single-pass URL decode turns it into a literal filename that simply misses (404), and the test now asserts that real behavior while `../secret.txt` keeps covering the refusal.
- **Cache saturation gauge in status.json**: culling runs on `freePercentChecked` but monitors could not see it; `cache_free_pct` rides along now (`-1` when statvfs fails, i.e. culling suspended).
- **Peer HTTP noise accounting**: connections whose request head never completed (connect-and-drop scanners, dribbled heads) are counted as `http_malformed` instead of vanishing, and a failed connection-handler spawn warns like every other spawn-failure site.

### Design review pass - 2026-08-25
- **`/have` answers now advertise their piece grid (`X-Piece-Size`)**: the bitmap body was raw bits with no context, so bit i meant "my piece i" under the *answering* node's `--piece` while the fetcher indexed it against its own; a fleet running mixed piece sizes silently misread every answer and routed fills by bits covering different byte ranges per node. The fetch client now excludes peers whose advertised grid differs from local (unknown, i.e. header absent from an older peer, still assumes aligned), matching the defense the local layer already had (`Bitfield.decode` resets sidecars whose stored piece size differs). Response parsing moved into one shared `finishBodyAlloc`/`haveFromHead` seam so the length-matching contract cannot drift between `/have` and `/data` readers. Mixed grids degrade to origin traffic, never to wrong data; covered at the parser, the cache roundtrip, and end to end through two live servers on different grids.

### Portability review pass - 2026-08-25
- **The documented aarch64 cross-build had no CI coverage**: README and docs/architecture.md name `aarch64-linux-gnu` as the spark deployment target, but CI only ever built x86_64-native, so a broken arm64 compile would ship unnoticed. New `cross-aarch64` CI job extracts the committed, hash-pinned libfuse3 debs (`dpkg-deb -x`, exactly the `.deps/fuse3-arm64/README.md` recipe; `build.zig` re-verifies both digests) and compiles `-Dtarget=aarch64-linux-gnu.2.39`, asserting the ELF machine type. Verified locally: the extraction reproduces the vendored trees byte-for-byte and the build links an ARM aarch64 binary.

### Recovery review pass - 2026-08-25
- **Origin had no backup story at all**: `tank/models` holds the only copy of every weight file, `unlink` through the mount lands there immediately, and the repo contained zero snapshots, replicas, or restore steps. New docs/recovery.md owns the durability posture: state inventory (caches and leases are derived/ephemeral, everything else is not), a sanoid/syncoid snapshot + replica schedule with failure alerting instead of exit-code trust, per-disaster restore procedures including the wipe-all-caches-before-remount ordering trap after any rollback (the stale-piece rule would otherwise serve post-rollback bytes), stated RPO/RTO per disaster, and a monthly timed restore drill.
- **Silent bit rot had no detector**: operations.md now schedules the monthly `zpool scrub` timer and smartd; cold weight files can carry checksum errors that no read will ever surface.
- **Documented, deliberately not changed: the ack-before-stable window**. `sharenfs="rw,async"` plus client `soft` mounts mean a NAS crash can lose writes clients already saw succeed (window bounded by the txg interval). Synced exports trade ingest throughput for durability; that call stays with the maintainer.

### Design review pass - 2026-08-24
- **`--advertise` requires dotted-quad IPs**: host names were accepted at the flag but every lease consumer (`peer.zig` dial, `discover.hopsBetween`) inet_pton's the ip field, so an advertised name published an address no peer could ever dial, silently dead-ending this node's P2P routes while NFS fallback masked it. Rejected at flag parse with a named error, mirroring the rationale that last pass made `--seed` resolve-or-fail-loudly; unlike a seed, an advertise address names our own interface, so there is nothing to resolve.
- **Peer `/data` accepts open-ended ranges (`bytes=N-`)**: the endpoint already clamps over-long explicit ends per RFC 9110 so ordinary HTTP clients can ask for the rest of a file, but the standard form for exactly that request was refused with 400. An empty end now parses as "through EOF" and flows through the existing clamp; suffix ranges (`bytes=-N`) stay rejected. Covered at the parser and end to end through a live server.

### Functional review pass - 2026-08-24
- **`--seed HOST[:PORT]` now works as documented**: seed hosts that are not dotted quads are resolved once at mount setup (`sys.resolveIpv4` via `getaddrinfo`), where an unresolvable host fails the mount with a named message instead of being accepted and then dying silently on every discovery tick's dial (peer dials only accept dotted quads). Numeric seeds pass through untouched; a regression-tested `buildSeeds` helper owns the resolution.
- **Script probes**: `peer_auth_probe.py` gained the same 30s HTTP timeout its sibling probes got in ce3aff4, so a peer that accepts but never answers fails the fault-tolerance suite instead of hanging it.

### Quality pass - 2026-08-23
- **Peer `/data` hydration**: the piece scratch buffer is now allocated before `claimPiece`, so an OOM can no longer leak a filling claim and wedge every later filler of that piece into `claimPiece`'s retry spin; a truncate racing the size sample now drops the claim instead of marking an empty piece filled (matching `fuse_fs.hydratePiece`).
- **Peer fetch contract**: `readFlexBodyAlloc` checks the caller-supplied buffer length before its zero-length early return, so a peer answering without `Content-Length` fails the fetch instead of "succeeding" with zero bytes written (the piece would have been marked filled over hole zeros).
- **Head deadline clamp**: `readHeadFullDeadline` restores the steady-state socket timeout once the head completes, so a dribbled head no longer leaves body streaming a millisecond-scale send/receive ceiling.
- **CLI**: `--piece` sizes with trailing garbage (`16Mfoo`, `1KB2`) are rejected instead of silently parsing as the prefix value; unknown flags report through the same plain usage-error channel as every other bad value.
- **Consistency/cleanup**: `mf_open` returns the captured origin-stat errno like `mf_getattr`/`mf_read`; `cacheFill`'s shrink path warns on OOM like the grow path; `Bitfield` pad-bit masking unified in one helper and `filled()` defends against corrupt pads like `lastSet()`; `writeFile`/`writeFileNoFollow` share one implementation.

### Performance pass - 2026-08-23
- **Peer probe cache**: successful `/have` bitmaps are cached per (peer, path) for 2 s in `Catalog`, so sequential piece fills of one model no longer re-probe the whole cluster (one connect + round trip + full bitmap transfer per peer per 16 MiB piece) before every fetch. Only hits are cached; failed probes stay uncached so down peers are retried next piece.
- **Read hot path**: `ensureRange` and the peer `/data` hydration loop now allocate their piece-size scratch buffer only when a covered piece actually lacks its bit; fully-cached reads previously paid a 16 MiB alloc/free per call.
- **Consistency**: `ensureRange` now uses the size sample `mf_read` already took under `file.mu` instead of re-reading `file.size` unlocked for its `cover()` computation.

### Fresh Autoresearch Session - 2026-08-22
- **New Benchmark Focus**: 64 MB piece transfer latency & peak zero-copy throughput.
- **Key Findings**:
  1. Unchunked single-pass `sendfile` kernel streaming achieves **3.43 to 3.94 GB/s** zero-copy throughput.
  2. Preserving read-ahead body bytes in `readHeadFull` prevents socket re-read stalls on multi-megabyte transfers.
  3. 2 MB socket buffers (`SO_RCVBUF`/`SO_SNDBUF`) provide optimal throughput on local TCP loopback.
- **Verification Integrity**: All 31 unit tests and 3 E2E integration test suites pass 100% cleanly with 0 memory leaks.

[Unreleased]: https://github.com/maci0/modelfs/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/maci0/modelfs/releases/tag/v0.5.0
[0.4.0]: https://github.com/maci0/modelfs/releases/tag/v0.4.0
[0.3.1]: https://github.com/maci0/modelfs/releases/tag/v0.3.1
[0.3.0]: https://github.com/maci0/modelfs/releases/tag/v0.3.0
[0.2.0]: https://github.com/maci0/modelfs/releases/tag/v0.2.0
[0.1.0]: https://github.com/maci0/modelfs/releases/tag/v0.1.0
