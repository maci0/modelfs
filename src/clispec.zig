//! clispec 0.3 document for `modelfs schema`, plus the output-mode decision
//! the CLI shares. Schema rendering reads no config, token, or network.
const std = @import("std");
const builtin = @import("builtin");

pub const Output = enum { auto, text, json };

pub fn parseOutput(raw: []const u8) ?Output {
    if (std.mem.eql(u8, raw, "auto")) return .auto;
    if (std.mem.eql(u8, raw, "text")) return .text;
    if (std.mem.eql(u8, raw, "json")) return .json;
    return null;
}

/// Set by the CLI before it dispatches. Tests leave it unset and get the
/// historical auto behavior (status JSON, every other report text).
var bound_io: ?std.Io = null;
pub var tty_override: ?bool = null;
pub var errors_as_json: bool = false;

pub fn bindIo(io: std.Io) void {
    bound_io = io;
}

pub fn stdoutIsTty() bool {
    if (tty_override) |v| return v;
    const io = bound_io orelse return false;
    var buf: [96]u8 = undefined;
    const n = std.Io.Dir.readLinkAbsolute(io, "/proc/self/fd/1", &buf) catch return false;
    const target = buf[0..n];
    if (std.mem.eql(u8, target, "/dev/console")) return true;
    if (std.mem.startsWith(u8, target, "/dev/pts/")) return true;
    if (std.mem.startsWith(u8, target, "/dev/tty")) return true;
    return false;
}

/// `legacy_json_on_auto` is the behavior tests already pin: status served
/// JSON before `-o` existed, and the other commands served text.
pub fn asJson(output: Output, legacy_json_on_auto: bool) bool {
    return switch (output) {
        .json => true,
        .text => false,
        .auto => if (builtin.is_test and tty_override == null) legacy_json_on_auto else !stdoutIsTty(),
    };
}

/// Text table for status and peers. Auto during tests keeps the historical
/// lines (status JSON, peers prose) so those tests stay on the bytes they pin.
pub fn asTextTable(output: Output) bool {
    return switch (output) {
        .text => true,
        .json => false,
        .auto => if (builtin.is_test and tty_override == null) false else stdoutIsTty(),
    };
}

pub fn setErrorMode(output: Output) void {
    errors_as_json = asJson(output, false);
}

const Arg = struct {
    name: []const u8,
    type: []const u8,
    description: ?[]const u8 = null,
    short: ?[]const u8 = null,
    required: ?bool = null,
    default: ?[]const u8 = null,
    @"enum": ?[]const []const u8 = null,
};

const Item = struct {
    type: []const u8,
    fields: ?[]const Field = null,
};

const Field = struct {
    name: []const u8,
    type: []const u8,
    description: ?[]const u8 = null,
    nullable: ?bool = null,
    items: ?Item = null,
    @"enum": ?[]const []const u8 = null,
};

const Command = struct {
    name: []const u8,
    description: []const u8,
    effects: []const u8,
    output_kind: []const u8,
    cardinality: ?[]const u8 = null,
    output_fields: ?[]const Field = null,
    stream_format: ?[]const u8 = null,
    media_type: ?[]const u8 = null,
    args: ?[]const Arg = null,
    errors: ?[]const []const u8 = null,
};

const ErrKind = struct {
    kind: []const u8,
    exit_code: u8,
    retryable: bool,
    description: []const u8,
};

const Doc = struct {
    clispec: []const u8 = "0.3",
    name: []const u8 = "modelfs",
    version: []const u8,
    description: []const u8,
    output: struct { tty: []const u8 = "text", piped: []const u8 = "json" } = .{},
    global_args: []const Arg,
    commands: []const Command,
    errors: []const ErrKind,
};

const output_enum = [_][]const u8{ "auto", "text", "json" };
const log_enum = [_][]const u8{ "err", "warn", "info", "debug" };
const usage_failed = [_][]const u8{ "usage", "failed" };

const global_args = [_]Arg{
    .{
        .name = "--output",
        .short = "-o",
        .type = "string",
        .@"enum" = &output_enum,
        .default = "auto",
        .description = "auto is a text table on a terminal and JSON when stdout is not a terminal. An explicit value wins, including -o text on a pipe.",
    },
    .{
        .name = "--help",
        .short = "-h",
        .type = "boolean",
        .description = "Print command help on stdout and exit 0.",
    },
    .{
        .name = "--version",
        .short = "-V",
        .type = "boolean",
        .description = "Print the release version on stdout and exit 0.",
    },
    .{
        .name = "--log",
        .type = "string",
        .@"enum" = &log_enum,
        .default = "info",
        .description = "Journal ceiling. MODELFS_LOG sets the same value; the flag wins.",
    },
};

