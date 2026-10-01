//! `modelfs update`: compare this build with the latest GitHub release and,
//! when asked to install, replace the running executable only after its bytes
//! match the SHA-256 digest in `SHA256SUMS` published with the release.
//!
//! The decision (repo shape, exact version, asset name, checksum, trusted
//! URL) is pure. Network requests and binary replacement are isolated so
//! unit tests in `zig build test` run hermetically without network access.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const sys = @import("sys.zig");

pub const default_repo = "maci0/modelfs";
pub const tool_name = "modelfs";
pub const token_env = "GITHUB_TOKEN";

pub const max_json_bytes: usize = 1 << 20; // 1 MiB
pub const max_sums_bytes: usize = 64 << 10; // 64 KiB
pub const max_asset_bytes: usize = 100 << 20; // 100 MiB

pub const Verdict = enum {
    current,
    /// The running build is newer than the published tag. Nothing to
    /// install: `latest` is behind, and installing it would downgrade the
    /// binary underneath a live daemon. Distinct from `current` because the
    /// operator reading the output is answering "am I up to date?", and
    /// "you are ahead of the published release" is a different answer.
    ahead,
    unsupported_target,
    missing_asset,
    missing_checksums,
    checksum_not_found,
    untrusted_url,
    checksum_mismatch,
    replaced,
};

pub const Inputs = struct {
    running: []const u8,
    tag: []const u8,
    asset_name: ?[]const u8 = null,
    asset_url: ?[]const u8 = null,
    asset_bytes: ?[]const u8 = null,
    sums_url: ?[]const u8 = null,
    sums_bytes: ?[]const u8 = null,
};

pub const ListedAsset = struct {
    name: []const u8,
    url: []const u8,
};

pub const Release = struct {
    tag: []const u8,
    page: []const u8,
    assets: []const ListedAsset,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Release) void {
        self.arena.deinit();
    }
};

/// One leading `v` on the tag, then exact equality. `v0.18.0` is `0.18.0`.
pub fn sameRelease(running: []const u8, tag: []const u8) bool {
    const bare = bareTag(tag);
    return std.mem.eql(u8, running, bare);
}

/// The tag's version string: one leading `v` dropped, nothing else. The
/// published tag is a string off GitHub's API, so the only spelling the
/// release process does not emit is the bare form.
fn bareTag(tag: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
}

/// True when `running` is strictly newer than `tag` by semver precedence.
///
/// The version model needs an order, not just equality. Equality alone
/// makes every difference look like "an update is available", so a build
/// ahead of the published release -- a development tree at `0.21.0`, a
/// backported patch, a rebased branch -- answers "new release available"
/// and then installs the *older* tag, downgrading the running binary while
/// `modelfs update` reloads the daemon on top of it. Downgrade is not a
/// state the release channel is meant to move in, so the check belongs in
/// the version comparison rather than in the operator's judgement.
///
/// A version either side cannot parse does not answer: the caller keeps the
/// previous behavior for a shape the release process has never published
/// rather than guessing an order from partial strings. `build_options.
/// version` is semver by construction (the `embedded version parses as
/// semver` test in src/main.zig), so in practice only the tag can.
pub fn runningIsNewer(running: []const u8, tag: []const u8) bool {
    const r = std.SemanticVersion.parse(running) catch return false;
    const t = std.SemanticVersion.parse(bareTag(tag)) catch return false;
    return std.SemanticVersion.order(r, t) == .gt;
}

/// Shipped release asset names:
///   x86_64: modelfs-x86_64-linux-musl (static musl binary runs on glibc and musl)
///   aarch64: modelfs-aarch64-linux-gnu (for glibc / sparks fleet) or modelfs-aarch64-linux-musl
pub fn releaseAssetName(arch: std.Target.Cpu.Arch, abi: std.Target.Abi) ?[]const u8 {
    return switch (arch) {
        .x86_64 => "modelfs-x86_64-linux-musl",
        .aarch64 => switch (abi) {
            .gnu => "modelfs-aarch64-linux-gnu",
            else => "modelfs-aarch64-linux-musl",
        },
        else => null,
    };
}

