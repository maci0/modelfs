//! CLI entry point: argument parsing, command dispatch (mount/status/peers/
//! pin), and mount wiring into the FUSE loop plus background workers.
const std = @import("std");
const builtin = @import("builtin");

pub const std_options: std.Options = .{
    .log_level = .info,
};

const fuse = @import("c.zig").c;
const piece = @import("piece.zig");
const proto = @import("proto.zig");
const sys = @import("sys.zig");
const store_mod = @import("store.zig");
const discover = @import("discover.zig");
const fuse_fs = @import("fuse_fs.zig");
const cull = @import("cull.zig");

const usage =
    \\modelfs: POSIX mount for model files. Local NVMe, then peers, then NFS.
    \\
    \\Usage:
    \\  modelfs mount <dir> --origin PATH [options]
    \\  modelfs status
    \\  modelfs peers --origin PATH
    \\  modelfs pin <relpath>
    \\  modelfs unpin <relpath>
    \\  modelfs help
    \\
    \\mount:
    \\  --origin PATH         NFS/dir origin (required). Writes go here.
    \\  --cache PATH          Local piece cache (default /var/cache/modelfs)
    \\  --id NAME             Override node id (default: hostname)
    \\  --listen [IP:]PORT    Peer HTTP port (default 18080); binds all interfaces
    \\  --advertise IP:PORT   Extra addresses (default: all non-loopback IPv4)
    \\  --psk FILE            Shared secret (default /etc/modelfs.psk)
    \\  --psk-value STR       Shared secret inline (dev)
    \\  --seed HOST[:PORT]    Peer seed if origin/.cluster is empty
    \\  --piece SIZE          Piece size (default 16M)
    \\  --direct-io           FUSE direct_io (default; skips kernel cache)
    \\  --kernel-cache        Allow kernel page cache (uses UMA RAM, can OOM)
    \\  --brun N              Stop culling above N% free (default 10)
    \\  --bcull N             Start culling at N% free (default 7)
    \\  --bstop N             Cull hard below N% free (default 3)
    \\  --allow-other         -o allow_other (needs user_allow_other)
    \\  --detach              Background after mount
    \\
    \\Env: MODELFS_ORIGIN MODELFS_CACHE MODELFS_PSK MODELFS_ID
    \\
    \\Cluster leases live on the origin at .cluster/<id>.json, not under the
    \\FUSE mount. Same PSK on every spark. Desktop can stay on plain NFS.
    \\
;

const Opts = struct {
    origin: ?[]const u8 = null,
    cache: []const u8 = "/var/cache/modelfs",
    id: ?[]const u8 = null,
    psk_file: []const u8 = "/etc/modelfs.psk",
    psk_value: ?[]const u8 = null,
    piece: u32 = piece.default_size,
    water: cull.Water = .{},
    direct_io: bool = true,
    allow_other: bool = false,
    detach: bool = false,
    listen: ?[]const u8 = null,
    advertise: std.ArrayList(proto.LeaseAddr) = .empty,
    seed: std.ArrayList([]const u8) = .empty,
};

fn parseHostPort(s: []const u8, default_port: u16) !proto.LeaseAddr {
    // Every consumer inet_pton's the ip field (bind, dial, hops scoring), so
    // an empty host ("", ":1234") can only fail later -- or, for --seed,
    // silently on every discovery tick. Reject it where the flag is parsed.
    if (std.mem.findScalarLast(u8, s, ':')) |i| {
        if (i == 0) return error.BadHostPort;
        const port = try std.fmt.parseInt(u16, s[i + 1 ..], 10);
        return .{ .ip = s[0..i], .port = port, .mbps = 0 };
    }
    if (s.len == 0) return error.BadHostPort;
    return .{ .ip = s, .port = default_port, .mbps = 0 };
}

fn isDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

/// "--listen [IP:]PORT": a bare numeric value is a port, any other bare value
/// is a host that keeps the default port. Binding is always wildcard.
fn listenPort(spec: []const u8, default_port: u16) !u16 {
    if (std.mem.findScalarLast(u8, spec, ':')) |i| {
        return std.fmt.parseInt(u16, spec[i + 1 ..], 10);
    }
    if (isDigits(spec)) return std.fmt.parseInt(u16, spec, 10);
    return default_port;
}

/// Consumes the value after a flag; names the flag when it is missing one.
fn takeValue(args: []const []const u8, flag: []const u8, i: *usize) ![]const u8 {
    i.* += 1;
    if (i.* >= args.len) {
        if (!builtin.is_test) std.debug.print("{s} needs a value\n", .{flag});
        return error.MissingValue;
    }
    return args[i.*];
}

/// Watermark percentages: parse failures name the flag instead of surfacing
/// as a bare InvalidCharacter.
fn takePercent(args: []const []const u8, flag: []const u8, i: *usize) !u32 {
    const raw = try takeValue(args, flag, i);
    const pct = std.fmt.parseInt(u32, raw, 10) catch {
        if (!builtin.is_test) std.debug.print("{s} {s}: not a percentage\n", .{ flag, raw });
        return error.BadWatermark;
    };
    // freePercent clamps to 0..100, so an out-of-range watermark would pin
    // the phase decision permanently (bstop=101 culls hard on every tick no
    // matter how full the cache fs is) instead of tracking it.
    if (pct > 100) {
        if (!builtin.is_test) std.debug.print("{s} {s}: percentage must be 0..100\n", .{ flag, raw });
        return error.BadWatermark;
    }
    return pct;
}

