# Zig 0.16 changelog conformance review

| Field | Value |
|---|---|
| Guide | [zig-0.16-changelog-review.md](../review-guides/zig-0.16-changelog-review.md) |
| Scope | `src/`, `build.zig`, `build.zig.zon` against the Zig 0.16.0 release notes |
| Pinned toolchain | `minimum_zig_version = "0.16.0"` |
| Date | 2026-09-02, against `v0.7.0` (`f28e89b`) |
| Result | 1 P2, deferred as its own scoped change. No P0 or P1 |

## Findings

| # | Changelog item | Status | Sev | Outcome |
|---|---|---|---|---|
| 1 | `mem: rename "index of" to "find"` | Both spellings live side by side | P2 | **Deferred** |

### 1. `std.mem.find*` and `std.mem.indexOf*` are both in use

Measured 2026-09-02 across `src/`:

| Spelling | Call sites | Where the bulk sits |
|---|---|---|
| `std.mem.find*` (0.16) | 31 | `peer.zig` 16, `proto.zig` 8 |
| `std.mem.indexOf*` / `lastIndexOf*` | 111 | `main.zig` 57, `peer.zig` 19, `proto.zig` 21 |

Both families exist in the 0.16 stdlib and behave identically, so this compiles and cannot
diverge: it is readability, not a defect. That is also why it is not fixed here. A tree-wide
rename touches 111 call sites across nine files, well past the guide's 200-line single-file
budget, and mixing it into another finding's diff would bury both. It wants one scoped change
with `./scripts/check.sh` run against it alone.

Worth noting the drift is getting worse rather than better: the modules `v0.7.0` added
(`handover.zig`, `hf.zig`) use the old spelling in three of their four call sites, because the
surrounding code does.

## Checked and clean

| Changelog section | Finding |
|---|---|
| **Time** | No `std.time` clock call anywhere in `src/`. The six `std.time.*` hits in `logStatsTick` are `ns_per_us`/`ns_per_ms` unit constants. Time comes from the injected `std.Io` through `sys.monoNs`, `sys.nowSec`, `sys.monoSec`, `sys.sleepMs` |
| **I/O as an interface** | `std.Io.Writer.Allocating` and `std.Io.Writer.fixed` are used where 0.15 would have reached for a stream; `hf.zig` streams a multi-gigabyte body through `std.Io.File.Writer` rather than buffering it |
| **posix removals** | No new stray. The documented exceptions still hold: `std.posix.kill(pid, 0)` in `pidAlive`, `std.posix.setrlimit` in `disableCoreDumps`, and test-block `utimensat` mtime pins. `handover.zig`'s raw `getrandom` was the one new stray and is fixed (see the practices review) |
| **Unmanaged containers** | No managed container. Every `std.ArrayList(T)` is `.empty` with `gpa` passed to `append`/`deinit`; `AutoHashMapUnmanaged`/`StringHashMapUnmanaged` throughout, including the three tables `v0.7.0` added |
| **Threading** | No `std.Thread.Pool`. Long-lived workers register in `State.workers` for join; per-request threads stay under `Server.max_inflight` |
| **Process, env, args** | `main` takes `std.process.Init`; the environment threads through `init.environ_map` into `parseArgs`. No global environ or argv read. `hf.loadToken` takes the map as a parameter rather than reaching for a global |
| **Formatting** | No `{D}`. Specifiers are 0.16-current: `{t}` for error and enum names, `{f}`, `{d}`, `{x}`, `{s}` |
| **Build system** | `src/c.h` translated once through `translateC`; no `@cImport` in `src/`. Executable and test modules both receive the include path, library, and options, which is the historical defect docs/audits.md records |
| **Language** | No `usingnamespace`, no pre-0.16 `callconv` spellings. `callconv(.c)` on the FUSE and custom-io callbacks is current |

One thing this review confirmed the hard way, and which is now recorded in the guide so the next
pass does not repeat it: **`std.crypto.random` and `std.posix.getrandom` were both removed in
0.16.** A fix that reached for either would not compile, which is why the syscall behind
`sys.randomBytes` is the correct answer rather than a policy violation to be designed away.
