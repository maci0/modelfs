//! Hugging Face model pulls for `modelfs pull`: repo/revision validation,
//! the listing and download endpoints, and the loop that lands a revision's
//! files on the NFS origin. CLI-only, over HTTPS with the platform trust
//! store; the daemon itself never speaks to anything but its peers.
const std = @import("std");
const discover = @import("discover.zig");
const store_mod = @import("store.zig");
const sys = @import("sys.zig");

pub const host = "huggingface.co";
pub const default_revision = "main";

/// Cap on a repo listing. The largest model repos list a few thousand
/// files; 8 MiB of JSON is well past any of them and keeps a broken or
/// hostile endpoint from driving an unbounded allocation.
pub const max_listing_bytes: usize = 8 << 20;

/// Suffix a download carries until its bytes are complete. A pull that dies
/// mid-file leaves this behind rather than a short file at the real name
/// that a later pull would count as already done.
pub const partial_ext = ".part";

/// Where the access token comes from. Never a flag: argv is world-readable
/// through /proc/<pid>/cmdline, the same reason `--psk-value` does not
/// exist. `HF_TOKEN` first, then the file `huggingface-cli login` writes.
pub const token_env = "HF_TOKEN";
pub const home_env = "HF_HOME";
pub const token_under_home = "token";
pub const token_under_cache = ".cache/huggingface/token";

/// Hugging Face caps ids at 96 characters per part; this bounds the URL
/// buffers rather than restating their rule.
pub const max_repo_bytes: usize = 200;
pub const max_revision_bytes: usize = 200;

/// Unreserved characters (RFC 3986). Anything else in a repo file name is
/// percent-encoded before it reaches a URL, so a name holding '?' or '#'
/// cannot end the path early or graft on a query string.
fn unreserved(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or ch == '-' or ch == '.' or ch == '_' or ch == '~';
}

/// Ids and refs are spliced into URLs as written, so they are held to the
/// unreserved set plus the separators their own syntax needs. A repo id or
/// ref outside it is a typo, not something to encode around.
fn idOk(s: []const u8, max: usize, extra: []const u8) bool {
    if (s.len == 0 or s.len > max) return false;
    for (s) |ch| {
        if (unreserved(ch)) continue;
        if (std.mem.indexOfScalar(u8, extra, ch) != null) continue;
        return false;
    }
    return true;
}

/// True when every "/"-separated part is non-empty and is not "." or "..",
/// which a URL-normalizing client would collapse into a different endpoint.
fn segmentsOk(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return false;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

/// `owner/name`, the only shape the model endpoints take.
pub fn repoOk(repo: []const u8) bool {
    if (!idOk(repo, max_repo_bytes, "/")) return false;
    if (!segmentsOk(repo)) return false;
    const slash = std.mem.indexOfScalar(u8, repo, '/') orelse return false;
    return std.mem.lastIndexOfScalar(u8, repo, '/').? == slash;
}

/// A branch, a tag, or a commit sha. Branches may hold '/'.
pub fn revisionOk(rev: []const u8) bool {
    if (!idOk(rev, max_revision_bytes, "/")) return false;
    return segmentsOk(rev);
}

fn appendEncoded(w: *std.ArrayList(u8), gpa: std.mem.Allocator, path: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (path) |ch| {
        if (unreserved(ch) or ch == '/') {
            try w.append(gpa, ch);
            continue;
        }
        try w.append(gpa, '%');
        try w.append(gpa, hex[ch >> 4]);
        try w.append(gpa, hex[ch & 0xf]);
    }
}

/// The recursive file listing for one revision: type, path, and size per
/// entry. Caller frees.
pub fn treeUrl(gpa: std.mem.Allocator, repo: []const u8, revision: []const u8) ![]u8 {
    if (!repoOk(repo)) return error.BadRepo;
    if (!revisionOk(revision)) return error.BadRevision;
    return std.fmt.allocPrint(gpa, "https://" ++ host ++ "/api/models/{s}/tree/{s}?recursive=1", .{ repo, revision });
}

/// One file's bytes at that revision. Caller frees.
pub fn fileUrl(gpa: std.mem.Allocator, repo: []const u8, revision: []const u8, path: []const u8) ![]u8 {
    if (!repoOk(repo)) return error.BadRepo;
    if (!revisionOk(revision)) return error.BadRevision;
    var w: std.ArrayList(u8) = .empty;
    errdefer w.deinit(gpa);
    try w.appendSlice(gpa, "https://" ++ host ++ "/");
    try w.appendSlice(gpa, repo);
    try w.appendSlice(gpa, "/resolve/");
    try w.appendSlice(gpa, revision);
    try w.append(gpa, '/');
    try appendEncoded(&w, gpa, path);
    return w.toOwnedSlice(gpa);
}

pub const Entry = struct { path: []const u8, size: u64 };

pub const Listing = struct {
    entries: []Entry,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Listing) void {
        self.arena.deinit();
    }
};

