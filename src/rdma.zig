//! RDMA data-plane transport seam for peer piece staging.
//!
//! The control plane (auth, routing, /have, /stage negotiation) stays on
//! HTTP/1.1; the data plane moves 16 MiB pieces through registered memory.
//! This module is the seam between the two: a `Backend` owns registered
//! buffers and exposes stage/read, and the `/stage` window codec is the
//! wire contract between the serving node's staged buffer and the fetching
//! node's read.
//!
//! The shipped backend is the null one: with no verbs device open, /have
//! never advertises `X-Stage`, fetchers never attempt `/stage`, and
//! production behavior is byte-identical to the HTTP-only tree. The
//! in-memory fake exists so the full protocol and pipeline -- serveStage
//! hydration/verification, the window reply, the staged fetch, and the
//! per-piece fallback to `/data` -- run under `zig build test` without
//! verbs hardware. The real verbs tail (libibverbs/rdma_cm QP setup,
//! `ibv_reg_mr`, the RDMA Read, fabric tuning) is design.md section 15.
const std = @import("std");
const piece = @import("piece.zig");

/// Serialized size of one stage window (the /stage 200 body).
/// len u64 + rkey u32 + addr u64 + digest 32.
pub const window_len = 8 + 4 + 8 + piece.digest_len;

/// A staged piece's window into the serving node's registered memory:
/// where the bytes live (addr, rkey, len) and their digest. `addr`/`rkey`
/// are opaque to the protocol -- the backend that produced the window is
/// the one that can read it -- so the fake uses `addr` as its pool index
/// and the future verbs backend uses the registered virtual address.
/// `digest` is advisory on the wire: the fetching node still verifies the
/// bytes it lands against its own trusted digest (expectedHash), never
/// against the serving node's claim.
pub const Window = struct {
    len: u64,
    rkey: u32,
    addr: u64,
    digest: [piece.digest_len]u8,
};

/// Encodes a window into out; exact-size, like the bitfield codec.
pub fn encodeWindow(w: Window, out: []u8) ![]u8 {
    if (out.len < window_len) return error.NoSpaceLeft;
    std.mem.writeInt(u64, out[0..8], w.len, .little);
    std.mem.writeInt(u32, out[8..12], w.rkey, .little);
    std.mem.writeInt(u64, out[12..20], w.addr, .little);
    @memcpy(out[20..][0..piece.digest_len], &w.digest);
    return out[0..window_len];
}

/// Decodes a /stage 200 body (untrusted peer input). Exact length only:
/// a torn reply must not decode half a window, and the fields are opaque
/// to the parser (the backend validates addr/rkey/len at read time).
pub fn decodeWindow(blob: []const u8) ?Window {
    if (blob.len != window_len) return null;
    return .{
        .len = std.mem.readInt(u64, blob[0..8], .little),
        .rkey = std.mem.readInt(u32, blob[8..12], .little),
        .addr = std.mem.readInt(u64, blob[12..20], .little),
        .digest = blob[20..][0..piece.digest_len].*,
    };
}

/// Which backend is wired. `.none` is the shipped state; `.fake` is the
/// in-memory test backend (never constructed outside tests, but harmless
/// in production builds since nothing wires it).
pub const Kind = enum { none, fake };

