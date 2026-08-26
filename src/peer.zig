//! Peer HTTP server (/ping, /have, /data) and the matching fetch client:
//! bearer auth, bounded head reads, range hydration, and zero-copy streaming.
const std = @import("std");
const piece = @import("piece.zig");
const proto = @import("proto.zig");
const sys = @import("sys.zig");
const store_mod = @import("store.zig");
const discover = @import("discover.zig");
const fuzzcorpus = @import("fuzzcorpus.zig");
const c = sys.c;

pub const Server = struct {
    /// Concurrent connection handlers the accept loop admits, and the worker
    /// count fillFromPeers probes with: probing harder than a peer accepts
    /// would only buy rejections, so both sides share one cap.
    const max_inflight: u32 = 16;

    gpa: std.mem.Allocator,
    io: std.Io,
    psk: []const u8,
    store: *store_mod.Store,
    listen_fds: std.ArrayList(std.posix.fd_t) = .empty,
    /// Guards listen_fds between serve()'s accept-loop spawner and stop():
    /// an unmount landing while the freshly spawned serve thread is still
    /// walking the list would otherwise close fds and free the list under it.
    /// bindAll runs strictly before either thread exists, so it needs no lock.
    fds_mu: std.Io.Mutex = .init,
    running: std.atomic.Value(bool) = .init(true),
    http_inflight: std.atomic.Value(u32) = .init(0),

    pub fn bindAll(self: *Server, specs: []const proto.LeaseAddr) !void {
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
        // SO_REUSEADDR alone keeps restarts fast (TIME_WAIT leftovers from
        // accepted connections do not block the rebind). SO_REUSEPORT would
        // let a second modelfs bind the same live port and silently split
        // connections between the old and new process -- usually different
        // PSKs, so peers see random 401s -- instead of failing the duplicate
        // start loudly like the FUSE mount side does.
        _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, &yes, @sizeOf(c_int));
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
        // The spawn phase takes fds_mu so stop() cannot tear the list down
        // mid-walk; it must NOT span the join below, or an unmount would
        // block in stop() behind a lock serve only releases after every
        // accept loop exits.
        {
            // Reserve one slot per listener before spawning anything: an
            // append failure after a spawn used to detach that accept loop
            // beyond the join-all below, leaving it unsupervised at shutdown.
            self.fds_mu.lockUncancelable(self.io);
            defer self.fds_mu.unlock(self.io);
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
    }

    pub fn stop(self: *Server) void {
        self.running.store(false, .release);
        self.fds_mu.lockUncancelable(self.io);
        defer self.fds_mu.unlock(self.io);
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
        // The accepted address rides along so security-relevant events can
        // name their source; connection handlers are the only consumers.
        var peer: c.struct_sockaddr_in = undefined;
        var peer_len: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
        const cfd = c.accept(fd, .{ .__sockaddr__ = @ptrCast(&peer) }, &peer_len);
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
            // exhaustion (EMFILE/ENFILE) is worth acting on, a 50 Hz stream is
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
            // Counted rather than logged: each drop is one close(2), and
            // logging them would hand a connection storm the same
            // log-flooding lever the malformed-head path refuses. The
            // counter rides status.json and the tick line instead, so
            // saturation is visible without giving up the cap's flood
            // protection.
            _ = self.store.stats.http_dropped.fetchAdd(1, .monotonic);
            sys.close(cfd);
            continue;
        }
        const t = std.Thread.spawn(.{}, handleConn, .{ self, cfd, peer }) catch |err| {
            std.log.warn("peer http: connection handler spawn failed ({t}); dropping fd {d}", .{ err, cfd });
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
const head_deadline_ms: i64 = 10_000;

/// Largest request head the protocol can produce: a PATH_MAX rel whose bytes
/// all need percent-escaping encodes to three times its length, and the
/// bearer token rides verbatim up to proto.max_psk_bytes, with method,
/// target framing, Host, Range, and Connection overhead under the slack.
/// sendRequest builds into this budget and the server reads heads into it,
/// so every request a client can legally emit fits one head read on both
/// sides; sizing either side smaller would drop those requests instead of
/// serving them.
const max_head_bytes: usize = 4096 * 3 + proto.max_psk_bytes + 512;

/// Wall-clock budget for one response body, read or served: a base allowance
/// plus 1s per expected MiB (Content-Length is known before any body byte
/// moves). Same per-transfer-reset hole as the head budget covers: SO_RCVTIMEO
/// resets on every dribbled byte, so a slow sender must not hold a client fill
/// (and the piece's filling claim every other reader of that piece waits
/// behind) open-endedly; SO_SNDTIMEO resets on every drain, so a receiver
/// reading one byte per timeout window cannot pin a /data handler slot (plus
/// thread, socket, and entry reference) forever -- sixteen of those deaden the
/// peer service permanently. Scaled so healthy but slow links never trip it:
/// a 16 MiB piece gets 76s (needs ~0.2 MB/s).
const body_deadline_base_ms: i64 = 60_000;
const body_deadline_per_mib_ms: i64 = 1_000;

/// Deadline instant for the body budget above, stamped at the call so every
/// chunk check compares against one sample.
fn bodyDeadlineFor(want_len: u64) i64 {
    const mibs: i64 = @intCast(want_len / (1024 * 1024));
    return sys.monoMs() + body_deadline_base_ms + mibs * body_deadline_per_mib_ms;
}

/// Arms one blocking chunk against a total wall-clock budget. False when
/// `deadline_ms` has already passed (the caller reports its own timeout
/// error); otherwise the socket timeout is clamped to the remaining budget,
/// so the last blocking syscall wakes at the deadline instead of a full
/// steady-state window. One copy of this rule for every head/body/send
/// loop: the clamp condition and the expiry comparison must not drift
/// between them. Connections close when a transfer stage ends, so the
/// clamp never needs restoring mid-stage (readHeadFull restores it for the
/// body stages that follow a completed head).
fn armChunkTimeout(fd: std.posix.fd_t, deadline_ms: i64) bool {
    const remain_ms = deadline_ms - sys.monoMs();
    if (remain_ms <= 0) return false;
    if (remain_ms < sock_timeout_ms)
        sys.setSockTimeout(fd, @intCast(remain_ms));
    return true;
}

/// Cap on a peer-chosen Content-Length driving an allocation in
/// readFlexBodyAlloc. Caller-supplied destinations bypass it: their length is
/// verified against Content-Length instead.
const max_alloc_body_bytes: usize = 512 * 1024 * 1024;

/// Tighter cap on a peer-chosen /have body, which is a piece bitmap:
/// bytesLen(pieces) for the serving grid. 16 MiB names 2^27 pieces -- a 2 PiB
/// file at the default 16 MiB grid -- so any larger answer is broken or
/// hostile. Honoring it up to max_alloc_body_bytes would drive a half-gigabyte
/// allocation per probe, and havePut caches the answer (have_cache_cap
/// entries), pinning copies of it past the probe.
const max_have_body_bytes: usize = 16 * 1024 * 1024;

fn readHeadFull(fd: std.posix.fd_t, buf: []u8, out_head_len: *usize, out_total_read: *usize) !void {
    return readHeadFullDeadline(fd, buf, out_head_len, out_total_read, sys.monoMs() + head_deadline_ms);
}

/// readHeadFull with an injectable budget: a non-null deadline drives the
/// head stage directly (virtual time in tests and any caller that already
/// holds an instant), null stamps the real clock here like every production
/// entry point. One branch so the expiry rule stays in readHeadFullDeadline.
fn readHeadFullAt(fd: std.posix.fd_t, buf: []u8, out_head_len: *usize, out_total_read: *usize, deadline_ms: ?i64) !void {
    if (deadline_ms) |d| return readHeadFullDeadline(fd, buf, out_head_len, out_total_read, d);
    return readHeadFull(fd, buf, out_head_len, out_total_read);
}

fn readHeadFullDeadline(fd: std.posix.fd_t, buf: []u8, out_head_len: *usize, out_total_read: *usize, deadline_ms: i64) !void {
    var n: usize = 0;
    while (n < buf.len) {
        if (!armChunkTimeout(fd, deadline_ms)) return error.HeadTimeout;
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

/// "IP:port" text for a connected peer's address, for security-event log
/// lines. Falls back to "unknown" rather than failing the caller: an
/// unformattable address (never seen with AF_INET accepts) must still log.
fn peerAddrText(peer: c.struct_sockaddr_in, buf: []u8) []const u8 {
    const raw = std.mem.bigToNative(u32, peer.sin_addr.s_addr);
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}:{d}", .{
        @as(u8, @truncate(raw >> 24)),
        @as(u8, @truncate(raw >> 16)),
        @as(u8, @truncate(raw >> 8)),
        @as(u8, @truncate(raw)),
        std.mem.bigToNative(u16, peer.sin_port),
    }) catch "unknown";
}

fn handleConn(self: *Server, fd: std.posix.fd_t, peer: c.struct_sockaddr_in) void {
    defer {
        _ = self.http_inflight.fetchSub(1, .monotonic);
        sys.close(fd);
    }
    sys.setSockTimeout(fd, sock_timeout_ms);
    sys.setTcpNoDelay(fd);
    sys.setSockBuffers(fd, sock_buf_bytes);
    // Sized to max_head_bytes: the wire form of a legal deeply-nested
    // non-ASCII path plus a full-size bearer token must complete here, or
    // the connection is dropped as malformed instead of served.
    var head_buf: [max_head_bytes]u8 = undefined;
    var n: usize = 0;
    var total_read: usize = 0;
    readHeadFull(fd, &head_buf, &n, &total_read) catch {
        // Connect-and-drop scanners, dribbled heads, oversized heads: the
        // request never became routable, so there is nothing to answer and
        // logging each one would only hand scanners a log-flooding lever.
        // Counted so a probe storm is still visible in status.json.
        _ = self.store.stats.http_malformed.fetchAdd(1, .monotonic);
        return;
    };
    const head = head_buf[0..n];
    const line_end = std.mem.find(u8, head, "\r\n") orelse return;
    const line = head[0..line_end];
    var it = std.mem.splitScalar(u8, line, ' ');
    const method = it.next() orelse return;
    const target = it.next() orelse {
        // A completed head whose request line names no target ("HELP\r\n")
        // is the same scanner noise the timeout/oversize paths count; a
        // bare drop here would make those probes invisible to status.json.
        _ = self.store.stats.http_malformed.fetchAdd(1, .monotonic);
        return;
    };
    if (!std.mem.eql(u8, method, "GET")) {
        // RFC 9110 §15.5.5: a 405 must name the methods the resource
        // supports, so a probing client can discover the shape of the API.
        reply(fd, "HTTP/1.1 405 Method Not Allowed\r\nAllow: GET\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }
    const auth = proto.headerGet(head, "Authorization") orelse "";
    if (!proto.bearerOk(auth, self.psk)) {
        // Security-relevant event: without this line a wrong-PSK node or an
        // unauthenticated prober is invisible to the operator, and without
        // the source address a probing campaign leaves nothing to
        // investigate after the fact. Bounded by the accept loop's inflight
        // cap, so it cannot flood faster than 16/s.
        var abuf: [64]u8 = undefined;
        std.log.warn("peer http: rejected unauthorized request from {s}", .{peerAddrText(peer, &abuf)});
        _ = self.store.stats.http_unauthorized.fetchAdd(1, .monotonic);
        // RFC 9110 §15.5.2: a 401 must carry a challenge naming the scheme
        // a client should retry with; same empty-body framing as replyStatus.
        reply(fd, "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }
    const path = proto.pathOnly(target);
    if (std.mem.eql(u8, path, "/ping")) {
        reply(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
        return;
    }
    // Route before touching the query string: an unknown path is 404 no
    // matter what rides behind it. Validating the path parameter first used
    // to shadow the 404 branch, so e.g. "/nope" answered 400 on one request
    // shape and 404 on another.
    const routed = std.mem.eql(u8, path, "/have") or std.mem.eql(u8, path, "/data");
    if (!routed) {
        replyStatus(self, fd, "404 Not Found");
        return;
    }
    var rel_buf: [4096]u8 = undefined;
    const rel = decodePath(target, &rel_buf) catch {
        replyStatus(self, fd, "400 Bad Request");
        return;
    };
    // Remote-supplied paths join the origin/cache roots downstream; a ".."
    // component here would read (and via cache hydration, write) outside them.
    if (!store_mod.relOk(rel)) {
        replyStatus(self, fd, "400 Bad Request");
        return;
    }
    if (std.mem.eql(u8, path, "/have")) {
        serveHave(self, fd, rel);
        return;
    }
    {
        const rh = proto.headerGet(head, "Range") orelse {
            replyStatus(self, fd, "400 Bad Request");
            return;
        };
        const rg = proto.parseRange(rh) orelse {
            replyStatus(self, fd, "400 Bad Request");
            return;
        };
        serveData(self, fd, rel, rg);
    }
}

fn decodePath(target: []const u8, out: []u8) ![]u8 {
    const q = proto.queryGet(target, "path") orelse return error.NoPath;
    return proto.urlDecode(out, q);
}

fn serveHave(self: *Server, fd: std.posix.fd_t, rel: []const u8) void {
    var st: sys.c.struct_stat = undefined;
    const rc = self.store.statOrigin(rel, &st);
    if (rc != 0) {
        replyOriginStat(self, fd, rel, rc);
        return;
    }
    if ((st.st_mode & sys.c.S_IFMT) != sys.c.S_IFREG) {
        replyStatus(self, fd, "404 Not Found");
        return;
    }
    const file = self.store.get(rel, @intCast(st.st_size), sys.monoSec()) catch |err| {
        // The fetching peer only sees 500; without this line the serving
        // node's log says nothing about why.
        std.log.warn("cache entry open failed for {s} ({t}); replying 500", .{ rel, err });
        replyStatus(self, fd, "500 Internal Server Error");
        return;
    };
    defer self.store.releaseFile(file);
    // Snapshot the bits under the lock and answer outside it: a stalled peer
    // socket (30s send timeout) must not pin file.mu and freeze local reads,
    // fills, and culls for that file.
    file.mu.lockUncancelable(self.io);
    const snap = self.gpa.dupe(u8, file.bits.bytes) catch {
        file.mu.unlock(self.io);
        std.log.warn("have bits snapshot failed for {s}; replying 500", .{rel});
        replyStatus(self, fd, "500 Internal Server Error");
        return;
    };
    file.mu.unlock(self.io);
    defer self.gpa.free(snap);
    var hdr: [192]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nX-Piece-Size: {d}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ self.store.piece_size, snap.len }) catch {
        return;
    };
    _ = sys.writeAll(fd, h);
    const put = sys.writeAll(fd, snap);
    if (put < 0) {
        // The 200 header is already on the wire, so the fetching peer only
        // sees a truncated body; this line is the sender-side trace of why
        // (EPIPE/ECONNRESET for a departed peer, ETIMEDOUT for a stalled one).
        std.log.warn("have bits send failed for {s} (errno {d}); dropping peer transfer", .{ rel, -put });
    }
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
    const piece_size = self.store.piece_size;
    var pbuf: ?[]u8 = null;
    defer if (pbuf) |b| self.gpa.free(b);
    var pi = cov.start;
    while (pi < cov.end) : (pi += 1) {
        if (!self.store.hasPiece(file, pi, sys.monoSec())) {
            // Allocate before claiming: nothing but finishPiece removes a
            // filling entry, so an allocation failure after the claim would
            // leave the piece claimed forever and wedge every later filler
            // of it into the claim's retry spin.
            if (pbuf == null)
                pbuf = self.gpa.alloc(u8, piece_size) catch {
                    std.log.warn("hydration buffer alloc failed for {s} piece {d}; replying 500", .{ file.rel, pi });
                    replyStatus(self, fd, "500 Internal Server Error");
                    return false;
                };
            // Claim and completion take separate samples, like the FUSE
            // hydration path: a fill that streamed for minutes must land a
            // fresh recency stamp at completion, not the claim's.
            const cl = self.store.beginFill(file, pi, sys.monoSec()) catch {
                std.log.warn("fill claim failed for {s} piece {d}; replying 500", .{ file.rel, pi });
                replyStatus(self, fd, "500 Internal Server Error");
                return false;
            };
            switch (cl) {
                // A concurrent filler finished while we waited on its claim:
                // the hasPiece gate below re-checks the bit before streaming.
                .filled => {},
                // Truncate raced the claim and shrank the file below this
                // piece; the claim was dropped unmarked. Move on: replying
                // 404 would tell the peer the path is gone over a size race.
                .raced => continue,
                .len => |ln| {
                    const got = self.store.originPread(file.rel, pbuf.?[0..ln], piece.offset(pi, piece_size));
                    if (got == @as(isize, @intCast(ln))) {
                        const w = self.store.completeFill(file, pi, pbuf.?[0..ln], sys.monoSec());
                        if (w != 0) {
                            // The bytes are in hand but the cache fs refused them
                            // (full or failing disk). Falling through to the
                            // !hasPiece check would reply 404 and make the
                            // fetching peer believe the path is gone.
                            std.log.warn("cache write failed for {s} piece {d} (errno {d}); replying 500", .{ file.rel, pi, -w });
                            replyStatus(self, fd, "500 Internal Server Error");
                            return false;
                        }
                    } else {
                        self.store.finishPiece(file, pi, false, sys.monoSec());
                        // statOrigin passed, so the file exists: a failed or short
                        // read is an upstream (origin) failure. Reporting 404 here
                        // would make peers believe the path is gone. Log it too:
                        // the 502 alone leaves the local operator no trace of why
                        // hydration failed.
                        std.log.warn("origin pread failed for {s} piece {d} (rc {d}); replying 502", .{ file.rel, pi, -got });
                        replyStatus(self, fd, "502 Bad Gateway");
                        return false;
                    }
                },
            }
            // Only pieces that entered a fill claim need revalidation: a piece
            // already cached above skips this entirely, halving the per-piece
            // lock traffic on fully-warm transfers. Punches cannot land under
            // us either way -- serveData holds xfer across the whole response.
            if (!self.store.hasPiece(file, pi, sys.monoSec())) {
                replyStatus(self, fd, "404 Not Found");
                return false;
            }
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
/// want-sized allocation. `deadline_ms` bounds the whole send (see
/// bodyDeadlineFor): SO_SNDTIMEO resets on every drained byte, so the
/// per-chunk clamp to its remainder is what keeps a dribbling receiver from
/// holding an inflight slot forever.
fn streamRange(self: *Server, fd: std.posix.fd_t, file: *store_mod.Store.Cached, start: u64, want: u64, deadline_ms: i64) void {
    const cfd = self.store.openCache(file);
    if (cfd >= 0) {
        var done: u64 = 0;
        while (done < want) {
            if (!armChunkTimeout(fd, deadline_ms)) {
                std.log.warn("range send budget expired for {s} at offset {d} ({d}/{d}); dropping peer transfer", .{ file.rel, start + done, done, want });
                return;
            }
            file.last_access.store(sys.monoSec(), .monotonic);
            const take: usize = @intCast(@min(want - done, @as(u64, self.store.piece_size)));
            const sent = sys.sendfileAll(fd, cfd, start + done, take);
            if (sent != @as(isize, @intCast(take))) {
                // Partial kernel send with bytes already on the wire:
                // resending would duplicate them. Drop the connection and let
                // the peer treat it as a failed fetch. A failed FIRST chunk
                // still falls back to user-space streaming below.
                if (sent > 0 or done > 0) {
                    // The fetching peer only sees a truncated body; this line
                    // is the sender-side trace of where the transfer died. A
                    // negative result is an errno (EAGAIN is the send-timeout
                    // expiry), not a count -- name it as one.
                    if (sent < 0)
                        std.log.warn("sendfile failed for {s} at offset {d} (errno {d}); dropping peer transfer", .{ file.rel, start + done, -sent })
                    else
                        std.log.warn("sendfile short send for {s} at offset {d} ({d}/{d}); dropping peer transfer", .{ file.rel, start + done, sent, take });
                    return;
                }
                break;
            }
            done += take;
        }
        if (done == want) return;
    }

    const chunk_cap: usize = 4 * 1024 * 1024;
    const buf = self.gpa.alloc(u8, @min(want, chunk_cap)) catch {
        // The 206 header is already on the wire, so the peer only sees a
        // truncated body; this line is the sender-side trace of why.
        std.log.warn("range stream buffer alloc failed for {s}; dropping connection", .{file.rel});
        return;
    };
    defer self.gpa.free(buf);
    var off = start;
    var remaining = want;
    while (remaining > 0) {
        if (!armChunkTimeout(fd, deadline_ms)) {
            std.log.warn("range send budget expired for {s} at offset {d} ({d}/{d}); dropping peer transfer", .{ file.rel, off, want - remaining, want });
            return;
        }
        const take = @min(remaining, buf.len);
        const n = self.store.readCache(file, buf[0..take], off, sys.monoSec());
        if (n < 0 or @as(u64, @intCast(n)) != take) {
            // Same contract as the sendfile path: the peer sees a truncated
            // body, so the local log must carry where and why. A negative
            // result is an errno, not a count -- name it as one.
            if (n < 0)
                std.log.warn("cache read failed for {s} at offset {d} (errno {d}); dropping peer transfer", .{ file.rel, off, -n })
            else
                std.log.warn("cache short read for {s} at offset {d} ({d}/{d}); dropping peer transfer", .{ file.rel, off, n, take });
            return;
        }
        const w = sys.writeAll(fd, buf[0..take]);
        if (w < 0) {
            // Same contract as the sendfile and short-read paths above: the
            // peer sees a truncated body, so the local log must carry where
            // the transfer died.
            std.log.warn("peer send failed for {s} at offset {d} (errno {d}); dropping peer transfer", .{ file.rel, off, -w });
            return;
        }
        off += take;
        remaining -= take;
    }
}

fn serveData(self: *Server, fd: std.posix.fd_t, rel: []const u8, rg: proto.Range) void {
    var st: sys.c.struct_stat = undefined;
    const src = self.store.statOrigin(rel, &st);
    if (src != 0) {
        replyOriginStat(self, fd, rel, src);
        return;
    }
    // Same answer as /have for the same resource state: a directory (or any
    // non-regular file) at the path is a miss per the documented status
    // table ("no regular file at path"), not an origin failure. Without this
    // gate the directory's st_size passed the range checks and hydration's
    // pread on the dir fd turned it into a 502 -- one resource, two answers,
    // and fill_err_origin blaming the NFS tier for a client bug.
    if ((st.st_mode & sys.c.S_IFMT) != sys.c.S_IFREG) {
        replyStatus(self, fd, "404 Not Found");
        return;
    }
    const size: u64 = @intCast(st.st_size);
    if (rg.start >= size or rg.end < rg.start) {
        // RFC 9110 §15.5.17/§14.4: a 416 should carry the selected
        // representation's complete length, so a client can recompute a
        // satisfiable range instead of probing. Falls back to the bare
        // status framing if the header ever fails to render.
        var rbuf: [128]u8 = undefined;
        const r = std.fmt.bufPrint(&rbuf, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{d}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{size}) catch {
            replyStatus(self, fd, "416 Range Not Satisfiable");
            return;
        };
        reply(fd, r);
        return;
    }
    // An end position past the last byte still names a satisfiable range
    // (RFC 9110): it means "to EOF", so clamp instead of refusing. Refusing
    // here would break ordinary HTTP clients asking for the rest of the file;
    // the internal peer protocol always sends exact piece bounds.
    const rg_end = @min(rg.end, size - 1);
    const file = self.store.get(rel, size, sys.monoSec()) catch |err| {
        // Same operator-trace contract as serveHave's 500: the peer sees the
        // status alone, so the local log must carry the cause.
        std.log.warn("cache entry open failed for {s} ({t}); replying 500", .{ rel, err });
        replyStatus(self, fd, "500 Internal Server Error");
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
    const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {d}-{d}/{d}\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{
        rg.start, rg_end, size, want,
    }) catch return;
    _ = sys.writeAll(fd, h);

    streamRange(self, fd, file, rg.start, want, bodyDeadlineFor(want));
}

fn reply(fd: std.posix.fd_t, s: []const u8) void {
    _ = sys.writeAll(fd, s);
}

/// Empty-body response; every error path shares this framing. 5xx replies
/// feed the store's http_5xx counter so a failing node is visible in
/// status.json without grepping the journal.
fn replyStatus(self: *Server, fd: std.posix.fd_t, status: []const u8) void {
    if (status.len > 0 and status[0] == '5')
        _ = self.store.stats.http_5xx.fetchAdd(1, .monotonic);
    var buf: [96]u8 = undefined;
    const res = std.fmt.bufPrint(&buf, "HTTP/1.1 {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{status}) catch return;
    reply(fd, res);
}

/// 404 when the origin reports the path truly absent, 400 when the path is
/// too long to name any file under the origin root (client input, like the
/// other unsafe-path rejections: a 502 here would feed the http_5xx health
/// gauge and send peers retrying every node for a request that can never
/// succeed), 502 when the origin itself failed (NFS I/O error, stale mount):
/// a fetching peer and an operator must be able to tell a missing file from
/// an unavailable one.
fn replyOriginStat(self: *Server, fd: std.posix.fd_t, rel: []const u8, rc: i32) void {
    if (rc == -sys.c.ENOENT or rc == -sys.c.ENOTDIR) {
        replyStatus(self, fd, "404 Not Found");
    } else if (rc == -sys.c.ENAMETOOLONG) {
        replyStatus(self, fd, "400 Bad Request");
    } else {
        std.log.warn("origin stat failed for {s} (errno {d})", .{ rel, -rc });
        replyStatus(self, fd, "502 Bad Gateway");
    }
}

/// Fetches one /have answer: the peer's cached-piece bitmap plus the piece
/// size its bits are indexed against (X-Piece-Size). A bitmap's bit i names
/// pieces of the SERVER's --piece grid, so without the size on the wire a
/// fleet running mixed piece sizes silently misreads every answer -- bit i
/// covers different byte ranges per node. Absent header (an older peer)
/// reads as 0, meaning unknown; consumers assume alignment for those. A
/// malformed header fails the probe like any other bad reply so failures
/// stay uncached and retried.
fn fetchHave(gpa: std.mem.Allocator, psk: []const u8, ip: []const u8, port: u16, rel: []const u8) !discover.HaveBits {
    return fetchHaveDeadline(gpa, psk, ip, port, rel, null);
}

/// fetchHave with an injectable budget (see readHeadFullAt): a non-null
/// deadline bounds both the head stage and the bitmap body as one span, so
/// tests expire the probe virtually instead of waiting out SO_RCVTIMEO.
fn fetchHaveDeadline(gpa: std.mem.Allocator, psk: []const u8, ip: []const u8, port: u16, rel: []const u8, deadline_ms: ?i64) !discover.HaveBits {
    const fd = try sendRequest(psk, ip, port, rel, null);
    defer sys.close(fd);
    var head_buf: [8192]u8 = undefined;
    var head_len: usize = 0;
    var total_read: usize = 0;
    readHeadFullAt(fd, &head_buf, &head_len, &total_read, deadline_ms) catch return error.Head;
    return haveFromHeadDeadline(gpa, fd, &head_buf, head_len, total_read, deadline_ms);
}

/// Parses one /have response head (already read, body bytes possibly
/// pipelined behind it in head_buf) and completes the bitmap body. The
/// seam between dialing and parsing so tests can drive replies directly.
fn haveFromHead(gpa: std.mem.Allocator, fd: std.posix.fd_t, head_buf: []const u8, head_len: usize, total_read: usize) !discover.HaveBits {
    return haveFromHeadDeadline(gpa, fd, head_buf, head_len, total_read, null);
}

fn haveFromHeadDeadline(gpa: std.mem.Allocator, fd: std.posix.fd_t, head_buf: []const u8, head_len: usize, total_read: usize, deadline_ms: ?i64) !discover.HaveBits {
    const head = head_buf[0..head_len];
    const status_end = std.mem.find(u8, head, "\r\n") orelse return error.BadHttp;
    if (!std.mem.startsWith(u8, head[0..status_end], "HTTP/1.1 200")) {
        // A 404 is a healthy peer answering "not cached here" -- the normal
        // shape of a fleet where replicas differ. It gets its own error so
        // the probe-failure counter can exclude it and stay meaningful;
        // everything else (auth rejected, peer broken, malformed reply)
        // means this node cannot actually talk to the cluster.
        if (std.mem.startsWith(u8, head[0..status_end], "HTTP/1.1 404")) return error.PeerMiss;
        return error.HttpStatus;
    }
    const ps_str = proto.headerGet(head, "X-Piece-Size") orelse "0";
    const piece_size = std.fmt.parseInt(u32, ps_str, 10) catch return error.BadPieceSize;
    // Refuse absurd bitmaps before the allocation instead of letting
    // finishBodyAlloc honor them up to max_alloc_body_bytes (see
    // max_have_body_bytes). A missing header reads as length 0, matching the
    // zero-length success below.
    const cl_str = proto.headerGet(head, "Content-Length") orelse "0";
    const declared = std.fmt.parseInt(usize, cl_str, 10) catch 0;
    if (declared > max_have_body_bytes) return error.BodyTooLarge;
    const bits = try finishBodyAlloc(gpa, fd, head_buf, head_len, total_read, null, deadline_ms);
    return .{ .bits = bits, .piece_size = piece_size };
}

/// Dials and sends one GET (/have, or /data when range is set); returns the
/// connected socket with the request already on the wire. One builder for
/// both shapes so URL encoding, bearer auth, and Connection framing cannot
/// drift between them.
fn sendRequest(psk: []const u8, ip: []const u8, port: u16, rel: []const u8, range: ?proto.Range) !c_int {
    var qbuf: [4096 * 3]u8 = undefined;
    const enc = try proto.urlEncode(&qbuf, rel);
    var req: [max_head_bytes]u8 = undefined;
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

fn fetchRange(gpa: std.mem.Allocator, psk: []const u8, ip: []const u8, port: u16, rel: []const u8, start: u64, end: u64) ![]u8 {
    return fetchRangeDeadline(gpa, psk, ip, port, rel, start, end, null);
}

/// Fetch variants with an injectable budget (see readHeadFullAt): a non-null
/// deadline bounds head and body stages as one span, so a test expires the
/// transfer virtually instead of holding real socket timeouts open.
fn fetchRangeDeadline(gpa: std.mem.Allocator, psk: []const u8, ip: []const u8, port: u16, rel: []const u8, start: u64, end: u64, deadline_ms: ?i64) ![]u8 {
    const fd = try sendRequest(psk, ip, port, rel, .{ .start = start, .end = end });
    defer sys.close(fd);
    return readFlexBodyAllocDeadline(gpa, fd, null, deadline_ms);
}

/// Like fetchRange, but streams the body directly into `out` (whose length
/// must match the peer's Content-Length): one fewer piece-sized allocation
/// and copy per fetched piece.
fn fetchRangeInto(gpa: std.mem.Allocator, psk: []const u8, ip: []const u8, port: u16, rel: []const u8, start: u64, end: u64, out: []u8) !void {
    return fetchRangeIntoDeadline(gpa, psk, ip, port, rel, start, end, out, null);
}

fn fetchRangeIntoDeadline(gpa: std.mem.Allocator, psk: []const u8, ip: []const u8, port: u16, rel: []const u8, start: u64, end: u64, out: []u8, deadline_ms: ?i64) !void {
    const fd = try sendRequest(psk, ip, port, rel, .{ .start = start, .end = end });
    defer sys.close(fd);
    _ = try readFlexBodyAllocDeadline(gpa, fd, out, deadline_ms);
}

fn rangeBps(bytes: u64, dt_ns: i128) f64 {
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
    sys.setTcpNoDelay(fd);
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
    return readFlexBodyAllocDeadline(gpa, fd, dest, null);
}

fn readFlexBodyAllocDeadline(gpa: std.mem.Allocator, fd: std.posix.fd_t, dest: ?[]u8, deadline_ms: ?i64) ![]u8 {
    var head_buf: [8192]u8 = undefined;
    var head_len: usize = 0;
    var total_read: usize = 0;
    readHeadFullAt(fd, &head_buf, &head_len, &total_read, deadline_ms) catch return error.Head;
    return finishBodyAlloc(gpa, fd, &head_buf, head_len, total_read, dest, deadline_ms);
}

/// Completes a response body whose head is already read: validates the
/// status line, lifts pipelined body bytes out of head_buf, enforces
/// Content-Length against dest (or allocates), and streams to the deadline.
/// The one body reader every fetch path shares, so the length-matching
/// contract cannot drift between them. head_buf must stay alive for the
/// call; the returned slice never aliases it.
fn finishBodyAlloc(gpa: std.mem.Allocator, fd: std.posix.fd_t, head_buf: []const u8, head_len: usize, total_read: usize, dest: ?[]u8, deadline_ms: ?i64) ![]u8 {
    const head = head_buf[0..head_len];
    const status_end = std.mem.find(u8, head, "\r\n") orelse return error.BadHttp;
    const status_line = head[0..status_end];
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 200") and
        !std.mem.startsWith(u8, status_line, "HTTP/1.1 206"))
    {
        return error.HttpStatus;
    }

    const cl_str = proto.headerGet(head, "Content-Length") orelse "0";
    // A malformed or overflowing length is a broken reply, not a zero-byte
    // one: coercing it to 0 would let e.g. "Content-Length: 16Mi" succeed as
    // an empty body, and the /have caller would then cache an empty bitmap
    // and route every fill away from a healthy peer for the probe TTL. Same
    // policy as haveFromHead's X-Piece-Size parse. An absent header keeps its
    // legacy 0 reading; the dest-length contract below still fails those.
    const want_len = std.fmt.parseInt(usize, cl_str, 10) catch return error.BadContentLength;

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
        if (want_len > max_alloc_body_bytes) return error.BodyTooLarge;
        if (want_len == 0) return try gpa.alloc(u8, 0);
    }
    // Now that the expected length is known, size the total budget to it.
    const deadline = deadline_ms orelse bodyDeadlineFor(want_len);

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
        if (!armChunkTimeout(fd, deadline)) return error.BodyTimeout;
        const n = sys.readOnce(fd, buf[got..]) catch {
            if (deadline - sys.monoMs() <= 0) return error.BodyTimeout;
            return error.Read;
        };
        if (n == 0) {
            if (deadline - sys.monoMs() <= 0) return error.BodyTimeout;
            break;
        }
        got += n;
    }
    if (got != want_len) return error.ReadIncomplete;
    return buf;
}

const ProbeCtx = struct {
    gpa: std.mem.Allocator,
    psk: []const u8,
    rel: []const u8,
    paths: []const discover.Path,
    /// Per unique peer id: indexes into paths, ordered best-first by the
    /// lease priors (discover.pathScore over ewma/hops).
    groups: []const []const usize,
    /// Group indexes that still need a probe (the rest came from cache).
    todo: []const usize,
    slots: []?discover.HaveBits,
    cat: *discover.Catalog,
    stats: ?*store_mod.Stats = null,
    /// The fill's one edge instant (see probeSlots): fresh answers are put
    /// into the have cache stamped with the same sample the cache-hit
    /// decisions ran on, so every TTL entry this fill writes is a pure
    /// function of the tick's clock sample, never of when each worker
    /// happened to win its slot.
    now_ms: i64,
    next: std.atomic.Value(u32) = .init(0),
};

/// Claims one unprobed group at a time and records its /have answer (null on
/// failure). Addresses are tried best-first: the first answer wins, so a
/// healthy multi-homed node costs one wire round trip total, and a dead
/// preferred address falls through to the same node's remaining interfaces
/// instead of hiding the whole node behind one unreachable NIC. Successes
/// feed the catalog's short-TTL have cache so later pieces of the same file
/// skip the probe entirely. A failed address is counted unless it answered
/// 404 (a healthy peer without the file): without this count, PSK drift or
/// a partitioned peer silently degrades every fill to the origin tier.
fn probeWorker(ctx: *ProbeCtx) void {
    while (true) {
        const t = ctx.next.fetchAdd(1, .monotonic);
        if (t >= ctx.todo.len) return;
        const gi = ctx.todo[t];
        for (ctx.groups[gi]) |pi| {
            const p = ctx.paths[pi];
            const rep = fetchHave(ctx.gpa, ctx.psk, p.ip, p.port, ctx.rel) catch |err| {
                if (err != error.PeerMiss) {
                    if (ctx.stats) |s| _ = s.probe_err.fetchAdd(1, .monotonic);
                }
                continue;
            };
            ctx.slots[gi] = rep;
            ctx.cat.havePut(ctx.rel, p.ip, p.port, rep.bits, rep.piece_size, ctx.now_ms);
            break;
        }
    }
}

/// Fills slots[] with one /have bitmap per peer group: groups answered by the
/// recent-probe cache skip the wire entirely; the rest are probed
/// concurrently (a serial probe would pay one full connect+request+response
/// round trip per peer before any piece data moves), walking each group's
/// addresses best-first until one answers. slots must be all-null.
fn probeSlots(
    gpa: std.mem.Allocator,
    psk: []const u8,
    cat: *discover.Catalog,
    rel: []const u8,
    paths: []const discover.Path,
    groups: []const []const usize,
    slots: []?discover.HaveBits,
    stats: ?*store_mod.Stats,
) !void {
    var todo: std.ArrayList(usize) = .empty;
    defer todo.deinit(gpa);
    // One edge instant for the whole fill: cache-hit decisions across groups
    // share the same clock sample instead of drifting mid-walk, and the
    // probe workers stamp their fresh answers into the have cache with this
    // same sample (see ProbeCtx.now_ms).
    const now_ms = sys.monoMs();
    for (groups, 0..) |g, gi| {
        var answered = false;
        for (g) |pi| {
            const p = paths[pi];
            if (cat.haveGet(gpa, rel, p.ip, p.port, now_ms)) |cached| {
                slots[gi] = cached;
                answered = true;
                break;
            }
        }
        if (!answered) try todo.append(gpa, gi);
    }
    if (todo.items.len == 0) return;

    var ctx = ProbeCtx{
        .gpa = gpa,
        .psk = psk,
        .rel = rel,
        .paths = paths,
        .groups = groups,
        .todo = todo.items,
        .slots = slots,
        .cat = cat,
        .stats = stats,
        .now_ms = now_ms,
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

/// Total order for the probe walk inside one peer-id group: higher lease
/// prior first (pathScore with inflight fixed at 0, the pre-probe state),
/// then pathTieLess (ip bytes, then port). The tie-break is
/// what keeps the walk a function of the address set alone: on a cold
/// cluster every path carries the same prior, so without it the first-tried
/// address would be decided by the publisher's getifaddrs order riding in
/// the lease document -- environment enumeration order choosing which NIC
/// gets the wire round trip and the first goodput sample.
fn probeOrderLess(a: discover.Path, b: discover.Path) bool {
    const sa = discover.pathScore(a.ewma_bps, a.hops, 0);
    const sb = discover.pathScore(b.ewma_bps, b.hops, 0);
    if (sa != sb) return sa > sb;
    return discover.pathTieLess(a, b);
}

/// Groups snapshot indexes by unique peer id, each group sorted best-first
/// by probeOrderLess. Caller frees the outer slice and every inner group
/// with gpa.
fn groupPathsByPeerId(gpa: std.mem.Allocator, paths: []const discover.Path) ![][]usize {
    var groups: std.ArrayList([]usize) = .empty;
    errdefer {
        for (groups.items) |g| gpa.free(g);
        groups.deinit(gpa);
    }
    var group_of = std.StringHashMap(usize).init(gpa);
    defer group_of.deinit();
    for (paths, 0..) |p, pi| {
        const gop = try group_of.getOrPut(p.peer_id);
        if (!gop.found_existing) {
            const g = try gpa.alloc(usize, 1);
            errdefer gpa.free(g);
            g[0] = pi;
            try groups.append(gpa, g);
            gop.value_ptr.* = groups.items.len - 1;
            continue;
        }
        const g = try gpa.realloc(groups.items[gop.value_ptr.*], groups.items[gop.value_ptr.*].len + 1);
        groups.items[gop.value_ptr.*] = g;
        // Insertion sort by the total order: equal-score addresses land in
        // ip/port order instead of lease arrival order (see probeOrderLess).
        g[g.len - 1] = pi;
        var j = g.len - 1;
        while (j > 0 and probeOrderLess(paths[g[j]], paths[g[j - 1]])) {
            std.mem.swap(usize, &g[j], &g[j - 1]);
            j -= 1;
        }
    }
    return groups.toOwnedSlice(gpa);
}

/// Snapshot of the catalog reduced to one candidate per lease path, each
/// carrying its node's /have answer for piece idx: peers answered by the
/// recent-probe cache skip the wire; the rest are probed concurrently, one
/// best-first address walk per unique peer id. local_piece_size is this
/// node's grid; a peer whose advertised grid differs answers unusable bits,
/// so its candidates are marked !have rather than routing fills by them.
/// Caller frees the returned slice with gpa.
fn probeCandidates(gpa: std.mem.Allocator, psk: []const u8, cat: *discover.Catalog, rel: []const u8, idx: u32, local_piece_size: u32, stats: ?*store_mod.Stats) ![]discover.PathCand {
    const paths = try cat.snapshot(gpa);
    defer discover.Catalog.freeSnapshot(gpa, paths);

    // Probing every address of every node would duplicate wire round trips
    // and slots; probing only each node's first lease entry would probe
    // interface enumeration order instead of fabric preference -- on
    // multi-homed hosts that is whichever NIC getifaddrs listed first,
    // which strands every fetch there no matter what pathScore would have
    // picked. The walk keeps one probe per healthy node while letting a down
    // preferred address fall through to that node's remaining interfaces.
    const groups = try groupPathsByPeerId(gpa, paths);
    defer {
        for (groups) |g| gpa.free(g);
        gpa.free(groups);
    }
    // peer_id -> group slot: each group's first index carries the group's
    // peer id by construction (the entry that created the group).
    var group_of = std.StringHashMap(usize).init(gpa);
    defer group_of.deinit();
    for (groups, 0..) |g, gi| {
        try group_of.put(paths[g[0]].peer_id, gi);
    }

    const slots = try gpa.alloc(?discover.HaveBits, groups.len);
    defer {
        for (slots) |s| if (s) |rep| gpa.free(rep.bits);
        gpa.free(slots);
    }
    @memset(slots, null);

    // One concurrent best-first probe per unique peer id, so a sequential
    // fill of one file probes once per peer per TTL instead of once per piece.
    try probeSlots(gpa, psk, cat, rel, paths, groups, slots, stats);

    var cands: std.ArrayList(discover.PathCand) = .empty;
    errdefer {
        for (cands.items) |cand| gpa.free(cand.ip);
        cands.deinit(gpa);
    }
    for (paths) |p| {
        var has = false;
        if (group_of.get(p.peer_id)) |gi| {
            if (slots[gi]) |rep| {
                // A bitmap's bit i names pieces of the answering peer's
                // --piece grid. Only an answer indexed against our own grid
                // can route a fill; a mismatched one is treated as no
                // answer (the fetch falls through to the next peer, then
                // origin) instead of reading bits that cover different
                // byte ranges than ours. piece_size 0 means the peer did
                // not advertise one: assume alignment for compatibility.
                if (rep.piece_size == 0 or rep.piece_size == local_piece_size) {
                    has = idx / 8 < rep.bits.len and (rep.bits[idx / 8] & (@as(u8, 1) << @intCast(idx % 8))) != 0;
                }
            }
        }
        const ip_copy = try gpa.dupe(u8, p.ip);
        errdefer gpa.free(ip_copy);
        try cands.append(gpa, .{
            .ip = ip_copy,
            .port = p.port,
            .ewma_bps = p.ewma_bps,
            .hops = p.hops,
            .inflight = p.inflight.load(.monotonic),
            .have = has,
        });
    }
    return cands.toOwnedSlice(gpa);
}

pub fn fillFromPeers(
    gpa: std.mem.Allocator,
    psk: []const u8,
    cat: *discover.Catalog,
    rel: []const u8,
    idx: u32,
    piece_size: u32,
    out: []u8,
    stats: ?*store_mod.Stats,
) !void {
    const cands = try probeCandidates(gpa, psk, cat, rel, idx, piece_size, stats);
    defer {
        for (cands) |cand| gpa.free(cand.ip);
        gpa.free(cands);
    }

    // exclusive: one winner, then next on failure, then error (caller uses NFS)
    var remaining = cands;
    while (discover.pickBest(remaining)) |bi| {
        const win = remaining[bi];
        _ = cat.inflight(win.ip, win.port, 1);
        const start = piece.offset(idx, piece_size);
        // Saturating: a caller passing an empty buffer (only possible via an
        // out-of-band truncate race today) must not underflow the range end.
        const end = start +| out.len -| 1;
        const t0 = sys.monoNs();
        // Stream the body straight into out: no piece-sized allocation or
        // copy on the fetch path.
        fetchRangeInto(gpa, psk, win.ip, win.port, rel, start, end, out) catch |err| {
            // The loop falls through to the next candidate (then the caller
            // falls back to the origin), but without this line nothing
            // records which dependency failed and why -- the read would
            // simply come back slow from NFS with no trace of the peer that
            // should have served it. Counted here rather than at the caller
            // so "nobody had the piece" (NoPeer with no attempt made) stays
            // out of the failure counters.
            std.log.warn("piece fetch failed on {s}:{d} for {s} piece {d}: {t}", .{ win.ip, win.port, rel, idx, err });
            if (stats) |s| _ = s.fill_err_peer.fetchAdd(1, .monotonic);
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
    // Exact rate: 16 MiB over 8 ms.
    const b = rangeBps(16 * 1024 * 1024, 8_000_000);
    try std.testing.expectEqual(@as(f64, 16 * 1024 * 1024) / 0.008, b);
    // A non-positive elapsed time must yield 0, not inf/NaN (it feeds
    // updateGoodput's EWMA, which would poison the path score).
    try std.testing.expectEqual(@as(f64, 0), rangeBps(16 * 1024 * 1024, 0));
    try std.testing.expectEqual(@as(f64, 0), rangeBps(16 * 1024 * 1024, -1));
}

test "groupPathsByPeerId orders ties by ip and port, never by arrival order" {
    const gpa = std.testing.allocator;
    // One multi-homed node whose lease lists addresses in scrambled order
    // (that order is the publisher's getifaddrs enumeration). Cold-cluster
    // priors are equal, so the probe walk's first-tried address must follow
    // ip/port bytes alone: both arrival permutations below must produce the
    // same per-group walk. Regression: ties used to keep lease arrival
    // order, letting environment enumeration choose which NIC got probed
    // (and the goodput sample) first.
    const mk = struct {
        fn path(id: []const u8, ip: []const u8, port: u16, mbps_bps: f64) discover.Path {
            return .{ .peer_id = id, .ip = ip, .port = port, .ewma_bps = mbps_bps, .hops = 0 };
        }
    }.path;
    const fabric = 25e9;
    const mgmt = 1e8;
    const a1 = mk("spark", "10.0.0.9", 18080, fabric); // highest prior...
    const a2 = mk("spark", "10.0.0.5", 18080, mgmt);
    const a3 = mk("spark", "10.0.0.5", 18081, mgmt);
    const b1 = mk("other", "10.1.0.1", 18080, mgmt);

    const groups1 = try groupPathsByPeerId(gpa, &.{ a1, a2, a3, b1 });
    defer {
        for (groups1) |g| gpa.free(g);
        gpa.free(groups1);
    }
    const groups2 = try groupPathsByPeerId(gpa, &.{ b1, a3, a2, a1 });
    defer {
        for (groups2) |g| gpa.free(g);
        gpa.free(groups2);
    }

    try std.testing.expectEqual(@as(usize, 2), groups1.len);
    // Highest prior walks first; equal-prior ties break by ip, then port.
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, groups1[0]);
    try std.testing.expectEqualSlices(usize, &.{3}, groups1[1]);

    try std.testing.expectEqual(@as(usize, 2), groups2.len);
    // Same addresses, reversed arrival: identical walk order per group
    // (fabric address first, then the mgmt pair by ip/port).
    try std.testing.expectEqualSlices(usize, &.{0}, groups2[0]);
    try std.testing.expectEqualSlices(usize, &.{ 3, 2, 1 }, groups2[1]);
}

test "peerAddrText formats the accepted peer address for security logs" {
    // The 401 rejection line names its source: a probing campaign must be
    // attributable after the fact (THREAT_MODEL R8). Loopback and a routable
    // address both format exactly, port included.
    var buf: [64]u8 = undefined;
    const lo = loopbackAddr(18080);
    try std.testing.expectEqualStrings("127.0.0.1:18080", peerAddrText(lo, &buf));

    var far = std.mem.zeroes(c.struct_sockaddr_in);
    far.sin_port = std.mem.nativeToBig(u16, 65535);
    far.sin_addr.s_addr = std.mem.nativeToBig(u32, 0xC0A80064); // 192.168.0.100
    try std.testing.expectEqualStrings("192.168.0.100:65535", peerAddrText(far, &buf));
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

test "readFlexBodyAlloc rejects a malformed Content-Length instead of coercing to 0" {
    const gpa = std.testing.allocator;
    // Regression: an unparsable or overflowing length used to read as 0, so
    // a 200 reply with e.g. "Content-Length: 16Mi" succeeded as an empty
    // body and fetchHave cached an empty bitmap for the probe TTL, routing
    // every fill away from a healthy peer. It must fail like any other
    // malformed reply so it stays uncached and retried.
    {
        const pair = try responsePair("HTTP/1.1 200 OK\r\nContent-Length: 16Mi\r\nConnection: close\r\n\r\n0123456789abcdef");
        defer sys.close(pair[0]);
        defer sys.close(pair[1]);
        try std.testing.expectError(error.BadContentLength, readFlexBodyAlloc(gpa, pair[1], null));
    }
    // Digit runs beyond usize must fail too, not wrap into a small length.
    {
        const pair = try responsePair("HTTP/1.1 206 Partial Content\r\nContent-Length: 99999999999999999999999\r\nConnection: close\r\n\r\n");
        defer sys.close(pair[0]);
        defer sys.close(pair[1]);
        try std.testing.expectError(error.BadContentLength, readFlexBodyAlloc(gpa, pair[1], null));
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

test "readFlexBodyAllocDeadline aborts a dribbled body at the deadline" {
    // Half the promised body, then silence. SO_RCVTIMEO alone resets on the
    // dribble, so the fetch -- and on the fill path, the piece's filling
    // claim every other reader of that piece spins behind -- would hang
    // forever; the total body budget must expire instead.
    const pair = try responsePair("HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\n1234");
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    const t0 = sys.monoMs();
    const err = readFlexBodyAllocDeadline(std.testing.allocator, pair[1], null, t0 + 150);
    try std.testing.expectError(error.BodyTimeout, err);
    try std.testing.expect(sys.monoMs() - t0 <= 2000);
}

test "readHeadFullAt expires an injected budget without waiting real time" {
    // Nothing staged and an already-past budget: the first armChunkTimeout
    // check must refuse before any blocking syscall, so a simulator (or this
    // test) can drive head expiry virtually instead of holding a socket
    // timeout open for sock_timeout_ms.
    const pair = try responsePair("");
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    var head_len: usize = 0;
    var total: usize = 0;
    var buf: [64]u8 = undefined;
    const t0 = sys.monoMs();
    const err = readHeadFullAt(pair[1], &buf, &head_len, &total, t0 - 1);
    try std.testing.expectError(error.HeadTimeout, err);
    try std.testing.expect(sys.monoMs() - t0 <= 2000);
}

test "haveFromHeadDeadline pairs refusal at an expired budget with success at a live one" {
    const gpa = std.testing.allocator;
    const wire = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX-Piece-Size: 4096\r\nConnection: close\r\n\r\nok";
    const head_len = std.mem.indexOf(u8, wire, "\r\n\r\n").? + 4;
    // Drains exactly the head bytes off the socket, leaving only the bitmap
    // body staged -- the state fetchHaveDeadline hands to this function.
    const drainHead = struct {
        fn go(fd: std.posix.fd_t, head_bytes: usize) !void {
            var sink: [96]u8 = undefined;
            var got: usize = 0;
            while (got < head_bytes) {
                // Capped so a coalesced read cannot swallow staged body
                // bytes past the head.
                got += try sys.readOnce(fd, sink[0 .. head_bytes - got]);
            }
        }
    }.go;
    // Head pre-read exactly like fetchHaveDeadline leaves it; the bitmap
    // bytes stay staged in the socket behind it.
    {
        // Fully staged reply, expired budget: no further byte may move under
        // a dead budget, even bytes already in the receive buffer -- same
        // rule streamRange applies to the send side.
        const pair = try responsePair(wire);
        defer sys.close(pair[0]);
        defer sys.close(pair[1]);
        try drainHead(pair[1], head_len);
        const t0 = sys.monoMs();
        try std.testing.expectError(error.BodyTimeout, haveFromHeadDeadline(gpa, pair[1], wire[0..head_len], head_len, head_len, t0 - 1));
    }
    {
        // The identical reply under a live injected budget parses exactly as
        // the real-clock path would: injection changes only when the budget
        // expires, never what a valid answer yields.
        const pair = try responsePair(wire);
        defer sys.close(pair[0]);
        defer sys.close(pair[1]);
        try drainHead(pair[1], head_len);
        const rep = try haveFromHeadDeadline(gpa, pair[1], wire[0..head_len], head_len, head_len, sys.monoMs() + 60_000);
        defer gpa.free(rep.bits);
        try std.testing.expectEqualSlices(u8, "ok", rep.bits);
        try std.testing.expectEqual(@as(u32, 4096), rep.piece_size);
    }
}

test "streamRange honors the response body budget in both directions" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-srv-o-budget");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-srv-c-budget");
    defer sys.deleteTree(std.testing.io, cache_d);

    // Two pieces at piece size 16, warmed so streamRange takes the sendfile
    // path against a real cache data file.
    var pattern: [32]u8 = undefined;
    for (&pattern, 0..) |*b, i| b.* = @truncate(i *% 57 + 5);
    var fbuf: [192]u8 = undefined;
    var fz: [192]u8 = undefined;
    const fp = try std.fmt.bufPrint(&fbuf, "{s}/budget.bin", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&fz, fp), &pattern));

    const srv = try TestServer.start(gpa, origin_d, cache_d, 16, "secret");
    defer srv.stop();

    const warm = try fetchRange(gpa, "secret", "127.0.0.1", srv.port(), "budget.bin", 0, 31);
    gpa.free(warm);

    const f = srv.store.lookupRef("budget.bin").?;
    defer srv.store.releaseFile(f);

    // Expired budget: the send must refuse before writing a byte and return
    // immediately instead of holding the inflight slot for a receiver that
    // drains one byte per timeout window (SO_SNDTIMEO resets on every such
    // drain; only the total budget ends the transfer). Expected-path warning
    // kept off the runner's stderr like the sibling fault-tolerance tests.
    {
        const prev_log_level = std.testing.log_level;
        std.testing.log_level = .err;
        defer std.testing.log_level = prev_log_level;
        const pair = try responsePair("");
        defer sys.close(pair[0]);
        defer sys.close(pair[1]);
        const t0 = sys.monoMs();
        streamRange(&srv.server, pair[1], f, 0, pattern.len, t0 - 1);
        try std.testing.expect(sys.monoMs() - t0 <= 2000);
        var probe: [1]u8 = undefined;
        try std.testing.expect(c.recv(pair[0], &probe, probe.len, c.MSG_PEEK | c.MSG_DONTWAIT) < 0);
    }
    // Live budget: the same range streams in full.
    {
        const pair = try responsePair("");
        defer sys.close(pair[0]);
        defer sys.close(pair[1]);
        streamRange(&srv.server, pair[1], f, 0, pattern.len, sys.monoMs() + 60_000);
        var got: [pattern.len]u8 = undefined;
        const n = sys.readOnce(pair[0], &got) catch 0;
        try std.testing.expectEqual(@as(usize, got.len), n);
        try std.testing.expectEqualSlices(u8, &pattern, &got);
    }
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

test "duplicate bind of a live port fails instead of sharing it" {
    // Re-execution guard: starting a second daemon against a port whose
    // first owner still lives must fail loudly (EADDRINUSE), never silently
    // share the port via SO_REUSEPORT and split connections -- typically
    // across two different PSKs -- between old and new process.
    const gpa = std.testing.allocator;
    var first = Server{
        .gpa = gpa,
        .io = std.testing.io,
        .psk = "secret",
        .store = undefined,
    };
    try first.bindOne("127.0.0.1", 0);
    const port = boundPort(first.listen_fds.items[0]);
    try std.testing.expect(port > 0);

    var second = Server{
        .gpa = gpa,
        .io = std.testing.io,
        .psk = "other-secret",
        .store = undefined,
    };
    try std.testing.expectError(error.Bind, second.bindOne("127.0.0.1", port));
    // The refused bind must not leave a listener behind.
    try std.testing.expectEqual(@as(usize, 0), second.listen_fds.items.len);

    first.stop();
}

test "bindAll collapses duplicate specs and refuses an already-bound port" {
    const gpa = std.testing.allocator;
    const spec = struct {
        fn addr(port: u16) proto.LeaseAddr {
            return .{ .ip = "", .port = port };
        }
    }.addr;

    // Kernel-chosen ports everywhere, like every sibling test: nothing here
    // races a fixed default (18080) a modelfs instance may already own.
    // Duplicate port-0 specs name one port as far as the seen-port set is
    // concerned, so they collapse into a single listener instead of two fds
    // fighting over one address.
    var dedup = Server{ .gpa = gpa, .io = std.testing.io, .psk = "secret", .store = undefined };
    defer dedup.stop();
    try dedup.bindAll(&.{ spec(0), spec(0) });
    try std.testing.expectEqual(@as(usize, 1), dedup.listen_fds.items.len);
    const port = boundPort(dedup.listen_fds.items[0]);
    try std.testing.expect(port > 0);

    // A later call appends its own listener instead of resetting the fd
    // registry serve() walks.
    try dedup.bindAll(&.{spec(0)});
    try std.testing.expectEqual(@as(usize, 2), dedup.listen_fds.items.len);

    // A spec naming a live listener's port must fail the whole call loudly
    // like a double daemon start (EADDRINUSE; no SO_REUSEPORT sharing), and
    // add no listener of its own.
    var refused = Server{ .gpa = gpa, .io = std.testing.io, .psk = "secret", .store = undefined };
    defer refused.stop();
    try std.testing.expectError(error.Bind, refused.bindAll(&.{spec(port)}));
    try std.testing.expectEqual(@as(usize, 0), refused.listen_fds.items.len);
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

    // The rejection must land in the counter status.json publishes -- and
    // only there: a 401 is auth noise, never a node-health 5xx -- or a
    // wrong-PSK prober stays invisible to the operator between ticks.
    // Reading the error reply above proves the handler finished its bump.
    try std.testing.expectEqual(@as(u64, 1), srv.store.stats.http_unauthorized.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), srv.store.stats.http_5xx.load(.monotonic));
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
    // The wire carries these percent-encoded (urlEncode escapes "/"), and
    // the server decodes exactly once, so this arrives back as ".." and is
    // refused with 400.
    try std.testing.expectError(error.HttpStatus, fetchHave(gpa, "correct_secret", "127.0.0.1", port, "../secret.txt"));
    try std.testing.expectError(error.HttpStatus, fetchRange(gpa, "correct_secret", "127.0.0.1", port, "../secret.txt", 0, 8));
    // Pre-encoded dots survive the single-pass decode as a literal "%2e%2e"
    // filename: no traversal component, so the boundary passes it through
    // and the origin simply misses (404, seen here as PeerMiss). Nothing
    // outside the origin is reachable either way.
    try std.testing.expectError(error.PeerMiss, fetchHave(gpa, "correct_secret", "127.0.0.1", port, "%2e%2e/secret.txt"));
    // Absolute paths are refused too, not silently re-rooted into the origin.
    try std.testing.expectError(error.HttpStatus, fetchHave(gpa, "correct_secret", "127.0.0.1", port, "/etc/passwd"));
}

test "origin stat failures answer 502 while true misses stay healthy 404s" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-srv-o-originfail");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-srv-c-originfail");
    defer sys.deleteTree(std.testing.io, cache_d);

    // A symlink loop under the origin makes stat of everything beneath it
    // fail with ELOOP deterministically (works even as root): an origin-side
    // failure, not a miss. deleteTree unlinks the link without following it.
    var lb: [192]u8 = undefined;
    var tz: [192]u8 = undefined;
    var lz: [192]u8 = undefined;
    const loop_fp = try std.fmt.bufPrint(&lb, "{s}/loop", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), c.symlink(try sys.toZ(&tz, "loop"), try sys.toZ(&lz, loop_fp)));

    const srv = try TestServer.start(gpa, origin_d, cache_d, 16, "secret");
    defer srv.stop();
    const port = srv.port();

    // Expected-path warning from replyOriginStat; keep it off the runner's
    // stderr like sibling fault-tolerance tests do. Restored on scope exit.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    // /have and /data must report the origin as unavailable (502, surfacing
    // here as HttpStatus), never as a healthy miss: a fetching peer and an
    // operator must be able to tell "nobody has this file" from "the origin
    // is broken" -- fillFromPeers keys probe_err and its fallback tier on
    // exactly this distinction.
    try std.testing.expectError(error.HttpStatus, fetchHave(gpa, "secret", "127.0.0.1", port, "loop/x.bin"));
    try std.testing.expectError(error.HttpStatus, fetchRange(gpa, "secret", "127.0.0.1", port, "loop/x.bin", 0, 8));

    // Both failures are server-side trouble: each must land in the http_5xx
    // counter status.json publishes (one per reply, bumped before the head
    // the client above already read), or an origin outage is indistinguishable
    // from ordinary traffic between discovery ticks.
    try std.testing.expectEqual(@as(u64, 2), srv.store.stats.http_5xx.load(.monotonic));

    // A genuinely absent path stays a healthy miss (404 => PeerMiss), the
    // shape fillFromPeers relies on to keep probe_err clean on skewed fleets.
    try std.testing.expectError(error.PeerMiss, fetchHave(gpa, "secret", "127.0.0.1", port, "gone.bin"));

    // The healthy miss must not have fed the failure gauge: 404s are fleet
    // skew, not broken nodes.
    try std.testing.expectEqual(@as(u64, 2), srv.store.stats.http_5xx.load(.monotonic));
}

test "a path too long for the origin answers 400 on /have and /data alike" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-srv-o-longpath");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-srv-c-longpath");
    defer sys.deleteTree(std.testing.io, cache_d);

    const srv = try TestServer.start(gpa, origin_d, cache_d, 16, "secret");
    defer srv.stop();
    const port = srv.port();

    // The longest rel the request boundary can carry (decodePath's buffer
    // cap): relOk-clean bytes that can never name a file because the joined
    // origin path exceeds PATH_MAX. That is client input -- the same family
    // as ".." and absolute paths -- so both data endpoints must answer 400,
    // not 502: a server-failure code here would bump the http_5xx health
    // counter and send the fetching peer retrying every node for a request
    // that can never succeed.
    const long_rel = "a" ** 4096;

    {
        var req_buf: [8192]u8 = undefined;
        const req = try std.fmt.bufPrint(&req_buf, "GET /have?path={s} HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer secret\r\nConnection: close\r\n\r\n", .{long_rel});
        var res = try roundTrip(port, req);
        defer res.deinit(gpa);
        try std.testing.expect(std.mem.startsWith(u8, res.items, "HTTP/1.1 400 Bad Request\r\n"));
    }
    {
        var req_buf: [8192]u8 = undefined;
        const req = try std.fmt.bufPrint(&req_buf, "GET /data?path={s} HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer secret\r\nRange: bytes=0-7\r\nConnection: close\r\n\r\n", .{long_rel});
        var res = try roundTrip(port, req);
        defer res.deinit(gpa);
        try std.testing.expect(std.mem.startsWith(u8, res.items, "HTTP/1.1 400 Bad Request\r\n"));
    }

    // And neither reply may pollute the 5xx health gauge status.json
    // publishes: nothing server-side failed here.
    try std.testing.expectEqual(@as(u64, 0), srv.store.stats.http_5xx.load(.monotonic));
}

/// Read the kernel-assigned port back from a listening socket (for port 0).
fn boundPort(fd: c_int) u16 {
    var addr = std.mem.zeroes(c.struct_sockaddr_in);
    var len: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
    if (c.getsockname(fd, .{ .__sockaddr__ = @ptrCast(&addr) }, &len) != 0) return 0;
    return std.mem.bigToNative(u16, addr.sin_port);
}

/// Loopback client address for a test dial: one construction so the
/// 127.0.0.1 spelling and byte orders cannot drift between call sites.
fn loopbackAddr(port: u16) c.struct_sockaddr_in {
    var addr = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = std.mem.nativeToBig(u16, port);
    addr.sin_addr.s_addr = std.mem.nativeToBig(u32, 0x7F000001); // 127.0.0.1
    return addr;
}

/// Reserves a kernel-picked free loopback TCP port and releases it, for tests
/// that need a port dialing fails on: a hardcoded one would break on any host
/// where a real service already holds it.
fn freeTcpPort() !u16 {
    const lfd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    try std.testing.expect(lfd >= 0);
    defer sys.close(lfd);
    var addr = loopbackAddr(0);
    try std.testing.expectEqual(@as(i32, 0), c.bind(lfd, .{ .__sockaddr__ = @ptrCast(&addr) }, @sizeOf(c.struct_sockaddr_in)));
    var got = std.mem.zeroes(c.struct_sockaddr_in);
    var glen: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
    try std.testing.expectEqual(@as(i32, 0), c.getsockname(lfd, .{ .__sockaddr__ = @ptrCast(&got) }, &glen));
    return std.mem.bigToNative(u16, got.sin_port);
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
        // stop() is the single destruction path (it ends in gpa.destroy), so
        // cleanup after it is registered must go through stop() alone: a
        // parallel destroy errdefer would double-free on the first failure
        // past that point. Nothing between create and registration can fail.
        const ts = try gpa.create(TestServer);
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
        // Drain detached connection handlers before freeing what they
        // reference (the same order as teardownMount): a handler still
        // inside serveData/serveHave would otherwise touch State, Store,
        // and Server through the TestServer struct the destroy below
        // frees. Bounded so a wedged handler cannot hang the runner.
        var waited: u32 = 0;
        while (self.server.http_inflight.load(.monotonic) != 0 and waited < 300) : (waited += 1)
            sys.sleepMs(10);
        self.server.stop();
        self.store.deinit();
        self.gpa.destroy(self);
    }
};

test "fault tolerance: dial unreachable peer fails gracefully" {
    // Reserve a kernel-picked free port, then release it: dialing a closed
    // port must fail with Connect.
    const err = dial("127.0.0.1", try freeTcpPort());
    try std.testing.expectError(error.Connect, err);
}

/// One raw request over its own connection; returns everything the server
/// wrote until it closed the socket (every reply here carries
/// "Connection: close"). Read failures surface so a hung handler fails the
/// test on the client socket timeout instead of hanging the runner.
fn roundTrip(port: u16, req: []const u8) !std.ArrayList(u8) {
    const gpa = std.testing.allocator;
    var addr = loopbackAddr(port);
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    try std.testing.expect(fd >= 0);
    defer sys.close(fd);
    sys.setSockTimeout(fd, 5000);
    try std.testing.expectEqual(@as(i32, 0), sys.connectIn(fd, &addr, 5000));
    try std.testing.expect(sys.writeAll(fd, req) == @as(isize, @intCast(req.len)));
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = sys.readOnce(fd, &buf) catch break;
        if (n == 0) break;
        try out.appendSlice(gpa, buf[0..n]);
        if (out.items.len > 64 * 1024) return error.ResponseTooBig;
    }
    return out;
}

test "handleConn counts a targetless request line as malformed" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-srv-o-notarget");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-srv-c-notarget");
    defer sys.deleteTree(std.testing.io, cache_d);

    const srv = try TestServer.start(gpa, origin_d, cache_d, 16, "secret");
    defer srv.stop();

    // A completed head whose request line names no target ("HELP") is the
    // scanner noise the timeout and oversize paths count; it must land in
    // http_malformed too instead of dropping invisibly.
    var addr = loopbackAddr(srv.port());
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    try std.testing.expect(fd >= 0);
    defer sys.close(fd);
    sys.setSockTimeout(fd, 5000);
    try std.testing.expectEqual(@as(i32, 0), sys.connectIn(fd, &addr, 5000));
    const before = srv.store.stats.http_malformed.load(.monotonic);
    _ = try std.testing.expectEqual(@as(isize, 8), sys.writeAll(fd, "HELP\r\n\r\n"));
    // The handler replies nothing and closes; EOF is the signal it finished
    // with our connection (the counter bump precedes the deferred close).
    var sink: [64]u8 = undefined;
    while (true) {
        const n = sys.readOnce(fd, &sink) catch break;
        if (n == 0) break;
    }
    try std.testing.expectEqual(before + 1, srv.store.stats.http_malformed.load(.monotonic));

    // Same counter on its other bump site: a head that fills the handler's
    // buffer without ever completing (no "\r\n\r\n" anywhere) is scanner
    // noise too. Sized to handleConn's own head budget so the test tracks
    // it; every byte lands before the server can close (it must consume all
    // of them to hit the limit), so no late write races the close. EOF ends
    // the drain like above; a reset from the closed socket surfaces as an
    // error instead.
    const cfd2 = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    try std.testing.expect(cfd2 >= 0);
    defer sys.close(cfd2);
    sys.setSockTimeout(cfd2, 5000);
    try std.testing.expectEqual(@as(i32, 0), sys.connectIn(cfd2, &addr, 5000));
    var flood: [max_head_bytes]u8 = undefined;
    @memset(&flood, 'A');
    _ = try std.testing.expectEqual(@as(isize, @intCast(flood.len)), sys.writeAll(cfd2, &flood));
    while (true) {
        const n = sys.readOnce(cfd2, &sink) catch break;
        if (n == 0) break;
    }
    try std.testing.expectEqual(before + 2, srv.store.stats.http_malformed.load(.monotonic));
}

