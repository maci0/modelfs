//! Local piece cache: the origin-relative path gate (`relOk`), per-file
//! bitfields with persisted sidecars, hydration claims, pinning, hole-punch
//! culling (in-memory and disk-only victims), and the cache/origin artifact
//! path helpers CLI verify/dupes use (`cacheMetaPath`, `sidecarPieceSize`,
//! `manifestPath`).
const std = @import("std");
const piece = @import("piece.zig");
const proto = @import("proto.zig");
const cull = @import("cull.zig");
const sys = @import("sys.zig");
const fuzzcorpus = @import("fuzzcorpus.zig");
const c = sys.c;

/// Daemon liveness artifact at the cache root; the discovery tick writes it
/// and `modelfs status` reads it. Not a piece sidecar (`data/`, `meta/`, `pin/`).
pub const status_file = "status.json";

/// True when rel is a safe origin-relative path at a trust boundary: not
/// empty, not absolute, no "." or ".." component, no empty component
/// (a doubled or trailing slash), no control character. Empty components
/// are refused because the kernel collapses `//` during path resolution
/// while cache keys are byte-exact: `"a//b"` and `"a/b"` are distinct keys
/// that name the same data/meta/pin artifacts, and a fill or cull through
/// one would alias the other's marks onto shared bytes.
/// Applied to every externally supplied path before it joins a root (FUSE
/// handlers and FUSE readdir components, peer HTTP, CLI pin); without it a
/// peer request can escape the origin/cache trees or forge multi-line
/// entries in operator logs via \n in a path.
/// `.cluster` is a sibling policy (`discover.relIsCluster`), not part of
/// this gate: a leading-dot component is a legal model name.
/// Control characters are proto.containsControl's set (C0, DEL, UTF-8 C1,
/// and UTF-8 Default_Ignorable_Code_Point including line separators, bidi
/// and zero-width format controls, variation selectors, BOM, soft hyphen,
/// CGJ, Hangul fillers, Mongolian FVS4, shorthand format controls, and tags),
/// the same discover.printable applies
/// before echoing a lease name. Non-control text above that set (NFC/NFD
/// spellings, astral emoji without a selector, names that are not valid
/// UTF-8 at all) passes byte-exact; identity is byte equality all the way
/// down.
pub fn relOk(rel: []const u8) bool {
    if (rel.len == 0 or rel[0] == '/') return false;
    if (proto.containsControl(rel)) return false;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return false;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

/// Process-lifetime operation counters, published in status.json every
/// discovery tick (plus one summary log line per tick while anything moved).
/// This is the daemon's metrics surface: per-event logs would flood the
/// journal at piece granularity, so steady-state work lands here instead and
/// only failures stay in the log. Atomics because FUSE handlers, peer HTTP
/// handlers, and background workers all bump them concurrently.
pub const Stats = struct {
    /// FUSE read outcomes. reads_err counts service-side failures only:
    /// origin stat failure, cache-entry OOM, hydration failure, or a failed
    /// cache read. Caller misuse (traversal paths, bad offsets, EISDIR) stays
    /// uncounted so the error rate tracks service health, not client bugs.
    reads_ok: std.atomic.Value(u64) = .init(0),
    reads_err: std.atomic.Value(u64) = .init(0),
    /// Fully-cached FUSE reads: ensureRange was skipped and the cache
    /// served the range. Hit rate is reads_warm / reads_ok; a node whose
    /// cache is not earning its keep shows fills climbing and this flat.
    reads_warm: std.atomic.Value(u64) = .init(0),
    bytes_read: std.atomic.Value(u64) = .init(0),
    /// Cumulative wall time inside mf_read, every op included (warm path
    /// pays two clock reads). Divided by attempted reads it is the average
    /// read latency the tick line publishes; nothing else in this daemon
    /// answers "reads got slow".
    read_nanos: std.atomic.Value(u64) = .init(0),
    writes_ok: std.atomic.Value(u64) = .init(0),
    writes_err: std.atomic.Value(u64) = .init(0),
    bytes_written: std.atomic.Value(u64) = .init(0),
    /// Cumulative wall time inside mf_write. wr_us on the tick line is the
    /// only signal that origin writes stalled (NFS), the write-side twin of
    /// read_nanos.
    write_nanos: std.atomic.Value(u64) = .init(0),
    /// Metadata operation latencies: getattr, open, statfs (ns).
    /// Every FUSE request traverses getattr; without these the tick line
    /// only answers "data reads got slow" while metadata storms stay invisible.
    getattr_nanos: std.atomic.Value(u64) = .init(0),
    open_nanos: std.atomic.Value(u64) = .init(0),
    statfs_nanos: std.atomic.Value(u64) = .init(0),
    /// Piece hydration outcomes by source: peer fetch vs origin pread.
    fills_peer: std.atomic.Value(u64) = .init(0),
    fills_origin: std.atomic.Value(u64) = .init(0),
    bytes_from_peer: std.atomic.Value(u64) = .init(0),
    bytes_from_origin: std.atomic.Value(u64) = .init(0),
    /// Content-Length of accepted /have 200, /data 206, and /stage 200 replies.
    /// Counted when the status goes on the wire, not after the body drain, so a
    /// client that has already read the reply cannot race the bump. Truncated
    /// sends keep the count and a warn. A serving node is otherwise
    /// indistinguishable from an idle one: http_5xx only moves when replies fail.
    bytes_to_peer: std.atomic.Value(u64) = .init(0),
    /// Cumulative wall time per piece fill by tier, claim through cache
    /// write. This is the stall a FUSE reader or a fetching peer eats on a
    /// miss; peer-serving origin hydrations count here too.
    fill_peer_nanos: std.atomic.Value(u64) = .init(0),
    fill_origin_nanos: std.atomic.Value(u64) = .init(0),
    /// Fill failures by tier: peer fetch failed (fell through to origin or
    /// EIO), origin read failed, cache write refused hydrated bytes, and
    /// peer bytes rejected by digest verification (fill_err_verify: the
    /// fetched bytes did not match the trusted hash, so they were discarded
    /// and the piece refilled from origin).
    fill_err_peer: std.atomic.Value(u64) = .init(0),
    fill_err_origin: std.atomic.Value(u64) = .init(0),
    fill_err_cache: std.atomic.Value(u64) = .init(0),
    fill_err_verify: std.atomic.Value(u64) = .init(0),
    /// Peer /data and /stage replies dropped because the cached bytes being
    /// served failed at-rest verification against their trusted digest (hole
    /// zeros, bit rot, local tamper). The fetching peer falls through to
    /// the next path or the origin, so the fleet keeps serving; this counter
    /// is how a node whose cache is silently corrupt is visible in status.json.
    serve_verify_fail: std.atomic.Value(u64) = .init(0),
    /// /have probes that failed for reasons other than a healthy 404 miss
    /// (dead peer, auth mismatch, malformed reply). A fleet silently
    /// degraded to NFS-only shows here while reads keep succeeding.
    probe_err: std.atomic.Value(u64) = .init(0),
    /// Discovery-tick lease publish write/rename failures. An idle node
    /// with a dead origin never touches getattr/read, so without this the
    /// outage is only origin_down in status.json and the tick line stays
    /// silent. One increment per failed publish, not per FUSE op.
    lease_err: std.atomic.Value(u64) = .init(0),
    /// getattr/open/readdir origin-infrastructure failures (EIO/ESTALE/
    /// ETIMEDOUT). md_us is time, not outcomes: an NFS outage during `ls`
    /// would otherwise look like a slow-but-healthy metadata interval.
    meta_err: std.atomic.Value(u64) = .init(0),
    pieces_culled: std.atomic.Value(u64) = .init(0),
    /// Peer HTTP server: accepted /have 200, /data 206, and /stage 200
    /// replies, rejected bearer tokens, and 5xx replies served. http_ok is
    /// the missing half of the error rate: without it a node serving pieces
    /// looks idle. 501 (no staging backend) is a capability answer, not a
    /// 5xx for this gauge.
    http_ok: std.atomic.Value(u64) = .init(0),
    http_unauthorized: std.atomic.Value(u64) = .init(0),
    http_5xx: std.atomic.Value(u64) = .init(0),
    /// Connections whose head never became a routable request: scanners
    /// that connect-and-drop, dribbled heads past the deadline, oversized
    /// heads, request lines without a target. Counted rather than logged;
    /// the accept cap bounds the rate anyway.
    http_malformed: std.atomic.Value(u64) = .init(0),
    /// Connections closed unaccepted because every inflight slot was taken:
    /// work this node actively refused while it looked up from the outside.
    /// Without the count a saturated server is indistinguishable from a
    /// quiet one -- fetchers time out and nothing on this node says why.
    http_dropped: std.atomic.Value(u64) = .init(0),
    /// Unsupported HTTP methods (non-GET). Deduplicated at warn level; every
    /// occurrence still counts here so a probing campaign is not silent.
    http_405: std.atomic.Value(u64) = .init(0),
    /// Cumulative wall time inside /have, /data, and /stage handlers.
    /// http_us on the tick line is the serving-side twin of rd_us: without it
    /// a node whose peer replies are slow looks healthy (http_ok climbing,
    /// inflight low between requests). 401, 405, malformed heads, and /ping
    /// stay untimed: /ping is liveness, and timing it would make a health
    /// check fire an otherwise-idle tick line of zeros.
    http_nanos: std.atomic.Value(u64) = .init(0),

    /// Consistent copy of every counter for diffing between discovery ticks
    /// and for status.json formatting. Snap's field list is the single
    /// source of truth for what gets published: snap() below loads these
    /// fields generically and statusJson emits them generically, so a new
    /// counter rides every output by adding its three declarations here --
    /// never by editing a format string in another module.
    pub const Snap = struct {
        reads_ok: u64 = 0,
        reads_err: u64 = 0,
        reads_warm: u64 = 0,
        bytes_read: u64 = 0,
        read_nanos: u64 = 0,
        writes_ok: u64 = 0,
        writes_err: u64 = 0,
        bytes_written: u64 = 0,
        write_nanos: u64 = 0,
        getattr_nanos: u64 = 0,
        open_nanos: u64 = 0,
        statfs_nanos: u64 = 0,
        fills_peer: u64 = 0,
        fills_origin: u64 = 0,
        bytes_from_peer: u64 = 0,
        bytes_from_origin: u64 = 0,
        bytes_to_peer: u64 = 0,
        fill_peer_nanos: u64 = 0,
        fill_origin_nanos: u64 = 0,
        fill_err_peer: u64 = 0,
        fill_err_origin: u64 = 0,
        fill_err_cache: u64 = 0,
        fill_err_verify: u64 = 0,
        serve_verify_fail: u64 = 0,
        probe_err: u64 = 0,
        lease_err: u64 = 0,
        meta_err: u64 = 0,
        pieces_culled: u64 = 0,
        http_ok: u64 = 0,
        http_unauthorized: u64 = 0,
        http_5xx: u64 = 0,
        http_malformed: u64 = 0,
        http_dropped: u64 = 0,
        http_405: u64 = 0,
        http_nanos: u64 = 0,
    };

    // Every Stats counter must have a Snap counterpart, or it compiles fine
    // while silently dropping out of every published output (status.json,
    // the tick line); make the omission a compile error instead.
    comptime {
        for (@typeInfo(Stats).@"struct".fields) |f| {
            if (!@hasField(Snap, f.name)) @compileError("Stats." ++ f.name ++ " has no Snap counterpart; the counter would never be published");
        }
    }

    pub fn snap(self: *const Stats) Snap {
        var out: Snap = .{};
        inline for (@typeInfo(Snap).@"struct".fields) |f| {
            @field(out, f.name) = @field(self.*, f.name).load(.monotonic);
        }
        return out;
    }
};

/// ENOENT is the expected already-gone case; any other unlink failure would
/// leave stale cache artifacts that a same-size recreate can resurrect.
/// Callers span forget, distrust, and the reaper's purges, so the line names
/// the artifact rather than attributing itself to one of them.
fn unlinkOrWarn(path_z: [*:0]const u8, what: []const u8, rel: []const u8) void {
    const rc = sys.unlink(path_z);
    if (rc != 0 and rc != -c.ENOENT)
        std.log.warn("cannot remove cached {s} for {s} (errno {d})", .{ what, rel, -rc });
}

/// Origin file identity used to detect a same-size rewrite that size-only
/// reconciliation cannot see (another node's FUSE write, or a direct write
/// into the origin tree). Trailer on `meta/*.pieces` and on origin
/// piece-hash manifests; optional, so older sidecars and manifests still
/// load. An unknown identity skips the check.
pub const OriginId = struct {
    mtime_sec: i64 = 0,
    mtime_nsec: i64 = 0,
    ino: u64 = 0,
    known: bool = false,

    pub const encoded_len: usize = piece.manifest_identity_len;

    pub fn fromStat(st: c.struct_stat) OriginId {
        return .{
            .mtime_sec = st.st_mtim.tv_sec,
            .mtime_nsec = @intCast(st.st_mtim.tv_nsec),
            .ino = @intCast(st.st_ino),
            .known = true,
        };
    }

    /// True when `observed` is a different object or a strictly newer write
    /// of the same object. An older or equal mtime on the same ino is NFS
    /// attribute lag after our own write, not a rewrite.
    pub fn contentChanged(recorded: OriginId, observed: OriginId) bool {
        if (!recorded.known or !observed.known) return false;
        if (recorded.ino != observed.ino) return true;
        if (observed.mtime_sec != recorded.mtime_sec)
            return observed.mtime_sec > recorded.mtime_sec;
        return observed.mtime_nsec > recorded.mtime_nsec;
    }

    /// Both sides named and the same object at the same mtime. Manifest
    /// load uses this (not contentChanged): a newer published identity
    /// is a rewrite this node has not observed yet, and must not mix
    /// those hashes into the current entry.
    pub fn eql(a: OriginId, b: OriginId) bool {
        if (!a.known or !b.known) return false;
        return a.ino == b.ino and a.mtime_sec == b.mtime_sec and a.mtime_nsec == b.mtime_nsec;
    }

    /// True when this identity is a strictly newer write than `st`'s mtime.
    /// A piece-hash manifest sampled at `st` then predates the rewrite and
    /// must not fill `Cached.hashes` (it still names the previous object's
    /// digests at the same file_size).
    pub fn newerThanMtime(self: OriginId, st: c.struct_stat) bool {
        if (!self.known) return false;
        const sec = st.st_mtim.tv_sec;
        const nsec: i64 = @intCast(st.st_mtim.tv_nsec);
        if (self.mtime_sec != sec) return self.mtime_sec > sec;
        return self.mtime_nsec > nsec;
    }

    fn write(self: OriginId, out: *[encoded_len]u8) void {
        std.mem.writeInt(i64, out[0..8], self.mtime_sec, .little);
        std.mem.writeInt(i64, out[8..16], self.mtime_nsec, .little);
        std.mem.writeInt(u64, out[16..24], self.ino, .little);
    }

    fn read(blob: *const [encoded_len]u8) OriginId {
        return .{
            .mtime_sec = std.mem.readInt(i64, blob[0..8], .little),
            .mtime_nsec = std.mem.readInt(i64, blob[8..16], .little),
            .ino = std.mem.readInt(u64, blob[16..24], .little),
            .known = true,
        };
    }
};

pub const Store = struct {
    /// Idle window a file must exceed before a cached piece may be punched:
    /// cullOne picks candidates this stale, and punchPiece revalidates under
    /// the file lock so a read/fill/transfer inside the window is never culled.
    const recency_secs: i64 = 10;

    /// Cache data files hold origin bytes. 0600 so a local user who cannot
    /// read the origin (FUSE default_permissions) cannot read the cache copy.
    /// Sidecars and pin markers share this mode via writeFileOwnerOnly.
    const cache_data_mode: c.mode_t = 0o600;

    /// Owner-only directories under the cache root (`data/`, `meta/`, `pin/`
    /// and every nested parent). 0755 would let a local user blocked by
    /// origin modes and FUSE `default_permissions` list which weights are
    /// cached or pinned. Leftover 0755 dirs (pre-0700 daemons) are tightened
    /// on ensureLayout; mkdirAll does not chmod an existing name.
    const cache_dir_mode: c.mode_t = 0o700;

    gpa: std.mem.Allocator,
    io: std.Io,
    origin: []const u8,
    cache: []const u8,
    piece_size: u32,
    water: cull.Water = .{},
    stats: Stats = .{},
    /// Edge-triggered origin I/O outage flag. FUSE getattr/open/read/write
    /// and originPread/originPwrite share this so an NFS outage logs once
    /// (path + errno) instead of once per syscall, and recovery logs once
    /// too, the same shape as cullLoop's statvfs suspension. Discovery-tick
    /// lease publish/refresh feed it as well (`tickCluster`), so an idle
    /// node with a dead origin is visible without waiting for a FUSE op.
    /// status.json publishes it as origin_down (0/1) so `modelfs status`
    /// answers whether NFS is currently failing. Peer HTTP keeps its
    /// per-request origin-stat warns: that path is already bounded by the
    /// inflight cap. Origin pread/pwrite still raise this flag, so a fill
    /// or peer /data hydration that hits EIO after a successful stat is not
    /// silent in status.json.
    origin_io_down: std.atomic.Value(bool) = .init(false),
    mu: std.Io.Mutex = .init,
    files: std.StringHashMap(*Cached),
    /// Bumped under mu after every mutation of on-disk cache artifacts
    /// (data/meta unlink or rewrite). get()'s builder loads the sidecar
    /// OUTSIDE mu; without this stamp a builder that started before a
    /// concurrent forget/reap-punch could publish an entry whose bits
    /// describe pieces whose bytes were just unlinked or holed -- reads
    /// would serve hole zeros that the bits claim are cached. Builders
    /// sample the epoch before loadBits and discard the build when it
    /// changed before the insert window.
    purge_epoch: u64 = 0,
    /// How long a transient manifest-load failure waits before the next
    /// attempt (a field so tests shrink it; 3 s in production). Cheap:
    /// expectedHash consults the timestamp per miss against the caller's
    /// monotonic-ms instant, so the origin is re-read at most once per
    /// interval while fills are active, and a simulator drives the
    /// interval without sleeping.
    manifest_retry_ms: i64 = 3000,

    pub const Cached = struct {
        rel: []u8,
        size: u64,
        mu: std.Io.Mutex = .init,
        bits: piece.Bitfield,
        /// In-flight fill claims: piece index -> `writes` sampled at beginFill.
        /// completeFill drops a claim whose generation no longer matches, so a
        /// peer fill cannot land over bytes this node just wrote through.
        filling: std.AutoHashMap(u32, u64),
        cache_fd: c_int = -1,
        last_access: std.atomic.Value(i64) = .init(0),
        /// Serializes write-through pwrite+mark with completeFill pwrite+mark,
        /// punchPiece, and size-changing ftruncate (reconcileSize, mf_truncate,
        /// cacheFill shrink). Without it the two pwrites race on the cache
        /// fd: a fill that claimed before the write can overwrite the
        /// write-through bytes and then mark them filled. punchPiece or
        /// ftruncate taking only file.mu could hole a piece between
        /// copyIntoCache's pwrite and mark, then the mark would publish hole
        /// zeros as cached data. beginXfer increments xfer under this lock
        /// so copyIntoCache cannot sample xfer==0 and then pwrite under a
        /// sendfile that started between the load and the copy. Lock order
        /// is content_mu then file.mu.
        content_mu: std.Io.Mutex = .init,
        /// Count of local origin mutations observed on this entry (write-through,
        /// distrust, truncate wipe). Nonzero means peer bytes for this path
        /// may predate those mutations; hydrates take the origin instead.
        writes: u64 = 0,
        /// Active users of this pointer. Taken under store.mu together with
        /// the map lookup; released by releaseFile. An entry removed from the
        /// map (forget/reap) can no longer be acquired, so the last release
        /// on a removed entry frees it.
        refs: std.atomic.Value(u32) = .init(0),
        /// Set when the entry is removed from the map. Read with .acquire by
        /// the final releaser to decide destruction.
        dead: std.atomic.Value(bool) = .init(false),
        /// Set by the thread that wins destruction. The last releaseFile (dead
        /// set, refs already 0) and forget (refs==0, dead just stamped) can
        /// both observe their condition on the same entry when a reference is
        /// dropped concurrently with the map removal; without a winner flag
        /// both would deinit it. Exactly one caller swaps false->true.
        freed: std.atomic.Value(bool) = .init(false),
        /// Peer transfers currently streaming through this entry (the whole
        /// /data span: hydration plus send) and cache reads in flight (the
        /// FUSE read path from the bit sample through pread, plus readCache).
        /// punchPiece refuses to hole a piece while this is nonzero: bytes
        /// in flight are read straight from the pages a punch would cut, and
        /// the fetching peer (or the FUSE reader) would get hole zeros.
        /// copyIntoCache refuses to pwrite while this is nonzero for the
        /// same reason: a write-through under sendfile mixes new bytes into
        /// the in-flight copy. Recency stamping alone cannot provide this
        /// -- a single stalled sendfile chunk, a slow hydrate of the next
        /// piece in a straddling read, or a pread can outlast recency_secs.
        xfer: std.atomic.Value(u32) = .init(0),
        /// Trusted per-piece content digests (blake3 of the piece bytes),
        /// keyed by piece index. Sources: the origin piece-hash manifest
        /// (published by the node that wrote or fully read the file), origin
        /// fills (the origin is the trust root), and this node's own
        /// write-throughs. Peer fills verify against a digest before admit;
        /// serves verify cached bytes against one before streaming. Read and
        /// written under file.mu; cleared on size change, forget, and
        /// distrust. Digests survive punchPiece (they are the expectation a
        /// refill must meet), so a culled piece refills verified.
        hashes: std.AutoHashMap(u32, [piece.digest_len]u8),
        /// file.size at the last manifest load attempt. null = never
        /// successfully loaded for the current size; a manifest whose
        /// recorded file_size differs from the entry's is stale and
        /// contributes nothing. Read/written under file.mu.
        manifest_size: ?u64 = null,
        /// Monotonic-ms instant after which a failed manifest load may be
        /// retried, compared to the caller's `now_ms` (see expectedHash).
        /// A transient failure (absent file, stale NFS negative cache,
        /// torn write) must not disable peer fills for the entry's whole
        /// lifetime: the writer publishes at close, which can be moments
        /// after this node's first fill. Read/written under file.mu.
        manifest_retry_at: i64 = 0,
        /// Trusted hashes changed since the last origin publish (admit,
        /// write-through, or a size-change wipe). mf_release publishes when
        /// set. Read/written under file.mu.
        manifest_dirty: bool = false,
        /// Origin mtime/ino last observed for this path. A later get() whose
        /// origin stat is a different ino or a newer mtime wipes marks the
        /// way a size change does, so a same-size rewrite cannot serve the
        /// previous file's bytes. Unknown until the first origin-stat'd
        /// get() or a sidecar trailer loads.
        origin_id: OriginId = .{},

        pub fn deinit(self: *Cached, gpa: std.mem.Allocator) void {
            sys.close(self.cache_fd);
            self.bits.deinit(gpa);
            self.filling.deinit();
            self.hashes.deinit();
            gpa.free(self.rel);
            gpa.destroy(self);
        }
    };

    /// Drops one reference acquired via get()/lookupRef(). When the entry was
    /// evicted from the map while the reference was outstanding, the final
    /// release destroys it.
    pub fn releaseFile(self: *Store, file: *Cached) void {
        if (file.refs.fetchSub(1, .acq_rel) != 1) return;
        if (!file.dead.load(.acquire)) return;
        // The last releaser and forget can both reach destruction on the same
        // entry; only the winner deinits (see `freed`).
        if (!file.freed.swap(true, .acq_rel)) file.deinit(self.gpa);
    }

    pub fn init(gpa: std.mem.Allocator, io: std.Io, origin: []const u8, cache: []const u8, piece_size: u32) Store {
        return .{
            .gpa = gpa,
            .io = io,
            .origin = origin,
            .cache = cache,
            .piece_size = piece_size,
            .files = std.StringHashMap(*Cached).init(gpa),
        };
    }

    /// True when `e` is an origin-infrastructure outage. The edge-triggered
    /// journal (first failure logs path+errno, recovery logs "origin recovered")
    /// is for these three: a busy FUSE storm must not flood the journal, and
    /// an operator grepping for recovery must be looking at NFS/transport
    /// health, not at a single path. Every other errno is a path-level
    /// answer (ENOENT, ELOOP from O_NOFOLLOW, EACCES, ENOSPC, ENAMETOOLONG)
    /// and stays counted in reads_err/writes_err without raising the flag --
    /// a planted-symlink write would otherwise look like the origin died,
    /// then log "origin recovered" on the next successful op of a different
    /// file. replyOriginStat keeps its own 404/400/502 split: a peer fetch
    /// still needs to tell "nobody has this file" from "this node cannot
    /// stat the origin", including ELOOP through a looping parent.
    pub fn originIoOutage(e: i32) bool {
        return e == c.EIO or e == c.ESTALE or e == c.ETIMEDOUT;
    }

    /// First infrastructure origin failure logs path and errno; later ones
    /// stay counted-only until a success (rc >= 0) clears the flag. `what`
    /// names the syscall ("stat", "write") so the line is greppable.
    pub fn noteOriginIo(self: *Store, rel: []const u8, rc: i32, what: []const u8) void {
        if (rc >= 0) {
            if (self.origin_io_down.swap(false, .monotonic))
                std.log.info("origin recovered", .{});
            return;
        }
        const e: i32 = -rc;
        if (!originIoOutage(e)) return;
        if (!self.origin_io_down.swap(true, .monotonic))
            std.log.warn("origin {s} failed for {s} (errno {d})", .{ what, rel, e });
    }

    pub fn deinit(self: *Store) void {
        var it = self.files.iterator();
        while (it.next()) |e| {
            const f = e.value_ptr.*;
            // Entries still referenced at shutdown belong to handlers the
            // drain wait gave up on. Destroying them would hand those threads
            // freed memory; leaking them is bounded by the stuck-handler cap
            // and strictly safer.
            if (f.refs.load(.acquire) != 0) {
                std.log.warn("store shutdown: {s} still referenced; leaking entry", .{f.rel});
                continue;
            }
            // A handler the drain gave up on may still be finishing its last
            // releaseFile on this entry; the winner flag keeps shutdown from
            // double-freeing with it.
            if (!f.freed.swap(true, .acq_rel)) f.deinit(self.gpa);
        }
        self.files.deinit();
    }

    pub fn originPath(self: *const Store, buf: []u8, rel: []const u8) ![*:0]u8 {
        // Empty rel names the origin root (FUSE "/"). Anything else joins
        // this root and must already have passed relOk at the trust
        // boundary; refuse here too so a missed gate cannot escape the tree
        // via ".." components. NameTooLong is the only error joinZ returns,
        // and callers already map it to ENAMETOOLONG.
        if (rel.len != 0 and !relOk(rel)) return error.NameTooLong;
        return sys.joinZ(buf, self.origin, rel);
    }

    /// Joins cache/<sub>/<rel> (rel empty names the subdir itself): one
    /// policy for every artifact path under the cache root.
    fn cacheSubPath(self: *const Store, buf: []u8, sub: []const u8, rel: []const u8) ![*:0]u8 {
        if (rel.len != 0 and !relOk(rel)) return error.NameTooLong;
        var mid: [sys.c.PATH_MAX]u8 = undefined;
        const d = try sys.joinZ(&mid, self.cache, sub);
        return sys.joinZ(buf, std.mem.span(d), rel);
    }

    pub fn cacheDataPath(self: *const Store, buf: []u8, rel: []const u8) ![*:0]u8 {
        return self.cacheSubPath(buf, "data", rel);
    }

    pub fn cacheMetaPath(self: *const Store, buf: []u8, rel: []const u8) ![*:0]u8 {
        var mid: [sys.c.PATH_MAX]u8 = undefined;
        const n = try self.cacheSubPath(&mid, "meta", rel);
        return sys.appendExt(buf, n, ".pieces");
    }

    /// Piece size recorded in `meta/<rel>.pieces`, or null when the sidecar
    /// is missing, unreadable, or not a usable header. `modelfs verify` uses
    /// this so it checks against the grid the daemon wrote, not `--piece`.
    pub fn sidecarPieceSize(self: *const Store, rel: []const u8) ?u32 {
        var buf: [sys.c.PATH_MAX]u8 = undefined;
        const z = self.cacheMetaPath(&buf, rel) catch return null;
        const fd = sys.open(z, c.O_RDONLY | c.O_NOFOLLOW, 0);
        if (fd < 0) return null;
        defer sys.close(fd);
        var hdr: [8]u8 = undefined;
        if (sys.preadAll(fd, &hdr, 0) != 8) return null;
        return piece.sidecarPieceSize(&hdr);
    }

    pub fn cachePinPath(self: *const Store, buf: []u8, rel: []const u8) ![*:0]u8 {
        return self.cacheSubPath(buf, "pin", rel);
    }

    pub fn cacheStatusPath(self: *const Store, buf: []u8) ![*:0]u8 {
        return sys.joinZ(buf, self.cache, status_file);
    }

    pub fn ensureLayout(self: *const Store) i32 {
        var buf: [sys.c.PATH_MAX]u8 = undefined;
        for ([_][]const u8{ "data", "meta", "pin" }) |sub| {
            const p = self.cacheSubPath(&buf, sub, "") catch return -sys.c.ENAMETOOLONG;
            if (sys.mkdirAll(std.mem.span(p), cache_dir_mode) != 0) return sys.negErrno();
            // mkdirAll leaves an existing dir's mode alone (EEXIST + is-dir).
            // A leftover 0755 `data/` from an older daemon is world-listable
            // even when the files inside are 0600; fchmod through an
            // O_DIRECTORY|O_NOFOLLOW fd so a planted symlink cannot steer
            // the mode change onto another tree.
            tightenCacheDir(p);
        }
        return 0;
    }

    /// Owner-only the named cache directory. Best-effort: a failure leaves
    /// the mkdirAll mode in place (0700 for a new dir, leftover for an
    /// existing one) the same way openCache ignores a failed data fchmod.
    fn tightenCacheDir(path_z: [*:0]const u8) void {
        const fd = sys.open(path_z, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW, 0);
        if (fd < 0) return;
        defer sys.close(fd);
        _ = c.fchmod(fd, cache_dir_mode);
    }

    /// lstat semantics: the origin is shared storage other parties can write
    /// (the .cluster threat model applies to model names too), so a planted
    /// final symlink must surface as S_IFLNK -- every caller's S_IFREG gate
    /// then rejects it fail-closed instead of stat'ing the link's target.
    /// Paired with the O_NOFOLLOW opens in originPread/originPwrite, which
    /// close the window between this sample and any later open.
    pub fn statOrigin(self: *Store, rel: []const u8, st: *c.struct_stat) i32 {
        var buf: [sys.c.PATH_MAX]u8 = undefined;
        const p = self.originPath(&buf, rel) catch return -c.ENAMETOOLONG;
        const rc = sys.lstatPath(p, st);
        self.noteOriginIo(rel, rc, "stat");
        return rc;
    }

    fn pinExists(self: *const Store, rel: []const u8) bool {
        var buf: [sys.c.PATH_MAX]u8 = undefined;
        const p = self.cachePinPath(&buf, rel) catch return false;
        var st: c.struct_stat = undefined;
        return sys.statPath(p, &st) == 0;
    }

    pub fn setPin(self: *const Store, rel: []const u8, on: bool) i32 {
        var buf: [sys.c.PATH_MAX]u8 = undefined;
        const p = self.cachePinPath(&buf, rel) catch return -c.ENAMETOOLONG;
        if (on) {
            const parent = sys.parentOf(std.mem.span(p));
            _ = sys.mkdirAll(parent, cache_dir_mode);
            return sys.writeFileOwnerOnly(p, "");
        }
        const rc = sys.unlink(p);
        if (rc == -c.ENOENT) return 0;
        return rc;
    }

    /// Unlinks the data/meta/pin artifacts keyed to rel. A path that no
    /// longer fits PATH_MAX cannot name an existing artifact, so build
    /// failures join ENOENT as already-gone.
    fn purgeArtifacts(self: *Store, rel: []const u8) void {
        var buf: [sys.c.PATH_MAX]u8 = undefined;
        if (self.cacheDataPath(&buf, rel)) |cp| {
            unlinkOrWarn(cp, "data", rel);
        } else |_| {}
        if (self.cacheMetaPath(&buf, rel)) |mp| {
            unlinkOrWarn(mp, "meta", rel);
        } else |_| {}
        if (self.cachePinPath(&buf, rel)) |pp| {
            unlinkOrWarn(pp, "pin", rel);
        } else |_| {}
    }

    /// Drop all cache state keyed to rel. The namespace mutates through
    /// origin-side unlink and rename while cache identity is the path, so the
    /// in-memory entry (bits, open fd to a possibly unlinked inode) and the
    /// data/meta/pin artifacts must die with it: a same-size recreate would
    /// otherwise serve the previous file's bytes through resurrected bits.
    /// Map removal, artifact unlinks, and eviction share one store.mu window
    /// so a concurrent get() cannot recreate the entry (and hydrate fresh
    /// bytes into it) between removal and unlink. Concurrent holders keep
    /// their reference alive until releaseFile; whoever holds the last
    /// reference frees the entry.
    ///
    /// The open cache fd is deliberately NOT closed here even though holders'
    /// references pin the entry: a reference holder may be past openCache()
    /// and about to pwrite/pread/sendfile on that exact descriptor. Closing
    /// it now lets the kernel hand the number to the next open() (another
    /// file's cache fd), turning the holder's I/O into writes to an
    /// unrelated cached file. Leaving it open keeps every outstanding use
    /// pointed at the purged (unlinked) inode, where late I/O is harmless;
    /// Cached.deinit closes it with the entry.
    pub fn forget(self: *Store, rel: []const u8) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.files.fetchRemove(rel)) |kv| {
            const file = kv.value;
            // Bits wipe, artifact unlinks, and the dead stamp share one
            // file.mu window (same shape as reapIdle). finishPiece and
            // copyIntoCache re-check dead under this same lock before they
            // save; stamping only after the unlock would leave a window
            // where a late finisher (a fill or write-through claimed before
            // the unlink) recreates the meta sidecar with filled bits over
            // artifacts that no longer exist, and a same-size recreate would
            // serve hole zeros as cached model data.
            file.mu.lockUncancelable(self.io);
            @memset(file.bits.bytes, 0);
            self.purgeArtifacts(rel);
            file.dead.store(true, .release);
            file.mu.unlock(self.io);
            // Invalidate any get() builder whose sidecar read raced this
            // purge: its insert window now sees a changed epoch and retries.
            self.purge_epoch += 1;
            // Removal above blocks new references; past this point refs only
            // decreases. Zero means nobody holds it: free now. The winner
            // flag keeps a releaseFile that already dropped the last
            // reference (and is between its dead.load and deinit) from
            // double-freeing alongside this path.
            if (file.refs.load(.acquire) == 0)
                if (!file.freed.swap(true, .acq_rel)) file.deinit(self.gpa);
            return;
        }
        // No live entry: artifacts from an earlier run must still be purged.
        self.purgeArtifacts(rel);
        self.purge_epoch += 1;
    }

    /// Drops trust in every cached byte keyed to rel after a write whose
    /// post-write size could not be observed: unlinks the persisted sidecar
    /// and clears the live entry's marks, so no read can serve pre-write
    /// bytes as current. Unlike forget, data files and pins stay: the bytes
    /// on disk are intact, they just cannot be proven current, and unmarked
    /// pieces refill over them on demand. The unlink shares the store.mu
    /// window with forget/reap purges so a racing get() builder cannot
    /// publish bits loaded from the doomed sidecar; the mark wipe sits under
    /// file.mu where finishPiece and copyIntoCache save.
    pub fn distrust(self: *Store, rel: []const u8) void {
        var mbuf: [sys.c.PATH_MAX]u8 = undefined;
        // A sidecar path that does not fit cannot name an on-disk artifact,
        // but live marks still have to drop: returning here used to leave
        // a map entry's bits set after a write whose size could not be
        // observed, so the next read served pre-write cache bytes as current.
        const mp: ?[*:0]u8 = self.cacheMetaPath(&mbuf, rel) catch blk: {
            std.log.warn("cannot name piece sidecar for {s}; dropping live cache marks", .{rel});
            break :blk null;
        };
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        // Sidecar unlink and mark wipe share one file.mu window (same shape
        // as forget): a finishPiece or copyIntoCache saving between a plain
        // unlink and the wipe would write the pre-write marks back over the
        // dropped sidecar -- trust in pre-write bytes resurrected on disk
        // for a file whose origin content just changed, loaded again by the
        // next entry build. Holding store.mu across both steps also keeps
        // the entry in the map for their duration, so no reference juggling
        // is needed.
        const f = self.files.get(rel);
        if (f) |file| file.mu.lockUncancelable(self.io);
        defer if (f) |file| file.mu.unlock(self.io);
        if (mp) |p| unlinkOrWarn(p, "meta", rel);
        // Same builder-invalidation contract as forget: a builder whose
        // sidecar read raced this unlink must not publish its stale bits.
        self.purge_epoch += 1;
        if (f) |file| {
            @memset(file.bits.bytes, 0);
            file.writes += 1;
            // Same trust drop for digests: the pre-write bytes they describe
            // are no longer provably current, and a stale expectation would
            // reject the origin's current bytes on every refill.
            self.clearHashes(file);
        }
    }

    /// Outcome of loading a sidecar: `bits` is always sized for the caller's
    /// geometry. `discarded` is true when a sidecar was present but unusable
    /// (wrong piece/file size, corrupt, unreadable). The in-memory field is
    /// then empty; the caller must persist that wipe or a restart can decode
    /// the old sidecar at the previous size and serve its marks over new
    /// bytes. A missing sidecar is not discarded: first touch stays empty
    /// on disk until a fill actually lands.
    const LoadedBits = struct {
        bits: piece.Bitfield,
        discarded: bool,
        id: OriginId = .{},
    };

    fn loadBits(self: *Store, rel: []const u8, file_size: u64, origin_id: OriginId) !LoadedBits {
        var buf: [sys.c.PATH_MAX]u8 = undefined;
        const p = try self.cacheMetaPath(&buf, rel);
        var open_errno: i32 = 0;
        const blob = sys.readFileAllocNoFollowOpenErrno(self.gpa, p, 8 * 1024 * 1024, &open_errno) catch |err| switch (err) {
            // Missing sidecar is every file's first touch: start empty.
            error.OpenFailed => {
                if (open_errno != c.ENOENT)
                    std.log.warn("cannot read piece sidecar for {s} (errno {d}); treating cache as empty", .{ rel, open_errno });
                // Non-ENOENT is a present sidecar we could not read: persist
                // the empty field so a later open of the previous size cannot
                // decode it. ENOENT is not a discard.
                return .{
                    .bits = try piece.Bitfield.init(self.gpa, piece.count(file_size, self.piece_size)),
                    .discarded = open_errno != c.ENOENT,
                    .id = .{},
                };
            },
            // Allocation failure propagates: callers turn it into EIO/500
            // instead of a cold entry pretending nothing was stored (the
            // same policy as beginFill's claim OOM).
            error.OutOfMemory => return error.OutOfMemory,
            // An unreadable or oversized sidecar degrades to "nothing
            // cached" like the corrupt case below, but the reason must
            // reach the log or a failing meta tree looks exactly like an
            // always-cold cache.
            else => {
                std.log.warn("cannot read piece sidecar for {s}: {t}; treating cache as empty", .{ rel, err });
                return .{
                    .bits = try piece.Bitfield.init(self.gpa, piece.count(file_size, self.piece_size)),
                    .discarded = true,
                    .id = .{},
                };
            },
        };
        defer self.gpa.free(blob);
        // A truncated or corrupt sidecar (torn writeFile, crash mid-save) must
        // degrade to "nothing cached", never poison every read of the file.
        // The reset is also named here: it means this file's cached state was
        // discarded and everything re-hydrates over origin/peers, which an
        // operator should be able to tell from the log instead of guessing why
        // the cache went cold.
        const bits = piece.Bitfield.decode(self.gpa, blob, self.piece_size, file_size) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadBitfield => {
                std.log.warn("corrupt piece sidecar for {s}; treating cache as empty", .{rel});
                return .{
                    .bits = try piece.Bitfield.init(self.gpa, piece.count(file_size, self.piece_size)),
                    .discarded = true,
                    .id = .{},
                };
            },
        };
        // decode() already returns an empty field on a geometry mismatch;
        // that empty field is only in RAM until we persist it. A sidecar
        // whose recorded size matches the loader's is kept as-is.
        const stale = blob.len >= 16 and std.mem.eql(u8, blob[0..4], piece.magic) and
            (std.mem.readInt(u32, blob[4..8], .little) != self.piece_size or
                std.mem.readInt(u64, blob[8..16], .little) != file_size);
        if (stale) return .{ .bits = bits, .discarded = true, .id = .{} };
        // Optional identity trailer after the bit bytes. Older sidecars omit
        // it; a rewrite then has no stamp to compare until the next save.
        var id = OriginId{};
        const trailer_off = 16 + bits.bytes.len;
        if (blob.len >= trailer_off + OriginId.encoded_len) {
            id = OriginId.read(blob[trailer_off..][0..OriginId.encoded_len]);
            if (OriginId.contentChanged(id, origin_id)) {
                @memset(bits.bytes, 0);
                return .{ .bits = bits, .discarded = true, .id = id };
            }
        }
        return .{ .bits = bits, .discarded = false, .id = id };
    }

    /// Persists the entry's current bits after a discarded sidecar load.
    /// Caller must not hold file.mu. A forget that raced the insert has
    /// already unlinked artifacts and stamped dead: saving then would
    /// recreate a sidecar over a name that no longer exists.
    fn persistDiscardedWipe(self: *Store, file: *Cached) void {
        file.mu.lockUncancelable(self.io);
        defer file.mu.unlock(self.io);
        if (file.dead.load(.acquire)) return;
        _ = self.saveBits(file, false);
    }

    /// Writes data at path under root/sub, creating the parent directory only
    /// when the first open reports ENOENT. Steady-state saves pay zero mkdir
    /// syscalls: an unconditional mkdirAll here cost one failed mkdir per path
    /// component on every piece fill and write-through for the life of the
    /// daemon. Failure semantics match the old best-effort mkdir: a parent
    /// that cannot be created surfaces as the retried write's errno.
    fn writeFileMakingParent(path_z: [*:0]const u8, data: []const u8, durable: bool) i32 {
        const w = if (durable)
            sys.writeFileOwnerOnlyDurable(path_z, data)
        else
            sys.writeFileOwnerOnly(path_z, data);
        if (w != -c.ENOENT) return w;
        _ = sys.mkdirAll(sys.parentOf(std.mem.span(path_z)), cache_dir_mode);
        return if (durable)
            sys.writeFileOwnerOnlyDurable(path_z, data)
        else
            sys.writeFileOwnerOnly(path_z, data);
    }

    /// Persists the entry's current bits. Caller must hold file.mu: encode
    /// reads bits/size under it. False means the sidecar was not updated
    /// (encode failure, unwritable path, torn write); callers that gate
    /// destructive disk work on persisted state must treat false as
    /// "do not proceed". `durable` fsyncs the sidecar before returning:
    /// required for punchPiece, where the cleared field must reach stable
    /// storage before the hole is cut (a plain write lets delayed allocation
    /// land the punch first, and power loss then leaves the old sidecar
    /// claiming filled over hole zeros). Fill-path saves stay best-effort;
    /// losing one only costs a refill over intact bytes.
    pub fn saveBits(self: *Store, file: *Cached, durable: bool) bool {
        // Stack for any sidecar that fits (16 KiB of bits is a 2 TiB file at
        // the default 16 MiB piece): a piece fill used to heap-allocate a
        // copy of bits the entry already holds, once per hydrated piece.
        const id_extra: usize = if (file.origin_id.known) OriginId.encoded_len else 0;
        const need = file.bits.encodedLen() + id_extra;
        var stack: [16 * 1024]u8 = undefined;
        var heap: []u8 = &.{};
        defer if (heap.len != 0) self.gpa.free(heap);
        const buf: []u8 = if (need <= stack.len) stack[0..need] else blk: {
            const h = self.gpa.alloc(u8, need) catch {
                std.log.warn("bitfield encode failed for {s}; cache state resets on restart", .{file.rel});
                return false;
            };
            heap = h;
            break :blk h;
        };
        const bits_blob = file.bits.encodeTo(self.piece_size, file.size, buf) catch {
            std.log.warn("bitfield encode failed for {s}; cache state resets on restart", .{file.rel});
            return false;
        };
        const blob: []const u8 = if (!file.origin_id.known) bits_blob else blk: {
            var trailer: [OriginId.encoded_len]u8 = undefined;
            file.origin_id.write(&trailer);
            @memcpy(buf[bits_blob.len..][0..OriginId.encoded_len], &trailer);
            break :blk buf[0 .. bits_blob.len + OriginId.encoded_len];
        };
        var path_buf: [sys.c.PATH_MAX]u8 = undefined;
        const p = self.cacheMetaPath(&path_buf, file.rel) catch {
            std.log.warn("bitfield save failed for {s}; cache path does not fit; cache state resets on restart", .{file.rel});
            return false;
        };
        const w = writeFileMakingParent(p, blob, durable);
        if (w != 0) {
            std.log.warn("bitfield save failed for {s} (errno {d}); cache state resets on restart", .{ file.rel, -w });
            return false;
        }
        return true;
    }

    /// Brings a live entry in line with a freshly observed origin size:
    /// swaps in an empty bitfield sized for the new length, truncates the
    /// cache fd so stale pieces cannot serve the new inode, and persists the
    /// emptied field best-effort. The save closes the crash window decode
    /// cannot: a sidecar whose recorded size equals the loader's decodes
    /// cleanly, so an unsaved wipe let a crash here reload the pre-reset
    /// marks as soon as the file was back at the last-saved length, serving
    /// old bytes or hole zeros as current. Must be called WITHOUT store.mu
    /// held (it takes content_mu then file.mu internally).
    fn reconcileSize(self: *Store, f: *Cached, file_size: u64) !*Cached {
        return self.reconcile(f, file_size, OriginId{});
    }

    /// Brings a live entry in line with a freshly observed origin size and
    /// identity. Size mismatch is the existing wipe; a same-size rewrite
    /// (newer mtime or different ino) is the same wipe, because the bits
    /// still name the previous object's pieces. An unknown identity is
    /// adopted without wiping so the next rewrite is visible. Callers that
    /// have no origin stat pass OriginId{} and keep size-only behavior.
    fn reconcile(self: *Store, f: *Cached, file_size: u64, origin_id: OriginId) !*Cached {
        // Size and identity are mutated under file.mu; an unlocked compare
        // races a concurrent truncate and can skip a needed wipe, or two
        // getters that both sampled a mismatch can each swap in an empty
        // field, the second wiping a fill that landed between them.
        f.mu.lockUncancelable(self.io);
        const size_chg = f.size != file_size;
        const content_chg = OriginId.contentChanged(f.origin_id, origin_id);
        if (!size_chg and !content_chg) {
            self.adoptOriginIdLocked(f, origin_id);
            f.mu.unlock(self.io);
            return f;
        }
        f.mu.unlock(self.io);
        var nb = try piece.Bitfield.init(self.gpa, piece.count(file_size, self.piece_size));
        // content_mu first, then file.mu: the same order copyIntoCache,
        // completeFill, and punchPiece use. Taking only file.mu let a
        // concurrent pwrite land, then this ftruncate cut those bytes,
        // then the filler's mark published the hole as cached data.
        // Readers read size/bits/cache_fd while holding file.mu, and the
        // ftruncate sits in the same window so cache_fd cannot be closed
        // (entry destroyed by the last releaser) between capture and use.
        f.content_mu.lockUncancelable(self.io);
        defer f.content_mu.unlock(self.io);
        f.mu.lockUncancelable(self.io);
        const size_chg2 = f.size != file_size;
        const content_chg2 = OriginId.contentChanged(f.origin_id, origin_id);
        if (!size_chg2 and !content_chg2) {
            self.adoptOriginIdLocked(f, origin_id);
            f.mu.unlock(self.io);
            nb.deinit(self.gpa);
            return f;
        }
        var ob = f.bits;
        f.bits = nb;
        f.size = file_size;
        f.writes += 1;
        // Digests described the pre-resize / pre-rewrite bytes: they can
        // no longer gate refills of the new content.
        self.clearHashes(f);
        if (origin_id.known) f.origin_id = origin_id;
        truncateCacheFd(f, file_size);
        // Same best-effort save mf_truncate pairs with its own swap: the
        // reset must outlive the process to count as an invalidation.
        _ = self.saveBits(f, false);
        f.mu.unlock(self.io);
        ob.deinit(self.gpa);
        return f;
    }

    /// Caller holds file.mu. Records `origin_id` when the entry has none.
    /// Persists only when there are marks to protect: first-touch of a new
    /// file must not create an empty sidecar.
    fn adoptOriginIdLocked(self: *Store, f: *Cached, origin_id: OriginId) void {
        if (!origin_id.known or f.origin_id.known) return;
        f.origin_id = origin_id;
        if (f.bits.lastSet() != null) _ = self.saveBits(f, false);
    }

    /// References a map hit found while holding store.mu, releases the lock,
    /// and returns the entry reconciled to file_size and origin identity; on
    /// reconcile failure the reference is released before the error escapes
    /// (the one cleanup rule all three lookup sites in get() must share).
    fn refHitUnlocking(self: *Store, hit: *Cached, file_size: u64, origin_id: OriginId) !*Cached {
        _ = hit.refs.fetchAdd(1, .monotonic);
        self.mu.unlock(self.io);
        return self.reconcile(hit, file_size, origin_id) catch |err| {
            self.releaseFile(hit);
            return err;
        };
    }

    /// Returns a referenced entry: the caller owns one reference and must
    /// releaseFile it. References are taken under store.mu so an entry cannot
    /// be evicted between lookup and refcount bump. A newly built entry is
    /// born stamped with `now_sec` (the caller's monotonic instant, as in
    /// punchPiece/cullOne/reapIdle): recency decisions stay pure functions of
    /// state plus caller-supplied instants, so simulation drives them without
    /// touching the wall clock.
    pub fn get(self: *Store, rel: []const u8, file_size: u64, now_sec: i64) !*Cached {
        return self.getIdentified(rel, file_size, OriginId{}, now_sec);
    }

    /// Like get(), with the origin identity from the stat that produced
    /// `file_size`. A same-size rewrite (newer mtime or different ino) wipes
    /// marks the way a size change does. Callers without a stat use get().
    pub fn getIdentified(self: *Store, rel: []const u8, file_size: u64, origin_id: OriginId, now_sec: i64) !*Cached {
        // Every pass probes the map first and serves a hit without any disk
        // I/O under the global lock; warm callers end there. A miss builds
        // the entry (sidecar read + decode) outside the lock so one cold
        // open cannot serialize every other get/forget/cull behind disk I/O.
        // A racing builder loses the insert below and discards its copy. A
        // racing artifact mutation (forget, reap purge, disk punch) bumps
        // purge_epoch between the sample and the insert check; that build is
        // then discarded -- its bits could describe pieces whose bytes were
        // just unlinked or holed -- and the attempt restarts from a fresh
        // map probe and epoch sample.
        while (true) {
            self.mu.lockUncancelable(self.io);
            if (self.files.get(rel)) |hit| return self.refHitUnlocking(hit, file_size, origin_id);
            const epoch0 = self.purge_epoch;
            self.mu.unlock(self.io);

            // Constructed in a scope so the errdefers cover only the build:
            // once f.* is assigned, f owns every field and all later cleanup
            // goes through f.deinit (double-free otherwise: an early error
            // return would fire both the errdefers and the deinit path).
            var discarded = false;
            const f = blk: {
                const raw = try self.gpa.create(Cached);
                errdefer self.gpa.destroy(raw);
                const rel_own = try self.gpa.dupe(u8, rel);
                errdefer self.gpa.free(rel_own);
                const loaded = try self.loadBits(rel, file_size, origin_id);
                errdefer loaded.bits.deinit(self.gpa);
                discarded = loaded.discarded;
                raw.* = .{
                    .rel = rel_own,
                    .size = file_size,
                    .bits = loaded.bits,
                    .filling = std.AutoHashMap(u32, u64).init(self.gpa),
                    .hashes = std.AutoHashMap(u32, [piece.digest_len]u8).init(self.gpa),
                    .last_access = .init(now_sec),
                    .origin_id = loaded.id,
                };
                break :blk raw;
            };

            self.mu.lockUncancelable(self.io);
            if (self.files.get(rel)) |winner| {
                defer f.deinit(self.gpa);
                return self.refHitUnlocking(winner, file_size, origin_id);
            }
            if (self.purge_epoch != epoch0) {
                self.mu.unlock(self.io);
                f.deinit(self.gpa);
                continue;
            }
            self.files.put(f.rel, f) catch |err| {
                self.mu.unlock(self.io);
                f.deinit(self.gpa);
                return err;
            };
            // Publish and reference atomically: the first release can arrive
            // before the caller's use, so the entry must be born with refs=1.
            _ = f.refs.fetchAdd(1, .monotonic);
            self.mu.unlock(self.io);
            // Same persist-the-wipe contract as reconcileSize on the hit
            // path: a discarded sidecar left on disk would decode cleanly
            // at its recorded size after a crash, serving pre-wipe marks
            // over post-wipe content. First-touch (no sidecar) does not
            // write one.
            if (discarded) self.persistDiscardedWipe(f);
            return self.reconcile(f, file_size, origin_id) catch |err| {
                self.releaseFile(f);
                return err;
            };
        }
    }

    /// Referenced lookup without size reconciliation or creation, for
    /// callers that only need the live entry if one exists.
    pub fn lookupRef(self: *Store, rel: []const u8) ?*Cached {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const f = self.files.get(rel) orelse return null;
        _ = f.refs.fetchAdd(1, .monotonic);
        return f;
    }

    /// Frees every entry that is unreferenced, quiescent for at least
    /// min_idle_secs, unpinned, not mid-fill, and holds nothing worth keeping:
    /// idle entries get their fd closed; entries that are still fully empty
    /// are evicted outright (their data/meta/pin artifacts carry no cached
    /// bytes). Bounds the files map on nodes that churn through many model
    /// paths without unlinks.
    pub fn reapIdle(self: *Store, now_sec: i64, min_idle_secs: i64) void {
        var cands: std.ArrayList(*Cached) = .empty;
        defer cands.deinit(self.gpa);

        // Phase 1 is memory-only under store.mu: pin idle unreferenced
        // entries. pinExists (a stat) and the bitfield scan used to run
        // here, holding the same global lock every get() takes behind
        // O(files) disk I/O -- the same split cullOne already made.
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            var it = self.files.iterator();
            while (it.next()) |e| {
                const f = e.value_ptr.*;
                if (f.refs.load(.acquire) != 0) continue;
                if (now_sec -| f.last_access.load(.monotonic) < min_idle_secs) continue;
                _ = f.refs.fetchAdd(1, .monotonic);
                cands.append(self.gpa, f) catch {
                    // A partial list is HashMap iteration order. Drop every
                    // pin and skip the round so an OOM cannot reap a
                    // hash-order prefix; the next tick retries the full set.
                    _ = f.refs.fetchSub(1, .monotonic);
                    for (cands.items) |pinned| _ = pinned.refs.fetchSub(1, .monotonic);
                    cands.clearRetainingCapacity();
                    return;
                };
            }
        }

        // Hash-map iteration order must not decide which equally idle
        // empty entries are unlinked first (a crash mid-reap would otherwise
        // leave a different remainder from the same set). Same total order
        // cullOne already uses for equal-recency files.
        std.mem.sort(*Cached, cands.items, {}, struct {
            fn lessThan(_: void, a: *Cached, b: *Cached) bool {
                return std.mem.order(u8, a.rel, b.rel) == .lt;
            }
        }.lessThan);

        // Phase 2: close idle fds; drop entries that still hold pieces or
        // a pin. lastSet returns on the first set bit from the end;
        // filled() scanned the whole field to count. pinExists is a stat
        // and must not run under store.mu.
        var n_evict: usize = 0;
        for (cands.items) |f| {
            var evict = false;
            f.mu.lockUncancelable(self.io);
            if (f.filling.count() == 0 and
                now_sec -| f.last_access.load(.monotonic) >= min_idle_secs)
            {
                if (f.cache_fd >= 0) {
                    sys.close(f.cache_fd);
                    f.cache_fd = -1;
                }
                evict = f.bits.lastSet() == null;
            }
            f.mu.unlock(self.io);
            if (evict and self.pinExists(f.rel)) evict = false;
            if (evict) {
                cands.items[n_evict] = f;
                n_evict += 1;
            } else {
                self.releaseFile(f);
            }
        }
        if (n_evict == 0) return;

        // Phase 3: remove and unlink in one store.mu window so get() cannot
        // rebuild the entry between those two steps. Revalidate: a get()
        // that raced phase 2 holds another ref, and a pin that landed
        // between the two phases must keep its pin file.
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (cands.items[0..n_evict]) |f| {
            if (f.dead.load(.acquire) or f.refs.load(.acquire) != 1) {
                self.releaseFile(f);
                continue;
            }
            f.mu.lockUncancelable(self.io);
            const still_empty = f.filling.count() == 0 and f.bits.lastSet() == null;
            f.mu.unlock(self.io);
            if (!still_empty or self.pinExists(f.rel)) {
                self.releaseFile(f);
                continue;
            }
            if (!self.files.remove(f.rel)) {
                self.releaseFile(f);
                continue;
            }
            f.mu.lockUncancelable(self.io);
            self.purgeArtifacts(f.rel);
            // Same stamp-before-unlock rule as forget: nothing can reach
            // this entry past the map removal, but the invariant "dead is
            // visible to any later file.mu holder" stays universal.
            f.dead.store(true, .release);
            f.mu.unlock(self.io);
            // Same builder-invalidation contract as forget: a get() whose
            // sidecar read raced this purge must not publish its stale bits.
            self.purge_epoch += 1;
            // Our pin is the last reference (store.mu blocked any other
            // taker past the refs==1 check); releaseFile destroys.
            self.releaseFile(f);
        }
    }

    pub fn openCache(self: *Store, file: *Cached) i32 {
        file.mu.lockUncancelable(self.io);
        defer file.mu.unlock(self.io);
        return self.openCacheUnlocked(file);
    }

    /// `hash`, when set, is the digest of the bytes that just landed; it is
    /// recorded alongside the bit so the piece carries a trusted hash from
    /// birth (the fill paths hash the in-hand buffer, so a rehash of the
    /// cache copy later has a reference to compare against). Recording under
    /// the same file.mu window as the bit keeps the two consistent: a punch
    /// or size wipe that clears the bit also invalidates the hash via
    /// clearHashes, and a recorded hash for a piece whose bit never
    /// landed would let a peer fill verify against bytes that were never
    /// written.
    pub fn finishPiece(self: *Store, file: *Cached, idx: u32, ok: bool, hash: ?[piece.digest_len]u8, now_sec: i64) void {
        file.mu.lockUncancelable(self.io);
        defer file.mu.unlock(self.io);
        // A forget that raced this fill removed the entry and unlinked its
        // artifacts while the claim was in flight: drop the claim but
        // persist nothing. Saving here would recreate a sidecar naming
        // filled pieces over a data file that no longer exists.
        if (file.dead.load(.acquire)) {
            _ = file.filling.remove(idx);
            return;
        }
        const gen = file.filling.get(idx);
        _ = file.filling.remove(idx);
        if (ok) {
            // completeFill's pre-I/O skip samples writes under this lock,
            // then drops it for the pwrite. A truncate, distrust, or
            // size reconcile that lands in that window bumps writes (and
            // may have swapped bits). Marking the fill's bytes would
            // publish pre-mutation content over the new inode.
            if (gen) |g| {
                if (g == file.writes) {
                    file.bits.set(idx);
                    // Landing bytes is access. The claim's stamp predates the fill,
                    // so a fill slower than recency_secs would leave this fresh piece
                    // punchable the moment the filling claim cleared, before the
                    // reader's readCache gets its own stamp in.
                    file.last_access.store(now_sec, .monotonic);
                    if (hash) |h| {
                        file.hashes.put(idx, h) catch |err| {
                            std.log.warn("cannot record trusted hash for {s} piece {d} ({t}); piece verifies by refill", .{ file.rel, idx, err });
                        };
                        file.manifest_dirty = true;
                    }
                }
            }
        }
        _ = self.saveBits(file, false);
    }

    /// Outcome of claiming one piece for a fill (the claim/sample contract
    /// both fill paths -- FUSE read hydration and peer /data hydration --
    /// must share, kept here so they cannot drift apart):
    pub const FillClaim = union(enum) {
        /// Already filled, including by a concurrent filler that finished
        /// while we waited on its claim.
        filled,
        /// A truncate shrank the file below this piece: the caller moves on
        /// without treating it as an error or as data; the piece stays
        /// unmarked (a later grow preserves marks, so a bogus bit would
        /// survive).
        raced,
        /// Byte length to fill.
        len: u32,
    };

    /// Claims exclusive fill of piece idx and samples its byte length in one
    /// file.mu window: the bit check, the length sample, and the claim land
    /// together, so a concurrent truncate cannot open a gap where the length
    /// disagrees with the bit finishPiece will set. A persistent allocation
    /// failure surfaces as an error instead of spinning forever: an unbounded
    /// retry here would wedge the reader (FUSE read, peer hydrate) with no
    /// timeout and no signal.
    pub fn beginFill(self: *Store, file: *Cached, idx: u32, now_sec: i64) !FillClaim {
        while (true) {
            file.mu.lockUncancelable(self.io);
            if (file.bits.get(idx)) {
                file.mu.unlock(self.io);
                return .filled;
            }
            if (file.filling.contains(idx)) {
                file.mu.unlock(self.io);
                // Yield through the injected Io, not nanosleep: a simulator
                // can interleave the in-flight filler instead of blocking
                // real time while this claim spins.
                sys.sleepMs(self.io, 2);
                continue;
            }
            file.filling.put(idx, file.writes) catch |err| {
                file.mu.unlock(self.io);
                return err;
            };
            // A fill in flight is access: it must keep punchPiece (which
            // rechecks recency under the same lock) from culling under it.
            file.last_access.store(now_sec, .monotonic);
            const ln = piece.len(file.size, idx, self.piece_size);
            if (ln == 0) {
                // The truncate won: drop the claim unmarked, persist nothing
                // (the bits did not change).
                _ = file.filling.remove(idx);
                file.mu.unlock(self.io);
                return .raced;
            }
            file.mu.unlock(self.io);
            return .{ .len = ln };
        }
    }

    /// Lands one claimed fill: writes buf at the piece offset and marks the
    /// piece only when every byte reached the cache fd, so an unmarked piece
    /// refills instead of serving hole zeros. Returns 0 on success (including
    /// when a local write-through already won the piece or invalidated this
    /// claim), else the negative errno from the write. `now_sec` is the
    /// caller's monotonic instant for the completion stamp (finishPiece).
    /// `hash` is the digest of buf's bytes (callers hash the in-hand buffer
    /// at admit; null for paths that cannot, which leaves the piece without
    /// a trusted hash until an origin fill or the manifest supplies one).
    pub fn completeFill(self: *Store, file: *Cached, idx: u32, buf: []const u8, hash: ?[piece.digest_len]u8, now_sec: i64) i32 {
        file.content_mu.lockUncancelable(self.io);
        defer file.content_mu.unlock(self.io);

        file.mu.lockUncancelable(self.io);
        const skip = blk: {
            if (file.dead.load(.acquire)) break :blk true;
            if (file.bits.get(idx)) break :blk true;
            const gen = file.filling.get(idx) orelse break :blk true;
            if (gen != file.writes) break :blk true;
            break :blk false;
        };
        if (skip) {
            _ = file.filling.remove(idx);
            file.mu.unlock(self.io);
            return 0;
        }
        file.mu.unlock(self.io);

        const w = self.writePiece(file, idx, buf);
        self.finishPiece(file, idx, w == 0, hash, now_sec);
        return w;
    }

    /// True when this node has mutated the path through the mount (or dropped
    /// trust after a write whose post-size could not be observed). Peer
    /// `/have` bits for the path can predate that mutation; hydrates must
    /// take origin bytes rather than resurrect pre-write peer data.
    pub fn wroteLocally(self: *Store, file: *Cached) bool {
        file.mu.lockUncancelable(self.io);
        defer file.mu.unlock(self.io);
        return file.writes != 0;
    }

    pub fn hasPiece(self: *Store, file: *Cached, idx: u32, now_sec: i64) bool {
        file.mu.lockUncancelable(self.io);
        defer file.mu.unlock(self.io);
        // Probing a piece is read intent: stamping under this same lock keeps
        // punchPiece's recency revalidation from holing the piece between
        // this answer and the caller's read of it, including across a
        // multi-piece hydration whose later pieces fill past the window
        // (per-piece claim stamps alone go stale mid-loop).
        file.last_access.store(now_sec, .monotonic);
        return file.bits.get(idx);
    }

    /// Origin-side manifest directory: `<origin>/.cluster/manifests/`. Flat
    /// hex names (piece.manifestName), so no nested directories and no
    /// traversal risk; lease walks and sweeps skip it (no .json/.tmp names,
    /// and walkLeases only parses .json files).
    pub const manifests_dir = ".cluster/manifests";

    /// Upper bound on a manifest blob read from shared storage. A fully
    /// hashed file at the default 16 MiB grid costs 36 bytes per piece, so
    /// this bounds files up to ~28 TiB; anything larger is treated as a
    /// missing manifest (origin fills, no peer verification) rather than an
    /// unbounded allocation from an untrusted artifact.
    pub const max_manifest_bytes: usize = 64 * 1024 * 1024;

    /// `<origin>/.cluster/manifests`.
    pub fn manifestsDirPath(self: *const Store, buf: []u8) ![*:0]u8 {
        return sys.joinZ(buf, self.origin, manifests_dir);
    }

    /// `<origin>/.cluster/manifests/<hex(blake3(rel))>`.
    pub fn manifestPath(self: *const Store, buf: []u8, rel: []const u8) ![*:0]u8 {
        var mname: [2 * piece.digest_len]u8 = undefined;
        const name = piece.manifestName(rel, &mname);
        var mid: [sys.c.PATH_MAX]u8 = undefined;
        const d = try self.manifestsDirPath(&mid);
        return sys.joinZ(buf, std.mem.span(d), name);
    }

    /// Trusted digest for piece idx, or null (the piece then fills from
    /// origin: without a trusted reference its bytes are unverifiable, so
    /// no peer may supply them). Loads the origin manifest lazily, once per
    /// entry size, so a cold entry can verify peer fills without a prior
    /// origin fill. `now_ms` is the caller's monotonic-ms instant: the
    /// retry gate is a pure function of `manifest_retry_at` plus this
    /// sample, so tests drive a transient miss without sleeping (the same
    /// seam haveGet uses for TTL). Caller must not hold file.mu (the load
    /// reads the origin). Returns under a fresh lock; a wipe that raced
    /// the load (size change, same-size rewrite, distrust) bumps `writes`
    /// and clears the map, and tryLoadManifest then refuses to merge so
    /// the lookup misses and the piece origin-fills.
    pub fn expectedHash(self: *Store, file: *Cached, idx: u32, now_ms: i64) ?[piece.digest_len]u8 {
        file.mu.lockUncancelable(self.io);
        if (file.manifest_size == file.size) {
            const h = file.hashes.get(idx);
            file.mu.unlock(self.io);
            return h;
        }
        // A failed load is retried after manifest_retry_ms: the writer
        // publishes the manifest at close, which may land after this node's
        // first fill (and an NFS negative cache can hide it briefly).
        const due = file.manifest_retry_at <= now_ms;
        file.mu.unlock(self.io);
        if (due) self.tryLoadManifest(file, now_ms);
        file.mu.lockUncancelable(self.io);
        defer file.mu.unlock(self.io);
        return file.hashes.get(idx);
    }

    /// Fetches and merges the origin piece-hash manifest for file.rel, once
    /// per entry size. A manifest whose grid, size, or origin identity
    /// disagrees with this node contributes nothing (peer fills stay
    /// unverifiable -> origin); a missing or oversized artifact is the
    /// same. Identity mismatch retries like a missing file: the writer
    /// publishes the new object's trailer at close. The load attempt is
    /// remembered in manifest_size so a failed fetch is not retried on
    /// every miss (the entry's size or the origin artifact can change, and
    /// a fresh entry or size reconcile retries). The origin read sits
    /// outside file.mu; `writes` is sampled first so a wipe that lands
    /// during the read cannot merge the previous object's digests, and a
    /// manifest whose mtime predates `Cached.origin_id` is treated as
    /// transient (the writer has not republished for this identity yet).
    fn tryLoadManifest(self: *Store, file: *Cached, now_ms: i64) void {
        file.mu.lockUncancelable(self.io);
        const gen0 = file.writes;
        file.mu.unlock(self.io);
        var pbuf: [sys.c.PATH_MAX]u8 = undefined;
        const p = self.manifestPath(&pbuf, file.rel) catch {
            // Path-too-long will not shrink; remembering it avoids retrying
            // a join that cannot succeed, but the operator must still see
            // why peer fills for this file stay unverified.
            std.log.warn("piece manifest path does not fit for {s}; peer fills unverified", .{file.rel});
            file.mu.lockUncancelable(self.io);
            file.manifest_size = file.size;
            file.mu.unlock(self.io);
            return;
        };
        var open_errno: i32 = 0;
        const blob = sys.readFileAllocNoFollowOpenErrno(self.gpa, p, max_manifest_bytes, &open_errno) catch |err| switch (err) {
            error.OpenFailed => {
                // ENOENT is the normal "not yet published" reading and stays
                // silent; any other open failure is an origin problem this
                // node will hit again and deserves a line. Both are
                // transient: the writer's close may publish moments later,
                // so retry after manifest_retry_ms instead of remembering
                // the absence for the entry's lifetime.
                if (open_errno != c.ENOENT)
                    std.log.warn("piece manifest open failed for {s} (errno {d}); peer fills unverified", .{ file.rel, open_errno });
                file.mu.lockUncancelable(self.io);
                file.manifest_retry_at = now_ms +| self.manifest_retry_ms;
                file.mu.unlock(self.io);
                return;
            },
            error.FileTooBig => {
                // An oversized artifact will not shrink; remembering it is
                // correct and avoids a 64 MiB read every retry interval.
                std.log.warn("piece manifest oversized for {s}; peer fills unverified", .{file.rel});
                file.mu.lockUncancelable(self.io);
                file.manifest_size = file.size;
                file.mu.unlock(self.io);
                return;
            },
            else => {
                std.log.warn("piece manifest read failed for {s}: {t}; peer fills unverified", .{ file.rel, err });
                file.mu.lockUncancelable(self.io);
                file.manifest_retry_at = now_ms +| self.manifest_retry_ms;
                file.mu.unlock(self.io);
                return;
            },
        };
        defer self.gpa.free(blob);
        const m = piece.manifestDecode(self.gpa, blob) catch {
            // A torn publish heals when the writer retries; retry too.
            std.log.warn("corrupt piece manifest for {s}; peer fills unverified", .{file.rel});
            file.mu.lockUncancelable(self.io);
            file.manifest_retry_at = now_ms +| self.manifest_retry_ms;
            file.mu.unlock(self.io);
            return;
        };
        if (m == null) {
            // The name exists but is not a manifest; retry in case a real
            // manifest lands on the next publish.
            file.mu.lockUncancelable(self.io);
            file.manifest_retry_at = now_ms +| self.manifest_retry_ms;
            file.mu.unlock(self.io);
            return;
        }
        const mf = m.?;
        defer self.gpa.free(mf.entries);
        var mst: c.struct_stat = undefined;
        const have_mtime = sys.lstatPath(p, &mst) == 0;
        // A manifest is only a trust reference when it names THIS file's
        // current size on THIS node's grid; anything else is stale or
        // foreign and must not gate peer fills (a stale manifest would
        // reject the origin's current bytes, which are authoritative).
        file.mu.lockUncancelable(self.io);
        defer file.mu.unlock(self.io);
        if (file.dead.load(.acquire)) return;
        // Same-size rewrite / distrust / truncate bump writes and clear
        // hashes while this load is off the lock. Merging anyway would
        // reinstall the previous object's digests (the blob still names
        // the same file_size) and a peer fill would admit them.
        if (file.writes != gen0) return;
        if (file.size != mf.file_size or self.piece_size != mf.piece_size) {
            file.manifest_size = file.size;
            return;
        }
        // A same-size rewrite leaves the previous object's manifest at
        // this path's hex name. Without the identity trailer that blob
        // still matches grid and size, and its hashes would admit the
        // old peer pieces as the new file. Older manifests omit the
        // trailer and keep that prior behavior until the next publish.
        // Mismatch retries: the writer publishes the new identity at
        // close, the same window a missing manifest waits for.
        if (mf.identity) |raw| {
            const mid = OriginId.read(&raw);
            if (file.origin_id.known and !OriginId.eql(mid, file.origin_id)) {
                file.manifest_retry_at = now_ms +| self.manifest_retry_ms;
                return;
            }
        }
        if (have_mtime and file.origin_id.newerThanMtime(mst)) {
            // Writer has not republished for this identity yet: retry,
            // do not remember the stale blob as "loaded for this size".
            file.manifest_retry_at = now_ms +| self.manifest_retry_ms;
            return;
        }
        // Manifest entries fill gaps only: a local origin fill or
        // write-through is the trust root for that piece, and a later
        // load (or a stale same-size manifest) must not replace it.
        // They must not mark the entry dirty (they already exist on origin).
        // Reserve once: a 70 GiB file is thousands of puts, and each
        // grow would realloc the map under file.mu.
        const extra: u32 = @intCast(@min(mf.entries.len, std.math.maxInt(u32)));
        file.hashes.ensureTotalCapacity(file.hashes.count() +| extra) catch {};
        for (mf.entries) |e| {
            if (file.hashes.contains(e.idx)) continue;
            file.hashes.put(e.idx, e.hash) catch |err| {
                std.log.warn("cannot load trusted hash for {s} piece {d} ({t}); piece verifies by refill", .{ file.rel, e.idx, err });
            };
        }
        file.manifest_size = file.size;
    }

    /// Publishes this entry's trusted hashes to origin as the file's
    /// piece-hash manifest (under .cluster/manifests/). Any node that wrote
    /// the file or filled pieces from origin can publish; readers fetch it
    /// as the trust reference that makes peer fills verifiable. Entries are
    /// filtered to the current size, sorted by idx, and encoded with the
    /// exact codec, so concurrent publishers converge on one blob. A no-op
    /// when nothing changed or nothing is worth publishing. Caller must not
    /// hold file.mu (the write hits the origin); mf_release is the natural
    /// caller. Failure is logged and leaves the flag set so a later release
    /// retries.
    pub fn publishManifest(self: *Store, file: *Cached) void {
        // Snapshot under file.mu, then write outside it: the origin write
        // (NFS) must not pin the entry lock, and the encode reads the map.
        const fsize = blk: {
            file.mu.lockUncancelable(self.io);
            defer file.mu.unlock(self.io);
            if (file.dead.load(.acquire)) return;
            if (!file.manifest_dirty or file.hashes.count() == 0) return;
            break :blk file.size;
        };
        const max_idx = piece.count(fsize, self.piece_size);
        var entries: std.ArrayList(piece.ManifestEntry) = .empty;
        defer entries.deinit(self.gpa);
        // Hash count at snapshot time. The final clear below only drops the
        // dirty flag when the count is unchanged: a digest recorded during
        // the origin write (finishPiece, copyIntoCache) raised the count, so
        // the just-written blob does not hold it and the flag must stay set
        // for the next release to publish it.
        var snap_count: usize = 0;
        var snap_id = OriginId{};
        file.mu.lockUncancelable(self.io);
        {
            defer file.mu.unlock(self.io);
            if (file.dead.load(.acquire)) return;
            if (!file.manifest_dirty) return;
            snap_count = file.hashes.count();
            snap_id = file.origin_id;
            var it = file.hashes.iterator();
            while (it.next()) |e| {
                if (e.key_ptr.* >= max_idx) continue;
                entries.append(self.gpa, .{ .idx = e.key_ptr.*, .hash = e.value_ptr.* }) catch |err| {
                    std.log.warn("piece manifest build failed for {s} ({t}); retried on next close", .{ file.rel, err });
                    return;
                };
            }
        }
        if (entries.items.len == 0) return;
        std.mem.sort(piece.ManifestEntry, entries.items, {}, struct {
            fn lessThan(_: void, a: piece.ManifestEntry, b: piece.ManifestEntry) bool {
                return a.idx < b.idx;
            }
        }.lessThan);
        const id_extra: usize = if (snap_id.known) OriginId.encoded_len else 0;
        const need = piece.manifestLen(entries.items.len) + id_extra;
        const blob = self.gpa.alloc(u8, need) catch |err| {
            std.log.warn("piece manifest build failed for {s} ({t}); retried on next close", .{ file.rel, err });
            return;
        };
        defer self.gpa.free(blob);
        const enc_body = piece.manifestEncode(self.piece_size, fsize, entries.items, blob) catch |err| {
            std.log.warn("piece manifest build failed for {s} ({t}); retried on next close", .{ file.rel, err });
            return;
        };
        const enc: []const u8 = if (!snap_id.known) enc_body else blk: {
            var trailer: [OriginId.encoded_len]u8 = undefined;
            snap_id.write(&trailer);
            @memcpy(blob[enc_body.len..][0..OriginId.encoded_len], &trailer);
            break :blk blob[0..need];
        };

        var pbuf: [sys.c.PATH_MAX]u8 = undefined;
        const p = self.manifestPath(&pbuf, file.rel) catch {
            std.log.warn("piece manifest publish failed for {s}; path does not fit; retried on next close", .{file.rel});
            return;
        };
        var tbuf: [sys.c.PATH_MAX]u8 = undefined;
        const ztmp = sys.appendExt(&tbuf, p, ".tmp") catch {
            std.log.warn("piece manifest publish failed for {s}; temp path does not fit; retried on next close", .{file.rel});
            return;
        };
        var w = sys.writeFileNoFollow(ztmp, enc);
        if (w == -c.ENOENT) {
            // First publish for this file (or after an operator wiped
            // .cluster): create the manifests dir, same lazy-mkdir shape as
            // lease publish (an unconditional mkdirAll would cost one failed
            // mkdir per publish for the life of the cluster).
            var mid: [sys.c.PATH_MAX]u8 = undefined;
            if (self.manifestsDirPath(&mid)) |d| {
                _ = sys.mkdirAll(std.mem.span(d), 0o755);
            } else |_| {}
            w = sys.writeFileNoFollow(ztmp, enc);
        }
        if (w != 0) {
            _ = sys.unlink(ztmp);
            std.log.warn("piece manifest publish failed for {s} (errno {d}); retried on next close", .{ file.rel, -w });
            return;
        }
        const re = sys.rename(ztmp, p);
        if (re != 0) {
            _ = sys.unlink(ztmp);
            std.log.warn("piece manifest rename failed for {s} (errno {d}); retried on next close", .{ file.rel, -re });
            return;
        }
        file.mu.lockUncancelable(self.io);
        defer file.mu.unlock(self.io);
        // Clear the flag only when the hash set is exactly what we just
        // published: a digest recorded during the origin write (snap_count
        // rose) is not in the blob and must ride the next release, so it
        // leaves the flag set instead of being lost forever.
        if (file.dead.load(.acquire)) return;
        if (file.manifest_dirty and file.hashes.count() == snap_count) file.manifest_dirty = false;
    }

    /// Clears a piece's mark after its cached bytes failed at-rest
    /// verification (verifyRange/serveStage), so the next fill re-hydrates
    /// from origin -- the serving node self-heals instead of failing every
    /// serve of the piece until a cull or `modelfs verify`. The bytes are
    /// left in place (no punch): the trusted digest is kept as the refill's
    /// expectation, and the fetching node's own verify-before-admit
    /// (hydratePiece) rejects any torn bytes a concurrent refill could
    /// introduce into an in-flight send. Same lock discipline as
    /// punchPiece: content_mu then file.mu.
    pub fn healPiece(self: *Store, file: *Cached, idx: u32) void {
        file.content_mu.lockUncancelable(self.io);
        defer file.content_mu.unlock(self.io);
        file.mu.lockUncancelable(self.io);
        defer file.mu.unlock(self.io);
        if (file.dead.load(.acquire)) return;
        if (!file.bits.get(idx)) return;
        file.bits.clear(idx);
        _ = self.saveBits(file, false);
    }

    /// Drops every trusted hash and the manifest-load state: a size change
    /// (reconcileSize, cacheFill shrink), distrust, or forget means the old
    /// digests describe bytes that no longer exist and would reject the
    /// origin's current ones. Sets manifest_dirty so the next release
    /// republishes a manifest matching the new state (or drops stale
    /// expectations for a shrunk file). Caller must hold file.mu; mf_truncate
    /// and the size reconcile paths call it under that lock.
    pub fn clearHashes(_: *Store, file: *Cached) void {
        file.hashes.clearRetainingCapacity();
        file.manifest_size = null;
        file.manifest_retry_at = 0;
        file.manifest_dirty = true;
    }

    /// Caller holds file.mu. True when every piece overlapping [off, off+n)
    /// against this size sample is marked filled. The FUSE warm-read path
    /// uses this under the size-sample lock so a fully-cached range skips
    /// ensureRange's per-piece lock round trips. A range the bitfield cannot
    /// name (piece index past u32, after count() clamps) is never filled:
    /// cover() of that tail is empty, which would otherwise look like a hit
    /// and serve hole zeros.
    pub fn rangeFilled(file: *Cached, span: piece.Span, file_size: u64, piece_size: u32) bool {
        if (!piece.rangeTracked(span, file_size, piece_size)) return false;
        const cov = piece.cover(span, file_size, piece_size);
        return file.bits.allSet(cov.start, cov.end);
    }

    /// Writes one piece at its offset. Internal step of completeFill; the
    /// bit that makes the bytes visible is set there on success only.
    fn writePiece(self: *Store, file: *Cached, idx: u32, buf: []const u8) i32 {
        const fd = self.openCache(file);
        if (fd < 0) return fd;
        const off = piece.offset(idx, self.piece_size);
        const n = sys.pwriteAll(fd, buf, off);
        if (n < 0) return @intCast(n);
        sys.fadviseDontneed(fd, off, buf.len);
        return 0;
    }

    /// Claim an in-flight cache-fd transfer. Pair with endXfer. The increment
    /// sits under content_mu so copyIntoCache cannot sample xfer==0 and then
    /// pwrite under a sendfile or FUSE read that started between the load
    /// and the copy. readCache still increments xfer without this lock: it
    /// must be able to land while punchPiece holds content_mu so the
    /// post-saveBits recheck can abort the hole.
    pub fn beginXfer(self: *Store, file: *Cached) void {
        file.content_mu.lockUncancelable(self.io);
        _ = file.xfer.fetchAdd(1, .monotonic);
        file.content_mu.unlock(self.io);
    }

    pub fn endXfer(_: *Store, file: *Cached) void {
        _ = file.xfer.fetchSub(1, .monotonic);
    }

    pub fn readCache(self: *Store, file: *Cached, buf: []u8, off: u64, now_sec: i64) isize {
        // Same in-flight protection serveData gives peer sends: punchPiece
        // must not hole a piece while bytes are being read from the cache fd
        // (the FUSE warm-read path), or the pread lands on the fresh hole and
        // serves zeros behind bits the caller already trusted. The claim is
        // taken before openCache so a read parked on file.mu behind the
        // punch's critical section is already visible to punchPiece's
        // post-save re-check instead of slipping under the hole cut.
        _ = file.xfer.fetchAdd(1, .monotonic);
        defer _ = file.xfer.fetchSub(1, .monotonic);
        const fd = self.openCache(file);
        if (fd < 0) return fd;
        file.last_access.store(now_sec, .monotonic);
        return sys.preadAll(fd, buf, off);
    }

    /// Serves one read range from the cache copy, falling back to the
    /// authoritative origin bytes when the cache tier answers nothing at all
    /// (open or pread failure: broken or full cache fs). The miss path
    /// already degrades to origin service; failing a warm read instead would
    /// turn a dead cache mount into a total read outage for every file with
    /// cached pieces. Each fallback is warned: without the line a silently
    /// degraded node is indistinguishable from normal service.
    ///
    /// Bytes past `piece.trackedEnd` have no bit and a sparse cache pread
    /// returns hole zeros as a successful read, so those ranges go to origin
    /// without touching the cache fd.
    pub fn readServed(self: *Store, file: *Cached, buf: []u8, off: u64, now_sec: i64) isize {
        file.mu.lockUncancelable(self.io);
        const fsize = file.size;
        file.mu.unlock(self.io);
        if (!piece.rangeTracked(.{ .off = off, .len = buf.len }, fsize, self.piece_size))
            return self.originPread(file.rel, buf, off);
        const n = self.readCache(file, buf, off, now_sec);
        if (n >= 0) return n;
        std.log.warn("cache read failed for {s} (errno {d}); serving from origin", .{ file.rel, -n });
        return self.originPread(file.rel, buf, off);
    }

    pub fn originPread(self: *Store, rel: []const u8, buf: []u8, off: u64) isize {
        var path: [sys.c.PATH_MAX]u8 = undefined;
        const p = self.originPath(&path, rel) catch return -c.ENAMETOOLONG;
        // O_NOFOLLOW: a symlink planted at this name on the shared origin
        // would otherwise have the daemon read the link's target (resolved
        // client-side) and serve those bytes to peers. ELOOP fails closed.
        // O_NONBLOCK: a FIFO at the name must not hang a FUSE worker or
        // peer /data hydration (same contract as lease reads); ignored on
        // regular files.
        const fd = sys.open(p, c.O_RDONLY | c.O_NOFOLLOW | c.O_NONBLOCK, 0);
        if (fd < 0) {
            const rc = sys.negErrno();
            self.noteOriginIo(rel, rc, "read");
            return rc;
        }
        defer sys.close(fd);
        const n = sys.preadAll(fd, buf, off);
        self.noteOriginIo(rel, if (n < 0) @intCast(n) else 0, "read");
        return n;
    }

    pub fn originPwrite(self: *Store, rel: []const u8, buf: []const u8, off: u64) isize {
        var path: [sys.c.PATH_MAX]u8 = undefined;
        const p = self.originPath(&path, rel) catch return -c.ENAMETOOLONG;
        // Same O_NOFOLLOW contract as every other daemon write into a tree
        // someone else can plant names in (writeFileNoFollow, openCache): a
        // planted symlink must not redirect this truncate-and-write onto an
        // arbitrary daemon-writable file. O_NONBLOCK: a FIFO at the name
        // must not hang the FUSE write path; O_WRONLY of a reader-less
        // FIFO then fails ENXIO instead of blocking.
        const fd = sys.open(p, c.O_WRONLY | c.O_NOFOLLOW | c.O_NONBLOCK, 0);
        if (fd < 0) {
            const rc = sys.negErrno();
            self.noteOriginIo(rel, rc, "write");
            return rc;
        }
        const n = sys.pwriteAll(fd, buf, off);
        const cr = sys.closeWrite(fd);
        const rc: i32 = if (n < 0) @intCast(n) else if (cr != 0) cr else 0;
        self.noteOriginIo(rel, rc, "write");
        if (n < 0) return n;
        if (cr != 0) return @intCast(cr);
        return n;
    }

    /// fsync/fdatasync the origin name. FUSE's default ENOSYS for an
    /// unwired `fsync` is converted to success by the kernel (`no_fsync`),
    /// so an ingest that called fsync would report durability without an
    /// NFS COMMIT. Open is O_RDONLY: COMMIT is per-inode, and a reader
    /// must be able to fsync a file it cannot write. O_NOFOLLOW / O_NONBLOCK
    /// match originPread (planted symlink, FIFO).
    pub fn originFsync(self: *Store, rel: []const u8, data_only: bool) i32 {
        var path: [sys.c.PATH_MAX]u8 = undefined;
        const p = self.originPath(&path, rel) catch return -c.ENAMETOOLONG;
        const what: []const u8 = if (data_only) "fdatasync" else "fsync";
        const fd = sys.open(p, c.O_RDONLY | c.O_NOFOLLOW | c.O_NONBLOCK, 0);
        if (fd < 0) {
            const rc = sys.negErrno();
            self.noteOriginIo(rel, rc, what);
            return rc;
        }
        const sc = if (data_only) sys.fdatasync(fd) else sys.fsync(fd);
        sys.close(fd);
        self.noteOriginIo(rel, sc, what);
        return sc;
    }

    /// Filesystem stats for the origin name. A planted final symlink would
    /// otherwise make statvfs(2) report the target's filesystem (df of a
    /// link to `/` leaks the host root's size/free through the mount).
    /// ELOOP matches originPread/originPwrite: open O_NOFOLLOW, not lstat
    /// then statvfs, so a racer cannot swap the name to a link in between.
    pub fn originStatvfs(self: *const Store, rel: []const u8, vs: *c.struct_statvfs) i32 {
        var buf: [sys.c.PATH_MAX]u8 = undefined;
        const p = self.originPath(&buf, rel) catch return -c.ENAMETOOLONG;
        return sys.statvfsNoFollow(p, vs);
    }

    /// Origin unlink plus cache-identity drop, with FUSE-retry semantics.
    /// Forget runs even when the origin name is already gone: a FUSE retry
    /// after the first attempt unlinked then crashed (or lost the reply)
    /// would otherwise leave data/meta/pin in place, and a same-size
    /// recreate would serve the deleted file's bytes. Forget also runs
    /// before the unlink so a crash between the two steps cannot leave a
    /// filled sidecar over a name that is already gone. The empty rel
    /// (FUSE "/") is the origin root itself and is not a cache key --
    /// skipping forget there keeps unlink of the mount root from targeting
    /// cache/data. A lost reply after a successful unlink is retried as
    /// ENOENT; if the name is already gone the second call is success,
    /// matching one unlink (and rmdirOrigin). A directory at that name
    /// stays EISDIR, the origin's own POSIX answer.
    pub fn unlinkOrigin(self: *Store, rel: []const u8) i32 {
        var buf: [sys.c.PATH_MAX]u8 = undefined;
        const op = self.originPath(&buf, rel) catch return -c.ENAMETOOLONG;
        if (rel.len != 0) self.forget(rel);
        const rc = sys.unlink(op);
        // A racer's get() between the first forget and the unlink may have
        // rebuilt an entry over the still-live origin name; drop it now that
        // the name is gone (or was already gone).
        if (rel.len != 0) self.forget(rel);
        if (rc == -c.ENOENT) return 0;
        return rc;
    }

    /// Origin rename plus cache-identity drop of both names. Flags ride
    /// through to renameat2 (RENAME_NOREPLACE/EXCHANGE) so the origin's own
    /// semantics answer, matching mf_rename. Forget runs before and after
    /// the origin rename, and on every errno including ENOENT, so a retry
    /// after a completed rename cannot leave either name's sidecar
    /// describing the pre-rename inode. Empty names are not cache keys
    /// (same mount-root skip as unlinkOrigin). The origin errno is returned
    /// as-is.
    pub fn renameOrigin(self: *Store, orel: []const u8, nrel: []const u8, flags: c_uint) i32 {
        var a: [sys.c.PATH_MAX]u8 = undefined;
        var b: [sys.c.PATH_MAX]u8 = undefined;
        const oa = self.originPath(&a, orel) catch return -c.ENAMETOOLONG;
        const ob = self.originPath(&b, nrel) catch return -c.ENAMETOOLONG;
        if (!std.mem.eql(u8, orel, nrel)) {
            if (orel.len != 0) self.forget(orel);
            if (nrel.len != 0) self.forget(nrel);
        }
        const rc = c.renameat2(c.AT_FDCWD, oa, c.AT_FDCWD, ob, flags);
        const e: i32 = if (rc != 0) sys.errno() else 0;
        if (!std.mem.eql(u8, orel, nrel)) {
            if (orel.len != 0) self.forget(orel);
            if (nrel.len != 0) self.forget(nrel);
        }
        if (e != 0) return -e;
        return 0;
    }

    /// Origin mkdir with FUSE-retry semantics. A lost reply after a
    /// successful mkdir is retried as EEXIST; if the name is already a
    /// directory the second call is success, matching one mkdir. A
    /// non-directory at that name (file, symlink) stays EEXIST, the
    /// origin's own POSIX answer. Empty rel is the origin root: mkdir of
    /// an existing directory still converges.
    pub fn mkdirOrigin(self: *const Store, rel: []const u8, mode: c.mode_t) i32 {
        var buf: [sys.c.PATH_MAX]u8 = undefined;
        const op = self.originPath(&buf, rel) catch return -c.ENAMETOOLONG;
        const rc = sys.mkdir(op, mode);
        if (rc != -c.EEXIST) return rc;
        var lst: c.struct_stat = undefined;
        if (sys.lstatPath(op, &lst) != 0) return rc;
        if ((lst.st_mode & c.S_IFMT) == c.S_IFDIR) return 0;
        return rc;
    }

    /// Origin rmdir with FUSE-retry semantics. A lost reply after a
    /// successful rmdir is retried as ENOENT; if the name is already gone
    /// the second call is success, matching one rmdir. A non-directory at
    /// that name stays ENOTDIR and a non-empty directory stays ENOTEMPTY,
    /// the origin's own POSIX answers. Empty rel is the origin root and
    /// is EBUSY: rmdir of FUSE "/" must not delete the export.
    pub fn rmdirOrigin(self: *const Store, rel: []const u8) i32 {
        if (rel.len == 0) return -c.EBUSY;
        var buf: [sys.c.PATH_MAX]u8 = undefined;
        const op = self.originPath(&buf, rel) catch return -c.ENAMETOOLONG;
        const rc = sys.rmdir(op);
        if (rc == -c.ENOENT) return 0;
        return rc;
    }

    /// Copies bytes this node just wrote through the mount into the local
    /// cache and marks the pieces they fully span. The entry is grown with
    /// its piece marks preserved: an append is our own write, not an external
    /// rewrite, so reconcileSize's wipe-on-size-change reset must not fire
    /// here (it would discard every earlier chunk's cached pieces on a
    /// sequential ingest). Call only when the observed origin size equals
    /// `end`; any other size goes through get()'s conservative reset.
    pub fn cacheFill(self: *Store, rel: []const u8, end: u64, off: u64, data: []const u8, now_sec: i64) void {
        self.cacheFillIdentified(rel, end, off, data, OriginId{}, now_sec);
    }

    /// Like cacheFill(), recording the post-write origin identity so a later
    /// getIdentified does not treat this node's own write as a foreign
    /// rewrite (NFS mtime lag is ignored: an older stamp is not adopted).
    pub fn cacheFillIdentified(self: *Store, rel: []const u8, end: u64, off: u64, data: []const u8, origin_id: OriginId, now_sec: i64) void {
        const file = blk: {
            if (self.lookupRef(rel)) |f| break :blk f;
            break :blk self.getIdentified(rel, end, origin_id, now_sec) catch {
                // Same contract as copyIntoCache's failures: say why reads
                // will fall back to origin instead of skipping silently.
                std.log.warn("cache fill skipped for {s} (no cache entry); reads fall back to origin", .{rel});
                return;
            };
        };
        defer self.releaseFile(file);

        // Size mutation takes content_mu then file.mu, matching reconcileSize
        // and mf_truncate, then drops both before copyIntoCache (which takes
        // the same pair). A shrink that took only file.mu let completeFill
        // pwrite between the bit swap and the copy, then mark pre-shrink
        // bytes on the new field because writes was not bumped.
        var dropped: ?piece.Bitfield = null;
        defer if (dropped) |*ob| ob.deinit(self.gpa);
        {
            file.content_mu.lockUncancelable(self.io);
            defer file.content_mu.unlock(self.io);
            file.mu.lockUncancelable(self.io);
            defer file.mu.unlock(self.io);
            if (end > file.size) {
                // Our own append: earlier piece marks stay valid.
                file.bits.resize(self.gpa, piece.count(end, self.piece_size)) catch {
                    // OOM leaves the field undersized: appended pieces stay
                    // unmarked and re-hydrate instead of serving hole zeros.
                    std.log.warn("bitfield grow failed for {s}; appended pieces refill", .{rel});
                };
                file.size = end;
            } else if (end < file.size) {
                // Entry is longer than the observed origin: someone truncated
                // externally. Reset like reconcileSize instead of keeping marks
                // for bytes past the new end, and persist the reset like it does:
                // the old sidecar's recorded size decodes cleanly again once the
                // file is back at that length, which would resurrect pre-shrink
                // marks over new content after a crash. writes++ invalidates a
                // fill claimed against the old generation; truncateCacheFd
                // cuts the tail the same way reconcileSize does.
                if (piece.Bitfield.init(self.gpa, piece.count(end, self.piece_size))) |nb| {
                    dropped = file.bits;
                    file.bits = nb;
                    file.size = end;
                    file.writes += 1;
                    // Same digest wipe as reconcileSize: the shrink invalidates
                    // every expectation, not just the tail's.
                    self.clearHashes(file);
                    truncateCacheFd(file, end);
                    _ = self.saveBits(file, false);
                } else |_| {
                    std.log.warn("bitfield shrink failed for {s}; stale tail pieces refill", .{rel});
                }
            }
            file.last_access.store(now_sec, .monotonic);
            // Own write: adopt a newer/unknown identity so the next
            // getIdentified does not wipe the copy we are about to mark.
            // An older mtime on the same ino is NFS lag and is ignored.
            if (origin_id.known and (!file.origin_id.known or OriginId.contentChanged(file.origin_id, origin_id)))
                file.origin_id = origin_id;
        }

        _ = self.copyIntoCache(file, off, data);
    }

    /// Records a post-write origin identity on a live entry without wiping
    /// marks. Same-ino older mtime is NFS lag and is ignored.
    pub fn noteOriginId(self: *Store, file: *Cached, id: OriginId) void {
        if (!id.known) return;
        file.mu.lockUncancelable(self.io);
        defer file.mu.unlock(self.io);
        if (!file.origin_id.known or OriginId.contentChanged(file.origin_id, id)) {
            file.origin_id = id;
            _ = self.saveBits(file, false);
        }
    }

    /// Copies a landed origin write into the cache fd and marks the pieces it
    /// fully spans, so reads serve the copy instead of re-hydrating over NFS.
    /// A retry whose fully-covered pieces are already marked re-pwrites but
    /// does not bump the write generation or rewrite the sidecar: the copy
    /// is already applied. Returns false when the copy did not land or
    /// pieces could not be marked; overlapping marks are then cleared so a
    /// warm read or `/have` cannot serve pre-write cache bytes, and those
    /// pieces refill from origin.
    /// The copy never truncates the cache fd: concurrent fills of one entry
    /// land overlapping appends outside any shared lock, and an absolute
    /// ftruncate here could shrink the shared descriptor below bytes another
    /// writer had already committed, leaving filled bits naming holes it cut.
    /// pwrite extends the fd to its own end by itself, so growth needs no
    /// truncate; a fresh openCache sizes the descriptor under file.mu.
    /// A peer sendfile or FUSE read holds xfer across the cache fd; pwrite
    /// under that transfer mixes new bytes into the in-flight copy. Skip
    /// the pwrite then: a retry of bytes already in the cache (matching
    /// hashes) is a no-op, and any other overlapping range is unmarked so
    /// readers refill from origin.
    pub fn copyIntoCache(self: *Store, file: *Cached, off: u64, data: []const u8) bool {
        file.content_mu.lockUncancelable(self.io);
        defer file.content_mu.unlock(self.io);

        const busy = file.xfer.load(.monotonic) != 0;
        var copied = false;
        if (!busy) {
            const cfd = self.openCache(file);
            if (cfd < 0) {
                std.log.warn("cache fill skipped for {s} (errno {d}); reads fall back to origin", .{ file.rel, -cfd });
            } else {
                const w = sys.pwriteAll(cfd, data, off);
                if (w != @as(isize, @intCast(data.len))) {
                    std.log.warn("cache fill failed for {s} (errno {d}); reads fall back to origin", .{ file.rel, -w });
                } else {
                    sys.fadviseDontneed(cfd, off, data.len);
                    copied = true;
                }
            }
        }
        // Marking, the write generation, and the sidecar save share file.mu:
        // saveBits encodes size/bits, and a concurrent truncate may swap and
        // free them. Bump writes even when the cache copy failed: the origin
        // already has the new bytes, and a later peer fill would resurrect
        // pre-write content.
        file.mu.lockUncancelable(self.io);
        defer file.mu.unlock(self.io);
        // Same dead-entry contract as finishPiece: a forget that raced this
        // write-through unlinked these artifacts; marking plus saving would
        // resurrect a sidecar claiming filled pieces over missing bytes.
        if (file.dead.load(.acquire)) return false;
        const cov = piece.fullCover(.{ .off = off, .len = data.len }, self.piece_size);
        // Already applied: every fully-covered piece is marked. A FUSE
        // retry after a lost reply re-pwrites the same bytes; bumping
        // writes again would drop in-flight fills of other pieces, and
        // rewriting the sidecar is a mutation a punch round could observe.
        // Partial writes (empty fullCover) still bump: they must invalidate
        // an in-flight fill of the overlapping piece so it cannot overwrite
        // the patch with stale whole-piece bytes. But "all marked" cannot
        // tell a retry from a same-size rewrite: re-hash the in-hand
        // buffer against the recorded digests. Unchanged keeps the fast
        // path (including when xfer blocked the pwrite: the cache already
        // holds these bytes); changed falls through so the writes bump.
        if (cov.start < cov.end) {
            if (file.bits.allSet(cov.start, cov.end)) {
                var changed = false;
                var i = cov.start;
                while (i < cov.end) : (i += 1) {
                    const in_data = piece.offset(i, self.piece_size) - off;
                    var h: [piece.digest_len]u8 = undefined;
                    piece.digest(data[@intCast(in_data)..][0..self.piece_size], &h);
                    if (file.hashes.get(i)) |old| {
                        if (!std.mem.eql(u8, &h, &old)) {
                            changed = true;
                            break;
                        }
                    } else {
                        changed = true;
                        break;
                    }
                }
                if (!changed) return true;
            }
        }
        if (copied) {
            file.writes += 1;
            // Trusted hashes for the fully-covered pieces: the write buffer
            // holds exactly their bytes (fullCover), so each digest is the
            // piece's content identity without a cache readback. Boundary
            // pieces are only partially covered: their cached content is now
            // a mix of old and new bytes, so their previous digest no longer
            // describes them and must not gate a refill.
            const span = piece.cover(.{ .off = off, .len = data.len }, file.size, self.piece_size);
            var i = cov.start;
            while (i < cov.end) : (i += 1) {
                file.bits.set(i);
                const in_data = piece.offset(i, self.piece_size) - off;
                var h: [piece.digest_len]u8 = undefined;
                piece.digest(data[@intCast(in_data)..][0..self.piece_size], &h);
                file.hashes.put(i, h) catch |err| {
                    std.log.warn("cannot record trusted hash for {s} piece {d} ({t}); piece verifies by refill", .{ file.rel, i, err });
                };
                file.manifest_dirty = true;
            }
            i = span.start;
            while (i < span.end) : (i += 1) {
                if (i >= cov.start and i < cov.end) continue;
                if (file.hashes.remove(i)) file.manifest_dirty = true;
            }
        } else {
            // Origin has the new bytes; this node's cache does not. writes
            // already forces peer fills onto origin, but a hit of an already
            // marked piece skips hydration and would serve the pre-write
            // cache copy -- and /have would advertise it to the fleet.
            file.writes += 1;
            const overlap = piece.cover(.{ .off = off, .len = data.len }, file.size, self.piece_size);
            var i = overlap.start;
            while (i < overlap.end) : (i += 1) {
                file.bits.clear(i);
                // The covered pieces' digests described pre-write bytes; the
                // refill that follows records fresh ones.
                if (file.hashes.remove(i)) file.manifest_dirty = true;
            }
        }
        _ = self.saveBits(file, false);
        return copied;
    }

    /// Null when the cache filesystem cannot be stat'ed; callers must not
    /// read that as "plenty free" without saying so.
    pub fn freePercentChecked(self: *const Store) ?u32 {
        var vs: c.struct_statvfs = undefined;
        var z: [sys.c.PATH_MAX]u8 = undefined;
        const p = sys.toZ(&z, self.cache) catch return null;
        if (sys.statvfsPath(p, &vs) != 0) return null;
        return cull.freePercent(@as(u64, vs.f_bavail), @as(u64, vs.f_blocks));
    }

    /// Punches piece idx when it may be culled at instant `now_sec`. The
    /// caller's monotonic instant keeps the decision a pure function of
    /// entry state plus time, drivable virtually in tests; cull drivers
    /// sample sys.monoSec(io) once per round. Holds content_mu across the
    /// hole so a concurrent copyIntoCache cannot mark bytes this punch cut.
    pub fn punchPiece(self: *Store, file: *Cached, idx: u32, now_sec: i64) bool {
        // content_mu first, then file.mu: the same order copyIntoCache and
        // completeFill use. Taking only file.mu let a punch hole a piece
        // between copyIntoCache's pwrite and mark, after which the mark
        // published hole zeros as cached model data.
        file.content_mu.lockUncancelable(self.io);
        defer file.content_mu.unlock(self.io);
        file.mu.lockUncancelable(self.io);
        defer file.mu.unlock(self.io);
        // Revalidate recency under the file lock: cullOne picked this file on
        // a >=10s idle sample, but a read, fill, or peer transfer may have
        // started since (its stamp lands under this same lock). Punching a
        // piece mid-transfer would serve hole zeros and the peer would mark
        // them filled.
        if (now_sec -| file.last_access.load(.monotonic) < recency_secs) return false;
        if (self.pinExists(file.rel)) return false;
        // A fill still writing this piece: punching now would ship hole
        // zeros the same way a mid-send punch would, and completeFill would
        // then mark them filled.
        if (file.filling.contains(idx)) return false;
        // Bytes of this entry may be mid-send to a fetching peer (stalled
        // socket, multi-piece response): punching now ships hole zeros that
        // the peer cannot tell from real data and will mark filled.
        if (file.xfer.load(.monotonic) != 0) return false;
        if (!file.bits.get(idx)) return false;
        const fd = if (file.cache_fd >= 0) file.cache_fd else self.openCacheUnlocked(file);
        if (fd < 0) {
            std.log.warn("piece punch skipped for {s} piece {d} (cache open errno {d}); piece stays cached", .{ file.rel, idx, -fd });
            return false;
        }
        const off = piece.offset(idx, self.piece_size);
        const ln = piece.len(file.size, idx, self.piece_size);
        // Write-ahead order: the cleared mark must be durable before the hole
        // exists. Hole first, persist second, a crash between the two leaves
        // the sidecar claiming filled over punched bytes, and post-restart
        // reads serve hole zeros as cached model data -- the one corruption
        // every other guard in this file exists to prevent. The save below is
        // fsync'ed (durable=true), so "persisted" means on stable storage, not
        // merely handed to delayed allocation: every crash point is safe.
        // Cleared bits over intact bytes merely refill; only a completed
        // durable save authorizes the punch.
        file.bits.clear(idx);
        if (!self.saveBits(file, true)) {
            // The on-disk sidecar still says filled; keep bytes and mark.
            file.bits.set(idx);
            _ = self.saveBits(file, false);
            return false;
        }
        // A cache read (FUSE warm read) that started while the durable save
        // ran is now visible via xfer: the recency re-check at the top of
        // this function predates the save (which can stall on fsync), and a
        // read landing during it would otherwise pread the hole about to be
        // cut here. The cut is deferred, not lost: the read's drop lets the
        // next cull round finish the job.
        if (file.xfer.load(.monotonic) != 0) {
            file.bits.set(idx);
            _ = self.saveBits(file, false);
            return false;
        }
        const punched = sys.punchHole(fd, off, ln);
        if (punched != 0) {
            // Bytes stay: restore the mark in memory and on disk so reads
            // keep serving the cached copy and LRU state stays truthful.
            std.log.warn("piece punch failed for {s} piece {d} (errno {d}); mark restored", .{ file.rel, idx, -punched });
            file.bits.set(idx);
            _ = self.saveBits(file, false);
            return false;
        }
        // Counted, not logged: sustained culling evicts one piece per round,
        // and a per-piece info line floods the journal; the total lands in
        // status.json and the discovery tick's summary instead.
        _ = self.stats.pieces_culled.fetchAdd(1, .monotonic);
        return true;
    }

    /// Caller holds file.mu. Cuts the live cache descriptor to `new_size`
    /// unless a peer /data send is streaming from it: ftruncate would punch
    /// holes under sendfile and the fetching peer would mark those zeros
    /// filled. xfer is held across that send (serveData); a later truncate
    /// or a reopen after reapIdle closed the fd still applies the cut.
    pub fn truncateCacheFd(file: *Cached, new_size: u64) void {
        if (file.cache_fd >= 0 and file.xfer.load(.monotonic) == 0) {
            const tr = sys.ftruncate(file.cache_fd, new_size);
            if (tr != 0)
                std.log.warn("cache truncate failed for {s} (errno {d}); unmarked pieces refill", .{ file.rel, -tr });
        }
    }

    /// Caller must hold file.mu.
    fn openCacheUnlocked(self: *Store, file: *Cached) i32 {
        if (file.cache_fd >= 0) return file.cache_fd;
        var buf: [sys.c.PATH_MAX]u8 = undefined;
        const p = self.cacheDataPath(&buf, file.rel) catch return -c.ENAMETOOLONG;
        const parent = sys.parentOf(std.mem.span(p));
        // O_NOFOLLOW on the data file: it is opened O_RDWR|O_CREAT and then
        // ftruncate'd/pwritten, so a symlink planted at this name in a
        // writable cache tree would turn the daemon into an arbitrary-file
        // truncate/write primitive. The parent directory is created only when
        // the first open misses it (same shape as writeFileMakingParent): a
        // reopen after the reaper closed the fd pays no mkdir walk.
        var fd = sys.open(p, c.O_RDWR | c.O_CREAT | c.O_NOFOLLOW, cache_data_mode);
        if (fd < 0 and sys.errno() == c.ENOENT) {
            _ = sys.mkdirAll(parent, cache_dir_mode);
            fd = sys.open(p, c.O_RDWR | c.O_CREAT | c.O_NOFOLLOW, cache_data_mode);
        }
        if (fd < 0) return sys.negErrno();
        // O_CREAT's mode is ignored when the name already exists, so a
        // leftover 0644 data file from an older daemon is tightened here.
        _ = c.fchmod(fd, cache_data_mode);
        if (sys.ftruncate(fd, file.size) != 0) {
            const e = sys.negErrno();
            sys.close(fd);
            return e;
        }
        file.cache_fd = fd;
        return fd;
    }

    /// In-memory LRU sample size. cullOne only punches one piece per round,
    /// so collecting every idle file allocated and sorted O(files) and pinned
    /// them all until the punch finished. 32 oldest is large enough that a
    /// handful of pinned or empty entries cannot hide a punchable victim,
    /// and small enough that the pins and the insertion walk stay bounded.
    const idle_sample_cap: usize = 32;

    const IdleCand = struct { f: *Cached, at: i64 };

    fn idleOlder(at: i64, rel: []const u8, b: IdleCand) bool {
        if (at != b.at) return at < b.at;
        return std.mem.order(u8, rel, b.f.rel) == .lt;
    }

    /// Inserts one idle live entry into the oldest-first sample, replacing
    /// the youngest when full. True when `f` occupies a slot (its pin stays);
    /// false when it lost to the current sample (caller drops the pin).
    fn considerIdle(cands: *[idle_sample_cap]IdleCand, count: *usize, f: *Cached, at: i64) bool {
        const slot = if (count.* < idle_sample_cap) blk: {
            const s = count.*;
            count.* += 1;
            break :blk s;
        } else blk: {
            if (!idleOlder(at, f.rel, cands[idle_sample_cap - 1])) return false;
            const evicted = cands[idle_sample_cap - 1].f;
            _ = evicted.refs.fetchSub(1, .monotonic);
            break :blk idle_sample_cap - 1;
        };
        cands[slot] = .{ .f = f, .at = at };
        var i = slot;
        while (i > 0 and idleOlder(cands[i].at, cands[i].f.rel, cands[i - 1])) {
            std.mem.swap(IdleCand, &cands[i], &cands[i - 1]);
            i -= 1;
        }
        return true;
    }

    /// Punch one LRU unpinned piece. Returns false if nothing to cull.
    /// `now_sec` is the caller's monotonic instant (see punchPiece).
    pub fn cullOne(self: *Store, now_sec: i64) bool {
        // Idle time is elapsed time: monotonic clock, immune to NTP steps.
        var cands: [idle_sample_cap]IdleCand = undefined;
        var n: usize = 0;
        // Phase 1 under store.mu is memory-only: an atomic last_access load
        // plus a reference pin per sampled idle entry. Stat'ing pin files
        // and probing bits here used to hold this global lock -- which every
        // get() and lookupRef() takes -- behind O(files) disk I/O on every
        // cull round. The sample is bounded: a node caching thousands of
        // idle models must not allocate and pin the whole map to punch one
        // piece.
        self.mu.lockUncancelable(self.io);
        var it = self.files.iterator();
        while (it.next()) |e| {
            const f = e.value_ptr.*;
            const at = f.last_access.load(.monotonic);
            if (now_sec -| at < recency_secs) continue;
            _ = f.refs.fetchAdd(1, .monotonic);
            if (!considerIdle(&cands, &n, f, at))
                _ = f.refs.fetchSub(1, .monotonic);
        }
        self.mu.unlock(self.io);
        defer for (cands[0..n]) |cd| self.releaseFile(cd.f);

        // Phase 2 runs outside every lock, LRU first: punchPiece revalidates
        // recency, pin, mid-fill, and bit state under content_mu then
        // file.mu, so a stale sample only wastes one attempt before the next
        // candidate. Equal-recency ties break by rel bytes: map iteration
        // order must not decide which of several equally idle files is
        // culled first.
        for (cands[0..n]) |cd| {
            if (self.pinExists(cd.f.rel)) continue;
            const idx = blk: {
                cd.f.mu.lockUncancelable(self.io);
                defer cd.f.mu.unlock(self.io);
                break :blk cd.f.bits.lastSet();
            } orelse continue;
            if (self.punchPiece(cd.f, idx, now_sec)) return true;
        }
        return self.cullOneOnDisk(now_sec);
    }

    /// One disk-only cull candidate sampled by walkData.
    const DiskVictim = struct {
        rel: [sys.c.PATH_MAX]u8,
        len: usize,
        at: i64,
    };

    /// Disk-only victims one data-tree walk samples. The walk costs
    /// O(cache files) readdir+stat calls; sampling several lets cullOneOnDisk
    /// punch one piece per victim before walking again, so sustained culling
    /// pays the scan once per batch instead of once per punched piece.
    const walk_sample_cap: usize = 8;

    fn cullOneOnDisk(self: *Store, now_sec: i64) bool {
        var data: [sys.c.PATH_MAX]u8 = undefined;
        const root = sys.joinZ(&data, self.cache, "data") catch return false;
        var victims: [walk_sample_cap]DiskVictim = undefined;
        var count: usize = 0;
        self.walkData(std.mem.span(root), "", &victims, &count, 0);
        // Oldest first: one LRU punch per sampled victim. punchPiece and
        // punchDisk revalidate pin, mid-fill, and bit state under their own
        // locks, so a stale sample wastes one attempt before the next
        // candidate instead of ending the round.
        var punched = false;
        for (victims[0..count]) |*v| {
            const rel = v.rel[0..v.len];
            const live = self.lookupRef(rel) orelse {
                punched = self.punchDisk(rel) or punched;
                continue;
            };
            defer self.releaseFile(live);
            live.mu.lockUncancelable(self.io);
            const idx = live.bits.lastSet();
            live.mu.unlock(self.io);
            if (idx) |i| punched = self.punchPiece(live, i, now_sec) or punched;
        }
        return punched;
    }

    /// True when (at, len, rel) names an older cull candidate than the
    /// sampled one: mtime ascending, then the same tie-break the single-best
    /// scan used (shorter rel wins an mtime tie), then rel bytes. The full
    /// order keeps the victim sample a function of durable state alone;
    /// stopping at (at, len) would let readdir arrival order decide which of
    /// several same-size same-mtime orphans the sample holds.
    fn victimOlder(at: i64, len: usize, rel: []const u8, v: *const DiskVictim) bool {
        if (at != v.at) return at < v.at;
        if (len != v.len) return len < v.len;
        return std.mem.order(u8, rel, v.rel[0..v.len]) == .lt;
    }

    /// Inserts one candidate into the oldest-first victim sample, replacing
    /// the youngest when full. A candidate that does not beat the current
    /// worst entry leaves the sample untouched.
    fn considerVictim(victims: *[walk_sample_cap]DiskVictim, count: *usize, nrel: []const u8, at: i64) void {
        const slot = if (count.* < walk_sample_cap) blk: {
            const s = count.*;
            count.* += 1;
            break :blk s;
        } else blk: {
            if (!victimOlder(at, nrel.len, nrel, &victims[walk_sample_cap - 1])) return;
            break :blk walk_sample_cap - 1;
        };
        const v = &victims[slot];
        v.at = at;
        v.len = nrel.len;
        @memcpy(v.rel[0..nrel.len], nrel);
        var i = slot;
        while (i > 0 and victimOlder(victims[i].at, victims[i].len, victims[i].rel[0..victims[i].len], &victims[i - 1])) {
            std.mem.swap(DiskVictim, &victims[i], &victims[i - 1]);
            i -= 1;
        }
    }

    /// Deepest data/<a>/<b>/... nesting the on-disk cull scan will enter.
    /// Entries are sampled with lstat (no final-symlink follow): a symlink
    /// planted in a writable cache tree must neither be descended into as a
    /// directory nor sampled as a cull victim, or punchDisk would resolve
    /// rels whose INTERMEDIATE components leave the tree and fallocate-hole
    /// an arbitrary daemon-writable file outside the cache. Past the depth
    /// bound entries are simply invisible to disk culling.
    const walk_max_depth: u32 = 64;

    fn walkData(self: *Store, dir_path: []const u8, rel: []const u8, victims: *[walk_sample_cap]DiskVictim, count: *usize, depth: u32) void {
        if (depth >= walk_max_depth) return;
        var z: [sys.c.PATH_MAX]u8 = undefined;
        const dz = sys.toZ(&z, dir_path) catch return;
        // O_NOFOLLOW: lstat of a child can see S_IFDIR then a racer swap
        // the name to a symlink before this opendir; following would list
        // (and consider as cull victims) names under the target.
        const dir = sys.opendirNoFollow(dz) orelse return;
        defer sys.closedir(dir);
        while (sys.readdir(dir)) |ent| {
            const name = sys.dirName(ent);
            // Skip the directory's own `.` / `..` only. relOk allows a
            // leading-dot component (`.hidden.gguf`, `dir/.cache/w.bin`),
            // and those files occupy cache blocks like any other: treating
            // every `.*` name as non-cache would leave them invisible to
            // disk culling after a restart, filling the cache fs past the
            // watermarks. Lease walks skip every leading-dot name because
            // validId refuses those ids; this tree is user paths.
            if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            // Same component gate FUSE readdir uses: a planted cache name
            // with a newline or ZWSP is not a path this daemon would create,
            // and joining it would put control bytes in a cull-victim rel.
            if (!relOk(name)) continue;
            var child: [sys.c.PATH_MAX]u8 = undefined;
            const cp = sys.joinZ(&child, dir_path, name) catch continue;
            var st: c.struct_stat = undefined;
            if (sys.lstatPath(cp, &st) != 0) continue;
            var nrel_buf: [sys.c.PATH_MAX]u8 = undefined;
            const nrel_z = if (rel.len == 0)
                sys.toZ(&nrel_buf, name) catch continue
            else
                sys.joinZ(&nrel_buf, rel, name) catch continue;
            const nrel = std.mem.span(nrel_z);
            if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) {
                self.walkData(std.mem.span(cp), nrel, victims, count, depth + 1);
                continue;
            }
            if ((st.st_mode & c.S_IFMT) != c.S_IFREG) continue;
            if (st.st_blocks == 0) continue;
            // Once the sample is full, considerVictim would discard any
            // candidate that does not beat the youngest sampled entry (same
            // victimOlder predicate): skip the pin stat and the files-map
            // probe for those outright, so a large cache under sustained
            // culling pays one lstat per data file per round instead of an
            // extra stat and a global-lock hash probe for every file.
            if (count.* == walk_sample_cap and
                !victimOlder(st.st_mtim.tv_sec, nrel.len, nrel, &victims[walk_sample_cap - 1])) continue;
            if (self.pinExists(nrel)) continue;
            self.mu.lockUncancelable(self.io);
            const in_mem = self.files.get(nrel) != null;
            self.mu.unlock(self.io);
            if (in_mem) continue;
            considerVictim(victims, count, nrel, st.st_mtim.tv_sec);
        }
    }

    fn punchDisk(self: *Store, rel: []const u8) bool {
        if (self.pinExists(rel)) return false;
        var dbuf: [sys.c.PATH_MAX]u8 = undefined;
        const dp = self.cacheDataPath(&dbuf, rel) catch {
            std.log.warn("disk punch skipped for {s}; cache path does not fit; bytes stay cached", .{rel});
            return false;
        };
        const fd = sys.open(dp, c.O_RDWR | c.O_NOFOLLOW, 0);
        if (fd < 0) {
            const e = sys.errno();
            if (e != c.ENOENT)
                std.log.warn("disk punch skipped for {s} (errno {d}); bytes stay cached", .{ rel, e });
            return false;
        }
        defer sys.close(fd);
        var st: c.struct_stat = undefined;
        if (sys.fstat(fd, &st) != 0) {
            std.log.warn("disk punch skipped for {s} (fstat errno {d}); bytes stay cached", .{ rel, sys.errno() });
            return false;
        }
        const size = sys.sizeFromStat(st.st_size) orelse {
            std.log.warn("disk punch skipped for {s}; data file size unusable; bytes stay cached", .{rel});
            return false;
        };
        // Builder-contract sample: if any artifact mutation (forget, reap
        // purge, another punch) lands between this and the critical section
        // below, the bits loaded here describe artifacts that no longer
        // exist, and the attempt is discarded instead of punching blind.
        self.mu.lockUncancelable(self.io);
        const epoch0 = self.purge_epoch;
        self.mu.unlock(self.io);
        var loaded = self.loadBits(rel, size, OriginId{}) catch |err| {
            std.log.warn("cannot load piece sidecar for {s} ({t}); piece stays cached", .{ rel, err });
            return false;
        };
        defer loaded.bits.deinit(self.gpa);
        const idx = loaded.bits.lastSet() orelse return self.punchDiskUnclaimed(rel, fd, size, loaded.bits, epoch0);
        const off = piece.offset(idx, self.piece_size);
        const ln = piece.len(size, idx, self.piece_size);
        loaded.bits.clear(idx);
        // Encode and path resolution stay outside the lock; both failures
        // bail before anything is mutated, so no hole can outlive its
        // unpersisted mark.
        var blob: std.ArrayList(u8) = .empty;
        defer blob.deinit(self.gpa);
        loaded.bits.encode(self.piece_size, size, &blob, self.gpa) catch {
            std.log.warn("bitfield encode failed for {s}; piece {d} stays cached", .{ rel, idx });
            return false;
        };
        var mbuf: [sys.c.PATH_MAX]u8 = undefined;
        const mp = self.cacheMetaPath(&mbuf, rel) catch {
            std.log.warn("bitfield save skipped for {s}; cache path does not fit; piece {d} stays cached", .{ rel, idx });
            return false;
        };
        // One store.mu window covers the liveness recheck, the durable
        // sidecar save, the punch, and the builder-invalidation bump -- the
        // same shape as forget/reapIdle purges. The save sits inside the
        // window like finishPiece's dead-entry check: writing it outside the
        // lock would let a concurrent forget purge the artifacts between the
        // loadBits above and the save, and rewriting the sidecar anyway
        // would recreate one naming filled pieces over data files that no
        // longer exist, which a same-size recreate would trust and serve
        // hole zeros as cached model data.
        // A get() cannot insert an entry for rel inside this window
        // (insertion takes store.mu), so a sampled victim can never grow a
        // live entry mid-punch: one that inserted before the window makes
        // contains() bail without saving or punching, and one whose sidecar
        // read raced the rewrite discards at insert because the bump below
        // follows the completed mutation -- sampling the new epoch
        // guarantees the reader sees post-punch bits.
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.files.contains(rel)) return false;
        if (self.purge_epoch != epoch0) return false;
        // Write-ahead (same contract as punchPiece): the cleared field is
        // persisted durably before any destructive step. A save failure leaves
        // the old sidecar standing and nothing punched; a crash after the save
        // but before the punch costs only a refill over intact bytes.
        const w = sys.writeFileOwnerOnlyDurable(mp, blob.items);
        if (w != 0) {
            std.log.warn("bitfield save failed for {s} (errno {d}); piece {d} stays cached", .{ rel, -w, idx });
            return false;
        }
        const punched = sys.punchHole(fd, off, ln);
        if (punched != 0) {
            // Write-ahead already cleared the sidecar: reads refill over the
            // intact bytes. Without this line a cache fs that cannot hole-punch
            // fills up with only culled=0 on the tick line.
            std.log.warn("piece punch failed for {s} piece {d} (errno {d}); bytes stay until the next round", .{ rel, idx, -punched });
            return false;
        }
        self.purge_epoch += 1;
        _ = self.stats.pieces_culled.fetchAdd(1, .monotonic);
        return true;
    }

    /// Reclaims a data file that no sidecar vouches for: the decoded field
    /// is empty because the sidecar is missing (crash between the data write
    /// and its first save), stale against the current piece grid or file
    /// size (decode resets on ps/fs mismatch), or already cleared while
    /// blocks remain allocated (crash between a durable clear and the
    /// punch). No mark claims these bytes, so hole-punching the whole extent
    /// cannot serve hole zeros behind a bit; leaving them, however, makes
    /// them invisible to every later cull round -- lastSet finds nothing to
    /// punch and this scan used to bail -- so sustained pressure could hold
    /// the watermark below bcull forever against victims that free nothing.
    /// Same write-ahead contract as the per-piece path: the cleared field is
    /// persisted durably before any destructive step, under the same
    /// store.mu window and builder-epoch guard.
    fn punchDiskUnclaimed(self: *Store, rel: []const u8, fd: c_int, size: u64, bits: piece.Bitfield, epoch0: u64) bool {
        if (size == 0) return false;
        var blob: std.ArrayList(u8) = .empty;
        defer blob.deinit(self.gpa);
        bits.encode(self.piece_size, size, &blob, self.gpa) catch {
            std.log.warn("bitfield encode failed for {s}; unclaimed bytes stay cached", .{rel});
            return false;
        };
        var mbuf: [sys.c.PATH_MAX]u8 = undefined;
        const mp = self.cacheMetaPath(&mbuf, rel) catch {
            std.log.warn("bitfield save skipped for {s}; cache path does not fit; unclaimed bytes stay cached", .{rel});
            return false;
        };
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.files.contains(rel)) return false;
        if (self.purge_epoch != epoch0) return false;
        const w = writeFileMakingParent(mp, blob.items, true);
        if (w != 0) {
            std.log.warn("bitfield save failed for {s} (errno {d}); unclaimed bytes stay cached", .{ rel, -w });
            return false;
        }
        const punched = sys.punchHole(fd, 0, size);
        if (punched != 0) {
            // The durable sidecar above already clears every mark, so reads
            // refill over these bytes on demand; a failed punch only delays
            // the space reclaim to the next sampled round.
            std.log.warn("unclaimed-byte punch failed for {s} (errno {d}); bytes stay until the next round", .{ rel, -punched });
            return false;
        }
        self.purge_epoch += 1;
        _ = self.stats.pieces_culled.fetchAdd(1, .monotonic);
        return true;
    }
};

