//! Peer wire helpers: range/header parsing, URL codec, bearer auth, the
//! /have bitmap document, and the cluster lease JSON document. Shared by
//! the HTTP server and client.
const std = @import("std");
const fuzzcorpus = @import("fuzzcorpus.zig");

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

/// RFC 3986 percent-encoding of a path query value. The unreserved set
/// matches urlDecode: '+' stays '+', spaces become %20, so two spellings
/// cannot collapse onto one file.
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

/// Unsigned decimal (`1*DIGIT`) as used on the wire for Range,
/// Content-Range, Content-Length, and X-Piece-Size. Rejects the sign and
/// underscore forms `std.fmt.parseInt` would accept, so a `+16` or `16_0`
/// length cannot size a body (or an advertised piece grid) differently
/// from a Range the same peer sent.
pub fn parseU64Fast(s: []const u8) ?u64 {
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

pub const ContentRange = struct { start: u64, end: u64, complete: u64 };

/// Parses an HTTP Content-Range header value ("bytes start-end/complete").
/// End is inclusive. An unknown complete length ("bytes start-end/*") is
/// recorded as maxInt(u64). The fetch client uses this to bind a 206 body
/// to the range it asked for: Content-Length alone cannot tell a piece at
/// offset 0 from the piece that was requested.
pub fn parseContentRange(h: []const u8) ?ContentRange {
    const p = "bytes ";
    const s = std.mem.trim(u8, h, " \t");
    if (!std.mem.startsWith(u8, s, p)) return null;
    const body = s[p.len..];
    const dash = std.mem.findScalar(u8, body, '-') orelse return null;
    const rest = body[dash + 1 ..];
    const slash = std.mem.findScalar(u8, rest, '/') orelse return null;
    const a = parseU64Fast(body[0..dash]) orelse return null;
    const b = parseU64Fast(rest[0..slash]) orelse return null;
    if (b < a) return null;
    const complete_s = rest[slash + 1 ..];
    const complete = if (complete_s.len == 1 and complete_s[0] == '*')
        std.math.maxInt(u64)
    else
        parseU64Fast(complete_s) orelse return null;
    return .{ .start = a, .end = b, .complete = complete };
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

/// Timing-safe bearer check. Tokens are hashed with SHA-256 first so a
/// length mismatch cannot leak through a byte-by-byte compare: the
/// comparison is always 32 bytes.
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

/// True when s holds a C0 byte, DEL, a UTF-8 C1 pair (U+0080..U+009F), or a
/// Unicode line/paragraph separator (U+2028/U+2029). store.relOk and
/// discover.printable share this set so a planted name cannot inject into
/// logs or terminals through only one of the two gates.
pub fn containsControl(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (ch < 0x20 or ch == 0x7f) return true;
        if (ch == 0xc2 and i + 1 < s.len and s[i + 1] >= 0x80 and s[i + 1] <= 0x9f) return true;
        if (ch == 0xe2 and i + 2 < s.len and s[i + 1] == 0x80 and (s[i + 2] == 0xa8 or s[i + 2] == 0xa9)) return true;
    }
    return false;
}

/// A successful /have answer: the peer's cached-piece bitmap plus the piece
/// size its bits are indexed against. piece_size 0 means the peer did not
/// advertise one (an older build); consumers assume alignment for those.
pub const HaveBits = struct {
    bits: []u8,
    piece_size: u32,

    /// True when bit `idx` is set on a grid compatible with `local_piece_size`.
    /// A mismatched advertised grid is treated as no-answer at this index
    /// (the fetch falls through) rather than reading bits that cover
    /// different byte ranges than ours.
    pub fn hasPiece(self: HaveBits, idx: u32, local_piece_size: u32) bool {
        if (self.piece_size != 0 and self.piece_size != local_piece_size) return false;
        return idx / 8 < self.bits.len and (self.bits[idx / 8] & (@as(u8, 1) << @intCast(idx % 8))) != 0;
    }
};

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

test "containsControl covers C0 C1 and Unicode line separators only" {
    try std.testing.expect(!containsControl("gguf/a.gguf"));
    try std.testing.expect(!containsControl("model\u{a0}v2.bin"));
    try std.testing.expect(!containsControl("a\xe2\x80.bin"));
    try std.testing.expect(containsControl("a\nb"));
    try std.testing.expect(containsControl("a\x7fb"));
    try std.testing.expect(containsControl("a\xc2\x9bb"));
    try std.testing.expect(containsControl("a\u{2028}b"));
    try std.testing.expect(containsControl("a\u{2029}b"));
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
    // The same digit-only rule Range uses: a leading sign or interior
    // underscore is not a length, so Content-Length/X-Piece-Size cannot
    // accept what Range would refuse.
    try std.testing.expectEqual(@as(u64, 0), parseU64Fast("0").?);
    try std.testing.expectEqual(@as(u64, 16), parseU64Fast("016").?);
    try std.testing.expect(parseU64Fast("") == null);
    try std.testing.expect(parseU64Fast("+16") == null);
    try std.testing.expect(parseU64Fast("16_0") == null);
    try std.testing.expect(parseU64Fast("16Mi") == null);
    try std.testing.expect(parseU64Fast("-1") == null);
    try std.testing.expect(parseU64Fast(" 16") == null);

    const cr = parseContentRange("bytes 16-31/48").?;
    try std.testing.expectEqual(@as(u64, 16), cr.start);
    try std.testing.expectEqual(@as(u64, 31), cr.end);
    try std.testing.expectEqual(@as(u64, 48), cr.complete);
    const cr_star = parseContentRange("bytes 0-7/*").?;
    try std.testing.expectEqual(@as(u64, 0), cr_star.start);
    try std.testing.expectEqual(@as(u64, 7), cr_star.end);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), cr_star.complete);
    try std.testing.expect(parseContentRange("bytes 10-1/20") == null);
    try std.testing.expect(parseContentRange("bytes=0-7/8") == null);
    try std.testing.expect(parseContentRange("bytes 0-7") == null);
    try std.testing.expect(parseContentRange("bytes 0-/8") == null);

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

