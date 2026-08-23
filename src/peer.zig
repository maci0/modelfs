//! Peer HTTP server (/have, /data) and the matching fetch client: bearer
//! auth, bounded head reads, range hydration, and zero-copy streaming.
const std = @import("std");
const piece = @import("piece.zig");
const proto = @import("proto.zig");
const sys = @import("sys.zig");
const store_mod = @import("store.zig");
const discover = @import("discover.zig");
const c = sys.c;

pub const Server = struct {
    /// Concurrent connection handlers the accept loop admits, and the worker
    /// count fillFromPeers probes with: probing harder than a peer accepts
    /// would only buy rejections, so both sides share one cap.
    pub const max_inflight: u32 = 16;

    gpa: std.mem.Allocator,
    io: std.Io,
    psk: []const u8,
    store: *store_mod.Store,
    listen_fds: std.ArrayList(std.posix.fd_t) = .empty,
    running: std.atomic.Value(bool) = .init(true),
    http_inflight: std.atomic.Value(u32) = .init(0),

    pub fn bindAll(self: *Server, specs: []const proto.LeaseAddr) !void {
        if (specs.len == 0) {
            try self.bindOne("0.0.0.0", proto.default_port);
            return;
        }
        var seen_port: std.AutoHashMap(u16, void) = std.AutoHashMap(u16, void).init(self.gpa);
        defer seen_port.deinit();
        for (specs) |a| {
            if (seen_port.contains(a.port)) continue;
            try seen_port.put(a.port, {});
            try self.bindOne("0.0.0.0", a.port);
        }
    }

    fn bindOne(self: *Server, ip: []const u8, port: u16) !void {
        var addr: c.struct_sockaddr_in = undefined;
        sockaddrV4(ip, port, &addr) catch return error.BadIp;
        const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (fd < 0) return error.Socket;
        var yes: c_int = 1;
        _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, &yes, @sizeOf(c_int));
        _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEPORT, &yes, @sizeOf(c_int));
        if (c.bind(fd, .{ .__sockaddr__ = @ptrCast(&addr) }, @sizeOf(c.struct_sockaddr_in)) != 0) {
            sys.close(fd);
            return error.Bind;
        }
        if (c.listen(fd, 128) != 0) {
            sys.close(fd);
            return error.Listen;
        }
        errdefer sys.close(fd);
        try self.listen_fds.append(self.gpa, fd);
        std.log.info("peer http on {s}:{d}", .{ ip, port });
    }

    pub fn serve(self: *Server) void {
        var threads: std.ArrayList(std.Thread) = .empty;
        defer {
            for (threads.items) |t| t.join();
            threads.deinit(self.gpa);
        }
        // Reserve one slot per listener before spawning anything: an append
        // failure after a spawn used to detach that accept loop beyond the
        // join-all below, leaving it unsupervised at shutdown.
        threads.ensureTotalCapacity(self.gpa, self.listen_fds.items.len) catch {
            std.log.err("peer http: cannot allocate accept-loop registry; ports unserved", .{});
            return;
        };
        for (self.listen_fds.items) |fd| {
            const t = std.Thread.spawn(.{}, acceptLoop, .{ self, fd }) catch {
                std.log.err("peer http: cannot start accept loop on fd {d}; port unserved", .{fd});
                continue;
            };
            threads.appendAssumeCapacity(t);
        }
    }

    pub fn stop(self: *Server) void {
        self.running.store(false, .release);
        for (self.listen_fds.items) |fd| {
            _ = c.shutdown(fd, c.SHUT_RDWR);
            sys.close(fd);
        }
        self.listen_fds.deinit(self.gpa);
        self.listen_fds = .empty;
    }
};

fn acceptLoop(self: *Server, fd: c_int) void {
    var failing = false;
    while (self.running.load(.acquire)) {
        const cfd = c.accept(fd, .{ .__sockaddr__ = null }, null);
        if (cfd < 0) {
            if (!self.running.load(.acquire)) return;
            const e = sys.errno();
            // A listener fd that can no longer accept (EBADF/EINVAL/ENOTSOCK,
            // e.g. closed out from under the loop) would otherwise spin here
            // at 50 Hz forever with the port silently unserved.
            if (e == c.EBADF or e == c.EINVAL or e == c.ENOTSOCK) {
                std.log.warn("peer http: listen fd {d} unusable (errno {d}); port unserved", .{ fd, e });
                return;
            }
            // One line per consecutive-failure run, not one per retry: fd
            // exhaustion (EMFILE/ENFILE) is actionable, a 50 Hz stream is
            // noise that hides everything else.
            if (!failing) std.log.warn("peer http: accept failed (errno {d}); retrying", .{e});
            failing = true;
            sys.sleepMs(20);
            continue;
        }
        failing = false;
        // Claim-then-check with one atomic: several listen fds run accept
        // loops concurrently, and a load-then-add between two of them lets
        // every loop pass the cap at once. fetchAdd returns the previous
        // value, so exactly the claims beyond the cap undo themselves.
        if (self.http_inflight.fetchAdd(1, .monotonic) >= Server.max_inflight) {
            _ = self.http_inflight.fetchSub(1, .monotonic);
            sys.close(cfd);
            continue;
        }
        const t = std.Thread.spawn(.{}, handleConn, .{ self, cfd }) catch {
            _ = self.http_inflight.fetchSub(1, .monotonic);
            sys.close(cfd);
            continue;
        };
        t.detach();
    }
}

/// Steady-state socket send/receive timeout for peer connections. Head
/// reads clamp it to the head budget's remainder and must restore it
/// afterwards, or a dribbled head leaves body streaming a millisecond-scale
/// send ceiling and piece transfers die mid-flight.
const sock_timeout_ms: u32 = 30_000;

/// SO_RCVBUF/SO_SNDBUF for every peer socket. The server accept path and the
/// outbound dial must agree: a lopsided pair turns throughput into the small
/// side's default window.
const sock_buf_bytes: c_int = 2 * 1024 * 1024;

/// Wall-clock budget for one outbound dial (connect(2) wait plus the steady
/// socket timeout armed before it). A blocking connect can otherwise sit for
/// minutes on a blackholed peer address.
const dial_timeout_ms: u32 = 15_000;

/// Wall-clock budget for reading one request/response head. SO_RCVTIMEO is
/// per-recv and resets on every dribbled byte, so without a total cap one
/// connection can hold an inflight slot (or a client fill thread) forever by
/// sending a partial head slower than the timeout.
pub const head_deadline_ms: i64 = 10_000;

fn readHeadFull(fd: std.posix.fd_t, buf: []u8, out_head_len: *usize, out_total_read: *usize) !void {
    return readHeadFullDeadline(fd, buf, out_head_len, out_total_read, sys.monoMs() + head_deadline_ms);
}

