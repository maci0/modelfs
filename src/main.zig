//! CLI entry point: argument parsing, command dispatch (mount/status/peers/
//! pin/unpin), and mount wiring into the FUSE loop plus background workers.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// The effective log ceiling, moved by MODELFS_LOG (parseArgs) before any
/// command runs. Default info keeps the steady-state daemon quiet while the
/// mount/tick/pin lines stay answerable from the journal.
var active_log_level: std.log.Level = .info;

pub const std_options: std.Options = .{
    // The compile-time gate stays fully open so every level reaches
    // logFilter; the runtime ceiling above decides what actually prints.
    // Without the indirection, raising or lowering verbosity would need a
    // rebuild instead of an environment variable.
    .log_level = .debug,
    .logFn = logFilter,
};

fn logFilter(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(active_log_level)) return;
    std.log.defaultLog(level, scope, format, args);
}

const fuse = sys.c;
const piece = @import("piece.zig");
const proto = @import("proto.zig");
const sys = @import("sys.zig");
const store_mod = @import("store.zig");
const discover = @import("discover.zig");
const fuse_fs = @import("fuse_fs.zig");
const cull = @import("cull.zig");
const fuzzcorpus = @import("fuzzcorpus.zig");

const usage =
    \\modelfs: POSIX mount for model files. Local NVMe, then peers, then NFS.
    \\
    \\Usage:
    \\  modelfs mount <dir> --origin PATH [options]
    \\  modelfs status [--cache PATH]
    \\  modelfs peers --origin PATH
    \\  modelfs pin <relpath> [--cache PATH]
    \\  modelfs unpin <relpath> [--cache PATH]
    \\  modelfs version
    \\  modelfs help
    \\
    \\mount options:
    \\  --origin PATH         Existing NFS/dir origin (required). Writes go here.
    \\  --cache PATH          Local piece cache (default /var/cache/modelfs)
    \\  --id NAME             Override node id (default: short hostname)
    \\  --listen [IP:]PORT    Peer HTTP port (default 18080, 1-65535); binds all interfaces
    \\  --advertise ADDRS     Lease addresses IP[:PORT], comma separated
    \\                        (replaces auto-detect; default: every local IPv4
    \\                        except loopback and 169.254; none -> 127.0.0.1)
    \\  --psk FILE            Shared secret file (default /etc/modelfs.psk, mode 0600)
    \\  --seed HOST[:PORT]    Peer seed while origin/.cluster has no live lease; repeatable
    \\  --piece SIZE          Piece size (default 16M)
    \\  --direct-io           FUSE direct_io (default; skips kernel cache)
    \\  --kernel-cache        Allow kernel page cache (uses UMA RAM, can OOM)
    \\  --brun N              Stop culling above N% free (default 10)
    \\  --bcull N             Start culling at N% free (default 7)
    \\  --bstop N             Cull hard below N% free (default 3)
    \\  --allow-other         -o allow_other (needs user_allow_other)
    \\  --detach              Background after mount
    \\  -f, --foreground      Stay in the foreground (default)
    \\
    \\status/peers/pin/unpin take only the flags shown on their Usage line plus
    \\the shared --origin/--cache/--psk values; mount-only
    \\options are refused elsewhere. Every command also accepts -h/--help,
    \\and -V/--version prints the release. "--" ends flag parsing: later
    \\arguments are taken literally (paths starting with '-'). Long options
    \\accept --name VALUE or --name=VALUE.
    \\
    \\Env: MODELFS_ORIGIN MODELFS_CACHE MODELFS_PSK MODELFS_PSK_VALUE
    \\MODELFS_ID set the same values as their flags; an explicit flag wins.
    \\MODELFS_PSK_VALUE cannot be combined with --psk or MODELFS_PSK on mount.
    \\MODELFS_LOG sets the log ceiling: err, warn, info (default), or debug.
    \\An empty environment value counts as unset (defaults apply).
    \\
    \\Examples:
    \\  modelfs mount /models --origin /net/192.168.0.100/models
    \\  modelfs status | jq -r .id
    \\  modelfs pin gguf/foo.gguf
    \\
    \\Cluster leases live on the origin at .cluster/<id>.json, not under the
    \\FUSE mount. Same PSK on every node. Desktop can stay on plain NFS.
    \\
;

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
    // Bare global forms live at position 0, where parseArgs sees a command
    // name, so they are answered here alongside their subcommand spellings.
    // Extra arguments are refused unless they are themselves those global
    // flags: `modelfs version --help` must match the documented "every
    // command also accepts -h/--help" instead of dying as a positional error.
    switch (classifyMeta(argv.items)) {
        .none => {},
        .help => {
            writeOut(init.io, usage);
            return 0;
        },
        .version => {
            printOut(init.io, init.gpa, "modelfs {s}\n", .{build_options.version});
            return 0;
        },
        .bad => {
            const what: []const u8 = if (isHelpTok(argv.items[0])) "help" else "version";
            std.debug.print("{s} takes no arguments (see 'modelfs help')\n", .{what});
            return 2;
        },
    }
    const parsed = parseArgs(gpa, init.environ_map, argv.items) catch |err| switch (err) {
        error.Help => {
            writeOut(init.io, usage);
            return 0;
        },
        error.Version => {
            printOut(init.io, init.gpa, "modelfs {s}\n", .{build_options.version});
            return 0;
        },
        // Usage errors exit 2, like every other bad invocation in this CLI
        // (missing subcommand argument, unknown command). Each one is named
        // at its own flag site inside parseArgs; only a failure before any
        // site could report (allocation) still needs a line here.
        else => {
            if (err == error.OutOfMemory) std.log.err("out of memory parsing arguments", .{});
            return 2;
        },
    };
    defer freeParsed(parsed, gpa);
    // Positional shapes follow the Usage lines exactly; extra arguments were
    // silently dropped before, so e.g. `status junk` and `mount a b` both
    // looked like they succeeded with the extras meaning something.
    if (std.mem.eql(u8, parsed.cmd, "mount")) {
        if (parsed.rest.len != 1) {
            std.debug.print("mount takes exactly one directory argument (see 'modelfs help')\n", .{});
            return 2;
        }
        return cmdMount(init, parsed.opts, parsed.rest[0]);
    }
    if (std.mem.eql(u8, parsed.cmd, "status")) {
        if (parsed.rest.len != 0) {
            std.debug.print("status takes no arguments (see 'modelfs help')\n", .{});
            return 2;
        }
        return cmdStatus(init.io, gpa, parsed.opts);
    }
    if (std.mem.eql(u8, parsed.cmd, "peers")) {
        if (parsed.rest.len != 0) {
            std.debug.print("peers takes no arguments (see 'modelfs help')\n", .{});
            return 2;
        }
        return cmdPeers(init.io, gpa, parsed.opts);
    }
    if (std.mem.eql(u8, parsed.cmd, "pin") or std.mem.eql(u8, parsed.cmd, "unpin")) {
        if (parsed.rest.len != 1) {
            std.debug.print("{s} takes exactly one path relative to the mount (see 'modelfs help')\n", .{parsed.cmd});
            return 2;
        }
        return cmdPin(init.io, gpa, parsed.opts, parsed.rest[0], std.mem.eql(u8, parsed.cmd, "pin"));
    }
    // parseArgs refuses anything outside the commands dispatched above, so
    // this point is unreachable unless the knownCommand list and this
    // dispatch drift apart; failing loudly here surfaces that immediately.
    unreachable;
}

/// Data output (help text, status JSON, lease listings, pin confirmations)
/// goes to stdout so pipes and redirections see only results; diagnostics
/// stay on stderr via std.log/std.debug.print. Best effort: the runtime
/// ignores SIGPIPE, so a closed reader surfaces here as BrokenPipe and the
/// consumer is gone either way.
fn writeOut(io: std.Io, bytes: []const u8) void {
    // Under test, stdout is the runner's IPC channel (--listen=-): raw data
    // written there corrupts the protocol and wedges the run. A test that
    // needs the operator-facing bytes installs a buffer on captured_stdout.
    if (builtin.is_test) {
        if (captured_stdout) |buf| {
            buf.appendSlice(std.testing.allocator, bytes) catch {};
        }
        return;
    }
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

var captured_stdout: ?*std.ArrayList(u8) = null;

fn printOut(io: std.Io, gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch {
        // A rendered line can outgrow the stack buffer: a lease id comes off
        // other nodes' JSON bounded by the read cap, not by validId, and a
        // pin relpath is whatever argv carried. Dropping the line would hide
        // a real result behind exit 0, so fall back to the heap instead.
        const heap = std.fmt.allocPrint(gpa, fmt, args) catch return;
        defer gpa.free(heap);
        return writeOut(io, heap);
    };
    writeOut(io, line);
}

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
    listen_port: ?u16 = null,
    advertise: std.ArrayList(proto.LeaseAddr) = .empty,
    seed: std.ArrayList([]const u8) = .empty,
};

fn parseHostPort(s: []const u8) !proto.LeaseAddr {
    // Every consumer inet_pton's the ip field (bind, dial, hops scoring), so
    // an empty host ("", ":1234") can only fail later -- or, for --seed,
    // silently on every discovery tick. Reject it where the flag is parsed.
    if (std.mem.findScalarLast(u8, s, ':')) |i| {
        if (i == 0) return error.BadHostPort;
        const port = try std.fmt.parseInt(u16, s[i + 1 ..], 10);
        // Port 0 is a kernel ephemeral bind, not a dialable address: a lease
        // or seed that advertises it is silently unreachable. Refuse it at
        // the flag, like an empty host.
        if (port == 0) return error.ZeroPort;
        return .{ .ip = s[0..i], .port = port, .mbps = 0 };
    }
    if (s.len == 0) return error.BadHostPort;
    return .{ .ip = s, .port = proto.default_port, .mbps = 0 };
}

/// "--listen [IP:]PORT": only the port is consumed (binding is always
/// wildcard), so a bare numeric value is a port and any HOST:PORT form is
/// honored for its explicit port. A bare word or empty value names no port
/// at all; defaulting it would silently mount on 18080 while the caller
/// believes their spec took effect, so it is refused where the flag is
/// parsed, like every other malformed flag value. Port 0 would bind an
/// ephemeral kernel port while the lease still advertised 0, so peers
/// could never dial this node: refused here instead of at first fetch.
fn listenPort(spec: []const u8) !u16 {
    const port = if (std.mem.findScalarLast(u8, spec, ':')) |i|
        try std.fmt.parseInt(u16, spec[i + 1 ..], 10)
    else
        try std.fmt.parseInt(u16, spec, 10);
    if (port == 0) return error.ZeroPort;
    return port;
}

/// CLI size values ("16M", "512", "3 MB") for --piece: plain byte counts or
/// a 1024-based K/M/G suffix. Exactly one unit character may remain;
/// anything else is trailing garbage ("16Mi", "1KB2") that must fail, not
/// silently parse as the prefix's value.
fn parseSize(s: []const u8) !u64 {
    if (s.len == 0) return error.BadSize;
    var i: usize = 0;
    var n: u64 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        const digit = s[i] - '0';
        n = std.math.mul(u64, n, 10) catch return error.BadSize;
        n = std.math.add(u64, n, digit) catch return error.BadSize;
    }
    if (i == 0) return error.BadSize;
    var rest = std.mem.trim(u8, s[i..], " \t");
    if (rest.len > 0 and (rest[rest.len - 1] == 'B' or rest[rest.len - 1] == 'b')) rest = rest[0 .. rest.len - 1];
    if (rest.len == 0) return n;
    if (rest.len != 1) return error.BadSize;
    const mul: u64 = switch (rest[0]) {
        'K', 'k' => 1024,
        'M', 'm' => 1024 * 1024,
        'G', 'g' => 1024 * 1024 * 1024,
        else => return error.BadSize,
    };
    return std.math.mul(u64, n, mul) catch return error.BadSize;
}

/// GNU long-option attached values: `--origin=/nas/models` is the same as
/// `--origin /nas/models`. Short flags (`-f`, `-h`, `-V`) have no attached
/// form here, so `-f=x` stays a single unknown token.
fn splitFlag(a: []const u8) struct { name: []const u8, value: ?[]const u8 } {
    if (a.len >= 3 and a[0] == '-' and a[1] == '-') {
        if (std.mem.indexOfScalar(u8, a, '=')) |eq| {
            return .{ .name = a[0..eq], .value = a[eq + 1 ..] };
        }
    }
    return .{ .name = a, .value = null };
}

fn rejectInlineValue(flag: []const u8, inline_val: ?[]const u8) !void {
    if (inline_val != null) {
        if (!builtin.is_test) std.debug.print("{s} does not take a value (see 'modelfs help')\n", .{flag});
        return error.UnexpectedValue;
    }
}

/// Consumes the value after a flag, or the attached `--name=VALUE` payload.
/// Names the flag when a separate value is missing.
fn takeValue(args: []const []const u8, flag: []const u8, i: *usize, inline_val: ?[]const u8) ![]const u8 {
    if (inline_val) |v| return v;
    i.* += 1;
    if (i.* >= args.len) {
        if (!builtin.is_test) std.debug.print("{s} needs a value (see 'modelfs help')\n", .{flag});
        return error.MissingValue;
    }
    return args[i.*];
}

