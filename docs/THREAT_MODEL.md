# Threat model

| Field | Value |
|---|---|
| Status | Living document; describes `src/` as of the date below |
| Last reviewed | 2026-08-26 |
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
| R5 | Lease poisoning: write access to `origin/.cluster` redirects victim fetches to attacker-chosen IPs, and the victim then hands the PSK to that IP in a Bearer header over plaintext | node to origin | No mitigation |
| R6 | Authenticated peer amplification: `/have` and `/data` force origin stats plus full-piece hydration (NFS read + NVMe write) per request, filling the serving node's cache disk | peer to peer | Bounded only by local cull watermarks |
| R7 | Local tamper surface: cache bitfields are trusted at load (a tampered `meta/*.pieces` serves hole zeros as valid data); `--psk-value` exposes the secret in `/proc/<pid>/cmdline` | local user to cache/secrets | Warned, not prevented (`--psk-value`) |
| R8 | Rejected peer requests leave no attributable trace: wrong-PSK probes were once invisible beyond a bare counter | network to peer server | Mitigated (source-address logging on 401s; scanner noise stays count-only by design) |

---

## Assets

| Asset | Where it lives | Impact if lost |
|---|---|---|
| LLM weights | origin tree (authoritative copy), per-node piece caches (`data/`) | Exfiltration of valuable/licensed models; silent corruption poisons training/serving runs |
| Cluster PSK | `/etc/modelfs.psk` or `--psk-value`/`MODELFS_PSK_VALUE`, process memory, every request's `Authorization` header (src/main.zig:410-468, src/peer.zig:721-737) | Full impersonation of any node: read every weight, serve poisoned pieces |
| Availability of the read path | `/models` mount, peer port, NFS origin | Reads block until a piece fills; stalled peers degrade the whole cluster to origin-tier throughput |
| Cache integrity | `data/` sparse files + `meta/*.pieces` bitfields | Punched holes read as zeros; without verification, zeros and attacker bytes are indistinguishable from real weights (sidecars trusted at load src/store.zig:375-413; cull loop src/fuse_fs.zig:911-954) |
| Origin write authority | The NFS export itself | Out of modelfs' control: anyone with origin write access rewrites weights and leases directly |

Not assets here: HF hub tokens live in user environments, not in this binary (src/main.zig has no credential handling beyond the PSK).

---

## Entry points

Everything below accepts input from outside the process; each is where validation must happen.

| Entry point | Code | Input accepted |
|---|---|---|
| Peer HTTP server, bound `0.0.0.0` on every advertised port (default 18080) | src/peer.zig:30-64 (`bindAll`/`bindOne`), accept loop src/peer.zig:109-153 | `GET /ping`, `GET /have?path=`, `GET /data?path=` with `Range`; `Authorization` header (request handling src/peer.zig:264-357) |
| FUSE operations on the mountpoint | ops table src/fuse_fs.zig:1081-1099; path policy src/fuse_fs.zig:86-95 | Paths, write buffers, modes from every local process that can reach the mount |
| Lease files `<origin>/.cluster/<id>.json` written by other nodes | publish src/discover.zig:392-443, refresh src/discover.zig:449-523, sweep src/discover.zig:532-566; also parsed for the `modelfs peers` listing src/main.zig:913-1024 | JSON documents: ids, expiry timestamps, address lists (parsed src/proto.zig:162-164) |
| Origin file tree (model data served to peers and locally) | statOrigin src/store.zig:248-252; hydration src/peer.zig:417-489 | File bytes and sizes as they are on the NFS export |
| CLI subcommands and flags | src/main.zig:553-588 dispatch, parseArgs src/main.zig:231-408 | Paths, addresses, sizes, watermarks, id, PSK source |
| Environment variables `MODELFS_ORIGIN/CACHE/PSK/PSK_VALUE/ID` | src/main.zig:247-260 | Same values as their flags; explicit flag wins |
| PSK file (`--psk`, default `/etc/modelfs.psk`) | loadPsk src/main.zig:410-468 | Up to 4096 bytes, whitespace-trimmed, CR/LF refused |
| Cache-dir artifacts read back at runtime (`meta/*.pieces` bitfields, `pin/` markers, `status.json`) | store walk/load src/store.zig, status read src/main.zig:881-911 | On-disk state written by this same process; trusted structurally, not cryptographically |

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

