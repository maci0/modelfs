# Architecture: the three-layer block cache

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

One piece, one source. Misses block the read until that hole is filled.

If the local cache cannot land the fill (full or broken cache disk), that one read is served
from the origin rather than failing EIO over a healthy origin (`serveHydrated` in
src/fuse_fs.zig); the piece stays unmarked and the next miss retries the cache. Peer `/data`
and `/stage` still answer 500 when this node's cache layer fails, so the fetching peer tries
its next path. There is no full-file background stripe: it OOMed UMA.

Setup and the CLI are in the [top-level README](../README.md). This document is what the
daemon does once it is running.

---

## Layout (this cluster)

| Path | What |
|---|---|
| `192.168.0.100:/export/models` | ZFS NFS export; `.cluster/` holds leases (`<id>.json`) and piece-hash manifests (`manifests/<hex>`, see [Piece integrity](#piece-integrity-blake3-level-1)) |
| `/net/192.168.0.100/models` | NFS origin on sparks, **no `fsc`** |
| `/models` | FUSE (sparks). Empty local dir, uid 1000 |
| `/var/cache/modelfs` | pieces (`data/` 0600 files under 0700 dirs, leftover 0755 dirs tightened at layout; `meta/*.pieces` and `pin/` 0600; `status.json` 0600) |
| `:18080` | peer HTTP, bound on all interfaces; non-loopback IPv4 advertised in the lease (127.0.0.1 if none) |

Desktop: mount NFS at `/models` with `fsc` as in [operations.md](operations.md). Do not run
`modelfs` there.

### What the origin must be

Required, and it can be any POSIX directory both nodes see, not only NFS. Two-node with no
shared store is not implemented.

* The mountpoint must not overlap the origin or the cache. FUSE is reentrant: an origin pread
  or a cache write under the mount would nest back through this daemon's own handlers.
* The cache must not overlap the origin, or piece files would land on the shared store and
  nodes would stomp each other.
* Weight files must be regular files. A Hugging Face hub-cache snapshot tree is a symlink farm
  and will not serve; see [operations.md](operations.md).

Every origin open is hostile-tree-safe. The data plane (`originPread` / `originPwrite` in
src/store.zig) uses `O_NOFOLLOW`, so a planted symlink is `ELOOP`, and `O_NONBLOCK`, so a FIFO
at the name cannot hang a FUSE worker. `sys.chmod`, `sys.statvfsNoFollow`, and
`sys.opendirNoFollow` are `O_NOFOLLOW` the same way (`opendirNoFollow` is `O_NONBLOCK` too).
`preadAll` / `pwriteAll` / `writeAll` in src/sys.zig return `-errno` like `sendfileAll`, so an
origin I/O failure surfaces as the real errno (EIO, ESTALE) rather than EPERM.

---

## Modules

Daemon code lives in a flat `src/*.zig`. Dependencies point downward; there are no cycles.
New code goes in the module that already owns that concern.

| File | Role |
|---|---|
| `c.h`, `c.zig` | Sole door to libfuse3 and libc |
| `sys.zig` | Syscall wrappers: EINTR retry, CLOEXEC, nofollow/owner-only writes; IPv4 `bind`/`accept`/`connect`/`listen`/`getsockname` and socket options through `std.c` |
| `piece.zig` | Piece arithmetic (`count`/`cover`/`trackedEnd`), the persisted bitfield codec, and piece-hash manifest overlap (`manifestOverlap` / `manifestOverlapPrepared`) |
| `proto.zig` | Peer HTTP and lease wire helpers (`HaveBits`, Range, bearer, lease JSON, `containsControl`) |
| `cull.zig` | Free-space watermark policy |
| `fuzzcorpus.zig` | Shared framing for `std.testing.fuzz` seed corpora |
| `store.zig` | Local piece cache, path gate (`relOk`), cache-root artifact names (`cacheMetaPath`, `sidecarPieceSize`, `manifestPath`) |
| `discover.zig` | Cluster leases (`walkLeases`, Catalog), `/have` probe cache, path scoring |
| `rdma.zig` | RDMA data-plane transport seam: `/stage` window codec and the backend interface (null until the verbs tail; see design.md section 15) |
| `peer.zig` | Peer HTTP server and fetch client |
| `fuse_fs.zig` | FUSE handlers, daemon `State` (`init`/`spawnWorkers`/`deinit`/`run`/`attach`), discovery/cull loops, process-image handover |
| `handover.zig` | Sealed-memfd knobs+PSK codec and `update` request/ack for `modelfs update` |
| `hf.zig` | Hugging Face pulls: id and ref validation, listing/download endpoints, and the download loop for `modelfs pull` |
| `main.zig` | CLI and mount wiring into `State.init` / `State.deinit`; mount-time `disableCoreDumps` / `scrubPskEnv` |
| `root.zig` | Test aggregator for `zig build test` |

`main` → `fuse_fs` → `peer` → (`store`, `discover`, `rdma`) → (`piece`, `proto`, `cull`, `sys`) → `c`.
`handover` and `hf` sit beside `fuse_fs`/`main`: neither speaks FUSE, and `hf` is the one place
that reaches a host outside the cluster (HTTPS through `std.http.Client`, CLI only).

`@cImport` is deprecated in Zig 0.16, so C declarations are translated once from `src/c.h` by
`build.zig`; `c.zig` re-exports that module and every other module goes through it.

The commands that skip FUSE (`status`, `peers`, `pin`, `verify`, `dupes`, `pull`, `update`)
import `store` and `discover` directly. They admit paths through `relOk`/`relIsCluster` and
name cache and origin artifacts through Store (`cacheMetaPath`, `sidecarPieceSize`,
`manifestPath`, `manifestsDirPath`) rather than reconstructing those joins. Pin, verify, and
dupes pass the process `std.Io` into Store so recency and retry instants stay on the injected
clock. `dupes` compares manifests through `piece.manifestOverlapPrepared`; `update` is a thin
client of `status.json` liveness and `pull` of `hf.pull`.

---

## Metadata and namespace operations

`stat`, `readdir`, `mkdir`, `rmdir`, `chmod`, `statfs`, `unlink`, `rename`, and `fsync` go
straight to the origin. `open`, `write`, `create`, and `truncate` go to the origin first, then
to this node's cache.

### Retries after a lost reply

FUSE can replay an operation whose reply was lost, so the destructive ones are idempotent:

| Operation | Already done | Wrong type at the name |
|---|---|---|
| `mkdir` (`Store.mkdirOrigin`) | success | `EEXIST` on a non-directory |
| `rmdir` (`Store.rmdirOrigin`) | success | `ENOTDIR` on a non-directory, `ENOTEMPTY` if not empty |
| `unlink` (`Store.unlinkOrigin`) | success | `EISDIR` on a directory |

`rmdir` of the mount root (empty rel) is `EBUSY`.

`unlink` and `rename` (`Store.renameOrigin`) also drop cache identity through `Store.forget`,
including when the origin name is already gone, so a replayed request cannot leave a sidecar
that a same-size recreate would then serve as the new file. Unlinking a file another process
still has open removes it: there is no `.fuse_hiddenNNNN` rename, which on a shared origin
would be visible to every other node and orphaned if this one died.

### Cache identity

Marks are only trusted while they provably describe the object currently at the path.

* `create` (`O_TRUNC`) and `truncate` with no live cache entry drop persisted marks through
  `Store.distrust`, for the same replay reason.
* A cold `Store.get` whose sidecar geometry does not match the origin size persists that wipe,
  so a restart cannot reload the old marks.
* A same-size rewrite is the same wipe (`Store.getIdentified` / `OriginId`), detected by a newer
  origin mtime or a different inode. Size-only reconciliation used to keep the previous
  object's pieces. An older mtime on the same inode is NFS attribute lag, not a rewrite.
* That identity rides as an optional trailer on `meta/*.pieces`, so a restart still sees it.

### Reads

`read` (`fileForRead` in src/fuse_fs.zig) uses a live cache entry without restatting the
origin: `open` and `getattr` already sampled it, and a getattr on every FUSE read would
make the warm NVMe path pay NFS. Size changes through the mount update the entry in place, and
an external origin rewrite becomes visible on the next open (NFS close-to-open). A cold read,
with no live entry, still stats the origin.

The reply buffer comes from a fixed pool (`claimReadBuf`), not the allocator: the kernel asks
for at most `max_pages * PAGE_SIZE`, which libfuse caps at 1 MiB, so a slot that size never
forces a short reply. There are `read_slots` (16, the same bound `peer.Server.max_inflight`
uses), filled on first use so an idle mount holds none and a single reader holds one. A burst
past the last slot falls back to the allocator rather than blocking a reader.

### Hidden and refused names

`.cluster` is the cluster control plane and is not part of the filesystem the mount presents.
It is hidden from FUSE `readdir`, answers `ENOENT` on lookup and `EPERM` on mutation, answers
404 on peer `/have`/`/data`/`/stage`, and is refused by `modelfs pin`/`unpin`/`verify`/`dupes`
(`relIsCluster` in src/discover.zig).

Names that fail `relOk` (C0/DEL, UTF-8 C1, Default_Ignorable) are omitted from FUSE `readdir`
the same way open and getattr refuse them. NFC/NFD spellings and non-UTF-8 names still list:
identity is byte-exact. Incoming lease JSON whose `id` fails `validId` is ignored at
`Catalog.refresh`, so a planted `"id":"spark1\u200b"` is not a peer.

---

## Discovery

Node identity is the hostname, not an IP. Each spark writes a lease on the **origin** (not
through FUSE):

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

Refresh every 10 s, `until` = now + 30 s. Expired leases are dropped and a node skips its own
`id`. No PSK in the JSON. A failed write or rename of `<id>.json.tmp` unlinks the staging file
in `Catalog.publish`, so a retrying tick cannot keep it alive by refreshing its mtime.

Every node also sweeps the directory each tick, unlinking lease files older than 300 s and
abandoned `<id>.json.tmp` files from crashed publishes, never its own lease. Age is measured
against **this node's own lease mtime on the origin** (the NAS clock): comparing NAS mtimes to
the spark's `CLOCK_REALTIME` would unlink live peers whenever the NAS ran minutes behind.
Stale names are collected and then unlinked in filename order (`sweepLeases` in
src/discover.zig), so NFS readdir order cannot decide which claim disappears first if the
sweeper crashes mid-tick.

The origin root must be writable by uid 1000 so `.cluster` can be created.

The advertised address list is every non-loopback IPv4 except 169.254, `0.0.0.0`, and
`255.255.255.255`, sorted by ip then port (`addrTieLess` in src/discover.zig, `leaseAddrs` in
src/main.zig) so `getifaddrs` order and `--advertise` flag order cannot change the document.

---

## Path score

A path is `(peer id, ip, port)`.

```
score = ewma_goodput_bps / (1 + hops) / (1 + inflight)
```

- **goodput**: EWMA of Range replies (bytes / wall time), in B/s. The prior until the first
  measured transfer (a successful piece fetch, not a `/have` probe) is 100 MB/s; a lease `mbps`
  (Mbit/s) is converted to B/s instead when nonzero. `rangeBps` returns 0, and
  `Catalog.updateGoodput` ignores the sample, for a non-positive, non-finite, or >1 TB/s rate
  (zero or 1 ns elapsed on a 16 MiB piece), so it cannot pull the EWMA toward 0 B/s or toward
  an infinitely fast path.
- **hops**: 0 if the same IPv4 /24 as a local address, else 1.
- **inflight**: pieces already assigned to that path.

### Choosing a source

On a miss, one `/have` walk per peer (`probeCandidates` in src/peer.zig). Addresses of the same
`peer id` are tried best-first until one answers, so a multi-homed node costs one round trip
and a dead preferred NIC falls through to that node's remaining interfaces rather than hiding
the whole node.

Among paths whose bit is set, fetch from the max-score address (`pickBest`). Ties break by ip
bytes then port (`pathTieLess`), never by lease-file or `getifaddrs` order: cold clusters start
every path at the same prior, so an unspecified tie would let environment enumeration pick the
winner. `Catalog.refresh` sorts the live path list by (peer id, ip, port) and
`groupPathsByPeerId` sorts the outer probe-group list by peer id, so lease-directory readdir
cannot decide snapshot or probe-todo order either.

A `/stage` failure falls back to `/data` on the same peer; a failed `/data` falls to the next
path, then NFS. Never two sources for one piece. A node that has written the path through the
mount (`Store.wroteLocally`) hydrates further misses of that path from the origin, not from
peers: a peer's cached piece can predate the write, and landing it would hide the writer's own
bytes.

### The probe cache

Probe answers are cached per (path, file) for 2 s (`Catalog.have_ttl_ms`), so a sequential fill
of one large model sends `/have` once per peer per TTL window instead of once per peer per
piece.

The cache holds 32 (file, ip, port) lines (`Catalog.have_cache_cap`). Overflow evicts an
expired line if one exists, else the soonest-to-expire; equal expiry (concurrent probes of one
fill share one clock sample) breaks by (rel, ip, port), so insert order cannot pick the
casualty. A concurrent multi-file fill may still re-probe within the TTL when a live line is
the victim.

Sequential fills consult that line through `Catalog.haveHas` (one bit, no bitmap copy) and,
when every live peer already has a line, `Catalog.collectCachedCands` (no snapshot, no probe
thread); `haveGet` still returns an owned `proto.HaveBits` for callers that need the whole
field.

Hits and healthy 404 misses are both cached, a 404 as an empty bitmap. A stale hit can at worst
route a fetch to a peer that no longer has the piece, which the next-path fallback already
handles; a stale miss delays noticing that peer for one TTL. Connection failures are never
cached, so a down peer is retried on the next piece.

Concurrent fills of the same file (a large FUSE read covering many pieces, or a TTL expiry
under several workers) share one probe walk (`Catalog.probeTryClaim` in src/discover.zig, taken
in `fillFromPeers`): without it each worker would `/have` every peer at once and saturate the
16 inflight slots. Waiters yield like `beginFill`'s in-flight claim spin and retry the have
cache; cap overflow probes without joining, so a many-file cold start cannot stall behind a
slot that will never name that rel.

---

## Auth and HTTP

Same secret on every spark: `/etc/modelfs.psk` mode 0600, or `MODELFS_PSK_VALUE` in the
environment. The mount refuses to start without one. A world-readable PSK file is refused at
load; group-readable warns.

On mount the daemon zeros `RLIMIT_CORE` so a crash cannot dump the secret (the mount exits if
that limit cannot be set), drops `MODELFS_PSK_VALUE` from the process environment so the
`auto_unmount` helper cannot inherit it, and wipes the in-memory copy on teardown
(`disableCoreDumps` / `scrubPskEnv` in src/main.zig).

```
GET /ping
GET /have?path=<url-encoded rel>
GET /stage?path=...&piece=N
GET /data?path=...
Range: bytes=start-end
Authorization: Bearer <psk>
```

Every request requires the bearer token, including `/ping` and non-GET methods: those answer
401 without a token and 405 with one. The server listens `0.0.0.0` on each unique advertised
port (default 18080).

At most 16 HTTP handlers run at once. A connection arriving while all 16 are busy is closed
immediately without a reply, so saturation shows up on the fetching peer as a failed transfer
(it falls through to its next candidate address, then the origin) rather than as queuing, and a
manual probe sees an empty reply rather than an error status.

Listen sockets, accepted connections, and files are opened close-on-exec (`sys.socket`,
`sys.accept`, `sys.open`) so the `auto_unmount` fusermount helper spawned at mount cannot
inherit them: a helper still holding the listen fd would keep the port bound after
`Server.stop`, and the next start would fail to bind.

### `/have` and the piece grid

`/have` replies carry `X-Piece-Size: <n>`, the piece grid the bitmap's bits are indexed
against. A fetcher running a different `--piece` treats that peer's answer as no-answer instead
of routing fills by bits that cover different byte ranges. A fleet should still run one piece
size: mixed grids degrade to origin traffic, never to wrong data. Peers older than this header
read as unknown and are assumed aligned. An advertised `0` is not unknown: `--piece 0` is
refused at mount, so a zero on the wire fails the probe like any other malformed grid.

The bitmap body is raw bits: one byte per eight pieces, bit i naming piece i least-significant
bit first, `ceil(pieces / 8)` bytes long. A bitmap that would exceed 16 MiB
(`max_have_body_bytes` in src/peer.zig, the same cap fetchers enforce) answers 500 without
opening a cache entry, so a huge sparse origin file cannot drive a half-gigabyte snapshot.
`piece.count` clamps at 2^32-1 pieces (`trackedEnd` in src/piece.zig); bytes past that have no
bit, and FUSE and peer reads take them from the origin rather than treating an empty `cover` as
a cache hit, which a sparse pread of the hole would otherwise answer with zeros.

### `/stage`, the staged data plane

`/stage` is the negotiated entry to the staged (RDMA) data plane. A node whose backend can
stage advertises `X-Stage: 1` on `/have`, and a fetching node then stages one piece at a time:
hydrate, at-rest verify, register the bytes, and reply with a 52-byte window (`len`/`rkey`/`addr`
plus the piece digest, advisory) that its backend reads.

Any `/stage` failure (501 because this node cannot stage, a malformed reply, a backend read
error, a dial or head timeout) falls back to `/data` on the same peer and marks the address
down for 2 s from the failure instant (`Catalog.noteStageDown` in src/discover.zig, stamped in
`fetchFromCands` after `fetchPieceStaged` returns), so a sequential fill does not retry the
extra round trip on every piece. A fleet without verbs never pays the probe, because the
capability rides the have-cache line.

The shipped backend is null, so this plane is protocol-and-pipeline only until the verbs tail
lands (design.md section 15).

### Status codes

Framing is identical on every endpoint: `Content-Length` always present, `Connection: close`,
empty body on errors.

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

### Wire parsing

A `/data` end past EOF clamps to it, and `bytes=N-` means through EOF (RFC 9110); suffix ranges
(`bytes=-N`) are rejected. Wire integers (`Range`, `Content-Range`, `Content-Length`,
`X-Piece-Size`, `/stage` `piece`) are unsigned decimal digits only: a leading sign or interior
underscore is malformed, the same rule RFC 9110 uses for Content-Length. Status lines are
`HTTP/1.1` plus a 3-digit code, so `2000` is not 200 and `4040` is not a healthy miss.

The fetching peer requires `206` plus a `Content-Range` whose start matches the request, whose
end is at most the request end (EOF clamp), and whose selected length equals `Content-Length`;
a shorter body under a matching window is refused rather than cached. `v0.1.0` servers already
send that header on every 206, so a mixed fleet still fills. Errors carry no body: both peers
of a conversation parse only the status line.

---

## Cache cull

Like cachefilesd, on **percent free** of the filesystem that holds `/var/cache/modelfs` (here
the 3.6T root): unprivileged available blocks (`statvfs.f_bavail` via `cull.freePercent`), not
root-reserved `f_bfree`.

| flag | default | meaning |
|---|---|---|
| `--brun` | 10 | stop culling |
| `--bcull` | 7 | start culling |
| `--bstop` | 3 | cull harder |

Culling punches piece-sized holes (default 16 MiB, `FALLOC_FL_PUNCH_HOLE`), clears that bit,
and leaves the sparse file. The next read hydrates that piece again.

Live entries are LRU by last access: FUSE reads, fills, and peer `/data`/`/stage` transfers
stamp `last_access`. The cull skips `pin`, files accessed in the last 10 s, pieces this node is
still filling, and entries with a cache-fd transfer in flight (`Cached.xfer`: peer
`/data`/`/stage` and the FUSE read from the bit sample through pread). Punching mid-send would
ship hole zeros the fetching peer cannot tell from real data.

Each round samples the 32 oldest idle live entries (`considerIdle` in src/store.zig) instead of
allocating and pinning the whole map to punch one piece; equal-recency ties break by rel bytes.
When the live sample has nothing punchable, `cullOneOnDisk` samples cache `data/` by mtime
(including after a restart, when nothing is in memory yet) and punches orphans; pins are still
skipped, but that path has no 10 s recency window. Unclaimed data files with no matching
sidecar are punched as a whole KEEP_SIZE extent.

```mermaid
flowchart TD
    free["cull.freePercent: f_bavail of the cache fs"] --> cmp{"against the watermarks"}
    cmp --> "|>= brun|" idle["idle: no round"]
    cmp --> "|bcull..brun|" round["cull one round"]
    cmp --> "|<= bstop|" hard["cull harder: keep going to brun"]
    round --> sample["considerIdle: sample the 32 oldest idle live entries"]
    hard --> sample
    sample --> skip["skip: pin, < 10 s idle, filling, or xfer in flight"]
    sample --> punch["punchPiece: save sidecar, then PUNCH_HOLE, clear bit"]
    punch --> empty{"nothing punchable in the sample?"}
    empty --> "|yes|" disk["cullOneOnDisk: sample data/ by mtime, punch orphan pieces or whole files"]
    empty --> |no| reap
    disk --> reap["reapIdle, every 30 s: unlink empty unpinned artifacts idle 300 s"]
```

`pin` is a marker under `pin/`. Culling itself never unlinks: after every piece is punched,
`reapIdle` (every 30 s, 300 s idle) unlinks empty unpinned data and meta artifacts so the
in-memory map stays bounded on nodes that churn paths. `Store.forget` unlinks cache artifacts
when the origin name goes away through unlink or rename.

---

## Piece integrity (blake3, Level 1)

Every piece that lands in the cache carries a blake3 digest of its bytes (`piece.digest` in
src/piece.zig, `Store.Cached.hashes` in src/store.zig), recorded at admit.

Verification happens twice:

* **At admit.** A peer fill is only accepted when a trusted digest already exists to check it
  against (`hydratePiece` in src/fuse_fs.zig, `expectedHash` in src/store.zig). Bytes that fail
  are discarded unmarked and the piece refills from the origin (`fill_err_verify`).
* **Before every `/data` and `/stage` serve.** Cached bytes are rehashed
  (`verifyRange`/`serveStage` in src/peer.zig). A mismatch drops the transfer with a 500, counts
  `serve_verify_fail`, and **self-heals**: `Store.healPiece` clears the piece's mark so the next
  fill re-hydrates from the origin instead of failing every serve of that piece.

`modelfs verify <rel>` rehashes a whole file's cached pieces against the manifest and clears
mismatched marks the same way. Local FUSE reads are not re-verified per read, so a piece that is
corrupt but never served to a peer waits for `modelfs verify` (operations.md, Integrity
runbook).

### Where trusted digests come from

**Origin fills and this node's own write-throughs.** The origin is the write authority, so bytes
read from it, or written to it by this node, are trusted, and their digest becomes the reference
for every later fill of that piece, including refills after a cull.

**The piece-hash manifest** (`Store.publishManifest` in src/store.zig), published on the origin
at `.cluster/manifests/<hex>` where `<hex>` is `blake3(rel)` hex (`piece.manifestName`): a
deterministic flat name, so no nested directories and no traversal risk. Any node that wrote or
filled a file publishes its digests at close (`mf_release` in src/fuse_fs.zig), so an ingested
file gets a manifest from its writer and a legacy file with no manifest gets one from the first
node that fully origin-reads it.

Readers load the manifest lazily, once per entry size (`expectedHash`), merging only hashes this
node does not already hold from an origin fill or write-through. Loading is deliberately
conservative:

* A transient load failure (an NFS negative cache hiding the writer's just-published manifest)
  is retried after `manifest_retry_ms` against the caller's monotonic instant, rather than
  disabling peer fills for the entry's lifetime.
* A manifest whose grid, size, or origin identity (mtime/ino trailer) disagrees with the
  reader's is ignored: origin fills, no peer verification.
* A load that races a wipe (`writes` bumped by a size change, same-size rewrite, or distrust
  while the origin read is off `file.mu`) is dropped rather than merged.
* A manifest whose mtime predates `Cached.origin_id` is retried the same way
  (`Store.tryLoadManifest`). The blob still names the previous object's digests at the same
  `file_size`, and admitting them would let a peer fill resurrect pre-rewrite bytes.

A file with no manifest anywhere has no trust reference, so its fills stay origin-only. That is
the cost of never serving unverified bytes (threat-model.md, former gap R2).

### Digest lifetime

Digests survive a punch (they are the expectation a refill must meet) and are dropped together
with the marks on size change, same-size rewrite (mtime/ino), distrust, and forget
(`Store.clearHashes`).

The sidecar bitfield prefix is unchanged; an optional origin-identity trailer follows the bits
so a restart can still detect a same-size rewrite. The same identity is an optional trailer on
the origin manifest, so a rewrite cannot keep the previous object's hashes as the trust
reference for peer fills. Hashes ride in memory and in the manifest, not in the bit bytes.

Manifest blobs are bounded (64 MiB, `Store.max_manifest_bytes`), parsed by a fuzzed codec
(`piece.manifestDecode`), and published atomically (tmp + rename, lazy mkdir of
`.cluster/manifests` like lease publish); lease walks and sweeps skip them (no `.json`/`.tmp`
names).

---

## Writes and races

A write is NFS 1:1, then a copy into this node's cache. If NFS fails, the write fails. There is
no write-back buffer.

```mermaid
sequenceDiagram
    participant K as kernel (FUSE)
    participant W as mf_write
    participant O as NFS origin
    participant C as this node's cache
    K->>W: write(buf, off)
    W->>O: originPwrite
    O-->>W: n bytes landed
    W->>O: statOrigin (size + identity sample)
    alt observed size == write end
        W->>C: cacheFillIdentified (marks preserved, short tail dropped)
    else size diverged (NFS lag or foreign write)
        W->>C: getIdentified (conservative mark reset)
    end
    C->>C: pwrite cache fd, mark fullCover pieces, record digests
    W-->>K: n
``` `originPwrite` (and FUSE create/truncate, lease/status/sidecar
`writeFile*`) treat a failed close after a successful write as failure: NFS reports delayed
write errors there.

`fsync` and `fdatasync` through the mount (`Store.originFsync` in src/store.zig) open the origin
name and issue the matching COMMIT. An unwired FUSE `fsync` would return ENOSYS, which the
kernel converts to success (`no_fsync`), so later fsyncs would never reach the origin.

`create`, `mkdir`, and `chmod` apply the caller's permission bits only (`clientCreateMode` in
src/fuse_fs.zig): setuid, setgid, and sticky are stripped so a mount writer cannot plant a
daemon-owned special-bit executable.

### Keeping marks honest across a write

`Store.copyIntoCache` bumps a per-entry write generation unless the copy already fully covers
marked pieces (a FUSE retry of the same write-through), and records blake3 digests for the fully
covered pieces from the write buffer; boundary pieces drop their old digest, since their bytes
are now a mix.

That generation is what makes concurrent mutation safe. `Store.completeFill` drops an in-flight
fill whose generation no longer matches, and `Store.finishPiece` re-checks it after the cache
write, so a truncate, size reconcile, or distrust that landed during the pwrite cannot mark the
fill's pre-mutation bytes.

If the cache copy itself fails, overlapping piece marks drop and the sidecar is saved, so this
node's reads and `/have` answers cannot serve pre-write bytes; those pieces refill from the
origin. A retry of bytes already in the cache (matching hashes) is a no-op; any other
overlapping range is unmarked so readers refill from the origin.

### Lock ordering against culls and sends

* `copyIntoCache` skips the pwrite while `Cached.xfer` is nonzero (a peer sendfile or FUSE read
  of the cache fd): mixing new write-through bytes into an in-flight copy would let the peer
  mark a torn piece filled.
* `mf_read` holds `xfer` from the size sample through the cache pread, so a cull cannot hole a
  piece between the bit check and the pread, including while a straddling read hydrates the next
  piece past the 10 s recency window.
* `Store.punchPiece` takes the same content lock as the copy, so a cull cannot hole a piece
  between the write-through pwrite and its mark.
* `Store.truncateCacheFd` refuses to cut a live cache descriptor while a peer `/data` send
  (`Cached.xfer`) is streaming from it.

Further misses on the writing node take the origin (`hydratePiece` in src/fuse_fs.zig). A fill
discarded by a concurrent write-through retries once from the origin, then fails the read with
EIO rather than spinning while writers keep landing.

### Two writers, and UMA

Two writers on the same path: the last `pwrite` on NFS wins. There is no cluster lock. The other
node's cache drops marks on the next open or read once it observes a newer origin mtime or a
different inode (`Store.getIdentified`); until that stat, a warm read of already-cached pieces
can still serve the previous write. Ingest on one node; everyone else reads. A second copy of a
model gets a new path.

The kernel page cache is off (`direct_io`) because it is UMA RAM shared with the GPU. mmap of
FUSE files will fail and engines fall back to `read`. `--kernel-cache` turns it back on if you
need mmap and the file fits in RAM.

---

## Command details

The [README](../README.md) has the command list. What each one reads and refuses:

### `status`

Prints the daemon's `status.json` from the cache dir (0600, so another uid gets EACCES rather
than a live/dead verdict). It is retired on two axes, so a monitor keying on this command's exit
code cannot be lied to:

* **Crashed.** A missing file, or a leftover naming an exited pid.
* **Wedged.** A live pid whose heartbeat is more than 120 s old: a hung daemon keeps its pid but
  stops rewriting the artifact. 120 s tolerates eleven missed 10 s ticks.

Age prefers `mono_s` (CLOCK_MONOTONIC, comparable across processes on this machine) so an NTP
step or admin clock set cannot flip the verdict. A leftover from the previous boot (`mono_s`
ahead of now, CLOCK_MONOTONIC having reset) is stale even when pid reuse keeps the pid check
green. Artifacts from older builds fall back to wall-clock `now_s`.

| Group | Fields |
|---|---|
| Liveness | `id`, `pid`, `uptime_s`, `now_s`, `mono_s` |
| Topology | `peers`, `piece`, `inflight` (HTTP handlers) |
| Saturation | `cache_free_pct`, the same sample culling runs on; `-1` when statvfs fails, i.e. culling suspended |
| Origin health | `origin_down`, 1 while an EIO/ESTALE/ETIMEDOUT getattr/open/stat, write, origin pread, lease publish, or `.cluster` walk has not yet recovered |
| Lifetime counters (`stats`) | reads/writes with errors, warm-cache reads (`reads_warm`), cumulative read/write/peer-HTTP durations in ns (`http_nanos` covers `/have` `/data` `/stage`, not `/ping`), piece fills by source with byte totals including `bytes_to_peer`, per-tier fill failures (including origin hydrations done to serve a peer), `probe_err`, `lease_err`, `meta_err`, pieces culled, `http_ok`, rejected auths, `http_405`, 5xx replies, malformed request heads, connections dropped at the inflight cap, and `serve_verify_fail` |

### `peers`

Lists every lease in `origin/.cluster` with its addresses and whether it is still live, using
the same `walkLeases` walk `Catalog.refresh` uses: dot-prefixed names skipped, O_NOFOLLOW,
corrupt entries skipped. Rows sort by lease file name and each row's addresses by ip then port
(`addrTieLess`), so NFS readdir and a mixed-fleet document's `getifaddrs` order cannot change
the listing.

An unreachable `--origin`, or a regular file at `--origin`, exits 1 for mount, peers, verify,
and dupes (`resolveOriginDir` in src/main.zig). An existing origin with no `.cluster` dir yet
lists as empty and exits 0. An unreadable `.cluster` (EIO, ENOTDIR, EACCES) exits 1 with the
reason on stderr (`cmdPeers`), so a pipe cannot read the failure as an empty fleet. `dupes --all`
applies the same split to `origin/.cluster/manifests` (`cmdDupesAll`).

### `pull`

Downloads one Hugging Face model revision onto the origin, where the mounts then serve it. The
recursive tree listing for the revision names every file and its size; files already present at
that size are skipped, so a rerun resumes, and each download lands as `<name>.part` and is
renamed only once complete.

`--revision` takes a branch, tag, or commit (default `main`); `--dest` sets where under the
origin the files land (default: the repo id). The token comes from `HF_TOKEN`, else
`$HF_HOME/token`, else `~/.cache/huggingface/token`, and travels as a privileged header so it is
dropped on the redirect to the signed CDN host. There is no token flag because argv is
world-readable, and core dumps are disabled for the run when a token is in play.

Everything the endpoint returns is untrusted: repo ids and refs are held to a URL-safe charset
with no `.`/`..` segments, file names are percent-encoded into the download URL, and every
listed path passes `relOk` and `relIsCluster` against the joined destination before it reaches
the origin (`cmdPull` src/main.zig, src/hf.zig).

```mermaid
flowchart TD
    start["modelfs pull owner/name @revision --dest"] --> token{"HF_TOKEN or the huggingface token file?"}
    token --> "|yes|" listing["GET the revision tree; token rides a privileged header,<br/>stripped on the CDN redirect"]
    token --> "|no|" anon["anonymous GET tree"]
    listing --> parse["parseTree: files only, every path through<br/>relOk + relIsCluster against the destination"]
    anon --> parse
    parse --> have{"lstat: regular file already at the listed size?"}
    have --> "|yes|" skip["skip; a rerun resumes here"]
    have --> "|no|" get["GET resolve URL into name.part (O_NOFOLLOW, O_TRUNC)"]
    get --> size{"bytes landed == listed size?"}
    size --> "|yes|" rename["rename part onto the real name"]
    size --> "|no|" refuse["refuse the file; rerun refetches it"]
```

### `update`

Finds the live daemon the same way `status` does (`status.json` pid plus the 120 s heartbeat
under `--cache` / `MODELFS_CACHE`) and asks that process to replace its image without
unmounting. A missing, stale, or dead `status.json` is a named exit 1.

The kernel FUSE connection and the peer listen fds stay open across the exec, and serving
identity (origin, cache, piece size, node id, listen port, advertise/seeds, watermarks, io mode,
cluster PSK) is reconstituted from a sealed memfd, so the PSK never appears on argv
(`cmdUpdate` src/main.zig; `execHandover` / `attach` src/fuse_fs.zig; codec src/handover.zig).

Two things make that possible:

* **The daemon speaks libfuse's low-level API.** The high-level API keeps the inode table
  privately and aborts on an inode it does not know, which is exactly what the replacement image
  inherits from the kernel. So the ino/path/nlookup and fh/path tables are modelfs's own
  (`State.nodes`, `State.opens`) and travel in the handover state.
* **The connection's `FUSE_INIT` request is captured verbatim off the wire** (`captureInit`) and
  replayed into the new session (`replayInit`) with the reply dropped. The kernel sends INIT
  once per connection and libfuse answers every request with EIO until it has seen one; nothing
  derived from that request round-trips, so it is kept as bytes.

```mermaid
sequenceDiagram
    participant CLI as modelfs update
    participant D as live daemon
    participant N as replacement image
    CLI->>CLI: /proc/self/exe + random handshake token
    CLI->>D: write update.req (token) under --cache
    CLI->>D: SIGUSR2
    Note over D: session exits; state is captured, not re-read
    D->>D: knobs, PSK, inode/fh tables, captured FUSE_INIT -> sealed memfd
    D->>N: exec self _handover --state-fd N /models (no secret on argv)
    N->>N: restoreMaps, replayInit (reply dropped)
    N->>CLI: update.ack (same token) under --cache
    CLI->>CLI: poll, match token, report pid
    Note over CLI,N: the kernel FUSE connection and the peer listen fds stay open throughout
```

Teardown of a replaced image rides the `auto_unmount` helper the original mount left behind.
`scripts/test_hot_reload.sh` drives the whole path on a live mount.

---

## Configuration rules

The [README](../README.md) lists the flags. These are the rules behind them.

### Environment

`MODELFS_ORIGIN`, `MODELFS_CACHE`, `MODELFS_PSK`, and `MODELFS_ID` (mount only, like `--id`) set
the same values as their flags. `MODELFS_PSK_VALUE` carries an inline secret that no flag
accepts. `MODELFS_LOG` and `--log` move the log ceiling (`err`, `warn`, `info` default, `debug`)
on every command. An explicit flag always wins.

Every `MODELFS_*` value is trimmed of surrounding whitespace (`envValue` in src/main.zig), so an
EnvironmentFile trailing space or a copied path with a newline cannot become the path, and an
empty or whitespace-only value counts as unset.

Both PSK sources trim the same way (`loadPsk`), with one deliberate exception: a whitespace-only
`MODELFS_PSK_VALUE` is refused as empty rather than falling through to the PSK file, matching
the file form, so an EnvironmentFile newline cannot start a node that then 401s every peer.
`MODELFS_PSK_VALUE` also cannot be combined with `--psk` or `MODELFS_PSK` on mount, which would
otherwise silently prefer the inline secret.

Any other `MODELFS_*` name is refused as a typo'd knob on every command. That is why the harness
and drill scripts keep their knobs outside this namespace (`MF_TEST_*`, `MF_DRILL_*`).

### Addresses and paths

* `--listen [IP:]PORT` picks the port; the IP is ignored, because binding is always all
  interfaces.
* `--advertise IP[:PORT][,...]` replaces the auto-detected NIC list rather than adding to it,
  and falls back to `127.0.0.1` when no NIC qualifies. A defaulted advertise port follows
  `--listen`; an explicit non-default port is bound as written (`leaseAddrs` in src/main.zig).
* `--listen`, `--advertise`, and `--seed` all refuse port 0: an ephemeral bind would still
  advertise 0 in the lease.
* `--advertise` and `--seed` also refuse `0.0.0.0` and `255.255.255.255` (`isDialableHost` in
  src/discover.zig). `parseV4` admits them because `inet_pton` does, but neither is a unicast
  address a peer can dial.
* `--seed HOST[:PORT]` bootstraps peers while `origin/.cluster` has no live lease.
* A cache or mountpoint path that exists as a regular file is refused as "not a directory"
  (`ensureDirReal` in src/main.zig), the same class of gate `resolveOriginDir` applies to
  `--origin`.

---

## Logging

The daemon runs in the foreground under systemd `Type=simple`. Journal output has two shapes.

### Per-event lines, failure-only and edge-triggered

A busy read storm must not flood the journal the way per-piece origin fills would. Anything
recurring logs its first failure and its recovery, and rides a counter in between:

| Condition | First failure | Recovery |
|---|---|---|
| Origin I/O outage (EIO/ESTALE/ETIMEDOUT on getattr/open/stat, write, or origin pread during fill, cache fallback, or peer `/data` hydration; not ENOENT) | path and errno | `origin recovered` |
| Discovery-tick lease publish | `lease publish failed` | `lease publish recovered` |
| `.cluster` walk unreadable | `cluster leases unreadable` | `cluster leases recovered` |
| Accept loop | `accept failed` | `accept recovered` |
| `/have` probe to a peer, per peer (a 404 counts as answering) | `peer <ip>:<port> /have probe failed` with the error class | logged on the next success |
| Cache-filesystem statvfs (suspends culling) | logged | `culling resumed` |

The lease-publish and `.cluster`-walk failures feed the same `origin_down` flag as FUSE I/O
(`tickCluster` in src/fuse_fs.zig), so an idle node with a dead origin is visible without
waiting for a FUSE getattr.

Unauthorized peer requests, failed piece fetches (with `ip:port` and the error), and cache
errors log per event. `pin` and `unpin` each land one info line, so "why is this file never
culled" is answerable from the journal. Cull watermarks are validated once at flag parse, not
per sample.

### The `tick:` line

One line per discovery interval, only while some counter moved, so an idle node logs nothing.
Membership changes log `cluster peers N -> M` even when counters are idle, so losing the fleet
reaches the journal without waiting for the next fill.

The tick line carries the only latency signal there is:

| Field | Meaning |
|---|---|
| `rd_us` / `wr_us` | average wall time of a FUSE read/write over the interval |
| `http_us` | average `/have`+`/data`+`/stage` handler time, over `httpok`+`http5xx`. `/ping` is liveness: neither timed nor counted, so a health-check poll cannot fire an idle tick |
| `fill_ms peer/nfs` | average per-piece hydration stall by tier. A miss blocks the reader for one whole piece, so this is how "reads got slow" is diagnosed from the journal |
| `md_us` | interval **total** (these handlers count wall time, not calls) of the getattr/open/statfs latency counters, so a metadata storm is visible in a window where no data read moved. The three publish separately in status.json |

And the counters worth knowing by name:

| Counter | What it says |
|---|---|
| `reads_warm` | fully cached FUSE reads. Hit rate is `reads_warm / reads_ok` |
| `probe_err` | `/have` probes that failed for a reason other than a healthy 404: a dead peer, PSK drift, a malformed reply. The signature of a cluster silently degraded to NFS-only |
| `httpok` / `serve_mib` | accepted `/have` 200, `/data` 206, and `/stage` 200 replies and the bytes they served (`/have`/`/data` Content-Length; `/stage` the window's piece `len`, not the 52-byte HTTP body), so a node serving pieces is distinguishable from an idle one |
| `httpbad` | connections whose request head never completed |
| `httpdrop` | connections closed because all inflight slots were taken: the server refusing work under saturation |
| `http405` | requests refused for method. The journal line is deduplicated on the same window as the 401 warn and echoes the method through `discover.displayName`, since a PSK holder picks that token |
| `meta_err` | getattr/open/readdir origin-infrastructure failures (EIO/ESTALE/ETIMEDOUT), so an `ls` during an NFS outage does not look like a slow-but-healthy `md_us` interval |
| `lease_err` | failed lease publishes: the heartbeat of an idle node whose origin is down |

---

## What did not ship

Canonical status is [design.md](design.md) sections 2.1 (G1-G10) and 13 (key decisions). Do not
treat this list as a second copy of those rows.

- Origin-less two-node (no shared dir)
- Content-addressed dedup (Level 2) and CDC (Level 3): **shelved/dormant**, not merely unbuilt;
  see design.md section 14. Level 1 integrity shipped ([Piece integrity](#piece-integrity-blake3-level-1))
- Full-file background stripe
- Sparse-file hydrate / FUSE passthrough (the agent stays in the I/O path; `direct_io` is the
  default)
- cachefilesd stacked on FUSE (FUSE is not an FS-Cache client)
