const std = @import("std");

fn allocPrint(b: *std.Build, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(b.allocator, fmt, args) catch @panic("out of memory");
}

fn isLowerHex(s: []const u8) bool {
    for (s) |ch| {
        const ok = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f');
        if (!ok) return false;
    }
    return true;
}

/// Digests in `.deps/fuse3-arm64/SHA256SUMS` (the same list
/// `scripts/extract_fuse3_arm64.sh` checks). Verified before any compile so
/// the vendored cross-build inputs cannot silently drift. Absent SHA256SUMS
/// (Zig package consumers: `.deps` is not in `build.zig.zon` `.paths`) skips
/// the check; a present file with no entries, a missing listed .deb, or a
/// digest mismatch fails the build.
fn vendoredFuseMismatch(b: *std.Build) ?[]const u8 {
    const sums_rel = ".deps/fuse3-arm64/SHA256SUMS";
    const sums = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        b.pathFromRoot(sums_rel),
        b.allocator,
        .limited(64 << 10),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return allocPrint(b, "cannot read {s}: {t}", .{ sums_rel, err }),
    };

    var saw_entry = false;
    var rest: []const u8 = sums;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const raw = rest[0..nl];
        rest = if (nl < rest.len) rest[nl + 1 ..] else rest[rest.len..];
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line.len < 66) {
            return allocPrint(b, "{s}: malformed line (need sha256 and filename)", .{sums_rel});
        }
        const hex = line[0..64];
        if (!isLowerHex(hex)) {
            return allocPrint(b, "{s}: malformed digest (need 64 lowercase hex chars)", .{sums_rel});
        }
        var name = std.mem.trim(u8, line[64..], " \t");
        if (name.len > 0 and name[0] == '*') name = std.mem.trim(u8, name[1..], " \t");
        if (name.len == 0 or
            std.mem.indexOfScalar(u8, name, '/') != null or
            std.mem.eql(u8, name, ".") or
            std.mem.eql(u8, name, ".."))
        {
            return allocPrint(b, "{s}: illegal filename (must be a basename in .deps/fuse3-arm64/)", .{sums_rel});
        }

        saw_entry = true;
        const rel = allocPrint(b, ".deps/fuse3-arm64/{s}", .{name});
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            b.graph.io,
            b.pathFromRoot(rel),
            b.allocator,
            .limited(8 << 20),
        ) catch |err| return allocPrint(
            b,
            "cannot read vendored input {s}: {t}",
            .{ rel, err },
        );
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const got = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &got, hex)) {
            return allocPrint(
                b,
                "vendored libfuse3 integrity check failed for {s}: expected sha256 {s}, got {s}; refresh per .deps/fuse3-arm64/README.md",
                .{ rel, hex, &got },
            );
        }
    }
    if (!saw_entry) {
        return allocPrint(b, "{s} lists no files", .{sums_rel});
    }
    return null;
}

/// Preflight for the most common first-build failure: without the libfuse3
/// headers, translate-c fails with a clang "file not found" buried in compile
/// noise. Name the missing package and the escape hatch instead.
fn fuseHeadersMissing(b: *std.Build, fuse_inc: []const u8) ?[]const u8 {
    std.Io.Dir.cwd().access(b.graph.io, fuse_inc, .{}) catch |err| {
        // Unreadable for any other reason: let translate-c report what it sees.
        if (err != error.FileNotFound) return null;
        return std.fmt.allocPrint(
            b.allocator,
            "libfuse3 headers not found at {s}: install them from your package manager (libfuse3-dev on Debian/Ubuntu, fuse3-devel on Fedora/RHEL), or pass -Dfuse-include=<dir> if they live elsewhere",
            .{fuse_inc},
        ) catch @panic("out of memory");
    };
    return null;
}