test "noteOriginIo edge-triggers infrastructure origin failures" {
    const gpa = std.testing.allocator;
    var st = Store.init(gpa, std.testing.io, "/unused", "/unused", 4096);
    defer st.deinit();

    // Expected-path warn/info stay off the runner's stderr like sibling tests.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    // Path-level answers must not raise the outage flag: an operator
    // grepping for "origin recovered" would otherwise see a flap on every
    // ENOENT the workload throws, and a planted symlink (ELOOP) or a
    // permission/space refusal would look like NFS died.
    st.noteOriginIo("gone.bin", -c.ENOENT, "stat");
    try std.testing.expect(!st.origin_io_down.load(.monotonic));
    st.noteOriginIo("dir.bin", -c.EISDIR, "write");
    try std.testing.expect(!st.origin_io_down.load(.monotonic));
    st.noteOriginIo("planted.bin", -c.ELOOP, "write");
    try std.testing.expect(!st.origin_io_down.load(.monotonic));
    st.noteOriginIo("denied.bin", -c.EACCES, "write");
    try std.testing.expect(!st.origin_io_down.load(.monotonic));
    st.noteOriginIo("full.bin", -c.ENOSPC, "write");
    try std.testing.expect(!st.origin_io_down.load(.monotonic));
    try std.testing.expect(!Store.originIoOutage(c.ENOENT));
    try std.testing.expect(!Store.originIoOutage(c.ELOOP));
    try std.testing.expect(Store.originIoOutage(c.EIO));
    try std.testing.expect(Store.originIoOutage(c.ESTALE));
    try std.testing.expect(Store.originIoOutage(c.ETIMEDOUT));

    // First infrastructure failure raises the flag; a second one stays quiet
    // so a busy FUSE read storm cannot flood the journal.
    st.noteOriginIo("a.bin", -c.EIO, "stat");
    try std.testing.expect(st.origin_io_down.load(.monotonic));
    st.noteOriginIo("b.bin", -c.ESTALE, "stat");
    try std.testing.expect(st.origin_io_down.load(.monotonic));
    st.noteOriginIo("c.bin", -c.ETIMEDOUT, "write");
    try std.testing.expect(st.origin_io_down.load(.monotonic));

    // The next success is the recovery edge: one info line, flag cleared.
    st.noteOriginIo("a.bin", 0, "stat");
    try std.testing.expect(!st.origin_io_down.load(.monotonic));
}