const origin_arg = Arg{
    .name = "--origin",
    .type = "path",
    .description = "Shared origin directory. MODELFS_ORIGIN sets the same value; the flag wins.",
};
const cache_arg = Arg{
    .name = "--cache",
    .type = "path",
    .default = "/var/cache/modelfs",
    .description = "Local piece cache. MODELFS_CACHE sets the same value; the flag wins.",
};

const status_fields = [_]Field{
    .{ .name = "id", .type = "string", .description = "Node id the daemon published." },
    .{ .name = "pid", .type = "integer" },
    .{ .name = "uptime_s", .type = "integer", .nullable = true },
    .{ .name = "peers", .type = "integer", .nullable = true },
    .{ .name = "piece", .type = "integer", .nullable = true },
    .{ .name = "inflight", .type = "integer", .nullable = true },
    .{ .name = "cache_free_pct", .type = "integer", .nullable = true, .description = "-1 when the cache filesystem could not be stat'ed." },
    .{ .name = "origin_down", .type = "integer", .nullable = true },
    .{ .name = "now_s", .type = "integer", .nullable = true },
    .{ .name = "mono_s", .type = "integer", .nullable = true },
    .{ .name = "boot_s", .type = "integer", .nullable = true },
    .{ .name = "stats", .type = "object", .nullable = true, .description = "Lifetime counters. Older documents omit fields this build adds." },
};

const addr_fields = [_]Field{
    .{ .name = "ip", .type = "string" },
    .{ .name = "port", .type = "integer" },
    .{ .name = "mbps", .type = "integer" },
};
const addr_item = Item{ .type = "object", .fields = &addr_fields };
const peer_fields = [_]Field{
    .{ .name = "id", .type = "string" },
    .{ .name = "until", .type = "integer" },
    .{ .name = "live", .type = "boolean" },
    .{ .name = "addrs", .type = "array", .items = addr_item },
};

const changed_fields = [_]Field{
    .{ .name = "path", .type = "string" },
    .{ .name = "pinned", .type = "boolean" },
    .{ .name = "changed", .type = "boolean", .description = "False when the pin marker was already in the requested state." },
};

const pull_fields = [_]Field{
    .{ .name = "repo", .type = "string" },
    .{ .name = "revision", .type = "string" },
    .{ .name = "dest", .type = "string" },
    .{ .name = "pulled", .type = "integer" },
    .{ .name = "bytes", .type = "integer" },
    .{ .name = "skipped", .type = "integer" },
    .{ .name = "changed", .type = "boolean", .description = "True when this run wrote at least one file. A rerun that only skips existing files is changed false and exits 0." },
};

const dupe_fields = [_]Field{
    .{ .name = "manifests", .type = "integer", .nullable = true, .description = "Set on the one record dupes --all streams." },
    .{ .name = "pieces", .type = "integer", .nullable = true, .description = "Piece count: the store total on a dupes --all record, or one file's count on a per-path record." },
    .{ .name = "identical_pairs", .type = "integer", .nullable = true },
    .{ .name = "shared_pairs", .type = "integer", .nullable = true },
    .{ .name = "rel", .type = "string", .nullable = true, .description = "Set on a per-path record." },
    .{ .name = "grid", .type = "integer", .nullable = true },
    .{ .name = "bytes", .type = "integer", .nullable = true },
    .{ .name = "left", .type = "string", .nullable = true, .description = "Set on an overlap record." },
    .{ .name = "right", .type = "string", .nullable = true },
    .{ .name = "aligned", .type = "integer", .nullable = true },
    .{ .name = "aligned_of", .type = "integer", .nullable = true },
    .{ .name = "shared", .type = "integer", .nullable = true },
    .{ .name = "shifted", .type = "integer", .nullable = true },
    .{ .name = "identical", .type = "boolean", .nullable = true },
};

