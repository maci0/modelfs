//! libfuse operation handlers: path resolution policy, read hydration,
//! write-through cache fill, daemon `State` lifecycle, and the background
//! discovery/cull loops.
const std = @import("std");
const fuse = sys.c;
const piece = @import("piece.zig");
const proto = @import("proto.zig");
const sys = @import("sys.zig");
const store_mod = @import("store.zig");
const discover = @import("discover.zig");
const peer = @import("peer.zig");
const cull = @import("cull.zig");
const fuzzcorpus = @import("fuzzcorpus.zig");
const handover = @import("handover.zig");

pub const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    store: store_mod.Store,
    catalog: discover.Catalog,
    server: peer.Server,
    direct_io: bool,
    /// monotonic-seconds stamp of daemon start; uptime_s in status.json.
    start_secs: i64,
    running: std.atomic.Value(bool) = .init(true),
    /// Background workers, spawned by mf_init: libfuse daemonizes with fork()
    /// before init runs, and fork keeps only the calling thread, so anything
    /// spawned earlier dies with the parent and a detached mount would
    /// silently lose its peer server, discovery, and culling.
    workers: std.ArrayList(std.Thread) = .empty,
    mountpoint: []const u8 = "",
    allow_other: bool = false,
    detach: bool = false,
    listen_port: u16 = 0,
    fuse_fd: c_int = -1,
    /// Set by SIGUSR2: the session loop exits without unmounting so
    /// `execHandover` can hand the FUSE and listen fds to a new image.
    handover_asked: std.atomic.Value(bool) = .init(false),
    /// The FUSE_INIT request the kernel opened this connection with, kept
    /// verbatim off the wire (`captureInit`) and replayed by a replacement
    /// image (`replayInit`). Written once, before any thread that reads it.
    init_raw: [handover.init_max]u8 = undefined,
    init_len: std.atomic.Value(usize) = .init(0),
    /// Set by `ll_init`: proof that a replayed INIT was accepted.
    init_seen: std.atomic.Value(bool) = .init(false),
    /// Set while the synthetic INIT of a handover is being processed: the
    /// kernel already has its INIT reply, so libfuse's must be dropped
    /// instead of written back onto the connection.
    swallow_reply: std.atomic.Value(bool) = .init(false),
    /// The mount namespace this daemon owns: `nodes`/`paths` map the inode
    /// numbers the kernel holds to mount-relative paths, `opens` maps open
    /// file handles, and `nlookup` counts the kernel's outstanding lookup
    /// references per inode (FORGET decrements; zero drops the node). The
    /// high-level libfuse API keeps this table privately, which is exactly
    /// why the daemon speaks the low-level API: only a table we own can be
    /// carried across a process-image handover.
    nodes_mu: std.Io.Mutex = .init,
    nodes: std.AutoHashMapUnmanaged(u64, Node) = .empty,
    paths: std.StringHashMapUnmanaged(u64) = .empty,
    opens: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
    next_ino: u64 = 2,
    next_fh: u64 = 1,
    /// Handshake token from `update.req`, acked once the new image serves.
    update_token: ?[]const u8 = null,

    /// `path` is owned here and aliased as the `paths` key.
    const Node = struct { path: []u8, nlookup: u64 };

    /// One constructor for the daemon composition: cache, membership, and
    /// peer HTTP share this object, and Server.store must alias the Store
    /// field rather than a copy. Callers (mount wiring, tests) never poke
    /// that pointer themselves. Pair with `deinit`; heap callers then
    /// `gpa.destroy` only when no peer handler is still inflight.
    pub fn init(
        self: *State,
        gpa: std.mem.Allocator,
        io: std.Io,
        origin: []const u8,
        cache: []const u8,
        piece_size: u32,
        water: cull.Water,
        id: []const u8,
        addrs: []const proto.LeaseAddr,
        local_ips: []const []const u8,
        seeds: []const proto.LeaseAddr,
        psk: []const u8,
        direct_io: bool,
    ) void {
        self.* = .{
            .gpa = gpa,
            .io = io,
            .store = store_mod.Store.init(gpa, io, origin, cache, piece_size),
            .catalog = discover.Catalog.init(gpa, io, origin, id, addrs, local_ips, seeds),
            .server = .{
                .gpa = gpa,
                .io = io,
                .psk = psk,
                .store = &self.store,
            },
            .direct_io = direct_io,
            .start_secs = sys.monoSec(io),
        };
        self.store.water = water;
    }

    /// Restores the captured FUSE_INIT request in an image that inherited
    /// the connection. Refuses an empty or oversized one: without a request
    /// to replay the session answers every op with EIO.
    pub fn setInitRequest(self: *State, msg: []const u8) !void {
        if (msg.len == 0 or msg.len > self.init_raw.len) return error.BadInitRequest;
        @memcpy(self.init_raw[0..msg.len], msg);
        self.init_len.store(msg.len, .release);
    }

    pub fn spawnWorkers(self: *State) void {
        // Reserve before spawning: an append failure after a spawn used to
        // detach that worker beyond the workers-list joins, letting it run
        // unsupervised against State after deinit's drain gave up waiting.
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

    /// Single shutdown path: signal workers, stop accepting, join background
    /// loops, drain in-flight connection handlers, and only then release
    /// what they reference. A leftover detach-then-sleep teardown used to
    /// free State while a detached thread was still inside it. When a
    /// handler outlives the drain, store and catalog stay allocated (the
    /// same stuck-handler policy as Store.deinit) and the caller must not
    /// free `self`.
    pub fn deinit(self: *State) void {
        self.running.store(false, .release);
        self.server.stop();
        // Joining the HTTP thread retires its accept loops: past this point
        // no new connection handler can start, so the drain below cannot
        // race a fresh accept. Handlers get 30s socket timeouts; allow a
        // little more.
        for (self.workers.items) |t| t.join();
        self.workers.deinit(self.gpa);
        var waited: u32 = 0;
        while (self.server.http_inflight.load(.monotonic) != 0 and waited < 400) : (waited += 1) {
            sys.sleepMs(self.io, 100);
        }
        if (self.server.http_inflight.load(.monotonic) != 0) {
            // A detached handler outlived the drain (stalled peer sink
            // resets its 30s send timeout on every chunk; an NFS-hung
            // originPread never returns). Freeing State here hands that
            // thread freed memory the moment its current syscall unwinds.
            // Leak the whole tree instead, mirroring Store.deinit's
            // stuck-handler policy; process exit reclaims it.
            std.log.warn("shutdown: peer handler still inflight after drain; leaking mount state", .{});
            return;
        }
        self.store.deinit();
        self.catalog.deinit();
        var n_it = self.nodes.iterator();
        while (n_it.next()) |e| self.gpa.free(e.value_ptr.path);
        self.nodes.deinit(self.gpa);
        self.paths.deinit(self.gpa);
        var o_it = self.opens.iterator();
        while (o_it.next()) |e| self.gpa.free(e.value_ptr.*);
        self.opens.deinit(self.gpa);
        if (self.update_token) |t| self.gpa.free(t);
    }
};

/// The State the request being served belongs to. Set once per low-level
/// op from `fuse_req_userdata`, so the path handlers below stay free of
/// libfuse request types and remain callable from tests.
threadlocal var tls_state: ?*State = null;

fn statePtr() *State {
    return tls_state.?;
}

fn cPath(p: [*c]const u8) []const u8 {
    if (p == null) return "";
    return std.mem.span(p);
}

/// "" and "/" name the mount root itself; everything else must be a clean
/// relative path once the leading slash is stripped. Null when the path
/// fails store.relOk after that strip.
fn relFromFuse(path: []const u8) ?[]const u8 {
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return "";
    const rel = if (path[0] == '/') path[1..] else path;
    return if (store_mod.relOk(rel)) rel else null;
}

fn isCluster(path: []const u8) bool {
    const rel = if (path.len > 0 and path[0] == '/') path[1..] else path;
    return discover.relIsCluster(rel);
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

/// Client-supplied create/mkdir/chmod modes carry permission bits only. The
/// FUSE authority transition makes the daemon the owner of everything created
/// through the mount, and Linux honors S_ISUID/S_ISGID in open(2)/mkdir(2)
/// create modes just as it does in a later chmod(2) on those daemon-owned
/// files, so passing the caller's mode verbatim would let any writer to a
/// mount directory plant a setuid/setgid executable owned by the daemon uid
/// -- root on an allow_other root mount. Nothing this filesystem stores
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
    // Mutation-shaped handlers pass EPERM: cluster stays hidden, and the
    // errno is the caller's, not a hardcoded ENOENT.
    try std.testing.expectEqual(@as(c_int, -sys.c.EPERM), resolveRel("/.cluster", -sys.c.EPERM, &rel));
    try std.testing.expectEqual(@as(c_int, -sys.c.EPERM), resolveRel("/.cluster/spark1.json", -sys.c.EPERM, &rel));
    // Prefix, not substring: a model named .clusterfoo is not the lease dir.
    try std.testing.expectEqual(@as(c_int, 0), resolveRel("/.clusterfoo", -sys.c.ENOENT, &rel));
    try std.testing.expectEqualStrings(".clusterfoo", rel);
    try std.testing.expectEqual(@as(c_int, 0), resolveRel("/.clusterfoo", -sys.c.EPERM, &rel));
    try std.testing.expectEqualStrings(".clusterfoo", rel);
    try std.testing.expectEqual(@as(c_int, 0), resolveRel("/gguf/a.gguf", -sys.c.ENOENT, &rel));
    try std.testing.expectEqualStrings("gguf/a.gguf", rel);
    try std.testing.expectEqual(@as(c_int, -sys.c.EPERM), resolveRel("/../etc", -sys.c.ENOENT, &rel));
    try std.testing.expectEqual(@as(c_int, -sys.c.EPERM), resolveRel("/../etc", -sys.c.EPERM, &rel));
}

test "relFromFuse rejects .." {
    try std.testing.expectEqualStrings("gguf/a.gguf", relFromFuse("/gguf/a.gguf").?);
    try std.testing.expect(relFromFuse("/../etc/passwd") == null);
    try std.testing.expectEqualStrings("", relFromFuse("/").?);
    try std.testing.expect(isCluster("/.cluster"));
    try std.testing.expect(isCluster("/.cluster/spark1.json"));
    // The trailing slash in the prefix match is the boundary: without it a
    // model named .clusterfoo would vanish as a control path.
    try std.testing.expect(!isCluster("/.clusterfoo"));
    try std.testing.expect(!isCluster("/foo/.cluster"));
    try std.testing.expect(!isCluster("/gguf/a.gguf"));
}

const seed_path_root = fuzzcorpus.entry("/");
const seed_path_model = fuzzcorpus.entry("/gguf/a.gguf");
const seed_path_cluster_dir = fuzzcorpus.entry("/.cluster");
const seed_path_cluster_file = fuzzcorpus.entry("/.cluster/spark1.json");
const seed_path_dotdot = fuzzcorpus.entry("/../etc/passwd");
const seed_path_inner_dotdot = fuzzcorpus.entry("/a/../b");
const seed_path_dot_seg = fuzzcorpus.entry("/a/./b");
const seed_path_dot_name = fuzzcorpus.entry("/...");
const seed_path_double_slash = fuzzcorpus.entry("/gguf//a.gguf");
const seed_path_trailing_slash = fuzzcorpus.entry("/gguf/");
const seed_path_control = fuzzcorpus.entry("/a\x1b[31mb\x7f");
const seed_path_line_sep = fuzzcorpus.entry("/gguf/a\u{2028}ERROR.bin");
const seed_path_bidi = fuzzcorpus.entry("/gguf/a\u{202e}gnp.bin");
const seed_path_zwsp = fuzzcorpus.entry("/gguf/model\u{200b}.bin");
const seed_path_vs = fuzzcorpus.entry("/a\u{fe0f}.bin");
const seed_path_shy = fuzzcorpus.entry("/gguf/model\u{ad}.bin");
const seed_path_vs17 = fuzzcorpus.entry("/a\u{e0100}.bin");
const seed_path_fvs4 = fuzzcorpus.entry("/a\u{180f}.bin");
const seed_path_shorthand = fuzzcorpus.entry("/a\u{1bca0}.bin");
const seed_path_empty = fuzzcorpus.entry("");
const seed_path_unicode = fuzzcorpus.entry("/权重/mödel.gguf");

const fuzz_path_corpus = [_][]const u8{
    &seed_path_root,
    &seed_path_model,
    &seed_path_cluster_dir,
    &seed_path_cluster_file,
    &seed_path_dotdot,
    &seed_path_inner_dotdot,
    &seed_path_dot_seg,
    &seed_path_dot_name,
    &seed_path_double_slash,
    &seed_path_trailing_slash,
    &seed_path_control,
    &seed_path_line_sep,
    &seed_path_bidi,
    &seed_path_zwsp,
    &seed_path_vs,
    &seed_path_shy,
    &seed_path_vs17,
    &seed_path_fvs4,
    &seed_path_shorthand,
    &seed_path_empty,
    &seed_path_unicode,
};

/// Every FUSE operation hands this gate a path any local process chose, so
/// the harness treats it as untrusted wire input. Asserts the gate's
/// published contract end to end: cluster control paths are denied under
/// both handler shapes (lookup ENOENT, mutation EPERM) whatever rides
/// behind them; results are deterministic across repeated calls; and the
/// one invariant every downstream handler leans on holds -- an accepted rel
/// is either the mount root itself or store.relOk-clean, so its join with
/// the origin/cache roots cannot escape either directory.
fn fuzzPathGateOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const p = buf[0..smith.slice(&buf)];

    const gated = relFromFuse(p);

    if (isCluster(p)) {
        var rel: []const u8 = "";
        try std.testing.expectEqual(@as(c_int, -sys.c.ENOENT), resolveRel(p, -sys.c.ENOENT, &rel));
        try std.testing.expectEqual(@as(c_int, -sys.c.EPERM), resolveRel(p, -sys.c.EPERM, &rel));
        return;
    }

    const again = relFromFuse(p);
    if (gated) |rel| {
        try std.testing.expect(again != null);
        try std.testing.expectEqualStrings(rel, again.?);
    } else {
        try std.testing.expect(again == null);
    }

    var rel: []const u8 = "";
    const rc = resolveRel(p, -sys.c.ENOENT, &rel);
    try std.testing.expectEqual(gated != null, rc == 0);
    if (rc != 0) return;

    if (rel.len == 0) {
        // Only "" and "/" name the root; anything else must produce a real
        // relative path.
        try std.testing.expect(p.len == 0 or std.mem.eql(u8, p, "/"));
        return;
    }
    try std.testing.expect(store_mod.relOk(rel));
}

test "fuzz fuse path gate denies cluster and traversal paths for every input" {
    try std.testing.fuzz({}, fuzzPathGateOne, .{ .corpus = &fuzz_path_corpus });
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

test "readdir omits names relOk would refuse" {
    // Origin filenames are bytes: a co-tenant can plant `a\nERROR.bin` or
    // `model\u{200b}.bin`. open/getattr already EPERM those via relOk; the
    // listing must not emit them either, or `ls /models` splits / spoofs.
    // NFC/NFD spellings and non-UTF-8 names stay visible (byte-exact identity).
    const gpa = std.testing.allocator;
    var db: [128]u8 = undefined;
    const scratch = try sys.scratchDir(&db, "modelfs-readdir-ctl");
    defer sys.deleteTree(std.testing.io, scratch);

    const files = [_][]const u8{
        "ok.bin",
        "a\nb.bin",
        "model\u{200b}.bin",
        "caf\u{e9}.bin",
        "cafe\u{301}.bin",
        "\xff\xfe.bin",
    };
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    for (files) |name| {
        const fp = try std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ scratch, name });
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), "x"));
    }
    const cluster_p = try std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ scratch, discover.cluster_dir });
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(cluster_p, 0o755));

    const dir = sys.opendirNoFollow(try sys.toZ(&zbuf, scratch)) orelse
        return error.TestUnexpectedResult;
    defer sys.closedir(dir);
    var names = OriginDirNames{ .dir = dir, .hide_cluster = true };
    var got: std.ArrayList([]const u8) = .empty;
    defer {
        for (got.items) |n| gpa.free(n);
        got.deinit(gpa);
    }
    while (names.next()) |n| {
        try got.append(gpa, try gpa.dupe(u8, n));
    }

    var seen_ok = false;
    var seen_nfc = false;
    var seen_nfd = false;
    var seen_raw = false;
    for (got.items) |n| {
        try std.testing.expect(store_mod.relOk(n));
        try std.testing.expect(!std.mem.eql(u8, n, discover.cluster_dir));
        try std.testing.expect(std.mem.indexOfScalar(u8, n, '\n') == null);
        try std.testing.expect(std.mem.indexOf(u8, n, "\u{200b}") == null);
        if (std.mem.eql(u8, n, "ok.bin")) seen_ok = true;
        if (std.mem.eql(u8, n, "caf\u{e9}.bin")) seen_nfc = true;
        if (std.mem.eql(u8, n, "cafe\u{301}.bin")) seen_nfd = true;
        if (std.mem.eql(u8, n, "\xff\xfe.bin")) seen_raw = true;
    }
    try std.testing.expect(seen_ok);
    try std.testing.expect(seen_nfc);
    try std.testing.expect(seen_nfd);
    try std.testing.expect(seen_raw);
    try std.testing.expectEqual(@as(usize, 4), got.items.len);
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
    const getattr_t0 = sys.monoNs(st.io);
    defer _ = st.store.stats.getattr_nanos.fetchAdd(@intCast(@max(sys.monoNs(st.io) - getattr_t0, 0)), .monotonic);
    const p = cPath(path);
    var rel: []const u8 = "";
    const rerr = resolveRel(p, -sys.c.ENOENT, &rel);
    if (rerr != 0) return rerr;
    var ost: sys.c.struct_stat = undefined;
    const rc = st.store.statOrigin(rel, &ost);
    if (rc != 0) {
        countMetaErr(st, rc);
        return rc;
    }
    // Same translated C type; a whole-struct assign keeps every stat field.
    if (stbuf) |out| out.* = ost;
    return 0;
}