test "HaveBits.hasPiece respects advertised grid" {
    var bits = [_]u8{0b0000_0001};
    const aligned = HaveBits{ .bits = &bits, .piece_size = 4096 };
    try std.testing.expect(aligned.hasPiece(0, 4096));
    try std.testing.expect(!aligned.hasPiece(1, 4096));
    try std.testing.expect(!aligned.hasPiece(0, 8192));
    // Absent X-Piece-Size (piece_size 0) is assumed aligned, so a fetcher
    // talking to an older peer still reads the bits it advertised.
    const unknown = HaveBits{ .bits = &bits, .piece_size = 0 };
    try std.testing.expect(unknown.hasPiece(0, 8192));
}

test "bearer compare is length-independent" {
    try std.testing.expect(bearerOk("Bearer secret", "secret"));
    try std.testing.expect(!bearerOk("Bearer secre", "secret"));
    try std.testing.expect(!bearerOk("Bearer secretx", "secret"));
    try std.testing.expect(!bearerOk("secret", "secret"));
    // Scheme match is case-insensitive (RFC 9110 auth-scheme); a peer that
    // sent "bearer" must still authenticate. The token itself is not folded.
    try std.testing.expect(bearerOk("bearer secret", "secret"));
    try std.testing.expect(bearerOk("BEARER secret", "secret"));
    try std.testing.expect(!bearerOk("Bearer Secret", "secret"));
    try std.testing.expect(!bearerOk("Basic secret", "secret"));
    // headerGet trims the header value, but interior padding after the
    // scheme still reaches here; surrounding space/tab on the token is trim.
    try std.testing.expect(bearerOk("Bearer  secret", "secret"));
    try std.testing.expect(bearerOk("Bearer secret\t", "secret"));
    try std.testing.expect(!bearerOk("Bearer ", "secret"));
    try std.testing.expect(!bearerOk("", "secret"));
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

    // The writer refuses an undersized buffer instead of truncating: publish
    // ships this document verbatim to every peer, so a torn tail would look
    // like a corrupt lease and drop the node from the cluster silently. The
    // exact fit succeeds byte-for-byte; one byte short is refused whole.
    var tight: [128]u8 = undefined;
    const single = [_]LeaseAddr{.{ .ip = "192.168.0.11", .port = default_port, .mbps = 7 }};
    const full = try formatLease(&tight, "spark1", 1710000060, &single);
    const need = full.len;
    try std.testing.expectEqualStrings(full, try formatLease(tight[0..need], "spark1", 1710000060, &single));
    try std.testing.expectError(error.WriteFailed, formatLease(tight[0 .. need - 1], "spark1", 1710000060, &single));
}

