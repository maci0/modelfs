//! Test aggregator: pulls every module's tests into the test binary.
//! A new src/*.zig file is invisible to `zig build test` until imported here.
test {
    _ = @import("piece.zig");
    _ = @import("proto.zig");
    _ = @import("sys.zig");
    _ = @import("store.zig");
    _ = @import("discover.zig");
    _ = @import("peer.zig");
    _ = @import("cull.zig");
    _ = @import("fuse_fs.zig");
    _ = @import("main.zig");
}
