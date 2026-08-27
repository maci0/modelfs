# Three-layer block cache

| Field | Value |
|---|---|
| Status | Shipped-behavior reference; kept current against `src/` |
| Date | 2026-08-27 (re-verified against `src/`) |
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
    F->>Peers: GET /have (all paths, 2s per-peer cache)
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

One piece, one source. Misses block the read until that hole is filled. No full-file background stripe (that OOMed UMA).

---

## Layout (this cluster)

| Path | What |
|---|---|
| `192.168.0.100:/export/models` | ZFS NFS export |
| `/net/192.168.0.100/models` | NFS origin on sparks, **no `fsc`** |
| `/models` | FUSE (sparks). Empty local dir, uid 1000 |
| `/var/cache/modelfs` | pieces (`data/`, `meta/*.pieces`, `pin/`) |
| `:18080` | peer HTTP, bound on all interfaces; non-loopback IPv4 advertised in the lease |

Desktop: mount NFS at `/models` with `fsc` as in [operations.md](operations.md). Do not run `modelfs` there.

`stat` / `readdir` / `mkdir` / `rmdir` / `chmod` / `statfs` / `unlink` / `rename` → origin. `unlink` (`Store.unlinkOrigin`) and `rename` (`Store.renameOrigin`) also drop cache identity via `Store.forget`, including when the origin name is already gone, so a FUSE retry after a lost reply cannot leave a sidecar that a same-size recreate would serve as the new file. `create` (`O_TRUNC`) and `truncate` with no live cache entry drop persisted marks via `Store.distrust` for the same reason; a cold `Store.get` whose sidecar geometry does not match the origin size persists that wipe so a restart cannot reload the old marks. `write` / `create` / `truncate` → origin, then this node's cache. `.cluster` is hidden from FUSE `readdir`, lookup (`ENOENT`), and mutation (`EPERM`).