**B1: local processes to daemon (FUSE).** Authority transition: anything crossing the mount becomes daemon-uid I/O against origin and cache. Enforcement is delegated to the kernel via `default_permissions` mounted by default; `allow_other` is opt-in (src/main.zig:776-779). Path policy is centralized in `resolveRel` (src/fuse_fs.zig:86-95): `.cluster` is invisible (lookup gets ENOENT, mutation EPERM), traversal and absolute paths get EPERM via `relOk`.

**B2: network to peer server.** Every endpoint requires the bearer PSK, checked before route dispatch so `/ping` is covered too (src/peer.zig:304-318); comparison is timing-safe SHA-256 equality (src/proto.zig:127-136). After auth, the request path is URL-decoded into a fixed buffer and gated by `relOk` before touching origin or cache roots (src/peer.zig:333-343). There is no per-node identity: possessing the PSK is membership.

**B3: daemon to origin (shared directory).** The origin is semi-trusted storage that also carries control data from other nodes. Untrusted inputs here: lease JSON (ids, addrs), file names under `.cluster`, and model bytes themselves. Controls: expired/corrupt/self leases skipped (src/discover.zig:471-484), lease ip fields validated by a hand parser before socket use (parseV4 src/discover.zig:22-49; inet_pton again at dial src/peer.zig:762-786), O_NOFOLLOW on every staged write into shared or locally-writable dirs (lease staging src/discover.zig:423-435, cache data src/store.zig:948-973, pin markers and status.json src/sys.zig:303-315, status staging rename src/fuse_fs.zig:1071-1078), control-byte filtering before any untrusted name/id is echoed to logs or terminals (printable/displayName src/discover.zig:143-167, applied in `peers` output src/main.zig:1007-1010 and refresh/sweep logging src/discover.zig:471-478, 557-564).

**B4: build to runtime.** Single Zig binary; no package dependencies, no plugins, no config fetched at runtime beyond the PSK file and env vars listed above.

**Secrets flow.** The PSK enters via file read at startup (mode-checked, group/world-readable warned src/main.zig:458-461) or `--psk-value`/`MODELFS_PSK_VALUE` (argv/env; the argv spelling warned as world-readable via /proc src/main.zig:413-425). It lives for the process lifetime in memory and leaves the host on every outbound peer request in a plaintext header (src/peer.zig:721-737) and implicitly to any passive listener on inbound connections. Empty PSKs are refused before binding (src/main.zig:413-417, 462-466), as are secrets containing CR/LF, which would corrupt the request head (src/main.zig:479-488). Rotation means regenerating the file on every node simultaneously; there is no versioning, overlap window, or revocation.

---

## Threats per boundary

STRIDE per boundary, tied to real entry points. "Mitigated" rows cite the control; unmitigated ones appear in the gaps section.

### B1: local processes to daemon (FUSE)

| Threat | Assessment |
|---|---|
| S spoofing another local user | Delegated to kernel permission checks (`default_permissions`, src/main.zig:778); root bypasses everything by definition |
| T tampering with weights via writes | By design: writes go through 1:1 to origin with last-writer-wins and no locking (documented architecture.md "Writes and races"); two-node staleness is a known consistency hazard, not mitigated in code |
| R repudiation | None: writes are not attributed or audited beyond aggregate counters |
| I disclosure across users | Governed by origin/cache file modes (cache data created 0644, src/store.zig:960; origin create/mkdir/chmod modes arrive from the client but are masked to permission bits, src/fuse_fs.zig:97-106); `.cluster` hidden but its secrecy is irrelevant (no PSK inside leases) |
| D resource exhaustion | A local reader forcing misses drives origin reads and cache fills; bounded by cull watermarks (src/cull.zig:22-36) and pin exclusions; `--kernel-cache` RAM use is operator-chosen |
| E elevation of privilege | Path escape blocked at `resolveRel`/`relOk` (src/fuse_fs.zig:66-95, src/store.zig:1276-1293); symlink redirection of staged writes blocked by O_NOFOLLOW (src/sys.zig:303-315); client-supplied create/mkdir/chmod modes stripped of setuid/setgid/sticky so a mount writer cannot plant a daemon-owned special-bit executable (clientCreateMode src/fuse_fs.zig:97-106, applied at mf_create 411, mf_mkdir 714, and mf_chmod 771-777); the disk-cull walk samples entries with lstat and skips symlinks so planted links can neither be punched through nor descended into to steer fallocate punches outside the cache tree (src/store.zig:1098-1147, src/sys.zig:233-241) |