fn readHeadFullDeadline(fd: std.posix.fd_t, buf: []u8, out_head_len: *usize, out_total_read: *usize, deadline_ms: i64) !void {
    var n: usize = 0;
    while (n < buf.len) {
        const remain_ms = deadline_ms - sys.monoMs();
        if (remain_ms <= 0) return error.HeadTimeout;
        // The last blocking read must wake at the deadline, not at the full
        // socket timeout: clamp it to the remaining budget.
        if (remain_ms < sock_timeout_ms)
            sys.setSockTimeout(fd, @intCast(remain_ms));
        const r = sys.readOnce(fd, buf[n..]) catch {
            if (deadline_ms - sys.monoMs() <= 0) return error.HeadTimeout;
            return error.Head;
        };
        if (r == 0) {
            if (deadline_ms - sys.monoMs() <= 0) return error.HeadTimeout;
            return error.Head;
        }
        const old_n = n;
        n += r;
        const search_start = if (old_n >= 3) old_n - 3 else 0;
        if (std.mem.findScalar(u8, buf[search_start..n], '\n') != null) {
            if (std.mem.find(u8, buf[search_start..n], "\r\n\r\n")) |idx| {
                out_head_len.* = search_start + idx + 4;
                out_total_read.* = n;
                // Head done: undo the budget clamp so response sends and
                // body reads get the full steady-state ceiling again.
                sys.setSockTimeout(fd, sock_timeout_ms);
                return;
            }
        }
    }
    return error.HeadTooBig;
}

fn handleConn(self: *Server, fd: std.posix.fd_t) void {
    defer {
        _ = self.http_inflight.fetchSub(1, .monotonic);
        sys.close(fd);
    }
    sys.setSockTimeout(fd, sock_timeout_ms);
    sys.setTcpNoDelay(fd, true);
    sys.setSockBuffers(fd, sock_buf_bytes);
    var head_buf: [8192]u8 = undefined;
    var n: usize = 0;
    var total_read: usize = 0;
    readHeadFull(fd, &head_buf, &n, &total_read) catch return;
    const head = head_buf[0..n];
    const line_end = std.mem.find(u8, head, "\r\n") orelse return;
    const line = head[0..line_end];
    var it = std.mem.splitScalar(u8, line, ' ');
    const method = it.next() orelse return;
    const target = it.next() orelse return;
    if (!std.mem.eql(u8, method, "GET")) {
        replyStatus(fd, "405 Method Not Allowed");
        return;
    }
    const auth = proto.headerGet(head, "Authorization") orelse "";
    if (!proto.bearerOk(auth, self.psk)) {
        // Security-relevant event: without this line a wrong-PSK node or an
        // unauthenticated prober is invisible to the operator. Bounded by the
        // accept loop's inflight cap, so it cannot flood faster than 16/s.
        std.log.warn("peer http: rejected unauthorized request", .{});
        replyStatus(fd, "401 Unauthorized");
        return;
    }
    const path = proto.pathOnly(target);
    if (std.mem.eql(u8, path, "/ping")) {
        reply(fd, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
        return;
    }
    var rel_buf: [4096]u8 = undefined;
    const rel = decodePath(target, &rel_buf) catch {
        replyStatus(fd, "400 Bad Request");
        return;
    };
    // Remote-supplied paths join the origin/cache roots downstream; a ".."
    // component here would read (and via cache hydration, write) outside them.
    if (!store_mod.relOk(rel)) {
        replyStatus(fd, "400 Bad Request");
        return;
    }
    if (std.mem.eql(u8, path, "/have")) {
        serveHave(self, fd, rel);
        return;
    }
    if (std.mem.eql(u8, path, "/data")) {
        const rh = proto.headerGet(head, "Range") orelse {
            replyStatus(fd, "400 Bad Request");
            return;
        };
        const rg = proto.parseRange(rh) orelse {
            replyStatus(fd, "400 Bad Request");
            return;
        };
        serveData(self, fd, rel, rg);
        return;
    }
    replyStatus(fd, "404 Not Found");
}

fn decodePath(target: []const u8, out: []u8) ![]u8 {
    const q = proto.queryGet(target, "path") orelse return error.NoPath;
    return proto.urlDecode(out, q);
}

fn serveHave(self: *Server, fd: std.posix.fd_t, rel: []const u8) void {
    var st: sys.c.struct_stat = undefined;
    const rc = self.store.statOrigin(rel, &st);
    if (rc != 0) {
        replyOriginStat(fd, rel, rc);
        return;
    }
    if ((st.st_mode & sys.c.S_IFMT) != sys.c.S_IFREG) {
        replyStatus(fd, "404 Not Found");
        return;
    }
    const file = self.store.get(rel, @intCast(st.st_size)) catch {
        replyStatus(fd, "500 Internal Server Error");
        return;
    };
    defer self.store.releaseFile(file);
    // Snapshot the bits under the lock and answer outside it: a stalled peer
    // socket (30s send timeout) must not pin file.mu and freeze local reads,
    // fills, and culls for that file.
    file.mu.lockUncancelable(self.io);
    const snap = self.gpa.dupe(u8, file.bits.bytes) catch {
        file.mu.unlock(self.io);
        replyStatus(fd, "500 Internal Server Error");
        return;
    };
    file.mu.unlock(self.io);
    defer self.gpa.free(snap);
    var hdr: [160]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{snap.len}) catch {
        return;
    };
    _ = sys.writeAll(fd, h);
    _ = sys.writeAll(fd, snap);
}

