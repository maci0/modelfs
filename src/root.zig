//! Test aggregator: pulls every module's tests into the test binary.
//! A new src/*.zig file is invisible to `zig build test` until imported here.
test {
    _ = @import("piece.zig");
    _ = @import("rdma.zig");
    _ = @import("proto.zig");
    _ = @import("sys.zig");
    _ = @import("cull.zig");
    _ = @import("fuzzcorpus.zig");
    _ = @import("store.zig");
    _ = @import("discover.zig");
    _ = @import("peer.zig");
    _ = @import("fuse_fs.zig");
    _ = @import("handover.zig");
    _ = @import("hf.zig");
    _ = @import("main.zig");
}