### B2: network to peer server (internet-facing boundary of this system; treat any routable host as the adversary)

| Threat | Assessment |
|---|---|
| S spoofing a legitimate node | Possession of the PSK is total; the PSK crosses the network in cleartext on every request, so a passive observer becomes a member (gap R1/R3) |
| T tampering with served/fetched bytes | No checksums anywhere on the wire or at rest; fetched pieces are cached and re-served verbatim (fill path src/peer.zig:1120-1168) (gap R2). Routing-level confusion (mixed piece grids) IS handled: mismatched `X-Piece-Size` answers are discarded (src/peer.zig:1094-1103) |
| R repudiation of actions | Requests are anonymous beyond PSK possession. Rejected requests ARE attributed: each 401 logs the accepted source address (src/peer.zig:305-315); malformed-head scanner noise is counted (`http_malformed`), not logged per event, to deny scanners a log-flooding lever (src/peer.zig:278-296). Successful requests carry no per-source audit trail |
| I information disclosure | Weights and PSK readable on path (gap R1); error replies carry empty bodies and no internals (src/peer.zig:655-676); log lines include rel paths only after relOk strips control bytes |
| D denial of service | Handler cap 16 with claim-then-check accounting (src/peer.zig:15, 136-151); head read deadline 10 s defeats dribble-holds (src/peer.zig:175, 216-248); body deadlines scale with Content-Length (src/peer.zig:197-205, 842); oversized/malformed heads counted, not logged per-event, bounding log flooding (src/peer.zig:278-296). Remaining exposure: 16 slots is small enough to occupy with reconnect loops, and authenticated requests force per-piece origin reads + NVMe writes (gap R4/R6). Server-side allocation is range-bounded: ranges clamp to file size (src/peer.zig:605-622) and hydration uses one reusable piece-sized buffer (src/peer.zig:420-435) |
| E elevation via path tricks | `..`, absolute, control-byte, NUL paths refused with 400 (relOk gate src/peer.zig:333-343; test coverage src/store.zig:1429-1477); unknown routes 404 before parameter parsing (src/peer.zig:328-332); non-GET 405 (src/peer.zig:298-303) |

### B3: daemon to origin (.cluster control plane)

| Threat | Assessment |
|---|---|
| S forging membership | Anyone with origin write access can publish a lease naming arbitrary ips/ports; victims will dial them. The forged peer still needs the PSK to answer /data, but the connection attempt itself hands the victim's PSK to the forged address in a Bearer header (sendRequest src/peer.zig:721-737). Lease mbps even lets the forged address win routing outright (prior from lease field, src/discover.zig:349-377) (gap R5) |
| T tampering with other nodes' leases | Sweeping is mtime-based and skips only the sweeper's own id (src/discover.zig:532-566, self-skip 541-542); a co-tenant who can touch mtimes can evict live nodes from discovery. Requires origin write access, same precondition as above |
| R repudiation | Leases carry no signature or provenance; sweeps delete history |
| I disclosure | Lease documents deliberately exclude the PSK (architecture.md Discovery); contents are topology only |
| D discovery poisoning | Corrupt/expired leases are skipped, not fatal (src/discover.zig:471-484); a flood of garbage lease files costs readdir+parse per tick, unbounded by count (minor, origin-write precondition) |
| E n/a | No authority executes from lease content beyond dial targets |

### Secrets to code

Covered under Secrets flow above. Notable accepted exposures: argv-carried PSK (warned), plaintext wire transmission, single-secret trust model with no rotation story.

---

## Mitigations in place

Controls that exist in code, mapped to the threats they cover:

| Control | Location | Covers |
|---|---|---|
| Bearer PSK required on every endpoint including /ping | src/peer.zig:304-318 | Raises B2 entry bar to PSK possession |
| Timing-safe token comparison (SHA-256 then constant-time eql) | src/proto.zig:127-136 | Timing oracle on the auth check |
| Empty-PSK refusal at startup, plus refusal of secrets containing CR/LF that would corrupt the request head | src/main.zig:413-417, 462-466; header-safety gate src/main.zig:479-488 | Accidental unauthenticated service; self-inflicted auth drift where every fetch 401s |
| PSK file permission warning (group/other bits) | src/main.zig:458-461 | Local PSK theft by co-users (detection, not prevention) |
| Duplicate-bind refusal: listeners use SO_REUSEADDR only, never SO_REUSEPORT, so a second modelfs start against a live port fails loudly instead of silently splitting connections between two daemons (usually different PSKs) | src/peer.zig:46-52; regression test src/peer.zig:1459-1486 | B2/S: accidental or malicious co-tenant daemon sharing the port and harvesting requests meant for the real one |
| Source-attributed rejection logging: the accepted peer address is captured per connection and named in every 401 line; malformed-head scanner noise is counted (`http_malformed`) instead of logged per event so probes cannot flood the journal | src/peer.zig:112-116, 253-262, 305-315 (attribution); 278-296 (count-only scanner path) | Investigating wrong-PSK probing campaigns after the fact (closes former gap R8) |
| Path safety gate `relOk` applied at every external path boundary (FUSE, peer HTTP, CLI pin) | src/store.zig:1276-1293; call sites src/peer.zig:333-343, src/fuse_fs.zig:66-95, src/main.zig:1042-1047 | B1/B2/E: traversal out of origin and cache roots; log/terminal injection via control bytes |
| Centralized FUSE path policy incl. `.cluster` hiding | src/fuse_fs.zig:81-95 | Lease-file exposure and mutation through the mount |
| Client-supplied FUSE create/mkdir/chmod modes masked to permission bits, stripping setuid/setgid/sticky before any origin create or attribute change | src/fuse_fs.zig:97-106, applied at mf_create 411, mf_mkdir 714, and mf_chmod 771-777 | B1/E: planting daemon-owned special-bit executables through the mount (or granting special bits to existing daemon-owned files post-create) |
| Symlink-planting defense (O_NOFOLLOW) on staged and cache writes | src/sys.zig:303-315, src/discover.zig:423-435, src/store.zig:948-973, src/fuse_fs.zig:1077 | Local attackers redirecting privileged writes |
| Disk-cull walk samples cache entries with lstat and skips symlinks entirely (neither sampled as punch victims nor descended into), with a depth cap on nesting | src/store.zig:1098-1147, src/sys.zig:233-241 | B1/E: planted symlinks in a writable cache tree steering fallocate punches at arbitrary daemon-writable files outside `data/` |
| Untrusted-name hygiene: printable gates before echoing lease names/ids to logs and terminal output | src/discover.zig:143-167, src/main.zig:1007-1010 | Log forgery and terminal escape injection from crafted lease names |
| Bounded parsing everywhere: overflow-safe size/range parsers, suffix ranges rejected, URL decode bounds-checked, fixed-size head buffers (server request head sized so any head sendRequest can emit fits: triple-encoded PATH_MAX rel plus a full-size bearer token plus framing, 16.5 KiB, src/peer.zig:177-185; client response heads 8 KiB at src/peer.zig:689, 793), 10 s head deadline, Content-Length allocation cap (client side, 512 MiB), body deadlines scaled to length | src/proto.zig:17-59, 83-125; src/peer.zig:155-210 (deadline constants), 216-248 (head read), 788-875 (shared body reader incl. length cap at 838) | Memory-exhaustion and slow-loris style holds on B2 |
| Concurrency cap: 16 handlers, atomic claim-then-check; probe concurrency capped to the same number | src/peer.zig:15, 136-151, 976-985 | Unbounded thread/connection growth |
| Socket timeouts: 30 s steady-state, 15 s dial, 10 s head, length-scaled body budget | src/peer.zig:155-210 | Stalled-peer slot retention |
| Range clamping to file size; one reusable piece-sized hydration buffer | src/peer.zig:605-622, 420-435 | Server-side allocation driven by attacker-chosen ranges |
| Regular-file gate before any cache work on both data endpoints: directories and other non-regular origin objects answer 404 on /have and /data alike, instead of reaching hydration's pread on a directory fd (which surfaced as a misattributed 502) | src/peer.zig:373-376, 600-603 | B2 validation: non-regular paths driving cache writes and wrong-status replies |
| CLI flag scoping: mount-only options refused on status/peers/pin, positional arity enforced at parse (exit 2), percentages clamped to 0..100, watermark ordering validated cross-field | rejectOutsideMount src/main.zig:195-200; positional gates src/main.zig:553-584; percent/ordering gates src/main.zig:204-218, 397-406 | CLI entry point: silent no-op runs that leave an operator believing an option took effect |
| Lease validation: expired filtered, corrupt skipped, self skipped, id charset enforced at publish and hostname fallback, dotted-quad enforcement on advertised addresses (--advertise refuses names at parse; --seed hostnames resolve exactly once at mount setup or fail loudly) | src/discover.zig:471-484, 176-184, 22-49; src/main.zig:390-396, 342-363, 652-672 | Discovery self-partitioning and malformed-document handling on B3 |
| Stale status.json retirement via pid liveness | src/main.zig:894-908 (pidAlive src/main.zig:871-875) | Monitoring deception by crash leftovers |
| Failure-only per-event logs plus tick summary counters (http_unauthorized/http_5xx/http_malformed/probe_err) | src/peer.zig:278-315, src/fuse_fs.zig:982-1026 | Detecting auth failures, malformed-request storms, silent cluster degradation |
| Fuzz harnesses over every untrusted-input parser: request heads and peer replies (auth/path/range pipeline), lease JSON documents, the URL codec pair across the trust boundary, the FUSE path gate, and parseV4 diffed against libc inet_pton across the whole input space | src/peer.zig:2626-2810; src/proto.zig:355-399, 460-507; src/discover.zig:907-940, 1098-1131; src/fuse_fs.zig:173-220 | Regression resistance on the B1/B2/B3 parsers; drift between ingestion and dial gates |