test "originPread and originPwrite raise and clear origin_io_down" {
    // Fill, peer /have stat, and write-through I/O used to skip noteOriginIo:
    // getattr/open could succeed (or never run) while an EIO pread left
    // origin_down at 0. Success must also clear a prior outage.
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-origio");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-origio");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    var tb: [192]u8 = undefined;
    var zb: [192]u8 = undefined;
    const real_z = try sys.toZ(&zb, try std.fmt.bufPrint(&tb, "{s}/real.bin", .{origin_d}));
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(real_z, "model"));

    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    var rbuf: [8]u8 = undefined;
    var stbuf: c.struct_stat = undefined;
    // Path-level miss is not an outage: ENOENT must not raise the flag.
    try std.testing.expectEqual(-c.ENOENT, st.statOrigin("gone.bin", &stbuf));
    try std.testing.expect(!st.origin_io_down.load(.monotonic));
    try std.testing.expectEqual(-c.ENOENT, st.originPread("gone.bin", &rbuf, 0));
    try std.testing.expect(!st.origin_io_down.load(.monotonic));
    try std.testing.expectEqual(-c.ENOENT, st.originPwrite("gone.bin", rbuf[0..5], 0));
    try std.testing.expect(!st.origin_io_down.load(.monotonic));

    st.origin_io_down.store(true, .monotonic);
    try std.testing.expectEqual(@as(i32, 0), st.statOrigin("real.bin", &stbuf));
    try std.testing.expect(!st.origin_io_down.load(.monotonic));
    st.origin_io_down.store(true, .monotonic);
    try std.testing.expectEqual(@as(isize, 5), st.originPread("real.bin", rbuf[0..5], 0));
    try std.testing.expect(!st.origin_io_down.load(.monotonic));
    st.origin_io_down.store(true, .monotonic);
    try std.testing.expectEqual(@as(isize, 5), st.originPwrite("real.bin", rbuf[0..5], 0));
    try std.testing.expect(!st.origin_io_down.load(.monotonic));
}

