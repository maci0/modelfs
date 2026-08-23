//! Thin syscall and libc wrappers: fd I/O with EINTR retry, sockets, clocks,
//! and NUL-terminated path helpers. No policy lives here beyond retry rules.
const std = @import("std");
pub const c = @import("c.zig").c;

pub fn errno() i32 {
    return c.__errno_location().*;
}

/// Borrowed name of a readdir entry; valid until the next readdir on its DIR.
pub fn dirName(ent: *c.struct_dirent) []const u8 {
    return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.d_name)), 0);
}

pub fn negErrno() i32 {
    const e = errno();
    return if (e == 0) -1 else -e;
}

/// Wall-clock epoch seconds: for instants shared across processes and
/// machines (cluster lease expiry). Never for elapsed-time math; that is
/// monoSec's job.
pub fn nowSec() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

/// Monotonic seconds: for elapsed-time comparisons within this process only
/// (never persisted, never shared across processes or machines).
pub fn monoSec() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return ts.sec;
}

/// Monotonic milliseconds: elapsed-time comparisons within this process
/// where second resolution is too coarse (short-lived cache TTLs).
pub fn monoMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Monotonic nanoseconds: same clock as monoSec at sub-second precision,
/// for throughput samples over short intervals.
pub fn monoNs() i128 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

pub fn sleepMs(ms: u32) void {
    var ts = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = std.os.linux.nanosleep(&ts, null);
}

pub fn joinZ(buf: []u8, a: []const u8, b: []const u8) ![*:0]u8 {
    if (a.len + b.len + 2 > buf.len) return error.NameTooLong;
    @memcpy(buf[0..a.len], a);
    var n = a.len;
    const b_start: []const u8 = if (b.len > 0 and b[0] == '/') b[1..] else b;
    if (b_start.len > 0) {
        if (n == 0 or buf[n - 1] != '/') {
            buf[n] = '/';
            n += 1;
        }
        @memcpy(buf[n..][0..b_start.len], b_start);
        n += b_start.len;
    }
    // collapse trailing slash except root
    if (n > 1 and buf[n - 1] == '/') n -= 1;
    buf[n] = 0;
    return buf[0..n :0];
}

pub fn realpathAlloc(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var src: [c.PATH_MAX]u8 = undefined;
    const z = try toZ(&src, path);
    var out: [c.PATH_MAX]u8 = undefined;
    const r = std.c.realpath(z, &out) orelse return error.BadPath;
    return gpa.dupe(u8, std.mem.span(r));
}

pub fn toZ(buf: []u8, s: []const u8) ![*:0]u8 {
    if (s.len + 1 > buf.len) return error.NameTooLong;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

/// Appends ext to the NUL-terminated path src, writing base+ext+NUL into
/// buf. One policy for sidecar suffixes (.pieces, .json, .tmp); buf must
/// not alias src.
pub fn appendExt(buf: []u8, src: [*:0]const u8, ext: []const u8) ![*:0]u8 {
    const base = std.mem.span(src);
    if (base.len + ext.len + 1 > buf.len) return error.NameTooLong;
    @memcpy(buf[0..base.len], base);
    @memcpy(buf[base.len..][0..ext.len], ext);
    buf[base.len + ext.len] = 0;
    return buf[0 .. base.len + ext.len :0];
}

pub fn mkdirAll(path: []const u8, mode: c.mode_t) i32 {
    var tmp: [c.PATH_MAX]u8 = undefined;
    if (path.len == 0 or path.len >= tmp.len) return -c.ENAMETOOLONG;
    @memcpy(tmp[0..path.len], path);
    tmp[path.len] = 0;
    var i: usize = if (path[0] == '/') 1 else 0;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/') continue;
        const save = tmp[i];
        tmp[i] = 0;
        const rc = c.mkdir(&tmp, mode);
        if (rc != 0) {
            const e = errno();
            if (e != c.EEXIST) {
                tmp[i] = save;
                return -e;
            }
        }
        tmp[i] = save;
    }
    return 0;
}

pub fn parentOf(path: []const u8) []const u8 {
    if (path.len == 0) return ".";
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    if (end == 0) return "/";
    const slash = std.mem.findScalarLast(u8, path[0..end], '/') orelse return ".";
    if (slash == 0) return "/";
    return path[0..slash];
}

pub fn open(path: [*:0]const u8, flags: c_int, mode: c.mode_t) c_int {
    return c.open(path, flags, mode);
}

pub fn close(fd: c_int) void {
    if (fd >= 0) _ = c.close(fd);
}

pub fn pread(fd: c_int, buf: []u8, off: u64) isize {
    return c.pread(fd, buf.ptr, buf.len, @intCast(off));
}

