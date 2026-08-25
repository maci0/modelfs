//! Piece arithmetic (count/offset/cover) and the persisted cache bitfield
//! codec, including pad-bit defenses against corrupt sidecars.
const std = @import("std");

pub const default_size: u32 = 16 * 1024 * 1024;
pub const magic = "MFS1";

pub fn count(file_size: u64, piece_size: u32) u32 {
    if (file_size == 0 or piece_size == 0) return 0;
    const ps: u64 = piece_size;
    // file_size can approach i64 max (a sparse truncate through the mount),
    // so the quotient can exceed u32: clamp like indexAt instead of letting
    // the cast panic (safe builds) or wrap (release builds) into a bitfield
    // too small for the file, whose bits then persist via saveBits.
    return @intCast(@min((file_size +| (ps - 1)) / ps, @as(u64, std.math.maxInt(u32))));
}

pub fn offset(index: u32, piece_size: u32) u64 {
    if (@popCount(piece_size) == 1) {
        const shift: u6 = @intCast(@ctz(piece_size));
        return @as(u64, index) << shift;
    }
    return @as(u64, index) * piece_size;
}

pub fn len(file_size: u64, index: u32, piece_size: u32) u32 {
    const start = offset(index, piece_size);
    if (start >= file_size) return 0;
    const remain = file_size - start;
    return @intCast(@min(remain, piece_size));
}

fn indexAt(file_off: u64, piece_size: u32) u32 {
    if (piece_size == 0) return 0;
    const idx = if (@popCount(piece_size) == 1)
        file_off >> @intCast(@ctz(piece_size))
    else
        file_off / piece_size;
    return @intCast(@min(idx, std.math.maxInt(u32)));
}

/// Valid-bit count at bit lo capped to span, null when the whole span is
/// valid. Written as a saturating subtraction instead of `lo + span >
/// nbits`: the final word of a max-clamped field (nbits = maxInt(u32),
/// what count() returns for sparse truncates near i64 max) sits at
/// lo = maxInt(u32) - span + 1, where the addition overflows u32, panicking
/// safe builds and silently skipping the pad mask in ReleaseFast.
fn tailValidBits(lo: u32, span: u32, nbits: u32) ?u6 {
    const v = nbits -| lo;
    if (v >= span) return null;
    return @intCast(v);
}

/// Inclusive start, exclusive end of pieces overlapping [file_off, file_off+n).
pub fn cover(file_off: u64, n: u64, file_size: u64, piece_size: u32) struct { start: u32, end: u32 } {
    if (n == 0 or piece_size == 0 or file_off >= file_size) return .{ .start = 0, .end = 0 };
    const last_byte = @min(file_off +| n, file_size) -| 1;
    const start = indexAt(file_off, piece_size);
    const last = indexAt(last_byte, piece_size);
    return .{ .start = start, .end = last +| 1 };
}

/// Inclusive start, exclusive end of pieces FULLY contained in [off, off+n).
/// Unlike cover, boundary pieces the range only partially covers are excluded:
/// marking such a piece filled would let later reads serve hole zeros for the
/// bytes the write never touched.
pub fn fullCover(off: u64, n: u64, piece_size: u32) struct { start: u32, end: u32 } {
    if (n == 0 or piece_size == 0) return .{ .start = 0, .end = 0 };
    const ps: u64 = piece_size;
    const first: u64 = (off +| (ps - 1)) / ps;
    const stop: u64 = (off +| n) / ps;
    if (first >= stop) return .{ .start = 0, .end = 0 };
    return .{
        .start = @intCast(@min(first, std.math.maxInt(u32))),
        .end = @intCast(@min(stop, std.math.maxInt(u32))),
    };
}

