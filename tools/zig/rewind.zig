//! rewind: list, restore, or snapshot git-first checkpoints for this session.
//! A snapshot runs `git stash create` (dangling commit, working tree
//! untouched) and appends the record to state/rewinds/<session>.jsonl; it is
//! the host's pre-mutating-tool hook, dispatched here so the git subprocess
//! and the record append live under this tool's sandbox (exec_allow: ["git"],
//! fs_prefixes: ["state/rewinds/"]) instead of native loop code. Restore
//! applies a recorded hash via git stash apply.
//! Input: {"list":true,"session":"..."} | {"restore":"<hash>","session":"..."}
//!        | {"snapshot":true,"session":"...","tool":"..."}

const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("rewind_logic.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const req = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    const session_id = lib.optStr(req, "session") orelse "default";
    if (!logic.validSessionId(session_id)) return lib.fail(out, "invalid session");
    var path_buf: [96]u8 = undefined;
    const path = try logic.logPath(session_id, &path_buf);

    if (lib.optBool(req, "snapshot", false)) {
        const tool = lib.optStr(req, "tool") orelse "";
        // ck_exec runs the child at the sandbox root, which is the same tree
        // the restore op targets, so snapshot and restore can never disagree
        // about which checkout they cover.
        const raw = lib.exec("git", &.{ "stash", "create", "clanker-rewind" }) catch |err| return lib.failErr(out, err, "git stash create");
        const hash = std.mem.trim(u8, raw, " \t\r\n");
        if (hash.len > 0 and !logic.isGitHash(hash)) return lib.fail(out, "git stash create returned a malformed hash");
        // A clean tree produces no hash; the caller treats that as "nothing
        // to snapshot" and may try again before the next mutating call.
        if (hash.len > 0) {
            var rec_buf: [512]u8 = undefined;
            var w: std.Io.Writer = .fixed(&rec_buf);
            try logic.writeRecord(&w, .{
                .ts = @intCast(lib.nowNanos() / std.time.ns_per_s),
                .session = session_id,
                .hash = hash,
                .tool = tool,
            });
            lib.fsMkdir("state/rewinds") catch {};
            try lib.fsAppend(path, w.buffered());
        }
        var w = lib.writer(out);
        var s = lib.json(&w);
        try s.beginObject();
        try s.objectField("ok");
        try s.write(true);
        try s.objectField("hash");
        try s.write(hash);
        try s.endObject();
        lib.commit(out, &w);
        return;
    }

    if (lib.optStr(req, "restore")) |hash| {
        if (!logic.isGitHash(hash)) return lib.fail(out, "restore needs a git hash");
        const raw = lib.exec("git", &.{ "stash", "apply", hash }) catch |err| return lib.failErr(out, err, "git stash apply");
        return lib.okText(out, raw);
    }

    const raw = lib.fsRead(path) catch |err| switch (err) {
        error.NotFound => return lib.okText(out, "no rewind checkpoints"),
        else => return lib.failErr(out, err, "reading rewind log"),
    };
    return lib.okText(out, raw);
}