pub fn thisAssetName() ?[]const u8 {
    return releaseAssetName(builtin.cpu.arch, builtin.abi);
}

fn repoPartOk(part: []const u8) bool {
    if (part.len == 0 or part.len > 100) return false;
    if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    for (part) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-')) return false;
    }
    return true;
}

/// `owner/name` only. A URL, a second slash, or an empty side is not a repo.
pub fn validRepo(text: []const u8) bool {
    if (std.mem.indexOf(u8, text, "://") != null) return false;
    const slash = std.mem.findScalar(u8, text, '/') orelse return false;
    const owner = text[0..slash];
    const name = text[slash + 1 ..];
    if (std.mem.findScalar(u8, name, '/') != null) return false;
    return repoPartOk(owner) and repoPartOk(name);
}

/// The release API URL. A repo that is not `owner/name` fails here.
pub fn releaseApiUrl(buf: []u8, repo: []const u8) error{ BadRepo, NameTooLong }![]const u8 {
    if (!validRepo(repo)) return error.BadRepo;
    return std.fmt.bufPrint(buf, "https://api.github.com/repos/{s}/releases/latest", .{repo}) catch
        return error.NameTooLong;
}

fn hostTrusted(host: []const u8) bool {
    var lower: [253]u8 = undefined;
    if (host.len == 0 or host.len > lower.len) return false;
    for (host, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const h = lower[0..host.len];
    if (std.mem.eql(u8, h, "github.com")) return true;
    if (std.mem.endsWith(u8, h, ".github.com")) return true;
    if (std.mem.endsWith(u8, h, ".githubusercontent.com")) return true;
    return false;
}

/// https, and the host is `github.com`, `*.github.com`, or `*.githubusercontent.com`.
/// Userinfo and lookalikes such as `github.com.evil.com` are refused.
pub fn trustedGithubUrl(url: []const u8) bool {
    const prefix = "https://";
    if (url.len < prefix.len) return false;
    for (prefix, 0..) |c, i| {
        if (std.ascii.toLower(url[i]) != c) return false;
    }
    const rest = url[prefix.len..];
    if (std.mem.indexOfAny(u8, rest, "@\\ \t\r\n") != null) return false;
    const slash = std.mem.findScalar(u8, rest, '/') orelse rest.len;
    var host = rest[0..slash];
    if (std.mem.findScalar(u8, host, ':')) |colon| {
        const port = host[colon + 1 ..];
        if (port.len == 0) return false;
        for (port) |c| if (!std.ascii.isDigit(c)) return false;
        host = host[0..colon];
    }
    return hostTrusted(host);
}

/// Extracts the 64-character SHA-256 hex checksum for `asset_name` from SHA256SUMS text.
pub fn parseChecksum(sums_text: []const u8, asset_name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, sums_text, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r \t");
        if (line.len < 66) continue;
        const hex = line[0..64];
        var is_hex = true;
        for (hex) |c| {
            if (!std.ascii.isHex(c)) {
                is_hex = false;
                break;
            }
        }
        if (!is_hex) continue;
        const sep = line[64..66];
        if (!std.mem.eql(u8, sep, "  ") and !std.mem.eql(u8, sep, " *")) continue;
        const file = line[66..];
        if (std.mem.eql(u8, file, asset_name)) {
            return hex;
        }
    }
    return null;
}

/// Matches SHA-256 of `asset_bytes` against `expected_hex`.
pub fn checksumMatches(asset_bytes: []const u8, expected_hex: []const u8) bool {
    if (expected_hex.len != 64) return false;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(asset_bytes, &digest, .{});
    const got = std.fmt.bytesToHex(digest, .lower);
    for (expected_hex, 0..) |c, i| {
        if (std.ascii.toLower(c) != got[i]) return false;
    }
    return true;
}