fn cachedFor(st: *State, rel: []const u8) ?*store_mod.Store.Cached {
    var ost: sys.c.struct_stat = undefined;
    if (st.store.statOrigin(rel, &ost) != 0) return null;
    if ((ost.st_mode & sys.c.S_IFMT) != sys.c.S_IFREG) return null;
    const size = sys.sizeFromStat(ost.st_size) orelse return null;
    return st.store.getIdentified(rel, size, store_mod.OriginId.fromStat(ost), sys.monoSec(st.io)) catch null;
}

export fn mf_open(path: [*c]const u8, fi: ?*fuse.fuse_file_info) callconv(.c) c_int {
    _ = fi;
    const st = statePtr();
    const open_t0 = sys.monoNs(st.io);
    defer _ = st.store.stats.open_nanos.fetchAdd(@intCast(@max(sys.monoNs(st.io) - open_t0, 0)), .monotonic);
    const p = cPath(path);
    var rel: []const u8 = "";
    const rerr = resolveRel(p, -sys.c.ENOENT, &rel);
    if (rerr != 0) return rerr;
    var ost: sys.c.struct_stat = undefined;
    // Return the captured errno, like getattr/read do: re-reading errno here
    // would report whatever ran between the failed stat and this return.
    const rc = st.store.statOrigin(rel, &ost);
    if (rc != 0) {
        countMetaErr(st, rc);
        return rc;
    }
    if ((ost.st_mode & sys.c.S_IFMT) == sys.c.S_IFLNK) return -sys.c.ELOOP;
    if ((ost.st_mode & sys.c.S_IFMT) == sys.c.S_IFREG) {
        const size = sys.sizeFromStat(ost.st_size) orelse {
            std.log.warn("origin size unusable for {s}; failing open", .{rel});
            return -sys.c.EIO;
        };
        const file = st.store.getIdentified(rel, size, store_mod.OriginId.fromStat(ost), sys.monoSec(st.io)) catch |err| {
            std.log.warn("cache entry open failed for {s} ({t}); failing open", .{ rel, err });
            return -sys.c.ENOMEM;
        };
        defer st.store.releaseFile(file);
        const fd = st.store.openCache(file);
        if (fd < 0) {
            // Same best-effort warmup mf_create already uses: the origin
            // file is there, and mf_read falls back to origin when the
            // cache cannot land a fill. Failing open here turned a full or
            // broken cache disk into a total outage -- engines never reach
            // the read path that already degrades.
            std.log.warn("cache open failed for {s} (errno {d}); reads will use origin until the cache recovers", .{ rel, -fd });
        }
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
    // O_NOFOLLOW like every daemon write into a tree someone else can plant
    // names in: a symlink staged at this name on the shared origin must not
    // turn the create's O_TRUNC into a truncate of the link's target.
    // O_NONBLOCK: an existing FIFO at the name must not hang this handler.
    const fd = sys.open(op, sys.c.O_CREAT | sys.c.O_RDWR | sys.c.O_TRUNC | sys.c.O_NOFOLLOW | sys.c.O_NONBLOCK, clientCreateMode(mode));
    if (fd < 0) return sys.negErrno();
    const cr = sys.closeWrite(fd);
    // O_TRUNC replaced the origin bytes at this path. Cache identity is the
    // path, so a leftover sidecar at the previous size would decode cleanly
    // after a crash and a same-size rewrite -- the same resurrection
    // unlink/rename already prevent via forget. Drop trust before warmup so
    // an OOM on get cannot leave the old marks on disk. Pins and data stay:
    // the path is still the operator's pin target, and unmarked pieces
    // refill over the truncated origin. Distrust even when close failed:
    // the truncate already landed, and a leftover sidecar would resurrect
    // pre-create marks over the new inode.
    st.store.distrust(rel);
    if (cr != 0) return cr;
    // The origin create above already landed: failing the syscall here (entry
    // warmup OOM) would tell the caller the create failed over a file that
    // exists and was possibly truncated. Warmup is best-effort; the next
    // open/read rebuilds the entry.
    if (st.store.get(rel, 0, sys.monoSec(st.io))) |file| {
        st.store.releaseFile(file);
    } else |err| {
        std.log.warn("cache entry warmup failed for {s} ({t}); rebuilding on next open", .{ rel, err });
    }
    return 0;
}

fn originFillBuf(st: *State, file: *store_mod.Store.Cached, idx: u32, buf: []u8) i32 {
    const n = st.store.originPread(file.rel, buf, piece.offset(idx, st.store.piece_size));
    if (n == @as(isize, @intCast(buf.len))) return 0;
    st.store.finishPiece(file, idx, false, null, sys.monoSec(st.io));
    _ = st.store.stats.fill_err_origin.fetchAdd(1, .monotonic);
    // The reader sees EIO and nothing else names the cause; keep the
    // same sender-side trace serveData's hydration branch does,
    // distinguishing a real errno from a short read.
    if (n < 0)
        std.log.warn("origin fill failed for {s} piece {d} (errno {d}); failing read", .{ file.rel, idx, -n })
    else
        std.log.warn("origin fill short for {s} piece {d} ({d}/{d} bytes); failing read", .{ file.rel, idx, n, buf.len });
    if (n < 0) return @intCast(n);
    return -sys.c.EIO;
}

/// Extra fill attempts after completeFill discards a claim because a local
/// write bumped the generation. The first retry is from origin so a peer
/// fill cannot overwrite in-flight write-through bytes; a second discard
/// fails the read instead of spinning the FUSE worker for as long as
/// writers keep landing.
const fill_discard_retries_max: u32 = 1;

fn hydratePiece(st: *State, file: *store_mod.Store.Cached, idx: u32, scratch: []u8) i32 {
    // piece.len() never exceeds piece_size, even when a concurrent append
    // grows the tail piece after cover() was computed, so the caller's
    // piece-size scratch always fits. An allocation failure claiming the
    // piece must fail this read with ENOMEM rather than hang: beginFill
    // surfaces claim OOM instead of retrying it forever.
    // Claim and completion are separate clock samples on purpose: a slow
    // fill must land a fresh recency stamp (finishPiece), not the claim's
    // pre-transfer one, or a piece that filled for minutes is born punchable.
    // Miss latency is claim-to-cache-write: exactly the stall the reader
    // eats for this piece. Failed fills keep their error counts and no time.
    const fill_t0 = sys.monoNs(st.io);
    var from_peer = false;
    var prefer_origin = st.store.wroteLocally(file);
    var piece_len: u32 = 0;
    var discard_retries: u32 = 0;
    while (true) {
        if (file.dead.load(.acquire)) return 0;
        const cl = st.store.beginFill(file, idx, sys.monoSec(st.io)) catch |err| {
            std.log.warn("fill claim failed for {s} piece {d} ({t}); failing read", .{ file.rel, idx, err });
            return -sys.c.ENOMEM;
        };
        piece_len = switch (cl) {
            // Filled by someone else, or a truncate shrank the file below the
            // piece between claim and sample (the claim was dropped unmarked):
            // report success either way -- the bounds-checked read below then
            // returns a short count against the new size. Passing an empty
            // buffer onward would underflow fillFromPeers' range end computation
            // (out.len - 1) and abort the daemon.
            .filled, .raced => return 0,
            .len => |n| n,
        };
        // beginFill's .len arm already dropped a zero-length (past-EOF) claim
        // as .raced, and piece.len never exceeds the piece grid.
        std.debug.assert(piece_len > 0);
        std.debug.assert(piece_len <= scratch.len);
        const buf = scratch[0..piece_len];
        from_peer = !prefer_origin;
        var expect: ?[piece.digest_len]u8 = null;
        if (from_peer) {
            // R2: a peer fill is only admissible when a trusted digest exists
            // to verify it against (learned from the origin manifest, a prior
            // origin fill, or this node's own write-through). Without one the
            // bytes are unverifiable, so the piece hydrates from origin -- the
            // trust root -- instead of accepting peer bytes blindly. expectedHash
            // loads the manifest lazily (one origin read per entry size), so a
            // cold entry can verify peer fills from the start.
            expect = st.store.expectedHash(file, idx, sys.monoMs(st.io));
            if (expect == null) from_peer = false;
        }
        if (from_peer) {
            peer.fillFromPeers(st.gpa, st.server.psk, &st.catalog, file.rel, idx, st.store.piece_size, buf, &st.store.stats) catch |err| {
                // NoPeer is the expected fleet-wide miss (already warned per
                // candidate inside fetchFromCands); anything else -- an
                // allocation failure while probing, say -- must not read as
                // a healthy fallback.
                if (err != error.NoPeer)
                    std.log.warn("peer fill failed for {s} piece {d} ({t}); refilling from origin", .{ file.rel, idx, err });
                from_peer = false;
            };
        }
        var filled_digest: [piece.digest_len]u8 = undefined;
        if (from_peer) {
            // Verify before admit: the fetched bytes must match the trusted
            // digest or they are discarded unmarked (a hostile peer, an
            // on-path rewriter, or a peer serving its own corrupt cache), and
            // the piece refills from origin -- whose bytes are authoritative
            // and get a fresh digest recorded at admit.
            piece.digest(buf, &filled_digest);
            const exp = expect.?;
            if (!std.mem.eql(u8, &filled_digest, &exp)) {
                _ = st.store.stats.fill_err_verify.fetchAdd(1, .monotonic);
                std.log.warn("piece {s} {d} failed digest verification; refilling from origin", .{ file.rel, idx });
                from_peer = false;
            }
        }
        if (!from_peer) {
            const oe = originFillBuf(st, file, idx, buf);
            if (oe != 0) return oe;
            // Origin bytes are the trust root: their digest is the trusted
            // reference for every later fill of this piece, recorded at admit
            // with the bit. Not compared against `expect` -- a rewrite with
            // the same size legitimately changes bytes, and origin wins.
            piece.digest(buf, &filled_digest);
        }
        const rc = st.store.completeFill(file, idx, buf, filled_digest, sys.monoSec(st.io));
        if (rc != 0) {
            // Hydrated bytes the cache fs refused: the piece stays unmarked and
            // the reader gets EIO, so name the refusal like serveData's twin
            // branch. Failed fills keep their error counts and no time (and no
            // fill or byte totals): the tick line's averages stay miss-only.
            _ = st.store.stats.fill_err_cache.fetchAdd(1, .monotonic);
            std.log.warn("cache write refused {s} piece {d} (errno {d}); piece unmarked", .{ file.rel, idx, -rc });
            return rc;
        }
        if (st.store.hasPiece(file, idx, sys.monoSec(st.io))) break;
        // A local write-through discarded this fill (peer bytes would have
        // overwritten it). One origin retry is the intended recovery; looping
        // past that would stall this FUSE worker for as long as writers keep
        // bumping the generation, and returning 0 unmarked would serve hole
        // zeros. Fail the read so the client retries.
        if (discard_retries >= fill_discard_retries_max) {
            std.log.warn("fill discarded for {s} piece {d} after origin retry; piece unmarked", .{ file.rel, idx });
            return -sys.c.EIO;
        }
        discard_retries += 1;
        prefer_origin = true;
        from_peer = false;
        sys.sleepMs(st.io, 2);
    }
    // Counted per fill instead of logged: a single model read covers hundreds
    // of pieces, and the totals land in status.json and the discovery tick's
    // summary line. Failures keep their own warns at the failure sites.
    const s = &st.store.stats;
    // Sampled after the cache write lands: the published average is the full
    // claim-to-cache-write stall the reader ate for this piece.
    const fill_dt: u64 = @intCast(@max(sys.monoNs(st.io) - fill_t0, 0));
    if (from_peer) {
        _ = s.fills_peer.fetchAdd(1, .monotonic);
        _ = s.bytes_from_peer.fetchAdd(piece_len, .monotonic);
        _ = s.fill_peer_nanos.fetchAdd(fill_dt, .monotonic);
    } else {
        _ = s.fills_origin.fetchAdd(1, .monotonic);
        _ = s.bytes_from_origin.fetchAdd(piece_len, .monotonic);
        _ = s.fill_origin_nanos.fetchAdd(fill_dt, .monotonic);
    }
    return 0;
}

/// `file_size` must be a size sample taken under file.mu by the caller (the
/// same sample that bounded `span`): cover() then agrees with the bounds
/// check instead of racing a concurrent truncate on an unlocked file.size
/// read.
fn ensureRange(st: *State, file: *store_mod.Store.Cached, span: piece.Span, file_size: u64) i32 {
    const cov = piece.cover(span, file_size, st.store.piece_size);
    if (cov.start >= cov.end) return 0;
    // One reusable buffer for every hydrated piece in the range, allocated
    // only when some covered piece actually lacks its bit: warm reads (every
    // piece cached) previously paid a piece-sized alloc/free per call.
    var scratch: ?[]u8 = null;
    defer if (scratch) |s| st.gpa.free(s);
    var i = cov.start;
    while (i < cov.end) : (i += 1) {
        if (st.store.hasPiece(file, i, sys.monoSec(st.io))) continue;
        if (scratch == null)
            scratch = st.gpa.alloc(u8, st.store.piece_size) catch {
                // Same operator-trace contract as hydratePiece's claim OOM
                // and serveData's hydration-buffer OOM: the reader sees
                // ENOMEM and reads_err moves, so the journal must name why.
                std.log.warn("hydration buffer alloc failed for {s}; failing read", .{file.rel});
                return -sys.c.ENOMEM;
            };
        const rc = hydratePiece(st, file, i, scratch.?);
        if (rc != 0) return rc;
    }
    return 0;
}

/// Serve `buf` at `span.off` after hydrating any missing pieces. A failed
/// fill (dead/full cache, discarded claim) must not black-hole a healthy
/// origin: `readServed` already degrades a failed cache pread, and this is
/// the matching miss-path policy. Returning the hydration errno without
/// the origin read turned a cache-disk failure into a total read outage.
/// Origin-down fails here too: `originPread` returns the same class of
/// error, and the caller publishes the hydration errno so the first
/// failure stays named.
fn serveHydrated(
    st: *State,
    file: *store_mod.Store.Cached,
    rel: []const u8,
    buf: []u8,
    span: piece.Span,
    file_size: u64,
    ready: bool,
) isize {
    std.debug.assert(span.len == buf.len);
    const rc = if (ready) 0 else ensureRange(st, file, span, file_size);
    if (rc == 0) return st.store.readServed(file, buf, span.off, sys.monoSec(st.io));
    const got = st.store.originPread(rel, buf, span.off);
    if (got >= 0) {
        std.log.warn("hydration failed for {s} (errno {d}); serving this read from origin", .{ rel, -rc });
        return got;
    }
    return rc;
}

/// Live cache entry for a FUSE read, or an errno. A referenced entry is
/// returned without restatting origin: open and getattr already sampled it,
/// and a getattr RTT on every 128 KiB read would make the warm NVMe path
/// pay NFS. Size changes through the mount update the entry in place
/// (`cacheFill`, `mf_truncate`); an external origin rewrite is visible on
/// the next open, matching NFS close-to-open. A cold path (no live entry)
/// still stats origin so the first read of an unopened file, and every
/// read after reapIdle dropped the entry, keep their previous errno.
fn fileForRead(st: *State, rel: []const u8) union(enum) { err: c_int, file: *store_mod.Store.Cached } {
    if (st.store.lookupRef(rel)) |file| return .{ .file = file };
    // Report the real origin failure (EIO on NFS, ENOENT, ...): collapsing it
    // into EISDIR would send readers hunting for a directory that is not there.
    var ost: sys.c.struct_stat = undefined;
    const rc_stat = st.store.statOrigin(rel, &ost);
    // Edge-triggered origin_down lives in statOrigin: path-level answers
    // (ENOENT, ELOOP, ...) stay counted here but do not raise the flag
    // (see Store.originIoOutage).
    if (rc_stat != 0) {
        // An origin outage fails every uncached read here before any tier
        // runs; without this count reads_err stays flat while clients see
        // an EIO storm.
        _ = st.store.stats.reads_err.fetchAdd(1, .monotonic);
        return .{ .err = rc_stat };
    }
    if ((ost.st_mode & sys.c.S_IFMT) != sys.c.S_IFREG) return .{ .err = -sys.c.EISDIR };
    const origin_size = sys.sizeFromStat(ost.st_size) orelse {
        _ = st.store.stats.reads_err.fetchAdd(1, .monotonic);
        std.log.warn("origin size unusable for {s}; failing read", .{rel});
        return .{ .err = -sys.c.EIO };
    };
    const file = st.store.getIdentified(rel, origin_size, store_mod.OriginId.fromStat(ost), sys.monoSec(st.io)) catch |err| {
        _ = st.store.stats.reads_err.fetchAdd(1, .monotonic);
        std.log.warn("cache entry open failed for {s} ({t}); failing read", .{ rel, err });
        return .{ .err = -sys.c.ENOMEM };
    };
    return .{ .file = file };
}

export fn mf_read(path: [*c]const u8, buf: [*c]u8, size: usize, off: fuse.off_t, fi: ?*fuse.fuse_file_info) callconv(.c) c_int {
    _ = fi;
    if (buf == null) return -sys.c.EFAULT;
    const st = statePtr();
    // Latency covers the whole handler: warm reads too, so the tick line's
    // average tracks real reader-perceived latency, not just miss stalls.
    const rd_t0 = sys.monoNs(st.io);
    defer _ = st.store.stats.read_nanos.fetchAdd(@intCast(@max(sys.monoNs(st.io) - rd_t0, 0)), .monotonic);
    var rel: []const u8 = "";
    const rerr = resolveRel(cPath(path), -sys.c.ENOENT, &rel);
    if (rerr != 0) return rerr;
    const opened = fileForRead(st, rel);
    const file = switch (opened) {
        .err => |e| return e,
        .file => |f| f,
    };
    defer st.store.releaseFile(file);
    const want = @min(size, @as(usize, std.math.maxInt(c_int)));
    if (off < 0) return -sys.c.EINVAL;
    const uoff: u64 = @intCast(off);
    // Hold xfer from the bit sample through the cache pread: recency
    // stamping alone cannot cover a straddling read whose next piece
    // hydrates past recency_secs, or a FUSE worker descheduled between
    // rangeFilled and readCache. punchPiece and copyIntoCache both refuse
    // the cache fd while this is nonzero.
    st.store.beginXfer(file);
    defer st.store.endXfer(file);
    // One size sample under file.mu: truncate/reconcileSize shrink it
    // concurrently, and reading it twice unlocked can pass the bounds check
    // on the old value then underflow the subtraction on the new one.
    file.mu.lockUncancelable(st.io);
    const fsize = file.size;
    // Checking the covered bits in this same window lets a fully-cached
    // range skip ensureRange's per-piece lock (hasPiece stamps and
    // re-checks what we already know). last_access still feeds LRU.
    file.last_access.store(sys.monoSec(st.io), .monotonic);
    if (uoff >= fsize) {
        file.mu.unlock(st.io);
        return 0;
    }
    const n = @min(want, @as(usize, @intCast(fsize - uoff)));
    const ready = store_mod.Store.rangeFilled(file, .{ .off = uoff, .len = @as(u64, n) }, fsize, st.store.piece_size);
    file.mu.unlock(st.io);
    const got = serveHydrated(st, file, rel, buf[0..n], .{ .off = uoff, .len = n }, fsize, ready);
    if (got < 0) {
        // The failing tier kept its own fill_err_* count; the op-level
        // counter must still see the read fail, or error-rate alerts keying
        // on reads_err miss exactly the EIO storms users feel.
        _ = st.store.stats.reads_err.fetchAdd(1, .monotonic);
    } else {
        _ = st.store.stats.reads_ok.fetchAdd(1, .monotonic);
        _ = st.store.stats.bytes_read.fetchAdd(@intCast(got), .monotonic);
        if (ready) _ = st.store.stats.reads_warm.fetchAdd(1, .monotonic);
    }
    return @intCast(got);
}

export fn mf_write(path: [*c]const u8, buf: [*c]const u8, size: usize, off: fuse.off_t, fi: ?*fuse.fuse_file_info) callconv(.c) c_int {
    _ = fi;
    if (buf == null) return -sys.c.EFAULT;
    const st = statePtr();
    // Same whole-handler coverage as mf_read: origin pwrite is the stall,
    // and wr_us on the tick line is the only way to see writes got slow.
    const wr_t0 = sys.monoNs(st.io);
    defer _ = st.store.stats.write_nanos.fetchAdd(@intCast(@max(sys.monoNs(st.io) - wr_t0, 0)), .monotonic);
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
    const rc = st.store.statOrigin(rel, &ost);
    const regular = rc == 0 and (ost.st_mode & sys.c.S_IFMT) == sys.c.S_IFREG;
    const osize: ?u64 = if (regular) sys.sizeFromStat(ost.st_size) else null;
    if (osize) |sz| {
        if (sz == end) {
            st.store.cacheFillIdentified(rel, end, uoff, buf[0..@intCast(n)], store_mod.OriginId.fromStat(ost), sys.monoSec(st.io));
            return @intCast(n);
        }
    }
    // One referenced entry for every remaining shape, resolved from the stat
    // sample this handler already paid for. The old shape stat'ed the origin
    // a second time through cachedFor on this path; each write's open-pwrite-
    // close cycle invalidates the NFS client's attribute cache, so both stats
    // were real GETATTR round trips -- two per written chunk whenever the
    // observed size lagged the write (the common ingest shape).
    const live = blk: {
        if (osize) |sz|
            break :blk st.store.getIdentified(rel, sz, store_mod.OriginId.fromStat(ost), sys.monoSec(st.io)) catch null;
        // Failed observation: one retry through cachedFor's own stat before
        // trust is dropped below, so a single flaky GETATTR cannot wipe marks.
        break :blk cachedFor(st, rel);
    };
    if (live) |file| {
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
        file.last_access.store(sys.monoSec(st.io), .monotonic);
        file.mu.unlock(st.io);
        // The origin write already succeeded, so a failed cache copy only
        // costs re-hydration; the helper logs it and skips piece marking.
        _ = st.store.copyIntoCache(file, uoff, buf[0..@intCast(n)]);
        if (regular) st.store.noteOriginId(file, store_mod.OriginId.fromStat(ost));
        return @intCast(n);
    }
    // Neither a matching size observation nor a live cache entry landed:
    // the entry's bits can no longer be proven to describe this inode's
    // post-write contents, so drop them instead of silently serving
    // pre-write bytes as current. The write itself already succeeded, so
    // the syscall still reports n. This path is also get() OOM after a
    // successful stat (size mismatch), not only a failed GETATTR.
    std.log.warn("post-write cache could not be updated for {s}; cache marks dropped, pieces refill", .{rel});
    st.store.distrust(rel);
    return @intCast(n);
}

export fn mf_fsync(path: [*c]const u8, datasync: c_int, fi: ?*fuse.fuse_file_info) callconv(.c) c_int {
    _ = fi;
    const st = statePtr();
    var rel: []const u8 = "";
    // Lookup-shaped denial: open/write on /.cluster already fail ENOENT,
    // so fsync must not leak that the control dir exists, and must not
    // COMMIT lease files a FUSE client cannot see.
    const rerr = resolveRel(cPath(path), -sys.c.ENOENT, &rel);
    if (rerr != 0) return rerr;
    return st.store.originFsync(rel, datasync != 0);
}

export fn mf_release(path: [*c]const u8, fi: ?*fuse.fuse_file_info) callconv(.c) c_int {
    _ = fi;
    const st = statePtr();
    var rel: []const u8 = "";
    // Same lookup-shaped denial as every other op: a release on a hidden
    // `.cluster` name must not publish anything.
    const rerr = resolveRel(cPath(path), 0, &rel);
    if (rerr != 0 or rel.len == 0) return 0;
    if (st.store.lookupRef(rel)) |file| {
        defer st.store.releaseFile(file);
        // Close-to-open (design.md 4.4): the close of a file this node wrote
        // or filled is the natural moment to publish the piece-hash manifest
        // that makes the fleet's peer fills verifiable. publishManifest
        // no-ops unless hashes changed since the last publish; read-only
        // releases and unchanged entries cost one lock + map-count probe.
        st.store.publishManifest(file);
    }
    return 0;
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
    // O_NOFOLLOW: the ftruncate below must land on the named origin file,
    // never on a planted symlink's target (arbitrary daemon-writable file).
    // O_NONBLOCK: a FIFO at the name must not hang this handler.
    const fd = sys.open(op, sys.c.O_WRONLY | sys.c.O_NOFOLLOW | sys.c.O_NONBLOCK, 0);
    if (fd < 0) return sys.negErrno();
    const origin_tr = sys.ftruncate(fd, new_size);
    const cr = sys.closeWrite(fd);
    if (origin_tr != 0) return origin_tr;
    if (cr != 0) return cr;
    // Map lookup must take store.mu; lookupRef also pins the entry against
    // eviction for the duration of the truncate.
    const live = st.store.lookupRef(rel);
    if (live) |file| {
        defer st.store.releaseFile(file);
        // content_mu first, then file.mu: the same order copyIntoCache,
        // completeFill, and punchPiece use. Taking only file.mu let a
        // concurrent write-through pwrite land, then this ftruncate cut
        // those bytes, then the mark published the hole as cached data.
        file.content_mu.lockUncancelable(st.io);
        defer file.content_mu.unlock(st.io);
        file.mu.lockUncancelable(st.io);
        defer file.mu.unlock(st.io);
        if (file.size == new_size) {
            // Already applied: a FUSE retry after a lost reply, or a no-op
            // truncate to the current size. Re-wiping bits would discard
            // pieces re-hydrated after the first truncate to this size.
            store_mod.Store.truncateCacheFd(file, new_size);
            return 0;
        }
        const nb = piece.Bitfield.init(st.gpa, piece.count(new_size, st.store.piece_size)) catch {
            // Origin is already the new length. Leaving filled bits at the
            // old size would let a concurrent read serve pre-truncate cache
            // bytes past the new EOF. Wipe marks now; shrink the recorded
            // size when we can do that without growing an undersized field.
            // truncateCacheFd, not a raw ftruncate: a peer /data sendfile
            // holds xfer and is reading this fd without file.mu.
            @memset(file.bits.bytes, 0);
            file.writes += 1;
            st.store.clearHashes(file);
            if (new_size < file.size) file.size = new_size;
            _ = st.store.saveBits(file, false);
            store_mod.Store.truncateCacheFd(file, file.size);
            std.log.warn("bitfield alloc failed for {s} after truncate; cache marks dropped, pieces refill", .{rel});
            return -sys.c.ENOMEM;
        };
        var ob = file.bits;
        file.size = new_size;
        file.bits = nb;
        file.writes += 1;
        // Digests described the pre-truncate bytes; the refills that follow
        // record fresh ones against the new size.
        st.store.clearHashes(file);
        // Save while the new bits are still under the lock: saveBits encodes
        // size/bits and must never race the swap below (or another thread's
        // encode) on freed storage. The fd truncate shares this window so
        // cache_fd cannot be closed between check and use. Best-effort save:
        // a lost sidecar here only costs refill, never stale bytes.
        _ = st.store.saveBits(file, false);
        store_mod.Store.truncateCacheFd(file, new_size);
        ob.deinit(st.gpa);
    } else {
        // No live entry: origin is already the new length, but a leftover
        // sidecar at the previous size would decode cleanly if the file is
        // later restored to that length. Same identity drop unlink/rename
        // use via forget, and create uses via distrust: drop persisted
        // marks, keep data/pins.
        st.store.distrust(rel);
    }
    return 0;
}

export fn mf_unlink(path: [*c]const u8) callconv(.c) c_int {
    const st = statePtr();
    const p = cPath(path);
    var rel: []const u8 = "";
    const rerr = resolveRel(p, -sys.c.EPERM, &rel);
    if (rerr != 0) return rerr;
    return st.store.unlinkOrigin(rel);
}

export fn mf_mkdir(path: [*c]const u8, mode: fuse.mode_t) callconv(.c) c_int {
    const st = statePtr();
    const p = cPath(path);
    var rel: []const u8 = "";
    const rerr = resolveRel(p, -sys.c.EPERM, &rel);
    if (rerr != 0) return rerr;
    return st.store.mkdirOrigin(rel, clientCreateMode(mode));
}

export fn mf_rmdir(path: [*c]const u8) callconv(.c) c_int {
    const st = statePtr();
    const p = cPath(path);
    var rel: []const u8 = "";
    const rerr = resolveRel(p, -sys.c.EPERM, &rel);
    if (rerr != 0) return rerr;
    return st.store.rmdirOrigin(rel);
}

export fn mf_rename(old: [*c]const u8, new: [*c]const u8, flags: c_uint) callconv(.c) c_int {
    const st = statePtr();
    var orel: []const u8 = "";
    var nrel: []const u8 = "";
    const oerr = resolveRel(cPath(old), -sys.c.EPERM, &orel);
    if (oerr != 0) return oerr;
    const nerr = resolveRel(cPath(new), -sys.c.EPERM, &nrel);
    if (nerr != 0) return nerr;
    // Namespace ops present the origin's own rename semantics, flags
    // included: the kernel routes RENAME_NOREPLACE/EXCHANGE through FUSE's
    // rename2 and libfuse forwards them here. Dropping them would silently
    // overwrite a destination the caller asked to keep (mv -n, cp -n) or
    // move instead of swap (renameat2 EXCHANGE). Cache drop on both names,
    // including when the origin rename returns ENOENT, is Store.renameOrigin.
    return st.store.renameOrigin(orel, nrel, flags);
}

export fn mf_chmod(path: [*c]const u8, mode: fuse.mode_t, fi: ?*fuse.fuse_file_info) callconv(.c) c_int {
    _ = fi;
    const st = statePtr();
    var rel: []const u8 = "";
    // Mutation-shaped denial: chmod on lease files was reachable here even
    // though create/unlink deny the same paths.
    const rerr = resolveRel(cPath(path), -sys.c.EPERM, &rel);
    if (rerr != 0) return rerr;
    // Same mask as create/mkdir (see clientCreateMode): chmod(2) honors
    // S_ISUID/S_ISGID on the daemon-owned origin file exactly like the
    // create modes do, so an unmasked mode here would let a mount writer
    // plant the special bit one step after a masked create.
    var buf: [sys.c.PATH_MAX]u8 = undefined;
    const op = st.store.originPath(&buf, rel) catch return -sys.c.ENAMETOOLONG;
    // sys.chmod opens O_NOFOLLOW then fchmods the fd: a planted origin
    // symlink (or a racer swapping the name after a lstat) must not route
    // the daemon's chmod onto the link's target. ELOOP matches O_NOFOLLOW.
    return sys.chmod(op, clientCreateMode(mode));
}

/// A READDIR contract has two valid modes: ignore the offset and stamp
/// every entry zero (only legal when the whole listing fits one reply), or
/// track offsets and resume where the kernel asks. This walk implements the
/// second: a listing of a models directory past one reply (~32-128 KiB of
/// fuse_dirent records) used to stamp every entry offset 0, so the kernel's
/// next READDIR resumed at 0 and re-received the head of the directory
/// forever -- duplicates without end in ls/readdir(3). Entries carry stable
/// 1-based ordinals (".", "..", then origin order); entries at or below the
/// incoming offset are skipped and emitted entries carry their ordinal,
/// which is exactly the value the kernel returns to resume after them.
/// Separate from ll_readdir so the resume contract is drivable in tests
/// without mounting.
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
/// to the mount (dot entries, the control dir at the root, and names
/// `store.relOk` would refuse) is filtered here, so the resume ordinals
/// count only emittable names. A planted origin file `a\nERROR.bin` or
/// `model\u{200b}.bin` cannot be opened through the mount (resolveRel
/// returns EPERM); listing it would still inject into `ls` / readdir(3).
const OriginDirNames = struct {
    dir: *anyopaque,
    hide_cluster: bool,

    fn next(self: *OriginDirNames) ?[]const u8 {
        while (sys.readdir(@ptrCast(self.dir))) |ent| {
            const name = sys.dirName(ent);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (self.hide_cluster and std.mem.eql(u8, name, discover.cluster_dir)) continue;
            if (!store_mod.relOk(name)) continue;
            return name;
        }
        return null;
    }
};

export fn mf_statfs(path: [*c]const u8, stbuf: ?*fuse.struct_statvfs) callconv(.c) c_int {
    const st = statePtr();
    const statfs_t0 = sys.monoNs(st.io);
    defer _ = st.store.stats.statfs_nanos.fetchAdd(@intCast(@max(sys.monoNs(st.io) - statfs_t0, 0)), .monotonic);
    var rel: []const u8 = "";
    // Lookup-shaped denial: /.cluster is hidden from readdir and getattr.
    const rerr = resolveRel(cPath(path), -sys.c.ENOENT, &rel);
    if (rerr != 0) return rerr;
    var vs: sys.c.struct_statvfs = undefined;
    const rc = st.store.originStatvfs(rel, &vs);
    if (rc != 0) return rc;
    if (stbuf) |out| out.* = vs;
    return 0;
}

export fn ll_init(ud: ?*anyopaque, conn: ?*fuse.fuse_conn_info) callconv(.c) void {
    _ = conn;
    const st: *State = @ptrCast(@alignCast(ud));
    tls_state = st;
    st.init_seen.store(true, .release);
    // First point that is guaranteed to be the final (post-fork) process:
    // background workers must start here or --detach loses them.
    st.spawnWorkers();
}

export fn ll_destroy(ud: ?*anyopaque) callconv(.c) void {
    const st: *State = @ptrCast(@alignCast(ud));
    st.running.store(false, .release);
    st.server.stop();
}

/// One discovery-tick origin sample: publish then refresh, then feed the
/// combined errno into origin_down / lease_err. An idle node never getattr's,
/// so without this the origin health gauge stays 0 until the first client
/// I/O even though the tick already wrote the origin. Mount startup uses
/// the same helper so a dead NFS is visible in status.json before the
/// first FUSE op.
pub fn tickCluster(st: *State, now: i64) void {
    st.catalog.publish(now);
    if (st.catalog.publish_rc != 0)
        _ = st.store.stats.lease_err.fetchAdd(1, .monotonic);
    st.catalog.refresh(now);
    st.store.noteOriginIo(discover.cluster_dir, st.catalog.originErrno(), "lease");
}

fn countMetaErr(st: *State, rc: i32) void {
    if (rc < 0 and store_mod.Store.originIoOutage(-rc))
        _ = st.store.stats.meta_err.fetchAdd(1, .monotonic);
}

/// Sleeps up to ms in 100ms slices, bailing out early once the daemon stops:
/// a plain sleepMs would keep shutdown waiting out the full tick.
fn napMs(st: *State, ms: u32) void {
    var waited: u32 = 0;
    while (waited < ms and st.running.load(.acquire)) : (waited += 100)
        sys.sleepMs(st.io, @min(ms - waited, 100));
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
    var last_reap = sys.monoSec(st.io);
    while (st.running.load(.acquire)) {
        // One monotonic instant per round: the reap gate, reapIdle's cutoff,
        // its reschedule stamp, and every cullOne recency decision below run
        // on this sample instead of four reads drifting across the round.
        // punchPiece/cullOne/reapIdle take the instant in precisely so their
        // decisions stay pure functions of state plus one clock sample
        // (see store.zig), which only holds if the driver samples once.
        const now = sys.monoSec(st.io);
        if (now -| last_reap >= reap_every_secs) {
            st.store.reapIdle(now, reap_idle_secs);
            last_reap = now;
        }
        const free_pct = st.store.freePercentChecked() orelse {
            if (!statfs_failing) std.log.err("cache statvfs failed on {s}; culling suspended", .{st.store.cache});
            statfs_failing = true;
            napMs(st, 2000);
            continue;
        };
        // Closure for the suspension line above: without it a suspended
        // stretch reads as permanent -- nothing in the journal ever says
        // culling came back after the cache fs healed or was remounted.
        if (statfs_failing) std.log.info("cache statvfs recovered on {s}; culling resumed", .{st.store.cache});
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
    var last_peers: u32 = 0;
    while (st.running.load(.acquire)) {
        // One wall-clock instant per tick: publish and refresh's expiry
        // filter decide against the same sample instead of two reads
        // drifting across the tick. Sweep prefers this node's own lease
        // mtime on the origin (NAS clock) and uses `now` only when that
        // file is missing.
        const now = sys.nowSec(st.io);
        tickCluster(st, now);
        st.catalog.sweepLeases(now);
        // Membership is a gauge, not a counter, so it never moves the tick
        // line. An idle node that loses every peer would otherwise stay
        // silent until the next fill fell through to NFS.
        const npeers = st.catalog.peerCount();
        if (npeers != last_peers) {
            std.log.info("cluster peers {d} -> {d}", .{ last_peers, npeers });
            last_peers = npeers;
        }
        writeStatus(st);
        logStatsTick(st, &last_stats);
        napMs(st, 10_000);
    }
}

/// Mean of `total` time in `unit` ticks per op. Divides by the unit first so
/// `count * unit` cannot overflow u64 (debug panic / wrapped average).
/// Equivalent to `total / (count * unit)` for positive integers.
fn meanPerOp(total: u64, count: u64, unit: u64) u64 {
    if (count == 0 or unit == 0) return 0;
    return @divTrunc(@divTrunc(total, unit), count);
}

/// One summary line per discovery tick, and only when some counter moved:
/// the daemon's activity heartbeat. Per-event logging at piece granularity
/// would flood the journal (one model read covers hundreds of pieces), so
/// steady-state work is aggregated here while failures keep their own
/// immediate warns. Deltas name the last interval, so a stalled ingest or a
/// read storm is visible straight from the journal; rd_us/wr_us and the
/// fill_ms pair and http_us are per-op averages over those deltas, the
/// latency signals this daemon publishes.
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
    const rd_us = meanPerOp(d.read_nanos, reads_attempted, std.time.ns_per_us);
    const writes_attempted = d.writes_ok + d.writes_err;
    const wr_us = meanPerOp(d.write_nanos, writes_attempted, std.time.ns_per_us);
    const fill_peer_ms = meanPerOp(d.fill_peer_nanos, d.fills_peer, std.time.ns_per_ms);
    const fill_origin_ms = meanPerOp(d.fill_origin_nanos, d.fills_origin, std.time.ns_per_ms);
    const http_attempted = d.http_ok + d.http_5xx;
    const http_us = meanPerOp(d.http_nanos, http_attempted, std.time.ns_per_us);
    // Total, not a mean: the metadata handlers count wall time but not calls,
    // and a tick fires on any counter moving. Without this field a
    // metadata-only interval logs a line of zeros.
    const md_us = @divTrunc(d.getattr_nanos + d.open_nanos + d.statfs_nanos, std.time.ns_per_us);
    // Format into a buffer then log one string: std.log.info is capped at
    // 32 format args, and the tick already named more Snap fields than that.
    var line_buf: [1536]u8 = undefined;
    var w = std.Io.Writer.fixed(&line_buf);
    // Field names mirror Stats.Snap's (what status.json publishes), so
    // the journal line and the machine artifact share one vocabulary and
    // no key collides ("err" used to name both read and write failures).
    w.print(
        "tick: reads_ok={d} reads_err={d} reads_warm={d} read_mib={d} rd_us={d} writes_ok={d} writes_err={d} write_mib={d} wr_us={d}" ++
            " fills peer={d} nfs={d} fill_ms peer/nfs={d}/{d} fill_err peer/nfs/cache/verify={d}/{d}/{d}/{d}",
        .{
            d.reads_ok,
            d.reads_err,
            d.reads_warm,
            @divTrunc(d.bytes_read, mib),
            rd_us,
            d.writes_ok,
            d.writes_err,
            @divTrunc(d.bytes_written, mib),
            wr_us,
            d.fills_peer,
            d.fills_origin,
            fill_peer_ms,
            fill_origin_ms,
            d.fill_err_peer,
            d.fill_err_origin,
            d.fill_err_cache,
            d.fill_err_verify,
        },
    ) catch return;
    w.print(
        " probe_err={d} lease_err={d} peer_mib={d} origin_mib={d} serve_mib={d} serve_verify_fail={d} culled={d} httpok={d} http401={d} http5xx={d} httpbad={d} httpdrop={d} http405={d} http_us={d} md_us={d} meta_err={d}",
        .{
            d.probe_err,
            d.lease_err,
            @divTrunc(d.bytes_from_peer, mib),
            @divTrunc(d.bytes_from_origin, mib),
            @divTrunc(d.bytes_to_peer, mib),
            d.serve_verify_fail,
            d.pieces_culled,
            d.http_ok,
            d.http_unauthorized,
            d.http_5xx,
            d.http_malformed,
            d.http_dropped,
            d.http_405,
            http_us,
            md_us,
            d.meta_err,
        },
    ) catch return;
    std.log.info("{s}", .{w.buffered()});
}

fn writeStatus(st: *State) void {
    // A silent failure here makes `modelfs status` claim the daemon is not
    // running, so any stage failing must reach the operator's log.
    statusJson(st) catch |err| std.log.warn("status.json update failed: {t}", .{err});
}

fn statusJson(st: *State) !void {
    var buf: [4096]u8 = undefined;
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
    const origin_down: i32 = if (st.store.origin_io_down.load(.monotonic)) 1 else 0;
    // Single line like every other machine-read artifact here: consumers
    // tail/grep it and a multi-line document would break line-oriented
    // parsing (journalctl, jq -line, watch loops). The stats object is
    // emitted from Stats.Snap's fields (the same list logStatsTick diffs),
    // so a new counter publishes here by construction instead of by
    // remembering to edit this document's format string.
    // One pair of samples for the whole document: uptime_s and mono_s share
    // the monotonic instant, and now_s is the matching wall-clock read.
    // mono_s is the wedge gate (same-machine CLOCK_MONOTONIC, immune to NTP
    // steps); now_s stays the human/monitor wall stamp.
    const now_mono = sys.monoSec(st.io);
    const now_wall = sys.nowSec(st.io);
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{{\"id\":\"{s}\",\"pid\":{d},\"uptime_s\":{d},\"peers\":{d},\"piece\":{d},\"inflight\":{d},\"cache_free_pct\":{d},\"origin_down\":{d},\"now_s\":{d},\"mono_s\":{d},\"stats\":{{", .{
        st.catalog.self_id,
        std.os.linux.getpid(),
        now_mono -| st.start_secs,
        npeers,
        st.store.piece_size,
        st.server.http_inflight.load(.monotonic),
        cache_free_pct,
        origin_down,
        now_wall,
        now_mono,
    });
    inline for (@typeInfo(store_mod.Stats.Snap).@"struct".fields, 0..) |f, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("\"{s}\":{d}", .{ f.name, @field(s, f.name) });
    }
    try w.writeAll("}}\n");
    const json = w.buffered();
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const p = try st.store.cacheStatusPath(&pbuf);
    var tbuf: [sys.c.PATH_MAX]u8 = undefined;
    const tp = try sys.appendExt(&tbuf, p, ".tmp");
    // Atomic swap: a torn half-written status.json would make `modelfs status`
    // print garbage; readers see either the old or the new file. O_NOFOLLOW
    // on the staging write keeps a planted symlink from redirecting it.
    if (sys.writeFileOwnerOnly(tp, json) != 0) {
        // Staging file may exist from a partial write; leave none behind.
        // A retry every tick would refresh mtime, so no sweeper ages it out.
        _ = sys.unlink(tp);
        return error.StatusWriteFailed;
    }
    if (sys.rename(tp, p) != 0) {
        _ = sys.unlink(tp);
        return error.StatusRenameFailed;
    }
}

// The low-level session below owns the mount's inode namespace. libfuse's
// high-level API keeps that table privately and aborts the process on an
// inode it does not know, which is exactly what a replacement image would
// inherit from the kernel after `modelfs update`; owning the table is what
// makes the handover possible. The path handlers above stay unchanged and
// are reached through the ino/fh resolution here.

/// libfuse's `struct fuse_file_info` carries bitfields, so translate-c
/// renders it opaque and the daemon reaches its head by offset. That head
/// is identical on libfuse 3.14 (the vendored arm64 build) and 3.18: int32
/// `flags` at 0, the bitfield word at 4 with `direct_io` at bit 1 and
/// `keep_cache` at bit 2, then the 8-byte-aligned uint64 `fh` at 16.
const fi_bits_off: usize = 4;
const fi_fh_off: usize = 16;
const fi_direct_io_bit: u5 = 1;
const fi_keep_cache_bit: u5 = 2;

fn fiFh(fi: ?*fuse.fuse_file_info) u64 {
    const p = fi orelse return 0;
    const bytes: [*]const u8 = @ptrCast(p);
    return std.mem.readInt(u64, bytes[fi_fh_off..][0..8], .little);
}

fn setFiFh(fi: ?*fuse.fuse_file_info, fh: u64) void {
    const p = fi orelse return;
    const bytes: [*]u8 = @ptrCast(p);
    std.mem.writeInt(u64, bytes[fi_fh_off..][0..8], fh, .little);
}

/// The kernel page cache is UMA RAM shared with the GPU, so it stays off
/// under direct_io (the default). `--kernel-cache` clears direct_io to
/// permit mmap and keeps cached pages across opens of the same file.
fn setFiCaching(st: *State, fi: ?*fuse.fuse_file_info) void {
    const p = fi orelse return;
    const bytes: [*]u8 = @ptrCast(p);
    const dio = @as(u32, 1) << fi_direct_io_bit;
    const keep = @as(u32, 1) << fi_keep_cache_bit;
    var bits = std.mem.readInt(u32, bytes[fi_bits_off..][0..4], .little);
    bits = if (st.direct_io) (bits | dio) & ~keep else (bits & ~dio) | keep;
    std.mem.writeInt(u32, bytes[fi_bits_off..][0..4], bits, .little);
}

/// Attribute and entry lifetime the kernel may cache before revalidating.
/// Negative lookups get a plain ENOENT and no caching at all, so a name
/// that appears on the origin is visible at the next access.
const cache_timeout_s: f64 = 1.0;

/// The mount root. Fixed by the FUSE protocol, never in `State.nodes`.
const root_ino: u64 = 1;

/// The path an inode names, copied into `buf`: a borrowed slice would be
/// freed under the caller by a concurrent FORGET the moment the table lock
/// is dropped.
fn pathForIno(st: *State, ino: u64, buf: *[sys.c.PATH_MAX]u8) ?[]const u8 {
    if (ino == root_ino) {
        buf[0] = '/';
        return buf[0..1];
    }
    st.nodes_mu.lockUncancelable(st.io);
    defer st.nodes_mu.unlock(st.io);
    const node = st.nodes.get(ino) orelse return null;
    if (node.path.len > buf.len) return null;
    @memcpy(buf[0..node.path.len], node.path);
    return buf[0..node.path.len];
}

/// The path an open file handle names. Preferred over the inode's own path
/// wherever both are available: a rename between open and I/O moves the
/// handle with the name, and both tables are kept in step by `renameNodes`.
fn pathForFh(st: *State, fh: u64, buf: *[sys.c.PATH_MAX]u8) ?[]const u8 {
    if (fh == 0) return null;
    st.nodes_mu.lockUncancelable(st.io);
    defer st.nodes_mu.unlock(st.io);
    const p = st.opens.get(fh) orelse return null;
    if (p.len > buf.len) return null;
    @memcpy(buf[0..p.len], p);
    return buf[0..p.len];
}

fn pathForOp(st: *State, ino: u64, fi: ?*fuse.fuse_file_info, buf: *[sys.c.PATH_MAX]u8) ?[]const u8 {
    if (pathForFh(st, fiFh(fi), buf)) |p| return p;
    return pathForIno(st, ino, buf);
}

/// The inode number for `path`, minting one if the kernel has not seen the
/// name yet. Every reply_entry/reply_create hands the kernel one lookup
/// reference, which it returns through FORGET.
fn internPath(st: *State, path: []const u8) !u64 {
    if (std.mem.eql(u8, path, "/")) return root_ino;
    st.nodes_mu.lockUncancelable(st.io);
    defer st.nodes_mu.unlock(st.io);
    if (st.paths.get(path)) |ino| {
        // getPtr cannot be null here: paths and nodes are only ever written
        // together under this lock.
        st.nodes.getPtr(ino).?.nlookup += 1;
        return ino;
    }
    const owned = try st.gpa.dupe(u8, path);
    errdefer st.gpa.free(owned);
    try st.nodes.ensureUnusedCapacity(st.gpa, 1);
    try st.paths.ensureUnusedCapacity(st.gpa, 1);
    const ino = st.next_ino;
    st.next_ino += 1;
    st.nodes.putAssumeCapacity(ino, .{ .path = owned, .nlookup = 1 });
    st.paths.putAssumeCapacity(owned, ino);
    return ino;
}

/// FORGET: the kernel dropped `n` of its references to `ino`. At zero the
/// node goes; its number is never reused, so a stale request naming it can
/// only ever answer ENOENT, never a different file.
fn dropLookup(st: *State, ino: u64, n: u64) void {
    if (ino == root_ino) return;
    st.nodes_mu.lockUncancelable(st.io);
    defer st.nodes_mu.unlock(st.io);
    const node = st.nodes.getPtr(ino) orelse return;
    if (node.nlookup > n) {
        node.nlookup -= n;
        return;
    }
    const path = node.path;
    // Only unmap the name when it still resolves here: a rename onto this
    // name has already pointed it at the other inode, and that mapping must
    // survive this node's last forget.
    if (st.paths.get(path)) |mapped| {
        if (mapped == ino) _ = st.paths.remove(path);
    }
    _ = st.nodes.remove(ino);
    st.gpa.free(path);
}

/// `path` rewritten for a rename of `old` to `new`, or null when the rename
/// does not cover it. A directory rename moves its whole subtree, so a
/// prefix match counts as long as it ends on a component boundary.
fn renamedPath(gpa: std.mem.Allocator, old: []const u8, new: []const u8, path: []const u8) !?[]u8 {
    const covered = std.mem.eql(u8, path, old) or
        (path.len > old.len and std.mem.startsWith(u8, path, old) and path[old.len] == '/');
    if (!covered) return null;
    const suffix = path[old.len..];
    const out = try gpa.alloc(u8, new.len + suffix.len);
    @memcpy(out[0..new.len], new);
    @memcpy(out[new.len..], suffix);
    return out;
}

/// Re-points the inode and open-handle tables after a successful rename.
/// The kernel keeps the inode numbers across a rename, so without this an
/// inode it still holds would keep resolving to the name it had before the
/// move. A node whose new path cannot be allocated is dropped rather than
/// left pointing at the old name: later requests naming it answer ENOENT
/// instead of reaching a different file.
fn renameNodes(st: *State, old: []const u8, new: []const u8) void {
    st.nodes_mu.lockUncancelable(st.io);
    defer st.nodes_mu.unlock(st.io);
    var stale: bool = false;
    var it = st.nodes.iterator();
    while (it.next()) |e| {
        const ino = e.key_ptr.*;
        const moved = renamedPath(st.gpa, old, new, e.value_ptr.path) catch {
            stale = true;
            continue;
        } orelse continue;
        if (st.paths.get(e.value_ptr.path)) |mapped| {
            if (mapped == ino) _ = st.paths.remove(e.value_ptr.path);
        }
        // Drop any node the destination name already had: the name is ours
        // now, and the displaced inode stays reachable only through handles
        // the kernel already holds until it forgets them.
        _ = st.paths.remove(moved);
        st.gpa.free(e.value_ptr.path);
        e.value_ptr.path = moved;
        st.paths.put(st.gpa, moved, ino) catch {
            stale = true;
        };
    }
    var oit = st.opens.iterator();
    while (oit.next()) |e| {
        const moved = renamedPath(st.gpa, old, new, e.value_ptr.*) catch {
            stale = true;
            continue;
        } orelse continue;
        st.gpa.free(e.value_ptr.*);
        e.value_ptr.* = moved;
    }
    if (stale) std.log.warn("rename bookkeeping ran out of memory; some cached inodes now answer ENOENT", .{});
}

/// Records an open file so later reads, writes, and the release can find
/// the name even after a rename. A zero handle means "no record kept"; the
/// inode's own path answers those requests.
fn rememberOpen(st: *State, path: []const u8) u64 {
    st.nodes_mu.lockUncancelable(st.io);
    defer st.nodes_mu.unlock(st.io);
    const owned = st.gpa.dupe(u8, path) catch return 0;
    const fh = st.next_fh;
    st.opens.put(st.gpa, fh, owned) catch {
        st.gpa.free(owned);
        return 0;
    };
    st.next_fh += 1;
    return fh;
}

fn forgetOpen(st: *State, fh: u64) void {
    if (fh == 0) return;
    st.nodes_mu.lockUncancelable(st.io);
    defer st.nodes_mu.unlock(st.io);
    if (st.opens.fetchRemove(fh)) |kv| st.gpa.free(kv.value);
}

/// `parent` joined with one component. The root is spelled "/", so its
/// children are built from an empty stem rather than doubling the slash.
fn childPath(buf: *[sys.c.PATH_MAX]u8, parent: []const u8, name: []const u8) ?[]const u8 {
    const stem: []const u8 = if (std.mem.eql(u8, parent, "/")) "" else parent;
    if (stem.len + 1 + name.len >= buf.len) return null;
    @memcpy(buf[0..stem.len], stem);
    buf[stem.len] = '/';
    @memcpy(buf[stem.len + 1 ..][0..name.len], name);
    return buf[0 .. stem.len + 1 + name.len];
}

/// Attributes plus an inode number for `path`, the reply shape LOOKUP,
/// MKDIR, and CREATE share.
fn fillEntry(st: *State, path: []const u8, e: *fuse.fuse_entry_param) c_int {
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    const z = sys.toZ(&zbuf, path) catch return -sys.c.ENAMETOOLONG;
    e.* = std.mem.zeroes(fuse.fuse_entry_param);
    const rc = mf_getattr(z, &e.attr, null);
    if (rc != 0) return rc;
    const ino = internPath(st, path) catch return -sys.c.ENOMEM;
    e.ino = ino;
    // Inode numbers are never reused, so one generation covers the mount.
    e.generation = 1;
    e.attr_timeout = cache_timeout_s;
    e.entry_timeout = cache_timeout_s;
    e.attr.st_ino = ino;
    return 0;
}

fn llEnter(req: fuse.fuse_req_t) *State {
    const st: *State = @ptrCast(@alignCast(fuse.fuse_req_userdata(req)));
    tls_state = st;
    return st;
}

fn replyErr(req: fuse.fuse_req_t, rc: c_int) void {
    _ = fuse.fuse_reply_err(req, if (rc < 0) -rc else rc);
}

export fn ll_lookup(req: fuse.fuse_req_t, parent: fuse.fuse_ino_t, name: [*c]const u8) callconv(.c) void {
    const st = llEnter(req);
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const parent_path = pathForIno(st, parent, &pbuf) orelse return replyErr(req, sys.c.ENOENT);
    var cbuf: [sys.c.PATH_MAX]u8 = undefined;
    const child = childPath(&cbuf, parent_path, cPath(name)) orelse return replyErr(req, sys.c.ENAMETOOLONG);
    var e: fuse.fuse_entry_param = undefined;
    const rc = fillEntry(st, child, &e);
    if (rc != 0) return replyErr(req, rc);
    _ = fuse.fuse_reply_entry(req, &e);
}

export fn ll_forget(req: fuse.fuse_req_t, ino: fuse.fuse_ino_t, nlookup: u64) callconv(.c) void {
    dropLookup(llEnter(req), ino, nlookup);
    fuse.fuse_reply_none(req);
}

export fn ll_forget_multi(req: fuse.fuse_req_t, count: usize, forgets: [*c]fuse.fuse_forget_data) callconv(.c) void {
    const st = llEnter(req);
    var i: usize = 0;
    while (i < count) : (i += 1) dropLookup(st, forgets[i].ino, forgets[i].nlookup);
    fuse.fuse_reply_none(req);
}

export fn ll_getattr(req: fuse.fuse_req_t, ino: fuse.fuse_ino_t, fi: ?*fuse.fuse_file_info) callconv(.c) void {
    const st = llEnter(req);
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const p = pathForOp(st, ino, fi, &pbuf) orelse return replyErr(req, sys.c.ENOENT);
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    const z = sys.toZ(&zbuf, p) catch return replyErr(req, sys.c.ENAMETOOLONG);
    var attr: sys.c.struct_stat = undefined;
    const rc = mf_getattr(z, &attr, fi);
    if (rc != 0) return replyErr(req, rc);
    attr.st_ino = ino;
    _ = fuse.fuse_reply_attr(req, &attr, cache_timeout_s);
}

/// The attribute bits the mount can actually apply. Ownership and
/// timestamps have no handler, exactly as they had none under the
/// high-level ops table, and answer ENOSYS in the same order libfuse used
/// to: mode first, then size, then the unsupported rest.
const settable_attrs: c_int = fuse.FUSE_SET_ATTR_MODE | fuse.FUSE_SET_ATTR_SIZE;

export fn ll_setattr(req: fuse.fuse_req_t, ino: fuse.fuse_ino_t, attr: [*c]fuse.struct_stat, to_set: c_int, fi: ?*fuse.fuse_file_info) callconv(.c) void {
    const st = llEnter(req);
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const p = pathForOp(st, ino, fi, &pbuf) orelse return replyErr(req, sys.c.ENOENT);
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    const z = sys.toZ(&zbuf, p) catch return replyErr(req, sys.c.ENAMETOOLONG);
    if ((to_set & fuse.FUSE_SET_ATTR_MODE) != 0) {
        const rc = mf_chmod(z, attr.*.st_mode, fi);
        if (rc != 0) return replyErr(req, rc);
    }
    if ((to_set & fuse.FUSE_SET_ATTR_SIZE) != 0) {
        const rc = mf_truncate(z, attr.*.st_size, fi);
        if (rc != 0) return replyErr(req, rc);
    }
    if ((to_set & ~settable_attrs) != 0) return replyErr(req, sys.c.ENOSYS);
    var out: sys.c.struct_stat = undefined;
    const rc = mf_getattr(z, &out, fi);
    if (rc != 0) return replyErr(req, rc);
    out.st_ino = ino;
    _ = fuse.fuse_reply_attr(req, &out, cache_timeout_s);
}

export fn ll_open(req: fuse.fuse_req_t, ino: fuse.fuse_ino_t, fi: ?*fuse.fuse_file_info) callconv(.c) void {
    const st = llEnter(req);
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const p = pathForIno(st, ino, &pbuf) orelse return replyErr(req, sys.c.ENOENT);
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    const z = sys.toZ(&zbuf, p) catch return replyErr(req, sys.c.ENAMETOOLONG);
    const rc = mf_open(z, fi);
    if (rc != 0) return replyErr(req, rc);
    setFiFh(fi, rememberOpen(st, p));
    setFiCaching(st, fi);
    _ = fuse.fuse_reply_open(req, fi);
}

export fn ll_create(req: fuse.fuse_req_t, parent: fuse.fuse_ino_t, name: [*c]const u8, mode: fuse.mode_t, fi: ?*fuse.fuse_file_info) callconv(.c) void {
    const st = llEnter(req);
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const parent_path = pathForIno(st, parent, &pbuf) orelse return replyErr(req, sys.c.ENOENT);
    var cbuf: [sys.c.PATH_MAX]u8 = undefined;
    const child = childPath(&cbuf, parent_path, cPath(name)) orelse return replyErr(req, sys.c.ENAMETOOLONG);
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    const z = sys.toZ(&zbuf, child) catch return replyErr(req, sys.c.ENAMETOOLONG);
    const rc = mf_create(z, mode, fi);
    if (rc != 0) return replyErr(req, rc);
    var e: fuse.fuse_entry_param = undefined;
    const erc = fillEntry(st, child, &e);
    if (erc != 0) return replyErr(req, erc);
    setFiFh(fi, rememberOpen(st, child));
    setFiCaching(st, fi);
    _ = fuse.fuse_reply_create(req, &e, fi);
}

export fn ll_read(req: fuse.fuse_req_t, ino: fuse.fuse_ino_t, size: usize, off: fuse.off_t, fi: ?*fuse.fuse_file_info) callconv(.c) void {
    const st = llEnter(req);
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const p = pathForOp(st, ino, fi, &pbuf) orelse return replyErr(req, sys.c.ENOENT);
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    const z = sys.toZ(&zbuf, p) catch return replyErr(req, sys.c.ENAMETOOLONG);
    const want = @min(size, @as(usize, std.math.maxInt(c_int)));
    // One buffer per read request, sized by the kernel's ask. libfuse's
    // high-level layer did the same malloc on this path; the no-hot-path
    // -allocation rule covers piece hydration and request parsing, which
    // still run on stack or on the one reusable piece buffer.
    const buf = st.gpa.alloc(u8, want) catch return replyErr(req, sys.c.ENOMEM);
    defer st.gpa.free(buf);
    const n = mf_read(z, buf.ptr, want, off, fi);
    if (n < 0) return replyErr(req, n);
    _ = fuse.fuse_reply_buf(req, buf.ptr, @intCast(n));
}

export fn ll_write(req: fuse.fuse_req_t, ino: fuse.fuse_ino_t, buf: [*c]const u8, size: usize, off: fuse.off_t, fi: ?*fuse.fuse_file_info) callconv(.c) void {
    const st = llEnter(req);
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const p = pathForOp(st, ino, fi, &pbuf) orelse return replyErr(req, sys.c.ENOENT);
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    const z = sys.toZ(&zbuf, p) catch return replyErr(req, sys.c.ENAMETOOLONG);
    const n = mf_write(z, buf, size, off, fi);
    if (n < 0) return replyErr(req, n);
    _ = fuse.fuse_reply_write(req, @intCast(n));
}

export fn ll_release(req: fuse.fuse_req_t, ino: fuse.fuse_ino_t, fi: ?*fuse.fuse_file_info) callconv(.c) void {
    const st = llEnter(req);
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const p = pathForOp(st, ino, fi, &pbuf);
    forgetOpen(st, fiFh(fi));
    if (p) |path| {
        var zbuf: [sys.c.PATH_MAX]u8 = undefined;
        if (sys.toZ(&zbuf, path)) |z| {
            _ = mf_release(z, fi);
        } else |_| {}
    }
    _ = fuse.fuse_reply_err(req, 0);
}

export fn ll_fsync(req: fuse.fuse_req_t, ino: fuse.fuse_ino_t, datasync: c_int, fi: ?*fuse.fuse_file_info) callconv(.c) void {
    const st = llEnter(req);
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const p = pathForOp(st, ino, fi, &pbuf) orelse return replyErr(req, sys.c.ENOENT);
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    const z = sys.toZ(&zbuf, p) catch return replyErr(req, sys.c.ENAMETOOLONG);
    replyErr(req, mf_fsync(z, datasync, fi));
}

export fn ll_unlink(req: fuse.fuse_req_t, parent: fuse.fuse_ino_t, name: [*c]const u8) callconv(.c) void {
    const st = llEnter(req);
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const parent_path = pathForIno(st, parent, &pbuf) orelse return replyErr(req, sys.c.ENOENT);
    var cbuf: [sys.c.PATH_MAX]u8 = undefined;
    const child = childPath(&cbuf, parent_path, cPath(name)) orelse return replyErr(req, sys.c.ENAMETOOLONG);
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    const z = sys.toZ(&zbuf, child) catch return replyErr(req, sys.c.ENAMETOOLONG);
    replyErr(req, mf_unlink(z));
}

export fn ll_mkdir(req: fuse.fuse_req_t, parent: fuse.fuse_ino_t, name: [*c]const u8, mode: fuse.mode_t) callconv(.c) void {
    const st = llEnter(req);
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const parent_path = pathForIno(st, parent, &pbuf) orelse return replyErr(req, sys.c.ENOENT);
    var cbuf: [sys.c.PATH_MAX]u8 = undefined;
    const child = childPath(&cbuf, parent_path, cPath(name)) orelse return replyErr(req, sys.c.ENAMETOOLONG);
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    const z = sys.toZ(&zbuf, child) catch return replyErr(req, sys.c.ENAMETOOLONG);
    const rc = mf_mkdir(z, mode);
    if (rc != 0) return replyErr(req, rc);
    var e: fuse.fuse_entry_param = undefined;
    const erc = fillEntry(st, child, &e);
    if (erc != 0) return replyErr(req, erc);
    _ = fuse.fuse_reply_entry(req, &e);
}

export fn ll_rmdir(req: fuse.fuse_req_t, parent: fuse.fuse_ino_t, name: [*c]const u8) callconv(.c) void {
    const st = llEnter(req);
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const parent_path = pathForIno(st, parent, &pbuf) orelse return replyErr(req, sys.c.ENOENT);
    var cbuf: [sys.c.PATH_MAX]u8 = undefined;
    const child = childPath(&cbuf, parent_path, cPath(name)) orelse return replyErr(req, sys.c.ENAMETOOLONG);
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    const z = sys.toZ(&zbuf, child) catch return replyErr(req, sys.c.ENAMETOOLONG);
    replyErr(req, mf_rmdir(z));
}

export fn ll_rename(req: fuse.fuse_req_t, parent: fuse.fuse_ino_t, name: [*c]const u8, newparent: fuse.fuse_ino_t, newname: [*c]const u8, flags: c_uint) callconv(.c) void {
    const st = llEnter(req);
    var opbuf: [sys.c.PATH_MAX]u8 = undefined;
    const old_parent = pathForIno(st, parent, &opbuf) orelse return replyErr(req, sys.c.ENOENT);
    var ocbuf: [sys.c.PATH_MAX]u8 = undefined;
    const old = childPath(&ocbuf, old_parent, cPath(name)) orelse return replyErr(req, sys.c.ENAMETOOLONG);
    var npbuf: [sys.c.PATH_MAX]u8 = undefined;
    const new_parent = pathForIno(st, newparent, &npbuf) orelse return replyErr(req, sys.c.ENOENT);
    var ncbuf: [sys.c.PATH_MAX]u8 = undefined;
    const new = childPath(&ncbuf, new_parent, cPath(newname)) orelse return replyErr(req, sys.c.ENAMETOOLONG);
    var ozbuf: [sys.c.PATH_MAX]u8 = undefined;
    const oz = sys.toZ(&ozbuf, old) catch return replyErr(req, sys.c.ENAMETOOLONG);
    var nzbuf: [sys.c.PATH_MAX]u8 = undefined;
    const nz = sys.toZ(&nzbuf, new) catch return replyErr(req, sys.c.ENAMETOOLONG);
    const rc = mf_rename(oz, nz, flags);
    if (rc != 0) return replyErr(req, rc);
    // RENAME_EXCHANGE leaves both names in place and swaps what they hold.
    // Inode identity here is the path, and every handler resolves through
    // it, so the tables already describe the post-exchange mount and only a
    // plain rename (where the old name is gone) needs re-pointing.
    if ((flags & sys.c.RENAME_EXCHANGE) == 0) renameNodes(st, old, new);
    _ = fuse.fuse_reply_err(req, 0);
}

export fn ll_statfs(req: fuse.fuse_req_t, ino: fuse.fuse_ino_t) callconv(.c) void {
    const st = llEnter(req);
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const p = pathForIno(st, ino, &pbuf) orelse return replyErr(req, sys.c.ENOENT);
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    const z = sys.toZ(&zbuf, p) catch return replyErr(req, sys.c.ENAMETOOLONG);
    var vs: sys.c.struct_statvfs = undefined;
    const rc = mf_statfs(z, &vs);
    if (rc != 0) return replyErr(req, rc);
    _ = fuse.fuse_reply_statfs(req, &vs);
}

/// Largest READDIR reply the daemon stages before handing it back. The
/// kernel asks for at most one page-cache page's worth per round today;
/// anything it asks beyond this simply resumes on the next request.
const readdir_reply_max: usize = 64 * 1024;

/// Entries the mount does not resolve to an inode report this number, the
/// same placeholder libfuse's high-level readdir used with `use_ino` off.
/// Zero would make glibc's readdir(3) skip the entry as deleted.
const unknown_dir_ino: u64 = 0xffff_ffff;

/// Stages planned entries into one READDIR reply. False ends the walk when
/// the next entry no longer fits, and the kernel resumes from the last
/// ordinal actually emitted. An entry longer than the staging buffer is
/// skipped instead: Linux NAME_MAX caps directory components at 255 bytes
/// and namez holds 256, so that branch is defense against a hostile origin
/// filesystem, not a state the walk can reach on a real one.
const LlDirFiller = struct {
    req: fuse.fuse_req_t,
    buf: []u8,
    used: *usize,

    fn run(self: LlDirFiller, name: []const u8, ordinal: fuse.off_t) bool {
        var namez: [256]u8 = undefined;
        if (name.len >= namez.len) return true;
        @memcpy(namez[0..name.len], name);
        namez[name.len] = 0;
        var attr = std.mem.zeroes(sys.c.struct_stat);
        attr.st_ino = unknown_dir_ino;
        const left = self.buf.len - self.used.*;
        const need = fuse.fuse_add_direntry(self.req, null, 0, &namez, &attr, ordinal);
        if (need > left) return false;
        _ = fuse.fuse_add_direntry(self.req, self.buf.ptr + self.used.*, left, &namez, &attr, ordinal);
        self.used.* += need;
        return true;
    }
};

export fn ll_readdir(req: fuse.fuse_req_t, ino: fuse.fuse_ino_t, size: usize, off: fuse.off_t, fi: ?*fuse.fuse_file_info) callconv(.c) void {
    _ = fi;
    const st = llEnter(req);
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const p = pathForIno(st, ino, &pbuf) orelse return replyErr(req, sys.c.ENOENT);
    var rel: []const u8 = "";
    const rerr = resolveRel(p, -sys.c.ENOENT, &rel);
    if (rerr != 0) return replyErr(req, rerr);
    var opbuf: [sys.c.PATH_MAX]u8 = undefined;
    const op = st.store.originPath(&opbuf, rel) catch return replyErr(req, sys.c.ENAMETOOLONG);
    // A planted directory symlink must not have the daemon list its
    // target's (client-local) contents into this mount. Open O_NOFOLLOW
    // rather than lstat-then-opendir: a racer swapping the name to a link
    // in that window would otherwise list the target.
    const dir = sys.opendirNoFollow(op) orelse {
        const rc = sys.negErrno();
        countMetaErr(st, rc);
        return replyErr(req, rc);
    };
    defer sys.closedir(dir);
    var reply: [readdir_reply_max]u8 = undefined;
    var used: usize = 0;
    var names = OriginDirNames{ .dir = dir, .hide_cluster = rel.len == 0 };
    const emit = LlDirFiller{ .req = req, .buf = reply[0..@min(size, reply.len)], .used = &used };
    readdirResume(&names, emit, off);
    _ = fuse.fuse_reply_buf(req, &reply[0], used);
}

pub fn llOps() fuse.fuse_lowlevel_ops {
    var o = std.mem.zeroes(fuse.fuse_lowlevel_ops);
    o.init = ll_init;
    o.destroy = ll_destroy;
    o.lookup = ll_lookup;
    o.forget = ll_forget;
    o.forget_multi = ll_forget_multi;
    o.getattr = ll_getattr;
    o.setattr = ll_setattr;
    o.open = ll_open;
    o.create = ll_create;
    o.read = ll_read;
    o.write = ll_write;
    o.release = ll_release;
    o.fsync = ll_fsync;
    o.unlink = ll_unlink;
    o.mkdir = ll_mkdir;
    o.rmdir = ll_rmdir;
    o.rename = ll_rename;
    o.statfs = ll_statfs;
    o.readdir = ll_readdir;
    return o;
}

// ---------------------------------------------------------------------------
// Session lifecycle: mount, attach across exec, and the handover exec itself
// ---------------------------------------------------------------------------

const mount_opts_max: usize = 192;

/// `auto_unmount` also carries the teardown of a handed-over mount: the
/// fusermount3 helper it leaves behind holds a socket this process keeps
/// across exec, so the mount comes down when the replacement image exits,
/// even though that image never called `fuse_session_mount`.
fn mountOpts(buf: *[mount_opts_max]u8, allow_other: bool) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, "default_permissions,auto_unmount,fsname=modelfs,subtype=modelfs{s}", .{
        if (allow_other) ",allow_other" else "",
    });
}