pub const Bitfield = struct {
    bytes: []u8,
    nbits: u32,

    pub fn bytesLen(nbits: u32) usize {
        return (@as(usize, nbits) + 7) / 8;
    }

    /// Clears pad bits above nbits in the final byte so phantom pieces can
    /// never inflate filled()/lastSet() or persist via encode.
    fn clearPadBits(bytes: []u8, nbits: u32) void {
        const rem = nbits % 8;
        if (rem != 0) bytes[bytesLen(nbits) - 1] &= (@as(u8, 1) << @intCast(rem)) - 1;
    }

    pub fn init(gpa: std.mem.Allocator, nbits: u32) !Bitfield {
        const n = bytesLen(nbits);
        const bytes = try gpa.alloc(u8, n);
        @memset(bytes, 0);
        return .{ .bytes = bytes, .nbits = nbits };
    }

    pub fn deinit(self: *Bitfield, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }

    /// Grows or shrinks in place, keeping the first min(old, new) bits.
    /// Grown capacity is zero-filled and pad bits past nbits are cleared,
    /// so filled()/lastSet() never count phantom pieces. On allocation
    /// failure the field is left untouched.
    pub fn resize(self: *Bitfield, gpa: std.mem.Allocator, nbits: u32) !void {
        const old_bytes = bytesLen(self.nbits);
        const new_bytes = bytesLen(nbits);
        const bytes = try gpa.realloc(self.bytes, new_bytes);
        self.bytes = bytes;
        if (new_bytes > old_bytes) @memset(bytes[old_bytes..], 0);
        self.nbits = nbits;
        clearPadBits(bytes, nbits);
    }

    pub fn get(self: Bitfield, i: u32) bool {
        if (i >= self.nbits) return false;
        return self.bytes[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0;
    }

    pub fn set(self: *Bitfield, i: u32) void {
        if (i >= self.nbits) return;
        self.bytes[i / 8] |= @as(u8, 1) << @intCast(i % 8);
    }

    pub fn clear(self: *Bitfield, i: u32) void {
        if (i >= self.nbits) return;
        self.bytes[i / 8] &= ~(@as(u8, 1) << @intCast(i % 8));
    }

    pub fn filled(self: Bitfield) u32 {
        var total: u32 = 0;
        var i: usize = 0;
        while (i + 8 <= self.bytes.len) : (i += 8) {
            // Same pad-bit defense as lastSet: a final word that is only
            // partly valid (nbits not a multiple of 64) must not count its
            // pad bits when they get set by corruption or a future writer.
            const lo: u32 = @intCast(i * 8);
            var w = std.mem.readInt(u64, self.bytes[i..][0..8], .little);
            if (tailValidBits(lo, 64, self.nbits)) |valid| {
                w &= (@as(u64, 1) << valid) - 1;
            }
            total += @popCount(w);
        }
        while (i < self.bytes.len) : (i += 1) {
            // Same pad-bit defense as lastSet: writers keep them zero, but
            // a corrupt field must not inflate the count.
            const lo: u32 = @intCast(i * 8);
            var b = self.bytes[i];
            if (tailValidBits(lo, 8, self.nbits)) |valid|
                b &= (@as(u8, 1) << @as(u3, @intCast(valid))) - 1;
            total += @popCount(b);
        }
        return total;
    }

    pub fn lastSet(self: Bitfield) ?u32 {
        // Word-at-a-time backward scan: @clz names the top set bit of a full
        // u64 in one instruction instead of walking every byte and bit. A
        // 16 MiB piece size makes a 1 TiB model an 8 KiB field, so the old
        // byte loop cost thousands of iterations per cull candidate.
        var end = self.bytes.len;
        while (end >= 8) {
            const lo: u32 = @intCast((end - 8) * 8);
            var w = std.mem.readInt(u64, self.bytes[end - 8 ..][0..8], .little);
            if (tailValidBits(lo, 64, self.nbits)) |valid| {
                // Trim pad bits above nbits (writers keep them zero; this
                // keeps that invariant local to the reader).
                w &= (@as(u64, 1) << valid) - 1;
            }
            if (w != 0) return lo + @as(u32, 63 - @clz(w));
            end -= 8;
        }
        while (end > 0) {
            end -= 1;
            const b = self.bytes[end];
            if (b != 0) {
                var bit: u8 = 8;
                while (bit > 0) {
                    bit -= 1;
                    const idx: u32 = @intCast(end * 8 + bit);
                    if (idx < self.nbits and (b & (@as(u8, 1) << @intCast(bit))) != 0) {
                        return idx;
                    }
                }
            }
        }
        return null;
    }

    pub fn encode(self: Bitfield, piece_size: u32, file_size: u64, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        // Exact size up front: saves run per piece fill and per punch, and an
        // empty-list append chain would otherwise realloc-copy the growing
        // blob several times per save.
        try out.ensureTotalCapacity(gpa, out.items.len + magic.len + 12 + self.bytes.len);
        try out.appendSlice(gpa, magic);
        var ps: [4]u8 = undefined;
        std.mem.writeInt(u32, &ps, piece_size, .little);
        try out.appendSlice(gpa, &ps);
        var fs: [8]u8 = undefined;
        std.mem.writeInt(u64, &fs, file_size, .little);
        try out.appendSlice(gpa, &fs);
        try out.appendSlice(gpa, self.bytes);
    }

    pub fn decode(gpa: std.mem.Allocator, blob: []const u8, piece_size: u32, file_size: u64) !Bitfield {
        if (blob.len < 16) return error.BadBitfield;
        if (!std.mem.eql(u8, blob[0..4], magic)) return error.BadBitfield;
        const ps = std.mem.readInt(u32, blob[4..8], .little);
        const fs = std.mem.readInt(u64, blob[8..16], .little);
        const n = count(file_size, piece_size);
        var bf = try init(gpa, n);
        if (ps != piece_size or fs != file_size) {
            // stale sidecar: empty field, caller will refill
            return bf;
        }
        const want = bytesLen(n);
        const src = blob[16..];
        const copy = @min(want, src.len);
        @memcpy(bf.bytes[0..copy], src[0..copy]);
        clearPadBits(bf.bytes, n);
        return bf;
    }
};

test "tailValidBits survives the max-clamped final word" {
    const max = std.math.maxInt(u32);
    // The final word of a max-clamped field: `lo + 64 > nbits`, the form
    // this helper replaced, overflows u32 exactly here (panic in safe
    // builds, skipped mask in ReleaseFast). 63 of 64 bits stay valid.
    try std.testing.expectEqual(@as(?u6, 63), tailValidBits(max - 63, 64, max));
    // Same boundary in the byte tail: 7 of 8 bits valid.
    try std.testing.expectEqual(@as(?u6, 7), tailValidBits(max - 7, 8, max));
    // Fully valid spans return null, partially valid ones the remainder.
    try std.testing.expectEqual(@as(?u6, null), tailValidBits(0, 64, 128));
    try std.testing.expectEqual(@as(?u6, 60), tailValidBits(0, 64, 60));
    try std.testing.expectEqual(@as(?u6, 6), tailValidBits(64, 8, 70));
    try std.testing.expectEqual(@as(?u6, null), tailValidBits(64, 64, 128));
}

test "count clamps instead of overflowing u32" {
    const ps: u32 = 16 * 1024 * 1024;
    // A sparse truncate near i64 max (user-controlled through mf_truncate)
    // must clamp, not panic the cast or wrap in release builds.
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), count(std.math.maxInt(i64), ps));
    // Largest length whose true piece count still fits stays exact.
    const fit: u64 = @as(u64, ps) * std.math.maxInt(u32);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), count(fit, ps));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), count(fit - 1, ps));
}

