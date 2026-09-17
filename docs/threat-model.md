# Threat model

| Field | Value |
|---|---|
| Status | Living document; describes `src/` as of the date below |
| Last reviewed | 2026-09-13 |
| Covers | modelfs daemon (`mount`) and CLI as of `v0.14.1`, peer HTTP protocol, lease discovery, FUSE surface, handover IPC, Hugging Face pull |
| Security owner | Unassigned |
| Review cadence | Unassigned; re-verify against `src/` after any protocol, auth, or listener change |

ModelFS is a single-binary FUSE cache for LLM weights with a plaintext peer-to-peer HTTP tier,
bound to all interfaces, guarded by one static pre-shared key per cluster. This document names
what can be attacked from outside the node, what it costs, and which controls exist. Findings
point at code; fixes belong to sec-review passes, not here.

Every claim below cites a file and symbol. When code moves, re-verify the citation before
trusting the row.

---

## Risk-ranked summary

| # | Risk | Boundary | State |
|---|---|---|---|
| [R1](#r1-plaintext-transport-with-inline-credentials) | Plaintext peer transport: the PSK rides every request and weights ride in the clear | network to peer server | **No mitigation** |
| [R2](#r2-peer-served-piece-integrity-mitigated) | A hostile peer's crafted pieces poisoning every cache in the fleet | peer to peer | Mitigated: blake3 verify before admit and before serve |
| [R3](#r3-static-shared-psk-no-rotation-or-revocation) | One static PSK for the whole cluster, no identity, rotation, or revocation | secrets to code | Operational only |
| [R4](#r4-trivial-peer-service-saturation) | 16 handler slots, held from before auth: 16 slow sockets stall all peer fills | network to peer server | Partially bounded |
| [R5](#r5-lease-poisoning-enables-psk-capture) | Lease poisoning (or a hijacked `--seed HOST`) redirects fetches and captures the PSK | node to origin / DNS at mount | **No mitigation** |
| [R6](#r6-authenticated-amplification-and-cache-littering) | Authenticated amplification: any PSK holder drives NFS reads and NVMe writes on any node | peer to peer | Bounded only by cull watermarks |
| [R7](#r7-cache-artifacts-trusted-without-verification) | Cache bitfields trusted at load, so a tampered sidecar serves hole zeros as data | local user to cache | **Not prevented** |
| [R8](#r8-crash-time-psk-spill-mitigated) | A crash dumping process memory that holds the secret | secrets to code | Mitigated: `RLIMIT_CORE` zeroed at mount |
| [R9](#r9-rejected-request-anonymity-mitigated) | Rejected peer requests leaving no attributable trace | network to peer server | Mitigated: source-attributed 401/405 logging |

---

## Assets

| Asset | Where it lives | Impact if lost |
|---|---|---|
| LLM weights | origin tree (authoritative copy), per-node piece caches (`data/`) | Exfiltration of valuable or licensed models; silent corruption poisons training and serving runs |
| Cluster PSK | `/etc/modelfs.psk` or `MODELFS_PSK_VALUE`, process memory, and every request's `Authorization` header (src/main.zig, src/peer.zig) | Full impersonation of any node: read every weight, serve poisoned pieces |
| Availability of the read path | `/models` mount, peer port, NFS origin | Reads block until a piece fills; stalled peers degrade the cluster to origin-tier throughput |
| Cache integrity | `data/` sparse files, `meta/*.pieces` bitfields, and per-piece blake3 digests in memory and in the origin manifest (`Store.hashes`/`expectedHash` src/store.zig) | Punched holes read as zeros. Peer fills are verified against a trusted digest before admit and serves before streaming, and `modelfs verify` rehashes against the manifest; the sidecars themselves are still trusted at load (R7) |
| Origin write authority | The NFS export itself | Out of modelfs' control: anyone with origin write access rewrites weights and leases directly |
| Operational state (`status.json`) | cache root, created 0600 (`writeFileOwnerOnly` src/sys.zig) | The daemon's uid and root can read pid, peer count, cache fill, and `origin_down`; not weights, not the PSK |
| Hugging Face Hub token | `HF_TOKEN`, `$HF_HOME/token`, or `~/.cache/huggingface/token`, CLI memory during `modelfs pull` (src/hf.zig, src/main.zig) | Unauthorized read/write access to user's private models and gated repositories on huggingface.co |

The daemon handles no credential but the cluster PSK; `modelfs pull` is the only command that
reads a Hugging Face token, and only from the environment or token file.

---

## Entry points

Everything below accepts input from outside the process. Each is where validation must happen.

### Peer HTTP server

Bound `0.0.0.0` (IPv4 only, `sockaddr_in`) on every unique advertised port, default 18080
(`bindAll`/`bindOne` src/peer.zig). `--listen [IP:]PORT` consumes only the port (`listenPort`
src/main.zig): there is no loopback-only or interface-scoped bind.

Accepts `GET /ping`, `GET /have?path=`, and `GET /data?path=` with a
`Range` header, plus the `Authorization` header (`handleConn` src/peer.zig). Non-GET after a
valid bearer answers `405 Allow: GET` and counts in `http_405`.

### FUSE operations on the mountpoint

Ops table constructor `llOps()` (returning `fuse.fuse_lowlevel_ops`) and path policy
`resolveRel`, both src/fuse_fs.zig. Accepts paths, write buffers, modes, and statfs from every
local process that can reach the mount.

`default_permissions` is always on, and `--allow-other` is the only way a uid other than the
mounter reaches the mount (src/main.zig). There are no `symlink`, `mknod`, `link`, or `xattr`
handlers: libfuse answers those with ENOSYS.

### Lease files written by other nodes

`<origin>/.cluster/<id>.json`, read by `Catalog.refresh` and `sweepLeases`, written by
`Catalog.publish`, and listed by `modelfs peers` through `walkLeases` (all src/discover.zig).
Accepts JSON documents: ids, expiry timestamps, and address lists, parsed in src/proto.zig.

### Origin file tree

`statOrigin` src/store.zig, hydration src/peer.zig. Accepts file bytes and sizes as they are on
the NFS export.

### CLI subcommands and flags

Dispatch and `parseArgs`, src/main.zig. Accepts paths, addresses, sizes, watermarks, id, the log
ceiling (`--log`), and the PSK **file path**, never the secret: `--psk-value` is gone.

`--seed HOST[:PORT]` hostnames are DNS-resolved once at mount (`buildSeeds` src/main.zig).
`modelfs update` locates the daemon via `status.json` (same pid and age gates as `status`) and
asks that process to replace its image; the PSK travels on a sealed memfd, not argv (`cmdUpdate`
src/main.zig, src/handover.zig). The replacement image enters via internal subcommand
`_handover --state-fd <fd>` (`cmdHandover` src/main.zig), which decodes the state blob from the
sealed memfd (`handover.decode`, capped at `max_state_bytes`), inherits the FUSE session and
peer listen descriptors, replays `FUSE_INIT`, writes `update.ack`, and unlinks `update.req`.
`modelfs pull` takes a Hugging Face `owner/repo` and a ref,
both held to a URL-safe charset with no `.`/`..` segments before being spliced into an endpoint
URL (`repoOk`/`revisionOk` src/hf.zig).

### Hugging Face API responses (`modelfs pull`)

Listing parse `parseTree`, download `fetchOne`, both src/hf.zig. Accepts JSON from
`huggingface.co` naming every file of a revision, and the file bodies themselves, served through
a redirect to a signed CDN host.

Every listed path is refused unless it passes `relOk` and, joined onto `--dest`, `relOk` again
plus `relIsCluster`, so a listing cannot write outside the destination or plant a lease file.
Names are percent-encoded into the download URL. Bodies stream to `<name>.part` opened
`O_NOFOLLOW` and are renamed only when complete. Transport is HTTPS with the platform trust
store, and the `HF_TOKEN` bearer travels as a privileged header so it is stripped on the
cross-host redirect.

### `modelfs dupes` manifest telemetry

`cmdDupes`/`cmdDupesAll` src/main.zig. Accepts paths relative to the mount (gated by `relOk`
plus `relIsCluster`) and every piece-hash manifest under `<origin>/.cluster/manifests/`. The
walk is read-only and never touches model bytes, is O_NOFOLLOW via `sys.opendirNoFollow`, and
manifests are parsed by the fuzz-covered `manifestDecode` src/piece.zig, bounded by
`Store.max_manifest_bytes` (64 MiB in src/store.zig, capping allocations for up to ~14 TiB
files at the default 8 MiB grid) to guard against unbounded allocation from untrusted artifacts.

Skip-warn paths filter manifest file names through `proto.displayName(name)` (src/main.zig),
matching the printable gate on lease names so crafted manifest names cannot forge journal lines
or inject terminal escapes. Origin-write precondition, CLI-triggered (B3).

### Secrets read from the environment or disk

| Source | Code | Accepted |
|---|---|---|
| PSK file (`--psk`, default `/etc/modelfs.psk`) or `MODELFS_PSK_VALUE` | `loadPsk` src/main.zig | Up to 4096 bytes after surrounding-whitespace trim. Files may contain at most 4098 raw bytes, allowing a maximum-length secret with LF or CRLF. A whitespace-only value is empty and refused; interior CR/LF is refused |
| Hugging Face token: `HF_TOKEN`, else `$HF_HOME/token`, else `~/.cache/huggingface/token` | `loadToken` src/hf.zig | Up to 4096 bytes after trimming for `HF_TOKEN`; files are capped at 4096 raw bytes, including whitespace. Whitespace-only counts as unset. No flag carries it, and `cmdPull` disables core dumps for the run when one is loaded |
| `MODELFS_ORIGIN/CACHE/PSK/PSK_VALUE/ID/LOG` | src/main.zig | Same values as their flags; an explicit flag wins. Whitespace-trimmed (`envValue`), empty counts as unset, except a whitespace-only `MODELFS_PSK_VALUE` which is refused as empty. Any other `MODELFS_*` name is refused as a typo (`checkKnownEnv`) |

### Cache-dir artifacts read back at runtime

`meta/*.pieces` bitfields, `pin/` markers, `status.json`, and `update.req`/`update.ack`. Read by
the store walk and load paths (src/store.zig), the status read (src/main.zig), and the handover
request (src/handover.zig).

This is on-disk state written by this same process, trusted structurally but not
cryptographically. `modelfs pin`/`unpin` writes `pin/` with no daemon and no PSK check
(`cmdPin`); `modelfs verify` rehashes cache bytes against the origin manifest (`cmdVerify`);
`.cluster` names are refused on pin, verify, and dupes (`relIsCluster`). `update.req` names the
replacement binary path and a handshake token (0600, O_NOFOLLOW), and anything running as the
daemon's uid can plant one.

### Not present

No scheduled jobs, network-based RPC or IPC sockets (Unix domain sockets / named pipes; local
daemon replacement uses file-and-signal handover via `update.req`/`SIGUSR2` and an inherited
sealed memfd), message consumers, webhooks, or debug/admin services. The binary links only
libfuse3, libc, and pthread; `build.zig.zon` declares no dependencies. The static release
binaries go one further: the vendored libfuse3 (`.deps/libfuse3-3.16.2/`) is compiled in, and
nothing is dynamically linked at all.

---

## Trust boundaries and data flow

```
local engines/processes ⇄ [FUSE/kernel] ⇄ modelfs daemon ⇄ [TCP :18080, plaintext] ⇄ peer daemons
                                   ⇅                            ⇅
                          [origin dir, NFS] ⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄ origin holds .cluster leases too
                                   ⇅                            ⇡ (writes model files)
                          [cache dir on NVMe] (bitfields, pins, status.json)
                                   ⇅ [update.req / SIGUSR2 / sealed memfd]
                       modelfs update / _handover (CLI)
                                                                ⇣ (HTTPS)
                       modelfs pull (CLI) ⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄ Hugging Face API & CDNs
```

### B1: local processes to daemon (FUSE)

Includes tenant-to-tenant on the same node. The authority transition: anything crossing the
mount becomes daemon-uid I/O against the origin and the cache.

Enforcement is delegated to the kernel through `default_permissions`, which is always mounted;
`allow_other` is opt-in (src/main.zig) and is the only way a uid other than the mounter reaches
the mount. Path policy is centralized in `resolveRel` (src/fuse_fs.zig): `.cluster` is invisible
(ENOENT on lookup, EPERM on mutation), and traversal and absolute paths get EPERM via `relOk`.

There is no multi-tenant boundary: every node in a cluster shares one PSK (R3). Local-user
isolation on one spark is origin modes plus cache file and directory modes.

### B2: network to peer server

The internet-facing boundary of this system. Treat any routable host as the adversary.

Every request, including `/ping` and non-GET, requires the bearer PSK, checked before the method
gate and route dispatch (src/peer.zig); comparison is timing-safe SHA-256 equality
(src/proto.zig). A missing or wrong token is `401 WWW-Authenticate: Bearer` on every method, so
an unauthenticated POST cannot learn that GET is the only verb, though the 401 itself still
confirms a live listener. After auth, non-GET answers `405 Allow: GET`.

The request path is URL-decoded into a fixed buffer and gated by `relOk` before touching origin
or cache roots (src/peer.zig).

There is no per-node identity: possessing the PSK is membership. Binding is always `0.0.0.0` on
each unique advertised port (`bindAll`), so `--listen 127.0.0.1:18080` does not confine the
listener to loopback.

### B3: daemon to origin (shared directory)

The origin is semi-trusted storage that also carries control data from other nodes. The
untrusted inputs are lease JSON (ids, addrs), file names under `.cluster`, piece-hash manifests
under `.cluster/manifests/` (the trust reference for peer fills, parsed by `manifestDecode`
src/piece.zig), and the model bytes themselves.

Controls:

* Expired, corrupt, and self leases are skipped (src/discover.zig).
* Lease ip fields are validated by a hand parser before socket use (`parseV4` src/discover.zig),
  and again by `inet_pton` at dial (src/peer.zig).
* O_NOFOLLOW on every staged write into shared or locally-writable directories: lease staging
  (src/discover.zig), cache data (src/store.zig), pin markers and status.json (src/sys.zig), and
  the status staging rename (src/fuse_fs.zig).
* Control-byte filtering before any untrusted name or id is echoed to logs or terminals
  (`containsControl`/`displayName` src/proto.zig), applied in `peers` output (src/main.zig) and
  refresh/sweep logging (src/discover.zig).

`--seed HOST` is a sibling control-plane input. The hostname is resolved once at mount
(`buildSeeds` src/main.zig via `sys.resolveIpv4`) and the resulting IPv4 becomes a dial target
that then receives the PSK in a Bearer header: the same handoff as a forged lease, with DNS or
`/etc/hosts` as the precondition instead of origin write.

### B4: local process to daemon update (handover IPC)

Local authority transition and IPC entry point: `modelfs update` asks the running daemon to
replace its process image without unmounting (`cmdUpdate` src/main.zig, src/handover.zig).

* **Trigger**: The CLI writes `<cache>/update.req` (mode 0600 durable via
  `writeFileOwnerOnlyDurable` src/sys.zig, opened `O_NOFOLLOW`) containing an absolute binary path
  and a random 16-byte hex handshake token, then sends `SIGUSR2` to the daemon PID.
* **Daemon verification**: In `onUsr2` (src/fuse_fs.zig), the signal is ignored if no `FUSE_INIT`
  was captured (`st.init_len == 0`) or if `update.req` cannot be opened `O_RDONLY | O_NOFOLLOW | O_NONBLOCK`.
  The event loop is awakened via a non-blocking internal pipe (`wakeup_w`).
* **Authority transition**: In `serve()` and `execHandover` (src/fuse_fs.zig), the daemon verifies
  the replacement path is absolute (`bin[0] == '/'`), encodes live daemon state into a sealed memfd
  (`handover.encode` src/handover.zig), unsets `CLOEXEC` on the memfd, the FUSE session fd, and the
  peer listen fds, and executes `execve(replacement_bin, ["modelfs", "_handover", "--state-fd", N], environ)`.
* **Trust & blast radius**: Any process running as the daemon's uid or root can plant `update.req`
  and signal `SIGUSR2`. The replacement binary inherits the active FUSE session fd, the peer HTTP
  listen sockets, and the cluster PSK in the sealed memfd.

### B5: build to runtime

A single Zig binary: no Zig package dependencies, no plugins, and no config fetched at runtime
beyond the PSK file and the environment variables above. The one compiled-in third-party surface
is libfuse3.

The static release builds vendor static libfuse3 C source in `.deps/libfuse3-3.16.2/`, and the
cross-aarch64 build vendors two libfuse3 `.deb`s in `.deps/fuse3-arm64/`. Both directory
`SHA256SUMS` digests are verified by `build.zig` before compiling (and verified by
`scripts/extract_fuse3_arm64.sh` before unpack for arm64). Static release binaries compile the
vendored libfuse3 directly (`-Dfuse-static`), producing a fully static binary with no external
dynamic dependencies. The host build links whatever libfuse3 dev package is installed system-wide,
so host provenance is an operator concern.

The long-lived networked image is hardened at build time: a PIE (`exe.pie`) compiled PIC
(`exe_mod.pic`) with stack canaries and stack probes in every optimize mode (`stack_protector`,
`stack_check`, on both the executable and test modules). RELRO, BIND_NOW, a non-executable
stack, and the absence of DT_RPATH/DT_RUNPATH are pinned and checked on the linked ELF
(`checkHardenedElf` in build.zig, run from `zig build` and `zig build test`). `each_lib_rpath`
is off so `-Dfuse-lib` cannot become a runtime search path, build-ids stay `none` so a uuid
stamp cannot make two builds disagree, and non-Debug builds strip DWARF so `DW_AT_comp_dir`
cannot leak the build path into a shipped binary.

### B6: CLI to external model hub (Hugging Face API & CDN)

`modelfs pull` connects to the public internet (`huggingface.co` and redirect CDN endpoints)
over HTTPS to fetch model file trees and weights into the origin directory (`src/hf.zig`, `src/main.zig`).

* **Untrusted data**: JSON model tree listings (capped at `max_listing_bytes` = 8 MiB in `src/hf.zig`),
  HTTP redirect URLs from `/resolve/` endpoints to CDN hosts, and binary model payloads streamed from CDNs.
* **Outbound credentials**: Hugging Face user access token (`HF_TOKEN`, `$HF_HOME/token`, or `~/.cache/huggingface/token`).
* **Authority transition**: Fetched files land on the shared origin directory under the destination prefix,
  becoming authoritative models served to all cluster nodes.
* **Validation & controls**:
  - Outbound TLS with platform trust store (`std.http.Client`).
  - Strict input gating on CLI inputs before URL interpolation: `repoOk` (must be `owner/name`,
    strictly unreserved characters, single slash, bounded to 200 bytes) and `revisionOk` (branch,
    tag, or commit sha, no `.` or `..` segments, bounded to 200 bytes) (`src/hf.zig`).
  - Fixed-size 8 MiB writer for tree listings (`max_listing_bytes`) preventing unbounded allocation from a hostile endpoint.
  - JSON tree parsing (`parseTree` `src/hf.zig`) validates every listed path against `relOk` and `relIsCluster`,
    both bare and joined with `--dest`, preventing path escape or planting files inside `.cluster/`.
  - Staged download: streams to `<name>.part` opened `O_NOFOLLOW` with owner-only/clean permissions,
    and atomic rename to real name only upon complete download (`fetchOne` `src/hf.zig`).
  - Credential containment: `HF_TOKEN` travels only to the primary host (`huggingface.co`) as a privileged
    header and is stripped by `std.http.Client` on cross-host redirects to CDNs. The token is bounded to
    4096 bytes (`max_token_bytes`), core dumps are disabled during execution (`disableCoreDumps` `src/main.zig`),
    and memory is zeroed on exit (`std.crypto.secureZero`).

### Secrets flow

The PSK enters through a file read at startup (world-readable refused, group-readable warned) or
`MODELFS_PSK_VALUE`, both in `loadPsk` (src/main.zig). On mount the two sources are exclusive:
both set is refused rather than silently preferring the env value. No flag carries the secret
(`--psk-value` was removed), because argv would publish it to every local user through
`/proc/<pid>/cmdline`, while the environment block is readable only by the process owner and
root. The mount log line names origin, cache, id, piece, port, and watermarks, never the secret
(`cmdMount`).

It then lives for the process lifetime in memory, and leaves the host on every outbound peer
request in a plaintext header (src/peer.zig), and implicitly to any passive listener on inbound
connections.

After `loadPsk` succeeds, mount zeros `RLIMIT_CORE` (`disableCoreDumps`) so a crash cannot dump
the secret, overwrites `MODELFS_PSK_VALUE` in the environment in place (`scrubPskEnv`: preserves
`MODELFS_PSK_VALUE=` while X-filling only the secret value bytes to prevent standard library
environment scanners like std's `Environ.scan` from crashing on a keyless entry) so child processes
and the `auto_unmount` helper cannot inherit it, and `secureZero`s the in-memory copy on teardown. A
`setrlimit` failure refuses to start rather than running with a dumpable secret.

Empty PSKs are refused before binding (both sources trim surrounding whitespace first, so a
whitespace-only `MODELFS_PSK_VALUE` is empty rather than a token that 401s every peer), as are
secrets containing interior CR/LF, which would corrupt the request head (`dupeHeaderSafePsk`).

Rotation means regenerating the file on every node simultaneously. There is no versioning,
overlap window, or revocation.

Hugging Face tokens enter via `HF_TOKEN` in the environment, `$HF_HOME/token`, or
`~/.cache/huggingface/token` when `modelfs pull` runs (`loadToken` src/hf.zig). The token is
capped at 4096 bytes (`max_token_bytes`), core dumps are disabled during execution (`disableCoreDumps`
src/main.zig), and the memory buffer is wiped with `secureZero` on exit. The token leaves the host
over HTTPS only to `huggingface.co` and is stripped on redirects to CDN hosts (`pull` src/hf.zig).

Accepted residual exposures: plaintext wire transmission of the PSK, `MODELFS_PSK_VALUE` in the process
environment until mount scrubs it (readable by the owner and root), ptrace or
`/proc/<pid>/mem` against a live daemon, and the single-secret trust model.

---

## Threats per boundary

STRIDE per boundary, tied to real entry points. Rows marked mitigated cite the control;
everything else appears in [Gaps](#gaps).

### B1: local processes to daemon (FUSE)

| Threat | State |
|---|---|
| **S** spoofing another local user | Delegated to kernel permission checks (`default_permissions`). Root bypasses everything by definition |
| **T** tampering with weights via writes | By design: writes go through 1:1 to the origin, last-writer-wins, no locking. Two-node staleness is a known consistency hazard, not mitigated in code (architecture.md, Writes and races) |
| **R** repudiation | None. Writes are not attributed or audited beyond aggregate counters |
| **I** disclosure across users | Mitigated by cache modes, below |
| **D** resource exhaustion | Bounded by cull watermarks and pin exclusions, below |
| **E** elevation of privilege | Mitigated by path gates and O_NOFOLLOW, below |

**Disclosure controls.** Cache data files are created 0600, with leftover 0644 tightened on the
next open (`cache_data_mode` src/store.zig). `data/`, `meta/`, `pin/`, and nested parents are
created 0700 (`cache_dir_mode`), and leftover 0755 roots are tightened on `ensureLayout`
(`tightenCacheDir`), so a uid blocked by origin modes cannot list which weights are cached or
pinned. Sidecars, pin markers, and `status.json` are 0600 (`writeFileOwnerOnly` src/sys.zig).
Origin create/mkdir/chmod modes arrive from the client but are masked to permission bits
(`clientCreateMode` src/fuse_fs.zig). `.cluster` is hidden from FUSE, from peer
`/have`/`/data`, and from `modelfs pin`/`unpin`/`verify`/`dupes` (`relIsCluster`); its
secrecy is irrelevant anyway, since leases hold no PSK.

**Exhaustion controls.** A local reader forcing misses drives origin reads and cache fills,
bounded by cull watermarks (src/cull.zig) and pin exclusions. Disk-only culling samples every
`relOk` name under `data/`, including leading-dot components (`walkData` src/store.zig; only `.`
and `..` are skipped), so hidden cache files cannot fill the filesystem past the watermarks
after a restart. `--kernel-cache` RAM use is operator-chosen.

**Elevation controls.** Path escape is blocked at `resolveRel`/`relOk`. Symlink redirection of
staged writes is blocked by O_NOFOLLOW (src/sys.zig). chmod, statfs, and directory opens use
O_NOFOLLOW (`sys.chmod`, `sys.statfsNoFollow`, `sys.opendirNoFollow`) rather than
lstat-then-follow, so a racer swapping a name to a link cannot chmod the target, list it through
the mount, or report the host root's size and free space via `df`. `statOrigin` is lstat, and
`mf_open` answers ELOOP on `S_IFLNK`. Client-supplied create/mkdir/chmod modes are stripped of
setuid, setgid, and sticky (`clientCreateMode`, applied at `mf_create`, `mf_mkdir`, `mf_chmod`).
There are no FUSE `symlink`/`mknod`/`link` handlers, so a mount user cannot plant origin links
through FUSE; origin write on the NFS export is B3. The disk-cull walk samples with lstat, opens
directories with O_NOFOLLOW, and skips non-regular entries, so planted links can neither be
punched through nor descended into (`walkData`).

### B2: network to peer server

| Threat | State |
|---|---|
| **S** spoofing a legitimate node | Possession of the PSK is total, and the PSK crosses the network in cleartext on every request, so a passive observer becomes a member (R1, R3) |
| **T** tampering with served or fetched bytes | Mitigated by blake3 verification, below |
| **R** repudiation of actions | Rejections are attributed and sampled; successful requests are not, below |
| **I** information disclosure | Weights and PSK are readable on path (R1). Error replies carry empty bodies and no internals; log lines include rel paths only after `relOk` strips control bytes. An unauthenticated request gets `401 WWW-Authenticate: Bearer`, confirming a live listener; `405 Allow: GET` only reaches an authenticated client |
| **D** denial of service | Partially bounded, below (R4, R6) |
| **E** elevation via path tricks | `..`, absolute, control-byte, and NUL paths are refused with 400 (`relOk` gate src/peer.zig). `.cluster` control paths answer 404, so lease JSON cannot be hydrated as a piece. Over-long paths that can never name an origin file also answer 400 rather than polluting the 5xx health gauge (the ENAMETOOLONG branch of `replyOriginStat`). Unknown routes are 404 before parameter parsing, and non-GET is 405 |

**Tampering controls.** Peer fills are verified before admit against a trusted blake3 digest,
which comes from the origin piece-hash manifest, an origin fill, or a local write-through
(`expectedHash` src/store.zig, verified in `hydratePiece` src/fuse_fs.zig). Cached bytes are
verified before every `/data` serve (`verifyRange` src/peer.zig). So a hostile peer's crafted
bytes never enter the cache, and a corrupt cached piece is never re-served. Routing-level
confusion is handled separately: mismatched `X-Piece-Size` answers are discarded. The residuals
are origin tampering (B3) and legacy cache entries with no manifest ([R2](#r2-peer-served-piece-integrity-mitigated)).

**Attribution.** Requests are anonymous beyond PSK possession. Rejections are attributed and
sampled: a 401 (wrong bearer) or 405 (authenticated non-GET) journal line names the accepted
source address, at most one of each per `auth_warn_min_gap_ms` (1 s) via
`claimAuthWarn`/`claimMethodWarn` (src/peer.zig), while `http_unauthorized` and `http_405` keep
the exact totals. Malformed-head scanner noise is counted (`http_malformed`) rather than logged
per event, to deny scanners a log-flooding lever. Successful requests carry no per-source audit
trail.

**Denial-of-service controls.** The handler cap is 16 with claim-then-check accounting. The head
read deadline is 10 s, defeating dribble-holds; body deadlines scale with Content-Length; a
declared request body is drained pre-auth under a second bounded hold (64 KiB / 10 s,
`drainDeclaredBody` src/peer.zig) so a close after the reply cannot RST it away.
Oversized and malformed heads are counted, not logged per event. 401 and 405 journal lines are
capped to one per second, so a serial scanner cannot fill the journal. Connections refused at
the cap are counted (`http_dropped`), so saturation is visible from status.json without
per-drop logging. Server-side allocation is range-bounded: ranges clamp to file size, and
hydration uses one reusable piece-sized buffer. Client-side `/have` bodies are refused above 16 MiB before
allocation (`max_have_body_bytes`); other allocated bodies honor a 512 MiB cap
(`max_alloc_body_bytes`). Remaining exposure: 16 slots is small enough to occupy with reconnect
loops, and authenticated requests force per-piece origin reads plus NVMe writes
([R4](#r4-trivial-peer-service-saturation), [R6](#r6-authenticated-amplification-and-cache-littering)).

### B3: daemon to origin (.cluster control plane)

| Threat | State |
|---|---|
| **S** forging membership | Anyone with origin write access can publish a lease naming arbitrary ips and ports, and victims will dial them. The forged peer still needs the PSK to answer `/data`, but the connection attempt itself hands the victim's PSK to the forged address in a Bearer header (`sendRequest` src/peer.zig). A lease `mbps` even lets the forged address win routing outright. The same handoff happens if `--seed HOST` resolves to an attacker IP at mount ([R5](#r5-lease-poisoning-enables-psk-capture)) |
| **T** tampering with other nodes' leases | Sweeping is mtime-based and skips only the sweeper's own id, so a co-tenant who can touch mtimes can evict live nodes from discovery. Requires origin write access, the same precondition as above |
| **R** repudiation | Leases carry no signature or provenance, and sweeps delete history |
| **I** disclosure | Lease documents deliberately exclude the PSK; contents are topology only |
| **D** discovery poisoning | Corrupt and expired leases are skipped rather than fatal. A flood of garbage lease files costs readdir plus parse per tick, unbounded by count. Minor, with an origin-write precondition |
| **E** elevation | Not applicable: no authority executes from lease content beyond dial targets |

### B4: local process to daemon update (handover IPC)

| Threat | State |
|---|---|
| **S** spoofing an update request | Gated by filesystem write access and signal permission: the CLI writes `<cache>/update.req` mode 0600 (`writeFileOwnerOnlyDurable` src/sys.zig); the daemon opens it `O_NOFOLLOW \| O_NONBLOCK` but does not validate its owner or mode. The cache root is operator-controlled, not forced to 0700. The kernel enforces `SIGUSR2` delivery permissions. A process running with the daemon's uid or root can plant a request naming an arbitrary binary |
| **T** tampering with handover state | Tampering in transit across exec is mitigated: the live state blob is encoded into a sealed memfd (`sys.memfdSealed` src/sys.zig, setting `F_SEAL_SEAL \| F_SEAL_SHRINK \| F_SEAL_GROW \| F_SEAL_WRITE`) before `execve`. JSON parsing validates request structure, not authenticity. The random token correlates the CLI request with its acknowledgement; it does not authenticate a request to the daemon (`decodeReq` / `randomToken` src/handover.zig, `cmdUpdate` src/main.zig) |
| **R** repudiation of updates | Handover completion logs to stdout (`updated pid {d}`) and daemon logs record handover steps and errors, but no cryptographic audit trail or signing of the replacement binary exists. `update.req` is unlinked after consumption or timeout |
| **I** disclosure of secrets across handover | Mitigated: the cluster PSK travels exclusively on the sealed memfd descriptor, never on argv or disk (`cmdUpdate` src/main.zig, src/handover.zig). `readStateFd` zeroes the buffer with `secureZero` before free. The state fd is closed immediately (`sys.close` src/main.zig) so it does not sit in `/proc/<pid>/fd`. Core dumps are disabled (`disableCoreDumps`) and environment is scrubbed (`scrubPskEnv`) in `cmdHandover` |
| **D** denial of service via signal or corrupt state | Unsolicited `SIGUSR2` before `FUSE_INIT` is ignored (`st.init_len == 0` src/fuse_fs.zig). A missing or unopenable `update.req` ignores the signal without leaving the FUSE loop (`onUsr2`). State decode enforces bounds (`max_state_bytes` 1 MiB cap, `init_max` 4096 cap, fuzz-covered `decode` in src/handover.zig) and validates watermark ordering via `cull.ordered` (src/handover.zig) to reject corrupted or disordered eviction thresholds. After the FUSE loop stops, any `execHandover` failure (including malformed request JSON or failed exec) exits the daemon, leaving the mount unserved |
| **E** elevation of privilege | Handover does not elevate OS privileges (the replacement binary executes with the same UID/GID as the daemon). However, a process with the daemon's UID can plant an arbitrary executable path, taking over the live FUSE mount session fd, peer HTTP listen sockets, and acquiring the cluster PSK from the sealed memfd without ptrace |

**Authentication and gating.** Handover requests require write access to the cache root and the ability to send `SIGUSR2` to the daemon PID. The cache root's permissions are operator-controlled: `ensureDirReal` (src/main.zig) creates it with mode 0755, subject to umask; `Store.ensureLayout` (src/store.zig) tightens only `data/`, `meta/`, and `pin/` to 0700. The request is read via `O_NOFOLLOW | O_NONBLOCK` and parsed by `decodeReq` (src/handover.zig). A random 16-byte hex token (`randomToken`) lets `cmdUpdate` match `update.ack` to its request. Unlinking `update.req` upon consumption or timeout removes accidental leftovers, but there is no daemon-side nonce history or authentication of a request planted by a process with the same uid.

**Integrity and confidentiality.** Live daemon knobs and the cluster PSK are serialized into a sealed memfd (`handover.encode`, `sys.memfdSealed`). File descriptor passing keeps the PSK off argv and /proc command lines. The receiving process (`cmdHandover` src/main.zig) verifies the mountpoint matches argv, disables core dumps, scrubs `MODELFS_PSK_VALUE` from the environment, wipes the raw PSK slice in memory with `secureZero` after decode, and closes the state descriptor immediately.

**Denial-of-service and failure handling.** Before initialization, `onUsr2` (src/fuse_fs.zig) refuses the signal and writes a diagnostic; an unopenable request is ignored silently. Once an openable request stops the FUSE loop, `execHandover` failures, including malformed request JSON or a failed `execve`, exit the daemon and leave the mount unserved (`serve` in src/fuse_fs.zig). Invalid state is rejected by the replacement image (`cmdHandover` in src/main.zig); the old image is already gone. These failures require a manual restart of the mount.

### B5: build to runtime

| Threat | State |
|---|---|
| **S** spoofing dependencies | Mitigated: `build.zig.zon` declares zero external package dependencies (`dependencies = .{}`). The only compiled-in external C library is libfuse3. Static release builds vendor static libfuse3 source in `.deps/libfuse3-3.16.2/` and arm64 packages in `.deps/fuse3-arm64/`, both verified against hardcoded `SHA256SUMS` at build time. Host dynamic builds link system libfuse3 (operator provenance concern) |
| **T** tampering with compiler output | Mitigated by build hardening: PIE (`exe.pie`), PIC (`exe_mod.pic`), stack canaries (`stack_protector`), stack probes on x86/x86_64 (`stack_check`), full RELRO (`link_z_relro`), BIND_NOW, a non-executable stack (`GNU_STACK RW`), and the absence of DT_RPATH/DT_RUNPATH are pinned and checked on the linked ELF (`checkHardenedElf` in build.zig) |
| **R** repudiation of build artifacts | Proven reproducible: `scripts/repro_check.sh` proves static release builds byte-identical across differently named trees. Build-id is frozen at `none` to prevent UUID divergence |
| **I** disclosure of build host paths | Mitigated: non-Debug builds strip DWARF (`strip = true`), suppressing host build paths (`DW_AT_comp_dir`). `each_lib_rpath = false` prevents host search paths from leaking into DT_RPATH |
| **D** build-time resource exhaustion | Bounded: minimal build graph and zero remote dependencies |
| **E** binary exploitation (ROP, memory safety) | Mitigated: ASLR/PIE, stack canaries, non-executable stack, BIND_NOW preventing GOT overwrites, and no runtime search path hijacking (no RPATH/RUNPATH) |

**Provenance and dependency isolation.** Shipped binaries eliminate supply chain risk by declaring no external Zig package dependencies in `build.zig.zon`. The single required C dependency (libfuse3) is vendored and cryptographically verified against pinned SHA-256 sums prior to compilation (`build.zig`, `scripts/extract_fuse3_arm64.sh`).

**Binary hardening and runtime exploit mitigations.** The executable is compiled with position-independent execution (`pie`), stack protector canaries, and stack probing (on supported x86/x86_64 architectures). The linker enforces full RELRO, immediate binding (`BIND_NOW`), non-executable stack permissions, and strips search paths (RPATH/RUNPATH). All properties are asserted post-link by `checkHardenedElf`.

### B6: CLI to external model hub (Hugging Face API & CDN)

| Threat | State |
|---|---|
| **S** spoofing the model hub or CDN | Mitigated by HTTPS and TLS certificate verification using the platform system trust store |
| **T** tampering with origin tree via malicious listing or redirect | Mitigated: listing paths must pass `relOk` and `relIsCluster` both individually and joined under `--dest`, blocking path traversal and `.cluster` overwrites; downloads stream to `.part` files opened `O_NOFOLLOW` and atomically rename on complete (`parseTree`/`fetchOne` src/hf.zig) |
| **R** repudiation of downloaded files | The CLI logs pulled and skipped file counts to stdout; no cryptographic commit signature verification is performed beyond TLS transport integrity |
| **I** disclosure of Hugging Face access token | Mitigated: token is sent as a privileged header to `huggingface.co` and stripped on cross-host CDN redirects; core dumps disabled during pull when token is present; token buffer wiped with `secureZero` on exit (src/hf.zig, src/main.zig) |
| **D** denial of service via huge listing or stall | Mitigated: JSON listing is capped at 8 MiB (`max_listing_bytes`) via fixed-size writer; aborted/stalled downloads leave `.part` files without corrupting existing destination files; streaming uses 1 MiB chunk buffers |
| **E** elevation of privilege on origin filesystem | Mitigated: paths cannot escape `--dest` or write into `.cluster` (`relOk`, `relIsCluster`); created files take standard user umask and cannot set setuid/setgid bits |

**Input containment and validation.** Model IDs and revisions are validated against strict character sets and bounded lengths before URL construction (`repoOk`, `revisionOk` src/hf.zig). Repository tree listings are parsed by `parseTree` (src/hf.zig), which refuses any entry that violates `relOk` or names `.cluster`, ensuring upstream JSON cannot escape destination directories or plant discovery leases.

**Transport and credential protection.** Network communication uses platform TLS. Bearer tokens travel exclusively to `huggingface.co` and are stripped on cross-host redirects to download CDNs. Core dumps are disabled while tokens reside in memory (`disableCoreDumps` src/main.zig), and token allocations are zeroed with `secureZero` upon deinitialization.

**Staged downloads.** Downloads stream into temporary `.part` files created with `O_NOFOLLOW`. Files are atomically renamed into place only after the payload completes, preventing interrupted downloads from leaving partial models that could be mistaken for valid weights.

---

## Mitigations in place

Controls that exist in code, grouped by what they defend.

### Authentication and the secret

| Control | Location | Covers |
|---|---|---|
| Bearer PSK required on every request including `/ping` and non-GET: 401 without a valid token, 405 with `Allow: GET` only after auth | `handleConn` src/peer.zig | Raises the B2 entry bar to PSK possession. A 401 still shows a listener is present, but not that GET is the only verb |
| Timing-safe token comparison (SHA-256 then constant-time eql) | src/proto.zig | Timing oracle on the auth check |
| Empty-PSK refusal at startup, plus refusal of secrets containing CR/LF that would corrupt the request head | `loadPsk` and the header-safety gate, src/main.zig | Accidental unauthenticated service; self-inflicted auth drift where every fetch 401s |
| PSK file mode gate: world-readable refuses to start, group bits warn | `loadPsk` src/main.zig | Local PSK theft by any uid. Group-readable is detection only |
| Mount zeros `RLIMIT_CORE`, X-fills `MODELFS_PSK_VALUE` in the environment in place so the `auto_unmount` helper cannot inherit it, and `secureZero`s the in-memory copy on teardown | `disableCoreDumps` / `scrubPskEnv` src/main.zig, called from `cmdMount` | Closes [R8](#r8-crash-time-psk-spill-mitigated). A `setrlimit` failure refuses to start. Residual: the secret still lives in process memory for the mount's lifetime |
| Duplicate-bind refusal: listeners use SO_REUSEADDR only, never SO_REUSEPORT | src/peer.zig, with a regression test | B2/S: a co-tenant daemon (usually with a different PSK) silently splitting connections with the real one |
| Handover PSK transport via sealed memfd, zeroed on decode, state fd closed immediately, core dumps disabled and env scrubbed in replacement image | `sys.memfdSealed` src/sys.zig, `readStateFd` src/handover.zig, `cmdHandover` src/main.zig | B4/I: secret leakage across live process-image replacement; keeps the PSK off argv, disk, or /proc/<pid>/fd |
| `HF_TOKEN` loaded exclusively from environment or token file (no CLI flag), capped at 4096 bytes, core dumps disabled during pull when token is present, in-memory buffer wiped with `secureZero` on exit, and stripped by HTTP client on cross-host CDN redirects | `loadToken` src/hf.zig, `cmdPull` src/main.zig, `std.http.Client` | B6/I: Hugging Face bearer token leakage via argv (`/proc/<pid>/cmdline`), memory dumps, post-exit memory retention, or cross-host redirect to third-party CDNs |

### Attribution

| Control | Location | Covers |
|---|---|---|
| Source-attributed rejection logging: the accepted peer address is captured per connection and named on 401 and 405 lines, both capped to one line per `auth_warn_min_gap_ms` (1 s), with `http_unauthorized` and `http_405` keeping exact counts. Malformed-head noise counts under `http_malformed` instead of logging per event, including a completed read whose request line has no CRLF or no method | `handleConn` src/peer.zig | Closes [R9](#r9-rejected-request-anonymity-mitigated). Residual: a well-formed flood is one journal line per second, so a multi-source campaign names at most one source per window |
| Failure-only per-event logs plus tick summary counters (`http_ok`, `http_unauthorized`, `http_5xx`, `http_malformed`, `http_dropped`, `http_405`, `probe_err`, `lease_err`, `meta_err`, `bytes_to_peer`, `http_us`, `md_us`) | src/peer.zig, `logStatsTick` src/fuse_fs.zig | Detecting auth failures, wrong-method probes, malformed-request storms, saturation at the handler cap, silent cluster degradation, idle origin outages, metadata EIO storms, and a serving node that would otherwise look idle |
| Status.json retirement on two axes: an exited pid reads as not running, and a live pid whose artifact stopped ticking past 120 s reads as not serving. The `mono_s` monotonic stamp is preferred, with wall-clock `now_s` as the fallback on older artifacts, and a previous-boot `mono_s` ahead of now is stale, so pid reuse after reboot cannot serve a leftover | `statusJson` src/fuse_fs.zig; `pidAlive` src/sys.zig; `max_status_age_secs`, `statusAgeSecs`, and the age gate in `liveDaemon` src/main.zig | Monitoring deception by crash leftovers and by hung-but-alive daemons |

### Path containment

| Control | Location | Covers |
|---|---|---|
| `relOk` applied at every external path boundary: FUSE handlers and readdir components, peer HTTP, and CLI pin/unpin/verify/dupes | src/store.zig; call sites in src/peer.zig, src/fuse_fs.zig, src/main.zig | B1/B2/E traversal out of the origin and cache roots, plus log and terminal injection and display-identity spoofing via control bytes (C0, DEL, UTF-8 C1, Default_Ignorable including U+2028/U+2029, bidi and zero-width format controls, variation selectors, BOM, soft hyphen, Mongolian FVS4, shorthand format controls, tags, VS17-256, via `containsControl` src/proto.zig). FUSE `readdir` omits the same names so a planted `a\nERROR.bin` cannot split `ls` |
| Centralized `.cluster` hide on FUSE, peer HTTP, and CLI pin/unpin/verify/dupes | `relIsCluster` src/discover.zig; `resolveRel` src/fuse_fs.zig; `handleConn` src/peer.zig; `cmdPin`/`cmdVerify`/`cmdDupes` src/main.zig | Lease-file exposure and mutation through the mount, piece-protocol hydration of lease JSON, and pin/verify/dupes of control-plane names |
| Untrusted-name hygiene: printable gates before echoing lease names and ids to logs or terminal output | src/discover.zig, src/main.zig | Log forgery and terminal escape injection from crafted lease names |

### Local filesystem hardening

| Control | Location | Covers |
|---|---|---|
| Client-supplied FUSE create/mkdir/chmod modes masked to permission bits, stripping setuid, setgid, and sticky before any origin create or attribute change | `clientCreateMode` src/fuse_fs.zig, applied at `mf_create`, `mf_mkdir`, `mf_chmod` | B1/E: planting daemon-owned special-bit executables through the mount, or granting special bits to existing daemon-owned files post-create |
| O_NOFOLLOW on origin and cache data-plane opens, status.json, lease reads, and staged writes | src/sys.zig, src/discover.zig, src/store.zig, src/fuse_fs.zig, src/main.zig | Local attackers redirecting privileged reads or writes: a planted `status.json` or `.cluster` lease name fails closed instead of serving its target |
| O_NOFOLLOW on FUSE chmod, readdir, and statfs, with no lstat-then-follow window (`statOrigin` is still lstat; `mf_open` rejects `S_IFLNK`) | `sys.chmod` / `sys.opendirNoFollow` / `sys.statfsNoFollow`; `mf_chmod`/`mf_readdir` src/fuse_fs.zig; `originStatfs` src/store.zig | B1/E: a planted origin symlink steering the daemon's chmod (setuid included), listing a client-local directory through the mount, or leaking the host root's size and free space via `df` |
| Cache data 0600, cache dirs 0700, sidecars and pins 0600, `status.json` 0600, with leftover looser modes tightened on the next open or publish | `cache_data_mode` / `cache_dir_mode` / `openCache` / `ensureLayout` / `tightenCacheDir` / `setPin` src/store.zig; `writeFileOwnerOnly` src/sys.zig | B1/I: a local uid blocked by origin modes and FUSE `default_permissions` cannot read cached weights, list which nested paths are cached or pinned, read piece bitfields or pin markers, or read operational state |
| Disk-cull walk samples cache entries with lstat and skips non-regular files, with a depth cap on nesting; leading-dot `relOk` names are sampled | `walkData` src/store.zig | B1/E: planted symlinks in a writable cache tree steering fallocate punches outside `data/`. B1/D: hidden cache files filling the filesystem past the watermarks after a restart |
| Cull punch refuses to hole a piece with bytes in flight: the `xfer` counter is held across peer `/data` hydration and send and across FUSE warm cache reads, and entries are punchable only when recency-idle and transfer-free | `punchPiece` / `xfer` src/store.zig (`readCache` holds `xfer` for the warm-read path) | B1/D and the R2/R7 residual: closes the punch-versus-in-flight-read race that would serve hole zeros behind set bits |
| Cache-identity drop on origin unlink and rename, including FUSE retries that see ENOENT | `Store.unlinkOrigin` / `Store.renameOrigin` src/store.zig | B1/T and the R7 crash window: a lost FUSE reply after origin unlink or rename used to leave `meta/*.pieces` behind, so a same-size recreate served the deleted file's bytes |
| Handover request opened O_NOFOLLOW \| O_NONBLOCK and written 0600 durable; ack written 0600; unlinked on consumption or timeout | `writeFileOwnerOnlyDurable` / `writeFileOwnerOnly` src/sys.zig, `onUsr2` / `execHandover` src/fuse_fs.zig, `cmdUpdate` / `cmdHandover` src/main.zig | B4/T, B4/E: symlink redirection or tampering of handover control files |

### Piece integrity

Per-piece blake3, covering B2/T: peer-injected and at-rest corruption is no longer served or
propagated, and a detected at-rest mismatch self-heals. This closes
[R2](#r2-peer-served-piece-integrity-mitigated), subject to its residuals.

* Digests are recorded at admit for origin fills, verified peer fills, and write-throughs
  (`piece.digest` src/piece.zig, `Store.hashes` src/store.zig).
* Peer fills are verified before admit and refused outright without a trusted reference
  (`expectedHash` src/store.zig, `hydratePiece` src/fuse_fs.zig).
* Cached bytes are verified before every `/data` serve, with self-heal on mismatch
  (`verifyRange` src/peer.zig, `Store.healPiece` src/store.zig).
* Manifests are published on the origin at close and loaded lazily as the trust reference
  (`Store.publishManifest`).
* `modelfs verify <rel>` audits at rest (`cmdVerify` src/main.zig).
* `fill_err_verify` and `serve_verify_fail` ride the tick line and status.json.

### Input parsing and resource bounds

**Bounded parsing everywhere**, against memory exhaustion and slow-loris holds on B2:

* Overflow-safe size and range parsers, suffix ranges rejected, bounds-checked URL decode
  (src/proto.zig).
* Fixed-size head buffers: server request heads are sized for anything `sendRequest` can emit,
  which is a triple-encoded PATH_MAX rel plus a full-size bearer token plus framing, 16.5 KiB;
  client response heads are 8 KiB.
* A 10 s head deadline and body deadlines scaled to length (`readHeadFullDeadline`,
  `haveFromHeadDeadline`, and the shared body reader, src/peer.zig).
* A 16 MiB `/have` body cap and a 512 MiB generic allocated-body cap. A truthful bitmap is
  KiB-scale, and `havePut` would otherwise pin copies of a 512 MiB answer in the 32-entry probe
  cache, so `serveHave` refuses the same bound before `get()`: that is hostile-peer `/have`
  amplification closed on both ends.
* 3-digit HTTP status codes (`httpStatusIs` src/proto.zig), so a prefix-matched `2000` is not
  200 and `4040` is not a healthy miss.
* 206 `Content-Length` equal to the Content-Range window (`checkRangeReply`), so a short body
  under a matching window is refused.
* An advertised `X-Piece-Size: 0` refused.

**Fuzz harnesses over every untrusted-input parser**, for regression resistance on the B1/B2/B3/B4
parsers and against drift between the ingestion and dial gates: request heads and peer replies
(the auth/path/range pipeline, Content-Range binding on 206 bodies, `HaveBits.hasPiece` against
packed bits and grid mismatch), lease JSON, the URL
codec pair across the trust boundary, the FUSE path gate, `relOk`, `parseV4` diffed against libc
`inet_pton` across the whole input space, the sidecar piece-size
header, the piece-hash manifest codec, handover state and req/ack decoding, CLI flag value
parsing, and status.json liveness parsing (src/peer.zig, src/proto.zig, src/discover.zig,
src/fuse_fs.zig, src/store.zig, src/piece.zig, src/handover.zig, src/main.zig).
Seed corpora share one framing helper (src/fuzzcorpus.zig) so `Smith.slice` feeds codec bytes
rather than a length prefix taken from the payload.

**Lease validation**, against discovery self-partitioning and malformed documents on B3: expired
filtered, corrupt skipped, self skipped, id charset enforced at publish with a hostname
fallback, and incoming JSON checked (`Catalog.refresh` skips an `id` that fails `validId`, so a
planted `"id":"spark1\u200b"` is not a peer). Advertised addresses must be dotted quads:
`--advertise` refuses names at parse, and `--seed` hostnames resolve exactly once at mount or
fail loudly (`validId` and lease filtering src/discover.zig; `buildSeeds` src/main.zig).

| Control | Location | Covers |
|---|---|---|
| Concurrency cap: 16 handlers with atomic claim-then-check; probe concurrency capped to the same number | `Server.max_inflight` src/peer.zig; probe cap in `fillFromPeers` | Unbounded thread and connection growth |
| Socket timeouts: 30 s steady-state, 15 s dial, 10 s head, length-scaled body budget | src/peer.zig | Stalled-peer slot retention |
| Range clamping to file size; one reusable piece-sized hydration buffer | `serveData` and `hydrateRange` src/peer.zig | Server-side allocation driven by attacker-chosen ranges |
| Regular-file gate before any cache work on `/have` and `/data`: directories and other non-regular origin objects answer 404 instead of reaching hydration's pread on a directory fd, which surfaced as a misattributed 502 | `originRegular` src/peer.zig | B2 validation: non-regular paths driving cache writes and wrong-status replies |

### CLI gates

Silent no-op runs are the failure to avoid: an accepted-and-ignored flag leaves an operator
believing an option took effect. `parseArgs` and the command entry points (src/main.zig) refuse
rather than ignore.

* **Scope.** Mount-only options are refused on status/peers/pin/unpin/verify/dupes/pull/update
  (`rejectOutsideMount`); `--all` is refused outside dupes and `--revision`/`--dest` outside
  pull (`rejectOutsideCommand`).
* **Shape.** Positional arity is enforced at parse (exit 2), percentages clamp to 0..100
  (`parsePercent`), and watermark ordering is validated cross-field (`cull.ordered`).
* **Paths.** `--origin` must be an existing directory for mount, peers, verify, and dupes
  (`resolveOriginDir`): a regular file realpaths fine but can never hold leases or serve joined
  reads, and `dupes --all` would otherwise exit 0 as an empty scan. Cache and mountpoint paths
  that exist as a regular file are refused as "not a directory" (`ensureDirReal`). An origin
  overlapping the cache is refused at mount (`pathsOverlap`), since piece files would land on
  the shared store.
* **Addresses.** Port 0 is refused on `--listen`/`--advertise`/`--seed` (an ephemeral bind whose
  lease would still advertise 0), and `--advertise`/`--seed` refuse `0.0.0.0` and
  `255.255.255.255` (`isDialableHost`).
* **Secrets and environment.** `MODELFS_PSK_VALUE` is exclusive of `--psk`/`MODELFS_PSK` on
  mount (`ConflictingPsk`); the inline PSK is capped at `proto.max_psk_bytes` like the file
  form; empty origin/cache/psk flags and an empty mount directory are refused at parse
  (`refuseEmpty`); every `MODELFS_*` value is whitespace-trimmed with empty counting as unset,
  except a whitespace-only `MODELFS_PSK_VALUE` which is refused as empty; and any `MODELFS_*`
  name outside the documented set is refused as a typo (`checkKnownEnv`), so harness knobs
  cannot squat on the daemon's env namespace.

### Build hardening

| Control | Location | Covers |
|---|---|---|
| PIE, PIC, stack canaries, stack probes, full RELRO, BIND_NOW, a non-executable stack, and no DT_RPATH/DT_RUNPATH on the shipped image; DWARF stripped from every non-Debug build; build-id frozen at none | `exe.pie`, `exe_mod.pic`, `stack_protector`, `stack_check`, `link_z_relro`, `each_lib_rpath`, `build_id`, `strip`, and `checkHardenedElf` in build.zig | B5: a fixed-address networked daemon, an uninstrumented ReleaseFast stack, lazy binding, an executable stack, a build-host `-L` baked into the spark image, a random build-id, and a `DW_AT_comp_dir` build-path leak in release binaries |

### Single points of failure, named honestly

* **The PSK is the only control on B2.** It carries authentication, membership, and, through the
  threat of forgery, the only barrier on read access to every weight in the cluster. Its loss is
  unrecoverable without manual redeployment to every node.
* **`relOk` plus `relIsCluster` are the path-safety controls** for every externally supplied
  path (FUSE `resolveRel`, peer `handleConn`, CLI `cmdPin`/`cmdVerify`/`cmdDupes`). Both are
  well tested and centrally defined, which is the right shape, but any new entry point that
  forgets them loses path containment.

---

## Gaps

Ranked by exploitability times impact. Fixes belong to sec-review passes; they are recorded here
with locations.

### R1: plaintext transport with inline credentials

**Unmitigated.** Every request carries `Authorization: Bearer <psk>` in cleartext
(src/peer.zig), and every piece moves unencrypted (`streamRange` src/peer.zig). Any host on path
(same L2, any router between racks, anyone doing ARP spoofing) reads weights and captures the
PSK. Auth is token-only over plain TCP.

### R2: peer-served piece integrity (mitigated)

blake3 on every chunk, never serve unverified bytes, now ships in
per-piece form.

Every admitted piece (origin fill, verified peer fill, write-through) records a blake3 digest
(`finishPiece`/`completeFill` src/store.zig). A node that wrote or fully read a file publishes
those digests as a piece-hash manifest on the origin under `.cluster/manifests/`
(`Store.publishManifest`), and readers load it as the trust reference for peer fills
(`expectedHash`).

A peer fill with no trusted digest is not attempted; the piece hydrates from the origin instead.
Fetched bytes that fail verification are discarded unmarked and refilled from the origin
(`hydratePiece` src/fuse_fs.zig, `fill_err_verify`). Cached bytes are re-verified before every
`/data` serve (`verifyRange` src/peer.zig, `serve_verify_fail`), and a
mismatch both refuses the serve **and** heals the piece (`Store.healPiece` clears the mark so
the next fill re-hydrates from the origin instead of failing forever). `modelfs verify <rel>`
rehashes a whole file's cached pieces against the manifest and clears mismatched marks the same
way (`cmdVerify` src/main.zig).

At-rest corruption (hole zeros, bit rot) is therefore detected and self-healed at serve time,
and auditable on demand, instead of reading as valid data.

Residuals:

* Local FUSE reads are not re-verified per read, only peer serves are, so a piece that is
  corrupt but never served to a peer waits for `modelfs verify` or a peer request.
* A file with no manifest (written outside modelfs, or a legacy pre-upgrade cache) has no trust
  reference, so its fills stay origin-only and its already-cached pieces serve unverified until
  a manifest appears. The first node that fully origin-reads it publishes one on close, and a
  transient manifest-load failure (an NFS negative-cache absence) is retried after
  `manifest_retry_ms` rather than remembered for the entry's lifetime, so a just-published
  manifest is picked up on a later miss (`expectedHash` src/store.zig).
* Origin tampering (B3) can forge a manifest, which is the same trust the file bytes themselves
  already place in the origin.
* Local tampering of sidecars is still [R7](#r7-cache-artifacts-trusted-without-verification).

### R3: static shared PSK, no rotation or revocation

**Operational only.** One credential authenticates every node forever (`loadPsk` src/main.zig):
no expiry, no identity. Node compromise equals cluster compromise, and the departure of a node
requires cluster-wide key regeneration by hand.

### R4: trivial peer-service saturation

**Partially bounded.** The 16-slot cap (src/peer.zig) is global, not per-source, and slots are
occupied before and during auth. Sixteen cycling connections, each held to the 10 s head
deadline plus up to another 10 s of bounded body drain when the head declares a
Content-Length (`drainDeclaredBody`: 64 KiB / 10 s cap, before auth), deny all peer fills
cluster-wide while the node itself stays up, degrading every other node's miss path to origin
speed.

### R5: lease poisoning enables PSK capture

**Unmitigated.** With origin write access, and the NFS export's own ACLs are the only gate, an
attacker publishes `<origin>/.cluster/<id>.json` pointing at their IP with a high `mbps`.
Victims dial it and transmit the PSK in a Bearer header over plaintext (src/discover.zig,
src/peer.zig). Origin write access therefore converts into full cluster credential compromise,
not just redirect denial of service.

The same handoff is available at mount through `--seed HOST` if DNS or `/etc/hosts` on that node
maps HOST to the attacker (`buildSeeds` src/main.zig): the seed is resolved once and then dialed
like any other path.

### R6: authenticated amplification and cache littering

**Bounded only by cull watermarks.** Any PSK holder can request arbitrary ranges of arbitrary
origin files from any node. Each miss forces an origin pread plus an NVMe write on the victim
(`hydrateRange` src/peer.zig), letting one host fill every node's cache disk with chosen data
and multiply NFS load.

Per endpoint: `/data` forces origin stats plus full-piece hydration per request. `/have` is an
origin stat plus a cache-entry load, unless the bitmap would exceed 16 MiB, in which case it is
a 500 with no entry opened.

Culling eventually evicts the litter; nothing prevents the cycle.

### R7: cache artifacts trusted without verification

**Not prevented.** Bitfield metadata loaded from `meta/*.pieces` determines which holes read as
zeros and which hydrate (store walk and load paths, sidecar load, src/store.zig). A local writer,
or malware running as the daemon uid, can flip bits to feed engines zero-filled weight regions,
or plant pin markers to make junk uncullable. The precondition is local, but the daemon performs
no integrity check of its own state.

Closed crash windows, which are not part of the remaining gap: size-change and same-size rewrite
(mtime/ino) wipes now persist to the sidecar (reconcile and the shrink branch save the reset
bitfield plus an optional origin-identity trailer), and unlink and rename drop cache identity
even when the origin name is already gone (`Store.unlinkOrigin`/`Store.renameOrigin`), so a FUSE
retry after a lost reply cannot resurrect a deleted file's bits over a same-size recreate.

### R8: crash-time PSK spill (mitigated)

Mount zeros `RLIMIT_CORE` after loading the secret (`disableCoreDumps` src/main.zig), X-fills
`MODELFS_PSK_VALUE` in the environment in place (`scrubPskEnv`: the entry stays, the bytes go),
and `secureZero`s the in-memory copy on teardown. A `setrlimit` failure refuses to start (`cmdMount`).

Residual: the secret still lives in process memory for the mount's lifetime.

### R9: rejected-request anonymity (mitigated)

401 and 405 rejections log the source address, rate-limited to one journal line per second
(`claimAuthWarn`/`claimMethodWarn` src/peer.zig), and scanner noise counts under
`http_malformed`/`http_405`.

Residuals: successful requests still carry no per-source audit trail, and a multi-source flood
names at most one source per window.

### Closed: `status.json` world-readable at the cache root

The file is created 0600 (`writeFileOwnerOnly` src/sys.zig) and leftover 0644 files are tightened
on the next publish. Residual: the daemon's own uid can already ptrace the live secret (see
Secrets flow); `modelfs status` as another uid now fails with EACCES rather than printing the
document.

---

## Abuse cases

What a hostile actor can do, with the enabling path named. Cases 1 to 5 need the PSK: a
legitimate but curious node, a compromised spark, or anyone who captured it off the wire per R1.
Case 6 needs write access to the cache directory; Case 7 needs daemon uid access (cache directory write plus signal permission).

1. **Bulk weight exfiltration.** Enumerate paths (any `relOk`-clean string; `replyOriginStat`
   src/peer.zig distinguishes 404 absent from 400 over-long from 502 origin-broken), then
   `GET /data?path=<rel>` with successive `Range` headers to pull entire files from any node, at
   line rate via sendfile (`streamRange` src/peer.zig). No quota, rate limit, or audit trail
   distinguishes this from normal fills.
2. **Silent model poisoning (closed).** A hostile peer answering a `/data` fetch with crafted
   bytes gets them discarded: the victim verifies against the trusted digest before admit
   (`hydratePiece`, `fill_err_verify`) and refills from the origin. Pre-upgrade poison already
   sitting in a cache serves until that file's manifest appears, because a legacy piece has no
   reference to prove it wrong; `modelfs verify` then finds and clears it. At-rest corruption
   found at serve time is refused and self-healed.
3. **Route hijack for interception.** Publish a lease advertising the attacker's IP with a high
   `mbps` (prior conversion src/discover.zig); victims preferentially connect and present the
   PSK, and the attacker now sees and can selectively alter fetch traffic. Equivalently, poison
   DNS or `/etc/hosts` for a `--seed HOST` at the victim's mount (`buildSeeds` src/main.zig).
4. **Cluster slowdown.** Hold all 16 handler slots with idle connections (R4), or issue
   wide-range `/data` requests for uncached origin files to convert peer traffic into NFS load
   on the origin (R6). Either degrades every engine read behind the mount without violating a
   single auth check.
5. **Cache-disk exhaustion on a victim.** Continuously fetch distinct large ranges so the
   victim's cache filesystem fills with attacker-chosen pieces. Culling (`cullLoop`
   src/fuse_fs.zig) fights back, but pinned files and active transfers are exempt (`cullOne`
   skip conditions and `punchPiece`'s xfer guard, src/store.zig), so steady pressure raises IO
   load and evicts useful pieces.
6. **Pin junk against cull, locally.** `modelfs pin <rel>` writes a marker under `cache/pin/`
   with a `relOk` plus `relIsCluster` check, no PSK and no running daemon (`cmdPin`
   src/main.zig). Any local uid that can write the cache dir can make attacker-chosen model
   paths uncullable, compounding case 5. The same is true of planting files directly in `pin/`.
   `.cluster` names are refused.
7. **Local process image replacement and PSK extraction via Handover.** A compromised local
   process running as the daemon's uid (or with write access to the cache root and signal
   permission to the daemon PID) writes `<cache>/update.req` naming an arbitrary executable path,
   then signals `SIGUSR2` (`cmdUpdate` src/main.zig, `onUsr2` src/fuse_fs.zig). The running daemon
   encodes its state, unsets `CLOEXEC` on the sealed memfd and descriptors, and executes
   `execve(replacement_bin, ["modelfs", "_handover", "--state-fd", N], environ)` (`execHandover`
   src/fuse_fs.zig). The replacement binary extracts the cluster PSK from the memfd (`readStateFd`
   src/handover.zig) and inherits the FUSE session and peer HTTP listen sockets. This enables
   credential extraction and execution persistence even on systems with `ptrace` restricted
   (`kernel.yama.ptrace_scope`).

**Closed:** reading `status.json` as another uid. The artifact is 0600. Cross-uid weight theft
stays closed by 0600 files and 0700 dirs; leftover 0755 `data/`/`meta/`/`pin/`, which listed
cached and pinned names, are tightened on `ensureLayout`.

**Trust placed in client-side enforcement: none found.** The server validates path, method,
range, and auth independently. Clients trust peer-supplied bitmaps only for routing
(`Catalog.havePut` src/discover.zig): hits and healthy 404 misses are cached for 2 s, a stale hit
routes to a peer that no longer has the piece and falls through to the next path or the origin,
a stale miss delays noticing that peer for one TTL, and connection failures are never cached.
Wrong data from a peer is caught by digest verification at the fetching node (R2), not by
client-enforcement holes. An `X-Piece-Size` mismatch discards the answer.

---

## Response readiness

**Audit trail.** Per-node journald logs carry failure-only events: 401 and 405 with source
address at most once per second, failed fetches with `ip:port`, origin errors (per-request for
peer HTTP; edge-triggered at `Store.noteOriginIo` for FUSE origin I/O and discovery-tick lease
publish and refresh), pin and unpin state changes, handover execution events (`updated pid {d}` on success;
handover exec/restore errors and pre-init signals logged; unopenable requests ignored silently), and membership changes (`cluster peers N -> M`).
The tick counters add serving volume (`http_ok`, `bytes_to_peer`), wrong-method probes
(`http_405`), handler time (`http_us`), FUSE metadata time (`md_us`), `lease_err`/`meta_err`, and
saturation (`http_dropped`). status.json exposes lifetime aggregates, `origin_down`, a wall-clock
`now_s`, and a same-machine monotonic `mono_s` that the wedge gate prefers (`logStatsTick` and
the status write, src/fuse_fs.zig). Still missing: a persistent, centralized record, and
per-client attribution of successful requests.

**Vulnerability handling.** [SECURITY.md](../SECURITY.md) names the supported version (`v0.14.1`
is current; the `0.12.x` line receives security fixes) and the route from report to shipped fix.
GitHub private vulnerability reporting is not enabled on the repository, so that route has no
intake until a repository admin turns the feature on, and there is no other disclosed contact.

**Compromise recovery that exists today.** PSK regeneration guidance is in
[recovery.md](recovery.md), which also documents wiping caches before remounting after a
rollback. Post-upgrade poison can instead be found per file with `modelfs verify <rel>` once its
manifest exists.

This document intentionally does not propose designs for the gaps; sec-review passes aimed by
the ranking above own those fixes.