fn newSession(args: *fuse.fuse_args, o: *const fuse.fuse_lowlevel_ops, st: *State) ?*fuse.fuse_session {
    // libfuse 3.17 moved the constructor behind a version-stamped call; the
    // vendored arm64 3.14 still exports the plain one.
    if (@hasDecl(fuse, "fuse_session_new_fn"))
        return fuse.fuse_session_new_fn(args, o, @sizeOf(fuse.fuse_lowlevel_ops), st);
    return fuse.fuse_session_new(args, o, @sizeOf(fuse.fuse_lowlevel_ops), st);
}

/// Mounts `st.mountpoint` and serves it. Returns libfuse's status code; the
/// caller then `deinit`s the same State. Lives here so the CLI does not
/// speak libfuse types. On SIGUSR2 the loop exits without unmounting and
/// the process image is replaced in place.
pub fn run(st: *State) c_int {
    return serve(st, null);
}

/// Serves a FUSE connection inherited across exec: no mount, no INIT
/// negotiation, just the fd the previous image was serving.
pub fn attach(st: *State, fuse_fd: c_int) c_int {
    return serve(st, fuse_fd);
}

fn serve(st: *State, inherit_fd: ?c_int) c_int {
    var opt_buf: [mount_opts_max]u8 = undefined;
    const opts = mountOpts(&opt_buf, st.allow_other) catch return 1;
    var prog_z: [8]u8 = "modelfs\x00".*;
    var dash_o: [3]u8 = "-o\x00".*;
    var argv = [_][*c]u8{ &prog_z, &dash_o, opts.ptr };
    var args = fuse.fuse_args{ .argc = argv.len, .argv = &argv, .allocated = 0 };

    const o = llOps();
    const se = newSession(&args, &o, st) orelse {
        std.log.err("fuse_session_new failed", .{});
        return 1;
    };
    var keep_session = false;
    defer if (!keep_session) fuse.fuse_session_destroy(se);

    if (inherit_fd) |fd| {
        st.fuse_fd = fd;
    } else {
        var mz_buf: [sys.c.PATH_MAX]u8 = undefined;
        const mz = sys.toZ(&mz_buf, st.mountpoint) catch return 1;
        if (fuse.fuse_session_mount(se, mz) != 0) return 1;
        st.fuse_fd = fuse.fuse_session_fd(se);
    }
    // Custom io on both paths, not only the inherited one: the read hook is
    // what keeps the kernel's FUSE_INIT request, and only a verbatim copy of
    // that request lets a later image take this connection over. A libfuse
    // that refuses it on an already-mounted session costs `modelfs update`,
    // not the mount, so say so and keep serving.
    var io = std.mem.zeroes(fuse.fuse_custom_io);
    io.read = ioRead;
    io.writev = ioWritev;
    const iorc = fuse.fuse_session_custom_io(se, &io, st.fuse_fd);
    if (iorc != 0) {
        if (inherit_fd != null) {
            std.log.err("handover: custom io on FUSE fd {d} failed (rc {d})", .{ st.fuse_fd, iorc });
            return 1;
        }
        std.log.warn("custom io on FUSE fd {d} failed (rc {d}); serving normally, but 'modelfs update' cannot replace this image", .{ st.fuse_fd, iorc });
    }
    _ = sys.setCloexec(st.fuse_fd, true);
    if (inherit_fd == null) {
        _ = fuse.fuse_daemonize(@intFromBool(!st.detach));
    } else {
        if (!replayInit(st, se)) return 1;
        // Back on for the image that is serving: a later auto_unmount
        // helper or any other fork must not inherit the peer sockets.
        st.server.setListenCloexec(true);
        std.log.info("attached to the FUSE connection on fd {d}", .{st.fuse_fd});
    }

    _ = fuse.fuse_set_signal_handlers(se);
    installHandoverSignal(st, se);
    // The replacement is serving from here: requests are answered as soon
    // as the loop below picks them up, so this is the honest point to tell
    // the waiting `modelfs update` that the swap took.
    if (st.update_token) |tok| writeAck(st, tok);
    const rc = fuse.fuse_session_loop_mt_31(se, 0);
    fuse.fuse_remove_signal_handlers(se);
    live_state = null;
    live_session = null;

    if (st.handover_asked.load(.acquire)) {
        // Neither unmount nor destroy: destroy closes the FUSE fd, and the
        // whole point is to hand that connection to the next image. execve
        // does not come back, so reaching the return means it failed.
        keep_session = true;
        execHandover(st) catch |err| {
            std.log.err("handover exec failed: {t}; the mount is unserved, restart the daemon", .{err});
        };
        return 1;
    }
    if (inherit_fd == null) fuse.fuse_session_unmount(se);
    return rc;
}