test "rangeFilled is true only when every covered piece is marked" {
    const gpa = std.testing.allocator;
    var bits = try piece.Bitfield.init(gpa, 4);
    defer bits.deinit(gpa);
    bits.set(0);
    bits.set(1);
    var filling = std.AutoHashMap(u32, u64).init(gpa);
    defer filling.deinit();
    var rel = [_]u8{ 't', '.', 'b', 'i', 'n' };
    var file = Store.Cached{
        .rel = &rel,
        .size = 64,
        .bits = bits,
        .filling = filling,
        .hashes = std.AutoHashMap(u32, [piece.digest_len]u8).init(gpa),
    };
    defer file.hashes.deinit();
    const ps: u32 = 16;
    try std.testing.expect(Store.rangeFilled(&file, .{ .off = 0, .len = 16 }, 64, ps));
    try std.testing.expect(Store.rangeFilled(&file, .{ .off = 0, .len = 32 }, 64, ps));
    try std.testing.expect(!Store.rangeFilled(&file, .{ .off = 0, .len = 33 }, 64, ps));
    try std.testing.expect(!Store.rangeFilled(&file, .{ .off = 32, .len = 16 }, 64, ps));
    try std.testing.expect(Store.rangeFilled(&file, .{ .off = 100, .len = 8 }, 64, ps));
    // Piece-size 1 past 4 GiB: cover() of the tail is empty (indexAt
    // clamps), which used to look filled.
    const tail_off: u64 = std.math.maxInt(u32);
    try std.testing.expect(!Store.rangeFilled(&file, .{ .off = tail_off, .len = 8 }, tail_off + 100, 1));
    try std.testing.expect(!Store.rangeFilled(&file, .{ .off = tail_off - 10, .len = 20 }, tail_off + 100, 1));
}

test "cacheFill grows entry preserving earlier piece marks" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-fill");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-fill");
    defer sys.deleteTree(std.testing.io, cache_d);

    // Piece size 16: a sequential ingest of three chunks must keep every
    // fully-written piece marked. Regression: the write path went through
    // reconcileSize on each growth, wiping all marks but the last chunk's.
    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    var w1: [16]u8 = undefined;
    @memset(&w1, 0xAA);
    // mf_create would have made the origin file before any write lands.
    var zbuf: [160]u8 = undefined;
    const fp = try std.fmt.bufPrint(&zbuf, "{s}/app.bin", .{origin_d});
    var fbuf2: [160]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&fbuf2, fp), ""));
    try std.testing.expectEqual(@as(isize, 16), st.originPwrite("app.bin", &w1, 0));
    st.cacheFill("app.bin", 16, 0, &w1, sys.monoSec(std.testing.io));

    {
        const f = st.lookupRef("app.bin").?;
        defer st.releaseFile(f);
        f.mu.lockUncancelable(std.testing.io);
        try std.testing.expectEqual(@as(u64, 16), f.size);
        try std.testing.expectEqual(@as(u32, 1), f.bits.nbits);
        try std.testing.expect(f.bits.get(0));
        f.mu.unlock(std.testing.io);
    }

    var w2: [24]u8 = undefined;
    @memset(&w2, 0xBB);
    try std.testing.expectEqual(@as(isize, 24), st.originPwrite("app.bin", &w2, 16));
    st.cacheFill("app.bin", 40, 16, &w2, sys.monoSec(std.testing.io));

    {
        const f = st.lookupRef("app.bin").?;
        defer st.releaseFile(f);
        f.mu.lockUncancelable(std.testing.io);
        try std.testing.expectEqual(@as(u64, 40), f.size);
        try std.testing.expectEqual(@as(u32, 3), f.bits.nbits);
        // pieces 0 and 1 fully written; piece 2 only half covered
        try std.testing.expect(f.bits.get(0));
        try std.testing.expect(f.bits.get(1));
        try std.testing.expect(!f.bits.get(2));
        f.mu.unlock(std.testing.io);
    }

    // A third append completes piece 2 without disturbing earlier marks.
    var w3: [8]u8 = undefined;
    @memset(&w3, 0xCC);
    try std.testing.expectEqual(@as(isize, 8), st.originPwrite("app.bin", &w3, 40));
    st.cacheFill("app.bin", 48, 40, &w3, sys.monoSec(std.testing.io));

    {
        const f = st.lookupRef("app.bin").?;
        defer st.releaseFile(f);
        f.mu.lockUncancelable(std.testing.io);
        try std.testing.expectEqual(@as(u64, 48), f.size);
        // Piece 2 spans two appends, so neither write alone fully covers
        // it; it stays unmarked until a read hydrates it (per-write
        // marking, as documented on fullCover).
        try std.testing.expectEqual(@as(u32, 2), f.bits.filled());
        f.mu.unlock(std.testing.io);
    }

    // The cache copy serves every written region back directly.
    var w2_full: [24]u8 = undefined;
    @memset(&w2_full, 0xBB);
    var rd: [48]u8 = undefined;
    const f = try st.get("app.bin", 48, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    const n = st.readCache(f, &rd, 0, sys.monoSec(std.testing.io));
    try std.testing.expectEqual(@as(isize, 48), n);
    try std.testing.expectEqualSlices(u8, &w1, rd[0..16]);
    try std.testing.expectEqualSlices(u8, &w2_full, rd[16..40]);
    try std.testing.expectEqualSlices(u8, &w3, rd[40..48]);
}

test "cacheFill resets every mark when an external truncate shrinks the file" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-extshrink");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-extshrink");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Three aligned appends fill all three pieces of a 48-byte file.
    var chunk: [16]u8 = undefined;
    for (&chunk, 0..) |*b, i| b.* = @truncate(i *% 31 + 1);
    // mf_create would have made the origin file before any write lands.
    var fb: [160]u8 = undefined;
    var zz0: [160]u8 = undefined;
    const fp = try std.fmt.bufPrint(&fb, "{s}/ext.bin", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zz0, fp), ""));
    for ([_]u64{ 0, 16, 32 }) |off| {
        try std.testing.expectEqual(@as(isize, 16), st.originPwrite("ext.bin", &chunk, off));
        st.cacheFill("ext.bin", off + 16, off, &chunk, sys.monoSec(std.testing.io));
    }
    {
        const f = st.lookupRef("ext.bin").?;
        defer st.releaseFile(f);
        f.mu.lockUncancelable(std.testing.io);
        try std.testing.expectEqual(@as(u32, 3), f.bits.filled());
        f.mu.unlock(std.testing.io);
    }

    // Someone else truncates the shared origin to 32 bytes and rewrites the
    // final full piece -- the shape mf_write observes when a co-writer shrank
    // the file between our writes (observed origin size == this write's end).
    // Regression class: keeping any mark across an external shrink would let
    // a bit name bytes whose content the truncator replaced or removed, and
    // reads would serve them as cached model data without a refill.
    {
        var zb: [160]u8 = undefined;
        const fd = sys.open(try sys.toZ(&zb, fp), c.O_WRONLY, 0);
        try std.testing.expect(fd >= 0);
        defer sys.close(fd);
        try std.testing.expectEqual(@as(i32, 0), sys.ftruncate(fd, 32));
        try std.testing.expectEqual(@as(isize, 16), sys.pwriteAll(fd, &chunk, 16));
    }
    st.cacheFill("ext.bin", 32, 16, &chunk, sys.monoSec(std.testing.io));

    {
        const f = st.lookupRef("ext.bin").?;
        defer st.releaseFile(f);
        f.mu.lockUncancelable(std.testing.io);
        // The entry reconciled down: piece 2 is gone with the grid...
        try std.testing.expectEqual(@as(u64, 32), f.size);
        try std.testing.expectEqual(@as(u32, 2), f.bits.nbits);
        try std.testing.expect(!f.bits.get(2));
        // ...and the reset is conservative like reconcileSize's: even piece
        // 0, whose bytes the truncate did not touch, refills rather than
        // trusting pre-shrink marks. Only the post-shrink write's own fully
        // covered piece is marked.
        try std.testing.expect(!f.bits.get(0));
        try std.testing.expect(f.bits.get(1));
        try std.testing.expectEqual(@as(u32, 1), f.bits.filled());
        f.mu.unlock(std.testing.io);
        // Same fd cut reconcileSize makes: the tail the truncator removed
        // must not remain readable on the live cache descriptor.
        var post: c.struct_stat = undefined;
        try std.testing.expect(f.cache_fd >= 0);
        try std.testing.expectEqual(@as(i32, 0), sys.fstat(f.cache_fd, &post));
        try std.testing.expectEqual(@as(u64, 32), @as(u64, @intCast(post.st_size)));
    }

    // The persisted sidecar names exactly this state, so a restart cannot
    // load the pre-shrink marks back over the rewritten file.
    var mb: [sys.c.PATH_MAX]u8 = undefined;
    const mp = try st.cacheMetaPath(&mb, "ext.bin");
    const blob = try sys.readFileAlloc(gpa, mp, 4096);
    defer gpa.free(blob);
    var sidecar = try piece.Bitfield.decode(gpa, blob, st.piece_size, 32);
    defer sidecar.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), sidecar.nbits);
    try std.testing.expect(!sidecar.get(0));
    try std.testing.expect(sidecar.get(1));
}

test "get reconciles an externally shrunken origin by wiping marks and truncating the cache fd" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-getshrink");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-getshrink");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Warm entry at 64 bytes: pieces 0 and 3 cached, sidecar saved, cache fd
    // opened (openCache sizes it to the entry with ftruncate).
    const f = try st.get("shrunk.bin", 64, sys.monoSec(std.testing.io));
    f.mu.lockUncancelable(std.testing.io);
    f.bits.set(0);
    f.bits.set(3);
    f.mu.unlock(std.testing.io);
    _ = st.saveBits(f, false);
    try std.testing.expect(st.openCache(f) >= 0);
    var pre: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(i32, 0), sys.fstat(f.cache_fd, &pre));
    try std.testing.expectEqual(@as(u64, 64), @as(u64, @intCast(pre.st_size)));

    // The sibling grow case (32 -> 64) is covered above; this is the other
    // direction, as mf_read observes after a co-writer truncated the shared
    // origin: the hit path must reconcile DOWN too. reconcileSize's contract
    // is an empty field sized for the new length plus an fd truncate, so no
    // stale piece can serve bytes past (or underneath) the new end.
    const f2 = try st.get("shrunk.bin", 32, sys.monoSec(std.testing.io));
    try std.testing.expectEqual(f, f2);
    st.releaseFile(f2);

    f.mu.lockUncancelable(std.testing.io);
    try std.testing.expectEqual(@as(u64, 32), f.size);
    try std.testing.expectEqual(@as(u32, 2), f.bits.nbits);
    try std.testing.expectEqual(@as(u32, 0), f.bits.filled());
    f.mu.unlock(std.testing.io);

    // The open descriptor was cut with the entry: reads through it can no
    // longer reach the truncated-away tail.
    var post: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(i32, 0), sys.fstat(f.cache_fd, &post));
    try std.testing.expectEqual(@as(u64, 32), @as(u64, @intCast(post.st_size)));
    st.releaseFile(f);
}

test "size reconciliation persists the wipe so a restart cannot reload stale marks" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-rcpersist");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-rcpersist");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Warm entry at 64 bytes: pieces 0 and 3 marked and saved, so the
    // sidecar on disk vouches for two filled pieces of a 64-byte grid.
    var mb: [sys.c.PATH_MAX]u8 = undefined;
    const mp = try st.cacheMetaPath(&mb, "rc.bin");
    {
        const f = try st.get("rc.bin", 64, sys.monoSec(std.testing.io));
        defer st.releaseFile(f);
        f.mu.lockUncancelable(std.testing.io);
        f.bits.set(0);
        f.bits.set(3);
        f.mu.unlock(std.testing.io);
        _ = st.saveBits(f, false);
        const blob = try sys.readFileAlloc(gpa, mp, 4096);
        defer gpa.free(blob);
        var side = try piece.Bitfield.decode(gpa, blob, st.piece_size, 64);
        defer side.deinit(gpa);
        try std.testing.expectEqual(@as(u32, 2), side.filled());
    }

    // The create-truncate shape (mf_create stats a zero-length file through
    // get): reconcileSize wipes the marks in memory, and the wipe must reach
    // the sidecar before returning. Regression: the reset lived only in RAM,
    // so a crash here let the next daemon load decode the old sidecar
    // cleanly against a file back at 64 bytes -- pre-truncate marks served
    // over post-truncate content.
    {
        const g = try st.get("rc.bin", 0, sys.monoSec(std.testing.io));
        defer st.releaseFile(g);
        try std.testing.expectEqual(@as(u64, 0), g.size);
    }
    {
        const blob = try sys.readFileAlloc(gpa, mp, 4096);
        defer gpa.free(blob);
        // Exactly what a restarted daemon loading against a regrown 64-byte
        // file would decode: empty, not the old two marks.
        var side = try piece.Bitfield.decode(gpa, blob, st.piece_size, 64);
        defer side.deinit(gpa);
        try std.testing.expectEqual(@as(u32, 0), side.filled());
    }

    // The cacheFill shrink branch (an externally truncated file observed on
    // the write path) carries the same contract.
    {
        var zb: [160]u8 = undefined;
        var zz: [160]u8 = undefined;
        const fp = try std.fmt.bufPrint(&zb, "{s}/rc.bin", .{origin_d});
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zz, fp), ""));
        const f = try st.get("rc.bin", 64, sys.monoSec(std.testing.io));
        defer st.releaseFile(f);
        f.mu.lockUncancelable(std.testing.io);
        f.bits.set(0);
        f.bits.set(3);
        f.mu.unlock(std.testing.io);
        _ = st.saveBits(f, false);

        var chunk: [32]u8 = undefined;
        @memset(&chunk, 0x5A);
        st.cacheFill("rc.bin", 32, 0, &chunk, sys.monoSec(std.testing.io));

        const blob = try sys.readFileAlloc(gpa, mp, 4096);
        defer gpa.free(blob);
        var side = try piece.Bitfield.decode(gpa, blob, st.piece_size, 64);
        defer side.deinit(gpa);
        try std.testing.expectEqual(@as(u32, 0), side.filled());
    }
}

test "cold get persists a stale-sidecar wipe so a restart cannot reload stale marks" {
    // The live-entry shape is covered above (reconcileSize). After a
    // restart there is no map hit: loadBits returns an empty field sized
    // for the new length and used to leave the old sidecar on disk, so a
    // crash plus a same-size restore decoded the pre-wipe marks over new
    // bytes. The miss path must persist the same wipe the hit path does.
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-coldwipe");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-coldwipe");
    defer sys.deleteTree(std.testing.io, cache_d);

    var mb: [sys.c.PATH_MAX]u8 = undefined;
    {
        var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
        defer st.deinit();
        try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());
        const f = try st.get("cold.bin", 64, sys.monoSec(std.testing.io));
        defer st.releaseFile(f);
        f.mu.lockUncancelable(std.testing.io);
        f.bits.set(0);
        f.bits.set(3);
        f.mu.unlock(std.testing.io);
        _ = st.saveBits(f, false);
        const mp = try st.cacheMetaPath(&mb, "cold.bin");
        const blob = try sys.readFileAlloc(gpa, mp, 4096);
        defer gpa.free(blob);
        var side = try piece.Bitfield.decode(gpa, blob, st.piece_size, 64);
        defer side.deinit(gpa);
        try std.testing.expectEqual(@as(u32, 2), side.filled());
    }

    {
        var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
        defer st.deinit();
        // Restart: no live entry. The create-truncate shape stats a
        // zero-length origin through get.
        const g = try st.get("cold.bin", 0, sys.monoSec(std.testing.io));
        defer st.releaseFile(g);
        try std.testing.expectEqual(@as(u64, 0), g.size);
        const mp = try st.cacheMetaPath(&mb, "cold.bin");
        const blob = try sys.readFileAlloc(gpa, mp, 4096);
        defer gpa.free(blob);
        var side = try piece.Bitfield.decode(gpa, blob, st.piece_size, 64);
        defer side.deinit(gpa);
        try std.testing.expectEqual(@as(u32, 0), side.filled());
    }

    {
        var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
        defer st.deinit();
        // File back at the old length: a leftover pre-wipe sidecar would
        // decode as two filled pieces. The persisted wipe must still hold.
        const h = try st.get("cold.bin", 64, sys.monoSec(std.testing.io));
        defer st.releaseFile(h);
        h.mu.lockUncancelable(std.testing.io);
        try std.testing.expectEqual(@as(u32, 0), h.bits.filled());
        h.mu.unlock(std.testing.io);
    }
}