Origin is **required**. It can be any POSIX dir both nodes see, not only NFS. Two-node with no shared store is not implemented. The mountpoint must not overlap the origin or the cache (FUSE reentrancy: origin preads or cache writes under the mount nest through this daemon's own handlers), and the cache must not overlap the origin (piece files would land on the shared store and nodes would stomp each other). Origin data-plane opens (`originPread` / `originPwrite` in src/store.zig) use `O_NOFOLLOW`; chmod and readdir lstat first and return `ELOOP` on a final-component symlink. Weight files on the origin must be regular files (a Hugging Face hub-cache snapshot tree will not serve; see [operations.md](operations.md)).

---

## Run

Needs `fuse3`. Same PSK on every spark. Id is the short hostname. Advertise is every non-loopback IPv4 except 169.254.

```bash
# once
sudo mkdir -p /models /var/cache/modelfs
sudo chown 1000:1000 /models /net/192.168.0.100/models /var/cache/modelfs
# optional: umask 077; openssl rand -hex 32 | sudo tee /etc/modelfs.psk

# spark1 and spark2, same command (hostname + NICs differ)
~/bin/modelfs mount /models --origin /net/192.168.0.100/models \
  --psk /etc/modelfs.psk
```

Foreground (systemd `Type=simple`). Per-event logs are failure-only: unauthorized peer requests, failed piece fetches (with `ip:port` and error), origin/cache errors, and cache-filesystem statvfs failures (which suspend culling until the next successful sample; recovery logs `culling resumed`, the watermarks themselves are validated once at flag parse). FUSE origin I/O outages (EIO/ESTALE/ETIMEDOUT on stat or write, not ENOENT) are edge-triggered: the first failure logs path and errno, later ones ride the counters, and recovery logs `origin recovered` -- a busy read storm must not flood the journal the way per-piece origin fills are allowed to. Steady state is summarized instead: one `tick:` line per discovery interval while any counter moved (reads, writes, fills by source, fill errors, MiB served and fetched, culled, httpok/401/5xx), so an idle node logs nothing. The tick line also carries the only latency signal: `rd_us`/`wr_us` are the average wall time of a FUSE read/write over the interval, and `fill_ms peer/nfs` the average per-piece hydration stall by tier (a miss blocks the reader for one whole piece, so these numbers are how "reads got slow" is diagnosed from the journal). `reads_warm` counts fully-cached FUSE reads (hit rate is `reads_warm / reads_ok`). `probe_err` counts `/have` probes that failed for reasons other than a healthy 404 miss (dead peer, PSK drift, malformed reply): the signature of a cluster silently degraded to NFS-only; `httpok`/`serve_mib` are accepted `/have` 200 and `/data` 206 replies and their Content-Length, so a node serving pieces is distinguishable from an idle one; `httpbad` counts connections whose request head never completed; `httpdrop` counts connections closed because all inflight slots were taken (the server refusing work under saturation). Pin and unpin actions land one info line each, so "why is this file never culled" is answerable from the journal.

```
modelfs status
modelfs peers --origin /net/192.168.0.100/models
modelfs pin gguf/foo.gguf
modelfs unpin gguf/foo.gguf
```

`status` prints the daemon's `status.json` from the cache dir; a missing file means the mount is not running, and so does a leftover naming an exited pid (the crash case) or one whose heartbeat is more than 120 s old (the wedged case: a hung daemon keeps its pid but stops rewriting the artifact; 120 s tolerates eleven missed 10 s ticks). Age prefers `mono_s` (CLOCK_MONOTONIC, comparable across processes on this machine) so an NTP step or admin clock set cannot flip the verdict; artifacts from older builds fall back to wall-clock `now_s`. It carries liveness (`id`, `pid`, `uptime_s`, `now_s`, `mono_s`), topology (`peers`, `piece`, `inflight` HTTP handlers), saturation (`cache_free_pct`, the same sample culling runs on; `-1` when statvfs fails, i.e. culling suspended), and lifetime counters (`stats`: reads/writes with errors, warm-cache reads (`reads_warm`), cumulative read and write durations in nanoseconds, piece fills by source (peer vs origin) with byte totals including accepted peer-reply Content-Length (`bytes_to_peer`), fill failures per tier -- including origin hydrations done to serve a peer, not only local FUSE reads -- failed `/have` probes (`probe_err`, healthy 404 misses excluded), pieces culled, accepted peer replies (`http_ok`), rejected auths, 5xx replies, malformed request heads, connections dropped at the inflight cap). `peers` lists every lease in `origin/.cluster` with its addresses and whether it is still live; an unreachable `--origin` fails with exit 1 (the same gate `mount` applies), while an existing origin without a `.cluster` dir yet lists as empty and exits 0.

Env: `MODELFS_ORIGIN` `MODELFS_CACHE` `MODELFS_PSK` `MODELFS_ID` set the same values as their flags, `MODELFS_PSK_VALUE` carries an inline secret that no flag accepts, and `MODELFS_LOG` moves the log ceiling (`err`, `warn`, `info` default, `debug`) for every command; an explicit flag wins and an empty environment value counts as unset. `MODELFS_PSK_VALUE` cannot be combined with `--psk` or `MODELFS_PSK` on mount (`loadPsk` would otherwise silently prefer the inline secret). Any other `MODELFS_*` variable is refused as a typo'd knob on every command, which is why the harness and drill scripts keep their own knobs outside this namespace (`MF_TEST_*`, `MF_DRILL_*`). `--listen`/`--advertise`/`--seed` refuse port 0 (an ephemeral bind whose lease would still advertise 0).

`--id`, `--advertise IP[:PORT][,...]`, `--cache`, `--listen [IP:]PORT` override defaults. `--seed HOST[:PORT]` bootstraps peers while `origin/.cluster` has no live lease. `--kernel-cache` turns kernel page cache back on (UMA can OOM). `--brun` / `--bcull` / `--bstop` are cull watermarks.

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
| `sys.zig` | Syscall wrappers; no policy beyond EINTR retry |
| `piece.zig` | Piece arithmetic and the persisted bitfield codec |
| `proto.zig` | Peer HTTP and lease wire helpers (`HaveBits`, Range, bearer, lease JSON) |
| `cull.zig` | Free-space watermark policy |
| `fuzzcorpus.zig` | Shared framing for `std.testing.fuzz` seed corpora |
| `store.zig` | Local piece cache, path gate (`relOk`), cache-root artifact names |
| `discover.zig` | Cluster leases, `/have` probe cache, path scoring |
| `peer.zig` | Peer HTTP server and fetch client |
| `fuse_fs.zig` | FUSE handlers, daemon `State`, discovery/cull loops |
| `main.zig` | CLI and mount wiring into `State.init` |
| `root.zig` | Test aggregator for `zig build test` |

`main` → `fuse_fs` → `peer` → (`store`, `discover`) → (`piece`, `proto`, `cull`, `sys`) → `c`.

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

Refresh every 10s, `until` = now+30s. Drop expired. Skip your own `id`. No PSK in the JSON. A failed write or rename of `<id>.json.tmp` unlinks the staging file in `Catalog.publish` so a retrying tick cannot keep it alive by refreshing mtime. Every node also sweeps the directory each tick: lease files whose mtime is older than 300 s and abandoned `<id>.json.tmp` staging files from crashed publishes are unlinked, except this node's own lease. Origin root must be writable by uid 1000 so `.cluster` can be created.

---

## Path score

A path is `(peer id, ip, port)`.

```
score = ewma_goodput_bps / (1 + hops) / (1 + inflight)
```

- **goodput**: EWMA of Range replies (bytes / wall time), in B/s. The prior until the first measured transfer (a successful piece fetch, not a `/have` probe) is 100 MB/s; a lease `mbps` (Mbit/s) is converted to B/s instead when nonzero.
- **hops**: 0 if same IPv4 /24 as a local addr, else 1.
- **inflight**: pieces already assigned to that path.

On miss: among paths whose `/have` bit is set, max score. GET fails: next path, then NFS. Never two sources for one piece. A node that has written the path through the mount (`Store.wroteLocally`) hydrates further misses of that path from the origin, not from peers: a peer's cached piece can predate the write, and landing it would hide the writer's own bytes.

Probe answers are cached per (path, file) for 2 s (`Catalog.have_ttl_ms`), so a sequential fill of one large model sends `/have` once per peer per TTL window instead of once per peer per piece. Sequential fills consult that line through `Catalog.haveHas` (one bit, no bitmap copy); `haveGet` still returns an owned `proto.HaveBits` for callers that need the whole field. Only hits are cached: a stale bitmap can at worst route a fetch to a peer that no longer has the piece, which the next-path fallback already handles; failed probes are never cached, so a down peer is retried on the next piece.

---

## Auth and HTTP

Same secret on every spark: `/etc/modelfs.psk` mode 0600, or `MODELFS_PSK_VALUE` in the environment.

```
GET /ping
GET /have?path=<url-encoded rel>
GET /data?path=...
Range: bytes=start-end
Authorization: Bearer <psk>
```

`/have` replies carry `X-Piece-Size: <n>`, the piece grid the bitmap's bits are indexed against; a fetcher running a different `--piece` treats that peer's answer as no-answer instead of routing fills by bits that cover different byte ranges (a fleet should still run one piece size; mixed grids degrade to origin traffic, never to wrong data). Peers older than this header read as unknown and are assumed aligned. The bitmap body itself stays raw bits: one byte per eight pieces, bit i naming piece i least-significant-bit first, `ceil(pieces / 8)` bytes long.

Status codes, identical framing on every endpoint (`Content-Length` always present, `Connection: close`, empty body on errors):

| Status | When |
|---|---|
| 200 | `/ping` (`text/plain`, body `ok`) or `/have` (`application/octet-stream` bitmap + `X-Piece-Size`) |
| 206 | `/data` partial content (`Content-Range`, `application/octet-stream`) |
| 400 | Undecodable or unsafe (`..`, absolute) `path`, or a `path` too long to name any file under the origin root; missing, malformed, or inverted (`end < start`) `Range` on `/data` |
| 401 | Missing or wrong bearer token (`WWW-Authenticate: Bearer`) |
| 404 | Unknown path, or the origin has no regular file at `path` |
| 405 | Any method other than GET (`Allow: GET`) |
| 416 | `/data` range start at/after EOF, with `Content-Range: bytes */<size>` naming the complete length (an over-long end clamps to EOF instead) |
| 500 | This node's cache layer failed (entry open, bitfield snapshot, hydration write) |
| 502 | The origin is unreachable or failed (stat/pread error), i.e. retry another peer |

A `/data` end past EOF clamps to it and `bytes=N-` means through EOF (RFC 9110); suffix ranges (`bytes=-N`) are rejected. The fetching peer requires `206` plus a `Content-Range` whose start matches the request and whose end is at most the request end (EOF clamp); a same-length window at a different offset is refused rather than cached. `v0.1.0` servers already send that header on every 206, so a mixed fleet still fills. Errors carry no body: both peers of a conversation parse only the status line.

Every endpoint requires the bearer token, including `/ping`. Listen `0.0.0.0` on each unique advertised port (default 18080); `--listen [IP:]PORT` picks the port, binding stays on all interfaces. At most 16 HTTP handlers; a connection arriving while all 16 are busy is closed immediately without a reply, so saturation shows up on the fetching peer as a failed transfer (it falls through to its next candidate address, then the origin), never as queuing, and a manual probe sees an empty reply rather than an error status. Listen sockets, accepted connections, and files are opened close-on-exec (`sys.socket`, `sys.accept`, `sys.open`) so the `auto_unmount` fusermount helper spawned at mount cannot inherit them: a helper still holding the listen fd would keep the port bound after `Server.stop`, and the next start would fail to bind.

---

## Cache cull

Like cachefilesd, on **percent free** of the filesystem that holds `/var/cache/modelfs` (here the 3.6T root):

| flag | default | meaning |
|---|---|---|
| `--brun` | 10 | stop culling |
| `--bcull` | 7 | start culling |
| `--bstop` | 3 | cull harder |

Culling punches piece-sized holes (default 16 MiB, `FALLOC_FL_PUNCH_HOLE`), clears that bit, leaves the sparse file. LRU by last read. Skip `pin`, files read in the last 10s, and entries with a peer transfer in flight (punching mid-send would ship hole zeros the fetching peer cannot tell from real data). Next read hydrates that piece again.

`pin` is a marker under `pin/`. Nothing else is deleted as a whole file.

---

## Writes and races

Write is NFS 1:1, then a copy into this node's cache. If NFS fails, the write fails. No write-back buffer. `Store.copyIntoCache` bumps a per-entry write generation; `Store.completeFill` drops an in-flight fill whose generation no longer matches, so a peer fill that claimed the piece before the write cannot overwrite the write-through bytes. Further misses on the writing node take the origin (`hydratePiece` in `src/fuse_fs.zig`).

Two writers on the same path: last `pwrite` on NFS wins. No cluster lock. The other node's cache can keep stale pieces until cull or size change. Ingest on one node; everyone else reads. Second copy of a model: new path.

UMA: kernel page cache is off (`direct_io`). mmap of FUSE files will fail; engines fall back to `read`. `--kernel-cache` if you need mmap and the file fits in RAM.

---

## What did not ship

Canonical status is [design.md](design.md) sections 2.1 (G1–G10) and 13 (key decisions):

- Origin-less two-node (no shared dir)
- Content-addressed dedup / blake3 chunks
- Full-file background stripe
- cachefilesd stacked on FUSE (FUSE is not an FS-Cache client)