pub fn decide(in: Inputs) Verdict {
    if (sameRelease(in.running, in.tag)) return .current;
    // Ordering before any download, for the same reason `current` is: a
    // published tag behind the running build is not an update. Checking it
    // here also keeps the caller from spending a 100 MiB asset fetch to
    // reach the same answer.
    if (runningIsNewer(in.running, in.tag)) return .ahead;
    const name = in.asset_name orelse return .unsupported_target;
    const a_url = in.asset_url orelse return .missing_asset;
    if (!trustedGithubUrl(a_url)) return .untrusted_url;
    const s_url = in.sums_url orelse return .missing_checksums;
    if (!trustedGithubUrl(s_url)) return .untrusted_url;
    const bytes = in.asset_bytes orelse return .missing_asset;
    const sums = in.sums_bytes orelse return .missing_checksums;
    const expected_hex = parseChecksum(sums, name) orelse return .checksum_not_found;
    if (!checksumMatches(bytes, expected_hex)) return .checksum_mismatch;
    return .replaced;
}

pub fn formatCurrent(buf: []u8, tool: []const u8, running: []const u8, tag: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s} {s} is current (latest release: {s})", .{ tool, running, tag });
}

/// The running build is ahead of the published release, so there is nothing
/// to install. Spelled out rather than reusing `formatCurrent`, because the
/// two mean opposite things: `current` is "nothing to do because you are up
/// to date", this is "nothing to do because the release is behind you".
pub fn formatAhead(buf: []u8, tool: []const u8, running: []const u8, tag: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s} {s} is newer than the latest release ({s}); not downgrading", .{ tool, running, tag });
}

pub fn formatNewRelease(buf: []u8, tag: []const u8, running: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "New release: {s} (running {s})", .{ tag, running });
}

pub fn formatInstalled(buf: []u8, tag: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "Installed {s} to {s}", .{ tag, path });
}

const RawAsset = struct {
    name: []const u8 = "",
    browser_download_url: []const u8 = "",
};

const RawRelease = struct {
    tag_name: []const u8 = "",
    html_url: []const u8 = "",
    assets: []const RawAsset = &.{},
};

pub fn parseRelease(gpa: std.mem.Allocator, body: []const u8) !Release {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSlice(RawRelease, a, body, .{ .ignore_unknown_fields = true }) catch
        return error.MalformedRelease;

    if (parsed.value.tag_name.len == 0 or parsed.value.html_url.len == 0) {
        return error.MalformedRelease;
    }

    var list: std.ArrayList(ListedAsset) = .empty;
    for (parsed.value.assets) |asset| {
        if (asset.name.len > 0 and asset.browser_download_url.len > 0) {
            try list.append(a, .{
                .name = asset.name,
                .url = asset.browser_download_url,
            });
        }
    }

    return .{
        .tag = parsed.value.tag_name,
        .page = parsed.value.html_url,
        .assets = try list.toOwnedSlice(a),
        .arena = arena,
    };
}

pub fn assetUrl(rel: Release, name: []const u8) ?[]const u8 {
    for (rel.assets) |asset| {
        if (std.mem.eql(u8, asset.name, name)) return asset.url;
    }
    return null;
}

/// Cap on a `GITHUB_TOKEN`, the same bound `pull` holds a Hugging Face
/// token to (`hf.max_token_bytes`). The value is one header on one
/// request, so a longer one is a wrong value to name rather than a
/// credential to send.
pub const max_token_bytes: usize = 4096;