/// Hydrates every piece the range touches before streaming; unhydrated
/// holes read back as zeros, so a multi-piece range must fill each one.
/// One reusable buffer for every hydration in the range instead of an
/// alloc/free pair per 16 MiB piece, allocated only when a covered piece
/// actually lacks its bit: fully-cached ranges skip the allocation.
/// Sends the error reply itself; false means streaming cannot proceed.
fn hydrateRange(self: *Server, fd: std.posix.fd_t, file: *store_mod.Store.Cached, start: u64, want: u64, size: u64) bool {
    const cov = piece.cover(start, want, size, self.store.piece_size);
    if (cov.start >= cov.end) return true;
    const ps = self.store.piece_size;
    var pbuf: ?[]u8 = null;
    defer if (pbuf) |b| self.gpa.free(b);
    var pi = cov.start;
    while (pi < cov.end) : (pi += 1) {
        if (!self.store.hasPiece(file, pi)) {
            // Allocate before claiming: nothing but finishPiece removes a
            // filling entry, so an allocation failure after the claim would
            // leave the piece claimed forever and wedge every later filler
            // of it into claimPiece's retry spin.
            if (pbuf == null)
                pbuf = self.gpa.alloc(u8, ps) catch {
                    replyStatus(fd, "500 Internal Server Error");
                    return false;
                };
            const claimed = self.store.claimPiece(file, pi) catch {
                replyStatus(fd, "500 Internal Server Error");
                return false;
            };
            if (claimed) {
                // file.size moves only under file.mu; sample it under the
                // lock so ln cannot disagree with the bit finishPiece sets.
                file.mu.lockUncancelable(self.io);
                const ln = piece.len(file.size, pi, ps);
                file.mu.unlock(self.io);
                // A truncate raced us between the claim and this sample and
                // shrank the file below this piece: drop the claim and move
                // on instead of marking an empty piece filled (a later grow
                // preserves marks, so the bogus bit would serve hole zeros).
                if (ln == 0) {
                    self.store.finishPiece(file, pi, false);
                    continue;
                }
                const got = self.store.originPread(file.rel, pbuf.?[0..ln], piece.offset(pi, ps));
                if (got == @as(isize, @intCast(ln))) {
                    const w = self.store.writePiece(file, pi, pbuf.?[0..ln]);
                    self.store.finishPiece(file, pi, w == 0);
                } else {
                    self.store.finishPiece(file, pi, false);
                    // statOrigin passed, so the file exists: a failed or short
                    // read is an upstream (origin) failure. Reporting 404 here
                    // would make peers believe the path is gone. Log it too:
                    // the 502 alone leaves the local operator no trace of why
                    // hydration failed.
                    std.log.warn("origin pread failed for {s} piece {d} (rc {d}); replying 502", .{ file.rel, pi, -got });
                    replyStatus(fd, "502 Bad Gateway");
                    return false;
                }
            }
        }
        if (!self.store.hasPiece(file, pi)) {
            replyStatus(fd, "404 Not Found");
            return false;
        }
    }
    return true;
}

/// Streams [start, start+want) from the cache entry. Zero-copy kernel
/// sendfile, piece-sized chunk at a time; each chunk re-stamps recency so
/// idle-time accounting tracks the transfer. Punch protection is the
/// caller's xfer guard (serveData): stamping alone cannot cover a single
/// chunk that stalls past the cull window. The 206 header is already on
/// the wire here, so any failure must just drop the connection: a second
/// status line would be parsed as body bytes and corrupt the response. The
/// user-space fallback streams fixed chunks so a large range cannot drive a
/// want-sized allocation.
fn streamRange(self: *Server, fd: std.posix.fd_t, file: *store_mod.Store.Cached, start: u64, want: u64) void {
    const cfd = self.store.openCache(file);
    if (cfd >= 0) {
        var done: u64 = 0;
        while (done < want) {
            file.last_access.store(sys.monoSec(), .monotonic);
            const take: usize = @intCast(@min(want - done, @as(u64, self.store.piece_size)));
            const sent = sys.sendfileAll(fd, cfd, start + done, take);
            if (sent != @as(isize, @intCast(take))) {
                // Partial kernel send with bytes already on the wire:
                // resending would duplicate them. Drop the connection and let
                // the peer treat it as a failed fetch. A failed FIRST chunk
                // still falls back to user-space streaming below.
                if (sent > 0 or done > 0) return;
                break;
            }
            done += take;
        }
        if (done == want) return;
    }

    const chunk_cap: usize = 4 * 1024 * 1024;
    const buf = self.gpa.alloc(u8, @min(want, chunk_cap)) catch return;
    defer self.gpa.free(buf);
    var off = start;
    var remaining = want;
    while (remaining > 0) {
        const take = @min(remaining, buf.len);
        const n = self.store.readCache(file, buf[0..take], off);
        if (n < 0 or @as(u64, @intCast(n)) != take) return;
        if (sys.writeAll(fd, buf[0..take]) < 0) return;
        off += take;
        remaining -= take;
    }
}

fn serveData(self: *Server, fd: std.posix.fd_t, rel: []const u8, rg: proto.Range) void {
    var st: sys.c.struct_stat = undefined;
    const src = self.store.statOrigin(rel, &st);
    if (src != 0) {
        replyOriginStat(fd, rel, src);
        return;
    }
    const size: u64 = @intCast(st.st_size);
    if (rg.start >= size or rg.end < rg.start) {
        replyStatus(fd, "416 Range Not Satisfiable");
        return;
    }
    // An end position past the last byte still names a satisfiable range
    // (RFC 9110): it means "to EOF", so clamp instead of refusing. Refusing
    // here would break ordinary HTTP clients asking for the rest of the file;
    // the internal peer protocol always sends exact piece bounds.
    const rg_end = @min(rg.end, size - 1);
    const file = self.store.get(rel, size) catch {
        replyStatus(fd, "500 Internal Server Error");
        return;
    };
    defer self.store.releaseFile(file);
    // The whole response (hydration plus streaming) is one transfer: hold
    // punchPiece off for its duration. Per-chunk recency stamping alone
    // cannot do this -- one stalled sendfile blocks up to the 30s socket
    // timeout, far past the 10s cull window, and a punch mid-send ships
    // hole zeros that the fetching peer then marks filled.
    _ = file.xfer.fetchAdd(1, .monotonic);
    defer _ = file.xfer.fetchSub(1, .monotonic);
    const want = rg_end -| rg.start +| 1;

    if (!hydrateRange(self, fd, file, rg.start, want, size)) return;

    var hdr: [220]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {d}-{d}/{d}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{
        rg.start, rg_end, size, want,
    }) catch return;
    _ = sys.writeAll(fd, h);

    streamRange(self, fd, file, rg.start, want);
}

fn reply(fd: std.posix.fd_t, s: []const u8) void {
    _ = sys.writeAll(fd, s);
}

