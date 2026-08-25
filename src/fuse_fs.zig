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
    /// monotonic-seconds stamp of daemon start; uptime_s in status.json.
    start_secs: i64,
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

/// Client-supplied create/mkdir modes carry permission bits only. The FUSE
/// authority transition makes the daemon the owner of everything created
/// through the mount, and Linux honors S_ISUID/S_ISGID in open(2)/mkdir(2)
/// create modes, so passing the caller's mode verbatim would let any writer
/// to a mount directory plant a setuid/setgid executable owned by the daemon
/// uid -- root on an allow_other root mount. Nothing this filesystem stores
/// (model weights, cache artifacts) has a use for special bits.
fn clientCreateMode(mode: fuse.mode_t) fuse.mode_t {
    return mode & 0o777;
}

test "clientCreateMode strips setuid, setgid, and sticky bits" {
    try std.testing.expectEqual(@as(fuse.mode_t, 0o755), clientCreateMode(0o4755));
    try std.testing.expectEqual(@as(fuse.mode_t, 0o755), clientCreateMode(0o2755));
    try std.testing.expectEqual(@as(fuse.mode_t, 0o777), clientCreateMode(0o1777));
    try std.testing.expectEqual(@as(fuse.mode_t, 0o600), clientCreateMode(0o4600));
    try std.testing.expectEqual(@as(fuse.mode_t, 0o644), clientCreateMode(0o644));
    try std.testing.expectEqual(@as(fuse.mode_t, 0), clientCreateMode(0));
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

/// Collects what readdirResume emits, honoring a per-call quota standing in
/// for the kernel reply buffer (run returns false once it is spent).
const DirSink = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    quota: usize = std.math.maxInt(usize),

    fn run(self: *DirSink, name: []const u8, ordinal: fuse.off_t) bool {
        if (self.quota == 0) return false;
        self.quota -= 1;
        var buf: [300]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{d}:{s},", .{ ordinal, name }) catch return false;
        self.out.appendSlice(self.gpa, line) catch return false;
        return true;
    }

    fn deinit(self: *DirSink) void {
        self.out.deinit(self.gpa);
    }
};

const dir_fixture = [_][]const u8{ "one", "two", "three", "four", "five" };

const DirIter = struct {
    items: []const []const u8,
    i: usize = 0,

    fn next(self: *DirIter) ?[]const u8 {
        if (self.i >= self.items.len) return null;
        const n = self.items[self.i];
        self.i += 1;
        return n;
    }
};

fn dirFixtureIter() DirIter {
    return .{ .items = &dir_fixture };
}

test "readdir resume splits a large listing without duplicates or gaps" {
    const gpa = std.testing.allocator;

    // One unlimited call emits the whole listing with stable ordinals:
    // "." and ".." lead, then the origin order.
    {
        var iter = dirFixtureIter();
        var sink = DirSink{ .gpa = gpa };
        defer sink.deinit();
        readdirResume(&iter, &sink, 0);
        try std.testing.expectEqualStrings("1:.,2:..,3:one,4:two,5:three,6:four,7:five,", sink.out.items);
    }

    // The old all-zero-offset shape made every full-buffer break restart
    // the directory: chunked calls must instead continue after the last
    // emitted ordinal, and the concatenation must equal the single call.
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    {
        var iter = dirFixtureIter();
        var sink = DirSink{ .gpa = gpa, .quota = 3 };
        defer sink.deinit();
        readdirResume(&iter, &sink, 0);
        try std.testing.expectEqualStrings("1:.,2:..,3:one,", sink.out.items);
        try joined.appendSlice(gpa, sink.out.items);
    }
    {
        // Resume from ordinal 3 (the value filler was handed for "one").
        var iter = dirFixtureIter();
        var sink = DirSink{ .gpa = gpa, .quota = 3 };
        defer sink.deinit();
        readdirResume(&iter, &sink, 3);
        try std.testing.expectEqualStrings("4:two,5:three,6:four,", sink.out.items);
        try joined.appendSlice(gpa, sink.out.items);
    }
    {
        var iter = dirFixtureIter();
        var sink = DirSink{ .gpa = gpa };
        defer sink.deinit();
        readdirResume(&iter, &sink, 6);
        try std.testing.expectEqualStrings("7:five,", sink.out.items);
        try joined.appendSlice(gpa, sink.out.items);
    }
    try std.testing.expectEqualStrings("1:.,2:..,3:one,4:two,5:three,6:four,7:five,", joined.items);

    // A rewind (fresh handle, offset 0) reproduces the full listing.
    {
        var iter = dirFixtureIter();
        var sink = DirSink{ .gpa = gpa };
        defer sink.deinit();
        readdirResume(&iter, &sink, 0);
        try std.testing.expectEqualStrings(joined.items, sink.out.items);
    }

    // A resume offset at or past the end yields nothing.
    {
        var iter = dirFixtureIter();
        var sink = DirSink{ .gpa = gpa };
        defer sink.deinit();
        readdirResume(&iter, &sink, 7);
        try std.testing.expectEqualStrings("", sink.out.items);
    }
}