/// The `Bearer` header for `GITHUB_TOKEN`, or null when the operator set
/// none (`pull`'s token loader draws the same line for a missing,
/// whitespace-only, or empty value). A value the request cannot carry is
/// an error, not a null: an oversized token silently became no token, and
/// the operator then read the anonymous rate limit the API answered with
/// as the endpoint being unreachable. Interior CR or LF would end the
/// header early, so that is refused rather than trimmed away.
pub fn githubBearer(buf: []u8, environ: ?*const std.process.Environ.Map) error{ TokenTooLarge, TokenNotHeaderSafe, NameTooLong }!?[]const u8 {
    const map = environ orelse return null;
    const raw = map.get(token_env) orelse return null;
    const tok = std.mem.trim(u8, raw, " \t\r\n");
    if (tok.len == 0) return null;
    for (tok) |ch| {
        if (ch == '\r' or ch == '\n') return error.TokenNotHeaderSafe;
    }
    if (tok.len > max_token_bytes) return error.TokenTooLarge;
    return std.fmt.bufPrint(buf, "Bearer {s}", .{tok}) catch error.NameTooLong;
}

/// The failure one non-200 GitHub answer becomes. 401 and 403 are a
/// credential the API would not take, 404 is a repository it does not
/// publish (or will not show an anonymous caller), and 429 is the
/// documented rate-limit answer; the three are what an operator can act
/// on, so they are named rather than collapsed into one status error the
/// way every other non-200 would be. `hf.listingError` / `hf.downloadError`
/// (src/hf.zig) make the same split of a Hugging Face answer, so both CLI
/// network paths classify an HTTP status identically.
pub fn statusError(status: std.http.Status) error{ HttpDenied, HttpNotFound, HttpRateLimited, HttpStatus } {
    return switch (status) {
        .unauthorized, .forbidden => error.HttpDenied,
        .not_found => error.HttpNotFound,
        .too_many_requests => error.HttpRateLimited,
        else => error.HttpStatus,
    };
}

pub fn fetchUrl(
    io: std.Io,
    gpa: std.mem.Allocator,
    url: []const u8,
    bearer: ?[]const u8,
    max_bytes: usize,
) ![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var auth_store: [1]std.http.Header = undefined;
    const auth: []const std.http.Header = if (bearer) |b| blk: {
        auth_store[0] = .{ .name = "authorization", .value = b };
        break :blk auth_store[0..1];
    } else &.{};

    const buf = try gpa.alloc(u8, max_bytes);
    errdefer gpa.free(buf);

    var writer = std.Io.Writer.fixed(buf);
    var head_buf: [16 << 10]u8 = undefined;

    const res = client.fetch(.{
        .location = .{ .url = url },
        .headers = .{
            .user_agent = .{ .override = tool_name ++ "/" ++ build_options.version },
        },
        .privileged_headers = auth,
        .redirect_buffer = &head_buf,
        .response_writer = &writer,
    }) catch |err| switch (err) {
        error.WriteFailed => if (writer.end >= max_bytes) return error.BodyTooLarge else return error.NetworkError,
        else => return error.NetworkError,
    };

    if (res.status != .ok) {
        return statusError(res.status);
    }
    const written = writer.end;
    const out = try gpa.alloc(u8, written);
    @memcpy(out, buf[0..written]);
    gpa.free(buf);
    return out;
}

pub fn replaceVerifiedPath(dest_path: []const u8, asset_bytes: []const u8) !void {
    var dest_z: [sys.c.PATH_MAX + 1]u8 = undefined;
    const dest_z_slice = try sys.toZ(&dest_z, dest_path);

    var ext_buf: [32]u8 = undefined;
    const ext = std.fmt.bufPrint(&ext_buf, ".tmp.{d}", .{sys.pidSelf()}) catch return error.NameTooLong;
    var stage_buf: [sys.c.PATH_MAX]u8 = undefined;
    const staged = sys.appendExt(&stage_buf, dest_z_slice, ext) catch return error.NameTooLong;

    if (sys.writeFileExec(staged, asset_bytes) != 0) {
        _ = sys.unlink(staged);
        return error.WriteFailed;
    }

    if (sys.rename(staged, dest_z_slice) != 0) {
        _ = sys.unlink(staged);
        return error.RenameFailed;
    }
}

