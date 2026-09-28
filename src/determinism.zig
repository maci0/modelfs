//! Source-level guards on the two nondeterminism doors the daemon has:
//! the wall clock and entropy. Neither rule needs a simulator to enforce,
//! and both fail at `zig build test` rather than in a replay nobody can
//! reproduce.
//!
//! Why source text and not runtime probes. A simulator can only steer what
//! the code lets it inject, and a leaked `clock_gettime` or a `/dev/urandom`
//! read is invisible to every runtime check this tree can make: the run is
//! still green, the replay still diverges, and the first differing field
//! names a source line nothing in the tree points at. Scanning the sources
//! turns that from a debugging session into a gate.
//!
//! Scope. Only `src/*.zig` daemon modules are scanned, and only real code
//! lines: a `//` comment naming a syscall is documentation, not a call.
//! `sys.zig` is exempt from the clock rule because it *is* the clock door
//! (nowSec / monoSec / bootSec / monoMs / monoNs / sleepMs, all sampled
//! through the injected `std.Io`); every other module goes through those.
//! `c.zig` is a re-export of the C door, and `root.zig` only aggregates
//! tests, so neither is scanned.
const std = @import("std");

/// Every daemon module under test, in the order root.zig imports them.
/// Named rather than globbed: a new src/*.zig that root.zig imports must be
/// added here, which is the same reminder the aggregator already gives.
const modules = [_][]const u8{
    "piece.zig",
    "proto.zig",
    "cull.zig",
    "fuzzcorpus.zig",
    "store.zig",
    "discover.zig",
    "peer.zig",
    "fuse_fs.zig",
    "handover.zig",
    "hf.zig",
    "main.zig",
};

/// Wall-clock and blocking-sleep reads. Each is a value the simulator's
/// virtual clock cannot advance, so one of these on a decision path makes a
/// replay diverge regardless of the seed.
const clock_patterns = [_][]const u8{
    "clock_gettime",
    "gettimeofday",
    "std.time.nanoTimestamp",
    "std.time.milliTimestamp",
    "std.time.timestamp",
    "std.Io.Clock.now",
    "nanosleep",
    "usleep",
    "std.Thread.sleep",
};

/// Raw OS entropy. The one security-sensitive value in the tree, the
/// handover token, is read through `io.randomSecure` (handover.zig's
/// randomToken), so a simulator substitutes it from a seeded PRNG while
/// production keeps the kernel CSPRNG. Reaching around that for
/// `std.crypto.random` or /dev/urandom takes the door off its hinge.
const entropy_patterns = [_][]const u8{
    "std.crypto.random",
    "/dev/urandom",
    "/dev/random",
    "RAND_bytes",
};

/// Read ceiling for one module's source. Comfortably above the largest
/// module, so a module that outgrew it gets split rather than exempted.
const max_module_bytes: usize = 1 << 20;

/// True when `line` carries a pattern. Comment-only lines are skipped: the
/// tree documents the syscalls it deliberately does not use by name
/// (store.zig's yield note names nanosleep), and flagging prose would make
/// this gate noise to route around.
fn codeLine(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t\r");
    return t.len != 0 and t[0] != '/' and t[0] != '*';
}

fn firstPattern(line: []const u8, patterns: []const []const u8) ?[]const u8 {
    for (patterns) |p| {
        if (std.mem.indexOf(u8, line, p) != null) return p;
    }
    return null;
}

fn expectClean(name: []const u8, source: []const u8, patterns: []const []const u8) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (!codeLine(line)) continue;
        if (firstPattern(line, patterns)) |p| {
            std.debug.print("src/{s}: {s}: nondeterminism source outside its door: {s}\n", .{ name, line, p });
            return error.NondeterminismSource;
        }
    }
}

/// Every module is a short name under `src/`, so the path fits a stack
/// buffer and the scan allocates exactly one thing: the source it reads.
/// `max_module_bytes` is a ceiling, not a real budget: the largest module
/// is a fraction of it, and a module that outgrew the ceiling should be
/// split rather than exempted.
fn readModule(io: std.Io, name: []const u8) ![]u8 {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "src/{s}", .{name});
    return std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(max_module_bytes));
}

test "wall clock and sleep are read only through the sys.zig clock door" {
    const io = std.testing.io;
    for (modules) |name| {
        const src = try readModule(io, name);
        defer std.testing.allocator.free(src);
        try expectClean(name, src, &clock_patterns);
    }
    // The door is not a loophole: it is where the injected clock lives.
    const sys_src = try readModule(io, "sys.zig");
    defer std.testing.allocator.free(sys_src);
    try std.testing.expect(firstPattern(sys_src, &clock_patterns) != null);
}

test "entropy is read through io.randomSecure, never the kernel directly" {
    const io = std.testing.io;
    for (modules) |name| {
        const src = try readModule(io, name);
        defer std.testing.allocator.free(src);
        try expectClean(name, src, &entropy_patterns);
    }
    // The door: handover's token entropy is the injected one, so a
    // simulation can seed it and a production run keeps the CSPRNG.
    const ho = try readModule(io, "handover.zig");
    defer std.testing.allocator.free(ho);
    try std.testing.expect(std.mem.indexOf(u8, ho, "io.randomSecure") != null);
}

test "codeLine skips prose and keeps code" {
    try std.testing.expect(codeLine("const x = 1;"));
    try std.testing.expect(codeLine("\tstd.log.info(\"hi\");"));
    // A syscall named in a comment is documentation, not a call.
    try std.testing.expect(!codeLine("    // yield through Io, not nanosleep"));
    try std.testing.expect(!codeLine("// clock_gettime is confined to sys.zig"));
    try std.testing.expect(!codeLine(""));
    try std.testing.expect(!codeLine("   "));
}