test "piece count and cover" {
    const ps: u32 = 16 * 1024 * 1024;
    try std.testing.expectEqual(@as(u32, 0), count(0, ps));
    try std.testing.expectEqual(@as(u32, 1), count(1, ps));
    try std.testing.expectEqual(@as(u32, 1), count(ps, ps));
    try std.testing.expectEqual(@as(u32, 2), count(ps + 1, ps));
    try std.testing.expectEqual(@as(u32, ps), len(ps + 100, 0, ps));
    try std.testing.expectEqual(@as(u32, 100), len(ps + 100, 1, ps));

    const c1 = cover(0, 100, 70 * 1024 * 1024 * 1024, ps);
    try std.testing.expectEqual(@as(u32, 0), c1.start);
    try std.testing.expectEqual(@as(u32, 1), c1.end);

    const c2 = cover(ps - 10, 20, 3 * ps, ps);
    try std.testing.expectEqual(@as(u32, 0), c2.start);
    try std.testing.expectEqual(@as(u32, 2), c2.end);

    // offset is the pwrite address for a piece: pow2 and odd sizes must agree
    try std.testing.expectEqual(@as(u64, 12288), offset(3, 4096));
    try std.testing.expectEqual(@as(u64, 15000), offset(3, 5000));
    try std.testing.expectEqual(@as(u32, 3), indexAt(12288, 4096));
    try std.testing.expectEqual(@as(u32, 3), indexAt(16383, 4096));
    try std.testing.expectEqual(@as(u32, 4), indexAt(16384, 4096));
}