fn ioRead(fd: c_int, buf: ?*anyopaque, size: usize, userdata: ?*anyopaque) callconv(.c) isize {
    const n = sys.c.read(fd, buf, size);
    if (n <= 0) return n;
    const st: *State = @ptrCast(@alignCast(userdata.?));
    const bytes: [*]const u8 = @ptrCast(buf.?);
    captureInit(st, bytes[0..@intCast(n)]);
    return n;
}

/// Keeps the connection's FUSE_INIT request verbatim the one time it comes
/// past. Nothing derived from it survives the round trip: libfuse's
/// `fuse_conn_info` drops wire bits such as FUSE_MAX_PAGES, and a replay
/// missing that one leaves the kernel writing 1 MiB requests into a 128 KiB
/// buffer, which the connection reports as EINVAL on every read.
fn captureInit(st: *State, msg: []const u8) void {
    if (st.init_len.load(.acquire) != 0) return;
    if (msg.len < @sizeOf(FuseInHeader) or msg.len > st.init_raw.len) return;
    if (std.mem.readInt(u32, msg[4..8], .little) != fuse_opcode_init) return;
    @memcpy(st.init_raw[0..msg.len], msg);
    st.init_len.store(msg.len, .release);
}

fn ioWritev(fd: c_int, iov: ?*sys.c.iovec, count: c_int, userdata: ?*anyopaque) callconv(.c) isize {
    const st: *State = @ptrCast(@alignCast(userdata.?));
    if (!st.swallow_reply.load(.acquire)) return sys.c.writev(fd, iov, @intCast(count));
    // The synthetic INIT of a handover: the kernel already holds its INIT
    // reply from the previous image and is not waiting for another one, so
    // report the write as done without putting it on the connection.
    var total: isize = 0;
    var i: usize = 0;
    const vec: [*]const sys.c.iovec = @ptrCast(iov.?);
    while (i < @as(usize, @intCast(count))) : (i += 1) total += @intCast(vec[i].iov_len);
    return total;
}

