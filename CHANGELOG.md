# Changelog & Autoresearch Notebook

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
