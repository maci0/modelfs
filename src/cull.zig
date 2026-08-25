//! Cull phase policy: cachefilesd-shaped brun/bcull/bstop watermarks over
//! percent free space on the cache filesystem.
const std = @import("std");

/// Same shape as cachefilesd brun/bcull/bstop: percent **free** on the cache fs.
pub const Water = struct {
    brun: u32 = 10,
    bcull: u32 = 7,
    bstop: u32 = 3,
};

/// True when the watermarks are strictly ordered brun > bcull > bstop, the
/// only arrangement phase() hysteresis works for. Out of order, the failure
/// is deterministic, not merely suboptimal:
///   * bstop >= bcull makes .stop win on every sample at or below bstop, so
///     hard culling runs far above the intended floor and keeps the cache
///     capped under bstop% used no matter how empty the disk is;
///   * brun <= bcull makes the band [brun, bcull] enter culling one tick and
///     leave it the next (free >= brun ends it, free <= bcull restarts it),
///     punching candidates every round while free space sits still.
/// cachefilesd documents the same ordering constraint on its config values.
pub fn ordered(w: Water) bool {
    return w.brun > w.bcull and w.bcull > w.bstop;
}

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

test "ordered rejects the orderings that break phase hysteresis" {
    // Defaults and any strict ordering are valid.
    try std.testing.expect(ordered(.{}));
    try std.testing.expect(ordered(.{ .brun = 100, .bcull = 99, .bstop = 0 }));
    // bstop >= bcull: .stop pins at every sample <= bstop, hard-culling the
    // cache down toward bstop% used regardless of bcull's intent.
    try std.testing.expect(!ordered(.{ .brun = 90, .bcull = 70, .bstop = 80 }));
    try std.testing.expect(!ordered(.{ .brun = 7, .bcull = 3, .bstop = 3 }));
    // brun <= bcull: the [brun, bcull] band flaps run/cull every tick,
    // punching candidates each round while free space never moves.
    try std.testing.expect(!ordered(.{ .brun = 5, .bcull = 10, .bstop = 3 }));
    try std.testing.expect(!ordered(.{ .brun = 7, .bcull = 7, .bstop = 3 }));
}

test "freePercent" {
    try std.testing.expectEqual(@as(u32, 100), freePercent(100, 0));
    try std.testing.expectEqual(@as(u32, 10), freePercent(10, 100));
    try std.testing.expectEqual(@as(u32, 7), freePercent(7, 100));
    // clamps at 100 instead of overflowing
    try std.testing.expectEqual(@as(u32, 100), freePercent(150, 100));
    // bavail * 100 exceeds u64 at these magnitudes: the widening must keep
    // the percentage exact instead of wrapping (safe builds panic otherwise).
    const max = std.math.maxInt(u64);
    try std.testing.expectEqual(@as(u32, 0), freePercent(1, max));
    try std.testing.expectEqual(@as(u32, 50), freePercent(max / 2 + 1, max));
    try std.testing.expectEqual(@as(u32, 100), freePercent(max, max));
}
