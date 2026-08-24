//! libfuse operation handlers: path resolution policy, read hydration,
//! write-through cache fill, and the background discovery/cull loops.
const std = @import("std");
const fuse = @import("c.zig").c;
const piece = @import("piece.zig");
const sys = @import("sys.zig");
const store_mod = @import("store.zig");
const discover = @import("discover.zig");
const peer = @import("peer.zig");
const cull = @import("cull.zig");

/// Daemon liveness artifact in the cache dir; `modelfs status` reads it.
pub const status_file = "status.json";

pub const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    store: store_mod.Store,
    catalog: discover.Catalog,
    server: peer.Server,
    psk: []const u8,
    direct_io: bool,
    running: std.atomic.Value(bool) = .init(true),
    /// Background workers, spawned by mf_init: libfuse daemonizes with fork()
    /// before init runs, and fork keeps only the calling thread, so anything
    /// spawned earlier dies with the parent and a detached mount would
    /// silently lose its peer server, discovery, and culling.
    workers: std.ArrayList(std.Thread) = .empty,

    pub fn spawnWorkers(self: *State) void {
        // Reserve before spawning: an append failure after a spawn used to
        // detach that worker beyond the workers-list joins, letting it run
        // unsupervised against State after teardown's drain gave up waiting.
        self.workers.ensureTotalCapacity(self.gpa, 3) catch {
            std.log.err("cannot allocate worker registry; peer http, discovery, and culling disabled", .{});
            return;
        };
        self.spawnWorker(peer.Server.serve, .{&self.server}, "peer http");
        self.spawnWorker(discLoop, .{self}, "discovery");
        self.spawnWorker(cullLoop, .{self}, "cull");
    }

    fn spawnWorker(self: *State, comptime f: anytype, args: anytype, what: []const u8) void {
        const t = std.Thread.spawn(.{}, f, args) catch |err| {
            // Degrade to serving through the origin only, but name the loss.
            std.log.err("spawn {s} thread: {t}", .{ what, err });
            return;
        };
        // Capacity was reserved for every worker up front, so this cannot
        // fail and strand a spawned thread detached from shutdown joins.
        self.workers.appendAssumeCapacity(t);
    }
};

fn statePtr() *State {
    return @ptrCast(@alignCast(fuse.fuse_get_context().*.private_data));
}

fn cPath(p: [*c]const u8) []const u8 {
    if (p == null) return "";
    return std.mem.span(p);
}

/// "" and "/" name the mount root itself; everything else must be a clean
/// relative path once the leading slash is stripped.
fn fuseRelOk(path: []const u8) bool {
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return true;
    const rel = if (path[0] == '/') path[1..] else path;
    return store_mod.relOk(rel);
}

fn relFromFuse(path: []const u8) ?[]const u8 {
    if (!fuseRelOk(path)) return null;
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return "";
    if (path[0] == '/') return path[1..];
    return path;
}

fn isCluster(path: []const u8) bool {
    return std.mem.eql(u8, path, "/" ++ discover.cluster_dir) or
        std.mem.startsWith(u8, path, "/" ++ discover.cluster_dir ++ "/");
}

/// One path policy for every handler: cluster control files are invisible
/// (ENOENT for lookup-shaped ops, EPERM for mutation-shaped ops), traversal
/// or absolute paths get EPERM. Returns 0 with rel set, else the errno.
/// Every op must go through here; handlers that skipped the cluster check
/// let truncate/chmod/read reach the lease files create/unlink already deny.
fn resolveRel(p: []const u8, cluster_rc: c_int, rel: *[]const u8) c_int {
    if (isCluster(p)) return cluster_rc;
    rel.* = relFromFuse(p) orelse return -sys.c.EPERM;
    return 0;
}

test "resolveRel denies cluster and traversal paths" {
    var rel: []const u8 = "";
    try std.testing.expectEqual(@as(c_int, -sys.c.ENOENT), resolveRel("/.cluster", -sys.c.ENOENT, &rel));
    try std.testing.expectEqual(@as(c_int, -sys.c.ENOENT), resolveRel("/.cluster/spark1.json", -sys.c.ENOENT, &rel));
    try std.testing.expectEqual(@as(c_int, 0), resolveRel("/gguf/a.gguf", -sys.c.ENOENT, &rel));
    try std.testing.expectEqualStrings("gguf/a.gguf", rel);
    try std.testing.expectEqual(@as(c_int, -sys.c.EPERM), resolveRel("/../etc", -sys.c.ENOENT, &rel));
}

