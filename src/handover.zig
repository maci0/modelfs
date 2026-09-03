//! Process-image handover for `modelfs update`: encode/decode of mount knobs
//! and the cluster PSK on a sealed memfd (never argv), exec argv that names
//! only fd numbers, and the cache-dir request/ack the CLI uses to ask a live
//! daemon to replace itself.
const std = @import("std");
const proto = @import("proto.zig");
const sys = @import("sys.zig");
const cull = @import("cull.zig");

pub const magic = "MFHO1\n";
pub const internal_cmd = "_handover";
pub const state_fd_flag = "--state-fd";
pub const req_file = "update.req";
pub const ack_file = "update.ack";
pub const token_bytes: usize = 16;

pub const Addr = struct {
    ip: []const u8,
    port: u16,
};

/// Cap on the captured FUSE_INIT request. Today's wire form is a 40-byte
/// header plus a 64-byte payload; the slack covers a protocol that grows
/// the payload without needing a new handover format.
pub const init_max: usize = 256;

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
    advertise: []const Addr,
    seeds: []const Addr,
    psk: []const u8,
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
    init: []u8 = &.{},
    nodes: []NodeSnap = &.{},
    opens: []OpenSnap = &.{},
    next_ino: u64 = 2,
    next_fh: u64 = 1,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
    }
};

const JsonAddr = struct { ip: []const u8, port: u16 };
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
    advertise: []const JsonAddr,
    seeds: []const JsonAddr,
    psk_len: usize,
    init: []const u8 = "",
    nodes: []const NodeSnap = &.{},
    opens: []const OpenSnap = &.{},
    next_ino: u64 = 2,
    next_fh: u64 = 1,
};

fn jsonStr(w: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try w.append(gpa, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try w.appendSlice(gpa, "\\\""),
            '\\' => try w.appendSlice(gpa, "\\\\"),
            // A raw C0 control makes the decoded blob fail std.json, so a
            // control byte in a mountpoint would hang every update of that
            // mount with no ack. \uXXXX is an exact byte round-trip below
            // 0x80, where every control lives.
            0x00...0x1f => {
                var esc: [6]u8 = undefined;
                try w.appendSlice(gpa, std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{ch}) catch return error.NoSpaceLeft);
            },
            else => try w.append(gpa, ch),
        }
    }
    try w.append(gpa, '"');
}

fn jsonAddrs(w: *std.ArrayList(u8), gpa: std.mem.Allocator, addrs: []const Addr) !void {
    try w.append(gpa, '[');
    for (addrs, 0..) |a, i| {
        if (i != 0) try w.append(gpa, ',');
        try w.appendSlice(gpa, "{\"ip\":");
        try jsonStr(w, gpa, a.ip);
        var pbuf: [16]u8 = undefined;
        const p = try std.fmt.bufPrint(&pbuf, ",\"port\":{d}}}", .{a.port});
        try w.appendSlice(gpa, p);
    }
    try w.append(gpa, ']');
}

fn jsonI32s(w: *std.ArrayList(u8), gpa: std.mem.Allocator, fds: []const i32) !void {
    try w.append(gpa, '[');
    for (fds, 0..) |fd, i| {
        if (i != 0) try w.append(gpa, ',');
        var buf: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{fd});
        try w.appendSlice(gpa, s);
    }
    try w.append(gpa, ']');
}