/// FUSE kernel ABI (linux/fuse.h): the request header every message on the
/// connection starts with, and the one opcode the daemon recognises itself.
const fuse_opcode_init: u32 = 26;

const FuseInHeader = extern struct {
    len: u32,
    opcode: u32,
    unique: u64,
    nodeid: u64,
    uid: u32,
    gid: u32,
    pid: u32,
    total_extlen: u16,
    padding: u16,
};

/// The kernel sends FUSE_INIT once per connection and libfuse answers every
/// request with EIO until it has seen one, so an inherited connection needs
/// the negotiation replayed: hand libfuse the exact request the kernel sent
/// the previous image, and drop the reply it produces (the kernel already
/// has one). libfuse lands on the same connection terms and calls
/// `ll_init`, whose arrival is the proof the replay took.
fn replayInit(st: *State, se: *fuse.fuse_session) bool {
    const len = st.init_len.load(.acquire);
    if (len == 0) {
        std.log.err("handover: no FUSE_INIT request to replay", .{});
        return false;
    }
    st.swallow_reply.store(true, .release);
    var buf = fuse.fuse_buf{ .size = len, .mem = &st.init_raw };
    fuse.fuse_session_process_buf(se, &buf);
    st.swallow_reply.store(false, .release);
    if (!st.init_seen.load(.acquire)) {
        std.log.err("handover: libfuse refused the replayed FUSE_INIT", .{});
        return false;
    }
    return true;
}