test "serveHave answers with the exact cached bitfield blob" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-srv-o-have");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-srv-c-have");
    defer sys.deleteTree(std.testing.io, cache_d);

    // Two pieces at piece size 16; warm both so /have must advertise both.
    var pattern: [32]u8 = undefined;
    for (&pattern, 0..) |*b, i| b.* = @truncate(i *% 13 + 1);
    var fbuf: [192]u8 = undefined;
    var fz: [192]u8 = undefined;
    const fp = try std.fmt.bufPrint(&fbuf, "{s}/bits.bin", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&fz, fp), &pattern));

    const srv = try TestServer.start(gpa, origin_d, cache_d, 16, "secret");
    defer srv.stop();
    const port = srv.port();
    const warm = try fetchRange(gpa, "secret", "127.0.0.1", port, "bits.bin", 0, 31);
    gpa.free(warm);

    // The /have body is the raw cache bitfield: bit i names piece i, one
    // byte per eight pieces. The X-Piece-Size header names the grid those
    // bits are indexed against, so a fetcher running a different --piece
    // can tell the answer apart from its own; fillFromPeers' candidate
    // "have" decisions are computed from exactly these bytes.
    const rep = try fetchHave(gpa, "secret", "127.0.0.1", port, "bits.bin");
    defer gpa.free(rep.bits);
    try std.testing.expectEqual(@as(usize, 1), rep.bits.len);
    try std.testing.expectEqual(@as(u8, 0b00000011), rep.bits[0]);
    try std.testing.expectEqual(@as(u32, 16), rep.piece_size);

    // A directory at the requested path is a miss (404), same as ENOENT:
    // /have advertises regular files only.
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(std.mem.span(try sys.joinZ(&fz, origin_d, "sub")), 0o755));
    var res = try roundTrip(port, "GET /have?path=sub HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer secret\r\nConnection: close\r\n\r\n");
    defer res.deinit(gpa);
    try std.testing.expect(std.mem.startsWith(u8, res.items, "HTTP/1.1 404 Not Found\r\n"));
}

