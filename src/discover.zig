//! Cluster membership over origin-side lease files: publish/refresh/sweep,
//! the /have probe cache, and path scoring (goodput, hops, inflight).
const std = @import("std");
const proto = @import("proto.zig");
const sys = @import("sys.zig");
const c = sys.c;

pub const Path = struct {
    peer_id: []const u8,
    ip: []const u8,
    port: u16,
    ewma_bps: f64,
    hops: u32,
    inflight: std.atomic.Value(u32) = .init(0),
};

pub fn parseV4(s: []const u8, out: *[4]u8) bool {
    var part: u8 = 0;
    var acc: u32 = 0;
    var saw = false;
    for (s) |ch| {
        if (ch == '.') {
            if (!saw or part >= 3 or acc > 255) return false;
            out[part] = @intCast(acc);
            part += 1;
            acc = 0;
            saw = false;
            continue;
        }
        if (ch < '0' or ch > '9') return false;
        // Octets cap at 255: bail before acc*10 can overflow u32 on long
        // digit runs from untrusted input (peer lease ip fields).
        if (acc > 255) return false;
        acc = acc * 10 + (ch - '0');
        saw = true;
    }
    if (!saw or part != 3 or acc > 255) return false;
    out[3] = @intCast(acc);
    return true;
}

pub fn hopsBetween(local_ip: []const u8, remote_ip: []const u8) u32 {
    // L2 neighbor heuristic: same IPv4 /24 => 0 hops, else routed.
    var a: [4]u8 = undefined;
    var b: [4]u8 = undefined;
    if (parseV4(local_ip, &a) and parseV4(remote_ip, &b)) {
        if (a[0] == b[0] and a[1] == b[1] and a[2] == b[2]) return 0;
        return 1;
    }
    return 1;
}

pub fn pathScore(ewma_bps: f64, hops: u32, inflight: u32) f64 {
    const g = if (ewma_bps > 1.0) ewma_bps else 1.0;
    return g / (1.0 + @as(f64, hops)) / (1.0 + @as(f64, inflight));
}

pub const PathCand = struct {
    ip: []const u8,
    port: u16,
    ewma_bps: f64,
    hops: u32,
    inflight: u32,
    have: bool,

    pub fn score(self: PathCand) f64 {
        if (!self.have) return 0;
        return pathScore(self.ewma_bps, self.hops, self.inflight);
    }
};

/// Total order for score ties: ip bytes, then port. Candidate lists arrive
/// in lease-directory readdir order (addresses in the publisher's
/// getifaddrs order), so an unspecified tie would let environment
/// enumeration order decide which peer serves a piece; cold clusters start
/// every path at the same prior, making ties the steady state until the
/// first goodput samples land.
fn candTieLess(a: PathCand, b: PathCand) bool {
    switch (std.mem.order(u8, a.ip, b.ip)) {
        .lt => return true,
        .gt => return false,
        .eq => return a.port < b.port,
    }
}

/// The same tie-break over live catalog Paths: score descending, then ip
/// bytes, then port. The peer probe walk sorts each multi-homed group with
/// it so equal priors resolve by address bytes alone -- never by the lease
/// document's address order, which is the publisher's getifaddrs
/// enumeration and varies across reboots and machines.
pub fn pathTieLess(a: Path, b: Path) bool {
    switch (std.mem.order(u8, a.ip, b.ip)) {
        .lt => return true,
        .gt => return false,
        .eq => return a.port < b.port,
    }
}

/// Highest score among candidates that have the piece. Null if none. Score
/// ties break by candTieLess so the winner is a function of the candidate
/// set alone, never of the order refresh happened to read the leases in.
pub fn pickBest(cands: []const PathCand) ?usize {
    var best_i: ?usize = null;
    var best_s: f64 = 0;
    for (cands, 0..) |cand, i| {
        if (!cand.have) continue;
        const s = cand.score();
        if (best_i == null or s > best_s or (s == best_s and candTieLess(cand, cands[best_i.?]))) {
            best_i = i;
            best_s = s;
        }
    }
    return best_i;
}

/// Name of the origin-side control directory holding cluster leases
/// (<origin>/.cluster/<id>.json). Hidden from the FUSE mount and read by
/// `modelfs peers`; every module referencing the path must use this constant.
pub const cluster_dir = ".cluster";

/// True when s carries no C0 control byte or DEL. Lease file names come off
/// shared NFS storage and lease ids out of other nodes' JSON, so neither is
/// trustworthy for verbatim echo: a co-tenant planting ".cluster/<newline>
/// forged line.json" would forge multi-line daemon log entries, and an id
/// holding escapes would inject into the terminal running `modelfs peers`.
/// Same policy store.relOk applies to paths; such entries are still swept,
/// only their names are withheld from output.
pub fn printable(s: []const u8) bool {
    for (s) |ch| {
        if (ch < 0x20 or ch == 0x7f) return false;
    }
    return true;
}

/// A successful /have answer: the peer's cached-piece bitmap plus the piece
/// size its bits are indexed against. piece_size 0 means the peer did not
/// advertise one (an older build); consumers assume alignment for those.
pub const HaveBits = struct {
    bits: []u8,
    piece_size: u32,
};

/// Name safe to echo into a log line: the input when printable, else a fixed
/// placeholder. Lease file names come off shared NFS storage anyone with
/// origin write access can craft, so every site that logs one goes through
/// here rather than re-deciding the printable gate inline.
pub fn displayName(name: []const u8) []const u8 {
    return if (printable(name)) name else "<name withheld: control bytes>";
}

/// True when s is safe to publish as this node's cluster id. The id names
/// the lease file (<origin>/.cluster/<id>.json), is embedded verbatim as a
/// JSON string in that document, and is echoed into logs, so it must be
/// printable ASCII without path separators (lease filename), quote or
/// backslash (would corrupt the JSON for every peer's parser), or a leading
/// dot (refresh skips dot files). An id failing this gate would otherwise
/// partition its own node out of peer discovery while NFS fallback hides it.
pub fn validId(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '.') return false;
    for (s) |ch| {
        if (ch < 0x20 or ch > 0x7e) return false;
        if (ch == '/' or ch == '"' or ch == '\\') return false;
    }
    return true;
}