/// JSON knobs plus a trailing raw PSK. The secret is never UTF-8 JSON and
/// never appears in exec argv.
pub fn encode(gpa: std.mem.Allocator, k: Knobs) ![]u8 {
    var w: std.ArrayList(u8) = .empty;
    errdefer w.deinit(gpa);
    try w.appendSlice(gpa, magic);
    try w.appendSlice(gpa, "{\"origin\":");
    try jsonStr(&w, gpa, k.origin);
    try w.appendSlice(gpa, ",\"cache\":");
    try jsonStr(&w, gpa, k.cache);
    try w.appendSlice(gpa, ",\"id\":");
    try jsonStr(&w, gpa, k.id);
    try w.appendSlice(gpa, ",\"mount\":");
    try jsonStr(&w, gpa, k.mount);
    var nbuf: [160]u8 = undefined;
    const nums = try std.fmt.bufPrint(&nbuf, ",\"piece\":{d},\"listen\":{d},\"brun\":{d},\"bcull\":{d},\"bstop\":{d},\"direct_io\":{},\"allow_other\":{},\"fuse_fd\":{d},\"listen_fds\":", .{
        k.piece, k.listen, k.water.brun, k.water.bcull, k.water.bstop, k.direct_io, k.allow_other, k.fuse_fd,
    });
    try w.appendSlice(gpa, nums);
    try jsonI32s(&w, gpa, k.listen_fds);
    try w.appendSlice(gpa, ",\"advertise\":");
    try jsonAddrs(&w, gpa, k.advertise);
    try w.appendSlice(gpa, ",\"seeds\":");
    try jsonAddrs(&w, gpa, k.seeds);
    if (k.init.len > init_max) return error.InitTooLarge;
    try w.appendSlice(gpa, ",\"init\":\"");
    const hex_digits = "0123456789abcdef";
    for (k.init) |b| {
        try w.append(gpa, hex_digits[b >> 4]);
        try w.append(gpa, hex_digits[b & 0xf]);
    }
    try w.appendSlice(gpa, "\",\"nodes\":[");
    for (k.nodes, 0..) |n, i| {
        if (i != 0) try w.append(gpa, ',');
        const pre = try std.fmt.bufPrint(&nbuf, "{{\"ino\":{d},\"path\":", .{n.ino});
        try w.appendSlice(gpa, pre);
        try jsonStr(&w, gpa, n.path);
        const post = try std.fmt.bufPrint(&nbuf, ",\"nlookup\":{d}}}", .{n.nlookup});
        try w.appendSlice(gpa, post);
    }
    try w.appendSlice(gpa, "],\"opens\":[");
    for (k.opens, 0..) |o, i| {
        if (i != 0) try w.append(gpa, ',');
        const pre = try std.fmt.bufPrint(&nbuf, "{{\"fh\":{d},\"path\":", .{o.fh});
        try w.appendSlice(gpa, pre);
        try jsonStr(&w, gpa, o.path);
        try w.appendSlice(gpa, "}");
    }
    const plen = try std.fmt.bufPrint(&nbuf, "],\"next_ino\":{d},\"next_fh\":{d},\"psk_len\":{d}}}\n", .{ k.next_ino, k.next_fh, k.psk.len });
    try w.appendSlice(gpa, plen);
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
    if (d.init.len % 2 != 0 or d.init.len / 2 > init_max) return error.BadInit;

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
        .init = try a.alloc(u8, d.init.len / 2),
        .nodes = try a.alloc(NodeSnap, d.nodes.len),
        .opens = try a.alloc(OpenSnap, d.opens.len),
        .next_ino = d.next_ino,
        .next_fh = d.next_fh,
        .arena = arena,
    };
    _ = std.fmt.hexToBytes(out.init, d.init) catch return error.BadInit;
    for (d.nodes, 0..) |n, i| {
        out.nodes[i] = .{ .ino = n.ino, .path = try a.dupe(u8, n.path), .nlookup = n.nlookup };
    }
    for (d.opens, 0..) |o, i| {
        out.opens[i] = .{ .fh = o.fh, .path = try a.dupe(u8, o.path) };
    }
    for (d.advertise, 0..) |ad, i| {
        out.advertise[i] = .{ .ip = try a.dupe(u8, ad.ip), .port = ad.port, .mbps = 0 };
    }
    for (d.seeds, 0..) |sd, i| {
        out.seeds[i] = .{ .ip = try a.dupe(u8, sd.ip), .port = sd.port, .mbps = 0 };
    }
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
    // PSK-holding buffer in the daemon.
    defer std.crypto.secureZero(u8, blob);
    defer gpa.free(blob);
    return decode(gpa, blob);
}

pub const Req = struct { bin: []const u8, token: []const u8 };
pub const Ack = struct { token: []const u8 };

pub fn encodeReq(gpa: std.mem.Allocator, bin: []const u8, token: []const u8) ![]u8 {
    var w: std.ArrayList(u8) = .empty;
    errdefer w.deinit(gpa);
    try w.appendSlice(gpa, "{\"bin\":");
    try jsonStr(&w, gpa, bin);
    try w.appendSlice(gpa, ",\"token\":");
    try jsonStr(&w, gpa, token);
    try w.appendSlice(gpa, "}\n");
    return w.toOwnedSlice(gpa);
}

pub fn decodeReq(gpa: std.mem.Allocator, blob: []const u8) !std.json.Parsed(Req) {
    return std.json.parseFromSlice(Req, gpa, std.mem.trim(u8, blob, " \t\r\n"), .{});
}

pub fn encodeAck(gpa: std.mem.Allocator, token: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"token\":\"{s}\"}}\n", .{token});
}

pub fn decodeAck(gpa: std.mem.Allocator, blob: []const u8) !std.json.Parsed(Ack) {
    return std.json.parseFromSlice(Ack, gpa, std.mem.trim(u8, blob, " \t\r\n"), .{ .ignore_unknown_fields = true });
}

/// Hex handshake nonce matching one `update.req` to its `update.ack`. Fails
/// rather than falling back to anything derivable: a pid-shaped token would
/// let a same-uid racer ack an update it did not request.
pub fn randomToken(out: *[token_bytes * 2]u8) !void {
    var raw: [token_bytes]u8 = undefined;
    if (sys.randomBytes(&raw) != 0) return error.NoRandom;
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
        .advertise = &.{.{ .ip = "10.0.0.1", .port = 18080 }},
        .seeds = &.{.{ .ip = "10.0.0.9", .port = 19091 }},
        .psk = psk,
        .init = "\x68\x00\x00\x00\x1a\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00",
        .nodes = &.{.{ .ino = 5, .path = "/gguf/a.gguf", .nlookup = 3 }},
        .opens = &.{.{ .fh = 9, .path = "/gguf/a.gguf" }},
        .next_ino = 6,
        .next_fh = 10,
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
    try std.testing.expectEqual(@as(usize, 1), got.seeds.len);
    try std.testing.expectEqualStrings("10.0.0.9", got.seeds[0].ip);
    try std.testing.expectEqual(@as(u16, 19091), got.seeds[0].port);
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
    try randomToken(&tok);
    // Two tokens in a row must differ, or a stale ack would match the next
    // request; a constant fallback used to make that possible.
    var again: [token_bytes * 2]u8 = undefined;
    try randomToken(&again);
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
}
