# Zig source review

| Field | Value |
|---|---|
| Guide | [zig-src-review.md](../review-guides/zig-src-review.md) |
| Scope | all of `src/`, with attention on what `v0.7.0` added: the low-level FUSE layer, `handover.zig`, `hf.zig` |
| Date | 2026-09-02, against `v0.7.0` (`f28e89b`) |
| Result | No P0 or P1. Two P2 fixed under other guides |

This is the defect and security pass. Findings of shape, structure, or idiom went to the guides
that own them; this report records only what could be wrong.

## Checklist

| # | Item | Finding |
|---|---|---|
| 1 | Peer auth gating | Clean. `proto.bearerOk` still returns 401 before route dispatch, the method gate, and query parsing. `v0.7.0` added no peer route |
| 2 | Path containment | Clean, and extended correctly. `hf.parseTree` is a new external-input boundary and gates every listed path through `store.relOk`, then `relOk` again joined onto `--dest`, then `discover.relIsCluster`. `cmdPull` refuses a `--dest` that fails either |
| 3 | Bounded input reads | Clean. `hf` caps the listing at `max_listing_bytes` (8 MiB) and the token file at `max_token_bytes`; `handover.readStateFd` caps the blob at `max_state_bytes`. The last two were bare literals and are now named (see the [practices review](ZIG_PRACTICES_REVIEW.md)) |
| 4 | Malformed-input behavior | Clean. `handover.decode` returns typed errors (`BadMagic`, `Truncated`, `PskLen`, `PskTooLarge`, `BadInit`, `BadJson`) rather than panicking; `hf.parseTree` returns `BadListing`/`BadEntryPath`. No new `catch unreachable` or length assert reachable from peer bytes, lease JSON, a `/stage` window, or an HF response |
| 5 | Syscall-wrapper policy | One new stray, now fixed: `randomToken`'s raw `getrandom`/`getpid` moved behind `sys.randomBytes`. The documented exceptions are otherwise unchanged |
| 6 | Descriptor lifetime | Clean. `hf.fetchOne` closes the `.part` fd on every path and unlinks the partial on error via `errdefer`. `execHandover` deliberately leaves the FUSE and listen fds open, which is the point, and `serve` skips `fuse_session_destroy` only on the handover branch |
| 7 | Cache identity | Clean. `v0.7.0` did not touch the fill path; peer fills still reach `completeFill` only through `hydratePiece`'s `expectedHash` and `piece.digest` compare |
| 8 | Streaming shape | Clean. `/data` still streams through `sendfileAll`; `/stage` still replies a fixed `rdma.window_len` window |
| 9 | FUSE path and mode | Clean. Every `ll_*` op resolves through the ino or fh table and then calls a path handler that goes through `resolveRel`. Create, mkdir, and chmod modes still pass `clientCreateMode` |
| 10 | PSK never on argv | Clean, and this is the item `v0.7.0` stressed hardest. The handover passes knobs and PSK on a sealed memfd; exec argv is `bin _handover --state-fd N <mountpoint>`. There is a unit test asserting the PSK appears in no argv word. `hf` adds a second secret and gives it the same treatment: `HF_TOKEN` or the token file, never a flag, with core dumps disabled for the run |
| 11 | Hot-path allocation | One finding, deferred with a reason: `ll_read` allocates per read. It replaces libfuse's own per-read `malloc` rather than adding one, and removing it means bounding `conn.max_write`, which changes what INIT negotiates and therefore touches the handover replay. Recorded in the [idiom review](ZIG_IDIOM_REVIEW.md) |
| 12 | Test visibility | Clean. `src/root.zig` imports `handover.zig` and `hf.zig`; `scripts/check.sh` re-derives the list by glob and passes |

## Notes on the memfd handover

The state blob is written to a memfd sealed with `F_SEAL_SEAL|SHRINK|GROW|WRITE`, so the
replacement image cannot have its knobs or PSK rewritten between exec and read. CLOEXEC is
cleared only on the fds that must survive the exec, and re-armed on the far side before the
session starts serving, so a later `auto_unmount` helper cannot inherit the peer port.

Two things bound what a planted `update.req` can do, and both were checked. A same-uid writer
can name any absolute path as the replacement binary, which the threat model already records as
a same-uid precondition (that attacker can ptrace the daemon anyway). And SIGUSR2 is refused
without a captured `FUSE_INIT` to replay, so a signal arriving before the connection is
negotiated cannot exit the loop into an exec that would leave the mount unserved.

## Suites run

`./scripts/check.sh` green, 352 tests. `./scripts/ci.sh` green, all three jobs, with both
reproducibility builds byte-identical. `./scripts/test_hot_reload.sh` green.