pub const Catalog = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mu: std.Io.Mutex = .init,
    origin: []const u8,
    self_id: []const u8,
    addrs: []const proto.LeaseAddr,
    /// Bootstrap peers used only while origin/.cluster has no live lease.
    seeds: []const proto.LeaseAddr = &.{},
    local_ips: []const []const u8,
    paths: std.ArrayList(Path) = .empty,
    // owned strings for paths
    arena: std.heap.ArenaAllocator,
    have_mu: std.Io.Mutex = .init,
    have_cache: std.ArrayList(HaveEntry) = .empty,

    /// Positive /have bitmaps from recent probes, keyed by (rel, ip, port).
    /// fillFromPeers runs once per piece; without this cache a sequential
    /// read of one large model re-probes the whole cluster for every piece
    /// (one connect plus round trip and a full bitmap transfer per peer per
    /// 16 MiB). Only hits are cached: a stale entry can at worst send us to
    /// a peer that no longer has the piece, which the fetch-failure
    /// fallback already handles.
    const have_ttl_ms: i64 = 2000;
    const have_cache_cap: usize = 32;

    const HaveEntry = struct {
        rel: []u8,
        ip: []u8,
        port: u16,
        bits: []u8,
        expires_ms: i64,
        /// Piece size the bits are indexed against, as advertised by the
        /// peer; cached so a TTL hit carries the same alignment context a
        /// fresh probe would.
        piece_size: u32 = 0,
    };

    fn freeHaveEntry(gpa: std.mem.Allocator, e: HaveEntry) void {
        gpa.free(e.rel);
        gpa.free(e.ip);
        gpa.free(e.bits);
    }

    /// Owned copy of a fresh /have bitmap for (rel, ip, port), or null when
    /// no unexpired entry exists at `now_ms`, the caller's monotonic-ms
    /// instant: the TTL decision is a pure function of cache state plus
    /// instant, so tests drive expiry virtually instead of sleeping.
    /// Copies under the lock so the entry cannot be replaced or freed
    /// between lookup and use by a concurrent filler.
    pub fn haveGet(self: *Catalog, gpa: std.mem.Allocator, rel: []const u8, ip: []const u8, port: u16, now_ms: i64) ?HaveBits {
        self.have_mu.lockUncancelable(self.io);
        defer self.have_mu.unlock(self.io);
        const now = now_ms;
        for (self.have_cache.items) |e| {
            if (e.port != port or !std.mem.eql(u8, e.rel, rel) or !std.mem.eql(u8, e.ip, ip)) continue;
            if (now >= e.expires_ms) return null;
            const bits = gpa.dupe(u8, e.bits) catch return null;
            return .{ .bits = bits, .piece_size = e.piece_size };
        }
        return null;
    }

    /// Caches a successful probe result; failures are never cached so a
    /// transiently down peer is retried on the next piece. `now_ms` is the
    /// caller's monotonic-ms instant (see haveGet).
    pub fn havePut(self: *Catalog, rel: []const u8, ip: []const u8, port: u16, bits: []const u8, piece_size: u32, now_ms: i64) void {
        const gpa = self.gpa;
        const now = now_ms;
        self.have_mu.lockUncancelable(self.io);
        defer self.have_mu.unlock(self.io);
        for (self.have_cache.items, 0..) |e, i| {
            if (e.port != port or !std.mem.eql(u8, e.rel, rel) or !std.mem.eql(u8, e.ip, ip)) continue;
            const b = gpa.dupe(u8, bits) catch {
                // OOM drops the cache line rather than keeping stale bits.
                freeHaveEntry(gpa, self.have_cache.orderedRemove(i));
                return;
            };
            gpa.free(e.bits);
            self.have_cache.items[i].bits = b;
            self.have_cache.items[i].expires_ms = now + have_ttl_ms;
            self.have_cache.items[i].piece_size = piece_size;
            return;
        }
        if (self.have_cache.items.len >= have_cache_cap) {
            // Evict an expired entry when one exists, else the soonest to
            // expire (items.len >= cap > 0, so a victim always exists).
            var victim: usize = 0;
            for (self.have_cache.items, 0..) |e, i| {
                if (now >= e.expires_ms) {
                    victim = i;
                    break;
                }
                if (e.expires_ms < self.have_cache.items[victim].expires_ms) victim = i;
            }
            freeHaveEntry(gpa, self.have_cache.orderedRemove(victim));
        }
        const rel_own = gpa.dupe(u8, rel) catch return;
        const ip_own = gpa.dupe(u8, ip) catch {
            gpa.free(rel_own);
            return;
        };
        const bits_own = gpa.dupe(u8, bits) catch {
            gpa.free(ip_own);
            gpa.free(rel_own);
            return;
        };
        self.have_cache.append(gpa, .{
            .rel = rel_own,
            .ip = ip_own,
            .port = port,
            .bits = bits_own,
            .expires_ms = now + have_ttl_ms,
            .piece_size = piece_size,
        }) catch {
            gpa.free(bits_own);
            gpa.free(ip_own);
            gpa.free(rel_own);
        };
    }

    /// Lease files are claims on shared NFS storage; without a teardown path
    /// one file per node id ever seen accumulates there forever. Nodes
    /// republish every discovery tick, so mtime age identifies dead claimants
    /// without parsing untrusted JSON or comparing clocks across hosts.
    const sweep_min_age_secs: i64 = 300;

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        origin: []const u8,
        self_id: []const u8,
        addrs: []const proto.LeaseAddr,
        local_ips: []const []const u8,
        seeds: []const proto.LeaseAddr,
    ) Catalog {
        return .{
            .gpa = gpa,
            .io = io,
            .origin = origin,
            .self_id = self_id,
            .addrs = addrs,
            .seeds = seeds,
            .local_ips = local_ips,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Catalog) void {
        for (self.have_cache.items) |e| freeHaveEntry(self.gpa, e);
        self.have_cache.deinit(self.gpa);
        self.paths.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Appends one address as a Path, duping id/ip into the given arena.
    /// The arena owns the dupes; on failure the entry is simply skipped.
    fn pushPath(
        self: *Catalog,
        list: *std.ArrayList(Path),
        arena: std.mem.Allocator,
        peer_id: []const u8,
        addr: proto.LeaseAddr,
    ) void {
        const id = arena.dupe(u8, peer_id) catch return;
        const ip = arena.dupe(u8, addr.ip) catch return;
        var hops: u32 = 1;
        for (self.local_ips) |lip| {
            hops = @min(hops, hopsBetween(lip, ip));
        }
        // Unprobed paths (mbps 0) start from a neutral prior instead of 0,
        // which pathScore would treat as "never pick".
        const prior_bps = if (addr.mbps == 0)
            1e8
        else
            @as(f64, addr.mbps) * 1_000_000.0 / 8.0;
        list.append(self.gpa, .{
            .peer_id = id,
            .ip = ip,
            .port = addr.port,
            .ewma_bps = prior_bps,
            .hops = hops,
        }) catch return;
    }

    fn clusterDir(self: Catalog, buf: []u8) ![*:0]u8 {
        return sys.joinZ(buf, self.origin, cluster_dir);
    }

    pub fn publish(self: *Catalog) void {
        // A node whose lease never lands disappears from the cluster for
        // every other peer; every skip below must reach the operator's log.
        var dbuf: [sys.c.PATH_MAX]u8 = undefined;
        const dir = self.clusterDir(&dbuf) catch {
            std.log.warn("lease publish skipped: origin path too long ({s})", .{self.origin});
            return;
        };
        _ = sys.mkdirAll(std.mem.span(dir), 0o755);
        var fbuf: [sys.c.PATH_MAX]u8 = undefined;
        const path = sys.joinZ(&fbuf, std.mem.span(dir), self.self_id) catch {
            std.log.warn("lease publish skipped: id \"{s}\" does not fit the lease path", .{self.self_id});
            return;
        };
        // <id>.json, staged through <id>.json.tmp + rename
        var with: [sys.c.PATH_MAX]u8 = undefined;
        const zpath = sys.appendExt(&with, path, ".json") catch {
            std.log.warn("lease publish skipped: id \"{s}\" does not fit the lease path", .{self.self_id});
            return;
        };
        var json_buf: [2048]u8 = undefined;
        const until = sys.nowSec() + 30;
        const json = proto.formatLease(&json_buf, self.self_id, until, self.addrs) catch {
            std.log.warn("lease publish skipped: {d} addresses do not fit the lease document", .{self.addrs.len});
            return;
        };

        var tmp: [sys.c.PATH_MAX]u8 = undefined;
        const ztmp = sys.appendExt(&tmp, zpath, ".tmp") catch {
            std.log.warn("lease publish skipped: id \"{s}\" does not fit the lease path", .{self.self_id});
            return;
        };
        // O_NOFOLLOW: the .cluster dir is shared NFS storage, and a symlink
        // planted at our staging name would redirect this truncate-and-write.
        if (sys.writeFileNoFollow(ztmp, json) != 0) {
            std.log.warn("lease publish failed at {s}", .{zpath});
            return;
        }
        if (std.c.rename(ztmp, zpath) != 0)
            std.log.warn("lease publish rename failed at {s}", .{zpath});
    }

    pub fn refresh(self: *Catalog) void {
        var dbuf: [sys.c.PATH_MAX]u8 = undefined;
        const dirz = self.clusterDir(&dbuf) catch return;
        const dir = c.opendir(dirz) orelse {
            // Degrade to the previous peer list, but say why it went stale.
            std.log.warn("cluster leases unreadable at {s}/{s}; keeping previous peer list", .{ self.origin, cluster_dir });
            return;
        };
        defer _ = c.closedir(dir);

        var new_arena = std.heap.ArenaAllocator.init(self.gpa);
        var new_paths: std.ArrayList(Path) = .empty;
        const now = sys.nowSec();

        while (c.readdir(dir)) |ent| {
            const name = sys.dirName(ent);
            if (name.len == 0 or name[0] == '.') continue;
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            var fbuf: [sys.c.PATH_MAX]u8 = undefined;
            const fp = sys.joinZ(&fbuf, std.mem.span(dirz), name) catch continue;
            var lease_buf: [4096]u8 = undefined;
            // ENOENT is the normal race against expiry cleanup; anything else
            // persisting across ticks is worth naming.
            const blob = sys.readFileBuf(&lease_buf, fp) catch |err| {
                if (err != error.OpenFailed) {
                    std.log.warn("lease read failed for {s}: {t}", .{ displayName(name), err });
                }
                continue;
            };
            const parsed = proto.parseLease(self.gpa, blob) catch {
                std.log.warn("skipping corrupt lease {s}", .{displayName(name)});
                continue;
            };
            defer parsed.deinit();
            const lease = parsed.value;
            if (lease.until < now) continue;
            if (std.mem.eql(u8, lease.id, self.self_id)) continue;
            for (lease.addrs) |a| {
                self.pushPath(&new_paths, new_arena.allocator(), lease.id, a);
            }
        }

        // Bootstrap: until any live lease shows up on the origin, dial the
        // static seeds passed via --seed so a cold cluster can still find
        // its first peers. Seeds are keyed by address, not by node id.
        if (new_paths.items.len == 0) {
            for (self.seeds) |s| {
                self.pushPath(&new_paths, new_arena.allocator(), s.ip, s);
            }
        }

        // Lease refresh replaces membership, not measurements: EWMA goodput
        // and in-flight transfer counts are properties of an address,
        // learned from the fetches since the last publish/refresh tick.
        // Rebuilding paths from cold lease priors every tick would reset
        // pathScore ten seconds after every measurement, re-bunching fetches
        // onto slow or busy peers, so a surviving (ip, port) carries its
        // numbers into the new list.
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (new_paths.items) |*np| {
            for (self.paths.items) |op| {
                if (op.port == np.port and std.mem.eql(u8, op.ip, np.ip)) {
                    np.ewma_bps = op.ewma_bps;
                    np.inflight.store(op.inflight.load(.monotonic), .monotonic);
                    break;
                }
            }
        }
        var old_arena = self.arena;
        var old_paths = self.paths;
        self.arena = new_arena;
        self.paths = new_paths;
        old_paths.deinit(self.gpa);
        old_arena.deinit();
    }

    /// Removes stale external claims from origin/.cluster: lease files whose
    /// mtime is older than sweep_min_age_secs (a live node rewrites its lease
    /// every publish tick) and abandoned .tmp staging files from crashed
    /// publishes. Our own lease is never swept even when our own writes are
    /// failing; that state must stay visible in the log, not vanish quietly.
    pub fn sweepLeases(self: *Catalog) void {
        var dbuf: [sys.c.PATH_MAX]u8 = undefined;
        const dirz = self.clusterDir(&dbuf) catch return;
        const dir = c.opendir(dirz) orelse return;
        defer _ = c.closedir(dir);
        const cutoff = sys.nowSec() - sweep_min_age_secs;
        while (c.readdir(dir)) |ent| {
            const name = sys.dirName(ent);
            if (name.len == 0 or name[0] == '.') continue;
            if (std.mem.endsWith(u8, name, ".json")) {
                if (std.mem.eql(u8, name[0 .. name.len - ".json".len], self.self_id)) continue;
            } else if (!std.mem.endsWith(u8, name, ".tmp")) {
                continue;
            }
            var fbuf: [sys.c.PATH_MAX]u8 = undefined;
            const fp = sys.joinZ(&fbuf, std.mem.span(dirz), name) catch continue;
            var st: c.struct_stat = undefined;
            if (sys.statPath(fp, &st) != 0) continue;
            if (st.st_mtim.tv_sec > cutoff) continue;
            if (c.unlink(fp) != 0) {
                std.log.warn("lease sweep unlink failed for {s} (errno {d})", .{ displayName(name), sys.errno() });
                continue;
            }
            std.log.info("swept stale cluster lease {s}", .{displayName(name)});
        }
    }

    pub fn snapshot(self: *Catalog, gpa: std.mem.Allocator) ![]Path {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var out: std.ArrayList(Path) = .empty;
        errdefer {
            for (out.items) |p| {
                gpa.free(p.peer_id);
                gpa.free(p.ip);
            }
            out.deinit(gpa);
        }
        for (self.paths.items) |p| {
            try out.append(gpa, .{
                .peer_id = try gpa.dupe(u8, p.peer_id),
                .ip = try gpa.dupe(u8, p.ip),
                .port = p.port,
                .ewma_bps = p.ewma_bps,
                .hops = p.hops,
                .inflight = .init(p.inflight.load(.monotonic)),
            });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Releases a slice returned by snapshot. Must be the allocator snapshot
    /// was called with.
    pub fn freeSnapshot(gpa: std.mem.Allocator, paths: []Path) void {
        for (paths) |p| {
            gpa.free(p.peer_id);
            gpa.free(p.ip);
        }
        gpa.free(paths);
    }

    pub fn updateGoodput(self: *Catalog, ip: []const u8, port: u16, bps: f64) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.paths.items) |*p| {
            if (p.port == port and std.mem.eql(u8, p.ip, ip)) {
                if (p.ewma_bps <= 1) {
                    p.ewma_bps = bps;
                } else {
                    p.ewma_bps = 0.3 * bps + 0.7 * p.ewma_bps;
                }
                return;
            }
        }
    }

    pub fn inflight(self: *Catalog, ip: []const u8, port: u16, delta: i32) u32 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.paths.items) |*p| {
            if (p.port == port and std.mem.eql(u8, p.ip, ip)) {
                if (delta > 0) {
                    return p.inflight.fetchAdd(@intCast(delta), .monotonic) + @as(u32, @intCast(delta));
                }
                const old = p.inflight.load(.monotonic);
                const sub: u32 = @intCast(-delta);
                const nv = if (old > sub) old - sub else 0;
                p.inflight.store(nv, .monotonic);
                return nv;
            }
        }
        return 0;
    }
};