test "fetchHave surfaces the advertised piece size and rejects malformed ones" {
    const gpa = std.testing.allocator;
    // haveFromHead is fetchHave minus the dial: replies are driven through a
    // socketpair like every other response-parser test here.
    {
        const head = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX-Piece-Size: 4194304\r\nConnection: close\r\n\r\n";
        const pair = try responsePair(head ++ "ab");
        defer sys.close(pair[0]);
        defer sys.close(pair[1]);
        const rep = try haveFromHead(gpa, pair[1], head ++ "ab", head.len, head.len + 2);
        defer gpa.free(rep.bits);
        try std.testing.expectEqualStrings("ab", rep.bits);
        try std.testing.expectEqual(@as(u32, 4 * 1024 * 1024), rep.piece_size);
    }
    // No header (an older peer): piece size unknown (0), bits still served.
    {
        const head = "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\n";
        const pair = try responsePair(head ++ "z");
        defer sys.close(pair[0]);
        defer sys.close(pair[1]);
        const rep = try haveFromHead(gpa, pair[1], head ++ "z", head.len, head.len + 1);
        defer gpa.free(rep.bits);
        try std.testing.expectEqual(@as(u32, 0), rep.piece_size);
    }
    // A healthy peer answering "not cached here" is its own outcome, distinct
    // from broken peers so the probe-failure counter can exclude it.
    {
        const head = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        const pair = try responsePair(head);
        defer sys.close(pair[0]);
        defer sys.close(pair[1]);
        try std.testing.expectError(error.PeerMiss, haveFromHead(gpa, pair[1], head, head.len, head.len));
    }
    // A malformed header fails the probe like any other bad reply so it is
    // never cached and retried on the next piece.
    {
        const head = "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nX-Piece-Size: huge\r\nConnection: close\r\n\r\nz";
        const pair = try responsePair(head);
        defer sys.close(pair[0]);
        defer sys.close(pair[1]);
        try std.testing.expectError(error.BadPieceSize, haveFromHead(gpa, pair[1], head, head.len, head.len));
    }
}