test "rename flag passthrough keeps NOREPLACE and EXCHANGE semantics" {
    // The flags libfuse forwards ride unchanged into the origin's
    // renameat2: NOREPLACE must refuse an existing destination instead of
    // silently overwriting it, and EXCHANGE must swap two names in place.
    // This pins the translated call surface mf_rename hands the flags to,
    // argument order included.
    const io = std.testing.io;
    var db: [128]u8 = undefined;
    const scratch = try sys.scratchDir(&db, "modelfs-rename-flags");
    defer sys.deleteTree(io, scratch);

    var az: [192]u8 = undefined;
    var bz: [192]u8 = undefined;
    var za: [192]u8 = undefined;
    var zb: [192]u8 = undefined;
    const a_fp = try std.fmt.bufPrint(&az, "{s}/a.bin", .{scratch});
    const b_fp = try std.fmt.bufPrint(&bz, "{s}/b.bin", .{scratch});
    const a_z = try sys.toZ(&za, a_fp);
    const b_z = try sys.toZ(&zb, b_fp);
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(a_z, "AAA"));
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(b_z, "BBB"));

    // NOREPLACE onto an existing destination fails EEXIST; b keeps its bytes.
    try std.testing.expect(fuse.renameat2(sys.c.AT_FDCWD, a_z, sys.c.AT_FDCWD, b_z, sys.c.RENAME_NOREPLACE) != 0);
    try std.testing.expectEqual(sys.c.EEXIST, sys.errno());
    var rb: [4]u8 = undefined;
    try std.testing.expectEqualStrings("BBB", try sys.readFileBuf(&rb, b_z));

    // EXCHANGE swaps the two names' contents in place.
    try std.testing.expectEqual(@as(i32, 0), fuse.renameat2(sys.c.AT_FDCWD, a_z, sys.c.AT_FDCWD, b_z, sys.c.RENAME_EXCHANGE));
    try std.testing.expectEqualStrings("BBB", try sys.readFileBuf(&rb, a_z));
    try std.testing.expectEqualStrings("AAA", try sys.readFileBuf(&rb, b_z));
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
    return st.store.get(rel, @intCast(ost.st_size), sys.monoSec()) catch null;
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
        const file = st.store.get(rel, @intCast(ost.st_size), sys.monoSec()) catch return -sys.c.ENOMEM;
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
    const fd = sys.open(op, sys.c.O_CREAT | sys.c.O_RDWR | sys.c.O_TRUNC, clientCreateMode(mode));
    if (fd < 0) return sys.negErrno();
    sys.close(fd);
    // The origin create above already landed: failing the syscall here (entry
    // warmup OOM) would tell the caller the create failed over a file that
    // exists and was possibly truncated. Warmup is best-effort; the next
    // open/read rebuilds the entry.
    if (st.store.get(rel, 0, sys.monoSec())) |file| {
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
    // Claim and completion are separate clock samples on purpose: a slow
    // fill must land a fresh recency stamp (finishPiece), not the claim's
    // pre-transfer one, or a piece that filled for minutes is born punchable.
    const cl = st.store.beginFill(file, idx, sys.monoSec()) catch return -sys.c.ENOMEM;
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
    // Miss latency is claim-to-cache-write: exactly the stall the reader
    // eats for this piece. Failed fills keep their error counts and no time.
    const fill_t0 = sys.monoNs();
    peer.fillFromPeers(st.gpa, st.psk, &st.catalog, file.rel, idx, st.store.piece_size, buf, &st.store.stats) catch {
        from_peer = false;
        const n = st.store.originPread(file.rel, buf, piece.offset(idx, st.store.piece_size));
        if (n != @as(isize, @intCast(ln))) {
            st.store.finishPiece(file, idx, false, sys.monoSec());
            _ = st.store.stats.fill_err_origin.fetchAdd(1, .monotonic);
            // The reader sees EIO and nothing else names the cause; keep the
            // same sender-side trace serveData's hydration branch does,
            // distinguishing a real errno from a short read.
            if (n < 0)
                std.log.warn("origin fill failed for {s} piece {d} (errno {d}); failing read", .{ file.rel, idx, -n })
            else
                std.log.warn("origin fill short for {s} piece {d} ({d}/{d} bytes); failing read", .{ file.rel, idx, n, ln });
            if (n < 0) return @intCast(n);
            return -sys.c.EIO;
        }
    };
    // Counted per fill instead of logged: a single model read covers hundreds
    // of pieces, and the totals land in status.json and the discovery tick's
    // summary line. Failures keep their own warns at the failure sites.
    const s = &st.store.stats;
    const rc = st.store.completeFill(file, idx, buf, sys.monoSec());
    if (rc != 0) {
        // Hydrated bytes the cache fs refused: the piece stays unmarked and
        // the reader gets EIO, so name the refusal like serveData's twin
        // branch. Failed fills keep their error counts and no time (and no
        // fill or byte totals): the tick line's averages stay miss-only.
        _ = s.fill_err_cache.fetchAdd(1, .monotonic);
        std.log.warn("cache write refused {s} piece {d} (errno {d}); failing read", .{ file.rel, idx, -rc });
        return rc;
    }
    // Sampled after the cache write lands: the published average is the full
    // claim-to-cache-write stall the reader ate for this piece.
    const fill_dt: u64 = @intCast(sys.monoNs() - fill_t0);
    if (from_peer) {
        _ = s.fills_peer.fetchAdd(1, .monotonic);
        _ = s.bytes_from_peer.fetchAdd(ln, .monotonic);
        _ = s.fill_peer_nanos.fetchAdd(fill_dt, .monotonic);
    } else {
        _ = s.fills_origin.fetchAdd(1, .monotonic);
        _ = s.bytes_from_origin.fetchAdd(ln, .monotonic);
        _ = s.fill_origin_nanos.fetchAdd(fill_dt, .monotonic);
    }
    return 0;
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
        if (st.store.hasPiece(file, i, sys.monoSec())) continue;
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
    // Latency covers the whole handler: warm reads too, so the tick line's
    // average tracks real reader-perceived latency, not just miss stalls.
    const rd_t0 = sys.monoNs();
    defer _ = st.store.stats.read_nanos.fetchAdd(@intCast(sys.monoNs() - rd_t0), .monotonic);
    var rel: []const u8 = "";
    const rerr = resolveRel(cPath(path), -sys.c.ENOENT, &rel);
    if (rerr != 0) return rerr;
    // Report the real origin failure (EIO on NFS, ENOENT, ...): collapsing it
    // into EISDIR would send readers hunting for a directory that is not there.
    var ost: sys.c.struct_stat = undefined;
    const src = st.store.statOrigin(rel, &ost);
    if (src != 0) {
        // An origin outage fails every uncached read here before any tier
        // runs; without this count reads_err stays flat while clients see
        // an EIO storm.
        _ = st.store.stats.reads_err.fetchAdd(1, .monotonic);
        return src;
    }
    if ((ost.st_mode & sys.c.S_IFMT) != sys.c.S_IFREG) return -sys.c.EISDIR;
    const file = st.store.get(rel, @intCast(ost.st_size), sys.monoSec()) catch {
        _ = st.store.stats.reads_err.fetchAdd(1, .monotonic);
        return -sys.c.ENOMEM;
    };
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
    if (rc != 0) {
        // The failing tier kept its own fill_err_* count; the op-level
        // counter must still see the read fail, or error-rate alerts keying
        // on reads_err miss exactly the EIO storms users feel.
        _ = st.store.stats.reads_err.fetchAdd(1, .monotonic);
        return rc;
    }
    const got = st.store.readServed(file, buf[0..n], uoff, sys.monoSec());
    if (got < 0) {
        _ = st.store.stats.reads_err.fetchAdd(1, .monotonic);
    } else {
        _ = st.store.stats.reads_ok.fetchAdd(1, .monotonic);
        _ = st.store.stats.bytes_read.fetchAdd(@intCast(got), .monotonic);
    }
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
    if (n < 0) {
        _ = st.store.stats.writes_err.fetchAdd(1, .monotonic);
        return @intCast(n);
    }
    _ = st.store.stats.writes_ok.fetchAdd(1, .monotonic);
    _ = st.store.stats.bytes_written.fetchAdd(@intCast(n), .monotonic);
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
        st.store.cacheFill(rel, end, uoff, buf[0..@intCast(n)], sys.monoSec());
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
        _ = st.store.copyIntoCache(file, uoff, buf[0..@intCast(n)]);
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
    if (std.c.mkdir(op, clientCreateMode(mode)) != 0) return sys.negErrno();
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
    // Namespace ops present the origin's own rename semantics, flags
    // included: the kernel routes RENAME_NOREPLACE/EXCHANGE through FUSE's
    // rename2 and libfuse forwards them here. Dropping them would silently
    // overwrite a destination the caller asked to keep (mv -n, cp -n) or
    // move instead of swap (renameat2 EXCHANGE). The origin filesystem
    // answers for whatever it cannot do -- loud failure, never a silently
    // different operation.
    if (fuse.renameat2(sys.c.AT_FDCWD, oa, sys.c.AT_FDCWD, ob, flags) != 0)
        return sys.negErrno();
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
    var names = OriginDirNames{ .dir = dir, .hide_cluster = rel.len == 0 };
    const emit = DirFiller{ .buf = buf, .fill = fill };
    readdirResume(&names, emit, off);
    return 0;
}