pub fn localIpv4(gpa: std.mem.Allocator) ![][]const u8 {
    var ifa: ?*c.struct_ifaddrs = null;
    if (c.getifaddrs(&ifa) != 0) return error.Ifaddrs;
    defer c.freeifaddrs(ifa);
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| gpa.free(s);
        list.deinit(gpa);
    }
    var p = ifa;
    // net/if.h flag bits (c.h does not pull the header in).
    const IFF_UP: u32 = 0x1;
    const IFF_LOOPBACK: u32 = 0x8;
    while (p) |node| {
        defer p = node.ifa_next;
        const addr = node.ifa_addr orelse continue;
        if (addr.*.sa_family != c.AF_INET) continue;
        const flags = node.ifa_flags;
        if (flags & IFF_LOOPBACK != 0) continue;
        if (flags & IFF_UP == 0) continue;
        const sin: *c.struct_sockaddr_in = @ptrCast(@alignCast(addr));
        var buf: [c.INET_ADDRSTRLEN]u8 = undefined;
        const s = c.inet_ntop(c.AF_INET, &sin.sin_addr, &buf, buf.len) orelse continue;
        const span = std.mem.span(s);
        if (!shouldAdvertise(span)) continue;
        var dup = false;
        for (list.items) |have| {
            if (std.mem.eql(u8, have, span)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        try list.append(gpa, try gpa.dupe(u8, span));
    }
    return list.toOwnedSlice(gpa);
}

pub fn shouldAdvertise(ip: []const u8) bool {
    var oct: [4]u8 = undefined;
    if (!parseV4(ip, &oct)) return false;
    if (oct[0] == 127) return false;
    if (oct[0] == 169 and oct[1] == 254) return false;
    return true;
}

pub fn shortName(s: []const u8) []const u8 {
    if (std.mem.findScalar(u8, s, '.')) |i| {
        if (i > 0) return s[0..i];
    }
    return s;
}

/// Cluster id for this node, written into buf ("node" when unnamed). The
/// returned slice aliases buf (or static text), never gethostname's own
/// storage.
pub fn hostname(buf: []u8) []const u8 {
    // HOST_NAME_MAX + 1: POSIX guarantees no truncation at that size.
    var host_buf: [c.HOST_NAME_MAX + 1]u8 = undefined;
    if (c.gethostname(&host_buf, host_buf.len) != 0) {
        // A shared fallback id makes every such node publish the same lease
        // file and overwrite each other; operators must see why.
        std.log.warn("hostname unavailable; using cluster id \"node\"", .{});
        return "node";
    }
    const s = shortName(std.mem.sliceTo(&host_buf, 0));
    // The same gate --id answers to: a hostname is kernel-set operator
    // input, and one with a quote or slash would publish a lease document
    // or file name every peer's parser refuses.
    if (s.len == 0 or s.len >= buf.len or !validId(s)) {
        std.log.warn("hostname \"{s}\" unusable as cluster id; using \"node\"", .{s});
        return "node";
    }
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

test "have cache stores, replaces, evicts at cap, and frees" {
    const gpa = std.testing.allocator;
    const addrs = [_]proto.LeaseAddr{};
    var cat = Catalog.init(gpa, std.testing.io, "/unused", "me", &addrs, &.{}, &.{});
    defer cat.deinit();

    // One edge read of the real clock; every decision below runs on this
    // instant or offsets of it, so the TTL behavior is replayable exactly.
    const t0 = sys.monoMs();

    try std.testing.expect(cat.haveGet(gpa, "a.bin", "10.0.0.1", 18080, t0) == null);

    cat.havePut("a.bin", "10.0.0.1", 18080, &.{ 1, 2 }, 4096, t0);
    {
        const got = cat.haveGet(gpa, "a.bin", "10.0.0.1", 18080, t0).?;
        defer gpa.free(got.bits);
        try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, got.bits);
        // The alignment context rides with the bits: a TTL hit must answer
        // exactly what a fresh probe would have.
        try std.testing.expectEqual(@as(u32, 4096), got.piece_size);
    }
    // A different rel, ip, or port must not hit this entry.
    try std.testing.expect(cat.haveGet(gpa, "b.bin", "10.0.0.1", 18080, t0) == null);
    try std.testing.expect(cat.haveGet(gpa, "a.bin", "10.0.0.2", 18080, t0) == null);

    // Same key replaces in place instead of growing the table.
    cat.havePut("a.bin", "10.0.0.1", 18080, &.{3}, 8192, t0);
    {
        const got = cat.haveGet(gpa, "a.bin", "10.0.0.1", 18080, t0).?;
        defer gpa.free(got.bits);
        try std.testing.expectEqualSlices(u8, &.{3}, got.bits);
        try std.testing.expectEqual(@as(u32, 8192), got.piece_size);
    }
    try std.testing.expectEqual(@as(usize, 1), cat.have_cache.items.len);

    // Past the TTL the same entry answers nothing: stale bits would send
    // fills to pieces a peer no longer has. Virtual time pins the exact
    // boundary without sleeping: still fresh one tick before expiry, gone
    // the moment the window closes (haveGet is exclusive of expires_ms).
    if (cat.haveGet(gpa, "a.bin", "10.0.0.1", 18080, t0 + Catalog.have_ttl_ms - 1)) |fresh| {
        gpa.free(fresh.bits);
    } else return error.TestUnexpectedResult;
    try std.testing.expect(cat.haveGet(gpa, "a.bin", "10.0.0.1", 18080, t0 + Catalog.have_ttl_ms) == null);

    // Distinct keys fill to the cap; one more insert evicts exactly one
    // entry so the bound holds.
    var i: usize = 0;
    while (i < Catalog.have_cache_cap) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "f{d}.bin", .{i});
        cat.havePut(name, "10.1.0.1", 18080, &.{@intCast(i)}, 0, t0);
    }
    try std.testing.expectEqual(@as(usize, Catalog.have_cache_cap), cat.have_cache.items.len);
    cat.havePut("spill.bin", "10.1.0.1", 18080, &.{0}, 0, t0);
    try std.testing.expectEqual(@as(usize, Catalog.have_cache_cap), cat.have_cache.items.len);
}