test "haveFromHead refuses a bitmap above the /have body bound before allocating" {
    const gpa = std.testing.allocator;
    // A truthful /have body is bytesLen(pieces) -- KiB-scale for any real
    // model. A peer-chosen Content-Length one byte past max_have_body_bytes
    // must fail the probe at parse time: finishBodyAlloc would otherwise
    // honor it up to max_alloc_body_bytes, and havePut caches the answer,
    // pinning the allocation in the probe cache past the probe itself.
    // Under the bound the body readers behave as every sibling test above
    // pins (small bodies parse, missing bytes fail ReadIncomplete), so only
    // the refusal needs its own case here.
    {
        const head = "HTTP/1.1 200 OK\r\nContent-Length: 16777217\r\nX-Piece-Size: 16777216\r\nConnection: close\r\n\r\n";
        const pair = try responsePair(head);
        defer sys.close(pair[0]);
        defer sys.close(pair[1]);
        try std.testing.expectError(error.BodyTooLarge, haveFromHead(gpa, pair[1], head, head.len, head.len));
    }
}

test "peer http dispatch answers ping, wrong method, and unknown paths" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-srv-o-dispatch");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-srv-c-dispatch");
    defer sys.deleteTree(std.testing.io, cache_d);

    const srv = try TestServer.start(gpa, origin_d, cache_d, 16, "secret");
    defer srv.stop();
    const port = srv.port();

    // /ping is the liveness probe: 200 with body "ok", typed like every
    // other success reply here.
    {
        var res = try roundTrip(port, "GET /ping HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer secret\r\nConnection: close\r\n\r\n");
        defer res.deinit(gpa);
        try std.testing.expect(std.mem.startsWith(u8, res.items, "HTTP/1.1 200 OK\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, res.items, "Content-Type: text/plain\r\n") != null);
        try std.testing.expect(std.mem.endsWith(u8, res.items, "\r\n\r\nok"));
    }
    // A non-GET method is refused even with valid auth, and the refusal
    // names what the resource accepts (RFC 9110 §15.5.5).
    {
        var res = try roundTrip(port, "POST /ping HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer secret\r\nConnection: close\r\n\r\n");
        defer res.deinit(gpa);
        try std.testing.expect(std.mem.startsWith(u8, res.items, "HTTP/1.1 405 Method Not Allowed\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, res.items, "Allow: GET\r\n") != null);
    }
    // A missing bearer token is a 401 that names the scheme to retry with
    // (RFC 9110 §15.5.2). The expected rejection warning stays off the
    // runner's stderr like sibling fault-tolerance tests.
    {
        const prev_log_level = std.testing.log_level;
        std.testing.log_level = .err;
        defer std.testing.log_level = prev_log_level;
        var res = try roundTrip(port, "GET /ping HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        defer res.deinit(gpa);
        try std.testing.expect(std.mem.startsWith(u8, res.items, "HTTP/1.1 401 Unauthorized\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, res.items, "WWW-Authenticate: Bearer\r\n") != null);
    }
    // Unknown paths are 404 regardless of the query string behind them.
    // Regression: routing used to run after path-parameter decoding, so an
    // unknown path without a decodable ?path= answered 400 while the same
    // path with one answered 404 -- two answers for one resource state.
    {
        for ([_][]const u8{
            "GET /nope HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer secret\r\nConnection: close\r\n\r\n",
            "GET /nope?path=x.bin HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer secret\r\nConnection: close\r\n\r\n",
            "GET /nope?path=%zz HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer secret\r\nConnection: close\r\n\r\n",
            "GET /nope?path=..%2Fx HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer secret\r\nConnection: close\r\n\r\n",
        }) |req| {
            var res = try roundTrip(port, req);
            defer res.deinit(gpa);
            try std.testing.expect(std.mem.startsWith(u8, res.items, "HTTP/1.1 404 Not Found\r\n"));
        }
    }
    // A routed path without its ?path= parameter is a client error answered
    // before any storage touch, not a 404 and not a crash.
    {
        var res = try roundTrip(port, "GET /have HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer secret\r\nConnection: close\r\n\r\n");
        defer res.deinit(gpa);
        try std.testing.expect(std.mem.startsWith(u8, res.items, "HTTP/1.1 400 Bad Request\r\n"));
    }
    // /data still demands its Range header (a client error, not a full-file
    // send) and types the 206 body like /have does.
    {
        var fbuf: [192]u8 = undefined;
        var fz: [192]u8 = undefined;
        const fp = try std.fmt.bufPrint(&fbuf, "{s}/r.bin", .{origin_d});
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&fz, fp), "data"));
        {
            var res = try roundTrip(port, "GET /data?path=r.bin HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer secret\r\nConnection: close\r\n\r\n");
            defer res.deinit(gpa);
            try std.testing.expect(std.mem.startsWith(u8, res.items, "HTTP/1.1 400 Bad Request\r\n"));
        }
        {
            var res = try roundTrip(port, "GET /data?path=r.bin HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer secret\r\nRange: bytes=0-3\r\nConnection: close\r\n\r\n");
            defer res.deinit(gpa);
            try std.testing.expect(std.mem.startsWith(u8, res.items, "HTTP/1.1 206 Partial Content\r\n"));
            try std.testing.expect(std.mem.indexOf(u8, res.items, "Content-Type: application/octet-stream\r\n") != null);
            try std.testing.expect(std.mem.endsWith(u8, res.items, "\r\n\r\ndata"));
        }
        // A directory at the path is the same miss /have reports (404), not
        // an origin failure (502): hydration's pread on the dir fd must never
        // be reached. Regression: serveData skipped the regular-file gate.
        try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(std.mem.span(try sys.joinZ(&fz, origin_d, "subdir")), 0o755));
        {
            var res = try roundTrip(port, "GET /data?path=subdir HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer secret\r\nRange: bytes=0-15\r\nConnection: close\r\n\r\n");
            defer res.deinit(gpa);
            try std.testing.expect(std.mem.startsWith(u8, res.items, "HTTP/1.1 404 Not Found\r\n"));
        }
    }
}

test "serveData replies 500 when the cache refuses hydrated bytes" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-srv-o-rocache");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-srv-c-rocache");
    defer sys.deleteTree(std.testing.io, cache_d);

    // Regression: when the origin read succeeded but the cache fs refused the
    // bytes (here: an unwritable data artifact), the unset bit fell through
    // to a 404 -- telling the fetching peer the path was gone -- with no log.
    var pattern: [16]u8 = undefined;
    for (&pattern, 0..) |*b, i| b.* = @truncate(i *% 53);
    var fbuf: [192]u8 = undefined;
    var fz: [192]u8 = undefined;
    const fp = try std.fmt.bufPrint(&fbuf, "{s}/ro.bin", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&fz, fp), &pattern));

    // Unwritable cache data file: openCache's O_RDWR|O_CREAT fails EACCES,
    // so writePiece fails after originPread delivered every byte.
    var dbuf: [192]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dbuf, "{s}/data", .{cache_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(data_dir, 0o755));
    var pbuf: [192]u8 = undefined;
    const dp = try std.fmt.bufPrint(&pbuf, "{s}/ro.bin", .{data_dir});
    var dz: [sys.c.PATH_MAX]u8 = undefined;
    const dpz = try sys.toZ(&dz, dp);
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(dpz, ""));
    try std.testing.expectEqual(@as(i32, 0), c.chmod(dpz, 0o444));

    const srv = try TestServer.start(gpa, origin_d, cache_d, 16, "secret");
    defer srv.stop();
    const port = srv.port();

    // Expected-path warning; keep it off the runner's stderr like sibling
    // fault-tolerance tests do.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    const fd = try sendRequest("secret", "127.0.0.1", port, "ro.bin", .{ .start = 0, .end = 15 });
    defer sys.close(fd);
    var head_buf: [8192]u8 = undefined;
    var head_len: usize = 0;
    var total_read: usize = 0;
    try readHeadFull(fd, &head_buf, &head_len, &total_read);
    // The status must name the server-side cache failure (500), not 404.
    try std.testing.expect(std.mem.startsWith(u8, head_buf[0..head_len], "HTTP/1.1 500"));
    // The same event feeds the http_5xx counter status.json publishes (the
    // bump precedes the head this client just read): a cache tier refusing
    // hydrated bytes must be visible without journal access.
    try std.testing.expectEqual(@as(u64, 1), srv.store.stats.http_5xx.load(.monotonic));
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

