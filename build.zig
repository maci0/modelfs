const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fuse_inc = b.option([]const u8, "fuse-include", "libfuse3 headers") orelse "/usr/include/fuse3";
    const fuse_lib = b.option([]const u8, "fuse-lib", "libfuse3 library dir");

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
    if (fuse_lib) |dir| {
        exe_mod.addLibraryPath(.{ .cwd_relative = dir });
        exe_mod.linkSystemLibrary("fuse3", .{ .use_pkg_config = .no, .preferred_link_mode = .dynamic });
        exe_mod.linkSystemLibrary("pthread", .{ .use_pkg_config = .no });
    } else {
        exe_mod.linkSystemLibrary("fuse3", .{});
    }
    exe_mod.addIncludePath(.{ .cwd_relative = fuse_inc });

    const exe = b.addExecutable(.{
        .name = "modelfs",
        .root_module = exe_mod,
        .use_llvm = true,
        .use_lld = true,
    });
    b.installArtifact(exe);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (fuse_lib) |dir| {
        test_mod.addLibraryPath(.{ .cwd_relative = dir });
        test_mod.linkSystemLibrary("fuse3", .{ .use_pkg_config = .no, .preferred_link_mode = .dynamic });
        test_mod.linkSystemLibrary("pthread", .{ .use_pkg_config = .no });
    } else {
        test_mod.linkSystemLibrary("fuse3", .{});
    }
    test_mod.addIncludePath(.{ .cwd_relative = fuse_inc });
    test_mod.addImport("c", c_mod);
    const unit = b.addTest(.{
        .name = "modelfs-test",
        .root_module = test_mod,
        .use_llvm = true,
        .use_lld = true,
    });
    const run_unit = b.addRunArtifact(unit);
    b.step("test", "Run unit tests").dependOn(&run_unit.step);
}