test "printable gates lease names and ids for log echo" {
    try std.testing.expect(printable("spark1.json"));
    try std.testing.expect(printable("spark9"));
    // CR/LF would forge multi-line daemon log entries
    try std.testing.expect(!printable("a\n2026-08-24 ERROR forged"));
    try std.testing.expect(!printable("a\rb"));
    // ESC and other C0 bytes, plus DEL, would inject terminal escapes
    try std.testing.expect(!printable("\x1b]0;pwned\x07"));
    try std.testing.expect(!printable("\x7f"));
}

test "displayName echoes printable names and withholds the rest" {
    try std.testing.expectEqualStrings("spark1.json", displayName("spark1.json"));
    try std.testing.expectEqualStrings("<name withheld: control bytes>", displayName("a\nb"));
    try std.testing.expectEqualStrings("<name withheld: control bytes>", displayName("\x7f"));
}

test "validId gates the lease file name and JSON document" {
    try std.testing.expect(validId("spark1"));
    try std.testing.expect(validId("spark_1"));
    try std.testing.expect(validId("node-9.a")); // dots after the first char are fine
    try std.testing.expect(validId("spark 1")); // spaces survive name/JSON/log paths
    try std.testing.expect(validId("x~!@#$%^&*()+=[]{};',<>?|`"));
    // empty: every empty-id node would share one lease file
    try std.testing.expect(!validId(""));
    // leading dot: refresh skips dot files, so the lease would be invisible
    try std.testing.expect(!validId(".hidden"));
    try std.testing.expect(!validId(".."));
    // path separator: the id names .cluster/<id>.json
    try std.testing.expect(!validId("a/b"));
    // quote or backslash: formatLease embeds the id verbatim as a JSON
    // string; either would publish a document every peer parses as corrupt
    try std.testing.expect(!validId("a\"b"));
    try std.testing.expect(!validId("a\\b"));
    // control bytes and non-ASCII: same JSON corruption via invalid escapes
    try std.testing.expect(!validId("a\nb"));
    try std.testing.expect(!validId("a\tb"));
    try std.testing.expect(!validId("h\xc3\xa9llo"));
}

