//! CLI entry point: argument parsing, command dispatch (mount/status/peers/
//! pin/unpin/verify/dupes/update), and mount wiring into State.init / fuse_fs.run.
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

const piece = @import("piece.zig");
const proto = @import("proto.zig");
const sys = @import("sys.zig");
const store_mod = @import("store.zig");
const discover = @import("discover.zig");
const fuse_fs = @import("fuse_fs.zig");
const cull = @import("cull.zig");
const fuzzcorpus = @import("fuzzcorpus.zig");
const handover = @import("handover.zig");
const hf = @import("hf.zig");

const usage =
    \\modelfs: POSIX mount for model files. Local NVMe, then peers, then NFS.
    \\
    \\Usage:
    \\  modelfs mount <dir> --origin PATH [options]
    \\  modelfs status [--cache PATH]
    \\  modelfs peers --origin PATH
    \\  modelfs pin <relpath> [--cache PATH]
    \\  modelfs unpin <relpath> [--cache PATH]
    \\  modelfs verify <relpath> --origin PATH [--cache PATH]
    \\  modelfs dupes <relpath>... --origin PATH
    \\  modelfs dupes --all --origin PATH
    \\  modelfs pull <owner/repo> --origin PATH [--revision REF] [--dest REL]
    \\  modelfs update [--cache PATH]
    \\  modelfs version
    \\  modelfs help
    \\
    \\mount options:
    \\  --origin PATH         Existing NFS/dir origin (required). Writes go here.
    \\  --cache PATH          Local piece cache (default /var/cache/modelfs)
    \\  --id NAME             Override node id (default: short hostname)
    \\  --listen [IP:]PORT    Peer HTTP port (default {d}, 1-65535); binds all interfaces
    \\  --advertise ADDRS     Lease addresses IP[:PORT], comma separated, repeatable
    \\                        (replaces auto-detect; a defaulted port follows
    \\                        --listen; default: every local IPv4 except
    \\                        loopback and 169.254; none -> 127.0.0.1;
    \\                        0.0.0.0 and 255.255.255.255 are refused)
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
    \\pull options:
    \\  --revision REF        Hugging Face branch, tag, or commit (default main)
    \\  --dest REL            Where under --origin the files land (default: the
    \\                        repo id, so owner/repo lands at origin/owner/repo)
    \\
    \\mount/status/peers/pin/unpin/verify/dupes/pull/update:
    \\  --log LEVEL           Journal ceiling: err, warn, info (default), or debug
    \\
    \\status/peers/pin/unpin/verify/dupes/pull/update take only the flags shown on
    \\their Usage line plus the shared --origin/--cache/--psk/--log values.
    \\dupes --all scans every manifest on the origin and refuses a path
    \\list; mount-only options are refused on the rest. Every command also
    \\accepts -h/--help and -V/--version. "--" ends flag parsing: later
    \\arguments are taken literally (paths starting with '-'). Long options
    \\accept --name VALUE or --name=VALUE. Usage errors exit 2 with one
    \\named line on stderr; other failures exit 1. Help, version, and
    \\command results print on stdout.
    \\
    \\Env: MODELFS_ORIGIN MODELFS_CACHE MODELFS_PSK MODELFS_PSK_VALUE
    \\MODELFS_ID (mount only, like --id) MODELFS_LOG set the same values
    \\as their flags; an explicit flag wins. MODELFS_PSK_VALUE cannot be
    \\combined with --psk or MODELFS_PSK on mount. Every MODELFS_* value
    \\is trimmed of surrounding whitespace. An empty or whitespace-only
    \\value counts as unset (defaults apply), except a whitespace-only
    \\MODELFS_PSK_VALUE which is refused as empty. pull reads its Hugging
    \\Face token from HF_TOKEN, else $HF_HOME/token, else
    \\~/.cache/huggingface/token; there is no token flag, because argv is
    \\world-readable through /proc. Without one, only public repos pull.
    \\
    \\Examples:
    \\  modelfs mount /models --origin /net/192.168.0.100/models
    \\  modelfs status | jq -r .id
    \\  modelfs pin gguf/foo.gguf
    \\  modelfs verify gguf/foo.gguf --origin /net/192.168.0.100/models
    \\  modelfs dupes gguf/a.gguf gguf/b.gguf --origin /net/192.168.0.100/models
    \\  modelfs dupes --all --origin /net/192.168.0.100/models
    \\  modelfs pull unsloth/Qwen3-8B-GGUF --origin /net/192.168.0.100/models
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
        // Same one-line usage channel as a missing operand or unknown
        // command: dumping the help blob here made `modelfs` with no args
        // the only usage error that printed the full text instead of
        // naming what was missing.
        std.debug.print("missing command (want mount, status, peers, pin, unpin, verify, dupes, pull, update, version, help)\n", .{});
        return 2;
    }
    // Bare global forms live at position 0, where parseArgs sees a command
    // name, so they are answered here alongside their subcommand spellings.
    // Extra arguments are refused unless they are themselves those global
    // flags: `modelfs version --help` must match the documented "every
    // command also accepts -h/--help" instead of dying as a positional error.
    if (argv.items.len >= 1 and std.mem.eql(u8, argv.items[0], handover.internal_cmd)) {
        return cmdHandover(init, argv.items);
    }
    switch (classifyMeta(argv.items)) {
        .none => {},
        .help => return if (printOut(init.io, init.gpa, usage, .{proto.default_port})) 0 else 1,
        .version => return if (printOut(init.io, init.gpa, "modelfs {s}\n", .{build_options.version})) 0 else 1,
        .bad => {
            const what: []const u8 = if (isHelpTok(argv.items[0])) "help" else "version";
            std.debug.print("{s} takes no arguments (see 'modelfs help')\n", .{what});
            return 2;
        },
    }
    const parsed = parseArgs(gpa, init.environ_map, argv.items) catch |err| switch (err) {
        error.Help => return if (printOut(init.io, init.gpa, usage, .{proto.default_port})) 0 else 1,
        error.Version => return if (printOut(init.io, init.gpa, "modelfs {s}\n", .{build_options.version})) 0 else 1,
        // Usage errors exit 2, like every other bad invocation in this CLI
        // (missing subcommand argument, unknown command). Each one is named
        // at its own flag site inside parseArgs. Allocation failure is not a
        // bad invocation: monitors treat exit 2 as "fix the flags", so OOM
        // must not look like a usage error.
        else => {
            if (err == error.OutOfMemory) {
                std.log.err("out of memory parsing arguments", .{});
                return 1;
            }
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
    if (std.mem.eql(u8, parsed.cmd, "verify")) {
        if (parsed.rest.len != 1) {
            std.debug.print("verify takes exactly one path relative to the mount (see 'modelfs help')\n", .{});
            return 2;
        }
        return cmdVerify(init.io, gpa, parsed.opts, parsed.rest[0]);
    }
    if (std.mem.eql(u8, parsed.cmd, "dupes")) {
        if (parsed.opts.all) {
            if (parsed.rest.len != 0) {
                std.debug.print("dupes --all takes no paths (see 'modelfs help')\n", .{});
                return 2;
            }
            return cmdDupesAll(init.io, gpa, parsed.opts);
        }
        if (parsed.rest.len == 0) {
            std.debug.print("dupes takes at least one path relative to the mount (see 'modelfs help')\n", .{});
            return 2;
        }
        return cmdDupes(init.io, gpa, parsed.opts, parsed.rest);
    }
    if (std.mem.eql(u8, parsed.cmd, "pull")) {
        if (parsed.rest.len != 1) {
            std.debug.print("pull takes exactly one owner/repo (see 'modelfs help')\n", .{});
            return 2;
        }
        return cmdPull(init.io, gpa, init.environ_map, parsed.opts, parsed.rest[0]);
    }
    if (std.mem.eql(u8, parsed.cmd, "update")) {
        if (parsed.rest.len != 0) {
            std.debug.print("update takes no arguments (see 'modelfs help')\n", .{});
            return 2;
        }
        return cmdUpdate(init.io, gpa, parsed.opts);
    }
    // parseArgs refuses anything outside the commands dispatched above, so
    // this point is unreachable unless the knownCommand list and this
    // dispatch drift apart; failing loudly here surfaces that immediately.
    unreachable;
}

/// Data output (help text, status JSON, lease listings, pin confirmations)
/// goes to stdout so pipes and redirections see only results; diagnostics
/// stay on stderr via std.log/std.debug.print. False means the write
/// failed: the runtime ignores SIGPIPE, so a closed pipe, a full disk,
/// and EIO all surface as WriteFailed. Callers exit 1 so a monitor that
/// redirected `status` onto a full filesystem cannot read the command as
/// healthy after the JSON never landed.
fn writeOut(io: std.Io, bytes: []const u8) bool {
    // Under test, stdout is the runner's IPC channel (--listen=-): raw data
    // written there corrupts the protocol and wedges the run. A test that
    // needs the operator-facing bytes installs a buffer on captured_stdout.
    if (builtin.is_test) {
        if (captured_stdout) |buf| {
            buf.appendSlice(std.testing.allocator, bytes) catch return false;
        }
        return true;
    }
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch return false;
    return true;
}

var captured_stdout: ?*std.ArrayList(u8) = null;
var captured_stderr: ?*std.ArrayList(u8) = null;

fn printErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch {
        if (builtin.is_test) {
            if (captured_stderr) |b| b.appendSlice(std.testing.allocator, "modelfs: error\n") catch {};
            return;
        }
        std.debug.print(fmt, args);
        return;
    };
    if (builtin.is_test) {
        if (captured_stderr) |b| b.appendSlice(std.testing.allocator, line) catch {};
        return;
    }
    std.debug.print("{s}", .{line});
}

fn printOut(io: std.Io, gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) bool {
    var buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch {
        // A rendered line can outgrow the stack buffer: a lease id comes off
        // other nodes' JSON bounded by the read cap, not by validId, and a
        // pin relpath is whatever argv carried. Dropping the line would hide
        // a real result behind exit 0, so fall back to the heap instead.
        const heap = std.fmt.allocPrint(gpa, fmt, args) catch return false;
        defer gpa.free(heap);
        return writeOut(io, heap);
    };
    return writeOut(io, line);
}