test "acceptLoop closes connections beyond the inflight handler cap" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-cap-o");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-cap-c");
    defer sys.deleteTree(std.testing.io, cache_d);

    const srv = try TestServer.start(gpa, origin_d, cache_d, 16, "secret");
    defer srv.stop();

    // More idle connections than the cap, none sending a head: admitted
    // handlers park on their head read until their clients close below, and
    // every connection beyond the cap must be closed outright. The
    // claim-then-check atomic decides which ones; only the count matters.
    const n_conns: usize = Server.max_inflight + 8;
    var fds: [n_conns]c_int = undefined;
    var addr = loopbackAddr(srv.port());
    for (&fds) |*fd| {
        fd.* = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        try std.testing.expect(fd.* >= 0);
        try std.testing.expectEqual(@as(i32, 0), sys.connectIn(fd.*, &addr, 5000));
    }
    defer for (&fds) |fd| sys.close(fd);

    // Rejected connections see EOF as soon as the accept loop claims them;
    // bounded retries absorb scheduler delay without masking a regression
    // (a missing or miscounted cap leaves every socket open).
    const expect_eof = n_conns - Server.max_inflight;
    var eof: usize = 0;
    var waited: u32 = 0;
    while (waited < 500) : (waited += 1) {
        eof = 0;
        for (&fds) |fd| {
            var probe: [1]u8 = undefined;
            if (c.recv(fd, &probe, probe.len, c.MSG_PEEK | c.MSG_DONTWAIT) == 0) eof += 1;
        }
        if (eof >= expect_eof) break;
        sys.sleepMs(10);
    }
    try std.testing.expectEqual(@as(usize, expect_eof), eof);
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

