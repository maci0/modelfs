# Zig idiomatic review

| Field | Value |
|---|---|
| Guide | [zig-idiomatic-review.md](../review-guides/zig-idiomatic-review.md) |
| Scope | all of `src/`, with attention on the modules `v0.7.0` added or reshaped: `fuse_fs.zig`, `handover.zig`, `hf.zig`, `sys.zig` |
| Date | 2026-09-02, against `v0.7.0` (`f28e89b`) |
| Result | 2 P1, 1 P2. One P1 fixed, one P1 deferred with a reason |

## Findings

| # | Location | Idiom | Cost | Sev | Outcome |
|---|---|---|---|---|---|
| 1 | `src/fuse_fs.zig` inode and handle layer | Non-trivial logic with no unit test | The nine functions the FUSE namespace rests on were covered only by `scripts/test_hot_reload.sh`, which needs `/dev/fuse` and therefore never runs in CI | P1 | **Fixed** |
| 2 | `src/fuse_fs.zig:1946` `ll_read` | Heap allocation on the FUSE read path | One `gpa.alloc` per read, against the house rule that hydration and request parsing use stack or one reusable buffer | P1 | **Deferred**, see below |
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

### 2. `ll_read` allocates per FUSE read (deferred, not dismissed)

`ll_read` allocates a reply buffer sized by the kernel's ask, then frees it. The house rule is
no heap on the hot path.

Two facts bound how bad this is. libfuse's high-level `fuse_lib_read`, which this tree used
through `v0.6.0`, did the same `malloc` per read, so `v0.7.0` did not add an allocation that was
not already there. And the fill path underneath, which is where the real cost is, still uses the
one reusable piece-sized buffer.

It is still a finding, and the fix is not a ride-along. Removing the allocation means bounding
what the kernel may ask for, which means setting `conn.max_write` in `ll_init`, which changes
what INIT negotiates. INIT is now captured verbatim and replayed across `modelfs update`, so
changing the negotiated terms touches the handover contract and wants its own change with its
own e2e run. A thread-local buffer avoids that but costs the same bound anyway, since the buffer
must be at least as large as the largest request the kernel may send.

Recorded here rather than fixed inside a review pass.

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

`./scripts/check.sh` green, 352 tests (up from 346). `./scripts/test_hot_reload.sh` green: two
image swaps with an fd held open across both.