/// Empty-body response; every error path shares this framing.
fn replyStatus(fd: std.posix.fd_t, status: []const u8) void {
    var buf: [96]u8 = undefined;
    const res = std.fmt.bufPrint(&buf, "HTTP/1.1 {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{status}) catch return;
    reply(fd, res);
}

/// 404 when the origin reports the path truly absent, 502 when the origin
/// itself failed (NFS I/O error, stale mount): a fetching peer and an
/// operator must be able to tell a missing file from an unavailable one.
fn replyOriginStat(fd: std.posix.fd_t, rel: []const u8, rc: i32) void {
    if (rc == -sys.c.ENOENT or rc == -sys.c.ENOTDIR) {
        replyStatus(fd, "404 Not Found");
    } else {
        std.log.warn("origin stat failed for {s} (errno {d})", .{ rel, -rc });
        replyStatus(fd, "502 Bad Gateway");
    }
}

pub fn fetchHave(gpa: std.mem.Allocator, psk: []const u8, ip: []const u8, port: u16, rel: []const u8) ![]u8 {
    const fd = try sendRequest(psk, ip, port, rel, null);
    defer sys.close(fd);
    return readFlexBodyAlloc(gpa, fd, null);
}

/// Dials and sends one GET (/have, or /data when range is set); returns the
/// connected socket with the request already on the wire. One builder for
/// both shapes so URL encoding, bearer auth, and Connection framing cannot
/// drift between them.
fn sendRequest(psk: []const u8, ip: []const u8, port: u16, rel: []const u8, range: ?proto.Range) !c_int {
    var qbuf: [4096 * 3]u8 = undefined;
    const enc = try proto.urlEncode(&qbuf, rel);
    var req: [4096 * 3 + 512]u8 = undefined;
    const s = if (range) |rg|
        try std.fmt.bufPrint(&req, "GET /data?path={s} HTTP/1.1\r\nHost: {s}:{d}\r\nAuthorization: Bearer {s}\r\nRange: bytes={d}-{d}\r\nConnection: close\r\n\r\n", .{
            enc, ip, port, psk, rg.start, rg.end,
        })
    else
        try std.fmt.bufPrint(&req, "GET /have?path={s} HTTP/1.1\r\nHost: {s}:{d}\r\nAuthorization: Bearer {s}\r\nConnection: close\r\n\r\n", .{
            enc, ip, port, psk,
        });
    const fd = try dial(ip, port);
    errdefer sys.close(fd);
    if (sys.writeAll(fd, s) < 0) return error.Write;
    return fd;
}

pub fn fetchRange(gpa: std.mem.Allocator, psk: []const u8, ip: []const u8, port: u16, rel: []const u8, start: u64, end: u64) ![]u8 {
    const fd = try sendRequest(psk, ip, port, rel, .{ .start = start, .end = end });
    defer sys.close(fd);
    return readFlexBodyAlloc(gpa, fd, null);
}

/// Like fetchRange, but streams the body directly into `out` (whose length
/// must match the peer's Content-Length): one fewer piece-sized allocation
/// and copy per fetched piece.
pub fn fetchRangeInto(gpa: std.mem.Allocator, psk: []const u8, ip: []const u8, port: u16, rel: []const u8, start: u64, end: u64, out: []u8) !void {
    const fd = try sendRequest(psk, ip, port, rel, .{ .start = start, .end = end });
    defer sys.close(fd);
    _ = try readFlexBodyAlloc(gpa, fd, out);
}

pub fn rangeBps(bytes: u64, dt_ns: i128) f64 {
    const sec = @as(f64, @floatFromInt(dt_ns)) / 1e9;
    if (sec <= 0) return 0;
    return @as(f64, @floatFromInt(bytes)) / sec;
}

/// Parses "IP" text plus numeric port into a sockaddr_in at the boundary
/// where untrusted address strings meet the kernel socket API.
fn sockaddrV4(ip: []const u8, port: u16, out: *c.struct_sockaddr_in) !void {
    out.* = std.mem.zeroes(c.struct_sockaddr_in);
    out.sin_family = c.AF_INET;
    out.sin_port = std.mem.nativeToBig(u16, port);
    var ipz: [64]u8 = undefined;
    const z = try sys.toZ(&ipz, ip);
    if (c.inet_pton(c.AF_INET, z, &out.sin_addr) != 1) return error.BadIp;
}

fn dial(ip: []const u8, port: u16) !c_int {
    var addr: c.struct_sockaddr_in = undefined;
    try sockaddrV4(ip, port, &addr);
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return error.Socket;
    sys.setSockTimeout(fd, dial_timeout_ms);
    sys.setTcpNoDelay(fd, true);
    sys.setSockBuffers(fd, sock_buf_bytes);
    // Bounded connect: SO_RCVTIMEO does not cover the dial itself, and a
    // blocking connect to a dead address stalls the fill path for minutes.
    if (sys.connectIn(fd, &addr, dial_timeout_ms) != 0) {
        sys.close(fd);
        return error.Connect;
    }
    return fd;
}

fn readFlexBodyAlloc(gpa: std.mem.Allocator, fd: std.posix.fd_t, dest: ?[]u8) ![]u8 {
    var head_buf: [8192]u8 = undefined;
    var head_len: usize = 0;
    var total_read: usize = 0;
    readHeadFull(fd, &head_buf, &head_len, &total_read) catch return error.Head;
    const head = head_buf[0..head_len];
    const status_end = std.mem.find(u8, head, "\r\n") orelse return error.BadHttp;
    const status_line = head[0..status_end];
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 200") and
        !std.mem.startsWith(u8, status_line, "HTTP/1.1 206"))
    {
        return error.HttpStatus;
    }

    const cl_str = proto.headerGet(head, "Content-Length") orelse "0";
    const want_len = std.fmt.parseInt(usize, cl_str, 10) catch 0;

    // A caller-supplied buffer streams straight into it (no piece-sized
    // allocation and copy per fetch); its length must match exactly. With a
    // matching buffer there is nothing left to allocate, so the size cap
    // below does not apply: piece sizes up to u32 stay fetchable. The match
    // is checked before any early return -- including the zero-length case,
    // or a peer omitting Content-Length would "succeed" without writing a
    // byte and the fetched piece would be marked filled over hole zeros.
    if (dest) |d| {
        if (d.len != want_len) return error.LengthMismatch;
        if (want_len == 0) return d[0..0];
    } else {
        // Content-Length is untrusted peer input: refuse absurd bodies
        // instead of letting one bad response drive a giant allocation.
        if (want_len > 512 * 1024 * 1024) return error.BodyTooLarge;
        if (want_len == 0) return try gpa.alloc(u8, 0);
    }

    const buf = dest orelse try gpa.alloc(u8, want_len);
    errdefer if (dest == null) gpa.free(buf);

    var got: usize = 0;
    if (total_read > head_len) {
        const extra = total_read - head_len;
        const take = @min(extra, want_len);
        @memcpy(buf[0..take], head_buf[head_len..][0..take]);
        got = take;
    }

    while (got < want_len) {
        const n = sys.readOnce(fd, buf[got..]) catch return error.Read;
        if (n == 0) break;
        got += n;
    }
    if (got != want_len) return error.ReadIncomplete;
    return buf;
}

pub const ProbePeer = struct { ip: []const u8, port: u16 };

const ProbeCtx = struct {
    gpa: std.mem.Allocator,
    psk: []const u8,
    rel: []const u8,
    peers: []const ProbePeer,
    /// Slot indexes that still need a probe (the rest came from cache).
    todo: []const usize,
    slots: []?[]u8,
    cat: *discover.Catalog,
    next: std.atomic.Value(u32) = .init(0),
};

