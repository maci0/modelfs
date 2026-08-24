# Changelog & Autoresearch Notebook

## [Design review pass] - 2026-08-25
- **`/have` answers now advertise their piece grid (`X-Piece-Size`)**: the bitmap body was raw bits with no context, so bit i meant "my piece i" under the *answering* node's `--piece` while the fetcher indexed it against its own; a fleet running mixed piece sizes silently misread every answer and routed fills by bits covering different byte ranges per node. The fetch client now excludes peers whose advertised grid differs from local (unknown, i.e. header absent from an older peer, still assumes aligned), matching the defense the local layer already had (`Bitfield.decode` resets sidecars whose stored piece size differs). Response parsing moved into one shared `finishBodyAlloc`/`haveFromHead` seam so the length-matching contract cannot drift between `/have` and `/data` readers. Mixed grids degrade to origin traffic, never to wrong data; covered at the parser, the cache roundtrip, and end to end through two live servers on different grids.

## [Portability review pass] - 2026-08-25
- **The documented aarch64 cross-build had no CI coverage**: README and docs/architecture.md name `aarch64-linux-gnu` as the spark deployment target, but CI only ever built x86_64-native, so a broken arm64 compile would ship unnoticed. New `cross-aarch64` CI job extracts the committed, hash-pinned libfuse3 debs (`dpkg-deb -x`, exactly the `.deps/fuse3-arm64/README.md` recipe; `build.zig` re-verifies both digests) and compiles `-Dtarget=aarch64-linux-gnu.2.39`, asserting the ELF machine type. Verified locally: the extraction reproduces the vendored trees byte-for-byte and the build links an ARM aarch64 binary.

## [Recovery review pass] - 2026-08-25
- **Origin had no backup story at all**: `tank/models` holds the only copy of every weight file, `unlink` through the mount lands there immediately, and the repo contained zero snapshots, replicas, or restore steps. New docs/recovery.md owns the durability posture: state inventory (caches and leases are derived/ephemeral, everything else is not), a sanoid/syncoid snapshot + replica schedule with failure alerting instead of exit-code trust, per-disaster restore procedures including the wipe-all-caches-before-remount ordering trap after any rollback (the stale-piece rule would otherwise serve post-rollback bytes), stated RPO/RTO per disaster, and a monthly timed restore drill.
- **Silent bit rot had no detector**: operations.md now schedules the monthly `zpool scrub` timer and smartd; cold weight files can carry checksum errors that no read will ever surface.
- **Documented, deliberately not changed: the ack-before-stable window**. `sharenfs="rw,async"` plus client `soft` mounts mean a NAS crash can lose writes clients already saw succeed (window bounded by the txg interval). Synced exports trade ingest throughput for durability; that call stays with the maintainer.

## [Design review pass] - 2026-08-24
- **`--advertise` requires dotted-quad IPs**: host names were accepted at the flag but every lease consumer (`peer.zig` dial, `discover.hopsBetween`) inet_pton's the ip field, so an advertised name published an address no peer could ever dial, silently dead-ending this node's P2P routes while NFS fallback masked it. Rejected at flag parse with a named error, mirroring the rationale that last pass made `--seed` resolve-or-fail-loudly; unlike a seed, an advertise address names our own interface, so there is nothing to resolve.
- **Peer `/data` accepts open-ended ranges (`bytes=N-`)**: the endpoint already clamps over-long explicit ends per RFC 9110 so ordinary HTTP clients can ask for the rest of a file, but the standard form for exactly that request was refused with 400. An empty end now parses as "through EOF" and flows through the existing clamp; suffix ranges (`bytes=-N`) stay rejected. Covered at the parser and end to end through a live server.

## [Functional review pass] - 2026-08-24
- **`--seed HOST[:PORT]` now works as documented**: seed hosts that are not dotted quads are resolved once at mount setup (`sys.resolveIpv4` via `getaddrinfo`), where an unresolvable host fails the mount with a named message instead of being accepted and then dying silently on every discovery tick's dial (peer dials only accept dotted quads). Numeric seeds pass through untouched; a regression-tested `buildSeeds` helper owns the resolution.
- **Script probes**: `peer_auth_probe.py` gained the same 30s HTTP timeout its sibling probes got in ce3aff4, so a peer that accepts but never answers fails the fault-tolerance suite instead of hanging it.

## [Quality pass] - 2026-08-23
- **Peer `/data` hydration**: the piece scratch buffer is now allocated before `claimPiece`, so an OOM can no longer leak a filling claim and wedge every later filler of that piece into `claimPiece`'s retry spin; a truncate racing the size sample now drops the claim instead of marking an empty piece filled (matching `fuse_fs.hydratePiece`).
- **Peer fetch contract**: `readFlexBodyAlloc` checks the caller-supplied buffer length before its zero-length early return, so a peer answering without `Content-Length` fails the fetch instead of "succeeding" with zero bytes written (the piece would have been marked filled over hole zeros).
- **Head deadline clamp**: `readHeadFullDeadline` restores the steady-state socket timeout once the head completes, so a dribbled head no longer leaves body streaming a millisecond-scale send/receive ceiling.
- **CLI**: `--piece` sizes with trailing garbage (`16Mfoo`, `1KB2`) are rejected instead of silently parsing as the prefix value; unknown flags report through the same plain usage-error channel as every other bad value.
- **Consistency/cleanup**: `mf_open` returns the captured origin-stat errno like `mf_getattr`/`mf_read`; `cacheFill`'s shrink path warns on OOM like the grow path; `Bitfield` pad-bit masking unified in one helper and `filled()` defends against corrupt pads like `lastSet()`; `writeFile`/`writeFileNoFollow` share one implementation.

## [Performance pass] - 2026-08-23
- **Peer probe cache**: successful `/have` bitmaps are cached per (peer, path) for 2 s in `Catalog`, so sequential piece fills of one model no longer re-probe the whole cluster (one connect + round trip + full bitmap transfer per peer per 16 MiB piece) before every fetch. Only hits are cached; failed probes stay uncached so down peers are retried next piece.
- **Read hot path**: `ensureRange` and the peer `/data` hydration loop now allocate their piece-size scratch buffer only when a covered piece actually lacks its bit; fully-cached reads previously paid a 16 MiB alloc/free per call.
- **Consistency**: `ensureRange` now uses the size sample `mf_read` already took under `file.mu` instead of re-reading `file.size` unlocked for its `cover()` computation.

## [Fresh Autoresearch Session] - 2026-08-22
- **New Benchmark Focus**: 64 MB piece transfer latency & peak zero-copy throughput.
- **Key Findings**:
  1. Unchunked single-pass `sendfile` kernel streaming achieves **3.43–3.94 GB/s** zero-copy throughput.
  2. Preserving read-ahead body bytes in `readHeadFull` prevents socket re-read stalls on multi-megabyte transfers.
  3. 2 MB socket buffers (`SO_RCVBUF`/`SO_SNDBUF`) provide optimal throughput on local TCP loopback.
- **Verification Integrity**: All 31 unit tests and 3 E2E integration test suites pass 100% cleanly with 0 memory leaks.