const TreeItem = struct {
    type: []const u8 = "",
    path: []const u8 = "",
    size: u64 = 0,
};

/// Files in the listing, directories dropped. Every path is endpoint input:
/// one that would escape the destination, name the cluster control dir, or
/// carry control bytes is refused here, before any of it reaches a join
/// against the origin.
pub fn parseTree(gpa: std.mem.Allocator, json: []const u8, dest: []const u8) !Listing {
    const parsed = std.json.parseFromSlice([]TreeItem, gpa, json, .{ .ignore_unknown_fields = true }) catch return error.BadListing;
    defer parsed.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var list: std.ArrayList(Entry) = .empty;
    for (parsed.value) |item| {
        if (!std.mem.eql(u8, item.type, "file")) continue;
        if (!store_mod.relOk(item.path)) return error.BadEntryPath;
        var rel_buf: [sys.c.PATH_MAX]u8 = undefined;
        const rel = joinRel(&rel_buf, dest, item.path) catch return error.BadEntryPath;
        if (!store_mod.relOk(rel) or discover.relIsCluster(rel)) return error.BadEntryPath;
        try list.append(a, .{ .path = try a.dupe(u8, item.path), .size = item.size });
    }
    return .{ .entries = try list.toOwnedSlice(a), .arena = arena };
}

/// `dest/path`, or just `path` when the destination is the origin root.
pub fn joinRel(buf: []u8, dest: []const u8, path: []const u8) ![]const u8 {
    if (dest.len == 0) {
        if (path.len > buf.len) return error.NameTooLong;
        @memcpy(buf[0..path.len], path);
        return buf[0..path.len];
    }
    if (dest.len + 1 + path.len > buf.len) return error.NameTooLong;
    @memcpy(buf[0..dest.len], dest);
    buf[dest.len] = '/';
    @memcpy(buf[dest.len + 1 ..][0..path.len], path);
    return buf[0 .. dest.len + 1 + path.len];
}

/// The access token, or null when the host has none configured. Caller
/// frees. A read failure on the token file is not an error: an anonymous
/// pull of a public repo is the common case.
pub fn loadToken(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) !?[]u8 {
    if (environ.get(token_env)) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len != 0) return try gpa.dupe(u8, trimmed);
    }
    var path_buf: [sys.c.PATH_MAX]u8 = undefined;
    const path = blk: {
        if (environ.get(home_env)) |hf_home| {
            if (hf_home.len != 0) break :blk sys.joinZ(&path_buf, hf_home, token_under_home) catch return null;
        }
        const home = environ.get("HOME") orelse return null;
        if (home.len == 0) return null;
        break :blk sys.joinZ(&path_buf, home, token_under_cache) catch return null;
    };
    const blob = sys.readFileAlloc(gpa, path, 4096) catch return null;
    defer gpa.free(blob);
    const trimmed = std.mem.trim(u8, blob, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try gpa.dupe(u8, trimmed);
}

pub const Report = struct {
    pulled: u32 = 0,
    skipped: u32 = 0,
    bytes: u64 = 0,
};

/// Streaming buffers. One request head and one body chunk at a time: a
/// model file is gigabytes and never lands in memory whole.
const head_buffer_bytes: usize = 16 << 10;
const body_buffer_bytes: usize = 1 << 20;