/// Claims one unprobed peer at a time and records its /have bitmap (null on
/// failure). The atomic cursor lets any number of workers drain the list
/// without overlap, so a partially started pool can always be finished off
/// inline. Successes feed the catalog's short-TTL have cache so later pieces
/// of the same file skip the probe entirely.
fn probeWorker(ctx: *ProbeCtx) void {
    while (true) {
        const t = ctx.next.fetchAdd(1, .monotonic);
        if (t >= ctx.todo.len) return;
        const i = ctx.todo[t];
        const bits = fetchHave(ctx.gpa, ctx.psk, ctx.peers[i].ip, ctx.peers[i].port, ctx.rel) catch null;
        ctx.slots[i] = bits;
        if (bits) |b| ctx.cat.havePut(ctx.rel, ctx.peers[i].ip, ctx.peers[i].port, b);
    }
}

/// Fills slots[] with one /have bitmap per peer: peers answered by the
/// recent-probe cache skip the wire entirely; the rest are probed
/// concurrently (a serial probe would pay one full connect+request+response
/// round trip per peer before any piece data moves). slots must be all-null.
fn probeSlots(gpa: std.mem.Allocator, psk: []const u8, cat: *discover.Catalog, rel: []const u8, peers: []const ProbePeer, slots: []?[]u8) !void {
    var todo: std.ArrayList(usize) = .empty;
    defer todo.deinit(gpa);
    for (peers, 0..) |pp, si| {
        if (cat.haveGet(gpa, rel, pp.ip, pp.port)) |cached| {
            slots[si] = cached;
        } else {
            try todo.append(gpa, si);
        }
    }
    if (todo.items.len == 0) return;

    var ctx = ProbeCtx{
        .gpa = gpa,
        .psk = psk,
        .rel = rel,
        .peers = peers,
        .todo = todo.items,
        .slots = slots,
        .cat = cat,
    };
    // Cap at the server's own inflight limit: probing harder than a peer
    // accepts would only buy rejections.
    const nthreads = @min(todo.items.len, Server.max_inflight);
    var workers: [Server.max_inflight]?std.Thread = .{null} ** Server.max_inflight;
    var spawned: usize = 0;
    while (spawned < nthreads) : (spawned += 1) {
        workers[spawned] = std.Thread.spawn(.{}, probeWorker, .{&ctx}) catch break;
    }
    for (workers[0..spawned]) |w| w.?.join();
    if (spawned < todo.items.len) probeWorker(&ctx);
}

pub fn fillFromPeers(
    gpa: std.mem.Allocator,
    psk: []const u8,
    cat: *discover.Catalog,
    rel: []const u8,
    idx: u32,
    ps: u32,
    out: []u8,
) !void {
    const paths = try cat.snapshot(gpa);
    defer discover.Catalog.freeSnapshot(gpa, paths);
    var cands: std.ArrayList(discover.PathCand) = .empty;
    defer cands.deinit(gpa);

    // One probe per unique peer id: several lease paths can name the same
    // node, and probing each would duplicate wire round trips and slots.
    var slot_of = std.StringHashMap(usize).init(gpa);
    defer slot_of.deinit();
    var peers: std.ArrayList(ProbePeer) = .empty;
    defer peers.deinit(gpa);
    for (paths) |p| {
        const gop = try slot_of.getOrPut(p.peer_id);
        if (gop.found_existing) continue;
        gop.value_ptr.* = peers.items.len;
        try peers.append(gpa, .{ .ip = p.ip, .port = p.port });
    }

    const slots = try gpa.alloc(?[]u8, peers.items.len);
    defer {
        for (slots) |s| if (s) |b| gpa.free(b);
        gpa.free(slots);
    }
    @memset(slots, null);

    // One /have probe per unique peer id, issued concurrently; peers answered
    // by the recent-probe cache skip the wire entirely, so a sequential fill
    // of one file probes once per peer per TTL instead of once per piece.
    try probeSlots(gpa, psk, cat, rel, peers.items, slots);
    for (paths) |p| {
        var bits: []u8 = &.{};
        if (slot_of.get(p.peer_id)) |si| {
            if (slots[si]) |b| bits = b;
        }
        const has = idx / 8 < bits.len and (bits[idx / 8] & (@as(u8, 1) << @intCast(idx % 8))) != 0;
        try cands.append(gpa, .{
            .peer_id = p.peer_id,
            .ip = p.ip,
            .port = p.port,
            .ewma_bps = p.ewma_bps,
            .hops = p.hops,
            .inflight = p.inflight.load(.monotonic),
            .have = has,
        });
    }

    // exclusive: one winner, then next on failure, then error (caller uses NFS)
    var remaining = cands.items;
    while (discover.pickBest(remaining)) |bi| {
        const win = remaining[bi];
        _ = cat.inflight(win.ip, win.port, 1);
        const start = piece.offset(idx, ps);
        // Saturating: a caller passing an empty buffer (only possible via an
        // out-of-band truncate race today) must not underflow the range end.
        const end = start +| out.len -| 1;
        const t0 = sys.monoNs();
        // Stream the body straight into out: no piece-sized allocation or
        // copy on the fetch path.
        fetchRangeInto(gpa, psk, win.ip, win.port, rel, start, end, out) catch {
            _ = cat.inflight(win.ip, win.port, -1);
            remaining[bi].have = false;
            continue;
        };
        _ = cat.inflight(win.ip, win.port, -1);
        const dt = sys.monoNs() - t0;
        cat.updateGoodput(win.ip, win.port, rangeBps(out.len, dt));
        return;
    }
    return error.NoPeer;
}

test "rangeBps" {
    const b = rangeBps(16 * 1024 * 1024, 8_000_000);
    try std.testing.expect(b > 1e9);
}

/// Connected socketpair with `response` already written into fds[0]: a
/// deterministic stand-in for the server side of the fetch* helpers.
fn responsePair(response: []const u8) ![2]c_int {
    var fds: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds) != 0) return error.Socket;
    errdefer sys.close(fds[0]);
    errdefer sys.close(fds[1]);
    if (sys.writeAll(fds[0], response) < 0) return error.Write;
    return fds;
}

test "readFlexBodyAlloc consumes body bytes pipelined with the header" {
    const gpa = std.testing.allocator;
    // Head and body delivered in one segment: over TCP this coalescing only
    // happens sometimes, so without this test the branch that lifts body
    // bytes out of the header buffer ran by luck, not by assertion.
    const pair = try responsePair("HTTP/1.1 206 Partial Content\r\nContent-Length: 8\r\nConnection: close\r\n\r\n12345678");
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    const body = try readFlexBodyAlloc(gpa, pair[1], null);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("12345678", body);
}