const mount_args = [_]Arg{
    .{ .name = "dir", .type = "path", .required = true, .description = "Mountpoint directory." },
    origin_arg,
    cache_arg,
    .{ .name = "--id", .type = "string", .description = "Node id. Default is the short hostname. MODELFS_ID is mount and config only." },
    .{ .name = "--listen", .type = "string", .description = "Peer HTTP [IP:]PORT. The IP is ignored; the socket binds all interfaces." },
    .{ .name = "--advertise", .type = "string", .description = "Comma-separated lease addresses. Repeatable." },
    .{ .name = "--psk", .type = "path", .description = "PSK file path. The secret itself is MODELFS_PSK_VALUE or the file, never a flag value." },
    .{ .name = "--seed", .type = "string", .description = "Peer seed HOST[:PORT]. Repeatable." },
    .{ .name = "--piece", .type = "string", .description = "Piece size, a positive multiple of the cache filesystem block size." },
    .{ .name = "--direct-io", .type = "boolean" },
    .{ .name = "--kernel-cache", .type = "boolean" },
    .{ .name = "--brun", .type = "integer" },
    .{ .name = "--bcull", .type = "integer" },
    .{ .name = "--bstop", .type = "integer" },
    .{ .name = "--allow-other", .type = "boolean" },
    .{ .name = "--detach", .type = "boolean" },
    .{ .name = "--foreground", .short = "-f", .type = "boolean" },
};

const status_args = [_]Arg{cache_arg};
const peers_args = [_]Arg{.{
    .name = "--origin",
    .type = "path",
    .required = true,
    .description = origin_arg.description,
}};
const pin_args = [_]Arg{
    .{ .name = "path", .type = "path", .required = true, .description = "Path relative to the mount. A /models/ prefix is stripped." },
    .{ .name = "--origin", .type = "path", .required = true, .description = origin_arg.description },
    cache_arg,
};
const verify_args = pin_args;
const dupes_args = [_]Arg{
    .{ .name = "path", .type = "path", .description = "Path relative to the mount. Repeatable. Refused together with --all." },
    .{ .name = "--all", .type = "boolean", .description = "Scan every manifest. The result is one aggregate record, not a paged file list: manifests are keyed by digest and cannot be named." },
    .{ .name = "--origin", .type = "path", .required = true, .description = origin_arg.description },
    cache_arg,
};
const pull_args = [_]Arg{
    .{ .name = "repo", .type = "string", .required = true, .description = "Hugging Face owner/repo. The token is HF_TOKEN, else $HF_HOME/token, else ~/.cache/huggingface/token. There is no token flag." },
    .{ .name = "--origin", .type = "path", .required = true, .description = origin_arg.description },
    .{ .name = "--revision", .type = "string", .default = "main" },
    .{ .name = "--dest", .type = "path", .description = "Path under the origin. Default is the repo id." },
};
const update_args = [_]Arg{
    cache_arg,
    .{ .name = "--check", .type = "boolean", .description = "Print whether a release is newer without installing." },
    .{ .name = "--repo", .type = "string", .description = "GitHub owner/name. Default maci0/modelfs." },
    .{ .name = "--reload", .type = "boolean", .description = "Ask the live daemon to replace its image without checking releases." },
};
const schema_args = [_]Arg{
    .{ .name = "path", .type = "string", .description = "Command path. Limits commands to that name and to names that start with it." },
};

const command_total = 12;