test "relFromFuse rejects .." {
    try std.testing.expectEqualStrings("gguf/a.gguf", relFromFuse("/gguf/a.gguf").?);
    try std.testing.expect(relFromFuse("/../etc/passwd") == null);
    try std.testing.expectEqualStrings("", relFromFuse("/").?);
    try std.testing.expect(isCluster("/.cluster/spark1.json"));
    try std.testing.expect(!isCluster("/gguf/a.gguf"));
}

export fn mf_getattr(path: [*c]const u8, stbuf: ?*fuse.struct_stat, fi: ?*fuse.fuse_file_info) callconv(.c) c_int {
    _ = fi;
    const st = statePtr();
    const p = cPath(path);
    var rel: []const u8 = "";
    const rerr = resolveRel(p, -sys.c.ENOENT, &rel);
    if (rerr != 0) return rerr;
    var ost: sys.c.struct_stat = undefined;
    const rc = st.store.statOrigin(rel, &ost);
    if (rc != 0) return rc;
    // Same translated C type; a whole-struct assign keeps every stat field.
    if (stbuf) |out| out.* = ost;
    return 0;
}

fn cachedFor(st: *State, rel: []const u8) ?*store_mod.Store.Cached {
    var ost: sys.c.struct_stat = undefined;
    if (st.store.statOrigin(rel, &ost) != 0) return null;
    if ((ost.st_mode & sys.c.S_IFMT) != sys.c.S_IFREG) return null;
    return st.store.get(rel, @intCast(ost.st_size)) catch null;
}

export fn mf_open(path: [*c]const u8, fi: ?*fuse.fuse_file_info) callconv(.c) c_int {
    _ = fi;
    const st = statePtr();
    const p = cPath(path);
    var rel: []const u8 = "";
    const rerr = resolveRel(p, -sys.c.ENOENT, &rel);
    if (rerr != 0) return rerr;
    var ost: sys.c.struct_stat = undefined;
    // Return the captured errno, like getattr/read do: re-reading errno here
    // would report whatever ran between the failed stat and this return.
    const src = st.store.statOrigin(rel, &ost);
    if (src != 0) return src;
    if ((ost.st_mode & sys.c.S_IFMT) == sys.c.S_IFREG) {
        const file = st.store.get(rel, @intCast(ost.st_size)) catch return -sys.c.ENOMEM;
        defer st.store.releaseFile(file);
        const fd = st.store.openCache(file);
        if (fd < 0) return fd;
    }
    return 0;
}

export fn mf_create(path: [*c]const u8, mode: fuse.mode_t, fi: ?*fuse.fuse_file_info) callconv(.c) c_int {
    _ = fi;
    const st = statePtr();
    const p = cPath(path);
    var rel: []const u8 = "";
    const rerr = resolveRel(p, -sys.c.EPERM, &rel);
    if (rerr != 0) return rerr;
    var buf: [sys.c.PATH_MAX]u8 = undefined;
    const op = st.store.originPath(&buf, rel) catch return -sys.c.ENAMETOOLONG;
    const fd = sys.open(op, sys.c.O_CREAT | sys.c.O_RDWR | sys.c.O_TRUNC, mode);
    if (fd < 0) return sys.negErrno();
    sys.close(fd);
    // The origin create above already landed: failing the syscall here (entry
    // warmup OOM) would tell the caller the create failed over a file that
    // exists and was possibly truncated. Warmup is best-effort; the next
    // open/read rebuilds the entry.
    if (st.store.get(rel, 0)) |file| {
        st.store.releaseFile(file);
    } else |_| {
        std.log.warn("cache entry warmup failed for {s}; rebuilding on next open", .{rel});
    }
    return 0;
}

