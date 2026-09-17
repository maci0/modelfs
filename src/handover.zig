//! Process-image handover for `modelfs update`: encode/decode of mount knobs
//! and the cluster PSK on a sealed memfd (never argv), exec argv that names
//! only fd numbers, and the cache-dir request/ack the CLI uses to ask a live
//! daemon to replace itself.
const std = @import("std");
const proto = @import("proto.zig");
const sys = @import("sys.zig");
const cull = @import("cull.zig");
const fuzzcorpus = @import("fuzzcorpus.zig");

pub const magic = "MFHO1\n";
pub const internal_cmd = "_handover";
pub const state_fd_flag = "--state-fd";
pub const req_file = "update.req";
pub const ack_file = "update.ack";
pub const token_bytes: usize = 16;

/// Cap on the captured FUSE_INIT request. Today's wire form is a 40-byte
/// header plus a 64-byte payload; the slack covers a protocol that grows
/// the payload without needing a new handover format. Sized past one
/// libfuse receive (the kernel can coalesce INIT with the next request
/// into a single read).
pub const init_max: usize = 4096;

/// Cap on the sealed state blob a replacement image reads back. The knobs
/// are a few hundred bytes plus one path per cached inode and open handle;
/// a megabyte is far past any live mount and bounds what a planted fd can
/// make the new image allocate.
pub const max_state_bytes: usize = 1 << 20;

/// Serializable serving identity. Strings are borrowed from the caller on
/// encode and owned by `Owned` on decode.
pub const Knobs = struct {
    origin: []const u8,
    cache: []const u8,
    id: []const u8,
    mount: []const u8,
    piece: u32,
    listen: u16,
    water: cull.Water,
    direct_io: bool,
    allow_other: bool,
    fuse_fd: i32,
    listen_fds: []const i32,
    advertise: []const proto.LeaseAddr,
    seeds: []const proto.LeaseAddr,
    psk: []const u8,
    log_level: std.log.Level = .info,
    /// The FUSE_INIT request the kernel sent, verbatim. The kernel sends it
    /// once per connection, so an image that inherits the connection has to
    /// replay it rather than negotiate; every derived form drops wire bits
    /// (FUSE_MAX_PAGES among them) the connection still runs on.
    init: []const u8 = &.{},
    nodes: []const NodeSnap = &.{},
    opens: []const OpenSnap = &.{},
    next_ino: u64 = 2,
    next_fh: u64 = 1,
};

pub const NodeSnap = struct { ino: u64, path: []const u8, nlookup: u64 };
pub const OpenSnap = struct { fh: u64, path: []const u8 };

pub const Owned = struct {
    origin: []u8,
    cache: []u8,
    id: []u8,
    mount: []u8,
    piece: u32,
    listen: u16,
    water: cull.Water,
    direct_io: bool,
    allow_other: bool,
    fuse_fd: i32,
    listen_fds: []i32,
    advertise: []proto.LeaseAddr,
    seeds: []proto.LeaseAddr,
    psk: []u8,
    log_level: std.log.Level = .info,
    init: []u8 = &.{},
    nodes: []NodeSnap = &.{},
    opens: []OpenSnap = &.{},
    next_ino: u64 = 2,
    next_fh: u64 = 1,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Owned) void {
        std.crypto.secureZero(u8, self.psk);
        self.arena.deinit();
    }
};

const JsonDoc = struct {
    origin: []const u8,
    cache: []const u8,
    id: []const u8,
    mount: []const u8,
    piece: u32,
    listen: u16,
    brun: u32,
    bcull: u32,
    bstop: u32,
    direct_io: bool,
    allow_other: bool,
    fuse_fd: i32,
    listen_fds: []const i32,
    advertise: []const proto.LeaseAddr,
    seeds: []const proto.LeaseAddr,
    psk_len: usize,
    log_level: std.log.Level = .info,
    init: []const u8 = "",
    nodes: []const NodeSnap = &.{},
    opens: []const OpenSnap = &.{},
    next_ino: u64 = 2,
    next_fh: u64 = 1,
};

fn utf8Knob(s: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.NonUtf8Knob;
}

fn hexInit(gpa: std.mem.Allocator, init: []const u8) ![]u8 {
    if (init.len > init_max) return error.InitTooLarge;
    const out = try gpa.alloc(u8, init.len * 2);
    const hex_digits = "0123456789abcdef";
    for (init, 0..) |b, i| {
        out[i * 2] = hex_digits[b >> 4];
        out[i * 2 + 1] = hex_digits[b & 0xf];
    }
    return out;
}