test "readFlexBodyAlloc rejects hostile responses" {
    const gpa = std.testing.allocator;

    // Non-200/206 status surfaces as HttpStatus, never parsed as body bytes.
    {
        const pair = try responsePair("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        defer sys.close(pair[0]);
        defer sys.close(pair[1]);
        try std.testing.expectError(error.HttpStatus, readFlexBodyAlloc(gpa, pair[1], null));
    }
    // Content-Length above the 512MiB cap is refused before any allocation.
    {
        const pair = try responsePair("HTTP/1.1 200 OK\r\nContent-Length: 536870913\r\nConnection: close\r\n\r\n");
        defer sys.close(pair[0]);
        defer sys.close(pair[1]);
        try std.testing.expectError(error.BodyTooLarge, readFlexBodyAlloc(gpa, pair[1], null));
    }
    // A caller-supplied buffer must match Content-Length exactly.
    {
        const pair = try responsePair("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nabcd");
        defer sys.close(pair[0]);
        defer sys.close(pair[1]);
        var short_dest: [3]u8 = undefined;
        try std.testing.expectError(error.LengthMismatch, readFlexBodyAlloc(gpa, pair[1], &short_dest));
    }
    // EOF before Content-Length is data loss: ReadIncomplete, not a short read.
    {
        const pair = try responsePair("HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\n1234");
        defer sys.close(pair[0]);
        defer sys.close(pair[1]);
        _ = c.shutdown(pair[0], c.SHUT_WR);
        try std.testing.expectError(error.ReadIncomplete, readFlexBodyAlloc(gpa, pair[1], null));
    }
}

test "readFlexBodyAlloc keeps the dest contract when Content-Length is absent" {
    const gpa = std.testing.allocator;
    // A peer answering without Content-Length must fail the fetch rather
    // than silently succeed having written nothing: the caller would mark
    // the piece filled over hole zeros.
    {
        const pair = try responsePair("HTTP/1.1 206 Partial Content\r\nConnection: close\r\n\r\n");
        defer sys.close(pair[0]);
        defer sys.close(pair[1]);
        var dest: [8]u8 = undefined;
        try std.testing.expectError(error.LengthMismatch, readFlexBodyAlloc(gpa, pair[1], &dest));
    }
    // An explicit zero length against an explicitly empty destination is fine.
    {
        const pair = try responsePair("HTTP/1.1 206 Partial Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        defer sys.close(pair[0]);
        defer sys.close(pair[1]);
        _ = try readFlexBodyAlloc(gpa, pair[1], &.{});
    }
}

test "readHeadFullDeadline aborts a dribbled head at the deadline" {
    // Half a request line, then silence: SO_RCVTIMEO alone would hold this
    // connection (and one of 16 inflight slots) until the sender resumes.
    // The total head budget must expire instead.
    const pair = try responsePair("");
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    try std.testing.expectEqual(@as(isize, 5), sys.writeAll(pair[0], "GET /"));
    var head_len: usize = 0;
    var total: usize = 0;
    var buf: [64]u8 = undefined;
    const t0 = sys.monoMs();
    const err = readHeadFullDeadline(pair[1], &buf, &head_len, &total, t0 + 150);
    try std.testing.expectError(error.HeadTimeout, err);
    try std.testing.expect(sys.monoMs() - t0 <= 2000);
}

test "server start and stop" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-srv-o");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-srv-c");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = store_mod.Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();

    var server = Server{
        .gpa = gpa,
        .io = std.testing.io,
        .psk = "secret",
        .store = &st,
    };
    // Port 0 lets the kernel pick a free ephemeral port: no collision with
    // any modelfs instance (default listen 18080) already running on host.
    try server.bindOne("127.0.0.1", 0);
    try std.testing.expectEqual(@as(usize, 1), server.listen_fds.items.len);
    const bound_port = boundPort(server.listen_fds.items[0]);
    try std.testing.expect(bound_port > 0);
    server.stop();
}

test "fault tolerance: bad psk fetchHave fails with http status" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-srv-o-psk");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-srv-c-psk");
    defer sys.deleteTree(std.testing.io, cache_d);

    const srv = try TestServer.start(gpa, origin_d, cache_d, 16, "correct_secret");
    defer srv.stop();
    const port = srv.port();

    // Try fetching /have with wrong PSK. The expected 401 makes the server
    // log its security warning; raising the test log level keeps that one
    // expected line off the runner's stderr (zig build renders any captured
    // stderr as a step-failure block even on green runs). Restored on scope
    // exit so unexpected warnings from later tests still surface.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;
    const err = fetchHave(gpa, "wrong_secret", "127.0.0.1", port, "foo.bin");
    try std.testing.expectError(error.HttpStatus, err);
}

test "fault tolerance: traversal path is rejected with 400" {
    const gpa = std.testing.allocator;
    var bb: [128]u8 = undefined;
    // Per-pid base tree (scratchDir) so the traversal target ../secret.txt is
    // a real sibling file of origin (not a shared .zig-cache/tmp/secret.txt
    // other test processes would race on) and one deleteTree cleans all.
    const base_d = try sys.scratchDir(&bb, "modelfs-srv-trav-base");
    defer sys.deleteTree(std.testing.io, base_d);
    var obuf: [160]u8 = undefined;
    const origin_d = try std.fmt.bufPrint(&obuf, "{s}/origin", .{base_d});
    var cbuf: [160]u8 = undefined;
    const cache_d = try std.fmt.bufPrint(&cbuf, "{s}/cache", .{base_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(origin_d, 0o755));
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(cache_d, 0o755));
    defer sys.deleteTree(std.testing.io, base_d);

    // A secret outside the origin must be unreadable even with the right PSK.
    var sbuf: [192]u8 = undefined;
    const secret_fp = try std.fmt.bufPrint(&sbuf, "{s}/secret.txt", .{base_d});
    var zbuf: [192]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, secret_fp), "topsecret"));

    const srv = try TestServer.start(gpa, origin_d, cache_d, 16, "correct_secret");
    defer srv.stop();
    const port = srv.port();

    // /have and /data with a ".." component must fail at the boundary.
    try std.testing.expectError(error.HttpStatus, fetchHave(gpa, "correct_secret", "127.0.0.1", port, "../secret.txt"));
    try std.testing.expectError(error.HttpStatus, fetchRange(gpa, "correct_secret", "127.0.0.1", port, "../secret.txt", 0, 8));
    // URL-encoded variants hit the same check after decoding.
    try std.testing.expectError(error.HttpStatus, fetchHave(gpa, "correct_secret", "127.0.0.1", port, "%2e%2e/secret.txt"));
    // Absolute paths are refused too, not silently re-rooted into the origin.
    try std.testing.expectError(error.HttpStatus, fetchHave(gpa, "correct_secret", "127.0.0.1", port, "/etc/passwd"));
}

/// Read the kernel-assigned port back from a listening socket (for port 0).
fn boundPort(fd: c_int) u16 {
    var addr = std.mem.zeroes(c.struct_sockaddr_in);
    var len: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
    if (c.getsockname(fd, .{ .__sockaddr__ = @ptrCast(&addr) }, &len) != 0) return 0;
    return std.mem.bigToNative(u16, addr.sin_port);
}

