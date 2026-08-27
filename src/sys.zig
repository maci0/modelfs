//! Thin syscall and libc wrappers: fd I/O with EINTR retry, sockets, clocks,
//! and NUL-terminated path helpers. No policy lives here beyond retry rules.
const std = @import("std");
pub const c = @import("c.zig").c;

pub fn errno() i32 {
    // std.c._errno is the libc thread-local errno pointer on every Linux
    // ABI Zig ships (glibc __errno_location, musl the same name, Android
    // __errno). translate-c of errno.h only exports the glibc spelling.
    return std.c._errno().*;
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
/// monoSec's job. Sampled through `io` so a simulator substitutes a virtual
/// clock; production Threaded Io reads CLOCK_REALTIME.
pub fn nowSec(io: std.Io) i64 {
    return std.Io.Clock.now(.real, io).toSeconds();
}

/// Monotonic seconds: elapsed-time comparisons on this machine
/// (CLOCK_MONOTONIC is comparable across processes, not across reboots or
/// hosts). Sampled through `io` (CLOCK_MONOTONIC via Clock.awake) so recency,
/// reap, fill stamps, and status.json's `mono_s` stay a function of the
/// injected clock.
pub fn monoSec(io: std.Io) i64 {
    return std.Io.Clock.now(.awake, io).toSeconds();
}

/// Monotonic milliseconds: elapsed-time comparisons within this process
/// where second resolution is too coarse (short-lived cache TTLs, peer
/// transfer budgets). Same injected clock as monoSec.
pub fn monoMs(io: std.Io) i64 {
    return std.Io.Clock.now(.awake, io).toMilliseconds();
}

/// Monotonic nanoseconds: same clock as monoSec at sub-second precision,
/// for throughput samples over short intervals.
pub fn monoNs(io: std.Io) i128 {
    return @intCast(std.Io.Clock.now(.awake, io).toNanoseconds());
}

/// Relative sleep on the injected clock. A simulator's Io can elide the
/// wait; production Threaded Io blocks for `ms` of CLOCK_MONOTONIC time.
/// Cancelation is ignored: these sleeps are shutdown-sliced waits and
/// fill-claim yields, not cancelable tasks.
pub fn sleepMs(io: std.Io, ms: u32) void {
    std.Io.sleep(io, .fromMilliseconds(ms), .awake) catch {};
}

/// Kernel CLOCK_MONOTONIC nanoseconds for syscall wrappers that implement
/// their own timeout (connectIn). Policy clocks go through nowSec/monoSec
/// and `io`; this is the I/O primitive, not a decision instant.
fn monoNsRaw() i128 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

/// Kernel CLOCK_REALTIME seconds for test-scratch uniqueness (pid-colliding
/// names). Not a policy instant: scratch dirs are not simulated.
fn nowSecRaw() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
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

/// mkdir -p: create every component, treating an existing directory as
/// success so a second run converges. EEXIST is not enough: a planted file
/// or symlink at a component used to make this return 0 while callers
/// believed the tree was in place. A file is ENOTDIR; a symlink is ELOOP
/// (same fail-closed as the O_NOFOLLOW artifact opens).
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
            var st: c.struct_stat = undefined;
            const lst = lstatPath(tmp[0..i :0], &st);
            if (lst != 0) {
                tmp[i] = save;
                return lst;
            }
            const kind = st.st_mode & c.S_IFMT;
            if (kind == c.S_IFLNK) {
                tmp[i] = save;
                return -c.ELOOP;
            }
            if (kind != c.S_IFDIR) {
                tmp[i] = save;
                return -c.ENOTDIR;
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

/// Every daemon-owned file is close-on-exec. libfuse's auto_unmount helper
/// is spawned from fuse_main after bindAll, and without O_CLOEXEC it would
/// inherit cache and origin fds for the life of the mount.
pub fn open(path: [*:0]const u8, flags: c_int, mode: c.mode_t) c_int {
    return c.open(path, flags | c.O_CLOEXEC, mode);
}

/// Peer-protocol TCP sockets (listen and dial). SOCK_CLOEXEC is set here so
/// the auto_unmount fusermount helper cannot inherit the listen fd bindAll
/// opens before fuse_main: a helper holding that fd keeps the port bound
/// after Server.stop, and the next start fails Bind.
pub fn socket(domain: c_int, type_: c_int, protocol: c_int) c_int {
    return c.socket(domain, type_ | c.SOCK_CLOEXEC, protocol);
}

/// Accept with SOCK_CLOEXEC (accept4). Same inherit contract as socket.
pub fn accept(listen_fd: c_int, peer: *c.struct_sockaddr_in) c_int {
    var peer_len: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
    return c.accept4(listen_fd, .{ .__sockaddr__ = @ptrCast(peer) }, &peer_len, c.SOCK_CLOEXEC);
}

pub fn close(fd: c_int) void {
    if (fd >= 0) _ = c.close(fd);
}

/// Close a write fd and return whether deallocation succeeded. NFS reports
/// delayed write errors here; ignoring them would turn a failed ingest into
/// a successful FUSE write over missing bytes. Linux still closes the
/// descriptor when close reports EINTR, so that result is success (retrying
/// would close a different fd).
pub fn closeWrite(fd: c_int) i32 {
    if (fd < 0) return 0;
    if (c.close(fd) == 0) return 0;
    const e = errno();
    if (e == c.EINTR) return 0;
    return if (e == 0) -1 else -e;
}

/// Refuse core dumps for this process. The cluster PSK lives in daemon
/// memory for the mount lifetime; a crash would otherwise write it
/// wherever kernel.core_pattern points (often a world-readable file).
/// Both soft and hard limits go to zero so a later setrlimit in this
/// process cannot raise them without CAP_SYS_RESOURCE. Failure is
/// returned so mount can refuse to keep the secret in a dumpable process.
pub fn disableCoreDumps() !void {
    std.posix.setrlimit(.CORE, .{ .cur = 0, .max = 0 }) catch |err| {
        std.log.err("cannot disable core dumps ({t}); a crash may write the cluster PSK", .{err});
        return err;
    };
}

/// Drops MODELFS_PSK_VALUE from the process environment so the
/// auto_unmount fusermount helper (spawned from fuse_main) and
/// /proc/<pid>/environ cannot inherit the inline secret. The daemon
/// already holds its own copy from loadPsk.
pub fn scrubPskEnv() void {
    _ = c.unsetenv("MODELFS_PSK_VALUE");
}

/// `stat.st_size` is signed off_t. NFS fattr is u64, so a size of 2^63 or
/// more shows up negative here; `@intCast` into piece/cache math panics in
/// safe builds and wraps to a multi-exabyte length in ReleaseFast.
pub fn sizeFromStat(st_size: c.off_t) ?u64 {
    if (st_size < 0) return null;
    return @intCast(st_size);
}

/// Kernel file offsets are signed. A u64 that does not fit must not become
/// a truncated (often negative) off_t: that would pread/pwrite/ftruncate
/// at the wrong address instead of failing the op.
fn offT(n: u64) ?c.off_t {
    return std.math.cast(c.off_t, n);
}

pub fn preadAll(fd: c_int, buf: []u8, off: u64) isize {
    var got: usize = 0;
    while (got < buf.len) {
        const pos = offT(off +| got) orelse return -c.EFBIG;
        const n = c.pread(fd, buf[got..].ptr, buf.len - got, pos);
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
    const o = offT(off) orelse return;
    const n = offT(len) orelse return;
    _ = c.posix_fadvise(fd, o, n, c.POSIX_FADV_DONTNEED);
}

pub fn punchHole(fd: c_int, off: u64, len: u64) i32 {
    const o = offT(off) orelse return -c.EFBIG;
    const n = offT(len) orelse return -c.EFBIG;
    const rc = c.fallocate(fd, c.FALLOC_FL_PUNCH_HOLE | c.FALLOC_FL_KEEP_SIZE, o, n);
    if (rc != 0) return negErrno();
    return 0;
}

pub fn pwriteAll(fd: c_int, buf: []const u8, off: u64) isize {
    var put: usize = 0;
    while (put < buf.len) {
        const pos = offT(off +| put) orelse return -c.EFBIG;
        const n = c.pwrite(fd, buf[put..].ptr, buf.len - put, pos);
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
    var offset = offT(off) orelse return -c.EFBIG;
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

pub fn fstat(fd: c_int, st: *c.struct_stat) i32 {
    if (c.fstat(fd, st) != 0) return negErrno();
    return 0;
}

pub fn statPath(path: [*:0]const u8, st: *c.struct_stat) i32 {
    if (c.stat(path, st) != 0) return negErrno();
    return 0;
}

/// stat(2) without following a final symlink. Walks over attacker-writable
/// trees (the cache data dir) must sample what the NAME names, not what a
/// planted symlink points at; intermediate components still resolve, which
/// is why walkers combine this with their own depth cap and treat S_IFLNK
/// entries as skippable.
pub fn lstatPath(path: [*:0]const u8, st: *c.struct_stat) i32 {
    if (c.fstatat(c.AT_FDCWD, path, st, c.AT_SYMLINK_NOFOLLOW) != 0) return negErrno();
    return 0;
}

pub fn statvfsPath(path: [*:0]const u8, vs: *c.struct_statvfs) i32 {
    if (c.statvfs(path, vs) != 0) return negErrno();
    return 0;
}

pub fn mkdir(path: [*:0]const u8, mode: c.mode_t) i32 {
    if (c.mkdir(path, mode) != 0) return negErrno();
    return 0;
}

pub fn rmdir(path: [*:0]const u8) i32 {
    if (c.rmdir(path) != 0) return negErrno();
    return 0;
}

pub fn chmod(path: [*:0]const u8, mode: c.mode_t) i32 {
    if (c.chmod(path, mode) != 0) return negErrno();
    return 0;
}

pub fn rename(old_path: [*:0]const u8, new_path: [*:0]const u8) i32 {
    if (c.rename(old_path, new_path) != 0) return negErrno();
    return 0;
}

pub fn ftruncate(fd: c_int, size: u64) i32 {
    const off = offT(size) orelse return -c.EFBIG;
    if (c.ftruncate(fd, off) != 0) return negErrno();
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

/// Writes data at path; when `durable` is set, fsyncs before close so a
/// later destructive step keyed to the same name cannot be reordered ahead
/// of these bytes by delayed allocation across a power loss. `mode` is the
/// create mode and is fchmod'd onto the fd: O_CREAT ignores mode when the
/// name already exists, and umask would otherwise strip bits from a new file.
fn writeFileFull(path: [*:0]const u8, data: []const u8, extra_flags: c_int, durable: bool, mode: c.mode_t) i32 {
    const fd = open(path, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | extra_flags, mode);
    if (fd < 0) return negErrno();
    _ = c.fchmod(fd, mode);
    const n = writeAll(fd, data);
    if (n < 0) {
        _ = closeWrite(fd);
        return @intCast(n);
    }
    if (durable) {
        while (true) {
            // libc fsync: a raw linux.fsync return is a usize with -errno
            // in the high bits, which does not fit i32 and so cannot be
            // compared to EINTR (the retry would panic in safe builds and
            // skip in ReleaseFast).
            if (c.fsync(fd) == 0) break;
            const e = errno();
            if (e != c.EINTR) {
                _ = closeWrite(fd);
                return -e;
            }
        }
    }
    return closeWrite(fd);
}

pub fn writeFile(path: [*:0]const u8, data: []const u8) i32 {
    return writeFileFull(path, data, 0, false, 0o644);
}

/// writeFile for daemon-owned artifact paths (cache data/meta/pin, lease
/// staging files). O_NOFOLLOW: a local writer who can plant a symlink
/// at one of those names must not redirect a truncate-and-write onto an
/// arbitrary file as the daemon user. `status.json` uses writeFileOwnerOnly.
pub fn writeFileNoFollow(path: [*:0]const u8, data: []const u8) i32 {
    return writeFileFull(path, data, c.O_NOFOLLOW, false, 0o644);
}

/// writeFileNoFollow plus fsync-before-close: for artifact writes whose
/// durability orders them against a later destructive step on the same key
/// (the bitfield cleared ahead of a hole punch).
pub fn writeFileDurable(path: [*:0]const u8, data: []const u8) i32 {
    return writeFileFull(path, data, c.O_NOFOLLOW, true, 0o644);
}

/// writeFileNoFollow at 0600. For cache-root artifacts that sit next to a
/// world-searchable directory (`status.json`): a local uid that can search
/// the cache root must not read operational state. Leftover 0644 files are
/// tightened on the fd that was written, the same leftover-open as cache data.
pub fn writeFileOwnerOnly(path: [*:0]const u8, data: []const u8) i32 {
    return writeFileFull(path, data, c.O_NOFOLLOW, false, 0o600);
}

pub fn readFileAlloc(gpa: std.mem.Allocator, path: [*:0]const u8, max: usize) ![]u8 {
    return readFileAllocOpenErrno(gpa, path, max, null, null);
}

/// readFileAlloc plus the failing open's errno written through open_errno_out
/// (when non-null), so callers can separate ENOENT from EACCES-style
/// conditions instead of reporting one generic cause for every open failure.
/// Follows a final symlink: for operator-specified paths (the PSK file) that
/// are commonly a link into a secrets volume. Daemon-owned artifacts in
/// trees someone else can plant names in use the NoFollow form.
/// `mode_out`, when set, is the fstat mode of the fd that was read, so a
/// permission check cannot race a path-stat of a different inode.
pub fn readFileAllocOpenErrno(gpa: std.mem.Allocator, path: [*:0]const u8, max: usize, open_errno_out: ?*i32, mode_out: ?*c.mode_t) ![]u8 {
    return readFileAllocFlags(gpa, path, max, 0, open_errno_out, mode_out);
}

/// readFileAllocOpenErrno for daemon-owned artifacts (cache sidecars,
/// status.json, origin leases). O_NOFOLLOW: a planted symlink must not turn
/// the read into an arbitrary file as the daemon user, or load a crafted
/// sidecar/lease from outside the tree.
pub fn readFileAllocNoFollowOpenErrno(gpa: std.mem.Allocator, path: [*:0]const u8, max: usize, open_errno_out: ?*i32) ![]u8 {
    return readFileAllocFlags(gpa, path, max, c.O_NOFOLLOW, open_errno_out, null);
}

fn readFileAllocFlags(gpa: std.mem.Allocator, path: [*:0]const u8, max: usize, extra_flags: c_int, open_errno_out: ?*i32, mode_out: ?*c.mode_t) ![]u8 {
    const fd = open(path, c.O_RDONLY | extra_flags, 0);
    if (fd < 0) {
        if (open_errno_out) |out| out.* = errno();
        return error.OpenFailed;
    }
    defer close(fd);
    var st: c.struct_stat = undefined;
    if (fstat(fd, &st) != 0) return error.StatFailed;
    if (mode_out) |out| out.* = st.st_mode;
    const n64 = sizeFromStat(st.st_size) orelse return error.StatFailed;
    const size = std.math.cast(usize, n64) orelse return error.FileTooBig;
    if (size > max) return error.FileTooBig;
    const buf = try gpa.alloc(u8, size);
    errdefer gpa.free(buf);
    const n = preadAll(fd, buf, 0);
    if (n < 0) return error.ReadFailed;
    const got: usize = @intCast(n);
    if (got == size) return buf;
    // Short read (concurrent truncate, flaky NFS): shrink so callers free a
    // slice whose length matches its allocation.
    return gpa.realloc(buf, got) catch {
        gpa.free(buf);
        return error.OutOfMemory;
    };
}

pub fn readFileBuf(buf: []u8, path: [*:0]const u8) ![]u8 {
    return readFileBufFlags(buf, path, 0, null);
}

/// readFileBuf with O_NOFOLLOW: origin lease files live on shared NFS where
/// a co-tenant can plant a symlink at a .json name. The failing open's
/// errno is written through open_errno_out (when non-null) so callers can
/// stay silent for the expected ENOENT race while naming every other open
/// failure, like readFileAllocOpenErrno does.
pub fn readFileBufNoFollowOpenErrno(buf: []u8, path: [*:0]const u8, open_errno_out: ?*i32) ![]u8 {
    return readFileBufFlags(buf, path, c.O_NOFOLLOW, open_errno_out);
}

fn readFileBufFlags(buf: []u8, path: [*:0]const u8, extra_flags: c_int, open_errno_out: ?*i32) ![]u8 {
    const fd = open(path, c.O_RDONLY | extra_flags, 0);
    if (fd < 0) {
        if (open_errno_out) |out| out.* = errno();
        return error.OpenFailed;
    }
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
    const deadline = monoNsRaw() + @as(i128, ms) * std.time.ns_per_ms;
    while (true) {
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLOUT, .revents = 0 };
        const remain_ms = @divTrunc(deadline - monoNsRaw(), std.time.ns_per_ms);
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

fn dottedQuad(out_ip: []u8, s_addr_be: u32) ?[]const u8 {
    const raw = std.mem.bigToNative(u32, s_addr_be);
    return std.fmt.bufPrint(out_ip, "{d}.{d}.{d}.{d}", .{
        @as(u8, @truncate(raw >> 24)),
        @as(u8, @truncate(raw >> 16)),
        @as(u8, @truncate(raw >> 8)),
        @as(u8, @truncate(raw)),
    }) catch null;
}

fn numericIpv4Host(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (ch != '.' and (ch < '0' or ch > '9')) return false;
    }
    return true;
}

/// Resolves a host name to its first IPv4 address, writing the dotted quad
/// into out_ip. Numeric dotted quads go through inet_pton (no DNS, no
/// AI_ADDRCONFIG). Null when resolution fails or yields no IPv4 address;
/// the peer dial path only accepts dotted quads (inet_pton), so callers
/// that accept host names must convert here or the address dies silently
/// later.
pub fn resolveIpv4(host: []const u8, out_ip: []u8) ?[]const u8 {
    var hz: [256]u8 = undefined;
    const h = toZ(&hz, host) catch return null;
    var addr: c.struct_in_addr = undefined;
    if (c.inet_pton(c.AF_INET, h, &addr) == 1) {
        return dottedQuad(out_ip, addr.s_addr);
    }
    // Digits-and-dots that inet_pton refused (leading zeros, 256, ...)
    // must not fall through to getaddrinfo: glibc may accept spellings
    // the dialer's inet_pton later rejects.
    if (numericIpv4Host(host)) return null;

    var hints: c.struct_addrinfo = std.mem.zeroes(c.struct_addrinfo);
    hints.ai_family = c.AF_INET;
    hints.ai_socktype = c.SOCK_STREAM;
    // No AI_ADDRCONFIG: that flag skips IPv4 when the only configured
    // address is loopback, so --seed HOST would fail on a loopback-only
    // or IPv6-first host. AF_INET already restricts the family.
    var res: [*c]c.struct_addrinfo = null;
    if (c.getaddrinfo(h, null, &hints, &res) != 0) return null;
    defer c.freeaddrinfo(res);
    var it: [*c]c.struct_addrinfo = res;
    while (it != null) : (it = it.*.ai_next) {
        if (it.*.ai_family != c.AF_INET) continue;
        if (it.*.ai_addrlen < @sizeOf(c.struct_sockaddr_in)) continue;
        const sin: *const c.struct_sockaddr_in = @ptrCast(@alignCast(it.*.ai_addr));
        return dottedQuad(out_ip, sin.sin_addr.s_addr);
    }
    return null;
}

pub fn setTcpNoDelay(fd: c_int) void {
    var flag: c_int = 1;
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
    const p = try std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}-{d}-{d}", .{ name, nowSecRaw(), std.os.linux.getpid() });
    if (mkdirAll(p, 0o755) != 0) return error.MkdirFailed;
    return p;
}

test "mkdirAll twice converges and refuses a file or symlink at the name" {
    var db: [128]u8 = undefined;
    const scratch = try scratchDir(&db, "modelfs-mkdirall");
    defer deleteTree(std.testing.io, scratch);

    var zb: [192]u8 = undefined;
    const dir = try std.fmt.bufPrint(&zb, "{s}/a/b", .{scratch});
    try std.testing.expectEqual(@as(i32, 0), mkdirAll(dir, 0o755));
    try std.testing.expectEqual(@as(i32, 0), mkdirAll(dir, 0o755));

    var fb: [192]u8 = undefined;
    var fz: [192]u8 = undefined;
    const file = try std.fmt.bufPrint(&fb, "{s}/a/b/file", .{scratch});
    try std.testing.expectEqual(@as(i32, 0), writeFile(try toZ(&fz, file), "x"));
    try std.testing.expectEqual(@as(i32, -c.ENOTDIR), mkdirAll(file, 0o755));

    var lb: [192]u8 = undefined;
    var lz: [192]u8 = undefined;
    const link = try std.fmt.bufPrint(&lb, "{s}/planted", .{scratch});
    try std.testing.expectEqual(@as(i32, 0), c.symlink("a", try toZ(&lz, link)));
    try std.testing.expectEqual(@as(i32, -c.ELOOP), mkdirAll(link, 0o755));
}

test "errno follows a failed libc call" {
    try std.testing.expectEqual(@as(c_int, -1), c.close(-1));
    try std.testing.expectEqual(@as(i32, c.EBADF), errno());
}

test "closeWrite reports a bad fd and succeeds after a write" {
    try std.testing.expectEqual(@as(i32, -c.EBADF), closeWrite(0x4000_0000));

    var path_buf: [128]u8 = undefined;
    var z_buf: [128]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/cw-{d}-{d}.tmp", .{ nowSecRaw(), std.os.linux.getpid() });
    const z = try toZ(&z_buf, p);
    const fd = open(z, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, 0o644);
    try std.testing.expect(fd >= 0);
    defer _ = c.unlink(z);
    const n = writeAll(fd, "ok");
    const cr = closeWrite(fd);
    try std.testing.expect(n >= 0);
    try std.testing.expectEqual(@as(i32, 0), cr);
}

test "sizeFromStat rejects a signed overflow" {
    try std.testing.expectEqual(@as(?u64, 0), sizeFromStat(0));
    try std.testing.expectEqual(@as(?u64, 1), sizeFromStat(1));
    try std.testing.expectEqual(@as(?u64, @intCast(std.math.maxInt(c.off_t))), sizeFromStat(std.math.maxInt(c.off_t)));
    // Concrete miss: NFS fattr 2^64-1 stored in off_t is -1. @intCast to
    // u64 panics in safe builds and becomes maxInt(u64) in ReleaseFast,
    // so piece.count would clamp to a 512 MiB bitfield for one file.
    try std.testing.expect(sizeFromStat(-1) == null);
    try std.testing.expect(sizeFromStat(std.math.minInt(c.off_t)) == null);
}

test "I/O wrappers refuse offsets that do not fit off_t" {
    var path_buf: [128]u8 = undefined;
    var z_buf: [128]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/off-{d}-{d}.tmp", .{ nowSecRaw(), std.os.linux.getpid() });
    const z = try toZ(&z_buf, p);
    try std.testing.expectEqual(@as(i32, 0), writeFile(z, "x"));
    defer _ = c.unlink(z);
    const fd = open(z, c.O_RDWR, 0);
    try std.testing.expect(fd >= 0);
    defer close(fd);

    const too_big: u64 = @as(u64, std.math.maxInt(c.off_t)) + 1;
    var buf: [1]u8 = .{0};
    try std.testing.expectEqual(@as(isize, -c.EFBIG), preadAll(fd, &buf, too_big));
    try std.testing.expectEqual(@as(isize, -c.EFBIG), pwriteAll(fd, &buf, too_big));
    try std.testing.expectEqual(@as(i32, -c.EFBIG), ftruncate(fd, too_big));
    try std.testing.expectEqual(@as(i32, -c.EFBIG), punchHole(fd, too_big, 1));
    try std.testing.expectEqual(@as(isize, -c.EFBIG), sendfileAll(fd, fd, too_big, 1));
    // void path: must not panic on the same too-big offset.
    fadviseDontneed(fd, too_big, 1);
}

test "joinZ" {
    var buf: [64]u8 = undefined;
    const a = try joinZ(&buf, "/mnt/nas/models", "gguf/foo.gguf");
    try std.testing.expectEqualStrings("/mnt/nas/models/gguf/foo.gguf", std.mem.span(a));
    const b = try joinZ(&buf, "/mnt/nas/models", "");
    try std.testing.expectEqualStrings("/mnt/nas/models", std.mem.span(b));
    const d = try joinZ(&buf, "/mnt/nas/models", "/gguf/foo.gguf");
    try std.testing.expectEqualStrings("/mnt/nas/models/gguf/foo.gguf", std.mem.span(d));
    // The join that does not fit must be refused before any byte lands:
    // these results name artifact paths, and a silent truncation would
    // point sidecars and data files at the wrong keys.
    try std.testing.expectError(error.NameTooLong, joinZ(buf[0..16], "/mnt/nas/models", "gguf/foo.gguf"));
    try std.testing.expectError(error.NameTooLong, joinZ(buf[0..29], "/mnt/nas/models", "gguf/foo.gguf"));
}

test "monoSec never goes backwards" {
    const io = std.testing.io;
    const m0 = monoSec(io);
    sleepMs(io, 5);
    const m1 = monoSec(io);
    try std.testing.expect(m1 >= m0);
}

test "parentOf" {
    try std.testing.expectEqualStrings("/a/b", parentOf("/a/b/c"));
    try std.testing.expectEqualStrings("/", parentOf("/a"));
    try std.testing.expectEqualStrings(".", parentOf("c"));
    // Trailing slashes name the directory itself: the parent of "/a/b/" is
    // "/a", never "" or "/a/b/".
    try std.testing.expectEqualStrings("/a/b", parentOf("/a/b/c/"));
    try std.testing.expectEqualStrings("/", parentOf("/a/"));
    // The root is its own parent; so is any all-slash path.
    try std.testing.expectEqualStrings("/", parentOf("/"));
    try std.testing.expectEqualStrings("/", parentOf("///"));
}

fn fdIsCloexec(fd: c_int) bool {
    const flags = c.fcntl(fd, c.F_GETFD, @as(c_int, 0));
    return flags >= 0 and (flags & c.FD_CLOEXEC) != 0;
}

test "disableCoreDumps zeros RLIMIT_CORE" {
    try disableCoreDumps();
    const lim = std.posix.getrlimit(.CORE) catch return error.SkipZigTest;
    try std.testing.expectEqual(@as(std.posix.rlim_t, 0), lim.cur);
    try std.testing.expectEqual(@as(std.posix.rlim_t, 0), lim.max);
}

test "scrubPskEnv removes MODELFS_PSK_VALUE" {
    try std.testing.expectEqual(@as(c_int, 0), c.setenv("MODELFS_PSK_VALUE", "inline-secret", 1));
    try std.testing.expect(c.getenv("MODELFS_PSK_VALUE") != null);
    scrubPskEnv();
    try std.testing.expect(c.getenv("MODELFS_PSK_VALUE") == null);
}

test "open, socket, and accept are close-on-exec" {
    var path_buf: [128]u8 = undefined;
    var z_buf: [128]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/cloexec-{d}-{d}.tmp", .{ nowSecRaw(), std.os.linux.getpid() });
    const z = try toZ(&z_buf, p);
    const file_fd = open(z, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, 0o644);
    try std.testing.expect(file_fd >= 0);
    defer close(file_fd);
    defer _ = c.unlink(z);
    try std.testing.expect(fdIsCloexec(file_fd));

    const lfd = socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (lfd < 0) return error.SkipZigTest;
    defer close(lfd);
    try std.testing.expect(fdIsCloexec(lfd));
    var yes: c_int = 1;
    _ = c.setsockopt(lfd, c.SOL_SOCKET, c.SO_REUSEADDR, &yes, @sizeOf(c_int));
    var addr = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = 0;
    addr.sin_addr.s_addr = std.mem.nativeToBig(u32, 0x7F000001); // 127.0.0.1
    if (c.bind(lfd, .{ .__sockaddr__ = @ptrCast(&addr) }, @sizeOf(c.struct_sockaddr_in)) != 0) return error.SkipZigTest;
    if (c.listen(lfd, 1) != 0) return error.SkipZigTest;
    var got = std.mem.zeroes(c.struct_sockaddr_in);
    var glen: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
    if (c.getsockname(lfd, .{ .__sockaddr__ = @ptrCast(&got) }, &glen) != 0) return error.SkipZigTest;

    const cfd = socket(c.AF_INET, c.SOCK_STREAM, 0);
    try std.testing.expect(cfd >= 0);
    defer close(cfd);
    try std.testing.expect(fdIsCloexec(cfd));
    try std.testing.expectEqual(@as(i32, 0), connectIn(cfd, &got, 5000));

    var peer = std.mem.zeroes(c.struct_sockaddr_in);
    const afd = accept(lfd, &peer);
    try std.testing.expect(afd >= 0);
    defer close(afd);
    try std.testing.expect(fdIsCloexec(afd));
}

test "connectIn succeeds against a local listener" {
    const lfd = socket(c.AF_INET, c.SOCK_STREAM, 0);
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
    const cfd = socket(c.AF_INET, c.SOCK_STREAM, 0);
    try std.testing.expect(cfd >= 0);
    defer close(cfd);
    try std.testing.expectEqual(@as(i32, 0), connectIn(cfd, &got, 5000));
}

test "connectIn bounds a dead dial" {
    const fd = socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SkipZigTest;
    defer close(fd);
    var addr = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = std.mem.nativeToBig(u16, 19999);
    // Unroutable RFC1918 sink: without the bound this dial blocks for the
    // kernel's full TCP timeout. A fast refusal (ENETUNREACH/ECONNREFUSED)
    // also satisfies rc != 0, so sandboxed environments pass either way.
    addr.sin_addr.s_addr = std.mem.nativeToBig(u32, 0x0AFFFFFF); // 10.255.255.255
    const t0 = monoSec(std.testing.io);
    const rc = connectIn(fd, &addr, 250);
    try std.testing.expect(rc != 0);
    try std.testing.expect(monoSec(std.testing.io) - t0 <= 5);
}

test "resolveIpv4 passes numeric quads and resolves localhost" {
    var out: [64]u8 = undefined;
    // Numeric form: what every existing seed uses; must not change.
    try std.testing.expectEqualStrings("127.0.0.1", resolveIpv4("127.0.0.1", &out).?);
    try std.testing.expectEqualStrings("192.168.0.100", resolveIpv4("192.168.0.100", &out).?);
    // Leading zeros are a numeric miss, not a getaddrinfo-accepted spelling
    // the dialer would later refuse.
    try std.testing.expect(resolveIpv4("192.168.000.001", &out) == null);
    try std.testing.expect(resolveIpv4("127.0.0.256", &out) == null);
    // Name form: documented "--seed HOST[:PORT]" (here via /etc/hosts, so
    // the assertion holds without network access).
    const resolved = resolveIpv4("localhost", &out).?;
    try std.testing.expectEqualStrings("127.0.0.1", resolved);
    // A host that cannot fit the NUL-terminated staging buffer is a miss,
    // not a truncation.
    var big: [300]u8 = undefined;
    @memset(&big, 'a');
    try std.testing.expect(resolveIpv4(&big, &out) == null);
}

test "sendfileAll zero copy" {
    var path_buf: [128]u8 = undefined;
    var z_buf: [128]u8 = undefined;
    // pid suffix: two test processes starting in the same second must not
    // share the scratch file (second-resolution stamps collide otherwise)
    const p = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/sf-{d}-{d}.tmp", .{ nowSecRaw(), std.os.linux.getpid() });
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

test "readFile NoFollow refuses a planted symlink that the following form would ingest" {
    const gpa = std.testing.allocator;
    var db: [128]u8 = undefined;
    const scratch = try scratchDir(&db, "modelfs-read-nofollow");
    defer deleteTree(std.testing.io, scratch);

    var zb: [192]u8 = undefined;
    var tb: [192]u8 = undefined;
    var lb: [192]u8 = undefined;
    const target = try std.fmt.bufPrint(&tb, "{s}/secret.txt", .{scratch});
    const link = try std.fmt.bufPrint(&lb, "{s}/planted.txt", .{scratch});
    const target_z = try toZ(&zb, target);
    try std.testing.expectEqual(@as(i32, 0), writeFile(target_z, "s3cret"));
    var lz: [192]u8 = undefined;
    // Basename target: both names sit in scratch, and a cwd-relative
    // target would not resolve from the link's directory.
    try std.testing.expectEqual(@as(i32, 0), c.symlink("secret.txt", try toZ(&lz, link)));

    // The following form is for operator-specified paths (PSK): it must
    // still reach the target, so a secrets-volume symlink keeps working.
    const followed = try readFileAlloc(gpa, try toZ(&lz, link), 64);
    defer gpa.free(followed);
    try std.testing.expectEqualStrings("s3cret", followed);

    // The artifact form must fail closed: ELOOP, never the target's bytes.
    var open_errno: i32 = 0;
    try std.testing.expectError(error.OpenFailed, readFileAllocNoFollowOpenErrno(gpa, try toZ(&lz, link), 64, &open_errno));
    try std.testing.expectEqual(@as(i32, c.ELOOP), open_errno);

    var rbuf: [16]u8 = undefined;
    var buf_errno: i32 = 0;
    try std.testing.expectError(error.OpenFailed, readFileBufNoFollowOpenErrno(&rbuf, try toZ(&lz, link), &buf_errno));
    try std.testing.expectEqual(@as(i32, c.ELOOP), buf_errno);
    // The planted target keeps its bytes.
    try std.testing.expectEqualStrings("s3cret", try readFileBuf(&rbuf, target_z));
}
