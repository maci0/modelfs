//! Peer wire helpers: range/header parsing, URL codec, bearer auth, and
//! the cluster lease JSON document. Shared by the HTTP server and client.
const std = @import("std");

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

/// Strict RFC 3986 percent-decoding for the peer protocol's path parameter.
/// No form-style "+"-as-space translation: this carries a file name, where a
/// literal '+' and an encoded space (%20) are different bytes -- collapsing
/// them would let two spellings reach one file while the real "a+b.gguf"
/// misses.
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

/// Upper bound on a bearer token in bytes: main.zig's loadPsk reads at most
/// this much and trims it, so it is also the token budget every request
/// builder and request-head buffer must reserve beyond the encoded path.
/// One constant here keeps the loader's cap and the wire budgets from
/// drifting apart (a longer legal secret would otherwise overflow
/// sendRequest's frame and silently disable the peer tier for that node).
pub const max_psk_bytes: usize = 4096;

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

test "url encode decode" {
    var ebuf: [64]u8 = undefined;
    var dbuf: [64]u8 = undefined;
    const e = try urlEncode(&ebuf, "gguf/foo.gguf");
    try std.testing.expectEqualStrings("gguf%2Ffoo.gguf", e);
    const d = try urlDecode(&dbuf, e);
    try std.testing.expectEqualStrings("gguf/foo.gguf", d);
    // Strict percent-decoding only: '+' is a literal plus in a path (form
    // encoding's space meaning would conflate it with %20), uppercase hex,
    // and every unreserved passthrough
    try std.testing.expectEqualStrings("a+b", try urlDecode(&dbuf, "a+b"));
    try std.testing.expectEqualStrings("a b", try urlDecode(&dbuf, "a%20b"));
    try std.testing.expectEqualStrings("/", try urlDecode(&dbuf, "%2f"));
}

test "url codec round-trips multi-byte UTF-8 names byte for byte" {
    // A non-ASCII model file name with a space and a slash: every byte above
    // the unreserved set escapes as %XX and decodes back to the identical
    // byte sequence -- no split multi-byte sequence, no case or plus folding.
    const name = "gguf/llama 70B/权重.gguf";
    var ebuf: [128]u8 = undefined;
    var dbuf: [128]u8 = undefined;
    const enc = try urlEncode(&ebuf, name);
    try std.testing.expect(std.mem.indexOf(u8, enc, " ") == null);
    try std.testing.expect(std.mem.indexOf(u8, enc, "/") == null);
    try std.testing.expectEqualStrings(name, try urlDecode(&dbuf, enc));
}

test "url codec round-trips bytes that are not valid UTF-8" {
    // Filesystem paths are bytes and need not be UTF-8 at all: the wire
    // codec must escape-carriage arbitrary high bytes exactly like the
    // multi-byte UTF-8 case, with no validation or lossy replacement --
    // a peer serving such a legal name must stay reachable byte-exact.
    const name = "raw \xff\xfe bytes.bin";
    var ebuf: [64]u8 = undefined;
    var dbuf: [64]u8 = undefined;
    const enc = try urlEncode(&ebuf, name);
    try std.testing.expectEqualStrings(name, try urlDecode(&dbuf, enc));
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
    // Well-formed JSON missing the required addrs list is malformed too:
    // a peer publishing such a document must fail closed here, never read
    // downstream as an empty-address (unreachable) or empty-cluster node.
    try std.testing.expectError(error.MissingField, parseLease(std.testing.allocator, "{\"id\":\"n1\",\"until\":5}"));
}

/// One lease document in the corpus framing the fuzz harness reads: u32
/// length prefix, then the raw JSON bytes.
fn leaseEntry(comptime doc: []const u8) [4 + doc.len]u8 {
    var out: [4 + doc.len]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], @intCast(doc.len), .little);
    for (doc, 0..) |b, i| out[4 + i] = b;
    return out;
}