fn commands() [command_total]Command {
    return .{
        .{
            .name = "mount",
            .description = "Mount the origin at a directory and serve it until the process exits. A retry starts another mount and cannot be made safe. Success writes nothing to stdout.",
            .effects = "non_idempotent",
            .output_kind = "opaque",
            .media_type = "text/plain",
            .args = &mount_args,
            .errors = &usage_failed,
        },
        .{
            .name = "status",
            .description = "Read the daemon's status document from the cache. A terminal, or -o text, prints a table. A pipe, or -o json, prints the document unchanged. A daemon that is not running exits 1.",
            .effects = "read_only",
            .output_kind = "data",
            .cardinality = "single",
            .output_fields = &status_fields,
            .args = &status_args,
            .errors = &usage_failed,
        },
        .{
            .name = "peers",
            .description = "List cluster leases. A terminal, or -o text, prints a table. A pipe, or -o json, streams one JSON object per lease and writes no record when the cluster is empty. The walk is not paged: close the pipe to stop.",
            .effects = "read_only",
            .output_kind = "stream",
            .stream_format = "ndjson",
            .output_fields = &peer_fields,
            .args = &peers_args,
            .errors = &usage_failed,
        },
        .{
            .name = "pin",
            .description = "Keep one file out of the cull. Repeating a pin that is already set exits 0 with changed false.",
            .effects = "idempotent",
            .output_kind = "data",
            .cardinality = "single",
            .output_fields = &changed_fields,
            .args = &pin_args,
            .errors = &usage_failed,
        },
        .{
            .name = "unpin",
            .description = "Allow one file to be culled again. Repeating an unpin that is already clear exits 0 with changed false.",
            .effects = "idempotent",
            .output_kind = "data",
            .cardinality = "single",
            .output_fields = &changed_fields,
            .args = &pin_args,
            .errors = &usage_failed,
        },
        .{
            .name = "verify",
            .description = "Rehash cached pieces and clear marks that do not match a trusted digest. Repeating a clean verify changes nothing. A mismatch exits 1 after the mark is cleared. The summary is text; -o does not change it.",
            .effects = "idempotent",
            .output_kind = "opaque",
            .media_type = "text/plain",
            .args = &verify_args,
            .errors = &usage_failed,
        },
        .{
            .name = "dupes",
            .description = "Report piece-hash overlap. With paths, JSON mode streams one record per file and one per pair. dupes --all walks every manifest and streams one aggregate object: the manifests are keyed by digest, so they cannot be named or paged, and a retry repeats the scan. Text mode prints the same report as lines.",
            .effects = "read_only",
            .output_kind = "stream",
            .stream_format = "ndjson",
            .output_fields = &dupe_fields,
            .args = &dupes_args,
            .errors = &usage_failed,
        },
        .{
            .name = "pull",
            .description = "Download one Hugging Face revision onto the origin. Files already present at the listed size are skipped, so a rerun exits 0. changed is false when this run wrote nothing. The token stays in HF_TOKEN or the token file; there is no token flag. A retry of a branch can observe a moved tip; a commit revision converges.",
            .effects = "idempotent",
            .output_kind = "data",
            .cardinality = "single",
            .output_fields = &pull_fields,
            .args = &pull_args,
            .errors = &usage_failed,
        },
        .{
            .name = "update",
            .description = "Replace this binary with a newer GitHub release, or reload the running daemon. A retry can download and replace again and cannot be made safe. --check only reads the release page.",
            .effects = "non_idempotent",
            .output_kind = "opaque",
            .media_type = "text/plain",
            .args = &update_args,
            .errors = &usage_failed,
        },
        .{
            .name = "config",
            .description = "Print the knobs a mount would run with, one line each, without touching the daemon or the origin. The inline PSK is reported as set and never printed. -o does not change the text.",
            .effects = "read_only",
            .output_kind = "opaque",
            .media_type = "text/plain",
            .args = &mount_args,
            .errors = &usage_failed,
        },
        .{
            .name = "schema",
            .description = "Print this clispec 0.3 document on stdout and exit 0. No config file, token, or network is read. A command path limits commands to that name and to names that start with it. -o does not change the document.",
            .effects = "read_only",
            .output_kind = "opaque",
            .media_type = "application/json",
            .args = &schema_args,
            .errors = &usage_failed,
        },
        .{
            .name = "version",
            .description = "Print the release version. -o does not change the line.",
            .effects = "read_only",
            .output_kind = "opaque",
            .media_type = "text/plain",
            .errors = &usage_failed,
        },
    };
}

const errors = [_]ErrKind{
    .{
        .kind = "usage",
        .exit_code = 2,
        .retryable = false,
        .description = "The invocation was wrong. Nothing was attempted.",
    },
    .{
        .kind = "failed",
        .exit_code = 1,
        .retryable = false,
        .description = "The command could not finish. The message names the cause. A retry is not automatically safe.",
    },
};

pub fn schemaJson(gpa: std.mem.Allocator, version: []const u8, path: ?[]const u8) ![]u8 {
    const all = commands();
    var matched: [command_total]Command = undefined;
    var n: usize = 0;
    if (path) |p| {
        if (p.len == 0) return error.UnknownCommand;
        for (all) |cmd| {
            if (std.mem.eql(u8, cmd.name, p) or std.mem.startsWith(u8, cmd.name, p) and (cmd.name.len == p.len or cmd.name[p.len] == ' ')) {
                matched[n] = cmd;
                n += 1;
            }
        }
        if (n == 0) return error.UnknownCommand;
    }
    const doc = Doc{
        .version = version,
        .description = "POSIX mount for model files. Local NVMe, then peers, then the origin.",
        .global_args = &global_args,
        .commands = if (path == null) &all else matched[0..n],
        .errors = &errors,
    };
    // `all` is a local array. Stringify copies the values it walks before
    // returning, so the allocated document does not borrow it.
    return std.json.Stringify.valueAlloc(gpa, doc, .{ .emit_null_optional_fields = false });
}

fn commandNamed(parsed: std.json.Value, name: []const u8) ?std.json.ObjectMap {
    const cmds = parsed.object.get("commands").?.array;
    for (cmds.items) |cmd| {
        if (std.mem.eql(u8, cmd.object.get("name").?.string, name)) return cmd.object;
    }
    return null;
}

