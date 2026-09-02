# Three-layer block cache

| Field | Value |
|---|---|
| Status | Shipped-behavior reference; kept current against `src/` |
| Date | 2026-09-02 (re-verified against `src/`) |
| Design history | [design.md](design.md): original architecture, goals G1-G10 with ship status, key decisions and what did not ship |

Shipped in `modelfs` (Zig, libfuse3). A process on a spark only opens `/models/...`.

```mermaid
sequenceDiagram
  participant P as vLLM / llama.cpp
  participant F as FUSE /models
  participant L as local NVMe
  participant Peers as other sparks
  participant N as NFS

  P->>F: pread piece k
  F->>L: hole filled?
  alt hit
    L-->>P: bytes
  else miss
    F->>Peers: GET /have (one walk per peer; 2s cache)
    alt some peer has k
      F->>F: pick path by score
      F->>Peers: Range GET
      Peers-->>F: 16 MiB
    else nobody
      F->>N: pread
      N-->>F: 16 MiB
    end
    F->>L: pwrite hole
    L-->>P: bytes
  end
```

One piece, one source. Misses block the read until that hole is filled. If the local cache cannot land the fill (full or broken cache disk), that one read is served from the origin rather than failing EIO over a healthy origin (`serveHydrated` in src/fuse_fs.zig); the piece stays unmarked and the next miss retries the cache. Peer `/data` and `/stage` still answer 500 when this node's cache layer fails, so the fetching peer tries its next path. No full-file background stripe (that OOMed UMA).

---

## Layout (this cluster)

| Path | What |
|---|---|
| `192.168.0.100:/export/models` | ZFS NFS export; `.cluster/` holds leases (`<id>.json`) and piece-hash manifests (`manifests/<hex>`, see Piece integrity) |
| `/net/192.168.0.100/models` | NFS origin on sparks, **no `fsc`** |
| `/models` | FUSE (sparks). Empty local dir, uid 1000 |
| `/var/cache/modelfs` | pieces (`data/` 0600 files under 0700 dirs, leftover 0755 dirs tightened at layout; `meta/*.pieces` and `pin/` 0600; `status.json` 0600) |
| `:18080` | peer HTTP, bound on all interfaces; non-loopback IPv4 advertised in the lease (127.0.0.1 if none) |

Desktop: mount NFS at `/models` with `fsc` as in [operations.md](operations.md). Do not run `modelfs` there.

`stat` / `readdir` / `mkdir` / `rmdir` / `chmod` / `statfs` / `unlink` / `rename` → origin. `mkdir` (`Store.mkdirOrigin`) of a path that already exists as a directory is success, so a FUSE retry after a lost reply does not fail `EEXIST`; a non-directory at that name is still `EEXIST`. `rmdir` (`Store.rmdirOrigin`) of a path that is already gone is success, so the same retry does not fail `ENOENT`; a non-directory at that name is still `ENOTDIR` and a non-empty directory is still `ENOTEMPTY`. `rmdir` of the mount root (empty rel) is `EBUSY`. `unlink` (`Store.unlinkOrigin`) and `rename` (`Store.renameOrigin`) also drop cache identity via `Store.forget`, including when the origin name is already gone, so a FUSE retry after a lost reply cannot leave a sidecar that a same-size recreate would serve as the new file. `create` (`O_TRUNC`) and `truncate` with no live cache entry drop persisted marks via `Store.distrust` for the same reason; a cold `Store.get` whose sidecar geometry does not match the origin size persists that wipe so a restart cannot reload the old marks. A same-size rewrite (newer origin mtime, or a different inode at the path) is the same wipe (`Store.getIdentified` / `OriginId`): size-only reconciliation used to keep the previous object's pieces. An older mtime on the same inode is treated as NFS attribute lag, not a rewrite. The identity rides as an optional trailer on `meta/*.pieces`, so a restart still sees it. `open` / `write` / `create` / `truncate` → origin, then this node's cache. `read` (`fileForRead` in src/fuse_fs.zig) uses a live cache entry without restatting origin: open and getattr already sampled it, and a getattr on every 128 KiB FUSE read would make the warm NVMe path pay NFS. Size changes through the mount update the entry in place; an external origin rewrite is visible on the next open (NFS close-to-open). A cold read (no live entry) still stats origin. `.cluster` is hidden from FUSE `readdir`, lookup (`ENOENT`), and mutation (`EPERM`), and from peer `/have`/`/data`/`/stage` (404) and `modelfs pin`/`unpin`/`verify`/`dupes` (`relIsCluster` in src/discover.zig).

