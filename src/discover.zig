//! Cluster membership over origin-side lease files: walkLeases, publish,
//! refresh, sweep, the /have probe cache, and path scoring (goodput, hops,
//! inflight).
const std = @import("std");
const proto = @import("proto.zig");
const sys = @import("sys.zig");
const fuzzcorpus = @import("fuzzcorpus.zig");
const c = sys.c;

pub const Path = struct {
    peer_id: []const u8,
    ip: []const u8,
    port: u16,
    ewma_bps: f64,
    hops: u32,
    inflight: std.atomic.Value(u32) = .init(0),
};

/// Parses a dotted quad into `out` (one byte per octet, in order). The accept
/// set is exactly the dialer's inet_pton: digits and dots, four parts, octets
/// capped at 255, and no leading zeros ("0255" is refused, "0" alone is
/// kept). Every admitted string is therefore dialable verbatim by peer.zig's
/// inet_pton gate; the fuzz harness below pins this against libc itself.
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
        // A second digit after a leading zero ("01", "0255") must fail: libc
        // inet_pton refuses those spellings, so admitting them here would put
        // undialable addresses into the path list.
        if (saw and acc == 0) return false;
        acc = acc * 10 + (ch - '0');
        saw = true;
    }
    if (!saw or part != 3 or acc > 255) return false;
    out[3] = @intCast(acc);
    return true;
}

fn hopsBetween(local_ip: []const u8, remote_ip: []const u8) u32 {
    // L2 neighbor heuristic: same IPv4 /24 => 0 hops, else routed.
    var a: [4]u8 = undefined;
    var b: [4]u8 = undefined;
    if (parseV4(local_ip, &a) and parseV4(remote_ip, &b)) {
        if (a[0] == b[0] and a[1] == b[1] and a[2] == b[2]) return 0;
        return 1;
    }
    return 1;
}

/// Path score: goodput / (1+hops) / (1+inflight). ewma_bps at or below 1 B/s
/// is floored to 1 so a zero prior cannot make every path score 0 and leave
/// pickBest with no winner; unprobed paths start at 100 MB/s instead.
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

/// Total order for score ties over an (ip, port) address: ip bytes, then
/// port. Candidate lists arrive in lease-directory readdir order (addresses
/// in the publisher's getifaddrs order), so an unspecified tie would let
/// environment enumeration order decide which peer serves a piece; cold
/// clusters start every path at the same prior, making ties the steady state
/// until the first goodput samples land.
fn addrTieLess(a_ip: []const u8, a_port: u16, b_ip: []const u8, b_port: u16) bool {
    switch (std.mem.order(u8, a_ip, b_ip)) {
        .lt => return true,
        .gt => return false,
        .eq => return a_port < b_port,
    }
}

fn candTieLess(a: PathCand, b: PathCand) bool {
    return addrTieLess(a.ip, a.port, b.ip, b.port);
}