fn parseArgs(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map, args: []const []const u8) !struct { cmd: []const u8, opts: Opts, rest: []const []const u8 } {
    if (args.len == 0) return error.Help;
    const cmd = args[0];
    var opts = Opts{};
    // 0.16: environment variables are only reachable via the main function's
    // process.Init; the map is threaded in instead of reading global environ.
    if (environ.get("MODELFS_ORIGIN")) |v| opts.origin = v;
    if (environ.get("MODELFS_CACHE")) |v| opts.cache = v;
    if (environ.get("MODELFS_PSK")) |v| opts.psk_file = v;
    if (environ.get("MODELFS_ID")) |v| opts.id = v;

    var i: usize = 1;
    var rest: std.ArrayList([]const u8) = .empty;
    // Callers only reach their cleanup defer on success (the result struct
    // never gets assigned on error), so parseArgs must release its own lists.
    errdefer {
        rest.deinit(gpa);
        opts.advertise.deinit(gpa);
        opts.seed.deinit(gpa);
    }
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) return error.Help;
        if (std.mem.eql(u8, a, "--origin")) {
            opts.origin = try takeValue(args, a, &i);
        } else if (std.mem.eql(u8, a, "--cache")) {
            opts.cache = try takeValue(args, a, &i);
        } else if (std.mem.eql(u8, a, "--id")) {
            opts.id = try takeValue(args, a, &i);
        } else if (std.mem.eql(u8, a, "--psk")) {
            opts.psk_file = try takeValue(args, a, &i);
        } else if (std.mem.eql(u8, a, "--psk-value")) {
            opts.psk_value = try takeValue(args, a, &i);
        } else if (std.mem.eql(u8, a, "--piece")) {
            const raw = try takeValue(args, a, &i);
            const psz = proto.parseSize(raw) catch {
                if (!builtin.is_test) std.debug.print("--piece {s}: bad size (want e.g. 16M)\n", .{raw});
                return error.BadSize;
            };
            if (psz > std.math.maxInt(u32)) return error.ValueTooLarge;
            // A zero piece makes piece.cover() empty: reads would serve hole
            // zeros forever and nothing would ever hydrate.
            if (psz == 0) return error.ZeroPieceSize;
            opts.piece = @intCast(psz);
        } else if (std.mem.eql(u8, a, "--brun")) {
            opts.water.brun = try takePercent(args, a, &i);
        } else if (std.mem.eql(u8, a, "--bcull")) {
            opts.water.bcull = try takePercent(args, a, &i);
        } else if (std.mem.eql(u8, a, "--bstop")) {
            opts.water.bstop = try takePercent(args, a, &i);
        } else if (std.mem.eql(u8, a, "--direct-io")) {
            opts.direct_io = true;
        } else if (std.mem.eql(u8, a, "--kernel-cache")) {
            opts.direct_io = false;
        } else if (std.mem.eql(u8, a, "--allow-other")) {
            opts.allow_other = true;
        } else if (std.mem.eql(u8, a, "--detach")) {
            opts.detach = true;
        } else if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--foreground")) {
            opts.detach = false;
        } else if (std.mem.eql(u8, a, "--listen")) {
            opts.listen = try takeValue(args, a, &i);
        } else if (std.mem.eql(u8, a, "--advertise")) {
            const v = try takeValue(args, a, &i);
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |one| {
                const hp = parseHostPort(one, proto.default_port) catch {
                    if (!builtin.is_test) std.debug.print("--advertise {s}: bad address (want IP[:PORT])\n", .{v});
                    return error.BadHostPort;
                };
                // Same contract --seed resolves for: every lease consumer
                // (peer dial, hops scoring) inet_pton's the ip field, so a
                // name here would publish an address no peer can ever dial,
                // silently dead-ending this node's P2P routes. Unlike a seed
                // it names our own interface, so there is nothing to resolve:
                // require the dotted quad where the flag is parsed.
                var quad: [4]u8 = undefined;
                if (!discover.parseV4(hp.ip, &quad)) {
                    if (!builtin.is_test) std.debug.print("--advertise {s}: {s} is not an IPv4 address (peers dial dotted quads only)\n", .{ v, hp.ip });
                    return error.BadAdvertiseIp;
                }
                try opts.advertise.append(gpa, hp);
            }
        } else if (std.mem.eql(u8, a, "--seed")) {
            const s = try takeValue(args, a, &i);
            // Validate now with a named message instead of failing later in
            // mount setup with a bare parseInt error.
            _ = parseHostPort(s, proto.default_port) catch {
                if (!builtin.is_test) std.debug.print("--seed {s}: bad address (want HOST[:PORT])\n", .{s});
                return error.BadHostPort;
            };
            try opts.seed.append(gpa, s);
        } else if (a.len > 0 and a[0] == '-') {
            // Plain print, like every other usage error in this loop; the
            // logger's level prefix is noise for a one-shot CLI failure.
            if (!builtin.is_test) std.debug.print("unknown flag {s}\n", .{a});
            return error.UnknownFlag;
        } else {
            try rest.append(gpa, a);
        }
    }
    // Flag and env sources share one gate: an empty id makes this node
    // publish the same lease file as every other empty-id node and
    // overwrite each other, and an id that cannot ride in the lease file
    // name or JSON document (separator, quote, control byte, leading dot)
    // makes every peer's parser refuse the lease -- either way this node
    // drops out of discovery while NFS fallback hides why. Same rules
    // discover.hostname answers to.
    if (opts.id) |id| {
        if (!discover.validId(id)) {
            if (!builtin.is_test)
                std.debug.print("--id \"{s}\": must be printable ASCII without / \\ \" or a leading dot\n", .{id});
            return error.BadId;
        }
    }
    return .{ .cmd = cmd, .opts = opts, .rest = try rest.toOwnedSlice(gpa) };
}

