# Abstraction review

| Field | Value |
|---|---|
| Guide | [abstractions-review.md](../review-guides/abstractions-review.md) |
| Scope | the load-bearing types in `src/`, per the guide's inventory |
| Date | 2026-09-02, against `v0.7.0` (`f28e89b`) |
| Result | 1 P2, accepted with a reason. No P0 or P1 |

## Inventory

| Abstraction | Call sites | Verdict |
|---|---|---|
| `Store` (src/store.zig) | every cache read, write, fill, and cull | **Keep.** Still the single owner: `cacheMetaPath`, `sidecarPieceSize`, `manifestPath`, `manifestsDirPath` are the only builders, and the CLI commands that skip FUSE call them rather than reconstructing joins |
| `Store.Cached` locks | hydrate, serve, cull, write-through | **Keep.** One documented order (`content_mu` then `file.mu`), stated at the definition, with `xfer` as the separate in-flight guard |
| `Catalog` (src/discover.zig) | leases, scoring, have cache | **Keep, watch.** Three concerns in one type, but they share the path list and the lease clock, and splitting them would duplicate that state. Closest thing to a bag in the tree |
| `rdma.Backend` (src/rdma.zig) | `serveStage`, `fetchPieceStaged` | **Keep.** Documented exception: one shipped implementation, but the seam carries live protocol on both sides (`/stage` negotiates, `X-Stage` advertises, the `/data` fallback is exercised today) |
| `peer.Server` (src/peer.zig) | serve and fetch | **Keep.** The two halves share the PSK, the Store pointer, the inflight counter, and the listen fds; `v0.7.0` added `adoptListenFd`/`detachListenFds` to that same shared fd state |
| `fuse_fs.State` (src/fuse_fs.zig) | the daemon composition root | **Keep.** Every field is reachable from a live path. `v0.7.0` added seven, all read by either the handover or the session setup |
| The ino/fh tables (src/fuse_fs.zig) | the whole FUSE namespace | **Keep, with a recorded cost.** See below |
| `handover.Knobs` / `Owned` (src/handover.zig) | one encode, one decode | **Keep.** One producer and one consumer is the right shape for a wire format; the arena in `Owned` is what makes the decode side leak-free |
| `fuzzcorpus` framing (src/fuzzcorpus.zig) | every fuzz seed | **Keep.** One shape, no private variants; it exists because `Smith.slice` would otherwise take a length prefix from the payload |
| `cull.Water` (src/cull.zig) | flag parse, cull loop | **Keep.** Carries the ordering invariant through `cull.ordered`, checked once at parse rather than at each call site |

## Finding

| # | Location | Verdict | Sev | Outcome |
|---|---|---|---|---|
| 1 | `State.nodes`, `State.paths`, `State.opens` | Three maps kept consistent by hand | P2 | **Accepted**, with tests as the mitigation |

### Three maps, one invariant

`v0.7.0` moved the daemon to libfuse's low-level API, so modelfs now owns the inode namespace.
That is three `HashMapUnmanaged`s under one mutex, with an invariant no type enforces:
`paths[nodes[ino].path] == ino` for every live node, except where a rename-over has deliberately
pointed a name at a different inode.

The guide asks whether one type would make the inconsistent state unrepresentable. It would, and
that is the honest reading of the finding. It is accepted anyway:

- The invariant has exactly three writers (`internPath`, `dropLookup`, `renameNodes`), all
  private to `fuse_fs.zig`, all holding `nodes_mu`, and all under 30 lines.
- The rename-over case means the invariant is not actually total, so a type enforcing it would
  need an escape hatch for exactly the case that makes it hard.
- `restoreMaps` has to rebuild all three from a flat snapshot anyway, so a richer type would add
  a conversion at the handover boundary without removing one.

What was missing was not a type but coverage: none of the three writers had a unit test. Six
tests now drive them, including both non-obvious cases (component-boundary prefix matching in
`renamedPath`, and `dropLookup` unmapping a name only while it still resolves to the node being
forgotten). Both were mutation-checked. See the [idiom review](ZIG_IDIOM_REVIEW.md).

Revisit if a fourth writer appears, or if the tables need to be read outside `fuse_fs.zig`.

## No second mechanisms found

The guide's most expensive finding class, a second mechanism for a job that already has one, is
absent. Checked specifically:

- **Path gating**: `store.relOk` and `discover.relIsCluster`, no third gate. `hf.parseTree`, new
  in `v0.7.0`, calls both rather than writing its own.
- **Cache-artifact paths**: `Store` only.
- **Clocks**: the injected `std.Io` through `sys.*`, no second one.
- **Syscalls**: `sys.zig`, after `randomToken`'s raw `getrandom` moved behind `sys.randomBytes`
  this pass.
