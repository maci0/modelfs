const std = @import("std");

const VendoredFuseDeb = struct {
    /// Relative to the build root, kept comptime-known per entry.
    path: []const u8,
    sha256: []const u8,
};

// Digests recorded in .deps/fuse3-arm64/README.md. Verified before any
// build so the vendored cross-build inputs cannot silently drift.
const vendored_fuse_debs = [_]VendoredFuseDeb{
    .{
        .path = ".deps/fuse3-arm64/libfuse3-3_3.14.0-5build1_arm64.deb",
        .sha256 = "d84990ee2b8e6a079ed6f77d7e5fa1fe70e2462bcf9aecd43f4a65a9ae1486c9",
    },
    .{
        .path = ".deps/fuse3-arm64/libfuse3-dev_3.14.0-5build1_arm64.deb",
        .sha256 = "9a32e4ed3fe950417074d534207d399c5a80ad06843e265ae75a06ba703feafb",
    },
};

fn vendoredFuseMismatch(b: *std.Build) ?[]const u8 {
    for (vendored_fuse_debs) |deb| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            b.graph.io,
            b.pathFromRoot(deb.path),
            b.allocator,
            .limited(8 << 20),
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return std.fmt.allocPrint(
                b.allocator,
                "cannot read vendored input {s}: {t}",
                .{ deb.path, err },
            ) catch @panic("out of memory"),
        };
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const got = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &got, deb.sha256)) {
            return std.fmt.allocPrint(
                b.allocator,
                "vendored libfuse3 integrity check failed for {s}: expected sha256 {s}, got {s}; refresh per .deps/fuse3-arm64/README.md",
                .{ deb.path, deb.sha256, &got },
            ) catch @panic("out of memory");
        }
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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run unit tests");
    if (vendoredFuseMismatch(b)) |msg| {
        const fail = b.addFail(msg);
        b.getInstallStep().dependOn(&fail.step);
        test_step.dependOn(&fail.step);
        return;
    }

    const fuse_inc = b.option([]const u8, "fuse-include", "libfuse3 headers") orelse "/usr/include/fuse3";
    const fuse_lib = b.option([]const u8, "fuse-lib", "libfuse3 library dir");

    // Edit-test loop: substring match on test names, so a contributor working
    // in one module pays for that module's tests, not all of them.
    // zig build test -Dtest-filter=store
    const test_filter = b.option([]const u8, "test-filter", "only run unit tests whose name contains this substring");

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

    // Stack canaries in every mode: Zig enables them by default only in safe
    // modes, so an unhardened -Doptimize=ReleaseFast ship build would link
    // without any. Debug info stays on for Debug development but is stripped
    // from anything shippable: DWARF records absolute build paths
    // (DW_AT_comp_dir), which is what makes two builds of the same tree from
    // different directories produce different bytes.
    exe_mod.stack_protector = true;
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
    b.installArtifact(exe);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // Exercise the same canary-instrumented code the executable ships.
        .stack_protector = true,
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
