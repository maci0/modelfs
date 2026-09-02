//! Shared framing for std.testing.fuzz seed corpora: every harness in this
//! tree stores one seed per entry in the shape Smith.slice reads back, so
//! that contract lives here once instead of once per module.
const std = @import("std");

/// One corpus entry carrying exactly `payload`: u32 little-endian length
/// prefix, then the raw bytes.
pub fn entry(comptime payload: []const u8) [4 + payload.len]u8 {
    var out: [4 + payload.len]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], @intCast(payload.len), .little);
    @memcpy(out[4..], payload);
    return out;
}

test "entry prefixes payload with a little-endian length" {
    // Smith.slice reads a u32 length prefix then that many bytes. A raw
    // codec blob used as a corpus seed is consumed as that prefix, so a
    // well-formed window or MFSM never reaches the decoder. Empty and
    // multi-byte payloads must both frame exactly.
    const framed = entry("abcd");
    try std.testing.expectEqual(@as(usize, 8), framed.len);
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, framed[0..4], .little));
    try std.testing.expectEqualSlices(u8, "abcd", framed[4..]);
    const empty = entry("");
    try std.testing.expectEqual(@as(usize, 4), empty.len);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, empty[0..4], .little));
}