test "serveData answers an open-ended range with the file tail" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-srv-o-open");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-srv-c-open");
    defer sys.deleteTree(std.testing.io, cache_d);

    // Ordinary HTTP clients ask for the rest of a file with "bytes=N-";
    // the endpoint must treat it like any over-long explicit end.
    var pattern: [32]u8 = undefined;
    for (&pattern, 0..) |*b, i| b.* = @truncate(i *% 29 + 7);
    var fbuf: [192]u8 = undefined;
    var fz: [192]u8 = undefined;
    const fp = try std.fmt.bufPrint(&fbuf, "{s}/open.bin", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&fz, fp), &pattern));

    const srv = try TestServer.start(gpa, origin_d, cache_d, 16, "secret");
    defer srv.stop();

    var addr = loopbackAddr(srv.port());
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    try std.testing.expect(fd >= 0);
    defer sys.close(fd);
    try std.testing.expectEqual(@as(i32, 0), sys.connectIn(fd, &addr, 5000));
    var req_buf: [256]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET /data?path=open.bin HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer secret\r\nRange: bytes=16-\r\nConnection: close\r\n\r\n", .{});
    try std.testing.expectEqual(@as(isize, @intCast(req.len)), sys.writeAll(fd, req));
    const body = try readFlexBodyAlloc(gpa, fd, null);
    defer gpa.free(body);
    try std.testing.expectEqual(pattern.len - 16, body.len);
    try std.testing.expectEqualSlices(u8, pattern[16..], body);
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

test "serveData serves a legal path whose encoded form exceeds 8KiB" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-srv-o-longname");
    defer sys.deleteTree(std.testing.io, origin_d);
    var cb: [128]u8 = undefined;
    const cache_d = try sys.scratchDir(&cb, "modelfs-srv-c-longname");
    defer sys.deleteTree(std.testing.io, cache_d);

    // A deeply nested non-ASCII rel: each "é/" component is 3 raw bytes but
    // 9 percent-encoded bytes (%C3%A9%2F), so ~1000 components push the
    // request line past the old 8 KiB server head budget while staying
    // inside sendRequest's documented maximum (and PATH_MAX joins).
    var rel_buf: [4096]u8 = undefined;
    var rl: usize = 0;
    while (rl + "f.bin".len + 3 <= 3000) : (rl += 3) {
        @memcpy(rel_buf[rl..][0..3], "\xc3\xa9/");
    }
    @memcpy(rel_buf[rl..][0.."f.bin".len], "f.bin");
    rl += "f.bin".len;
    const rel = rel_buf[0..rl];
    try std.testing.expect(store_mod.relOk(rel));

    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const fp = try sys.joinZ(&pbuf, origin_d, rel);
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(sys.parentOf(std.mem.span(fp)), 0o755));
    const body = "payload";
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(fp, body));

    // A loadPsk-maximum secret rides along: the request frame must carry
    // the escaped PATH_MAX rel AND a proto.max_psk_bytes token together.
    // Regression: the builder budgeted only fixed overhead past the encoded
    // path, so exactly this combination overflowed sendRequest and silently
    // disabled the peer tier for nodes with long secrets.
    const psk = "k" ** proto.max_psk_bytes;
    const srv = try TestServer.start(gpa, origin_d, cache_d, 16, psk);
    defer srv.stop();

    const got = try fetchRange(gpa, psk, "127.0.0.1", srv.port(), rel, 0, body.len - 1);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(body, got);
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

    // The 416 names the complete length (RFC 9110 §15.5.17/§14.4) so a
    // client can recompute a satisfiable range instead of probing.
    var res = try roundTrip(port, "GET /data?path=tiny.bin HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer secret\r\nRange: bytes=3-9\r\nConnection: close\r\n\r\n");
    defer res.deinit(gpa);
    try std.testing.expect(std.mem.startsWith(u8, res.items, "HTTP/1.1 416 Range Not Satisfiable\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, res.items, "Content-Range: bytes */3\r\n") != null);
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
    try fillFromPeers(gpa, "secret", &cat, "one.bin", 0, 16, &out, &srv.store.stats);
    try std.testing.expectEqualSlices(u8, &pattern, &out);
    // The empty peer answered /have with a healthy 404 (PeerMiss): a normal
    // fleet miss, never a probe failure. The counter must stay at zero here
    // or it would cry wolf on every replica-skewed cluster.
    try std.testing.expectEqual(@as(u64, 0), srv.store.stats.probe_err.load(.monotonic));

    // Regression: a zero-length out (reachable only when a truncate raced
    // hydration) must fail cleanly instead of underflowing the requested
    // range end and aborting the daemon. The winning peer answers 206 with
    // Content-Length 1 against a 0-byte destination, the fetch fails with
    // LengthMismatch, and the candidate loop drains to NoPeer. The failed
    // attempt now also logs its warn; raising the print threshold keeps
    // that expected line off the runner's stderr. Restored on scope exit.
    {
        const prev_log_level = std.testing.log_level;
        std.testing.log_level = .err;
        defer std.testing.log_level = prev_log_level;
        try std.testing.expectError(error.NoPeer, fillFromPeers(gpa, "secret", &cat, "one.bin", 0, 16, &.{}, &srv.store.stats));
        // An attempted-and-failed transfer lands in the error counters that
        // status.json publishes; a benign NoPeer with no attempt (the
        // missing.bin case below) must not.
        try std.testing.expectEqual(@as(u64, 1), srv.store.stats.fill_err_peer.load(.monotonic));
    }
    try std.testing.expectEqual(@as(u64, 1), srv.store.stats.fill_err_peer.load(.monotonic));

    // No candidate has the piece: NoPeer surfaces (caller falls back to NFS).
    try std.testing.expectError(error.NoPeer, fillFromPeers(gpa, "secret", &cat, "missing.bin", 0, 16, &out, &srv.store.stats));
    try std.testing.expectEqual(@as(u64, 1), srv.store.stats.fill_err_peer.load(.monotonic));
}

test "fillFromPeers counts failed /have probes but not healthy misses" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-probe-o");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-probe-c");
    defer sys.deleteTree(std.testing.io, cache_d);
    var st = store_mod.Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();

    // Reserve a free port, then release it: dialing it fails with Connect,
    // the wire shape of a dead or partitioned peer.
    const dead_port = try freeTcpPort();

    var cat = discover.Catalog.init(gpa, std.testing.io, origin_d, "me", &.{}, &.{}, &.{});
    defer cat.deinit();
    try cat.paths.append(gpa, .{
        .peer_id = "dead",
        .ip = "127.0.0.1",
        .port = dead_port,
        .ewma_bps = 1e9,
        .hops = 0,
    });

    // The probe failure must land in the counter status.json publishes:
    // without it a PSK drift or a partitioned peer silently degrades every
    // fill to the origin tier while reads keep succeeding.
    var out: [16]u8 = undefined;
    try std.testing.expectError(error.NoPeer, fillFromPeers(gpa, "secret", &cat, "x.bin", 0, 16, &out, &st.stats));
    try std.testing.expectEqual(@as(u64, 1), st.stats.probe_err.load(.monotonic));
}

test "fillFromPeers excludes peers whose advertised piece size differs" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-ffp-o-grid");
    defer sys.deleteTree(std.testing.io, origin_d);
    var pattern: [16]u8 = undefined;
    for (&pattern, 0..) |*b, i| b.* = @truncate(i *% 41 + 3);
    var fbuf: [192]u8 = undefined;
    var fz: [192]u8 = undefined;
    const fp = try std.fmt.bufPrint(&fbuf, "{s}/grid.bin", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&fz, fp), &pattern));

    // Misaligned peer: same origin file cached on a 64M grid, listed first.
    // Its bitmap's bit 0 covers bytes 0..64M of its grid while ours covers
    // 0..16M, so consulting it would route fills by bits that mean different
    // byte ranges per node; it must read as no-answer instead.
    var mb: [128]u8 = undefined;
    const cache_mis = try sys.scratchDir(&mb, "modelfs-ffp-c-mis");
    defer sys.deleteTree(std.testing.io, cache_mis);
    const srv_mis = try TestServer.start(gpa, origin_d, cache_mis, 64 * 1024 * 1024, "secret");
    defer srv_mis.stop();
    const warm = try fetchRange(gpa, "secret", "127.0.0.1", srv_mis.port(), "grid.bin", 0, 15);
    gpa.free(warm);

    // Aligned peer on our own grid, serving identical bytes from the shared
    // origin: despite the misaligned peer listing first, this one serves.
    var nb: [128]u8 = undefined;
    const cache_ok = try sys.scratchDir(&nb, "modelfs-ffp-c-ok");
    defer sys.deleteTree(std.testing.io, cache_ok);
    const srv_ok = try TestServer.start(gpa, origin_d, cache_ok, 16, "secret");
    defer srv_ok.stop();
    const warm2 = try fetchRange(gpa, "secret", "127.0.0.1", srv_ok.port(), "grid.bin", 0, 15);
    gpa.free(warm2);

    var cat = discover.Catalog.init(gpa, std.testing.io, origin_d, "me", &.{}, &.{}, &.{});
    defer cat.deinit();
    try cat.paths.append(gpa, .{
        .peer_id = "mis",
        .ip = "127.0.0.1",
        .port = srv_mis.port(),
        .ewma_bps = 1e9,
        .hops = 0,
    });
    try cat.paths.append(gpa, .{
        .peer_id = "ok",
        .ip = "127.0.0.1",
        .port = srv_ok.port(),
        .ewma_bps = 1e9,
        .hops = 0,
    });

    var out: [16]u8 = undefined;
    try fillFromPeers(gpa, "secret", &cat, "grid.bin", 0, 16, &out, null);
    try std.testing.expectEqualSlices(u8, &pattern, &out);

    // With only the misaligned holder listed, nothing may answer at all:
    // NoPeer surfaces and the caller falls through to the origin tier.
    _ = cat.paths.pop();
    try std.testing.expectError(error.NoPeer, fillFromPeers(gpa, "secret", &cat, "grid.bin", 0, 16, &out, null));
}

const seed_reply_ok = fuzzcorpus.entry("HTTP/1.1 200 OK\r\nContent-Length: 3\r\nX-Piece-Size: 4096\r\nConnection: close\r\n\r\nabc");
const seed_reply_206 = fuzzcorpus.entry("HTTP/1.1 206 Partial Content\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi");
const seed_reply_miss = fuzzcorpus.entry("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
const seed_reply_huge_cl = fuzzcorpus.entry("HTTP/1.1 200 OK\r\nContent-Length: 536870913\r\nConnection: close\r\n\r\n");
const seed_reply_bad_ps = fuzzcorpus.entry("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nX-Piece-Size: huge\r\nConnection: close\r\n\r\nz");
const seed_reply_short_body = fuzzcorpus.entry("HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\n1234");
const seed_reply_garbage = fuzzcorpus.entry("HTTP/1.0 500 oops\r\n\r\n");
const seed_reply_dup_header = fuzzcorpus.entry("HTTP/1.1 200 OK\r\ncontent-length: 2\r\nCONTENT-LENGTH: 99999999999\r\nX-Piece-Size: 16\r\nConnection: close\r\n\r\nok");

const fuzz_reply_corpus = [_][]const u8{
    &seed_reply_ok,
    &seed_reply_206,
    &seed_reply_miss,
    &seed_reply_huge_cl,
    &seed_reply_bad_ps,
    &seed_reply_short_body,
    &seed_reply_garbage,
    &seed_reply_dup_header,
};

/// Connected socketpair with `wire` already written into fds[0]: a
/// deterministic stand-in for the peer side of the response parsers. False
/// when the pair could not be created or the bytes could not be staged.
fn stageWire(wire: []const u8, out: *[2]c_int) bool {
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, out) != 0) return false;
    const staged = sys.writeAll(out[0], wire) == @as(isize, @intCast(wire.len));
    sys.close(out[0]);
    return staged;
}