/// Empty --origin/--cache/--psk would otherwise surface later as a confusing
/// "not reachable" or open-failed path. Same named missing-value refusal as
/// a flag with no argument at all.
fn refuseEmpty(flag: []const u8, value: []const u8) !void {
    if (value.len == 0) {
        if (!builtin.is_test) std.debug.print("{s} needs a value (see 'modelfs help')\n", .{flag});
        return error.MissingValue;
    }
}

fn isHelpTok(s: []const u8) bool {
    return std.mem.eql(u8, s, "help") or
        std.mem.eql(u8, s, "-h") or
        std.mem.eql(u8, s, "--help");
}

fn isVersionTok(s: []const u8) bool {
    return std.mem.eql(u8, s, "version") or
        std.mem.eql(u8, s, "-V") or
        std.mem.eql(u8, s, "--version");
}

/// help/version (and their flag spellings) are answered before parseArgs.
/// Extra arguments are refused unless they are themselves those global flags,
/// so `modelfs version --help` shows help instead of dying as a positional
/// error, matching the documented "every command also accepts -h/--help".
fn classifyMeta(args: []const []const u8) enum { none, help, version, bad } {
    if (args.len == 0) return .none;
    const first_help = isHelpTok(args[0]);
    const first_ver = isVersionTok(args[0]);
    if (!first_help and !first_ver) return .none;
    var help = first_help;
    for (args[1..]) |a| {
        if (isHelpTok(a)) {
            help = true;
            continue;
        }
        if (isVersionTok(a)) continue;
        return .bad;
    }
    return if (help) .help else .version;
}

/// An exported-but-empty variable ("export MODELFS_CACHE=" left behind by a
/// script, a systemd Environment= line with no value) names no configuration:
/// it falls through to the default like an unset variable instead of
/// replacing a usable path with "" or bricking every mount with BadId on a
/// value that never appears anywhere. Explicit empty flags keep their
/// meaning -- `--id ""` is still refused.
fn envValue(environ: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const v = environ.get(name) orelse return null;
    return if (v.len == 0) null else v;
}

/// MODELFS_LOG values name a std.log.Level exactly; anything else ("Info",
/// "warning", "verbose") is refused by the caller instead of silently
/// leaving the default ceiling in force.
fn parseLogLevel(s: []const u8) ?std.log.Level {
    if (std.mem.eql(u8, s, "err")) return .err;
    if (std.mem.eql(u8, s, "warn")) return .warn;
    if (std.mem.eql(u8, s, "info")) return .info;
    if (std.mem.eql(u8, s, "debug")) return .debug;
    return null;
}

/// Refusal line for a MODELFS_-prefixed variable no flag answers to. The
/// name goes through discover.displayName, never verbatim: like MODELFS_ID,
/// it arrives from whatever composed this process's environment (a systemd
/// Environment= line, CI wrapper, remote shell), and a name holding ESC,
/// CR/LF, or their UTF-8 C1 spellings must refuse without injecting terminal
/// escapes or forging log lines. Names longer than the staging buffer render
/// as the generic line; the refusal itself is the point and stays
/// unconditional either way.
fn unknownEnvLine(buf: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "unknown environment variable {s} (see 'modelfs help')\n", .{discover.displayName(name)}) catch "unknown environment variable (see 'modelfs help')\n";
}

/// The MODELFS_ prefix is this CLI's environment namespace; anything under
/// it that no flag answers to is a misspelling, not a foreign variable.
/// Variables outside the namespace are never this binary's business and
/// pass untouched.
fn checkKnownEnv(environ: *const std.process.Environ.Map) !void {
    const known = [_][]const u8{ "MODELFS_ORIGIN", "MODELFS_CACHE", "MODELFS_PSK", "MODELFS_PSK_VALUE", "MODELFS_ID", "MODELFS_LOG" };
    var it = environ.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        if (!std.mem.startsWith(u8, name, "MODELFS_")) continue;
        for (known) |k| {
            if (std.mem.eql(u8, name, k)) break;
        } else {
            if (!builtin.is_test) {
                var lbuf: [512]u8 = undefined;
                std.debug.print("{s}", .{unknownEnvLine(&lbuf, name)});
            }
            return error.UnknownEnv;
        }
    }
}

/// True when sub lies beneath dir (component-wise). Both sides are
/// realpaths, so a leading run of components is containment: "/a/bc" does
/// not start with "/a/b/" and stays outside, while everything sits within
/// "/" (the one realpath that ends in a slash).
fn pathWithin(sub: []const u8, dir: []const u8) bool {
    if (!std.mem.startsWith(u8, sub, dir)) return false;
    if (dir.len > 0 and dir[dir.len - 1] == '/') return true;
    return sub.len > dir.len and sub[dir.len] == '/';
}

/// Equal or one contains the other. Any such pair between the mountpoint
/// and its origin or cache makes the daemon serve or fill through its own
/// mount, so cmdMount refuses it before any socket is bound.
fn pathsOverlap(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b) or pathWithin(a, b) or pathWithin(b, a);
}

/// True when the (already realpathed) path names an existing directory.
/// Both --origin consumers gate on this right after their reachability
/// check: a regular file realpaths fine, but leases can never live under
/// it (.cluster creation fails every tick) and joined relpath reads all
/// die ENOTDIR behind the NFS fallback, so accepting it would trade one
/// named refusal now for a silently dead origin.
fn pathIsDir(zp: [*:0]const u8) bool {
    var st: sys.c.struct_stat = undefined;
    return sys.statPath(zp, &st) == 0 and (st.st_mode & sys.c.S_IFMT) == sys.c.S_IFDIR;
}

/// Refuses mount-only knobs on the other commands, as the help text promises
/// ("status/peers/pin take only the flags shown on their Usage line"):
/// accepted-and-ignored they would silently do nothing (a `status --detach`,
/// a `pin --piece 4M` that changes no piece grid), leaving the caller to
/// believe an option took effect.
fn rejectOutsideMount(cmd: []const u8, flag: []const u8) !void {
    if (!std.mem.eql(u8, cmd, "mount")) {
        if (!builtin.is_test) std.debug.print("{s} only applies to modelfs mount\n", .{flag});
        return error.FlagOutsideMount;
    }
}

/// Refusal line for an --id/MODELFS_ID value failing discover.validId. The
/// offending text goes through discover.displayName, never verbatim: the id
/// can arrive from the environment (a systemd Environment= line, CI wrapper,
/// remote shell), and this is the same echo policy discover.hostname answers
/// to -- an id holding ESC, CR/LF, or their UTF-8 C1 spellings must refuse
/// without injecting terminal escapes or forging log lines. Ids longer than
/// the staging buffer render as the generic line; the refusal itself is the
/// point and stays unconditional either way.
fn badIdLine(buf: []u8, id: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "--id \"{s}\": must be printable ASCII without / \\ \" or a leading dot\n", .{discover.displayName(id)}) catch "--id unusable as cluster id (see 'modelfs help')\n";
}

