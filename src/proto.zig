//! Peer wire helpers: size/range/header parsing, URL codec, bearer auth, and
//! the cluster lease JSON document. Shared by the HTTP server and client.
const std = @import("std");

pub fn parseSize(s: []const u8) !u64 {
    if (s.len == 0) return error.BadSize;
    var i: usize = 0;
    var n: u64 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        const digit = s[i] - '0';
        n = std.math.mul(u64, n, 10) catch return error.BadSize;
        n = std.math.add(u64, n, digit) catch return error.BadSize;
    }
    if (i == 0) return error.BadSize;
    var rest = std.mem.trim(u8, s[i..], " \t");
    if (rest.len > 0 and (rest[rest.len - 1] == 'B' or rest[rest.len - 1] == 'b')) rest = rest[0 .. rest.len - 1];
    // Exactly one unit character may remain: anything else is trailing
    // garbage ("16Mi", "1KB2") that must fail, not silently parse as the
    // prefix's value.
    if (rest.len == 0) return n;
    if (rest.len != 1) return error.BadSize;
    const mul: u64 = switch (rest[0]) {
        'K', 'k' => 1024,
        'M', 'm' => 1024 * 1024,
        'G', 'g' => 1024 * 1024 * 1024,
        else => return error.BadSize,
    };
    return std.math.mul(u64, n, mul) catch return error.BadSize;
}

const unreserved_lut: [256]bool = blk: {
    var tbl = [_]bool{false} ** 256;
    for ('a'..'z' + 1) |ch| tbl[ch] = true;
    for ('A'..'Z' + 1) |ch| tbl[ch] = true;
    for ('0'..'9' + 1) |ch| tbl[ch] = true;
    tbl['-'] = true;
    tbl['_'] = true;
    tbl['.'] = true;
    tbl['~'] = true;
    break :blk tbl;
};

pub fn urlEncode(out: []u8, s: []const u8) ![]u8 {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (s) |ch| {
        if (unreserved_lut[ch]) {
            if (n >= out.len) return error.NoSpaceLeft;
            out[n] = ch;
            n += 1;
        } else {
            if (n + 3 > out.len) return error.NoSpaceLeft;
            out[n] = '%';
            out[n + 1] = hex[ch >> 4];
            out[n + 2] = hex[ch & 0x0f];
            n += 3;
        }
    }
    return out[0..n];
}

pub fn urlDecode(out: []u8, s: []const u8) ![]u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (n >= out.len) return error.NoSpaceLeft;
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = hexVal(s[i + 1]) orelse return error.BadUrl;
            const lo = hexVal(s[i + 2]) orelse return error.BadUrl;
            out[n] = (hi << 4) | lo;
            n += 1;
            i += 3;
        } else if (s[i] == '+') {
            out[n] = ' ';
            n += 1;
            i += 1;
        } else {
            out[n] = s[i];
            n += 1;
            i += 1;
        }
    }
    return out[0..n];
}

fn hexVal(ch: u8) ?u8 {
    return std.fmt.charToDigit(ch, 16) catch null;
}

pub fn queryGet(target: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.findScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse continue;
        if (eq != key.len) continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

pub fn pathOnly(target: []const u8) []const u8 {
    const q = std.mem.findScalar(u8, target, '?') orelse return target;
    return target[0..q];
}

pub const Range = struct { start: u64, end: u64 };

fn parseU64Fast(s: []const u8) ?u64 {
    if (s.len == 0 or s.len > 20) return null;
    var n: u64 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return null;
        const digit: u64 = ch - '0';
        n = std.math.mul(u64, n, 10) catch return null;
        n = std.math.add(u64, n, digit) catch return null;
    }
    return n;
}

/// Parses an HTTP Range header value ("bytes=start-end"). End is inclusive.
/// An open-ended form ("bytes=start-") names everything through EOF; the
/// server clamps the end like any over-long explicit end.
pub fn parseRange(h: []const u8) ?Range {
    const p = "bytes=";
    const s = std.mem.trim(u8, h, " \t");
    if (!std.mem.startsWith(u8, s, p)) return null;
    const body = s[p.len..];
    const dash = std.mem.findScalar(u8, body, '-') orelse return null;
    const a = parseU64Fast(body[0..dash]) orelse return null;
    const b = if (body.len == dash + 1)
        std.math.maxInt(u64)
    else
        parseU64Fast(body[dash + 1 ..]) orelse return null;
    if (b < a) return null;
    return .{ .start = a, .end = b };
}