fn loadPsk(gpa: std.mem.Allocator, opts: Opts) ![]u8 {
    // An empty shared secret would authenticate every "Bearer " request;
    // refuse it before any socket is bound.
    if (opts.psk_value) |v| {
        if (v.len == 0) {
            if (!builtin.is_test) std.log.err("--psk-value is empty; refusing to serve unauthenticated", .{});
            return error.EmptyPsk;
        }
        // argv is world-readable via /proc/<pid>/cmdline for the daemon's
        // whole lifetime, so an inline secret hands the cluster credential to
        // every local user. Never refuse (dev convenience), always surface it,
        // like the group-readable PSK-file warning below.
        if (!builtin.is_test)
            std.log.warn("--psk-value exposes the secret in /proc/<pid>/cmdline to every local user; prefer --psk FILE (mode 0600)", .{});
        return gpa.dupe(u8, v);
    }
    var z: [sys.c.PATH_MAX]u8 = undefined;
    const p = try sys.toZ(&z, opts.psk_file);
    var open_errno: i32 = 0;
    const raw = sys.readFileAllocOpenErrno(gpa, p, 4096, &open_errno) catch |err| switch (err) {
        // Remediation output for operators, like every other usage print in
        // this file: suppressed under test so the named errors stay
        // assertable without tripping the runner's error-log counter. A
        // present-but-unreadable file (EACCES, EISDIR) must not be reported
        // as "missing" -- the operator would be told to recreate a file that
        // actually needs its permissions fixed.
        error.OpenFailed => {
            if (open_errno != sys.c.ENOENT) {
                if (!builtin.is_test)
                    std.log.err("cannot read PSK at {s} (errno {d}); check the file's permissions", .{ opts.psk_file, open_errno });
                return error.PskUnreadable;
            }
            if (!builtin.is_test) {
                std.log.err("missing PSK at {s} (mode 0600). create one:", .{opts.psk_file});
                std.log.err("  umask 077; openssl rand -hex 32 > {s}", .{opts.psk_file});
            }
            return error.MissingPsk;
        },
        else => {
            if (!builtin.is_test)
                std.log.err("cannot read PSK at {s}: {t}", .{ opts.psk_file, err });
            return error.PskUnreadable;
        },
    };
    defer gpa.free(raw);
    // A group/world-readable PSK lets any local user impersonate this node to
    // every cluster peer; never refuse an existing deployment, but always
    // surface it.
    var st: sys.c.struct_stat = undefined;
    if (sys.statPath(p, &st) == 0 and (st.st_mode & 0o077) != 0) {
        std.log.warn("PSK file {s} is readable by group/other; run: chmod 600 {s}", .{ opts.psk_file, opts.psk_file });
    }
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        if (!builtin.is_test) std.log.err("PSK at {s} is empty; refusing to serve unauthenticated", .{opts.psk_file});
        return error.EmptyPsk;
    }
    return gpa.dupe(u8, trimmed);
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // argv0
    while (it.next()) |a| try argv.append(gpa, a);

    if (argv.items.len == 0) {
        std.debug.print("{s}", .{usage});
        return 2;
    }
    const parsed = parseArgs(gpa, init.environ_map, argv.items) catch |err| switch (err) {
        error.Help => {
            std.debug.print("{s}", .{usage});
            return 0;
        },
        // Usage errors are operating errors, not crashes: report them as a
        // plain message (the flag sites name the specifics) instead of the
        // error-return stack trace dump.
        else => {
            if (err != error.MissingValue and err != error.UnknownFlag) {
                std.log.err("bad arguments: {t}", .{err});
            }
            return 1;
        },
    };
    defer freeParsed(parsed, gpa);

    if (std.mem.eql(u8, parsed.cmd, "help") or std.mem.eql(u8, parsed.cmd, "--help")) {
        std.debug.print("{s}", .{usage});
        return 0;
    }
    if (std.mem.eql(u8, parsed.cmd, "mount")) {
        if (parsed.rest.len < 1) {
            std.log.err("mount needs a directory", .{});
            std.debug.print("{s}", .{usage});
            return 2;
        }
        return cmdMount(init, parsed.opts, parsed.rest[0]);
    }
    if (std.mem.eql(u8, parsed.cmd, "status")) return cmdStatus(gpa, parsed.opts);
    if (std.mem.eql(u8, parsed.cmd, "peers")) return cmdPeers(gpa, parsed.opts);
    if (std.mem.eql(u8, parsed.cmd, "pin") or std.mem.eql(u8, parsed.cmd, "unpin")) {
        if (parsed.rest.len < 1) {
            std.log.err("{s} needs a path relative to the mount", .{parsed.cmd});
            return 2;
        }
        return cmdPin(gpa, parsed.opts, parsed.rest[0], std.mem.eql(u8, parsed.cmd, "pin"));
    }
    std.log.err("unknown command {s}", .{parsed.cmd});
    std.debug.print("{s}", .{usage});
    return 2;
}

/// realpath of path, creating the directory first when missing. label names
/// the directory ("mountpoint", "cache") in failure messages.
fn ensureDirReal(gpa: std.mem.Allocator, path: []const u8, label: []const u8) ![]u8 {
    return sys.realpathAlloc(gpa, path) catch {
        const rc = sys.mkdirAll(path, 0o755);
        if (rc != 0) {
            std.log.err("cannot create {s} {s} (errno {d})", .{ label, path, -rc });
            return error.MkdirFailed;
        }
        return sys.realpathAlloc(gpa, path) catch {
            std.log.err("{s} {s} is not reachable", .{ label, path });
            return error.BadPath;
        };
    };
}

/// Addresses published in this node's lease: explicit --advertise entries
/// (whose parse-defaulted ports follow --listen), or every advertised local
/// IP, or loopback when nothing else is available.
fn leaseAddrs(gpa: std.mem.Allocator, opts: Opts, local_ips: []const []const u8, eff_port: u16) !std.ArrayList(proto.LeaseAddr) {
    var addrs: std.ArrayList(proto.LeaseAddr) = .empty;
    errdefer addrs.deinit(gpa);
    if (opts.advertise.items.len > 0) {
        try addrs.appendSlice(gpa, opts.advertise.items);
        if (opts.listen != null) {
            for (addrs.items) |*a| {
                if (a.port == proto.default_port) a.port = eff_port;
            }
        }
    } else {
        for (local_ips) |ip| {
            try addrs.append(gpa, .{ .ip = ip, .port = eff_port, .mbps = 0 });
        }
        if (addrs.items.len == 0) {
            try addrs.append(gpa, .{ .ip = "127.0.0.1", .port = eff_port, .mbps = 0 });
        }
    }
    for (addrs.items) |a| {
        std.log.info("advertise {s}:{d}", .{ a.ip, a.port });
    }
    return addrs;
}

/// Seed addresses for Catalog: "--seed HOST[:PORT]" entries. HOST is
/// documented to work, but peer dials only accept dotted quads (inet_pton),
/// so a name must be resolved exactly once here at mount setup, where an
/// unresolvable host can fail the mount loudly instead of silently dead-
/// seeding every discovery tick's dial.
const SeedList = struct {
    addrs: std.ArrayList(proto.LeaseAddr) = .empty,
    /// Backing storage for names resolved at startup; the Catalog borrows
    /// `addrs` for the process lifetime and frees nothing.
    owned_ips: std.ArrayList([]u8) = .empty,

    fn deinit(self: *SeedList, gpa: std.mem.Allocator) void {
        for (self.owned_ips.items) |ip| gpa.free(ip);
        self.owned_ips.deinit(gpa);
        self.addrs.deinit(gpa);
    }
};