test "bitfield set get persist" {
    const gpa = std.testing.allocator;
    var bf = try Bitfield.init(gpa, 10);
    defer bf.deinit(gpa);
    try std.testing.expect(!bf.get(3));
    bf.set(3);
    bf.set(9);
    try std.testing.expect(bf.get(3));
    try std.testing.expect(bf.get(9));
    try std.testing.expectEqual(@as(u32, 2), bf.filled());
    try std.testing.expectEqual(@as(u32, 9), bf.lastSet().?);

    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(gpa);
    try bf.encode(4096, 40960, &blob, gpa);
    var bf2 = try Bitfield.decode(gpa, blob.items, 4096, 40960);
    defer bf2.deinit(gpa);
    try std.testing.expect(bf2.get(3));
    try std.testing.expect(bf2.get(9));
    try std.testing.expect(!bf2.get(1));
}

test "decode masks pad bits past nbits" {
    const gpa = std.testing.allocator;
    var bf = try Bitfield.init(gpa, 10);
    defer bf.deinit(gpa);
    bf.set(0);
    bf.set(9);
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(gpa);
    try bf.encode(4096, 40960, &blob, gpa);
    // Corrupt the pad bits (bits 10..15 live in byte 1 above nbits=10).
    blob.items[16 + 1] |= 0b11111100;
    var bf2 = try Bitfield.decode(gpa, blob.items, 4096, 40960);
    defer bf2.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), bf2.filled());
    try std.testing.expect(bf2.get(0));
    try std.testing.expect(bf2.get(9));
}

test "stale bitfield size resets" {
    const gpa = std.testing.allocator;
    var bf = try Bitfield.init(gpa, 4);
    defer bf.deinit(gpa);
    bf.set(0);
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(gpa);
    try bf.encode(16, 64, &blob, gpa);
    var bf2 = try Bitfield.decode(gpa, blob.items, 16, 128);
    defer bf2.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 8), bf2.nbits);
    try std.testing.expectEqual(@as(u32, 0), bf2.filled());
}

test "filled masks pad bits inside a full trailing word" {
    const gpa = std.testing.allocator;
    // nbits=60: bytesLen=8, so the whole field is one full-width u64 word
    // whose top four bits (60..63) are pad. Regression: the word loop counted
    // them unmasked, so a corrupt field inflated filled() (which reapIdle
    // gates eviction on) while lastSet correctly ignored the same bits.
    var bf = try Bitfield.init(gpa, 60);
    defer bf.deinit(gpa);
    bf.set(0);
    bf.set(59);
    try std.testing.expectEqual(@as(u32, 2), bf.filled());
    // Corrupt every pad bit in the trailing word.
    bf.bytes[7] |= 0b11110000;
    try std.testing.expectEqual(@as(u32, 2), bf.filled());
    try std.testing.expectEqual(@as(u32, 59), bf.lastSet().?);

    // A byte-aligned tail keeps its existing defense too.
    var bf2 = try Bitfield.init(gpa, 10);
    defer bf2.deinit(gpa);
    bf2.set(9);
    bf2.bytes[1] |= 0b11110000;
    try std.testing.expectEqual(@as(u32, 1), bf2.filled());
}

test "lastSet scans words and tolerates pad bits" {
    const gpa = std.testing.allocator;
    // 70 bits = 8-byte word plus 1 byte, exercising the word/byte boundary.
    var bf = try Bitfield.init(gpa, 70);
    defer bf.deinit(gpa);
    bf.set(0);
    bf.set(64);
    bf.set(69);
    try std.testing.expectEqual(@as(u32, 69), bf.lastSet().?);
    // Writers never set pad bits above nbits; forcing them must not make the
    // word-wise scan report a phantom piece.
    bf.bytes[8] |= 0b11000000;
    try std.testing.expectEqual(@as(u32, 69), bf.lastSet().?);

    var big = try Bitfield.init(gpa, 200);
    defer big.deinit(gpa);
    big.set(3);
    big.set(128);
    big.set(199);
    try std.testing.expectEqual(@as(u32, 199), big.lastSet().?);
}

