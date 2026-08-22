//! Native OAuth credential storage shared by provider plugins.
//!
//! Provider plugins describe authorization/token endpoints and wire codecs;
//! this module owns secrets, expiry decisions, and owner-only persistence.

const std = @import("std");
const atomic_write = @import("../util/atomic_write.zig");

pub const Record = struct {
    access_token: []const u8,
    refresh_token: []const u8 = "",
    expires_at_ms: i64 = 0,
    token_type: []const u8 = "Bearer",
    account_id: []const u8 = "",
    scopes: []const []const u8 = &.{},

    /// Refresh early so a request cannot cross expiry while streaming.
    pub fn needsRefresh(self: Record, now_ms: i64, window_ms: i64) bool {
        if (self.expires_at_ms <= 0) return false;
        const threshold = std.math.sub(i64, self.expires_at_ms, window_ms) catch std.math.minInt(i64);
        return now_ms >= threshold;
    }
};

pub fn validProviderName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
    return true;
}

pub fn path(alloc: std.mem.Allocator, state_dir: []const u8, provider: []const u8) ![]const u8 {
    if (!validProviderName(provider)) return error.BadProviderName;
    return std.fmt.allocPrint(alloc, "{s}/oauth/{s}.json", .{ state_dir, provider });
}

pub fn load(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator, state_dir: []const u8, provider: []const u8) !?Record {
    const rel = try path(alloc, state_dir, provider);
    defer alloc.free(rel);
    const raw = dir.readFileAlloc(io, rel, alloc, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(raw);
    return try std.json.parseFromSliceLeaky(Record, alloc, raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

pub fn save(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator, state_dir: []const u8, provider: []const u8, record: Record) !void {
    if (record.access_token.len == 0) return error.EmptyAccessToken;
    const rel = try path(alloc, state_dir, provider);
    defer alloc.free(rel);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try stringify.write(record);
    try atomic_write.writeFilePerms(io, dir, rel, out.written(), atomic_write.private_file);
}

pub fn remove(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator, state_dir: []const u8, provider: []const u8) !bool {
    const rel = try path(alloc, state_dir, provider);
    defer alloc.free(rel);
    dir.deleteFile(io, rel) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

test "OAuth record refresh window is conservative and overflow safe" {
    const r = Record{ .access_token = "secret", .expires_at_ms = 10_000 };
    try std.testing.expect(!r.needsRefresh(4_999, 5_000));
    try std.testing.expect(r.needsRefresh(5_000, 5_000));
    try std.testing.expect(r.needsRefresh(10_001, 5_000));
    try std.testing.expect(!(Record{ .access_token = "secret" }).needsRefresh(std.math.maxInt(i64), 5_000));
}

test "OAuth store is owner-only, round trips, and logout removes it" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = Record{
        .access_token = "access-secret",
        .refresh_token = "refresh-secret",
        .expires_at_ms = 123456,
        .account_id = "acct",
        .scopes = &.{ "models.read", "responses.write" },
    };
    try save(io, tmp.dir, std.testing.allocator, "state", "codex", original);
    const stat = try tmp.dir.statFile(io, "state/oauth/codex.json", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), @as(std.posix.mode_t, @intFromEnum(stat.permissions)) & 0o777);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = (try load(io, tmp.dir, arena_state.allocator(), "state", "codex")).?;
    try std.testing.expectEqualStrings(original.access_token, got.access_token);
    try std.testing.expectEqualStrings(original.refresh_token, got.refresh_token);
    try std.testing.expectEqualStrings(original.account_id, got.account_id);
    try std.testing.expectEqual(@as(usize, 2), got.scopes.len);
    try std.testing.expect(try remove(io, tmp.dir, std.testing.allocator, "state", "codex"));
    try std.testing.expect(!try remove(io, tmp.dir, std.testing.allocator, "state", "codex"));
}

test "OAuth store refuses provider path traversal" {
    try std.testing.expectError(error.BadProviderName, path(std.testing.allocator, "state", "../codex"));
}