const seed_lease_ok = fuzzcorpus.entry("{\"id\":\"spark1\",\"until\":1710000060,\"addrs\":[{\"ip\":\"192.168.100.1\",\"port\":18080,\"mbps\":200000},{\"ip\":\"192.168.0.11\",\"port\":18080,\"mbps\":10000}]}");
const seed_lease_unknown_field = fuzzcorpus.entry("{\"id\":\"n1\",\"until\":5,\"addrs\":[],\"proto_version\":9}");
const seed_lease_truncated = fuzzcorpus.entry("{\"id\":");
const seed_lease_not_json = fuzzcorpus.entry("not json at all");
const seed_lease_quote_id = fuzzcorpus.entry("{\"id\":\"a\\\"b\\\\c\",\"until\":1,\"addrs\":[]}");
const seed_lease_escape_id = fuzzcorpus.entry("{\"id\":\"a\\nb\",\"until\":1,\"addrs\":[]}");
const seed_lease_until_overflow = fuzzcorpus.entry("{\"id\":\"x\",\"until\":18446744073709551615,\"addrs\":[]}");
const seed_lease_dup_keys = fuzzcorpus.entry("{\"id\":\"a\",\"id\":\"b\",\"until\":7,\"addrs\":[]}");
const seed_lease_deep_unknown = fuzzcorpus.entry("{\"id\":\"d\",\"until\":1,\"addrs\":[],\"z\":[[[[[[[[]]]]]]]]}");
const seed_lease_extreme_addrs = fuzzcorpus.entry("{\"id\":\"m\",\"until\":-5,\"addrs\":[{\"ip\":\"\",\"port\":0,\"mbps\":4294967295}]}");

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

// headerGet, queryGet, parseRange, and parseContentRange are the extraction
// layer every untrusted-byte decision rides: Authorization on both server
// and client, Content-Length and X-Piece-Size sizing the bitmap allocation,
// the path= query parameter feeding the relOk gate, the Range clamp before
// origin reads, and Content-Range binding a 206 body to the offset the
// fetch asked for. The harnesses above execute them on every input but
// read their expectations back through these same functions -- a drift
// there (returning the last duplicate instead of the first, matching a
// prefix of the name, trimming more than OWS, wrapping a 21-digit value)
// would reconfirm itself in every assertion and ship silently. These
// oracles restate each contract independently so the fuzzer sees the
// difference.

fn refHeaderGet(head: []const u8, name: []const u8) ?[]const u8 {
    // Manual offset walk instead of splitSequence: skip the status/request
    // line, then scan lines until the blank terminator, honoring exact-name
    // case-insensitive matches and space/tab-only OWS trimming.
    const first_end = std.mem.indexOf(u8, head, "\r\n") orelse return null;
    var pos: usize = first_end + 2;
    while (pos <= head.len) {
        const rel_end = std.mem.indexOf(u8, head[pos..], "\r\n") orelse head.len - pos;
        const line = head[pos .. pos + rel_end];
        if (line.len == 0) return null;
        if (std.mem.findScalar(u8, line, ':')) |colon| {
            if (colon == name.len and std.ascii.eqlIgnoreCase(line[0..colon], name)) {
                var v = line[colon + 1 ..];
                while (v.len > 0 and (v[0] == ' ' or v[0] == '\t')) v = v[1..];
                while (v.len > 0 and (v[v.len - 1] == ' ' or v[v.len - 1] == '\t')) v = v[0 .. v.len - 1];
                return v;
            }
        }
        pos += rel_end + 2;
    }
    return null;
}

