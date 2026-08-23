//! Cull phase policy: cachefilesd-shaped brun/bcull/bstop watermarks over
//! percent free space on the cache filesystem.
const std = @import("std");

/// Same shape as cachefilesd brun/bcull/bstop: percent **free** on the cache fs.
pub const Water = struct {
    brun: u32 = 10,
    bcull: u32 = 7,
    bstop: u32 = 3,
};

pub const Phase = enum { run, cull, stop };

pub fn phase(free_pct: u32, w: Water, culling: bool) Phase {
    if (free_pct <= w.bstop) return .stop;
    if (culling) {
        if (free_pct >= w.brun) return .run;
        return .cull;
    }
    if (free_pct <= w.bcull) return .cull;
    return .run;
}

pub fn freePercent(bavail: u64, blocks: u64) u32 {
    if (blocks == 0) return 100;
    // bavail * 100 can exceed u64 on huge filesystems; widen before dividing.
    const pct: u128 = @as(u128, bavail) * 100 / blocks;
    return @intCast(@min(pct, 100));
}

test "phase matches cachefilesd watermarks" {
    const w = Water{};
    try std.testing.expectEqual(Phase.run, phase(50, w, false));
    try std.testing.expectEqual(Phase.run, phase(10, w, false));
    try std.testing.expectEqual(Phase.cull, phase(7, w, false));
    try std.testing.expectEqual(Phase.cull, phase(5, w, false));
    try std.testing.expectEqual(Phase.stop, phase(3, w, false));
    try std.testing.expectEqual(Phase.stop, phase(0, w, true));
    try std.testing.expectEqual(Phase.cull, phase(8, w, true));
    try std.testing.expectEqual(Phase.run, phase(10, w, true));
}

test "freePercent" {
    try std.testing.expectEqual(@as(u32, 100), freePercent(100, 0));
    try std.testing.expectEqual(@as(u32, 10), freePercent(10, 100));
    try std.testing.expectEqual(@as(u32, 7), freePercent(7, 100));
    // clamps at 100 instead of overflowing
    try std.testing.expectEqual(@as(u32, 100), freePercent(150, 100));
}