Single points of failure worth naming honestly:

- **The PSK is the only control on B2.** It simultaneously carries authentication, membership, and (through the threat of forgery) the only barrier on read access to every weight in the cluster. Its loss is unrecoverable without manual redeployment to every node.
- **`relOk` is the only path-safety control** for every externally supplied path (three call sites above). It is well tested (src/store.zig:1429-1477) and centrally defined, which is the right shape, but any new entry point that forgets it loses all path containment.

---

## Gaps (unmitigated threats)

Ranked by exploitability times impact. Fixes belong to sec-review passes; recorded here with locations.

1. **Plaintext transport with inline credentials (R1).** Every request carries `Authorization: Bearer <psk>` in cleartext (src/peer.zig:721-737) and every piece moves unencrypted (streamRange src/peer.zig:503-585). Any host on path (same L2, any router between racks, anyone doing ARP spoofing) reads weights and captures the PSK. design.md §9 promised mTLS-or-token as v1 auth; shipped is token-only over plain TCP.
2. **No piece integrity verification (R2).** Fetched bytes go straight into the cache and are marked filled (fetchRangeInto src/peer.zig:748-752, called from fillFromPeers src/peer.zig:1120-1168; completeFill src/store.zig:729-733); they are then served to local engines and to other peers. A malicious or compromised peer (or on-path rewriter, per R1) injects arbitrary bytes that propagate fleet-wide and persist until culled. design.md §9's "blake3 on every chunk... never serve unverified bytes" did NOT ship (architecture.md lists blake3 under "What did not ship"). At-rest corruption is equally silent: hole zeros read as valid filled data whenever a bitfield says filled.
3. **Static shared PSK, no rotation or revocation (R3).** One credential authenticates every node forever (loadPsk src/main.zig:410-468; no expiry, no identity). Node compromise equals cluster compromise; departure of a node requires cluster-wide key regeneration by hand.
4. **Trivial peer-service saturation (R4).** The 16-slot cap (src/peer.zig:15) is global, not per-source, and slots are occupied before and during auth. Sixteen cycling connections (each held to the 10 s head deadline, src/peer.zig:175) deny all peer fills cluster-wide while the node itself stays up, degrading every other node's miss path to origin speed.
5. **Lease poisoning enables PSK capture (R5).** With origin write access (the NFS export's own ACLs are the only gate), an attacker publishes `<origin>/.cluster/<id>.json` pointing at their IP with high `mbps`; victims dial it and transmit the PSK in a Bearer header over plaintext (src/discover.zig:349-377, src/peer.zig:721-737). Origin write access therefore converts into full cluster credential compromise, not just redirect DoS.
6. **Authenticated amplification and cache littering (R6).** Any PSK holder can request arbitrary ranges of arbitrary origin files from any node: each miss forces an origin pread plus an NVMe write on the victim (hydrateRange src/peer.zig:417-489), letting one host fill every node's cache disk with chosen data and multiply NFS load. Culling eventually evicts it; nothing prevents the cycle.
7. **Cache artifacts trusted without verification (R7).** Bitfield metadata loaded from `meta/*.pieces` determines which holes read as zeros versus hydrate (store walk/load paths, sidecar load src/store.zig:375-413); a local writer (or malware under the daemon uid) can flip bits to feed engines zero-filled weight regions, or plant pin markers to make junk uncullable. Local-only precondition, but the daemon performs no integrity check of its own state.

Former gap 8 (rejected-request anonymity) is closed: the code now logs each 401 rejection with its source address and counts scanner noise under `http_malformed`; see [Mitigations](#mitigations-in-place). The residual limitation is recorded there too: successful requests still carry no per-source audit trail.

---

## Abuse cases

What a hostile but authenticated actor (PSK in hand: a legit-but-curious node, a compromised spark, or anyone who captured the PSK off the wire per R1) can do, with the enabling path named:

1. **Bulk weight exfiltration.** Enumerate paths (any relOk-clean string; 404 vs 502 distinguishes absent from broken, replyOriginStat src/peer.zig:669-676), then `GET /data?path=<rel>` with successive `Range` headers to pull entire files from any node, at line rate via sendfile (streamRange src/peer.zig:503-585). No quota, rate limit, or audit trail distinguishes this from normal fills.
2. **Silent model poisoning.** Answer a victim's `/data` fetch with crafted bytes; the victim caches them marked-filled (fetchRangeInto src/peer.zig:748-752, landed by fillFromPeers via completeFill src/store.zig:729-733) and re-serves them to peers and local engines. Repeat per piece to corrupt a model everywhere it is cached, with no detection point anywhere in the system (R2).
3. **Route hijack for interception.** Publish a lease advertising the attacker's IP with high `mbps` (prior conversion src/discover.zig:349-377); victims preferentially connect and present the PSK; the attacker now sees (and can alter) fetch traffic selectively.
4. **Cluster slowdown.** Hold all 16 handler slots with idle connections (R4), or issue wide-range `/data` requests for uncached origin files to convert peer traffic into NFS load on the origin (R6). Either degrades every engine read behind the mount without ever violating a single auth check.
5. **Cache-disk exhaustion on a victim.** Continuously fetch distinct large ranges so the victim's cache fs fills with attacker-chosen pieces; culling (src/fuse_fs.zig:911 cullLoop) fights back but pinned files and active transfers are exempt (cullOne skip conditions, src/store.zig:977-1022; punchPiece's xfer guard, src/store.zig:912), so steady pressure raises IO load and evicts useful pieces (denial of cache).

Trust placed in client-side enforcement: none found. The server validates path, method, range, and auth independently; clients trust peer-supplied bitmaps only for routing, and stale bits degrade to origin fallback rather than wrong data (probe-cache design, src/discover.zig:202-303, X-Piece-Size gate src/peer.zig:1094-1103).

---

## Response readiness (notes only)

- **Audit trail:** per-node journald logs carry failure-only events, each 401 with its source address (src/peer.zig:305-315), failed fetches with ip:port, origin errors, plus the tick counters; status.json exposes lifetime aggregates (tick summary src/fuse_fs.zig:982-1026, status write src/fuse_fs.zig:1028-1079). Still no persistent, centralized record, and successful requests are unattributed; o11y-review owns log structure.
- **Vulnerability-handling path:** documented in [SECURITY.md](../SECURITY.md): GitHub private vulnerability reporting, a supported-version statement (none released yet; fixes land on main), and the route from "vulnerability reported" to "fix shipped" (advisory thread to fix on main to CHANGELOG entry). Until a first tag exists there is still no patched release to point users at. docs/audits.md records internal review history only, and docs/design.md §9 contains historical mitigation claims (now annotated) that should not be cited as current posture.
- **Compromise recovery sketch that exists today:** PSK regeneration guidance lives in docs/recovery.md (regenerate and redistribute after site loss); cache wiping before remount after rollback is documented there too, which doubles as the poison-recovery step for R2.

---

## Maintenance notes

- Every claim above cites a file and line; when code moves, re-verify the citation before trusting the row.
- Historical security claims live in docs/design.md §9 and are annotated there; do not import them here without checking src/.
- This document intentionally does not propose designs for the gaps; sec-review passes aimed by the ranking above own those fixes.