fn refQueryGet(target: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var rest = target[q + 1 ..];
    while (rest.len > 0) {
        const amp = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
        const pair = rest[0..amp];
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            if (eq == key.len and std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
        }
        if (amp == rest.len) break;
        rest = rest[amp + 1 ..];
    }
    return null;
}

/// Overflow via parseInt's machinery instead of parseU64Fast's hand-rolled
/// mul/add ladder, so a corrupted ladder cannot self-confirm (same shape as
/// main.zig's refParseSize). The digit pre-scan keeps parseInt's sign and
/// underscore tolerance out of the accepted set.
fn refDigitsU64(s: []const u8) ?u64 {
    if (s.len == 0 or s.len > 20) return null;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return null;
    }
    return std.fmt.parseInt(u64, s, 10) catch null;
}

fn refParseRange(h: []const u8) ?Range {
    const s = std.mem.trim(u8, h, " \t");
    const prefix = "bytes=";
    if (!std.mem.startsWith(u8, s, prefix)) return null;
    const body = s[prefix.len..];
    const dash = std.mem.indexOfScalar(u8, body, '-') orelse return null;
    const start = refDigitsU64(body[0..dash]) orelse return null;
    const tail = body[dash + 1 ..];
    const end: u64 = if (tail.len == 0) std.math.maxInt(u64) else refDigitsU64(tail) orelse return null;
    if (end < start) return null;
    return .{ .start = start, .end = end };
}