/// libfuse's readdir contract has two valid modes: ignore the offset and
/// always pass zero to filler (only legal when the whole listing fits one
/// reply buffer), or track offsets and resume where the kernel asks. This
/// handler implements the second: a listing of a models directory past one
/// reply (~32-128 KiB of fuse_dirent records) made filler report full with
/// every entry stamped offset 0, so the kernel's next READDIR resumed at 0
/// and re-received the head of the directory forever -- duplicates without
/// end in ls/readdir(3). Entries carry stable 1-based ordinals (".", "..",
/// then origin order); entries at or below the incoming offset are skipped
/// and emitted entries hand filler their ordinal, which is exactly the
/// value the kernel returns to resume after them. Extracted from
/// mf_readdir so the resume contract is drivable in tests without mounting.
fn readdirResume(names: anytype, emit: anytype, off: fuse.off_t) void {
    var pos: fuse.off_t = 0;
    inline for ([_][]const u8{ ".", ".." }) |dot| {
        pos += 1;
        if (pos > off) {
            if (!emit.run(dot, pos)) return;
        }
    }
    while (names.next()) |name| {
        pos += 1;
        if (pos <= off) continue;
        if (!emit.run(name, pos)) return;
    }
}

/// The origin-side entry stream of an mf_readdir walk: everything invisible
/// to the mount (dot entries, the control dir at the root) is filtered here,
/// so the resume ordinals count only emittable names.
const OriginDirNames = struct {
    dir: *anyopaque,
    hide_cluster: bool,

    fn next(self: *OriginDirNames) ?[]const u8 {
        while (sys.c.readdir(@ptrCast(self.dir))) |ent| {
            const name = sys.dirName(ent);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (self.hide_cluster and std.mem.eql(u8, name, discover.cluster_dir)) continue;
            return name;
        }
        return null;
    }
};