/// The data-plane backend. One per daemon (see `backend` below); the
/// serving half stages verified piece bytes into registered buffers and
/// the fetching half reads windows back out. All methods are best-effort:
/// null/false means "use the HTTP path", never a hard failure.
pub const Backend = struct {
    kind: Kind = .none,
    /// Allocator for the fake's staged buffers (the verbs tail pins its
    /// own registered memory and never touches this).
    gpa: std.mem.Allocator = undefined,
    /// Fake backend state: staged buffers indexed by Window.addr.
    staged: std.ArrayList([]u8) = .empty,
    /// The fake's bounded pool: at most this many pieces staged at once
    /// (the verbs tail's registered-buffer pool has the same bound).
    fake_cap: usize = 16,
    /// Fake-only: successful window reads (the staged-fetch path), so
    /// tests can tell a staged fetch from the HTTP fallback.
    reads_done: u64 = 0,
    /// Fake-only: stage() attempts, so tests can observe the stage-failure
    /// backoff (a downed peer must stop costing /stage round trips).
    stage_calls: u64 = 0,
    /// Serializes the fake's pool: the serving thread stages while the
    /// fetching thread reads in the e2e tests, and the real verbs pool
    /// must be thread-safe for the same reason. std.atomic.Mutex (not the
    /// Io-cancelable one) because the backend interface carries no io.
    lock: std.atomic.Mutex = .unlocked,

    /// Whether this backend can stage right now (a verbs device is open,
    /// or the fake is wired). /have advertises X-Stage only when true.
    pub fn available(self: *const Backend) bool {
        return switch (self.kind) {
            .none => false,
            .fake => true,
        };
    }

    /// Registers `data` into a registered buffer and returns its window,
    /// or null when no buffer is free. The serving node calls this after
    /// verification: only verified bytes are ever exposed through a window.
    pub fn stage(self: *Backend, data: []const u8, digest: *const [piece.digest_len]u8) ?Window {
        switch (self.kind) {
            .none => return null,
            .fake => {
                lockOrYield(&self.lock);
                defer self.lock.unlock();
                self.stage_calls += 1;
                // Tombstones are empty slices (releaseLocked) so Window.addr
                // stays a stable index. Count live buffers, not the array
                // length: a consumed window must free the slot for the next
                // piece, or the cap is a lifetime limit and every /stage after
                // fake_cap sequential pieces falls back to /data.
                var free_slot: ?usize = null;
                var live: usize = 0;
                for (self.staged.items, 0..) |buf, i| {
                    if (buf.len == 0) {
                        if (free_slot == null) free_slot = i;
                    } else live += 1;
                }
                if (live >= self.fake_cap) return null;
                const own = self.gpa.dupe(u8, data) catch return null;
                const addr: u64 = if (free_slot) |i| blk: {
                    self.staged.items[i] = own;
                    break :blk i;
                } else blk: {
                    self.staged.append(self.gpa, own) catch {
                        self.gpa.free(own);
                        return null;
                    };
                    break :blk self.staged.items.len - 1;
                };
                return .{
                    .len = data.len,
                    .rkey = 1,
                    .addr = addr,
                    .digest = digest.*,
                };
            },
        }
    }

    /// Copies the staged window's bytes into out (the RDMA Read). False on
    /// any failure; the fetching node then falls back to /data. A window
    /// is single-use: a successful read consumes the staged buffer (the
    /// verbs tail would pair release with the fetcher's completion/ACK).
    pub fn read(self: *Backend, window: Window, out: []u8) bool {
        switch (self.kind) {
            .none => return false,
            .fake => {
                lockOrYield(&self.lock);
                defer self.lock.unlock();
                if (window.addr >= self.staged.items.len) return false;
                const buf = self.staged.items[@intCast(window.addr)];
                if (buf.len != out.len or window.len != out.len) return false;
                @memcpy(out, buf);
                self.releaseLocked(window);
                self.reads_done += 1;
                return true;
            },
        }
    }

    /// Consumes a staged buffer without a read (the serving node's reply
    /// failed, or the fetcher gave up). Slots are tombstoned (freed and
    /// set to an empty slice), never reordered: Window.addr is a stable
    /// index, so any number of outstanding windows stay valid regardless
    /// of read/release order -- the pool discipline the verbs tail's
    /// registered-buffer pool must keep for real.
    pub fn release(self: *Backend, window: Window) void {
        switch (self.kind) {
            .none => {},
            .fake => {
                lockOrYield(&self.lock);
                defer self.lock.unlock();
                self.releaseLocked(window);
            },
        }
    }

    /// Caller holds self.lock.
    fn releaseLocked(self: *Backend, window: Window) void {
        if (window.addr >= self.staged.items.len) return;
        const buf = self.staged.items[@intCast(window.addr)];
        if (buf.len == 0) return;
        self.staged.items[@intCast(window.addr)] = &.{};
        self.gpa.free(buf);
    }
};

/// Blocking lock over std.atomic.Mutex's tryLock: the fake pool is
/// contended by the serving and fetching threads in the e2e tests, and
/// std.atomic.Mutex exposes no blocking lock by design.
fn lockOrYield(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.Thread.yield() catch {};
}

/// The daemon's data-plane backend. `.none` until a verbs backend ships;
/// set once at State.init (before any peer/fill thread that reads it
/// exists), swapped for the in-memory fake by tests with a restore on
/// scope exit. Read-only after start.
pub var backend: Backend = .{ .kind = .none };