const seed_lease_ok = leaseEntry("{\"id\":\"spark1\",\"until\":1710000060,\"addrs\":[{\"ip\":\"192.168.100.1\",\"port\":18080,\"mbps\":200000},{\"ip\":\"192.168.0.11\",\"port\":18080,\"mbps\":10000}]}");
const seed_lease_unknown_field = leaseEntry("{\"id\":\"n1\",\"until\":5,\"addrs\":[],\"proto_version\":9}");
const seed_lease_truncated = leaseEntry("{\"id\":");
const seed_lease_not_json = leaseEntry("not json at all");
const seed_lease_quote_id = leaseEntry("{\"id\":\"a\\\"b\\\\c\",\"until\":1,\"addrs\":[]}");
const seed_lease_escape_id = leaseEntry("{\"id\":\"a\\nb\",\"until\":1,\"addrs\":[]}");
const seed_lease_until_overflow = leaseEntry("{\"id\":\"x\",\"until\":18446744073709551615,\"addrs\":[]}");
const seed_lease_dup_keys = leaseEntry("{\"id\":\"a\",\"id\":\"b\",\"until\":7,\"addrs\":[]}");
const seed_lease_deep_unknown = leaseEntry("{\"id\":\"d\",\"until\":1,\"addrs\":[],\"z\":[[[[[[[[]]]]]]]]}");
const seed_lease_extreme_addrs = leaseEntry("{\"id\":\"m\",\"until\":-5,\"addrs\":[{\"ip\":\"\",\"port\":0,\"mbps\":4294967295}]}");

const fuzz_lease_corpus = [_][]const u8{
    &seed_lease_ok,
    &seed_lease_unknown_field,
    &seed_lease_truncated,
    &seed_lease_not_json,
    &seed_lease_quote_id,
    &seed_lease_escape_id,
    &seed_lease_until_overflow,
    &seed_lease_dup_keys,
    &seed_lease_deep_unknown,
    &seed_lease_extreme_addrs,
};

/// True when s survives formatLease's verbatim embedding: the writer does
/// no JSON escaping, so a quote, backslash, or C0 byte would publish a
/// document every peer's parser refuses. Producers gate ids through
/// discover.validId; this mirrors just the JSON-hostile part of that gate.
fn leaseJsonClean(s: []const u8) bool {
    for (s) |ch| {
        if (ch < 0x20 or ch == '"' or ch == '\\') return false;
    }
    return true;
}

/// Lease documents cross a trust boundary twice: written by one node onto
/// shared NFS storage, parsed by every peer (refresh, `modelfs peers`).
/// The harness asserts fail-closed parsing, determinism across re-reads,
/// and the writer contract: any parsed document whose strings carry no
/// JSON-hostile bytes must survive a formatLease/parseLease cycle with all
/// values intact. Documents with hostile ids legitimately skip that leg.
fn fuzzLeaseDocOne(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var doc_buf: [512]u8 = undefined;
    const json = doc_buf[0..smith.slice(&doc_buf)];
    const parsed = parseLease(gpa, json) catch return;
    defer parsed.deinit();
    const lease = parsed.value;

    {
        const again = try parseLease(gpa, json);
        defer again.deinit();
        try std.testing.expectEqualStrings(lease.id, again.value.id);
        try std.testing.expectEqual(lease.until, again.value.until);
        try std.testing.expectEqual(lease.addrs.len, again.value.addrs.len);
        for (lease.addrs, again.value.addrs) |a, b| {
            try std.testing.expectEqualStrings(a.ip, b.ip);
            try std.testing.expectEqual(a.port, b.port);
            try std.testing.expectEqual(a.mbps, b.mbps);
        }
    }

    if (!leaseJsonClean(lease.id)) return;
    for (lease.addrs) |a| {
        if (!leaseJsonClean(a.ip)) return;
    }
    var size: usize = 64 + lease.id.len;
    for (lease.addrs) |a| size += a.ip.len + 48;
    const out = try gpa.alloc(u8, size);
    defer gpa.free(out);
    const formatted = formatLease(out, lease.id, lease.until, lease.addrs) catch return;
    const reparsed = try parseLease(gpa, formatted);
    defer reparsed.deinit();
    try std.testing.expectEqualStrings(lease.id, reparsed.value.id);
    try std.testing.expectEqual(lease.until, reparsed.value.until);
    try std.testing.expectEqual(lease.addrs.len, reparsed.value.addrs.len);
    for (lease.addrs, reparsed.value.addrs) |a, b| {
        try std.testing.expectEqualStrings(a.ip, b.ip);
        try std.testing.expectEqual(a.port, b.port);
        try std.testing.expectEqual(a.mbps, b.mbps);
    }
}

test "fuzz lease document parsing fails closed and round-trips clean docs" {
    try std.testing.fuzz({}, fuzzLeaseDocOne, .{ .corpus = &fuzz_lease_corpus });
}

// The URL codec is one wire contract split across the peer trust boundary:
// clients escape model paths into the query string (sendRequest) and servers
// decode them back (the relOk gate). Only the decode half sits inside the
// request-head harness, so an encoder/decoder drift there -- say a "+"
// folding or case-insensitive hex change on one side alone -- would silently
// split one file into two spellings instead of failing loudly. This harness
// pins the pair end to end.