/// Downloads every file of `repo` at `revision` under `origin/dest`, skipping
/// what is already there at the listed size. Returns on the first failure
/// with `report` describing what did land, so a rerun resumes.
pub fn pull(
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    origin: []const u8,
    dest: []const u8,
    repo: []const u8,
    revision: []const u8,
    token: ?[]const u8,
    report: *Report,
) !void {
    var auth_buf: [512]u8 = undefined;
    var auth_store: [1]std.http.Header = undefined;
    // The privileged set, not extra_headers: a `resolve` URL redirects to a
    // signed CDN host, and the token must not follow it there.
    const auth: []const std.http.Header = if (token) |t| blk: {
        auth_store[0] = .{ .name = "authorization", .value = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{t}) };
        break :blk auth_store[0..1];
    } else &.{};

    const listing_url = try treeUrl(gpa, repo, revision);
    defer gpa.free(listing_url);
    var listing_writer = std.Io.Writer.Allocating.init(gpa);
    defer listing_writer.deinit();
    const listing_res = client.fetch(.{
        .location = .{ .url = listing_url },
        .privileged_headers = auth,
        .response_writer = &listing_writer.writer,
    }) catch return error.ListingFailed;
    if (listing_res.status != .ok) {
        std.log.err("{s} listing {s}@{s} answered {d}", .{ host, repo, revision, @intFromEnum(listing_res.status) });
        return switch (listing_res.status) {
            .unauthorized, .forbidden => error.ListingDenied,
            .not_found => error.RepoNotFound,
            else => error.ListingFailed,
        };
    }
    if (listing_writer.written().len > max_listing_bytes) return error.ListingTooLarge;

    var listing = try parseTree(gpa, listing_writer.written(), dest);
    defer listing.deinit();
    if (listing.entries.len == 0) return error.EmptyRevision;

    const body_buf = try gpa.alloc(u8, body_buffer_bytes);
    defer gpa.free(body_buf);

    for (listing.entries) |entry| {
        var rel_buf: [sys.c.PATH_MAX]u8 = undefined;
        const rel = try joinRel(&rel_buf, dest, entry.path);
        var path_buf: [sys.c.PATH_MAX]u8 = undefined;
        const path = try sys.joinZ(&path_buf, origin, rel);

        var st: sys.c.struct_stat = undefined;
        if (sys.statPath(path, &st) == 0) {
            const have = sys.sizeFromStat(st.st_size) orelse 0;
            if (have == entry.size) {
                report.skipped += 1;
                continue;
            }
        }
        try fetchOne(gpa, io, client, origin, rel, path, repo, revision, entry, auth, body_buf);
        report.pulled += 1;
        report.bytes += entry.size;
        std.log.info("pulled {s} ({d} bytes)", .{ rel, entry.size });
    }
}