fn buildSeeds(gpa: std.mem.Allocator, specs: []const []const u8) !SeedList {
    var out: SeedList = .{};
    errdefer out.deinit(gpa);
    for (specs) |s| {
        const hp = try parseHostPort(s, proto.default_port);
        var quad: [4]u8 = undefined;
        if (discover.parseV4(hp.ip, &quad)) {
            try out.addrs.append(gpa, hp);
            continue;
        }
        var rb: [64]u8 = undefined;
        const rip = sys.resolveIpv4(hp.ip, &rb) orelse {
            if (!builtin.is_test) std.log.err("--seed {s}: host {s} does not resolve to an IPv4 address", .{ s, hp.ip });
            return error.SeedUnresolved;
        };
        const owned = try gpa.dupe(u8, rip);
        try out.owned_ips.append(gpa, owned);
        try out.addrs.append(gpa, .{ .ip = owned, .port = hp.port, .mbps = 0 });
    }
    return out;
}

fn cmdMount(init: std.process.Init, opts: Opts, mount: []const u8) !u8 {
    const gpa = init.gpa;
    const origin_raw = opts.origin orelse {
        std.log.err("mount needs --origin (the NFS path, e.g. /mnt/nas/models)", .{});
        return 2;
    };
    const origin = sys.realpathAlloc(gpa, origin_raw) catch {
        std.log.err("origin {s} is not reachable", .{origin_raw});
        return 1;
    };
    defer gpa.free(origin);

    const mount_abs = ensureDirReal(gpa, mount, "mountpoint") catch return 1;
    defer gpa.free(mount_abs);

    const cache = ensureDirReal(gpa, opts.cache, "cache") catch return 1;
    defer gpa.free(cache);

    // MissingPsk/EmptyPsk/PskUnreadable are already reported with remediation
    // steps inside loadPsk; anything else still needs a one-line cause before
    // the clean exit.
    const psk = loadPsk(gpa, opts) catch |err| {
        if (err != error.MissingPsk and err != error.EmptyPsk and err != error.PskUnreadable)
            std.log.err("load PSK: {t}", .{err});
        return 1;
    };
    defer gpa.free(psk);

    var id_buf: [256]u8 = undefined;
    const id = try gpa.dupe(u8, opts.id orelse discover.hostname(&id_buf));
    defer gpa.free(id);

    const local_ips = discover.localIpv4(gpa) catch &.{};
    defer {
        if (local_ips.len > 0) {
            for (local_ips) |s| gpa.free(s);
            gpa.free(local_ips);
        }
    }
    if (local_ips.len == 0) std.log.warn("no non-loopback IPv4; advertise may be empty", .{});

    // Effective listening port: an explicit --listen wins over the default,
    // including for --advertise entries that did not spell out their own
    // ":PORT" (they carry 18080 from parsing).
    const eff_port: u16 = blk: {
        if (opts.listen) |l| {
            break :blk listenPort(l, proto.default_port) catch {
                std.log.err("bad --listen {s} (want [IP:]PORT)", .{l});
                return 1;
            };
        }
        break :blk proto.default_port;
    };

    var addrs = try leaseAddrs(gpa, opts, local_ips, eff_port);
    defer addrs.deinit(gpa);

    var seed_list = buildSeeds(gpa, opts.seed.items) catch |err| switch (err) {
        // Already reported with the offending flag inside buildSeeds.
        error.SeedUnresolved => return 1,
        else => {
            std.log.err("build seeds: {t}", .{err});
            return 1;
        },
    };
    defer seed_list.deinit(gpa);

    const st = try gpa.create(fuse_fs.State);
    st.* = .{
        .gpa = gpa,
        .io = init.io,
        .store = store_mod.Store.init(gpa, init.io, origin, cache, opts.piece),
        .catalog = discover.Catalog.init(gpa, init.io, origin, id, addrs.items, local_ips, seed_list.addrs.items),
        .server = .{
            .gpa = gpa,
            .io = init.io,
            .psk = psk,
            .store = undefined,
        },
        .psk = psk,
        .direct_io = opts.direct_io,
        .start_secs = sys.monoSec(),
    };
    st.server.store = &st.store;
    st.store.water = opts.water;
    // From here every error return owns st. Without this, an allocation
    // failure while building the fuse argv escaped without teardown,
    // leaking the bound listen fds and skipping the shutdown path that
    // every named failure below takes.
    errdefer teardownMount(st);
    const layout_rc = st.store.ensureLayout();
    if (layout_rc != 0) {
        std.log.err("cannot create cache dirs under {s} (errno {d})", .{ cache, -layout_rc });
        teardownMount(st);
        return 1;
    }
    st.catalog.publish();
    st.catalog.refresh();
    st.server.bindAll(addrs.items) catch |err| {
        std.log.err("bind peer http: {t}", .{err});
        teardownMount(st);
        return 1;
    };

    var o_args: std.ArrayList(u8) = .empty;
    defer o_args.deinit(gpa);
    try o_args.appendSlice(gpa, "default_permissions,auto_unmount,fsname=modelfs,subtype=modelfs,max_idle_threads=8");
    if (opts.allow_other) try o_args.appendSlice(gpa, ",allow_other");
    const o_slice = try gpa.dupeZ(u8, o_args.items);
    defer gpa.free(o_slice);

    const prog = try gpa.dupeZ(u8, "modelfs");
    defer gpa.free(prog);
    const mount_z = try gpa.dupeZ(u8, mount_abs);
    defer gpa.free(mount_z);
    const f_flag = try gpa.dupeZ(u8, "-f");
    defer gpa.free(f_flag);
    const o_flag = try gpa.dupeZ(u8, "-o");
    defer gpa.free(o_flag);

    var cargv: std.ArrayList([*c]u8) = .empty;
    defer cargv.deinit(gpa);
    try cargv.append(gpa, prog.ptr);
    if (!opts.detach) try cargv.append(gpa, f_flag.ptr);
    try cargv.append(gpa, o_flag.ptr);
    try cargv.append(gpa, o_slice.ptr);
    try cargv.append(gpa, mount_z.ptr);

    std.log.info("mount {s} origin={s} cache={s} id={s} piece={d}", .{
        mount_abs, origin, cache, id, opts.piece,
    });

    var ops = fuse_fs.ops();
    const rc = fuseMain(cargv.items, &ops, st);
    teardownMount(st);
    return @intCast(if (rc < 0) 1 else rc);
}