test "sweepLeases removes stale claims, keeps fresh and own" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-disc-sweep");
    defer sys.deleteTree(std.testing.io, origin_d);
    var cbuf: [160]u8 = undefined;
    const cluster_d = try std.fmt.bufPrint(&cbuf, "{s}/.cluster", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(cluster_d, 0o755));

    const lease_json = "{\"id\":\"x\",\"until\":1,\"addrs\":[]}";
    var zbuf: [192]u8 = undefined;
    // stale peer lease: swept
    var old_buf: [192]u8 = undefined;
    const old_fp = try std.fmt.bufPrint(&old_buf, "{s}/dead.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, old_fp), lease_json));
    // fresh peer lease: kept
    var new_buf: [192]u8 = undefined;
    const new_fp = try std.fmt.bufPrint(&new_buf, "{s}/alive.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, new_fp), lease_json));
    // abandoned staging file: swept
    var tmpf_buf: [192]u8 = undefined;
    const tmp_fp = try std.fmt.bufPrint(&tmpf_buf, "{s}/crashed.json.tmp", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, tmp_fp), "half"));
    // own lease with stale mtime: kept (our publish failures must stay visible)
    var me_buf: [192]u8 = undefined;
    const me_fp = try std.fmt.bufPrint(&me_buf, "{s}/me.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, me_fp), lease_json));

    // Age dead.json, crashed.json.tmp and me.json beyond the sweep cutoff.
    const past = [2]std.os.linux.timespec{
        .{ .sec = sys.nowSec() - 2 * Catalog.sweep_min_age_secs, .nsec = 0 },
        .{ .sec = sys.nowSec() - 2 * Catalog.sweep_min_age_secs, .nsec = 0 },
    };
    for ([_][]const u8{ old_fp, tmp_fp, me_fp }) |fp| {
        var zb: [192]u8 = undefined;
        const rc = std.os.linux.utimensat(std.posix.AT.FDCWD, try sys.toZ(&zb, fp), &past, 0);
        try std.testing.expectEqual(@as(usize, 0), rc);
    }

    const addrs = [_]proto.LeaseAddr{};
    var cat = Catalog.init(gpa, std.testing.io, origin_d, "me", &addrs, &.{}, &.{});
    defer cat.deinit();
    cat.sweepLeases();

    var stbuf: c.struct_stat = undefined;
    try std.testing.expect(sys.statPath(try sys.toZ(&zbuf, old_fp), &stbuf) != 0);
    try std.testing.expect(sys.statPath(try sys.toZ(&zbuf, tmp_fp), &stbuf) != 0);
    try std.testing.expect(sys.statPath(try sys.toZ(&zbuf, new_fp), &stbuf) == 0);
    try std.testing.expect(sys.statPath(try sys.toZ(&zbuf, me_fp), &stbuf) == 0);
}