/// The same tie-break over live catalog Paths: score descending, then ip
/// bytes, then port. The peer probe walk sorts each multi-homed group with
/// it so equal priors resolve by address bytes alone -- never by the lease
/// document's address order, which is the publisher's getifaddrs
/// enumeration and varies across reboots and machines.
pub fn pathTieLess(a: Path, b: Path) bool {
    return addrTieLess(a.ip, a.port, b.ip, b.port);
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

/// True when s carries no control character in its terminal-visible form
/// (proto.containsControl's set). Lease file names come off shared NFS
/// storage and lease ids out of other nodes' JSON, so neither is trustworthy
/// for verbatim echo: a co-tenant planting ".cluster/<newline> forged
/// line.json" would forge multi-line daemon log entries, an id holding ESC,
/// its C1 spelling "\u{9d}0;pwned\u{9c}", or "spark1\u{2028}ERROR forged"
/// would inject into the terminal running `modelfs peers`. Same policy
/// store.relOk applies to paths; such entries are still swept, only their
/// names are withheld from output. Bytes above that set (NFC/NFD spellings,
/// astral emoji, bare high bytes) are display text, not controls, and stay
/// echoable.
pub fn printable(s: []const u8) bool {
    return !proto.containsControl(s);
}

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
/// dot (walkLeases skips dot files). An id failing this gate would otherwise
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

/// Outcome of opening origin/.cluster for a lease walk. Callers interpret
/// missing_dir themselves: Catalog.refresh keeps the previous peer list;
/// `modelfs peers` lists as empty.
pub const LeaseWalk = enum { ok, path_too_long, missing_dir };

/// Cap on a lease document read from origin/.cluster. formatLease writes
/// into 2048 bytes; this is twice that so a slightly larger co-tenant
/// document still parses, while a multi-megabyte plant is refused.
const lease_file_max: usize = 4096;

/// Walks origin/.cluster, invoking `visitor.visit(name, parsed)` for each
/// `.json` lease that opened and parsed. `name` and `parsed` are valid only
/// for that call: copy anything that outlives it. Dot-prefixed names are
/// skipped (they cannot be a validId lease). Open/read/parse failures are
/// skipped and named. Catalog.refresh and `modelfs peers` share this walk
/// so the O_NOFOLLOW read, skip set, and corrupt-lease handling cannot drift.
pub fn walkLeases(gpa: std.mem.Allocator, origin: []const u8, visitor: anytype) LeaseWalk {
    var dbuf: [sys.c.PATH_MAX]u8 = undefined;
    const dirz = sys.joinZ(&dbuf, origin, cluster_dir) catch return .path_too_long;
    const dir = c.opendir(dirz) orelse return .missing_dir;
    defer _ = c.closedir(dir);

    while (c.readdir(dir)) |ent| {
        const name = sys.dirName(ent);
        if (name.len == 0 or name[0] == '.') continue;
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        var fbuf: [sys.c.PATH_MAX]u8 = undefined;
        const fp = sys.joinZ(&fbuf, std.mem.span(dirz), name) catch continue;
        var lease_buf: [lease_file_max]u8 = undefined;
        // ENOENT is the normal race against expiry cleanup and stays
        // unnamed; any other open failure (EACCES, ELOOP from a planted
        // symlink) persists across ticks and, left silent, reads exactly
        // like a dead cluster -- so it is named like the read failures
        // below. O_NOFOLLOW: a co-tenant who can plant a .json name must
        // not redirect this read onto a crafted lease outside .cluster.
        var open_errno: i32 = 0;
        const blob = sys.readFileBufNoFollowOpenErrno(&lease_buf, fp, &open_errno) catch |err| switch (err) {
            error.OpenFailed => {
                if (open_errno != c.ENOENT)
                    std.log.warn("lease open failed for {s} (errno {d})", .{ displayName(name), open_errno });
                continue;
            },
            else => {
                std.log.warn("lease read failed for {s}: {t}", .{ displayName(name), err });
                continue;
            },
        };
        const parsed = proto.parseLease(gpa, blob) catch {
            std.log.warn("skipping corrupt lease {s}", .{displayName(name)});
            continue;
        };
        defer parsed.deinit();
        visitor.visit(name, parsed);
    }
    return .ok;
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

    /// Live cache line for (rel, ip, port) at `now_ms`, or null when none
    /// is unexpired. Caller must hold have_mu: the pointer is invalidated
    /// by any havePut that replaces or evicts this key.
    fn haveLookup(self: *Catalog, rel: []const u8, ip: []const u8, port: u16, now_ms: i64) ?*HaveEntry {
        for (self.have_cache.items) |*e| {
            if (e.port != port or !std.mem.eql(u8, e.rel, rel) or !std.mem.eql(u8, e.ip, ip)) continue;
            if (now_ms >= e.expires_ms) return null;
            return e;
        }
        return null;
    }

    /// Owned copy of a fresh /have bitmap for (rel, ip, port), or null when
    /// no unexpired entry exists at `now_ms`, the caller's monotonic-ms
    /// instant: the TTL decision is a pure function of cache state plus
    /// instant, so tests drive expiry virtually instead of sleeping.
    /// Copies under the lock so the entry cannot be replaced or freed
    /// between lookup and use by a concurrent filler.
    pub fn haveGet(self: *Catalog, gpa: std.mem.Allocator, rel: []const u8, ip: []const u8, port: u16, now_ms: i64) ?proto.HaveBits {
        self.have_mu.lockUncancelable(self.io);
        defer self.have_mu.unlock(self.io);
        const e = self.haveLookup(rel, ip, port, now_ms) orelse return null;
        const bits = gpa.dupe(u8, e.bits) catch return null;
        return .{ .bits = bits, .piece_size = e.piece_size };
    }

    /// Whether piece `idx` is present in an unexpired (rel, ip, port) line
    /// whose grid matches `local_piece_size` (unknown advertised size is
    /// assumed aligned). Null means no usable line -- the caller must
    /// probe. Reads the one bit under the lock and copies nothing: sequential
    /// fills of one file used to dupe the whole bitmap per peer per piece
    /// just to test this bit, allocating bytesLen(pieces) on every 16 MiB
    /// for the TTL window.
    pub fn haveHas(self: *Catalog, rel: []const u8, ip: []const u8, port: u16, idx: u32, local_piece_size: u32, now_ms: i64) ?bool {
        self.have_mu.lockUncancelable(self.io);
        defer self.have_mu.unlock(self.io);
        const e = self.haveLookup(rel, ip, port, now_ms) orelse return null;
        return (proto.HaveBits{ .bits = e.bits, .piece_size = e.piece_size }).hasPiece(idx, local_piece_size);
    }

    /// Caches a successful probe result; failures are never cached so a
    /// transiently down peer is retried on the next piece. `now_ms` is the
    /// caller's monotonic-ms instant (see haveGet).
    pub fn havePut(self: *Catalog, rel: []const u8, ip: []const u8, port: u16, bits: []const u8, piece_size: u32, now_ms: i64) void {
        const gpa = self.gpa;
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
            self.have_cache.items[i].expires_ms = now_ms +| have_ttl_ms;
            self.have_cache.items[i].piece_size = piece_size;
            return;
        }
        if (self.have_cache.items.len >= have_cache_cap) {
            // Evict an expired entry when one exists, else the soonest to
            // expire (items.len >= cap > 0, so a victim always exists).
            var victim: usize = 0;
            for (self.have_cache.items, 0..) |e, i| {
                if (now_ms >= e.expires_ms) {
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
            .expires_ms = now_ms +| have_ttl_ms,
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
    /// without parsing untrusted JSON. Age is measured against this node's
    /// own lease mtime on that filesystem (the origin/NAS clock), not against
    /// CLOCK_REALTIME on the spark: a NAS minutes behind the nodes would
    /// otherwise make every live peer look idle and unlink their leases.
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
    /// Addresses failing the dotted-quad gate are skipped too: every dialer
    /// inet_pton's the ip field, so a non-quad could never be reached, and
    /// lease ips arrive as other nodes' JSON off shared NFS storage -- an
    /// arbitrary string here would otherwise ride the fetch-failure log
    /// line (its CR/LF or terminal escapes included) while dialing it. The
    /// gate accepts digits and dots only, so nothing unprintable survives
    /// it; legitimate publishers emit inet_ntop output, never hostnames
    /// (--advertise refuses those at the flag for the same reason). Port 0
    /// is the same class as a non-quad: --listen/--advertise/--seed already
    /// refuse it (an ephemeral bind whose lease would still advertise 0),
    /// and a planted lease with port 0 is undialable, so it must not occupy
    /// a path slot that fillFromPeers will burn a dial-timeout on.
    fn pushPath(
        self: *Catalog,
        list: *std.ArrayList(Path),
        arena: std.mem.Allocator,
        peer_id: []const u8,
        addr: proto.LeaseAddr,
    ) void {
        var quad: [4]u8 = undefined;
        if (!parseV4(addr.ip, &quad)) return;
        if (addr.port == 0) return;
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

    /// Lease lifetime in seconds: several discovery ticks wide, so one
    /// missed republish does not expire this node out of every peer's list.
    const lease_ttl_secs: i64 = 30;

    /// Publishes this node's lease with `until = now_sec + lease_ttl_secs`.
    /// The caller's wall-clock instant (epoch seconds: leases are compared
    /// across machines) keeps the document a pure function of state plus
    /// instant, so tests pin the exact expiry instead of racing a second
    /// boundary between two clock reads.
    pub fn publish(self: *Catalog, now_sec: i64) void {
        // A node whose lease never lands disappears from the cluster for
        // every other peer; every skip below must reach the operator's log.
        var dbuf: [sys.c.PATH_MAX]u8 = undefined;
        const dir = self.clusterDir(&dbuf) catch {
            std.log.warn("lease publish skipped: origin path too long ({s})", .{self.origin});
            return;
        };
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
        const until = now_sec +| lease_ttl_secs;
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
        // The parent directory is created only when the first write misses it
        // (same shape as store.writeFileMakingParent): an unconditional mkdirAll
        // here cost one failed mkdir per path component on the origin -- NFS
        // round trips -- from every node on every discovery tick for the life
        // of the cluster. A parent that cannot be created surfaces as the
        // retried write's errno below.
        var w = sys.writeFileNoFollow(ztmp, json);
        if (w == -c.ENOENT) {
            _ = sys.mkdirAll(std.mem.span(dir), 0o755);
            w = sys.writeFileNoFollow(ztmp, json);
        }
        if (w != 0) {
            // Staging file may exist from a partial write; leave none behind.
            // A retry every tick would refresh mtime, so sweepLeases would
            // never age it out.
            _ = c.unlink(ztmp);
            std.log.warn("lease publish failed at {s} (errno {d})", .{ zpath, -w });
            return;
        }
        if (std.c.rename(ztmp, zpath) != 0) {
            const e = sys.errno();
            _ = c.unlink(ztmp);
            std.log.warn("lease publish rename failed at {s} (errno {d})", .{ zpath, e });
        }
    }

    /// Rebuilds the peer list from origin/.cluster, dropping leases expired
    /// at `now_sec` (the caller's wall-clock instant, as in publish). One
    /// sample per tick: every expiry decision below sees the same instant
    /// instead of drifting across the directory walk.
    pub fn refresh(self: *Catalog, now_sec: i64) void {
        const Acc = struct {
            cat: *Catalog,
            now_sec: i64,
            arena: std.mem.Allocator,
            paths: *std.ArrayList(Path),

            pub fn visit(acc: *@This(), name: []const u8, parsed: std.json.Parsed(proto.Lease)) void {
                _ = name;
                const lease = parsed.value;
                if (lease.until < acc.now_sec) return;
                if (std.mem.eql(u8, lease.id, acc.cat.self_id)) return;
                for (lease.addrs) |a| {
                    acc.cat.pushPath(acc.paths, acc.arena, lease.id, a);
                }
            }
        };

        var new_arena = std.heap.ArenaAllocator.init(self.gpa);
        var new_paths: std.ArrayList(Path) = .empty;
        var acc: Acc = .{
            .cat = self,
            .now_sec = now_sec,
            .arena = new_arena.allocator(),
            .paths = &new_paths,
        };
        switch (walkLeases(self.gpa, self.origin, &acc)) {
            .ok => {},
            .path_too_long => {
                new_paths.deinit(self.gpa);
                new_arena.deinit();
                return;
            },
            .missing_dir => {
                new_paths.deinit(self.gpa);
                new_arena.deinit();
                // Degrade to the previous peer list, but say why it went stale.
                std.log.warn("cluster leases unreadable at {s}/{s}; keeping previous peer list", .{ self.origin, cluster_dir });
                return;
            },
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
    /// mtime is older than sweep_min_age_secs relative to this node's own
    /// lease mtime on that filesystem (a live node rewrites its lease every
    /// publish tick) and abandoned .tmp staging files from crashed publishes.
    /// Our own lease is never swept even when our own writes are failing;
    /// that state must stay visible in the log, not vanish quietly. `now_sec`
    /// is the fallback cutoff clock when we have no lease file yet (tests,
    /// or a tick whose publish never landed).
    pub fn sweepLeases(self: *Catalog, now_sec: i64) void {
        var dbuf: [sys.c.PATH_MAX]u8 = undefined;
        const dirz = self.clusterDir(&dbuf) catch return;
        const dir = c.opendir(dirz) orelse return;
        defer _ = c.closedir(dir);
        const cutoff = self.sweepCutoff(dirz, now_sec);
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
            // Every node runs this sweep each discovery tick, so a stale
            // claim usually has several removers racing: losing the race is
            // ENOENT between our stat above and the unlink, and that is the
            // swept outcome already reached, not a failure. Only a real
            // unlink error gets an operator line (same policy as store.zig's
            // unlinkOrWarn); the info line stays tied to actually sweeping.
            if (c.unlink(fp) != 0) {
                const e = sys.errno();
                if (e != c.ENOENT) {
                    std.log.warn("lease sweep unlink failed for {s} (errno {d})", .{ displayName(name), e });
                }
                continue;
            }
            std.log.info("swept stale cluster lease {s}", .{displayName(name)});
        }
    }

    /// Cutoff instant for sweepLeases: this node's own lease mtime on the
    /// origin filesystem minus sweep_min_age_secs, so NAS/spark clock skew
    /// cannot make live peers look idle. `now_sec` is used only when that
    /// file is missing.
    fn sweepCutoff(self: *const Catalog, dirz: [*:0]const u8, now_sec: i64) i64 {
        const ref_sec = blk: {
            var ibuf: [sys.c.PATH_MAX]u8 = undefined;
            const ipath = sys.joinZ(&ibuf, std.mem.span(dirz), self.self_id) catch break :blk now_sec;
            var ebuf: [sys.c.PATH_MAX]u8 = undefined;
            const zown = sys.appendExt(&ebuf, ipath, ".json") catch break :blk now_sec;
            var ost: c.struct_stat = undefined;
            if (sys.statPath(zown, &ost) != 0) break :blk now_sec;
            break :blk ost.st_mtim.tv_sec;
        };
        return ref_sec -| sweep_min_age_secs;
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
            // Own each string before the struct literal: a failed ip dupe must
            // free the id copy instead of leaking it past the errdefer above
            // (which only sees appended items).
            const peer_id = try gpa.dupe(u8, p.peer_id);
            errdefer gpa.free(peer_id);
            const ip = try gpa.dupe(u8, p.ip);
            errdefer gpa.free(ip);
            try out.append(gpa, .{
                .peer_id = peer_id,
                .ip = ip,
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

    test "snapshot frees both strings when any allocation fails" {
        const gpa = std.testing.allocator;
        const addrs = [_]proto.LeaseAddr{};
        var cat = Catalog.init(gpa, std.testing.io, "/unused", "me", &addrs, &.{}, &.{});
        defer cat.deinit();
        try cat.paths.append(gpa, .{ .peer_id = "a", .ip = "10.0.0.1", .port = 1, .ewma_bps = 0, .hops = 0 });
        try cat.paths.append(gpa, .{ .peer_id = "b", .ip = "10.0.0.2", .port = 2, .ewma_bps = 0, .hops = 0 });

        const Runner = struct {
            fn run(alloc: std.mem.Allocator, catalog: *Catalog) !void {
                const snap = try catalog.snapshot(alloc);
                Catalog.freeSnapshot(alloc, snap);
            }
        };
        // Walks every allocation index of snapshot, including the ip dupe
        // that lands after the id copy: regression, a failure there used to
        // leak the id copy because the errdefer only saw appended items.
        try std.testing.checkAllAllocationFailures(gpa, Runner.run, .{&cat});
    }

    pub fn updateGoodput(self: *Catalog, ip: []const u8, port: u16, bps: f64) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const p = self.pathByAddr(ip, port) orelse return;
        if (p.ewma_bps <= 1) {
            p.ewma_bps = bps;
        } else {
            p.ewma_bps = 0.3 * bps + 0.7 * p.ewma_bps;
        }
    }

    pub fn inflight(self: *Catalog, ip: []const u8, port: u16, delta: i32) u32 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const p = self.pathByAddr(ip, port) orelse return 0;
        if (delta > 0) {
            return p.inflight.fetchAdd(@intCast(delta), .monotonic) + @as(u32, @intCast(delta));
        }
        const old = p.inflight.load(.monotonic);
        const sub: u32 = @intCast(-delta);
        const nv = if (old > sub) old - sub else 0;
        p.inflight.store(nv, .monotonic);
        return nv;
    }

    /// Path keyed to (ip, port), or null. Caller must hold mu; every
    /// address-keyed lookup on the live list goes through here so the
    /// keying contract cannot drift between callers.
    fn pathByAddr(self: *Catalog, ip: []const u8, port: u16) ?*Path {
        for (self.paths.items) |*p| {
            if (p.port == port and std.mem.eql(u8, p.ip, ip)) return p;
        }
        return null;
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
    while (p) |node| {
        defer p = node.ifa_next;
        const addr = node.ifa_addr orelse continue;
        if (addr.*.sa_family != c.AF_INET) continue;
        const flags = node.ifa_flags;
        if ((flags & @as(@TypeOf(flags), @intCast(c.IFF_LOOPBACK))) != 0) continue;
        if ((flags & @as(@TypeOf(flags), @intCast(c.IFF_UP))) == 0) continue;
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

fn shouldAdvertise(ip: []const u8) bool {
    var oct: [4]u8 = undefined;
    if (!parseV4(ip, &oct)) return false;
    if (oct[0] == 127) return false;
    if (oct[0] == 169 and oct[1] == 254) return false;
    return true;
}

fn shortName(s: []const u8) []const u8 {
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
        // Same echo policy as refresh/sweepLeases: a name failing the
        // printable gate must not forge log lines or inject terminal escapes.
        std.log.warn("hostname \"{s}\" unusable as cluster id; using \"node\"", .{displayName(s)});
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
    const t0 = sys.monoMs(std.testing.io);

    try std.testing.expect(cat.haveGet(gpa, "a.bin", "10.0.0.1", 18080, t0) == null);

    cat.havePut("a.bin", "10.0.0.1", 18080, &.{ 1, 2 }, 4096, t0);
    {
        const got = cat.haveGet(gpa, "a.bin", "10.0.0.1", 18080, t0).?;
        defer gpa.free(got.bits);
        try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, got.bits);
        // The alignment context rides with the bits: a TTL hit must answer
        // exactly what a fresh probe would have.
        try std.testing.expectEqual(@as(u32, 4096), got.piece_size);
        try std.testing.expect(got.hasPiece(0, 4096));
        try std.testing.expect(!got.hasPiece(1, 4096));
        try std.testing.expect(got.hasPiece(9, 4096));
        try std.testing.expect(!got.hasPiece(0, 8192));
    }
    // haveHas reads the same line without copying the bitmap.
    try std.testing.expectEqual(@as(?bool, true), cat.haveHas("a.bin", "10.0.0.1", 18080, 0, 4096, t0));
    try std.testing.expectEqual(@as(?bool, false), cat.haveHas("a.bin", "10.0.0.1", 18080, 1, 4096, t0));
    try std.testing.expectEqual(@as(?bool, true), cat.haveHas("a.bin", "10.0.0.1", 18080, 9, 4096, t0));
    try std.testing.expectEqual(@as(?bool, false), cat.haveHas("a.bin", "10.0.0.1", 18080, 0, 8192, t0));
    try std.testing.expect(cat.haveHas("b.bin", "10.0.0.1", 18080, 0, 4096, t0) == null);
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
    try std.testing.expectEqual(@as(?bool, true), cat.haveHas("a.bin", "10.0.0.1", 18080, 0, 8192, t0 + Catalog.have_ttl_ms - 1));
    try std.testing.expect(cat.haveGet(gpa, "a.bin", "10.0.0.1", 18080, t0 + Catalog.have_ttl_ms) == null);
    try std.testing.expect(cat.haveHas("a.bin", "10.0.0.1", 18080, 0, 8192, t0 + Catalog.have_ttl_ms) == null);

    // Distinct keys fill to the cap; one more insert evicts exactly one
    // entry so the bound holds. Expiries are staggered (earlier inserts
    // expire sooner), so the documented victim choice -- expired first,
    // else soonest to expire -- names a specific casualty per spill, and
    // the freshest line (a.bin) must survive both.
    var i: usize = 0;
    while (i < Catalog.have_cache_cap) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "f{d}.bin", .{i});
        const put_at = t0 - @as(i64, @intCast(Catalog.have_cache_cap - i));
        cat.havePut(name, "10.1.0.1", 18080, &.{@intCast(i)}, 0, put_at);
    }
    try std.testing.expectEqual(@as(usize, Catalog.have_cache_cap), cat.have_cache.items.len);
    // f31's insert evicted soonest-to-expire f0, not the newest entry.
    try std.testing.expect(cat.haveGet(gpa, "f0.bin", "10.1.0.1", 18080, t0) == null);
    if (cat.haveGet(gpa, "a.bin", "10.0.0.1", 18080, t0)) |fresh| {
        gpa.free(fresh.bits);
    } else return error.TestUnexpectedResult;
    cat.havePut("spill.bin", "10.1.0.1", 18080, &.{0}, 0, t0);
    try std.testing.expectEqual(@as(usize, Catalog.have_cache_cap), cat.have_cache.items.len);
    // The next spill drains the next-soonest expiry in sequence.
    try std.testing.expect(cat.haveGet(gpa, "f1.bin", "10.1.0.1", 18080, t0) == null);
    if (cat.haveGet(gpa, "f31.bin", "10.1.0.1", 18080, t0)) |fresh| {
        gpa.free(fresh.bits);
    } else return error.TestUnexpectedResult;
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
    // C1 controls ride in as UTF-8 (0xC2 0x80..0xC2 0x9F), past a C0-only
    // byte gate: an id "\u{9d}0;pwned\u{9c}" is an 8-bit OSC sequence some
    // terminal families honor even in UTF-8 mode, and "\u{9b}31m" is CSI.
    try std.testing.expect(!printable("a\xc2\x9bd"));
    try std.testing.expect(!printable("\xc2\x9d0;pwned\xc2\x9c"));
    try std.testing.expect(!printable("\xc2\x9b"));
    // Unicode line/paragraph separators split log lines in Unicode-aware
    // terminals the same way CR/LF does; a C0/C1-only gate still echoes
    // "spark1\u{2028}ERROR forged" as two lines.
    try std.testing.expect(!printable("spark1\u{2028}ERROR forged"));
    try std.testing.expect(!printable("spark1\u{2029}p"));
    // Display text above the C1 range stays echoable: NBSP (U+00A0) shares
    // the 0xC2 lead byte but is not a control, nor are accented names.
    try std.testing.expect(printable("caf\xc3\xa9"));
    try std.testing.expect(printable("\xc2\xa0"));
    // A trailing 0xC2 with no continuation byte is invalid UTF-8 display
    // noise, not an injectable control. Incomplete U+2028 encodings match.
    try std.testing.expect(printable("a\xc2"));
    try std.testing.expect(printable("a\xe2\x80"));
    try std.testing.expect(printable("a\xe2"));
}

test "displayName echoes printable names and withholds the rest" {
    try std.testing.expectEqualStrings("spark1.json", displayName("spark1.json"));
    try std.testing.expectEqualStrings("<name withheld: control bytes>", displayName("a\nb"));
    try std.testing.expectEqualStrings("<name withheld: control bytes>", displayName("\x7f"));
    try std.testing.expectEqualStrings("<name withheld: control bytes>", displayName("spark1\u{2028}ERROR forged"));
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

const seed_id_plain = fuzzcorpus.entry("spark1");
const seed_id_dotted = fuzzcorpus.entry("node-9.a");
const seed_id_punct = fuzzcorpus.entry("x~!@#$%^&*()+=[]{};',<>?|`");
const seed_id_empty = fuzzcorpus.entry("");
const seed_id_leading_dot = fuzzcorpus.entry(".hidden");
const seed_id_dotdot = fuzzcorpus.entry("..");
const seed_id_separator = fuzzcorpus.entry("a/b");
const seed_id_quote = fuzzcorpus.entry("a\"b");
const seed_id_backslash = fuzzcorpus.entry("a\\b");
const seed_id_newline = fuzzcorpus.entry("a\nb");
const seed_id_nul = fuzzcorpus.entry("a\x00b");
const seed_id_non_ascii = fuzzcorpus.entry("h\xc3\xa9llo");
const seed_id_space = fuzzcorpus.entry("spark 1");
const seed_id_line_sep = fuzzcorpus.entry("spark1\u{2028}ERROR forged");

const fuzz_id_corpus = [_][]const u8{
    &seed_id_plain,
    &seed_id_dotted,
    &seed_id_punct,
    &seed_id_empty,
    &seed_id_leading_dot,
    &seed_id_dotdot,
    &seed_id_separator,
    &seed_id_quote,
    &seed_id_backslash,
    &seed_id_newline,
    &seed_id_nul,
    &seed_id_non_ascii,
    &seed_id_space,
    &seed_id_line_sep,
};

/// Lease ids arrive as other nodes' JSON on shared NFS storage and fan out
/// into three sinks: the lease file name, the verbatim JSON string this node
/// republishes, and daemon log lines. The harness pins all three edges:
/// validId must equal an independent restatement of its published contract
/// (so a table or loop drift cannot self-confirm); accepted ids are always
/// printable, so displayName echoes them verbatim; and every accepted id
/// survives the write/read pair publish() and refresh() perform -- embedded
/// by formatLease, parsed back by parseLease byte-exact. Rejected ids
/// legitimately skip that last leg (the writer never publishes them).
fn fuzzIdGateOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [128]u8 = undefined;
    const id = buf[0..smith.slice(&buf)];
    const ok = validId(id);

    var ref = id.len > 0 and id[0] != '.';
    for (id) |ch| {
        if (ch < 0x20 or ch > 0x7e or ch == '/' or ch == '"' or ch == '\\') ref = false;
    }
    try std.testing.expectEqual(ref, ok);

    try std.testing.expectEqual(printable(id), std.mem.eql(u8, id, displayName(id)));
    if (!ok) return;

    var doc_buf: [512]u8 = undefined;
    const addrs = [_]proto.LeaseAddr{.{ .ip = "192.168.0.11", .port = proto.default_port }};
    const doc = try proto.formatLease(&doc_buf, id, 1710000060, &addrs);
    const parsed = try proto.parseLease(std.testing.allocator, doc);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(id, parsed.value.id);
}

test "fuzz cluster id gate keeps ids name-safe log-safe and json round-trippable" {
    try std.testing.fuzz({}, fuzzIdGateOne, .{ .corpus = &fuzz_id_corpus });
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
    // own lease: kept (self-id skip). Left at write mtime so it is the
    // origin-clock sample the cutoff uses; aged after the first sweep.
    var me_buf: [192]u8 = undefined;
    const me_fp = try std.fmt.bufPrint(&me_buf, "{s}/me.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, me_fp), lease_json));

    // Age dead.json and crashed.json.tmp beyond the sweep cutoff. me.json
    // stays at its write mtime: production publishes then sweeps, so the
    // own-lease stamp is the origin-filesystem clock the cutoff uses. One
    // edge instant drives the mtime stamps and the sweep call, so every
    // aged file sits exactly sweep_min_age_secs outside that clock no
    // matter how long the test takes between those steps.
    const sweep_now = sys.nowSec(std.testing.io);
    const past = [2]std.os.linux.timespec{
        .{ .sec = sweep_now - 2 * Catalog.sweep_min_age_secs, .nsec = 0 },
        .{ .sec = sweep_now - 2 * Catalog.sweep_min_age_secs, .nsec = 0 },
    };
    for ([_][]const u8{ old_fp, tmp_fp }) |fp| {
        var zb: [192]u8 = undefined;
        const rc = std.os.linux.utimensat(std.posix.AT.FDCWD, try sys.toZ(&zb, fp), &past, 0);
        try std.testing.expectEqual(@as(usize, 0), rc);
    }

    const addrs = [_]proto.LeaseAddr{};
    var cat = Catalog.init(gpa, std.testing.io, origin_d, "me", &addrs, &.{}, &.{});
    defer cat.deinit();
    cat.sweepLeases(sweep_now);

    var stbuf: c.struct_stat = undefined;
    try std.testing.expect(sys.statPath(try sys.toZ(&zbuf, old_fp), &stbuf) != 0);
    try std.testing.expect(sys.statPath(try sys.toZ(&zbuf, tmp_fp), &stbuf) != 0);
    try std.testing.expect(sys.statPath(try sys.toZ(&zbuf, new_fp), &stbuf) == 0);
    try std.testing.expect(sys.statPath(try sys.toZ(&zbuf, me_fp), &stbuf) == 0);

    // Own lease with stale mtime: still kept (publish failures must stay
    // visible). Cutoff then follows that stale stamp, so a second pass
    // must not start deleting survivors.
    const own_past = [2]std.os.linux.timespec{
        .{ .sec = sweep_now - 2 * Catalog.sweep_min_age_secs, .nsec = 0 },
        .{ .sec = sweep_now - 2 * Catalog.sweep_min_age_secs, .nsec = 0 },
    };
    {
        var zb: [192]u8 = undefined;
        const rc = std.os.linux.utimensat(std.posix.AT.FDCWD, try sys.toZ(&zb, me_fp), &own_past, 0);
        try std.testing.expectEqual(@as(usize, 0), rc);
    }

    // Re-execution is the sweep's normal shape: every node runs one per
    // discovery tick, so the same stale directory is swept repeatedly and
    // concurrently. A second pass over the already-swept tree must converge
    // on exactly the first pass's outcome -- no further removals, survivors
    // untouched -- instead of erroring or resurrecting anything.
    cat.sweepLeases(sweep_now);
    try std.testing.expect(sys.statPath(try sys.toZ(&zbuf, old_fp), &stbuf) != 0);
    try std.testing.expect(sys.statPath(try sys.toZ(&zbuf, tmp_fp), &stbuf) != 0);
    try std.testing.expect(sys.statPath(try sys.toZ(&zbuf, new_fp), &stbuf) == 0);
    try std.testing.expect(sys.statPath(try sys.toZ(&zbuf, me_fp), &stbuf) == 0);
}

test "sweepLeases ages origin mtimes against our own lease, not CLOCK_REALTIME" {
    // NAS five-plus minutes behind the spark: every live mtime looks older
    // than sweep_min_age_secs on the node's wall clock. Comparing to
    // now_sec would unlink alive.json; comparing to me.json's mtime keeps
    // the live peer and still sweeps the one that actually went idle.
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-disc-sweep-skew");
    defer sys.deleteTree(std.testing.io, origin_d);
    var cbuf: [160]u8 = undefined;
    const cluster_d = try std.fmt.bufPrint(&cbuf, "{s}/.cluster", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(cluster_d, 0o755));

    const lease_json = "{\"id\":\"x\",\"until\":1,\"addrs\":[]}";
    var zbuf: [192]u8 = undefined;
    var me_buf: [192]u8 = undefined;
    const me_fp = try std.fmt.bufPrint(&me_buf, "{s}/me.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, me_fp), lease_json));
    var new_buf: [192]u8 = undefined;
    const new_fp = try std.fmt.bufPrint(&new_buf, "{s}/alive.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, new_fp), lease_json));
    var old_buf: [192]u8 = undefined;
    const old_fp = try std.fmt.bufPrint(&old_buf, "{s}/dead.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, old_fp), lease_json));

    const sweep_now = sys.nowSec(std.testing.io);
    const nas_lag: i64 = Catalog.sweep_min_age_secs + 100;
    const own_ts = [2]std.os.linux.timespec{
        .{ .sec = sweep_now - nas_lag, .nsec = 0 },
        .{ .sec = sweep_now - nas_lag, .nsec = 0 },
    };
    const live_ts = [2]std.os.linux.timespec{
        .{ .sec = sweep_now - nas_lag + 10, .nsec = 0 },
        .{ .sec = sweep_now - nas_lag + 10, .nsec = 0 },
    };
    const dead_ts = [2]std.os.linux.timespec{
        .{ .sec = sweep_now - nas_lag - 2 * Catalog.sweep_min_age_secs, .nsec = 0 },
        .{ .sec = sweep_now - nas_lag - 2 * Catalog.sweep_min_age_secs, .nsec = 0 },
    };
    {
        var zb: [192]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 0), std.os.linux.utimensat(std.posix.AT.FDCWD, try sys.toZ(&zb, me_fp), &own_ts, 0));
        try std.testing.expectEqual(@as(usize, 0), std.os.linux.utimensat(std.posix.AT.FDCWD, try sys.toZ(&zb, new_fp), &live_ts, 0));
        try std.testing.expectEqual(@as(usize, 0), std.os.linux.utimensat(std.posix.AT.FDCWD, try sys.toZ(&zb, old_fp), &dead_ts, 0));
    }

    const addrs = [_]proto.LeaseAddr{};
    var cat = Catalog.init(gpa, std.testing.io, origin_d, "me", &addrs, &.{}, &.{});
    defer cat.deinit();
    cat.sweepLeases(sweep_now);

    var stbuf: c.struct_stat = undefined;
    try std.testing.expect(sys.statPath(try sys.toZ(&zbuf, old_fp), &stbuf) != 0);
    try std.testing.expect(sys.statPath(try sys.toZ(&zbuf, new_fp), &stbuf) == 0);
    try std.testing.expect(sys.statPath(try sys.toZ(&zbuf, me_fp), &stbuf) == 0);
}

test "hostname copies into buf" {
    var buf: [256]u8 = undefined;
    @memset(&buf, 0xaa);
    const name = hostname(&buf);
    try std.testing.expect(name.len > 0);
    try std.testing.expect(std.mem.findScalar(u8, name, '.') == null);
    if (name.ptr == buf[0..].ptr) {
        // Copied into the caller buffer: the returned slice is that prefix,
        // not a view of gethostname's stack storage.
        try std.testing.expect(name.len < buf.len);
        try std.testing.expectEqualSlices(u8, name, buf[0..name.len]);
    } else {
        // Documented fallback when gethostname fails or the short name is
        // unusable as a cluster id. A static string, never an alias of buf.
        try std.testing.expectEqualStrings("node", name);
    }
}

test "shouldAdvertise skips loopback and link-local" {
    try std.testing.expect(shouldAdvertise("10.0.1.1"));
    try std.testing.expect(shouldAdvertise("192.168.0.211"));
    try std.testing.expect(!shouldAdvertise("127.0.0.1"));
    try std.testing.expect(!shouldAdvertise("127.0.0.2"));
    try std.testing.expect(!shouldAdvertise("169.254.1.1"));
    try std.testing.expect(!shouldAdvertise("169.254.0.1"));
    // parseV4 miss: a hostname or truncated quad must not be published.
    try std.testing.expect(!shouldAdvertise("spark1"));
    try std.testing.expect(!shouldAdvertise("10.0.1"));
    try std.testing.expect(!shouldAdvertise(""));
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
    // leading zeros are refused exactly like the dialer's inet_pton, so an
    // admitted quad is always dialable as written; a lone 0 stays valid
    try std.testing.expect(!parseV4("0255.0.0.1", &out));
    try std.testing.expect(!parseV4("010.1.1.1", &out));
    try std.testing.expect(!parseV4("1.1.1.01", &out));
    try std.testing.expect(parseV4("0.0.0.0", &out));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, &out);
    try std.testing.expect(parseV4("10.0.0.100", &out));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 0, 0, 100 }, &out);
}

// Lease ip fields are untrusted twice over: published by other nodes' JSON
// off shared NFS storage, then consumed by dialers that gate through libc
// inet_pton (peer.zig). parseV4 sits between the two, so its accept set must
// equal inet_pton's exactly -- a spelling one side refuses and the other
// admits either strands a live-looking path on every fetch or drops an
// address the peer would have answered. Unit tests pin known spellings; this
// harness diffs the pair across the whole input space so any future drift in
// either parser surfaces as a fuzz failure instead of dead cluster routes.

const seed_quad_ok = fuzzcorpus.entry("192.168.100.10");
const seed_quad_zero = fuzzcorpus.entry("0.0.0.0");
const seed_quad_max = fuzzcorpus.entry("255.255.255.255");
const seed_quad_leading_zero = fuzzcorpus.entry("0255.0.0.1");
const seed_quad_leading_zero_last = fuzzcorpus.entry("1.2.3.040");
const seed_quad_overflow_octet = fuzzcorpus.entry("256.1.1.1");
const seed_quad_long_run = fuzzcorpus.entry("99999999999999999999.1.1.1");
const seed_quad_empty_part = fuzzcorpus.entry("1..2.3");
const seed_quad_trailing_dot = fuzzcorpus.entry("1.2.3.");
const seed_quad_five_parts = fuzzcorpus.entry("10.0.0.1.2");
const seed_quad_hostname = fuzzcorpus.entry("spark9.example");
const seed_quad_log_forge = fuzzcorpus.entry("10.0.0.1\r2026-08-26 ERROR forged");
const seed_quad_trailing_space = fuzzcorpus.entry("10.0.0.1 ");
const seed_quad_empty = fuzzcorpus.entry("");

const fuzz_quad_corpus = [_][]const u8{
    &seed_quad_ok,
    &seed_quad_zero,
    &seed_quad_max,
    &seed_quad_leading_zero,
    &seed_quad_leading_zero_last,
    &seed_quad_overflow_octet,
    &seed_quad_long_run,
    &seed_quad_empty_part,
    &seed_quad_trailing_dot,
    &seed_quad_five_parts,
    &seed_quad_hostname,
    &seed_quad_log_forge,
    &seed_quad_trailing_space,
    &seed_quad_empty,
};

/// Asserts the cross-implementation contract: parseV4 accepts exactly what
/// the dialer's inet_pton accepts, hands back the same four octets, and
/// every accepted address survives a canonical inet_ntop reparse -- so the
/// ingestion gate and the dial gate can never disagree about a lease ip.
fn fuzzParseV4One(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [48]u8 = undefined;
    const s = buf[0..smith.slice(&buf)];
    // inet_pton reads a C string and stops at the first NUL, so inputs
    // carrying one have no reference answer to differ against.
    if (std.mem.indexOfScalar(u8, s, 0) != null) return;

    var quad: [4]u8 = undefined;
    const ours = parseV4(s, &quad);

    var zbuf: [buf.len + 1]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{s}) catch unreachable;
    var ref: c.struct_in_addr = undefined;
    const rc = c.inet_pton(c.AF_INET, z.ptr, &ref);
    try std.testing.expectEqual(ours, rc == 1);

    if (!ours) return;
    // Same bytes the dialer binds: struct in_addr stores the octets in
    // network order.
    try std.testing.expectEqualSlices(u8, &quad, std.mem.asBytes(&ref));

    // The canonical spelling reparses to the identical address on both
    // sides, so publishers echoing inet_ntop output stay reachable.
    var nbuf: [c.INET_ADDRSTRLEN]u8 = undefined;
    const canon = c.inet_ntop(c.AF_INET, &ref, &nbuf, nbuf.len) orelse return error.NtopFailed;
    var back: [4]u8 = undefined;
    try std.testing.expect(parseV4(std.mem.span(canon), &back));
    try std.testing.expectEqualSlices(u8, &quad, &back);
}

test "fuzz lease ip parsing matches the dialer's inet_pton exactly" {
    try std.testing.fuzz({}, fuzzParseV4One, .{ .corpus = &fuzz_quad_corpus });
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
    // Nobody holds the piece: null is the caller's signal to fall through to
    // the next tier, so both an empty candidate list and an all-!have one
    // must answer it.
    try std.testing.expect(pickBest(&.{}) == null);
    try std.testing.expect(pickBest(&.{cands[0]}) == null);
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
    try std.testing.expectEqual(@as(u32, 0), hopsBetween("192.168.100.1", "192.168.100.1"));
    try std.testing.expectEqual(@as(u32, 1), hopsBetween("192.168.100.1", "192.168.0.11"));
    // Unparseable addresses are treated as routed, never as a same-subnet
    // shortcut that would make a garbage lease look like L2.
    try std.testing.expectEqual(@as(u32, 1), hopsBetween("not-an-ip", "192.168.100.1"));
    try std.testing.expectEqual(@as(u32, 1), hopsBetween("192.168.100.1", "256.0.0.1"));
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
    const pub_now = sys.nowSec(std.testing.io);
    cat.publish(pub_now);

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
    // until is exactly the caller's instant plus the TTL: publish takes the
    // clock sample in, so the boundary is pinned with no drift allowance.
    try std.testing.expectEqual(pub_now + Catalog.lease_ttl_secs, parsed.value.until);
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
    cat2.publish(pub_now);
    const blob2 = try sys.readFileAlloc(gpa, try sys.toZ(&zbuf, lease_fp), 4096);
    defer gpa.free(blob2);
    const parsed2 = try proto.parseLease(gpa, blob2);
    defer parsed2.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed2.value.addrs.len);
    try std.testing.expectEqualStrings("10.9.9.9", parsed2.value.addrs[0].ip);

    // Regression: publish no longer runs an unconditional mkdirAll before
    // every write (one failed mkdir per component on the origin -- NFS round
    // trips -- from every node on every tick). The lazy retry it replaced must
    // still rebuild the control directory when it is genuinely gone.
    var cbuf2: [160]u8 = undefined;
    const cluster_d = try std.fmt.bufPrint(&cbuf2, "{s}/.cluster", .{origin_d});
    sys.deleteTree(std.testing.io, cluster_d);
    cat2.publish(pub_now);
    const blob3 = try sys.readFileAlloc(gpa, try sys.toZ(&zbuf, lease_fp), 4096);
    defer gpa.free(blob3);
    const parsed3 = try proto.parseLease(gpa, blob3);
    defer parsed3.deinit();
    try std.testing.expectEqualStrings("me", parsed3.value.id);
}

test "publish unlinks the staging file when rename fails" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-disc-pub-tmp");
    defer sys.deleteTree(std.testing.io, origin_d);

    var cbuf: [160]u8 = undefined;
    const cluster_d = try std.fmt.bufPrint(&cbuf, "{s}/.cluster", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(cluster_d, 0o755));
    // Destination is a directory: rename(me.json.tmp, me.json) fails and
    // must not leave the staging file (a retry every tick would refresh
    // mtime so sweepLeases never aged it out).
    var lbuf: [192]u8 = undefined;
    const lease_fp = try std.fmt.bufPrint(&lbuf, "{s}/me.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(lease_fp, 0o755));

    const addrs = [_]proto.LeaseAddr{.{ .ip = "10.0.0.1", .port = 18080, .mbps = 0 }};
    var cat = Catalog.init(gpa, std.testing.io, origin_d, "me", &addrs, &.{}, &.{});
    defer cat.deinit();
    cat.publish(sys.nowSec(std.testing.io));

    var zbuf: [192]u8 = undefined;
    var stbuf: c.struct_stat = undefined;
    var tbuf: [192]u8 = undefined;
    const tmp_fp = try std.fmt.bufPrint(&tbuf, "{s}/me.json.tmp", .{cluster_d});
    try std.testing.expect(sys.statPath(try sys.toZ(&zbuf, tmp_fp), &stbuf) != 0);
}

test "walkLeases visits parsed leases and skips hidden corrupt and missing" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-walk-leases");
    defer sys.deleteTree(std.testing.io, origin_d);

    // No .cluster yet: missing_dir, not a walk of zero files.
    {
        const Empty = struct {
            pub fn visit(_: *@This(), _: []const u8, _: std.json.Parsed(proto.Lease)) void {
                unreachable;
            }
        };
        var empty: Empty = .{};
        try std.testing.expectEqual(LeaseWalk.missing_dir, walkLeases(gpa, origin_d, &empty));
    }

    var cbuf: [160]u8 = undefined;
    const cluster_d = try std.fmt.bufPrint(&cbuf, "{s}/.cluster", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(cluster_d, 0o755));

    var zbuf: [192]u8 = undefined;
    var pbuf: [192]u8 = undefined;
    const live_fp = try std.fmt.bufPrint(&pbuf, "{s}/spark9.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, live_fp), "{\"id\":\"spark9\",\"until\":4102444800,\"addrs\":[]}"));
    // Leading-dot names cannot be a validId lease; Catalog.refresh already
    // skipped them and `modelfs peers` now shares that skip.
    const hidden_fp = try std.fmt.bufPrint(&pbuf, "{s}/.hidden.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, hidden_fp), "{\"id\":\"hidden\",\"until\":4102444800,\"addrs\":[]}"));
    const corrupt_fp = try std.fmt.bufPrint(&pbuf, "{s}/corrupt.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, corrupt_fp), "{oops"));
    const not_json_fp = try std.fmt.bufPrint(&pbuf, "{s}/notes.txt", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, not_json_fp), "x"));

    const Acc = struct {
        gpa: std.mem.Allocator,
        names: std.ArrayList([]u8) = .empty,
        pub fn visit(acc: *@This(), name: []const u8, parsed: std.json.Parsed(proto.Lease)) void {
            _ = parsed;
            const owned = acc.gpa.dupe(u8, name) catch return;
            acc.names.append(acc.gpa, owned) catch acc.gpa.free(owned);
        }
        fn deinit(acc: *@This()) void {
            for (acc.names.items) |n| acc.gpa.free(n);
            acc.names.deinit(acc.gpa);
        }
    };
    var acc: Acc = .{ .gpa = gpa };
    defer acc.deinit();

    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;
    try std.testing.expectEqual(LeaseWalk.ok, walkLeases(gpa, origin_d, &acc));
    try std.testing.expectEqual(@as(usize, 1), acc.names.items.len);
    try std.testing.expectEqualStrings("spark9.json", acc.names.items[0]);
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
    cat.refresh(sys.nowSec(std.testing.io));

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

test "refresh drops undialable lease addresses" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-disc-addr");
    defer sys.deleteTree(std.testing.io, origin_d);
    var cbuf: [160]u8 = undefined;
    const cluster_d = try std.fmt.bufPrint(&cbuf, "{s}/.cluster", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(cluster_d, 0o755));

    // A forged lease off shared storage: its first address carries CR plus
    // a forged journal line, its second a hostname no dialer can resolve,
    // its third a leading-zero quad parseV4 must refuse exactly like the
    // dialer's inet_pton (admitting it would list a path no fetch can
    // ever use), its fourth a port-0 address the CLI already refuses as
    // undialable. Only the trailing dotted quad with a real port survives.
    var zbuf: [192]u8 = undefined;
    var pbuf: [192]u8 = undefined;
    const fp = try std.fmt.bufPrint(&pbuf, "{s}/forged.json", .{cluster_d});
    const forged = "{\"id\":\"forged\",\"until\":4102444800,\"addrs\":[" ++
        "{\"ip\":\"10.0.0.1\\r2026-08-26 ERROR forged\",\"port\":18080,\"mbps\":0}," ++
        "{\"ip\":\"spark9.example\",\"port\":18080,\"mbps\":0}," ++
        "{\"ip\":\"010.0.0.7\",\"port\":18080,\"mbps\":0}," ++
        "{\"ip\":\"10.0.0.8\",\"port\":0,\"mbps\":0}," ++
        "{\"ip\":\"10.0.0.9\",\"port\":18080,\"mbps\":0}]}";
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), forged));

    const addrs = [_]proto.LeaseAddr{};
    var cat = Catalog.init(gpa, std.testing.io, origin_d, "me", &addrs, &.{}, &.{});
    defer cat.deinit();
    cat.refresh(sys.nowSec(std.testing.io));

    const snap = try cat.snapshot(gpa);
    defer Catalog.freeSnapshot(gpa, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqualStrings("10.0.0.9", snap[0].ip);
}

test "refresh keeps the previous peer list while .cluster is unreadable" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-disc-keep");
    defer sys.deleteTree(std.testing.io, origin_d);
    var cbuf: [160]u8 = undefined;
    const cluster_d = try std.fmt.bufPrint(&cbuf, "{s}/.cluster", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(cluster_d, 0o755));

    var zbuf: [192]u8 = undefined;
    var pbuf: [192]u8 = undefined;
    const fp = try std.fmt.bufPrint(&pbuf, "{s}/spark9.json", .{cluster_d});
    const live = "{\"id\":\"spark9\",\"until\":4102444800,\"addrs\":[{\"ip\":\"10.0.0.1\",\"port\":18080,\"mbps\":0}]}";
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), live));

    const addrs = [_]proto.LeaseAddr{};
    var cat = Catalog.init(gpa, std.testing.io, origin_d, "me", &addrs, &.{}, &.{});
    defer cat.deinit();
    cat.refresh(sys.nowSec(std.testing.io));

    // A transient origin outage (NFS unmounted, control dir swept) makes
    // opendir fail. Regression shape: rebuilding from an empty walk here
    // would silently go peerless and drop every fill to the origin tier for
    // a full tick; the documented degrade keeps the last known membership.
    {
        const prev_log_level = std.testing.log_level;
        std.testing.log_level = .err;
        defer std.testing.log_level = prev_log_level;
        sys.deleteTree(std.testing.io, cluster_d);
        cat.refresh(sys.nowSec(std.testing.io));
    }

    const snap = try cat.snapshot(gpa);
    defer Catalog.freeSnapshot(gpa, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqualStrings("spark9", snap[0].peer_id);
    try std.testing.expectEqualStrings("10.0.0.1", snap[0].ip);
}