/// Single shutdown path for the mount: signal workers, stop accepting, join
/// background loops, drain in-flight connection handlers, and only then
/// release what they reference. The previous detach-then-sleep teardown could
/// free State while a detached thread was still inside it.
fn teardownMount(st: *fuse_fs.State) void {
    st.running.store(false, .release);
    st.server.stop();
    // Joining the HTTP thread retires its accept loops: past this point no
    // new connection handler can start, so the drain below cannot race a
    // fresh accept. Handlers get 30s socket timeouts; allow a little more.
    for (st.workers.items) |t| t.join();
    st.workers.deinit(st.gpa);
    var waited: u32 = 0;
    while (st.server.http_inflight.load(.monotonic) != 0 and waited < 400) : (waited += 1) {
        sys.sleepMs(100);
    }
    if (st.server.http_inflight.load(.monotonic) != 0) {
        // A detached handler outlived the drain (stalled peer sink resets
        // its 30s send timeout on every chunk; an NFS-hung originPread never
        // returns). Freeing State here hands that thread freed memory the
        // moment its current syscall unwinds. Leak the whole tree instead,
        // mirroring Store.deinit's stuck-handler policy; process exit
        // reclaims it.
        std.log.warn("shutdown: peer handler still inflight after drain; leaking mount state", .{});
        return;
    }
    st.store.deinit();
    st.catalog.deinit();
    st.gpa.destroy(st);
}

fn fuseMain(argv: []const [*c]u8, ops: *const fuse.fuse_operations, st: *fuse_fs.State) c_int {
    const argc: c_int = @intCast(argv.len);
    const cargv: [*c][*c]u8 = @ptrCast(@constCast(argv.ptr));
    if (@hasDecl(fuse, "fuse_main_real_versioned")) {
        var ver = fuse.libfuse_version{
            .major = fuse.FUSE_MAJOR_VERSION,
            .minor = fuse.FUSE_MINOR_VERSION,
            .hotfix = fuse.FUSE_HOTFIX_VERSION,
            .padding = 0,
        };
        return fuse.fuse_main_real_versioned(argc, cargv, ops, @sizeOf(fuse.fuse_operations), &ver, st);
    }
    return fuse.fuse_main_real(argc, cargv, ops, @sizeOf(fuse.fuse_operations), st);
}

/// True when the process named by pid still exists. kill(pid, 0) signals
/// nothing; EPERM means the process exists but belongs to another user.
/// Nonpositive or out-of-range ids name no process.
fn pidAlive(pid: i64) bool {
    if (pid <= 0 or pid > std.math.maxInt(i32)) return false;
    std.posix.kill(@intCast(pid), @enumFromInt(0)) catch |err| return err == error.PermissionDenied;
    return true;
}

/// Only the pid field matters for liveness; every other status.json field is
/// ignored here (and validated by whoever consumes the full document).
const StatusLiveness = struct { pid: i64 };

fn cmdStatus(gpa: std.mem.Allocator, opts: Opts) !u8 {
    var z: [sys.c.PATH_MAX]u8 = undefined;
    const p = sys.joinZ(&z, opts.cache, fuse_fs.status_file) catch return 1;
    const blob = sys.readFileAlloc(gpa, p, 4096) catch {
        std.debug.print("modelfs: not running (no {s}/{s})\n", .{ opts.cache, fuse_fs.status_file });
        return 1;
    };
    defer gpa.free(blob);
    // status.json is a crash leftover until proven otherwise: a daemon that
    // died without unmounting leaves its document behind indefinitely, and
    // serving it verbatim would report a dead node as live to every monitor
    // keying on this command. The pid check retires the artifact when its
    // writer exits; pid reuse can only ever false-positive, never hide a
    // genuinely running daemon behind a stale report.
    const doc = std.json.parseFromSlice(StatusLiveness, gpa, blob, .{ .ignore_unknown_fields = true }) catch {
        std.debug.print("modelfs: not running ({s}/{s} is unreadable)\n", .{ opts.cache, fuse_fs.status_file });
        return 1;
    };
    defer doc.deinit();
    if (!pidAlive(doc.value.pid)) {
        std.debug.print("modelfs: not running (stale status.json names exited pid {d})\n", .{doc.value.pid});
        return 1;
    }
    std.debug.print("{s}", .{blob});
    return 0;
}

fn cmdPeers(gpa: std.mem.Allocator, opts: Opts) !u8 {
    const origin = opts.origin orelse {
        std.log.err("peers needs --origin", .{});
        return 2;
    };
    var dbuf: [sys.c.PATH_MAX]u8 = undefined;
    const dirz = sys.joinZ(&dbuf, origin, discover.cluster_dir) catch return 1;
    const dir = sys.c.opendir(dirz) orelse {
        std.debug.print("no cluster leases at {s}/{s}\n", .{ origin, discover.cluster_dir });
        return 0;
    };
    defer _ = sys.c.closedir(dir);
    const now = sys.nowSec();
    var any = false;
    while (sys.c.readdir(dir)) |ent| {
        const name = sys.dirName(ent);
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        var fbuf: [sys.c.PATH_MAX]u8 = undefined;
        const fp = sys.joinZ(&fbuf, std.mem.span(dirz), name) catch continue;
        const blob = sys.readFileAlloc(gpa, fp, 64 * 1024) catch |err| {
            // Open failure covers the normal race against expiry cleanup;
            // anything persisting across invocations is named, matching the
            // corrupt-lease warn below and Catalog.refresh's policy.
            if (err != error.OpenFailed) {
                std.log.warn("peers: cannot read lease {s}: {t}", .{ discover.displayName(name), err });
            }
            continue;
        };
        defer gpa.free(blob);
        const parsed = proto.parseLease(gpa, blob) catch {
            std.log.warn("peers: skipping corrupt lease {s}", .{discover.displayName(name)});
            continue;
        };
        defer parsed.deinit();
        const live = parsed.value.until >= now;
        const status_str = if (live) "live" else "expired";
        // Lease ids and addresses come off shared storage as other nodes'
        // JSON; echo them only when free of control bytes so `modelfs peers`
        // cannot be turned into a terminal-injection vector.
        const id_shown = if (discover.printable(parsed.value.id)) parsed.value.id else "<id withheld: control bytes>";
        std.debug.print("{s} (until={d}, {s})\n", .{ id_shown, parsed.value.until, status_str });
        for (parsed.value.addrs) |a| {
            const ip_shown = if (discover.printable(a.ip)) a.ip else "<ip withheld>";
            std.debug.print("  -> {s}:{d} (speed={d}mbps)\n", .{ ip_shown, a.port, a.mbps });
        }
        any = true;
    }
    if (!any) std.debug.print("no leases\n", .{});
    return 0;
}