const Opts = struct {
    origin: ?[]const u8 = null,
    cache: []const u8 = "/var/cache/modelfs",
    /// dupes-only: scan every manifest under origin/.cluster/manifests
    /// instead of a positional rel list (aggregate duplicate telemetry).
    all: bool = false,
    /// pull-only: the Hugging Face ref to pull, and where under the origin
    /// its files land (default: the repo id itself).
    revision: []const u8 = hf.default_revision,
    dest: ?[]const u8 = null,
    id: ?[]const u8 = null,
    psk_file: []const u8 = "/etc/modelfs.psk",
    psk_value: ?[]const u8 = null,
    log_level: std.log.Level = .info,
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

/// True when a dotted-quad host is 0.0.0.0 or 255.255.255.255: parseV4
/// admits both (they match inet_pton) but neither is a unicast address a
/// peer can dial. --advertise would publish them in the lease; --seed would
/// burn a timeout on every miss. Names are left to buildSeeds.
fn undialablePeerIp(ip: []const u8) bool {
    var quad: [4]u8 = undefined;
    if (!discover.parseV4(ip, &quad)) return false;
    return !discover.isDialableHost(&quad);
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
        if (std.mem.findScalar(u8, a, '=')) |eq| {
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
/// meaning -- `--id ""` is still refused. Surrounding whitespace is not
/// part of the value (EnvironmentFile trailing space, a copied path with a
/// newline): trimmed first, and a whitespace-only remainder counts as unset
/// the same way. MODELFS_PSK_VALUE is the exception -- a whitespace-only
/// secret still reaches loadPsk so it can refuse EmptyPsk rather than
/// falling through to the PSK file.
fn envValue(environ: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const v = environ.get(name) orelse return null;
    const trimmed = std.mem.trim(u8, v, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

/// MODELFS_LOG / --log values name a std.log.Level exactly; anything else
/// ("Info", "warning", "verbose") is refused by the caller instead of
/// silently leaving the default ceiling in force.
fn parseLogLevel(s: []const u8) ?std.log.Level {
    if (std.mem.eql(u8, s, "err")) return .err;
    if (std.mem.eql(u8, s, "warn")) return .warn;
    if (std.mem.eql(u8, s, "info")) return .info;
    if (std.mem.eql(u8, s, "debug")) return .debug;
    return null;
}

/// Named refusal for a log-ceiling value that parseLogLevel rejects.
/// `source` is `--log` or `MODELFS_LOG` so the operator sees which knob
/// was wrong.
fn takeLogLevel(source: []const u8, raw: []const u8) !std.log.Level {
    return parseLogLevel(raw) orelse {
        if (!builtin.is_test)
            std.debug.print("{s} {s}: want err, warn, info, or debug\n", .{ source, raw });
        return error.BadLogLevel;
    };
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

/// First unknown `MODELFS_*` name in the environment, or null. The name
/// aliases the map. HashMap iteration must not choose which typo is
/// reported when several exist: the refusal is a function of the name set.
fn unknownEnvName(environ: *const std.process.Environ.Map) ?[]const u8 {
    const known = [_][]const u8{ "MODELFS_ORIGIN", "MODELFS_CACHE", "MODELFS_PSK", "MODELFS_PSK_VALUE", "MODELFS_ID", "MODELFS_LOG" };
    var best: ?[]const u8 = null;
    var it = environ.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        if (!std.mem.startsWith(u8, name, "MODELFS_")) continue;
        for (known) |k| {
            if (std.mem.eql(u8, name, k)) break;
        } else {
            if (best == null or std.mem.order(u8, name, best.?) == .lt) best = name;
        }
    }
    return best;
}

/// The MODELFS_ prefix is this CLI's environment namespace; anything under
/// it that no flag answers to is a misspelling, not a foreign variable.
/// Variables outside the namespace are never this binary's business and
/// pass untouched.
fn checkKnownEnv(environ: *const std.process.Environ.Map) !void {
    const name = unknownEnvName(environ) orelse return;
    if (!builtin.is_test) {
        var lbuf: [512]u8 = undefined;
        std.debug.print("{s}", .{unknownEnvLine(&lbuf, name)});
    }
    return error.UnknownEnv;
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
/// Every --origin consumer gates on this right after their reachability
/// check: a regular file realpaths fine, but leases can never live under
/// it (.cluster creation fails every tick) and joined relpath reads all
/// die ENOTDIR behind the NFS fallback, so accepting it would trade one
/// named refusal now for a silently dead origin (or, for dupes --all, an
/// empty scan that exits 0).
fn pathIsDir(zp: [*:0]const u8) bool {
    var st: sys.c.struct_stat = undefined;
    return sys.statPath(zp, &st) == 0 and (st.st_mode & sys.c.S_IFMT) == sys.c.S_IFDIR;
}

/// Realpath of an --origin that exists as a directory. Unreachable paths
/// and regular files fail with the same named messages mount already used,
/// so peers/verify/dupes cannot read a typo or a file as an empty cluster
/// or an empty duplicate scan.
fn resolveOriginDir(gpa: std.mem.Allocator, origin: []const u8) ![]u8 {
    const real = sys.realpathAlloc(gpa, origin) catch {
        if (!builtin.is_test) std.log.err("origin {s} is not reachable", .{origin});
        return error.BadPath;
    };
    errdefer gpa.free(real);
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    if (!if (sys.toZ(&zbuf, real)) |z| pathIsDir(z) else |_| false) {
        if (!builtin.is_test) std.log.err("origin {s} is not a directory", .{origin});
        return error.NotDir;
    }
    return real;
}

/// Refuses mount-only knobs on the other commands, as the help text promises
/// ("status/peers/pin/unpin take only the flags shown on their Usage line"):
/// accepted-and-ignored they would silently do nothing (a `status --detach`,
/// a `pin --piece 4M` that changes no piece grid), leaving the caller to
/// believe an option took effect.
/// A flag only one non-mount command understands. Accepted-and-ignored is
/// the failure to avoid: it reads as a working knob.
fn rejectOutsideCommand(cmd: []const u8, want: []const u8, flag: []const u8) !void {
    if (!std.mem.eql(u8, cmd, want)) {
        if (!builtin.is_test) std.debug.print("{s} only applies to modelfs {s}\n", .{ flag, want });
        return error.FlagOutsideCommand;
    }
}

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
    inline for (.{ "mount", "status", "peers", "pin", "unpin", "verify", "dupes", "pull", "update" }) |c| {
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
            std.debug.print("unknown command \"{s}\" (want mount, status, peers, pin, unpin, verify, dupes, pull, update, version, help)\n", .{cmd});
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
    // For scripted mounts that cannot place a PSK file. Trimmed like the
    // file form, but a whitespace-only value stays set so loadPsk can
    // refuse EmptyPsk instead of envValue treating it as unset and
    // falling through to /etc/modelfs.psk.
    if (environ.get("MODELFS_PSK_VALUE")) |raw| {
        if (raw.len != 0) opts.psk_value = std.mem.trim(u8, raw, " \t\r\n");
    }
    // The journal is the only configuration observability this daemon has,
    // so the ceiling is movable per environment: MODELFS_LOG=err quiets a
    // cron'd status loop, debug aids a misbehaving mount. Applied for every
    // command -- status/peers/pin/unpin log warnings too. A value outside the
    // documented set is refused like any other malformed knob: silently
    // keeping the default would leave the operator believing verbosity
    // changed. --log overwrites this below (explicit flag wins).
    if (envValue(environ, "MODELFS_LOG")) |v| {
        opts.log_level = try takeLogLevel("MODELFS_LOG", v);
    }
    // MODELFS_ID follows the --id flag's mount-only scope: status/peers/pin/unpin
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
        if (std.mem.eql(u8, flag, "--log")) {
            const raw = try takeValue(args, flag, &i, inline_val);
            opts.log_level = try takeLogLevel(flag, raw);
        } else if (std.mem.eql(u8, flag, "--origin")) {
            opts.origin = try takeValue(args, flag, &i, inline_val);
        } else if (std.mem.eql(u8, flag, "--cache")) {
            opts.cache = try takeValue(args, flag, &i, inline_val);
        } else if (std.mem.eql(u8, flag, "--all")) {
            // dupes-only: the other commands have no whole-store scan, and
            // an accepted-and-ignored --all would read as a working knob.
            try rejectOutsideCommand(cmd, "dupes", flag);
            try rejectInlineValue(flag, inline_val);
            opts.all = true;
        } else if (std.mem.eql(u8, flag, "--revision")) {
            try rejectOutsideCommand(cmd, "pull", flag);
            opts.revision = try takeValue(args, flag, &i, inline_val);
        } else if (std.mem.eql(u8, flag, "--dest")) {
            try rejectOutsideCommand(cmd, "pull", flag);
            opts.dest = try takeValue(args, flag, &i, inline_val);
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
                if (!discover.isDialableHost(&quad)) {
                    if (!builtin.is_test) std.debug.print("--advertise {s}: {s} is not a dialable peer address\n", .{ v, hp.ip });
                    return error.UndialableIp;
                }
                try opts.advertise.append(gpa, hp);
            }
        } else if (std.mem.eql(u8, flag, "--seed")) {
            try rejectOutsideMount(cmd, flag);
            // Same surrounding-space trim --advertise applies to each
            // comma-separated token: a quoted " 10.0.0.9" is the address,
            // not a hostname parseHostPort would then reject.
            const s = std.mem.trim(u8, try takeValue(args, flag, &i, inline_val), " \t");
            // Validate now with a named message instead of failing later in
            // mount setup with a bare parseInt error.
            const hp = parseHostPort(s) catch |err| {
                if (!builtin.is_test) {
                    if (err == error.ZeroPort)
                        std.debug.print("--seed {s}: port 0 is not a peer port (want 1-65535)\n", .{s})
                    else
                        std.debug.print("--seed {s}: bad address (want HOST[:PORT])\n", .{s});
                }
                return error.BadHostPort;
            };
            // Numeric form is gated here; a hostname that resolves to
            // 0.0.0.0 is refused in buildSeeds after DNS, same message.
            if (undialablePeerIp(hp.ip)) {
                if (!builtin.is_test) std.debug.print("--seed {s}: {s} is not a dialable peer address\n", .{ s, hp.ip });
                return error.UndialableIp;
            }
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
    // for every other pair. status/peers/pin/unpin never load the secret, so a
    // shell-wide inline value must not fail those commands the way the
    // e2e suites pass --psk to them.
    if (std.mem.eql(u8, cmd, "mount") and opts.psk_value != null and psk_file_set) {
        if (!builtin.is_test)
            std.debug.print("MODELFS_PSK_VALUE cannot be combined with --psk or MODELFS_PSK; pick one\n", .{});
        return error.ConflictingPsk;
    }
    // Empty positional after flags (`mount ""`) is the same missing
    // directory as omitting the argument; refuse it here so cmdMount never
    // sees a zero-length path that would fail later as "not reachable".
    if (std.mem.eql(u8, cmd, "mount")) {
        for (rest.items) |r| {
            if (r.len == 0) {
                if (!builtin.is_test)
                    std.debug.print("mount takes exactly one directory argument (see 'modelfs help')\n", .{});
                return error.MissingValue;
            }
        }
    }
    // Applied once the parse succeeded so a later usage error does not
    // leave a half-applied ceiling. Under test the process-wide logger
    // stays at the runner default; callers assert opts.log_level.
    if (!builtin.is_test) active_log_level = opts.log_level;
    return .{ .cmd = cmd, .opts = opts, .rest = try rest.toOwnedSlice(gpa) };
}

fn loadPsk(gpa: std.mem.Allocator, opts: Opts) ![]u8 {
    // An empty shared secret would authenticate every "Bearer " request;
    // refuse it before any socket is bound.
    if (opts.psk_value) |v| {
        // Same surrounding-whitespace trim as the file form: openssl-rand
        // files and systemd EnvironmentFile lines carry a trailing newline,
        // and a leading/trailing space would start the daemon then 401 every
        // peer (bearerOk trims the received token but hashes `want`
        // verbatim, so "secret " never equals the wire form "secret").
        const trimmed = std.mem.trim(u8, v, " \t\r\n");
        if (trimmed.len == 0) {
            if (!builtin.is_test) std.log.err("MODELFS_PSK_VALUE is empty; refusing to serve unauthenticated", .{});
            return error.EmptyPsk;
        }
        // Cap the token that actually rides the wire, after trim: a
        // max-size secret plus a trailing newline is still one legal token.
        if (trimmed.len > proto.max_psk_bytes) {
            if (!builtin.is_test)
                std.log.err("MODELFS_PSK_VALUE is longer than {d} bytes; refusing", .{proto.max_psk_bytes});
            return error.PskTooLarge;
        }
        return dupeHeaderSafePsk(gpa, trimmed);
    }
    var z: [sys.c.PATH_MAX]u8 = undefined;
    const p = try sys.toZ(&z, opts.psk_file);
    var open_errno: i32 = 0;
    var file_mode: sys.c.mode_t = 0;
    const raw = sys.readFileAllocOpenErrno(gpa, p, proto.max_psk_bytes, &open_errno, &file_mode) catch |err| switch (err) {
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
    // Mode of the fd we just read, not a later path-stat: swapping the
    // file between read and chmod-check would otherwise let a world-readable
    // secret through. Other bits mean any local user can steal the cluster
    // credential; group bits are a warning (a dedicated group is a valid
    // deployment).
    if ((file_mode & 0o007) != 0) {
        if (!builtin.is_test)
            std.log.err("PSK file {s} is world-readable; chmod 600 {s} and remount", .{ opts.psk_file, opts.psk_file });
        return error.PskWorldReadable;
    }
    if ((file_mode & 0o070) != 0) {
        std.log.warn("PSK file {s} is readable by group; run: chmod 600 {s}", .{ opts.psk_file, opts.psk_file });
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
    const abs = sys.realpathAlloc(gpa, path) catch blk: {
        const rc = sys.mkdirAll(path, 0o755);
        if (rc != 0) {
            std.log.err("cannot create {s} {s} (errno {d})", .{ label, path, -rc });
            return error.MkdirFailed;
        }
        break :blk sys.realpathAlloc(gpa, path) catch {
            std.log.err("{s} {s} is not reachable", .{ label, path });
            return error.BadPath;
        };
    };
    // realpath succeeds for a regular file; mkdir under it then fails as
    // a bare ENOTDIR from ensureLayout. Same named refusal origin uses.
    var zbuf: [sys.c.PATH_MAX]u8 = undefined;
    if (!if (sys.toZ(&zbuf, abs)) |z| pathIsDir(z) else |_| false) {
        if (!builtin.is_test) std.log.err("{s} {s} is not a directory", .{ label, path });
        gpa.free(abs);
        return error.NotDir;
    }
    return abs;
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
    // Canonicalize so the published lease JSON is a function of the
    // address set, never of getifaddrs or --advertise enumeration order.
    // Probe walks already ignore that order (pathTieLess); this keeps the
    // document itself replayable from the NIC set.
    std.mem.sort(proto.LeaseAddr, addrs.items, {}, struct {
        fn lessThan(_: void, a: proto.LeaseAddr, b: proto.LeaseAddr) bool {
            return discover.addrTieLess(a.ip, a.port, b.ip, b.port);
        }
    }.lessThan);
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
            if (!discover.isDialableHost(&quad)) {
                if (!builtin.is_test) std.log.err("--seed {s}: {s} is not a dialable peer address", .{ s, hp.ip });
                return error.SeedUndialable;
            }
            try out.addrs.append(gpa, hp);
            continue;
        }
        var rb: [64]u8 = undefined;
        const rip = sys.resolveIpv4(hp.ip, &rb) orelse {
            if (!builtin.is_test) std.log.err("--seed {s}: host {s} does not resolve to an IPv4 address", .{ s, hp.ip });
            return error.SeedUnresolved;
        };
        var resolved: [4]u8 = undefined;
        if (!discover.parseV4(rip, &resolved) or !discover.isDialableHost(&resolved)) {
            if (!builtin.is_test) std.log.err("--seed {s}: host {s} resolved to {s}, which is not a dialable peer address", .{ s, hp.ip, rip });
            return error.SeedUndialable;
        }
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
    const origin = resolveOriginDir(gpa, origin_raw) catch return 1;
    defer gpa.free(origin);

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
        if (err != error.MissingPsk and err != error.EmptyPsk and err != error.PskUnreadable and err != error.PskWorldReadable)
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
    disableCoreDumps() catch {
        std.log.err("cannot disable core dumps; refusing to start with the PSK in a dumpable process", .{});
        return 1;
    };
    scrubPskEnv();

    var id_buf: [256]u8 = undefined;
    const id = try gpa.dupe(u8, opts.id orelse discover.hostname(&id_buf));
    defer gpa.free(id);

    const local_ips = discover.localIpv4(gpa) catch |err| blk: {
        std.log.warn("cannot enumerate local IPv4 ({t}); advertise may be empty", .{err});
        break :blk @as([][]const u8, &.{});
    };
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
        error.SeedUnresolved, error.SeedUndialable => return 1,
        else => {
            std.log.err("build seeds: {t}", .{err});
            return 1;
        },
    };
    defer seed_list.deinit(gpa);

    const st = try gpa.create(fuse_fs.State);
    st.init(gpa, init.io, origin, cache, opts.piece, opts.water, id, addrs.items, local_ips, seed_list.addrs.items, psk, opts.direct_io);
    st.mountpoint = mount_abs;
    st.allow_other = opts.allow_other;
    st.detach = opts.detach;
    st.listen_port = eff_port;
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
    fuse_fs.tickCluster(st, cluster_now);
    st.server.bindAll(addrs.items) catch |err| {
        std.log.err("bind peer http: {t}", .{err});
        teardownMount(st);
        return 1;
    };

    // The whole effective configuration in one line: a cull/listen/io
    // misconfiguration must be diagnosable from the journal alone, without
    // reconstructing which flag or env var won. Secrets never appear here.
    std.log.info("mount {s} origin={s} cache={s} id={s} piece={d} listen=:{d} io={s} water={d}/{d}/{d} allow_other={}", .{
        mount_abs,                                  origin,           cache,
        id,                                         opts.piece,       eff_port,
        if (opts.direct_io) "direct" else "kernel", opts.water.brun,  opts.water.bcull,
        opts.water.bstop,                           opts.allow_other,
    });

    const rc = fuse_fs.run(st);
    teardownMount(st);
    // Lifecycle closure next to the startup "mount" line: when this node
    // later shows up with an expired lease in `modelfs peers`, the journal
    // distinguishes a cleanly stopped daemon from one that crashed or was
    // killed by the absence of this line. A nonzero rc means the mount never
    // served; libfuse already narrated the failure on stderr.
    if (rc == 0) std.log.info("unmounted {s}", .{mount_abs});
    return @intCast(if (rc < 0) 1 else rc);
}

/// Heap-State counterpart of `State.deinit`: the mount path allocates
/// State with gpa.create, so teardown has to destroy it too, unless a
/// stuck peer handler still holds the object (deinit already leaked the
/// tree in that case).
fn teardownMount(st: *fuse_fs.State) void {
    st.deinit();
    if (st.server.http_inflight.load(.monotonic) != 0) return;
    st.gpa.destroy(st);
}

/// Refuse core dumps for this process. The cluster PSK lives in daemon
/// memory for the mount lifetime; a crash would otherwise write it
/// wherever kernel.core_pattern points (often a world-readable file).
/// Both soft and hard limits go to zero so a later setrlimit in this
/// process cannot raise them without CAP_SYS_RESOURCE. Failure is
/// returned so mount can refuse to keep the secret in a dumpable process.
/// Lives here (mount-time process policy), not in sys.zig (syscall
/// wrappers: EINTR retry, CLOEXEC, nofollow, owner-only writes).
fn disableCoreDumps() !void {
    std.posix.setrlimit(.CORE, .{ .cur = 0, .max = 0 }) catch |err| {
        std.log.err("cannot disable core dumps ({t}); a crash may write the cluster PSK", .{err});
        return err;
    };
}

/// Drops MODELFS_PSK_VALUE from the process environment so the
/// auto_unmount fusermount helper (spawned from fuse_main) and
/// /proc/<pid>/environ cannot inherit the inline secret. The daemon
/// already holds its own copy from loadPsk.
fn scrubPskEnv() void {
    _ = sys.c.unsetenv("MODELFS_PSK_VALUE");
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
/// subtraction in safe builds. A `mono_s` ahead of now is a previous-boot
/// leftover or a hostile future stamp: CLOCK_MONOTONIC resets on reboot,
/// and `now -| stamp` would read as age 0, so the gap is taken the other
/// way. Wall-clock `now_s` still treats a backward step as fresh (NTP noise
/// on older artifacts).
fn statusAgeSecs(io: std.Io, doc: StatusLiveness) ?i64 {
    if (doc.mono_s) |stamp| {
        const now = sys.monoSec(io);
        return if (stamp > now) stamp -| now else now -| stamp;
    }
    if (doc.now_s) |stamp| return sys.nowSec(io) -| stamp;
    return null;
}

/// Same pid + 120s heartbeat gates `status` and `update` use. On success
/// `blob_out` owns the document (caller frees). Failures print a named
/// line through printErr and return error.NotLive.
fn liveDaemon(io: std.Io, gpa: std.mem.Allocator, cache: []const u8, blob_out: *?[]u8) error{ NotLive, OutOfMemory }!i64 {
    blob_out.* = null;
    var z: [sys.c.PATH_MAX]u8 = undefined;
    const p = sys.joinZ(&z, cache, store_mod.status_file) catch {
        printErr("modelfs: cache path too long to name {s}/{s}\n", .{ cache, store_mod.status_file });
        return error.NotLive;
    };
    var open_errno: i32 = 0;
    const blob = sys.readFileAllocNoFollowOpenErrno(gpa, p, 4096, &open_errno) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.OpenFailed and open_errno != sys.c.ENOENT)
            printErr("modelfs: cannot read {s}/{s} (errno {d}); cannot tell whether the daemon is running\n", .{ cache, store_mod.status_file, open_errno })
        else
            printErr("modelfs: not running (no {s}/{s})\n", .{ cache, store_mod.status_file });
        return error.NotLive;
    };
    const doc = std.json.parseFromSlice(StatusLiveness, gpa, blob, .{ .ignore_unknown_fields = true }) catch {
        printErr("modelfs: not running ({s}/{s} is unreadable)\n", .{ cache, store_mod.status_file });
        gpa.free(blob);
        return error.NotLive;
    };
    defer doc.deinit();
    if (!pidAlive(doc.value.pid)) {
        printErr("modelfs: not running (stale status.json names exited pid {d})\n", .{doc.value.pid});
        gpa.free(blob);
        return error.NotLive;
    }
    if (statusAgeSecs(io, doc.value)) |age| {
        if (age > max_status_age_secs) {
            printErr("modelfs: not serving ({s}/{s} is {d}s stale; the daemon stopped ticking)\n", .{ cache, store_mod.status_file, age });
            gpa.free(blob);
            return error.NotLive;
        }
    }
    blob_out.* = blob;
    return doc.value.pid;
}

fn cmdStatus(io: std.Io, gpa: std.mem.Allocator, opts: Opts) !u8 {
    var blob: ?[]u8 = null;
    _ = liveDaemon(io, gpa, opts.cache, &blob) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotLive => return 1,
    };
    defer if (blob) |b| gpa.free(b);
    return if (writeOut(io, blob.?)) 0 else 1;
}

const update_wait_ms: u32 = 30_000;
const update_poll_ms: u32 = 50;

fn selfExe(buf: *[sys.c.PATH_MAX]u8) ![]const u8 {
    const n = std.os.linux.readlink("/proc/self/exe", buf, buf.len);
    const signed: isize = @bitCast(n);
    if (signed < 0 or n == 0 or n >= buf.len) return error.NoExe;
    return buf[0..n];
}

fn cmdUpdate(io: std.Io, gpa: std.mem.Allocator, opts: Opts) !u8 {
    var blob: ?[]u8 = null;
    const pid = liveDaemon(io, gpa, opts.cache, &blob) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotLive => return 1,
    };
    defer if (blob) |b| gpa.free(b);

    var exe_buf: [sys.c.PATH_MAX]u8 = undefined;
    const bin = selfExe(&exe_buf) catch {
        printErr("modelfs: cannot resolve this binary via /proc/self/exe\n", .{});
        return 1;
    };
    var tok: [handover.token_bytes * 2]u8 = undefined;
    handover.randomToken(&tok) catch {
        printErr("modelfs: cannot read random bytes for the update handshake token\n", .{});
        return 1;
    };
    const req = handover.encodeReq(gpa, bin, &tok) catch return 1;
    defer gpa.free(req);
    var pbuf: [sys.c.PATH_MAX]u8 = undefined;
    const req_path = sys.joinZ(&pbuf, opts.cache, handover.req_file) catch {
        printErr("modelfs: cache path too long to name {s}/{s}\n", .{ opts.cache, handover.req_file });
        return 1;
    };
    if (sys.writeFileOwnerOnly(req_path, req) != 0) {
        printErr("modelfs: cannot write {s}/{s}\n", .{ opts.cache, handover.req_file });
        return 1;
    }
    std.posix.kill(@intCast(pid), .USR2) catch {
        printErr("modelfs: cannot signal pid {d} to replace its image\n", .{pid});
        return 1;
    };

    var ack_buf: [sys.c.PATH_MAX]u8 = undefined;
    const ack_path = sys.joinZ(&ack_buf, opts.cache, handover.ack_file) catch {
        printErr("modelfs: cache path too long to name {s}/{s}\n", .{ opts.cache, handover.ack_file });
        return 1;
    };
    var waited: u32 = 0;
    while (waited < update_wait_ms) : (waited += update_poll_ms) {
        var open_errno: i32 = 0;
        const ack_blob = sys.readFileAllocNoFollowOpenErrno(gpa, ack_path, 4096, &open_errno) catch {
            sys.sleepMs(io, update_poll_ms);
            continue;
        };
        defer gpa.free(ack_blob);
        const ack = handover.decodeAck(gpa, ack_blob) catch {
            sys.sleepMs(io, update_poll_ms);
            continue;
        };
        defer ack.deinit();
        if (std.mem.eql(u8, ack.value.token, &tok)) {
            if (!printOut(io, gpa, "updated pid {d}\n", .{pid})) return 1;
            return 0;
        }
        sys.sleepMs(io, update_poll_ms);
    }
    printErr("modelfs: update timed out waiting for pid {d} to replace its image\n", .{pid});
    return 1;
}

/// Pulls one Hugging Face model revision onto the origin. No daemon and no
/// PSK: this writes the NFS export the cluster reads from, and every node's
/// mount then serves what landed. Files already present at the listed size
/// are left alone, so a rerun after a failure finishes the job.
fn cmdPull(io: std.Io, gpa: std.mem.Allocator, environ: *const std.process.Environ.Map, opts: Opts, repo: []const u8) !u8 {
    const origin_raw = opts.origin orelse {
        printErr("pull needs --origin (or MODELFS_ORIGIN)\n", .{});
        return 2;
    };
    if (!hf.repoOk(repo)) {
        printErr("modelfs: {s} is not a Hugging Face owner/repo id\n", .{discover.displayName(repo)});
        return 2;
    }
    if (!hf.revisionOk(opts.revision)) {
        printErr("modelfs: --revision {s} is not a branch, tag, or commit\n", .{discover.displayName(opts.revision)});
        return 2;
    }
    // Default destination is the repo id, so two models never collide and
    // the mount path reads like the model card it came from.
    const dest = opts.dest orelse repo;
    if (dest.len != 0 and (!store_mod.relOk(dest) or discover.relIsCluster(dest))) {
        printErr("modelfs: --dest {s} is not a path under the origin\n", .{discover.displayName(dest)});
        return 2;
    }

    const origin = resolveOriginDir(gpa, origin_raw) catch return 1;
    defer gpa.free(origin);

    const token = hf.loadToken(gpa, environ) catch null;
    defer if (token) |t| {
        std.crypto.secureZero(u8, t);
        gpa.free(t);
    };
    // A token is a bearer credential for a private repo; core dumps of this
    // process must not carry it, the same gate mount applies to the PSK.
    if (token != null) {
        disableCoreDumps() catch {
            printErr("modelfs: cannot disable core dumps; refusing to pull with a token in a dumpable process\n", .{});
            return 1;
        };
    }

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var report: hf.Report = .{};
    hf.pull(gpa, io, &client, origin, dest, repo, opts.revision, token, &report) catch |err| {
        printErr("modelfs: pull {s}@{s} failed ({t}) after {d} file(s); rerun to resume\n", .{
            discover.displayName(repo), discover.displayName(opts.revision), err, report.pulled,
        });
        return 1;
    };
    if (!printOut(io, gpa, "pulled {d} file(s), {d} bytes; {d} already present\n", .{
        report.pulled, report.bytes, report.skipped,
    })) return 1;
    return 0;
}

fn cmdHandover(init: std.process.Init, args: []const []const u8) !u8 {
    const gpa = init.gpa;
    const handoff = handover.parseHandoffArgs(args) catch {
        printErr("modelfs: _handover needs --state-fd N MOUNTPOINT\n", .{});
        return 1;
    };
    var owned = handover.readStateFd(gpa, @intCast(handoff.state_fd)) catch |err| {
        printErr("modelfs: cannot read handover state fd {d} ({t})\n", .{ handoff.state_fd, err });
        return 1;
    };
    defer {
        std.crypto.secureZero(u8, owned.psk);
        owned.deinit();
    }
    // argv and the state blob name the same mount or this is not the
    // handover the exec intended.
    if (!std.mem.eql(u8, handoff.mount, owned.mount)) {
        printErr("modelfs: handover state names {s} but argv names {s}\n", .{ owned.mount, handoff.mount });
        return 1;
    }
    disableCoreDumps() catch {
        printErr("modelfs: cannot disable core dumps; refusing handover with the PSK in a dumpable process\n", .{});
        return 1;
    };
    scrubPskEnv();

    const local_ips = discover.localIpv4(gpa) catch @as([][]const u8, &.{});
    defer {
        if (local_ips.len > 0) {
            for (local_ips) |s| gpa.free(s);
            gpa.free(local_ips);
        }
    }

    const st = try gpa.create(fuse_fs.State);
    st.init(gpa, init.io, owned.origin, owned.cache, owned.piece, owned.water, owned.id, owned.advertise, local_ips, owned.seeds, owned.psk, owned.direct_io);
    st.mountpoint = owned.mount;
    st.allow_other = owned.allow_other;
    st.listen_port = owned.listen;
    st.setInitRequest(owned.init) catch {
        printErr("modelfs: handover state carries no usable FUSE_INIT request\n", .{});
        teardownMount(st);
        return 1;
    };
    errdefer teardownMount(st);
    fuse_fs.restoreMaps(st, &owned) catch {
        printErr("modelfs: cannot restore the inode and open-file tables after handover\n", .{});
        teardownMount(st);
        return 1;
    };
    const layout_rc = st.store.ensureLayout();
    if (layout_rc != 0) {
        std.log.err("cannot create cache dirs under {s} (errno {d})", .{ owned.cache, -layout_rc });
        teardownMount(st);
        return 1;
    }
    for (owned.listen_fds) |fd| {
        st.server.adoptListenFd(@intCast(fd)) catch |err| {
            std.log.err("adopt listen fd {d}: {t}", .{ fd, err });
            teardownMount(st);
            return 1;
        };
    }
    // The request that triggered this exec carries the token the waiting
    // CLI matches against the ack. It is consumed here so a leftover cannot
    // make a later SIGUSR2 replay an update nobody asked for.
    {
        var pbuf: [sys.c.PATH_MAX]u8 = undefined;
        if (sys.joinZ(&pbuf, owned.cache, handover.req_file)) |rp| {
            var open_errno: i32 = 0;
            if (sys.readFileAllocNoFollowOpenErrno(gpa, rp, 4096, &open_errno)) |req_blob| {
                defer gpa.free(req_blob);
                if (handover.decodeReq(gpa, req_blob)) |parsed| {
                    defer parsed.deinit();
                    st.update_token = gpa.dupe(u8, parsed.value.token) catch null;
                } else |_| {}
            } else |_| {}
            _ = sys.unlink(rp);
        } else |_| {}
    }
    const rc = fuse_fs.attach(st, owned.fuse_fd);
    teardownMount(st);
    return @intCast(if (rc < 0) 1 else rc);
}

fn cmdPeers(io: std.Io, gpa: std.mem.Allocator, opts: Opts) !u8 {
    const origin = opts.origin orelse {
        std.debug.print("peers needs --origin (or MODELFS_ORIGIN)\n", .{});
        return 2;
    };
    // Same reachability and directory gate mount applies: a typo'd path or
    // a regular file must fail loudly instead of listing as an empty cluster.
    const real = resolveOriginDir(gpa, origin) catch return 1;
    defer gpa.free(real);

    // Collect before printing: readdir order is filesystem-dependent (and
    // the origin is NFS), so sorting by lease file name keeps the listing a
    // function of the directory's contents alone and run-to-run diffable.
    // Each row's addrs are sorted the same way the published lease is
    // (addrTieLess), so a mixed-fleet document that still carries getifaddrs
    // order cannot change the listing. walkLeases's parsed value aliases a
    // stack buffer, so every string printed below is copied here.
    const Addr = struct {
        ip: []u8,
        port: u16,
        mbps: u32,
    };
    const Row = struct {
        name: []u8,
        id: []u8,
        until: i64,
        addrs: []Addr,
    };
    const Acc = struct {
        gpa: std.mem.Allocator,
        rows: *std.ArrayList(Row),

        pub fn visit(acc: *@This(), name: []const u8, parsed: std.json.Parsed(proto.Lease)) void {
            const lease = parsed.value;
            const owned_name = acc.gpa.dupe(u8, name) catch return;
            const owned_id = acc.gpa.dupe(u8, lease.id) catch {
                acc.gpa.free(owned_name);
                return;
            };
            const addrs = acc.gpa.alloc(Addr, lease.addrs.len) catch {
                acc.gpa.free(owned_name);
                acc.gpa.free(owned_id);
                return;
            };
            var n: usize = 0;
            while (n < lease.addrs.len) : (n += 1) {
                addrs[n] = .{
                    .ip = acc.gpa.dupe(u8, lease.addrs[n].ip) catch {
                        for (addrs[0..n]) |a| acc.gpa.free(a.ip);
                        acc.gpa.free(addrs);
                        acc.gpa.free(owned_name);
                        acc.gpa.free(owned_id);
                        return;
                    },
                    .port = lease.addrs[n].port,
                    .mbps = lease.addrs[n].mbps,
                };
            }
            acc.rows.append(acc.gpa, .{
                .name = owned_name,
                .id = owned_id,
                .until = lease.until,
                .addrs = addrs,
            }) catch {
                for (addrs) |a| acc.gpa.free(a.ip);
                acc.gpa.free(addrs);
                acc.gpa.free(owned_name);
                acc.gpa.free(owned_id);
            };
        }
    };

    var rows: std.ArrayList(Row) = .empty;
    defer {
        for (rows.items) |r| {
            for (r.addrs) |a| gpa.free(a.ip);
            gpa.free(r.addrs);
            gpa.free(r.name);
            gpa.free(r.id);
        }
        rows.deinit(gpa);
    }
    var acc: Acc = .{ .gpa = gpa, .rows = &rows };
    switch (discover.walkLeases(gpa, origin, &acc)) {
        .ok => {},
        .path_too_long => {
            std.log.err("origin path too long to name {s}/{s}", .{ origin, discover.cluster_dir });
            return 1;
        },
        .missing_dir => {
            // The origin itself was verified reachable above, so a missing
            // .cluster dir here is a fresh/empty cluster, not an error: same
            // exit-0 empty output as below, with the reason on stdout next
            // to where the listing would have been.
            return if (printOut(io, gpa, "no cluster leases at {s}/{s}\n", .{ origin, discover.cluster_dir })) 0 else 1;
        },
        .io_err => |e| {
            // EIO/ENOTDIR/EACCES: the origin is there but .cluster cannot
            // be listed. Printing the empty-cluster line would look like a
            // healthy fleet of zero, which is the wrong incident start.
            // Stdout is the listing a pipe consumes (`modelfs peers | grep
            // live`); the reason belongs on stderr, like status's "cannot
            // read" / "not running" lines.
            if (!builtin.is_test)
                std.debug.print("cannot read cluster leases at {s}/{s} (errno {d})\n", .{ origin, discover.cluster_dir, e });
            return 1;
        },
    }

    std.mem.sort(Row, rows.items, {}, struct {
        fn lessThan(_: void, a: Row, b: Row) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
    for (rows.items) |*r| {
        std.mem.sort(Addr, r.addrs, {}, struct {
            fn lessThan(_: void, a: Addr, b: Addr) bool {
                return discover.addrTieLess(a.ip, a.port, b.ip, b.port);
            }
        }.lessThan);
    }

    const now = sys.nowSec(io);
    var any = false;
    for (rows.items) |r| {
        const live = r.until >= now;
        const status_str = if (live) "live" else "expired";
        // Lease ids and addresses come off shared storage as other nodes'
        // JSON; echo them only when free of control bytes so `modelfs peers`
        // cannot be turned into a terminal-injection vector.
        const id_shown = if (discover.printable(r.id)) r.id else "<id withheld: control bytes>";
        if (!printOut(io, gpa, "{s} (until={d}, {s})\n", .{ id_shown, r.until, status_str })) return 1;
        for (r.addrs) |a| {
            const ip_shown = if (discover.printable(a.ip)) a.ip else "<ip withheld>";
            if (!printOut(io, gpa, "  -> {s}:{d} (speed={d}mbps)\n", .{ ip_shown, a.port, a.mbps })) return 1;
        }
        any = true;
    }
    if (!any) return if (printOut(io, gpa, "no leases\n", .{})) 0 else 1;
    return 0;
}

/// Strip the `/models/` convenience prefix operators paste from the default
/// mountpoint, then a leftover leading slash. The result is origin-relative;
/// callers still run `relOk` / `relIsCluster`.
fn mountRel(path: []const u8) []const u8 {
    var rel = path;
    if (std.mem.startsWith(u8, rel, "/models/")) rel = rel["/models/".len..];
    if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
    return rel;
}

/// True when `rel` is refused at a CLI trust boundary (pin/verify/dupes).
/// Prints the same refusal those commands used to inline. Call before any
/// cache or origin I/O so a refused path cannot create dirs or read.
fn refuseCliRel(cmd: []const u8, rel: []const u8) bool {
    if (!store_mod.relOk(rel)) {
        // Suppressed under test like every usage print here, so the refusal
        // stays assertable without tripping the runner's error-log counter.
        // `/models/` strips to empty (the prefix convenience for the default
        // mountpoint) and `..` would write outside the tree: name which.
        if (!builtin.is_test) {
            if (rel.len == 0)
                std.debug.print("{s}: empty path (need a path relative to the mount, not /models itself)\n", .{cmd})
            else
                std.debug.print("{s}: refusing path outside the mount root\n", .{cmd});
        }
        return true;
    }
    // Same control-plane hide FUSE and peer HTTP apply.
    if (discover.relIsCluster(rel)) {
        if (!builtin.is_test) std.debug.print("{s}: refusing cluster control path\n", .{cmd});
        return true;
    }
    return false;
}

fn cmdPin(io: std.Io, gpa: std.mem.Allocator, opts: Opts, path: []const u8, on: bool) !u8 {
    const rel = mountRel(path);
    // Gate before ensureLayout so a refused path cannot create cache dirs.
    if (refuseCliRel(if (on) "pin" else "unpin", rel)) return 1;
    // Same process Io the daemon and cmdDupes use: Store recency and mutex
    // waits stay on the injected clock, not a second Threaded wall clock.
    var store = store_mod.Store.init(gpa, io, opts.origin orelse "", opts.cache, opts.piece);
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
    return if (printOut(io, gpa, "{s} {s}\n", .{ if (on) "pinned" else "unpinned", rel })) 0 else 1;
}

/// Verifies the cached pieces of one path against their trusted digests
/// (the origin piece-hash manifest, or hashes learned from origin fills and
/// write-throughs during a live daemon's run): every marked piece is read
/// back from the cache, rehashed, and compared. A piece whose bytes no
/// longer match (hole zeros from a crashed punch, bit rot, local tamper,
/// or a pre-upgrade poisoned cache) has its mark cleared so it refills from
/// a verified source instead of serving corrupt bytes. Daemon-less, like
/// pin: safe to run while the daemon is down; racy-but-harmless alongside
/// it (the daemon rebuilds entries from the sidecar, and a lost wipe only
/// costs a refill). The manifest it verifies against is the writer's
/// publication on the origin, so a file with no manifest (written outside
/// modelfs, or a pre-upgrade cache) reports "no trusted hashes" rather than
/// clearing anything: without a reference there is nothing to compare
/// against.
fn cmdVerify(io: std.Io, gpa: std.mem.Allocator, opts: Opts, path: []const u8) !u8 {
    const origin_raw = opts.origin orelse {
        std.debug.print("verify needs --origin (or MODELFS_ORIGIN)\n", .{});
        return 2;
    };
    const origin = resolveOriginDir(gpa, origin_raw) catch return 1;
    defer gpa.free(origin);
    const cache = opts.cache;
    if (cache.len == 0) {
        std.debug.print("verify needs --cache (or MODELFS_CACHE)\n", .{});
        return 2;
    }
    const rel = mountRel(path);
    if (refuseCliRel("verify", rel)) return 1;
    // Same process Io as cmdPin/cmdDupes: expectedHash retry instants and
    // recency stamps stay on the injected clock.
    var store = store_mod.Store.init(gpa, io, origin, cache, opts.piece);
    defer store.deinit();
    // The piece grid comes from the cache's own sidecar header, not a flag:
    // the daemon that wrote the marks chose the grid, and verifying against
    // a different one would misread every mark (a mismatched grid decodes as
    // an empty field, so verify would report nothing checked). A missing or
    // unreadable sidecar falls back to the default grid -- there is nothing
    // cached to verify anyway.
    if (store.sidecarPieceSize(rel)) |ps| store.piece_size = ps;
    const piece_size = store.piece_size;
    const layout_rc = store.ensureLayout();
    if (layout_rc != 0) {
        if (!builtin.is_test) std.log.err("cannot create cache dirs under {s} (errno {d})", .{ cache, -layout_rc });
        return 1;
    }
    // The piece grid and file size come from the same origin stat the daemon
    // reconciles against; a path that is not a regular origin file has no
    // cache identity to verify.
    var st: sys.c.struct_stat = undefined;
    const sstat = store.statOrigin(rel, &st);
    if (sstat != 0) {
        if (!builtin.is_test) std.log.err("origin stat failed for {s} (errno {d})", .{ rel, -sstat });
        return 1;
    }
    if ((st.st_mode & sys.c.S_IFMT) != sys.c.S_IFREG) {
        if (!builtin.is_test) std.debug.print("verify: {s} is not a regular file\n", .{rel});
        return 1;
    }
    const size = sys.sizeFromStat(st.st_size) orelse {
        if (!builtin.is_test) std.log.err("origin size unusable for {s}", .{rel});
        return 1;
    };
    const file = store.getIdentified(rel, size, store_mod.OriginId.fromStat(st), sys.monoSec(io)) catch |err| {
        if (!builtin.is_test) std.log.err("cache entry open failed for {s} ({t})", .{ rel, err });
        return 1;
    };
    defer store.releaseFile(file);

    var checked: u64 = 0;
    var mismatches: u64 = 0;
    const buf = gpa.alloc(u8, piece_size) catch {
        if (!builtin.is_test) std.log.err("verify buffer alloc failed for {s}", .{rel});
        return 1;
    };
    defer gpa.free(buf);
    const nbits = piece.count(size, piece_size);
    const now_ms = sys.monoMs(io);
    var i: u32 = 0;
    while (i < nbits) : (i += 1) {
        file.mu.lockUncancelable(io);
        const marked = file.bits.get(i);
        file.mu.unlock(io);
        if (!marked) continue;
        // expectedHash loads the origin manifest lazily; with no manifest
        // and no hashes learned from a live daemon, there is no reference
        // and nothing to verify (reported in the summary, not an error).
        const expect = store.expectedHash(file, i, now_ms) orelse continue;
        const ln = piece.len(size, i, piece_size);
        if (ln == 0) continue;
        const n = store.readCache(file, buf[0..ln], piece.offset(i, piece_size), sys.monoSec(io));
        if (n < 0 or @as(u64, @intCast(n)) != ln) {
            if (!builtin.is_test) std.log.warn("verify read failed for {s} piece {d}; leaving mark", .{ rel, i });
            continue;
        }
        var h: [piece.digest_len]u8 = undefined;
        piece.digest(buf[0..ln], &h);
        checked += 1;
        if (std.mem.eql(u8, &h, &expect)) continue;
        mismatches += 1;
        if (!builtin.is_test) std.log.warn("verify mismatch for {s} piece {d}; clearing cached mark", .{ rel, i });
        store.healPiece(file, i);
    }
    std.log.info("verified {s}: {d} piece(s) checked, {d} mismatch(es) cleared", .{ rel, checked, mismatches });
    if (!printOut(io, gpa, "verified {s}: {d} piece(s) checked, {d} mismatch(es) cleared{s}\n", .{
        rel,
        checked,
        mismatches,
        // A marked file with nothing checked means no trusted hash existed
        // (no manifest, or no origin fill this session): there was no
        // reference to compare against, which the operator should hear.
        if (checked == 0 and nbits > 0) " (no trusted hashes: no manifest or nothing cached)" else "",
    })) return 1;
    return if (mismatches == 0) 0 else 1;
}

test "badIdLine renders refused ids through the displayName echo gate" {
    // MODELFS_ID and --id can arrive from environments this process does not
    // control, so the refusal line must never echo the raw value: ESC (OSC
    // title escape) or CR/LF (forged follow-up lines) would inject into the
    // operator's terminal exactly like discover.hostname's own gate warns.
    var buf: [512]u8 = undefined;
    {
        const line = badIdLine(&buf, "\x1b]0;pwned\x07");
        try std.testing.expect(std.mem.find(u8, line, "\x1b") == null);
        try std.testing.expect(std.mem.find(u8, line, "\n2026-08-26 forged") == null);
        try std.testing.expect(std.mem.find(u8, line, "<name withheld: control bytes>") != null);
    }
    // The UTF-8 C1 spellings ride in as 0xC2 0x80..0xC2 0x9F and get the same
    // withholding as their raw C0 counterparts.
    {
        const line = badIdLine(&buf, "\xc2\x9d0;pwned\xc2\x9c");
        try std.testing.expect(std.mem.find(u8, line, "\xc2\x9d") == null);
        try std.testing.expect(std.mem.find(u8, line, "<name withheld: control bytes>") != null);
    }
    // U+2028 splits Unicode-aware terminals; the refusal must not echo it.
    {
        const line = badIdLine(&buf, "spark1\u{2028}ERROR forged");
        try std.testing.expect(std.mem.find(u8, line, "\u{2028}") == null);
        try std.testing.expect(std.mem.find(u8, line, "<name withheld: control bytes>") != null);
    }
    {
        const line = badIdLine(&buf, "spark1\u{202e}gnp");
        try std.testing.expect(std.mem.find(u8, line, "\u{202e}") == null);
        try std.testing.expect(std.mem.find(u8, line, "<name withheld: control bytes>") != null);
    }
    {
        const line = badIdLine(&buf, "spark1\u{200b}");
        try std.testing.expect(std.mem.find(u8, line, "\u{200b}") == null);
        try std.testing.expect(std.mem.find(u8, line, "<name withheld: control bytes>") != null);
    }
    {
        const line = badIdLine(&buf, "spark1\u{ad}");
        try std.testing.expect(std.mem.find(u8, line, "\u{ad}") == null);
        try std.testing.expect(std.mem.find(u8, line, "<name withheld: control bytes>") != null);
    }
    {
        const line = badIdLine(&buf, "spark1\u{e0100}");
        try std.testing.expect(std.mem.find(u8, line, "\u{e0100}") == null);
        try std.testing.expect(std.mem.find(u8, line, "<name withheld: control bytes>") != null);
    }
    // A printable but invalid id (quote) still names itself verbatim, so the
    // operator sees which value was refused.
    {
        const line = badIdLine(&buf, "a\"b");
        try std.testing.expect(std.mem.find(u8, line, "--id \"a\"b\":") != null);
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
    // u64 max + 1 is still 20 digits: the overflow is in the mul/add ladder,
    // not the longer 31-nines string above which fails earlier.
    try std.testing.expectError(error.BadSize, parseSize("18446744073709551616"));
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

test "unknownEnvName reports the lexicographically first typo" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    // Insert Z first so HashMap iteration would otherwise surface it
    // ahead of A. The refusal must name A: the env set, not insertion.
    try environ.put("MODELFS_ZZZ", "1");
    try environ.put("MODELFS_AAA", "1");
    try environ.put("PATH", "/usr/bin");
    try environ.put("MODELFS_CACHE", "/env/cache");
    try std.testing.expectEqualStrings("MODELFS_AAA", unknownEnvName(&environ).?);
    try std.testing.expectError(error.UnknownEnv, parseArgs(gpa, &environ, &.{"status"}));
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
        try std.testing.expect(std.mem.find(u8, line, "\x1b") == null);
        try std.testing.expect(std.mem.find(u8, line, "<name withheld: control bytes>") != null);
    }
    // The UTF-8 C1 spellings get the same withholding as their raw C0
    // counterparts.
    {
        const line = unknownEnvLine(&buf, "MODELFS_\xc2\x9d0;pwned\xc2\x9c");
        try std.testing.expect(std.mem.find(u8, line, "\xc2\x9d") == null);
        try std.testing.expect(std.mem.find(u8, line, "<name withheld: control bytes>") != null);
    }
    {
        const line = unknownEnvLine(&buf, "MODELFS_\u{2028}ERROR");
        try std.testing.expect(std.mem.find(u8, line, "\u{2028}") == null);
        try std.testing.expect(std.mem.find(u8, line, "<name withheld: control bytes>") != null);
    }
    {
        const line = unknownEnvLine(&buf, "MODELFS_\u{200b}X");
        try std.testing.expect(std.mem.find(u8, line, "\u{200b}") == null);
        try std.testing.expect(std.mem.find(u8, line, "<name withheld: control bytes>") != null);
    }
    {
        const line = unknownEnvLine(&buf, "MODELFS_\u{ad}X");
        try std.testing.expect(std.mem.find(u8, line, "\u{ad}") == null);
        try std.testing.expect(std.mem.find(u8, line, "<name withheld: control bytes>") != null);
    }
    {
        const line = unknownEnvLine(&buf, "MODELFS_\u{e0100}X");
        try std.testing.expect(std.mem.find(u8, line, "\u{e0100}") == null);
        try std.testing.expect(std.mem.find(u8, line, "<name withheld: control bytes>") != null);
    }
    // A printable misspelling still names itself verbatim, so the operator
    // sees which variable was refused.
    {
        const line = unknownEnvLine(&buf, "MODELFS_CACHEE");
        try std.testing.expect(std.mem.find(u8, line, "unknown environment variable MODELFS_CACHEE") != null);
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

    // CLOCK_MONOTONIC resets on reboot. A leftover stamp from the previous
    // boot is larger than now; saturating now-stamp used to read as age 0,
    // so pid reuse (common in the first seconds after boot) served a crash
    // leftover as live. A hostile/future mono_s has the same shape.
    {
        var reboot_buf: [192]u8 = undefined;
        const reboot_doc = try std.fmt.bufPrint(&reboot_buf, "{{\"id\":\"me\",\"pid\":{d},\"now_s\":{d},\"mono_s\":{d}}}\n", .{
            std.os.linux.getpid(),
            sys.nowSec(std.testing.io),
            sys.monoSec(std.testing.io) + 1000,
        });
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), reboot_doc));
        try std.testing.expectEqual(@as(u8, 1), try cmdStatus(std.testing.io, gpa, .{ .cache = cache_d }));

        var max_buf: [192]u8 = undefined;
        const max_doc = try std.fmt.bufPrint(&max_buf, "{{\"id\":\"me\",\"pid\":{d},\"now_s\":{d},\"mono_s\":{d}}}\n", .{
            std.os.linux.getpid(),
            sys.nowSec(std.testing.io),
            std.math.maxInt(i64),
        });
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), max_doc));
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

    // A planted link to a live-looking document elsewhere must not be
    // served as this cache's status: O_NOFOLLOW fails the open (ELOOP)
    // instead of following and printing the target.
    {
        var live_path_buf: [192]u8 = undefined;
        var sbuf: [192]u8 = undefined;
        const other = try std.fmt.bufPrint(&live_path_buf, "{s}/other.json", .{cache_d});
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, other), live_doc));
        try std.testing.expectEqual(@as(i32, 0), sys.c.unlink(try sys.toZ(&zbuf, fp)));
        // Basename target so a following open would serve other.json as
        // this cache's status; O_NOFOLLOW must fail the open instead.
        try std.testing.expectEqual(@as(i32, 0), sys.c.symlink("other.json", try sys.toZ(&sbuf, fp)));
        try std.testing.expectEqual(@as(u8, 1), try cmdStatus(std.testing.io, gpa, .{ .cache = cache_d }));
    }
}