test "copyIntoCache never shrinks bytes a concurrent fill already landed" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-nocut");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-nocut");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Two writers appending through mf_write/cacheFill concurrently. Writer 1
    // grows the entry to its end (16) under file.mu; writer 2 then appends
    // past it (end 40) and its copy lands fully; writer 1's copy lands last.
    // Regression: copyIntoCache ran an absolute ftruncate(truncate_to) before
    // its pwrite outside any lock, so writer 1's cut shrank the shared cache
    // fd below writer 2's committed bytes while bit 1 stayed set -- reads
    // served hole zeros as cached model data. pwrite extends the fd on its
    // own, so the fill must never truncate.
    var w1: [16]u8 = undefined;
    @memset(&w1, 0xAA);
    var w2: [24]u8 = undefined;
    @memset(&w2, 0xBB);

    st.cacheFill("app.bin", 16, 0, &w1, sys.monoSec(std.testing.io));
    st.cacheFill("app.bin", 40, 16, &w2, sys.monoSec(std.testing.io));
    {
        const f = st.lookupRef("app.bin").?;
        defer st.releaseFile(f);
        try std.testing.expect(st.copyIntoCache(f, 0, &w1));

        var stbuf: c.struct_stat = undefined;
        try std.testing.expectEqual(@as(i32, 0), sys.fstat(f.cache_fd, &stbuf));
        try std.testing.expect(@as(u64, @intCast(stbuf.st_size)) >= 40);

        f.mu.lockUncancelable(std.testing.io);
        const bit1 = f.bits.get(1);
        f.mu.unlock(std.testing.io);
        try std.testing.expect(bit1);

        var rd: [40]u8 = undefined;
        try std.testing.expectEqual(@as(isize, 40), st.readCache(f, &rd, 0, sys.monoSec(std.testing.io)));
        try std.testing.expectEqualSlices(u8, &w1, rd[0..16]);
        try std.testing.expectEqualSlices(u8, &w2, rd[16..40]);
    }
}

test "finishPiece does not mark a fill whose write generation raced" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-fingen");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-fingen");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const f = try st.get("gen.bin", 16, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);

    // completeFill samples writes, drops file.mu for the pwrite, then
    // finishPiece marks. A truncate/distrust that bumps writes in that
    // window used to publish the fill's pre-mutation bytes as current.
    try std.testing.expect((try st.beginFill(f, 0, sys.monoSec(std.testing.io))) == .len);
    f.mu.lockUncancelable(std.testing.io);
    f.writes += 1;
    f.mu.unlock(std.testing.io);
    st.finishPiece(f, 0, true, null, sys.monoSec(std.testing.io));
    try std.testing.expect(!st.hasPiece(f, 0, sys.monoSec(std.testing.io)));
}

test "size reconciliation does not wipe marks already matching the observed size" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-recon");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-recon");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Grow 16 -> 32 wipes; a fill at 32 must survive a second get(32).
    // Without a locked re-check, two getters that both sampled a mismatch
    // each swap in an empty field and the later swap drops the fill.
    {
        const cold = try st.get("rc2.bin", 16, sys.monoSec(std.testing.io));
        st.releaseFile(cold);
    }
    const f = try st.get("rc2.bin", 32, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    try std.testing.expectEqual(@as(u32, 16), (try st.beginFill(f, 0, sys.monoSec(std.testing.io))).len);
    try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 0, "0123456789abcdef", null, sys.monoSec(std.testing.io)));
    try std.testing.expect(st.hasPiece(f, 0, sys.monoSec(std.testing.io)));

    const f2 = try st.get("rc2.bin", 32, sys.monoSec(std.testing.io));
    defer st.releaseFile(f2);
    try std.testing.expectEqual(f, f2);
    try std.testing.expect(st.hasPiece(f2, 0, sys.monoSec(std.testing.io)));
}

test "size reconciliation does not cut a cache fd under an in-flight peer send" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-xferfd");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-xferfd");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const f = try st.get("xferfd.bin", 64, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    try std.testing.expect(st.openCache(f) >= 0);
    var pre: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(i32, 0), sys.fstat(f.cache_fd, &pre));
    try std.testing.expectEqual(@as(u64, 64), @as(u64, @intCast(pre.st_size)));

    // serveData holds xfer across hydration plus sendfile. A concurrent
    // get() that observes a smaller origin must wipe marks but must not
    // ftruncate the descriptor sendfile is copying from -- that would
    // ship hole zeros the fetching peer marks filled.
    _ = f.xfer.fetchAdd(1, .monotonic);
    const f2 = try st.get("xferfd.bin", 32, sys.monoSec(std.testing.io));
    defer st.releaseFile(f2);
    f.mu.lockUncancelable(std.testing.io);
    try std.testing.expectEqual(@as(u64, 32), f.size);
    try std.testing.expectEqual(@as(u32, 0), f.bits.filled());
    f.mu.unlock(std.testing.io);
    var post: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(i32, 0), sys.fstat(f.cache_fd, &post));
    try std.testing.expectEqual(@as(u64, 64), @as(u64, @intCast(post.st_size)));
    _ = f.xfer.fetchSub(1, .monotonic);
}

test "cacheFill shrink drops an in-flight fill of a surviving piece" {
    // beginFill samples writes, then completeFill pwrites without file.mu.
    // A shrink that did not bump writes left that claim valid against the
    // new (empty) field, so the filler marked pre-shrink bytes as current
    // on a piece the post-shrink write did not cover.
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-cfshrink-race");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-cfshrink-race");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const f = try st.get("race.bin", 64, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    try std.testing.expect(st.openCache(f) >= 0);

    var stale: [16]u8 = undefined;
    @memset(&stale, 0xBB);
    var fresh: [16]u8 = undefined;
    @memset(&fresh, 0xAA);

    var round: usize = 0;
    while (round < 50) : (round += 1) {
        {
            f.content_mu.lockUncancelable(std.testing.io);
            defer f.content_mu.unlock(std.testing.io);
            f.mu.lockUncancelable(std.testing.io);
            defer f.mu.unlock(std.testing.io);
            if (f.size != 64) {
                try f.bits.resize(gpa, piece.count(64, st.piece_size));
                f.size = 64;
            }
            @memset(f.bits.bytes, 0);
            f.filling.clearRetainingCapacity();
        }

        var claimed = std.atomic.Value(bool).init(false);
        const filler = try std.Thread.spawn(.{}, struct {
            fn run(s: *Store, file: *Store.Cached, buf: []const u8, ready: *std.atomic.Value(bool)) void {
                const cl = s.beginFill(file, 0, sys.monoSec(std.testing.io)) catch {
                    ready.store(true, .release);
                    return;
                };
                if (cl != .len) {
                    ready.store(true, .release);
                    return;
                }
                ready.store(true, .release);
                _ = s.completeFill(file, 0, buf, null, sys.monoSec(std.testing.io));
            }
        }.run, .{ &st, f, stale[0..], &claimed });

        while (!claimed.load(.acquire))
            std.Thread.yield() catch {};
        st.cacheFill("race.bin", 32, 16, &fresh, sys.monoSec(std.testing.io));
        filler.join();

        f.mu.lockUncancelable(std.testing.io);
        try std.testing.expectEqual(@as(u64, 32), f.size);
        try std.testing.expect(!f.bits.get(0));
        try std.testing.expect(f.bits.get(1));
        f.mu.unlock(std.testing.io);
    }
}

test "completeFill does not overwrite a racing write-through" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-wt-race");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-wt-race");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const f = try st.get("race.bin", 16, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);

    var fresh: [16]u8 = undefined;
    @memset(&fresh, 0xAA);
    var stale: [16]u8 = undefined;
    @memset(&stale, 0xBB);

    try std.testing.expect((try st.beginFill(f, 0, sys.monoSec(std.testing.io))) == .len);
    try std.testing.expect(st.copyIntoCache(f, 0, &fresh));
    try std.testing.expect(st.wroteLocally(f));
    try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 0, &stale, null, sys.monoSec(std.testing.io)));
    try std.testing.expect(st.hasPiece(f, 0, sys.monoSec(std.testing.io)));

    var rd: [16]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 16), st.readCache(f, &rd, 0, sys.monoSec(std.testing.io)));
    try std.testing.expectEqualSlices(u8, &fresh, &rd);
}

test "a retried fill leaves bits, bytes, and sidecar identical to one run" {
    // The fill path is the daemon's most retried operation: fetchFromCands
    // walks candidate peers after a timeout or lost reply, and a crash
    // between a fill and its sidecar save re-fills the same piece. This
    // pins the idempotency those retries depend on: a second fill of the
    // same piece must leave the cache exactly as one run did.
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-dupfill");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-dupfill");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const f = try st.get("dupfill.bin", 16, sys.monoSec(std.testing.io));
    var data: [16]u8 = undefined;
    for (0..data.len) |i| data[i] = @intCast(i);
    var hash: [piece.digest_len]u8 = undefined;
    piece.digest(&data, &hash);

    // Run 1: hydrate the piece like a peer or origin fetch would.
    try std.testing.expect((try st.beginFill(f, 0, sys.monoSec(std.testing.io))) == .len);
    try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 0, &data, hash, sys.monoSec(std.testing.io)));
    try std.testing.expect(st.hasPiece(f, 0, sys.monoSec(std.testing.io)));

    // Run 2: the redelivered fetch. beginFill must report .filled instead
    // of double-claiming, and a blind completeFill of the same bytes must
    // be a no-op rather than re-writing or re-marking the piece.
    try std.testing.expect((try st.beginFill(f, 0, sys.monoSec(std.testing.io))) == .filled);
    try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 0, &data, hash, sys.monoSec(std.testing.io)));

    // Identical state: the bit is still set, the bytes are unchanged, and
    // the trusted hash recorded at the first fill still matches.
    try std.testing.expect(st.hasPiece(f, 0, sys.monoSec(std.testing.io)));
    var rd: [16]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 16), st.readCache(f, &rd, 0, sys.monoSec(std.testing.io)));
    try std.testing.expectEqualSlices(u8, &data, &rd);
    const rec = st.expectedHash(f, 0, 0);
    try std.testing.expect(rec != null);
    if (rec) |h| try std.testing.expectEqualSlices(u8, &hash, &h);

    // The persisted sidecar is equally unaffected: a fresh entry (the
    // crash-restart shape) reloads the same marks and bytes.
    st.releaseFile(f);
    const f2 = try st.get("dupfill.bin", 16, sys.monoSec(std.testing.io));
    defer st.releaseFile(f2);
    try std.testing.expect(st.hasPiece(f2, 0, sys.monoSec(std.testing.io)));
    var rd2: [16]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 16), st.readCache(f2, &rd2, 0, sys.monoSec(std.testing.io)));
    try std.testing.expectEqualSlices(u8, &data, &rd2);
}

test "completeFill drops a stale peer buffer after a partial write-through" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-wt-part");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-wt-part");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const f = try st.get("part.bin", 16, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);

    const patch = [_]u8{ 0xAA, 0xAA, 0xAA, 0xAA };
    var stale: [16]u8 = undefined;
    @memset(&stale, 0xBB);

    try std.testing.expect((try st.beginFill(f, 0, sys.monoSec(std.testing.io))) == .len);
    try std.testing.expect(st.copyIntoCache(f, 0, &patch));
    try std.testing.expect(st.wroteLocally(f));
    try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 0, &stale, null, sys.monoSec(std.testing.io)));
    try std.testing.expect(!st.hasPiece(f, 0, sys.monoSec(std.testing.io)));

    var rd: [16]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 16), st.readCache(f, &rd, 0, sys.monoSec(std.testing.io)));
    try std.testing.expectEqualSlices(u8, &patch, rd[0..4]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 12), rd[4..]);
}

test "copyIntoCache unmarks overlapping pieces when the cache write fails" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-wt-fail");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-wt-fail");
    defer sys.deleteTree(std.testing.io, cache_d);

    // Expected-path warning from the refused pwrite; keep it off stderr.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    var old: [32]u8 = undefined;
    @memset(&old, 0xAA);
    var patch: [8]u8 = undefined;
    @memset(&patch, 0xBB);

    {
        var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
        defer st.deinit();
        try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

        const f = try st.get("fail.bin", 32, sys.monoSec(std.testing.io));
        defer st.releaseFile(f);
        try std.testing.expect((try st.beginFill(f, 0, sys.monoSec(std.testing.io))) == .len);
        try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 0, old[0..16], null, sys.monoSec(std.testing.io)));
        try std.testing.expect((try st.beginFill(f, 1, sys.monoSec(std.testing.io))) == .len);
        try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 1, old[16..32], null, sys.monoSec(std.testing.io)));
        try std.testing.expect(st.hasPiece(f, 0, sys.monoSec(std.testing.io)));
        try std.testing.expect(st.hasPiece(f, 1, sys.monoSec(std.testing.io)));

        // Plant a read-only cache fd so the write-through pwrite fails while
        // both pieces stay marked. A 8-byte overwrite at offset 12 overlaps
        // both; leaving those bits set used to serve the 0xAA cache copy
        // after origin already held 0xBB, and /have advertised the stale
        // pieces to peers.
        try std.testing.expect(st.openCache(f) >= 0);
        var dbuf: [sys.c.PATH_MAX]u8 = undefined;
        const dp = try st.cacheDataPath(&dbuf, "fail.bin");
        f.mu.lockUncancelable(std.testing.io);
        sys.close(f.cache_fd);
        const ro = sys.open(dp, c.O_RDONLY | c.O_NOFOLLOW, 0);
        f.cache_fd = ro;
        f.mu.unlock(std.testing.io);
        try std.testing.expect(ro >= 0);

        try std.testing.expect(!st.copyIntoCache(f, 12, &patch));
        try std.testing.expect(st.wroteLocally(f));
        try std.testing.expect(!st.hasPiece(f, 0, sys.monoSec(std.testing.io)));
        try std.testing.expect(!st.hasPiece(f, 1, sys.monoSec(std.testing.io)));
    }

    // The wipe reached the sidecar: a restart must not reload the pre-write
    // marks over the bytes the refused pwrite never replaced.
    {
        var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
        defer st.deinit();
        const f = try st.get("fail.bin", 32, sys.monoSec(std.testing.io));
        defer st.releaseFile(f);
        f.mu.lockUncancelable(std.testing.io);
        try std.testing.expectEqual(@as(u32, 0), f.bits.filled());
        f.mu.unlock(std.testing.io);
    }
}

test "originPath and cacheDataPath refuse a rel that fails relOk" {
    const gpa = std.testing.allocator;
    var st = Store.init(gpa, std.testing.io, "/o", "/c", 16);
    defer st.deinit();
    var buf: [sys.c.PATH_MAX]u8 = undefined;
    try std.testing.expectError(error.NameTooLong, st.originPath(&buf, "../etc/passwd"));
    try std.testing.expectError(error.NameTooLong, st.originPath(&buf, "/etc/passwd"));
    try std.testing.expectError(error.NameTooLong, st.originPath(&buf, "a/../b"));
    try std.testing.expectError(error.NameTooLong, st.cacheDataPath(&buf, "../x"));
    const ok = try st.originPath(&buf, "a.bin");
    try std.testing.expect(std.mem.endsWith(u8, std.mem.span(ok), "/o/a.bin"));
    const root = try st.originPath(&buf, "");
    try std.testing.expectEqualStrings("/o", std.mem.span(root));
}

test "manifestsDirPath and manifestPath join under origin/.cluster/manifests" {
    const gpa = std.testing.allocator;
    var st = Store.init(gpa, std.testing.io, "/o", "/c", 16);
    defer st.deinit();
    var buf: [sys.c.PATH_MAX]u8 = undefined;
    const d = try st.manifestsDirPath(&buf);
    try std.testing.expectEqualStrings("/o/.cluster/manifests", std.mem.span(d));
    const p = try st.manifestPath(&buf, "a.bin");
    const span = std.mem.span(p);
    try std.testing.expect(std.mem.startsWith(u8, span, "/o/.cluster/manifests/"));
    try std.testing.expect(std.mem.find(u8, span, "a.bin") == null);
}

test "sidecarPieceSize reads the cache meta header and ignores a missing sidecar" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-sps");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-sps");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());
    try std.testing.expect(st.sidecarPieceSize("a.bin") == null);
    try writeFilledSidecar(&st, "a.bin", 64, &.{0});
    try std.testing.expectEqual(@as(?u32, 16), st.sidecarPieceSize("a.bin"));
    try std.testing.expect(st.sidecarPieceSize("../x") == null);
}

test "relOk rejects traversal and absolute paths" {
    try std.testing.expect(relOk("gguf/a.gguf"));
    try std.testing.expect(relOk("a.bin"));
    // traversal in every position
    try std.testing.expect(!relOk("../etc/passwd"));
    try std.testing.expect(!relOk("gguf/../../etc/passwd"));
    try std.testing.expect(!relOk("a/../b"));
    try std.testing.expect(!relOk("a/./b"));
    try std.testing.expect(!relOk("a/.."));
    try std.testing.expect(!relOk(".."));
    try std.testing.expect(!relOk("./a.bin"));
    // absolute and empty
    try std.testing.expect(!relOk("/etc/passwd"));
    try std.testing.expect(!relOk(""));
    // doubled and trailing slashes alias a distinct byte key onto the same
    // on-disk artifacts (`a//b` and `a/b` name the same data/meta/pin file
    // once the kernel collapses the run), so they must refuse like "." / ".."
    try std.testing.expect(!relOk("a//b"));
    try std.testing.expect(!relOk("a/"));
    try std.testing.expect(!relOk("gguf/"));
    // NUL would truncate the path at the syscall boundary
    try std.testing.expect(!relOk("a\x00b"));
    // CR/LF/ESC must not reach log sinks: a peer-supplied path could forge
    // multi-line log entries or inject terminal escapes
    try std.testing.expect(!relOk("a\n2026-08-23 INFO forged"));
    try std.testing.expect(!relOk("a\rb"));
    try std.testing.expect(!relOk("\x1b[31mred\x1b[0m"));
    try std.testing.expect(!relOk("a\tb"));
    try std.testing.expect(!relOk("a\x7fb"));
    // C1 controls arrive UTF-8-encoded (0xC2 0x80..0xC2 0x9F) and several
    // terminal families honor them as 8-bit OSC/CSI even in UTF-8 mode, so
    // the same log/terminal-injection class ESC closes needs the C1 pair
    // closed too.
    try std.testing.expect(!relOk("a\xc2\x9bb.bin"));
    try std.testing.expect(!relOk("\xc2\x9d0;pwned\xc2\x9c.bin"));
    // Unicode line/paragraph separators (U+2028/U+2029) are the remaining
    // Unicode line terminators after C0/C1: a C0/C1-only gate still lets
    // "gguf/a\u{2028}ERROR forged.bin" pass and split a journal line.
    try std.testing.expect(!relOk("gguf/a\u{2028}ERROR forged.bin"));
    try std.testing.expect(!relOk("a\u{2029}b.bin"));
    // Bidi format controls spoof display order in the same log and pin
    // lines: "gguf/a\u{202e}gnp.bin" renders as a .png next to a .bin.
    try std.testing.expect(!relOk("gguf/a\u{202e}gnp.bin"));
    try std.testing.expect(!relOk("a\u{200e}b.bin"));
    try std.testing.expect(!relOk("a\u{2066}b.bin"));
    try std.testing.expect(!relOk("a\u{061c}b.bin"));
    // Zero-width format controls in the same E2 80 / E2 81 blocks as the
    // bidi marks already refused: `gguf/model\u{200b}.bin` renders as
    // `gguf/model.bin` in the journal and pin lines.
    try std.testing.expect(!relOk("gguf/model\u{200b}.bin"));
    try std.testing.expect(!relOk("a\u{200c}b.bin"));
    try std.testing.expect(!relOk("a\u{200d}b.bin"));
    try std.testing.expect(!relOk("a\u{2060}b.bin"));
    try std.testing.expect(!relOk("a\u{206a}b.bin"));
    // Variation selectors and BOM: the emoji without a selector still
    // passes below; U+FE0F or a leading U+FEFF is an invisible extra.
    try std.testing.expect(!relOk("\u{1f512}\u{fe0f}locked.bin"));
    try std.testing.expect(!relOk("\u{feff}model.bin"));
    // Remaining Default_Ignorable: `gguf/model\u{ad}.bin` and
    // `a\u{e0100}.bin` render as the unadorned names.
    try std.testing.expect(!relOk("gguf/model\u{ad}.bin"));
    try std.testing.expect(!relOk("a\u{34f}b.bin"));
    try std.testing.expect(!relOk("a\u{180b}b.bin"));
    try std.testing.expect(!relOk("a\u{180f}b.bin"));
    try std.testing.expect(!relOk("a\u{1bca0}b.bin"));
    try std.testing.expect(!relOk("a\u{3164}b.bin"));
    try std.testing.expect(!relOk("a\u{e0020}b.bin"));
    try std.testing.expect(!relOk("a\u{e0100}b.bin"));
}

test "relOk passes non-ASCII and non-UTF-8 names through byte-exact" {
    // Paths are bytes at every boundary here: identity is byte equality all
    // the way down (kernel, cache keys, URL codec), nothing normalizes or
    // folds. So NFC and NFD spellings of the same display name are two
    // different files, and a name that is not valid UTF-8 at all is still
    // legal on Linux filesystems. The gate refuses only control bytes; these
    // cases pin that a future Unicode-awareness pass cannot quietly start
    // rejecting or rewriting legal names.
    try std.testing.expect(relOk("gguf/权重.gguf"));
    try std.testing.expect(relOk("caf\u{e9}.bin"));
    // Same display name in NFD (e + combining acute): distinct bytes, kept.
    try std.testing.expect(relOk("cafe\u{301}.bin"));
    // Astral-plane emoji (UTF-16 surrogate pair in other encodings).
    try std.testing.expect(relOk("\u{1f512}locked.bin"));
    // Bare high bytes, not valid UTF-8.
    try std.testing.expect(relOk("\xff\xfe.bin"));
    // NBSP is U+00A0: same 0xC2 lead byte as the rejected C1 controls but a
    // continuation above their range, so the C1 gate must not swallow it.
    try std.testing.expect(relOk("model\u{a0}v2.bin"));
    // Incomplete U+2028/bidi/VS encodings are invalid UTF-8 display noise, not
    // a control, matching a trailing 0xC2 with no C1 continuation.
    try std.testing.expect(relOk("a\xe2\x80.bin"));
    try std.testing.expect(relOk("a\xe2.bin"));
    try std.testing.expect(relOk("a\xe2\x81.bin"));
    try std.testing.expect(relOk("a\xd8.bin"));
    try std.testing.expect(relOk("a\xef.bin"));
    try std.testing.expect(relOk("a\xef\xb8.bin"));
    try std.testing.expect(relOk("a\xef\xbb.bin"));
    try std.testing.expect(relOk("a\xcd.bin"));
    try std.testing.expect(relOk("a\xe1\xa0.bin"));
    try std.testing.expect(relOk("a\xf3.bin"));
    try std.testing.expect(relOk("a\xf3\xa0.bin"));
    try std.testing.expect(relOk("a\xf3\xa0\x84.bin"));
    // U+2010 hyphen sits between ZWSP and U+2028 in the same lead-byte run
    // and is visible punctuation, not a format control.
    try std.testing.expect(relOk("a\u{2010}b.bin"));
    try std.testing.expect(relOk("a\u{ac}b.bin"));
    try std.testing.expect(relOk("a\u{180a}b.bin"));
    try std.testing.expect(relOk("a\u{1810}b.bin"));
    try std.testing.expect(relOk("a\u{1bc9f}b.bin"));
    try std.testing.expect(relOk("a\xf0\x9b\xb2.bin"));
    try std.testing.expect(relOk("a\u{fffc}b.bin"));
}

const seed_rel_model = fuzzcorpus.entry("gguf/a.gguf");
const seed_rel_dotdot = fuzzcorpus.entry("../etc/passwd");
const seed_rel_inner_dotdot = fuzzcorpus.entry("a/../b");
const seed_rel_dot_seg = fuzzcorpus.entry("a/./b");
const seed_rel_dot_name = fuzzcorpus.entry("...");
const seed_rel_absolute = fuzzcorpus.entry("/etc/passwd");
const seed_rel_empty = fuzzcorpus.entry("");
const seed_rel_double_slash = fuzzcorpus.entry("gguf//a.gguf");
const seed_rel_trailing_slash = fuzzcorpus.entry("gguf/");
const seed_rel_control = fuzzcorpus.entry("a\x1b[31mb\x7f");
const seed_rel_nul = fuzzcorpus.entry("a\x00b");
const seed_rel_c1 = fuzzcorpus.entry("a\xc2\x9bb.bin");
const seed_rel_line_sep = fuzzcorpus.entry("gguf/a\u{2028}ERROR.bin");
const seed_rel_bidi = fuzzcorpus.entry("gguf/a\u{202e}gnp.bin");
const seed_rel_zwsp = fuzzcorpus.entry("gguf/model\u{200b}.bin");
const seed_rel_vs = fuzzcorpus.entry("a\u{fe0f}.bin");
const seed_rel_bom = fuzzcorpus.entry("\u{feff}model.bin");
const seed_rel_shy = fuzzcorpus.entry("gguf/model\u{ad}.bin");
const seed_rel_vs17 = fuzzcorpus.entry("a\u{e0100}.bin");
const seed_rel_fvs4 = fuzzcorpus.entry("a\u{180f}.bin");
const seed_rel_shorthand = fuzzcorpus.entry("a\u{1bca0}.bin");
const seed_rel_tag = fuzzcorpus.entry("a\u{e007f}.bin");
const seed_rel_nbsp = fuzzcorpus.entry("model\u{a0}v2.bin");
const seed_rel_lone_c1byte = fuzzcorpus.entry("a\x9bb.bin");
const seed_rel_trailing_c2 = fuzzcorpus.entry("foo\xc2");
const seed_rel_unicode = fuzzcorpus.entry("权重/mödel.gguf");

const fuzz_rel_corpus = [_][]const u8{
    &seed_rel_model,
    &seed_rel_dotdot,
    &seed_rel_inner_dotdot,
    &seed_rel_dot_seg,
    &seed_rel_dot_name,
    &seed_rel_absolute,
    &seed_rel_empty,
    &seed_rel_double_slash,
    &seed_rel_trailing_slash,
    &seed_rel_control,
    &seed_rel_nul,
    &seed_rel_c1,
    &seed_rel_line_sep,
    &seed_rel_bidi,
    &seed_rel_zwsp,
    &seed_rel_vs,
    &seed_rel_bom,
    &seed_rel_shy,
    &seed_rel_vs17,
    &seed_rel_fvs4,
    &seed_rel_shorthand,
    &seed_rel_tag,
    &seed_rel_nbsp,
    &seed_rel_lone_c1byte,
    &seed_rel_trailing_c2,
    &seed_rel_unicode,
};

/// Independent restatement of relOk: empty/absolute refuse, C0/DEL, and
/// proto.utf8FormatControlAt's set (C1 and Default_Ignorable, including
/// variation selectors, tags, soft hyphen) refuse, "." / ".." components refuse,
/// empty components (double slash, trailing slash) refuse too -- a doubled
/// or trailing slash aliases a distinct byte key onto the same on-disk
/// artifacts. Walks segments by index instead of splitScalar so a corrupted
/// splitter cannot self-confirm.
fn refRelOk(rel: []const u8) bool {
    if (rel.len == 0 or rel[0] == '/') return false;
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i <= rel.len) : (i += 1) {
        if (i != rel.len and rel[i] != '/') {
            const ch = rel[i];
            if (ch < 0x20 or ch == 0x7f) return false;
            if (proto.utf8FormatControlAt(rel, i)) return false;
            continue;
        }
        const seg = rel[seg_start..i];
        if (seg.len == 0) return false;
        if (seg[0] == '.' and (seg.len == 1 or (seg.len == 2 and seg[1] == '.'))) return false;
        seg_start = i + 1;
    }
    return true;
}

/// relOk is the only path-safety gate at every external boundary (FUSE after
/// the leading slash is stripped, peer HTTP after URL decode, CLI pin). The
/// FUSE and request-head harnesses call it as a downstream check; this one
/// drives it as the parser under test, against an independent oracle, on
/// every byte string including C1 spellings, lone high bytes, and empty
/// components the unit tests pin by example.
fn fuzzRelOkOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const rel = buf[0..smith.slice(&buf)];

    const got = relOk(rel);
    try std.testing.expectEqual(refRelOk(rel), got);
    try std.testing.expectEqual(got, relOk(rel));

    if (!got) return;
    try std.testing.expect(rel.len > 0);
    try std.testing.expect(rel[0] != '/');
    var i: usize = 0;
    while (i < rel.len) : (i += 1) {
        try std.testing.expect(rel[i] >= 0x20 and rel[i] != 0x7f);
        try std.testing.expect(!proto.utf8FormatControlAt(rel, i));
    }
    var seg_start: usize = 0;
    var j: usize = 0;
    while (j <= rel.len) : (j += 1) {
        if (j != rel.len and rel[j] != '/') continue;
        const seg = rel[seg_start..j];
        try std.testing.expect(!(std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")));
        seg_start = j + 1;
    }
}

test "fuzz relOk denies traversal controls and C1 spellings for every input" {
    try std.testing.fuzz({}, fuzzRelOkOne, .{ .corpus = &fuzz_rel_corpus });
}

test "store get file size update and pin" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-pin");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-pin");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const f1 = try st.get("bar.bin", 32, sys.monoSec(std.testing.io));
    try std.testing.expectEqual(@as(u64, 32), f1.size);
    try std.testing.expectEqual(@as(u32, 2), f1.bits.nbits);

    // Resizing file
    const f2 = try st.get("bar.bin", 64, sys.monoSec(std.testing.io));
    try std.testing.expectEqual(f1, f2);
    try std.testing.expectEqual(@as(u64, 64), f2.size);
    try std.testing.expectEqual(@as(u32, 4), f2.bits.nbits);

    // Pinning
    try std.testing.expectEqual(@as(i32, 0), st.setPin("bar.bin", true));
    try std.testing.expect(st.pinExists("bar.bin"));
    try std.testing.expectEqual(@as(i32, 0), st.setPin("bar.bin", false));
    try std.testing.expect(!st.pinExists("bar.bin"));

    // Both lookups hold a reference; dropping both frees the entry (any leak
    // or double free is reported by the testing allocator).
    st.releaseFile(f1);
    st.releaseFile(f2);
}

test "forget drops bits, fd, and disk artifacts for the path" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-forget");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-forget");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const f1 = try st.get("gone.bin", 64, sys.monoSec(std.testing.io));
    f1.mu.lockUncancelable(std.testing.io);
    f1.bits.set(0);
    f1.bits.set(3);
    f1.mu.unlock(std.testing.io);
    _ = st.saveBits(f1, false);
    try std.testing.expect(st.openCache(f1) >= 0);

    // No live entry: artifacts from an earlier process must still be purged.
    var mb: [sys.c.PATH_MAX]u8 = undefined;
    st.forget("never-known.bin");
    const stale_meta = try st.cacheMetaPath(&mb, "never-known.bin");
    var st_buf: c.struct_stat = undefined;
    try std.testing.expect(sys.statPath(stale_meta, &st_buf) != 0);

    st.forget("gone.bin");
    // The entry is evicted from the map: a later get() builds a fresh one.
    // The old pointer stays valid until its reference is dropped, and its
    // bits were emptied so no stale state survives. The cache fd also stays
    // valid until that release (closing it under live holders would let the
    // descriptor number be reused mid-I/O); it dies with the entry.
    const f2 = try st.get("gone.bin", 64, sys.monoSec(std.testing.io));
    try std.testing.expect(f2 != f1);
    f1.mu.lockUncancelable(std.testing.io);
    try std.testing.expectEqual(@as(u32, 0), f1.bits.filled());
    try std.testing.expect(f1.cache_fd >= 0);
    f1.mu.unlock(std.testing.io);
    try std.testing.expectEqual(@as(u32, 0), f2.bits.filled());
    const meta = try st.cacheMetaPath(&mb, "gone.bin");
    try std.testing.expect(sys.statPath(meta, &st_buf) != 0);
    var db: [sys.c.PATH_MAX]u8 = undefined;
    const data = try st.cacheDataPath(&db, "gone.bin");
    try std.testing.expect(sys.statPath(data, &st_buf) != 0);
    st.releaseFile(f1);
    st.releaseFile(f2);
}

test "corrupt sidecar degrades to empty bitfield" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-corrupt");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-corrupt");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // The torn sidecars below trip loadBits' reset warning by design; keep
    // those expected lines off the runner's stderr like the punchPiece
    // save-failure tests do. Restored on scope exit.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    // Torn sidecar, as a crash mid-saveBits can leave behind: shorter than
    // the header must not make every read of the file fail.
    var mb: [sys.c.PATH_MAX]u8 = undefined;
    const torn = try st.cacheMetaPath(&mb, "torn.bin");
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(torn, "MF"));

    const f1 = try st.get("torn.bin", 64, sys.monoSec(std.testing.io));
    try std.testing.expectEqual(@as(u32, 4), f1.bits.nbits);
    try std.testing.expectEqual(@as(u32, 0), f1.bits.filled());

    // Plausible length but wrong magic must also reset, not fail.
    var bb: [sys.c.PATH_MAX]u8 = undefined;
    const bad = try st.cacheMetaPath(&bb, "bad.bin");
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(bad, "XXXX" ** 8));

    const f2 = try st.get("bad.bin", 64, sys.monoSec(std.testing.io));
    try std.testing.expectEqual(@as(u32, 4), f2.bits.nbits);
    try std.testing.expectEqual(@as(u32, 0), f2.bits.filled());
    st.releaseFile(f1);
    st.releaseFile(f2);
}

test "unreadable sidecar degrades to empty bitfield with a named warning" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-unreadable");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-unreadable");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // A regular file parked where a meta subdirectory belongs makes every
    // sidecar open under it fail ENOTDIR deterministically (even under
    // root), the way an EACCES/EIO meta tree would. The entry must still
    // build (empty), and loadBits must name the read failure -- regression:
    // any unreadable sidecar reset the cache silently, so a failing meta fs
    // looked exactly like an always-cold one.
    var zb: [192]u8 = undefined;
    var zz: [192]u8 = undefined;
    const blocker = try std.fmt.bufPrint(&zb, "{s}/meta/blocker", .{cache_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zz, blocker), "x"));

    // Expected-path warning; keep it off the runner's stderr like sibling
    // fault-injection tests do. Restored on scope exit.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    const f = try st.get("blocker/x.bin", 64, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    try std.testing.expectEqual(@as(u32, 4), f.bits.nbits);
    try std.testing.expectEqual(@as(u32, 0), f.bits.filled());
}

test "forget evicts after release and reapIdle frees idle empty entries" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-reap");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-reap");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Virtual clock: every stamp below is a caller-supplied instant, so the
    // reaper's idleness window is driven exactly -- an hour passes between
    // entry creation and the reap tick with no sleep and no wall clock.
    const t0: i64 = 1_000_000;

    // forget evicts from the map immediately; the entry dies with the last
    // release, not before (the reference must stay valid until then). The
    // open cache fd is part of that validity: it closes with the entry, so
    // holders never see their descriptor yanked and reused.
    const f1 = try st.get("cycle.bin", 64, t0);
    try std.testing.expectEqual(@as(usize, 1), st.files.count());
    try std.testing.expect(st.openCache(f1) >= 0);
    st.forget("cycle.bin");
    try std.testing.expectEqual(@as(usize, 0), st.files.count());
    f1.mu.lockUncancelable(std.testing.io);
    try std.testing.expect(f1.cache_fd >= 0);
    f1.mu.unlock(std.testing.io);
    st.releaseFile(f1);

    // A filled entry survives the reaper, but its idle fd is closed...
    const f2 = try st.get("kept.bin", 64, t0);
    try std.testing.expect(st.openCache(f2) >= 0);
    f2.mu.lockUncancelable(std.testing.io);
    f2.bits.set(0);
    f2.mu.unlock(std.testing.io);
    st.releaseFile(f2);

    // ...while an empty idle entry is evicted outright.
    const f3 = try st.get("empty.bin", 64, t0);
    st.releaseFile(f3);

    // ...and a pinned entry survives the reaper even when idle and empty:
    // an operator's pin must hold across reaping, not just culling.
    const f4 = try st.get("held.bin", 64, t0);
    try std.testing.expectEqual(@as(i32, 0), st.setPin("held.bin", true));
    st.releaseFile(f4);

    st.reapIdle(t0 + 3600, 60);
    try std.testing.expectEqual(@as(usize, 2), st.files.count());
    const f4b = st.lookupRef("held.bin").?;
    try std.testing.expectEqual(f4, f4b);
    st.releaseFile(f4b);
    try std.testing.expectEqual(@as(i32, 0), st.setPin("held.bin", false));
    const f2b = st.lookupRef("kept.bin").?;
    try std.testing.expectEqual(f2, f2b);
    f2b.mu.lockUncancelable(std.testing.io);
    try std.testing.expectEqual(@as(c_int, -1), f2b.cache_fd);
    try std.testing.expect(f2b.bits.get(0));
    f2b.mu.unlock(std.testing.io);
    st.releaseFile(f2b);
}