var live_session: ?*fuse.fuse_session = null;
var live_state: ?*State = null;

/// SIGUSR2 asks for a handover. Refused, silently and without leaving the
/// loop, when this session has no FUSE_INIT request to pass on: exiting
/// would end the only thing serving the mount, and the exec that followed
/// could not bring it back. `modelfs update` then reports its timeout,
/// which is the honest outcome. Signal context, so nothing here allocates,
/// locks, or logs.
fn onUsr2(_: c_int) callconv(.c) void {
    const st = live_state orelse return;
    if (st.init_len.load(.acquire) == 0) return;
    st.handover_asked.store(true, .release);
    if (live_session) |se| fuse.fuse_session_exit(se);
}

fn installHandoverSignal(st: *State, se: *fuse.fuse_session) void {
    live_state = st;
    live_session = se;
    var sa = std.mem.zeroes(sys.c.struct_sigaction);
    sa.__sigaction_handler.sa_handler = onUsr2;
    _ = sys.c.sigemptyset(&sa.sa_mask);
    sa.sa_flags = sys.c.SA_RESTART;
    _ = sys.c.sigaction(sys.c.SIGUSR2, &sa, null);
}

fn snapNodes(st: *State, gpa: std.mem.Allocator) ![]handover.NodeSnap {
    st.nodes_mu.lockUncancelable(st.io);
    defer st.nodes_mu.unlock(st.io);
    var list: std.ArrayList(handover.NodeSnap) = .empty;
    errdefer list.deinit(gpa);
    var it = st.nodes.iterator();
    while (it.next()) |e| {
        try list.append(gpa, .{ .ino = e.key_ptr.*, .path = e.value_ptr.path, .nlookup = e.value_ptr.nlookup });
    }
    return list.toOwnedSlice(gpa);
}

fn snapOpens(st: *State, gpa: std.mem.Allocator) ![]handover.OpenSnap {
    st.nodes_mu.lockUncancelable(st.io);
    defer st.nodes_mu.unlock(st.io);
    var list: std.ArrayList(handover.OpenSnap) = .empty;
    errdefer list.deinit(gpa);
    var it = st.opens.iterator();
    while (it.next()) |e| {
        try list.append(gpa, .{ .fh = e.key_ptr.*, .path = e.value_ptr.* });
    }
    return list.toOwnedSlice(gpa);
}

/// Rebuilds the inode and open-handle tables in a replacement image from
/// the snapshot the previous one took, before a single request is served:
/// the kernel keeps handing back the inode numbers it already holds.
pub fn restoreMaps(st: *State, owned: *const handover.Owned) !void {
    st.nodes_mu.lockUncancelable(st.io);
    defer st.nodes_mu.unlock(st.io);
    st.next_ino = owned.next_ino;
    st.next_fh = owned.next_fh;
    try st.nodes.ensureUnusedCapacity(st.gpa, @intCast(owned.nodes.len));
    try st.paths.ensureUnusedCapacity(st.gpa, @intCast(owned.nodes.len));
    try st.opens.ensureUnusedCapacity(st.gpa, @intCast(owned.opens.len));
    for (owned.nodes) |n| {
        const path = try st.gpa.dupe(u8, n.path);
        st.nodes.putAssumeCapacity(n.ino, .{ .path = path, .nlookup = n.nlookup });
        st.paths.putAssumeCapacity(path, n.ino);
    }
    for (owned.opens) |o| {
        st.opens.putAssumeCapacity(o.fh, try st.gpa.dupe(u8, o.path));
    }
}

fn asHandoverAddrs(gpa: std.mem.Allocator, addrs: []const proto.LeaseAddr) ![]handover.Addr {
    const out = try gpa.alloc(handover.Addr, addrs.len);
    for (addrs, 0..) |a, i| out[i] = .{ .ip = a.ip, .port = a.port };
    return out;
}