test "cmdUpdate retires missing stale dead and requests handover for live" {
    const gpa = std.testing.allocator;
    var cb: [128]u8 = undefined;
    const cache_d = try sys.scratchDir(&cb, "modelfs-update-live");
    defer sys.deleteTree(std.testing.io, cache_d);

    var zbuf: [192]u8 = undefined;
    var pbuf: [160]u8 = undefined;
    const fp = try std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ cache_d, store_mod.status_file });

    {
        var err: std.ArrayList(u8) = .empty;
        defer err.deinit(gpa);
        captured_stderr = &err;
        defer captured_stderr = null;
        try std.testing.expectEqual(@as(u8, 1), try cmdUpdate(std.testing.io, gpa, .{ .cache = cache_d }));
        try std.testing.expect(std.mem.find(u8, err.items, "not running") != null);
    }

    {
        const dead_doc = "{\"id\":\"me\",\"pid\":-3,\"uptime_s\":99}\n";
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), dead_doc));
        var err: std.ArrayList(u8) = .empty;
        defer err.deinit(gpa);
        captured_stderr = &err;
        defer captured_stderr = null;
        try std.testing.expectEqual(@as(u8, 1), try cmdUpdate(std.testing.io, gpa, .{ .cache = cache_d }));
        try std.testing.expect(std.mem.find(u8, err.items, "not running") != null);
        try std.testing.expect(std.mem.find(u8, err.items, "exited pid") != null);
    }

    {
        const old_doc = try std.fmt.allocPrint(gpa, "{{\"id\":\"me\",\"pid\":{d},\"now_s\":{d}}}\n", .{ std.os.linux.getpid(), sys.nowSec(std.testing.io) - 121 });
        defer gpa.free(old_doc);
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), old_doc));
        var err: std.ArrayList(u8) = .empty;
        defer err.deinit(gpa);
        captured_stderr = &err;
        defer captured_stderr = null;
        try std.testing.expectEqual(@as(u8, 1), try cmdUpdate(std.testing.io, gpa, .{ .cache = cache_d }));
        try std.testing.expect(std.mem.find(u8, err.items, "not serving") != null);
        try std.testing.expect(std.mem.find(u8, err.items, "stale") != null);
    }

    const script = try std.fmt.allocPrint(gpa,
        \\trap 'cp "{s}/{s}" "{s}/{s}"' USR2
        \\touch "{s}/child.ready"
        \\while [ ! -f "{s}/{s}" ]; do
        \\  if [ -f "{s}/{s}" ]; then cp "{s}/{s}" "{s}/{s}"; break; fi
        \\  sleep 0.05
        \\done
        \\while true; do sleep 3600; done
    , .{
        cache_d,           handover.req_file, cache_d,           handover.ack_file,
        cache_d,           cache_d,           handover.ack_file, cache_d,
        handover.req_file, cache_d,           handover.req_file, cache_d,
        handover.ack_file,
    });
    defer gpa.free(script);
    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "sh", "-c", script },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(std.testing.io);

    var ready_buf: [192]u8 = undefined;
    const ready = try std.fmt.bufPrint(&ready_buf, "{s}/child.ready", .{cache_d});
    var waited: u32 = 0;
    while (waited < 2000) : (waited += 20) {
        var stbuf: sys.c.struct_stat = undefined;
        if (sys.statPath(try sys.toZ(&zbuf, ready), &stbuf) == 0) break;
        sys.sleepMs(std.testing.io, 20);
    }
    const child_pid: i32 = child.id.?;
    const live_doc = try std.fmt.allocPrint(gpa, "{{\"id\":\"me\",\"pid\":{d},\"now_s\":{d},\"mono_s\":{d}}}\n", .{
        child_pid,
        sys.nowSec(std.testing.io),
        sys.monoSec(std.testing.io),
    });
    defer gpa.free(live_doc);
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, fp), live_doc));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    captured_stdout = &out;
    defer captured_stdout = null;
    try std.testing.expectEqual(@as(u8, 0), try cmdUpdate(std.testing.io, gpa, .{ .cache = cache_d }));
    try std.testing.expect(std.mem.find(u8, out.items, "updated pid") != null);
    var reqp: [192]u8 = undefined;
    const req_path = try std.fmt.bufPrint(&reqp, "{s}/{s}", .{ cache_d, handover.req_file });
    const req_blob = try sys.readFileAlloc(gpa, try sys.toZ(&zbuf, req_path), 4096);
    defer gpa.free(req_blob);
    try std.testing.expect(std.mem.find(u8, req_blob, "\"bin\"") != null);
    try std.testing.expect(std.mem.find(u8, req_blob, "\"token\"") != null);
}