/// Watermark percentages: parse failures name the flag instead of surfacing
/// as a bare InvalidCharacter.
fn parsePercent(flag: []const u8, raw: []const u8) !u32 {
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

/// The command words main() dispatches on; the bare help/version forms are
/// answered before parseArgs ever runs. Keeping one list means a newly added
/// command missing from it fails loudly everywhere instead of slipping past
/// this gate into the help answer below.
fn knownCommand(cmd: []const u8) bool {
    inline for (.{ "mount", "status", "peers", "pin", "unpin" }) |c| {
        if (std.mem.eql(u8, cmd, c)) return true;
    }
    return false;
}

fn parseArgs(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map, args: []const []const u8) !struct { cmd: []const u8, opts: Opts, rest: []const []const u8 } {
    if (args.len == 0) return error.Help;
    const cmd = args[0];
    // Refuse an unknown command word before any flag scanning: otherwise
    // `modelfs typo-cmd -h` answered with the help text and exit 0, because
    // -h preempted dispatch, so a script's misspelled invocation read as a
    // success. Same verdict as the post-parse refusal this replaces, just
    // reached before -h/-V get their turn.
    if (!knownCommand(cmd)) {
        if (!builtin.is_test)
            std.debug.print("unknown command \"{s}\" (want mount, status, peers, pin, unpin, version, help)\n", .{cmd});
        return error.UnknownCommand;
    }
    var opts = Opts{};
    // A MODELFS_* variable outside the documented set is a typo'd knob
    // (MODELFS_CACHEE, MODELFS_ORIGN): applied-and-ignored it would silently
    // drop the operator's setting (mount onto /var/cache/modelfs instead of
    // the intended cache, wrong origin) and surface only as a later
    // incident. Refused here like every unknown flag.
    try checkKnownEnv(environ);
    // 0.16: environment variables are only reachable via the main function's
    // process.Init; the map is threaded in instead of reading global environ.
    if (envValue(environ, "MODELFS_ORIGIN")) |v| opts.origin = v;
    if (envValue(environ, "MODELFS_CACHE")) |v| opts.cache = v;
    // An explicit file source (env or --psk) plus MODELFS_PSK_VALUE would
    // otherwise silently prefer the inline secret in loadPsk; tracked so
    // mount can refuse the pair instead of picking one.
    var psk_file_set = false;
    if (envValue(environ, "MODELFS_PSK")) |v| {
        opts.psk_file = v;
        psk_file_set = true;
    }
    // The only inline-secret spelling: no flag carries the secret, because
    // argv is world-readable through /proc/<pid>/cmdline while the
    // environment block is readable only by the process owner and root.
    // For scripted mounts that cannot place a PSK file.
    if (envValue(environ, "MODELFS_PSK_VALUE")) |v| opts.psk_value = v;
    // The journal is the only configuration observability this daemon has,
    // so the ceiling is movable per environment: MODELFS_LOG=err quiets a
    // cron'd status loop, debug aids a misbehaving mount. Applied for every
    // command -- status/peers/pin log warnings too. A value outside the
    // documented set is refused like any other malformed knob: silently
    // keeping the default would leave the operator believing verbosity
    // changed.
    if (envValue(environ, "MODELFS_LOG")) |v| {
        const level = parseLogLevel(v) orelse {
            if (!builtin.is_test)
                std.debug.print("MODELFS_LOG {s}: want err, warn, info, or debug\n", .{v});
            return error.BadLogLevel;
        };
        if (!builtin.is_test) active_log_level = level;
    }
    // MODELFS_ID follows the --id flag's mount-only scope: status/peers/pin
    // never read the id, so an ambient shell-wide variable must neither leak
    // into them nor fail them with BadId the way the explicit flag is
    // refused by rejectOutsideMount.
    if (std.mem.eql(u8, cmd, "mount")) {
        if (envValue(environ, "MODELFS_ID")) |v| opts.id = v;
    }

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
        // POSIX end-of-options: everything after "--" is positional, so
        // pin/unpin relpaths and mount dirs that begin with "-" stay
        // reachable instead of dying as unknown flags. Checked before
        // --name=VALUE splitting so a literal "--" cannot be an attached form.
        if (std.mem.eql(u8, a, "--")) {
            try rest.appendSlice(gpa, args[i + 1 ..]);
            break;
        }
        const split = splitFlag(a);
        const flag = split.name;
        const inline_val = split.value;
        if (std.mem.eql(u8, flag, "-h") or std.mem.eql(u8, flag, "--help")) {
            try rejectInlineValue(flag, inline_val);
            return error.Help;
        }
        if (std.mem.eql(u8, flag, "-V") or std.mem.eql(u8, flag, "--version")) {
            try rejectInlineValue(flag, inline_val);
            return error.Version;
        }
        if (std.mem.eql(u8, flag, "--origin")) {
            opts.origin = try takeValue(args, flag, &i, inline_val);
        } else if (std.mem.eql(u8, flag, "--cache")) {
            opts.cache = try takeValue(args, flag, &i, inline_val);
        } else if (std.mem.eql(u8, flag, "--id")) {
            try rejectOutsideMount(cmd, flag);
            opts.id = try takeValue(args, flag, &i, inline_val);
        } else if (std.mem.eql(u8, flag, "--psk")) {
            opts.psk_file = try takeValue(args, flag, &i, inline_val);
            psk_file_set = true;
        } else if (std.mem.eql(u8, flag, "--piece")) {
            try rejectOutsideMount(cmd, flag);
            const raw = try takeValue(args, flag, &i, inline_val);
            const psz = parseSize(raw) catch {
                if (!builtin.is_test) std.debug.print("--piece {s}: bad size (want e.g. 16M)\n", .{raw});
                return error.BadSize;
            };
            if (psz > std.math.maxInt(u32)) {
                if (!builtin.is_test) std.debug.print("--piece {s}: too large (max 4294967295)\n", .{raw});
                return error.ValueTooLarge;
            }
            // A zero piece makes piece.cover() empty: reads would serve hole
            // zeros forever and nothing would ever hydrate.
            if (psz == 0) {
                if (!builtin.is_test) std.debug.print("--piece {s}: must be above zero\n", .{raw});
                return error.ZeroPieceSize;
            }
            opts.piece = @intCast(psz);
        } else if (std.mem.eql(u8, flag, "--brun")) {
            try rejectOutsideMount(cmd, flag);
            opts.water.brun = try parsePercent(flag, try takeValue(args, flag, &i, inline_val));
        } else if (std.mem.eql(u8, flag, "--bcull")) {
            try rejectOutsideMount(cmd, flag);
            opts.water.bcull = try parsePercent(flag, try takeValue(args, flag, &i, inline_val));
        } else if (std.mem.eql(u8, flag, "--bstop")) {
            try rejectOutsideMount(cmd, flag);
            opts.water.bstop = try parsePercent(flag, try takeValue(args, flag, &i, inline_val));
        } else if (std.mem.eql(u8, flag, "--direct-io")) {
            try rejectOutsideMount(cmd, flag);
            try rejectInlineValue(flag, inline_val);
            opts.direct_io = true;
        } else if (std.mem.eql(u8, flag, "--kernel-cache")) {
            try rejectOutsideMount(cmd, flag);
            try rejectInlineValue(flag, inline_val);
            opts.direct_io = false;
        } else if (std.mem.eql(u8, flag, "--allow-other")) {
            try rejectOutsideMount(cmd, flag);
            try rejectInlineValue(flag, inline_val);
            opts.allow_other = true;
        } else if (std.mem.eql(u8, flag, "--detach")) {
            try rejectOutsideMount(cmd, flag);
            try rejectInlineValue(flag, inline_val);
            opts.detach = true;
        } else if (std.mem.eql(u8, flag, "-f") or std.mem.eql(u8, flag, "--foreground")) {
            try rejectOutsideMount(cmd, flag);
            try rejectInlineValue(flag, inline_val);
            opts.detach = false;
        } else if (std.mem.eql(u8, flag, "--listen")) {
            try rejectOutsideMount(cmd, flag);
            const raw = try takeValue(args, flag, &i, inline_val);
            opts.listen_port = listenPort(raw) catch |err| {
                if (!builtin.is_test) {
                    if (err == error.ZeroPort)
                        std.debug.print("--listen {s}: port 0 is not a listen port (want 1-65535)\n", .{raw})
                    else
                        std.debug.print("--listen {s}: bad endpoint (want [IP:]PORT)\n", .{raw});
                }
                return error.BadListen;
            };
        } else if (std.mem.eql(u8, flag, "--advertise")) {
            try rejectOutsideMount(cmd, flag);
            const v = try takeValue(args, flag, &i, inline_val);
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |one| {
                // Comma-separated lists are commonly written with a space
                // after each comma; a leading/trailing space is not part of
                // the address and would fail parseV4 as a host name.
                const tok = std.mem.trim(u8, one, " \t");
                const hp = parseHostPort(tok) catch |err| {
                    if (!builtin.is_test) {
                        if (err == error.ZeroPort)
                            std.debug.print("--advertise {s}: port 0 is not a peer port (want 1-65535)\n", .{v})
                        else
                            std.debug.print("--advertise {s}: bad address (want IP[:PORT])\n", .{v});
                    }
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
        } else if (std.mem.eql(u8, flag, "--seed")) {
            try rejectOutsideMount(cmd, flag);
            const s = try takeValue(args, flag, &i, inline_val);
            // Validate now with a named message instead of failing later in
            // mount setup with a bare parseInt error.
            _ = parseHostPort(s) catch |err| {
                if (!builtin.is_test) {
                    if (err == error.ZeroPort)
                        std.debug.print("--seed {s}: port 0 is not a peer port (want 1-65535)\n", .{s})
                    else
                        std.debug.print("--seed {s}: bad address (want HOST[:PORT])\n", .{s});
                }
                return error.BadHostPort;
            };
            try opts.seed.append(gpa, s);
        } else if (flag.len > 0 and flag[0] == '-') {
            // Plain print, like every other usage error in this loop; the
            // logger's level prefix is noise for a one-shot CLI failure.
            // Echo the original token so `--nope=x` still names what was typed.
            if (!builtin.is_test) std.debug.print("unknown flag {s} (see 'modelfs help')\n", .{a});
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
            if (!builtin.is_test) {
                var lbuf: [512]u8 = undefined;
                std.debug.print("{s}", .{badIdLine(&lbuf, id)});
            }
            return error.BadId;
        }
    }
    // Cross-field gate on the cull watermarks: each value is individually a
    // percentage (parsePercent), but only the strict ordering brun > bcull >
    // bstop gives phase() working hysteresis. Out of order, the daemon
    // hard-culls far above the intended floor (bstop >= bcull) or punches
    // candidates every tick in the run/cull flap band (brun <= bcull).
    if (!cull.ordered(opts.water)) {
        if (!builtin.is_test)
            std.debug.print("watermarks out of order (brun {d}, bcull {d}, bstop {d}): need brun > bcull > bstop\n", .{ opts.water.brun, opts.water.bcull, opts.water.bstop });
        return error.BadWatermarks;
    }
    // Empty path flags would fail later as "not reachable" / missing PSK
    // with no mention of the flag; refuse them at parse like a missing
    // argument. Empty env values already count as unset (defaults apply).
    if (opts.origin) |o| try refuseEmpty("--origin", o);
    try refuseEmpty("--cache", opts.cache);
    try refuseEmpty("--psk", opts.psk_file);
    // loadPsk prefers MODELFS_PSK_VALUE over the file. Both set on mount
    // would start with the env secret while the operator believed --psk
    // (or MODELFS_PSK) won, matching the documented "explicit flag wins"
    // for every other pair. status/peers/pin never load the secret, so a
    // shell-wide inline value must not fail those commands the way the
    // e2e suites pass --psk to them.
    if (std.mem.eql(u8, cmd, "mount") and opts.psk_value != null and psk_file_set) {
        if (!builtin.is_test)
            std.debug.print("MODELFS_PSK_VALUE cannot be combined with --psk or MODELFS_PSK; pick one\n", .{});
        return error.ConflictingPsk;
    }
    return .{ .cmd = cmd, .opts = opts, .rest = try rest.toOwnedSlice(gpa) };
}

fn loadPsk(gpa: std.mem.Allocator, opts: Opts) ![]u8 {
    // An empty shared secret would authenticate every "Bearer " request;
    // refuse it before any socket is bound.
    if (opts.psk_value) |v| {
        if (v.len == 0) {
            if (!builtin.is_test) std.log.err("MODELFS_PSK_VALUE is empty; refusing to serve unauthenticated", .{});
            return error.EmptyPsk;
        }
        // The file form is capped by the read (proto.max_psk_bytes); the
        // inline form must match or a huge env value would start the
        // daemon and then fail every peer request as a truncated head.
        if (v.len > proto.max_psk_bytes) {
            if (!builtin.is_test)
                std.log.err("MODELFS_PSK_VALUE is longer than {d} bytes; refusing", .{proto.max_psk_bytes});
            return error.PskTooLarge;
        }
        return dupeHeaderSafePsk(gpa, v);
    }
    var z: [sys.c.PATH_MAX]u8 = undefined;
    const p = try sys.toZ(&z, opts.psk_file);
    var open_errno: i32 = 0;
    const raw = sys.readFileAllocOpenErrno(gpa, p, proto.max_psk_bytes, &open_errno) catch |err| switch (err) {
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
    return dupeHeaderSafePsk(gpa, trimmed);
}

/// Copies the shared secret, refusing CR or LF anywhere inside it. The
/// secret is embedded verbatim in the peer protocol's "Authorization" header
/// (peer.zig sendRequest) and compared byte-exact there (proto.bearerOk), so
/// a line break would split one node's request head mid-token: every fetch
/// between two such nodes fails 401 with only probe_err counting the storm.
/// Spaces and tabs ride fine (both sides trim only the token's ends); any
/// other byte, non-ASCII included, passes through the slice-based head parser
/// untouched. Failing at load names the cause instead of leaving the operator
/// a cluster that reads as PSK-drifted.
fn dupeHeaderSafePsk(gpa: std.mem.Allocator, secret: []const u8) ![]u8 {
    for (secret) |ch| {
        if (ch == '\r' or ch == '\n') {
            if (!builtin.is_test)
                std.log.err("shared secret contains a line break; it would corrupt the peer request head -- regenerate it (umask 077; openssl rand -hex 32)", .{});
            return error.PskNotHeaderSafe;
        }
    }
    return gpa.dupe(u8, secret);
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
/// replace auto-detect (parse-defaulted ports follow --listen). Otherwise
/// every advertised local IP, or loopback when nothing else is available.
fn leaseAddrs(gpa: std.mem.Allocator, opts: Opts, local_ips: []const []const u8, eff_port: u16) !std.ArrayList(proto.LeaseAddr) {
    var addrs: std.ArrayList(proto.LeaseAddr) = .empty;
    errdefer addrs.deinit(gpa);
    if (opts.advertise.items.len > 0) {
        try addrs.appendSlice(gpa, opts.advertise.items);
        if (opts.listen_port != null) {
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
        const hp = try parseHostPort(s);
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
        std.debug.print("mount needs --origin (the NFS path, e.g. /mnt/nas/models; or MODELFS_ORIGIN)\n", .{});
        return 2;
    };
    const origin = sys.realpathAlloc(gpa, origin_raw) catch {
        std.log.err("origin {s} is not reachable", .{origin_raw});
        return 1;
    };
    defer gpa.free(origin);
    // Reachable is not enough: a regular file realpaths fine but cannot
    // hold .cluster leases or serve joined relpath reads. Refused before
    // the mountpoint or cache is touched, like the dependent-path gates
    // below.
    var ozbuf: [sys.c.PATH_MAX]u8 = undefined;
    if (!if (sys.toZ(&ozbuf, origin)) |z| pathIsDir(z) else |_| false) {
        std.log.err("origin {s} is not a directory", .{origin});
        return 1;
    }

    const mount_abs = ensureDirReal(gpa, mount, "mountpoint") catch return 1;
    defer gpa.free(mount_abs);

    const cache = ensureDirReal(gpa, opts.cache, "cache") catch return 1;
    defer gpa.free(cache);

    // Dependent-path gate: the kernel routes by mount, so origin preads or
    // cache piece writes under the mountpoint would come back through this
    // daemon's own FUSE handlers, each nesting another request until the
    // handler threads exhaust and the mount wedges. Origin overlapping the
    // cache would write piece files onto the shared store (every node's
    // data/meta/pin landing in the origin, stomping each other). Both
    // sides are already realpaths, so symlinks cannot smuggle the overlap
    // past this check.
    if (pathsOverlap(origin, mount_abs)) {
        std.log.err("mountpoint {s} equals or contains origin {s}; mount outside the origin", .{ mount_abs, origin });
        return 1;
    }
    if (pathsOverlap(cache, mount_abs)) {
        std.log.err("mountpoint {s} equals or contains cache {s}; keep the cache outside the mountpoint", .{ mount_abs, cache });
        return 1;
    }
    if (pathsOverlap(origin, cache)) {
        std.log.err("origin {s} equals or overlaps cache {s}; keep the cache off the origin", .{ origin, cache });
        return 1;
    }

    // MissingPsk/EmptyPsk/PskUnreadable are already reported with remediation
    // steps inside loadPsk; anything else still needs a one-line cause before
    // the clean exit.
    const psk = loadPsk(gpa, opts) catch |err| {
        if (err != error.MissingPsk and err != error.EmptyPsk and err != error.PskUnreadable)
            std.log.err("load PSK: {t}", .{err});
        return 1;
    };
    defer {
        std.crypto.secureZero(u8, psk);
        gpa.free(psk);
    }
    // The secret is in memory from here: refuse cores so a crash cannot
    // spill it, and drop MODELFS_PSK_VALUE so fuse_main's auto_unmount
    // helper cannot inherit it through the environment block.
    sys.disableCoreDumps();
    sys.scrubPskEnv();

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
    // ":PORT" (they carry 18080 from parsing). The spec itself was validated
    // at flag-parse time, so nothing can fail here.
    const eff_port: u16 = opts.listen_port orelse proto.default_port;

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
    st.init(gpa, init.io, origin, cache, opts.piece, opts.water, id, addrs.items, local_ips, seed_list.addrs.items, psk, opts.direct_io);
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
    // One wall-clock instant for both lease steps, like every discovery tick
    // (discLoop): publish's until stamp and refresh's expiry filter decide
    // against the same sample instead of two reads drifting across startup,
    // which could persist a lease a same-tick refresh would call expired.
    const cluster_now = sys.nowSec(init.io);
    st.catalog.publish(cluster_now);
    st.catalog.refresh(cluster_now);
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

    // The whole effective configuration in one line: a cull/listen/io
    // misconfiguration must be diagnosable from the journal alone, without
    // reconstructing which flag or env var won. Secrets never appear here.
    std.log.info("mount {s} origin={s} cache={s} id={s} piece={d} listen=:{d} io={s} water={d}/{d}/{d} allow_other={}", .{
        mount_abs,                                  origin,           cache,
        id,                                         opts.piece,       eff_port,
        if (opts.direct_io) "direct" else "kernel", opts.water.brun,  opts.water.bcull,
        opts.water.bstop,                           opts.allow_other,
    });

    var ops = fuse_fs.ops();
    const rc = fuseMain(cargv.items, &ops, st);
    teardownMount(st);
    // Lifecycle closure next to the startup "mount" line: when this node
    // later shows up with an expired lease in `modelfs peers`, the journal
    // distinguishes a cleanly stopped daemon from one that crashed or was
    // killed by the absence of this line. A nonzero rc means the mount never
    // served; libfuse already narrated the failure on stderr.
    if (rc == 0) std.log.info("unmounted {s}", .{mount_abs});
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
        sys.sleepMs(st.io, 100);
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

/// Only liveness fields matter here; every other status.json field is
/// ignored (and validated by whoever consumes the full document). now_s and
/// mono_s are optional so artifacts from older builds keep parsing: without
/// a stamp the staleness gate below simply cannot fire.
const StatusLiveness = struct { pid: i64, now_s: ?i64 = null, mono_s: ?i64 = null };

/// How long a status.json may go unrefreshed before `status` stops serving
/// it as evidence of a working mount. The discovery tick rewrites the
/// artifact every 10s, so this tolerates eleven missed ticks; a daemon
/// wedged inside a hung origin call or a stuck worker leaves the file aging
/// past it while its pid lives on, which the pid check alone cannot catch.
const max_status_age_secs: i64 = 120;

/// Seconds since the heartbeat was written. Prefer `mono_s` (CLOCK_MONOTONIC,
/// comparable across processes on this machine) so an NTP step or admin
/// clock set cannot make a wedged daemon look fresh or a healthy one look
/// dead. Fall back to wall-clock `now_s` for artifacts from older builds.
/// Saturating subtract so a hostile i64-min stamp cannot overflow the
/// subtraction in safe builds.
fn statusAgeSecs(io: std.Io, doc: StatusLiveness) ?i64 {
    if (doc.mono_s) |stamp| return sys.monoSec(io) -| stamp;
    if (doc.now_s) |stamp| return sys.nowSec(io) -| stamp;
    return null;
}

fn cmdStatus(io: std.Io, gpa: std.mem.Allocator, opts: Opts) !u8 {
    var z: [sys.c.PATH_MAX]u8 = undefined;
    const p = sys.joinZ(&z, opts.cache, store_mod.status_file) catch {
        // Same audience as the "not running" prints below: a bare exit 1
        // would leave the operator guessing which path was refused.
        std.debug.print("modelfs: cache path too long to name {s}/{s}\n", .{ opts.cache, store_mod.status_file });
        return 1;
    };
    var open_errno: i32 = 0;
    const blob = sys.readFileAllocOpenErrno(gpa, p, 4096, &open_errno) catch |err| {
        // An artifact that exists but cannot be opened (EACCES for a status
        // query from another user, ELOOP on a planted link) must not read as
        // "not running (no ...)": a daemon may be live and refreshing exactly
        // this file, and the remediation differs -- the same distinction
        // loadPsk draws for its PSK file.
        if (!builtin.is_test) {
            if (err == error.OpenFailed and open_errno != sys.c.ENOENT)
                std.debug.print("modelfs: cannot read {s}/{s} (errno {d}); cannot tell whether the daemon is running\n", .{ opts.cache, store_mod.status_file, open_errno })
            else
                std.debug.print("modelfs: not running (no {s}/{s})\n", .{ opts.cache, store_mod.status_file });
        }
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
        if (!builtin.is_test) std.debug.print("modelfs: not running ({s}/{s} is unreadable)\n", .{ opts.cache, store_mod.status_file });
        return 1;
    };
    defer doc.deinit();
    if (!pidAlive(doc.value.pid)) {
        if (!builtin.is_test) std.debug.print("modelfs: not running (stale status.json names exited pid {d})\n", .{doc.value.pid});
        return 1;
    }
    // A live pid with a frozen artifact is the wedged case: the daemon hangs
    // (origin call that never returns, deadlocked worker) and keeps status.json
    // exactly as it was when the discovery tick last got to run. Serving it
    // would report a mount that cannot serve reads as healthy to every
    // monitor keying on this command's exit code. Age is monotonic when the
    // document carries mono_s, so a wall-clock step no longer flips the
    // verdict; the now_s fallback still treats a backward step as fresh.
    if (statusAgeSecs(io, doc.value)) |age| {
        if (age > max_status_age_secs) {
            if (!builtin.is_test)
                std.debug.print("modelfs: not serving ({s}/{s} is {d}s stale; the daemon stopped ticking)\n", .{ opts.cache, store_mod.status_file, age });
            return 1;
        }
    }
    writeOut(io, blob);
    return 0;
}

fn cmdPeers(io: std.Io, gpa: std.mem.Allocator, opts: Opts) !u8 {
    const origin = opts.origin orelse {
        std.debug.print("peers needs --origin (or MODELFS_ORIGIN)\n", .{});
        return 2;
    };
    // Same reachability gate mount applies to --origin: a typo'd path must
    // fail loudly instead of reading as an empty cluster through the
    // missing-.cluster branch below.
    const real = sys.realpathAlloc(gpa, origin) catch {
        if (!builtin.is_test) std.log.err("origin {s} is not reachable", .{origin});
        return 1;
    };
    defer gpa.free(real);
    // And the same non-directory gate: a file at --origin can never hold
    // .cluster leases, so listing it as an empty cluster would read a dead
    // origin as healthy.
    var rzbuf: [sys.c.PATH_MAX]u8 = undefined;
    if (!if (sys.toZ(&rzbuf, real)) |z| pathIsDir(z) else |_| false) {
        if (!builtin.is_test) std.log.err("origin {s} is not a directory", .{origin});
        return 1;
    }
    var dbuf: [sys.c.PATH_MAX]u8 = undefined;
    const dirz = sys.joinZ(&dbuf, origin, discover.cluster_dir) catch {
        std.log.err("origin path too long to name {s}/{s}", .{ origin, discover.cluster_dir });
        return 1;
    };
    if (sys.c.opendir(dirz)) |dir| {
        defer _ = sys.c.closedir(dir);
        const now = sys.nowSec(io);

        // Collect before printing: readdir order is filesystem-dependent (and
        // the origin is NFS), so sorting by lease file name keeps the listing a
        // function of the directory's contents alone and run-to-run diffable.
        const Row = struct {
            name: []const u8,
            doc: std.json.Parsed(proto.Lease),
        };
        var rows: std.ArrayList(Row) = .empty;
        // parseLease leaves unescaped strings pointing into the file blob
        // (std.json's alloc_if_needed), so every blob must outlive the
        // printing below, not just the loop iteration that read it.
        var blobs: std.ArrayList([]u8) = .empty;
        defer {
            for (rows.items) |r| r.doc.deinit();
            for (rows.items) |r| gpa.free(r.name);
            rows.deinit(gpa);
            for (blobs.items) |b| gpa.free(b);
            blobs.deinit(gpa);
        }
        while (sys.c.readdir(dir)) |ent| {
            const name = sys.dirName(ent);
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            var fbuf: [sys.c.PATH_MAX]u8 = undefined;
            const fp = sys.joinZ(&fbuf, std.mem.span(dirz), name) catch continue;
            var open_errno: i32 = 0;
            const blob = sys.readFileAllocOpenErrno(gpa, fp, 64 * 1024, &open_errno) catch |err| {
                // ENOENT is the normal race against expiry cleanup; any other
                // failure persists across invocations and is named, matching
                // the corrupt-lease warn below and Catalog.refresh's policy.
                if (err == error.OpenFailed) {
                    if (open_errno != sys.c.ENOENT)
                        std.log.warn("peers: cannot open lease {s} (errno {d})", .{ discover.displayName(name), open_errno });
                } else {
                    std.log.warn("peers: cannot read lease {s}: {t}", .{ discover.displayName(name), err });
                }
                continue;
            };
            const parsed = proto.parseLease(gpa, blob) catch {
                gpa.free(blob);
                std.log.warn("peers: skipping corrupt lease {s}", .{discover.displayName(name)});
                continue;
            };
            blobs.append(gpa, blob) catch {
                parsed.deinit();
                gpa.free(blob);
                continue;
            };
            const owned_name = gpa.dupe(u8, name) catch {
                parsed.deinit();
                _ = blobs.pop();
                gpa.free(blob);
                continue;
            };
            rows.append(gpa, .{ .name = owned_name, .doc = parsed }) catch {
                gpa.free(owned_name);
                parsed.deinit();
                _ = blobs.pop();
                gpa.free(blob);
                continue;
            };
        }
        std.mem.sort(Row, rows.items, {}, struct {
            fn lessThan(_: void, a: Row, b: Row) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);

        var any = false;
        for (rows.items) |r| {
            const lease = r.doc.value;
            const live = lease.until >= now;
            const status_str = if (live) "live" else "expired";
            // Lease ids and addresses come off shared storage as other nodes'
            // JSON; echo them only when free of control bytes so `modelfs peers`
            // cannot be turned into a terminal-injection vector.
            const id_shown = if (discover.printable(lease.id)) lease.id else "<id withheld: control bytes>";
            printOut(io, gpa, "{s} (until={d}, {s})\n", .{ id_shown, lease.until, status_str });
            for (lease.addrs) |a| {
                const ip_shown = if (discover.printable(a.ip)) a.ip else "<ip withheld>";
                printOut(io, gpa, "  -> {s}:{d} (speed={d}mbps)\n", .{ ip_shown, a.port, a.mbps });
            }
            any = true;
        }
        if (!any) printOut(io, gpa, "no leases\n", .{});
    } else {
        // The origin itself was verified reachable above, so a missing or
        // unreadable .cluster dir here is a fresh/empty cluster, not an
        // error: same exit-0 empty output as below, with the reason on
        // stdout next to where the listing would have been.
        printOut(io, gpa, "no cluster leases at {s}/{s}\n", .{ origin, discover.cluster_dir });
    }
    return 0;
}

fn cmdPin(io: std.Io, gpa: std.mem.Allocator, opts: Opts, path: []const u8, on: bool) !u8 {
    var rel = path;
    if (std.mem.startsWith(u8, rel, "/models/")) rel = rel["/models/".len..];
    if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
    // The pin path joins cache/pin below; ".." would write outside it.
    // Gate before ensureLayout so a refused path cannot create cache dirs.
    if (!store_mod.relOk(rel)) {
        // Suppressed under test like every usage print here, so the refusal
        // stays assertable without tripping the runner's error-log counter.
        // `/models/` strips to empty (the prefix convenience for the default
        // mountpoint) and `..` would write outside cache/pin: name which.
        if (!builtin.is_test) {
            if (rel.len == 0)
                std.debug.print("{s}: empty path (need a path relative to the mount, not /models itself)\n", .{if (on) "pin" else "unpin"})
            else
                std.debug.print("{s}: refusing path outside the mount root\n", .{if (on) "pin" else "unpin"});
        }
        return 1;
    }
    var dummy_io = std.Io.Threaded.init(gpa, .{});
    defer dummy_io.deinit();
    var store = store_mod.Store.init(gpa, dummy_io.io(), opts.origin orelse "", opts.cache, opts.piece);
    defer store.deinit();
    // Same operator trace as cmdMount's mount-time layout check: the errno
    // distinguishes EACCES from ENOSPC, which the remediation differs for.
    const layout_rc = store.ensureLayout();
    if (layout_rc != 0) {
        std.log.err("cannot create cache dirs under {s} (errno {d})", .{ opts.cache, -layout_rc });
        return 1;
    }
    const rc = store.setPin(rel, on);
    if (rc != 0) {
        std.log.err("{s} failed errno {d}", .{ if (on) "pin" else "unpin", -rc });
        return 1;
    }
    // Audit line beside the stdout confirmation: pins are persistent state
    // that shields a file from culling across restarts, so "why is this file
    // never culled" must be answerable from the journal alone, including
    // when stdout went down a pipe. rel passed relOk, so echoing it cannot
    // forge log lines.
    std.log.info("{s} {s}", .{ if (on) "pinned" else "unpinned", rel });
    printOut(io, gpa, "{s} {s}\n", .{ if (on) "pinned" else "unpinned", rel });
    return 0;
}

test "badIdLine renders refused ids through the displayName echo gate" {
    // MODELFS_ID and --id can arrive from environments this process does not
    // control, so the refusal line must never echo the raw value: ESC (OSC
    // title escape) or CR/LF (forged follow-up lines) would inject into the
    // operator's terminal exactly like discover.hostname's own gate warns.
    var buf: [512]u8 = undefined;
    {
        const line = badIdLine(&buf, "\x1b]0;pwned\x07");
        try std.testing.expect(std.mem.indexOf(u8, line, "\x1b") == null);
        try std.testing.expect(std.mem.indexOf(u8, line, "\n2026-08-26 forged") == null);
        try std.testing.expect(std.mem.indexOf(u8, line, "<name withheld: control bytes>") != null);
    }
    // The UTF-8 C1 spellings ride in as 0xC2 0x80..0xC2 0x9F and get the same
    // withholding as their raw C0 counterparts.
    {
        const line = badIdLine(&buf, "\xc2\x9d0;pwned\xc2\x9c");
        try std.testing.expect(std.mem.indexOf(u8, line, "\xc2\x9d") == null);
        try std.testing.expect(std.mem.indexOf(u8, line, "<name withheld: control bytes>") != null);
    }
    // U+2028 splits Unicode-aware terminals; the refusal must not echo it.
    {
        const line = badIdLine(&buf, "spark1\u{2028}ERROR forged");
        try std.testing.expect(std.mem.indexOf(u8, line, "\u{2028}") == null);
        try std.testing.expect(std.mem.indexOf(u8, line, "<name withheld: control bytes>") != null);
    }
    // A printable but invalid id (quote) still names itself verbatim, so the
    // operator sees which value was refused.
    {
        const line = badIdLine(&buf, "a\"b");
        try std.testing.expect(std.mem.indexOf(u8, line, "--id \"a\"b\":") != null);
    }
    // An id that cannot fit the staging buffer degrades to the generic line:
    // the refusal stays unconditional either way.
    const long = badIdLine(buf[0..64], "x" ** 100);
    try std.testing.expectEqualStrings("--id unusable as cluster id (see 'modelfs help')\n", long);
}

test "parseHostPort splits and defaults" {
    const a = try parseHostPort("192.168.1.5:9999");
    try std.testing.expectEqualStrings("192.168.1.5", a.ip);
    try std.testing.expectEqual(@as(u16, 9999), a.port);
    const b = try parseHostPort("spark1");
    try std.testing.expectEqualStrings("spark1", b.ip);
    try std.testing.expectEqual(@as(u16, 18080), b.port);
    try std.testing.expectError(error.Overflow, parseHostPort("h:70000"));
    // An empty host names no interface: bind/dial inet_pton would reject it
    // later (a bad --seed silently, on every discovery tick), so refuse it
    // at the flag boundary instead.
    try std.testing.expectError(error.BadHostPort, parseHostPort(""));
    try std.testing.expectError(error.BadHostPort, parseHostPort(":19081"));
    // Port 0 would publish an undialable lease / seed.
    try std.testing.expectError(error.ZeroPort, parseHostPort("10.0.0.9:0"));
    try std.testing.expectError(error.ZeroPort, parseHostPort("spark1:0"));
}

test "listenPort accepts bare port per --listen [IP:]PORT" {
    // bare port must win, not fall back to the default (regression: it did)
    try std.testing.expectEqual(@as(u16, 19090), try listenPort("19090"));
    try std.testing.expectEqual(@as(u16, 19090), try listenPort("127.0.0.1:19090"));
    // the host part is never consumed (binding is always wildcard), so a
    // name there is tolerated as long as the explicit port rides along
    try std.testing.expectEqual(@as(u16, 19090), try listenPort("spark1:19090"));
    try std.testing.expectEqual(@as(u16, 19090), try listenPort(":19090"));
    // a bare word or empty value names no port: defaulting it would mount on
    // 18080 while the caller believes their spec took effect
    try std.testing.expectError(error.InvalidCharacter, listenPort("spark1"));
    try std.testing.expectError(error.InvalidCharacter, listenPort(""));
    try std.testing.expectError(error.InvalidCharacter, listenPort("spark1:"));
    // numeric garbage must fail loudly, not silently become the default
    try std.testing.expectError(error.Overflow, listenPort("70000"));
    try std.testing.expectError(error.Overflow, listenPort("h:70000"));
    // Port 0 binds an ephemeral kernel port but the lease would still say 0.
    try std.testing.expectError(error.ZeroPort, listenPort("0"));
    try std.testing.expectError(error.ZeroPort, listenPort("127.0.0.1:0"));
    try std.testing.expectError(error.ZeroPort, listenPort(":0"));
}

test "parseSize overflow and invalid" {
    try std.testing.expectError(error.BadSize, parseSize("9999999999999999999999999999999"));
    try std.testing.expectError(error.BadSize, parseSize("18446744073709551615G"));
    try std.testing.expectError(error.BadSize, parseSize("abc"));
    try std.testing.expectError(error.BadSize, parseSize(""));
    try std.testing.expectError(error.BadSize, parseSize("12x"));
    // trailing garbage after a valid prefix must not parse as the prefix
    try std.testing.expectError(error.BadSize, parseSize("16Mfoo"));
    try std.testing.expectError(error.BadSize, parseSize("1KB2"));
}

test "parseSize accepts plain and suffixed values" {
    try std.testing.expectEqual(@as(u64, 0), try parseSize("0"));
    try std.testing.expectEqual(@as(u64, 512), try parseSize("512"));
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024), try parseSize("16M"));
    try std.testing.expectEqual(@as(u64, 4 * 1024 * 1024 * 1024), try parseSize("4G"));
    try std.testing.expectEqual(@as(u64, 2048), try parseSize("2k"));
    try std.testing.expectEqual(@as(u64, 4096), try parseSize("4KB"));
    try std.testing.expectEqual(@as(u64, 3145728), try parseSize("3 MB"));
    // u64 max is exactly representable
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), try parseSize("18446744073709551615"));
}

const seed_argv_plain = fuzzcorpus.entry("512");
const seed_argv_suffixed = fuzzcorpus.entry("16M");
const seed_argv_spaced_unit = fuzzcorpus.entry("3 MB");
const seed_argv_lower_suffix = fuzzcorpus.entry("4kb");
const seed_argv_trailing_b = fuzzcorpus.entry("12 B");
const seed_argv_trailing_garbage = fuzzcorpus.entry("16Mi");
const seed_argv_two_tokens = fuzzcorpus.entry("1KB2");
const seed_argv_leading_space = fuzzcorpus.entry(" 16");
const seed_argv_word = fuzzcorpus.entry("abc");
const seed_argv_empty = fuzzcorpus.entry("");
const seed_argv_digit_run_overflow = fuzzcorpus.entry("99999999999999999999999");
const seed_argv_max_u64 = fuzzcorpus.entry("18446744073709551615");
const seed_argv_suffix_mul_overflow = fuzzcorpus.entry("18446744073709551615G");
const seed_argv_host_port = fuzzcorpus.entry("192.168.0.100:18080");
const seed_argv_host_only = fuzzcorpus.entry("spark9.example");
const seed_argv_colon_only = fuzzcorpus.entry(":18081");
const seed_argv_trailing_colon = fuzzcorpus.entry("spark1:");
const seed_argv_port_zero = fuzzcorpus.entry("10.0.0.9:0");
const seed_argv_port_max = fuzzcorpus.entry("10.0.0.9:65535");
const seed_argv_port_overflow = fuzzcorpus.entry("10.0.0.9:65536");
const seed_argv_double_colon = fuzzcorpus.entry("a:b:19090");
const seed_argv_pct_low = fuzzcorpus.entry("50");
const seed_argv_pct_edge = fuzzcorpus.entry("100");
const seed_argv_pct_over = fuzzcorpus.entry("101");
const seed_argv_pct_negative = fuzzcorpus.entry("-1");
const seed_argv_pct_overflow = fuzzcorpus.entry("99999999999999999999");

const fuzz_argv_corpus = [_][]const u8{
    &seed_argv_plain,
    &seed_argv_suffixed,
    &seed_argv_spaced_unit,
    &seed_argv_lower_suffix,
    &seed_argv_trailing_b,
    &seed_argv_trailing_garbage,
    &seed_argv_two_tokens,
    &seed_argv_leading_space,
    &seed_argv_word,
    &seed_argv_empty,
    &seed_argv_digit_run_overflow,
    &seed_argv_max_u64,
    &seed_argv_suffix_mul_overflow,
    &seed_argv_host_port,
    &seed_argv_host_only,
    &seed_argv_colon_only,
    &seed_argv_trailing_colon,
    &seed_argv_port_zero,
    &seed_argv_port_max,
    &seed_argv_port_overflow,
    &seed_argv_double_colon,
    &seed_argv_pct_low,
    &seed_argv_pct_edge,
    &seed_argv_pct_over,
    &seed_argv_pct_negative,
    &seed_argv_pct_overflow,
};

/// Independent restatement of parseSize's published contract ("plain byte
/// counts or one 1024-based K/M/G suffix; anything else is trailing
/// garbage"), using std.fmt.parseInt's overflow machinery instead of the
/// hand-rolled mul/add ladder so a corrupted ladder cannot self-confirm.
fn refParseSize(s: []const u8) ?u64 {
    var i: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    if (i == 0) return null;
    const n = std.fmt.parseInt(u64, s[0..i], 10) catch return null;
    var rest = std.mem.trim(u8, s[i..], " \t");
    if (rest.len > 0 and (rest[rest.len - 1] == 'B' or rest[rest.len - 1] == 'b')) rest = rest[0 .. rest.len - 1];
    if (rest.len == 0) return n;
    if (rest.len != 1) return null;
    const mul: u64 = switch (rest[0]) {
        'K', 'k' => 1024,
        'M', 'm' => 1024 * 1024,
        'G', 'g' => 1024 * 1024 * 1024,
        else => return null,
    };
    return std.math.mul(u64, n, mul) catch null;
}

/// The flag-value parsers are the CLI's untrusted-input boundary: every
/// --piece/--seed/--listen/watermark value is operator or script text that
/// must fail loudly rather than panic, wrap, or silently mean something
/// else. Unit tests pin the documented shapes; this harness walks the whole
/// input space asserting each parser against an independent restatement,
/// the canonical-form reparse (overflow refuses, never wraps into a small
/// accepted size), and the port agreement between --seed and --listen on
/// HOST:PORT specs.
fn fuzzFlagValuesOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [64]u8 = undefined;
    const s = buf[0..smith.slice(&buf)];

    const size: ?u64 = parseSize(s) catch null;
    try std.testing.expectEqual(refParseSize(s), size);
    if (size) |n| {
        var canon_buf: [24]u8 = undefined;
        const canon = try std.fmt.bufPrint(&canon_buf, "{d}", .{n});
        try std.testing.expectEqual(n, try parseSize(canon));
    }

    // Watermark gate: an unsigned integer 0..100, nothing else.
    const pct_raw: ?u32 = std.fmt.parseInt(u32, s, 10) catch null;
    const want_pct: ?u32 = if (pct_raw) |p| (if (p <= 100) p else null) else null;
    const pct: ?u32 = parsePercent("--brun", s) catch null;
    try std.testing.expectEqual(want_pct, pct);

    // --seed consumes HOST[:PORT]; --listen consumes [IP:]PORT. On any spec
    // both accept as a HOST:PORT form, they must name the same explicit
    // port; on a bare host --seed defaults while --listen only takes a bare
    // numeric port.
    const hp: ?proto.LeaseAddr = parseHostPort(s) catch null;
    const lp: ?u16 = listenPort(s) catch null;
    if (hp) |a| {
        try std.testing.expectEqual(@as(u32, 0), a.mbps);
        if (std.mem.findScalarLast(u8, s, ':')) |ci| {
            try std.testing.expect(ci > 0);
            try std.testing.expectEqual(@as(?u16, a.port), lp);
        } else {
            try std.testing.expectEqualStrings(s, a.ip);
            try std.testing.expectEqual(@as(u16, proto.default_port), a.port);
            // Bare numeric "0" is a --seed host (defaults to 18080) but not
            // a --listen port (port 0 is refused).
            const parsed_port: ?u16 = std.fmt.parseInt(u16, s, 10) catch null;
            const want_lp: ?u16 = if (parsed_port) |p| (if (p == 0) null else p) else null;
            try std.testing.expectEqual(want_lp, lp);
        }
    }
}

test "fuzz cli flag value parsers fail loudly without wrapping or panicking" {
    try std.testing.fuzz({}, fuzzFlagValuesOne, .{ .corpus = &fuzz_argv_corpus });
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

test "pathsOverlap matches equality and whole-component containment" {
    try std.testing.expect(pathsOverlap("/m", "/m"));
    try std.testing.expect(pathsOverlap("/m/sub/x", "/m"));
    try std.testing.expect(pathsOverlap("/m", "/m/sub/x"));
    // The root contains everything: mounting with origin "/" would shadow
    // the whole filesystem.
    try std.testing.expect(pathsOverlap("/x", "/"));
    // Cache under origin would publish piece files through the shared store.
    try std.testing.expect(pathsOverlap("/net/nas/models", "/net/nas/models/cache"));
    try std.testing.expect(pathsOverlap("/var/cache/modelfs", "/var/cache/modelfs"));
    // A bare string prefix is not containment: /models2 is a sibling of
    // /models, and refusing it would break legitimate layouts.
    try std.testing.expect(!pathsOverlap("/models2/c", "/models"));
    try std.testing.expect(!pathsOverlap("/models", "/models2/c"));
    try std.testing.expect(!pathsOverlap("/a/b", "/a/bc"));
    try std.testing.expect(!pathsOverlap("/other", "/m"));
}

test "parseArgs refuses unknown MODELFS_ variables as typos" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    // A misspelled knob must fail loudly instead of silently dropping the
    // operator's setting, on every command that reads configuration.
    try environ.put("MODELFS_CACHEE", "/intended/cache");
    try std.testing.expectError(error.UnknownEnv, parseArgs(gpa, &environ, &.{ "mount", "--origin", "/o" }));
    try std.testing.expectError(error.UnknownEnv, parseArgs(gpa, &environ, &.{"status"}));
    // Variables outside the MODELFS_ namespace are never this CLI's
    // business and stay untouched; documented variables keep applying.
    _ = environ.orderedRemove("MODELFS_CACHEE");
    try environ.put("PATH", "/usr/bin");
    try environ.put("MODELFS_CACHE", "/env/cache");
    {
        const parsed = try parseArgs(gpa, &environ, &.{ "mount", "--origin", "/o" });
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("/env/cache", parsed.opts.cache);
    }
}

test "unknownEnvLine renders refused names through the displayName echo gate" {
    // An unknown MODELFS_ variable arrives from whatever composed this
    // process's environment (systemd unit, CI wrapper, remote shell), so the
    // refusal must never echo the raw name: ESC (OSC title escape) or CR/LF
    // (forged follow-up lines) would inject into the operator's terminal,
    // exactly the exposure badIdLine's gate closes for MODELFS_ID.
    var buf: [512]u8 = undefined;
    {
        const line = unknownEnvLine(&buf, "MODELFS_\x1b]0;pwned\x07");
        try std.testing.expect(std.mem.indexOf(u8, line, "\x1b") == null);
        try std.testing.expect(std.mem.indexOf(u8, line, "<name withheld: control bytes>") != null);
    }
    // The UTF-8 C1 spellings get the same withholding as their raw C0
    // counterparts.
    {
        const line = unknownEnvLine(&buf, "MODELFS_\xc2\x9d0;pwned\xc2\x9c");
        try std.testing.expect(std.mem.indexOf(u8, line, "\xc2\x9d") == null);
        try std.testing.expect(std.mem.indexOf(u8, line, "<name withheld: control bytes>") != null);
    }
    {
        const line = unknownEnvLine(&buf, "MODELFS_\u{2028}ERROR");
        try std.testing.expect(std.mem.indexOf(u8, line, "\u{2028}") == null);
        try std.testing.expect(std.mem.indexOf(u8, line, "<name withheld: control bytes>") != null);
    }
    // A printable misspelling still names itself verbatim, so the operator
    // sees which variable was refused.
    {
        const line = unknownEnvLine(&buf, "MODELFS_CACHEE");
        try std.testing.expect(std.mem.indexOf(u8, line, "unknown environment variable MODELFS_CACHEE") != null);
    }
    // A name that cannot fit the staging buffer degrades to the generic
    // line: the refusal stays unconditional either way.
    const long = unknownEnvLine(buf[0..64], "MODELFS_" ** 20);
    try std.testing.expectEqualStrings("unknown environment variable (see 'modelfs help')\n", long);
}

test "cmdStatus retires a crashed daemon's status.json as not running" {
    const gpa = std.testing.allocator;
    var cb: [128]u8 = undefined;
    const cache_d = try sys.scratchDir(&cb, "modelfs-status-stale");
    defer sys.deleteTree(std.testing.io, cache_d);

    var zbuf: [192]u8 = undefined;
    var pbuf: [160]u8 = undefined;
    const fp = try std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ cache_d, store_mod.status_file });

    // A live writer's document is served verbatim with success.
    var live_buf: [160]u8 = undefined;
    const live_doc = try std.fmt.bufPrint(&live_buf, "{{\"id\":\"me\",\"pid\":{d},\"uptime_s\":1,\"peers\":0,\"piece\":16,\"inflight\":0,\"stats\":{{}}}}\n", .{std.os.linux.getpid()});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), live_doc));
    // The live pid must read as running (exit 0) and the document must
    // reach stdout unchanged; the stale-document cases below pin exit 1.
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        captured_stdout = &out;
        defer captured_stdout = null;
        try std.testing.expectEqual(@as(u8, 0), try cmdStatus(std.testing.io, gpa, .{ .cache = cache_d }));
        try std.testing.expectEqualStrings(live_doc, out.items);
    }

    // The same path after the daemon died without cleanup (crash, kill -9):
    // the leftover names an exited pid and must read as not running, exit 1,
    // like the absent-artifact case -- not as a live node with frozen stats.
    var dead_buf: [96]u8 = undefined;
    const dead_doc = try std.fmt.bufPrint(&dead_buf, "{{\"id\":\"me\",\"pid\":-3,\"uptime_s\":99}}\n", .{});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), dead_doc));
    try std.testing.expectEqual(@as(u8, 1), try cmdStatus(std.testing.io, gpa, .{ .cache = cache_d }));

    // A live writer whose artifact has stopped ticking is the wedged daemon:
    // pid alive, discovery tick hung. Past the freshness window the document
    // must read as not serving (exit 1) instead of reporting frozen stats as
    // a healthy node; inside the window it still serves. now_s-only artifacts
    // are the older-build fallback.
    {
        var old_buf: [128]u8 = undefined;
        const old_doc = try std.fmt.bufPrint(&old_buf, "{{\"id\":\"me\",\"pid\":{d},\"now_s\":{d}}}\n", .{ std.os.linux.getpid(), sys.nowSec(std.testing.io) - 121 });
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), old_doc));
        try std.testing.expectEqual(@as(u8, 1), try cmdStatus(std.testing.io, gpa, .{ .cache = cache_d }));

        var fresh_buf: [128]u8 = undefined;
        const fresh_doc = try std.fmt.bufPrint(&fresh_buf, "{{\"id\":\"me\",\"pid\":{d},\"now_s\":{d}}}\n", .{ std.os.linux.getpid(), sys.nowSec(std.testing.io) });
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), fresh_doc));
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        captured_stdout = &out;
        defer captured_stdout = null;
        try std.testing.expectEqual(@as(u8, 0), try cmdStatus(std.testing.io, gpa, .{ .cache = cache_d }));
        try std.testing.expectEqualStrings(fresh_doc, out.items);
    }

    // NTP step / admin clock set: wall time and monotonic disagree. Prefer
    // mono_s so a forward jump does not retire a ticking daemon and a
    // backward jump does not keep a wedged one looking live.
    {
        var ntp_ok_buf: [192]u8 = undefined;
        const ntp_ok = try std.fmt.bufPrint(&ntp_ok_buf, "{{\"id\":\"me\",\"pid\":{d},\"now_s\":{d},\"mono_s\":{d}}}\n", .{
            std.os.linux.getpid(),
            sys.nowSec(std.testing.io) - 121,
            sys.monoSec(std.testing.io),
        });
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), ntp_ok));
        try std.testing.expectEqual(@as(u8, 0), try cmdStatus(std.testing.io, gpa, .{ .cache = cache_d }));

        var ntp_dead_buf: [192]u8 = undefined;
        const ntp_dead = try std.fmt.bufPrint(&ntp_dead_buf, "{{\"id\":\"me\",\"pid\":{d},\"now_s\":{d},\"mono_s\":{d}}}\n", .{
            std.os.linux.getpid(),
            sys.nowSec(std.testing.io),
            sys.monoSec(std.testing.io) - 121,
        });
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), ntp_dead));
        try std.testing.expectEqual(@as(u8, 1), try cmdStatus(std.testing.io, gpa, .{ .cache = cache_d }));
    }

    // A hostile/corrupt now_s of i64 min used to overflow the age subtract
    // (panic in safe builds). Saturating treat it as stale, not live.
    {
        var min_buf: [128]u8 = undefined;
        const min_doc = try std.fmt.bufPrint(&min_buf, "{{\"id\":\"me\",\"pid\":{d},\"now_s\":{d}}}\n", .{ std.os.linux.getpid(), std.math.minInt(i64) });
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), min_doc));
        try std.testing.expectEqual(@as(u8, 1), try cmdStatus(std.testing.io, gpa, .{ .cache = cache_d }));
    }

    // An unparseable leftover gets the same verdict as an absent one.
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), "not json"));
    try std.testing.expectEqual(@as(u8, 1), try cmdStatus(std.testing.io, gpa, .{ .cache = cache_d }));

    // A status.json that exists but cannot be opened at all (self-referential
    // symlink: ELOOP even under root) is neither running nor plainly absent:
    // same exit-1 verdict, through the cannot-read branch rather than the
    // absent one, so a live daemon whose artifact this user cannot read is
    // not misdiagnosed as "no status.json".
    {
        var sbuf: [192]u8 = undefined;
        try std.testing.expectEqual(@as(i32, 0), sys.c.unlink(try sys.toZ(&zbuf, fp)));
        try std.testing.expectEqual(@as(i32, 0), sys.c.symlink(try sys.toZ(&zbuf, fp), try sys.toZ(&sbuf, fp)));
        try std.testing.expectEqual(@as(u8, 1), try cmdStatus(std.testing.io, gpa, .{ .cache = cache_d }));
    }
}