fn hydratePiece(st: *State, file: *store_mod.Store.Cached, idx: u32, scratch: []u8) i32 {
    // piece.len() never exceeds piece_size, even when a concurrent append
    // grows the tail piece after cover() was computed, so the caller's
    // piece-size scratch always fits. An allocation failure claiming the
    // piece must fail this read with ENOMEM rather than hang: beginFill
    // surfaces claim OOM instead of retrying it forever.
    const cl = st.store.beginFill(file, idx) catch return -sys.c.ENOMEM;
    const ln = switch (cl) {
        // Filled by someone else, or a truncate shrank the file below the
        // piece between claim and sample (the claim was dropped unmarked):
        // report success either way -- the bounds-checked read below then
        // returns a short count against the new size. Passing an empty
        // buffer onward would underflow fillFromPeers' range end computation
        // (out.len - 1) and abort the daemon.
        .filled, .raced => return 0,
        .len => |n| n,
    };
    const buf = scratch[0..ln];
    var from_peer = true;
    peer.fillFromPeers(st.gpa, st.psk, &st.catalog, file.rel, idx, st.store.piece_size, buf) catch {
        from_peer = false;
        const n = st.store.originPread(file.rel, buf, piece.offset(idx, st.store.piece_size));
        if (n != @as(isize, @intCast(ln))) {
            st.store.finishPiece(file, idx, false);
            if (n < 0) return @intCast(n);
            return -sys.c.EIO;
        }
    };
    std.log.info("piece {d} {s} {s}", .{ idx, file.rel, if (from_peer) "peer" else "nfs" });
    return st.store.completeFill(file, idx, buf);
}

/// fsize must be a size sample taken under file.mu by the caller (the same
/// sample that bounded n): cover() then agrees with the bounds check instead
/// of racing a concurrent truncate on an unlocked file.size read.
fn ensureRange(st: *State, file: *store_mod.Store.Cached, fsize: u64, off: u64, n: u64) i32 {
    const cov = piece.cover(off, n, fsize, st.store.piece_size);
    if (cov.start >= cov.end) return 0;
    // One reusable buffer for every hydrated piece in the range, allocated
    // only when some covered piece actually lacks its bit: warm reads (every
    // piece cached) previously paid a piece-sized alloc/free per call.
    var scratch: ?[]u8 = null;
    defer if (scratch) |s| st.gpa.free(s);
    var i = cov.start;
    while (i < cov.end) : (i += 1) {
        if (st.store.hasPiece(file, i)) continue;
        if (scratch == null)
            scratch = st.gpa.alloc(u8, st.store.piece_size) catch return -sys.c.ENOMEM;
        const rc = hydratePiece(st, file, i, scratch.?);
        if (rc != 0) return rc;
    }
    return 0;
}

export fn mf_read(path: [*c]const u8, buf: [*c]u8, size: usize, off: fuse.off_t, fi: ?*fuse.fuse_file_info) callconv(.c) c_int {
    _ = fi;
    if (buf == null) return -sys.c.EFAULT;
    const st = statePtr();
    var rel: []const u8 = "";
    const rerr = resolveRel(cPath(path), -sys.c.ENOENT, &rel);
    if (rerr != 0) return rerr;
    // Report the real origin failure (EIO on NFS, ENOENT, ...): collapsing it
    // into EISDIR would send readers hunting for a directory that is not there.
    var ost: sys.c.struct_stat = undefined;
    const src = st.store.statOrigin(rel, &ost);
    if (src != 0) return src;
    if ((ost.st_mode & sys.c.S_IFMT) != sys.c.S_IFREG) return -sys.c.EISDIR;
    const file = st.store.get(rel, @intCast(ost.st_size)) catch return -sys.c.ENOMEM;
    defer st.store.releaseFile(file);
    const want = @min(size, @as(usize, std.math.maxInt(c_int)));
    if (off < 0) return -sys.c.EINVAL;
    const uoff: u64 = @intCast(off);
    // One size sample under file.mu: truncate/reconcileSize shrink it
    // concurrently, and reading it twice unlocked can pass the bounds check
    // on the old value then underflow the subtraction on the new one.
    file.mu.lockUncancelable(st.io);
    const fsize = file.size;
    // A warm read touches no other state until readCache stamps at the end:
    // without a stamp here, a cull punch (idle past the window, all gates
    // green) could land between ensureRange's bit checks and the read and
    // serve hole zeros behind bits this call already trusted.
    file.last_access.store(sys.monoSec(), .monotonic);
    file.mu.unlock(st.io);
    if (uoff >= fsize) return 0;
    const n = @min(want, @as(usize, @intCast(fsize - uoff)));
    const rc = ensureRange(st, file, fsize, uoff, n);
    if (rc != 0) return rc;
    const got = st.store.readCache(file, buf[0..n], uoff);
    return @intCast(got);
}

