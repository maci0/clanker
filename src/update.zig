//! `clanker update`: compare this build with the latest GitHub release and,
//! when asked to install, replace the running executable only after its bytes
//! match the `.sha256` sidecar the release job already publishes.
//!
//! The decision (repo shape, exact version, asset name, checksum, trusted
//! URL) is pure. `cmdUpdate` is the only function that talks to GitHub or
//! names the running executable, and a test never calls it.

const std = @import("std");
const builtin = @import("builtin");
const atomic_write = @import("util/atomic_write.zig");
const http_client = @import("util/http_client.zig");

const version = @import("build_options").version;

pub const default_repo = "maci0/clanker";
pub const tool_name = "clanker";

pub const Verdict = enum {
    current,
    missing_asset,
    untrusted_url,
    missing_sidecar,
    checksum_mismatch,
    replaced,
};

pub const Inputs = struct {
    running: []const u8,
    tag: []const u8,
    asset_url: ?[]const u8 = null,
    asset: ?[]const u8 = null,
    sidecar_url: ?[]const u8 = null,
    sidecar: ?[]const u8 = null,
    basename: []const u8 = "",
};

pub const ListedAsset = struct {
    name: []const u8,
    url: []const u8,
};

pub const Release = struct {
    tag: []const u8,
    page: []const u8,
    assets: []const ListedAsset,
};

/// One leading `v` on the tag, then exact equality. `v0.6.10` is not `0.6.1`.
pub fn sameRelease(running: []const u8, tag: []const u8) bool {
    const bare = if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
    return std.mem.eql(u8, running, bare);
}

pub fn thisTarget(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}-{s}-{s}", .{
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        @tagName(builtin.abi),
    }) catch buf[0..0];
}

pub fn writeAssetName(buf: []u8, tag: []const u8, target: []const u8) error{NameTooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "clanker-{s}-{s}", .{ tag, target }) catch return error.NameTooLong;
}

pub fn writeSidecarName(buf: []u8, asset_name: []const u8) error{NameTooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.sha256", .{asset_name}) catch return error.NameTooLong;
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

/// The release API URL. A repo that is not `owner/name` fails here, before
/// any bytes are requested.
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
/// Userinfo and a lookalike such as `github.com.evil.com` are refused.
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

/// Stdout of `--check` is this URL, or nothing when the page is not a GitHub https URL.
pub fn releasePageLine(url: []const u8) error{UntrustedUrl}![]const u8 {
    if (!trustedGithubUrl(url)) return error.UntrustedUrl;
    return url;
}

/// `--check` never downloads an asset. An equal version never does either.
pub fn fetchesAsset(check_only: bool, running: []const u8, tag: []const u8) bool {
    if (check_only) return false;
    return !sameRelease(running, tag);
}

/// Sidecar line from `scripts/release-checksum.sh`: `<hex>  <basename>`.
pub fn checksumMatches(asset: []const u8, sidecar: []const u8, basename: []const u8) bool {
    const line_end = std.mem.findScalar(u8, sidecar, '\n') orelse sidecar.len;
    var line = sidecar[0..line_end];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    if (line.len < 66) return false;
    const hex = line[0..64];
    if (!std.mem.eql(u8, line[64..66], "  ")) return false;
    if (!std.mem.eql(u8, line[66..], basename)) return false;
    for (hex) |c| if (!std.ascii.isHex(c)) return false;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(asset, &digest, .{});
    const got = std.fmt.bytesToHex(digest, .lower);
    for (hex, 0..) |c, i| {
        if (std.ascii.toLower(c) != got[i]) return false;
    }
    return true;
}

pub fn decide(in: Inputs) Verdict {
    if (sameRelease(in.running, in.tag)) return .current;
    const url = in.asset_url orelse return .missing_asset;
    if (!trustedGithubUrl(url)) return .untrusted_url;
    const side_url = in.sidecar_url orelse return .missing_sidecar;
    if (!trustedGithubUrl(side_url)) return .untrusted_url;
    const bytes = in.asset orelse return .missing_asset;
    const side = in.sidecar orelse return .missing_sidecar;
    if (side.len == 0) return .missing_sidecar;
    if (!checksumMatches(bytes, side, in.basename)) return .checksum_mismatch;
    return .replaced;
}

const exec_mode: std.Io.File.Permissions = @enumFromInt(@as(std.posix.mode_t, 0o755));

/// Writes `asset` over `dest_name` only when the verdict is `replaced`.
/// Every other verdict returns `error.Refused` and leaves the file untouched.
pub fn replaceVerified(
    io: std.Io,
    dir: std.Io.Dir,
    dest_name: []const u8,
    decision: Verdict,
    asset: []const u8,
) !void {
    if (decision != .replaced) return error.Refused;
    try atomic_write.writeFilePerms(io, dir, dest_name, asset, exec_mode);
}

pub fn formatCurrent(buf: []u8, tool: []const u8, running: []const u8, tag: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s} {s} is current (latest release: {s})", .{ tool, running, tag });
}