pub fn headerGet(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next(); // status / request line
    while (it.next()) |line| {
        if (line.len == 0) break;
        const col = std.mem.findScalar(u8, line, ':') orelse continue;
        if (col != name.len) continue;
        if (std.ascii.eqlIgnoreCase(line[0..col], name)) {
            return std.mem.trim(u8, line[col + 1 ..], " \t");
        }
    }
    return null;
}

pub fn bearerOk(got: []const u8, want: []const u8) bool {
    const prefix = "Bearer ";
    if (!std.ascii.startsWithIgnoreCase(got, prefix)) return false;
    const token = std.mem.trim(u8, got[prefix.len..], " \t");
    var ha: [32]u8 = undefined;
    var hb: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &ha, .{});
    std.crypto.hash.sha2.Sha256.hash(want, &hb, .{});
    return std.crypto.timing_safe.eql([32]u8, ha, hb);
}

/// Default TCP port of the peer HTTP protocol; every --listen/--advertise/
/// --seed address without an explicit ":PORT" resolves to it.
pub const default_port: u16 = 18080;

pub const LeaseAddr = struct {
    ip: []const u8,
    port: u16,
    mbps: u32 = 0,
};

pub const Lease = struct {
    id: []const u8,
    until: i64,
    addrs: []LeaseAddr,
};

pub fn parseLease(gpa: std.mem.Allocator, json: []const u8) !std.json.Parsed(Lease) {
    return std.json.parseFromSlice(Lease, gpa, json, .{ .ignore_unknown_fields = true });
}

pub fn formatLease(buf: []u8, id: []const u8, until: i64, addrs: []const LeaseAddr) ![]u8 {
    var w = std.Io.Writer.fixed(buf);
    try w.print("{{\"id\":\"{s}\",\"until\":{d},\"addrs\":[", .{ id, until });
    for (addrs, 0..) |a, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"ip\":\"{s}\",\"port\":{d},\"mbps\":{d}}}", .{ a.ip, a.port, a.mbps });
    }
    try w.writeAll("]}");
    return w.buffered();
}

test "parseSize overflow and invalid" {
    try std.testing.expectError(error.BadSize, parseSize("9999999999999999999999999999999"));
    try std.testing.expectError(error.BadSize, parseSize("18446744073709551615G"));
    try std.testing.expectError(error.BadSize, parseSize("abc"));
    try std.testing.expectError(error.BadSize, parseSize(""));
    try std.testing.expectError(error.BadSize, parseSize("12x"));
    // trailing garbage after a valid prefix must not parse as the prefix
    try std.testing.expectError(error.BadSize, parseSize("16Mfoo"));
    try std.testing.expectError(error.BadSize, parseSize("1KB2"));
}

test "parseSize accepts plain and suffixed values" {
    try std.testing.expectEqual(@as(u64, 0), try parseSize("0"));
    try std.testing.expectEqual(@as(u64, 512), try parseSize("512"));
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024), try parseSize("16M"));
    try std.testing.expectEqual(@as(u64, 4 * 1024 * 1024 * 1024), try parseSize("4G"));
    try std.testing.expectEqual(@as(u64, 2048), try parseSize("2k"));
    try std.testing.expectEqual(@as(u64, 4096), try parseSize("4KB"));
    try std.testing.expectEqual(@as(u64, 3145728), try parseSize("3 MB"));
    // u64 max is exactly representable
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), try parseSize("18446744073709551615"));
}

test "url encode decode" {
    var ebuf: [64]u8 = undefined;
    var dbuf: [64]u8 = undefined;
    const e = try urlEncode(&ebuf, "gguf/foo.gguf");
    try std.testing.expectEqualStrings("gguf%2Ffoo.gguf", e);
    const d = try urlDecode(&dbuf, e);
    try std.testing.expectEqualStrings("gguf/foo.gguf", d);
    // form-style space, uppercase hex, and every unreserved passthrough
    try std.testing.expectEqualStrings("a b", try urlDecode(&dbuf, "a+b"));
    try std.testing.expectEqualStrings("/", try urlDecode(&dbuf, "%2f"));
}