export fn mf_write(path: [*c]const u8, buf: [*c]const u8, size: usize, off: fuse.off_t, fi: ?*fuse.fuse_file_info) callconv(.c) c_int {
    _ = fi;
    if (buf == null) return -sys.c.EFAULT;
    const st = statePtr();
    var rel: []const u8 = "";
    // Lookup-shaped denial: open on /.cluster already fails with ENOENT, so
    // write must agree instead of leaking that the control dir exists.
    const rerr = resolveRel(cPath(path), -sys.c.ENOENT, &rel);
    if (rerr != 0) return rerr;
    const want = @min(size, @as(usize, std.math.maxInt(c_int)));
    if (off < 0) return -sys.c.EINVAL;
    const uoff: u64 = @intCast(off);
    const n = st.store.originPwrite(rel, buf[0..want], uoff);
    if (n < 0) return @intCast(n);
    const end = uoff + @as(u64, @intCast(n));

    // Cache fill. Statting through get() after every write would trip
    // reconcileSize's wipe-on-size-change reset: an append is our own work,
    // but it changes the origin size exactly like an external rewrite, so a
    // sequential ingest would discard every earlier chunk's cached pieces.
    // When the observed size matches what we just wrote, fill through
    // cacheFill (marks preserved); any divergence keeps the conservative
    // reset below.
    var ost: sys.c.struct_stat = undefined;
    if (st.store.statOrigin(rel, &ost) == 0 and
        (ost.st_mode & sys.c.S_IFMT) == sys.c.S_IFREG and
        @as(u64, @intCast(ost.st_size)) == end)
    {
        st.store.cacheFill(rel, end, uoff, buf[0..@intCast(n)]);
        return @intCast(n);
    }
    if (cachedFor(st, rel)) |file| {
        defer st.store.releaseFile(file);
        file.mu.lockUncancelable(st.io);
        const old_size = file.size;
        if (end > old_size) {
            // NFS attribute lag can report the pre-write size; grow the
            // bitfield alongside so appended pieces stay markable.
            file.bits.resize(st.gpa, piece.count(end, st.store.piece_size)) catch {
                // Same policy as cacheFill's grow: undersized field means
                // appended pieces stay unmarked and re-hydrate.
                std.log.warn("bitfield grow failed for {s}; appended pieces refill", .{rel});
            };
            file.size = end;
        }
        file.last_access.store(sys.monoSec(), .monotonic);
        file.mu.unlock(st.io);
        // The origin write already succeeded, so a failed cache copy only
        // costs re-hydration; the helper logs it and skips piece marking.
        _ = st.store.copyIntoCache(file, uoff, buf[0..@intCast(n)], if (end > old_size) end else null);
        return @intCast(n);
    }
    // Neither size observation landed: the entry's bits can no longer be
    // proven to describe this inode's post-write contents, so drop them
    // instead of silently serving pre-write bytes as current. The write
    // itself already succeeded, so the syscall still reports n.
    std.log.warn("post-write stat failed for {s}; cache marks dropped, pieces refill", .{rel});
    st.store.distrust(rel);
    return @intCast(n);
}