test "hostname copies into buf" {
    var buf: [256]u8 = undefined;
    const name = hostname(&buf);
    try std.testing.expect(name.len > 0);
    try std.testing.expect(std.mem.findScalar(u8, name, '.') == null);
}

test "shouldAdvertise skips loopback and link-local" {
    try std.testing.expect(shouldAdvertise("10.0.1.1"));
    try std.testing.expect(shouldAdvertise("192.168.0.211"));
    try std.testing.expect(!shouldAdvertise("127.0.0.1"));
    try std.testing.expect(!shouldAdvertise("169.254.1.1"));
}

test "parseV4 validation" {
    var out: [4]u8 = undefined;
    try std.testing.expect(parseV4("10.0.0.1", &out));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 0, 0, 1 }, &out);
    try std.testing.expect(!parseV4("256.0.0.1", &out));
    try std.testing.expect(!parseV4("10.0.0", &out));
    try std.testing.expect(!parseV4("10.0.0.1.2", &out));
    try std.testing.expect(!parseV4("abc", &out));
    // long digit runs must fail validation, not overflow the accumulator
    try std.testing.expect(!parseV4("99999999999.1.1.1", &out));
    try std.testing.expect(!parseV4("1.1.1.99999999999", &out));
    try std.testing.expect(parseV4("0255.0.0.1", &out));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 1 }, &out);
}

test "path score: 200G L2 beats 10G routed beats busy 200G" {
    const fabric = pathScore(200_000_000_000.0 / 8.0, 0, 0);
    const mgmt = pathScore(10_000_000_000.0 / 8.0, 1, 0);
    const busy = pathScore(200_000_000_000.0 / 8.0, 0, 8);
    try std.testing.expect(fabric > mgmt);
    try std.testing.expect(fabric > busy);
}

test "pickBest is exclusive: one winner, skips !have" {
    const cands = [_]PathCand{
        .{ .ip = "192.168.0.1", .port = 18080, .ewma_bps = 1e9, .hops = 0, .inflight = 0, .have = false },
        .{ .ip = "192.168.0.2", .port = 18080, .ewma_bps = 5e8, .hops = 0, .inflight = 0, .have = true },
        .{ .ip = "192.168.0.3", .port = 18080, .ewma_bps = 9e9, .hops = 0, .inflight = 0, .have = true },
    };
    const i = pickBest(&cands).?;
    try std.testing.expectEqual(@as(usize, 2), i);
}

test "pickBest breaks score ties by ip and port, never by list order" {
    // A cold cluster hands every path the same prior, so equal scores are
    // the steady state; the winner must not follow lease-readdir order.
    const a = PathCand{ .ip = "10.0.0.2", .port = 18080, .ewma_bps = 1e9, .hops = 0, .inflight = 0, .have = true };
    const b = PathCand{ .ip = "10.0.0.1", .port = 18081, .ewma_bps = 1e9, .hops = 0, .inflight = 0, .have = true };
    try std.testing.expectEqual(@as(usize, 1), pickBest(&.{ a, b }).?);
    try std.testing.expectEqual(@as(usize, 0), pickBest(&.{ b, a }).?);
    // Same ip: the lower port wins regardless of arrival order.
    const lo = PathCand{ .ip = "10.0.0.2", .port = 18079, .ewma_bps = 1e9, .hops = 0, .inflight = 0, .have = true };
    try std.testing.expectEqual(@as(usize, 1), pickBest(&.{ a, lo }).?);
    try std.testing.expectEqual(@as(usize, 0), pickBest(&.{ lo, a }).?);
}