test "reapIdle allocation failure leaves the idle set intact" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-reap-oom");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-reap-oom");
    defer sys.deleteTree(std.testing.io, cache_d);

    var failing = std.testing.FailingAllocator.init(gpa, .{});
    var st = Store.init(failing.allocator(), std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const t0: i64 = 1_000_000;
    const a = try st.get("a.bin", 64, t0);
    st.releaseFile(a);
    const b = try st.get("b.bin", 64, t0);
    st.releaseFile(b);
    try std.testing.expectEqual(@as(usize, 2), st.files.count());

    // Next allocation is the candidate list: abort rather than reap a
    // HashMap-iteration prefix of the idle set.
    failing.fail_index = failing.alloc_index;
    st.reapIdle(t0 + 3600, 60);
    try std.testing.expectEqual(@as(usize, 2), st.files.count());
    try std.testing.expect(st.files.contains("a.bin"));
    try std.testing.expect(st.files.contains("b.bin"));

    failing.fail_index = std.math.maxInt(usize);
    st.reapIdle(t0 + 3600, 60);
    try std.testing.expectEqual(@as(usize, 0), st.files.count());
}

test "distrust drops sidecar and live marks but keeps data bytes and pins" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-distrust");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-distrust");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Cached piece with landed bytes plus an operator pin: distrust must
    // drop the trust state (sidecar + marks) without destroying either.
    const f = try st.get("d.bin", 32, sys.monoSec(std.testing.io));
    try std.testing.expect(st.openCache(f) >= 0);
    try std.testing.expectEqual(@as(isize, 32), sys.pwriteAll(f.cache_fd, "0123456789abcdef0123456789abcdef", 0));
    f.mu.lockUncancelable(std.testing.io);
    f.bits.set(1);
    f.mu.unlock(std.testing.io);
    _ = st.saveBits(f, false);
    try std.testing.expectEqual(@as(i32, 0), st.setPin("d.bin", true));
    st.releaseFile(f);

    const e0 = st.purge_epoch;
    st.distrust("d.bin");
    try std.testing.expectEqual(e0 + 1, st.purge_epoch);

    var mb: [sys.c.PATH_MAX]u8 = undefined;
    var db: [sys.c.PATH_MAX]u8 = undefined;
    var stbuf: c.struct_stat = undefined;
    // Sidecar unlinked: a later build (this run or post-restart) cannot
    // load the pre-write bits back.
    const mp = try st.cacheMetaPath(&mb, "d.bin");
    try std.testing.expect(sys.statPath(mp, &stbuf) != 0);
    // Data file and pin stay: unmarked pieces refill over intact bytes,
    // and the operator's pin outlives a failed stat.
    const dp = try st.cacheDataPath(&db, "d.bin");
    try std.testing.expect(sys.statPath(dp, &stbuf) == 0);
    try std.testing.expect(st.pinExists("d.bin"));

    // The live entry's marks are cleared under the same contract.
    const f2 = st.lookupRef("d.bin").?;
    defer st.releaseFile(f2);
    f2.mu.lockUncancelable(std.testing.io);
    try std.testing.expectEqual(@as(u32, 0), f2.bits.filled());
    f2.mu.unlock(std.testing.io);
    try std.testing.expect(st.wroteLocally(f2));

    // A rel with no live entry still loses its persisted sidecar.
    _ = try st.cacheMetaPath(&mb, "ghost.bin");
    var ghost_bits = try piece.Bitfield.init(gpa, 2);
    defer ghost_bits.deinit(gpa);
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(gpa);
    try ghost_bits.encode(16, 32, &blob, gpa);
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(mp, blob.items));
    st.distrust("ghost.bin");
    try std.testing.expect(sys.statPath(mp, &stbuf) != 0);

    // The next build starts from nothing instead of the dropped bits.
    const f3 = try st.get("ghost.bin", 32, sys.monoSec(std.testing.io));
    defer st.releaseFile(f3);
    f3.mu.lockUncancelable(std.testing.io);
    try std.testing.expectEqual(@as(u32, 0), f3.bits.filled());
    f3.mu.unlock(std.testing.io);
}

test "a finisher racing distrust never republishes the wiped marks" {
    // Regression harness for distrust's lock window: the sidecar unlink and
    // the live entry's mark wipe must sit in one file.mu section, the same
    // contract forget's dead stamp gives late finishers. Old shape ran them
    // apart, so a finishPiece saving in between wrote the pre-write marks
    // back over the dropped sidecar -- any schedule below leaving bits 0 or
    // 1 on disk trips the assertion.
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-dt-race");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-dt-race");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const f = try st.get("dt.bin", 64, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    try std.testing.expect(st.openCache(f) >= 0);

    var stop = std.atomic.Value(bool).init(false);
    const filler = try std.Thread.spawn(.{}, struct {
        fn run(s: *Store, file: *Store.Cached, halt: *std.atomic.Value(bool)) void {
            while (!halt.load(.acquire)) {
                // Piece 3 is the concurrent filler's own fresh post-write
                // hydration: re-marking it across a distrust is legitimate.
                if ((s.beginFill(file, 3, sys.monoSec(std.testing.io)) catch return) == .len)
                    s.finishPiece(file, 3, true, null, sys.monoSec(std.testing.io));
            }
        }
    }.run, .{ &st, f, &stop });
    defer {
        stop.store(true, .release);
        filler.join();
    }

    var round: usize = 0;
    while (round < 50) : (round += 1) {
        // Seed the exact state distrust erases: pre-write marks in memory
        // and persisted.
        f.mu.lockUncancelable(std.testing.io);
        f.bits.set(0);
        f.bits.set(1);
        f.mu.unlock(std.testing.io);
        _ = st.saveBits(f, false);

        st.distrust("dt.bin");

        var mb: [sys.c.PATH_MAX]u8 = undefined;
        const mp = try st.cacheMetaPath(&mb, "dt.bin");
        var blob_buf: [4096]u8 = undefined;
        if (sys.readFileBuf(&blob_buf, mp)) |blob| {
            // The filler's own post-distrust save can be mid-flight when this
            // read samples the file (open O_TRUNC landed, bytes not yet), so
            // a torn or empty prefix is an expected observation, not a
            // violation -- loadBits degrades exactly these to "cache as
            // empty". Only a decodable snapshot asserts anything: its bits 0
            // and 1 must stay clear.
            const decoded = piece.Bitfield.decode(gpa, blob, st.piece_size, 64) catch continue;
            defer gpa.free(decoded.bytes);
            try std.testing.expect(!decoded.get(0));
            try std.testing.expect(!decoded.get(1));
        } else |_| {}
    }
}

test "punchPiece refuses while a peer transfer is inflight" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-xfer");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-xfer");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Virtual clock: instants are caller-supplied, so the whole race window
    // below runs on exact timestamps -- an hour passes between samples with
    // no sleep and no dependence on how fast this test executes.
    const t0: i64 = 50_000;

    const f = try st.get("busy.bin", 64, t0);
    defer st.releaseFile(f);
    f.mu.lockUncancelable(std.testing.io);
    f.bits.set(0);
    f.mu.unlock(std.testing.io);

    _ = f.xfer.fetchAdd(1, .monotonic);
    try std.testing.expect(!st.punchPiece(f, 0, t0 + 3600));
    // Passive bit observation (hasPiece itself now counts as access and
    // would refresh the recency window under test).
    f.mu.lockUncancelable(std.testing.io);
    const piece0_cached = f.bits.get(0);
    f.mu.unlock(std.testing.io);
    try std.testing.expect(piece0_cached);

    // Transfer done: the idle cached piece culls normally.
    _ = f.xfer.fetchSub(1, .monotonic);
    try std.testing.expect(st.punchPiece(f, 0, t0 + 3600));
    try std.testing.expect(!st.hasPiece(f, 0, t0 + 3600));
}

test "readCache holds xfer for the read and restores it" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-rdxfer");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-rdxfer");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const content = "0123456789abcdef";
    const f = try st.get("warm.bin", 64, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    try std.testing.expect((try st.beginFill(f, 0, sys.monoSec(std.testing.io))) == .len);
    try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 0, content, null, sys.monoSec(std.testing.io)));

    // The warm-read path holds xfer across the pread (the same in-flight
    // claim a peer send carries), so a concurrent punchPiece cannot cut the
    // hole under the read; the count must be balanced once the read returns.
    try std.testing.expectEqual(@as(u32, 0), f.xfer.load(.monotonic));
    var dbuf: [content.len]u8 = undefined;
    try std.testing.expectEqual(@as(isize, content.len), st.readCache(f, &dbuf, 0, sys.monoSec(std.testing.io)));
    try std.testing.expectEqualSlices(u8, content, &dbuf);
    try std.testing.expectEqual(@as(u32, 0), f.xfer.load(.monotonic));

    // With no read in flight the same idle piece still culls normally: the
    // claim gates the punch window, it does not block culling.
    const idle = sys.monoSec(std.testing.io) + 3600;
    try std.testing.expect(st.punchPiece(f, 0, idle));
    try std.testing.expect(!st.hasPiece(f, 0, idle));
}

test "copyIntoCache does not pwrite under an in-flight transfer" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-wt-xfer");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-wt-xfer");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    var first: [16]u8 = undefined;
    @memset(&first, 0xAA);
    var next: [16]u8 = undefined;
    @memset(&next, 0xBB);

    const f = try st.get("xferwt.bin", 16, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    try std.testing.expect(st.copyIntoCache(f, 0, &first));
    try std.testing.expect(st.hasPiece(f, 0, sys.monoSec(std.testing.io)));

    // Peer sendfile / FUSE read holds xfer across the cache fd. A
    // write-through of different bytes must not pwrite under that copy:
    // the in-flight reader would mark a mix of 0xAA and 0xBB filled.
    st.beginXfer(f);
    try std.testing.expect(!st.copyIntoCache(f, 0, &next));
    try std.testing.expect(st.wroteLocally(f));
    try std.testing.expect(!st.hasPiece(f, 0, sys.monoSec(std.testing.io)));
    var rd: [16]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 16), st.readCache(f, &rd, 0, sys.monoSec(std.testing.io)));
    try std.testing.expectEqualSlices(u8, &first, &rd);
    st.endXfer(f);

    // A retry of the bytes already in the cache is a no-op even while
    // xfer is held: re-pwrite is skipped, marks stay, writes does not bump.
    const f2 = try st.get("retry.bin", 16, sys.monoSec(std.testing.io));
    defer st.releaseFile(f2);
    try std.testing.expect(st.copyIntoCache(f2, 0, &first));
    f2.mu.lockUncancelable(std.testing.io);
    const w0 = f2.writes;
    f2.mu.unlock(std.testing.io);
    st.beginXfer(f2);
    try std.testing.expect(st.copyIntoCache(f2, 0, &first));
    try std.testing.expect(st.hasPiece(f2, 0, sys.monoSec(std.testing.io)));
    f2.mu.lockUncancelable(std.testing.io);
    try std.testing.expectEqual(w0, f2.writes);
    f2.mu.unlock(std.testing.io);
    st.endXfer(f2);
}

test "fill completion and piece probes refresh the cull recency window" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-recency-fill");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-recency-fill");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Virtual clock: the fill below starts at t0 and lands an hour later,
    // exactly the "fill slower than the cull window" shape that is
    // impossible to stage against the real clock without sleeping.
    const t0: i64 = 100_000;

    const f = try st.get("slow.bin", 64, t0);
    defer st.releaseFile(f);

    // A fill that outruns the cull window: the claim stamped last_access at
    // its start, so on completion the entry reads as window-stale. Regression:
    // punchPiece could hole the just-filled piece before the reader's
    // readCache stamped, serving hole zeros behind a bit this read trusted.
    try std.testing.expect((try st.beginFill(f, 0, t0)) == .len);
    try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 0, "0123456789abcdef", null, t0 + 3600));
    try std.testing.expect(!st.punchPiece(f, 0, t0 + 3600));
    try std.testing.expect(st.hasPiece(f, 0, t0 + 3600));

    // Same guard on the probe itself: a warm read answers every bit check
    // without filling anything, so hasPiece must carry the stamp that keeps
    // a concurrent punch out of the check-to-readCache window.
    _ = st.hasPiece(f, 1, t0 + 3600);
    try std.testing.expect(!st.punchPiece(f, 0, t0 + 3600));

    // Once genuinely idle past the window, the same piece culls normally:
    // the stamps close race windows, they do not block culling.
    try std.testing.expect(st.punchPiece(f, 0, t0 + 3600 + 11)); // 10s recency_secs + 1
    try std.testing.expect(!st.hasPiece(f, 0, t0 + 3600));
}

// Re-execution is the normal consequence of retries and redeliveries, so
// the fill path's dedup contract gets a twice-versus-once proof: a second
// completeFill of the same piece must be absorbed by the claim (the second
// beginFill answers .filled, no re-fetch) and leave bitfield, sidecar
// bytes, and cached bytes identical to a store where the fill ran once.
test "a piece filled twice ends in the same state as filled once" {
    const gpa = std.testing.allocator;
    var ob1: [128]u8 = undefined;
    var cb1: [128]u8 = undefined;
    var ob2: [128]u8 = undefined;
    var cb2: [128]u8 = undefined;
    const origin_1 = try sys.scratchDir(&ob1, "modelfs-o-fill-once");
    defer sys.deleteTree(std.testing.io, origin_1);
    const cache_1 = try sys.scratchDir(&cb1, "modelfs-c-fill-once");
    defer sys.deleteTree(std.testing.io, cache_1);
    const origin_2 = try sys.scratchDir(&ob2, "modelfs-o-fill-twice");
    defer sys.deleteTree(std.testing.io, origin_2);
    const cache_2 = try sys.scratchDir(&cb2, "modelfs-c-fill-twice");
    defer sys.deleteTree(std.testing.io, cache_2);

    var once = Store.init(gpa, std.testing.io, origin_1, cache_1, 16);
    defer once.deinit();
    var twice = Store.init(gpa, std.testing.io, origin_2, cache_2, 16);
    defer twice.deinit();
    try std.testing.expectEqual(@as(i32, 0), once.ensureLayout());
    try std.testing.expectEqual(@as(i32, 0), twice.ensureLayout());

    const content = "0123456789abcdef";
    const f1 = try once.get("fill.bin", 64, sys.monoSec(std.testing.io));
    defer once.releaseFile(f1);
    const f2 = try twice.get("fill.bin", 64, sys.monoSec(std.testing.io));
    defer twice.releaseFile(f2);

    // Once...
    try std.testing.expect((try once.beginFill(f1, 0, sys.monoSec(std.testing.io))) == .len);
    try std.testing.expectEqual(@as(i32, 0), once.completeFill(f1, 0, content, null, sys.monoSec(std.testing.io)));

    // ...and twice. The second claim must answer .filled -- the dedup a
    // retried fetch depends on: the piece is skipped, not re-fetched.
    try std.testing.expect((try twice.beginFill(f2, 0, sys.monoSec(std.testing.io))) == .len);
    try std.testing.expectEqual(@as(i32, 0), twice.completeFill(f2, 0, content, null, sys.monoSec(std.testing.io)));
    try std.testing.expect((try twice.beginFill(f2, 0, sys.monoSec(std.testing.io))) == .filled);

    try std.testing.expect(once.hasPiece(f1, 0, sys.monoSec(std.testing.io)));
    try std.testing.expect(twice.hasPiece(f2, 0, sys.monoSec(std.testing.io)));

    var mbuf1: [sys.c.PATH_MAX]u8 = undefined;
    var mbuf2: [sys.c.PATH_MAX]u8 = undefined;
    const meta1 = try once.cacheMetaPath(&mbuf1, "fill.bin");
    const meta2 = try twice.cacheMetaPath(&mbuf2, "fill.bin");
    var blob1: [4096]u8 = undefined;
    var blob2: [4096]u8 = undefined;
    const side1 = try sys.readFileBuf(&blob1, meta1);
    const side2 = try sys.readFileBuf(&blob2, meta2);
    try std.testing.expectEqualSlices(u8, side1, side2);

    var dbuf1: [content.len]u8 = undefined;
    var dbuf2: [content.len]u8 = undefined;
    try std.testing.expectEqual(@as(isize, content.len), once.readCache(f1, &dbuf1, 0, sys.monoSec(std.testing.io)));
    try std.testing.expectEqual(@as(isize, content.len), twice.readCache(f2, &dbuf2, 0, sys.monoSec(std.testing.io)));
    try std.testing.expectEqualStrings(&dbuf1, &dbuf2);
}

// Same twice-versus-once proof for the write-through marking path: a
// repeated copyIntoCache re-marks the same pieces and converges on the
// identical persisted state instead of double-counting or corrupting.
test "write-through copied twice marks the same pieces as one copy" {
    const gpa = std.testing.allocator;
    var ob1: [128]u8 = undefined;
    var cb1: [128]u8 = undefined;
    var ob2: [128]u8 = undefined;
    var cb2: [128]u8 = undefined;
    const origin_1 = try sys.scratchDir(&ob1, "modelfs-o-wt-once");
    defer sys.deleteTree(std.testing.io, origin_1);
    const cache_1 = try sys.scratchDir(&cb1, "modelfs-c-wt-once");
    defer sys.deleteTree(std.testing.io, cache_1);
    const origin_2 = try sys.scratchDir(&ob2, "modelfs-o-wt-twice");
    defer sys.deleteTree(std.testing.io, origin_2);
    const cache_2 = try sys.scratchDir(&cb2, "modelfs-c-wt-twice");
    defer sys.deleteTree(std.testing.io, cache_2);

    var once = Store.init(gpa, std.testing.io, origin_1, cache_1, 16);
    defer once.deinit();
    var twice = Store.init(gpa, std.testing.io, origin_2, cache_2, 16);
    defer twice.deinit();
    try std.testing.expectEqual(@as(i32, 0), once.ensureLayout());
    try std.testing.expectEqual(@as(i32, 0), twice.ensureLayout());

    const chunk = "abcdefghijklmnop";
    const f1 = try once.get("wt.bin", 32, sys.monoSec(std.testing.io));
    defer once.releaseFile(f1);
    const f2 = try twice.get("wt.bin", 32, sys.monoSec(std.testing.io));
    defer twice.releaseFile(f2);

    try std.testing.expect(once.copyIntoCache(f1, 0, chunk));

    // The retry lands the same bytes again: still true (marks reapplied),
    // never a false negative that would send reads back to the origin.
    try std.testing.expect(twice.copyIntoCache(f2, 0, chunk));
    try std.testing.expect(twice.copyIntoCache(f2, 0, chunk));

    try std.testing.expect(once.hasPiece(f1, 0, sys.monoSec(std.testing.io)));
    try std.testing.expect(twice.hasPiece(f2, 0, sys.monoSec(std.testing.io)));
    try std.testing.expect(!twice.hasPiece(f2, 1, sys.monoSec(std.testing.io)));

    // Generation must match one copy: a retry must not bump writes again.
    f1.mu.lockUncancelable(std.testing.io);
    const w_once = f1.writes;
    f1.mu.unlock(std.testing.io);
    f2.mu.lockUncancelable(std.testing.io);
    const w_twice = f2.writes;
    f2.mu.unlock(std.testing.io);
    try std.testing.expectEqual(w_once, w_twice);
    try std.testing.expectEqual(@as(u64, 1), w_once);

    var mbuf1: [sys.c.PATH_MAX]u8 = undefined;
    var mbuf2: [sys.c.PATH_MAX]u8 = undefined;
    const meta1 = try once.cacheMetaPath(&mbuf1, "wt.bin");
    const meta2 = try twice.cacheMetaPath(&mbuf2, "wt.bin");
    var blob1: [4096]u8 = undefined;
    var blob2: [4096]u8 = undefined;
    const side1 = try sys.readFileBuf(&blob1, meta1);
    const side2 = try sys.readFileBuf(&blob2, meta2);
    try std.testing.expectEqualSlices(u8, side1, side2);
}

test "write-through overwrite of a marked piece still lands the new bytes" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-wt-ovw");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-wt-ovw");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    var first: [16]u8 = undefined;
    @memset(&first, 0xAA);
    var next: [16]u8 = undefined;
    @memset(&next, 0xBB);

    const f = try st.get("ovw.bin", 16, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    try std.testing.expect(st.copyIntoCache(f, 0, &first));
    try std.testing.expect(st.copyIntoCache(f, 0, &next));
    try std.testing.expect(st.hasPiece(f, 0, sys.monoSec(std.testing.io)));

    var rd: [16]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 16), st.readCache(f, &rd, 0, sys.monoSec(std.testing.io)));
    try std.testing.expectEqualSlices(u8, &next, &rd);

    // The overwrite is a content change, not a retry: writes must bump so
    // wroteLocally() keeps peer fills off the path (a fleet peer could
    // still hold the pre-rewrite bytes), and the recorded digest must name
    // the new bytes so verification and the manifest publish describe what
    // the cache fd actually holds.
    f.mu.lockUncancelable(std.testing.io);
    const w = f.writes;
    f.mu.unlock(std.testing.io);
    try std.testing.expectEqual(@as(u64, 2), w);
    const expect = st.expectedHash(f, 0, 0);
    var want: [piece.digest_len]u8 = undefined;
    piece.digest(&next, &want);
    try std.testing.expect(expect != null);
    try std.testing.expectEqualSlices(u8, &want, &expect.?);
}

// A destructive job run twice in quick succession must change nothing the
// first run did not: the second punch finds its own cleared mark and stops
// before any hole cut, sidecar rewrite, or counter bump.
test "a punched piece punched again stays culled with nothing rewritten" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-pp-twice");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-pp-twice");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Virtual clock: the fill lands at t0 and the punch tick runs an hour
    // later, with no wall-clock reads anywhere in between.
    const t0: i64 = 20_000;

    const f = try st.get("punch.bin", 64, t0);
    defer st.releaseFile(f);
    try std.testing.expect((try st.beginFill(f, 0, t0)) == .len);
    try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 0, "0123456789abcdef", null, t0));

    try std.testing.expect(st.punchPiece(f, 0, t0 + 3600));

    var mbuf: [sys.c.PATH_MAX]u8 = undefined;
    const meta = try st.cacheMetaPath(&mbuf, "punch.bin");
    var before: [4096]u8 = undefined;
    var after: [4096]u8 = undefined;
    const side_before = try sys.readFileBuf(&before, meta);

    try std.testing.expect(!st.punchPiece(f, 0, t0 + 3600));
    try std.testing.expect(!st.hasPiece(f, 0, t0 + 3600));

    const side_after = try sys.readFileBuf(&after, meta);
    try std.testing.expectEqualSlices(u8, side_before, side_after);
    try std.testing.expectEqual(@as(u32, 1), st.stats.pieces_culled.load(.monotonic));
}

// The pin marker is the guard punchPiece defers to, so a repeated pin or
// unpin (operator double-runs the CLI, a script re-executes after a timeout)
// must converge on the single-marker state instead of erroring or piling up
// artifacts: pin twice leaves exactly one marker, unpin twice absorbs the
// already-gone second unlink as success.
test "pin and unpin run twice converge on the one-marker state" {
    const gpa: std.mem.Allocator = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-pin-twice");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-pin-twice");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const pp = try st.cachePinPath(&pbuf, "m.bin");
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    const pp_z = try sys.toZ(&zbuf, std.mem.span(pp));
    var stat: c.struct_stat = undefined;

    // Pin twice: both runs succeed and the same single marker answers.
    try std.testing.expectEqual(@as(i32, 0), st.setPin("m.bin", true));
    try std.testing.expectEqual(@as(i32, 0), st.setPin("m.bin", true));
    try std.testing.expectEqual(@as(i32, 0), sys.statPath(pp_z, &stat));
    try std.testing.expectEqual(@as(u64, 0), @as(u64, @intCast(stat.st_size)));
    try std.testing.expect(st.pinExists("m.bin"));

    // Unpin twice: the first removes it, the second is the normal
    // already-gone case reported as success.
    try std.testing.expectEqual(@as(i32, 0), st.setPin("m.bin", false));
    try std.testing.expect(sys.statPath(pp_z, &stat) != 0);
    try std.testing.expectEqual(@as(i32, 0), st.setPin("m.bin", false));
    try std.testing.expect(!st.pinExists("m.bin"));
}

// Re-execution of unlink is the FUSE retry after a lost reply (daemon
// crash between origin unlink and the response, or a dropped FUSE
// buffer). The origin name is already gone, so the second call is
// success (ENOENT would fail the FUSE retry after the file had already
// converged); cache identity must still drop, or a same-size recreate
// serves the deleted file's bytes. Twice-versus-once: both end with
// origin, data, meta, and pin gone.
test "unlinkOrigin twice matches once, and a retry after origin-only unlink still drops cache" {
    const gpa = std.testing.allocator;
    var ob1: [128]u8 = undefined;
    var cb1: [128]u8 = undefined;
    var ob2: [128]u8 = undefined;
    var cb2: [128]u8 = undefined;
    const origin_1 = try sys.scratchDir(&ob1, "modelfs-o-ul-once");
    defer sys.deleteTree(std.testing.io, origin_1);
    const cache_1 = try sys.scratchDir(&cb1, "modelfs-c-ul-once");
    defer sys.deleteTree(std.testing.io, cache_1);
    const origin_2 = try sys.scratchDir(&ob2, "modelfs-o-ul-twice");
    defer sys.deleteTree(std.testing.io, origin_2);
    const cache_2 = try sys.scratchDir(&cb2, "modelfs-c-ul-twice");
    defer sys.deleteTree(std.testing.io, cache_2);

    var once = Store.init(gpa, std.testing.io, origin_1, cache_1, 16);
    defer once.deinit();
    var twice = Store.init(gpa, std.testing.io, origin_2, cache_2, 16);
    defer twice.deinit();
    try std.testing.expectEqual(@as(i32, 0), once.ensureLayout());
    try std.testing.expectEqual(@as(i32, 0), twice.ensureLayout());

    const content = "0123456789abcdef";
    const now = sys.monoSec(std.testing.io);
    var op1: [sys.c.PATH_MAX]u8 = undefined;
    var op2: [sys.c.PATH_MAX]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try once.originPath(&op1, "gone.bin"), content));
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try twice.originPath(&op2, "gone.bin"), content));

    const f1 = try once.get("gone.bin", content.len, now);
    defer once.releaseFile(f1);
    const f2 = try twice.get("gone.bin", content.len, now);
    defer twice.releaseFile(f2);
    try std.testing.expect((try once.beginFill(f1, 0, now)) == .len);
    try std.testing.expectEqual(@as(i32, 0), once.completeFill(f1, 0, content, null, now));
    try std.testing.expect((try twice.beginFill(f2, 0, now)) == .len);
    try std.testing.expectEqual(@as(i32, 0), twice.completeFill(f2, 0, content, null, now));
    try std.testing.expectEqual(@as(i32, 0), once.setPin("gone.bin", true));
    try std.testing.expectEqual(@as(i32, 0), twice.setPin("gone.bin", true));

    try std.testing.expectEqual(@as(i32, 0), once.unlinkOrigin("gone.bin"));
    try std.testing.expectEqual(@as(i32, 0), twice.unlinkOrigin("gone.bin"));
    // FUSE retry after a lost reply: the name is gone, the second call
    // must not fail ENOENT.
    try std.testing.expectEqual(@as(i32, 0), twice.unlinkOrigin("gone.bin"));

    var stbuf: c.struct_stat = undefined;
    try std.testing.expect(sys.statPath(try once.originPath(&op1, "gone.bin"), &stbuf) != 0);
    try std.testing.expect(sys.statPath(try twice.originPath(&op2, "gone.bin"), &stbuf) != 0);
    var mb1: [sys.c.PATH_MAX]u8 = undefined;
    var mb2: [sys.c.PATH_MAX]u8 = undefined;
    try std.testing.expect(sys.statPath(try once.cacheMetaPath(&mb1, "gone.bin"), &stbuf) != 0);
    try std.testing.expect(sys.statPath(try twice.cacheMetaPath(&mb2, "gone.bin"), &stbuf) != 0);
    var db1: [sys.c.PATH_MAX]u8 = undefined;
    var db2: [sys.c.PATH_MAX]u8 = undefined;
    try std.testing.expect(sys.statPath(try once.cacheDataPath(&db1, "gone.bin"), &stbuf) != 0);
    try std.testing.expect(sys.statPath(try twice.cacheDataPath(&db2, "gone.bin"), &stbuf) != 0);
    try std.testing.expect(!once.pinExists("gone.bin"));
    try std.testing.expect(!twice.pinExists("gone.bin"));

    // Crash window: origin unlinked, forget never ran, retry must still
    // drop the sidecar so a same-size recreate cannot resurrect bits.
    var ob3: [128]u8 = undefined;
    var cb3: [128]u8 = undefined;
    const origin_3 = try sys.scratchDir(&ob3, "modelfs-o-ul-retry");
    defer sys.deleteTree(std.testing.io, origin_3);
    const cache_3 = try sys.scratchDir(&cb3, "modelfs-c-ul-retry");
    defer sys.deleteTree(std.testing.io, cache_3);
    var retry = Store.init(gpa, std.testing.io, origin_3, cache_3, 16);
    defer retry.deinit();
    try std.testing.expectEqual(@as(i32, 0), retry.ensureLayout());
    var op3: [sys.c.PATH_MAX]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try retry.originPath(&op3, "gone.bin"), content));
    const f3 = try retry.get("gone.bin", content.len, now);
    defer retry.releaseFile(f3);
    try std.testing.expect((try retry.beginFill(f3, 0, now)) == .len);
    try std.testing.expectEqual(@as(i32, 0), retry.completeFill(f3, 0, content, null, now));
    try std.testing.expect(retry.hasPiece(f3, 0, now));
    try std.testing.expectEqual(@as(i32, 0), c.unlink(try retry.originPath(&op3, "gone.bin")));
    var mb3: [sys.c.PATH_MAX]u8 = undefined;
    const meta3 = try retry.cacheMetaPath(&mb3, "gone.bin");
    try std.testing.expect(sys.statPath(meta3, &stbuf) == 0);
    try std.testing.expectEqual(@as(i32, 0), retry.unlinkOrigin("gone.bin"));
    try std.testing.expect(sys.statPath(meta3, &stbuf) != 0);
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try retry.originPath(&op3, "gone.bin"), content));
    const f4 = try retry.get("gone.bin", content.len, now);
    defer retry.releaseFile(f4);
    try std.testing.expectEqual(@as(u32, 0), f4.bits.filled());

    // A directory at that name stays EISDIR: ENOENT-as-success is only the
    // already-gone file case, not "unlink whatever is missing or wrong".
    try std.testing.expectEqual(@as(i32, 0), once.mkdirOrigin("subdir", 0o755));
    try std.testing.expectEqual(@as(i32, -c.EISDIR), once.unlinkOrigin("subdir"));
}

// Same retry contract for rename: an origin-only rename (first attempt
// completed, reply lost) leaves both names' sidecars behind; the ENOENT
// retry must still drop them, or a same-size recreate at either name
// serves the pre-rename inode.
test "renameOrigin on a retry after origin-only rename still drops cache" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-rn-retry");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-rn-retry");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const content = "0123456789abcdef";
    const now = sys.monoSec(std.testing.io);
    var oa: [sys.c.PATH_MAX]u8 = undefined;
    var obuf: [sys.c.PATH_MAX]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try st.originPath(&oa, "a.bin"), content));
    const f = try st.get("a.bin", content.len, now);
    defer st.releaseFile(f);
    try std.testing.expect((try st.beginFill(f, 0, now)) == .len);
    try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 0, content, null, now));
    try std.testing.expect(st.hasPiece(f, 0, now));

    // First attempt's origin step, then crash before forget.
    try std.testing.expectEqual(@as(i32, 0), c.rename(try st.originPath(&oa, "a.bin"), try st.originPath(&obuf, "b.bin")));
    var ma: [sys.c.PATH_MAX]u8 = undefined;
    var stbuf: c.struct_stat = undefined;
    try std.testing.expect(sys.statPath(try st.cacheMetaPath(&ma, "a.bin"), &stbuf) == 0);

    try std.testing.expectEqual(@as(i32, -c.ENOENT), st.renameOrigin("a.bin", "b.bin", 0));
    try std.testing.expect(sys.statPath(try st.cacheMetaPath(&ma, "a.bin"), &stbuf) != 0);
    var mb: [sys.c.PATH_MAX]u8 = undefined;
    try std.testing.expect(sys.statPath(try st.cacheMetaPath(&mb, "b.bin"), &stbuf) != 0);
    try std.testing.expect(sys.statPath(try st.originPath(&oa, "a.bin"), &stbuf) != 0);
    try std.testing.expect(sys.statPath(try st.originPath(&obuf, "b.bin"), &stbuf) == 0);

    const f2 = try st.get("b.bin", content.len, now);
    defer st.releaseFile(f2);
    try std.testing.expectEqual(@as(u32, 0), f2.bits.filled());

    // Twice-versus-once on a fresh pair: rename then retry leave the same
    // origin layout and empty cache as a single rename.
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try st.originPath(&oa, "c.bin"), content));
    const f3 = try st.get("c.bin", content.len, now);
    defer st.releaseFile(f3);
    try std.testing.expect((try st.beginFill(f3, 0, now)) == .len);
    try std.testing.expectEqual(@as(i32, 0), st.completeFill(f3, 0, content, null, now));
    try std.testing.expectEqual(@as(i32, 0), st.renameOrigin("c.bin", "d.bin", 0));
    try std.testing.expectEqual(@as(i32, -c.ENOENT), st.renameOrigin("c.bin", "d.bin", 0));
    try std.testing.expect(sys.statPath(try st.originPath(&oa, "c.bin"), &stbuf) != 0);
    try std.testing.expect(sys.statPath(try st.originPath(&obuf, "d.bin"), &stbuf) == 0);
    try std.testing.expect(sys.statPath(try st.cacheMetaPath(&ma, "c.bin"), &stbuf) != 0);
    try std.testing.expect(sys.statPath(try st.cacheMetaPath(&mb, "d.bin"), &stbuf) != 0);
}

test "mkdirOrigin twice matches once, and a file at that name stays EEXIST" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-mkdir-twice");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-mkdir-twice");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    try std.testing.expectEqual(@as(i32, 0), st.mkdirOrigin("sub", 0o755));
    // FUSE retry after a lost reply: the directory exists, the second call
    // must not fail EEXIST.
    try std.testing.expectEqual(@as(i32, 0), st.mkdirOrigin("sub", 0o755));

    var stbuf: c.struct_stat = undefined;
    var pb: [sys.c.PATH_MAX]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 0), sys.lstatPath(try st.originPath(&pb, "sub"), &stbuf));
    try std.testing.expect((stbuf.st_mode & c.S_IFMT) == c.S_IFDIR);

    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try st.originPath(&pb, "file.bin"), "x"));
    try std.testing.expectEqual(@as(i32, -c.EEXIST), st.mkdirOrigin("file.bin", 0o755));
}

test "rmdirOrigin twice matches once, a file stays ENOTDIR, nonempty stays ENOTEMPTY" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-rmdir-twice");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-rmdir-twice");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    try std.testing.expectEqual(@as(i32, 0), st.mkdirOrigin("sub", 0o755));
    try std.testing.expectEqual(@as(i32, 0), st.rmdirOrigin("sub"));
    // FUSE retry after a lost reply: the directory is gone, the second call
    // must not fail ENOENT.
    try std.testing.expectEqual(@as(i32, 0), st.rmdirOrigin("sub"));

    var stbuf: c.struct_stat = undefined;
    var pb: [sys.c.PATH_MAX]u8 = undefined;
    try std.testing.expect(sys.lstatPath(try st.originPath(&pb, "sub"), &stbuf) != 0);

    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try st.originPath(&pb, "file.bin"), "x"));
    try std.testing.expectEqual(@as(i32, -c.ENOTDIR), st.rmdirOrigin("file.bin"));

    try std.testing.expectEqual(@as(i32, 0), st.mkdirOrigin("full", 0o755));
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try st.originPath(&pb, "full/x.bin"), "x"));
    try std.testing.expectEqual(@as(i32, -c.ENOTEMPTY), st.rmdirOrigin("full"));

    // FUSE "/" is the origin root. Removing it would delete the export.
    try std.testing.expectEqual(@as(i32, -c.EBUSY), st.rmdirOrigin(""));
}