/// Test harness: one Store plus a Server bound to an ephemeral kernel-picked
/// port with its accept loop running. Heap-allocated so the Server's store
/// pointer stays valid across the return. stop() is the single shutdown
/// path: signal, shut the listener down so accept() wakes, join the accept
/// thread, then release the store.
const TestServer = struct {
    gpa: std.mem.Allocator,
    store: store_mod.Store,
    server: Server,
    accept_thread: ?std.Thread = null,

    fn start(gpa: std.mem.Allocator, origin: []const u8, cache: []const u8, piece_size: u32, psk: []const u8) !*TestServer {
        const ts = try gpa.create(TestServer);
        errdefer gpa.destroy(ts);
        ts.* = .{
            .gpa = gpa,
            .store = store_mod.Store.init(gpa, std.testing.io, origin, cache, piece_size),
            .server = undefined,
        };
        ts.server = .{ .gpa = gpa, .io = std.testing.io, .psk = psk, .store = &ts.store };
        errdefer ts.stop();
        try ts.server.bindOne("127.0.0.1", 0);
        if (ts.port() == 0) return error.Bind;
        ts.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{ &ts.server, ts.server.listen_fds.items[0] });
        return ts;
    }

    fn port(self: *TestServer) u16 {
        return boundPort(self.server.listen_fds.items[0]);
    }

    fn stop(self: *TestServer) void {
        // Signal before shutdown: the bare join would otherwise block forever
        // in accept() and mask whatever error brought us here.
        self.server.running.store(false, .release);
        for (self.server.listen_fds.items) |fd| _ = c.shutdown(fd, c.SHUT_RDWR);
        if (self.accept_thread) |t| t.join();
        self.server.stop();
        self.store.deinit();
        self.gpa.destroy(self);
    }
};

test "fault tolerance: dial unreachable peer fails gracefully" {
    const err = dial("127.0.0.1", 19999);
    try std.testing.expectError(error.Connect, err);
}

test "serve joins its accept loops once stop shuts the listeners down" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-srv-o-serve");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-srv-c-serve");
    defer sys.deleteTree(std.testing.io, cache_d);
    var st = store_mod.Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();

    var server = Server{ .gpa = gpa, .io = std.testing.io, .psk = "secret", .store = &st };
    try server.bindOne("127.0.0.1", 0);
    // serve() blocks joining its accept loops; the join below must return
    // promptly once stop() signals and shuts the listeners down. Regression:
    // an append failure used to strand an accept loop detached from this
    // join, unsupervised past shutdown.
    const t = try std.Thread.spawn(.{}, Server.serve, .{&server});
    server.stop();
    t.join();
}

test "acceptLoop exits instead of spinning when the listen fd is unusable" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-srv-o-accept");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-srv-c-accept");
    defer sys.deleteTree(std.testing.io, cache_d);
    var st = store_mod.Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();

    var server = Server{ .gpa = gpa, .io = std.testing.io, .psk = "secret", .store = &st };
    // The loop's own report of the dead fd is the point of this test; raising
    // the print threshold keeps that expected line off the runner's stderr.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;
    // A fd number that is not open makes accept fail with EBADF every time.
    // Regression: the loop used to retry that forever at 50 Hz with the port
    // silently unserved; it must return so the failure stays observable.
    const t = try std.Thread.spawn(.{}, acceptLoop, .{ &server, @as(c_int, 0x4000_0000) });
    t.join();
}

test "serveData fills every piece of a multi-piece range" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-srv-o-multi");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-srv-c-multi");
    defer sys.deleteTree(std.testing.io, cache_d);

    // 32-byte file, 16-byte pieces: range 0..31 spans exactly two pieces.
    // Regression: only the first piece was hydrated, the rest served zeros.
    var pattern: [32]u8 = undefined;
    for (&pattern, 0..) |*b, i| b.* = @truncate(i);
    var fbuf: [192]u8 = undefined;
    var fz: [192]u8 = undefined;
    const fp = try std.fmt.bufPrint(&fbuf, "{s}/two.bin", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&fz, fp), &pattern));

    const srv = try TestServer.start(gpa, origin_d, cache_d, 16, "secret");
    defer srv.stop();
    const port = srv.port();

    const body = try fetchRange(gpa, "secret", "127.0.0.1", port, "two.bin", 0, 31);
    defer gpa.free(body);
    try std.testing.expectEqual(@as(usize, 32), body.len);
    try std.testing.expectEqualSlices(u8, &pattern, body);
}

test "serveData serves ranges beyond the old 64MiB transfer cap" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-srv-o-big");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-srv-c-big");
    defer sys.deleteTree(std.testing.io, cache_d);

    // Sparse 70MiB origin file (5 pieces at 16MiB). Regression: any range
    // above 64MiB was answered 416, silently disabling the peer tier for
    // --piece sizes beyond it (the config still accepts them).
    var fbuf: [192]u8 = undefined;
    var fz: [192]u8 = undefined;
    const fp = try std.fmt.bufPrint(&fbuf, "{s}/big.bin", .{origin_d});
    {
        const fd = sys.open(try sys.toZ(&fz, fp), c.O_WRONLY | c.O_CREAT, 0o644);
        try std.testing.expect(fd >= 0);
        defer sys.close(fd);
        try std.testing.expectEqual(@as(i32, 0), sys.ftruncate(fd, 70 * 1024 * 1024));
    }

    const srv = try TestServer.start(gpa, origin_d, cache_d, 16 * 1024 * 1024, "secret");
    defer srv.stop();
    const port = srv.port();

    const total: u64 = 70 * 1024 * 1024;
    const body = try fetchRange(gpa, "secret", "127.0.0.1", port, "big.bin", 0, total - 1);
    defer gpa.free(body);
    try std.testing.expectEqual(total, body.len);
    for (body, 0..) |b, i| {
        if (b != 0) {
            std.debug.print("nonzero byte at {d}\n", .{i});
            return error.TestUnexpectedResult;
        }
    }
}

test "serveData clamps an over-long range end to EOF" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-srv-o-clamp");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-srv-c-clamp");
    defer sys.deleteTree(std.testing.io, cache_d);

    // Regression: bytes=0-<past EOF> was answered 416 even though the range
    // is satisfiable; HTTP clients use over-long ends to ask for the rest.
    var pattern: [32]u8 = undefined;
    for (&pattern, 0..) |*b, i| b.* = @truncate(i);
    var fbuf: [192]u8 = undefined;
    var fz: [192]u8 = undefined;
    const fp = try std.fmt.bufPrint(&fbuf, "{s}/tail.bin", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&fz, fp), &pattern));

    const srv = try TestServer.start(gpa, origin_d, cache_d, 16, "secret");
    defer srv.stop();
    const port = srv.port();

    const body = try fetchRange(gpa, "secret", "127.0.0.1", port, "tail.bin", 0, pattern.len + 999_999);
    defer gpa.free(body);
    try std.testing.expectEqual(pattern.len, body.len);
    try std.testing.expectEqualSlices(u8, &pattern, body);

    // A start inside the file with an over-long end serves only the tail.
    const tail = try fetchRange(gpa, "secret", "127.0.0.1", port, "tail.bin", 30, 999_999);
    defer gpa.free(tail);
    try std.testing.expectEqualSlices(u8, pattern[30..], tail);
}

