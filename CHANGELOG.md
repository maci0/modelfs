# Changelog

## [Unreleased]

Work since `v0.1.0`. A binary built from this tree still prints `0.1.0`
until the next tag is cut (CONTRIBUTING.md, Cutting a release); pin a
commit hash if you are not on the tag.

### Upgrade from v0.1.0

CLI, peer-wire, and on-disk changes that will surprise a node still
running the tagged binary, or a script written against it. A mixed
fleet with `v0.1.0` peers still fills: those servers already send
`Content-Range` on every 206, and a `status.json` they wrote still
parses (`now_s` stays, `mono_s` is new). Details stay in the entries
below.

- **`modelfs status` exits 1** on a leftover or wedged `status.json` (was 0 with the stale document printed).
- **Unauthenticated peer requests, including POST, are 401** (was 405 before the token was checked).
- **An origin path too long to name is 400**, not 502.
- **`Content-Length` and `X-Piece-Size` are unsigned decimal digits**; a signed or grouped length is refused. **`/data` fetches require a matching `Content-Range`.**
- **Origin, cache, `status.json`, and `.cluster` lease opens use `O_NOFOLLOW`.** Hugging Face hub-cache snapshot trees will not serve through the mount; `hf download --local-dir` writes regular files.
- **Cache data files are 0600** (were 0644); leftover 0644 files are tightened on the next open. `data/`/`meta/`/`pin/` are 0700.
- **`--kernel-cache` enables the kernel page cache** (the flag used to leave `kernel_cache` off).
- **Mount refuses** `--listen`/`--advertise`/`--seed` port 0, origin overlapping the cache, `MODELFS_PSK_VALUE` combined with `--psk`/`MODELFS_PSK`, empty `--origin`/`--cache`/`--psk`, and a regular file at `--origin`.
- **Usage errors print one named line** (no help dump).
- **Harness and drill knobs are `MF_TEST_*` / `MF_DRILL_*`** (were `MODELFS_TEST_*` / `MODELFS_DRILL_*`).
- **U+2028 / U+2029 in paths and lease ids are refused.**

### Changes

- **Healthy `/have` 404s are cached for the same 2 s TTL as hits**: a sequential fill used to re-dial every peer that already answered "not cached here" on every 16 MiB piece. Connection failures stay uncached so a down peer is still retried on the next piece. Once every live peer has a cache line, `fillFromPeers` skips the catalog snapshot and probe threads (`Catalog.collectCachedCands`).
- **`reapIdle` no longer holds the store lock across pin stats and bitfield scans**: the same split `cullOne` already made. Idle emptiness uses `lastSet` (returns on the first set bit) instead of counting every bit with `filled()`.
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

[Unreleased]: https://github.com/maci0/modelfs/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/maci0/modelfs/releases/tag/v0.1.0
