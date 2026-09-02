# SIMD opportunity review

| Field | Value |
|---|---|
| Guide | [simd-review.md](../review-guides/simd-review.md) |
| Scope | dense byte and numeric loops in `src/` |
| Date | 2026-09-02, against `v0.7.0` (`f28e89b`) |
| Optimize mode | none measured, because nothing survived to the measurement stage |
| Result | **Nothing shipped. Every candidate rejected**, which is the expected outcome for this tree |

modelfs is I/O bound by construction. A warm read is an NVMe `pread`; a peer serve is `sendfile`
from the page cache straight to the socket, so the bytes never enter user space at all; a miss
is an NFS round trip. The only sustained CPU work on a live path is blake3 over 16 MiB pieces,
and that is `std.crypto`.

## Candidates and verdicts

| Site | Shape | Verdict |
|---|---|---|
| `Bitfield.filled` (src/piece.zig:225) | population count over the bitfield | **Already vectorized.** `@popCount` over `u64` words with a byte tail. Widening to `@Vector` would move a KiB-scale loop |
| `Bitfield.lastSet` (src/piece.zig:251) | reverse scan for the top set bit | **Already vectorized.** Word-at-a-time backward scan with `@clz` |
| `piece.digest` (src/piece.zig:340) | blake3 over one piece | **Use the stdlib.** `std.crypto.hash.Blake3` is already vectorized, and hand-rolling a hash on the path that decides whether peer bytes are admitted would be a correctness and security regression, not an optimization |
| `containsControl` (src/proto.zig:202) | byte classification over a path | **Input too short.** Bounded by path length and called once per request; per-call fixed cost dominates |
| `decodePath` (src/peer.zig:545) | percent-decode a request target | **Input too short.** Same bound, same reason |
| `Bitfield.encode`/`decode` (src/piece.zig:302) | pack and unpack the sidecar | **Not on a live path.** Once per entry load and save |
| `manifestOverlap` / `digestSorted` (src/piece.zig) | compare and sort per-piece digest arrays | **Plausible, unmeasured.** The one site whose element count scales with the store rather than one request, through `dupes --all`. Still a CLI path, not a serve path. Reported, not shipped |
| `serveData` / `streamRange` (src/peer.zig:878) | `sendfile` | **Reject by construction.** The bytes are moved by the kernel. Adding a user-space vector pass here would undo the zero-copy design the benchmarks measure |

## The one thing worth measuring later

`manifestOverlapPrepared` is the only loop in the tree whose work grows with the size of the
store instead of the size of one request: `modelfs dupes --all` walks every manifest under
`.cluster/manifests/` and compares digest arrays pairwise.

It is not shipped because there is no baseline. Per the guide, a projected speedup without a
`-Doptimize=ReleaseFast` measurement on representative input is not a finding. Anyone picking
this up needs a store with enough manifests to measure, `scripts/run_benchmarks_and_plots.py`'s
methodology for keeping both sides of the comparison identical, and a scalar golden across a
size sweep including the empty, one-element, exactly-one-vector, and one-past-a-vector cases.

Its share of any real profile is likely small: `dupes --all` is an operator command run to
decide whether duplicate models are worth engineering for, not something in a serving loop.