const seed_status_live = fuzzcorpus.entry("{\"id\":\"me\",\"pid\":1,\"uptime_s\":1,\"peers\":0,\"piece\":16,\"inflight\":0,\"now_s\":1710000060,\"mono_s\":100,\"stats\":{}}\n");
const seed_status_pid_only = fuzzcorpus.entry("{\"pid\":1}");
const seed_status_now_only = fuzzcorpus.entry("{\"pid\":1,\"now_s\":1710000060}");
const seed_status_missing_pid = fuzzcorpus.entry("{\"id\":\"me\",\"now_s\":1}");
const seed_status_truncated = fuzzcorpus.entry("{\"pid\":");
const seed_status_not_json = fuzzcorpus.entry("not json at all");
const seed_status_now_min = fuzzcorpus.entry("{\"pid\":1,\"now_s\":-9223372036854775808}");
const seed_status_mono_max = fuzzcorpus.entry("{\"pid\":1,\"now_s\":1,\"mono_s\":9223372036854775807}");
const seed_status_dup_pid = fuzzcorpus.entry("{\"pid\":1,\"pid\":2,\"now_s\":0}");
const seed_status_float_pid = fuzzcorpus.entry("{\"pid\":1.5}");
const seed_status_string_pid = fuzzcorpus.entry("{\"pid\":\"1\"}");
const seed_status_deep_unknown = fuzzcorpus.entry("{\"pid\":1,\"z\":[[[[[[[[]]]]]]]]}");
const seed_status_empty = fuzzcorpus.entry("");
const seed_status_null_stamps = fuzzcorpus.entry("{\"pid\":1,\"now_s\":null,\"mono_s\":null}");