test "refresh skips unreadable and corrupt leases without dropping healthy peers" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-disc-corrupt");
    defer sys.deleteTree(std.testing.io, origin_d);
    var cbuf: [160]u8 = undefined;
    const cluster_d = try std.fmt.bufPrint(&cbuf, "{s}/.cluster", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(cluster_d, 0o755));

    var zbuf: [192]u8 = undefined;
    var pbuf: [192]u8 = undefined;
    // Truncated JSON off shared storage (crash mid-rename is impossible with
    // staging, but a co-tenant's torn write is not): skipped, not fatal.
    const bad_fp = try std.fmt.bufPrint(&pbuf, "{s}/corrupt.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, bad_fp), "{oops"));
    // A directory parked at a lease name makes every read of it fail with
    // EISDIR (works even as root): the non-ENOENT warn branch, still a skip.
    const dir_fp = try std.fmt.bufPrint(&pbuf, "{s}/dir.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(dir_fp, 0o755));
    // A name that cannot even be opened (self-referential symlink: ELOOP
    // even under root) skips through the cannot-open branch -- named like
    // the read failures, silent only for the ENOENT expiry race.
    var sbuf: [192]u8 = undefined;
    const poison_fp = try std.fmt.bufPrint(&pbuf, "{s}/poison.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), c.symlink(try sys.toZ(&zbuf, poison_fp), try sys.toZ(&sbuf, poison_fp)));
    // One healthy lease among them: it must survive the walk.
    const fp = try std.fmt.bufPrint(&pbuf, "{s}/spark9.json", .{cluster_d});
    const live = "{\"id\":\"spark9\",\"until\":4102444800,\"addrs\":[{\"ip\":\"10.0.0.1\",\"port\":18080,\"mbps\":0}]}";
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), live));

    const addrs = [_]proto.LeaseAddr{};
    var cat = Catalog.init(gpa, std.testing.io, origin_d, "me", &addrs, &.{}, &.{});
    defer cat.deinit();

    // Expected-path warns for both broken entries; restored on scope exit so
    // unexpected warnings from later tests still surface.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;
    cat.refresh(sys.nowSec(std.testing.io));

    const snap = try cat.snapshot(gpa);
    defer Catalog.freeSnapshot(gpa, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqualStrings("spark9", snap[0].peer_id);
}

test "refresh skips a planted lease symlink instead of ingesting its target" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-disc-leasesym");
    defer sys.deleteTree(std.testing.io, origin_d);
    var cbuf: [160]u8 = undefined;
    const cluster_d = try std.fmt.bufPrint(&cbuf, "{s}/.cluster", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(cluster_d, 0o755));

    var zbuf: [192]u8 = undefined;
    var pbuf: [192]u8 = undefined;
    var sbuf: [192]u8 = undefined;
    // A valid lease sitting beside the planted name: following would ingest
    // it as a peer. Basename target so a following open would resolve;
    // O_NOFOLLOW must skip the link. Non-.json so refresh does not also
    // pick the target up as its own lease file.
    const live = "{\"id\":\"evil\",\"until\":4102444800,\"addrs\":[{\"ip\":\"10.9.9.9\",\"port\":18080,\"mbps\":0}]}";
    const outside_fp = try std.fmt.bufPrint(&pbuf, "{s}/outside.lease", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, outside_fp), live));
    const planted_fp = try std.fmt.bufPrint(&pbuf, "{s}/evil.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), c.symlink("outside.lease", try sys.toZ(&sbuf, planted_fp)));

    const healthy_fp = try std.fmt.bufPrint(&pbuf, "{s}/spark9.json", .{cluster_d});
    const healthy = "{\"id\":\"spark9\",\"until\":4102444800,\"addrs\":[{\"ip\":\"10.0.0.1\",\"port\":18080,\"mbps\":0}]}";
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, healthy_fp), healthy));

    const addrs = [_]proto.LeaseAddr{};
    var cat = Catalog.init(gpa, std.testing.io, origin_d, "me", &addrs, &.{}, &.{});
    defer cat.deinit();

    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;
    cat.refresh(sys.nowSec(std.testing.io));

    const snap = try cat.snapshot(gpa);
    defer Catalog.freeSnapshot(gpa, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqualStrings("spark9", snap[0].peer_id);
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
    cat.refresh(sys.nowSec(std.testing.io));

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
    cat.refresh(sys.nowSec(std.testing.io));

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
    cat.refresh(sys.nowSec(std.testing.io));
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
    cat.refresh(sys.nowSec(std.testing.io));
    try std.testing.expectEqual(@as(usize, 1), cat.paths.items.len);
    try std.testing.expectEqual(learned, cat.paths.items[0].ewma_bps);
    try std.testing.expectEqual(@as(u32, 1), cat.paths.items[0].inflight.load(.monotonic));

    // The carried inflight drains exactly once.
    try std.testing.expectEqual(@as(u32, 0), cat.inflight("10.0.0.9", 19099, -1));
}