fn refParseContentRange(h: []const u8) ?ContentRange {
    const s = std.mem.trim(u8, h, " \t");
    const prefix = "bytes ";
    if (!std.mem.startsWith(u8, s, prefix)) return null;
    const body = s[prefix.len..];
    const dash = std.mem.indexOfScalar(u8, body, '-') orelse return null;
    const rest = body[dash + 1 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const start = refDigitsU64(body[0..dash]) orelse return null;
    const end = refDigitsU64(rest[0..slash]) orelse return null;
    if (end < start) return null;
    const complete_s = rest[slash + 1 ..];
    const complete: u64 = if (complete_s.len == 1 and complete_s[0] == '*')
        std.math.maxInt(u64)
    else
        refDigitsU64(complete_s) orelse return null;
    return .{ .start = start, .end = end, .complete = complete };
}

/// Five framed slices per corpus entry: the raw head, the header name to
/// look up in it, the request target queryGet scans, the Range value, and
/// the Content-Range value the fetch client binds a 206 body against.
fn extractEntry(
    comptime head: []const u8,
    comptime name: []const u8,
    comptime target: []const u8,
    comptime range: []const u8,
    comptime crange: []const u8,
) [20 + head.len + name.len + target.len + range.len + crange.len]u8 {
    var out: [20 + head.len + name.len + target.len + range.len + crange.len]u8 = undefined;
    comptime var off: usize = 0;
    inline for (.{ head, name, target, range, crange }) |part| {
        std.mem.writeInt(u32, out[off..][0..4], @intCast(part.len), .little);
        @memcpy(out[off + 4 ..][0..part.len], part);
        off += 4 + part.len;
    }
    return out;
}

const seed_extract_ok = extractEntry(
    "GET /have?path=gguf%2Fmodel.gguf HTTP/1.1\r\nAuthorization: Bearer tok\r\nRange: bytes=0-1023\r\n\r\n",
    "Authorization",
    "/have?path=gguf%2Fmodel.gguf&x=1",
    "bytes=0-1023",
    "bytes 0-1023/4096",
);
const seed_extract_dup_cl = extractEntry(
    "HTTP/1.1 200 OK\r\nContent-Length: 3\r\ncontent-length: 999\r\nX-Piece-Size: 4096\r\nConnection: close\r\n\r\nabc",
    "Content-Length",
    "/data?path=a.bin",
    "bytes=536870912-536870913",
    "bytes 0-1/16",
);
const seed_extract_prefix_name = extractEntry(
    "HTTP/1.1 200 OK\r\nX-Piece-Size-Extra: 9\r\nX-Piece-Size: 16\r\n\r\n",
    "X-Piece-SIZE",
    "?path=%2F..%2Fetc",
    "bytes=10-",
    "bytes 10-15/*",
);
const seed_extract_lf_only = extractEntry(
    "GET / HTTP/1.1\nAuthorization: Bearer x\n",
    "authorization",
    "/have?path",
    "bytes=-",
    "bytes -5/10",
);
const seed_extract_odd_lines = extractEntry(
    "H: v\r\nno-colon\r\nA:\r\n \t spaced \t\r\n",
    "A",
    "?a=b=c&path=z=9",
    "BYTES=0-1",
    "BYTES 0-1/2",
);
const seed_extract_space_before_colon = extractEntry(
    "S\r\na: 1\r\nA : 2\r\nAuthorization: B\r\n\r\n",
    "A",
    "//?=&path",
    "bytes=18446744073709551615-18446744073709551615",
    "bytes 18446744073709551615-18446744073709551615/18446744073709551615",
);
const seed_extract_empty = extractEntry("", "", "", "", "");
const seed_extract_bad_range = extractEntry(
    "%zz\r\nRange: bytes=x-\r\n",
    "Range",
    "no-question-mark",
    "bytes=99999999999999999999-1",
    "bytes 99999999999999999999-1/1",
);
const seed_extract_cr_ok = extractEntry(
    "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 16-31/48\r\nContent-Length: 16\r\n\r\n",
    "Content-Range",
    "/data?path=a.bin",
    "bytes=16-31",
    "bytes 16-31/48",
);
const seed_extract_cr_star = extractEntry(
    "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-7/*\r\n\r\n",
    "Content-Range",
    "/data?path=x",
    "bytes=0-7",
    "bytes 0-7/*",
);
const seed_extract_cr_inverted = extractEntry(
    "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 10-1/20\r\n\r\n",
    "Content-Range",
    "/data",
    "bytes=10-1",
    "bytes 10-1/20",
);
const seed_extract_cr_eq = extractEntry(
    "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes=0-7/8\r\n\r\n",
    "Content-Range",
    "/data?path=y",
    "bytes=0-7",
    "bytes=0-7/8",
);
const seed_extract_cr_ows = extractEntry(
    "HTTP/1.1 206 Partial Content\r\nContent-Range:   bytes 8-15/16\t\r\n\r\n",
    "content-range",
    "/data?path=z",
    "bytes=8-15",
    "  bytes 8-15/16\t",
);

const fuzz_extract_corpus = [_][]const u8{
    &seed_extract_ok,
    &seed_extract_dup_cl,
    &seed_extract_prefix_name,
    &seed_extract_lf_only,
    &seed_extract_odd_lines,
    &seed_extract_space_before_colon,
    &seed_extract_empty,
    &seed_extract_bad_range,
    &seed_extract_cr_ok,
    &seed_extract_cr_star,
    &seed_extract_cr_inverted,
    &seed_extract_cr_eq,
    &seed_extract_cr_ows,
};

/// Asserts each extractor against its independent oracle on arbitrary bytes:
/// identical accept/reject and identical values for headerGet, queryGet,
/// parseRange, and parseContentRange; a canonically reformatted accepted
/// range or Content-Range reparses to the same bounds; and the
/// first-match-wins property the wire depends on holds for duplicated
/// headers and repeated query keys (synthesized only when the fuzzed
/// name/key cannot corrupt the frame itself).
fn fuzzExtractorsOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var head_buf: [512]u8 = undefined;
    const head = head_buf[0..smith.slice(&head_buf)];
    var name_buf: [64]u8 = undefined;
    const name = name_buf[0..smith.slice(&name_buf)];

    {
        const got = headerGet(head, name);
        const want = refHeaderGet(head, name);
        if (want) |w| {
            try std.testing.expectEqualStrings(w, got orelse return error.HeaderOracleMismatch);
        } else try std.testing.expect(got == null);
    }

    var target_buf: [256]u8 = undefined;
    const target = target_buf[0..smith.slice(&target_buf)];
    {
        const got = queryGet(target, name);
        const want = refQueryGet(target, name);
        if (want) |w| {
            try std.testing.expectEqualStrings(w, got orelse return error.QueryOracleMismatch);
        } else try std.testing.expect(got == null);
    }

    var range_buf: [64]u8 = undefined;
    const range_val = range_buf[0..smith.slice(&range_buf)];
    {
        const got = parseRange(range_val);
        const want = refParseRange(range_val);
        if (want) |w| {
            const g = got orelse return error.RangeOracleMismatch;
            try std.testing.expectEqual(w.start, g.start);
            try std.testing.expectEqual(w.end, g.end);
            var canon: [64]u8 = undefined;
            const rt = try std.fmt.bufPrint(&canon, "bytes={d}-{d}", .{ g.start, g.end });
            const reparsed = parseRange(rt) orelse return error.RangeRoundTripFailed;
            try std.testing.expectEqual(g.start, reparsed.start);
            try std.testing.expectEqual(g.end, reparsed.end);
        } else try std.testing.expect(got == null);
    }

    var cr_buf: [96]u8 = undefined;
    const cr_val = cr_buf[0..smith.slice(&cr_buf)];
    {
        const got = parseContentRange(cr_val);
        const want = refParseContentRange(cr_val);
        if (want) |w| {
            const g = got orelse return error.ContentRangeOracleMismatch;
            try std.testing.expectEqual(w.start, g.start);
            try std.testing.expectEqual(w.end, g.end);
            try std.testing.expectEqual(w.complete, g.complete);
            try std.testing.expect(g.end >= g.start);
            var canon: [96]u8 = undefined;
            const rt = if (g.complete == std.math.maxInt(u64))
                try std.fmt.bufPrint(&canon, "bytes {d}-{d}/*", .{ g.start, g.end })
            else
                try std.fmt.bufPrint(&canon, "bytes {d}-{d}/{d}", .{ g.start, g.end, g.complete });
            const reparsed = parseContentRange(rt) orelse return error.ContentRangeRoundTripFailed;
            try std.testing.expectEqual(g.start, reparsed.start);
            try std.testing.expectEqual(g.end, reparsed.end);
            try std.testing.expectEqual(g.complete, reparsed.complete);
        } else try std.testing.expect(got == null);
    }

    // First match wins on both extraction layers, spelled out because the
    // reply-side allocation sizes ride exactly the first Content-Length a
    // peer sends. Synthesis needs a name/key free of frame bytes; hostile
    // spellings stay covered by the oracle legs above.
    const clean = struct {
        fn frame(s: []const u8) bool {
            for (s) |ch| {
                if (ch == '\r' or ch == '\n' or ch == ':' or ch == '&' or ch == '=') return false;
            }
            return s.len > 0;
        }
    }.frame;
    if (clean(name)) {
        var dup_head: [256]u8 = undefined;
        const dup = try std.fmt.bufPrint(&dup_head, "S\r\n{s}: first\r\n{s}: last\r\n\r\n", .{ name, name });
        try std.testing.expectEqualStrings("first", headerGet(dup, name).?);
    }
    if (clean(name)) {
        var dup_target: [256]u8 = undefined;
        const dup = try std.fmt.bufPrint(&dup_target, "/x?{s}=2&{s}=1", .{ name, name });
        try std.testing.expectEqualStrings("2", queryGet(dup, name).?);
    }
}

test "fuzz header query range and content-range extraction match an independent scan" {
    try std.testing.fuzz({}, fuzzExtractorsOne, .{ .corpus = &fuzz_extract_corpus });
}