test "pathIsDir separates directories from files and absent paths" {
    var cb: [128]u8 = undefined;
    const d = try sys.scratchDir(&cb, "modelfs-isdir");
    defer sys.deleteTree(std.testing.io, d);

    var zb: [256]u8 = undefined;
    try std.testing.expect(pathIsDir(try sys.toZ(&zb, d)));
    // The --origin gate exists for exactly this case: a regular file passes
    // realpath ("reachable") but must never read as an origin.
    var fb: [160]u8 = undefined;
    const fp = try std.fmt.bufPrint(&fb, "{s}/regular", .{d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zb, fp), "x"));
    try std.testing.expect(!pathIsDir(try sys.toZ(&zb, fp)));
    var ab: [160]u8 = undefined;
    const ap = try std.fmt.bufPrint(&ab, "{s}/absent", .{d});
    try std.testing.expect(!pathIsDir(try sys.toZ(&zb, ap)));
}

test "cmdPeers separates unreachable origins from empty clusters" {
    const gpa = std.testing.allocator;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&cb, "modelfs-peers-empty");
    defer sys.deleteTree(std.testing.io, origin_d);

    // An existing origin with no .cluster dir yet is a fresh cluster:
    // listing succeeds and names the missing dir, never a fabricated peer.
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        captured_stdout = &out;
        defer captured_stdout = null;
        try std.testing.expectEqual(@as(u8, 0), try cmdPeers(std.testing.io, gpa, .{ .origin = origin_d }));
        try std.testing.expect(std.mem.indexOf(u8, out.items, "no cluster leases") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, discover.cluster_dir) != null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "spark") == null);
    }

    // A typo'd/unreachable path must not read as "no leases": same exit-1
    // verdict mount gives an unreachable --origin.
    var nb: [160]u8 = undefined;
    const absent = try std.fmt.bufPrint(&nb, "{s}/does-not-exist", .{origin_d});
    try std.testing.expectEqual(@as(u8, 1), try cmdPeers(std.testing.io, gpa, .{ .origin = absent }));

    // A regular file at --origin is the same verdict: reachable but unable
    // to hold .cluster leases, so it must fail loudly instead of listing as
    // a healthy empty cluster.
    var wb: [256]u8 = undefined;
    var fb: [160]u8 = undefined;
    const file_origin = try std.fmt.bufPrint(&fb, "{s}/regular", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&wb, file_origin), "x"));
    try std.testing.expectEqual(@as(u8, 1), try cmdPeers(std.testing.io, gpa, .{ .origin = file_origin }));
}

