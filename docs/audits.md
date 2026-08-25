# Audit history

| Field | Value |
|---|---|
| Status | Historical record. Current behavior is [architecture.md](architecture.md) |
| Covers | 2026-08-22 review passes; the 2026-08-23 and later passes are in [../CHANGELOG.md](../CHANGELOG.md) |

Six review passes were run against the guides in [review-guides/](review-guides/), one pass per guide. Every finding below was fixed and covered by a regression test in the same pass; the fixes are in the code, so this file is kept for the reasoning, not as a to-do list. Descriptions are as recorded at the time and some name APIs that later changed (`@cImport` in `src/c.zig` moved into `build.zig`'s `translateC` step; `nowSec`/`sleepMs` went from `std.time` to `std.os.linux`).

---

## Correctness and memory safety

| Location | Finding | Fix |
|---|---|---|
| `piece.zig` | Divide-by-zero panic when `piece_size == 0` in `count()`, `indexAt()`, `cover()` (corrupt metadata or a `0` flag) | Guard returning 0 |
| `piece.zig` | `file_off + n` and `last + 1` wrapped near `u64`/`u32` max; `@intCast` panicked past ~17.5 TB | Saturating arithmetic (`+|`, `-|`), `indexAt` saturates to `u32.max` |
| `proto.zig` | `parseSize()` wrapped on `n * 10 + digit` | Checked `std.math.mul`/`add`, `error.BadSize` |
| `main.zig` | `--piece 100G` overflowed the `@intCast` to `u32` | Explicit range check, `error.ValueTooLarge` |
| `fuse_fs.zig` | Null buffer pointer from FUSE dereferenced in `mf_read`/`mf_write` | `EFAULT` at callback entry |
| `fuse_fs.zig` | `mf_write` updated `file.size` before comparing against it, so the growth `ftruncate` was skipped | Capture `old_size` under `file.mu` |
| `store.zig` | `Store.get()` mutated `f.bits`/`f.size` without `f.mu`: data race on concurrent resize | Lock across resize |
| `store.zig` | `walkData()` used `<` on path length, skipping 4096-byte paths, and moved `best_at` without `best_rel` | `<=`, and both updated together |
| `store.zig` | New cache files in `openCacheUnlocked` skipped `ftruncate` | Unified with `openCache` |
| `peer.zig` | `readBodyAlloc()` double-freed on an HTTP error status | Single `errdefer acc.deinit(gpa)` |
| `peer.zig` | `Server.stop()` used `clearRetainingCapacity()`, leaking the fd list | `deinit(gpa)` |
| `peer.zig` | A `/data` Range request for e.g. 10 GB tried to allocate it | 64 MiB cap, `HTTP 416` above it |
| `peer.zig`, `discover.zig` | Request buffers too small for URL-encoded paths; `Catalog.publish()` had no bound on its `.json.tmp` name | Buffers at `PATH_MAX * 3 + 512`, explicit bounds check |
| `main.zig` | CLI argument strings leaked on early exit from `cmdMount()` | `defer gpa.free(...)` per allocation |

## Performance

| Location | Finding | Fix |
|---|---|---|
| `peer.zig` | `serveData()` copied each piece through a user-space buffer | `sendfileAll()` in `sys.zig`: NVMe page cache straight to the socket |
| `peer.zig` | `readHead()` read HTTP headers one byte at a time, ~200 syscalls per request | Block-buffered read, typically one syscall |
| `peer.zig`, `sys.zig` | Peer sockets left at kernel defaults | `TCP_NODELAY` plus 2 MiB `SO_RCVBUF`/`SO_SNDBUF` |
| `peer.zig` | `readBodyAlloc()` read bodies in 16 KiB chunks | 64 KiB, 4x fewer loop iterations on piece payloads |
| `piece.zig` | `Bitfield.filled()` counted bit by bit | `u64` words via hardware `@popCount` |
| `piece.zig` | `Bitfield.lastSet()` walked backwards bit by bit | Byte-level reverse scan |
| `discover.zig` | `Catalog.refresh()` heap-allocated per lease | Stack-buffered `sys.readFileBuf()` |
| `main.zig` | `writeStatus()` allocated to format status output | `std.fmt.bufPrint` into a stack buffer |

## Zig 0.16 conformance

`build.zig` gave the executable module its FUSE include path and library but not `test_mod`, so FUSE callbacks would not compile under `root.zig`; both are configured now. Beyond that the pass replaced libc calls with standard-library equivalents (`std.os.linux.clock_gettime`, `std.os.linux.nanosleep`, `std.posix.gethostname`, `std.posix` socket calls, `std.crypto.timing_safe.eql` for bearer comparison) and moved hand-rolled JSON formatting in `proto.zig` and `main.zig` onto `std.Io.Writer.fixed`.

## Fault tolerance coverage added

* `peer.zig` unit tests: a wrong bearer token gets `HTTP 401` and `error.HttpStatus` with no double free; dialing a dead peer fails fast with `error.Connect` so the read falls back to the origin.
* [`scripts/run_cluster_e2e_9nodes.sh`](../scripts/run_cluster_e2e_9nodes.sh): one origin plus nine instances, exercising heartbeats, lease discovery, piece exchange between instances, and partial caching under tight disk watermarks.
* [`scripts/test_fault_tolerance.sh`](../scripts/test_fault_tolerance.sh): unauthenticated requests rejected, stale leases (`until < now`) filtered out, node drop-out handled.

## State at the end of the passes

31 unit tests passing with zero leaks under `DebugAllocator`, and all three integration suites green.