export fn mf_truncate(path: [*c]const u8, size: fuse.off_t, fi: ?*fuse.fuse_file_info) callconv(.c) c_int {
    _ = fi;
    const st = statePtr();
    var rel: []const u8 = "";
    // Mutation-shaped denial: without this, ftruncate through the mount
    // could clobber lease files that create/unlink already protect.
    const rerr = resolveRel(cPath(path), -sys.c.EPERM, &rel);
    if (rerr != 0) return rerr;
    if (size < 0) return -sys.c.EINVAL;
    const new_size: u64 = @intCast(size);
    var buf: [sys.c.PATH_MAX]u8 = undefined;
    const op = st.store.originPath(&buf, rel) catch return -sys.c.ENAMETOOLONG;
    const fd = sys.open(op, sys.c.O_WRONLY, 0);
    if (fd < 0) return sys.negErrno();
    defer sys.close(fd);
    if (sys.ftruncate(fd, new_size) != 0) return sys.negErrno();
    // Map lookup must take store.mu; lookupRef also pins the entry against
    // eviction for the duration of the truncate.
    const live = st.store.lookupRef(rel);
    if (live) |file| {
        defer st.store.releaseFile(file);
        file.mu.lockUncancelable(st.io);
        const nb = piece.Bitfield.init(st.gpa, piece.count(new_size, st.store.piece_size)) catch {
            file.mu.unlock(st.io);
            return -sys.c.ENOMEM;
        };
        var ob = file.bits;
        file.size = new_size;
        file.bits = nb;
        // Save while the new bits are still under the lock: saveBits encodes
        // size/bits and must never race the swap below (or another thread's
        // encode) on freed storage. The fd truncate shares this window so
        // cache_fd cannot be closed between check and use. Best-effort save:
        // a lost sidecar here only costs refill, never stale bytes.
        _ = st.store.saveBits(file, false);
        if (file.cache_fd >= 0) _ = sys.ftruncate(file.cache_fd, new_size);
        file.mu.unlock(st.io);
        ob.deinit(st.gpa);
    }
    return 0;
}

export fn mf_unlink(path: [*c]const u8) callconv(.c) c_int {
    const st = statePtr();
    const p = cPath(path);
    var rel: []const u8 = "";
    const rerr = resolveRel(p, -sys.c.EPERM, &rel);
    if (rerr != 0) return rerr;
    var buf: [sys.c.PATH_MAX]u8 = undefined;
    const op = st.store.originPath(&buf, rel) catch return -sys.c.ENAMETOOLONG;
    if (std.c.unlink(op) != 0) return sys.negErrno();
    // Cache artifacts keyed to this rel must not outlive it, or a same-size
    // recreate would resurrect stale bits over fresh empty data. forget also
    // empties the live in-memory entry (bits + open fd), which disk cleanup
    // alone leaves pointing at the old inode.
    st.store.forget(rel);
    return 0;
}

export fn mf_mkdir(path: [*c]const u8, mode: fuse.mode_t) callconv(.c) c_int {
    const st = statePtr();
    const p = cPath(path);
    var rel: []const u8 = "";
    const rerr = resolveRel(p, -sys.c.EPERM, &rel);
    if (rerr != 0) return rerr;
    var buf: [sys.c.PATH_MAX]u8 = undefined;
    const op = st.store.originPath(&buf, rel) catch return -sys.c.ENAMETOOLONG;
    if (std.c.mkdir(op, mode) != 0) return sys.negErrno();
    return 0;
}

export fn mf_rmdir(path: [*c]const u8) callconv(.c) c_int {
    const st = statePtr();
    const p = cPath(path);
    var rel: []const u8 = "";
    const rerr = resolveRel(p, -sys.c.EPERM, &rel);
    if (rerr != 0) return rerr;
    var buf: [sys.c.PATH_MAX]u8 = undefined;
    const op = st.store.originPath(&buf, rel) catch return -sys.c.ENAMETOOLONG;
    if (std.c.rmdir(op) != 0) return sys.negErrno();
    return 0;
}

export fn mf_rename(old: [*c]const u8, new: [*c]const u8, flags: c_uint) callconv(.c) c_int {
    _ = flags;
    const st = statePtr();
    var orel: []const u8 = "";
    var nrel: []const u8 = "";
    const oerr = resolveRel(cPath(old), -sys.c.EPERM, &orel);
    if (oerr != 0) return oerr;
    const nerr = resolveRel(cPath(new), -sys.c.EPERM, &nrel);
    if (nerr != 0) return nerr;
    var a: [sys.c.PATH_MAX]u8 = undefined;
    var b: [sys.c.PATH_MAX]u8 = undefined;
    const oa = st.store.originPath(&a, orel) catch return -sys.c.ENAMETOOLONG;
    const ob = st.store.originPath(&b, nrel) catch return -sys.c.ENAMETOOLONG;
    if (std.c.rename(oa, ob) != 0) return sys.negErrno();
    // Both names lose their cache identity with this rename: the source name
    // no longer exists on the origin, and the destination name now holds the
    // source's bytes in place of whatever its bits describe. Purge both like
    // unlink does, or a same-size recreate at either name would serve the
    // previous content through resurrected bits.
    if (!std.mem.eql(u8, orel, nrel)) {
        st.store.forget(orel);
        st.store.forget(nrel);
    }
    return 0;
}