test "url codec rejects bad hex and undersized buffers" {
    var buf: [32]u8 = undefined;
    // invalid escape digit after a syntactically complete %XX position
    try std.testing.expectError(error.BadUrl, urlDecode(&buf, "%zz"));
    try std.testing.expectError(error.BadUrl, urlDecode(&buf, "ok%2G"));
    // a truncated trailing escape passes through verbatim (the caller's
    // relOk gate still applies to the decoded result)
    try std.testing.expectEqualStrings("100%", try urlDecode(&buf, "100%"));
    try std.testing.expectEqualStrings("%2", try urlDecode(&buf, "%2"));
    // buffer too small for the decoded bytes
    try std.testing.expectError(error.NoSpaceLeft, urlDecode(buf[0..2], "abc"));
    // encode needs 3 bytes per escaped character
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, urlEncode(tiny[0..3], "ab/d"));
}

test "range and query" {
    const r = parseRange("bytes=0-16777215").?;
    try std.testing.expectEqual(@as(u64, 0), r.start);
    try std.testing.expectEqual(@as(u64, 16777215), r.end);
    try std.testing.expect(parseRange("bytes=10-1") == null);
    try std.testing.expect(parseRange("bytes=-5") == null);
    // the open-ended form names everything through EOF; the suffix form
    // (last N bytes) stays unsupported and rejected
    const open = parseRange("bytes=10-").?;
    try std.testing.expectEqual(@as(u64, 10), open.start);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), open.end);
    try std.testing.expect(parseRange("bytes=-") == null);
    try std.testing.expect(parseRange("chunks=0-5") == null);
    // 20-digit values above u64 max are rejected, not overflowed
    try std.testing.expect(parseRange("bytes=0-99999999999999999999") == null);
    try std.testing.expect(parseRange("bytes=99999999999999999999-0") == null);
    try std.testing.expect(parseRange("bytes=18446744073709551615-18446744073709551615") != null);
    const q = queryGet("/have?path=foo%2Fbar&x=1", "path").?;
    try std.testing.expectEqualStrings("foo%2Fbar", q);
    // key must match whole token, not a suffix
    try std.testing.expect(queryGet("/have?xpath=1", "path") == null);
    try std.testing.expectEqualStrings("/have", pathOnly("/have?path=x"));
    try std.testing.expectEqualStrings("/data", pathOnly("/data"));
}

test "headerGet is case-insensitive and trims" {
    const head = "GET /ping HTTP/1.1\r\nHost: node1:18080\r\nAuthorization: Bearer  tok123 \r\nRange: bytes=0-9\r\n\r\n";
    try std.testing.expectEqualStrings("Bearer  tok123", headerGet(head, "Authorization").?);
    try std.testing.expectEqualStrings("Bearer  tok123", headerGet(head, "authorization").?);
    try std.testing.expectEqualStrings("node1:18080", headerGet(head, "Host").?);
    try std.testing.expectEqualStrings("bytes=0-9", headerGet(head, "range").?);
    try std.testing.expect(headerGet(head, "Content-Length") == null);
}

test "bearer compare is length-independent" {
    try std.testing.expect(bearerOk("Bearer secret", "secret"));
    try std.testing.expect(!bearerOk("Bearer secre", "secret"));
    try std.testing.expect(!bearerOk("Bearer secretx", "secret"));
    try std.testing.expect(!bearerOk("secret", "secret"));
}

test "lease json roundtrip" {
    var buf: [256]u8 = undefined;
    const addrs = [_]LeaseAddr{
        .{ .ip = "192.168.100.1", .port = 18080, .mbps = 200000 },
        .{ .ip = "192.168.0.11", .port = 18080, .mbps = 10000 },
    };
    const s = try formatLease(&buf, "spark1", 1710000060, &addrs);
    const parsed = try parseLease(std.testing.allocator, s);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("spark1", parsed.value.id);
    try std.testing.expectEqual(@as(i64, 1710000060), parsed.value.until);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.addrs.len);
    try std.testing.expectEqual(@as(u32, 200000), parsed.value.addrs[0].mbps);

    // Lease documents come off shared NFS storage: unknown fields from a
    // newer peer must be tolerated...
    {
        const extended = "{\"id\":\"n1\",\"until\":5,\"addrs\":[],\"proto_version\":9}";
        const p = try parseLease(std.testing.allocator, extended);
        defer p.deinit();
        try std.testing.expectEqualStrings("n1", p.value.id);
    }
    // ...while malformed JSON is rejected, not half-parsed.
    try std.testing.expectError(error.UnexpectedEndOfInput, parseLease(std.testing.allocator, "{\"id\":"));
    try std.testing.expectError(error.SyntaxError, parseLease(std.testing.allocator, "not json at all"));
}
