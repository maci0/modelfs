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
/// Named rather than globbed, because a glob cannot tell the two doors
/// (sys.zig, c.zig) from a module a caller added; the coverage test below
/// holds the list to root.zig's import set so the naming is a reminder,
/// not a chore.
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
    "update.zig",
    "main.zig",
};

/// Modules the scan skips, each for a stated reason. `sys.zig` is the clock
/// and syscall door itself; `c.zig` re-exports the C bindings; this file
/// names the syscalls it searches for, in its pattern tables. A fourth
/// exemption is a hole in the gate, so the list is checked against
/// root.zig's imports below.
const exempt = [_][]const u8{
    "sys.zig",
    "c.zig",
    "determinism.zig",
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

// The clock door holds one exemption from the rule above, and the
// exemption is narrower than the file. Policy instants are the injected
// `std.Io.Clock.now` and its `std.Io.sleep` wait; the single raw
// `std.os.linux.clock_gettime` is sys.zig's own `nowSecRaw`, kept for
// test-scratch directory names, which no simulation replays. A second raw
// read, or any other clock entry point, lands in the one file the scan
// never opened, so it is checked here instead.
test "the clock door itself only samples the injected clock" {
    const io = std.testing.io;
    const src = try readModule(io, "sys.zig");
    defer std.testing.allocator.free(src);
    var raw_reads: usize = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        if (!codeLine(line)) continue;
        const p = firstPattern(line, &clock_patterns) orelse continue;
        if (std.mem.indexOf(u8, line, "std.Io.Clock.now") != null) continue;
        if (std.mem.indexOf(u8, line, "std.Io.sleep") != null) continue;
        if (!std.mem.eql(u8, p, "clock_gettime")) {
            std.debug.print("src/sys.zig: {s}: {s}: the clock door samples the injected clock only\n", .{ line, p });
            return error.ClockDoorLeak;
        }
        raw_reads += 1;
        if (std.mem.indexOf(u8, line, "std.os.linux.clock_gettime") == null) {
            std.debug.print("src/sys.zig: {s}: raw clock read outside nowSecRaw\n", .{line});
            return error.ClockDoorLeak;
        }
    }
    // One, not zero: a helper nobody calls is dead code, and the count is
    // what anchors this test to the read it permits.
    try std.testing.expectEqual(@as(usize, 1), raw_reads);
}

/// The `.zig` module name a source line imports, or null. A module
/// aggregator writes one import per line; a name that does not end in
/// `.zig` is a build-options import, which the scan does not cover.
fn importedModule(line: []const u8) ?[]const u8 {
    const marker = "@import(\"";
    const at = std.mem.indexOf(u8, line, marker) orelse return null;
    const rest = line[at + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const name = rest[0..end];
    if (!std.mem.endsWith(u8, name, ".zig")) return null;
    return name;
}

fn known(name: []const u8) bool {
    for (modules) |m| {
        if (std.mem.eql(u8, m, name)) return true;
    }
    for (exempt) |x| {
        if (std.mem.eql(u8, x, name)) return true;
    }
    return false;
}

// The scan's coverage must be exactly what root.zig imports. A module
// added to the aggregator and forgotten here ships unscanned: the gate
// passes a `clock_gettime` in a file it never opens, which is the exact
// failure these two rules exist to catch. The reverse direction matters
// too, because a typo in `modules` leaves a real module unwatched while
// the test still passes.
test "the scanned module list is exactly what root.zig imports" {
    const io = std.testing.io;
    const src = try readModule(io, "root.zig");
    defer std.testing.allocator.free(src);
    var seen: usize = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        const name = importedModule(line) orelse continue;
        if (std.mem.eql(u8, name, "root.zig")) continue;
        seen += 1;
        if (!known(name)) {
            std.debug.print("src/root.zig imports {s}, which the determinism scan does not cover; add it to modules or exempt it with a reason\n", .{name});
            return error.UnscannedModule;
        }
    }
    // The parse has to have found the aggregator's imports at all, or the
    // checks above pass on an empty walk.
    try std.testing.expect(seen >= modules.len);
    for (modules) |m| {
        if (std.mem.indexOf(u8, src, m) == null) {
            std.debug.print("determinism scan lists {s}, which src/root.zig does not import\n", .{m});
            return error.StaleModule;
        }
    }
}

test "importedModule reads a module name and skips other imports" {
    try std.testing.expectEqualStrings("store.zig", importedModule("    _ = @import(\"store.zig\");").?);
    try std.testing.expect(importedModule("const build_options = @import(\"build_options\");") == null);
    try std.testing.expect(importedModule("const std = @import(\"std\");") == null);
    try std.testing.expect(importedModule("test {") == null);
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