/// Hands each planned entry to libfuse's filler. False ends the walk, both
/// on a full reply buffer (filler nonzero) and for a name that cannot ride
/// the fixed staging buffer; either way the kernel resumes from the last
/// ordinal actually emitted.
const DirFiller = struct {
    buf: ?*anyopaque,
    fill: fuse.fuse_fill_dir_t,

    fn run(self: DirFiller, name: []const u8, ordinal: fuse.off_t) bool {
        var namez: [256]u8 = undefined;
        if (name.len >= namez.len) return true;
        @memcpy(namez[0..name.len], name);
        namez[name.len] = 0;
        return self.fill.?(self.buf, &namez, null, ordinal, 0) == 0;
    }
};

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
        // One monotonic instant per round: the reap gate, reapIdle's cutoff,
        // its reschedule stamp, and every cullOne recency decision below run
        // on this sample instead of four reads drifting across the round.
        // punchPiece/cullOne/reapIdle take the instant in precisely so their
        // decisions stay pure functions of state plus one clock sample
        // (see store.zig), which only holds if the driver samples once.
        const now = sys.monoSec();
        if (now - last_reap >= reap_every_secs) {
            st.store.reapIdle(now, reap_idle_secs);
            last_reap = now;
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
                if (!st.store.cullOne(now)) break;
            }
            napMs(st, if (ph == .stop) 500 else 1000);
            continue;
        }
        napMs(st, 2000);
    }
}