pub fn replaceExecutable(io: std.Io, gpa: std.mem.Allocator, asset_bytes: []const u8) ![]u8 {
    var exe_buf: [sys.c.PATH_MAX]u8 = undefined;
    const exe = try sys.selfExe(io, &exe_buf);
    try replaceVerifiedPath(exe, asset_bytes);
    return try gpa.dupe(u8, exe);
}

test "sameRelease compares tags accurately" {
    try std.testing.expect(sameRelease("0.18.0", "v0.18.0"));
    try std.testing.expect(sameRelease("0.18.0", "0.18.0"));
    try std.testing.expect(!sameRelease("0.18.0", "v0.18.1"));
    try std.testing.expect(!sameRelease("0.18.1", "v0.18.10"));
    try std.testing.expect(!sameRelease("0.18.0", "v0.19.0"));
}

test "runningIsNewer orders versions, not just compares them" {
    try std.testing.expect(runningIsNewer("0.19.0", "v0.18.0"));
    try std.testing.expect(runningIsNewer("1.0.0", "v0.99.99"));
    try std.testing.expect(runningIsNewer("0.18.10", "v0.18.9"));
    try std.testing.expect(runningIsNewer("0.18.1", "v0.18.0"));
    try std.testing.expect(runningIsNewer("0.18.0", "v0.18.0-rc.1"));
    // Not newer: older, or equal by precedence with a different spelling.
    try std.testing.expect(!runningIsNewer("0.18.0", "v0.18.0"));
    try std.testing.expect(!runningIsNewer("0.18.0", "v0.18.0+build"));
    try std.testing.expect(!runningIsNewer("0.17.9", "v0.18.0"));
    try std.testing.expect(!runningIsNewer("0.18.0", "v0.18.10"));
    // A shape either side cannot parse answers nothing, so an unpublished
    // tag spelling keeps the old behavior instead of ordering by string.
    try std.testing.expect(!runningIsNewer("0.18.0", "nightly"));
    try std.testing.expect(!runningIsNewer("dev", "v0.18.0"));
}

test "releaseAssetName maps architecture and abi to correct asset" {
    try std.testing.expectEqualStrings("modelfs-x86_64-linux-musl", releaseAssetName(.x86_64, .musl).?);
    try std.testing.expectEqualStrings("modelfs-x86_64-linux-musl", releaseAssetName(.x86_64, .gnu).?);
    try std.testing.expectEqualStrings("modelfs-aarch64-linux-gnu", releaseAssetName(.aarch64, .gnu).?);
    try std.testing.expectEqualStrings("modelfs-aarch64-linux-musl", releaseAssetName(.aarch64, .musl).?);
    try std.testing.expect(releaseAssetName(.riscv64, .gnu) == null);
}

test "validRepo validates owner/name syntax" {
    try std.testing.expect(validRepo("maci0/modelfs"));
    try std.testing.expect(validRepo("foo-bar/baz_qux"));
    try std.testing.expect(!validRepo("https://github.com/maci0/modelfs"));
    try std.testing.expect(!validRepo("maci0"));
    try std.testing.expect(!validRepo("a/b/c"));
    try std.testing.expect(!validRepo("/modelfs"));
    try std.testing.expect(!validRepo("maci0/"));
    try std.testing.expect(!validRepo("./modelfs"));
    try std.testing.expect(!validRepo("maci0/.."));
}

test "releaseApiUrl formats endpoint" {
    var buf: [128]u8 = undefined;
    const url = try releaseApiUrl(&buf, "maci0/modelfs");
    try std.testing.expectEqualStrings("https://api.github.com/repos/maci0/modelfs/releases/latest", url);
    try std.testing.expectError(error.BadRepo, releaseApiUrl(&buf, "invalid"));
}