fn fetchOne(
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    origin: []const u8,
    rel: []const u8,
    path: [*:0]const u8,
    repo: []const u8,
    revision: []const u8,
    entry: Entry,
    auth: []const std.http.Header,
    body_buf: []u8,
) !void {
    const parent = sys.parentOf(rel);
    // "." is parentOf's answer for a name with no directory part: the file
    // lands straight under the origin and there is nothing to create.
    if (!std.mem.eql(u8, parent, ".")) {
        var dir_buf: [sys.c.PATH_MAX]u8 = undefined;
        const dir = try sys.joinZ(&dir_buf, origin, parent);
        const rc = sys.mkdirAll(std.mem.span(dir), 0o755);
        if (rc != 0) {
            std.log.err("cannot create {s} on the origin (errno {d})", .{ parent, -rc });
            return error.MakeDirFailed;
        }
    }

    var part_buf: [sys.c.PATH_MAX]u8 = undefined;
    const part = try sys.appendExt(&part_buf, path, partial_ext);
    // O_NOFOLLOW like every other write into a tree other hosts can plant
    // names in: a symlink staged at this name must not redirect the pull.
    // O_TRUNC because a leftover part file from a dead pull is not resumable
    // (the endpoint is fetched whole, no ranged restart).
    const fd = sys.open(part, sys.c.O_CREAT | sys.c.O_WRONLY | sys.c.O_TRUNC | sys.c.O_NOFOLLOW | sys.c.O_NONBLOCK, 0o644);
    if (fd < 0) {
        std.log.err("cannot open {s}{s} on the origin (errno {d})", .{ rel, partial_ext, -sys.negErrno() });
        return error.OpenFailed;
    }
    var closed = false;
    errdefer {
        if (!closed) sys.close(fd);
        _ = sys.unlink(part);
    }
    // O_NONBLOCK did its job at open time; the writer below expects a
    // blocking fd, and a regular file has nothing to poll for anyway.
    var fst: sys.c.struct_stat = undefined;
    if (sys.fstat(fd, &fst) != 0) return error.OpenFailed;
    if ((fst.st_mode & sys.c.S_IFMT) != sys.c.S_IFREG) return error.NotRegular;
    if (sys.setNonblocking(fd, false) != 0) return error.OpenFailed;

    const url = try fileUrl(gpa, repo, revision, entry.path);
    defer gpa.free(url);
    var file_writer = (std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } }).writerStreaming(io, body_buf);
    var head_buf: [head_buffer_bytes]u8 = undefined;
    const res = client.fetch(.{
        .location = .{ .url = url },
        .privileged_headers = auth,
        .redirect_buffer = &head_buf,
        .response_writer = &file_writer.interface,
    }) catch return error.DownloadFailed;
    if (res.status != .ok) {
        std.log.err("{s} answered {d} for {s}", .{ host, @intFromEnum(res.status), entry.path });
        return error.DownloadFailed;
    }
    file_writer.interface.flush() catch return error.WriteFailed;

    closed = true;
    if (sys.closeWrite(fd) != 0) {
        _ = sys.unlink(part);
        return error.WriteFailed;
    }
    // Only now does the file take its real name: a pull that dies mid-body
    // must not leave a short file the next run counts as already there.
    if (sys.rename(part, path) != 0) {
        _ = sys.unlink(part);
        return error.RenameFailed;
    }
}

test "repo and revision ids take only what goes into a URL as written" {
    try std.testing.expect(repoOk("meta-llama/Llama-3.1-8B"));
    try std.testing.expect(repoOk("a/b"));
    try std.testing.expect(!repoOk("no-slash"));
    try std.testing.expect(!repoOk("/leading"));
    try std.testing.expect(!repoOk("trailing/"));
    try std.testing.expect(!repoOk("too/many/slashes"));
    try std.testing.expect(!repoOk(""));
    // Anything that would change the meaning of the URL it is pasted into.
    try std.testing.expect(!repoOk("owner/name?x=1"));
    try std.testing.expect(!repoOk("owner/name#frag"));
    try std.testing.expect(!repoOk("owner/na me"));
    // A URL-normalizing client collapses these into a different endpoint.
    try std.testing.expect(!repoOk("owner/.."));
    try std.testing.expect(!repoOk("owner/."));
    try std.testing.expect(!revisionOk("refs/../main"));
    try std.testing.expect(!revisionOk(".."));

    try std.testing.expect(revisionOk("main"));
    try std.testing.expect(revisionOk("refs/pr/3"));
    try std.testing.expect(revisionOk("a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"));
    try std.testing.expect(!revisionOk(""));
    try std.testing.expect(!revisionOk("/main"));
    try std.testing.expect(!revisionOk("main/"));
    try std.testing.expect(!revisionOk("main?x"));
}

test "fileUrl percent-encodes a repo file name and treeUrl asks for the whole tree" {
    const gpa = std.testing.allocator;
    const tree = try treeUrl(gpa, "meta-llama/Llama-3.1-8B", "main");
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(
        "https://huggingface.co/api/models/meta-llama/Llama-3.1-8B/tree/main?recursive=1",
        tree,
    );

    const plain = try fileUrl(gpa, "a/b", "main", "sub/model.gguf");
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("https://huggingface.co/a/b/resolve/main/sub/model.gguf", plain);

    // A name that would otherwise open a query string or cut the path short.
    const odd = try fileUrl(gpa, "a/b", "main", "we ird/name?x#y.bin");
    defer gpa.free(odd);
    try std.testing.expectEqualStrings("https://huggingface.co/a/b/resolve/main/we%20ird/name%3Fx%23y.bin", odd);

    try std.testing.expectError(error.BadRepo, treeUrl(gpa, "nope", "main"));
    try std.testing.expectError(error.BadRevision, fileUrl(gpa, "a/b", "ma in", "x"));
}