const fuzz_status_corpus = [_][]const u8{
    &seed_status_live,
    &seed_status_pid_only,
    &seed_status_now_only,
    &seed_status_missing_pid,
    &seed_status_truncated,
    &seed_status_not_json,
    &seed_status_now_min,
    &seed_status_mono_max,
    &seed_status_dup_pid,
    &seed_status_float_pid,
    &seed_status_string_pid,
    &seed_status_deep_unknown,
    &seed_status_empty,
    &seed_status_null_stamps,
};

/// Leftover status.json is untrusted twice over: a crashed daemon leaves
/// whatever it last published, and a local uid that can write the cache
/// root can plant a document. cmdStatus must fail closed on anything that
/// is not a liveness object, and statusAgeSecs must not overflow on a
/// hostile i64 stamp. The harness asserts fail-closed parsing, determinism
/// across re-reads, and that age is the absolute monotonic gap when
/// mono_s is present (the reboot leftover / future-stamp case).
fn fuzzStatusLivenessOne(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var doc_buf: [512]u8 = undefined;
    const json = doc_buf[0..smith.slice(&doc_buf)];
    const parsed = std.json.parseFromSlice(StatusLiveness, gpa, json, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const live = parsed.value;

    {
        const again = try std.json.parseFromSlice(StatusLiveness, gpa, json, .{ .ignore_unknown_fields = true });
        defer again.deinit();
        try std.testing.expectEqual(live.pid, again.value.pid);
        try std.testing.expectEqual(live.now_s, again.value.now_s);
        try std.testing.expectEqual(live.mono_s, again.value.mono_s);
    }

    const age = statusAgeSecs(std.testing.io, live);
    if (live.mono_s) |stamp| {
        const now = sys.monoSec(std.testing.io);
        const want = if (stamp > now) stamp -| now else now -| stamp;
        try std.testing.expectEqual(want, age.?);
        try std.testing.expect(age.? >= 0);
    } else if (live.now_s) |stamp| {
        try std.testing.expectEqual(sys.nowSec(std.testing.io) -| stamp, age.?);
    } else {
        try std.testing.expect(age == null);
    }
}

test "fuzz status.json liveness parsing fails closed and ages without overflow" {
    try std.testing.fuzz({}, fuzzStatusLivenessOne, .{ .corpus = &fuzz_status_corpus });
}

test "ensureDirReal creates a missing dir and refuses a file" {
    const gpa = std.testing.allocator;
    var cb: [128]u8 = undefined;
    const d = try sys.scratchDir(&cb, "modelfs-ensuredir");
    defer sys.deleteTree(std.testing.io, d);

    var zb: [256]u8 = undefined;
    var fb: [160]u8 = undefined;
    const fp = try std.fmt.bufPrint(&fb, "{s}/regular", .{d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zb, fp), "x"));
    try std.testing.expectError(error.NotDir, ensureDirReal(gpa, fp, "cache"));

    const existing = try ensureDirReal(gpa, d, "cache");
    defer gpa.free(existing);
    try std.testing.expect(pathIsDir(try sys.toZ(&zb, existing)));

    var nb: [160]u8 = undefined;
    const missing = try std.fmt.bufPrint(&nb, "{s}/new-cache", .{d});
    const created = try ensureDirReal(gpa, missing, "cache");
    defer gpa.free(created);
    try std.testing.expect(pathIsDir(try sys.toZ(&zb, created)));
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
        try std.testing.expect(std.mem.find(u8, out.items, "no cluster leases") != null);
        try std.testing.expect(std.mem.find(u8, out.items, discover.cluster_dir) != null);
        try std.testing.expect(std.mem.find(u8, out.items, "spark") == null);
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

    // A regular file at origin/.cluster is unreadable, not an empty
    // cluster: listing must fail instead of printing "no cluster leases".
    // The reason is on stderr (operator diagnostic), not stdout (the
    // listing a pipe consumes).
    var zb2: [256]u8 = undefined;
    var fb2: [192]u8 = undefined;
    const cluster_fp = try std.fmt.bufPrint(&fb2, "{s}/.cluster", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zb2, cluster_fp), "not-a-dir"));
    var out2: std.ArrayList(u8) = .empty;
    defer out2.deinit(gpa);
    captured_stdout = &out2;
    defer captured_stdout = null;
    try std.testing.expectEqual(@as(u8, 1), try cmdPeers(std.testing.io, gpa, .{ .origin = origin_d }));
    try std.testing.expectEqual(@as(usize, 0), out2.items.len);
}

test "verify and dupes refuse a file origin instead of scanning empty" {
    const gpa = std.testing.allocator;
    var cb: [128]u8 = undefined;
    const scratch = try sys.scratchDir(&cb, "modelfs-origin-file");
    defer sys.deleteTree(std.testing.io, scratch);
    var zb: [256]u8 = undefined;
    var fb: [160]u8 = undefined;
    const file_origin = try std.fmt.bufPrint(&fb, "{s}/regular", .{scratch});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zb, file_origin), "x"));
    var nb: [160]u8 = undefined;
    const absent = try std.fmt.bufPrint(&nb, "{s}/does-not-exist", .{scratch});

    // dupes --all used to opendir-fail and print "no manifests to compare"
    // with exit 0, the same reading as a healthy empty origin.
    try std.testing.expectEqual(@as(u8, 1), try cmdDupesAll(std.testing.io, gpa, .{ .origin = file_origin }));
    try std.testing.expectEqual(@as(u8, 1), try cmdDupesAll(std.testing.io, gpa, .{ .origin = absent }));
    try std.testing.expectEqual(@as(u8, 1), try cmdDupes(std.testing.io, gpa, .{ .origin = file_origin }, &.{"a.bin"}));
    try std.testing.expectEqual(@as(u8, 1), try cmdDupes(std.testing.io, gpa, .{ .origin = absent }, &.{"a.bin"}));
    try std.testing.expectEqual(@as(u8, 1), try cmdVerify(std.testing.io, gpa, .{ .origin = file_origin, .cache = scratch, .piece = 16 }, "m.bin"));
    try std.testing.expectEqual(@as(u8, 1), try cmdVerify(std.testing.io, gpa, .{ .origin = absent, .cache = scratch, .piece = 16 }, "m.bin"));
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
    // Leading-dot names cannot be a validId lease; the shared walk skips them
    // the way Catalog.refresh already did, so they must not appear here.
    const hidden_fp = try std.fmt.bufPrint(&pbuf, "{s}/.hidden.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, hidden_fp), "{\"id\":\"hidden\",\"until\":4102444800,\"addrs\":[]}"));

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

test "cmdPeers lists lease addrs by ip then port, not document order" {
    const gpa = std.testing.allocator;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&cb, "modelfs-peers-addr-order");
    defer sys.deleteTree(std.testing.io, origin_d);
    var cbuf: [160]u8 = undefined;
    const cluster_d = try std.fmt.bufPrint(&cbuf, "{s}/.cluster", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(cluster_d, 0o755));

    var zbuf: [256]u8 = undefined;
    var pbuf: [192]u8 = undefined;
    const live_fp = try std.fmt.bufPrint(&pbuf, "{s}/spark.json", .{cluster_d});
    // Scrambled addrs: document order is .9:18081 then .1:18080. Listing
    // must still be ip then port, matching the published lease document.
    const live = "{\"id\":\"spark\",\"until\":4102444800,\"addrs\":[{\"ip\":\"10.0.0.9\",\"port\":18081,\"mbps\":0},{\"ip\":\"10.0.0.1\",\"port\":18080,\"mbps\":1}]}";
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, live_fp), live));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    captured_stdout = &out;
    defer captured_stdout = null;
    try std.testing.expectEqual(@as(u8, 0), try cmdPeers(std.testing.io, gpa, .{ .origin = origin_d }));
    try std.testing.expectEqualStrings(
        "spark (until=4102444800, live)\n  -> 10.0.0.1:18080 (speed=1mbps)\n  -> 10.0.0.9:18081 (speed=0mbps)\n",
        out.items,
    );
}

test "cmdPeers skips a planted lease symlink instead of ingesting its target" {
    const gpa = std.testing.allocator;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&cb, "modelfs-peers-leasesym");
    defer sys.deleteTree(std.testing.io, origin_d);
    var cbuf: [160]u8 = undefined;
    const cluster_d = try std.fmt.bufPrint(&cbuf, "{s}/.cluster", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(cluster_d, 0o755));

    var zbuf: [192]u8 = undefined;
    var sbuf: [192]u8 = undefined;
    var pbuf: [192]u8 = undefined;
    const live = "{\"id\":\"evil\",\"until\":4102444800,\"addrs\":[{\"ip\":\"10.9.9.9\",\"port\":18080,\"mbps\":0}]}";
    const outside_fp = try std.fmt.bufPrint(&pbuf, "{s}/outside.lease", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, outside_fp), live));
    const planted_fp = try std.fmt.bufPrint(&pbuf, "{s}/evil.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.c.symlink("outside.lease", try sys.toZ(&sbuf, planted_fp)));
    const healthy_fp = try std.fmt.bufPrint(&pbuf, "{s}/spark9.json", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zbuf, healthy_fp), "{\"id\":\"spark9\",\"until\":4102444800,\"addrs\":[]}"));

    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    try std.testing.expectEqual(@as(u8, 0), try cmdPeers(std.testing.io, gpa, .{ .origin = origin_d }));
}