pub fn formatNewRelease(buf: []u8, tag: []const u8, running: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "New release: {s} (running {s})", .{ tag, running });
}

pub fn formatInstalled(buf: []u8, tag: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "Installed {s} to {s}", .{ tag, path });
}

pub fn parseRelease(arena: std.mem.Allocator, body: []const u8) !Release {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.MalformedRelease;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.MalformedRelease,
    };
    const tag = switch (obj.get("tag_name") orelse return error.MalformedRelease) {
        .string => |s| s,
        else => return error.MalformedRelease,
    };
    const page = switch (obj.get("html_url") orelse return error.MalformedRelease) {
        .string => |s| s,
        else => return error.MalformedRelease,
    };
    const arr = switch (obj.get("assets") orelse return error.MalformedRelease) {
        .array => |a| a,
        else => return error.MalformedRelease,
    };
    var list: std.ArrayList(ListedAsset) = .empty;
    for (arr.items) |item| {
        const asset_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (asset_obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const url = switch (asset_obj.get("browser_download_url") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        try list.append(arena, .{ .name = name, .url = url });
    }
    return .{
        .tag = tag,
        .page = page,
        .assets = try list.toOwnedSlice(arena),
    };
}

pub fn assetUrl(rel: Release, name: []const u8) ?[]const u8 {
    for (rel.assets) |asset| {
        if (std.mem.eql(u8, asset.name, name)) return asset.url;
    }
    return null;
}

fn writeErr(io: std.Io, bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

fn writeOut(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn fail(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "error: " ++ fmt ++ "\n", args) catch "error: update failed\n";
    writeErr(io, line);
    std.process.exit(1);
}

fn githubBearer(arena: std.mem.Allocator, env: *std.process.Environ.Map) ?[]const u8 {
    const tok = env.get("GITHUB_TOKEN") orelse return null;
    if (tok.len == 0) return null;
    return std.fmt.allocPrint(arena, "Bearer {s}", .{tok}) catch null;
}

fn fetchBody(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, url: []const u8, bearer: ?[]const u8, timeout_ms: i64) ![]const u8 {
    const res = try http_client.fetchStatus(io, gpa, arena, .GET, url, null, bearer, timeout_ms);
    if (res.status >= 400) return error.HttpStatus;
    return res.body;
}

fn replaceExecutable(io: std.Io, gpa: std.mem.Allocator, asset: []const u8) ![]const u8 {
    const exe = try std.process.executablePathAlloc(io, gpa);
    const base = std.fs.path.basename(exe);
    if (std.fs.path.dirname(exe)) |dir_path| {
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
        defer dir.close(io);
        try replaceVerified(io, dir, base, .replaced, asset);
    } else {
        try replaceVerified(io, std.Io.Dir.cwd(), base, .replaced, asset);
    }
    return exe;
}

/// Operator entry. Tests do not call this: it fetches GitHub and, without
/// `--check`, may replace the process executable after `decide` says so.
pub fn cmdUpdate(init: std.process.Init, check_only: bool, repo_arg: ?[]const u8) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const repo = repo_arg orelse default_repo;
    var api_buf: [240]u8 = undefined;
    const api = releaseApiUrl(&api_buf, repo) catch {
        const shown = repo[0..@min(repo.len, 80)];
        var msg: [160]u8 = undefined;
        const line = std.fmt.bufPrint(&msg, "error: want owner/repo, not a URL (got '{s}')\n", .{shown}) catch
            "error: want owner/repo, not a URL\n";
        writeErr(io, line);
        std.process.exit(2);
    };

    const bearer = githubBearer(arena, init.environ_map);
    const body = fetchBody(io, gpa, arena, api, bearer, 20_000) catch |err| {
        fail(io, "could not reach GitHub ({s})", .{@errorName(err)});
    };
    const rel = parseRelease(arena, body) catch fail(io, "the latest release could not be read", .{});
    const page = releasePageLine(rel.page) catch fail(io, "refusing to install unverified binary", .{});

    var line_buf: [256]u8 = undefined;
    if (sameRelease(version, rel.tag)) {
        const line = formatCurrent(&line_buf, tool_name, version, rel.tag) catch
            fail(io, "could not format the version comparison", .{});
        writeErr(io, line);
        writeErr(io, "\n");
    } else {
        const line = formatNewRelease(&line_buf, rel.tag, version) catch
            fail(io, "could not format the version comparison", .{});
        writeErr(io, line);
        writeErr(io, "\n");
    }

    if (!fetchesAsset(check_only, version, rel.tag)) {
        if (check_only) {
            try writeOut(io, page);
            try writeOut(io, "\n");
        }
        return;
    }

    var target_buf: [64]u8 = undefined;
    const target = thisTarget(&target_buf);
    var name_buf: [192]u8 = undefined;
    const asset_name = writeAssetName(&name_buf, rel.tag, target) catch
        fail(io, "release asset name does not fit", .{});
    var side_name_buf: [208]u8 = undefined;
    const side_name = writeSidecarName(&side_name_buf, asset_name) catch
        fail(io, "release asset name does not fit", .{});

    const a_url = assetUrl(rel, asset_name) orelse
        fail(io, "missing release asset {s}; the binary was not replaced", .{asset_name});
    const s_url = assetUrl(rel, side_name) orelse
        fail(io, "missing checksum sidecar; the binary was not replaced", .{});
    if (!trustedGithubUrl(a_url) or !trustedGithubUrl(s_url)) {
        fail(io, "refusing to install unverified binary", .{});
    }

    const asset = fetchBody(io, gpa, arena, a_url, bearer, 120_000) catch |err| {
        fail(io, "could not download {s} ({s}); the binary was not replaced", .{ asset_name, @errorName(err) });
    };
    const sidecar = fetchBody(io, gpa, arena, s_url, bearer, 20_000) catch |err| {
        fail(io, "could not download the checksum sidecar ({s}); the binary was not replaced", .{@errorName(err)});
    };
    const decision = decide(.{
        .running = version,
        .tag = rel.tag,
        .asset_url = a_url,
        .asset = asset,
        .sidecar_url = s_url,
        .sidecar = sidecar,
        .basename = asset_name,
    });
    switch (decision) {
        .replaced => {},
        .checksum_mismatch => fail(io, "checksum mismatch; refusing to install unverified binary", .{}),
        .missing_sidecar => fail(io, "missing checksum sidecar; the binary was not replaced", .{}),
        .missing_asset => fail(io, "missing release asset; the binary was not replaced", .{}),
        .untrusted_url => fail(io, "refusing to install unverified binary", .{}),
        .current => return,
    }

    const exe = replaceExecutable(io, gpa, asset) catch |err| {
        fail(io, "could not replace the binary ({s})", .{@errorName(err)});
    };
    const installed = formatInstalled(&line_buf, rel.tag, exe) catch
        fail(io, "could not format the install line", .{});
    try writeOut(io, installed);
    try writeOut(io, "\n");
}

const abc_sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
const asset_base = "clanker-v0.6.3-x86_64-linux-musl";

fn copyOf(io: std.Io, dir: std.Io.Dir) ![]u8 {
    return dir.readFileAlloc(io, "clanker", std.testing.allocator, .limited(64));
}

test "update: a v-prefixed tag equals the running version exactly" {
    try std.testing.expect(sameRelease("0.6.2", "v0.6.2"));
    try std.testing.expect(sameRelease("0.6.2", "0.6.2"));
    try std.testing.expect(!sameRelease("0.6.1", "v0.6.10"));
    try std.testing.expect(!sameRelease("0.6.10", "v0.6.1"));
    try std.testing.expect(sameRelease("0.6.10", "v0.6.10"));
    try std.testing.expect(!sameRelease("v0.6.2", "v0.6.2"));
    try std.testing.expect(!sameRelease("0.6.2", "vv0.6.2"));
}

test "update: asset name is clanker-tag-target" {
    var buf: [80]u8 = undefined;
    const name = try writeAssetName(&buf, "v0.6.2", "x86_64-linux-musl");
    try std.testing.expectEqualStrings("clanker-v0.6.2-x86_64-linux-musl", name);
    var side: [96]u8 = undefined;
    try std.testing.expectEqualStrings("clanker-v0.6.2-x86_64-linux-musl.sha256", try writeSidecarName(&side, name));
}

test "update: a repo that is not owner/name is refused before a release url exists" {
    var buf: [160]u8 = undefined;
    try std.testing.expectError(error.BadRepo, releaseApiUrl(&buf, "https://github.com/maci0/clanker"));
    try std.testing.expectError(error.BadRepo, releaseApiUrl(&buf, "maci0/clanker/extra"));
    try std.testing.expectError(error.BadRepo, releaseApiUrl(&buf, "maci0"));
    try std.testing.expectError(error.BadRepo, releaseApiUrl(&buf, "/clanker"));
    try std.testing.expect(!validRepo("maci0/clanker/"));
    const url = try releaseApiUrl(&buf, default_repo);
    try std.testing.expectEqualStrings("https://api.github.com/repos/maci0/clanker/releases/latest", url);
}

test "update: a release page that is not https on a GitHub host is not printed" {
    try std.testing.expectError(error.UntrustedUrl, releasePageLine("http://github.com/maci0/clanker/releases/tag/v0.6.2"));
    try std.testing.expectError(error.UntrustedUrl, releasePageLine("https://github.com.evil.com/maci0/clanker"));
    try std.testing.expectError(error.UntrustedUrl, releasePageLine("https://user@github.com/maci0/clanker"));
    try std.testing.expectError(error.UntrustedUrl, releasePageLine("https://example.com/clanker"));
    const page = "https://github.com/maci0/clanker/releases/tag/v0.6.2";
    try std.testing.expectEqualStrings(page, try releasePageLine(page));
    try std.testing.expect(trustedGithubUrl("https://api.github.com/repos/maci0/clanker/releases/latest"));
    try std.testing.expect(trustedGithubUrl("https://release-assets.githubusercontent.com/clanker"));
    try std.testing.expect(!trustedGithubUrl("https://objects.githubusercontent.com.evil.com/x"));
}

test "update: --check and an equal version do not fetch an asset" {
    try std.testing.expect(!fetchesAsset(true, "0.6.2", "v0.9.0"));
    try std.testing.expect(!fetchesAsset(false, "0.6.2", "v0.6.2"));
    try std.testing.expect(fetchesAsset(false, "0.6.2", "v0.9.0"));
}

test "update: checksum line is the published hex, two spaces, and the basename" {
    const sidecar = abc_sha ++ "  " ++ asset_base ++ "\n";
    try std.testing.expect(checksumMatches("abc", sidecar, asset_base));
    try std.testing.expect(!checksumMatches("abd", sidecar, asset_base));
    try std.testing.expect(!checksumMatches("abc", sidecar, "other"));
    const one_space = abc_sha ++ " " ++ asset_base;
    try std.testing.expect(!checksumMatches("abc", one_space, asset_base));
}

test "update: fixture release picks the named asset" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const body =
        \\{"tag_name":"v0.6.3","html_url":"https://github.com/maci0/clanker/releases/tag/v0.6.3","assets":[
        \\{"name":"clanker-v0.6.3-aarch64-macos-none","browser_download_url":"https://example.com/nope"},
        \\{"name":"clanker-v0.6.3-x86_64-linux-musl","browser_download_url":"https://github.com/maci0/clanker/releases/download/v0.6.3/clanker-v0.6.3-x86_64-linux-musl"},
        \\{"name":"clanker-v0.6.3-x86_64-linux-musl.sha256","browser_download_url":"https://github.com/maci0/clanker/releases/download/v0.6.3/clanker-v0.6.3-x86_64-linux-musl.sha256"}
        \\]}
    ;
    const rel = try parseRelease(arena_state.allocator(), body);
    try std.testing.expectEqualStrings("v0.6.3", rel.tag);
    var name_buf: [80]u8 = undefined;
    const name = try writeAssetName(&name_buf, rel.tag, "x86_64-linux-musl");
    const url = assetUrl(rel, name) orelse return error.TestUnexpectedResult;
    try std.testing.expect(trustedGithubUrl(url));
    try std.testing.expect(assetUrl(rel, "clanker-v0.6.3-no-such") == null);
    try std.testing.expect(!trustedGithubUrl(assetUrl(rel, "clanker-v0.6.3-aarch64-macos-none").?));
}