test "schema document is clispec 0.3 and names output, errors, and effects" {
    const gpa = std.testing.allocator;
    const bytes = try schemaJson(gpa, "0.21.0", null);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "HF_TOKEN") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "--token") == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("0.3", root.get("clispec").?.string);
    try std.testing.expectEqualStrings("modelfs", root.get("name").?.string);
    try std.testing.expectEqualStrings("0.21.0", root.get("version").?.string);
    try std.testing.expectEqualStrings("text", root.get("output").?.object.get("tty").?.string);
    try std.testing.expectEqualStrings("json", root.get("output").?.object.get("piped").?.string);
    try std.testing.expect(root.get("outcomes") == null);

    var saw_output = false;
    for (root.get("global_args").?.array.items) |arg| {
        if (!std.mem.eql(u8, arg.object.get("name").?.string, "--output")) continue;
        saw_output = true;
        try std.testing.expectEqualStrings("-o", arg.object.get("short").?.string);
        try std.testing.expectEqualStrings("auto", arg.object.get("default").?.string);
        const en = arg.object.get("enum").?.array;
        try std.testing.expectEqual(@as(usize, 3), en.items.len);
    }
    try std.testing.expect(saw_output);

    var saw_usage = false;
    var saw_failed = false;
    for (root.get("errors").?.array.items) |err| {
        const kind = err.object.get("kind").?.string;
        const code = err.object.get("exit_code").?.integer;
        if (std.mem.eql(u8, kind, "usage")) {
            saw_usage = true;
            try std.testing.expectEqual(@as(i64, 2), code);
            try std.testing.expect(!err.object.get("retryable").?.bool);
        } else if (std.mem.eql(u8, kind, "failed")) {
            saw_failed = true;
            try std.testing.expectEqual(@as(i64, 1), code);
        } else return error.UnexpectedKind;
    }
    try std.testing.expect(saw_usage and saw_failed);

    const names = [_][]const u8{ "mount", "status", "peers", "pin", "unpin", "verify", "dupes", "pull", "update", "config", "schema", "version" };
    try std.testing.expectEqual(names.len, root.get("commands").?.array.items.len);
    for (names) |name| {
        const cmd = commandNamed(parsed.value, name) orelse return error.MissingCommand;
        try std.testing.expect(cmd.get("description").?.string.len > 0);
        const effects = cmd.get("effects").?.string;
        try std.testing.expect(std.mem.eql(u8, effects, "read_only") or std.mem.eql(u8, effects, "idempotent") or std.mem.eql(u8, effects, "non_idempotent"));
        try std.testing.expect(cmd.get("idempotency_key_arg") == null);
        const kind = cmd.get("output_kind").?.string;
        if (std.mem.eql(u8, kind, "data")) {
            try std.testing.expect(cmd.get("cardinality") != null);
            try std.testing.expect(cmd.get("output_fields") != null);
            try std.testing.expect(cmd.get("media_type") == null);
            try std.testing.expect(cmd.get("pagination") == null);
        } else if (std.mem.eql(u8, kind, "stream")) {
            try std.testing.expectEqualStrings("ndjson", cmd.get("stream_format").?.string);
            try std.testing.expect(cmd.get("cardinality") == null);
            try std.testing.expect(cmd.get("pagination") == null);
        } else if (std.mem.eql(u8, kind, "opaque")) {
            try std.testing.expect(cmd.get("media_type").?.string.len > 0);
            try std.testing.expect(cmd.get("cardinality") == null);
            try std.testing.expect(cmd.get("output_fields") == null);
        } else return error.BadOutputKind;
    }
    try std.testing.expectEqualStrings("idempotent", commandNamed(parsed.value, "pin").?.get("effects").?.string);
    try std.testing.expectEqualStrings("idempotent", commandNamed(parsed.value, "pull").?.get("effects").?.string);
    try std.testing.expectEqualStrings("stream", commandNamed(parsed.value, "dupes").?.get("output_kind").?.string);
    try std.testing.expect(std.mem.find(u8, commandNamed(parsed.value, "mount").?.get("description").?.string, "cannot be made safe") != null);
    try std.testing.expect(std.mem.find(u8, commandNamed(parsed.value, "update").?.get("description").?.string, "cannot be made safe") != null);
}

test "schema path filter keeps the top-level document" {
    const gpa = std.testing.allocator;
    const bytes = try schemaJson(gpa, "0.21.0", "status");
    defer gpa.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("0.3", parsed.value.object.get("clispec").?.string);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("commands").?.array.items.len);
    try std.testing.expectEqualStrings("status", commandNamed(parsed.value, "status").?.get("name").?.string);
    try std.testing.expectError(error.UnknownCommand, schemaJson(gpa, "0.21.0", "nope"));
}