fn cmdPin(gpa: std.mem.Allocator, opts: Opts, path: []const u8, on: bool) !u8 {
    var dummy_io = std.Io.Threaded.init(gpa, .{});
    defer dummy_io.deinit();
    var store = store_mod.Store.init(gpa, dummy_io.io(), opts.origin orelse "", opts.cache, opts.piece);
    defer store.deinit();
    if (store.ensureLayout() != 0) {
        std.log.err("cannot create cache dirs under {s}", .{opts.cache});
        return 1;
    }
    var rel = path;
    if (std.mem.startsWith(u8, rel, "/models/")) rel = rel["/models/".len..];
    if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
    // The pin path joins cache/pin below; ".." would write outside it.
    if (!store_mod.relOk(rel)) {
        std.log.err("pin: refusing path outside the mount root", .{});
        return 1;
    }
    const rc = store.setPin(rel, on);
    if (rc != 0) {
        std.log.err("pin failed errno {d}", .{-rc});
        return 1;
    }
    std.debug.print("{s} {s}\n", .{ if (on) "pinned" else "unpinned", rel });
    return 0;
}

test "parseHostPort splits and defaults" {
    const a = try parseHostPort("192.168.1.5:9999", 18080);
    try std.testing.expectEqualStrings("192.168.1.5", a.ip);
    try std.testing.expectEqual(@as(u16, 9999), a.port);
    const b = try parseHostPort("spark1", 18080);
    try std.testing.expectEqualStrings("spark1", b.ip);
    try std.testing.expectEqual(@as(u16, 18080), b.port);
    try std.testing.expectError(error.Overflow, parseHostPort("h:70000", 18080));
    // An empty host names no interface: bind/dial inet_pton would reject it
    // later (a bad --seed silently, on every discovery tick), so refuse it
    // at the flag boundary instead.
    try std.testing.expectError(error.BadHostPort, parseHostPort("", 18080));
    try std.testing.expectError(error.BadHostPort, parseHostPort(":19081", 18080));
}

test "listenPort accepts bare port per --listen [IP:]PORT" {
    // bare port must win, not fall back to the default (regression: it did)
    try std.testing.expectEqual(@as(u16, 19090), try listenPort("19090", 18080));
    try std.testing.expectEqual(@as(u16, 19090), try listenPort("127.0.0.1:19090", 18080));
    try std.testing.expectEqual(@as(u16, 18080), try listenPort("spark1", 18080));
    try std.testing.expectEqual(@as(u16, 18080), try listenPort("", 18080));
    // numeric garbage must fail loudly, not silently become the default
    try std.testing.expectError(error.Overflow, listenPort("70000", 18080));
    try std.testing.expectError(error.Overflow, listenPort("h:70000", 18080));
}

test "pidAlive answers for live and exited processes" {
    try std.testing.expect(pidAlive(@intCast(std.os.linux.getpid())));
    // Nonpositive and out-of-range ids name no process.
    try std.testing.expect(!pidAlive(0));
    try std.testing.expect(!pidAlive(-5));
    try std.testing.expect(!pidAlive(@as(i64, std.math.maxInt(i32)) + 1));
    // A child that has been spawned AND waited on is deterministically dead:
    // the liveness probe must answer for the process itself, not guess from
    // the id's plausibility.
    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{"true"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const dead_pid: i64 = @intCast(child.id.?);
    const term = try child.wait(std.testing.io);
    try std.testing.expect(term == .exited);
    try std.testing.expect(!pidAlive(dead_pid));
}

test "cmdStatus retires a crashed daemon's status.json as not running" {
    const gpa = std.testing.allocator;
    var cb: [128]u8 = undefined;
    const cache_d = try sys.scratchDir(&cb, "modelfs-status-stale");
    defer sys.deleteTree(std.testing.io, cache_d);

    var zbuf: [192]u8 = undefined;
    var pbuf: [160]u8 = undefined;
    const fp = try std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ cache_d, fuse_fs.status_file });

    // A live writer's document is served verbatim with success.
    var live_buf: [160]u8 = undefined;
    const live_doc = try std.fmt.bufPrint(&live_buf, "{{\"id\":\"me\",\"pid\":{d},\"uptime_s\":1,\"peers\":0,\"piece\":16,\"inflight\":0,\"stats\":{{}}}}\n", .{std.os.linux.getpid()});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), live_doc));
    _ = try cmdStatus(gpa, .{ .cache = cache_d });

    // The same path after the daemon died without cleanup (crash, kill -9):
    // the leftover names an exited pid and must read as not running, exit 1,
    // like the absent-artifact case -- not as a live node with frozen stats.
    var dead_buf: [96]u8 = undefined;
    const dead_doc = try std.fmt.bufPrint(&dead_buf, "{{\"id\":\"me\",\"pid\":-3,\"uptime_s\":99}}\n", .{});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), dead_doc));
    try std.testing.expectEqual(@as(u8, 1), try cmdStatus(gpa, .{ .cache = cache_d }));

    // An unparseable leftover gets the same verdict as an absent one.
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), "not json"));
    try std.testing.expectEqual(@as(u8, 1), try cmdStatus(gpa, .{ .cache = cache_d }));
}

fn freeParsed(p: anytype, gpa: std.mem.Allocator) void {
    // deinit takes a mutable receiver, so each list is copied out of the
    // (possibly const) parsed value before release.
    var adv = p.opts.advertise;
    adv.deinit(gpa);
    var seed = p.opts.seed;
    seed.deinit(gpa);
    gpa.free(p.rest);
}