export fn mf_chmod(path: [*c]const u8, mode: fuse.mode_t, fi: ?*fuse.fuse_file_info) callconv(.c) c_int {
    _ = fi;
    const st = statePtr();
    var rel: []const u8 = "";
    // Mutation-shaped denial: chmod on lease files was reachable here even
    // though create/unlink deny the same paths.
    const rerr = resolveRel(cPath(path), -sys.c.EPERM, &rel);
    if (rerr != 0) return rerr;
    var buf: [sys.c.PATH_MAX]u8 = undefined;
    const op = st.store.originPath(&buf, rel) catch return -sys.c.ENAMETOOLONG;
    if (std.c.chmod(op, mode) != 0) return sys.negErrno();
    return 0;
}

export fn mf_readdir(path: [*c]const u8, buf: ?*anyopaque, filler: fuse.fuse_fill_dir_t, off: fuse.off_t, fi: ?*fuse.fuse_file_info, flags: fuse.enum_fuse_readdir_flags) callconv(.c) c_int {
    _ = off;
    _ = fi;
    _ = flags;
    const st = statePtr();
    const p = cPath(path);
    var rel: []const u8 = "";
    const rerr = resolveRel(p, -sys.c.ENOENT, &rel);
    if (rerr != 0) return rerr;
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const op = st.store.originPath(&pbuf, rel) catch return -sys.c.ENAMETOOLONG;
    const dir = sys.c.opendir(op) orelse return sys.negErrno();
    defer _ = sys.c.closedir(dir);
    const fill = filler orelse return -sys.c.EIO;
    _ = fill(buf, ".", null, 0, 0);
    _ = fill(buf, "..", null, 0, 0);
    const hide_cluster = rel.len == 0;
    while (sys.c.readdir(dir)) |ent| {
        const name = sys.dirName(ent);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (hide_cluster and std.mem.eql(u8, name, discover.cluster_dir)) continue;
        var namez: [256]u8 = undefined;
        if (name.len >= namez.len) continue;
        @memcpy(namez[0..name.len], name);
        namez[name.len] = 0;
        if (fill(buf, &namez, null, 0, 0) != 0) break;
    }
    return 0;
}

export fn mf_statfs(path: [*c]const u8, stbuf: ?*fuse.struct_statvfs) callconv(.c) c_int {
    const st = statePtr();
    var rel: []const u8 = "";
    // Lookup-shaped denial: /.cluster is hidden from readdir and getattr.
    const rerr = resolveRel(cPath(path), -sys.c.ENOENT, &rel);
    if (rerr != 0) return rerr;
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const op = st.store.originPath(&pbuf, rel) catch return -sys.c.ENAMETOOLONG;
    var vs: sys.c.struct_statvfs = undefined;
    if (sys.c.statvfs(op, &vs) != 0) return sys.negErrno();
    if (stbuf) |out| out.* = vs;
    return 0;
}

export fn mf_init(conn: ?*fuse.fuse_conn_info, cfg: ?*fuse.fuse_config) callconv(.c) ?*anyopaque {
    _ = conn;
    const st = statePtr();
    if (cfg) |cf| {
        cf.*.kernel_cache = 0;
        cf.*.auto_cache = 0;
        // UMA: kernel page cache is the same RAM as the GPU. Keep it off.
        cf.*.direct_io = @intFromBool(st.direct_io);
        cf.*.use_ino = 0;
        cf.*.entry_timeout = 1.0;
        cf.*.attr_timeout = 1.0;
        cf.*.negative_timeout = 0.0;
    }
    // First point that is guaranteed to be the final (post-fork) process:
    // background workers must start here or --detach loses them.
    st.spawnWorkers();
    return st;
}

