# Threat model

| Field | Value |
|---|---|
| Status | Living document; describes `src/` as of the date below |
| Last reviewed | 2026-08-27 |
| Covers | modelfs daemon (`mount`) and CLI, peer HTTP protocol, lease discovery, FUSE surface |
| Security owner | Unassigned |
| Review cadence | Unassigned; re-verify against `src/` after any protocol, auth, or listener change |

ModelFS is a single-binary FUSE cache for LLM weights with a plaintext peer-to-peer HTTP tier, bound to all interfaces, guarded by one static pre-shared key per cluster. This model names what can be attacked from outside the node, what it costs, and which controls exist. Findings point at code; fixes belong to sec-review passes, not this document.

---

## Risk-ranked summary

| # | Risk | Boundary | State |
|---|---|---|---|
| R1 | Peer transport is plaintext HTTP: the PSK rides every request and weights ride in the clear; an on-path observer reads both, an active one rewrites bytes | network to peer server | No mitigation (see [Gaps](#gaps-unmitigated-threats)) |
| R2 | No integrity check on peer-served pieces: fetched bytes are cached, marked filled, and re-served, so one hostile peer poisons every cache in the fleet silently | peer to peer | No mitigation |
| R3 | One static PSK shared by every node, no per-node identity, no revocation or rotation path: compromising any node yields the whole cluster | secrets to code | Operational only (file mode warnings) |
| R4 | Peer service denial: 16 handler slots total; unauthenticated connections hold slots up to the head deadline, so 16 slow sockets stall all peer fills | network to peer server | Partially bounded (deadlines, caps) |
| R5 | Lease poisoning (or a `--seed HOST` that resolves to the attacker): victim fetches are redirected to attacker-chosen IPs, and the victim then hands the PSK to that IP in a Bearer header over plaintext | node to origin / DNS at mount | No mitigation |
| R6 | Authenticated peer amplification: `/have` and `/data` force origin stats plus full-piece hydration (NFS read + NVMe write) per request, filling the serving node's cache disk | peer to peer | Bounded only by local cull watermarks |
| R7 | Local tamper surface: cache bitfields are trusted at load, so a tampered `meta/*.pieces` serves hole zeros as valid data | local user to cache | Not prevented |
| R8 | Crash-time PSK spill: process memory holding the secret has no `RLIMIT_CORE` cap and no dump redirection, so a daemon crash writes a core wherever `kernel.core_pattern` points | secrets to code | Not prevented |
| R9 | Rejected peer requests leave no attributable trace: wrong-PSK probes were once invisible beyond a bare counter | network to peer server | Mitigated (source-address logging on 401s; scanner noise stays count-only by design) |

---

## Assets

| Asset | Where it lives | Impact if lost |
|---|---|---|
| LLM weights | origin tree (authoritative copy), per-node piece caches (`data/`) | Exfiltration of valuable/licensed models; silent corruption poisons training/serving runs |
| Cluster PSK | `/etc/modelfs.psk` or `MODELFS_PSK_VALUE`, process memory (and any core dump a crash leaves behind, gap R8), every request's `Authorization` header (src/main.zig, src/peer.zig) | Full impersonation of any node: read every weight, serve poisoned pieces |
| Availability of the read path | `/models` mount, peer port, NFS origin | Reads block until a piece fills; stalled peers degrade the whole cluster to origin-tier throughput |
| Cache integrity | `data/` sparse files + `meta/*.pieces` bitfields | Punched holes read as zeros; without verification, zeros and attacker bytes are indistinguishable from real weights (sidecars trusted at load src/store.zig; cull loop src/fuse_fs.zig) |
| Origin write authority | The NFS export itself | Out of modelfs' control: anyone with origin write access rewrites weights and leases directly |

Not assets here: HF hub tokens live in user environments, not in this binary (src/main.zig has no credential handling beyond the PSK).

---

## Entry points

Everything below accepts input from outside the process; each is where validation must happen.

| Entry point | Code | Input accepted |
|---|---|---|
| Peer HTTP server, bound `0.0.0.0` on every unique advertised port (default 18080) | src/peer.zig (`bindAll`/`bindOne`), accept loop src/peer.zig | `GET /ping`, `GET /have?path=`, `GET /data?path=` with `Range`; `Authorization` header (request handling src/peer.zig). `--listen [IP:]PORT` consumes only the port (`listenPort` src/main.zig); there is no loopback-only or interface-scoped bind |
| FUSE operations on the mountpoint | ops table src/fuse_fs.zig; path policy src/fuse_fs.zig | Paths, write buffers, modes from every local process that can reach the mount |
| Lease files `<origin>/.cluster/<id>.json` written by other nodes | publish src/discover.zig, refresh src/discover.zig, sweep src/discover.zig; `modelfs peers` listing via walkLeases src/discover.zig | JSON documents: ids, expiry timestamps, address lists (parsed src/proto.zig) |
| Origin file tree (model data served to peers and locally) | statOrigin src/store.zig; hydration src/peer.zig | File bytes and sizes as they are on the NFS export |
| CLI subcommands and flags | src/main.zig dispatch, parseArgs src/main.zig | Paths, addresses, sizes, watermarks, id, PSK file path (never the secret: `--psk-value` is gone). `--seed HOST[:PORT]` hostnames are DNS-resolved once at mount (`buildSeeds` src/main.zig) |
| Environment variables `MODELFS_ORIGIN/CACHE/PSK/PSK_VALUE/ID/LOG` | src/main.zig | Same values as their flags (LOG: log ceiling `err`/`warn`/`info`/`debug`); explicit flag wins. Any other `MODELFS_*` name is refused as a typo (`checkKnownEnv` src/main.zig) |
| PSK file (`--psk`, default `/etc/modelfs.psk`) | loadPsk src/main.zig | Up to 4096 bytes, whitespace-trimmed, CR/LF refused |
| Cache-dir artifacts read back at runtime (`meta/*.pieces` bitfields, `pin/` markers, `status.json`) | store walk/load src/store.zig, status read src/main.zig | On-disk state written by this same process; trusted structurally, not cryptographically. `modelfs pin`/`unpin` writes `pin/` with no daemon and no PSK check (`cmdPin` src/main.zig) |

No scheduled jobs, IPC endpoints, message consumers, webhooks, or debug/admin services exist; the binary links only libfuse3/libc/pthread (build.zig.zon declares no dependencies).

---

## Trust boundaries and data flow

```
local engines/processes ⇄ [FUSE/kernel] ⇄ modelfs daemon ⇄ [TCP :18080, plaintext] ⇄ peer daemons
                                   ⇅                            ⇅
                          [origin dir, NFS] ⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄⇄ origin holds .cluster leases too
                                   ⇅
                          [cache dir on NVMe] (bitfields, pins, status.json)
```

**B1: local processes to daemon (FUSE).** Authority transition: anything crossing the mount becomes daemon-uid I/O against origin and cache. Enforcement is delegated to the kernel via `default_permissions` mounted by default; `allow_other` is opt-in (src/main.zig). Path policy is centralized in `resolveRel` (src/fuse_fs.zig): `.cluster` is invisible (lookup gets ENOENT, mutation EPERM), traversal and absolute paths get EPERM via `relOk`.

**B2: network to peer server.** Every request, including `/ping` and non-GET, requires the bearer PSK, checked before the method gate and route dispatch (src/peer.zig); comparison is timing-safe SHA-256 equality (src/proto.zig). A missing or wrong token is `401 WWW-Authenticate: Bearer` on every method, so an unauthenticated POST cannot learn that GET is the only verb. A live listener is still confirmed by the 401 itself. After auth, non-GET answers `405 Allow: GET`; the request path is URL-decoded into a fixed buffer and gated by `relOk` before touching origin or cache roots (src/peer.zig). There is no per-node identity: possessing the PSK is membership. Binding is always `0.0.0.0` on each unique advertised port (`bindAll` src/peer.zig); `--listen 127.0.0.1:18080` does not confine the listener to loopback.

**B3: daemon to origin (shared directory).** The origin is semi-trusted storage that also carries control data from other nodes. Untrusted inputs here: lease JSON (ids, addrs), file names under `.cluster`, and model bytes themselves. Controls: expired/corrupt/self leases skipped (src/discover.zig), lease ip fields validated by a hand parser before socket use (parseV4 src/discover.zig; inet_pton again at dial src/peer.zig), O_NOFOLLOW on every staged write into shared or locally-writable dirs (lease staging src/discover.zig, cache data src/store.zig, pin markers and status.json src/sys.zig, status staging rename src/fuse_fs.zig), control-byte filtering before any untrusted name/id is echoed to logs or terminals (printable/displayName src/discover.zig, applied in `peers` output src/main.zig and refresh/sweep logging src/discover.zig). `--seed HOST` is a sibling control-plane input: the hostname is resolved once at mount (`buildSeeds` src/main.zig via `sys.resolveIpv4`) and the resulting IPv4 is a dial target that then receives the PSK in a Bearer header, same handoff as a forged lease, with DNS/`/etc/hosts` as the precondition instead of origin write.

**B4: build to runtime.** Single Zig binary; no Zig package dependencies, no plugins, no config fetched at runtime beyond the PSK file and env vars listed above. The one compiled-in third-party surface is libfuse3; the cross-aarch64 build vendors two libfuse3 `.deb`s whose sha256 digests live in `.deps/fuse3-arm64/SHA256SUMS` and are verified by `scripts/extract_fuse3_arm64.sh` before unpack (into `.scratch/fuse3-arm64/`, not the source tree) and again by build.zig before compiling. The host build links whatever libfuse3 dev package is installed system-wide, so host provenance is an operator concern. The long-lived networked image is a PIE (`exe.pie = true` in build.zig) with stack canaries in every optimize mode (`stack_protector = true` on the executable and test modules); non-Debug builds strip DWARF so `DW_AT_comp_dir` cannot leak the build path into a shipped binary.

**Secrets flow.** The PSK enters via file read at startup (mode-checked, group/world-readable warned) or `MODELFS_PSK_VALUE`, both in `loadPsk` (src/main.zig). On mount the two sources are exclusive: both set is refused rather than silently preferring the env value. No flag carries the secret (`--psk-value` was removed): argv would publish it to every local user through `/proc/<pid>/cmdline`, while the environment block is readable only by the process owner and root. The mount log line names origin, cache, id, piece, port, and watermarks and never the secret (cmdMount src/main.zig). It lives for the process lifetime in memory and leaves the host on every outbound peer request in a plaintext header (src/peer.zig) and implicitly to any passive listener on inbound connections. It also leaves via crash dumps: nothing installs an `RLIMIT_CORE` cap or steers `core_pattern` (src/main.zig sets no rlimits; src/sys.zig has none either), so a crashing daemon writes PSK-bearing memory to whatever destination the kernel's dump setting names — this tree itself once shipped a committed core of its own test binary. Empty PSKs are refused before binding, as are secrets containing CR/LF, which would corrupt the request head (`dupeHeaderSafePsk` src/main.zig). Rotation means regenerating the file on every node simultaneously; there is no versioning, overlap window, or revocation.

---

## Threats per boundary

STRIDE per boundary, tied to real entry points. "Mitigated" rows cite the control; unmitigated ones appear in the gaps section.

### B1: local processes to daemon (FUSE)

| Threat | Assessment |
|---|---|
| S spoofing another local user | Delegated to kernel permission checks (`default_permissions`, src/main.zig); root bypasses everything by definition |
| T tampering with weights via writes | By design: writes go through 1:1 to origin with last-writer-wins and no locking (documented architecture.md "Writes and races"); two-node staleness is a known consistency hazard, not mitigated in code |
| R repudiation | None: writes are not attributed or audited beyond aggregate counters |
| I disclosure across users | Governed by origin/cache file modes (cache data created 0644, src/store.zig; origin create/mkdir/chmod modes arrive from the client but are masked to permission bits, src/fuse_fs.zig); `.cluster` hidden but its secrecy is irrelevant (no PSK inside leases) |
| D resource exhaustion | A local reader forcing misses drives origin reads and cache fills; bounded by cull watermarks (src/cull.zig) and pin exclusions; `--kernel-cache` RAM use is operator-chosen |
| E elevation of privilege | Path escape blocked at `resolveRel`/`relOk` (src/fuse_fs.zig, src/store.zig); symlink redirection of staged writes blocked by O_NOFOLLOW (src/sys.zig); client-supplied create/mkdir/chmod modes stripped of setuid/setgid/sticky so a mount writer cannot plant a daemon-owned special-bit executable (clientCreateMode src/fuse_fs.zig, applied at mf_create, mf_mkdir, and mf_chmod); the disk-cull walk samples entries with lstat and skips symlinks so planted links can neither be punched through nor descended into to steer fallocate punches outside the cache tree (src/store.zig, src/sys.zig) |

### B2: network to peer server (internet-facing boundary of this system; treat any routable host as the adversary)

| Threat | Assessment |
|---|---|
| S spoofing a legitimate node | Possession of the PSK is total; the PSK crosses the network in cleartext on every request, so a passive observer becomes a member (gap R1/R3) |
| T tampering with served/fetched bytes | No checksums anywhere on the wire or at rest; fetched pieces are cached and re-served verbatim (fill path src/peer.zig) (gap R2). Routing-level confusion (mixed piece grids) IS handled: mismatched `X-Piece-Size` answers are discarded (src/peer.zig) |
| R repudiation of actions | Requests are anonymous beyond PSK possession. Rejected requests ARE attributed: each 401 logs the accepted source address (src/peer.zig); malformed-head scanner noise is counted (`http_malformed`), not logged per event, to deny scanners a log-flooding lever (src/peer.zig). Successful requests carry no per-source audit trail |
| I information disclosure | Weights and PSK readable on path (gap R1); error replies carry empty bodies and no internals (src/peer.zig); log lines include rel paths only after relOk strips control bytes. Unauthenticated requests receive `401 WWW-Authenticate: Bearer` (handleConn src/peer.zig), confirming a live peer listener; `405 Allow: GET` is only for an authenticated client using the wrong method |
| D denial of service | Handler cap 16 with claim-then-check accounting (src/peer.zig); head read deadline 10 s defeats dribble-holds (src/peer.zig); body deadlines scale with Content-Length (src/peer.zig); oversized/malformed heads counted, not logged per-event, bounding log flooding (src/peer.zig); connections refused at the cap are counted (`http_dropped`) so saturation is visible from status.json without per-drop logging (accept loop src/peer.zig). Remaining exposure: 16 slots is small enough to occupy with reconnect loops, and authenticated requests force per-piece origin reads + NVMe writes (gap R4/R6). Server-side allocation is range-bounded: ranges clamp to file size (src/peer.zig) and hydration uses one reusable piece-sized buffer (src/peer.zig). Client-side `/have` bodies are refused above 16 MiB before allocation (`max_have_body_bytes` src/peer.zig); other allocated bodies still honor a 512 MiB cap (`max_alloc_body_bytes`) |
| E elevation via path tricks | `..`, absolute, control-byte, NUL paths refused with 400 (relOk gate src/peer.zig; test coverage src/store.zig); over-long paths that can never name an origin file also answer 400 instead of polluting the 5xx health gauge (ENAMETOOLONG branch of replyOriginStat src/peer.zig); unknown routes 404 before parameter parsing (src/peer.zig); non-GET 405 (src/peer.zig) |

### B3: daemon to origin (.cluster control plane)

| Threat | Assessment |
|---|---|
| S forging membership | Anyone with origin write access can publish a lease naming arbitrary ips/ports; victims will dial them. The forged peer still needs the PSK to answer /data, but the connection attempt itself hands the victim's PSK to the forged address in a Bearer header (sendRequest src/peer.zig). Lease mbps even lets the forged address win routing outright (prior from lease field, src/discover.zig) (gap R5). The same PSK-handoff happens if `--seed HOST` resolves to an attacker IP at mount (`buildSeeds` src/main.zig): the seed is dialed on the first miss |
| T tampering with other nodes' leases | Sweeping is mtime-based and skips only the sweeper's own id (sweepLeases self-id skip src/discover.zig); a co-tenant who can touch mtimes can evict live nodes from discovery. Requires origin write access, same precondition as above |
| R repudiation | Leases carry no signature or provenance; sweeps delete history |
| I disclosure | Lease documents deliberately exclude the PSK (architecture.md Discovery); contents are topology only |
| D discovery poisoning | Corrupt/expired leases are skipped, not fatal (src/discover.zig); a flood of garbage lease files costs readdir+parse per tick, unbounded by count (minor, origin-write precondition) |
| E n/a | No authority executes from lease content beyond dial targets |

### Secrets to code

Covered under Secrets flow above. `--psk-value` on argv is gone (it would have published the secret through `/proc/<pid>/cmdline`). Remaining accepted exposures: plaintext wire transmission, `MODELFS_PSK_VALUE` in the process environment (readable by the owner and root), crash-time cores (R8), and the single-secret trust model with no rotation story.

---

## Mitigations in place

Controls that exist in code, mapped to the threats they cover:

| Control | Location | Covers |
|---|---|---|
| Bearer PSK required on every request including /ping and non-GET (401 without a valid token; 405 with `Allow: GET` only after auth) | src/peer.zig handleConn | Raises B2 entry bar to PSK possession; a 401 still shows that a listener is present, but not that GET is the only verb |
| Timing-safe token comparison (SHA-256 then constant-time eql) | src/proto.zig | Timing oracle on the auth check |
| Empty-PSK refusal at startup, plus refusal of secrets containing CR/LF that would corrupt the request head | src/main.zig; header-safety gate src/main.zig | Accidental unauthenticated service; self-inflicted auth drift where every fetch 401s |
| PSK file permission warning (group/other bits) | src/main.zig | Local PSK theft by co-users (detection, not prevention) |
| Duplicate-bind refusal: listeners use SO_REUSEADDR only, never SO_REUSEPORT, so a second modelfs start against a live port fails loudly instead of silently splitting connections between two daemons (usually different PSKs) | src/peer.zig; regression test src/peer.zig | B2/S: accidental or malicious co-tenant daemon sharing the port and harvesting requests meant for the real one |
| Source-attributed rejection logging: the accepted peer address is captured per connection and named in every 401 line; malformed-head scanner noise is counted (`http_malformed`) instead of logged per event so incomplete probes cannot flood the journal | src/peer.zig handleConn (401 attribution and the count-only malformed-head paths) | Investigating wrong-PSK probing campaigns after the fact (closes former gap R9's anonymity). Residual: a well-formed wrong-bearer flood is still one warn line per request; the 16-slot cap bounds concurrency, not line rate |
| Path safety gate `relOk` applied at every external path boundary (FUSE, peer HTTP, CLI pin) | src/store.zig; call sites src/peer.zig, src/fuse_fs.zig, src/main.zig | B1/B2/E: traversal out of origin and cache roots; log/terminal injection via control bytes |
| Centralized FUSE path policy incl. `.cluster` hiding | src/fuse_fs.zig | Lease-file exposure and mutation through the mount |
| Client-supplied FUSE create/mkdir/chmod modes masked to permission bits, stripping setuid/setgid/sticky before any origin create or attribute change | clientCreateMode src/fuse_fs.zig, applied at mf_create, mf_mkdir, and mf_chmod | B1/E: planting daemon-owned special-bit executables through the mount (or granting special bits to existing daemon-owned files post-create) |
| Symlink-planting defense (O_NOFOLLOW) on staged and cache writes | src/sys.zig, src/discover.zig, src/store.zig, src/fuse_fs.zig | Local attackers redirecting privileged writes |
| Disk-cull walk samples cache entries with lstat and skips symlinks entirely (neither sampled as punch victims nor descended into), with a depth cap on nesting | src/store.zig, src/sys.zig | B1/E: planted symlinks in a writable cache tree steering fallocate punches at arbitrary daemon-writable files outside `data/` |
| Untrusted-name hygiene: printable gates before echoing lease names/ids to logs and terminal output | src/discover.zig, src/main.zig | Log forgery and terminal escape injection from crafted lease names |
| Bounded parsing everywhere: overflow-safe size/range parsers, suffix ranges rejected, URL decode bounds-checked, fixed-size head buffers (server request head sized so any head sendRequest can emit fits: triple-encoded PATH_MAX rel plus a full-size bearer token plus framing, 16.5 KiB, src/peer.zig; client response heads 8 KiB at src/peer.zig), 10 s head deadline, `/have` body cap 16 MiB (`max_have_body_bytes` src/peer.zig; a truthful bitmap is KiB-scale, and `havePut` would otherwise pin copies of a 512 MiB answer in the 32-entry probe cache), generic allocated-body cap 512 MiB (`max_alloc_body_bytes`), body deadlines scaled to length | src/proto.zig; src/peer.zig (deadline constants, `readHeadFullDeadline`, `haveFromHeadDeadline`, and the shared body reader that carries the length cap) | Memory-exhaustion and slow-loris style holds on B2; hostile-peer `/have` amplification into the probe cache |
| Concurrency cap: 16 handlers, atomic claim-then-check; probe concurrency capped to the same number | src/peer.zig Server.max_inflight; probe cap in fillFromPeers | Unbounded thread/connection growth |
| Socket timeouts: 30 s steady-state, 15 s dial, 10 s head, length-scaled body budget | src/peer.zig | Stalled-peer slot retention |
| Range clamping to file size; one reusable piece-sized hydration buffer | src/peer.zig serveData and hydrateRange | Server-side allocation driven by attacker-chosen ranges |
| Regular-file gate before any cache work on both data endpoints: directories and other non-regular origin objects answer 404 on /have and /data alike, instead of reaching hydration's pread on a directory fd (which surfaced as a misattributed 502) | src/peer.zig serveData regular-file gate (and its /have counterpart) | B2 validation: non-regular paths driving cache writes and wrong-status replies |
| CLI flag scoping: mount-only options refused on status/peers/pin, positional arity enforced at parse (exit 2), percentages clamped to 0..100, watermark ordering validated cross-field, `--origin` required to be an existing directory for both consumers (a regular file realpaths fine but can never hold leases or serve joined reads), port 0 refused on `--listen`/`--advertise`/`--seed` (ephemeral bind whose lease still advertised 0), origin overlapping the cache refused at mount (piece files would land on the shared store), `MODELFS_PSK_VALUE` exclusive of `--psk`/`MODELFS_PSK` on mount, empty origin/cache/psk flags refused at parse, inline PSK capped at `proto.max_psk_bytes` like the file form, and any `MODELFS_*` name outside the documented set refused as a typo | rejectOutsideMount src/main.zig; positional gates src/main.zig; percent gate parsePercent and the cull.ordered watermark-ordering gate in parseArgs src/main.zig; pathIsDir and pathsOverlap gates at cmdMount and cmdPeers src/main.zig; listenPort/parseHostPort ZeroPort, refuseEmpty, ConflictingPsk, loadPsk PskTooLarge src/main.zig; checkKnownEnv src/main.zig | CLI entry point: silent no-op runs that leave an operator believing an option took effect; harness knobs cannot squat on the daemon's env namespace |
| Lease validation: expired filtered, corrupt skipped, self skipped, id charset enforced at publish and hostname fallback, dotted-quad enforcement on advertised addresses (--advertise refuses names at parse; --seed hostnames resolve exactly once at mount setup or fail loudly) | validId and lease filtering src/discover.zig; --advertise parse refusal in parseArgs and seed resolution buildSeeds src/main.zig | Discovery self-partitioning and malformed-document handling on B3 |
| Status.json retirement on two axes: an exited pid reads as not running, and a live pid whose artifact stopped ticking past 120 s (eleven missed discovery ticks) reads as not serving, so a wedged daemon cannot report healthy to monitors keying on `status`'s exit code (`mono_s` monotonic stamp published by statusJson src/fuse_fs.zig, falling back to wall-clock `now_s` on older artifacts; pidAlive, max_status_age_secs, statusAgeSecs, and the age gate in cmdStatus src/main.zig) | src/main.zig, src/fuse_fs.zig | Monitoring deception by crash leftovers and by hung-but-alive daemons |
| Failure-only per-event logs plus tick summary counters (http_ok/http_unauthorized/http_5xx/http_malformed/http_dropped/probe_err, bytes_to_peer) | src/peer.zig, src/fuse_fs.zig | Detecting auth failures, malformed-request storms, saturation at the handler cap, silent cluster degradation, and a serving node that would otherwise look idle |
| Fuzz harnesses over every untrusted-input parser: request heads and peer replies (auth/path/range pipeline, Content-Range binding on 206 bodies), lease JSON documents, the URL codec pair across the trust boundary, the FUSE path gate, the origin-relative path gate (`relOk`), and parseV4 diffed against libc inet_pton across the whole input space; seed corpora share one framing helper (src/fuzzcorpus.zig) | src/peer.zig; src/proto.zig; src/discover.zig; src/fuse_fs.zig; src/store.zig | Regression resistance on the B1/B2/B3 parsers; drift between ingestion and dial gates |
| PIE + stack canaries on the shipped image; DWARF stripped from every non-Debug build | `exe.pie`, `stack_protector`, `strip` in build.zig | B4: fixed-address networked daemon; uninstrumented ReleaseFast stack; `DW_AT_comp_dir` build-path leak in release binaries |
| Cache-identity drop on origin unlink/rename, including FUSE retries that see ENOENT | `Store.unlinkOrigin` / `Store.renameOrigin` src/store.zig (mf_unlink / mf_rename src/fuse_fs.zig) | B1/T and R7 crash window: a lost FUSE reply after origin unlink/rename used to leave `meta/*.pieces` behind, so a same-size recreate served the deleted file's bytes |

Single points of failure worth naming honestly:

- **The PSK is the only control on B2.** It simultaneously carries authentication, membership, and (through the threat of forgery) the only barrier on read access to every weight in the cluster. Its loss is unrecoverable without manual redeployment to every node.
- **`relOk` is the only path-safety control** for every externally supplied path (three call sites above). It is well tested (src/store.zig) and centrally defined, which is the right shape, but any new entry point that forgets it loses all path containment.

---

## Gaps (unmitigated threats)

Ranked by exploitability times impact. Fixes belong to sec-review passes; recorded here with locations.

1. **Plaintext transport with inline credentials (R1).** Every request carries `Authorization: Bearer <psk>` in cleartext (src/peer.zig) and every piece moves unencrypted (streamRange src/peer.zig). Any host on path (same L2, any router between racks, anyone doing ARP spoofing) reads weights and captures the PSK. design.md §9 promised mTLS-or-token as v1 auth; shipped is token-only over plain TCP.
2. **No piece integrity verification (R2).** Fetched bytes go straight into the cache and are marked filled (fetchRangeInto src/peer.zig, called from fillFromPeers src/peer.zig; completeFill src/store.zig); they are then served to local engines and to other peers. A malicious or compromised peer (or on-path rewriter, per R1) injects arbitrary bytes that propagate fleet-wide and persist until culled. design.md §9's "blake3 on every chunk... never serve unverified bytes" did NOT ship (architecture.md lists blake3 under "What did not ship"). At-rest corruption is equally silent: hole zeros read as valid filled data whenever a bitfield says filled.
3. **Static shared PSK, no rotation or revocation (R3).** One credential authenticates every node forever (loadPsk src/main.zig; no expiry, no identity). Node compromise equals cluster compromise; departure of a node requires cluster-wide key regeneration by hand.
4. **Trivial peer-service saturation (R4).** The 16-slot cap (src/peer.zig) is global, not per-source, and slots are occupied before and during auth. Sixteen cycling connections (each held to the 10 s head deadline, src/peer.zig) deny all peer fills cluster-wide while the node itself stays up, degrading every other node's miss path to origin speed.
5. **Lease poisoning enables PSK capture (R5).** With origin write access (the NFS export's own ACLs are the only gate), an attacker publishes `<origin>/.cluster/<id>.json` pointing at their IP with high `mbps`; victims dial it and transmit the PSK in a Bearer header over plaintext (src/discover.zig, src/peer.zig). Origin write access therefore converts into full cluster credential compromise, not just redirect DoS. The same handoff is available at mount via `--seed HOST` if DNS or `/etc/hosts` on that node maps HOST to the attacker (`buildSeeds` src/main.zig); the seed is resolved once and then dialed like any other path.
6. **Authenticated amplification and cache littering (R6).** Any PSK holder can request arbitrary ranges of arbitrary origin files from any node: each miss forces an origin pread plus an NVMe write on the victim (hydrateRange src/peer.zig), letting one host fill every node's cache disk with chosen data and multiply NFS load. Culling eventually evicts it; nothing prevents the cycle.
7. **Cache artifacts trusted without verification (R7).** Bitfield metadata loaded from `meta/*.pieces` determines which holes read as zeros versus hydrate (store walk/load paths, sidecar load src/store.zig); a local writer (or malware under the daemon uid) can flip bits to feed engines zero-filled weight regions, or plant pin markers to make junk uncullable. Local-only precondition, but the daemon performs no integrity check of its own state. Closed crash windows, not the remaining gap: size-change wipes now persist to the sidecar (reconcileSize and the shrink branch save the reset bitfield, src/store.zig), and unlink/rename drop cache identity even when the origin name is already gone (`Store.unlinkOrigin` / `Store.renameOrigin` src/store.zig), so a FUSE retry after a lost reply cannot resurrect a deleted file's bits over a same-size recreate.
8. **Crash-time PSK spill (R8).** The secret lives in process memory for the daemon's lifetime; nothing caps `RLIMIT_CORE` or steers dump handling (src/main.zig installs no rlimits), so any crash writes PSK-bearing memory wherever `kernel.core_pattern` points — world-readable if that destination is sloppy. The channel already fired in miniature: a core of this repo's own test binary was committed here and removed. Local-only precondition, but it converts every unexplained daemon crash into a potential credential-discard event; sec-review owns the fix.

Former gap (rejected-request anonymity, renumbered R9 above) is closed: the code now logs each 401 rejection with its source address and counts scanner noise under `http_malformed`; see [Mitigations](#mitigations-in-place). Residuals: successful requests still carry no per-source audit trail, and a well-formed wrong-bearer flood is one journal line per request (the handler cap bounds concurrency, not line rate).

---

## Abuse cases

What a hostile actor can do, with the enabling path named. Cases 1–5 need the PSK (a legit-but-curious node, a compromised spark, or anyone who captured it off the wire per R1). Case 6 needs only write access to the cache directory.

1. **Bulk weight exfiltration.** Enumerate paths (any relOk-clean string; replyOriginStat src/peer.zig distinguishes 404 absent from 400 over-long from 502 origin-broken), then `GET /data?path=<rel>` with successive `Range` headers to pull entire files from any node, at line rate via sendfile (streamRange src/peer.zig). No quota, rate limit, or audit trail distinguishes this from normal fills.
2. **Silent model poisoning.** Answer a victim's `/data` fetch with crafted bytes; the victim caches them marked-filled (fetchRangeInto src/peer.zig, landed by fillFromPeers via completeFill src/store.zig) and re-serves them to peers and local engines. Repeat per piece to corrupt a model everywhere it is cached, with no detection point anywhere in the system (R2).
3. **Route hijack for interception.** Publish a lease advertising the attacker's IP with high `mbps` (prior conversion src/discover.zig); victims preferentially connect and present the PSK; the attacker now sees (and can alter) fetch traffic selectively. Equivalently, poison DNS or `/etc/hosts` for a `--seed HOST` at the victim's mount (`buildSeeds` src/main.zig).
4. **Cluster slowdown.** Hold all 16 handler slots with idle connections (R4), or issue wide-range `/data` requests for uncached origin files to convert peer traffic into NFS load on the origin (R6). Either degrades every engine read behind the mount without ever violating a single auth check.
5. **Cache-disk exhaustion on a victim.** Continuously fetch distinct large ranges so the victim's cache fs fills with attacker-chosen pieces; culling (src/fuse_fs.zig cullLoop) fights back but pinned files and active transfers are exempt (cullOne skip conditions, src/store.zig; punchPiece's xfer guard, src/store.zig), so steady pressure raises IO load and evicts useful pieces (denial of cache).
6. **Pin junk against cull, locally.** `modelfs pin <rel>` writes a marker under `cache/pin/` with only a `relOk` check: no PSK, no running daemon (`cmdPin` src/main.zig). Any local uid that can write the cache dir can make attacker-chosen paths uncullable, compounding case 5. The same is true of planting files directly in `pin/`.

Trust placed in client-side enforcement: none found. The server validates path, method, range, and auth independently; clients trust peer-supplied bitmaps only for routing, and stale bits degrade to origin fallback rather than wrong data (probe-cache design, src/discover.zig, X-Piece-Size gate src/peer.zig).

---

## Response readiness (notes only)

- **Audit trail:** per-node journald logs carry failure-only events, each 401 with its source address (src/peer.zig), failed fetches with ip:port, origin errors (peer HTTP per-request; FUSE origin I/O edge-triggered at Store.noteOriginIo), pin/unpin state changes (persistent culling-exempt state is answerable from the journal alone, cmdPin src/main.zig), plus the tick counters including `http_ok`/`bytes_to_peer` serving volume and `http_dropped` saturation; status.json exposes lifetime aggregates, a wall-clock `now_s` stamp, and a same-machine monotonic `mono_s` stamp the wedge gate prefers (tick summary src/fuse_fs.zig, status write src/fuse_fs.zig). Still no persistent, centralized record, and successful peer requests are counted but unattributed per client.
- **Vulnerability-handling path:** documented in [SECURITY.md](../SECURITY.md): GitHub private vulnerability reporting, a supported-version statement (`v0.1.0` is the current release; the `0.1.x` line receives security fixes), and the route from "vulnerability reported" to "fix shipped" (advisory thread to fix on main to CHANGELOG entry naming affected and fixed versions). docs/audits.md records internal review history only, and docs/design.md §9 contains historical mitigation claims (now annotated) that should not be cited as current posture.
- **Compromise recovery sketch that exists today:** PSK regeneration guidance lives in docs/recovery.md (regenerate and redistribute after site loss); cache wiping before remount after rollback is documented there too, which doubles as the poison-recovery step for R2.

---

## Maintenance notes

- Every claim above cites a file and symbol; when code moves, re-verify the citation before trusting the row.
- Historical security claims live in docs/design.md §9 and are annotated there; do not import them here without checking src/.
- This document intentionally does not propose designs for the gaps; sec-review passes aimed by the ranking above own those fixes.