test "resize preserves prefix bits and clears grown capacity" {
    const gpa = std.testing.allocator;
    var bf = try Bitfield.init(gpa, 4);
    defer bf.deinit(gpa);
    bf.set(0);
    bf.set(3);
    try bf.resize(gpa, 10);
    try std.testing.expectEqual(@as(u32, 10), bf.nbits);
    try std.testing.expectEqual(@as(u32, 2), bf.filled());
    try std.testing.expect(bf.get(0));
    try std.testing.expect(bf.get(3));
    try std.testing.expect(!bf.get(9));

    // Shrink keeps the low bits and masks the new pad bits.
    bf.set(8);
    try bf.resize(gpa, 5);
    try std.testing.expectEqual(@as(u32, 5), bf.nbits);
    try std.testing.expectEqual(@as(u32, 2), bf.filled());
    try std.testing.expect(bf.get(3));
}

test "zero piece_size edge cases" {
    try std.testing.expectEqual(@as(u32, 0), count(100, 0));
    try std.testing.expectEqual(@as(u32, 0), indexAt(100, 0));
    const c = cover(10, 20, 100, 0);
    try std.testing.expectEqual(@as(u32, 0), c.start);
    try std.testing.expectEqual(@as(u32, 0), c.end);
}

test "fullCover only claims pieces the range fully spans" {
    const ps: u32 = 16 * 1024 * 1024;
    // write of one exact piece at piece boundary fills exactly that piece
    var fc = fullCover(0, ps, ps);
    try std.testing.expectEqual(@as(u32, 0), fc.start);
    try std.testing.expectEqual(@as(u32, 1), fc.end);
    // two aligned pieces
    fc = fullCover(ps, 2 * ps, ps);
    try std.testing.expectEqual(@as(u32, 1), fc.start);
    try std.testing.expectEqual(@as(u32, 3), fc.end);
    // partial write inside one piece fills nothing (regression: cover() was
    // used here and marked the whole boundary piece, serving hole zeros for
    // the untouched tail)
    fc = fullCover(100, 200, ps);
    try std.testing.expectEqual(@as(u32, 0), fc.start);
    try std.testing.expectEqual(@as(u32, 0), fc.end);
    // straddling a boundary: middle piece is full, both edges are not
    fc = fullCover(ps - 10, ps + 20, ps);
    try std.testing.expectEqual(@as(u32, 1), fc.start);
    try std.testing.expectEqual(@as(u32, 2), fc.end);
    // empty range
    fc = fullCover(0, 0, ps);
    try std.testing.expectEqual(@as(u32, 0), fc.start);
    try std.testing.expectEqual(@as(u32, 0), fc.end);
}

test "cover saturation near max int" {
    const max = std.math.maxInt(u64);
    // indexAt clamps huge offsets to maxInt(u32); +| keeps end inside u32
    const c = cover(max - 5, 100, max, 1024);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), c.start);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), c.end);
    // read fully past eof yields empty range
    const past = cover(max - 2049, 10, 100, 1024);
    try std.testing.expectEqual(@as(u32, 0), past.start);
    try std.testing.expectEqual(@as(u32, 0), past.end);
}

/// One sidecar blob as it lands on shared storage, wrapped in the corpus
/// framing the decode harness reads: u32 length prefix, blob bytes, then the
/// u64 geometry selector drawn after the blob.
fn decodeEntry(comptime blob: []const u8, comptime geo: u64) [4 + blob.len + 8]u8 {
    var out: [4 + blob.len + 8]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], @intCast(blob.len), .little);
    @memcpy(out[4..][0..blob.len], blob);
    std.mem.writeInt(u64, out[4 + blob.len ..][0..8], geo, .little);
    return out;
}

/// A well-formed sidecar body: MFS1 magic, little-endian piece size and file
/// size, then the raw bit bytes.
fn sidecarBody(comptime ps: u32, comptime fs: u64, comptime bits: []const u8) [16 + bits.len]u8 {
    var b: [16 + bits.len]u8 = undefined;
    @memcpy(b[0..4], magic);
    std.mem.writeInt(u32, b[4..8], ps, .little);
    std.mem.writeInt(u64, b[8..16], fs, .little);
    @memcpy(b[16..], bits);
    return b;
}