Origin is **required**. It can be any POSIX dir both nodes see, not only NFS. Two-node with no shared store is not implemented. The mountpoint must not overlap the origin or the cache (FUSE reentrancy: origin preads or cache writes under the mount nest through this daemon's own handlers), and the cache must not overlap the origin (piece files would land on the shared store and nodes would stomp each other). Origin data-plane opens (`originPread` / `originPwrite` in src/store.zig) use `O_NOFOLLOW` (ELOOP on a planted symlink) and `O_NONBLOCK` (a FIFO at the name cannot hang a FUSE worker). chmod, origin statvfs, and directory opens (`sys.chmod` / `sys.statvfsNoFollow` / `sys.opendirNoFollow`) also use `O_NOFOLLOW` and return `ELOOP` on a final-component symlink; `opendirNoFollow` is `O_NONBLOCK` as well. `preadAll` / `pwriteAll` / `writeAll` (src/sys.zig) return `-errno` like `sendfileAll`, so an origin I/O failure is the real errno (EIO/ESTALE) rather than EPERM. Weight files on the origin must be regular files (a Hugging Face hub-cache snapshot tree will not serve; see [operations.md](operations.md)).

---

## Run

Needs `fuse3`. Same PSK on every spark (file or `MODELFS_PSK_VALUE`); mount refuses to start without one. Id is the short hostname. Advertise is every non-loopback IPv4 except 169.254, `0.0.0.0`, and `255.255.255.255`; `--advertise` replaces that list rather than adding to it (and refuses those last two as undialable); with no qualifying NIC the lease publishes `127.0.0.1`. The published address list is sorted by ip then port (`addrTieLess` in src/discover.zig; `leaseAddrs` in src/main.zig) so NIC `getifaddrs` order and `--advertise` flag order cannot change the lease document.

```bash
# once
sudo mkdir -p /models /var/cache/modelfs
sudo chown 1000:1000 /models /net/192.168.0.100/models /var/cache/modelfs
# same file on every node; skip if it already exists
umask 077; openssl rand -hex 32 | sudo tee /etc/modelfs.psk

# spark1 and spark2, same command (hostname + NICs differ)
~/bin/modelfs mount /models --origin /net/192.168.0.100/models \
  --psk /etc/modelfs.psk
```

Foreground (systemd `Type=simple`). Per-event logs are failure-only: unauthorized peer requests, failed piece fetches (with `ip:port` and error), origin/cache errors, and cache-filesystem statvfs failures (which suspend culling until the next successful sample; recovery logs `culling resumed`, the watermarks themselves are validated once at flag parse). FUSE origin I/O outages (EIO/ESTALE/ETIMEDOUT on getattr/open/stat, write, or origin pread during fill / cache-fallback / peer `/data` hydration, not ENOENT) are edge-triggered: the first failure logs path and errno, later ones ride the counters, and recovery logs `origin recovered`. A busy read storm must not flood the journal the way per-piece origin fills are allowed to. Accept-loop errors are the same shape (one `accept failed` line, then `accept recovered`). Steady state is summarized instead: one `tick:` line per discovery interval while any counter moved (reads, writes, fills by source, fill errors including digest-verification rejections, MiB served and fetched, culled, httpok/401/5xx, `serve_verify_fail`), so an idle node logs nothing. Membership changes log `cluster peers N -> M` even when counters are idle, so losing the fleet is in the journal without waiting for the next fill. The tick line also carries the only latency signal: `rd_us`/`wr_us` are the average wall time of a FUSE read/write over the interval, `http_us` the average `/ping`+`/have`+`/data`+`/stage` handler time (over `httpok`+`http5xx`; `/ping` is timed but not counted in `httpok`), and `fill_ms peer/nfs` the average per-piece hydration stall by tier (a miss blocks the reader for one whole piece, so these numbers are how "reads got slow" is diagnosed from the journal). `reads_warm` counts fully-cached FUSE reads (hit rate is `reads_warm / reads_ok`). `probe_err` counts `/have` probes that failed for reasons other than a healthy 404 miss (dead peer, PSK drift, malformed reply): the signature of a cluster silently degraded to NFS-only, edge-triggered per peer so the first failure logs `peer <ip>:<port> /have probe failed` with the error class and the next success logs recovery (a 404 counts as answering); `httpok`/`serve_mib` are accepted `/have` 200, `/data` 206, and `/stage` 200 replies and the bytes they served (`/have`/`/data` Content-Length; `/stage` the window's piece `len`, not the 52-byte HTTP body), so a node serving pieces is distinguishable from an idle one; `httpbad` counts connections whose request head never completed; `httpdrop` counts connections closed because all inflight slots were taken (the server refusing work under saturation); `http405` counts requests refused for method, whose journal line is deduplicated on the same window as the 401 warn and echoes the method through `discover.displayName` (a PSK holder can pick that token). `md_us` is the interval total (not an average: these handlers count wall time, not calls) of the `getattr`/`open`/`statfs` latency counters, so a metadata storm is visible in a window where no data read moved; the three counters publish separately in status.json. Pin and unpin actions land one info line each, so "why is this file never culled" is answerable from the journal.

```
modelfs status
modelfs peers --origin /net/192.168.0.100/models
modelfs pin gguf/foo.gguf
modelfs unpin gguf/foo.gguf
modelfs verify gguf/foo.gguf --origin /net/192.168.0.100/models
modelfs dupes gguf/a.gguf gguf/b.gguf --origin /net/192.168.0.100/models
```

`status` prints the daemon's `status.json` from the cache dir (0600, so another uid gets EACCES rather than a live/dead verdict). A missing file means the mount is not running, and so does a leftover naming an exited pid (the crash case) or one whose heartbeat is more than 120 s old (the wedged case: a hung daemon keeps its pid but stops rewriting the artifact; 120 s tolerates eleven missed 10 s ticks). Age prefers `mono_s` (CLOCK_MONOTONIC, comparable across processes on this machine) so an NTP step or admin clock set cannot flip the verdict; a leftover from the previous boot (`mono_s` ahead of now, CLOCK_MONOTONIC having reset) is stale even when pid reuse keeps the pid check green; artifacts from older builds fall back to wall-clock `now_s`. It carries liveness (`id`, `pid`, `uptime_s`, `now_s`, `mono_s`), topology (`peers`, `piece`, `inflight` HTTP handlers), saturation (`cache_free_pct`, the same sample culling runs on; `-1` when statvfs fails, i.e. culling suspended), origin health (`origin_down`, 1 while an EIO/ESTALE/ETIMEDOUT getattr/open/stat, write, or origin pread has not yet recovered), and lifetime counters (`stats`: reads/writes with errors, warm-cache reads (`reads_warm`), cumulative read, write, and peer-HTTP (`http_nanos`) durations in nanoseconds, piece fills by source (peer vs origin) with byte totals including bytes served to peers (`bytes_to_peer`: `/have`/`/data` Content-Length, `/stage` staged piece `len`), fill failures per tier -- including origin hydrations done to serve a peer, not only local FUSE reads -- failed `/have` probes (`probe_err`, healthy 404 misses excluded), pieces culled, accepted peer replies (`http_ok`), rejected auths, wrong-method refusals (`http_405`), 5xx replies, malformed request heads, connections dropped at the inflight cap, at-rest serve mismatches (`serve_verify_fail`)). `peers` lists every lease in `origin/.cluster` with its addresses and whether it is still live, using the same `walkLeases` walk Catalog.refresh uses (dot-prefixed names skipped, O_NOFOLLOW, corrupt entries skipped); rows are sorted by lease file name and each row's addresses by ip then port (`addrTieLess` in src/discover.zig), so NFS readdir and a mixed-fleet document's getifaddrs order cannot change the listing. An unreachable `--origin` or a regular file at `--origin` fails with exit 1 for mount, peers, verify, and dupes (`resolveOriginDir` in src/main.zig), while an existing origin without a `.cluster` dir yet lists as empty and exits 0.

Env: `MODELFS_ORIGIN` `MODELFS_CACHE` `MODELFS_PSK` `MODELFS_ID` (mount only, like `--id`) set the same values as their flags, `MODELFS_PSK_VALUE` carries an inline secret that no flag accepts, and `MODELFS_LOG` / `--log` move the log ceiling (`err`, `warn`, `info` default, `debug`) for mount, status, peers, pin, unpin, verify, and dupes; an explicit flag wins and an empty or whitespace-only environment value counts as unset. Every `MODELFS_*` value is trimmed of surrounding whitespace (`envValue` in src/main.zig), so an EnvironmentFile trailing space or a copied path with a newline cannot become the path. `MODELFS_PSK_VALUE` cannot be combined with `--psk` or `MODELFS_PSK` on mount (`loadPsk` would otherwise silently prefer the inline secret). Both PSK sources trim surrounding whitespace (`loadPsk`); a whitespace-only `MODELFS_PSK_VALUE` is empty and refused rather than falling through to the PSK file, matching the file form, so an EnvironmentFile newline or a copied secret with trailing space cannot start a node that then 401s every peer. Any other `MODELFS_*` variable is refused as a typo'd knob on every command, which is why the harness and drill scripts keep their own knobs outside this namespace (`MF_TEST_*`, `MF_DRILL_*`). `--listen`/`--advertise`/`--seed` refuse port 0 (an ephemeral bind whose lease would still advertise 0). `--advertise`/`--seed` also refuse `0.0.0.0` and `255.255.255.255` (`isDialableHost` in src/discover.zig): parseV4 admits them because inet_pton does, but neither is a unicast address a peer can dial. A cache or mountpoint path that exists as a regular file is refused as "not a directory" (`ensureDirReal` in src/main.zig), the same class of gate `resolveOriginDir` applies to `--origin` on mount, peers, verify, and dupes.

`--id`, `--cache`, `--listen [IP:]PORT` override defaults. `--advertise IP[:PORT][,...]` replaces the auto-detected NIC list (not additive; no qualifying NIC falls back to 127.0.0.1). A defaulted advertise port follows `--listen`; an explicit non-default port is bound as written (`leaseAddrs` in src/main.zig). The IP in `--listen IP:PORT` is ignored: binding is always all interfaces. `--seed HOST[:PORT]` bootstraps peers while `origin/.cluster` has no live lease. `--kernel-cache` turns kernel page cache back on (UMA can OOM). `--allow-other` passes FUSE `-o allow_other` (needs `user_allow_other` in fuse.conf); it is the only way a uid other than the mounter reaches the mount. `--detach` backgrounds after mount (`-f`/`--foreground` is the default). `--brun` / `--bcull` / `--bstop` are cull watermarks.

Build:

```bash
# this desktop (x86_64)
zig build -Doptimize=ReleaseFast

# sparks (aarch64, Ubuntu 24.04 fuse 3.14): same recipe CI runs
./scripts/cross_aarch64.sh
```

Daemon code lives in a flat `src/*.zig`. Dependencies point downward; there are no cycles. New code goes in the module that already owns that concern.

| File | Role |
|---|---|
| `c.h`, `c.zig` | Sole door to libfuse3 and libc |
| `sys.zig` | Syscall wrappers: EINTR retry, CLOEXEC, nofollow/owner-only writes; IPv4 `bind`/`accept`/`connect`/`getsockname` through `std.c` |
| `piece.zig` | Piece arithmetic (`count`/`cover`/`trackedEnd`) and the persisted bitfield codec |
| `proto.zig` | Peer HTTP and lease wire helpers (`HaveBits`, Range, bearer, lease JSON, `containsControl`) |
| `cull.zig` | Free-space watermark policy |
| `fuzzcorpus.zig` | Shared framing for `std.testing.fuzz` seed corpora |
| `store.zig` | Local piece cache, path gate (`relOk`), cache-root artifact names |
| `discover.zig` | Cluster leases (`walkLeases`, Catalog), `/have` probe cache, path scoring |
| `rdma.zig` | RDMA data-plane transport seam: `/stage` window codec and the backend interface (null until the verbs tail; see design.md section 15) |
| `peer.zig` | Peer HTTP server and fetch client |
| `fuse_fs.zig` | FUSE handlers, daemon `State` (`init`/`spawnWorkers`/`deinit`/`run`), discovery/cull loops |
| `main.zig` | CLI and mount wiring into `State.init` / `State.deinit`; mount-time `disableCoreDumps` / `scrubPskEnv` |
| `root.zig` | Test aggregator for `zig build test` |

`main` → `fuse_fs` → `peer` → (`store`, `discover`, `rdma`) → (`piece`, `proto`, `cull`, `sys`) → `c`.

---

## Discovery

Node identity is hostname, not an IP. Each spark writes a lease on the **origin** (not through FUSE):

```
<origin>/.cluster/<id>.json
```

```json
{
  "id": "spark1",
  "until": 1710000060,
  "addrs": [
    {"ip": "10.0.1.1", "port": 18080, "mbps": 0},
    {"ip": "192.168.0.211", "port": 18080, "mbps": 0}
  ]
}
```

Refresh every 10s, `until` = now+30s. Drop expired. Skip your own `id`. No PSK in the JSON. A failed write or rename of `<id>.json.tmp` unlinks the staging file in `Catalog.publish` so a retrying tick cannot keep it alive by refreshing mtime. Every node also sweeps the directory each tick: lease files whose mtime is older than 300 s relative to this node's own lease mtime on the origin (the NAS clock; comparing those mtimes to the spark's CLOCK_REALTIME would unlink live peers when the NAS is minutes behind) and abandoned `<id>.json.tmp` staging files from crashed publishes are unlinked, except this node's own lease. Stale names are collected then unlinked in filename order (`sweepLeases` in src/discover.zig) so NFS readdir cannot decide which claim disappears first if the sweeper crashes mid-tick. Origin root must be writable by uid 1000 so `.cluster` can be created.

---

## Path score

A path is `(peer id, ip, port)`.

```
score = ewma_goodput_bps / (1 + hops) / (1 + inflight)
```

- **goodput**: EWMA of Range replies (bytes / wall time), in B/s. The prior until the first measured transfer (a successful piece fetch, not a `/have` probe) is 100 MB/s; a lease `mbps` (Mbit/s) is converted to B/s instead when nonzero. `Catalog.updateGoodput` ignores a non-positive or non-finite sample (zero elapsed wall time on a tiny piece) so it cannot pull the EWMA toward 0 B/s.
- **hops**: 0 if same IPv4 /24 as a local addr, else 1.
- **inflight**: pieces already assigned to that path.

On miss, one `/have` walk per peer (`probeCandidates` in src/peer.zig): addresses of the same `peer id` are tried best-first until one answers, so a multi-homed node costs one round trip and a dead preferred NIC falls through to that node's remaining interfaces rather than hiding the whole node. Among paths whose bit is set, fetch from the max-score address (`pickBest`). Score ties break by ip bytes then port (`pathTieLess`), never by lease-file or `getifaddrs` order: cold clusters start every path at the same prior, so an unspecified tie would let environment enumeration pick the winner. `Catalog.refresh` sorts the live path list by (peer id, ip, port) and `groupPathsByPeerId` sorts the outer probe-group list by peer id, so lease-directory readdir cannot decide snapshot or probe-todo order either. A `/stage` failure falls back to `/data` on the same peer; GET `/data` fails: next path, then NFS. Never two sources for one piece. A node that has written the path through the mount (`Store.wroteLocally`) hydrates further misses of that path from the origin, not from peers: a peer's cached piece can predate the write, and landing it would hide the writer's own bytes.

Probe answers are cached per (path, file) for 2 s (`Catalog.have_ttl_ms`), so a sequential fill of one large model sends `/have` once per peer per TTL window instead of once per peer per piece. The cache holds 32 (file, ip, port) lines (`Catalog.have_cache_cap`); overflow evicts an expired line if one exists, else the soonest-to-expire, with equal expiry (concurrent probes of one fill share one clock sample) broken by (rel, ip, port) so insert order cannot pick the casualty. A concurrent multi-file fill may still re-probe within the TTL when a live line is the victim. Sequential fills consult that line through `Catalog.haveHas` (one bit, no bitmap copy) and, when every live peer already has a line, `Catalog.collectCachedCands` (no snapshot, no probe thread); `haveGet` still returns an owned `proto.HaveBits` for callers that need the whole field. Hits and healthy 404 misses are cached (a 404 as an empty bitmap): a stale hit can at worst route a fetch to a peer that no longer has the piece, which the next-path fallback already handles, and a stale miss delays noticing that peer for one TTL. Connection failures are never cached, so a down peer is retried on the next piece.

---

## Auth and HTTP

Same secret on every spark: `/etc/modelfs.psk` mode 0600, or `MODELFS_PSK_VALUE` in the environment. A world-readable PSK file is refused at load (group-readable warns). On mount the daemon zeros `RLIMIT_CORE` so a crash cannot dump the secret (the mount exits if that limit cannot be set), drops `MODELFS_PSK_VALUE` from the process environment so the `auto_unmount` helper cannot inherit it, and wipes the in-memory copy on teardown (`disableCoreDumps` / `scrubPskEnv` in src/main.zig).

```
GET /ping
GET /have?path=<url-encoded rel>
GET /stage?path=...&piece=N
GET /data?path=...
Range: bytes=start-end
Authorization: Bearer <psk>
```

`/stage` is the negotiated entry to the staged (RDMA) data plane: a node
whose backend can stage advertises `X-Stage: 1` on `/have`, and a fetching
node then stages one piece at a time -- hydrate, at-rest verify, register
the bytes, and reply with a 52-byte window (`len`/`rkey`/`addr` plus the
piece digest, advisory) that its backend reads. Any `/stage` failure (501
= this node cannot stage, malformed reply, backend read error) falls back
to the existing `/data` path on the same peer; a fleet without verbs never
pays the probe because the capability rides the have-cache line. The
shipped backend is null, so this plane is protocol-and-pipeline only until
the verbs tail lands (design.md section 15).

`/have` replies carry `X-Piece-Size: <n>`, the piece grid the bitmap's bits are indexed against; a fetcher running a different `--piece` treats that peer's answer as no-answer instead of routing fills by bits that cover different byte ranges (a fleet should still run one piece size; mixed grids degrade to origin traffic, never to wrong data). Peers older than this header read as unknown and are assumed aligned. An advertised `0` is not unknown: `--piece 0` is refused at mount, so a zero on the wire fails the probe like any other malformed grid. The bitmap body itself stays raw bits: one byte per eight pieces, bit i naming piece i least-significant-bit first, `ceil(pieces / 8)` bytes long. A `/have` whose bitmap would exceed 16 MiB (`max_have_body_bytes` in src/peer.zig, the same cap fetchers enforce) answers 500 without opening a cache entry, so a huge sparse origin file cannot drive a half-gigabyte snapshot. `piece.count` clamps at 2^32-1 pieces (`trackedEnd` in src/piece.zig); bytes past that have no bit, and FUSE/peer reads take them from the origin rather than treating an empty `cover` as a cache hit (a sparse pread of the hole would otherwise return zeros).

Status codes, identical framing on every endpoint (`Content-Length` always present, `Connection: close`, empty body on errors):

| Status | When |
|---|---|
| 200 | `/ping` (`text/plain`, body `ok`), `/have` (`application/octet-stream` bitmap + `X-Piece-Size`), or `/stage` (52-byte window body, see design.md section 15) |
| 206 | `/data` partial content (`Content-Range`, `application/octet-stream`) |
| 400 | Missing, empty, undecodable, or unsafe (`..`, absolute) `path`, or a `path` too long to name any file under the origin root; missing, malformed, or inverted (`end < start`) `Range` on `/data`; missing, malformed, or past-EOF `piece` on `/stage` |
| 401 | Missing or wrong bearer token (`WWW-Authenticate: Bearer`), including on non-GET |
| 404 | Unknown path, a `.cluster` control path, or the origin has no regular file at `path` |
| 405 | Authenticated request whose method is not GET (`Allow: GET`) |
| 416 | `/data` range start at/after EOF, with `Content-Range: bytes */<size>` naming the complete length (an over-long end clamps to EOF instead) |
| 500 | This node's cache layer failed (entry open, bitfield snapshot, hydration write, staging verify failure), or a `/have` bitmap that would exceed the 16 MiB fetch bound |
| 501 | `/stage` only: this node has no data-plane backend (its `/have` does not advertise `X-Stage`); the fetching peer falls back to `/data`. Capability, not a 5xx for the `http_5xx` health gauge |
| 502 | The origin is unreachable or failed (stat/pread error, or a size that does not fit `off_t`), i.e. retry another peer |

A `/data` end past EOF clamps to it and `bytes=N-` means through EOF (RFC 9110); suffix ranges (`bytes=-N`) are rejected. Wire integers (`Range`, `Content-Range`, `Content-Length`, `X-Piece-Size`, `/stage` `piece`) are unsigned decimal digits only: a leading sign or interior underscore is malformed, the same rule RFC 9110 uses for Content-Length. Status lines are `HTTP/1.1` plus a 3-digit code: `2000` is not 200, and `4040` is not a healthy miss. The fetching peer requires `206` plus a `Content-Range` whose start matches the request, whose end is at most the request end (EOF clamp), and whose selected length equals `Content-Length` (a shorter body under a matching window is refused rather than cached). `v0.1.0` servers already send that header on every 206, so a mixed fleet still fills. Errors carry no body: both peers of a conversation parse only the status line.

Every request requires the bearer token, including `/ping` and non-GET methods (those answer 401 without a token, 405 with one). Listen `0.0.0.0` on each unique advertised port (default 18080); `--listen [IP:]PORT` picks the port (the IP is ignored), binding stays on all interfaces. At most 16 HTTP handlers; a connection arriving while all 16 are busy is closed immediately without a reply, so saturation shows up on the fetching peer as a failed transfer (it falls through to its next candidate address, then the origin), never as queuing, and a manual probe sees an empty reply rather than an error status. Listen sockets, accepted connections, and files are opened close-on-exec (`sys.socket`, `sys.accept`, `sys.open`) so the `auto_unmount` fusermount helper spawned at mount cannot inherit them: a helper still holding the listen fd would keep the port bound after `Server.stop`, and the next start would fail to bind.

---

## Cache cull

Like cachefilesd, on **percent free** of the filesystem that holds `/var/cache/modelfs` (here the 3.6T root): unprivileged available blocks (`statvfs.f_bavail` via `cull.freePercent`), not root-reserved `f_bfree`.

| flag | default | meaning |
|---|---|---|
| `--brun` | 10 | stop culling |
| `--bcull` | 7 | start culling |
| `--bstop` | 3 | cull harder |

Culling punches piece-sized holes (default 16 MiB, `FALLOC_FL_PUNCH_HOLE`), clears that bit, leaves the sparse file. Live entries are LRU by last access: FUSE reads, fills, and peer `/data`/`/stage` transfers stamp `last_access`. That path skips `pin`, files accessed in the last 10s, pieces this node is still filling, and entries with a peer transfer in flight (`Cached.xfer`; punching mid-send would ship hole zeros the fetching peer cannot tell from real data). Each cull round samples the 32 oldest idle live entries (`considerIdle` in src/store.zig) instead of allocating and pinning the whole map to punch one piece; equal-recency ties still break by rel bytes. When the live sample has nothing punchable, `cullOneOnDisk` samples cache `data/` by mtime (including after a restart, when nothing is in memory yet) and punches orphans; pins are still skipped, but that path has no 10s recency window. Unclaimed data files with no matching sidecar are punched as a whole KEEP_SIZE extent. Next read hydrates that piece again.

`pin` is a marker under `pin/`. Culling itself does not unlink: after every piece is punched, `reapIdle` (every 30 s, 300 s idle) unlinks empty unpinned data/meta artifacts so the in-memory map stays bounded on nodes that churn paths. `Store.forget` unlinks cache artifacts when the origin name goes away (unlink/rename).

---

## Piece integrity (blake3, Level 1)

Every piece that lands in the cache carries a blake3 digest of its bytes
(`piece.digest` in src/piece.zig, `Store.Cached.hashes` in src/store.zig),
recorded at admit: origin fills and this node's own write-throughs are the
trust root, and a peer fill is only admitted when a trusted digest exists
to verify it against (`hydratePiece` in src/fuse_fs.zig; `expectedHash` in
src/store.zig). Fetched bytes that fail verification are discarded unmarked
and the piece refills from origin (`fill_err_verify` counter). Cached bytes
are re-verified against their digest before every `/data` and `/stage`
serve (`verifyRange`/`serveStage` in src/peer.zig; a mismatch drops the
transfer with a 500, counts `serve_verify_fail`, and **self-heals** --
`Store.healPiece` clears the piece's mark so the next fill re-hydrates
from origin instead of failing every serve of that piece). `modelfs verify
<rel>` rehashes a whole file's cached pieces against the manifest and
clears mismatched marks the same way. Local (FUSE) reads are not re-verified
per-read; a piece corrupt but never served to a peer waits for `modelfs
verify` (operations.md Integrity runbook).

The trusted digests come from two places:

- **Origin fills and write-throughs** (this node's own). The origin is the
  write authority, so bytes read from it (or written to it by this node)
  are trusted, and their digest becomes the reference for every later fill
  of that piece -- including refills after a cull.
- **The piece-hash manifest** (`Store.publishManifest` in src/store.zig),
  published on the origin at `.cluster/manifests/<hex>` where `<hex>` is
  `blake3(rel)` hex (`piece.manifestName`): a deterministic flat name, so
  no nested directories and no traversal risk. Any node that wrote or
  filled a file publishes its digests at close (`mf_release` in
  src/fuse_fs.zig), so an ingested file gets a manifest from its writer,
  and a legacy file with no manifest gets one from the first node that
  fully origin-reads it. Readers load the manifest lazily, once per entry
  size (`expectedHash`), merging only hashes this node does not already
  hold from an origin fill or write-through, and verify peer fills against
  it; a transient
  load failure (an NFS negative cache hiding the writer's just-published
  manifest) is retried after `manifest_retry_ms` against the caller's
  monotonic instant instead of disabling peer fills for the entry's
  lifetime, and a manifest whose grid or size disagrees
  with the reader's is ignored (origin fills, no peer verification). A file with no manifest anywhere has no trust
  reference, so its fills stay origin-only -- the cost of never serving
  unverified bytes (THREAT_MODEL.md, former gap R2).

Digests survive a punch (they are the expectation a refill must meet) and
are dropped together with the marks on size change, same-size rewrite
(mtime/ino), distrust, and forget (`Store.clearHashes`). The sidecar
bitfield prefix is unchanged; an optional origin-identity trailer follows
the bits so a restart can still detect a same-size rewrite. Hashes ride
in memory and in the manifest, not in the bit bytes. Manifest blobs
are bounded (64 MiB, `Store.max_manifest_bytes`), parsed by a fuzzed
codec (`piece.manifestDecode`), and published atomically (tmp + rename,
lazy mkdir of `.cluster/manifests` like lease publish); lease walks and
sweeps skip them (no `.json`/`.tmp` names).

---

## Writes and races

Write is NFS 1:1, then a copy into this node's cache. If NFS fails, the write fails. `originPwrite` (and FUSE create/truncate, lease/status/sidecar `writeFile*`) treat a failed close after a successful write as failure: NFS reports delayed write errors there. No write-back buffer. `create` / `mkdir` / `chmod` apply the caller's permission bits only (`clientCreateMode` in src/fuse_fs.zig): setuid, setgid, and sticky are stripped so a mount writer cannot plant a daemon-owned special-bit executable. `Store.copyIntoCache` bumps a per-entry write generation unless the copy already fully covers marked pieces (a FUSE retry of the same write-through) and records blake3 digests for the fully covered pieces from the write buffer (boundary pieces drop their old digest: their bytes are now a mix); `Store.completeFill` drops an in-flight fill whose generation no longer matches, and `Store.finishPiece` re-checks that generation after the cache write so a truncate, size reconcile, or distrust that landed during the pwrite cannot mark the fill's pre-mutation bytes. If the cache copy itself fails, overlapping piece marks drop (and the sidecar is saved) so this node's reads and `/have` answers cannot serve pre-write bytes; those pieces refill from origin. `Store.punchPiece` takes the same content lock as the copy so a cull cannot hole a piece between the write-through pwrite and its mark. Further misses on the writing node take the origin (`hydratePiece` in `src/fuse_fs.zig`): a fill discarded by a concurrent write-through retries once from origin, then fails the read with EIO rather than spinning while writers keep landing. `Store.truncateCacheFd` refuses to cut a live cache descriptor while a peer `/data` send (`Cached.xfer`) is streaming from it.

Two writers on the same path: last `pwrite` on NFS wins. No cluster lock. The other node's cache drops marks on the next open/read once it observes a newer origin mtime or a different inode (`Store.getIdentified`); until that stat, a warm read of already-cached pieces can still serve the previous write. Ingest on one node; everyone else reads. Second copy of a model: new path.

UMA: kernel page cache is off (`direct_io`). mmap of FUSE files will fail; engines fall back to `read`. `--kernel-cache` if you need mmap and the file fits in RAM.

---

## What did not ship

Canonical status is [design.md](design.md) sections 2.1 (G1–G10) and 13 (key decisions). Do not treat this list as a second copy of those rows.

- Origin-less two-node (no shared dir)
- Content-addressed dedup (Level 2) and CDC (Level 3): **shelved/dormant**, not merely unbuilt; see design.md section 14. Level 1 integrity shipped (Piece integrity above).
- Full-file background stripe
- Sparse-file hydrate / FUSE passthrough (the agent stays in the I/O path; `direct_io` is the default)
- cachefilesd stacked on FUSE (FUSE is not an FS-Cache client)