fn fuzzHaveReplyOne(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var wire_buf: [2048]u8 = undefined;
    const wire = wire_buf[0..smith.slice(&wire_buf)];

    // fetchHave leg: the bitmap answer rides an allocation sized by
    // Content-Length. A reply this parser rejects skips the assertions that
    // need a parsed value; the dest leg below still runs on every input.
    {
        var fds: [2]c_int = undefined;
        defer sys.close(fds[1]);
        if (stageWire(wire, &fds)) {
            var head_buf: [8192]u8 = undefined;
            var head_len: usize = 0;
            var total_read: usize = 0;
            if (readHeadFull(fds[1], &head_buf, &head_len, &total_read)) |_| {
                if (haveFromHead(gpa, fds[1], &head_buf, head_len, total_read)) |rep| {
                    defer gpa.free(rep.bits);
                    const head = head_buf[0..head_len];
                    const cl_str = proto.headerGet(head, "Content-Length") orelse "0";
                    const want_len = std.fmt.parseInt(usize, cl_str, 10) catch 0;
                    try std.testing.expectEqual(want_len, rep.bits.len);
                    try std.testing.expect(total_read >= head_len + rep.bits.len);
                    try std.testing.expectEqualSlices(u8, wire[head_len..][0..rep.bits.len], rep.bits);
                    const ps_str = proto.headerGet(head, "X-Piece-Size") orelse "0";
                    try std.testing.expectEqual(try std.fmt.parseInt(u32, ps_str, 10), rep.piece_size);
                } else |_| {}
            } else |_| {}
        }
    }

    // /data fetch leg (fetchRangeInto): the same wire against a
    // caller-supplied destination whose length must match Content-Length
    // exactly -- the piece-fill trust boundary where a fetched piece may be
    // marked filled only over bytes actually received. Runs on every input,
    // including replies the /have leg rejects.
    {
        var dest_fds: [2]c_int = undefined;
        defer sys.close(dest_fds[1]);
        if (stageWire(wire, &dest_fds)) {
            var dest_head_buf: [8192]u8 = undefined;
            var dest_head_len: usize = 0;
            var dest_total: usize = 0;
            if (readHeadFull(dest_fds[1], &dest_head_buf, &dest_head_len, &dest_total)) |_| {
                const dest_head = dest_head_buf[0..dest_head_len];
                const status_end = std.mem.find(u8, dest_head, "\r\n") orelse return;
                const status_ok = std.mem.startsWith(u8, dest_head[0..status_end], "HTTP/1.1 200") or
                    std.mem.startsWith(u8, dest_head[0..status_end], "HTTP/1.1 206");
                const dest_cl_str = proto.headerGet(dest_head, "Content-Length") orelse "0";
                const dest_want: ?usize = std.fmt.parseInt(usize, dest_cl_str, 10) catch null;

                var dest_buf: [64]u8 = undefined;
                const dest_len: usize = @intCast(smith.value(usize) % (dest_buf.len + 1));
                const dest_call = finishBodyAlloc(gpa, dest_fds[1], &dest_head_buf, dest_head_len, dest_total, dest_buf[0..dest_len], null);
                if (!status_ok) {
                    try std.testing.expectError(error.HttpStatus, dest_call);
                    return;
                }
                const want = dest_want orelse {
                    try std.testing.expectError(error.BadContentLength, dest_call);
                    return;
                };
                if (dest_len != want) {
                    // A mismatching destination is refused before any byte
                    // moves, whatever the body looks like behind the head.
                    try std.testing.expectError(error.LengthMismatch, dest_call);
                    return;
                }
                _ = dest_call catch |err| switch (err) {
                    error.ReadIncomplete => {
                        // EOF before Content-Length is data loss: refused
                        // outright, never a short success the fill path
                        // would mark filled over hole zeros.
                        try std.testing.expect(wire.len - dest_head_len < want);
                        return;
                    },
                    else => return err,
                };
                try std.testing.expect(wire.len - dest_head_len >= want);
                try std.testing.expectEqualSlices(u8, wire[dest_head_len..][0..want], dest_buf[0..want]);
            } else |_| {}
        }
    }
}

test "fuzz peer reply parsing accepts well-formed replies and fails closed" {
    try std.testing.fuzz({}, fuzzHaveReplyOne, .{ .corpus = &fuzz_reply_corpus });
}

const fuzz_request_psk = "fuzz-psk";

const seed_req_have_ok = fuzzcorpus.entry("GET /have?path=gguf%2Fmodel.gguf HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\nRange: bytes=0-1023\r\n\r\n");
const seed_req_traversal = fuzzcorpus.entry("GET /data?path=..%2F..%2Fetc%2Fpasswd HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\n\r\n");
const seed_req_wrong_auth = fuzzcorpus.entry("POST /ping HTTP/1.1\r\nauthorization: BEARER wrong\r\n\r\n");
const seed_req_max_range = fuzzcorpus.entry("GET /data?path=a HTTP/1.1\r\nAuthorization: Bearer fuzz-psk \r\nRange: bytes=18446744073709551615-\r\n\r\n");
const seed_req_control_path = fuzzcorpus.entry("GET /have?path=%00%1b%5b0m HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\n\r\n");
const seed_req_inverted_range = fuzzcorpus.entry("GET /data?path=x HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\nRange: bytes=10-5\r\n\r\n");
const seed_req_no_path = fuzzcorpus.entry("GET /have HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\n\r\n");

const fuzz_request_corpus = [_][]const u8{
    &seed_req_have_ok,
    &seed_req_traversal,
    &seed_req_wrong_auth,
    &seed_req_max_range,
    &seed_req_control_path,
    &seed_req_inverted_range,
    &seed_req_no_path,
};

fn refBearerOk(got: []const u8, want: []const u8) bool {
    const prefix: []const u8 = "Bearer ";
    if (got.len < prefix.len) return false;
    for (prefix, 0..) |p, i| {
        if (std.ascii.toLower(got[i]) != std.ascii.toLower(p)) return false;
    }
    const token = std.mem.trim(u8, got[prefix.len..], " \t");
    var ha: [32]u8 = undefined;
    var hb: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &ha, .{});
    std.crypto.hash.sha2.Sha256.hash(want, &hb, .{});
    return std.crypto.timing_safe.eql([32]u8, ha, hb);
}

fn refRelOk(rel: []const u8) bool {
    if (rel.len == 0 or rel[0] == '/') return false;
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i <= rel.len) : (i += 1) {
        if (i != rel.len and rel[i] != '/') {
            if (rel[i] < 0x20 or rel[i] == 0x7f) return false;
            continue;
        }
        const seg = rel[seg_start..i];
        if (seg.len != 0 and seg[0] == '.' and (seg.len == 1 or (seg.len == 2 and seg[1] == '.'))) return false;
        seg_start = i + 1;
    }
    return true;
}

fn fuzzRequestHeadOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var wire_buf: [2048]u8 = undefined;
    const head = wire_buf[0..smith.slice(&wire_buf)];
    const line_end = std.mem.find(u8, head, "\r\n") orelse return;
    const line = head[0..line_end];
    var it = std.mem.splitScalar(u8, line, ' ');
    const method = it.next() orelse return;
    const target = it.next() orelse return;
    if (!std.mem.eql(u8, method, "GET")) return;
    const auth = proto.headerGet(head, "Authorization") orelse return;
    const authed = proto.bearerOk(auth, fuzz_request_psk);
    try std.testing.expectEqual(refBearerOk(auth, fuzz_request_psk), authed);
    if (!authed) return;

    var tok_buf: [128]u8 = undefined;
    const tok = tok_buf[0..smith.slice(&tok_buf)];
    var form_buf: ["Bearer ".len + tok_buf.len]u8 = undefined;
    const formed = std.fmt.bufPrint(&form_buf, "Bearer {s}", .{tok}) catch return;
    const trimmed = std.mem.trim(u8, tok, " \t");
    try std.testing.expectEqual(std.mem.eql(u8, trimmed, tok), proto.bearerOk(formed, tok));
    try std.testing.expectEqual(refBearerOk(formed, tok), proto.bearerOk(formed, tok));

    const path = proto.pathOnly(target);
    if (!std.mem.eql(u8, path, "/have") and !std.mem.eql(u8, path, "/data")) return;
    var rel_buf: [4096]u8 = undefined;
    const q = proto.queryGet(target, "path") orelse return;
    const rel = proto.urlDecode(&rel_buf, q) catch return;
    try std.testing.expect(rel.len <= q.len);
    const routed_ok = store_mod.relOk(rel);
    try std.testing.expectEqual(refRelOk(rel), routed_ok);
    if (!routed_ok or path[1] != 'd') return;
    const rh = proto.headerGet(head, "Range") orelse return;
    const rg = proto.parseRange(rh) orelse return;
    try std.testing.expect(rg.start <= rg.end);
    var canon: [64]u8 = undefined;
    const canon_s = std.fmt.bufPrint(&canon, "bytes={d}-{d}", .{ rg.start, rg.end }) catch return;
    const rt = proto.parseRange(canon_s) orelse return error.RangeRoundTripFailed;
    try std.testing.expectEqual(rg.start, rt.start);
    try std.testing.expectEqual(rg.end, rt.end);
}

test "fuzz request head parsing pipeline gates auth paths and ranges" {
    try std.testing.fuzz({}, fuzzRequestHeadOne, .{ .corpus = &fuzz_request_corpus });
}

// The request-head harness above mirrors handleConn's pipeline, so parser
// drift shows up as oracle mismatches -- but wiring drift (a reordered
// branch, an uncounted rejection, a reply missing its challenge header)
// would leave both the handler and its mirror agreeing on the wrong thing.
// This harness drives the real handleConn over a socketpair instead and
// pins the published routing contract end to end: method gate before auth,
// auth before routing, unknown routes 404 ahead of query validation,
// traversal/control paths refused, ranges required on /data, and every
// outcome landed in the counter status.json publishes.

const seed_serve_ping_ok = fuzzcorpus.entry("GET /ping HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\n\r\n");
const seed_serve_post_ping = fuzzcorpus.entry("POST /ping HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\n\r\n");
const seed_serve_no_target = fuzzcorpus.entry("HELP\r\n\r\n");
const seed_serve_unterminated = fuzzcorpus.entry("GET /have?path=a HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\n");
const seed_serve_ping_unauthed = fuzzcorpus.entry("GET /ping HTTP/1.1\r\nAuthorization: Bearer wrong\r\n\r\n");
const seed_serve_unknown_route = fuzzcorpus.entry("GET /nope?path=x HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\n\r\n");
const seed_serve_bad_escape = fuzzcorpus.entry("GET /have?path=%zz HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\n\r\n");
const seed_serve_data_no_range = fuzzcorpus.entry("GET /data?path=a.bin HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\n\r\n");
const seed_serve_data_bad_range = fuzzcorpus.entry("GET /data?path=a.bin HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\nRange: bytes=x-\r\n\r\n");

const fuzz_serve_corpus = [_][]const u8{
    &seed_req_have_ok,
    &seed_req_traversal,
    &seed_req_wrong_auth,
    &seed_req_control_path,
    &seed_req_max_range,
    &seed_req_inverted_range,
    &seed_req_no_path,
    &seed_serve_ping_ok,
    &seed_serve_post_ping,
    &seed_serve_no_target,
    &seed_serve_unterminated,
    &seed_serve_ping_unauthed,
    &seed_serve_unknown_route,
    &seed_serve_bad_escape,
    &seed_serve_data_no_range,
    &seed_serve_data_bad_range,
};

/// Every outcome handleConn's published order can produce for a head whose
/// origin lookups all miss. `dropped` covers both unroutable shapes: a head
/// that never terminates (EOF before \r\n\r\n) and one whose request line
/// names no target; neither earns a reply, only the malformed counter.
const ServeClass = enum { dropped, unauthorized, method_not_allowed, ping_ok, no_route, bad_path, bad_range, miss };

/// Independent walk of handleConn's decision order over the head the
/// handler will actually see (everything up to and including the blank
/// line; pipelined bytes past it belong to no request).
fn classifyServedHead(head: []const u8) ServeClass {
    const done = std.mem.find(u8, head, "\r\n\r\n") orelse return .dropped;
    const served = head[0 .. done + 4];
    const line_end = std.mem.find(u8, served, "\r\n") orelse return .dropped;
    var it = std.mem.splitScalar(u8, served[0..line_end], ' ');
    const method = it.next() orelse return .dropped;
    const target = it.next() orelse return .dropped;
    if (!std.mem.eql(u8, method, "GET")) return .method_not_allowed;
    const auth = proto.headerGet(served, "Authorization") orelse "";
    if (!proto.bearerOk(auth, fuzz_request_psk)) return .unauthorized;
    const path = proto.pathOnly(target);
    if (std.mem.eql(u8, path, "/ping")) return .ping_ok;
    const is_have = std.mem.eql(u8, path, "/have");
    if (!is_have and !std.mem.eql(u8, path, "/data")) return .no_route;
    var rel_buf: [4096]u8 = undefined;
    const q = proto.queryGet(target, "path") orelse return .bad_path;
    const rel = proto.urlDecode(&rel_buf, q) catch return .bad_path;
    if (!store_mod.relOk(rel)) return .bad_path;
    if (!is_have) {
        const rh = proto.headerGet(served, "Range") orelse return .bad_range;
        _ = proto.parseRange(rh) orelse return .bad_range;
    }
    // Both routed requests stop at statOrigin's ENOENT in the fixture
    // below and answer the healthy-miss 404.
    return .miss;
}

/// One connection served end to end against the classifier: the shared
/// body of the fuzz entry below and the mutation drill behind it, kept a
/// plain function of the head so both callers assert identical facts.
fn serveConnCheck(head: []const u8) anyerror!void {
    const want = classifyServedHead(head);

    const gpa = std.testing.allocator;
    // No origin or cache tree sits behind this server: every routed request
    // stops at statOrigin's ENOENT and touches no disk, so a check is a
    // pure function of the input and the only mutable state is the
    // monotonic counters asserted as deltas below.
    var st = store_mod.Store.init(gpa, std.testing.io, "/modelfs-fuzz-absent-origin", "/modelfs-fuzz-absent-cache", 16);
    defer st.deinit();
    var srv = Server{ .gpa = gpa, .io = std.testing.io, .psk = fuzz_request_psk, .store = &st };

    var fds: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds) != 0) return;
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    if (sys.writeAll(fds[0], head) < 0) return;
    // End the write half so a non-terminating head meets EOF instead of
    // holding the handler for the full head budget; replies still flow
    // back through this half of the pair.
    _ = c.shutdown(fds[0], c.SHUT_WR);

    // Expected-path warnings (401 source lines, 502 traces) stay off the
    // runner's stderr, like the sibling fault-tolerance tests.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    const malformed_before = st.stats.http_malformed.load(.monotonic);
    const unauthorized_before = st.stats.http_unauthorized.load(.monotonic);
    // acceptLoop claims one inflight slot per admitted connection; claim
    // the matching slot here so handleConn's unconditional release leaves
    // the gauge level.
    _ = srv.http_inflight.fetchAdd(1, .monotonic);

    handleConn(&srv, fds[1], std.mem.zeroes(c.struct_sockaddr_in));

    var rbuf: [512]u8 = undefined;
    var got_len: usize = 0;
    while (got_len < rbuf.len) {
        const r = c.recv(fds[0], &rbuf[got_len], rbuf.len - got_len, c.MSG_DONTWAIT);
        if (r <= 0) break;
        got_len += @intCast(r);
    }
    const got = rbuf[0..got_len];

    try std.testing.expectEqual(
        @as(u64, @intFromBool(want == .dropped)),
        st.stats.http_malformed.load(.monotonic) - malformed_before,
    );
    try std.testing.expectEqual(
        @as(u64, @intFromBool(want == .unauthorized)),
        st.stats.http_unauthorized.load(.monotonic) - unauthorized_before,
    );

    if (want == .dropped) {
        // An unroutable head earns silence: nothing a scanner can learn from.
        try std.testing.expectEqual(@as(usize, 0), got.len);
        return;
    }
    try std.testing.expect(got.len > 0);
    // Header block must terminate before any body bytes (/ping's "ok").
    try std.testing.expect(std.mem.indexOf(u8, got, "\r\n\r\n") != null);
    switch (want) {
        .dropped => unreachable,
        .method_not_allowed => try std.testing.expectEqualStrings(
            "HTTP/1.1 405 Method Not Allowed\r\nAllow: GET\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            got,
        ),
        .unauthorized => try std.testing.expectEqualStrings(
            "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            got,
        ),
        .ping_ok => try std.testing.expectEqualStrings(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
            got,
        ),
        .no_route, .miss => {
            try std.testing.expectEqualStrings(
                "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                got,
            );
        },
        .bad_path, .bad_range => {
            try std.testing.expectEqualStrings(
                "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                got,
            );
        },
    }
}

fn fuzzServeConnOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var wire_buf: [2048]u8 = undefined;
    try serveConnCheck(wire_buf[0..smith.slice(&wire_buf)]);
}

test "fuzz server conn answers every head per the routing contract" {
    try std.testing.fuzz({}, fuzzServeConnOne, .{ .corpus = &fuzz_serve_corpus });
}

test "fuzz server conn contract holds for mutated corpus heads" {
    // std.testing.fuzz runs each corpus entry once outside the --fuzz
    // runner, so the continuous loop this module's other harnesses rely on
    // never spins here (and the 0.16.0 --fuzz runner does not build at all).
    // This drill stands in: mutated corpus shapes get the exact assertions
    // the fuzzer would apply, deterministically, on every ordinary
    // `zig build test` run.
    var prng = std.Random.DefaultPrng.init(20260826);
    const rand = prng.random();
    const specials = "\r\n ?=&%.00";
    var buf: [2048]u8 = undefined;
    for (0..5_000) |_| {
        const base = fuzz_serve_corpus[rand.uintLessThan(usize, fuzz_serve_corpus.len)];
        const take = 1 + rand.uintLessThan(usize, @min(base.len + 24, buf.len));
        const n = @min(take, base.len);
        @memcpy(buf[0..n], base[0..n]);
        // Extending past the seed stages pipelined noise behind the blank
        // line; truncating cuts anywhere, including mid-escape or mid-CRLF.
        @memset(buf[n..take], 'A');
        const flips = rand.uintLessThan(usize, 6);
        for (0..flips) |_| {
            const p = rand.uintLessThan(usize, take);
            switch (rand.intRangeAtMost(u8, 0, 2)) {
                0 => buf[p] = rand.int(u8),
                1 => buf[p] = specials[rand.uintLessThan(usize, specials.len)],
                else => {},
            }
        }
        try serveConnCheck(buf[0..take]);
    }
}

