//! Pure rewind-log logic shared by the `rewind` WASM tool and its host tests:
//! the record shape, git-hash validation, the per-session log path, and the
//! session-id alphabet. The guest owns the git calls and the file I/O; this
//! module only decides what a valid record looks like, so a malformed line can
//! never be appended by a path that skipped the checks.

const std = @import("std");

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

/// The session-id alphabet the rest of the harness uses (session.zig's
/// `validSessionId`): alphanumeric plus `-` and `_`, at most 64 bytes. A
/// rewind log path is built from the id, so an id that could smuggle a
/// separator would be a path bug; the check is repeated here so the guest
/// never has to trust its caller.
pub fn validSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
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

/// `state/rewinds/<session>.jsonl`, with an invalid or empty id mapped to
/// "default" so the log can never be written outside its directory.
pub fn logPath(session_id: []const u8, buf: []u8) ![]u8 {
    const sid = if (validSessionId(session_id)) session_id else "default";
    return std.fmt.bufPrint(buf, "state/rewinds/{s}.jsonl", .{sid});
}

test "isGitHash accepts sha1 and sha256 and rejects noise" {
    try std.testing.expect(isGitHash("0123456789abcdef0123456789abcdef01234567"));
    try std.testing.expect(isGitHash("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!isGitHash("not-a-hash"));
    try std.testing.expect(!isGitHash(""));
    try std.testing.expect(!isGitHash("0123456789abcdef0123456789abcdef0123456g"));
}

test "validSessionId accepts the harness alphabet" {
    try std.testing.expect(validSessionId("abc-123_DEF"));
    try std.testing.expect(!validSessionId(""));
    try std.testing.expect(!validSessionId("a/b"));
    try std.testing.expect(!validSessionId("x" ** 65));
}

test "writeRecord is one json object per line" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRecord(&w, .{ .ts = 1, .session = "s", .hash = "0123456789abcdef0123456789abcdef01234567", .tool = "edit_file" });
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "{\"ts\":1,"));
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "}\n"));
}

test "logPath maps invalid ids to default and fits the longest valid id" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("state/rewinds/default.jsonl", try logPath("", &buf));
    try std.testing.expectEqualStrings("state/rewinds/default.jsonl", try logPath("bad/id", &buf));
    const long = try logPath("x" ** 64, &buf);
    try std.testing.expectEqualStrings("state/rewinds/" ++ ("x" ** 64) ++ ".jsonl", long);
}