test "mountRel strips the default mount prefix" {
    try std.testing.expectEqualStrings("gguf/a.gguf", mountRel("/models/gguf/a.gguf"));
    try std.testing.expectEqualStrings("gguf/a.gguf", mountRel("gguf/a.gguf"));
    try std.testing.expectEqualStrings("a.bin", mountRel("/a.bin"));
    try std.testing.expectEqualStrings("", mountRel("/models/"));
    try std.testing.expectEqualStrings(".cluster/spark1.json", mountRel("/models/.cluster/spark1.json"));
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

    // `.cluster` is the discovery control plane: FUSE and peer HTTP hide it,
    // so pin must not mark those names either. Prefix, not substring.
    try std.testing.expectEqual(@as(u8, 1), try cmdPin(std.testing.io, gpa, .{ .cache = cache_d }, ".cluster/spark1.json", true));
    try std.testing.expectEqual(@as(u8, 1), try cmdPin(std.testing.io, gpa, .{ .cache = cache_d }, "/models/.cluster", true));
    const cluster_pin = try std.fmt.bufPrint(&pbuf, "{s}/pin/.cluster/spark1.json", .{cache_d});
    try std.testing.expect(sys.statPath(try sys.toZ(&zb, cluster_pin), &stbuf) != 0);
    try std.testing.expectEqual(@as(u8, 0), try cmdPin(std.testing.io, gpa, .{ .cache = cache_d }, ".clusterfoo", true));
    const clusterfoo_pin = try std.fmt.bufPrint(&pbuf, "{s}/pin/.clusterfoo", .{cache_d});
    try std.testing.expect(sys.statPath(try sys.toZ(&zb, clusterfoo_pin), &stbuf) == 0);

    // A refused path must not create cache layout.
    {
        var nb: [128]u8 = undefined;
        const cache2 = try sys.scratchDir(&nb, "modelfs-pin-refuse");
        defer sys.deleteTree(std.testing.io, cache2);
        try std.testing.expectEqual(@as(u8, 1), try cmdPin(std.testing.io, gpa, .{ .cache = cache2 }, "../escape.bin", true));
        const pin_dir = try std.fmt.bufPrint(&pbuf, "{s}/pin", .{cache2});
        try std.testing.expect(sys.statPath(try sys.toZ(&zb, pin_dir), &stbuf) != 0);
        try std.testing.expectEqual(@as(u8, 1), try cmdPin(std.testing.io, gpa, .{ .cache = cache2 }, ".cluster/spark1.json", true));
        try std.testing.expect(sys.statPath(try sys.toZ(&zb, pin_dir), &stbuf) != 0);
    }

    // Unpin removes the artifact so the file becomes cullable again.
    try std.testing.expectEqual(@as(u8, 0), try cmdPin(std.testing.io, gpa, .{ .cache = cache_d }, "gguf/big.gguf", false));
    try std.testing.expect(sys.statPath(try sys.toZ(&zb, pin_fp), &stbuf) != 0);
}

test "cmdVerify checks cached pieces against the origin manifest and clears mismatches" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    var cb: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-verify");
    defer sys.deleteTree(std.testing.io, origin_d);
    const cache_d = try sys.scratchDir(&cb, "modelfs-c-verify");
    defer sys.deleteTree(std.testing.io, cache_d);

    var zb: [256]u8 = undefined;
    var pbuf: [256]u8 = undefined;
    const origin_fp = try std.fmt.bufPrint(&pbuf, "{s}/m.bin", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zb, origin_fp), "0123456789abcdef"));
    const opts = Opts{ .origin = origin_d, .cache = cache_d, .piece = 16 };

    // Without a manifest there is no trusted reference: nothing to clear,
    // and the summary reports zero checked pieces (exit 0).
    try std.testing.expectEqual(@as(u8, 0), try cmdVerify(std.testing.io, gpa, opts, "m.bin"));

    // Publish the manifest the way a writer's release does: fill the cache
    // from origin, then publish the learned hashes.
    {
        var store = store_mod.Store.init(gpa, std.testing.io, origin_d, cache_d, 16);
        defer store.deinit();
        try std.testing.expectEqual(@as(i32, 0), store.ensureLayout());
        const f = try store.get("m.bin", 16, sys.monoSec(std.testing.io));
        defer store.releaseFile(f);
        var h: [piece.digest_len]u8 = undefined;
        piece.digest("0123456789abcdef", &h);
        try std.testing.expectEqual(@as(u32, 16), (try store.beginFill(f, 0, sys.monoSec(std.testing.io))).len);
        try std.testing.expectEqual(@as(i32, 0), store.completeFill(f, 0, "0123456789abcdef", h, sys.monoSec(std.testing.io)));
        store.publishManifest(f);
    }

    // Intact cache: verified, zero mismatches, exit 0.
    try std.testing.expectEqual(@as(u8, 0), try cmdVerify(std.testing.io, gpa, opts, "m.bin"));

    // Corrupt the cached piece; verify must find the mismatch, clear the
    // mark, and exit 1 so scripts can react. A mismatched --piece must not
    // decode the sidecar as empty and skip the check: the grid is the
    // daemon's recorded header, not the flag.
    var dpb: [256]u8 = undefined;
    const dp = try std.fmt.bufPrint(&dpb, "{s}/data/m.bin", .{cache_d});
    const cfd = sys.open(try sys.toZ(&zb, dp), sys.c.O_WRONLY, 0);
    try std.testing.expect(cfd >= 0);
    defer sys.close(cfd);
    const junk = [_]u8{0xAA} ** 16;
    try std.testing.expectEqual(@as(isize, 16), sys.pwriteAll(cfd, &junk, 0));
    try std.testing.expectEqual(@as(u8, 1), try cmdVerify(std.testing.io, gpa, .{
        .origin = origin_d,
        .cache = cache_d,
        .piece = 4096,
    }, "m.bin"));

    // The cleared mark persisted: a second verify finds nothing to check
    // (the piece refills from a verified source on the next read).
    try std.testing.expectEqual(@as(u8, 0), try cmdVerify(std.testing.io, gpa, opts, "m.bin"));

    // Path gates match pin's: escapes and control-plane names are refused
    // before any cache or origin I/O.
    try std.testing.expectEqual(@as(u8, 1), try cmdVerify(std.testing.io, gpa, opts, "../escape.bin"));
    try std.testing.expectEqual(@as(u8, 1), try cmdVerify(std.testing.io, gpa, opts, ".cluster/spark1.json"));
    try std.testing.expectEqual(@as(u8, 2), try cmdVerify(std.testing.io, gpa, .{ .cache = cache_d, .piece = 16 }, "m.bin"));
}

/// Whole-store duplicate telemetry: scans every piece-hash manifest under
/// origin/.cluster/manifests and reports aggregate overlap -- total
/// manifests, total pieces, byte-identical pairs, and pairs sharing any
/// digest. Manifests are keyed by `blake3(rel)` hex, so the scan cannot
/// name the files behind them; the aggregates are what the dedup decision
/// needs (design.md section 14), and the per-path form `modelfs dupes
/// <rel>...` names specific pairs. Reads manifests only, never model
/// bytes. A missing manifests dir is an empty scan, not an error; an
/// unreadable one (EIO, ENOTDIR, EACCES) exits 1 like `modelfs peers` on
/// an unreadable `.cluster`.
fn cmdDupesAll(io: std.Io, gpa: std.mem.Allocator, opts: Opts) !u8 {
    const origin_raw = opts.origin orelse {
        std.debug.print("dupes needs --origin (or MODELFS_ORIGIN)\n", .{});
        return 2;
    };
    const origin = resolveOriginDir(gpa, origin_raw) catch return 1;
    defer gpa.free(origin);
    var store = store_mod.Store.init(gpa, io, origin, opts.cache, opts.piece);
    defer store.deinit();
    var dbuf: [sys.c.PATH_MAX]u8 = undefined;
    const dirz = store.manifestsDirPath(&dbuf) catch {
        if (!builtin.is_test) std.log.err("manifest dir path too long at {s}", .{origin});
        return 1;
    };
    // O_NOFOLLOW like lease walks: a planted .cluster/manifests symlink
    // must not list or parse names under its target.
    const dir = sys.opendirNoFollow(dirz) orelse {
        const e = sys.errno();
        if (e == sys.c.ENOENT) {
            // Missing manifests dir is a fresh/empty origin, not an error:
            // same exit-0 empty report as a dir with no files.
            if (!printOut(io, gpa, "no manifests to compare\n", .{})) return 1;
            return 0;
        }
        // EIO/ENOTDIR/EACCES: the origin is there but manifests cannot be
        // listed. Printing the empty-scan line would look like a healthy
        // store of zero, which is the wrong incident start. Same split
        // walkLeases / cmdPeers apply to origin/.cluster. Stdout is the
        // report a pipe consumes; the reason belongs on stderr.
        if (!builtin.is_test)
            std.debug.print("cannot read manifests at {s}/{s} (errno {d})\n", .{ origin, store_mod.Store.manifests_dir, e });
        return 1;
    };
    defer sys.closedir(dir);

    var manifests: std.ArrayList(piece.Manifest) = .empty;
    var sorted: std.ArrayList([]piece.ManifestEntry) = .empty;
    defer {
        for (manifests.items) |m| gpa.free(m.entries);
        manifests.deinit(gpa);
        for (sorted.items) |s| gpa.free(s);
        sorted.deinit(gpa);
    }
    var total_pieces: u64 = 0;
    while (sys.readdir(dir)) |ent| {
        const name = sys.dirName(ent);
        if (name.len == 0 or name[0] == '.') continue;
        // Names come off shared NFS storage. Skip-warns go through
        // displayName so a planted CR/LF or terminal escape cannot forge
        // journal lines; lease walks already apply the same gate.
        var fbuf: [sys.c.PATH_MAX]u8 = undefined;
        const fp = sys.joinZ(&fbuf, std.mem.span(dirz), name) catch continue;
        var open_errno: i32 = 0;
        const blob = sys.readFileAllocNoFollowOpenErrno(gpa, fp, store_mod.Store.max_manifest_bytes, &open_errno) catch |err| switch (err) {
            error.OpenFailed => {
                if (open_errno != sys.c.ENOENT)
                    if (!builtin.is_test) std.log.warn("manifest open failed for {s} (errno {d}); skipping", .{ discover.displayName(name), open_errno });
                continue;
            },
            else => {
                if (!builtin.is_test) std.log.warn("manifest read failed for {s}: {t}; skipping", .{ discover.displayName(name), err });
                continue;
            },
        };
        defer gpa.free(blob);
        const m = piece.manifestDecode(gpa, blob) catch {
            if (!builtin.is_test) std.log.warn("corrupt piece-hash manifest {s}; skipping", .{discover.displayName(name)});
            continue;
        } orelse continue;
        total_pieces += m.entries.len;
        manifests.append(gpa, m) catch return 1;
        sorted.append(gpa, piece.digestSorted(gpa, m.entries) catch return 1) catch return 1;
    }

    if (manifests.items.len == 0) {
        if (!printOut(io, gpa, "no manifests to compare\n", .{})) return 1;
        return 0;
    }
    var identical_pairs: u64 = 0;
    var shared_pairs: u64 = 0;
    for (manifests.items, 0..) |a, ai| {
        for (manifests.items[ai + 1 ..], 0..) |b, bj| {
            const ov = piece.manifestOverlapPrepared(a, b, sorted.items[ai], sorted.items[ai + 1 + bj]);
            if (ov.identical) identical_pairs += 1;
            if (ov.shared > 0) shared_pairs += 1;
        }
    }
    if (!printOut(io, gpa, "scanned {d} manifest(s), {d} piece(s) total\n", .{ manifests.items.len, total_pieces })) return 1;
    if (!printOut(io, gpa, "byte-identical pairs: {d}\n", .{identical_pairs})) return 1;
    if (!printOut(io, gpa, "pairs sharing any digest: {d}\n", .{shared_pairs})) return 1;
    return 0;
}

/// The dedup-telemetry command: compares piece-hash manifests across
/// paths and reports how much content they share. The manifest store on
/// the origin (`.cluster/manifests/<hex>`) is already a duplicate-content
/// index -- every ingested file's piece digests live there -- so this scan
/// reads manifests only, never the model bytes, and is cheap even for
/// hundreds of GB of files. This is the measured answer to "do we want
/// dedup?" (design.md section 14): aligned overlap is what a same-size
/// re-export would share, shifted overlap is what only CDC could recover,
/// and byte-identical files are outright duplicates. A path with no
/// manifest (never ingested through modelfs, or never fully hashed) is
/// reported as such and contributes nothing.
fn cmdDupes(io: std.Io, gpa: std.mem.Allocator, opts: Opts, paths: []const []const u8) !u8 {
    const origin_raw = opts.origin orelse {
        std.debug.print("dupes needs --origin (or MODELFS_ORIGIN)\n", .{});
        return 2;
    };
    const origin = resolveOriginDir(gpa, origin_raw) catch return 1;
    defer gpa.free(origin);
    // Gate every rel before any origin I/O (same refusals as verify): a
    // bad path must not create cache dirs or read anything.
    for (paths) |path| {
        if (refuseCliRel("dupes", mountRel(path))) return 1;
    }
    var store = store_mod.Store.init(gpa, io, origin, opts.cache, opts.piece);
    defer store.deinit();

    const File = struct {
        rel: []const u8,
        manifest: piece.Manifest,
        /// Digest-sorted copy of manifest.entries, built once per file so
        /// the pair scan below does not re-sort per pair.
        by_digest: []piece.ManifestEntry,
    };
    var files: std.ArrayList(File) = .empty;
    defer {
        for (files.items) |f| {
            gpa.free(f.by_digest);
            gpa.free(f.manifest.entries);
        }
        files.deinit(gpa);
    }
    for (paths) |path| {
        const rel = mountRel(path);
        var mbuf: [sys.c.PATH_MAX]u8 = undefined;
        const mp = store.manifestPath(&mbuf, rel) catch {
            if (!builtin.is_test) std.log.err("manifest path too long for {s}", .{rel});
            return 1;
        };
        var open_errno: i32 = 0;
        const blob = sys.readFileAllocNoFollowOpenErrno(gpa, mp, store_mod.Store.max_manifest_bytes, &open_errno) catch |err| switch (err) {
            error.OpenFailed => {
                if (open_errno == sys.c.ENOENT) {
                    if (!builtin.is_test)
                        std.debug.print("{s}: no piece-hash manifest (not ingested through modelfs, or never fully hashed)\n", .{rel});
                } else {
                    if (!builtin.is_test) std.log.err("manifest open failed for {s} (errno {d})", .{ rel, open_errno });
                }
                continue;
            },
            else => {
                if (!builtin.is_test) std.log.err("manifest read failed for {s}: {t}", .{ rel, err });
                continue;
            },
        };
        defer gpa.free(blob);
        const m = piece.manifestDecode(gpa, blob) catch {
            if (!builtin.is_test) std.log.err("corrupt piece-hash manifest for {s}", .{rel});
            continue;
        } orelse {
            if (!builtin.is_test) std.log.err("unusable piece-hash manifest for {s}", .{rel});
            continue;
        };
        files.append(gpa, .{
            .rel = rel,
            .manifest = m,
            .by_digest = piece.digestSorted(gpa, m.entries) catch return 1,
        }) catch return 1;
    }

    if (files.items.len == 0) {
        // Same empty-report result as cmdDupesAll: the "nothing to compare"
        // line is the report, so it rides stdout where a pipe sees it, not
        // stderr beside the per-path diagnostics.
        if (!printOut(io, gpa, "no manifests to compare\n", .{})) return 1;
        return 0;
    }
    for (files.items) |f| {
        if (!printOut(io, gpa, "{s}: {d} piece(s), {d} grid, {d} bytes\n", .{
            f.rel,
            f.manifest.entries.len,
            f.manifest.piece_size,
            f.manifest.file_size,
        })) return 1;
    }
    for (files.items, 0..) |a, ai| {
        for (files.items[ai + 1 ..]) |b| {
            const ov = piece.manifestOverlapPrepared(a.manifest, b.manifest, a.by_digest, b.by_digest);
            // Shifted = digests shared outside the aligned positions: the
            // only overlap CDC (Level 3) could recover.
            const shifted = ov.shared -| ov.aligned;
            if (!printOut(io, gpa, "overlap {s} vs {s}: {d}/{d} aligned, {d} shared digest(s), {d} shifted{s}\n", .{
                a.rel,
                b.rel,
                ov.aligned,
                @min(a.manifest.entries.len, b.manifest.entries.len),
                ov.shared,
                shifted,
                if (ov.identical) " -- byte-identical" else "",
            })) return 1;
        }
    }
    return 0;
}

