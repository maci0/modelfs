# Peer transfer path review

| Field | Value |
|---|---|
| Guide | [net-send-review.md](../review-guides/net-send-review.md) |
| Scope | `src/peer.zig` send and fetch paths, `src/discover.zig` scoring and probe cache, `src/rdma.zig` window codec |
| Date | 2026-09-02, against `v0.7.0` (`f28e89b`) |
| Result | No P0 or P1. One observation recorded |

The transfer path is unchanged by `v0.7.0` except at its edges, where `modelfs update` now
inherits the listen sockets rather than rebinding them. That is where this pass spent most of
its attention.

## Contract checks

| Item | Finding |
|---|---|
| **One piece, one source** | `Store.beginFill` claims the piece; `completeFill` re-checks the write generation, and `finishPiece` re-checks it again after the cache write. No second source is started |
| **Fallback ladder** | `/stage` to `/data` on the same peer, then the next path, then origin. `fetchFromCands` walks it once in one direction; a failed rung is not re-entered |
| **Origin-only after a local write** | `Store.wroteLocally` still gates it, so a peer's pre-write piece cannot hide the writer's own bytes |
| **Verification before admit** | The fetch path reaches `completeFill` only through `hydratePiece`, which calls `expectedHash` and compares `piece.digest` first. No route around it |
| **Source determinism** | `pickBest` takes the max score, `pathTieLess` breaks ties by ip bytes then port, `Catalog.refresh` sorts the path list and `groupPathsByPeerId` the probe groups. Nothing is left to lease-directory or `getifaddrs` order |
| **Probe singleflight** | `Catalog.probeTryClaim` gives one owner the walk; waiters retry the have cache. Cap overflow probes without joining, so a many-file cold start cannot stall behind a slot that will never name that rel |
| **Connection failures never cached** | Confirmed: hits and healthy 404 misses populate the have cache, dial failures do not, so a peer that comes back is retried on the next piece |
| **Stage-down stamping** | `Catalog.noteStageDown` is stamped in `fetchFromCands` from the failure instant (`src/peer.zig:1759`), with unit coverage in `src/discover.zig`. A sequential fill does not re-pay the `/stage` round trip per piece |
| **Reply validation** | `checkRangeReply` requires 206, a matching `Content-Range` start, an end at most the request end, and a selected length equal to `Content-Length`. A short body under a matching window is refused rather than cached |
| **Grid agreement** | A mismatched `X-Piece-Size` is treated as no-answer; an advertised `0` is malformed, not unknown |
| **Deadlines** | 46 deadline references across the path. `sock_timeout_ms` 30 s, `dial_timeout_ms` 15 s, `head_deadline_ms` 10 s, body budget scaled to the announced length. No blocking socket step without one |
| **Saturation refuses, never queues** | Atomic claim-then-check against `Server.max_inflight` (16); an over-cap connection is closed with no reply and counts `http_dropped` |
| **Partial transfers looped** | `sys.sendfileAll` and the `preadAll`/`pwriteAll`/`writeAll` family return `-errno` and are driven to completion |
| **Zero-copy preserved** | `/data` still streams through `sendfileAll`, with `Cached.xfer` held across the send so a cull cannot punch a hole mid-stream |
| **Counter coverage** | 33 `fetchAdd` sites against 87 failure and reply branches. Sampled the branches `v0.7.0` touched; each failure reaches a counter |

## Listener identity across a handover (item 12)

This is the item `v0.7.0` put pressure on, and it holds.

`sys.setReuseAddr` sets `SO_REUSEADDR` only. `SO_REUSEPORT` appears in exactly two places: the
comment in `bindOne` explaining why it is not set, and `sys.reuseportIsOn`, which exists to
*detect* it. `Server.adoptListenFd`, the handover entry point, refuses an fd that is not
listening, refuses one carrying `SO_REUSEPORT`, and re-arms CLOEXEC so a later `auto_unmount`
helper cannot inherit the port. There is a regression test that a second bind against a live
port still fails loudly rather than silently splitting connections.

## Observation, since closed

`ll_read`'s ENOMEM path replied without moving a counter, because the allocation failed before
`mf_read` ran and `reads_err` is incremented inside it. The guide's rule is that every failure
branch moves something, and this one did not.

Closed on 2026-09-03 by the read-buffer pool: the branch now increments `reads_err`, and the
allocation it guarded only happens on the documented fallback past the last pool slot. See the
[idiom review](ZIG_IDIOM_REVIEW.md).

## Suites run

`./scripts/check.sh` green. `./scripts/test_hot_reload.sh` green: two image swaps with an fd
held open across both, the peer port accepting throughout. `./scripts/run_cluster_e2e_9nodes.sh`
was run five times earlier in this cycle for the low-level-API migration; four passed and one
failed on `spark_2 reported no peer fills`, a harness race where node 2 beat node 1 to the
origin. That is recorded as a suspected pre-existing flake on one data point, not as a verdict.