test "parseTree keeps files, drops directories, and refuses an escaping path" {
    const gpa = std.testing.allocator;
    const doc =
        \\[{"type":"directory","path":"sub","size":0},
        \\ {"type":"file","path":"config.json","size":614},
        \\ {"type":"file","path":"sub/model.safetensors","size":16060522496,"lfs":{"size":16060522496}}]
    ;
    var listing = try parseTree(gpa, doc, "meta/llama");
    defer listing.deinit();
    try std.testing.expectEqual(@as(usize, 2), listing.entries.len);
    try std.testing.expectEqualStrings("config.json", listing.entries[0].path);
    try std.testing.expectEqual(@as(u64, 614), listing.entries[0].size);
    try std.testing.expectEqualStrings("sub/model.safetensors", listing.entries[1].path);
    try std.testing.expectEqual(@as(u64, 16060522496), listing.entries[1].size);

    // Endpoint input is a trust boundary: a listing may not write outside
    // the destination or plant a lease file.
    try std.testing.expectError(error.BadEntryPath, parseTree(gpa, "[{\"type\":\"file\",\"path\":\"../escape\",\"size\":1}]", "d"));
    try std.testing.expectError(error.BadEntryPath, parseTree(gpa, "[{\"type\":\"file\",\"path\":\"/abs\",\"size\":1}]", "d"));
    try std.testing.expectError(error.BadEntryPath, parseTree(gpa, "[{\"type\":\"file\",\"path\":\"a\\nb\",\"size\":1}]", "d"));
    // The same name is fine below a destination but not at the origin root,
    // where it would be the cluster control dir.
    try std.testing.expectError(error.BadEntryPath, parseTree(gpa, "[{\"type\":\"file\",\"path\":\".cluster/x.json\",\"size\":1}]", ""));
    {
        var ok = try parseTree(gpa, "[{\"type\":\"file\",\"path\":\".cluster/x.json\",\"size\":1}]", "d");
        defer ok.deinit();
        try std.testing.expectEqual(@as(usize, 1), ok.entries.len);
    }
    try std.testing.expectError(error.BadListing, parseTree(gpa, "{not json", "d"));
}

test "joinRel joins under a destination and passes a bare path through" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("d/a/b.bin", try joinRel(&buf, "d", "a/b.bin"));
    try std.testing.expectEqualStrings("a/b.bin", try joinRel(&buf, "", "a/b.bin"));
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.NameTooLong, joinRel(&tiny, "dest", "path"));
}

test "loadToken prefers the environment and never needs a flag" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    try std.testing.expectEqual(@as(?[]u8, null), try loadToken(gpa, &env));

    try env.put(token_env, "  hf_fromenv \n");
    const from_env = (try loadToken(gpa, &env)).?;
    defer gpa.free(from_env);
    try std.testing.expectEqualStrings("hf_fromenv", from_env);

    // A whitespace-only value counts as unset, like every other secret this
    // tree reads, so a stray newline in an EnvironmentFile cannot become
    // the token and 401 the whole pull.
    try env.put(token_env, "   ");
    var dir_buf: [128]u8 = undefined;
    const home = try sys.scratchDir(&dir_buf, "modelfs-hf-token");
    defer sys.deleteTree(std.testing.io, home);
    var path_buf: [256]u8 = undefined;
    const path = try sys.joinZ(&path_buf, home, token_under_home);
    try std.testing.expectEqual(@as(i32, 0), sys.writeFile(path, "hf_fromfile\n"));
    try env.put(home_env, home);
    const from_file = (try loadToken(gpa, &env)).?;
    defer gpa.free(from_file);
    try std.testing.expectEqualStrings("hf_fromfile", from_file);
}
