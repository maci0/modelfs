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