test "cmdPeers skips an unleasable lease entry instead of failing the listing" {
    const gpa = std.testing.allocator;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&cb, "modelfs-peers-poison");
    defer sys.deleteTree(std.testing.io, origin_d);
    var cbuf: [160]u8 = undefined;
    const cluster_d = try std.fmt.bufPrint(&cbuf, "{s}/.cluster", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(cluster_d, 0o755));

    // One poisoned name (self-referential symlink: open fails ELOOP even
    // under root) beside one healthy lease. The listing must degrade to a
    // skipped row -- named by the cannot-open warning -- never abort or hide
    // spark9 behind the one broken entry.
    var zbuf: [192]u8 = undefined;
    var sbuf: [192]u8 = undefined;
    var pbuf: [192]u8 = undefined;
    const poison_fp = try std.fmt.bufPrint(&pbuf, "{s}/poison.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.c.symlink(try sys.toZ(&zbuf, poison_fp), try sys.toZ(&sbuf, poison_fp)));
    const live_fp = try std.fmt.bufPrint(&pbuf, "{s}/spark9.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, live_fp), "{\"id\":\"spark9\",\"until\":4102444800,\"addrs\":[]}"));
    // Expired leases stay in the listing, marked, so an operator can tell
    // a dead node from a missing one. Sorted by filename, this row leads.
    const old_fp = try std.fmt.bufPrint(&pbuf, "{s}/old.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, old_fp), "{\"id\":\"old\",\"until\":1,\"addrs\":[]}"));

    // Expected-path warning from the cannot-open branch; keep it off the
    // runner's stderr like sibling fault-tolerance tests.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    captured_stdout = &out;
    defer captured_stdout = null;
    try std.testing.expectEqual(@as(u8, 0), try cmdPeers(std.testing.io, gpa, .{ .origin = origin_d }));
    try std.testing.expectEqualStrings("old (until=1, expired)\nspark9 (until=4102444800, live)\n", out.items);
}