// Caller-side geometries the harness draws from: small enough that decode's
// allocation stays tiny, yet covering pow2, odd, zero-file, and the unit
// tests' canonical shape. Indices appear in the seeds below.
const decode_geos = [_]struct { ps: u32, fs: u64 }{
    .{ .ps = 1, .fs = 0 }, // empty field
    .{ .ps = 1, .fs = 512 }, // largest field the harness allows
    .{ .ps = 7, .fs = 1001 }, // non-power-of-two piece size
    .{ .ps = 8, .fs = 520 },
    .{ .ps = 512, .fs = 8192 },
    .{ .ps = 4096, .fs = 40960 }, // matches the unit tests' shape
};

const seed_sidecar_clean = decodeEntry(&sidecarBody(4096, 40960, &.{ 0x05, 0x80 }), 5);
const seed_sidecar_pad_corrupt = decodeEntry(&sidecarBody(4096, 40960, &.{ 0x05, 0xff }), 5);
const seed_sidecar_stale_geo = decodeEntry(&sidecarBody(4096, 40960, &.{ 0x05, 0x80 }), 4);
const seed_sidecar_short_body = decodeEntry(&sidecarBody(8, 520, &.{ 0xff, 0xff, 0xff }), 3);
const seed_sidecar_bad_magic = decodeEntry("XXXX\x00\x10\x00\x00" ++ "\x00" ** 8 ++ "\x01", 3);
const seed_sidecar_truncated_header = decodeEntry("MFS1\x00", 1);
const seed_sidecar_empty = decodeEntry("", 0);

const fuzz_decode_corpus = [_][]const u8{
    &seed_sidecar_clean,
    &seed_sidecar_pad_corrupt,
    &seed_sidecar_stale_geo,
    &seed_sidecar_short_body,
    &seed_sidecar_bad_magic,
    &seed_sidecar_truncated_header,
    &seed_sidecar_empty,
};

/// Sidecars ride on shared storage where crashes and co-tenants corrupt
/// them; every pad-bit regression this module fixed came through decode.
/// The harness asserts a complete oracle, not just crash-freedom: the field
/// shape follows the caller's geometry (never the blob's claims), an exact
/// header match reproduces the stored bits up to the copied region with pad
/// bits masked, and anything else comes back empty rather than half-applied.
fn fuzzBitfieldDecodeOne(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var blob_buf: [96]u8 = undefined;
    const blob = blob_buf[0..smith.slice(&blob_buf)];
    const gi: usize = @intCast(smith.value(u64) % decode_geos.len);
    const geo = decode_geos[gi];

    var bf = Bitfield.decode(gpa, blob, geo.ps, geo.fs) catch return;
    defer bf.deinit(gpa);

    try std.testing.expectEqual(count(geo.fs, geo.ps), bf.nbits);
    try std.testing.expectEqual(Bitfield.bytesLen(bf.nbits), bf.bytes.len);
    try std.testing.expect(bf.filled() <= bf.nbits);
    if (bf.lastSet()) |ls| try std.testing.expect(ls < bf.nbits);

    if (blob.len >= 16 and std.mem.eql(u8, blob[0..4], magic) and
        std.mem.readInt(u32, blob[4..8], .little) == geo.ps and
        std.mem.readInt(u64, blob[8..16], .little) == geo.fs)
    {
        const src = blob[16..];
        const copy = @min(Bitfield.bytesLen(bf.nbits), src.len);
        var i: u32 = 0;
        while (i < bf.nbits) : (i += 1) {
            const kept = i / 8 < copy and (src[i / 8] >> @as(u3, @intCast(i % 8))) & 1 != 0;
            try std.testing.expectEqual(kept, bf.get(i));
        }
    } else {
        try std.testing.expectEqual(@as(u32, 0), bf.filled());
        try std.testing.expect(bf.lastSet() == null);
    }
}

test "fuzz bitfield sidecar decode matches stored bits or resets empty" {
    try std.testing.fuzz({}, fuzzBitfieldDecodeOne, .{ .corpus = &fuzz_decode_corpus });
}

/// One op sequence as a corpus entry: u32 length prefix, then one byte per
/// op (low 2 bits pick set/clear/grow/shrink, the rest carry the index).
fn opsEntry(comptime ops: []const u8) [4 + ops.len]u8 {
    var out: [4 + ops.len]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], @intCast(ops.len), .little);
    @memcpy(out[4..], ops);
    return out;
}