pub fn pwrite(fd: c_int, buf: []const u8, off: u64) isize {
    return c.pwrite(fd, buf.ptr, buf.len, @intCast(off));
}

pub fn preadAll(fd: c_int, buf: []u8, off: u64) isize {
    var got: usize = 0;
    while (got < buf.len) {
        const n = pread(fd, buf[got..], off + got);
        if (n < 0) {
            // Signal interrupts are retried like readOnce/sendfileAll: a
            // stray signal must not end a multi-chunk transfer midway.
            if (errno() == c.EINTR) continue;
            return n;
        }
        if (n == 0) break;
        got += @intCast(n);
    }
    return @intCast(got);
}

pub fn fadviseDontneed(fd: c_int, off: u64, len: u64) void {
    _ = c.posix_fadvise(fd, @intCast(off), @intCast(len), c.POSIX_FADV_DONTNEED);
}

pub const FALLOC_FL_KEEP_SIZE: c_int = 0x01;
pub const FALLOC_FL_PUNCH_HOLE: c_int = 0x02;

pub fn punchHole(fd: c_int, off: u64, len: u64) i32 {
    const rc = c.fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, @intCast(off), @intCast(len));
    if (rc != 0) return negErrno();
    return 0;
}

pub fn pwriteAll(fd: c_int, buf: []const u8, off: u64) isize {
    var put: usize = 0;
    while (put < buf.len) {
        const n = pwrite(fd, buf[put..], off + put);
        if (n < 0) {
            // Signal interrupts are retried like readOnce/sendfileAll; a
            // partial write must never be mistaken for a completed one.
            if (errno() == c.EINTR) continue;
            return n;
        }
        if (n == 0) return -c.EIO;
        put += @intCast(n);
    }
    return @intCast(put);
}

pub fn sendfileAll(out_fd: c_int, in_fd: c_int, off: u64, count: usize) isize {
    if (@import("builtin").os.tag == .linux) {
        var offset: c.off_t = @intCast(off);
        var sent: usize = 0;
        while (sent < count) {
            const rc = std.c.sendfile(out_fd, in_fd, &offset, count - sent);
            if (rc < 0) {
                const e = errno();
                // Only EINTR is retried. On a blocking out-socket EAGAIN is
                // the SO_SNDTIMEO expiry: retrying would just re-arm another
                // full timeout window and loop forever against a stalled
                // receiver, so surface it like readOnce does.
                if (e == c.EINTR) continue;
                return -e;
            }
            if (rc == 0) break;
            sent += @intCast(rc);
        }
        return @intCast(sent);
    }
    return -c.ENOSYS;
}

pub fn fstat(fd: c_int, st: *c.struct_stat) i32 {
    if (c.fstat(fd, st) != 0) return negErrno();
    return 0;
}

pub fn statPath(path: [*:0]const u8, st: *c.struct_stat) i32 {
    if (c.stat(path, st) != 0) return negErrno();
    return 0;
}

pub fn ftruncate(fd: c_int, size: u64) i32 {
    if (c.ftruncate(fd, @intCast(size)) != 0) return negErrno();
    return 0;
}

pub fn writeAll(fd: c_int, buf: []const u8) isize {
    var put: usize = 0;
    while (put < buf.len) {
        const n = c.write(fd, buf.ptr + put, buf.len - put);
        if (n < 0) {
            // Signal interrupts are retried like readOnce/sendfileAll: a
            // stray signal must not truncate a response or file write midway.
            if (errno() == c.EINTR) continue;
            return n;
        }
        if (n == 0) return -c.EIO;
        put += @intCast(n);
    }
    return @intCast(put);
}

/// One read with EINTR retried and every other failure (SO_RCVTIMEO expiry
/// surfaces as EAGAIN) returned as an error. Socket reads treat any error as
/// connection death.
pub fn readOnce(fd: c_int, buf: []u8) !usize {
    while (true) {
        const n = c.read(fd, buf.ptr, buf.len);
        if (n >= 0) return @intCast(n);
        if (errno() != c.EINTR) return error.Read;
    }
}

fn writeFileFlags(path: [*:0]const u8, data: []const u8, extra_flags: c_int) i32 {
    const fd = open(path, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | extra_flags, 0o644);
    if (fd < 0) return negErrno();
    defer close(fd);
    const n = writeAll(fd, data);
    if (n < 0) return @intCast(n);
    return 0;
}

pub fn writeFile(path: [*:0]const u8, data: []const u8) i32 {
    return writeFileFlags(path, data, 0);
}

/// writeFile for daemon-owned artifact paths (cache data/meta/pin, lease and
/// status staging files). O_NOFOLLOW: a local writer who can plant a symlink
/// at one of those names must not redirect a truncate-and-write onto an
/// arbitrary file as the daemon user.
pub fn writeFileNoFollow(path: [*:0]const u8, data: []const u8) i32 {
    return writeFileFlags(path, data, c.O_NOFOLLOW);
}