test "pathTieLess orders by ip then port" {
    // Same total order candTieLess gives candidates: the probe walk must
    // resolve equal priors by address bytes, never by lease arrival order.
    const mk = struct {
        fn p(ip: []const u8, port: u16) Path {
            return .{ .peer_id = "x", .ip = ip, .port = port, .ewma_bps = 1e8, .hops = 0 };
        }
    }.p;
    try std.testing.expect(pathTieLess(mk("10.0.0.5", 18080), mk("10.0.0.9", 18080)));
    try std.testing.expect(!pathTieLess(mk("10.0.0.9", 18080), mk("10.0.0.5", 18080)));
    try std.testing.expect(pathTieLess(mk("10.0.0.5", 18079), mk("10.0.0.5", 18081)));
    // Reflexivity: identical paths compare false both ways.
    try std.testing.expect(!pathTieLess(mk("10.0.0.5", 18080), mk("10.0.0.5", 18080)));
}

test "same /24 is zero hops" {
    try std.testing.expectEqual(@as(u32, 0), hopsBetween("192.168.100.1", "192.168.100.2"));
    try std.testing.expectEqual(@as(u32, 1), hopsBetween("192.168.100.1", "192.168.0.11"));
}

test "shortName strips domain" {
    try std.testing.expectEqualStrings("spark1", shortName("spark1"));
    try std.testing.expectEqualStrings("spark2", shortName("spark2.local"));
    try std.testing.expectEqualStrings("spark1", shortName("spark1.lan.example"));
}

test "publish stages a parseable lease, leaves no tmp, and replaces in place" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-disc-pub");
    defer sys.deleteTree(std.testing.io, origin_d);

    const addrs = [_]proto.LeaseAddr{
        .{ .ip = "192.168.100.10", .port = 18080, .mbps = 200000 },
        .{ .ip = "127.0.0.1", .port = 19090, .mbps = 0 },
    };
    var cat = Catalog.init(gpa, std.testing.io, origin_d, "me", &addrs, &.{}, &.{});
    defer cat.deinit();
    cat.publish();

    // The lease lands at <id>.json under .cluster with no .json.tmp staging
    // file left behind, and refresh's parser accepts exactly what publish
    // wrote: this roundtrip is what makes the node visible to peers.
    var zbuf: [192]u8 = undefined;
    var stbuf: c.struct_stat = undefined;
    var pbuf: [192]u8 = undefined;
    const lease_fp = try std.fmt.bufPrint(&pbuf, "{s}/.cluster/me.json", .{origin_d});
    try std.testing.expect(sys.statPath(try sys.toZ(&zbuf, lease_fp), &stbuf) == 0);
    var tbuf: [192]u8 = undefined;
    const tmp_fp = try std.fmt.bufPrint(&tbuf, "{s}/.cluster/me.json.tmp", .{origin_d});
    try std.testing.expect(sys.statPath(try sys.toZ(&zbuf, tmp_fp), &stbuf) != 0);

    const blob = try sys.readFileAlloc(gpa, try sys.toZ(&zbuf, lease_fp), 4096);
    defer gpa.free(blob);
    const parsed = try proto.parseLease(gpa, blob);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("me", parsed.value.id);
    // until is publish-time nowSec() + 30; allow one second of drift so a
    // second boundary between the two clock reads cannot flip the test.
    const now = sys.nowSec();
    try std.testing.expect(parsed.value.until >= now + 29);
    try std.testing.expect(parsed.value.until <= now + 31);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.addrs.len);
    try std.testing.expectEqualStrings("192.168.100.10", parsed.value.addrs[0].ip);
    try std.testing.expectEqual(@as(u16, 18080), parsed.value.addrs[0].port);
    try std.testing.expectEqual(@as(u32, 200000), parsed.value.addrs[0].mbps);
    try std.testing.expectEqualStrings("127.0.0.1", parsed.value.addrs[1].ip);
    try std.testing.expectEqual(@as(u16, 19090), parsed.value.addrs[1].port);

    // A later tick republishes: rename over the live lease must replace the
    // document wholesale (new address set wins), never fail or append.
    const addrs2 = [_]proto.LeaseAddr{.{ .ip = "10.9.9.9", .port = 19100, .mbps = 10000 }};
    var cat2 = Catalog.init(gpa, std.testing.io, origin_d, "me", &addrs2, &.{}, &.{});
    defer cat2.deinit();
    cat2.publish();
    const blob2 = try sys.readFileAlloc(gpa, try sys.toZ(&zbuf, lease_fp), 4096);
    defer gpa.free(blob2);
    const parsed2 = try proto.parseLease(gpa, blob2);
    defer parsed2.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed2.value.addrs.len);
    try std.testing.expectEqualStrings("10.9.9.9", parsed2.value.addrs[0].ip);
}