// The harnesses above drive handleConn against a deliberately absent origin,
// so every routed request stops at statOrigin's ENOENT and the /data body
// path -- where attacker-chosen Range values meet real file bytes, hydration
// and the streaming loop -- never runs under fuzz. This section pins that
// branch: a tiny fixture origin (one 48-byte model on a 16-byte piece grid,
// one empty file, one directory) sits behind the same socketpair harness,
// and every head is classified by an independent walk of handleConn plus
// serveData's published decisions before the reply bytes are asserted.

/// The fixture model's bytes: distinct per position so any off-by-one in the
/// range clamp or the streaming offsets shows up as a body mismatch.
const data_file_size: u64 = 48;
const data_pattern: [data_file_size]u8 = blk: {
    var p: [data_file_size]u8 = undefined;
    for (&p, 0..) |*b, i| b.* = @truncate(i * 7 + 3);
    break :blk p;
};

const DataKind = enum { file48, file0, dir, absent };

fn dataKindOf(rel: []const u8) DataKind {
    if (std.mem.eql(u8, rel, "m.bin")) return .file48;
    if (std.mem.eql(u8, rel, "empty.bin")) return .file0;
    if (std.mem.eql(u8, rel, "d.gguf")) return .dir;
    return .absent;
}

const DataClass = union(enum) {
    dropped,
    method_not_allowed,
    unauthorized,
    ping_ok,
    no_route,
    bad_path,
    bad_range,
    /// Absent paths and non-regular files answer one identical 404, on
    /// /have and /data alike.
    not_found,
    have_bits: struct { bits_bytes: usize, nbits: u32 },
    not_satisfiable: u64,
    partial: struct { start: u64, end: u64 },
};

/// Independent restatement of handleConn's gate order plus serveData's and
/// serveHave's decisions over the fixture. Must stay a pure function of the
/// head: no store state, no clocks.
fn classifyDataHead(head: []const u8) DataClass {
    const done = std.mem.find(u8, head, "\r\n\r\n") orelse return .dropped;
    const served = head[0 .. done + 4];
    const line_end = std.mem.find(u8, served, "\r\n") orelse return .dropped;
    var it = std.mem.splitScalar(u8, served[0..line_end], ' ');
    const method = it.next().?;
    const target = it.next() orelse return .dropped;
    if (!std.mem.eql(u8, method, "GET")) return .method_not_allowed;
    const auth = proto.headerGet(served, "Authorization") orelse "";
    if (!proto.bearerOk(auth, fuzz_request_psk)) return .unauthorized;
    const path = proto.pathOnly(target);
    if (std.mem.eql(u8, path, "/ping")) return .ping_ok;
    const is_have = std.mem.eql(u8, path, "/have");
    if (!is_have and !std.mem.eql(u8, path, "/data")) return .no_route;
    var rel_buf: [4096]u8 = undefined;
    const q = proto.queryGet(target, "path") orelse return .bad_path;
    const rel = proto.urlDecode(&rel_buf, q) catch return .bad_path;
    if (!store_mod.relOk(rel)) return .bad_path;
    switch (dataKindOf(rel)) {
        .dir, .absent => return .not_found,
        .file48 => {},
        .file0 => {},
    }
    if (is_have) {
        return switch (dataKindOf(rel)) {
            .file48 => .{ .have_bits = .{ .bits_bytes = 1, .nbits = 3 } },
            .file0 => .{ .have_bits = .{ .bits_bytes = 0, .nbits = 0 } },
            .dir, .absent => .not_found,
        };
    }
    const rh = proto.headerGet(served, "Range") orelse return .bad_range;
    const rg = proto.parseRange(rh) orelse return .bad_range;
    switch (dataKindOf(rel)) {
        .dir, .absent => return .not_found,
        .file48 => {
            if (rg.start >= data_file_size) return .{ .not_satisfiable = data_file_size };
            return .{ .partial = .{ .start = rg.start, .end = @min(rg.end, data_file_size - 1) } };
        },
        // size 0: every start satisfies start >= size, so every range is 416
        .file0 => return .{ .not_satisfiable = 0 },
    }
}

/// Bits the server hands out must never carry uninitialized pad bits: the
/// bitmap rides the wire to peers verbatim, so a stray high bit would be a
/// heap-info leak across the trust boundary, not just a wrong answer.
fn havePadMask(nbits: usize) u8 {
    const rem = nbits % 8;
    return if (rem == 0) 0xFF else ~((@as(u8, 1) << @intCast(rem)) - 1);
}

const DataFixture = struct {
    gpa: std.mem.Allocator,
    origin_buf: [128]u8 = undefined,
    origin_len: usize = 0,
    cache_buf: [128]u8 = undefined,
    cache_len: usize = 0,
    st: store_mod.Store = undefined,
    srv: Server = undefined,

    fn create(gpa: std.mem.Allocator) !*DataFixture {
        const f = try gpa.create(DataFixture);
        errdefer gpa.destroy(f);
        f.* = .{ .gpa = gpa };
        const od = try sys.scratchDir(&f.origin_buf, "modelfs-fzdata-o");
        f.origin_len = od.len;
        errdefer sys.deleteTree(std.testing.io, od);
        const cd = try sys.scratchDir(&f.cache_buf, "modelfs-fzdata-c");
        f.cache_len = cd.len;
        errdefer sys.deleteTree(std.testing.io, cd);
        var zbuf: [192]u8 = undefined;
        var pbuf: [192]u8 = undefined;
        const mp = try std.fmt.bufPrint(&zbuf, "{s}/m.bin", .{od});
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&pbuf, mp), &data_pattern));
        const ep = try std.fmt.bufPrint(&zbuf, "{s}/empty.bin", .{od});
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&pbuf, ep), ""));
        const dp = try std.fmt.bufPrint(&zbuf, "{s}/d.gguf", .{od});
        try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(dp, 0o755));
        // Slices handed to Store must point at the heap copy: the local f
        // dies at return, its buffers do not survive the move.
        f.st = store_mod.Store.init(gpa, std.testing.io, od, cd, 16);
        errdefer f.st.deinit();
        try std.testing.expectEqual(@as(i32, 0), f.st.ensureLayout());
        f.srv = .{ .gpa = gpa, .io = std.testing.io, .psk = fuzz_request_psk, .store = &f.st };
        return f;
    }

    fn destroy(self: *DataFixture) void {
        self.st.deinit();
        sys.deleteTree(std.testing.io, self.origin());
        sys.deleteTree(std.testing.io, self.cache());
        self.gpa.destroy(self);
    }

    fn origin(self: *DataFixture) []const u8 {
        return self.origin_buf[0..self.origin_len];
    }

    fn cache(self: *DataFixture) []const u8 {
        return self.cache_buf[0..self.cache_len];
    }
};

/// One connection against the fixture, asserted per classifyDataHead. The
/// cache behind the fixture may already hold pieces from earlier heads in
/// the same run; every assertion below is a function of the origin bytes and
/// geometry only, so state evolution changes nothing the oracle expects --
/// which is what makes the mutated-head drill below safe to sequence.
fn serveDataCheck(f: *DataFixture, head: []const u8) anyerror!void {
    const want = classifyDataHead(head);

    var fds: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds) != 0) return;
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    if (sys.writeAll(fds[0], head) < 0) return;
    _ = c.shutdown(fds[0], c.SHUT_WR);

    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    const malformed_before = f.st.stats.http_malformed.load(.monotonic);
    const unauthorized_before = f.st.stats.http_unauthorized.load(.monotonic);
    _ = f.srv.http_inflight.fetchAdd(1, .monotonic);

    handleConn(&f.srv, fds[1], std.mem.zeroes(c.struct_sockaddr_in));

    var rbuf: [2048]u8 = undefined;
    var got_len: usize = 0;
    while (got_len < rbuf.len) {
        const r = c.recv(fds[0], &rbuf[got_len], rbuf.len - got_len, c.MSG_DONTWAIT);
        if (r <= 0) break;
        got_len += @intCast(r);
    }
    const got = rbuf[0..got_len];

    try std.testing.expectEqual(
        @as(u64, @intFromBool(want == .dropped)),
        f.st.stats.http_malformed.load(.monotonic) - malformed_before,
    );
    try std.testing.expectEqual(
        @as(u64, @intFromBool(want == .unauthorized)),
        f.st.stats.http_unauthorized.load(.monotonic) - unauthorized_before,
    );

    if (want == .dropped) {
        try std.testing.expectEqual(@as(usize, 0), got.len);
        return;
    }
    try std.testing.expect(got.len > 0);
    const body_at = std.mem.indexOf(u8, got, "\r\n\r\n") orelse return error.NoHeaderEnd;
    const rep_head = got[0..body_at];
    const body = got[body_at + 4 ..];

    switch (want) {
        .dropped => unreachable,
        .method_not_allowed => try std.testing.expectEqualStrings(
            "HTTP/1.1 405 Method Not Allowed\r\nAllow: GET\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            got,
        ),
        .unauthorized => try std.testing.expectEqualStrings(
            "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            got,
        ),
        .ping_ok => try std.testing.expectEqualStrings(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
            got,
        ),
        .no_route, .not_found => try std.testing.expectEqualStrings(
            "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            got,
        ),
        .bad_path, .bad_range => try std.testing.expectEqualStrings(
            "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            got,
        ),
        .not_satisfiable => |size| {
            var xbuf: [160]u8 = undefined;
            const x = try std.fmt.bufPrint(&xbuf, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{d}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{size});
            try std.testing.expectEqualStrings(x, got);
        },
        .partial => |pr| {
            const want_len: u64 = pr.end - pr.start + 1;
            try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 206 Partial Content\r\n"));
            var crbuf: [96]u8 = undefined;
            const cr = try std.fmt.bufPrint(&crbuf, "bytes {d}-{d}/{d}", .{ pr.start, pr.end, data_file_size });
            try std.testing.expectEqualStrings(cr, proto.headerGet(rep_head, "Content-Range") orelse return error.NoContentRange);
            const cl_str = proto.headerGet(rep_head, "Content-Length") orelse return error.NoContentLength;
            try std.testing.expectEqual(want_len, try std.fmt.parseInt(u64, cl_str, 10));
            try std.testing.expectEqual(want_len, @as(u64, body.len));
            try std.testing.expectEqualSlices(u8, data_pattern[pr.start..][0..want_len], body);
        },
        .have_bits => |hb| {
            try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200 OK\r\n"));
            try std.testing.expectEqualStrings("16", proto.headerGet(rep_head, "X-Piece-Size") orelse return error.NoPieceSize);
            const cl_str = proto.headerGet(rep_head, "Content-Length") orelse return error.NoContentLength;
            try std.testing.expectEqual(hb.bits_bytes, try std.fmt.parseInt(usize, cl_str, 10));
            try std.testing.expectEqual(hb.bits_bytes, body.len);
            const mask = havePadMask(hb.nbits);
            for (body) |b| try std.testing.expect(b & mask == 0);
        },
    }
}

const seed_data_full = fuzzcorpus.entry("GET /data?path=m.bin HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\nRange: bytes=0-47\r\n\r\n");
const seed_data_piece = fuzzcorpus.entry("GET /data?path=m.bin HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\nRange: bytes=16-31\r\n\r\n");
const seed_data_last_byte = fuzzcorpus.entry("GET /data?path=m.bin HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\nRange: bytes=47-47\r\n\r\n");
const seed_data_clamp = fuzzcorpus.entry("GET /data?path=m.bin HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\nRange: bytes=32-9999\r\n\r\n");
const seed_data_open = fuzzcorpus.entry("GET /data?path=m.bin HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\nRange: bytes=24-\r\n\r\n");
const seed_data_maxend = fuzzcorpus.entry("GET /data?path=m.bin HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\nRange: bytes=0-18446744073709551615\r\n\r\n");
const seed_data_416_eof = fuzzcorpus.entry("GET /data?path=m.bin HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\nRange: bytes=48-\r\n\r\n");
const seed_data_empty_416 = fuzzcorpus.entry("GET /data?path=empty.bin HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\nRange: bytes=0-0\r\n\r\n");
const seed_data_dir = fuzzcorpus.entry("GET /data?path=d.gguf HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\nRange: bytes=0-7\r\n\r\n");
const seed_data_absent = fuzzcorpus.entry("GET /data?path=nope.bin HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\nRange: bytes=0-7\r\n\r\n");
const seed_data_no_range = fuzzcorpus.entry("GET /data?path=m.bin HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\n\r\n");
const seed_data_bad_range = fuzzcorpus.entry("GET /data?path=m.bin HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\nRange: bytes=x-\r\n\r\n");
const seed_data_inverted = fuzzcorpus.entry("GET /data?path=m.bin HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\nRange: bytes=10-5\r\n\r\n");
const seed_data_escape = fuzzcorpus.entry("GET /data?path=%zz HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\nRange: bytes=0-1\r\n\r\n");
const seed_data_traversal = fuzzcorpus.entry("GET /data?path=..%2Fsecret HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\nRange: bytes=0-1\r\n\r\n");
const seed_have_cached = fuzzcorpus.entry("GET /have?path=m.bin HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\n\r\n");
const seed_have_empty = fuzzcorpus.entry("GET /have?path=empty.bin HTTP/1.1\r\nAuthorization: Bearer fuzz-psk\r\n\r\n");

const fuzz_data_corpus = [_][]const u8{
    &seed_data_full,
    &seed_data_piece,
    &seed_data_last_byte,
    &seed_data_clamp,
    &seed_data_open,
    &seed_data_maxend,
    &seed_data_416_eof,
    &seed_data_empty_416,
    &seed_data_dir,
    &seed_data_absent,
    &seed_data_no_range,
    &seed_data_bad_range,
    &seed_data_inverted,
    &seed_data_escape,
    &seed_data_traversal,
    &seed_have_cached,
    &seed_have_empty,
    // Shapes shared with the routing harness above: same input, now with a
    // live origin behind the server.
    &seed_req_have_ok,
    &seed_req_traversal,
    &seed_req_control_path,
    &seed_serve_ping_ok,
    &seed_serve_post_ping,
    &seed_serve_unterminated,
    &seed_serve_ping_unauthed,
    &seed_serve_unknown_route,
};

fn fuzzServeDataOne(fixture: *DataFixture, smith: *std.testing.Smith) anyerror!void {
    var wire_buf: [2048]u8 = undefined;
    try serveDataCheck(fixture, wire_buf[0..smith.slice(&wire_buf)]);
}

test "fuzz data path serves attacker ranges within the published contract" {
    const gpa = std.testing.allocator;
    const fixture = try DataFixture.create(gpa);
    defer fixture.destroy();
    try std.testing.fuzz(fixture, fuzzServeDataOne, .{ .corpus = &fuzz_data_corpus });
}

test "fuzz data path contract holds for mutated corpus heads" {
    // Same stand-in for the continuous --fuzz runner as the routing drill
    // above, with one addition the absent-origin harness cannot offer:
    // sequenced heads evolve the cache (fills land, bits persist), and the
    // oracle must hold identically on every iteration anyway.
    const gpa = std.testing.allocator;
    const fixture = try DataFixture.create(gpa);
    defer fixture.destroy();
    var prng = std.Random.DefaultPrng.init(20260827);
    const rand = prng.random();
    const specials = "\r\n ?=&%.-09";
    var buf: [2048]u8 = undefined;
    for (0..2_500) |_| {
        const base = fuzz_data_corpus[rand.uintLessThan(usize, fuzz_data_corpus.len)];
        const take = 1 + rand.uintLessThan(usize, @min(base.len + 24, buf.len));
        const n = @min(take, base.len);
        @memcpy(buf[0..n], base[0..n]);
        @memset(buf[n..take], 'A');
        const flips = rand.uintLessThan(usize, 6);
        for (0..flips) |_| {
            const p = rand.uintLessThan(usize, take);
            switch (rand.intRangeAtMost(u8, 0, 2)) {
                0 => buf[p] = rand.int(u8),
                1 => buf[p] = specials[rand.uintLessThan(usize, specials.len)],
                else => {},
            }
        }
        try serveDataCheck(fixture, buf[0..take]);
    }
}