/// JSON knobs plus a trailing raw PSK. The secret is never UTF-8 JSON and
/// never appears in exec argv.
pub fn encode(gpa: std.mem.Allocator, k: Knobs) ![]u8 {
    if (!cull.ordered(k.water)) return error.BadWatermarks;
    const init_hex = try hexInit(gpa, k.init);
    defer gpa.free(init_hex);
    try utf8Knob(k.id);
    for (k.advertise) |a| try utf8Knob(a.ip);
    for (k.seeds) |a| try utf8Knob(a.ip);
    for (k.psk) |ch| {
        if (ch == '\r' or ch == '\n') return error.BadPsk;
    }
    const doc = JsonDoc{
        .origin = k.origin,
        .cache = k.cache,
        .id = k.id,
        .mount = k.mount,
        .piece = k.piece,
        .listen = k.listen,
        .brun = k.water.brun,
        .bcull = k.water.bcull,
        .bstop = k.water.bstop,
        .direct_io = k.direct_io,
        .allow_other = k.allow_other,
        .fuse_fd = k.fuse_fd,
        .listen_fds = k.listen_fds,
        .advertise = k.advertise,
        .seeds = k.seeds,
        .psk_len = k.psk.len,
        .log_level = k.log_level,
        .init = init_hex,
        .nodes = k.nodes,
        .opens = k.opens,
        .next_ino = k.next_ino,
        .next_fh = k.next_fh,
    };
    const json = try std.json.Stringify.valueAlloc(gpa, doc, .{});
    defer gpa.free(json);
    var w: std.ArrayList(u8) = .empty;
    errdefer w.deinit(gpa);
    try w.appendSlice(gpa, magic);
    try w.appendSlice(gpa, json);
    try w.append(gpa, '\n');
    try w.appendSlice(gpa, k.psk);
    return w.toOwnedSlice(gpa);
}

pub fn decode(gpa: std.mem.Allocator, blob: []const u8) !Owned {
    if (!std.mem.startsWith(u8, blob, magic)) return error.BadMagic;
    const rest = blob[magic.len..];
    const nl = std.mem.findScalar(u8, rest, '\n') orelse return error.Truncated;
    const json = rest[0..nl];
    const psk_bytes = rest[nl + 1 ..];
    const parsed = std.json.parseFromSlice(JsonDoc, gpa, json, .{ .ignore_unknown_fields = true }) catch return error.BadJson;
    defer parsed.deinit();
    const d = parsed.value;
    if (d.psk_len != psk_bytes.len) return error.PskLen;
    if (d.psk_len > proto.max_psk_bytes) return error.PskTooLarge;
    for (psk_bytes) |ch| {
        if (ch == '\r' or ch == '\n') return error.BadPsk;
    }
    if (d.init.len % 2 != 0 or d.init.len / 2 > init_max) return error.BadInit;
    if (!cull.ordered(.{ .brun = d.brun, .bcull = d.bcull, .bstop = d.bstop })) return error.BadWatermarks;

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var out: Owned = .{
        .origin = try a.dupe(u8, d.origin),
        .cache = try a.dupe(u8, d.cache),
        .id = try a.dupe(u8, d.id),
        .mount = try a.dupe(u8, d.mount),
        .piece = d.piece,
        .listen = d.listen,
        .water = .{ .brun = d.brun, .bcull = d.bcull, .bstop = d.bstop },
        .direct_io = d.direct_io,
        .allow_other = d.allow_other,
        .fuse_fd = d.fuse_fd,
        .listen_fds = try a.dupe(i32, d.listen_fds),
        .advertise = try a.alloc(proto.LeaseAddr, d.advertise.len),
        .seeds = try a.alloc(proto.LeaseAddr, d.seeds.len),
        .psk = try a.dupe(u8, psk_bytes),
        .log_level = d.log_level,
        .init = try a.alloc(u8, d.init.len / 2),
        .nodes = try a.alloc(NodeSnap, d.nodes.len),
        .opens = try a.alloc(OpenSnap, d.opens.len),
        .next_ino = d.next_ino,
        .next_fh = d.next_fh,
        .arena = undefined,
    };
    _ = std.fmt.hexToBytes(out.init, d.init) catch return error.BadInit;
    for (d.nodes, 0..) |n, i| {
        out.nodes[i] = .{ .ino = n.ino, .path = try a.dupe(u8, n.path), .nlookup = n.nlookup };
    }
    for (d.opens, 0..) |o, i| {
        out.opens[i] = .{ .fh = o.fh, .path = try a.dupe(u8, o.path) };
    }
    for (d.advertise, 0..) |ad, i| {
        out.advertise[i] = .{ .ip = try a.dupe(u8, ad.ip), .port = ad.port, .mbps = ad.mbps };
    }
    for (d.seeds, 0..) |sd, i| {
        out.seeds[i] = .{ .ip = try a.dupe(u8, sd.ip), .port = sd.port, .mbps = sd.mbps };
    }
    out.arena = arena;
    return out;
}

/// NUL-terminated argv for execve of the replacement image:
/// `bin _handover --state-fd N <mountpoint>`. Only the fd number and the
/// mountpoint travel here; the knobs and the PSK are on the memfd that
/// number names, because argv is world-readable through /proc. The
/// mountpoint is repeated from the state blob so `ps` keeps naming the
/// mount this process serves, and `cmdHandover` refuses a pair that
/// disagrees.
pub fn execArgvZ(gpa: std.mem.Allocator, bin: []const u8, state_fd: i32, mount: []const u8) ![:null]?[*:0]const u8 {
    const fd_tmp = try std.fmt.allocPrint(gpa, "{d}", .{state_fd});
    defer gpa.free(fd_tmp);
    const argv = try gpa.allocSentinel(?[*:0]const u8, 5, null);
    errdefer gpa.free(argv);
    var filled: usize = 0;
    errdefer for (argv[0..filled]) |a| gpa.free(std.mem.span(a.?));
    for ([_][]const u8{ bin, internal_cmd, state_fd_flag, fd_tmp, mount }) |word| {
        argv[filled] = try gpa.dupeZ(u8, word);
        filled += 1;
    }
    return argv;
}