test "refresh skips self and expired leases" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    // pid suffix in scratchDir: scratch trees persist under .zig-cache/tmp
    // across runs, and a second-resolution stamp made runs starting in the
    // same second inherit the previous run's live (year-2100) leases,
    // flipping expectations.
    const origin_d = try sys.scratchDir(&ob, "modelfs-disc");
    defer sys.deleteTree(std.testing.io, origin_d);
    var cbuf: [160]u8 = undefined;
    const cluster_d = try std.fmt.bufPrint(&cbuf, "{s}/.cluster", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(cluster_d, 0o755));

    const leases = [_]struct { name: []const u8, json: []const u8 }{
        // live peer: must be discovered (until = year 2100)
        .{ .name = "spark9.json", .json = "{\"id\":\"spark9\",\"until\":4102444800,\"addrs\":[{\"ip\":\"10.0.0.1\",\"port\":18080,\"mbps\":200000}]}" },
        // self: must be skipped
        .{ .name = "me.json", .json = "{\"id\":\"me\",\"until\":0,\"addrs\":[{\"ip\":\"10.0.0.2\",\"port\":18080,\"mbps\":1}]}" },
        // expired: must be skipped
        .{ .name = "dead.json", .json = "{\"id\":\"dead\",\"until\":1,\"addrs\":[{\"ip\":\"10.0.0.3\",\"port\":18080,\"mbps\":1}]}" },
    };
    var zbuf: [192]u8 = undefined;
    for (leases) |l| {
        var pbuf: [192]u8 = undefined;
        const fp = try std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ cluster_d, l.name });
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), l.json));
    }

    const addrs = [_]proto.LeaseAddr{};
    const local_ips = [_][]const u8{"192.168.100.77"};
    var cat = Catalog.init(gpa, std.testing.io, origin_d, "me", &addrs, &local_ips, &.{});
    defer cat.deinit();
    cat.refresh();

    const snap = try cat.snapshot(gpa);
    defer Catalog.freeSnapshot(gpa, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqualStrings("spark9", snap[0].peer_id);
    try std.testing.expectEqualStrings("10.0.0.1", snap[0].ip);
    try std.testing.expectEqual(@as(u16, 18080), snap[0].port);
    // mbps prior converted to bps: 200000 mbit/s -> 25 Gbyte/s
    try std.testing.expectEqual(@as(f64, 25_000_000_000.0), snap[0].ewma_bps);
    // different /24 than local ip => routed
    try std.testing.expectEqual(@as(u32, 1), snap[0].hops);

    cat.updateGoodput("10.0.0.1", 18080, 5e9);
    cat.updateGoodput("10.0.0.1", 18080, 5e9);
    const paths = cat.paths.items;
    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expect(paths[0].ewma_bps < 25_000_000_000.0 and paths[0].ewma_bps > 5e9);

    try std.testing.expectEqual(@as(u32, 1), cat.inflight("10.0.0.1", 18080, 1));
    try std.testing.expectEqual(@as(u32, 0), cat.inflight("10.0.0.1", 18080, -1));
}

test "refresh uses seeds only while cluster is empty" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-disc-seed");
    defer sys.deleteTree(std.testing.io, origin_d);
    var cbuf: [160]u8 = undefined;
    const cluster_d = try std.fmt.bufPrint(&cbuf, "{s}/.cluster", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(cluster_d, 0o755));

    const seeds = [_]proto.LeaseAddr{
        .{ .ip = "10.0.0.9", .port = 19099, .mbps = 0 },
        .{ .ip = "10.1.0.9", .port = 19100, .mbps = 200000 },
    };
    const addrs = [_]proto.LeaseAddr{};
    const local_ips = [_][]const u8{"192.168.100.77"};
    var cat = Catalog.init(gpa, std.testing.io, origin_d, "me", &addrs, &local_ips, &seeds);
    defer cat.deinit();
    cat.refresh();

    const snap = try cat.snapshot(gpa);
    defer Catalog.freeSnapshot(gpa, snap);
    try std.testing.expectEqual(@as(usize, 2), snap.len);
    try std.testing.expectEqualStrings("10.0.0.9", snap[0].peer_id);
    try std.testing.expectEqual(@as(u16, 19099), snap[0].port);
    // mbps=0 seed gets the same default prior as an unprobed lease path
    try std.testing.expectEqual(@as(f64, 1e8), snap[0].ewma_bps);
    // mbps seed prior converts Mbit/s to B/s: 200000 mbit/s -> 25 GB/s
    try std.testing.expectEqual(@as(f64, 25_000_000_000.0), snap[1].ewma_bps);

    // Once a live lease exists, seeds are dropped in favor of real peers.
    var zbuf: [192]u8 = undefined;
    var pbuf: [192]u8 = undefined;
    const fp = try std.fmt.bufPrint(&pbuf, "{s}/spark9.json", .{cluster_d});
    const live = "{\"id\":\"spark9\",\"until\":4102444800,\"addrs\":[{\"ip\":\"10.9.9.9\",\"port\":18080,\"mbps\":0}]}";
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), live));
    cat.refresh();

    const snap2 = try cat.snapshot(gpa);
    defer Catalog.freeSnapshot(gpa, snap2);
    try std.testing.expectEqual(@as(usize, 1), snap2.len);
    try std.testing.expectEqualStrings("spark9", snap2[0].peer_id);
}

test "refresh carries learned goodput and inflight across ticks" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-disc-carry");
    defer sys.deleteTree(std.testing.io, origin_d);
    var cbuf: [160]u8 = undefined;
    const cluster_d = try std.fmt.bufPrint(&cbuf, "{s}/.cluster", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(cluster_d, 0o755));

    // Regression: refresh rebuilt every path from cold lease priors, so the
    // EWMA goodput learned since the last tick (and any in-flight count)
    // was discarded every ten seconds and pathScore reset to the prior.
    const seeds = [_]proto.LeaseAddr{
        .{ .ip = "10.0.0.9", .port = 19099, .mbps = 0 },
    };
    const addrs = [_]proto.LeaseAddr{};
    var cat = Catalog.init(gpa, std.testing.io, origin_d, "me", &addrs, &.{}, &seeds);
    defer cat.deinit();
    cat.refresh();
    try std.testing.expectEqual(@as(f64, 1e8), cat.paths.items[0].ewma_bps);

    // Learn something about the seed address: one measured transfer plus an
    // in-flight fetch.
    cat.updateGoodput("10.0.0.9", 19099, 5e9);
    const learned = cat.paths.items[0].ewma_bps;
    try std.testing.expectEqual(0.3 * 5e9 + 0.7 * @as(f64, 1e8), learned);
    try std.testing.expectEqual(@as(u32, 1), cat.inflight("10.0.0.9", 19099, 1));

    // A later tick republishes leases; the same address must keep its
    // measured goodput and its in-flight slot instead of restarting from
    // the prior.
    cat.refresh();
    try std.testing.expectEqual(@as(usize, 1), cat.paths.items.len);
    try std.testing.expectEqual(learned, cat.paths.items[0].ewma_bps);
    try std.testing.expectEqual(@as(u32, 1), cat.paths.items[0].inflight.load(.monotonic));

    // The carried inflight drains exactly once.
    try std.testing.expectEqual(@as(u32, 0), cat.inflight("10.0.0.9", 19099, -1));
}