fn discLoop(st: *State) void {
    // Baseline for the per-tick activity summary; the first tick only logs
    // what happened since daemon start.
    var last_stats = st.store.stats.snap();
    while (st.running.load(.acquire)) {
        // One wall-clock instant per tick: publish, refresh's expiry filter,
        // and the sweep cutoff all decide against the same sample instead of
        // three reads drifting across the tick.
        const now = sys.nowSec();
        st.catalog.publish(now);
        st.catalog.refresh(now);
        st.catalog.sweepLeases(now);
        writeStatus(st);
        logStatsTick(st, &last_stats);
        napMs(st, 10_000);
    }
}

/// One summary line per discovery tick, and only when some counter moved:
/// the daemon's activity heartbeat. Per-event logging at piece granularity
/// would flood the journal (one model read covers hundreds of pieces), so
/// steady-state work is aggregated here while failures keep their own
/// immediate warns. Deltas name the last interval, so a stalled ingest or a
/// read storm is visible straight from the journal; rd_us and the fill_ms
/// pair are per-op averages over those deltas, the only latency signal this
/// daemon publishes.
fn logStatsTick(st: *State, prev: *store_mod.Stats.Snap) void {
    const cur = st.store.stats.snap();
    defer prev.* = cur;
    var d = store_mod.Stats.Snap{};
    inline for (@typeInfo(store_mod.Stats.Snap).@"struct".fields) |f| {
        @field(d, f.name) = @field(cur, f.name) -| @field(prev.*, f.name);
    }
    if (std.meta.eql(d, store_mod.Stats.Snap{})) return;
    const mib = 1024 * 1024;
    const reads_attempted = d.reads_ok + d.reads_err;
    const rd_us = if (reads_attempted > 0) d.read_nanos / (reads_attempted * std.time.ns_per_us) else 0;
    const fill_ms_peer = if (d.fills_peer > 0) d.fill_peer_nanos / (d.fills_peer * std.time.ns_per_ms) else 0;
    const fill_ms_origin = if (d.fills_origin > 0) d.fill_origin_nanos / (d.fills_origin * std.time.ns_per_ms) else 0;
    std.log.info(
        // Field names mirror Stats.Snap's (what status.json publishes), so
        // the journal line and the machine artifact share one vocabulary and
        // no key collides ("err" used to name both read and write failures).
        "tick: reads_ok={d} reads_err={d} read_mib={d} rd_us={d} writes_ok={d} writes_err={d} write_mib={d}" ++
            " fills peer={d} nfs={d} fill_ms peer/nfs={d}/{d} fill_err peer/nfs/cache={d}/{d}/{d}" ++
            " probe_err={d} peer_mib={d} origin_mib={d} culled={d} http401={d} http5xx={d} httpbad={d}",
        .{
            d.reads_ok,
            d.reads_err,
            d.bytes_read / mib,
            rd_us,
            d.writes_ok,
            d.writes_err,
            d.bytes_written / mib,
            d.fills_peer,
            d.fills_origin,
            fill_ms_peer,
            fill_ms_origin,
            d.fill_err_peer,
            d.fill_err_origin,
            d.fill_err_cache,
            d.probe_err,
            d.bytes_from_peer / mib,
            d.bytes_from_origin / mib,
            d.pieces_culled,
            d.http_unauthorized,
            d.http_5xx,
            d.http_malformed,
        },
    );
}