const seed_ops_sets = opsEntry(&.{ 0x08, 0x10, 0x18, 0xff });
const seed_ops_grow_set = opsEntry(&.{ 0x22, 0x2a, 0x06 });
const seed_ops_shrink = opsEntry(&.{ 0x23, 0x2f, 0x37, 0x03 });
const seed_ops_mixed = opsEntry(&.{ 0x08, 0x22, 0x1a, 0x23, 0x11, 0x2b });
const seed_ops_pad_shape = opsEntry(&.{ 0x22, 0x08, 0x12, 0x1c }); // stops at nbits=5, a pad-bit boundary

const fuzz_persist_corpus = [_][]const u8{
    &seed_ops_sets,
    &seed_ops_grow_set,
    &seed_ops_shrink,
    &seed_ops_mixed,
    &seed_ops_pad_shape,
};

/// The sidecar is a persistence pair, not just a parser: writers build the
/// field through set/clear/resize and encode, readers take decode at the
/// stored geometry. Every pad-bit regression this module fixed lived in the
/// gap between those halves, invisible to a decode-only harness. This drives
/// random op sequences against a shadow model and asserts, after the
/// encode/decode round trip through shared-storage framing, that filled(),
/// lastSet(), and every get() reproduce the model exactly -- while a stale
/// geometry still resets empty rather than half-applying old bits.
fn fuzzBitfieldPersistOne(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    const bits_cap: u32 = 128;

    var bf = try Bitfield.init(gpa, 1);
    defer bf.deinit(gpa);
    var expect = [_]bool{false} ** bits_cap;
    var nbits: u32 = 1;

    var ops_buf: [24]u8 = undefined;
    const ops = ops_buf[0..smith.slice(&ops_buf)];
    for (ops) |op| {
        const idx: u32 = op >> 2;
        switch (@as(u2, @truncate(op & 3))) {
            0 => if (idx < nbits) {
                bf.set(idx);
                expect[idx] = true;
            },
            1 => if (idx < nbits) {
                bf.clear(idx);
                expect[idx] = false;
            },
            2 => {
                const new_nbits = @min(nbits + 1 + idx % 5, bits_cap);
                if (new_nbits != nbits) {
                    try bf.resize(gpa, new_nbits);
                    for (expect[nbits..new_nbits]) |*e| e.* = false;
                    nbits = new_nbits;
                }
            },
            else => if (nbits > 1) {
                nbits = @max(1, nbits - 1 - idx % 5);
                try bf.resize(gpa, nbits);
            },
        }
    }

    var want_filled: u32 = 0;
    var want_last: ?u32 = null;
    for (expect[0..nbits], 0..) |set_at, i| {
        try std.testing.expectEqual(set_at, bf.get(@intCast(i)));
        if (set_at) {
            want_filled += 1;
            want_last = @intCast(i);
        }
    }
    try std.testing.expectEqual(want_filled, bf.filled());
    try std.testing.expectEqual(want_last, bf.lastSet());

    // Persist with the caller's geometry (piece size 1 keeps count() equal to
    // the file size) and read it back exactly.
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(gpa);
    try bf.encode(1, nbits, &blob, gpa);
    var back = try Bitfield.decode(gpa, blob.items, 1, nbits);
    defer back.deinit(gpa);
    try std.testing.expectEqual(nbits, back.nbits);
    var i: u32 = 0;
    while (i < nbits) : (i += 1) try std.testing.expectEqual(expect[i], back.get(i));
    try std.testing.expectEqual(want_filled, back.filled());
    try std.testing.expectEqual(want_last, back.lastSet());

    // A reader with any other geometry must see an empty field, never a
    // half-applied one sized from the blob's stale header claims.
    var stale = try Bitfield.decode(gpa, blob.items, 1, nbits + 1);
    defer stale.deinit(gpa);
    try std.testing.expectEqual(count(nbits + 1, 1), stale.nbits);
    try std.testing.expectEqual(@as(u32, 0), stale.filled());
    try std.testing.expect(stale.lastSet() == null);
}

test "fuzz bitfield persist cycle reproduces the shadow model exactly" {
    try std.testing.fuzz({}, fuzzBitfieldPersistOne, .{ .corpus = &fuzz_persist_corpus });
}