pub fn readFileAlloc(gpa: std.mem.Allocator, path: [*:0]const u8, max: usize) ![]u8 {
    const fd = open(path, c.O_RDONLY, 0);
    if (fd < 0) return error.OpenFailed;
    defer close(fd);
    var st: c.struct_stat = undefined;
    if (fstat(fd, &st) != 0) return error.StatFailed;
    const size: usize = @intCast(st.st_size);
    if (size > max) return error.FileTooBig;
    const buf = try gpa.alloc(u8, size);
    errdefer gpa.free(buf);
    const n = preadAll(fd, buf, 0);
    if (n < 0) return error.ReadFailed;
    const got: usize = @intCast(n);
    if (got == size) return buf;
    // Short read (concurrent truncate, flaky NFS): shrink so callers free a
    // slice whose length matches its allocation.
    return gpa.realloc(buf, got) catch return error.OutOfMemory;
}

pub fn readFileBuf(buf: []u8, path: [*:0]const u8) ![]u8 {
    const fd = open(path, c.O_RDONLY, 0);
    if (fd < 0) return error.OpenFailed;
    defer close(fd);
    const n = preadAll(fd, buf, 0);
    if (n < 0) return error.ReadFailed;
    return buf[0..@intCast(n)];
}

pub fn setSockTimeout(fd: c_int, ms: u32) void {
    var tv = c.timeval{
        .tv_sec = @intCast(ms / 1000),
        .tv_usec = @intCast((ms % 1000) * 1000),
    };
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.timeval));
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_SNDTIMEO, &tv, @sizeOf(c.timeval));
}

/// connect(2) with a bounded wait. A blocking connect can sit for minutes on
/// a blackholed peer address; SO_RCVTIMEO/SO_SNDTIMEO do not cover it. The
/// socket is flipped non-blocking for the dial and restored afterwards.
/// Returns 0 on success or a negative errno (-ETIMEDOUT when ms elapses).
pub fn connectIn(fd: c_int, addr: *const c.struct_sockaddr_in, ms: u32) i32 {
    const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (fl < 0) return negErrno();
    if (c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK) < 0) return negErrno();
    const rc = c.connect(fd, .{ .__sockaddr__ = @ptrCast(@constCast(addr)) }, @sizeOf(c.struct_sockaddr_in));
    if (rc == 0) {
        _ = c.fcntl(fd, c.F_SETFL, fl);
        return 0;
    }
    const e0 = errno();
    if (e0 != c.EINPROGRESS) return -e0;
    // EINTR during poll must not fail the dial: retry against the original
    // deadline, like the read/write loops retry their syscalls.
    const deadline = monoNs() + @as(i128, ms) * std.time.ns_per_ms;
    while (true) {
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLOUT, .revents = 0 };
        const remain_ms = @divTrunc(deadline - monoNs(), std.time.ns_per_ms);
        if (remain_ms <= 0) return -c.ETIMEDOUT;
        const wait: c_int = @intCast(@min(remain_ms, @as(i128, std.math.maxInt(c_int))));
        const prc = c.poll(@ptrCast(&pfd), 1, wait);
        if (prc < 0) {
            if (errno() == c.EINTR) continue;
            return negErrno();
        }
        if (prc == 0) return -c.ETIMEDOUT;
        break;
    }
    var soerr: c_int = 0;
    var slen: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &soerr, &slen) != 0) return negErrno();
    if (soerr != 0) return -soerr;
    _ = c.fcntl(fd, c.F_SETFL, fl);
    return 0;
}

pub fn setSockBuffers(fd: c_int, size_bytes: c_int) void {
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVBUF, &size_bytes, @sizeOf(c_int));
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_SNDBUF, &size_bytes, @sizeOf(c_int));
}

pub fn setTcpNoDelay(fd: c_int, enable: bool) void {
    var flag: c_int = @intFromBool(enable);
    _ = c.setsockopt(fd, c.IPPROTO_TCP, c.TCP_NODELAY, &flag, @sizeOf(c_int));
}

/// Best-effort recursive delete for test scratch trees under .zig-cache/tmp.
/// Failures are ignored: a leftover scratch dir pollutes the developer's
/// cache dir across runs but is never a test outcome.
pub fn deleteTree(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

/// Creates a unique throwaway directory for test fixtures:
/// ".zig-cache/tmp/<name>-<unix sec>-<pid>". The pid suffix keeps two test
/// processes starting in the same second from sharing a tree (second-
/// resolution stamps collide otherwise). Returns the path in buf; remove it
/// with deleteTree.
pub fn scratchDir(buf: []u8, name: []const u8) ![]const u8 {
    const p = try std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}-{d}-{d}", .{ name, nowSec(), std.os.linux.getpid() });
    if (mkdirAll(p, 0o755) != 0) return error.MkdirFailed;
    return p;
}