pub fn freeExecArgvZ(gpa: std.mem.Allocator, argv: [:null]?[*:0]const u8) void {
    var i: usize = 0;
    while (argv[i]) |a| : (i += 1) gpa.free(std.mem.span(a));
    gpa.free(argv);
}

pub fn writeStateFd(blob: []const u8) !c_int {
    const fd = try sys.memfdSealed(blob);
    return fd;
}

pub fn readStateFd(gpa: std.mem.Allocator, fd: c_int) !Owned {
    const blob = try sys.readAllFdAlloc(gpa, fd, max_state_bytes);
    // The blob's tail is the raw PSK: wipe before the free so the secret
    // does not linger in the allocator's recycle pool, like every other
    // PSK-holding buffer in the daemon. Defers run LIFO, so the wipe is
    // declared second and executes first.
    defer gpa.free(blob);
    defer std.crypto.secureZero(u8, blob);
    return decode(gpa, blob);
}

pub const Req = struct { bin: []const u8, token: []const u8 };
pub const Ack = struct { token: []const u8 };

pub fn encodeReq(gpa: std.mem.Allocator, bin: []const u8, token: []const u8) ![]u8 {
    try utf8Knob(token);
    const json = try std.json.Stringify.valueAlloc(gpa, Req{ .bin = bin, .token = token }, .{});
    defer gpa.free(json);
    return std.fmt.allocPrint(gpa, "{s}\n", .{json});
}
pub fn decodeReq(gpa: std.mem.Allocator, blob: []const u8) !std.json.Parsed(Req) {
    return std.json.parseFromSlice(Req, gpa, std.mem.trim(u8, blob, " \t\r\n"), .{});
}

pub fn encodeAck(gpa: std.mem.Allocator, token: []const u8) ![]u8 {
    try utf8Knob(token);
    const json = try std.json.Stringify.valueAlloc(gpa, Ack{ .token = token }, .{});
    defer gpa.free(json);
    return std.fmt.allocPrint(gpa, "{s}\n", .{json});
}

pub fn decodeAck(gpa: std.mem.Allocator, blob: []const u8) !std.json.Parsed(Ack) {
    return std.json.parseFromSlice(Ack, gpa, std.mem.trim(u8, blob, " \t\r\n"), .{ .ignore_unknown_fields = true });
}

/// Hex handshake nonce matching one `update.req` to its `update.ack`. Fails
/// rather than falling back to anything derivable: a pid-shaped token would
/// let a same-uid racer ack an update it did not request.
pub fn randomToken(io: std.Io, out: *[token_bytes * 2]u8) !void {
    var raw: [token_bytes]u8 = undefined;
    io.randomSecure(&raw) catch return error.NoRandom;
    const hex = std.fmt.bytesToHex(raw, .lower);
    @memcpy(out, &hex);
}

pub const Handoff = struct { state_fd: i32, mount: []const u8 };

/// `_handover --state-fd N <mountpoint>`, the only argv `execArgvZ` writes.
pub fn parseHandoffArgs(args: []const []const u8) !Handoff {
    if (args.len != 4 or !std.mem.eql(u8, args[1], state_fd_flag)) return error.BadStateFd;
    const n = std.fmt.parseInt(i32, args[2], 10) catch return error.BadStateFd;
    if (n < 0) return error.BadStateFd;
    if (args[3].len == 0) return error.BadStateFd;
    return .{ .state_fd = n, .mount = args[3] };
}