export fn mf_destroy(ud: ?*anyopaque) callconv(.c) void {
    const st: *State = @ptrCast(@alignCast(ud));
    st.running.store(false, .release);
    st.server.stop();
}

/// Sleeps up to ms in 100ms slices, bailing out early once the daemon stops:
/// a plain sleepMs would keep shutdown waiting out the full tick.
fn napMs(st: *State, ms: u32) void {
    var waited: u32 = 0;
    while (waited < ms and st.running.load(.acquire)) : (waited += 100)
        sys.sleepMs(@min(ms - waited, 100));
}

fn cullLoop(st: *State) void {
    var culling = false;
    // statvfs failure reads as "100% free" downstream, i.e. culling off.
    // Without this line a broken cache mount silently suspends culling until
    // the disk fills; log each failure run once instead of every 2s tick.
    var statfs_failing = false;
    // In-memory per-file state (map entries, open cache fds) is reaped on a
    // slow cadence: entries idle this long with nothing cached are freed, so
    // nodes churning through many model paths stay bounded without unlinks.
    const reap_every_secs: i64 = 30;
    const reap_idle_secs: i64 = 300;
    var last_reap = sys.monoSec();
    while (st.running.load(.acquire)) {
        if (sys.monoSec() - last_reap >= reap_every_secs) {
            st.store.reapIdle(reap_idle_secs);
            last_reap = sys.monoSec();
        }
        const free_pct = st.store.freePercentChecked() orelse {
            if (!statfs_failing) std.log.err("cache statvfs failed on {s}; culling suspended", .{st.store.cache});
            statfs_failing = true;
            napMs(st, 2000);
            continue;
        };
        statfs_failing = false;
        const ph = cull.phase(free_pct, st.store.water, culling);
        culling = ph != .run;
        if (culling) {
            var n: u32 = 0;
            while (n < 16) : (n += 1) {
                if (!st.store.cullOne()) break;
            }
            napMs(st, if (ph == .stop) 500 else 1000);
            continue;
        }
        napMs(st, 2000);
    }
}

fn discLoop(st: *State) void {
    while (st.running.load(.acquire)) {
        st.catalog.publish();
        st.catalog.refresh();
        st.catalog.sweepLeases();
        writeStatus(st);
        napMs(st, 10_000);
    }
}

fn writeStatus(st: *State) void {
    // A silent failure here makes `modelfs status` claim the daemon is not
    // running, so any stage failing must reach the operator's log.
    statusJson(st) catch |err| std.log.warn("status.json update failed: {t}", .{err});
}

fn statusJson(st: *State) !void {
    var buf: [1024]u8 = undefined;
    const paths = try st.catalog.snapshot(st.gpa);
    defer discover.Catalog.freeSnapshot(st.gpa, paths);
    const npeers = blk: {
        var seen = std.StringHashMap(void).init(st.gpa);
        defer seen.deinit();
        for (paths) |p| _ = try seen.put(p.peer_id, {});
        break :blk seen.count();
    };
    const json = try std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"pid\":{d},\"peers\":{d},\"piece\":{d}}}\n", .{
        st.catalog.self_id,
        std.os.linux.getpid(),
        npeers,
        st.store.piece_size,
    });
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const p = try sys.joinZ(&pbuf, st.store.cache, status_file);
    var tbuf: [sys.c.PATH_MAX]u8 = undefined;
    const tp = try sys.appendExt(&tbuf, p, ".tmp");
    // Atomic swap: a torn half-written status.json would make `modelfs status`
    // print garbage; readers see either the old or the new file. O_NOFOLLOW
    // on the staging write keeps a planted symlink from redirecting it.
    if (sys.writeFileNoFollow(tp, json) != 0) return error.StatusWriteFailed;
    if (std.c.rename(tp, p) != 0) return error.StatusRenameFailed;
}

pub fn ops() fuse.fuse_operations {
    var o = std.mem.zeroes(fuse.fuse_operations);
    o.getattr = mf_getattr;
    o.open = mf_open;
    o.create = mf_create;
    o.read = mf_read;
    o.write = mf_write;
    o.truncate = mf_truncate;
    o.unlink = mf_unlink;
    o.mkdir = mf_mkdir;
    o.rmdir = mf_rmdir;
    o.rename = mf_rename;
    o.chmod = mf_chmod;
    o.readdir = mf_readdir;
    o.statfs = mf_statfs;
    o.init = mf_init;
    o.destroy = mf_destroy;
    return o;
}