test "parseArgs mount flags" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{
        "mount",       "/mnt/models", "--origin", "/srv/origin",     "--piece", "4M",
        "--psk-value", "topsecret",   "--listen", "127.0.0.1:19090", "--seed",  "10.0.0.9:19099",
        "--brun",      "12",          "--bcull",  "6",               "--bstop", "2",
        "--detach",
    };
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    const parsed = try parseArgs(gpa, &environ, &args);
    defer freeParsed(parsed, gpa);
    try std.testing.expectEqualStrings("mount", parsed.cmd);
    try std.testing.expectEqualStrings("/mnt/models", parsed.rest[0]);
    try std.testing.expectEqualStrings("/srv/origin", parsed.opts.origin.?);
    try std.testing.expectEqual(@as(u32, 4 * 1024 * 1024), parsed.opts.piece);
    try std.testing.expectEqualStrings("127.0.0.1:19090", parsed.opts.listen.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.opts.seed.items.len);
    try std.testing.expectEqualStrings("10.0.0.9:19099", parsed.opts.seed.items[0]);
    try std.testing.expectEqual(@as(u32, 12), parsed.opts.water.brun);
    try std.testing.expectEqual(@as(u32, 6), parsed.opts.water.bcull);
    try std.testing.expectEqual(@as(u32, 2), parsed.opts.water.bstop);
    try std.testing.expect(parsed.opts.detach);
    // --kernel-cache flips direct_io off; default is on
    try std.testing.expect(parsed.opts.direct_io);
}

test "parseArgs rejects bad values" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    // Usage errors print via std.debug.print, suppressed under test, so all
    // rejection paths are assertable here.
    try std.testing.expectError(error.MissingValue, parseArgs(gpa, &environ, &.{ "mount", "--origin" }));
    try std.testing.expectError(error.Help, parseArgs(gpa, &environ, &.{ "mount", "--help" }));
    try std.testing.expectError(error.UnknownFlag, parseArgs(gpa, &environ, &.{ "mount", "--nope" }));
    // piece size overflows u32
    try std.testing.expectError(error.ValueTooLarge, parseArgs(gpa, &environ, &.{ "mount", "--piece", "999G" }));
    // zero piece size would break hydration and reads (cover() yields nothing)
    try std.testing.expectError(error.ZeroPieceSize, parseArgs(gpa, &environ, &.{ "mount", "--piece", "0" }));
    // malformed seed/advertise addresses are named, not bare parseInt failures
    try std.testing.expectError(error.BadHostPort, parseArgs(gpa, &environ, &.{ "mount", "--seed", "h:70000" }));
    try std.testing.expectError(error.BadHostPort, parseArgs(gpa, &environ, &.{ "mount", "--advertise", "10.0.0.1:99999" }));
    // an empty address (bare comma split) is refused at the flag, not at bind
    try std.testing.expectError(error.BadHostPort, parseArgs(gpa, &environ, &.{ "mount", "--advertise", "," }));
    // host names in --advertise would publish addresses no peer can dial
    try std.testing.expectError(error.BadAdvertiseIp, parseArgs(gpa, &environ, &.{ "mount", "--advertise", "spark1" }));
    try std.testing.expectError(error.BadAdvertiseIp, parseArgs(gpa, &environ, &.{ "mount", "--advertise", "10.0.0.1:19091,host.example" }));
    try std.testing.expectError(error.BadAdvertiseIp, parseArgs(gpa, &environ, &.{ "mount", "--advertise", "::1" }));
    // watermarks are percentages of free space (freePercent clamps to 100):
    // values above 100 would pin the cull phase permanently
    try std.testing.expectError(error.BadWatermark, parseArgs(gpa, &environ, &.{ "mount", "--brun", "101" }));
    try std.testing.expectError(error.BadWatermark, parseArgs(gpa, &environ, &.{ "mount", "--bstop", "4294967295" }));
    try std.testing.expectEqual(@as(u32, 100), blk: {
        const parsed = try parseArgs(gpa, &environ, &.{ "mount", "--bcull", "100" });
        defer freeParsed(parsed, gpa);
        break :blk parsed.opts.water.bcull;
    });
    // An id that cannot ride in the lease file name or JSON document would
    // make every peer's parser refuse this node's lease (or skip it as a
    // dot file): rejected at the flag boundary like --advertise's quads.
    try std.testing.expectError(error.BadId, parseArgs(gpa, &environ, &.{ "mount", "--id", "a\"b" }));
    try std.testing.expectError(error.BadId, parseArgs(gpa, &environ, &.{ "mount", "--id", "a\\b" }));
    try std.testing.expectError(error.BadId, parseArgs(gpa, &environ, &.{ "mount", "--id", "a/b" }));
    try std.testing.expectError(error.BadId, parseArgs(gpa, &environ, &.{ "mount", "--id", ".lead" }));
    try std.testing.expectError(error.BadId, parseArgs(gpa, &environ, &.{ "mount", "--id", "a\nb" }));
    // an empty id (flag or env) would collide every such node onto one lease;
    // kept last because the env put below taints every later parse
    try std.testing.expectError(error.BadId, parseArgs(gpa, &environ, &.{ "mount", "--id", "" }));
    try environ.put("MODELFS_ID", "");
    try std.testing.expectError(error.BadId, parseArgs(gpa, &environ, &.{"mount"}));
    // The env source answers to the same gate.
    try environ.put("MODELFS_ID", "x\"y");
    try std.testing.expectError(error.BadId, parseArgs(gpa, &environ, &.{"mount"}));
}

test "parseArgs defaults come from the environ map" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("MODELFS_ORIGIN", "/env/origin");
    try environ.put("MODELFS_ID", "spark-env");
    const parsed = try parseArgs(gpa, &environ, &.{"mount"});
    defer freeParsed(parsed, gpa);
    try std.testing.expectEqualStrings("/env/origin", parsed.opts.origin.?);
    try std.testing.expectEqualStrings("spark-env", parsed.opts.id.?);
}