test "cmdDupes reports manifest overlap and gates its paths" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-dupes");
    defer sys.deleteTree(std.testing.io, origin_d);

    const h0 = [_]u8{0x11} ** piece.digest_len;
    const h1 = [_]u8{0x22} ** piece.digest_len;
    var a_entries = [_]piece.ManifestEntry{
        .{ .idx = 0, .hash = h0 },
        .{ .idx = 1, .hash = h1 },
    };
    var b_entries = [_]piece.ManifestEntry{
        .{ .idx = 0, .hash = h0 },
        .{ .idx = 1, .hash = h1 },
    };
    // Two manifests sharing every digest: a byte-identical pair under two
    // names -- exactly the duplicate the telemetry exists to surface.
    try writeManifestForTest(gpa, origin_d, "a.bin", 16, 32, &a_entries);
    try writeManifestForTest(gpa, origin_d, "b.bin", 16, 32, &b_entries);
    const opts = Opts{ .origin = origin_d };
    try std.testing.expectEqual(@as(u8, 0), try cmdDupes(std.testing.io, gpa, opts, &.{ "a.bin", "b.bin" }));
    // A path with no manifest is reported, not an error.
    try std.testing.expectEqual(@as(u8, 0), try cmdDupes(std.testing.io, gpa, opts, &.{ "a.bin", "missing.bin" }));
    // All paths missing is the same empty report as --all: the line lands on
    // stdout (a pipe sees it), not stderr beside the diagnostics.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    captured_stdout = &out;
    defer captured_stdout = null;
    try std.testing.expectEqual(@as(u8, 0), try cmdDupes(std.testing.io, gpa, opts, &.{"missing.bin"}));
    try std.testing.expect(std.mem.find(u8, out.items, "no manifests to compare") != null);
    // Path gates match verify's; a missing origin is a usage error.
    try std.testing.expectEqual(@as(u8, 1), try cmdDupes(std.testing.io, gpa, opts, &.{"../escape.bin"}));
    try std.testing.expectEqual(@as(u8, 1), try cmdDupes(std.testing.io, gpa, opts, &.{".cluster/spark1.json"}));
    try std.testing.expectEqual(@as(u8, 2), try cmdDupes(std.testing.io, gpa, .{}, &.{"a.bin"}));
}

/// Writes a piece-hash manifest for rel directly under origin's
/// .cluster/manifests/, the way a writer's release would (test helper).
fn writeManifestForTest(gpa: std.mem.Allocator, origin: []const u8, rel: []const u8, ps: u32, fs: u64, entries: []const piece.ManifestEntry) !void {
    var mname: [2 * piece.digest_len]u8 = undefined;
    const name = piece.manifestName(rel, &mname);
    var mb: [256]u8 = undefined;
    var tb: [256]u8 = undefined;
    var zb: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&mb, "{s}/.cluster/manifests", .{origin});
    _ = sys.mkdirAll(dir, 0o755);
    const fp = try std.fmt.bufPrint(&tb, "{s}/{s}", .{ dir, name });
    const need = piece.manifestLen(entries.len);
    const blob = try gpa.alloc(u8, need);
    defer gpa.free(blob);
    const enc = try piece.manifestEncode(ps, fs, entries, blob);
    try std.testing.expectEqual(@as(i32, 0), sys.writeFileNoFollow(try sys.toZ(&zb, fp), enc));
}

test "cmdDupesAll scans the manifest store and --all is dupes-only" {
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-dupes-all");
    defer sys.deleteTree(std.testing.io, origin_d);

    const h0 = [_]u8{0x11} ** piece.digest_len;
    const h1 = [_]u8{0x22} ** piece.digest_len;
    const h2 = [_]u8{0x33} ** piece.digest_len;
    var a_entries = [_]piece.ManifestEntry{
        .{ .idx = 0, .hash = h0 },
        .{ .idx = 1, .hash = h1 },
    };
    var c_entries = [_]piece.ManifestEntry{
        .{ .idx = 0, .hash = h2 },
        .{ .idx = 1, .hash = h1 },
    };
    try writeManifestForTest(gpa, origin_d, "a.bin", 16, 32, &a_entries);
    try writeManifestForTest(gpa, origin_d, "b.bin", 16, 32, &a_entries); // byte-identical to a
    try writeManifestForTest(gpa, origin_d, "c.bin", 16, 32, &c_entries); // shares one digest with a/b

    const opts = Opts{ .origin = origin_d };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    captured_stdout = &out;
    defer captured_stdout = null;
    try std.testing.expectEqual(@as(u8, 0), try cmdDupesAll(std.testing.io, gpa, opts));
    const report = out.items;
    try std.testing.expect(std.mem.find(u8, report, "scanned 3 manifest(s), 6 piece(s) total") != null);
    try std.testing.expect(std.mem.find(u8, report, "byte-identical pairs: 1") != null);
    // a-b (identical + shared), a-c (shared), b-c (shared) = 3 shared pairs.
    try std.testing.expect(std.mem.find(u8, report, "pairs sharing any digest: 3") != null);

    // A missing manifests dir is an empty scan, not an error.
    var nb: [128]u8 = undefined;
    const empty_origin = try sys.scratchDir(&nb, "modelfs-o-dupes-empty");
    defer sys.deleteTree(std.testing.io, empty_origin);
    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try cmdDupesAll(std.testing.io, gpa, .{ .origin = empty_origin }));
    try std.testing.expect(std.mem.find(u8, out.items, "no manifests to compare") != null);

    // A regular file at origin/.cluster/manifests is unreadable, not an
    // empty scan: must fail instead of printing "no manifests to compare"
    // on stdout (the report a pipe consumes).
    var zb: [256]u8 = undefined;
    var cb: [192]u8 = undefined;
    const cluster_d = try std.fmt.bufPrint(&cb, "{s}/.cluster", .{empty_origin});
    try std.testing.expectEqual(@as(i32, 0), sys.mkdirAll(cluster_d, 0o755));
    var mb: [192]u8 = undefined;
    const manifests_fp = try std.fmt.bufPrint(&mb, "{s}/manifests", .{cluster_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zb, manifests_fp), "not-a-dir"));
    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 1), try cmdDupesAll(std.testing.io, gpa, .{ .origin = empty_origin }));
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    // --all parses on dupes and is refused anywhere else.
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const parsed_ok = try parseArgs(gpa, &env, &.{ "dupes", "--all", "--origin", origin_d });
    freeParsed(parsed_ok, gpa);
    try std.testing.expect(parsed_ok.opts.all);
    try std.testing.expectError(error.FlagOutsideCommand, parseArgs(gpa, &env, &.{ "peers", "--all", "--origin", origin_d }));
    try std.testing.expectError(error.FlagOutsideCommand, parseArgs(gpa, &env, &.{ "verify", "--all", "--origin", origin_d, "m.bin" }));
}

test "cmdDupesAll skips a control-byte manifest name and still scans the rest" {
    // Origin-write plant: a manifests/ file whose name holds CR/LF. The
    // skip-warn goes through displayName (so the raw name never reaches
    // the journal); this pins that the scan still succeeds and does not
    // count the junk as a manifest. The echo gate itself is tested in
    // discover.zig.
    const gpa = std.testing.allocator;
    var ob: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&ob, "modelfs-o-dupes-ctrl");
    defer sys.deleteTree(std.testing.io, origin_d);

    const h0 = [_]u8{0x11} ** piece.digest_len;
    var entries = [_]piece.ManifestEntry{.{ .idx = 0, .hash = h0 }};
    try writeManifestForTest(gpa, origin_d, "a.bin", 16, 16, &entries);

    var mb: [256]u8 = undefined;
    var zb: [256]u8 = undefined;
    const evil = try std.fmt.bufPrint(&mb, "{s}/.cluster/manifests/evil\n2026-09-02 forged", .{origin_d});
    try std.testing.expectEqual(@as(i32, 0), sys.writeFileNoFollow(try sys.toZ(&zb, evil), "not a manifest"));

    const opts = Opts{ .origin = origin_d };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    captured_stdout = &out;
    defer captured_stdout = null;
    try std.testing.expectEqual(@as(u8, 0), try cmdDupesAll(std.testing.io, gpa, opts));
    try std.testing.expect(std.mem.find(u8, out.items, "scanned 1 manifest(s), 1 piece(s) total") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "forged") == null);
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
    try std.testing.expectEqualStrings("/etc/modelfs.psk", parsed.opts.psk_file);
    try std.testing.expectEqual(@as(u32, 4 * 1024 * 1024), parsed.opts.piece);
    // --listen is fully parsed at the flag boundary; only the port survives
    try std.testing.expectEqual(@as(u16, 19090), parsed.opts.listen_port.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.opts.seed.items.len);
    try std.testing.expectEqualStrings("10.0.0.9:19099", parsed.opts.seed.items[0]);
    try std.testing.expectEqual(@as(u32, 12), parsed.opts.water.brun);
    try std.testing.expectEqual(@as(u32, 6), parsed.opts.water.bcull);
    try std.testing.expectEqual(@as(u32, 2), parsed.opts.water.bstop);
    try std.testing.expect(parsed.opts.detach);
    // --kernel-cache flips direct_io off; default is on. --allow-other is
    // off until named: that is the only way a uid other than the mounter
    // reaches the mount.
    try std.testing.expect(parsed.opts.direct_io);
    try std.testing.expect(!parsed.opts.allow_other);
    {
        const kc = try parseArgs(gpa, &environ, &.{ "mount", "--kernel-cache", "--allow-other" });
        defer freeParsed(kc, gpa);
        try std.testing.expect(!kc.opts.direct_io);
        try std.testing.expect(kc.opts.allow_other);
    }
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
    // Unspecified and limited-broadcast are dotted quads inet_pton accepts
    // but no peer can dial: --advertise would publish them, --seed would
    // wait out a connect timeout on every miss. Loopback stays legal
    // (single-node / the no-NIC fallback).
    try std.testing.expectError(error.UndialableIp, parseArgs(gpa, &environ, &.{ "mount", "--advertise", "0.0.0.0" }));
    try std.testing.expectError(error.UndialableIp, parseArgs(gpa, &environ, &.{ "mount", "--advertise", "255.255.255.255:19091" }));
    try std.testing.expectError(error.UndialableIp, parseArgs(gpa, &environ, &.{ "mount", "--seed", "0.0.0.0" }));
    try std.testing.expectError(error.UndialableIp, parseArgs(gpa, &environ, &.{ "mount", "--seed", "255.255.255.255:18080" }));
    {
        const parsed = try parseArgs(gpa, &environ, &.{ "mount", "--advertise", "127.0.0.1" });
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("127.0.0.1", parsed.opts.advertise.items[0].ip);
    }
    // Empty mount directory is the same missing positional as omitting it.
    try std.testing.expectError(error.MissingValue, parseArgs(gpa, &environ, &.{ "mount", "" }));
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
    try std.testing.expectEqual(std.log.Level.info, parsed.opts.log_level);

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

test "parseArgs trims surrounding whitespace on environment values" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    // EnvironmentFile trailing space and a copied path with a newline must
    // not become the path (realpath would then fail as "not reachable").
    try environ.put("MODELFS_ORIGIN", " /env/origin \n");
    try environ.put("MODELFS_CACHE", "\t/env/cache ");
    try environ.put("MODELFS_PSK", " /env/psk\r\n");
    try environ.put("MODELFS_ID", " spark-env ");
    try environ.put("MODELFS_LOG", " debug ");
    {
        const parsed = try parseArgs(gpa, &environ, &.{"mount"});
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("/env/origin", parsed.opts.origin.?);
        try std.testing.expectEqualStrings("/env/cache", parsed.opts.cache);
        try std.testing.expectEqualStrings("/env/psk", parsed.opts.psk_file);
        try std.testing.expectEqualStrings("spark-env", parsed.opts.id.?);
        try std.testing.expectEqual(std.log.Level.debug, parsed.opts.log_level);
    }
    // Whitespace-only non-secret knobs count as unset, like an empty export.
    try environ.put("MODELFS_ORIGIN", "  \t");
    try environ.put("MODELFS_CACHE", " \n");
    try environ.put("MODELFS_PSK", " ");
    try environ.put("MODELFS_ID", " ");
    try environ.put("MODELFS_LOG", "  ");
    {
        const parsed = try parseArgs(gpa, &environ, &.{"mount"});
        defer freeParsed(parsed, gpa);
        try std.testing.expect(parsed.opts.origin == null);
        try std.testing.expectEqualStrings("/var/cache/modelfs", parsed.opts.cache);
        try std.testing.expectEqualStrings("/etc/modelfs.psk", parsed.opts.psk_file);
        try std.testing.expect(parsed.opts.id == null);
        try std.testing.expectEqual(std.log.Level.info, parsed.opts.log_level);
    }
    // Interior spaces in an id survive the trim (validId allows them).
    try environ.put("MODELFS_ID", " spark 1 ");
    {
        const parsed = try parseArgs(gpa, &environ, &.{"mount"});
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("spark 1", parsed.opts.id.?);
    }
    _ = environ.orderedRemove("MODELFS_PSK");
    _ = environ.orderedRemove("MODELFS_ID");
    // A whitespace-only inline secret is not "unset": falling through to
    // the PSK file would start with a different credential than the
    // operator just tried to set. loadPsk refuses it as empty.
    try environ.put("MODELFS_PSK_VALUE", " \t\n");
    {
        const parsed = try parseArgs(gpa, &environ, &.{"mount"});
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("", parsed.opts.psk_value.?);
        try std.testing.expectError(error.EmptyPsk, loadPsk(gpa, parsed.opts));
    }
    // Surrounding whitespace on a real secret is stripped; interior spaces
    // stay, matching loadPsk's file-form trim.
    try environ.put("MODELFS_PSK_VALUE", "  top secret \n");
    {
        const parsed = try parseArgs(gpa, &environ, &.{"mount"});
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("top secret", parsed.opts.psk_value.?);
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
    try std.testing.expectEqual(std.log.Level.err, parsed.opts.log_level);
}