test "cmdPin pins through the /models prefix, refuses escapes, and unpins" {
    const gpa = std.testing.allocator;
    var cb: [128]u8 = undefined;
    const cache_d = try sys.scratchDir(&cb, "modelfs-pin");
    defer sys.deleteTree(std.testing.io, cache_d);

    var zb: [192]u8 = undefined;
    var pbuf: [192]u8 = undefined;
    var stbuf: sys.c.struct_stat = undefined;

    // The mount-root prefix and any leading slash are stripped; the pin
    // artifact lands at cache/pin/<rel>, exactly where punchPiece and
    // reapIdle consult it. This roundtrip is what makes an operator's pin
    // actually protect a file from culling.
    try std.testing.expectEqual(@as(u8, 0), try cmdPin(std.testing.io, gpa, .{ .cache = cache_d }, "/models/gguf/big.gguf", true));
    const pin_fp = try std.fmt.bufPrint(&pbuf, "{s}/pin/gguf/big.gguf", .{cache_d});
    try std.testing.expect(sys.statPath(try sys.toZ(&zb, pin_fp), &stbuf) == 0);

    // A ".." component would write outside cache/pin: refused with exit 1,
    // and nothing may be written for the escaped name.
    try std.testing.expectEqual(@as(u8, 1), try cmdPin(std.testing.io, gpa, .{ .cache = cache_d }, "../escape.bin", true));
    const escape_fp = try std.fmt.bufPrint(&pbuf, "{s}/pin/escape.bin", .{cache_d});
    try std.testing.expect(sys.statPath(try sys.toZ(&zb, escape_fp), &stbuf) != 0);

    // `/models/` is the mount-root prefix strip, not a pinable path: empty
    // after the convenience strip, same exit-1 refusal as an escape.
    try std.testing.expectEqual(@as(u8, 1), try cmdPin(std.testing.io, gpa, .{ .cache = cache_d }, "/models/", true));

    // A refused path must not create cache layout.
    {
        var nb: [128]u8 = undefined;
        const cache2 = try sys.scratchDir(&nb, "modelfs-pin-refuse");
        defer sys.deleteTree(std.testing.io, cache2);
        try std.testing.expectEqual(@as(u8, 1), try cmdPin(std.testing.io, gpa, .{ .cache = cache2 }, "../escape.bin", true));
        const pin_dir = try std.fmt.bufPrint(&pbuf, "{s}/pin", .{cache2});
        try std.testing.expect(sys.statPath(try sys.toZ(&zb, pin_dir), &stbuf) != 0);
    }

    // Unpin removes the artifact so the file becomes cullable again.
    try std.testing.expectEqual(@as(u8, 0), try cmdPin(std.testing.io, gpa, .{ .cache = cache_d }, "gguf/big.gguf", false));
    try std.testing.expect(sys.statPath(try sys.toZ(&zb, pin_fp), &stbuf) != 0);
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
        "mount",    "/mnt/models",      "--origin", "/srv/origin",     "--piece", "4M",
        "--psk",    "/etc/modelfs.psk", "--listen", "127.0.0.1:19090", "--seed",  "10.0.0.9:19099",
        "--brun",   "12",               "--bcull",  "6",               "--bstop", "2",
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
    // --listen is fully parsed at the flag boundary; only the port survives
    try std.testing.expectEqual(@as(u16, 19090), parsed.opts.listen_port.?);
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
    // --listen is validated at the flag like its sibling value flags: a bare
    // word or empty spec names no port and must not silently mount on 18080
    // (regression: both were accepted-and-defaulted, exiting 1 only after the
    // origin/cache/mountpoint had already been created)
    try std.testing.expectError(error.BadListen, parseArgs(gpa, &environ, &.{ "mount", "--listen", "spark1" }));
    try std.testing.expectError(error.BadListen, parseArgs(gpa, &environ, &.{ "mount", "--listen", "" }));
    try std.testing.expectError(error.BadListen, parseArgs(gpa, &environ, &.{ "mount", "--listen", "abc:def" }));
    try std.testing.expectError(error.BadListen, parseArgs(gpa, &environ, &.{ "mount", "--listen", "70000" }));
    try std.testing.expectError(error.BadListen, parseArgs(gpa, &environ, &.{ "mount", "--listen", "0" }));
    try std.testing.expectError(error.BadListen, parseArgs(gpa, &environ, &.{ "mount", "--listen", "127.0.0.1:0" }));
    try std.testing.expectError(error.BadHostPort, parseArgs(gpa, &environ, &.{ "mount", "--advertise", "10.0.0.1:0" }));
    try std.testing.expectError(error.BadHostPort, parseArgs(gpa, &environ, &.{ "mount", "--seed", "10.0.0.9:0" }));
    // Empty path flags name no configuration: fail at parse, not later as
    // "not reachable" / missing PSK with no mention of the flag.
    try std.testing.expectError(error.MissingValue, parseArgs(gpa, &environ, &.{ "mount", "--origin", "" }));
    try std.testing.expectError(error.MissingValue, parseArgs(gpa, &environ, &.{ "mount", "--cache", "" }));
    try std.testing.expectError(error.MissingValue, parseArgs(gpa, &environ, &.{ "status", "--psk", "" }));
    try std.testing.expectError(error.MissingValue, parseArgs(gpa, &environ, &.{ "mount", "--origin=" }));
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
    // Boundary percentages are accepted when the set stays ordered.
    try std.testing.expectEqual(@as(u32, 100), blk: {
        const parsed = try parseArgs(gpa, &environ, &.{ "mount", "--brun", "100", "--bcull", "99", "--bstop", "0" });
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqual(@as(u32, 99), parsed.opts.water.bcull);
        break :blk parsed.opts.water.brun;
    });
    // Only strict ordering gives phase() hysteresis: bstop >= bcull pins .stop
    // (hard-culling toward bstop% used no matter how empty the disk), and
    // brun <= bcull flaps run/cull every tick across [brun, bcull].
    try std.testing.expectError(error.BadWatermarks, parseArgs(gpa, &environ, &.{ "mount", "--brun", "5", "--bcull", "10" }));
    try std.testing.expectError(error.BadWatermarks, parseArgs(gpa, &environ, &.{ "mount", "--brun", "7", "--bcull", "7" }));
    try std.testing.expectError(error.BadWatermarks, parseArgs(gpa, &environ, &.{ "mount", "--brun", "90", "--bcull", "70", "--bstop", "80" }));
    // An id that cannot ride in the lease file name or JSON document would
    // make every peer's parser refuse this node's lease (or skip it as a
    // dot file): rejected at the flag boundary like --advertise's quads.
    try std.testing.expectError(error.BadId, parseArgs(gpa, &environ, &.{ "mount", "--id", "a\"b" }));
    try std.testing.expectError(error.BadId, parseArgs(gpa, &environ, &.{ "mount", "--id", "a\\b" }));
    try std.testing.expectError(error.BadId, parseArgs(gpa, &environ, &.{ "mount", "--id", "a/b" }));
    try std.testing.expectError(error.BadId, parseArgs(gpa, &environ, &.{ "mount", "--id", ".lead" }));
    try std.testing.expectError(error.BadId, parseArgs(gpa, &environ, &.{ "mount", "--id", "a\nb" }));
    // An empty id would collide every such node onto one lease, but from the
    // environment it reads as unset (hostname fallback) instead of bricking
    // mounts until the stray variable is unset; only the explicit flag is
    // refused. Kept last because the env put below taints every later parse.
    try std.testing.expectError(error.BadId, parseArgs(gpa, &environ, &.{ "mount", "--id", "" }));
    try environ.put("MODELFS_ID", "");
    {
        const parsed = try parseArgs(gpa, &environ, &.{"mount"});
        defer freeParsed(parsed, gpa);
        try std.testing.expect(parsed.opts.id == null);
    }
    // A non-empty env id answers to the same gate.
    try environ.put("MODELFS_ID", "x\"y");
    try std.testing.expectError(error.BadId, parseArgs(gpa, &environ, &.{"mount"}));
}