/// One libfuse3 link contract for the executable and the test binary alike:
/// an explicit -Dfuse-lib dir (cross builds, pkg-config disabled) or the
/// system default.
fn linkFuse(m: *std.Build.Module, fuse_lib: ?[]const u8) void {
    if (fuse_lib) |dir| {
        m.addLibraryPath(.{ .cwd_relative = dir });
        m.linkSystemLibrary("fuse3", .{ .use_pkg_config = .no, .preferred_link_mode = .dynamic });
        m.linkSystemLibrary("pthread", .{ .use_pkg_config = .no });
    } else {
        m.linkSystemLibrary("fuse3", .{});
    }
}

/// Fail `zig build` / `zig build test` unless the shipped ELF is a PIE with
/// full RELRO, BIND_NOW, and a non-executable stack. Linking the executable
/// as part of the test step also compiles `pub fn main`, which the test
/// binary does not reference.
fn checkHardenedElf(exe: *std.Build.Step.Compile) *std.Build.Step {
    const check = exe.checkObject();
    // Debug images can exceed CheckObject's 20 MiB default; headers+phdrs
    // still fit, but the step reads the whole file.
    check.max_bytes = 64 * 1024 * 1024;
    check.checkInHeaders();
    check.checkExact("type DYN");
    check.checkInHeaders();
    check.checkExact("type GNU_RELRO");
    check.checkInHeaders();
    check.checkExact("type GNU_STACK");
    check.checkExact("flags RW");
    check.checkInDynamicSection();
    check.checkContains("NOW");
    check.checkInDynamicSection();
    check.checkContains("PIE");
    return &check.step;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Zig 0.16 implements stack probing only for the x86 family; requesting
    // it on aarch64 (the Sparks' deploy ABI) fails the compile, so gate on
    // the arch rather than forcing every target through an unsupported flag.
    const stack_check_supported = target.result.cpu.arch == .x86 or target.result.cpu.arch == .x86_64;

    // Registered before the libfuse3 preflight so `zig build --help`,
    // `zig build fmt`, and the check/ci wrappers still work on a machine
    // that cannot compile yet.
    const fmt_step = b.step("fmt", "Format Zig sources in place");
    fmt_step.dependOn(&b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } }).step);

    const check_cmd = b.addSystemCommand(&.{"./scripts/check.sh"});
    check_cmd.setCwd(b.path("."));
    const check_step = b.step("check", "Run the static gate (scripts/check.sh)");
    check_step.dependOn(&check_cmd.step);

    const ci_cmd = b.addSystemCommand(&.{"./scripts/ci.sh"});
    ci_cmd.setCwd(b.path("."));
    const ci_step = b.step("ci", "Run every CI job locally (scripts/ci.sh)");
    ci_step.dependOn(&ci_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    if (vendoredFuseMismatch(b)) |msg| {
        const fail = b.addFail(msg);
        b.getInstallStep().dependOn(&fail.step);
        test_step.dependOn(&fail.step);
        return;
    }

    const fuse_inc = b.option([]const u8, "fuse-include", "libfuse3 headers") orelse "/usr/include/fuse3";
    const fuse_lib = b.option([]const u8, "fuse-lib", "libfuse3 library dir");

    // Edit-test loop: substring match on test *names* (Zig collects tests
    // from the whole import graph, so a file name is not a filter). A
    // distinctive fragment like relOk or cacheFill keeps the loop short.
    // zig build test -Dtest-filter=relOk
    const test_filter = b.option([]const u8, "test-filter", "only run unit tests whose name contains this substring");

    // Options are registered above so `zig build --help` still lists them
    // when this early-return fires. Linux is the only claimed OS: FUSE3,
    // sendfile, fallocate hole-punch, and accept4. A non-Linux target used
    // to proceed into translate-c / std.os.linux and die on missing headers
    // or glibc-only sockaddr unions.
    if (target.result.os.tag != .linux) {
        const fail = b.addFail("modelfs is Linux-only (libfuse3, sendfile, FUSE)");
        b.getInstallStep().dependOn(&fail.step);
        test_step.dependOn(&fail.step);
        return;
    }

    if (fuseHeadersMissing(b, fuse_inc)) |msg| {
        const fail = b.addFail(msg);
        b.getInstallStep().dependOn(&fail.step);
        test_step.dependOn(&fail.step);
        return;
    }

    // `modelfs version` reports the release from build.zig.zon, the single
    // source of truth; extracted here because 0.16 exposes no graph API for it.
    const version_mod = blk: {
        const zon = std.Io.Dir.cwd().readFileAlloc(
            b.graph.io,
            b.pathFromRoot("build.zig.zon"),
            b.allocator,
            .limited(1 << 20),
        ) catch @panic("cannot read build.zig.zon");
        const marker = ".version = \"";
        const start = std.mem.indexOf(u8, zon, marker) orelse @panic("no .version in build.zig.zon");
        const rest = zon[start + marker.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse @panic("unterminated .version in build.zig.zon");
        const opts = b.addOptions();
        opts.addOption([]const u8, "version", zon[start + marker.len .. start + marker.len + end]);
        break :blk opts.createModule();
    };

    // @cImport is deprecated in 0.16: C interop moves to the build system.
    // src/c.h + these macros reproduce the former @cImport block verbatim.
    const tc = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tc.defineCMacro("_GNU_SOURCE", "1");
    tc.defineCMacro("FUSE_USE_VERSION", "31");
    tc.defineCMacro("_FILE_OFFSET_BITS", "64");
    tc.addIncludePath(.{ .cwd_relative = fuse_inc });
    const c_mod = tc.createModule();

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("c", c_mod);
    exe_mod.addImport("build_options", version_mod);
    linkFuse(exe_mod, fuse_lib);
    exe_mod.addIncludePath(.{ .cwd_relative = fuse_inc });

    // Stack canaries and stack probes in every mode: Zig enables both by
    // default only in safe modes, so an unhardened -Doptimize=ReleaseFast
    // ship build would link without either. Debug info stays on for Debug
    // development but is stripped from anything shippable: DWARF records
    // absolute build paths (DW_AT_comp_dir), which is what makes two builds
    // of the same tree from different directories produce different bytes.
    // Stack probing exists only for the x86 family in 0.16: aarch64 and
    // other targets reject -fstack-check, and the Sparks deploy as aarch64,
    // so the cross-build must not request it. Canaries are supported
    // wherever libc is present, so they stay on for every target.
    exe_mod.stack_protector = true;
    if (stack_check_supported) {
        exe_mod.stack_check = true;
    }
    if (optimize != .Debug) {
        exe_mod.strip = true;
    }

    const exe = b.addExecutable(.{
        .name = "modelfs",
        .root_module = exe_mod,
        .use_llvm = true,
        .use_lld = true,
    });
    // ASLR for the main image: without this Zig links ET_EXEC, so the
    // long-lived networked daemon runs at a fixed address.
    exe.pie = true;
    // Zig already defaults these on; pin them so a default flip cannot ship
    // a lazy-binding or partial-RELRO networked image.
    exe.link_z_relro = true;
    exe.link_z_lazy = false;
    b.installArtifact(exe);

    if (target.result.ofmt == .elf) {
        const hardening = checkHardenedElf(exe);
        b.getInstallStep().dependOn(hardening);
        test_step.dependOn(hardening);
    }

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // Exercise the same canary- and probe-instrumented code the executable ships.
        .stack_protector = true,
        .stack_check = stack_check_supported,
    });
    linkFuse(test_mod, fuse_lib);
    test_mod.addIncludePath(.{ .cwd_relative = fuse_inc });
    test_mod.addImport("c", c_mod);
    test_mod.addImport("build_options", version_mod);
    const unit = b.addTest(.{
        .name = "modelfs-test",
        .root_module = test_mod,
        .use_llvm = true,
        .use_lld = true,
        .filters = if (test_filter) |f| &.{f} else &.{},
    });
    const run_unit = b.addRunArtifact(unit);
    test_step.dependOn(&run_unit.step);
}
