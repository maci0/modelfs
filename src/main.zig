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
    // overwrite each other -- the exact collision hostname() refuses to
    // fall into silently.
    if (opts.id) |id| {
        if (id.len == 0) {
            if (!builtin.is_test) std.debug.print("--id needs a non-empty name\n", .{});
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
            std.log.err("--psk-value is empty; refusing to serve unauthenticated", .{});
            return error.EmptyPsk;
        }
        return gpa.dupe(u8, v);
    }
    var z: [sys.c.PATH_MAX]u8 = undefined;
    const p = try sys.toZ(&z, opts.psk_file);
    const raw = sys.readFileAlloc(gpa, p, 4096) catch {
        std.log.err("missing PSK at {s} (mode 0600). create one:", .{opts.psk_file});
        std.log.err("  umask 077; openssl rand -hex 32 > {s}", .{opts.psk_file});
        return error.MissingPsk;
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
        std.log.err("PSK at {s} is empty; refusing to serve unauthenticated", .{opts.psk_file});
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

    // MissingPsk/EmptyPsk are already reported with remediation steps inside
    // loadPsk; anything else still needs a one-line cause before the clean exit.
    const psk = loadPsk(gpa, opts) catch |err| {
        if (err != error.MissingPsk and err != error.EmptyPsk)
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

    var seeds: std.ArrayList(proto.LeaseAddr) = .empty;
    defer seeds.deinit(gpa);
    for (opts.seed.items) |s| {
        try seeds.append(gpa, try parseHostPort(s, proto.default_port));
    }

    const st = try gpa.create(fuse_fs.State);
    st.* = .{
        .gpa = gpa,
        .io = init.io,
        .store = store_mod.Store.init(gpa, init.io, origin, cache, opts.piece),
        .catalog = discover.Catalog.init(gpa, init.io, origin, id, addrs.items, local_ips, seeds.items),
        .server = .{
            .gpa = gpa,
            .io = init.io,
            .psk = psk,
            .store = undefined,
        },
        .psk = psk,
        .direct_io = opts.direct_io,
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

fn cmdStatus(gpa: std.mem.Allocator, opts: Opts) !u8 {
    var z: [sys.c.PATH_MAX]u8 = undefined;
    const p = sys.joinZ(&z, opts.cache, fuse_fs.status_file) catch return 1;
    const blob = sys.readFileAlloc(gpa, p, 4096) catch {
        std.debug.print("modelfs: not running (no {s}/{s})\n", .{ opts.cache, fuse_fs.status_file });
        return 1;
    };
    defer gpa.free(blob);
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
            if (err != error.OpenFailed)
                std.log.warn("peers: cannot read lease {s}: {t}", .{ name, err });
            continue;
        };
        defer gpa.free(blob);
        const parsed = proto.parseLease(gpa, blob) catch {
            std.log.warn("peers: skipping corrupt lease {s}", .{name});
            continue;
        };
        defer parsed.deinit();
        const live = parsed.value.until >= now;
        const status_str = if (live) "live" else "expired";
        std.debug.print("{s} (until={d}, {s})\n", .{ parsed.value.id, parsed.value.until, status_str });
        for (parsed.value.addrs) |a| {
            std.debug.print("  -> {s}:{d} (speed={d}mbps)\n", .{ a.ip, a.port, a.mbps });
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
    // watermarks are percentages of free space (freePercent clamps to 100):
    // values above 100 would pin the cull phase permanently
    try std.testing.expectError(error.BadWatermark, parseArgs(gpa, &environ, &.{ "mount", "--brun", "101" }));
    try std.testing.expectError(error.BadWatermark, parseArgs(gpa, &environ, &.{ "mount", "--bstop", "4294967295" }));
    try std.testing.expectEqual(@as(u32, 100), blk: {
        const parsed = try parseArgs(gpa, &environ, &.{ "mount", "--bcull", "100" });
        defer freeParsed(parsed, gpa);
        break :blk parsed.opts.water.bcull;
    });
    // an empty id (flag or env) would collide every such node onto one lease;
    // kept last because the env put below taints every later parse
    try std.testing.expectError(error.BadId, parseArgs(gpa, &environ, &.{ "mount", "--id", "" }));
    try environ.put("MODELFS_ID", "");
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