test "punchPiece refuses pinned and freshly accessed entries" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-pp-gates");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-pp-gates");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Virtual clock: the entry is created at t0 and every decision below
    // samples its own exact instant.
    const t0: i64 = 30_000;

    const f = try st.get("gated.bin", 64, t0);
    defer st.releaseFile(f);
    f.mu.lockUncancelable(std.testing.io);
    f.bits.set(0);
    f.mu.unlock(std.testing.io);

    // A pinned piece must survive culling no matter how idle it sits.
    try std.testing.expectEqual(@as(i32, 0), st.setPin("gated.bin", true));
    try std.testing.expect(!st.punchPiece(f, 0, t0 + 3600));
    try std.testing.expect(st.hasPiece(f, 0, t0 + 3600));
    try std.testing.expectEqual(@as(i32, 0), st.setPin("gated.bin", false));

    // A piece touched inside the recency window must not punch: a read,
    // fill, or transfer may still be using those pages. The instant comes
    // from the caller, so the exact boundary is pinned virtually -- still
    // guarded one tick before the window closes, culled the moment it does,
    // with no sleeping and no dependence on how fast this test runs (and no
    // second-boundary straddle: every sample below is a fixed offset of t0).
    const touched = t0 + 3600;
    _ = st.hasPiece(f, 0, touched);
    try std.testing.expect(!st.punchPiece(f, 0, touched + Store.recency_secs - 1));

    // Past the window with nothing held, the same piece culls normally.
    try std.testing.expect(st.punchPiece(f, 0, touched + Store.recency_secs));
}

test "cullOne punches the least recently used live entry first" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-lru");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-lru");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Two idle cached entries aged past the recency window relative to the
    // caller-supplied instant: the victim must be picked by last_access
    // alone, never by map iteration order. Virtual stamps pin the exact
    // boundary with no sleeping.
    const t0 = sys.monoSec(std.testing.io);
    {
        // Creation stamps are caller-supplied instants: old.bin is born an
        // hour before new.bin, no poking required.
        const old = try st.get("old.bin", 16, t0);
        const new = try st.get("new.bin", 16, t0 + 60);
        old.mu.lockUncancelable(std.testing.io);
        old.bits.set(0);
        old.mu.unlock(std.testing.io);
        new.mu.lockUncancelable(std.testing.io);
        new.bits.set(0);
        new.mu.unlock(std.testing.io);
        st.releaseFile(old);
        st.releaseFile(new);
    }
    const now = t0 + 60 + Store.recency_secs;
    try std.testing.expect(st.cullOne(now));

    {
        const old = st.lookupRef("old.bin").?;
        defer st.releaseFile(old);
        const new = st.lookupRef("new.bin").?;
        defer st.releaseFile(new);
        old.mu.lockUncancelable(std.testing.io);
        const old_punched = !old.bits.get(0);
        old.mu.unlock(std.testing.io);
        new.mu.lockUncancelable(std.testing.io);
        const new_kept = new.bits.get(0);
        new.mu.unlock(std.testing.io);
        try std.testing.expect(old_punched);
        try std.testing.expect(new_kept);
    }

    // The next round moves to the previously newer entry: LRU order drains
    // candidates oldest-first instead of replaying the same victim.
    try std.testing.expect(st.cullOne(now));
    const new2 = st.lookupRef("new.bin").?;
    defer st.releaseFile(new2);
    new2.mu.lockUncancelable(std.testing.io);
    const new_punched = !new2.bits.get(0);
    new2.mu.unlock(std.testing.io);
    try std.testing.expect(new_punched);
}

test "cullOne breaks equal-recency ties by rel bytes, not map order" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-lru-tie");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-lru-tie");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Identical stamps on every entry: the tie must resolve by rel bytes
    // ("a.bin" before "b.bin"), so the victim is a function of durable state
    // alone even though b.bin entered the map first.
    const t0 = sys.monoSec(std.testing.io);
    for ([_][]const u8{ "b.bin", "a.bin" }) |rel| {
        // Both entries born stamped t0: the tie is real, not an artifact of
        // creation order or clock granularity.
        const f = try st.get(rel, 16, t0);
        f.mu.lockUncancelable(std.testing.io);
        f.bits.set(0);
        f.mu.unlock(std.testing.io);
        st.releaseFile(f);
    }

    const now = t0 + Store.recency_secs;
    try std.testing.expect(st.cullOne(now));
    {
        const a = st.lookupRef("a.bin").?;
        defer st.releaseFile(a);
        const b = st.lookupRef("b.bin").?;
        defer st.releaseFile(b);
        a.mu.lockUncancelable(std.testing.io);
        const a_punched = !a.bits.get(0);
        a.mu.unlock(std.testing.io);
        b.mu.lockUncancelable(std.testing.io);
        const b_kept = b.bits.get(0);
        b.mu.unlock(std.testing.io);
        try std.testing.expect(a_punched);
        try std.testing.expect(b_kept);
    }

    try std.testing.expect(st.cullOne(now));
    {
        const b = st.lookupRef("b.bin").?;
        defer st.releaseFile(b);
        b.mu.lockUncancelable(std.testing.io);
        const b_punched = !b.bits.get(0);
        b.mu.unlock(std.testing.io);
        try std.testing.expect(b_punched);
    }
    // Every live candidate drained: nothing left to punch.
    try std.testing.expect(!st.cullOne(now));
}

/// Writes a meta sidecar for rel naming exactly `filled` pieces as cached,
/// the way finishPiece/saveBits would leave it.
fn writeFilledSidecar(st: *Store, rel: []const u8, size: u64, filled: []const u32) !void {
    var bits = try piece.Bitfield.init(std.testing.allocator, piece.count(size, st.piece_size));
    defer bits.deinit(std.testing.allocator);
    for (filled) |i| bits.set(i);
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(std.testing.allocator);
    try bits.encode(st.piece_size, size, &blob, std.testing.allocator);
    var mb: [sys.c.PATH_MAX]u8 = undefined;
    const mp = try st.cacheMetaPath(&mb, rel);
    try std.testing.expectEqual(@as(i32, 0), sys.writeFileNoFollow(mp, blob.items));
}

test "punchDisk refuses a rel owned by a live entry" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-pd-live");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-pd-live");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Disk-only victim sampled by walkData, then hydrated into a live entry
    // before the punch runs: the entry's bits say filled, so punching would
    // serve hole zeros behind them. Regression: punchDisk never rechecked
    // map membership between walkData's sample and the punch.
    const pattern = "0123456789abcdef";
    var db: [sys.c.PATH_MAX]u8 = undefined;
    const dp = try st.cacheDataPath(&db, "live.bin");
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(dp, pattern));
    try writeFilledSidecar(&st, "live.bin", pattern.len, &.{0});

    const f = try st.get("live.bin", pattern.len, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    try std.testing.expect(!st.punchDisk("live.bin"));

    var rb: [16]u8 = undefined;
    const got = sys.readFileBuf(&rb, dp) catch return error.ReadFailed;
    try std.testing.expectEqualStrings(pattern, got);
}

test "punchDisk punches an orphaned rel and publishes cleared bits" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-pd-orph");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-pd-orph");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const pattern = "0123456789abcdef";
    var db: [sys.c.PATH_MAX]u8 = undefined;
    const dp = try st.cacheDataPath(&db, "orph.bin");
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(dp, pattern));
    try writeFilledSidecar(&st, "orph.bin", pattern.len, &.{0});

    const e0 = st.purge_epoch;
    try std.testing.expect(st.punchDisk("orph.bin"));
    try std.testing.expectEqual(e0 + 1, st.purge_epoch);
    // A successful punch must land in the counters status.json publishes:
    // culling volume is otherwise invisible (the per-piece log line is gone).
    try std.testing.expectEqual(@as(u64, 1), st.stats.pieces_culled.load(.monotonic));

    // The sidecar rewrite precedes the epoch bump, so any builder sampling
    // the new epoch reads post-punch bits: a fresh entry must not believe
    // the punched piece is cached.
    var mb: [sys.c.PATH_MAX]u8 = undefined;
    const mp = try st.cacheMetaPath(&mb, "orph.bin");
    const blob = try sys.readFileAlloc(gpa, mp, 4096);
    defer gpa.free(blob);
    var decoded = try piece.Bitfield.decode(gpa, blob, st.piece_size, pattern.len);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), decoded.filled());

    const f = try st.get("orph.bin", pattern.len, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    try std.testing.expect(!f.bits.get(0));
}

test "punchDisk reclaims a data file no sidecar vouches for" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-pd-void");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-pd-void");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Orphan of the crash-before-first-save shape: allocated bytes on disk,
    // no sidecar. walkData samples it (blocks > 0), but lastSet finds
    // nothing to punch; regression: the disk scan bailed here forever, so
    // such blocks were invisible to every cull round and could strand the
    // watermark below bcull with victims that never free anything.
    const pattern = "0123456789abcdef0123456789abcdef";
    var db: [sys.c.PATH_MAX]u8 = undefined;
    const dp = try st.cacheDataPath(&db, "orphan.bin");
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(dp, pattern));

    // A rel with a live map entry is still refused, empty bits or not:
    // the membership gate protects the unclaimed path like the marked one.
    const kept = try st.get("kept.bin", 16, sys.monoSec(std.testing.io));
    defer st.releaseFile(kept);
    var kb: [sys.c.PATH_MAX]u8 = undefined;
    const kp = try st.cacheDataPath(&kb, "kept.bin");
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(kp, pattern[0..16]));
    try std.testing.expect(!st.punchDisk("kept.bin"));

    const e0 = st.purge_epoch;
    try std.testing.expect(st.punchDisk("orphan.bin"));
    try std.testing.expectEqual(e0 + 1, st.purge_epoch);
    try std.testing.expectEqual(@as(u64, 1), st.stats.pieces_culled.load(.monotonic));

    // The cleared field was published durably under the file's real
    // geometry: a fresh entry must start empty instead of trusting anything.
    var mb: [sys.c.PATH_MAX]u8 = undefined;
    const mp = try st.cacheMetaPath(&mb, "orphan.bin");
    const blob = try sys.readFileAlloc(gpa, mp, 4096);
    defer gpa.free(blob);
    var decoded = try piece.Bitfield.decode(gpa, blob, st.piece_size, pattern.len);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), decoded.filled());

    // KEEP_SIZE punch: the skeleton stays at its old length, now blockless,
    // so later walkData samples skip it instead of repunching every round.
    var sb: c.struct_stat = undefined;
    try std.testing.expect(sys.statPath(dp, &sb) == 0);
    try std.testing.expectEqual(@as(u64, pattern.len), @as(u64, @intCast(sb.st_size)));
}

test "punchDisk reclaims a data file whose sidecar names another geometry" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-pd-grid");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-pd-grid");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Stale-grid shape (e.g. --piece changed across restarts): decode resets
    // on the ps/fs mismatch, so the marks are untrusted and the whole file
    // must be reclaimable rather than stranded.
    const pattern = "0123456789abcdef";
    var db: [sys.c.PATH_MAX]u8 = undefined;
    const dp = try st.cacheDataPath(&db, "stale.bin");
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(dp, pattern));
    try writeFilledSidecar(&st, "stale.bin", 4 * 1024 * 1024, &.{0});

    try std.testing.expect(st.punchDisk("stale.bin"));

    var mb: [sys.c.PATH_MAX]u8 = undefined;
    const mp = try st.cacheMetaPath(&mb, "stale.bin");
    const blob = try sys.readFileAlloc(gpa, mp, 4096);
    defer gpa.free(blob);
    var decoded = try piece.Bitfield.decode(gpa, blob, st.piece_size, pattern.len);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), decoded.filled());
}

test "readServed falls back to origin when the cache tier cannot answer" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-rsrv");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-rsrv");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const pattern = "0123456789abcdef";
    var zbuf: [192]u8 = undefined;
    var fbuf: [192]u8 = undefined;
    const fp = try std.fmt.bufPrint(&zbuf, "{s}/fb.bin", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&fbuf, fp), ""));
    try std.testing.expectEqual(@as(isize, @intCast(pattern.len)), st.originPwrite("fb.bin", pattern, 0));
    const f = try st.get("fb.bin", pattern.len, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);

    // Break the cache tier for this file: a directory planted at the data
    // path refuses the cache fd open (EISDIR). A warm read must degrade to
    // origin service -- regression: it surfaced the cache error as EIO,
    // turning a dead cache mount into a total read outage for every file
    // with cached pieces while the origin stayed perfectly healthy.
    var db: [sys.c.PATH_MAX]u8 = undefined;
    const dp = try st.cacheDataPath(&db, "fb.bin");
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(std.mem.span(dp), 0o755));

    var rb: [16]u8 = undefined;
    // The expected fallback warn is below the raised threshold; restored on
    // scope exit so unexpected warnings from later tests still surface.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;
    const n = st.readServed(f, &rb, 0, sys.monoSec(std.testing.io));
    try std.testing.expectEqual(@as(isize, @intCast(pattern.len)), n);
    try std.testing.expectEqualStrings(pattern, rb[0..pattern.len]);

    // The plain cache read still reports the failure itself: the fallback
    // must not swallow the errno from callers that want it.
    try std.testing.expect(st.readCache(f, &rb, 0, sys.monoSec(std.testing.io)) < 0);
}

test "readServed takes origin for the tail past the u32 piece-index clamp" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-untracked");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-untracked");
    defer sys.deleteTree(std.testing.io, cache_d);

    // Piece size 1: count() clamps at maxInt(u32), so bytes at that offset
    // have no bit. A sparse origin write there is cheap; the cache fd would
    // pread hole zeros and used to return them as a successful warm read.
    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 1);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const tail_off: u64 = std.math.maxInt(u32);
    const pattern = "UNTRACKED_TAIL!";
    var zbuf: [192]u8 = undefined;
    var fbuf: [192]u8 = undefined;
    const fp = try std.fmt.bufPrint(&zbuf, "{s}/tail.bin", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&fbuf, fp), ""));
    try std.testing.expectEqual(@as(isize, @intCast(pattern.len)), st.originPwrite("tail.bin", pattern, tail_off));

    // Allocate a tiny bitfield (get at a small size) then raise file.size so
    // the production rangeTracked check fires without a 512 MiB sidecar.
    const f = try st.get("tail.bin", 16, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    f.mu.lockUncancelable(std.testing.io);
    f.size = tail_off + pattern.len;
    f.mu.unlock(std.testing.io);

    var rb: [16]u8 = undefined;
    const n = st.readServed(f, rb[0..pattern.len], tail_off, sys.monoSec(std.testing.io));
    try std.testing.expectEqual(@as(isize, @intCast(pattern.len)), n);
    try std.testing.expectEqualStrings(pattern, rb[0..pattern.len]);
}

test "considerIdle keeps a bounded oldest-first sample" {
    const gpa = std.testing.allocator;
    var dummy_bits = try piece.Bitfield.init(gpa, 1);
    defer dummy_bits.deinit(gpa);
    var filling = std.AutoHashMap(u32, u64).init(gpa);
    defer filling.deinit();
    var hashes = std.AutoHashMap(u32, [piece.digest_len]u8).init(gpa);
    defer hashes.deinit();
    var rels: [Store.idle_sample_cap + 1][8]u8 = undefined;
    var files: [Store.idle_sample_cap + 1]Store.Cached = undefined;
    var i: usize = 0;
    while (i < files.len) : (i += 1) {
        const name = try std.fmt.bufPrint(&rels[i], "f{d:0>2}", .{i});
        files[i] = .{
            .rel = name,
            .size = 1,
            .bits = dummy_bits,
            .filling = filling,
            .hashes = hashes,
        };
        files[i].refs.store(1, .monotonic);
    }
    var cands: [Store.idle_sample_cap]Store.IdleCand = undefined;
    var count: usize = 0;
    // Scrambled arrival: at = 100+i so f00 is oldest. The extra file is
    // younger than the sample and must not occupy a slot.
    i = files.len;
    while (i > 0) {
        i -= 1;
        const f = &files[i];
        const at: i64 = @intCast(100 + i);
        _ = f.refs.fetchAdd(1, .monotonic);
        if (!Store.considerIdle(&cands, &count, f, at))
            _ = f.refs.fetchSub(1, .monotonic);
    }
    try std.testing.expectEqual(Store.idle_sample_cap, count);
    try std.testing.expectEqualStrings("f00", cands[0].f.rel);
    try std.testing.expectEqual(@as(i64, 100), cands[0].at);
    try std.testing.expectEqualStrings("f31", cands[count - 1].f.rel);
    // The extra file (f32) lost the sample: refs back to the birth pin.
    try std.testing.expectEqual(@as(u32, 1), files[Store.idle_sample_cap].refs.load(.monotonic));
    // Occupants keep the extra pin.
    try std.testing.expectEqual(@as(u32, 2), files[0].refs.load(.monotonic));
    // An even older candidate replaces the youngest and bubbles to the front.
    files[Store.idle_sample_cap].rel = try std.fmt.bufPrint(&rels[Store.idle_sample_cap], "f-old", .{});
    _ = files[Store.idle_sample_cap].refs.fetchAdd(1, .monotonic);
    try std.testing.expect(Store.considerIdle(&cands, &count, &files[Store.idle_sample_cap], 50));
    try std.testing.expectEqualStrings("f-old", cands[0].f.rel);
    try std.testing.expectEqual(@as(i64, 50), cands[0].at);
    try std.testing.expectEqual(@as(u32, 1), files[Store.idle_sample_cap - 1].refs.load(.monotonic));
}

test "considerVictim keeps a bounded oldest-first sample" {
    var victims: [Store.walk_sample_cap]Store.DiskVictim = undefined;
    var count: usize = 0;
    // Fill the sample with at=10..17 in scrambled arrival order.
    const ats = [_]i64{ 13, 10, 16, 11, 17, 12, 15, 14 };
    for (ats, 0..) |at, i| {
        var nb: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&nb, "f{d}.bin", .{i});
        Store.considerVictim(&victims, &count, name, at);
    }
    try std.testing.expectEqual(Store.walk_sample_cap, count);
    for (&victims, 0..) |*v, i| {
        try std.testing.expectEqual(@as(i64, @intCast(10 + i)), v.at);
    }
    // An older candidate replaces the youngest and bubbles to the front...
    Store.considerVictim(&victims, &count, "old.bin", 5);
    try std.testing.expectEqualStrings("old.bin", victims[0].rel[0..victims[0].len]);
    try std.testing.expectEqual(@as(i64, 5), victims[0].at);
    // ...and one younger than every entry is ignored outright.
    Store.considerVictim(&victims, &count, "young.bin", 99);
    try std.testing.expectEqual(@as(i64, 16), victims[count - 1].at);

    // Equal mtimes fall back to rel length, then rel bytes: the sampled
    // order must be a function of durable state alone, not of readdir
    // arrival order. Both arrival permutations below must sample identically.
    var tv: [Store.walk_sample_cap]Store.DiskVictim = undefined;
    var tcount: usize = 0;
    for ([_][]const u8{ "z.bin", "b.bin", "aa.bin" }) |name| {
        Store.considerVictim(&tv, &tcount, name, 7);
    }
    try std.testing.expectEqualStrings("b.bin", tv[0].rel[0..tv[0].len]);
    try std.testing.expectEqualStrings("z.bin", tv[1].rel[0..tv[1].len]);
    try std.testing.expectEqualStrings("aa.bin", tv[2].rel[0..tv[2].len]);
    var tv2: [Store.walk_sample_cap]Store.DiskVictim = undefined;
    var tcount2: usize = 0;
    for ([_][]const u8{ "aa.bin", "z.bin", "b.bin" }) |name| {
        Store.considerVictim(&tv2, &tcount2, name, 7);
    }
    try std.testing.expectEqualStrings(tv[0].rel[0..tv[0].len], tv2[0].rel[0..tv2[0].len]);
    try std.testing.expectEqualStrings(tv[1].rel[0..tv[1].len], tv2[1].rel[0..tv2[1].len]);
    try std.testing.expectEqualStrings(tv[2].rel[0..tv[2].len], tv2[2].rel[0..tv2[2].len]);
}

test "walkData samples oldest-first disk-only files across subdirs" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-walk");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-walk");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Cached files at two nesting levels plus an old pinned file the scan
    // must skip; mtimes are stamped explicitly so ordering does not depend
    // on write scheduling.
    var db: [256]u8 = undefined;
    const sub = try std.fmt.bufPrint(&db, "{s}/data/gguf", .{cache_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(sub, 0o755));
    const entries = [_]struct { rel: []const u8, age: i64 }{
        .{ .rel = "pinned.bin", .age = 400 },
        .{ .rel = "old.bin", .age = 300 },
        .{ .rel = "gguf/mid.bin", .age = 200 },
        .{ .rel = "new.bin", .age = 100 },
    };
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    const walk_now = sys.nowSec(std.testing.io);
    for (entries) |e| {
        var fb: [320]u8 = undefined;
        const fp = try std.fmt.bufPrint(&fb, "{s}/data/{s}", .{ cache_d, e.rel });
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), "cached"));
        const past = [2]std.os.linux.timespec{
            .{ .sec = walk_now - e.age, .nsec = 0 },
            .{ .sec = walk_now - e.age, .nsec = 0 },
        };
        const rc = std.os.linux.utimensat(std.posix.AT.FDCWD, try sys.toZ(&zbuf, fp), &past, 0);
        try std.testing.expectEqual(@as(usize, 0), rc);
    }
    try std.testing.expectEqual(@as(i32, 0), st.setPin("pinned.bin", true));

    var rb: [sys.c.PATH_MAX]u8 = undefined;
    const root = try sys.joinZ(&rb, cache_d, "data");
    var victims: [Store.walk_sample_cap]Store.DiskVictim = undefined;
    var count: usize = 0;
    st.walkData(std.mem.span(root), "", &victims, &count, 0);

    try std.testing.expectEqual(@as(usize, 3), count);
    const want = [_][]const u8{ "old.bin", "gguf/mid.bin", "new.bin" };
    for (want, 0..) |w, i| {
        try std.testing.expectEqualStrings(w, victims[i].rel[0..victims[i].len]);
        if (i > 0) try std.testing.expect(victims[i - 1].at <= victims[i].at);
    }
}

test "walkData keeps the oldest cap files when candidates exceed the sample" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-walkcap");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-walkcap");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // More disk-only candidates than walk_sample_cap: the sample must hold
    // exactly the oldest eight in ascending mtime order. The later (younger)
    // files arrive after the sample is full and are rejected by the same
    // victimOlder predicate considerVictim applies -- the early gate that
    // skips their pin stat and map probe must not change what it would have
    // sampled.
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    const n: usize = Store.walk_sample_cap + 4;
    const walk_now = sys.nowSec(std.testing.io);
    for (0..n) |i| {
        var fb: [320]u8 = undefined;
        var nb: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&nb, "f{d:0>2}.bin", .{i});
        const fp = try std.fmt.bufPrint(&fb, "{s}/data/{s}", .{ cache_d, name });
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), "cached"));
        // Descending age with index: f00 is the oldest, fNN the youngest.
        // One wall sample for the whole set so a second boundary mid-loop
        // cannot reorder two files whose ages differ by that second.
        const age: i64 = @intCast(100 * (n - i));
        const past = [2]std.os.linux.timespec{
            .{ .sec = walk_now - age, .nsec = 0 },
            .{ .sec = walk_now - age, .nsec = 0 },
        };
        const rc = std.os.linux.utimensat(std.posix.AT.FDCWD, try sys.toZ(&zbuf, fp), &past, 0);
        try std.testing.expectEqual(@as(usize, 0), rc);
    }

    var rb: [sys.c.PATH_MAX]u8 = undefined;
    const root = try sys.joinZ(&rb, cache_d, "data");
    var victims: [Store.walk_sample_cap]Store.DiskVictim = undefined;
    var count: usize = 0;
    st.walkData(std.mem.span(root), "", &victims, &count, 0);

    try std.testing.expectEqual(@as(usize, Store.walk_sample_cap), count);
    for (&victims, 0..) |*v, i| {
        var nb: [32]u8 = undefined;
        const want = try std.fmt.bufPrint(&nb, "f{d:0>2}.bin", .{i});
        try std.testing.expectEqualStrings(want, v.rel[0..v.len]);
        if (i > 0) try std.testing.expect(victims[i - 1].at <= v.at);
    }
}

test "walkData never samples or descends planted symlinks" {
    const gpa = std.testing.allocator;
    var cb: [128]u8 = undefined;
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-walk-link");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, "/unused", cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Real cached files the walk must still sample, plus two planted
    // symlinks in the same writable tree a local writer would use: one at
    // a regular file, one at a directory OUTSIDE data/ holding another aged
    // file. Both symlinks must be invisible to the scan: sampling the first
    // would let punchDisk punch through a name resolving outside the tree,
    // and descending the second would do the same via intermediate
    // components.
    const entries = [_][]const u8{ "real.bin", "hidden/target.bin", "../outside/escaped.bin" };
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    for (entries) |e| {
        var fb: [320]u8 = undefined;
        const fp = try std.fmt.bufPrint(&fb, "{s}/data/{s}", .{ cache_d, e });
        try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(sys.parentOf(fp), 0o755));
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), "cached"));
    }
    var lbuf: [sys.c.PATH_MAX]u8 = undefined;
    var tbuf: [sys.c.PATH_MAX]u8 = undefined;
    const sneaky = try std.fmt.bufPrint(&lbuf, "{s}/data/sneaky.bin", .{cache_d});
    const target = try std.fmt.bufPrint(&tbuf, "{s}/data/real.bin", .{cache_d});
    try std.testing.expect(c.symlink(try sys.toZ(&zbuf, target), try sys.toZ(&zbuf, sneaky)) == 0);
    const dirlink = try std.fmt.bufPrint(&lbuf, "{s}/data/dirlink", .{cache_d});
    const outside = try std.fmt.bufPrint(&tbuf, "{s}/outside", .{cache_d});
    try std.testing.expect(c.symlink(try sys.toZ(&zbuf, outside), try sys.toZ(&zbuf, dirlink)) == 0);

    var rb: [sys.c.PATH_MAX]u8 = undefined;
    const root = try sys.joinZ(&rb, cache_d, "data");
    var victims: [Store.walk_sample_cap]Store.DiskVictim = undefined;
    var count: usize = 0;
    st.walkData(std.mem.span(root), "", &victims, &count, 0);

    try std.testing.expectEqual(@as(usize, 2), count);
    var saw_real = false;
    var saw_hidden = false;
    for (victims[0..count]) |v| {
        const got = v.rel[0..v.len];
        if (std.mem.eql(u8, got, "real.bin")) saw_real = true;
        if (std.mem.eql(u8, got, "hidden/target.bin")) saw_hidden = true;
        // Neither link may appear, in sampled or traversed form.
        try std.testing.expect(std.mem.find(u8, got, "sneaky") == null);
        try std.testing.expect(std.mem.find(u8, got, "dirlink") == null);
        try std.testing.expect(std.mem.find(u8, got, "escaped") == null);
    }
    try std.testing.expect(saw_real and saw_hidden);
}

test "walkData samples dot-prefixed cache files that relOk allows" {
    const gpa = std.testing.allocator;
    var cb: [128]u8 = undefined;
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-walk-dot");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, "/unused", cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // relOk admits a leading-dot component; skipping every `.*` readdir
    // name (the `.` / `..` filter written as name[0]=='.') left those
    // cache files invisible to disk culling after a restart.
    try std.testing.expect(relOk(".hidden.bin"));
    try std.testing.expect(relOk("dir/.cache.bin"));
    const entries = [_][]const u8{ "plain.bin", ".hidden.bin", "dir/.cache.bin" };
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    for (entries) |e| {
        var fb: [320]u8 = undefined;
        const fp = try std.fmt.bufPrint(&fb, "{s}/data/{s}", .{ cache_d, e });
        try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(sys.parentOf(fp), 0o700));
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), "cached"));
    }

    var rb: [sys.c.PATH_MAX]u8 = undefined;
    const root = try sys.joinZ(&rb, cache_d, "data");
    var victims: [Store.walk_sample_cap]Store.DiskVictim = undefined;
    var count: usize = 0;
    st.walkData(std.mem.span(root), "", &victims, &count, 0);

    try std.testing.expectEqual(@as(usize, 3), count);
    var saw_plain = false;
    var saw_dotfile = false;
    var saw_dotdir = false;
    for (victims[0..count]) |v| {
        const got = v.rel[0..v.len];
        if (std.mem.eql(u8, got, "plain.bin")) saw_plain = true;
        if (std.mem.eql(u8, got, ".hidden.bin")) saw_dotfile = true;
        if (std.mem.eql(u8, got, "dir/.cache.bin")) saw_dotdir = true;
    }
    try std.testing.expect(saw_plain and saw_dotfile and saw_dotdir);
}

test "get survives concurrent artifact invalidation between loadBits and insert" {
    // Regression harness for the purge_epoch contract: a get() builder whose
    // sidecar read raced a forget/reap-punch must retry instead of publishing
    // bits loaded from the pre-mutation artifacts. The bumper thread forces
    // epoch mismatches inside the unlocked build window; every mismatch walks
    // the retry path (deinit + rebuild), so any double-free of the entry,
    // its rel copy, or its bitfield trips the testing allocator.
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-epoch");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-epoch");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // forget bumps the epoch exactly once per purge.
    {
        const f = try st.get("epoch.bin", 64, sys.monoSec(std.testing.io));
        st.releaseFile(f);
        const e0 = st.purge_epoch;
        st.forget("epoch.bin");
        try std.testing.expectEqual(e0 + 1, st.purge_epoch);
    }

    var done = std.atomic.Value(bool).init(false);
    const bumper = try std.Thread.spawn(.{}, struct {
        fn run(s: *Store, stop: *std.atomic.Value(bool)) void {
            // Bursts with sleeps between them: a tight spinner could starve
            // every build window and livelock get()'s retry. The gaps let
            // builders complete; the bursts land inside others.
            while (!stop.load(.acquire)) {
                s.mu.lockUncancelable(s.io);
                s.purge_epoch +%= 1;
                s.mu.unlock(s.io);
                sys.sleepMs(std.testing.io, 1);
            }
        }
    }.run, .{ &st, &done });
    defer {
        done.store(true, .release);
        bumper.join();
    }

    // Each round is a fresh slow-path build (forget removes the entry); the
    // bumper keeps invalidating builds mid-flight, exercising the retry.
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const f = try st.get("race.bin", 64, sys.monoSec(std.testing.io));
        try std.testing.expectEqual(@as(u64, 64), f.size);
        try std.testing.expectEqual(@as(u32, 64 / 16), f.bits.nbits);
        st.releaseFile(f);
        st.forget("race.bin");
    }
    try std.testing.expectEqual(@as(usize, 0), st.files.count());
}

/// Makes every sidecar rewrite fail until undone (read-only sidecar file),
/// the way a full or failing cache filesystem would.
const SidecarBroken = struct {
    path_z: [sys.c.PATH_MAX]u8,

    fn apply(st: *Store, rel: []const u8) !SidecarBroken {
        var self = SidecarBroken{ .path_z = undefined };
        _ = try st.cacheMetaPath(&self.path_z, rel);
        try std.testing.expectEqual(@as(i32, 0), c.chmod(&self.path_z, 0o444));
        return self;
    }

    fn undo(self: *const SidecarBroken) void {
        _ = c.chmod(&self.path_z, 0o644);
    }
};

test "punchPiece refuses to cut the hole unless the cleared bits persist" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-pp-save");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-pp-save");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    var pattern: [32]u8 = undefined;
    for (&pattern, 0..) |*b, i| b.* = @truncate(i *% 37 + 5);
    const f = try st.get("p.bin", pattern.len, 40_000);
    defer st.releaseFile(f);
    // Expected-path warnings from SidecarBroken below (saveBits names each
    // failed persist); keep them off the runner's stderr like sibling
    // fault-injection tests do. Restored on scope exit so later tests still
    // surface unexpected warnings.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;
    try std.testing.expect(st.openCache(f) >= 0);
    try std.testing.expectEqual(@as(isize, 32), sys.pwriteAll(f.cache_fd, &pattern, 0));
    f.mu.lockUncancelable(std.testing.io);
    f.bits.set(0);
    f.bits.set(1);
    try std.testing.expect(st.saveBits(f, true));
    f.mu.unlock(std.testing.io);

    // Regression: punching first and persisting second let a failed sidecar
    // save leave a hole under a filled mark -- post-restart reads would
    // serve hole zeros as cached bytes. The punch must be refused instead,
    // leaving both bytes and mark intact. The punch instant sits an hour
    // past the entry's creation stamp (virtual time: the candidate is idle).
    var broken = try SidecarBroken.apply(&st, "p.bin");
    defer broken.undo();
    try std.testing.expect(!st.punchPiece(f, 0, 40_000 + 3600));

    f.mu.lockUncancelable(std.testing.io);
    try std.testing.expect(f.bits.get(0));
    f.mu.unlock(std.testing.io);
    var back: [32]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 32), sys.preadAll(f.cache_fd, &back, 0));
    try std.testing.expectEqualSlices(u8, &pattern, &back);

    // Once saves work again the same piece culls normally. Same virtual
    // clock as the entry's 40_000 creation stamp: sys.monoSec(std.testing.io) here would
    // compare seconds-since-boot against that stamp, so the punch would be
    // refused as too recent on any host up for less than 11 hours.
    broken.undo();
    try std.testing.expect(st.punchPiece(f, 0, 40_000 + 7200));
    try std.testing.expect(!st.hasPiece(f, 0, 40_000 + 7200));
}

test "disk cull refuses to cut the hole unless the cleared bits persist" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-pd-save");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-pd-save");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Orphaned artifacts from an earlier run, no live entry: data present,
    // sidecar says piece 0 filled.
    const pattern = "0123456789abcdef";
    var db: [sys.c.PATH_MAX]u8 = undefined;
    const dp = try st.cacheDataPath(&db, "d.bin");
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(dp, pattern));
    try writeFilledSidecar(&st, "d.bin", pattern.len, &.{0});

    var broken = try SidecarBroken.apply(&st, "d.bin");
    defer broken.undo();
    // Same expected-warning suppression as the punchPiece save test above.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;
    try std.testing.expect(!st.punchDisk("d.bin"));

    var rb: [16]u8 = undefined;
    const got = sys.readFileBuf(&rb, dp) catch return error.ReadFailed;
    try std.testing.expectEqualStrings(pattern, got);

    // With persistence possible again the orphan punches through cullOne.
    broken.undo();
    try std.testing.expect(st.cullOne(sys.monoSec(std.testing.io)));
    const after = sys.readFileBuf(&rb, dp) catch return error.ReadFailed;
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** pattern.len), after);
}

test "beginFill surfaces allocation failure instead of spinning" {
    const gpa = std.testing.allocator;
    var st = Store.init(gpa, std.testing.io, "/unused", "/unused", 16);
    defer st.deinit();
    const f = try st.get("oom.bin", 64, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);

    // Rebind the entry's filling map to an allocator whose first allocation
    // fails: beginFill must report the failure to its caller (which turns it
    // into EIO/500) rather than retry forever and wedge the reader.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    f.filling.deinit();
    f.filling = std.AutoHashMap(u32, u64).init(failing.allocator());
    try std.testing.expectError(error.OutOfMemory, st.beginFill(f, 0, sys.monoSec(std.testing.io)));
}

test "beginFill answers filled and raced without claiming or marking" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-claim");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-claim");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Already filled (including by a concurrent filler that finished while
    // we waited): the second hydrator must see .filled and take no claim,
    // so the first filler's finishPiece never finds a dangling entry.
    const f = try st.get("claim.bin", 48, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    f.mu.lockUncancelable(std.testing.io);
    f.bits.set(0);
    f.mu.unlock(std.testing.io);
    try std.testing.expect((try st.beginFill(f, 0, sys.monoSec(std.testing.io))) == .filled);
    f.mu.lockUncancelable(std.testing.io);
    const no_dangling_claim = !f.filling.contains(0);
    f.mu.unlock(std.testing.io);
    try std.testing.expect(no_dangling_claim);

    // Raced: the piece starts past EOF, exactly the state a concurrent
    // truncate leaves between claim and sample. The claim must come back
    // dropped with nothing marked -- a hydrator treating this as data would
    // mark hole zeros as a filled piece (the underflow hazard hydratePiece
    // documents for an empty buf).
    try std.testing.expect((try st.beginFill(f, 5, sys.monoSec(std.testing.io))) == .raced);
    f.mu.lockUncancelable(std.testing.io);
    const dropped_unmarked = !f.bits.get(5) and f.filling.count() == 0;
    f.mu.unlock(std.testing.io);
    try std.testing.expect(dropped_unmarked);

    // The raced piece stays fillable once it is in range again: the drop
    // must not poison later claims. Growing size and bitfield together under
    // file.mu is the same move reconcileSize and truncate make.
    f.mu.lockUncancelable(std.testing.io);
    f.bits.deinit(gpa);
    f.bits = try piece.Bitfield.init(gpa, piece.count(112, st.piece_size));
    f.size = 112;
    f.mu.unlock(std.testing.io);
    try std.testing.expectEqual(@as(u32, 16), (try st.beginFill(f, 5, sys.monoSec(std.testing.io))).len);
    try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 5, "0123456789abcdef", null, sys.monoSec(std.testing.io)));
    try std.testing.expect(st.hasPiece(f, 5, sys.monoSec(std.testing.io)));
}