test "trustedGithubUrl validates host and scheme" {
    try std.testing.expect(trustedGithubUrl("https://api.github.com/repos/maci0/modelfs/releases/latest"));
    try std.testing.expect(trustedGithubUrl("https://github.com/maci0/modelfs/releases/download/v0.18.0/SHA256SUMS"));
    try std.testing.expect(trustedGithubUrl("https://objects.githubusercontent.com/github-production-release-asset-2e65be/1234"));
    try std.testing.expect(!trustedGithubUrl("http://api.github.com/repos/maci0/modelfs"));
    try std.testing.expect(!trustedGithubUrl("https://github.com.attacker.com/fake"));
    try std.testing.expect(!trustedGithubUrl("https://evil@github.com/fake"));
    try std.testing.expect(!trustedGithubUrl("ftp://github.com/file"));
}

test "parseChecksum extracts expected checksum line" {
    const sample =
        \\6fbba5989fb5c29547732d963a69cfd60fa43137ed79658eceeb45b925b97c94  modelfs-aarch64-linux-gnu
        \\282fca174c956af78b5e7b98d3359db092043ccdafd3a863ac44a20a7aaa4328  modelfs-aarch64-linux-musl
        \\91d7ed45e20ca953753631f1f18794a267bfe605de031ae4540d6db97cc7311e  modelfs-licenses.tar.gz
        \\951ec8daf1bff678130b40e4fe51722a1e6d1d003005f039bfea97b5a1471261 *modelfs-x86_64-linux-musl
        \\
    ;
    try std.testing.expectEqualStrings(
        "6fbba5989fb5c29547732d963a69cfd60fa43137ed79658eceeb45b925b97c94",
        parseChecksum(sample, "modelfs-aarch64-linux-gnu").?,
    );
    try std.testing.expectEqualStrings(
        "951ec8daf1bff678130b40e4fe51722a1e6d1d003005f039bfea97b5a1471261",
        parseChecksum(sample, "modelfs-x86_64-linux-musl").?,
    );
    try std.testing.expect(parseChecksum(sample, "nonexistent") == null);
}

test "checksumMatches checks sha256 bytes" {
    const data = "abc";
    // NIST standard test vector sha256("abc"):
    const expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    const expected_upper = "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD";
    try std.testing.expect(checksumMatches(data, expected));
    try std.testing.expect(checksumMatches(data, expected_upper));
    try std.testing.expect(!checksumMatches("wrong", expected));
    try std.testing.expect(!checksumMatches(data, "short"));
}

test "decide evaluates release inputs correctly" {
    const data = "abc";
    const sums = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  modelfs-x86_64-linux-musl\n";

    try std.testing.expectEqual(Verdict.current, decide(.{
        .running = "0.18.0",
        .tag = "v0.18.0",
    }));

    try std.testing.expectEqual(Verdict.unsupported_target, decide(.{
        .running = "0.18.0",
        .tag = "v0.19.0",
        .asset_name = null,
    }));

    try std.testing.expectEqual(Verdict.missing_asset, decide(.{
        .running = "0.18.0",
        .tag = "v0.19.0",
        .asset_name = "modelfs-x86_64-linux-musl",
        .asset_url = null,
    }));

    try std.testing.expectEqual(Verdict.untrusted_url, decide(.{
        .running = "0.18.0",
        .tag = "v0.19.0",
        .asset_name = "modelfs-x86_64-linux-musl",
        .asset_url = "http://evil.com/asset",
        .sums_url = "https://github.com/maci0/modelfs/releases/download/v0.19.0/SHA256SUMS",
        .asset_bytes = data,
        .sums_bytes = sums,
    }));

    try std.testing.expectEqual(Verdict.checksum_mismatch, decide(.{
        .running = "0.18.0",
        .tag = "v0.19.0",
        .asset_name = "modelfs-x86_64-linux-musl",
        .asset_url = "https://github.com/maci0/modelfs/releases/download/v0.19.0/modelfs-x86_64-linux-musl",
        .sums_url = "https://github.com/maci0/modelfs/releases/download/v0.19.0/SHA256SUMS",
        .asset_bytes = "tampered bytes",
        .sums_bytes = sums,
    }));

    try std.testing.expectEqual(Verdict.checksum_not_found, decide(.{
        .running = "0.18.0",
        .tag = "v0.19.0",
        .asset_name = "modelfs-aarch64-linux-musl",
        .asset_url = "https://github.com/maci0/modelfs/releases/download/v0.19.0/modelfs-aarch64-linux-musl",
        .sums_url = "https://github.com/maci0/modelfs/releases/download/v0.19.0/SHA256SUMS",
        .asset_bytes = data,
        .sums_bytes = sums,
    }));

    try std.testing.expectEqual(Verdict.replaced, decide(.{
        .running = "0.18.0",
        .tag = "v0.19.0",
        .asset_name = "modelfs-x86_64-linux-musl",
        .asset_url = "https://github.com/maci0/modelfs/releases/download/v0.19.0/modelfs-x86_64-linux-musl",
        .sums_url = "https://github.com/maci0/modelfs/releases/download/v0.19.0/SHA256SUMS",
        .asset_bytes = data,
        .sums_bytes = sums,
    }));
}