test "parseArgs --log wins over MODELFS_LOG on every command" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("MODELFS_LOG", "debug");
    {
        const parsed = try parseArgs(gpa, &environ, &.{"status"});
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqual(std.log.Level.debug, parsed.opts.log_level);
    }
    // Explicit flag wins, including the attached --name=VALUE form, and
    // is not mount-only: a cron'd `status --log err` must quiet the
    // journal without a shell-wide MODELFS_LOG.
    {
        const parsed = try parseArgs(gpa, &environ, &.{ "status", "--log", "err" });
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqual(std.log.Level.err, parsed.opts.log_level);
    }
    {
        const parsed = try parseArgs(gpa, &environ, &.{ "pin", "x.bin", "--log=warn" });
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqual(std.log.Level.warn, parsed.opts.log_level);
    }
    {
        const parsed = try parseArgs(gpa, &environ, &.{ "mount", "--log", "info" });
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqual(std.log.Level.info, parsed.opts.log_level);
    }
    try std.testing.expectError(error.BadLogLevel, parseArgs(gpa, &environ, &.{ "status", "--log", "verbose" }));
    try std.testing.expectError(error.BadLogLevel, parseArgs(gpa, &environ, &.{ "peers", "--log", "" }));
    try std.testing.expectError(error.MissingValue, parseArgs(gpa, &environ, &.{ "unpin", "--log" }));
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

test "parseArgs accepts update and honors --cache" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try std.testing.expect(knownCommand("update"));
    {
        const parsed = try parseArgs(gpa, &environ, &.{"update"});
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("update", parsed.cmd);
        try std.testing.expectEqualStrings("/var/cache/modelfs", parsed.opts.cache);
        try std.testing.expectEqual(@as(usize, 0), parsed.rest.len);
    }
    {
        const parsed = try parseArgs(gpa, &environ, &.{ "update", "--cache", "/c" });
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("/c", parsed.opts.cache);
    }
    {
        const parsed = try parseArgs(gpa, &environ, &.{ "update", "--cache=/env/cache" });
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("/env/cache", parsed.opts.cache);
    }
    try environ.put("MODELFS_CACHE", "/from-env");
    {
        const parsed = try parseArgs(gpa, &environ, &.{"update"});
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("/from-env", parsed.opts.cache);
    }
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "update", "--detach" }));
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "update", "--kernel-cache" }));
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "update", "--listen", "19090" }));
    try std.testing.expectError(error.Help, parseArgs(gpa, &environ, &.{ "update", "--help" }));
    try std.testing.expectError(error.Version, parseArgs(gpa, &environ, &.{ "update", "-V" }));
}

test "parseArgs scopes the pull flags to pull and defaults the revision" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try std.testing.expect(knownCommand("pull"));
    {
        const parsed = try parseArgs(gpa, &environ, &.{ "pull", "owner/repo", "--origin", "/o" });
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("pull", parsed.cmd);
        try std.testing.expectEqualStrings("/o", parsed.opts.origin.?);
        try std.testing.expectEqualStrings(hf.default_revision, parsed.opts.revision);
        try std.testing.expectEqual(@as(?[]const u8, null), parsed.opts.dest);
        try std.testing.expectEqual(@as(usize, 1), parsed.rest.len);
        try std.testing.expectEqualStrings("owner/repo", parsed.rest[0]);
    }
    {
        const parsed = try parseArgs(gpa, &environ, &.{ "pull", "owner/repo", "--origin=/o", "--revision=v2", "--dest=gguf/x" });
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("v2", parsed.opts.revision);
        try std.testing.expectEqualStrings("gguf/x", parsed.opts.dest.?);
    }
    // Accepted-and-ignored is the failure to avoid: --revision on verify
    // would read as a working knob.
    try std.testing.expectError(error.FlagOutsideCommand, parseArgs(gpa, &environ, &.{ "verify", "a.bin", "--origin", "/o", "--revision", "v2" }));
    try std.testing.expectError(error.FlagOutsideCommand, parseArgs(gpa, &environ, &.{ "status", "--dest", "x" }));
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "pull", "owner/repo", "--origin", "/o", "--listen", "19090" }));
    try std.testing.expectError(error.FlagOutsideCommand, parseArgs(gpa, &environ, &.{ "pull", "owner/repo", "--origin", "/o", "--all" }));
    try std.testing.expectError(error.MissingValue, parseArgs(gpa, &environ, &.{ "pull", "owner/repo", "--origin", "/o", "--revision" }));
}

test "cmdPull names a bad repo, revision, or destination and never opens a socket" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var db: [128]u8 = undefined;
    const origin_d = try sys.scratchDir(&db, "modelfs-pull-args");
    defer sys.deleteTree(std.testing.io, origin_d);

    const Case = struct { repo: []const u8, opts: Opts, want: []const u8 };
    const cases = [_]Case{
        .{ .repo = "owner/repo", .opts = .{}, .want = "pull needs --origin" },
        .{ .repo = "no-slash", .opts = .{ .origin = origin_d }, .want = "not a Hugging Face owner/repo id" },
        .{ .repo = "owner/..", .opts = .{ .origin = origin_d }, .want = "not a Hugging Face owner/repo id" },
        .{ .repo = "owner/repo", .opts = .{ .origin = origin_d, .revision = "bad ref" }, .want = "not a branch, tag, or commit" },
        .{ .repo = "owner/repo", .opts = .{ .origin = origin_d, .dest = "../escape" }, .want = "not a path under the origin" },
        .{ .repo = "owner/repo", .opts = .{ .origin = origin_d, .dest = discover.cluster_dir }, .want = "not a path under the origin" },
    };
    for (cases) |case| {
        var err: std.ArrayList(u8) = .empty;
        defer err.deinit(gpa);
        captured_stderr = &err;
        defer captured_stderr = null;
        // Exit 2, the usage code: these are all argument mistakes, and none
        // of them may cost a DNS lookup or a TLS handshake first.
        try std.testing.expectEqual(@as(u8, 2), try cmdPull(std.testing.io, gpa, &environ, case.opts, case.repo));
        try std.testing.expect(std.mem.find(u8, err.items, case.want) != null);
    }
}

test "parseArgs rejects mount-only flags on other commands" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    // The help text promises status/peers/pin/unpin take only their Usage-line
    // flags; mount-only knobs must be refused, not accepted-and-ignored.
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "status", "--detach" }));
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "status", "--kernel-cache" }));
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "status", "--allow-other" }));
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "status", "--direct-io" }));
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "peers", "--origin", "/o", "--piece", "4M" }));
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "peers", "--id", "spark9" }));
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "pin", "x.bin", "--listen", "19090" }));
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "unpin", "x.bin", "-f" }));
    try std.testing.expectError(error.FlagOutsideMount, parseArgs(gpa, &environ, &.{ "peers", "--seed", "10.0.0.9" }));
    // Shared value flags stay legal on every command (the e2e suites pass
    // --psk/--origin to pin and peers).
    {
        const parsed = try parseArgs(gpa, &environ, &.{ "pin", "x.bin", "--cache", "/c", "--origin", "/o", "--psk", "/p", "--log", "err" });
        defer freeParsed(parsed, gpa);
        try std.testing.expectEqualStrings("/c", parsed.opts.cache);
        try std.testing.expectEqual(std.log.Level.err, parsed.opts.log_level);
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

test "usage lists exclusive dupes forms and interpolates the default port" {
    var buf: [usage.len + 16]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, usage, .{proto.default_port});
    try std.testing.expect(std.mem.find(u8, text, "modelfs update [--cache PATH]") != null);
    try std.testing.expect(std.mem.find(u8, text, "modelfs pull <owner/repo> --origin PATH") != null);
    // The token has no flag on purpose; help has to say where it comes from
    // or the only documented way to reach a private repo is guesswork.
    try std.testing.expect(std.mem.find(u8, text, hf.token_env) != null);
    try std.testing.expect(std.mem.find(u8, text, "modelfs dupes <relpath>... --origin PATH") != null);
    try std.testing.expect(std.mem.find(u8, text, "modelfs dupes --all --origin PATH") != null);
    // Combined `[--all]` next to the path list implied `dupes a --all` was
    // legal; that combination is refused (exit 2).
    try std.testing.expect(std.mem.find(u8, text, "[--all]") == null);
    try std.testing.expect(std.mem.find(u8, text, "Usage errors exit 2") != null);
    var port_buf: [8]u8 = undefined;
    const port = try std.fmt.bufPrint(&port_buf, "{d}", .{proto.default_port});
    try std.testing.expect(std.mem.find(u8, text, port) != null);
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
    try std.testing.expectError(error.UnexpectedValue, parseArgs(gpa, &environ, &.{ "mount", "--kernel-cache=off" }));
    try std.testing.expectError(error.UnexpectedValue, parseArgs(gpa, &environ, &.{ "mount", "--allow-other=1" }));
    try std.testing.expectError(error.UnexpectedValue, parseArgs(gpa, &environ, &.{ "mount", "--direct-io=false" }));
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

test "parseArgs trims surrounding whitespace on --seed" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    const parsed = try parseArgs(gpa, &environ, &.{ "mount", "--seed", " 10.0.0.9:19099 " });
    defer freeParsed(parsed, gpa);
    try std.testing.expectEqual(@as(usize, 1), parsed.opts.seed.items.len);
    try std.testing.expectEqualStrings("10.0.0.9:19099", parsed.opts.seed.items[0]);
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
    // status/peers/pin/unpin never load the secret; a shell-wide inline value
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

    // Group-readable PSK files warn at load; world-readable ones refuse.
    // Tests that must load a secret chmod 0600 after write. The log ceiling
    // still hides the group warning for the 0640 case below.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    // Inline value passes through interior spaces...
    {
        const psk = try loadPsk(gpa, .{ .psk_value = "inline secret" });
        defer gpa.free(psk);
        try std.testing.expectEqualStrings("inline secret", psk);
    }
    // ...and surrounding whitespace/newlines, matching the file form, so
    // EnvironmentFile lines and `$(cat psk)`-shaped copies of a file secret
    // produce the same token. bearerOk trims only the received token.
    {
        const psk = try loadPsk(gpa, .{ .psk_value = "  topsecret \r\n" });
        defer gpa.free(psk);
        try std.testing.expectEqualStrings("topsecret", psk);
    }
    // ...but an empty or whitespace-only one would authenticate every
    // "Bearer " request (or 401 forever against a trimmed wire token).
    try std.testing.expectError(error.EmptyPsk, loadPsk(gpa, .{ .psk_value = "" }));
    try std.testing.expectError(error.EmptyPsk, loadPsk(gpa, .{ .psk_value = " \t\n" }));
    // The file form is capped at proto.max_psk_bytes; the inline form must
    // match or a huge env value would start the daemon and then fail the
    // peer request head.
    try std.testing.expectError(error.PskTooLarge, loadPsk(gpa, .{ .psk_value = "k" ** (proto.max_psk_bytes + 1) }));
    {
        const psk = try loadPsk(gpa, .{ .psk_value = "k" ** proto.max_psk_bytes });
        defer gpa.free(psk);
        try std.testing.expectEqual(@as(usize, proto.max_psk_bytes), psk.len);
    }
    // Cap is the trimmed token: a max-size secret plus a trailing newline
    // (EnvironmentFile, a copied psk file) is still one legal token.
    {
        const psk = try loadPsk(gpa, .{ .psk_value = ("k" ** proto.max_psk_bytes) ++ "\n" });
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
        try std.testing.expectEqual(@as(i32, 0), sys.c.chmod(try sys.toZ(&zb, fp), 0o600));
        const psk = try loadPsk(gpa, .{ .psk_file = fp });
        defer gpa.free(psk);
        try std.testing.expectEqualStrings("topsecret", psk);
    }
    // A whitespace-only file is an empty secret: refuse it too.
    {
        var pb: [160]u8 = undefined;
        const fp = try std.fmt.bufPrint(&pb, "{s}/blank.psk", .{scratch});
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zb, fp), "\n\t  \n"));
        try std.testing.expectEqual(@as(i32, 0), sys.c.chmod(try sys.toZ(&zb, fp), 0o600));
        try std.testing.expectError(error.EmptyPsk, loadPsk(gpa, .{ .psk_file = fp }));
    }
    // World-readable is a stolen credential waiting to happen: refuse
    // rather than warn. Group-readable still loads (a dedicated group
    // is a valid deployment) and is the warning the log ceiling hides.
    {
        var pb: [160]u8 = undefined;
        const world = try std.fmt.bufPrint(&pb, "{s}/world.psk", .{scratch});
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zb, world), "secret"));
        try std.testing.expectEqual(@as(i32, 0), sys.c.chmod(try sys.toZ(&zb, world), 0o644));
        try std.testing.expectError(error.PskWorldReadable, loadPsk(gpa, .{ .psk_file = world }));
        const group = try std.fmt.bufPrint(&pb, "{s}/group.psk", .{scratch});
        try std.testing.expectEqual(@as(i32, 0), sys.writeFile(try sys.toZ(&zb, group), "secret"));
        try std.testing.expectEqual(@as(i32, 0), sys.c.chmod(try sys.toZ(&zb, group), 0o640));
        const psk = try loadPsk(gpa, .{ .psk_file = group });
        defer gpa.free(psk);
        try std.testing.expectEqualStrings("secret", psk);
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
        try std.testing.expectEqual(@as(i32, 0), sys.c.chmod(try sys.toZ(&zb, fp), 0o600));
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

test "disableCoreDumps zeros RLIMIT_CORE" {
    try disableCoreDumps();
    const lim = std.posix.getrlimit(.CORE) catch return error.SkipZigTest;
    try std.testing.expectEqual(@as(std.posix.rlim_t, 0), lim.cur);
    try std.testing.expectEqual(@as(std.posix.rlim_t, 0), lim.max);
}

test "scrubPskEnv removes MODELFS_PSK_VALUE" {
    try std.testing.expectEqual(@as(c_int, 0), sys.c.setenv("MODELFS_PSK_VALUE", "inline-secret", 1));
    try std.testing.expect(sys.c.getenv("MODELFS_PSK_VALUE") != null);
    scrubPskEnv();
    try std.testing.expect(sys.c.getenv("MODELFS_PSK_VALUE") == null);
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
    // parseArgs already refuses these; buildSeeds is the mount-time backstop
    // for a hostname that resolved to the unspecified address.
    try std.testing.expectError(error.SeedUndialable, buildSeeds(gpa, &.{"0.0.0.0"}));
    try std.testing.expectError(error.SeedUndialable, buildSeeds(gpa, &.{"255.255.255.255:19099"}));
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
    // --advertise order is canonicalized the same way: 10.0.0.1 before
    // 10.0.0.2 regardless of flag order.
    {
        var opts = Opts{};
        opts.listen_port = 19091;
        try opts.advertise.append(gpa, .{ .ip = "10.0.0.2", .port = 19090 });
        try opts.advertise.append(gpa, .{ .ip = "10.0.0.1", .port = proto.default_port });
        defer opts.advertise.deinit(gpa);
        var addrs = try leaseAddrs(gpa, opts, &.{}, 19091);
        defer addrs.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 2), addrs.items.len);
        try std.testing.expectEqualStrings("10.0.0.1", addrs.items[0].ip);
        try std.testing.expectEqual(@as(u16, 19091), addrs.items[0].port);
        try std.testing.expectEqualStrings("10.0.0.2", addrs.items[1].ip);
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
    // effective listening port, sorted by ip so getifaddrs order cannot
    // decide the lease document.
    {
        const local = [_][]const u8{ "192.168.1.5", "10.1.1.5" };
        var addrs = try leaseAddrs(gpa, .{}, &local, 18080);
        defer addrs.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 2), addrs.items.len);
        try std.testing.expectEqualStrings("10.1.1.5", addrs.items[0].ip);
        try std.testing.expectEqual(@as(u16, 18080), addrs.items[0].port);
        try std.testing.expectEqualStrings("192.168.1.5", addrs.items[1].ip);
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