test "sidecar save and cache open recreate a deleted parent directory" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-mkdir");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-mkdir");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // Regression: saveBits and openCache ran an unconditional mkdirAll walk
    // (one failed mkdir per component) before every write and open. The
    // retry-on-ENOENT shape they replaced must still create the directory
    // when it is genuinely missing.
    const f = try st.get("deep/sub/x.bin", 64, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    try std.testing.expect(st.openCache(f) >= 0);

    var mb: [sys.c.PATH_MAX]u8 = undefined;
    const mp = try st.cacheMetaPath(&mb, "deep/sub/x.bin");
    var db2: [sys.c.PATH_MAX]u8 = undefined;
    const dp = try st.cacheDataPath(&db2, "deep/sub/x.bin");
    var stbuf: c.struct_stat = undefined;

    // Remove both artifact subtrees; the next save and open must rebuild them.
    {
        var pb: [sys.c.PATH_MAX]u8 = undefined;
        const meta_parent = try std.fmt.bufPrint(&pb, "{s}/meta/deep", .{cache_d});
        sys.deleteTree(std.testing.io, meta_parent);
        var qb: [sys.c.PATH_MAX]u8 = undefined;
        const data_parent = try std.fmt.bufPrint(&qb, "{s}/data/deep", .{cache_d});
        sys.deleteTree(std.testing.io, data_parent);
    }

    try std.testing.expect(st.saveBits(f, false));
    try std.testing.expect(sys.statPath(mp, &stbuf) == 0);
    // Drop the live fd the way reapIdle does, so the reopen below actually
    // goes to disk instead of returning the cached descriptor.
    f.mu.lockUncancelable(std.testing.io);
    sys.close(f.cache_fd);
    f.cache_fd = -1;
    f.mu.unlock(std.testing.io);
    try std.testing.expect(st.openCache(f) >= 0);
    try std.testing.expect(sys.statPath(dp, &stbuf) == 0);
}

test "openCache refuses a symlink planted at the data path" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-sym");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-sym");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // O_NOFOLLOW contract on the data artifact: a local writer who can plant
    // a symlink at a cache data path must not turn the daemon's open with
    // O_RDWR|O_CREAT (and its ftruncate/pwrite) into writes to an arbitrary
    // file. The open fails and the planted target keeps its bytes.
    var tb: [192]u8 = undefined;
    const target = try std.fmt.bufPrint(&tb, "{s}/outside.txt", .{origin_d});
    var zb: [192]u8 = undefined;
    const target_z = try sys.toZ(&zb, target);
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(target_z, "keepme"));

    var db: [sys.c.PATH_MAX]u8 = undefined;
    const dp = try st.cacheDataPath(&db, "sym.bin");
    try std.testing.expectEqual(@as(i32, 0), c.symlink(target_z, dp));

    const f = try st.get("sym.bin", 32, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    try std.testing.expect(st.openCache(f) < 0);

    var rb: [8]u8 = undefined;
    try std.testing.expectEqualStrings("keepme", try sys.readFileBuf(&rb, try sys.toZ(&zb, target)));
}

test "openCache creates owner-only data files and tightens leftovers" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-mode");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-mode");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    var db: [sys.c.PATH_MAX]u8 = undefined;
    const data_dir = try st.cacheSubPath(&db, "data", "");
    var dst: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(i32, 0), sys.statPath(data_dir, &dst));
    try std.testing.expectEqual(@as(c.mode_t, 0o700), dst.st_mode & 0o777);

    // Leftover 0755 `data/`/`meta/`/`pin/` (pre-0700 daemon) stay world-
    // listable until ensureLayout fchmods them: mkdirAll treats EEXIST as
    // success without touching mode. A co-tenant blocked by origin modes
    // could otherwise `ls` which weights are cached or pinned.
    for ([_][]const u8{ "data", "meta", "pin" }) |sub| {
        const dir = try st.cacheSubPath(&db, sub, "");
        try std.testing.expectEqual(@as(i32, 0), c.chmod(dir, 0o755));
    }
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());
    for ([_][]const u8{ "data", "meta", "pin" }) |sub| {
        const dir = try st.cacheSubPath(&db, sub, "");
        try std.testing.expectEqual(@as(i32, 0), sys.statPath(dir, &dst));
        try std.testing.expectEqual(@as(c.mode_t, 0o700), dst.st_mode & 0o777);
    }

    const f = try st.get("weights.bin", 32, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    try std.testing.expect(st.openCache(f) >= 0);

    var dp: [sys.c.PATH_MAX]u8 = undefined;
    const path = try st.cacheDataPath(&dp, "weights.bin");
    var stbuf: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(i32, 0), sys.statPath(path, &stbuf));
    try std.testing.expectEqual(@as(c.mode_t, 0o600), stbuf.st_mode & 0o777);

    // A leftover world-readable data file is tightened on the next open,
    // not left at the mode O_CREAT ignored because the name already existed.
    f.mu.lockUncancelable(std.testing.io);
    sys.close(f.cache_fd);
    f.cache_fd = -1;
    f.mu.unlock(std.testing.io);
    try std.testing.expectEqual(@as(i32, 0), c.chmod(path, 0o644));
    try std.testing.expect(st.openCache(f) >= 0);
    try std.testing.expectEqual(@as(i32, 0), sys.statPath(path, &stbuf));
    try std.testing.expectEqual(@as(c.mode_t, 0o600), stbuf.st_mode & 0o777);

    // Nested parents under data/meta/pin must be 0700 too: a 0755 `pin/gguf`
    // or `meta/gguf` would list which nested weights are cached/pinned even
    // when the files themselves are 0600. openCache already used 0700 for
    // data/; pin and sidecar saves used to mkdirAll 0755.
    const nested = try st.get("gguf/w.bin", 32, sys.monoSec(std.testing.io));
    defer st.releaseFile(nested);
    try std.testing.expect(st.openCache(nested) >= 0);
    const data_sub = try st.cacheSubPath(&db, "data", "gguf");
    try std.testing.expectEqual(@as(i32, 0), sys.statPath(data_sub, &dst));
    try std.testing.expectEqual(@as(c.mode_t, 0o700), dst.st_mode & 0o777);
    try std.testing.expectEqual(@as(i32, 0), st.setPin("gguf/w.bin", true));
    const pin_sub = try st.cacheSubPath(&db, "pin", "gguf");
    try std.testing.expectEqual(@as(i32, 0), sys.statPath(pin_sub, &dst));
    try std.testing.expectEqual(@as(c.mode_t, 0o700), dst.st_mode & 0o777);
    const pin_fp = try st.cachePinPath(&db, "gguf/w.bin");
    try std.testing.expectEqual(@as(i32, 0), sys.statPath(pin_fp, &dst));
    try std.testing.expectEqual(@as(c.mode_t, 0o600), dst.st_mode & 0o777);
    // Leftover 0644 pin marker (writeFileNoFollow used to create these)
    // is tightened on the next pin, matching leftover data files.
    try std.testing.expectEqual(@as(i32, 0), c.chmod(pin_fp, 0o644));
    try std.testing.expectEqual(@as(i32, 0), st.setPin("gguf/w.bin", true));
    try std.testing.expectEqual(@as(i32, 0), sys.statPath(pin_fp, &dst));
    try std.testing.expectEqual(@as(c.mode_t, 0o600), dst.st_mode & 0o777);
    try std.testing.expect(st.copyIntoCache(nested, 0, &[_]u8{0} ** 32));
    const meta_sub = try st.cacheSubPath(&db, "meta", "gguf");
    try std.testing.expectEqual(@as(i32, 0), sys.statPath(meta_sub, &dst));
    try std.testing.expectEqual(@as(c.mode_t, 0o700), dst.st_mode & 0o777);
    const meta_fp = try st.cacheMetaPath(&db, "gguf/w.bin");
    try std.testing.expectEqual(@as(i32, 0), sys.statPath(meta_fp, &dst));
    try std.testing.expectEqual(@as(c.mode_t, 0o600), dst.st_mode & 0o777);
    try std.testing.expectEqual(@as(i32, 0), c.chmod(meta_fp, 0o644));
    nested.mu.lockUncancelable(std.testing.io);
    try std.testing.expect(st.saveBits(nested, false));
    nested.mu.unlock(std.testing.io);
    try std.testing.expectEqual(@as(i32, 0), sys.statPath(meta_fp, &dst));
    try std.testing.expectEqual(@as(c.mode_t, 0o600), dst.st_mode & 0o777);
}

test "loadBits refuses a symlink planted at the sidecar path" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-metasym");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-metasym");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // A filled sidecar next to the artifact name: following a planted
    // link would mark piece 0 filled over hole zeros. O_NOFOLLOW must
    // treat the link as unreadable and start empty. Basename target so
    // a following open would resolve (cwd-relative targets would not).
    var bits = try piece.Bitfield.init(gpa, piece.count(16, 16));
    defer bits.deinit(gpa);
    bits.set(0);
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(gpa);
    try bits.encode(16, 16, &blob, gpa);
    var tb: [sys.c.PATH_MAX]u8 = undefined;
    const target = try st.cacheMetaPath(&tb, "outside.bin");
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(target, blob.items));

    var mb: [sys.c.PATH_MAX]u8 = undefined;
    const mp = try st.cacheMetaPath(&mb, "sym.bin");
    try std.testing.expectEqual(@as(i32, 0), c.symlink("outside.bin.pieces", mp));

    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    const f = try st.get("sym.bin", 16, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    try std.testing.expect(!f.bits.get(0));
}

test "origin access refuses a symlink planted at the model path" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-origsym");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-origsym");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // O_NOFOLLOW contract on the origin tier: the origin is shared storage a
    // co-tenant can plant names in, so a symlink at a model path must never
    // turn the daemon's stat/pread/pwrite/fsync/statvfs into reads or writes
    // of the link's client-local target. statOrigin reports S_IFLNK (every
    // caller's S_IFREG gate then rejects fail-closed), and data/statvfs/fsync
    // answer ELOOP.
    var tb: [192]u8 = undefined;
    const target = try std.fmt.bufPrint(&tb, "{s}/secret.txt", .{origin_d});
    var zb: [192]u8 = undefined;
    const target_z = try sys.toZ(&zb, target);
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(target_z, "s3cret"));

    var lb: [sys.c.PATH_MAX]u8 = undefined;
    const lp = try st.originPath(&lb, "planted.gguf");
    try std.testing.expectEqual(@as(i32, 0), c.symlink(target_z, lp));

    var stbuf: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(i32, 0), st.statOrigin("planted.gguf", &stbuf));
    try std.testing.expect((stbuf.st_mode & sys.c.S_IFMT) == sys.c.S_IFLNK);

    var rbuf: [8]u8 = undefined;
    try std.testing.expectEqual(-c.ELOOP, st.originPread("planted.gguf", &rbuf, 0));
    try std.testing.expectEqual(-c.ELOOP, st.originPwrite("planted.gguf", &rbuf, 0));
    try std.testing.expectEqual(-c.ELOOP, st.originFsync("planted.gguf", false));
    try std.testing.expectEqual(-c.ELOOP, st.originFsync("planted.gguf", true));
    var vs: c.struct_statvfs = undefined;
    try std.testing.expectEqual(-c.ELOOP, st.originStatvfs("planted.gguf", &vs));
    // The planted target keeps its bytes: nothing read or wrote through.
    try std.testing.expectEqualStrings("s3cret", try sys.readFileBuf(&rbuf, target_z));

    // A regular origin file keeps working through the same calls.
    var fz: [192]u8 = undefined;
    const real_z = try sys.toZ(&fz, try std.fmt.bufPrint(&tb, "{s}/real.bin", .{origin_d}));
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(real_z, "model"));
    try std.testing.expectEqual(@as(isize, 5), st.originPread("real.bin", rbuf[0..5], 0));
    try std.testing.expectEqualStrings("model", rbuf[0..5]);
    try std.testing.expectEqual(@as(i32, 0), st.originStatvfs("real.bin", &vs));
    try std.testing.expect(vs.f_blocks > 0);
}

test "origin access refuses a FIFO planted at the model path" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-origfifo");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-origfifo");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    // A FIFO at a model name would hang open(2) without O_NONBLOCK and
    // wedge a FUSE worker (or peer /data hydration) until a reader/writer
    // appears. The flag is ignored on regular files; on a FIFO, O_RDONLY
    // returns immediately and pread fails ESPIPE, O_WRONLY fails ENXIO
    // when no reader is waiting.
    var lb: [sys.c.PATH_MAX]u8 = undefined;
    const lp = try st.originPath(&lb, "fifo.gguf");
    try std.testing.expectEqual(@as(c_int, 0), c.mkfifo(lp, 0o600));

    var rbuf: [8]u8 = undefined;
    try std.testing.expectEqual(-c.ESPIPE, st.originPread("fifo.gguf", &rbuf, 0));
    try std.testing.expectEqual(-c.ENXIO, st.originPwrite("fifo.gguf", rbuf[0..5], 0));
    // O_RDONLY|O_NONBLOCK of a FIFO returns immediately; fsync on a pipe
    // is EINVAL, not a hang.
    try std.testing.expectEqual(-c.EINVAL, st.originFsync("fifo.gguf", false));
}

test "originFsync of a regular file succeeds and missing is ENOENT" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-fsync");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-fsync");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    try std.testing.expectEqual(-c.ENOENT, st.originFsync("gone.bin", false));

    var tb: [192]u8 = undefined;
    var zb: [192]u8 = undefined;
    const real_z = try sys.toZ(&zb, try std.fmt.bufPrint(&tb, "{s}/real.bin", .{origin_d}));
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(real_z, "model"));
    try std.testing.expectEqual(@as(i32, 0), st.originFsync("real.bin", false));
    try std.testing.expectEqual(@as(i32, 0), st.originFsync("real.bin", true));
}

test "late finisher on a forgotten entry does not resurrect the sidecar" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-latefin");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-latefin");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    var mb: [sys.c.PATH_MAX]u8 = undefined;
    var stbuf: c.struct_stat = undefined;

    // A fill claimed before a concurrent unlink: forget purges the artifacts
    // while this reference is outstanding; the late finishPiece must drop
    // the claim without saving. Regression: saving unconditionally recreated
    // a sidecar naming filled pieces over a data file that no longer exists,
    // and a same-size recreate would trust those bits and serve hole zeros.
    const f = try st.get("late.bin", 64, sys.monoSec(std.testing.io));
    try std.testing.expect((try st.beginFill(f, 0, sys.monoSec(std.testing.io))) == .len);
    st.forget("late.bin");
    st.finishPiece(f, 0, true, null, sys.monoSec(std.testing.io));
    const mp = try st.cacheMetaPath(&mb, "late.bin");
    try std.testing.expect(sys.statPath(mp, &stbuf) != 0);
    st.releaseFile(f);

    // Same contract for the write-through path: copyIntoCache on a dead
    // entry reports failure instead of marking and saving bits.
    const f2 = try st.get("late2.bin", 64, sys.monoSec(std.testing.io));
    defer st.releaseFile(f2);
    try std.testing.expect(st.openCache(f2) >= 0);
    st.forget("late2.bin");
    const mp2 = try st.cacheMetaPath(&mb, "late2.bin");
    try std.testing.expect(!st.copyIntoCache(f2, 0, "0123456789abcdef"));
    try std.testing.expect(sys.statPath(mp2, &stbuf) != 0);

    // The dead stamp must be visible to any file.mu holder that follows the
    // purge: finishPiece's skip runs under the same lock forget stamped in,
    // so there is no window where the save slips through.
    const f3 = try st.get("late3.bin", 64, sys.monoSec(std.testing.io));
    defer st.releaseFile(f3);
    st.forget("late3.bin");
    f3.mu.lockUncancelable(std.testing.io);
    const dead_seen = f3.dead.load(.acquire);
    f3.mu.unlock(std.testing.io);
    try std.testing.expect(dead_seen);
}

test "forget racing the last releaseFile cannot double-free" {
    // Regression harness for the freed-flag contract: forget's refs==0 check
    // and the last releaseFile's dead check can both fire on the same entry
    // when a reference is dropped concurrently with the map removal. The
    // testing allocator aborts on any double-free of the entry, its rel
    // copy, or its bitfield. With the winner flag the race is benign; this
    // loop pins that the concurrent path stays allocation-safe.
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-forgfree");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-forgfree");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    var done = std.atomic.Value(bool).init(false);
    const forgetter = try std.Thread.spawn(.{}, struct {
        fn run(s: *Store, stop: *std.atomic.Value(bool)) void {
            var i: usize = 0;
            while (!stop.load(.acquire)) : (i += 1) {
                s.forget("race.bin");
                // A fixed bound so a wedged thread cannot hang the suite; the
                // interleaving needs the forget to land inside a release.
                if (i > 100_000) break;
            }
        }
    }.run, .{ &st, &done });
    var joined = false;
    defer if (!joined) forgetter.join();

    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        const f = try st.get("race.bin", 64, sys.monoSec(std.testing.io));
        st.releaseFile(f);
    }
    done.store(true, .release);
    forgetter.join();
    joined = true;
    // The allocator abort is the double-free check; the store must still
    // serve the path once the race has stopped.
    const f = try st.get("race.bin", 64, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    try std.testing.expectEqual(@as(u64, 64), f.size);
}

test "completeFill records the trusted digest; expectedHash and clearHashes obey" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-hash");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-hash");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const f = try st.get("h.bin", 16, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    // No manifest and no local admit: no trusted hash, so a peer fill of
    // this piece would be refused upstream (expectedHash null -> origin).
    try std.testing.expect(st.expectedHash(f, 0, 0) == null);
    var h: [piece.digest_len]u8 = undefined;
    piece.digest("0123456789abcdef", &h);
    try std.testing.expectEqual(@as(u32, 16), (try st.beginFill(f, 0, sys.monoSec(std.testing.io))).len);
    try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 0, "0123456789abcdef", h, sys.monoSec(std.testing.io)));
    const got = st.expectedHash(f, 0, 0).?;
    try std.testing.expectEqualSlices(u8, &h, &got);
    // A different piece stays unknown.
    try std.testing.expect(st.expectedHash(f, 1, 0) == null);
    // The admit also armed the manifest publish flag.
    f.mu.lockUncancelable(std.testing.io);
    try std.testing.expect(f.manifest_dirty);
    f.mu.unlock(std.testing.io);
    // clearHashes drops the expectation and re-arms the publish flag.
    f.mu.lockUncancelable(std.testing.io);
    st.clearHashes(f);
    f.mu.unlock(std.testing.io);
    try std.testing.expect(st.expectedHash(f, 0, 0) == null);
}

test "copyIntoCache records fully covered piece digests and drops boundary ones" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-whash");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-whash");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const f = try st.get("w.bin", 48, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    // A full 16-byte write of piece 1 (offset 16): its digest is recorded.
    const piece1 = "ABCDEFGHIJKLMNOP";
    try std.testing.expect(st.copyIntoCache(f, 16, piece1));
    var h1: [piece.digest_len]u8 = undefined;
    piece.digest(piece1, &h1);
    try std.testing.expectEqualSlices(u8, &h1, &st.expectedHash(f, 1, 0).?);
    // Piece 0 was never written: no hash.
    try std.testing.expect(st.expectedHash(f, 0, 0) == null);

    // A 20-byte write at 0 fully covers piece 0 and partially covers piece
    // 1: piece 0's digest is recorded (from the buffer), piece 1's old
    // digest must be dropped (its bytes are now a mix of old and new).
    const w20 = "0123456789abcdefXXXX";
    try std.testing.expect(st.copyIntoCache(f, 0, w20));
    var h0: [piece.digest_len]u8 = undefined;
    piece.digest("0123456789abcdef", &h0);
    try std.testing.expectEqualSlices(u8, &h0, &st.expectedHash(f, 0, 0).?);
    try std.testing.expect(st.expectedHash(f, 1, 0) == null);
}

test "manifest publish then load: a fresh store verifies peer expectations from origin" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-manifest");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-manifest");
    defer sys.deleteTree(std.testing.io, cache_d);

    var writer = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer writer.deinit();
    try std.testing.expectEqual(@as(i32, 0), writer.ensureLayout());
    const wf = try writer.get("m.bin", 32, sys.monoSec(std.testing.io));
    defer writer.releaseFile(wf);
    var h0: [piece.digest_len]u8 = undefined;
    piece.digest("0123456789abcdef", &h0);
    var h1: [piece.digest_len]u8 = undefined;
    piece.digest("ABCDEFGHIJKLMNOP", &h1);
    try std.testing.expectEqual(@as(u32, 16), (try writer.beginFill(wf, 0, sys.monoSec(std.testing.io))).len);
    try std.testing.expectEqual(@as(i32, 0), writer.completeFill(wf, 0, "0123456789abcdef", h0, sys.monoSec(std.testing.io)));
    try std.testing.expectEqual(@as(u32, 16), (try writer.beginFill(wf, 1, sys.monoSec(std.testing.io))).len);
    try std.testing.expectEqual(@as(i32, 0), writer.completeFill(wf, 1, "ABCDEFGHIJKLMNOP", h1, sys.monoSec(std.testing.io)));
    writer.publishManifest(wf);

    // A second store (a cold reader) with no local fills loads the manifest
    // from origin and can verify peer fills immediately.
    var reader = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer reader.deinit();
    try std.testing.expectEqual(@as(i32, 0), reader.ensureLayout());
    const rf = try reader.get("m.bin", 32, sys.monoSec(std.testing.io));
    defer reader.releaseFile(rf);
    const got0 = reader.expectedHash(rf, 0, 0).?;
    const got1 = reader.expectedHash(rf, 1, 0).?;
    try std.testing.expectEqualSlices(u8, &h0, &got0);
    try std.testing.expectEqualSlices(u8, &h1, &got1);
    try std.testing.expect(reader.expectedHash(rf, 2, 0) == null);

    // A manifest for a different grid or size is ignored: the trust
    // reference only applies to this file on this grid.
    var other = Store.init(gpa, std.testing.io, origin_d, cache_d, 32);
    defer other.deinit();
    const of = try other.get("m.bin", 32, sys.monoSec(std.testing.io));
    defer other.releaseFile(of);
    try std.testing.expect(other.expectedHash(of, 0, 0) == null);
}

test "reconcileSize drops every trusted hash with the old marks" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-rsize-hash");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-rsize-hash");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const f = try st.get("r.bin", 16, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    var h: [piece.digest_len]u8 = undefined;
    piece.digest("0123456789abcdef", &h);
    try std.testing.expectEqual(@as(u32, 16), (try st.beginFill(f, 0, sys.monoSec(std.testing.io))).len);
    try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 0, "0123456789abcdef", h, sys.monoSec(std.testing.io)));
    try std.testing.expect(st.expectedHash(f, 0, 0) != null);
    // The same entry observed at a new size reconciles: bits and digests
    // both reset, and the stale sidecar's claim is wiped.
    const f2 = try st.get("r.bin", 32, sys.monoSec(std.testing.io));
    defer st.releaseFile(f2);
    try std.testing.expectEqual(f, f2);
    try std.testing.expect(st.expectedHash(f2, 0, 0) == null);
    f2.mu.lockUncancelable(std.testing.io);
    try std.testing.expectEqual(@as(u32, 0), f2.bits.filled());
    f2.mu.unlock(std.testing.io);
}

test "a transient manifest absence is retried and picked up after publication" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-manifest-retry");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-manifest-retry");
    defer sys.deleteTree(std.testing.io, cache_d);

    // Reader misses first (the writer has not published yet). The absence
    // must be transient: an NFS negative cache can hide the manifest for a
    // moment after the writer's close, and remembering it would disable
    // peer fills for the whole entry lifetime. Virtual instants: the retry
    // gate is a function of now_ms, so the miss, the still-too-soon lookup,
    // and the due lookup run with no sleep.
    var reader = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer reader.deinit();
    try std.testing.expectEqual(@as(i32, 0), reader.ensureLayout());
    reader.manifest_retry_ms = 5;
    const t0: i64 = 1000;
    const rf = try reader.get("m.bin", 32, sys.monoSec(std.testing.io));
    defer reader.releaseFile(rf);
    try std.testing.expect(reader.expectedHash(rf, 0, t0) == null);

    // The writer publishes its manifest (as its release would).
    var writer = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer writer.deinit();
    try std.testing.expectEqual(@as(i32, 0), writer.ensureLayout());
    const wf = try writer.get("m.bin", 32, sys.monoSec(std.testing.io));
    defer writer.releaseFile(wf);
    var h0: [piece.digest_len]u8 = undefined;
    piece.digest("0123456789abcdef", &h0);
    try std.testing.expectEqual(@as(u32, 16), (try writer.beginFill(wf, 0, sys.monoSec(std.testing.io))).len);
    try std.testing.expectEqual(@as(i32, 0), writer.completeFill(wf, 0, "0123456789abcdef", h0, sys.monoSec(std.testing.io)));
    writer.publishManifest(wf);

    // Not yet due: the first miss stamped retry_at = t0 + 5. Exclusive of
    // the boundary's predecessor, inclusive of the instant itself.
    try std.testing.expect(reader.expectedHash(rf, 0, t0) == null);
    try std.testing.expect(reader.expectedHash(rf, 0, t0 + 4) == null);
    const got = reader.expectedHash(rf, 0, t0 + 5).?;
    try std.testing.expectEqualSlices(u8, &h0, &got);
}

test "OriginId.contentChanged is newer mtime or ino, never older mtime" {
    const a = OriginId{ .mtime_sec = 10, .mtime_nsec = 5, .ino = 1, .known = true };
    const newer_sec = OriginId{ .mtime_sec = 11, .mtime_nsec = 0, .ino = 1, .known = true };
    const newer_nsec = OriginId{ .mtime_sec = 10, .mtime_nsec = 6, .ino = 1, .known = true };
    const older = OriginId{ .mtime_sec = 9, .mtime_nsec = 0, .ino = 1, .known = true };
    const other_ino = OriginId{ .mtime_sec = 10, .mtime_nsec = 5, .ino = 2, .known = true };
    const unknown = OriginId{};
    try std.testing.expect(OriginId.contentChanged(a, newer_sec));
    try std.testing.expect(OriginId.contentChanged(a, newer_nsec));
    try std.testing.expect(OriginId.contentChanged(a, other_ino));
    try std.testing.expect(!OriginId.contentChanged(a, older));
    try std.testing.expect(!OriginId.contentChanged(a, a));
    try std.testing.expect(!OriginId.contentChanged(a, unknown));
    try std.testing.expect(!OriginId.contentChanged(unknown, newer_sec));
    try std.testing.expect(OriginId.eql(a, a));
    try std.testing.expect(!OriginId.eql(a, newer_sec));
    try std.testing.expect(!OriginId.eql(a, older));
    try std.testing.expect(!OriginId.eql(a, other_ino));
    try std.testing.expect(!OriginId.eql(a, unknown));
    try std.testing.expect(!OriginId.eql(unknown, unknown));
}

test "OriginId.newerThanMtime is a strictly newer write than the sampled artifact" {
    const id = OriginId{ .mtime_sec = 10, .mtime_nsec = 5, .ino = 1, .known = true };
    var older: c.struct_stat = undefined;
    older.st_mtim = .{ .tv_sec = 9, .tv_nsec = 0 };
    var same: c.struct_stat = undefined;
    same.st_mtim = .{ .tv_sec = 10, .tv_nsec = 5 };
    var newer: c.struct_stat = undefined;
    newer.st_mtim = .{ .tv_sec = 10, .tv_nsec = 6 };
    try std.testing.expect(id.newerThanMtime(older));
    try std.testing.expect(!id.newerThanMtime(same));
    try std.testing.expect(!id.newerThanMtime(newer));
    try std.testing.expect(!(OriginId{}).newerThanMtime(older));
}

test "same-size rewrite with newer mtime wipes cache marks and hashes" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-id-mtime");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-id-mtime");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const t0: i64 = 1_000;
    const id1 = OriginId{ .mtime_sec = 100, .mtime_nsec = 0, .ino = 7, .known = true };
    const id2 = OriginId{ .mtime_sec = 200, .mtime_nsec = 0, .ino = 7, .known = true };
    const f = try st.getIdentified("rw.bin", 16, id1, t0);
    var h: [piece.digest_len]u8 = undefined;
    piece.digest("0123456789abcdef", &h);
    try std.testing.expectEqual(@as(u32, 16), (try st.beginFill(f, 0, t0)).len);
    try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 0, "0123456789abcdef", h, t0));
    try std.testing.expect(st.hasPiece(f, 0, t0));
    try std.testing.expect(st.expectedHash(f, 0, 0) != null);

    const f2 = try st.getIdentified("rw.bin", 16, id2, t0);
    defer st.releaseFile(f2);
    try std.testing.expectEqual(f, f2);
    st.releaseFile(f);
    try std.testing.expect(!st.hasPiece(f2, 0, t0));
    try std.testing.expect(st.expectedHash(f2, 0, 0) == null);
}

test "older origin mtime does not wipe (NFS attribute lag)" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-id-lag");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-id-lag");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const t0: i64 = 1_000;
    const id1 = OriginId{ .mtime_sec = 200, .mtime_nsec = 0, .ino = 7, .known = true };
    const lag = OriginId{ .mtime_sec = 100, .mtime_nsec = 0, .ino = 7, .known = true };
    const f = try st.getIdentified("lag.bin", 16, id1, t0);
    defer st.releaseFile(f);
    try std.testing.expectEqual(@as(u32, 16), (try st.beginFill(f, 0, t0)).len);
    try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 0, "0123456789abcdef", null, t0));

    const f2 = try st.getIdentified("lag.bin", 16, lag, t0);
    defer st.releaseFile(f2);
    try std.testing.expect(st.hasPiece(f2, 0, t0));
}

test "ino change at the same size wipes cache marks" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-id-ino");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-id-ino");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const t0: i64 = 1_000;
    const id1 = OriginId{ .mtime_sec = 100, .mtime_nsec = 0, .ino = 7, .known = true };
    const id2 = OriginId{ .mtime_sec = 100, .mtime_nsec = 0, .ino = 8, .known = true };
    const f = try st.getIdentified("ino.bin", 16, id1, t0);
    defer st.releaseFile(f);
    try std.testing.expectEqual(@as(u32, 16), (try st.beginFill(f, 0, t0)).len);
    try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 0, "0123456789abcdef", null, t0));

    const f2 = try st.getIdentified("ino.bin", 16, id2, t0);
    defer st.releaseFile(f2);
    try std.testing.expect(!st.hasPiece(f2, 0, t0));
}

test "sidecar identity trailer wipes a same-size rewrite across restart" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-id-restart");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-id-restart");
    defer sys.deleteTree(std.testing.io, cache_d);

    const t0: i64 = 1_000;
    const id1 = OriginId{ .mtime_sec = 100, .mtime_nsec = 0, .ino = 7, .known = true };
    const id2 = OriginId{ .mtime_sec = 200, .mtime_nsec = 0, .ino = 7, .known = true };
    {
        var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
        defer st.deinit();
        try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());
        const f = try st.getIdentified("rst.bin", 16, id1, t0);
        defer st.releaseFile(f);
        try std.testing.expectEqual(@as(u32, 16), (try st.beginFill(f, 0, t0)).len);
        try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 0, "0123456789abcdef", null, t0));
        try std.testing.expect(st.hasPiece(f, 0, t0));
    }
    {
        var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
        defer st.deinit();
        try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());
        const f = try st.getIdentified("rst.bin", 16, id2, t0);
        defer st.releaseFile(f);
        try std.testing.expect(!st.hasPiece(f, 0, t0));
        try std.testing.expectEqual(@as(u32, 0), f.bits.filled());
    }
}

test "manifest load does not replace a local origin-fill hash" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-hash-keep");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-hash-keep");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const f = try st.get("keep.bin", 16, sys.monoSec(std.testing.io));
    defer st.releaseFile(f);
    var h_local: [piece.digest_len]u8 = undefined;
    piece.digest("0123456789abcdef", &h_local);
    try std.testing.expectEqual(@as(u32, 16), (try st.beginFill(f, 0, sys.monoSec(std.testing.io))).len);
    try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 0, "0123456789abcdef", h_local, sys.monoSec(std.testing.io)));

    var h_stale: [piece.digest_len]u8 = undefined;
    piece.digest("ABCDEFGHIJKLMNOP", &h_stale);
    var wcb: [128]u8 = undefined;
    const writer_cache = try sys.scratchDir(&wcb, "modelfs-c-hash-keep-w");
    defer sys.deleteTree(std.testing.io, writer_cache);
    var writer = Store.init(gpa, std.testing.io, origin_d, writer_cache, 16);
    defer writer.deinit();
    try std.testing.expectEqual(@as(i32, 0), writer.ensureLayout());
    const wf = try writer.get("keep.bin", 16, sys.monoSec(std.testing.io));
    defer writer.releaseFile(wf);
    try std.testing.expectEqual(@as(u32, 16), (try writer.beginFill(wf, 0, sys.monoSec(std.testing.io))).len);
    try std.testing.expectEqual(@as(i32, 0), writer.completeFill(wf, 0, "ABCDEFGHIJKLMNOP", h_stale, sys.monoSec(std.testing.io)));
    writer.publishManifest(wf);

    f.mu.lockUncancelable(std.testing.io);
    f.manifest_size = null;
    f.manifest_retry_at = 0;
    f.mu.unlock(std.testing.io);
    const got = st.expectedHash(f, 0, 0).?;
    try std.testing.expectEqualSlices(u8, &h_local, &got);
}

test "same-size rewrite does not load a stale origin manifest" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-id-stale-mf");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-id-stale-mf");
    defer sys.deleteTree(std.testing.io, cache_d);

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    const t0: i64 = 1_000;
    const id1 = OriginId{ .mtime_sec = 100, .mtime_nsec = 0, .ino = 7, .known = true };
    const id2 = OriginId{ .mtime_sec = 200, .mtime_nsec = 0, .ino = 7, .known = true };
    const f = try st.getIdentified("stale.bin", 16, id1, t0);
    var h: [piece.digest_len]u8 = undefined;
    piece.digest("0123456789abcdef", &h);
    try std.testing.expectEqual(@as(u32, 16), (try st.beginFill(f, 0, t0)).len);
    try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 0, "0123456789abcdef", h, t0));
    st.publishManifest(f);
    try std.testing.expect(st.expectedHash(f, 0, 0) != null);

    {
        var rcb: [128]u8 = undefined;
        const reader_cache = try sys.scratchDir(&rcb, "modelfs-c-id-stale-mf-r");
        defer sys.deleteTree(std.testing.io, reader_cache);
        var reader = Store.init(gpa, std.testing.io, origin_d, reader_cache, 16);
        defer reader.deinit();
        try std.testing.expectEqual(@as(i32, 0), reader.ensureLayout());
        const rf = try reader.getIdentified("stale.bin", 16, id1, t0);
        defer reader.releaseFile(rf);
        const got = reader.expectedHash(rf, 0, 0).?;
        try std.testing.expectEqualSlices(u8, &h, &got);
    }

    const f2 = try st.getIdentified("stale.bin", 16, id2, t0);
    defer st.releaseFile(f2);
    try std.testing.expectEqual(f, f2);
    st.releaseFile(f);
    // The origin still holds id1's manifest (same path, same size). Its
    // hashes must not become the trust reference for id2: a peer that
    // still has the old piece would then verify and land as the new file.
    try std.testing.expect(st.expectedHash(f2, 0, 0) == null);
}

test "same-size rewrite does not resurrect hashes from a stale manifest" {
    // Writer publishes hashes for content A. A later same-size rewrite
    // (newer mtime) wipes this node's map; the still-published manifest
    // names A's digests and the same file_size, so a load that only
    // checked size would reinstall them and a peer fill would admit A's
    // bytes as the new object.
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-stale-mf");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-stale-mf");
    defer sys.deleteTree(std.testing.io, cache_d);

    var tb: [192]u8 = undefined;
    var zb: [192]u8 = undefined;
    const origin_z = try sys.toZ(&zb, try std.fmt.bufPrint(&tb, "{s}/rw.bin", .{origin_d}));
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(origin_z, "0123456789abcdef"));

    var st = Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
    defer st.deinit();
    try std.testing.expectEqual(@as(i32, 0), st.ensureLayout());

    var ost: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(i32, 0), sys.lstatPath(origin_z, &ost));
    const id1 = OriginId.fromStat(ost);
    const t0: i64 = 1_000;
    const f = try st.getIdentified("rw.bin", 16, id1, t0);
    defer st.releaseFile(f);
    var h_old: [piece.digest_len]u8 = undefined;
    piece.digest("0123456789abcdef", &h_old);
    try std.testing.expectEqual(@as(u32, 16), (try st.beginFill(f, 0, t0)).len);
    try std.testing.expectEqual(@as(i32, 0), st.completeFill(f, 0, "0123456789abcdef", h_old, t0));
    st.publishManifest(f);
    try std.testing.expectEqualSlices(u8, &h_old, &st.expectedHash(f, 0, 0).?);

    // Identity strictly newer than the just-published manifest, matching a
    // rewrite whose origin mtime moved after that publish. Virtual: the
    // origin file is not rewritten, only the identity the entry observes.
    const id2 = OriginId{
        .mtime_sec = id1.mtime_sec + 10,
        .mtime_nsec = id1.mtime_nsec,
        .ino = id1.ino,
        .known = true,
    };
    const f2 = try st.getIdentified("rw.bin", 16, id2, t0);
    defer st.releaseFile(f2);
    try std.testing.expectEqual(f, f2);
    try std.testing.expect(!st.hasPiece(f2, 0, t0));
    try std.testing.expect(st.expectedHash(f2, 0, 0) == null);
}