/// Replaces this process image with the binary `update.req` names, handing
/// it the FUSE connection, the peer listen sockets, and everything needed
/// to keep serving them. Only returns on failure: execve does not come
/// back, and by then the mount and the port are already this image's to
/// lose.
fn execHandover(st: *State) !void {
    const gpa = st.gpa;
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const req_path = try sys.joinZ(&pbuf, st.store.cache, handover.req_file);
    var open_errno: i32 = 0;
    const req_blob = sys.readFileAllocNoFollowOpenErrno(gpa, req_path, 4096, &open_errno) catch return error.NoRequest;
    defer gpa.free(req_blob);
    const parsed = handover.decodeReq(gpa, req_blob) catch return error.BadRequest;
    defer parsed.deinit();
    const bin = parsed.value.bin;
    if (bin.len == 0 or bin[0] != '/') return error.BadBin;

    const node_snaps = try snapNodes(st, gpa);
    defer gpa.free(node_snaps);
    const open_snaps = try snapOpens(st, gpa);
    defer gpa.free(open_snaps);
    const adv = try asHandoverAddrs(gpa, st.catalog.addrs);
    defer gpa.free(adv);
    const seeds = try asHandoverAddrs(gpa, st.catalog.seeds);
    defer gpa.free(seeds);
    const listen_fds = try gpa.alloc(i32, st.server.listen_fds.items.len);
    defer gpa.free(listen_fds);
    for (st.server.listen_fds.items, 0..) |fd, i| listen_fds[i] = fd;

    const blob = try handover.encode(gpa, .{
        .origin = st.store.origin,
        .cache = st.store.cache,
        .id = st.catalog.self_id,
        .mount = st.mountpoint,
        .piece = st.store.piece_size,
        .listen = st.listen_port,
        .water = st.store.water,
        .direct_io = st.direct_io,
        .allow_other = st.allow_other,
        .fuse_fd = st.fuse_fd,
        .listen_fds = listen_fds,
        .advertise = adv,
        .seeds = seeds,
        .psk = st.server.psk,
        .init = st.init_raw[0..st.init_len.load(.acquire)],
        .nodes = node_snaps,
        .opens = open_snaps,
        .next_ino = st.next_ino,
        .next_fh = st.next_fh,
    });
    defer {
        std.crypto.secureZero(u8, blob);
        gpa.free(blob);
    }
    const state_fd = try handover.writeStateFd(blob);
    // Everything the next image must find has to survive execve; the sealed
    // memfd carries the secret, so the fd number is all argv needs.
    if (sys.setCloexec(state_fd, false) != 0) return error.Cloexec;
    if (sys.setCloexec(st.fuse_fd, false) != 0) return error.Cloexec;
    st.server.setListenCloexec(false);

    var bin_z: [sys.c.PATH_MAX]u8 = undefined;
    const bz = try sys.toZ(&bin_z, bin);
    const argv_z = try handover.execArgvZ(gpa, bin, state_fd, st.mountpoint);
    // Only reached when execve fails: on success this image is gone.
    defer handover.freeExecArgvZ(gpa, argv_z);
    _ = sys.c.execve(bz, @ptrCast(argv_z.ptr), std.c.environ);
    return error.ExecFailed;
}

/// Tells the waiting `modelfs update` that this image is the one serving.
pub fn writeAck(st: *State, token: []const u8) void {
    const gpa = st.gpa;
    const blob = handover.encodeAck(gpa, token) catch return;
    defer gpa.free(blob);
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const p = sys.joinZ(&pbuf, st.store.cache, handover.ack_file) catch return;
    _ = sys.writeFileOwnerOnly(p, blob);
}

/// A State with only the fields the inode and handle tables touch. The
/// tables are pure bookkeeping over `gpa` and `io`, so they are drivable
/// without a mount, an origin, or a peer server; `deinit` on a full State
/// would tear down workers that were never started.
fn tableFixture(gpa: std.mem.Allocator) State {
    return .{
        .gpa = gpa,
        .io = std.testing.io,
        .store = undefined,
        .catalog = undefined,
        .server = undefined,
        .direct_io = true,
        .start_secs = 0,
    };
}

fn freeTables(st: *State) void {
    var it = st.nodes.iterator();
    while (it.next()) |e| st.gpa.free(e.value_ptr.path);
    st.nodes.deinit(st.gpa);
    st.paths.deinit(st.gpa);
    var o = st.opens.iterator();
    while (o.next()) |e| st.gpa.free(e.value_ptr.*);
    st.opens.deinit(st.gpa);
}

test "childPath joins under the root without doubling the slash" {
    var buf: [sys.c.PATH_MAX]u8 = undefined;
    try std.testing.expectEqualStrings("/a", childPath(&buf, "/", "a").?);
    try std.testing.expectEqualStrings("/a/b", childPath(&buf, "/a", "b").?);
    try std.testing.expectEqualStrings("/a/b/c", childPath(&buf, "/a/b", "c").?);
    // A name that would not fit is refused rather than truncated: a
    // truncated path names a different file.
    var tiny: [sys.c.PATH_MAX]u8 = undefined;
    const long = "x" ** (sys.c.PATH_MAX - 1);
    try std.testing.expectEqual(@as(?[]const u8, null), childPath(&tiny, "/a", long));
}

test "internPath mints once, counts lookups, and forgets at zero" {
    const gpa = std.testing.allocator;
    var st = tableFixture(gpa);
    defer freeTables(&st);

    // The root is fixed by the protocol and never enters the table.
    try std.testing.expectEqual(root_ino, try internPath(&st, "/"));
    try std.testing.expectEqual(@as(usize, 0), st.nodes.count());

    const a = try internPath(&st, "/gguf/a.bin");
    const b = try internPath(&st, "/gguf/b.bin");
    try std.testing.expect(a != b);
    // A second lookup of the same name is the same inode with one more
    // reference, not a new number: the kernel would otherwise hold two.
    try std.testing.expectEqual(a, try internPath(&st, "/gguf/a.bin"));
    try std.testing.expectEqual(@as(u64, 2), st.nodes.get(a).?.nlookup);

    var buf: [sys.c.PATH_MAX]u8 = undefined;
    try std.testing.expectEqualStrings("/gguf/a.bin", pathForIno(&st, a, &buf).?);
    try std.testing.expectEqualStrings("/", pathForIno(&st, root_ino, &buf).?);

    // One forget of two references keeps the node; the second drops it.
    dropLookup(&st, a, 1);
    try std.testing.expectEqualStrings("/gguf/a.bin", pathForIno(&st, a, &buf).?);
    dropLookup(&st, a, 1);
    try std.testing.expectEqual(@as(?[]const u8, null), pathForIno(&st, a, &buf));
    try std.testing.expect(!st.paths.contains("/gguf/a.bin"));

    // Inode numbers are never reused, so a request naming a forgotten one
    // can only answer ENOENT, never a different file.
    try std.testing.expect(try internPath(&st, "/gguf/a.bin") > b);
    // A batched forget larger than the count still drops exactly once, and
    // the root is not forgettable.
    dropLookup(&st, b, 99);
    try std.testing.expectEqual(@as(?[]const u8, null), pathForIno(&st, b, &buf));
    dropLookup(&st, root_ino, 1);
    try std.testing.expectEqualStrings("/", pathForIno(&st, root_ino, &buf).?);
}

test "open handles resolve to their path and are released by fh" {
    const gpa = std.testing.allocator;
    var st = tableFixture(gpa);
    defer freeTables(&st);

    var buf: [sys.c.PATH_MAX]u8 = undefined;
    const fh = rememberOpen(&st, "/gguf/a.bin");
    try std.testing.expect(fh != 0);
    try std.testing.expectEqualStrings("/gguf/a.bin", pathForFh(&st, fh, &buf).?);
    // Handle 0 means "no record kept", so it must never resolve.
    try std.testing.expectEqual(@as(?[]const u8, null), pathForFh(&st, 0, &buf));
    try std.testing.expectEqual(@as(?[]const u8, null), pathForFh(&st, fh + 1, &buf));

    const second = rememberOpen(&st, "/gguf/a.bin");
    try std.testing.expect(second != fh);
    forgetOpen(&st, fh);
    try std.testing.expectEqual(@as(?[]const u8, null), pathForFh(&st, fh, &buf));
    // The other handle on the same file is untouched.
    try std.testing.expectEqualStrings("/gguf/a.bin", pathForFh(&st, second, &buf).?);
    forgetOpen(&st, second);
    forgetOpen(&st, 0);
}

test "renamedPath rewrites only paths the rename covers" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { path: []const u8, want: ?[]const u8 }{
        .{ .path = "/a", .want = "/z" },
        .{ .path = "/a/b", .want = "/z/b" },
        .{ .path = "/a/b/c", .want = "/z/b/c" },
        // A prefix that does not end on a component boundary is a
        // different name: /ab must not move when /a does.
        .{ .path = "/ab", .want = null },
        .{ .path = "/abc/d", .want = null },
        .{ .path = "/b", .want = null },
        .{ .path = "/", .want = null },
    };
    for (cases) |c| {
        const got = try renamedPath(gpa, "/a", "/z", c.path);
        if (c.want) |want| {
            defer gpa.free(got.?);
            try std.testing.expectEqualStrings(want, got.?);
        } else {
            try std.testing.expectEqual(@as(?[]u8, null), got);
        }
    }
}

test "renameNodes moves a subtree and its open handles, and lets the destination win" {
    const gpa = std.testing.allocator;
    var st = tableFixture(gpa);
    defer freeTables(&st);

    const dir = try internPath(&st, "/d");
    const child = try internPath(&st, "/d/sub/f.txt");
    const other = try internPath(&st, "/keep");
    const fh = rememberOpen(&st, "/d/sub/f.txt");

    renameNodes(&st, "/d", "/moved");

    var buf: [sys.c.PATH_MAX]u8 = undefined;
    // The kernel keeps these inode numbers across a rename, so they must
    // now resolve to the new names, not the old ones.
    try std.testing.expectEqualStrings("/moved", pathForIno(&st, dir, &buf).?);
    try std.testing.expectEqualStrings("/moved/sub/f.txt", pathForIno(&st, child, &buf).?);
    try std.testing.expectEqualStrings("/moved/sub/f.txt", pathForFh(&st, fh, &buf).?);
    try std.testing.expectEqualStrings("/keep", pathForIno(&st, other, &buf).?);
    try std.testing.expectEqual(child, st.paths.get("/moved/sub/f.txt").?);
    try std.testing.expect(!st.paths.contains("/d/sub/f.txt"));

    // Rename onto a live name: the destination inode keeps its number and
    // its path, but the name now resolves to the mover. Forgetting the
    // displaced node must not unmap the name from under the winner.
    const victim = try internPath(&st, "/victim");
    renameNodes(&st, "/keep", "/victim");
    try std.testing.expectEqual(other, st.paths.get("/victim").?);
    dropLookup(&st, victim, 1);
    try std.testing.expectEqual(other, st.paths.get("/victim").?);
    try std.testing.expectEqualStrings("/victim", pathForIno(&st, other, &buf).?);
    forgetOpen(&st, fh);
}

test "restoreMaps rebuilds the tables a handover snapshot carried" {
    const gpa = std.testing.allocator;
    var st = tableFixture(gpa);
    defer freeTables(&st);

    var owned: handover.Owned = .{
        .origin = &.{},
        .cache = &.{},
        .id = &.{},
        .mount = &.{},
        .piece = 0,
        .listen = 0,
        .water = .{},
        .direct_io = true,
        .allow_other = false,
        .fuse_fd = -1,
        .listen_fds = &.{},
        .advertise = &.{},
        .seeds = &.{},
        .psk = &.{},
        .nodes = @constCast(&[_]handover.NodeSnap{
            .{ .ino = 5, .path = "/gguf/a.bin", .nlookup = 3 },
        }),
        .opens = @constCast(&[_]handover.OpenSnap{
            .{ .fh = 9, .path = "/gguf/a.bin" },
        }),
        .next_ino = 6,
        .next_fh = 10,
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    owned.arena.deinit();

    try restoreMaps(&st, &owned);

    var buf: [sys.c.PATH_MAX]u8 = undefined;
    // The kernel still holds ino 5 and fh 9 across the exec, so both must
    // resolve without a fresh lookup.
    try std.testing.expectEqualStrings("/gguf/a.bin", pathForIno(&st, 5, &buf).?);
    try std.testing.expectEqualStrings("/gguf/a.bin", pathForFh(&st, 9, &buf).?);
    try std.testing.expectEqual(@as(u64, 3), st.nodes.get(5).?.nlookup);
    // The counters resume where the previous image left them, so a new
    // lookup cannot collide with an inode the kernel already holds.
    try std.testing.expectEqual(@as(u64, 6), try internPath(&st, "/new.bin"));
    try std.testing.expectEqual(@as(u64, 10), rememberOpen(&st, "/new.bin"));
    // The restored reference count is still honored: three forgets, not one.
    dropLookup(&st, 5, 2);
    try std.testing.expectEqualStrings("/gguf/a.bin", pathForIno(&st, 5, &buf).?);
    dropLookup(&st, 5, 1);
    try std.testing.expectEqual(@as(?[]const u8, null), pathForIno(&st, 5, &buf));
    forgetOpen(&st, 9);
    forgetOpen(&st, 10);
}

test "fuse operations wire every supported handler" {
    const o = llOps();
    // A null entry makes libfuse answer that operation with a default
    // behavior instead of going through the store: e.g. a dropped setattr
    // wiring would silently corrupt cache/origin size agreement. Identity,
    // not mere non-null: swapping two handlers would still pass a null check.
    try std.testing.expectEqual(&ll_init, o.init);
    try std.testing.expectEqual(&ll_destroy, o.destroy);
    try std.testing.expectEqual(&ll_lookup, o.lookup);
    // Without forget the inode table grows for the life of the mount, and
    // without the batched form the kernel's FORGET_MULTI is dropped whole.
    try std.testing.expectEqual(&ll_forget, o.forget);
    try std.testing.expectEqual(&ll_forget_multi, o.forget_multi);
    try std.testing.expectEqual(&ll_getattr, o.getattr);
    try std.testing.expectEqual(&ll_setattr, o.setattr);
    try std.testing.expectEqual(&ll_open, o.open);
    try std.testing.expectEqual(&ll_create, o.create);
    try std.testing.expectEqual(&ll_read, o.read);
    try std.testing.expectEqual(&ll_write, o.write);
    try std.testing.expectEqual(&ll_release, o.release);
    try std.testing.expectEqual(&ll_fsync, o.fsync);
    try std.testing.expectEqual(&ll_unlink, o.unlink);
    try std.testing.expectEqual(&ll_mkdir, o.mkdir);
    try std.testing.expectEqual(&ll_rmdir, o.rmdir);
    try std.testing.expectEqual(&ll_rename, o.rename);
    try std.testing.expectEqual(&ll_statfs, o.statfs);
    try std.testing.expectEqual(&ll_readdir, o.readdir);
    // Unwired ops stay ENOSYS: a planted symlink/mknod/link/xattr handler
    // would let a local process create names the path gate never sees.
    try std.testing.expect(o.readlink == null);
    try std.testing.expect(o.mknod == null);
    try std.testing.expect(o.symlink == null);
    try std.testing.expect(o.link == null);
    try std.testing.expect(o.setxattr == null);
    try std.testing.expect(o.getxattr == null);
    try std.testing.expect(o.listxattr == null);
    try std.testing.expect(o.removexattr == null);
    try std.testing.expect(o.readdirplus == null);
    try std.testing.expect(o.getlk == null);
    try std.testing.expect(o.setlk == null);
    try std.testing.expect(o.ioctl == null);
}

test "statusJson publishes parseable liveness atomically and replaces in place" {
    const gpa = std.testing.allocator;
    var cb: [128]u8 = undefined;
    const cache_d = try sys.scratchDir(&cb, "modelfs-status");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st: State = undefined;
    st.init(gpa, std.testing.io, "/unused", cache_d, 4096, .{}, "me", &.{}, &.{}, &.{}, "", true);
    defer st.deinit();
    try std.testing.expectEqual(&st.store, st.server.store);
    // Two paths sharing one peer id plus one distinct peer: the published
    // count must be unique peers (2), not raw paths (3).
    try st.catalog.paths.append(gpa, .{ .peer_id = "dup", .ip = "10.0.0.1", .port = 18080, .ewma_bps = 1e8, .hops = 0 });
    try st.catalog.paths.append(gpa, .{ .peer_id = "dup", .ip = "10.0.0.2", .port = 18080, .ewma_bps = 1e8, .hops = 0 });
    try st.catalog.paths.append(gpa, .{ .peer_id = "other", .ip = "10.0.0.3", .port = 18080, .ewma_bps = 1e8, .hops = 0 });

    try statusJson(&st);

    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const fp = try st.store.cacheStatusPath(&pbuf);
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    const tmp_fp = try sys.appendExt(&zbuf, fp, ".tmp");
    var stbuf: sys.c.struct_stat = undefined;
    // The rename must leave no staging file behind: a leftover .tmp next to
    // the live artifact means readers raced a torn write.
    try std.testing.expect(sys.statPath(fp, &stbuf) == 0);
    try std.testing.expectEqual(@as(sys.c.mode_t, 0o600), stbuf.st_mode & 0o777);
    try std.testing.expect(sys.statPath(tmp_fp, &stbuf) != 0);

    const blob = try sys.readFileAlloc(gpa, fp, 4096);
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
        origin_down: i32,
        now_s: i64,
        mono_s: i64,
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
    try std.testing.expectEqual(@as(i32, 0), doc.value.origin_down);
    try std.testing.expectEqual(@as(u64, 0), doc.value.stats.http_nanos);
    try std.testing.expectEqual(@as(u64, 0), doc.value.stats.lease_err);
    try std.testing.expectEqual(@as(u64, 0), doc.value.stats.meta_err);
    // now_s is a current epoch second (operators/monitors); mono_s is the
    // same-machine monotonic instant the wedge gate compares against. Zero
    // or a swapped pair would make `status` misread a live node.
    try std.testing.expect(doc.value.now_s >= sys.nowSec(st.io) - 5);
    try std.testing.expect(doc.value.mono_s >= sys.monoSec(st.io) - 5);
    // Counters ride along with the liveness fields: an operator answers
    // "is it serving, from where, is it failing" from one artifact.
    try std.testing.expectEqual(@as(u64, 0), doc.value.stats.reads_ok);
    try std.testing.expectEqual(@as(u64, 0), doc.value.stats.reads_warm);
    try std.testing.expectEqual(@as(u64, 0), doc.value.stats.http_ok);
    try std.testing.expectEqual(@as(u64, 0), doc.value.stats.bytes_to_peer);
    try std.testing.expectEqual(@as(u64, 0), doc.value.stats.write_nanos);

    // A later discovery tick republishes: the rename replaces the document
    // wholesale, so the peer count tracks membership instead of growing.
    _ = st.catalog.paths.pop();
    // Bump one counter and require it to surface: the publish path must
    // carry live stats, not a frozen snapshot.
    _ = st.store.stats.fills_peer.fetchAdd(1, .monotonic);
    _ = st.store.stats.bytes_from_peer.fetchAdd(4096, .monotonic);
    _ = st.store.stats.http_405.fetchAdd(3, .monotonic);
    _ = st.store.stats.getattr_nanos.fetchAdd(2000, .monotonic);
    _ = st.store.stats.open_nanos.fetchAdd(4000, .monotonic);
    _ = st.store.stats.statfs_nanos.fetchAdd(8000, .monotonic);
    st.store.origin_io_down.store(true, .monotonic);
    try statusJson(&st);
    const blob2 = try sys.readFileAlloc(gpa, fp, 4096);
    defer gpa.free(blob2);
    const doc2 = try std.json.parseFromSlice(StatusDoc, gpa, blob2, .{});
    defer doc2.deinit();
    try std.testing.expectEqual(@as(u32, 1), doc2.value.peers);
    try std.testing.expectEqual(@as(u64, 1), doc2.value.stats.fills_peer);
    try std.testing.expectEqual(@as(u64, 4096), doc2.value.stats.bytes_from_peer);
    try std.testing.expectEqual(@as(i32, 1), doc2.value.origin_down);
    // Snap fields default to 0, so a missing JSON key would still parse.
    // The four keys 0.5.0 added must actually be in the published document.
    try std.testing.expectEqual(@as(u64, 3), doc2.value.stats.http_405);
    try std.testing.expectEqual(@as(u64, 2000), doc2.value.stats.getattr_nanos);
    try std.testing.expectEqual(@as(u64, 4000), doc2.value.stats.open_nanos);
    try std.testing.expectEqual(@as(u64, 8000), doc2.value.stats.statfs_nanos);

    // A leftover world-readable status.json (older daemon, or a 0644 tmp
    // that was renamed in) is tightened on the next publish: O_CREAT's
    // mode is ignored when the name exists, so writeFileOwnerOnly fchmods
    // the staging fd before the rename.
    try std.testing.expectEqual(@as(i32, 0), sys.c.chmod(fp, 0o644));
    try statusJson(&st);
    try std.testing.expectEqual(@as(i32, 0), sys.statPath(fp, &stbuf));
    try std.testing.expectEqual(@as(sys.c.mode_t, 0o600), stbuf.st_mode & 0o777);
}

test "statusJson unlinks the staging file when rename fails" {
    const gpa = std.testing.allocator;
    var cb: [128]u8 = undefined;
    const cache_d = try sys.scratchDir(&cb, "modelfs-status-tmp");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st: State = undefined;
    st.init(gpa, std.testing.io, "/unused", cache_d, 4096, .{}, "me", &.{}, &.{}, &.{}, "", true);
    defer st.deinit();

    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const fp = try st.store.cacheStatusPath(&pbuf);
    // Destination is a directory: rename(status.json.tmp, status.json) fails
    // and must not leave the staging file (a retry every tick would refresh
    // mtime with no sweeper to age it out).
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(std.mem.span(fp), 0o755));
    try std.testing.expectError(error.StatusRenameFailed, statusJson(&st));

    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    const tmp_fp = try sys.appendExt(&zbuf, fp, ".tmp");
    var stbuf: sys.c.struct_stat = undefined;
    try std.testing.expect(sys.statPath(tmp_fp, &stbuf) != 0);
}