test "empty environment variables read as unset" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    // A leftover "export MODELFS_X=" must not replace defaults with unusable
    // values: every variable falls back to its default exactly as if it had
    // never been set.
    try environ.put("MODELFS_ORIGIN", "");
    try environ.put("MODELFS_CACHE", "");
    try environ.put("MODELFS_PSK", "");
    try environ.put("MODELFS_PSK_VALUE", "");
    try environ.put("MODELFS_ID", "");
    try environ.put("MODELFS_LOG", "");
    const parsed = try parseArgs(gpa, &environ, &.{"mount"});
    defer freeParsed(parsed, gpa);
    try std.testing.expect(parsed.opts.origin == null);
    try std.testing.expectEqualStrings("/var/cache/modelfs", parsed.opts.cache);
    try std.testing.expectEqualStrings("/etc/modelfs.psk", parsed.opts.psk_file);
    try std.testing.expect(parsed.opts.psk_value == null);
    try std.testing.expect(parsed.opts.id == null);

    // Non-empty values still apply, and an explicitly empty flag keeps its
    // stricter meaning where one exists (--id "" is refused by the BadId
    // gate above). The two PSK sources are exclusive on mount, so the
    // file form and the inline form are applied in separate parses.
    try environ.put("MODELFS_ORIGIN", "/env/origin");
    try environ.put("MODELFS_CACHE", "/env/cache");
    try environ.put("MODELFS_PSK", "/env/psk");
    try environ.put("MODELFS_ID", "spark-env");
    {
        const parsed2 = try parseArgs(gpa, &environ, &.{"mount"});
        defer freeParsed(parsed2, gpa);
        try std.testing.expectEqualStrings("/env/origin", parsed2.opts.origin.?);
        try std.testing.expectEqualStrings("/env/cache", parsed2.opts.cache);
        try std.testing.expectEqualStrings("/env/psk", parsed2.opts.psk_file);
        try std.testing.expect(parsed2.opts.psk_value == null);
        try std.testing.expectEqualStrings("spark-env", parsed2.opts.id.?);
    }
    _ = environ.orderedRemove("MODELFS_PSK");
    try environ.put("MODELFS_PSK_VALUE", "env-secret");
    {
        const parsed3 = try parseArgs(gpa, &environ, &.{"mount"});
        defer freeParsed(parsed3, gpa);
        try std.testing.expectEqualStrings("env-secret", parsed3.opts.psk_value.?);
        try std.testing.expectEqualStrings("/etc/modelfs.psk", parsed3.opts.psk_file);
    }
}

test "parseLogLevel accepts the documented names only" {
    try std.testing.expectEqual(std.log.Level.err, parseLogLevel("err").?);
    try std.testing.expectEqual(std.log.Level.warn, parseLogLevel("warn").?);
    try std.testing.expectEqual(std.log.Level.info, parseLogLevel("info").?);
    try std.testing.expectEqual(std.log.Level.debug, parseLogLevel("debug").?);
    // Near-misses must refuse rather than silently keep the default
    // ceiling: the operator asked for a verbosity change and would never
    // learn it did not happen.
    try std.testing.expect(parseLogLevel("Info") == null);
    try std.testing.expect(parseLogLevel("warning") == null);
    try std.testing.expect(parseLogLevel("verbose") == null);
    try std.testing.expect(parseLogLevel("") == null);
}

test "parseArgs refuses an unknown MODELFS_LOG value on every command" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("MODELFS_LOG", "verbose");
    try std.testing.expectError(error.BadLogLevel, parseArgs(gpa, &environ, &.{ "mount", "--origin", "/o" }));
    try std.testing.expectError(error.BadLogLevel, parseArgs(gpa, &environ, &.{"status"}));
    try std.testing.expectError(error.BadLogLevel, parseArgs(gpa, &environ, &.{"peers"}));
    // A documented value is accepted on the non-mount commands too: the log
    // ceiling is shared configuration, not a mount-only knob.
    _ = environ.orderedRemove("MODELFS_LOG");
    try environ.put("MODELFS_LOG", "err");
    const parsed = try parseArgs(gpa, &environ, &.{"status"});
    defer freeParsed(parsed, gpa);
}

test "parseArgs refuses unknown commands before flag scanning" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try std.testing.expectError(error.UnknownCommand, parseArgs(gpa, &environ, &.{"frobnicate"}));
    // A trailing -h must not turn a typo'd command into a successful help
    // request (regression: it printed the usage and exited 0).
    try std.testing.expectError(error.UnknownCommand, parseArgs(gpa, &environ, &.{ "frobnicate", "-h", "--origin", "/o" }));
}