test "decide refuses to downgrade a build ahead of the published release" {
    // Every input here would otherwise reach .replaced: the asset and the
    // sums are present, trusted, and the checksum matches. Only the version
    // order says the release is older than what is running.
    const data = "abc";
    const sums = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  modelfs-x86_64-linux-musl\n";
    const inputs = [_]struct { running: []const u8, tag: []const u8 }{
        .{ .running = "0.19.0", .tag = "v0.18.0" },
        .{ .running = "0.18.1", .tag = "v0.18.0" },
        .{ .running = "0.18.10", .tag = "v0.18.9" },
        // A prerelease of the running line: v0.19.0-rc.1 is older than the
        // 0.19.0 that built it.
        .{ .running = "0.19.0", .tag = "v0.19.0-rc.1" },
    };
    inline for (inputs) |in| {
        try std.testing.expectEqual(Verdict.ahead, decide(.{
            .running = in.running,
            .tag = in.tag,
            .asset_name = "modelfs-x86_64-linux-musl",
            .asset_url = "https://github.com/maci0/modelfs/releases/download/v0.19.0/modelfs-x86_64-linux-musl",
            .sums_url = "https://github.com/maci0/modelfs/releases/download/v0.19.0/SHA256SUMS",
            .asset_bytes = data,
            .sums_bytes = sums,
        }));
    }
    // A tag the version model cannot parse answers nothing, so it keeps
    // the pre-existing behavior rather than silently refusing to update.
    try std.testing.expectEqual(Verdict.replaced, decide(.{
        .running = "0.18.0",
        .tag = "nightly",
        .asset_name = "modelfs-x86_64-linux-musl",
        .asset_url = "https://github.com/maci0/modelfs/releases/download/nightly/modelfs-x86_64-linux-musl",
        .sums_url = "https://github.com/maci0/modelfs/releases/download/nightly/SHA256SUMS",
        .asset_bytes = data,
        .sums_bytes = sums,
    }));
}

test "formatAhead says the release is behind, not that the build is current" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "modelfs 0.19.0 is newer than the latest release (v0.18.0); not downgrading",
        try formatAhead(&buf, tool_name, "0.19.0", "v0.18.0"),
    );
    // The current line reads the other way round, and the two must not
    // collapse into one message.
    try std.testing.expectEqualStrings(
        "modelfs 0.19.0 is current (latest release: v0.19.0)",
        try formatCurrent(&buf, tool_name, "0.19.0", "v0.19.0"),
    );
}