test "joinZ" {
    var buf: [64]u8 = undefined;
    const a = try joinZ(&buf, "/mnt/nas/models", "gguf/foo.gguf");
    try std.testing.expectEqualStrings("/mnt/nas/models/gguf/foo.gguf", std.mem.span(a));
    const b = try joinZ(&buf, "/mnt/nas/models", "");
    try std.testing.expectEqualStrings("/mnt/nas/models", std.mem.span(b));
    const d = try joinZ(&buf, "/mnt/nas/models", "/gguf/foo.gguf");
    try std.testing.expectEqualStrings("/mnt/nas/models/gguf/foo.gguf", std.mem.span(d));
}

test "monoSec never goes backwards" {
    const m0 = monoSec();
    sleepMs(5);
    const m1 = monoSec();
    try std.testing.expect(m1 >= m0);
}

test "parentOf" {
    try std.testing.expectEqualStrings("/a/b", parentOf("/a/b/c"));
    try std.testing.expectEqualStrings("/", parentOf("/a"));
    try std.testing.expectEqualStrings(".", parentOf("c"));
}

test "connectIn succeeds against a local listener" {
    const lfd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (lfd < 0) return error.SkipZigTest;
    defer close(lfd);
    var yes: c_int = 1;
    _ = c.setsockopt(lfd, c.SOL_SOCKET, c.SO_REUSEADDR, &yes, @sizeOf(c_int));
    var addr = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = 0;
    addr.sin_addr.s_addr = std.mem.nativeToBig(u32, 0x7F000001); // 127.0.0.1
    if (c.bind(lfd, .{ .__sockaddr__ = @ptrCast(&addr) }, @sizeOf(c.struct_sockaddr_in)) != 0) return error.SkipZigTest;
    if (c.listen(lfd, 1) != 0) return error.SkipZigTest;
    // Port 0 lets the kernel pick; read the assigned port back before dial.
    var got = std.mem.zeroes(c.struct_sockaddr_in);
    var glen: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
    if (c.getsockname(lfd, .{ .__sockaddr__ = @ptrCast(&got) }, &glen) != 0) return error.SkipZigTest;
    const cfd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    try std.testing.expect(cfd >= 0);
    defer close(cfd);
    try std.testing.expectEqual(@as(i32, 0), connectIn(cfd, &got, 5000));
}

test "connectIn bounds a dead dial" {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SkipZigTest;
    defer close(fd);
    var addr = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = std.mem.nativeToBig(u16, 19999);
    // Unroutable RFC1918 sink: without the bound this dial blocks for the
    // kernel's full TCP timeout. A fast refusal (ENETUNREACH/ECONNREFUSED)
    // also satisfies rc != 0, so sandboxed environments pass either way.
    addr.sin_addr.s_addr = std.mem.nativeToBig(u32, 0x0AFFFFFF); // 10.255.255.255
    const t0 = monoSec();
    const rc = connectIn(fd, &addr, 250);
    try std.testing.expect(rc != 0);
    try std.testing.expect(monoSec() - t0 <= 5);
}

test "sendfileAll zero copy" {
    if (@import("builtin").os.tag == .linux) {
        var path_buf: [128]u8 = undefined;
        var z_buf: [128]u8 = undefined;
        // pid suffix: two test processes starting in the same second must not
        // share the scratch file (second-resolution stamps collide otherwise)
        const p = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/sf-{d}-{d}.tmp", .{ nowSec(), std.os.linux.getpid() });
        const z = try toZ(&z_buf, p);
        const data = "hello zero-copy sendfile world!";
        try std.testing.expectEqual(@as(i32, 0), writeFile(z, data));
        defer _ = c.unlink(z);

        const in_fd = open(z, c.O_RDONLY, 0);
        try std.testing.expect(in_fd >= 0);
        defer close(in_fd);

        var fds: [2]c_int = undefined;
        if (c.pipe(&fds) != 0) return error.Pipe;
        defer close(fds[0]);
        defer close(fds[1]);

        const n = sendfileAll(fds[1], in_fd, 0, data.len);
        try std.testing.expectEqual(@as(isize, @intCast(data.len)), n);

        var buf: [64]u8 = undefined;
        const read_n = c.read(fds[0], &buf, buf.len);
        try std.testing.expectEqual(@as(isize, @intCast(data.len)), read_n);
        try std.testing.expectEqualStrings(data, buf[0..@intCast(read_n)]);
    }
}
