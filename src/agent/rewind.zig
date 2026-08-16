//! Git-first checkpoint records. Snapshot is `git stash create` (dangling
//! commit, working tree untouched). Restore is a later apply.

const std = @import("std");
const ensure_dir = @import("../util/ensure_dir.zig");
const session = @import("session.zig");

pub const Record = struct {
    ts: i64 = 0,
    session: []const u8 = "",
    hash: []const u8 = "",
    tool: []const u8 = "",
};

pub fn isGitHash(s: []const u8) bool {
    if (s.len != 40 and s.len != 64) return false;
    for (s) |c| {
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!hex) return false;
    }
    return true;
}

pub fn writeRecord(w: *std.Io.Writer, r: Record) !void {
    var s = std.json.Stringify{ .writer = w, .options = .{} };
    try s.beginObject();
    try s.objectField("ts");
    try s.write(r.ts);
    try s.objectField("session");
    try s.write(r.session);
    try s.objectField("hash");
    try s.write(r.hash);
    try s.objectField("tool");
    try s.write(r.tool);
    try s.endObject();
    try w.writeByte('\n');
}

pub fn logPath(session_id: []const u8, buf: []u8) ![]u8 {
    const sid = if (session.validSessionId(session_id)) session_id else "default";
    return std.fmt.bufPrint(buf, "state/rewinds/{s}.jsonl", .{sid});
}

/// Creates a dangling stash commit of the dirty tree. Empty (clean) tree
/// returns null. Never changes HEAD or the worktree.
pub fn createSnapshot(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator) !?[]const u8 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "stash", "create", "clanker-rewind" },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(1024),
    }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const hash = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!isGitHash(hash)) return null;
    return try arena.dupe(u8, hash);
}

pub fn appendRecord(
    io: std.Io,
    gpa: std.mem.Allocator,
    base: std.Io.Dir,
    session_id: []const u8,
    hash: []const u8,
    tool: []const u8,
) !void {
    try ensure_dir.ensureDir(base, io, "state/rewinds");
    var path_buf: [80]u8 = undefined;
    const path = try logPath(session_id, &path_buf);
    var file = try base.createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    var rec_buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&rec_buf);
    try writeRecord(&w, .{
        .ts = @intCast(@divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_s)),
        .session = if (session.validSessionId(session_id)) session_id else "default",
        .hash = hash,
        .tool = tool,
    });
    const end = (try file.stat(io)).size;
    try file.writePositionalAll(io, w.buffered(), end);
    _ = gpa;
}

test "isGitHash accepts sha1 and rejects noise" {
    try std.testing.expect(isGitHash("0123456789abcdef0123456789abcdef01234567"));
    try std.testing.expect(!isGitHash("not-a-hash"));
    try std.testing.expect(!isGitHash(""));
}

test "writeRecord is one json object" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRecord(&w, .{ .ts = 1, .session = "s", .hash = "0123456789abcdef0123456789abcdef01234567", .tool = "edit_file" });
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "{\"ts\":1,"));
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "}\n"));
}