test "loadPsk refuses empty secrets and trims file contents" {
    const gpa = std.testing.allocator;
    var db: [128]u8 = undefined;
    const scratch = try sys.scratchDir(&db, "modelfs-psk");
    defer sys.deleteTree(std.testing.io, scratch);

    // Scratch files carry 0644, so the group/other permission warning is an
    // expected line here; raising the log level keeps it off the runner's
    // stderr. Restored on scope exit so later tests still surface warnings.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    // Inline value passes through...
    {
        const psk = try loadPsk(gpa, .{ .psk_value = "inline secret" });
        defer gpa.free(psk);
        try std.testing.expectEqualStrings("inline secret", psk);
    }
    // ...but an empty one would authenticate every "Bearer " request.
    try std.testing.expectError(error.EmptyPsk, loadPsk(gpa, .{ .psk_value = "" }));

    var zb: [192]u8 = undefined;
    // Missing file: the named error the CLI turns into remediation output.
    {
        var pb: [160]u8 = undefined;
        const absent = try std.fmt.bufPrint(&pb, "{s}/absent.psk", .{scratch});
        try std.testing.expectError(error.MissingPsk, loadPsk(gpa, .{ .psk_file = absent }));
    }
    // A path that exists but cannot be opened must be reported unreadable,
    // not "missing": the remediation for a missing file would misdiagnose
    // it. A regular file in place of the final directory component makes
    // open fail ENOTDIR deterministically, even under root.
    {
        var pb: [160]u8 = undefined;
        const blocker = try std.fmt.bufPrint(&pb, "{s}/blocker", .{scratch});
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zb, blocker), "x"));
        var qb: [176]u8 = undefined;
        const behind_blocker = try std.fmt.bufPrint(&qb, "{s}/x.psk", .{blocker});
        try std.testing.expectError(error.PskUnreadable, loadPsk(gpa, .{ .psk_file = behind_blocker }));
    }
    // A PSK over the 4096-byte read cap is a read failure of an existing
    // file (FileTooBig), equally distinct from a missing one.
    {
        var pb: [160]u8 = undefined;
        const big_psk = try std.fmt.bufPrint(&pb, "{s}/big.psk", .{scratch});
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zb, big_psk), "x" ** 5000));
        try std.testing.expectError(error.PskUnreadable, loadPsk(gpa, .{ .psk_file = big_psk }));
    }
    // File contents are trimmed of surrounding whitespace and newline.
    {
        var pb: [160]u8 = undefined;
        const fp = try std.fmt.bufPrint(&pb, "{s}/trimmed.psk", .{scratch});
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zb, fp), "  topsecret \r\n"));
        const psk = try loadPsk(gpa, .{ .psk_file = fp });
        defer gpa.free(psk);
        try std.testing.expectEqualStrings("topsecret", psk);
    }
    // A whitespace-only file is an empty secret: refuse it too.
    {
        var pb: [160]u8 = undefined;
        const fp = try std.fmt.bufPrint(&pb, "{s}/blank.psk", .{scratch});
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zb, fp), "\n\t  \n"));
        try std.testing.expectError(error.EmptyPsk, loadPsk(gpa, .{ .psk_file = fp }));
    }
}

test "buildSeeds passes numeric ips through and resolves names" {
    const gpa = std.testing.allocator;
    // Numeric form: the common case, untouched, nothing owned.
    {
        var sl = try buildSeeds(gpa, &.{"127.0.0.1:19099"});
        defer sl.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), sl.addrs.items.len);
        try std.testing.expectEqualStrings("127.0.0.1", sl.addrs.items[0].ip);
        try std.testing.expectEqual(@as(u16, 19099), sl.addrs.items[0].port);
        try std.testing.expectEqual(@as(usize, 0), sl.owned_ips.items.len);
    }
    // Name form: documented "--seed HOST[:PORT]". Resolved here (localhost
    // via /etc/holds no-network hosts file) and owned by the list.
    {
        var sl = try buildSeeds(gpa, &.{"localhost"});
        defer sl.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), sl.addrs.items.len);
        try std.testing.expectEqualStrings("127.0.0.1", sl.addrs.items[0].ip);
        try std.testing.expectEqual(@as(u16, proto.default_port), sl.addrs.items[0].port);
        try std.testing.expectEqual(@as(usize, 1), sl.owned_ips.items.len);
    }
    // Malformed specs keep parseArgs' named failure path (port overflow
    // surfaces as the underlying parse error, as parseHostPort has always
    // propagated it).
    try std.testing.expectError(error.Overflow, buildSeeds(gpa, &.{"h:70000"}));
}

test "leaseAddrs follows --listen and falls back to loopback" {
    const gpa = std.testing.allocator;

    // Explicit --advertise entries keep their own port unless they carried
    // the default and an explicit --listen overrides it.
    {
        var opts = Opts{};
        opts.listen = "0.0.0.0:19091";
        try opts.advertise.append(gpa, .{ .ip = "10.0.0.1", .port = proto.default_port });
        try opts.advertise.append(gpa, .{ .ip = "10.0.0.2", .port = 19090 });
        defer opts.advertise.deinit(gpa);
        var addrs = try leaseAddrs(gpa, opts, &.{}, 19091);
        defer addrs.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 2), addrs.items.len);
        try std.testing.expectEqual(@as(u16, 19091), addrs.items[0].port);
        try std.testing.expectEqual(@as(u16, 19090), addrs.items[1].port);
    }
    // Without --advertise, every advertised local IP publishes with the
    // effective listening port.
    {
        const local = [_][]const u8{ "192.168.1.5", "10.1.1.5" };
        var addrs = try leaseAddrs(gpa, .{}, &local, 18080);
        defer addrs.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 2), addrs.items.len);
        try std.testing.expectEqualStrings("192.168.1.5", addrs.items[0].ip);
        try std.testing.expectEqual(@as(u16, 18080), addrs.items[0].port);
        try std.testing.expectEqual(@as(u16, 18080), addrs.items[1].port);
    }
    // No addresses at all: loopback keeps the node visible on localhost.
    {
        var addrs = try leaseAddrs(gpa, .{}, &.{}, 19095);
        defer addrs.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), addrs.items.len);
        try std.testing.expectEqualStrings("127.0.0.1", addrs.items[0].ip);
        try std.testing.expectEqual(@as(u16, 19095), addrs.items[0].port);
    }
}