test "window encode decode round trip" {
    var buf: [window_len]u8 = undefined;
    const w = Window{
        .len = 16,
        .rkey = 0xfeed,
        .addr = 3,
        .digest = [_]u8{0xAB} ** piece.digest_len,
    };
    const blob = try encodeWindow(w, &buf);
    try std.testing.expectEqual(@as(usize, window_len), blob.len);
    const back = decodeWindow(blob).?;
    try std.testing.expectEqual(@as(u64, 16), back.len);
    try std.testing.expectEqual(@as(u32, 0xfeed), back.rkey);
    try std.testing.expectEqual(@as(u64, 3), back.addr);
    try std.testing.expectEqualSlices(u8, &w.digest, &back.digest);
    // Wrong length is not a window (torn reply, or a body that is not ours).
    try std.testing.expect(decodeWindow(blob[0..10]) == null);
    try std.testing.expect(decodeWindow("") == null);
    try std.testing.expectError(error.NoSpaceLeft, encodeWindow(w, buf[0..8]));
}

/// The window body arrives from a peer over the control channel: the
/// harness asserts the codec oracle -- a decoded window must be exactly
/// window_len bytes, and a clean round trip reproduces the fields -- not
/// just crash-freedom.
fn fuzzWindowDecodeOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var blob_buf: [64]u8 = undefined;
    const blob = blob_buf[0..smith.slice(&blob_buf)];
    const w = decodeWindow(blob) orelse return;
    try std.testing.expectEqual(blob.len, window_len);
    // The fields are opaque to the parser, but a round trip must reproduce
    // them exactly (len/rkey/addr are what the backend reads against).
    var out: [window_len]u8 = undefined;
    const enc = try encodeWindow(w, &out);
    try std.testing.expectEqualSlices(u8, blob, enc);
}

test "fuzz window decode honors the codec oracle" {
    var seed: [window_len]u8 = undefined;
    const w = Window{
        .len = 16777216,
        .rkey = 7,
        .addr = 0x1234,
        .digest = [_]u8{0xCD} ** piece.digest_len,
    };
    _ = try encodeWindow(w, &seed);
    try std.testing.fuzz({}, fuzzWindowDecodeOne, .{ .corpus = &.{&seed} });
}

test "fake backend stages and reads one window" {
    const gpa = std.testing.allocator;
    var b: Backend = .{ .kind = .fake, .gpa = gpa };
    defer {
        for (b.staged.items) |buf| gpa.free(buf);
        b.staged.deinit(gpa);
    }
    try std.testing.expect(b.available());
    const data = "0123456789abcdef";
    var d: [piece.digest_len]u8 = undefined;
    piece.digest(data, &d);
    const w = b.stage(data, &d).?;
    try std.testing.expectEqual(@as(u64, 16), w.len);
    var out: [16]u8 = undefined;
    try std.testing.expect(b.read(w, &out));
    try std.testing.expectEqualSlices(u8, data, &out);
    // Single-use: the second read of the same window fails.
    try std.testing.expect(!b.read(w, &out));
    // Windows stay valid across other windows' consumption (regression:
    // swapRemove used to reindex outstanding windows under the reader).
    const d2 = "fedcba9876543210";
    var dg2: [piece.digest_len]u8 = undefined;
    piece.digest(d2, &dg2);
    const wa = b.stage(data, &d).?;
    const wb = b.stage(d2, &dg2).?;
    var out2: [16]u8 = undefined;
    try std.testing.expect(b.read(wa, &out)); // consume the first
    try std.testing.expect(b.read(wb, &out2)); // the second window still lands
    try std.testing.expectEqualSlices(u8, d2, &out2);
    // The null backend stages and reads nothing.
    var none: Backend = .{ .kind = .none };
    try std.testing.expect(!none.available());
    try std.testing.expect(none.stage(data, &d) == null);
    try std.testing.expect(!none.read(w, &out));
    // Pool bound: more stages than the cap refuse cleanly.
    var small: Backend = .{ .kind = .fake, .gpa = gpa, .fake_cap = 1 };
    defer {
        for (small.staged.items) |buf| gpa.free(buf);
        small.staged.deinit(gpa);
    }
    const w_cap = small.stage(data, &d).?;
    try std.testing.expect(small.stage(data, &d) == null);
    // Cap is concurrent occupancy: consuming the window frees the slot
    // so a later piece can stage. A lifetime count would 501 every
    // /stage after fake_cap sequential pieces even with nothing live.
    var out_cap: [16]u8 = undefined;
    try std.testing.expect(small.read(w_cap, &out_cap));
    try std.testing.expectEqualSlices(u8, data, &out_cap);
    const w_reuse = small.stage(data, &d).?;
    try std.testing.expect(small.stage(data, &d) == null);
    try std.testing.expect(small.read(w_reuse, &out_cap));
}