test "update: comparison and install lines use the release wording" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "clanker 0.6.2 is current (latest release: v0.6.2)",
        try formatCurrent(&buf, "clanker", "0.6.2", "v0.6.2"),
    );
    try std.testing.expectEqualStrings(
        "New release: v0.6.3 (running 0.6.2)",
        try formatNewRelease(&buf, "v0.6.3", "0.6.2"),
    );
    try std.testing.expectEqualStrings(
        "Installed v0.6.3 to /usr/local/bin/clanker",
        try formatInstalled(&buf, "v0.6.3", "/usr/local/bin/clanker"),
    );
}

test "update: checksum match replaces a copy; mismatch, missing sidecar, and a bad url do not" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const good_url = "https://github.com/maci0/clanker/releases/download/v0.6.3/" ++ asset_base;
    const good_side_url = good_url ++ ".sha256";
    const good_side = abc_sha ++ "  " ++ asset_base ++ "\n";
    const bad_side = "0000000000000000000000000000000000000000000000000000000000000000  " ++ asset_base ++ "\n";

    try tmp.dir.writeFile(io, .{ .sub_path = "clanker", .data = "old-binary" });

    const current = decide(.{
        .running = "0.6.2",
        .tag = "v0.6.2",
        .asset_url = good_url,
        .asset = "abc",
        .sidecar_url = good_side_url,
        .sidecar = good_side,
        .basename = asset_base,
    });
    try std.testing.expectEqual(Verdict.current, current);
    try std.testing.expectError(error.Refused, replaceVerified(io, tmp.dir, "clanker", current, "abc"));

    const mismatch = decide(.{
        .running = "0.6.2",
        .tag = "v0.6.3",
        .asset_url = good_url,
        .asset = "abc",
        .sidecar_url = good_side_url,
        .sidecar = bad_side,
        .basename = asset_base,
    });
    try std.testing.expectEqual(Verdict.checksum_mismatch, mismatch);
    try std.testing.expectError(error.Refused, replaceVerified(io, tmp.dir, "clanker", mismatch, "abc"));

    const missing = decide(.{
        .running = "0.6.2",
        .tag = "v0.6.3",
        .asset_url = good_url,
        .asset = "abc",
        .sidecar_url = null,
        .basename = asset_base,
    });
    try std.testing.expectEqual(Verdict.missing_sidecar, missing);
    try std.testing.expectError(error.Refused, replaceVerified(io, tmp.dir, "clanker", missing, "abc"));

    const untrusted = decide(.{
        .running = "0.6.2",
        .tag = "v0.6.3",
        .asset_url = "http://github.com/maci0/clanker/releases/download/v0.6.3/" ++ asset_base,
        .asset = "abc",
        .sidecar_url = good_side_url,
        .sidecar = good_side,
        .basename = asset_base,
    });
    try std.testing.expectEqual(Verdict.untrusted_url, untrusted);
    try std.testing.expectError(error.Refused, replaceVerified(io, tmp.dir, "clanker", untrusted, "abc"));

    const off_host = decide(.{
        .running = "0.6.2",
        .tag = "v0.6.3",
        .asset_url = "https://example.com/clanker",
        .asset = "abc",
        .sidecar_url = good_side_url,
        .sidecar = good_side,
        .basename = asset_base,
    });
    try std.testing.expectEqual(Verdict.untrusted_url, off_host);
    try std.testing.expectError(error.Refused, replaceVerified(io, tmp.dir, "clanker", off_host, "abc"));

    {
        const got = try copyOf(io, tmp.dir);
        defer alloc.free(got);
        try std.testing.expectEqualStrings("old-binary", got);
    }

    const replaced = decide(.{
        .running = "0.6.2",
        .tag = "v0.6.3",
        .asset_url = good_url,
        .asset = "abc",
        .sidecar_url = good_side_url,
        .sidecar = good_side,
        .basename = asset_base,
    });
    try std.testing.expectEqual(Verdict.replaced, replaced);
    try replaceVerified(io, tmp.dir, "clanker", replaced, "abc");
    const got = try copyOf(io, tmp.dir);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("abc", got);
}