test "handover encode/decode round-trips knobs and keeps the PSK off argv" {
    const gpa = std.testing.allocator;
    const psk = "cluster-secret-do-not-leak";
    const knobs = Knobs{
        .origin = "/nas/models",
        .cache = "/var/cache/modelfs",
        .id = "spark1",
        .mount = "/models",
        .piece = 16 * 1024 * 1024,
        .listen = 18080,
        .water = .{ .brun = 12, .bcull = 6, .bstop = 2 },
        .direct_io = true,
        .allow_other = false,
        .fuse_fd = 7,
        .listen_fds = &.{ 4, 5 },
        .advertise = &.{.{ .ip = "10.0.0.1", .port = 18080, .mbps = 200000 }},
        .seeds = &.{.{ .ip = "10.0.0.9", .port = 19091, .mbps = 10000 }},
        .psk = psk,
        .init = "\x68\x00\x00\x00\x1a\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00",
        .nodes = &.{.{ .ino = 5, .path = "/gguf/a.gguf", .nlookup = 3 }},
        .opens = &.{.{ .fh = 9, .path = "/gguf/a.gguf" }},
        .next_ino = 6,
        .next_fh = 10,
        .log_level = .err,
    };
    const blob = try encode(gpa, knobs);
    defer gpa.free(blob);
    try std.testing.expect(std.mem.startsWith(u8, blob, magic));

    var got = try decode(gpa, blob);
    defer got.deinit();
    try std.testing.expectEqualStrings(knobs.origin, got.origin);
    try std.testing.expectEqualStrings(knobs.cache, got.cache);
    try std.testing.expectEqualStrings(knobs.id, got.id);
    try std.testing.expectEqualStrings(knobs.mount, got.mount);
    try std.testing.expectEqual(knobs.piece, got.piece);
    try std.testing.expectEqual(knobs.listen, got.listen);
    try std.testing.expectEqual(knobs.water.brun, got.water.brun);
    try std.testing.expectEqual(knobs.water.bcull, got.water.bcull);
    try std.testing.expectEqual(knobs.water.bstop, got.water.bstop);
    try std.testing.expectEqual(knobs.direct_io, got.direct_io);
    try std.testing.expectEqual(knobs.allow_other, got.allow_other);
    try std.testing.expectEqual(knobs.fuse_fd, got.fuse_fd);
    try std.testing.expectEqualSlices(i32, knobs.listen_fds, got.listen_fds);
    try std.testing.expectEqual(@as(usize, 1), got.advertise.len);
    try std.testing.expectEqualStrings("10.0.0.1", got.advertise[0].ip);
    try std.testing.expectEqual(@as(u16, 18080), got.advertise[0].port);
    try std.testing.expectEqual(@as(u32, 200000), got.advertise[0].mbps);
    try std.testing.expectEqual(@as(usize, 1), got.seeds.len);
    try std.testing.expectEqualStrings("10.0.0.9", got.seeds[0].ip);
    try std.testing.expectEqual(@as(u16, 19091), got.seeds[0].port);
    try std.testing.expectEqual(@as(u32, 10000), got.seeds[0].mbps);
    try std.testing.expectEqualStrings(psk, got.psk);
    // The kernel sends FUSE_INIT once per connection: losing those bytes
    // would leave the replacement image unable to replay the negotiation.
    try std.testing.expectEqualSlices(u8, knobs.init, got.init);
    try std.testing.expectEqual(@as(usize, 1), got.nodes.len);
    try std.testing.expectEqual(@as(u64, 5), got.nodes[0].ino);
    try std.testing.expectEqualStrings("/gguf/a.gguf", got.nodes[0].path);
    try std.testing.expectEqual(@as(u64, 3), got.nodes[0].nlookup);
    try std.testing.expectEqual(@as(usize, 1), got.opens.len);
    try std.testing.expectEqual(@as(u64, 9), got.opens[0].fh);
    try std.testing.expectEqualStrings("/gguf/a.gguf", got.opens[0].path);
    try std.testing.expectEqual(@as(u64, 6), got.next_ino);
    try std.testing.expectEqual(@as(u64, 10), got.next_fh);

    const argv_z = try execArgvZ(gpa, "/usr/bin/modelfs", 9, knobs.mount);
    defer freeExecArgvZ(gpa, argv_z);
    try std.testing.expectEqualStrings("/usr/bin/modelfs", std.mem.span(argv_z[0].?));
    try std.testing.expectEqualStrings(internal_cmd, std.mem.span(argv_z[1].?));
    try std.testing.expectEqualStrings(state_fd_flag, std.mem.span(argv_z[2].?));
    try std.testing.expectEqualStrings("9", std.mem.span(argv_z[3].?));
    // ps must keep naming the mount a replaced image is serving.
    try std.testing.expectEqualStrings(knobs.mount, std.mem.span(argv_z[4].?));
    // The whole point of the memfd: /proc/<pid>/cmdline is world-readable.
    var w: usize = 0;
    while (argv_z[w]) |word| : (w += 1) {
        try std.testing.expect(std.mem.find(u8, std.mem.span(word), psk) == null);
    }

    const fd = try writeStateFd(blob);
    defer sys.close(fd);
    var from_fd = try readStateFd(gpa, fd);
    defer from_fd.deinit();
    try std.testing.expectEqualStrings(knobs.origin, from_fd.origin);
    try std.testing.expectEqualStrings(psk, from_fd.psk);
    try std.testing.expectEqual(knobs.listen, from_fd.listen);
    try std.testing.expectEqual(knobs.piece, from_fd.piece);
    try std.testing.expectEqual(knobs.log_level, from_fd.log_level);
    inline for (std.meta.tags(std.log.Level)) |level| {
        var configured = knobs;
        configured.log_level = level;
        const encoded = try encode(gpa, configured);
        defer gpa.free(encoded);
        var decoded = try decode(gpa, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(level, decoded.log_level);
    }
}

test "handover log level defaults for older images and rejects invalid values" {
    const gpa = std.testing.allocator;
    const legacy_blob = seed_handover_ok[4..];
    var legacy = try decode(gpa, legacy_blob);
    defer legacy.deinit();
    try std.testing.expectEqual(std.log.Level.info, legacy.log_level);
    const end = std.mem.findScalar(u8, legacy_blob, '}').?;
    for ([_][]const u8{ "\"verbose\"", "null", "true", "{}" }) |value| {
        const blob = try std.fmt.allocPrint(gpa, "{s},\"log_level\":{s}{s}", .{
            legacy_blob[0..end], value, legacy_blob[end..],
        });
        defer gpa.free(blob);
        try std.testing.expectError(error.BadJson, decode(gpa, blob));
    }
}

test "handover decode owns arena blocks allocated for snapshot paths" {
    const gpa = std.testing.allocator;
    const path = [_]u8{'x'} ** 1024;
    const nodes = [_]NodeSnap{.{ .ino = 5, .path = &path, .nlookup = 3 }} ** 32;
    const opens = [_]OpenSnap{.{ .fh = 9, .path = &path }} ** 32;
    const knobs = Knobs{
        .origin = "/o",
        .cache = "/c",
        .id = "n",
        .mount = "/m",
        .piece = 4096,
        .listen = 1,
        .water = .{},
        .direct_io = true,
        .allow_other = false,
        .fuse_fd = 3,
        .listen_fds = &.{3},
        .advertise = &.{},
        .seeds = &.{},
        .psk = "secret",
        .nodes = &nodes,
        .opens = &opens,
    };
    const blob = try encode(gpa, knobs);
    defer gpa.free(blob);
    var got = try decode(gpa, blob);
    defer got.deinit();
    try std.testing.expectEqual(nodes.len, got.nodes.len);
    try std.testing.expectEqual(opens.len, got.opens.len);
    for (got.nodes) |node| try std.testing.expectEqualStrings(&path, node.path);
    for (got.opens) |open| try std.testing.expectEqualStrings(&path, open.path);
}

test "handover JSON escapes control bytes so odd argv paths still round-trip" {
    const gpa = std.testing.allocator;
    // A raw C0 byte in a mountpoint or binary path used to publish a
    // document std.json refuses: the replacement image's decode failed and,
    // with the req-decode failure swallowed, `modelfs update` of that mount
    // silently timed out forever.
    const knobs = Knobs{
        .origin = "/nas/mo\"dels",
        .cache = "/var/cache/m\todelfs",
        .id = "spa\rk1",
        .mount = "/mo\nmodels",
        .piece = 4096,
        .listen = 1,
        .water = .{},
        .direct_io = true,
        .allow_other = false,
        .fuse_fd = 3,
        .listen_fds = &.{3},
        .advertise = &.{},
        .seeds = &.{},
        .psk = "secret",
    };
    const blob = try encode(gpa, knobs);
    defer gpa.free(blob);
    var got = try decode(gpa, blob);
    defer got.deinit();
    try std.testing.expectEqualStrings(knobs.origin, got.origin);
    try std.testing.expectEqualStrings(knobs.cache, got.cache);
    try std.testing.expectEqualStrings(knobs.id, got.id);
    try std.testing.expectEqualStrings(knobs.mount, got.mount);

    const req = try encodeReq(gpa, "/opt/bi\nnary", "tok\"0\\");
    defer gpa.free(req);
    const parsed = try decodeReq(gpa, req);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/opt/bi\nnary", parsed.value.bin);
    try std.testing.expectEqualStrings("tok\"0\\", parsed.value.token);

    const paths = [_][]const u8{ "/models/überutf8", "/models/caf\u{e9}", "/models/cafe\u{301}", "/models/\u{1f600}", "/nas/\xff\xfe", "/models/\xc3", "/models/\xed\xa0\x80" };
    for (paths) |path| {
        var raw = knobs;
        raw.origin = path;
        raw.cache = path;
        raw.mount = path;
        raw.nodes = &.{.{ .ino = 5, .path = path, .nlookup = 3 }};
        raw.opens = &.{.{ .fh = 9, .path = path }};
        const blob2 = try encode(gpa, raw);
        defer gpa.free(blob2);
        try std.testing.expect(std.unicode.utf8ValidateSlice(blob2));
        var got2 = try decode(gpa, blob2);
        defer got2.deinit();
        try std.testing.expectEqualStrings(path, got2.origin);
        try std.testing.expectEqualStrings(path, got2.cache);
        try std.testing.expectEqualStrings(path, got2.mount);
        try std.testing.expectEqualStrings(path, got2.nodes[0].path);
        try std.testing.expectEqualStrings(path, got2.opens[0].path);
        const argv = try execArgvZ(gpa, "/bin/modelfs", 9, got2.mount);
        defer freeExecArgvZ(gpa, argv);
        try std.testing.expectEqualStrings(path, std.mem.span(argv[4].?));
    }
}

test "handover request preserves non-UTF-8 binary paths" {
    const gpa = std.testing.allocator;
    const bin = "/opt/\xff/modelfs";
    const req = try encodeReq(gpa, bin, "token");
    defer gpa.free(req);
    try std.testing.expect(std.unicode.utf8ValidateSlice(req));
    const parsed = try decodeReq(gpa, req);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(bin, parsed.value.bin);
    try std.testing.expectEqualStrings("token", parsed.value.token);
}

test "handover decode refuses a truncated or mismatched PSK trailer" {
    const gpa = std.testing.allocator;
    const knobs = Knobs{
        .origin = "/o",
        .cache = "/c",
        .id = "n",
        .mount = "/m",
        .piece = 4096,
        .listen = 1,
        .water = .{},
        .direct_io = true,
        .allow_other = false,
        .fuse_fd = 3,
        .listen_fds = &.{3},
        .advertise = &.{},
        .seeds = &.{},
        .psk = "secret",
    };
    const blob = try encode(gpa, knobs);
    defer gpa.free(blob);
    try std.testing.expectError(error.BadMagic, decode(gpa, blob[1..]));
    try std.testing.expectError(error.PskLen, decode(gpa, blob[0 .. blob.len - 1]));
}

test "parseHandoffArgs takes only the form execArgvZ writes" {
    const ok = try parseHandoffArgs(&.{ internal_cmd, state_fd_flag, "11", "/models" });
    try std.testing.expectEqual(@as(i32, 11), ok.state_fd);
    try std.testing.expectEqualStrings("/models", ok.mount);
    try std.testing.expectError(error.BadStateFd, parseHandoffArgs(&.{internal_cmd}));
    try std.testing.expectError(error.BadStateFd, parseHandoffArgs(&.{ internal_cmd, "7", "/models" }));
    try std.testing.expectError(error.BadStateFd, parseHandoffArgs(&.{ internal_cmd, state_fd_flag, "11" }));
    try std.testing.expectError(error.BadStateFd, parseHandoffArgs(&.{ internal_cmd, state_fd_flag, "-3", "/models" }));
    try std.testing.expectError(error.BadStateFd, parseHandoffArgs(&.{ internal_cmd, state_fd_flag, "nope", "/models" }));
    try std.testing.expectError(error.BadStateFd, parseHandoffArgs(&.{ internal_cmd, state_fd_flag, "11", "" }));
    try std.testing.expectError(error.BadStateFd, parseHandoffArgs(&.{ internal_cmd, "--other", "3", "/models" }));
}

test "update req/ack carry a token the client can match" {
    const gpa = std.testing.allocator;
    var tok: [token_bytes * 2]u8 = undefined;
    try randomToken(std.testing.io, &tok);
    // Two tokens in a row must differ, or a stale ack would match the next
    // request; a constant fallback used to make that possible.
    var again: [token_bytes * 2]u8 = undefined;
    try randomToken(std.testing.io, &again);
    try std.testing.expect(!std.mem.eql(u8, &tok, &again));
    const req = try encodeReq(gpa, "/bin/modelfs", &tok);
    defer gpa.free(req);
    const parsed = try decodeReq(gpa, req);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/bin/modelfs", parsed.value.bin);
    try std.testing.expectEqualStrings(&tok, parsed.value.token);
    const ack = try encodeAck(gpa, parsed.value.token);
    defer gpa.free(ack);
    const got = try decodeAck(gpa, ack);
    defer got.deinit();
    try std.testing.expectEqualStrings(&tok, got.value.token);

    const ack_special = try encodeAck(gpa, "tok\"0\\");
    defer gpa.free(ack_special);
    const got_special = try decodeAck(gpa, ack_special);
    defer got_special.deinit();
    try std.testing.expectEqualStrings("tok\"0\\", got_special.value.token);
}

test "update tokens and request bytes replay from injected entropy" {
    const Entropy = struct {
        fn fill(userdata: ?*anyopaque, buf: []u8) std.Io.RandomSecureError!void {
            const prng: *std.Random.DefaultPrng = @ptrCast(@alignCast(userdata));
            prng.random().bytes(buf);
        }
    };
    var vtable = std.Io.failing.vtable.*;
    vtable.randomSecure = Entropy.fill;
    const seed = 20260917;
    var prng = std.Random.DefaultPrng.init(seed);
    const io: std.Io = .{ .userdata = &prng, .vtable = &vtable };
    var tokens: [4][token_bytes * 2]u8 = undefined;
    for (&tokens) |*token| try randomToken(io, token);
    prng = std.Random.DefaultPrng.init(seed);
    for (tokens, 0..) |token, i| {
        var replay: [token_bytes * 2]u8 = undefined;
        try randomToken(io, &replay);
        try std.testing.expectEqualSlices(u8, &token, &replay);
        if (i > 0) try std.testing.expect(!std.mem.eql(u8, &token, &tokens[i - 1]));
        const req = try encodeReq(std.testing.allocator, "/bin/modelfs", &token);
        defer std.testing.allocator.free(req);
        const replay_req = try encodeReq(std.testing.allocator, "/bin/modelfs", &replay);
        defer std.testing.allocator.free(replay_req);
        try std.testing.expectEqualStrings(req, replay_req);
        const ack = try encodeAck(std.testing.allocator, &token);
        defer std.testing.allocator.free(ack);
        const replay_ack = try encodeAck(std.testing.allocator, &replay);
        defer std.testing.allocator.free(replay_ack);
        try std.testing.expectEqualStrings(ack, replay_ack);
    }
}

test "update token entropy failures leave output unchanged" {
    const Entropy = struct {
        fn fill(userdata: ?*anyopaque, buf: []u8) std.Io.RandomSecureError!void {
            const err: *std.Io.RandomSecureError = @ptrCast(@alignCast(userdata));
            @memset(buf[0 .. buf.len / 2], 0xab);
            return err.*;
        }
    };
    var vtable = std.Io.failing.vtable.*;
    vtable.randomSecure = Entropy.fill;
    const original = [_]u8{'!'} ** (token_bytes * 2);
    var token = original;
    try std.testing.expectError(error.NoRandom, randomToken(std.Io.failing, &token));
    try std.testing.expectEqualSlices(u8, &original, &token);
    for ([_]std.Io.RandomSecureError{ error.EntropyUnavailable, error.Canceled }) |err| {
        var failure = err;
        const io: std.Io = .{ .userdata = &failure, .vtable = &vtable };
        try std.testing.expectError(error.NoRandom, randomToken(io, &token));
        try std.testing.expectEqualSlices(u8, &original, &token);
    }
}

test "handover encode and decode refuse PSK with line breaks" {
    const gpa = std.testing.allocator;
    var knobs = Knobs{
        .origin = "/o",
        .cache = "/c",
        .id = "n",
        .mount = "/m",
        .piece = 4096,
        .listen = 1,
        .water = .{},
        .direct_io = true,
        .allow_other = false,
        .fuse_fd = 3,
        .listen_fds = &.{3},
        .advertise = &.{},
        .seeds = &.{},
        .psk = "secret\nbreak",
    };
    try std.testing.expectError(error.BadPsk, encode(gpa, knobs));
    knobs.psk = "secret";
    const blob = try encode(gpa, knobs);
    defer gpa.free(blob);
    var tampered = try gpa.dupe(u8, blob);
    defer gpa.free(tampered);
    tampered[tampered.len - 1] = '\n';
    try std.testing.expectError(error.BadPsk, decode(gpa, tampered));
}

const seed_handover_ok = fuzzcorpus.entry(
    "MFHO1\n{\"origin\":\"/o\",\"cache\":\"/c\",\"id\":\"n1\",\"mount\":\"/m\",\"piece\":4096,\"listen\":18080,\"brun\":10,\"bcull\":7,\"bstop\":3,\"direct_io\":false,\"allow_other\":false,\"fuse_fd\":3,\"listen_fds\":[4],\"advertise\":[],\"seeds\":[],\"init\":\"\",\"nodes\":[],\"opens\":[],\"next_ino\":2,\"next_fh\":1,\"psk_len\":6}\nsecret",
);
const seed_handover_bad_magic = fuzzcorpus.entry("BAD1\n{}");
const seed_handover_truncated = fuzzcorpus.entry("MFHO1\n{\"origin\":\"/o\"");
const seed_handover_bad_psk_len = fuzzcorpus.entry(
    "MFHO1\n{\"origin\":\"/o\",\"cache\":\"/c\",\"id\":\"n1\",\"mount\":\"/m\",\"piece\":4096,\"listen\":1,\"brun\":10,\"bcull\":7,\"bstop\":3,\"direct_io\":false,\"allow_other\":false,\"fuse_fd\":3,\"listen_fds\":[],\"advertise\":[],\"seeds\":[],\"init\":\"\",\"nodes\":[],\"opens\":[],\"next_ino\":2,\"next_fh\":1,\"psk_len\":99}\nshort",
);
const seed_handover_odd_init = fuzzcorpus.entry(
    "MFHO1\n{\"origin\":\"/o\",\"cache\":\"/c\",\"id\":\"n1\",\"mount\":\"/m\",\"piece\":4096,\"listen\":1,\"brun\":10,\"bcull\":7,\"bstop\":3,\"direct_io\":false,\"allow_other\":false,\"fuse_fd\":3,\"listen_fds\":[],\"advertise\":[],\"seeds\":[],\"init\":\"abc\",\"nodes\":[],\"opens\":[],\"next_ino\":2,\"next_fh\":1,\"psk_len\":0}\n",
);
const seed_handover_bad_hex = fuzzcorpus.entry(
    "MFHO1\n{\"origin\":\"/o\",\"cache\":\"/c\",\"id\":\"n1\",\"mount\":\"/m\",\"piece\":4096,\"listen\":1,\"brun\":10,\"bcull\":7,\"bstop\":3,\"direct_io\":false,\"allow_other\":false,\"fuse_fd\":3,\"listen_fds\":[],\"advertise\":[],\"seeds\":[],\"init\":\"zzzz\",\"nodes\":[],\"opens\":[],\"next_ino\":2,\"next_fh\":1,\"psk_len\":0}\n",
);
const seed_handover_psk_huge = fuzzcorpus.entry(
    "MFHO1\n{\"origin\":\"/o\",\"cache\":\"/c\",\"id\":\"n1\",\"mount\":\"/m\",\"piece\":4096,\"listen\":1,\"brun\":10,\"bcull\":7,\"bstop\":3,\"direct_io\":false,\"allow_other\":false,\"fuse_fd\":3,\"listen_fds\":[],\"advertise\":[],\"seeds\":[],\"init\":\"\",\"nodes\":[],\"opens\":[],\"next_ino\":2,\"next_fh\":1,\"psk_len\":4097}\n",
);
const seed_handover_bad_json = fuzzcorpus.entry("MFHO1\n{not json\n");
const seed_handover_nodes = fuzzcorpus.entry(
    "MFHO1\n{\"origin\":\"/o\",\"cache\":\"/c\",\"id\":\"n1\",\"mount\":\"/m\",\"piece\":4096,\"listen\":1,\"brun\":10,\"bcull\":7,\"bstop\":3,\"direct_io\":true,\"allow_other\":false,\"fuse_fd\":3,\"listen_fds\":[3],\"advertise\":[{\"ip\":\"127.0.0.1\",\"port\":18080}],\"seeds\":[],\"init\":\"0102\",\"nodes\":[{\"ino\":5,\"path\":\"/a.bin\",\"nlookup\":1}],\"opens\":[{\"fh\":10,\"path\":\"/a.bin\"}],\"next_ino\":6,\"next_fh\":11,\"psk_len\":4}\npsk1",
);
const seed_handover_req = fuzzcorpus.entry("{\"bin\":\"/usr/bin/modelfs\",\"token\":\"0123456789abcdef\"}\n");
const seed_handover_ack = fuzzcorpus.entry("{\"token\":\"0123456789abcdef\"}\n");

const fuzz_handover_corpus = [_][]const u8{
    &seed_handover_ok,
    &seed_handover_bad_magic,
    &seed_handover_truncated,
    &seed_handover_bad_psk_len,
    &seed_handover_odd_init,
    &seed_handover_bad_hex,
    &seed_handover_psk_huge,
    &seed_handover_bad_json,
    &seed_handover_nodes,
    &seed_handover_req,
    &seed_handover_ack,
};

/// decode consumes untrusted handover state blobs. It must fail closed on
/// invalid magic, truncated headers, mismatched PSK lengths, or non-hex
/// init data, bound all allocations, and be deterministic across re-reads.
fn fuzzHandoverDecodeOne(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var blob_buf: [2048]u8 = undefined;
    const blob = blob_buf[0..smith.slice(&blob_buf)];

    if (decode(gpa, blob)) |owned| {
        var mut_owned = owned;
        defer mut_owned.deinit();

        try std.testing.expect(mut_owned.psk.len <= proto.max_psk_bytes);
        try std.testing.expect(mut_owned.init.len <= init_max);

        // Determinism: decoding again yields identical values
        var again = try decode(gpa, blob);
        defer again.deinit();
        try std.testing.expectEqualStrings(mut_owned.origin, again.origin);
        try std.testing.expectEqualStrings(mut_owned.cache, again.cache);
        try std.testing.expectEqualStrings(mut_owned.id, again.id);
        try std.testing.expectEqualStrings(mut_owned.mount, again.mount);
        try std.testing.expectEqual(mut_owned.piece, again.piece);
        try std.testing.expectEqual(mut_owned.listen, again.listen);
        try std.testing.expectEqual(mut_owned.fuse_fd, again.fuse_fd);
        try std.testing.expectEqual(mut_owned.direct_io, again.direct_io);
        try std.testing.expectEqual(mut_owned.allow_other, again.allow_other);
        try std.testing.expectEqualStrings(mut_owned.psk, again.psk);
        try std.testing.expectEqualSlices(u8, mut_owned.init, again.init);
        try std.testing.expectEqual(mut_owned.nodes.len, again.nodes.len);
        try std.testing.expectEqual(mut_owned.opens.len, again.opens.len);
        try std.testing.expectEqual(mut_owned.advertise.len, again.advertise.len);
        for (mut_owned.advertise, again.advertise) |a, b| {
            try std.testing.expectEqualStrings(a.ip, b.ip);
            try std.testing.expectEqual(a.port, b.port);
            try std.testing.expectEqual(a.mbps, b.mbps);
        }
        try std.testing.expectEqual(mut_owned.seeds.len, again.seeds.len);
        for (mut_owned.seeds, again.seeds) |a, b| {
            try std.testing.expectEqualStrings(a.ip, b.ip);
            try std.testing.expectEqual(a.port, b.port);
            try std.testing.expectEqual(a.mbps, b.mbps);
        }
        try std.testing.expectEqual(mut_owned.next_ino, again.next_ino);
        try std.testing.expectEqual(mut_owned.next_fh, again.next_fh);
    } else |_| {}

    if (decodeReq(gpa, blob)) |req| {
        defer req.deinit();
        var again_req = try decodeReq(gpa, blob);
        defer again_req.deinit();
        try std.testing.expectEqualStrings(req.value.bin, again_req.value.bin);
        try std.testing.expectEqualStrings(req.value.token, again_req.value.token);
    } else |_| {}

    if (decodeAck(gpa, blob)) |ack| {
        defer ack.deinit();
        var again_ack = try decodeAck(gpa, blob);
        defer again_ack.deinit();
        try std.testing.expectEqualStrings(ack.value.token, again_ack.value.token);
    } else |_| {}
}

test "fuzz handover state decode fails closed and enforces bounds" {
    try std.testing.fuzz({}, fuzzHandoverDecodeOne, .{ .corpus = &fuzz_handover_corpus });
}