test "parseArgs rejects mount-only flags on other commands" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    // The help text promises status/peers/pin/unpin take only their Usage-line
    // flags; mount-only knobs must be refused, not accepted-and-ignored.
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "status", "--detach" }));
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "status", "--kernel-cache" }));
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "peers", "--origin", "/o", "--piece", "4M" }));
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "peers", "--id", "spark9" }));
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "pin", "x.bin", "--listen", "19090" }));
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "unpin", "x.bin", "-f" }));
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "peers", "--seed", "10.0.0.9" }));
    // Shared value flags stay legal on every command (the e2e suites pass
    // --psk/--origin to pin and peers).
    {
        const parsed = try parseArgs(gpa, &environ, &.{ "pin", "x.bin", "--cache", "/c", "--origin", "/o", "--psk", "/p" });
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("/c", parsed.opts.cache);
    }
}

test "classifyMeta answers help/version and refuses real extras" {
    try std.testing.expectEqual(.help, classifyMeta(&.{"help"}));
    try std.testing.expectEqual(.help, classifyMeta(&.{"--help"}));
    try std.testing.expectEqual(.help, classifyMeta(&.{"-h"}));
    try std.testing.expectEqual(.version, classifyMeta(&.{"version"}));
    try std.testing.expectEqual(.version, classifyMeta(&.{"--version"}));
    try std.testing.expectEqual(.version, classifyMeta(&.{"-V"}));
    // Documented "every command also accepts -h/--help": version --help is
    // help, not a positional error. Help wins when both globals appear.
    try std.testing.expectEqual(.help, classifyMeta(&.{ "version", "--help" }));
    try std.testing.expectEqual(.help, classifyMeta(&.{ "version", "-h" }));
    try std.testing.expectEqual(.help, classifyMeta(&.{ "help", "--version" }));
    try std.testing.expectEqual(.version, classifyMeta(&.{ "version", "-V" }));
    try std.testing.expectEqual(.bad, classifyMeta(&.{ "help", "junk" }));
    try std.testing.expectEqual(.bad, classifyMeta(&.{ "version", "junk" }));
    try std.testing.expectEqual(.none, classifyMeta(&.{"mount"}));
    try std.testing.expectEqual(.none, classifyMeta(&.{}));
}

test "splitFlag splits --name=VALUE and leaves short flags whole" {
    {
        const s = splitFlag("--origin=/nas/models");
        try std.testing.expectEqualStrings("--origin", s.name);
        try std.testing.expectEqualStrings("/nas/models", s.value.?);
    }
    {
        const s = splitFlag("--origin");
        try std.testing.expectEqualStrings("--origin", s.name);
        try std.testing.expect(s.value == null);
    }
    {
        const s = splitFlag("--origin=");
        try std.testing.expectEqualStrings("--origin", s.name);
        try std.testing.expectEqualStrings("", s.value.?);
    }
    // Short flags have no attached-value form; `-f=x` is one unknown token.
    {
        const s = splitFlag("-f=x");
        try std.testing.expectEqualStrings("-f=x", s.name);
        try std.testing.expect(s.value == null);
    }
    {
        const s = splitFlag("-h");
        try std.testing.expectEqualStrings("-h", s.name);
        try std.testing.expect(s.value == null);
    }
}

test "parseArgs accepts --name=VALUE and refuses it on boolean flags" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    {
        const parsed = try parseArgs(gpa, &environ, &.{
            "mount",          "/mnt/models", "--origin=/srv/origin", "--piece=4M",
            "--listen=19090", "--brun=12",   "--bcull=6",            "--bstop=2",
        });
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("/mnt/models", parsed.rest[0]);
        try std.testing.expectEqualStrings("/srv/origin", parsed.opts.origin.?);
        try std.testing.expectEqual(@as(u32, 4 * 1024 * 1024), parsed.opts.piece);
        try std.testing.expectEqual(@as(u16, 19090), parsed.opts.listen_port.?);
        try std.testing.expectEqual(@as(u32, 12), parsed.opts.water.brun);
        try std.testing.expectEqual(@as(u32, 6), parsed.opts.water.bcull);
        try std.testing.expectEqual(@as(u32, 2), parsed.opts.water.bstop);
    }
    // Space and attached forms mix: the attached payload is the value, so
    // the next token stays positional.
    {
        const parsed = try parseArgs(gpa, &environ, &.{ "pin", "--cache=/c", "x.bin" });
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("/c", parsed.opts.cache);
        try std.testing.expectEqualStrings("x.bin", parsed.rest[0]);
    }
    try std.testing.expectError(error.UnexpectedValue, parseArgs(gpa, &environ, &.{ "mount", "--detach=true" }));
    try std.testing.expectError(error.UnexpectedValue, parseArgs(gpa, &environ, &.{ "mount", "--help=foo" }));
    try std.testing.expectError(error.UnexpectedValue, parseArgs(gpa, &environ, &.{ "mount", "--foreground=1" }));
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "status", "--kernel-cache=off" }));
}

test "parseArgs trims whitespace in --advertise lists" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    const parsed = try parseArgs(gpa, &environ, &.{ "mount", "--advertise", "10.0.0.1, 10.0.0.2:19091" });
    defer freeParsed(parsed, gpa);
    try std.testing.expectEqual(@as(usize, 2), parsed.opts.advertise.items.len);
    try std.testing.expectEqualStrings("10.0.0.1", parsed.opts.advertise.items[0].ip);
    try std.testing.expectEqual(@as(u16, proto.default_port), parsed.opts.advertise.items[0].port);
    try std.testing.expectEqualStrings("10.0.0.2", parsed.opts.advertise.items[1].ip);
    try std.testing.expectEqual(@as(u16, 19091), parsed.opts.advertise.items[1].port);
}

test "parseArgs treats everything after -- as positional" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    // A relpath starting with '-' would otherwise die as an unknown flag;
    // "--" hands it through verbatim.
    {
        const parsed = try parseArgs(gpa, &environ, &.{ "pin", "--", "-weird.gguf" });
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqual(@as(usize, 1), parsed.rest.len);
        try std.testing.expectEqualStrings("-weird.gguf", parsed.rest[0]);
    }
    // -h after -- is a positional, not a help request.
    {
        const parsed = try parseArgs(gpa, &environ, &.{ "mount", "--", "-h", "/mnt" });
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqual(@as(usize, 2), parsed.rest.len);
        try std.testing.expectEqualStrings("-h", parsed.rest[0]);
        try std.testing.expectEqualStrings("/mnt", parsed.rest[1]);
    }
    // Flags before -- still parse; a bare -- changes nothing.
    {
        const parsed = try parseArgs(gpa, &environ, &.{ "pin", "--origin", "/o", "--" });
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("/o", parsed.opts.origin.?);
        try std.testing.expectEqual(@as(usize, 0), parsed.rest.len);
    }
}

test "the inline secret comes from MODELFS_PSK_VALUE and has no flag" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("MODELFS_PSK_VALUE", "env-secret");
    {
        const parsed = try parseArgs(gpa, &environ, &.{"mount"});
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("env-secret", parsed.opts.psk_value.?);
    }
    // No argv spelling exists: a secret on the command line is world-readable
    // through /proc/<pid>/cmdline, so the flag is an unknown one.
    try std.testing.expectError(
        error.UnknownFlag,
        parseArgs(gpa, &environ, &.{ "mount", "--psk-value", "flag-secret" }),
    );
    // Combined with an explicit file source on mount, loadPsk would silently
    // prefer the env secret while the operator believed --psk won.
    try std.testing.expectError(
        error.ConflictingPsk,
        parseArgs(gpa, &environ, &.{ "mount", "--psk", "/etc/modelfs.psk" }),
    );
    // status/peers/pin never load the secret; a shell-wide inline value
    // must not fail them the way the e2e suites pass --psk.
    {
        const parsed = try parseArgs(gpa, &environ, &.{ "status", "--psk", "/etc/modelfs.psk" });
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("env-secret", parsed.opts.psk_value.?);
        try std.testing.expectEqualStrings("/etc/modelfs.psk", parsed.opts.psk_file);
    }
}

test "MODELFS_PSK and MODELFS_PSK_VALUE conflict on mount" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("MODELFS_PSK", "/env/psk");
    try environ.put("MODELFS_PSK_VALUE", "env-secret");
    try std.testing.expectError(error.ConflictingPsk, parseArgs(gpa, &environ, &.{"mount"}));
    // Either source alone still applies.
    _ = environ.orderedRemove("MODELFS_PSK_VALUE");
    {
        const parsed = try parseArgs(gpa, &environ, &.{"mount"});
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("/env/psk", parsed.opts.psk_file);
        try std.testing.expect(parsed.opts.psk_value == null);
    }
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

test "env MODELFS_ID follows the --id mount-only scope" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    // Outside mount the ambient id is neither applied nor refused: status
    // never reads it, so a shell-wide MODELFS_ID must not break the command
    // (the explicit flag is rejected there by rejectOutsideMount instead).
    try environ.put("MODELFS_ID", "x\"y");
    {
        const parsed = try parseArgs(gpa, &environ, &.{"status"});
        defer freeParsed(parsed, gpa);
        try std.testing.expect(parsed.opts.id == null);
    }
    // On mount it answers to the same validation gate as the flag.
    try std.testing.expectError(error.BadId, parseArgs(gpa, &environ, &.{"mount"}));
}

test "embedded version parses as semver" {
    // build_options.version is extracted from build.zig.zon by build.zig;
    // `modelfs version` must only ever print a well-formed release string.
    _ = try std.SemanticVersion.parse(build_options.version);
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
    // The file form is capped at proto.max_psk_bytes; the inline form must
    // match or a huge env value would start the daemon and then fail the
    // peer request head.
    try std.testing.expectError(error.PskTooLarge, loadPsk(gpa, .{ .psk_value = "k" ** (proto.max_psk_bytes + 1) }));
    {
        const psk = try loadPsk(gpa, .{ .psk_value = "k" ** proto.max_psk_bytes });
        defer gpa.free(psk);
        try std.testing.expectEqual(@as(usize, proto.max_psk_bytes), psk.len);
    }

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

test "loadPsk refuses line breaks but rides every other byte header-safe" {
    const gpa = std.testing.allocator;
    var db: [128]u8 = undefined;
    const scratch = try sys.scratchDir(&db, "modelfs-psk-frame");
    defer sys.deleteTree(std.testing.io, scratch);
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    // sendRequest embeds the secret verbatim in one HTTP header line; an
    // interior CR/LF splits the head there, so both nodes' fetches 401
    // forever while reads silently fall back to NFS. Refused at load, for
    // the inline value...
    try std.testing.expectError(error.PskNotHeaderSafe, loadPsk(gpa, .{ .psk_value = "ab\rcd" }));
    try std.testing.expectError(error.PskNotHeaderSafe, loadPsk(gpa, .{ .psk_value = "ab\ncd" }));
    try std.testing.expectError(error.PskNotHeaderSafe, loadPsk(gpa, .{ .psk_value = "a\r\nb" }));
    // ...and for the file form (surrounding breaks are trim, not content).
    var zb: [192]u8 = undefined;
    {
        var pb: [160]u8 = undefined;
        const fp = try std.fmt.bufPrint(&pb, "{s}/wrapped.psk", .{scratch});
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zb, fp), "first\r\nsecond\n"));
        try std.testing.expectError(error.PskNotHeaderSafe, loadPsk(gpa, .{ .psk_file = fp }));
    }
    // Everything else survives verbatim: spaces and tabs (both sides trim
    // only the token's ends), high bytes, and multi-byte UTF-8 spellings of
    // the same secret ride the slice-based head parser byte-exact.
    {
        const psk = try loadPsk(gpa, .{ .psk_value = "ke\u{e9}y \ttw\xfeice" });
        defer gpa.free(psk);
        try std.testing.expectEqualStrings("ke\xc3\xa9y \ttw\xfeice", psk);
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
        opts.listen_port = 19091;
        try opts.advertise.append(gpa, .{ .ip = "10.0.0.1", .port = proto.default_port });
        try opts.advertise.append(gpa, .{ .ip = "10.0.0.2", .port = 19090 });
        defer opts.advertise.deinit(gpa);
        var addrs = try leaseAddrs(gpa, opts, &.{}, 19091);
        defer addrs.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 2), addrs.items.len);
        try std.testing.expectEqual(@as(u16, 19091), addrs.items[0].port);
        try std.testing.expectEqual(@as(u16, 19090), addrs.items[1].port);
    }
    // --advertise replaces auto-detect: local IPs must not also be published.
    {
        var opts = Opts{};
        try opts.advertise.append(gpa, .{ .ip = "10.0.0.9", .port = 18080 });
        defer opts.advertise.deinit(gpa);
        const local = [_][]const u8{ "192.168.1.5", "10.1.1.5" };
        var addrs = try leaseAddrs(gpa, opts, &local, 18080);
        defer addrs.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), addrs.items.len);
        try std.testing.expectEqualStrings("10.0.0.9", addrs.items[0].ip);
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