fn writeStatus(st: *State) void {
    // A silent failure here makes `modelfs status` claim the daemon is not
    // running, so any stage failing must reach the operator's log.
    statusJson(st) catch |err| std.log.warn("status.json update failed: {t}", .{err});
}

fn statusJson(st: *State) !void {
    var buf: [2048]u8 = undefined;
    const paths = try st.catalog.snapshot(st.gpa);
    defer discover.Catalog.freeSnapshot(st.gpa, paths);
    const npeers = blk: {
        var seen = std.StringHashMap(void).init(st.gpa);
        defer seen.deinit();
        for (paths) |p| _ = try seen.put(p.peer_id, {});
        break :blk seen.count();
    };
    const s = st.store.stats.snap();
    // Saturation signal for monitors: the same sample culling runs on.
    // -1 means the cache filesystem could not be stat'ed (culling suspended).
    const cache_free_pct: i32 = if (st.store.freePercentChecked()) |pct| @intCast(pct) else -1;
    // Single line like every other machine-read artifact here: consumers
    // tail/grep it and a multi-line document would break line-oriented
    // parsing (journalctl, jq -line, watch loops). The stats object is
    // emitted from Stats.Snap's fields (the same list logStatsTick diffs),
    // so a new counter publishes here by construction instead of by
    // remembering to edit this document's format string.
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{{\"id\":\"{s}\",\"pid\":{d},\"uptime_s\":{d},\"peers\":{d},\"piece\":{d},\"inflight\":{d},\"cache_free_pct\":{d},\"stats\":{{", .{
        st.catalog.self_id,
        std.os.linux.getpid(),
        sys.monoSec() - st.start_secs,
        npeers,
        st.store.piece_size,
        st.server.http_inflight.load(.monotonic),
        cache_free_pct,
    });
    inline for (@typeInfo(store_mod.Stats.Snap).@"struct".fields, 0..) |f, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("\"{s}\":{d}", .{ f.name, @field(s, f.name) });
    }
    try w.writeAll("}}\n");
    const json = w.buffered();
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
        .start_secs = sys.monoSec(),
    };
    // statusJson reads server.http_inflight; give the test a real Server so
    // it does not sample undefined memory.
    st.server = .{ .gpa = gpa, .io = std.testing.io, .psk = "", .store = &st.store };
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
    const StatsDoc = store_mod.Stats.Snap;
    const StatusDoc = struct {
        id: []const u8,
        pid: i64,
        uptime_s: i64,
        peers: u32,
        piece: u32,
        inflight: u32,
        cache_free_pct: i32,
        stats: StatsDoc,
    };
    const doc = try std.json.parseFromSlice(StatusDoc, gpa, blob, .{});
    defer doc.deinit();
    try std.testing.expectEqualStrings("me", doc.value.id);
    try std.testing.expectEqual(@as(i64, std.os.linux.getpid()), doc.value.pid);
    try std.testing.expect(doc.value.uptime_s >= 0);
    try std.testing.expectEqual(@as(u32, 2), doc.value.peers);
    try std.testing.expectEqual(@as(u32, 4096), doc.value.piece);
    try std.testing.expectEqual(@as(u32, 0), doc.value.inflight);
    // The saturation gauge rides along: statvfs works here, so a real
    // percentage, not the -1 unknown marker.
    try std.testing.expect(doc.value.cache_free_pct >= 0);
    // Counters ride along with the liveness fields: an operator answers
    // "is it serving, from where, is it failing" from one artifact.
    try std.testing.expectEqual(@as(u64, 0), doc.value.stats.reads_ok);

    // A later discovery tick republishes: the rename replaces the document
    // wholesale, so the peer count tracks membership instead of growing.
    _ = st.catalog.paths.pop();
    // Bump one counter and require it to surface: the publish path must
    // carry live stats, not a frozen snapshot.
    _ = st.store.stats.fills_peer.fetchAdd(1, .monotonic);
    _ = st.store.stats.bytes_from_peer.fetchAdd(4096, .monotonic);
    try statusJson(&st);
    const blob2 = try sys.readFileAlloc(gpa, fp, 1024);
    defer gpa.free(blob2);
    const doc2 = try std.json.parseFromSlice(StatusDoc, gpa, blob2, .{});
    defer doc2.deinit();
    try std.testing.expectEqual(@as(u32, 1), doc2.value.peers);
    try std.testing.expectEqual(@as(u64, 1), doc2.value.stats.fills_peer);
    try std.testing.expectEqual(@as(u64, 4096), doc2.value.stats.bytes_from_peer);
}