test "meanPerOp does not overflow the per-op divisor" {
    // Old form `total / (count * ns_per_us)` panics in safe builds when
    // count > maxInt(u64)/1000. Concrete: 2^64/1000 + 1 ops, 0 ns.
    const count: u64 = std.math.maxInt(u64) / 1000 + 1;
    try std.testing.expectEqual(@as(u64, 0), meanPerOp(0, count, 1000));
    try std.testing.expectEqual(@as(u64, 2), meanPerOp(5, 2, 1));
    try std.testing.expectEqual(@as(u64, 1), meanPerOp(2500, 2, 1000));
    try std.testing.expectEqual(@as(u64, 0), meanPerOp(100, 0, 1000));
    try std.testing.expectEqual(@as(u64, 0), meanPerOp(100, 1, 0));
}

test "logStatsTick summarizes deltas and stays silent when idle" {
    const gpa = std.testing.allocator;
    var cb: [128]u8 = undefined;
    const cache_d = try sys.scratchDir(&cb, "modelfs-tick");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st: State = undefined;
    st.init(gpa, std.testing.io, "/unused", cache_d, 4096, .{}, "me", &.{}, &.{}, &.{}, "", true);
    defer st.deinit();

    var prev = st.store.stats.snap();

    // Idle tick: no movement since the snapshot, no log line. The summary
    // must stay quiet on an idle node or it is exactly the noise it exists
    // to prevent. A stale prev that is *ahead* of current would also yield
    // a zero saturating delta; the snapshot still has to catch up or a
    // later real increment is swallowed as 0 forever.
    prev.fills_origin = 99;
    logStatsTick(&st, &prev);
    try std.testing.expectEqual(@as(u64, 0), prev.fills_origin);
    try std.testing.expect(std.meta.eql(prev, st.store.stats.snap()));

    // Activity since the last tick: the delta line carries per-interval
    // counts (here: one origin fill of 4096 bytes), not lifetime totals.
    _ = st.store.stats.fills_origin.fetchAdd(1, .monotonic);
    _ = st.store.stats.bytes_from_origin.fetchAdd(4096, .monotonic);
    _ = st.store.stats.http_ok.fetchAdd(1, .monotonic);
    _ = st.store.stats.http_nanos.fetchAdd(1000, .monotonic);
    // The expected info line is below the raised threshold; restored on
    // scope exit so unexpected warnings from later tests still surface.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;
    logStatsTick(&st, &prev);
    try std.testing.expectEqual(@as(u64, 1), prev.fills_origin);
    try std.testing.expectEqual(@as(u64, 4096), prev.bytes_from_origin);
    try std.testing.expectEqual(@as(u64, 1), prev.http_ok);
    try std.testing.expectEqual(@as(u64, 1000), prev.http_nanos);

    // Metadata-only and 405-only intervals must still advance prev: they
    // are Snap fields, so a tick that only moved those cannot leave the
    // snapshot behind (the next real increment would then look like 0).
    _ = st.store.stats.getattr_nanos.fetchAdd(2000, .monotonic);
    _ = st.store.stats.http_405.fetchAdd(2, .monotonic);
    logStatsTick(&st, &prev);
    try std.testing.expectEqual(@as(u64, 2000), prev.getattr_nanos);
    try std.testing.expectEqual(@as(u64, 2), prev.http_405);

    // lease_err and meta_err are Snap fields too: an idle origin outage or
    // a getattr EIO storm must advance prev or the next real increment is
    // swallowed as 0.
    _ = st.store.stats.lease_err.fetchAdd(1, .monotonic);
    _ = st.store.stats.meta_err.fetchAdd(4, .monotonic);
    logStatsTick(&st, &prev);
    try std.testing.expectEqual(@as(u64, 1), prev.lease_err);
    try std.testing.expectEqual(@as(u64, 4), prev.meta_err);
}

test "tickCluster counts lease_err on publish failure and meta_err on origin outage" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-tick-cluster");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-tick-cluster");
    defer sys.deleteTree(std.testing.io, cache_d);

    var cbuf: [160]u8 = undefined;
    const cluster_d = try std.fmt.bufPrint(&cbuf, "{s}/.cluster", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(cluster_d, 0o755));
    var lbuf: [192]u8 = undefined;
    const lease_fp = try std.fmt.bufPrint(&lbuf, "{s}/me.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(lease_fp, 0o755));

    const addrs = [_]proto.LeaseAddr{.{ .ip = "10.0.0.1", .port = 18080, .mbps = 0 }};
    var st: State = undefined;
    st.init(gpa, std.testing.io, origin_d, cache_d, 4096, .{}, "me", &addrs, &.{}, &.{}, "", true);
    defer st.deinit();

    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    tickCluster(&st, sys.nowSec(st.io));
    try std.testing.expectEqual(@as(u64, 1), st.store.stats.lease_err.load(.monotonic));
    try std.testing.expect(st.catalog.originErrno() != 0);
    // EISDIR is path-level, not NFS down.
    try std.testing.expect(!st.store.origin_io_down.load(.monotonic));

    countMetaErr(&st, -sys.c.ENOENT);
    try std.testing.expectEqual(@as(u64, 0), st.store.stats.meta_err.load(.monotonic));
    countMetaErr(&st, -sys.c.EIO);
    try std.testing.expectEqual(@as(u64, 1), st.store.stats.meta_err.load(.monotonic));
    countMetaErr(&st, -sys.c.ESTALE);
    try std.testing.expectEqual(@as(u64, 2), st.store.stats.meta_err.load(.monotonic));
}

test "hydratePiece fails closed when write generation keeps discarding fills" {
    // A local write-through that races every completeFill used to retry
    // unbounded and stall the FUSE worker. One origin retry is recovery;
    // a second discard is EIO so the client retries instead of hanging
    // (and instead of returning 0 unmarked, which would serve hole zeros).
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-hydrate-discard");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-hydrate-discard");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st: State = undefined;
    st.init(gpa, std.testing.io, origin_d, cache_d, 16, .{}, "me", &.{}, &.{}, &.{}, "", true);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.store.ensureLayout());

    var tb: [192]u8 = undefined;
    var zb: [192]u8 = undefined;
    const origin_z = try sys.toZ(&zb, try std.fmt.bufPrint(&tb, "{s}/race.bin", .{origin_d}));
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(origin_z, "0123456789abcdef"));

    const file = try st.store.get("race.bin", 16, sys.monoSec(st.io));
    defer st.store.releaseFile(file);

    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    var scratch: [16]u8 = undefined;
    var rc: i32 = 0;
    // Hold content_mu so completeFill blocks after beginFill claims. Bump
    // writes, then release so the claim is dropped unmarked. Repeat once
    // during the origin-retry sleep; the second discard must be EIO.
    file.content_mu.lockUncancelable(st.io);
    var holding_content = true;
    const hydrator = try std.Thread.spawn(.{}, struct {
        fn run(state: *State, f: *store_mod.Store.Cached, buf: []u8, out_rc: *i32) void {
            out_rc.* = hydratePiece(state, f, 0, buf);
        }
    }.run, .{ &st, file, scratch[0..], &rc });
    var joined = false;
    // Reverse order: content_mu is dropped before the join, so an assertion
    // that fires mid-scenario cannot deadlock on a parked hydrator.
    defer if (!joined) hydrator.join();
    defer if (holding_content) file.content_mu.unlock(st.io);

    // Each claim records file.writes; discard #1 is the claim stamped 0 and
    // discard #2 the retry's claim stamped 1. Polling "piece 0 is claimed"
    // cannot tell them apart, so the old wait raced the retry's 2 ms sleep
    // and read a lost race as a missing claim.
    var gen: u64 = 0;
    while (gen < 2) {
        var spins: u32 = 0;
        while (true) {
            file.mu.lockUncancelable(st.io);
            const claim = file.filling.get(0);
            file.mu.unlock(st.io);
            if (claim) |g| {
                if (g == gen) break;
                // The hydrator is parked in completeFill on the content_mu
                // held here with the previous claim still recorded: it needs
                // that lock to discard and claim again.
                file.content_mu.unlock(st.io);
                holding_content = false;
                std.Thread.yield() catch {};
                file.content_mu.lockUncancelable(st.io);
                holding_content = true;
            } else {
                // Sleeping between the discard and the retry's claim. Keep
                // content_mu so the retry parks instead of filling.
                std.Thread.yield() catch {};
            }
            spins += 1;
            try std.testing.expect(spins < 1_000_000);
        }
        file.mu.lockUncancelable(st.io);
        file.writes +%= 1;
        file.mu.unlock(st.io);
        file.content_mu.unlock(st.io);
        holding_content = false;
        gen += 1;
        if (gen < 2) {
            file.content_mu.lockUncancelable(st.io);
            holding_content = true;
        }
    }
    // rc is only settled once the hydrator returns; reading it while that
    // thread still runs reports the initial 0 as a passing fill.
    hydrator.join();
    joined = true;
    try std.testing.expectEqual(@as(i32, -sys.c.EIO), rc);
    try std.testing.expect(!st.store.hasPiece(file, 0, sys.monoSec(st.io)));
}

test "serveHydrated falls back to origin when the cache cannot land a fill" {
    // A directory planted at the cache data path refuses openCache (EISDIR),
    // so hydratePiece cannot pwrite the piece. The FUSE read must still
    // return origin bytes: failing that read was a total outage while the
    // origin stayed healthy, the miss-path twin of readServed's warm
    // fallback. Regression: ensureRange's errno used to be the syscall
    // result, so engines saw EIO over a perfectly readable origin file.
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-serve-hydrated");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-serve-hydrated");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st: State = undefined;
    st.init(gpa, std.testing.io, origin_d, cache_d, 16, .{}, "me", &.{}, &.{}, &.{}, "", true);
    defer st.store.deinit();
    defer st.catalog.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.store.ensureLayout());

    const pattern = "0123456789abcdef";
    var tb: [192]u8 = undefined;
    var zb: [192]u8 = undefined;
    const origin_z = try sys.toZ(&zb, try std.fmt.bufPrint(&tb, "{s}/fb.bin", .{origin_d}));
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(origin_z, pattern));

    const file = try st.store.get("fb.bin", pattern.len, sys.monoSec(st.io));
    defer st.store.releaseFile(file);

    var db: [sys.c.PATH_MAX]u8 = undefined;
    const dp = try st.store.cacheDataPath(&db, "fb.bin");
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(std.mem.span(dp), 0o755));

    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    var rb: [16]u8 = undefined;
    const n = serveHydrated(&st, file, "fb.bin", &rb, .{ .off = 0, .len = rb.len }, pattern.len, false);
    try std.testing.expectEqual(@as(isize, @intCast(pattern.len)), n);
    try std.testing.expectEqualStrings(pattern, rb[0..pattern.len]);
    try std.testing.expect(!st.store.hasPiece(file, 0, sys.monoSec(st.io)));
}

test "fileForRead uses a live entry without restatting origin" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-file-for-read");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-file-for-read");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st: State = undefined;
    st.init(gpa, std.testing.io, origin_d, cache_d, 16, .{}, "me", &.{}, &.{}, &.{}, "", true);
    defer st.store.deinit();
    defer st.catalog.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.store.ensureLayout());

    const pattern = "0123456789abcdef";
    var tb: [192]u8 = undefined;
    var zb: [192]u8 = undefined;
    const origin_z = try sys.toZ(&zb, try std.fmt.bufPrint(&tb, "{s}/warm.bin", .{origin_d}));
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(origin_z, pattern));

    const file = try st.store.get("warm.bin", pattern.len, sys.monoSec(st.io));
    st.store.releaseFile(file);

    // Origin gone: a restat would fail ENOENT. A live entry must still
    // answer so a warm sequential read does not pay NFS getattr, and so
    // origin-down does not black-hole a fully cached file.
    try std.testing.expectEqual(@as(i32, 0), sys.unlink(origin_z));
    const live = fileForRead(&st, "warm.bin");
    try std.testing.expect(std.meta.activeTag(live) == .file);
    const got = live.file;
    defer st.store.releaseFile(got);
    try std.testing.expectEqual(pattern.len, got.size);

    const cold = fileForRead(&st, "gone.bin");
    try std.testing.expect(std.meta.activeTag(cold) == .err);
    try std.testing.expectEqual(@as(c_int, -sys.c.ENOENT), cold.err);
}