test "serveData counts as access for cull recency" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-srv-o-recency");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-srv-c-recency");
    defer sys.deleteTree(std.testing.io, cache_d);

    // Two pieces at piece size 16; both warmed so the second fetch takes the
    // fully-cached sendfile path, which (unlike readCache) stamps nothing.
    var pattern: [32]u8 = undefined;
    for (&pattern, 0..) |*b, i| b.* = @truncate(i *% 91);
    var fbuf: [192]u8 = undefined;
    var fz: [192]u8 = undefined;
    const fp = try std.fmt.bufPrint(&fbuf, "{s}/rec.bin", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&fz, fp), &pattern));

    const srv = try TestServer.start(gpa, origin_d, cache_d, 16, "secret");
    defer srv.stop();
    const port = srv.port();

    const warm = try fetchRange(gpa, "secret", "127.0.0.1", port, "rec.bin", 0, 31);
    defer gpa.free(warm);

    // Age the entry past punchPiece's 10s recency window, as it would sit
    // between peer requests on an otherwise idle node under cull pressure.
    {
        const f = srv.store.lookupRef("rec.bin").?;
        defer srv.store.releaseFile(f);
        f.mu.lockUncancelable(std.testing.io);
        f.last_access.store(sys.monoSec() - 3600, .monotonic);
        f.mu.unlock(std.testing.io);
    }

    // Regression: serving a cached range over sendfile left last_access
    // ancient, so cullOne could punch a piece mid-stream and ship hole zeros
    // that the fetching peer then marked filled.
    const body = try fetchRange(gpa, "secret", "127.0.0.1", port, "rec.bin", 0, 31);
    defer gpa.free(body);
    try std.testing.expectEqualSlices(u8, &pattern, body);

    const f = srv.store.lookupRef("rec.bin").?;
    defer srv.store.releaseFile(f);
    try std.testing.expect(sys.monoSec() - f.last_access.load(.monotonic) < 10);
}

test "serveData refuses ranges starting past EOF with 416" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-srv-o-416");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-srv-c-416");
    defer sys.deleteTree(std.testing.io, cache_d);

    var fbuf: [192]u8 = undefined;
    var fz: [192]u8 = undefined;
    const fp = try std.fmt.bufPrint(&fbuf, "{s}/tiny.bin", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&fz, fp), "abc"));

    const srv = try TestServer.start(gpa, origin_d, cache_d, 16, "secret");
    defer srv.stop();
    const port = srv.port();

    // Start at/after EOF is genuinely unsatisfiable; the non-200/206 status
    // surfaces as HttpStatus through fetchRange.
    try std.testing.expectError(error.HttpStatus, fetchRange(gpa, "secret", "127.0.0.1", port, "tiny.bin", 3, 9));
    try std.testing.expectError(error.HttpStatus, fetchRange(gpa, "secret", "127.0.0.1", port, "tiny.bin", 100, 200));
    // Inverted range stays refused too.
    try std.testing.expectError(error.HttpStatus, fetchRange(gpa, "secret", "127.0.0.1", port, "tiny.bin", 2, 1));
}

test "fillFromPeers probes concurrently and streams piece into out" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-ffp-o");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-ffp-c");
    defer sys.deleteTree(std.testing.io, cache_d);

    // 16-byte file on the having peer; a second peer's origin lacks it.
    var pattern: [16]u8 = undefined;
    for (&pattern, 0..) |*b, i| b.* = @truncate(i *% 37);
    var fbuf: [192]u8 = undefined;
    var fz: [192]u8 = undefined;
    const fp = try std.fmt.bufPrint(&fbuf, "{s}/one.bin", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&fz, fp), &pattern));

    const srv = try TestServer.start(gpa, origin_d, cache_d, 16, "secret");
    defer srv.stop();
    const port = srv.port();

    // Warm the having peer through its own /data path: /have advertises
    // cached pieces only, so piece 0 must be hydrated before any probe.
    const warm = try fetchRange(gpa, "secret", "127.0.0.1", port, "one.bin", 0, 15);
    gpa.free(warm);

    var ob2: [128]u8 = undefined;
    var cb2: [128]u8 = undefined;
    const origin2 = try sys.scratchDir(&ob2, "modelfs-ffp-o2");
    defer sys.deleteTree(std.testing.io, origin2);
    const cache2 = try sys.scratchDir(&cb2, "modelfs-ffp-c2");
    defer sys.deleteTree(std.testing.io, cache2);
    const srv2 = try TestServer.start(gpa, origin2, cache2, 16, "secret");
    defer srv2.stop();
    const port2 = srv2.port();

    // Two candidates in path order: one whose origin lacks the file (/have
    // fails there), one that has it. The concurrent probe must mark the
    // first !have and stream the piece from the second.
    var cat = discover.Catalog.init(gpa, std.testing.io, origin_d, "me", &.{}, &.{}, &.{});
    defer cat.deinit();
    try cat.paths.append(gpa, .{
        .peer_id = "empty",
        .ip = "127.0.0.1",
        .port = port2,
        .ewma_bps = 1e9,
        .hops = 0,
    });
    try cat.paths.append(gpa, .{
        .peer_id = "full",
        .ip = "127.0.0.1",
        .port = port,
        .ewma_bps = 1e9,
        .hops = 0,
    });

    var out: [16]u8 = undefined;
    try fillFromPeers(gpa, "secret", &cat, "one.bin", 0, 16, &out);
    try std.testing.expectEqualSlices(u8, &pattern, &out);

    // Regression: a zero-length out (reachable only when a truncate raced
    // hydration) must fail cleanly instead of underflowing the requested
    // range end and aborting the daemon. The winning peer answers 206 with
    // Content-Length 1 against a 0-byte destination, the fetch fails with
    // LengthMismatch, and the candidate loop drains to NoPeer.
    try std.testing.expectError(error.NoPeer, fillFromPeers(gpa, "secret", &cat, "one.bin", 0, 16, &.{}));

    // No candidate has the piece: NoPeer surfaces (caller falls back to NFS).
    try std.testing.expectError(error.NoPeer, fillFromPeers(gpa, "secret", &cat, "missing.bin", 0, 16, &out));
}
