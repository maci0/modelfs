# Zig idiomatic review

| Field | Value |
|---|---|
| Guide | [zig-idiomatic-review.md](../review-guides/zig-idiomatic-review.md) |
| Scope | all of `src/`, with attention on the modules `v0.7.0` added or reshaped: `fuse_fs.zig`, `handover.zig`, `hf.zig`, `sys.zig` |
| Date | 2026-09-02, against `v0.7.0` (`f28e89b`) |
| Result | 2 P1, 1 P2, all fixed. Follow-up pass on 2026-09-03 closed the deferred one |

## Findings

| # | Location | Idiom | Cost | Sev | Outcome |
|---|---|---|---|---|---|
| 1 | `src/fuse_fs.zig` inode and handle layer | Non-trivial logic with no unit test | The nine functions the FUSE namespace rests on were covered only by `scripts/test_hot_reload.sh`, which needs `/dev/fuse` and therefore never runs in CI | P1 | **Fixed** |
| 2 | `src/fuse_fs.zig` `ll_read` | Heap allocation on the FUSE read path | One `gpa.alloc` per read, against the house rule that hydration and request parsing use stack or one reusable buffer | P1 | **Fixed** 2026-09-03 |
| 3 | `src/handover.zig` `randomToken` | Swallowed failure substituting a derivable value | A `getrandom` failure fell back to a pid-derived token | P2 | **Fixed** |

### 1. The inode and handle layer had no unit tests (fixed)

`v0.7.0` moved the daemon to libfuse's low-level API, which means modelfs now owns the ino to
path table, the lookup reference counts, and the fh to path table. Nine functions carry that:
`childPath`, `internPath`, `dropLookup`, `pathForIno`, `pathForFh`, `rememberOpen`,
`forgetOpen`, `renamedPath`, and `renameNodes`.

None had a unit test. The only coverage was the end-to-end harness, which needs `/dev/fuse` and
`fusermount3` and so runs locally rather than in CI: a regression here would reach a tag.

The logic is not trivial. `renamedPath` must match a prefix only on a component boundary, or
`/ab` moves when `/a` does. `dropLookup` must unmap a name only while it still resolves to the
node being forgotten, or forgetting a node displaced by a rename-over unmaps the winner's name
and leaves a dangling key in `paths`. Inode numbers must never be reused. `restoreMaps` must
resume both counters, or a post-handover lookup collides with an inode the kernel already holds.

Six tests added, driving the real functions against a `State` fixture holding only the fields
the tables touch. Both non-obvious invariants were mutation-checked: removing the
component-boundary test in `renamedPath` and removing the ownership guard in `dropLookup` each
fail the suite.

### 2. `ll_read` allocated per FUSE read (fixed 2026-09-03)

`ll_read` allocated a reply buffer sized by the kernel's ask, then freed it, once per read. The
house rule is no heap on the hot path.

The first pass deferred this because the obvious fix, bounding `conn.max_write` in `ll_init`,
changes what INIT negotiates, and INIT is captured verbatim and replayed across `modelfs update`.
Measuring first showed that was the wrong fix anyway.

**Measured** what the kernel actually asks for, with a temporary instrument on `ll_read` and
`-Doptimize=Debug` builds against a live mount:

| Mode | Request sizes observed |
|---|---|
| `direct_io` (default), `dd bs=1M` and `bs=4M` | 1048576, every time, 32 of 32 reads |
| `--kernel-cache`, `dd bs=8M` and `cat` | 262144 (130 reads), 524288 (10), 339968 (2) |

1 MiB is the ceiling in both modes by construction: it is `max_pages * PAGE_SIZE`, and libfuse
caps `max_pages` from a `bufsize` of 256 pages. So a fixed 1 MiB buffer never forces a short
reply, which on the page-cache path the kernel would read as a hole.

The fix is a pool rather than a smaller negotiation: `claimReadBuf` hands out one of
`read_slots` (16, mirroring `peer.Server.max_inflight`) slot buffers, claimed with an atomic
`fetchOr` on a bitmask so the owner can fill its slot lazily without a race. An idle mount holds
no buffers, a single reader holds one, and a burst past the last slot falls back to the
allocator rather than blocking a reader or replying short. INIT negotiation is untouched, so the
handover contract is untouched.

The ENOMEM branch that the [peer transfer review](PEER_TRANSFER_REVIEW.md) recorded as moving no
counter now increments `reads_err`.

Verified on a live mount: 200 MB warm read at 3.4 GB/s with `cmp` against the origin clean, and
`scripts/test_hot_reload.sh` green across two image swaps.

### 3. `randomToken` fell back to a pid-derived value (fixed)

On a `getrandom` failure the token was filled from the pid, which is readable from `/proc`. The
token matches one `update.req` to its `update.ack`; a derivable one lets a same-uid racer ack an
update it did not request.

`std.crypto.random` and `std.posix.getrandom` are both gone in 0.16, so the raw syscall is the
available primitive. It now lives behind `sys.randomBytes` with EINTR retry and short-read
looping, and `randomToken` returns an error instead of substituting anything. `cmdUpdate` names
the failure and exits 1.

## Not findings

- **`sys.*` returning `-errno` instead of error unions.** The sanctioned layer shape: FUSE
  handlers return `-errno` to the kernel, so an error set would be translated back at every
  call site.
- **`readdirResume(names: anytype, emit: anytype, ...)`.** The seam that makes the readdir
  resume contract drivable without a mount. Earning its keep.
- **`std.time.ns_per_us` and `ns_per_ms` in `logStatsTick`.** Unit constants, not a clock. The
  rule is about a second time source, and `sys.monoNs`/`sys.nowSec` remain the only ones.
- **`rememberOpen` and `internPath` allocating.** Once per open and once per newly seen name,
  not per read. Not the hot path.
- **`hf.pull`'s per-file `.part` buffer.** Allocated once outside the loop and reused across
  every file in a revision.

## After

`./scripts/check.sh` green, 353 tests (up from 346 before the pass). `./scripts/ci.sh` green,
all three jobs. `./scripts/test_hot_reload.sh` green: two image swaps with an fd held open
across both, and a 200 MB read through the pool byte-identical to the origin.