test "logStatsTick summarizes deltas and stays silent when idle" {
    const gpa = std.testing.allocator;
    var cb: [128]u8 = undefined;
    const cache_d = try sys.scratchDir(&cb, "modelfs-tick");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = State{
        .gpa = gpa,
        .io = std.testing.io,
        .store = store_mod.Store.init(gpa, std.testing.io, "/unused", cache_d, 4096),
        .catalog = discover.Catalog.init(gpa, std.testing.io, "/unused", "me", &.{}, &.{}, &.{}),
        .server = undefined,
        .psk = "",
        .direct_io = true,
        .start_secs = sys.monoSec(),
    };
    defer st.store.deinit();
    defer st.catalog.deinit();

    var prev = st.store.stats.snap();

    // Idle tick: no movement since the snapshot, no log line. The summary
    // must stay quiet on an idle node or it is exactly the noise it exists
    // to prevent.
    logStatsTick(&st, &prev);
    try std.testing.expect(std.meta.eql(prev, st.store.stats.snap()));

    // Activity since the last tick: the delta line carries per-interval
    // counts (here: one origin fill of 4096 bytes), not lifetime totals.
    _ = st.store.stats.fills_origin.fetchAdd(1, .monotonic);
    _ = st.store.stats.bytes_from_origin.fetchAdd(4096, .monotonic);
    // The expected info line is below the raised threshold; restored on
    // scope exit so unexpected warnings from later tests still surface.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;
    logStatsTick(&st, &prev);
    try std.testing.expectEqual(@as(u64, 1), prev.fills_origin);
}