test "parseRelease extracts metadata and assets from json" {
    const json =
        \\{
        \\  "tag_name": "v0.17.0",
        \\  "html_url": "https://github.com/maci0/modelfs/releases/tag/v0.17.0",
        \\  "assets": [
        \\    {
        \\      "name": "modelfs-x86_64-linux-musl",
        \\      "browser_download_url": "https://github.com/maci0/modelfs/releases/download/v0.17.0/modelfs-x86_64-linux-musl"
        \\    },
        \\    {
        \\      "name": "SHA256SUMS",
        \\      "browser_download_url": "https://github.com/maci0/modelfs/releases/download/v0.17.0/SHA256SUMS"
        \\    }
        \\  ]
        \\}
    ;
    var rel = try parseRelease(std.testing.allocator, json);
    defer rel.deinit();

    try std.testing.expectEqualStrings("v0.17.0", rel.tag);
    try std.testing.expectEqualStrings("https://github.com/maci0/modelfs/releases/tag/v0.17.0", rel.page);
    try std.testing.expectEqual(@as(usize, 2), rel.assets.len);
    try std.testing.expectEqualStrings(
        "https://github.com/maci0/modelfs/releases/download/v0.17.0/SHA256SUMS",
        assetUrl(rel, "SHA256SUMS").?,
    );
    try std.testing.expect(assetUrl(rel, "missing") == null);
}

test "githubBearer names a token the request cannot carry" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var buf: [max_token_bytes + "Bearer ".len]u8 = undefined;

    try std.testing.expect((try githubBearer(&buf, null)) == null);
    try std.testing.expect((try githubBearer(&buf, &environ)) == null);
    try environ.put(token_env, "  \t\r\n");
    try std.testing.expect((try githubBearer(&buf, &environ)) == null);

    try environ.put(token_env, "  ghp_example  ");
    try std.testing.expectEqualStrings("Bearer ghp_example", (try githubBearer(&buf, &environ)).?);

    // The two shapes that used to read as no token at all: the operator
    // set a value and the request could not carry it.
    try environ.put(token_env, "x" ** (max_token_bytes + 1));
    try std.testing.expectError(error.TokenTooLarge, githubBearer(&buf, &environ));
    try environ.put(token_env, "ghp_line\nbreak");
    try std.testing.expectError(error.TokenNotHeaderSafe, githubBearer(&buf, &environ));

    // The maximum the cap admits still forms its header whole.
    try environ.put(token_env, "x" ** max_token_bytes);
    try std.testing.expectEqualStrings("Bearer " ++ "x" ** max_token_bytes, (try githubBearer(&buf, &environ)).?);
}

test "statusError names the refusals an operator can act on" {
    try std.testing.expectEqual(error.HttpDenied, statusError(.unauthorized));
    try std.testing.expectEqual(error.HttpDenied, statusError(.forbidden));
    try std.testing.expectEqual(error.HttpNotFound, statusError(.not_found));
    try std.testing.expectEqual(error.HttpRateLimited, statusError(.too_many_requests));
    // A 200 never reaches the mapping, and every other refusal stays the
    // one unclassified status rather than borrowing another's name.
    try std.testing.expectEqual(error.HttpStatus, statusError(.internal_server_error));
    try std.testing.expectEqual(error.HttpStatus, statusError(.not_implemented));
    try std.testing.expectEqual(error.HttpStatus, statusError(.bad_gateway));
}

test "replaceVerifiedPath atomically installs binary with 0755 permissions" {
    var db: [128]u8 = undefined;
    const scratch = try sys.scratchDir(&db, "modelfs-replace-bin");
    defer sys.deleteTree(std.testing.io, scratch);
    var pb: [192]u8 = undefined;
    const bin_path = try std.fmt.bufPrintZ(&pb, "{s}/target_bin", .{scratch});

    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(bin_path, "old_version"));

    const new_bin_data = "#!/bin/sh\necho updated\n";
    try replaceVerifiedPath(bin_path, new_bin_data);

    var rbuf: [64]u8 = undefined;
    const read = try sys.readFileBuf(&rbuf, bin_path);
    try std.testing.expectEqualStrings(new_bin_data, read);

    var st: sys.c.struct_stat = undefined;
    try std.testing.expectEqual(@as(i32, 0), sys.statPath(bin_path, &st));
    try std.testing.expectEqual(@as(sys.c.mode_t, 0o755), st.st_mode & 0o777);
}
