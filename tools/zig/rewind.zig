//! rewind: list or restore git-first checkpoints for this session.
//! Snapshot is taken by the host before a mutating tool. This guest lists
//! state/rewinds/<session>.jsonl and applies a hash via git (stash apply).
//! Input: {"list":true,"session":"..."} | {"restore":"<hash>","session":"..."}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const req = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    const session_id = lib.optStr(req, "session") orelse "default";
    if (!validSessionId(session_id)) return lib.fail(out, "invalid session");
    const path = try std.fmt.allocPrint(lib.alloc, "state/rewinds/{s}.jsonl", .{session_id});

    if (lib.optStr(req, "restore")) |hash| {
        if (hash.len != 40 and hash.len != 64) return lib.fail(out, "restore needs a git hash");
        const raw = lib.exec("git", &.{ "stash", "apply", hash }) catch |err| return lib.failErr(out, err, "git stash apply");
        return lib.okText(out, raw);
    }

    const raw = lib.fsRead(path) catch |err| switch (err) {
        error.NotFound => return lib.okText(out, "no rewind checkpoints"),
        else => return lib.failErr(out, err, "reading rewind log"),
    };
    return lib.okText(out, raw);
}

fn validSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}