test "fuse operations wire every supported handler" {
    const o = ops();
    // A null entry makes libfuse answer that operation with a default
    // behavior instead of going through the store: e.g. a dropped truncate
    // wiring would silently corrupt cache/origin size agreement.
    try std.testing.expect(o.getattr != null);
    try std.testing.expect(o.open != null);
    try std.testing.expect(o.create != null);
    try std.testing.expect(o.read != null);
    try std.testing.expect(o.write != null);
    try std.testing.expect(o.truncate != null);
    try std.testing.expect(o.unlink != null);
    try std.testing.expect(o.mkdir != null);
    try std.testing.expect(o.rmdir != null);
    try std.testing.expect(o.rename != null);
    try std.testing.expect(o.chmod != null);
    try std.testing.expect(o.readdir != null);
    try std.testing.expect(o.statfs != null);
    try std.testing.expect(o.init != null);
    try std.testing.expect(o.destroy != null);
}

test "statusJson publishes parseable liveness atomically and replaces in place" {
    const gpa = std.testing.allocator;
    var cb: [128]u8 = undefined;
    const cache_d = try sys.scratchDir(&cb, "modelfs-status");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = State{
        .gpa = gpa,
        .io = std.testing.io,
        .store = store_mod.Store.init(gpa, std.testing.io, "/unused", cache_d, 4096),
        .catalog = discover.Catalog.init(gpa, std.testing.io, "/unused", "me", &.{}, &.{}, &.{}),
        .server = undefined,
        .psk = "",
        .direct_io = true,
    };
    defer st.store.deinit();
    defer st.catalog.deinit();
    // Two paths sharing one peer id plus one distinct peer: the published
    // count must be unique peers (2), not raw paths (3).
    try st.catalog.paths.append(gpa, .{ .peer_id = "dup", .ip = "10.0.0.1", .port = 18080, .ewma_bps = 1e8, .hops = 0 });
    try st.catalog.paths.append(gpa, .{ .peer_id = "dup", .ip = "10.0.0.2", .port = 18080, .ewma_bps = 1e8, .hops = 0 });
    try st.catalog.paths.append(gpa, .{ .peer_id = "other", .ip = "10.0.0.3", .port = 18080, .ewma_bps = 1e8, .hops = 0 });

    try statusJson(&st);

    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const fp = try sys.joinZ(&pbuf, cache_d, status_file);
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    const tmp_fp = try sys.appendExt(&zbuf, fp, ".tmp");
    var stbuf: sys.c.struct_stat = undefined;
    // The rename must leave no staging file behind: a leftover .tmp next to
    // the live artifact means readers raced a torn write.
    try std.testing.expect(sys.statPath(fp, &stbuf) == 0);
    try std.testing.expect(sys.statPath(tmp_fp, &stbuf) != 0);

    const blob = try sys.readFileAlloc(gpa, fp, 1024);
    defer gpa.free(blob);
    const StatusDoc = struct { id: []const u8, pid: i64, peers: u32, piece: u32 };
    const doc = try std.json.parseFromSlice(StatusDoc, gpa, blob, .{});
    defer doc.deinit();
    try std.testing.expectEqualStrings("me", doc.value.id);
    try std.testing.expectEqual(@as(i64, std.os.linux.getpid()), doc.value.pid);
    try std.testing.expectEqual(@as(u32, 2), doc.value.peers);
    try std.testing.expectEqual(@as(u32, 4096), doc.value.piece);

    // A later discovery tick republishes: the rename replaces the document
    // wholesale, so the peer count tracks membership instead of growing.
    _ = st.catalog.paths.pop();
    try statusJson(&st);
    const blob2 = try sys.readFileAlloc(gpa, fp, 1024);
    defer gpa.free(blob2);
    const doc2 = try std.json.parseFromSlice(StatusDoc, gpa, blob2, .{});
    defer doc2.deinit();
    try std.testing.expectEqual(@as(u32, 1), doc2.value.peers);
}