/// RFC 3986 unreserved set, derived independently of urlEncode's lookup
/// table so a corrupted table cannot self-confirm the length oracle below.
fn codecUnreserved(ch: u8) bool {
    return switch (ch) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}

fn expectedEncodedLen(s: []const u8) usize {
    var n: usize = 0;
    for (s) |ch| n += if (codecUnreserved(ch)) 1 else 3;
    return n;
}

/// Two framed slices per corpus entry: the path the client encodes, then an
/// arbitrary wire form fed straight into the decoder.
fn codecEntry(comptime name: []const u8, comptime wire: []const u8) [8 + name.len + wire.len]u8 {
    var out: [8 + name.len + wire.len]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], @intCast(name.len), .little);
    @memcpy(out[4..][0..name.len], name);
    std.mem.writeInt(u32, out[4 + name.len ..][0..4], @intCast(wire.len), .little);
    @memcpy(out[8 + name.len ..], wire);
    return out;
}

const seed_codec_plain = codecEntry("gguf/model.gguf", "%zz");
const seed_codec_spaced = codecEntry("llama 70B/v2.gguf", "%2");
const seed_codec_utf8 = codecEntry("权重/mödel.gguf", "100%");
const seed_codec_raw_bytes = codecEntry("raw \xff\xfe.bin", "a+b%20c");
const seed_codec_control = codecEntry("\x00\x1b\x7f", "%41%4");
const seed_codec_empty = codecEntry("", "");
const seed_codec_escapes_only = codecEntry("%%%", "%25%25%25");

const fuzz_codec_corpus = [_][]const u8{
    &seed_codec_plain,
    &seed_codec_spaced,
    &seed_codec_utf8,
    &seed_codec_raw_bytes,
    &seed_codec_control,
    &seed_codec_empty,
    &seed_codec_escapes_only,
};

/// Asserts the codec contract from both ends of the trust boundary: the
/// encoded form's length matches an independent RFC 3986 oracle exactly
/// (tight buffer succeeds, one byte short refuses), carries only unreserved
/// bytes and complete uppercase-hex escapes, decodes back to the original
/// bytes, and the decoder alone never asks for more room than its input --
/// so server-side callers sizing buffers off the query length cannot be
/// made to fail by any crafted request line.
fn fuzzUrlCodecOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var name_buf: [256]u8 = undefined;
    const name = name_buf[0..smith.slice(&name_buf)];

    const want_len = expectedEncodedLen(name);
    var enc_buf: [3 * 256]u8 = undefined;
    const enc = try urlEncode(&enc_buf, name);
    try std.testing.expectEqual(want_len, enc.len);

    var tight: [enc_buf.len]u8 = undefined;
    try std.testing.expectEqualStrings(enc, try urlEncode(tight[0..want_len], name));
    if (want_len > 0)
        try std.testing.expectError(error.NoSpaceLeft, urlEncode(tight[0 .. want_len - 1], name));

    var i: usize = 0;
    while (i < enc.len) {
        if (codecUnreserved(enc[i])) {
            i += 1;
            continue;
        }
        try std.testing.expect(enc[i] == '%');
        try std.testing.expect(i + 3 <= enc.len);
        try std.testing.expect(hexVal(enc[i + 1]) != null);
        try std.testing.expect(hexVal(enc[i + 2]) != null);
        i += 3;
    }

    var dec_buf: [enc_buf.len]u8 = undefined;
    const dec = try urlDecode(dec_buf[0..enc.len], enc);
    try std.testing.expectEqualStrings(name, dec);

    var wire_buf: [256]u8 = undefined;
    const wire = wire_buf[0..smith.slice(&wire_buf)];
    var out_buf: [256]u8 = undefined;
    const got = urlDecode(out_buf[0..wire.len], wire) catch |err| switch (err) {
        error.BadUrl => return,
        else => return err,
    };
    var reenc_buf: [enc_buf.len]u8 = undefined;
    const re_enc = try urlEncode(&reenc_buf, got);
    var again_buf: [256]u8 = undefined;
    const again = try urlDecode(again_buf[0..re_enc.len], re_enc);
    try std.testing.expectEqualStrings(got, again);
}

test "fuzz url codec round-trips across the peer trust boundary" {
    try std.testing.fuzz({}, fuzzUrlCodecOne, .{ .corpus = &fuzz_codec_corpus });
}
