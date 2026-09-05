//! recent_commits: summarize the last N git commits in one call.
//! Autolearn flagged "summarize the last 3 git commits" as a recurring task
//! that burned a full agent loop (pick args, run git, read, condense) every
//! time; this collapses it to one tool call with a fixed, read-only argv.
//! Input:  {"count": 3}   (default 3, clamped to 1..50)
//! Output: {"ok": true, "text": "<hash  date  subject  (author)> per line"}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    var count: i64 = 3;
    if (parsed == .object) {
        if (parsed.object.get("count")) |c| {
            if (c == .integer) count = c.integer;
        }
    }
    count = std.math.clamp(count, 1, 50);

    const n_arg = try std.fmt.allocPrint(lib.alloc, "-n{d}", .{count});
    const raw = lib.exec("git", &.{
        "log",
        n_arg,
        "--date=short",
        "--format=%h  %ad  %s  (%an)",
    }) catch |err| return lib.failErr(out, err, "running git log");

    // The exec result is {"ok","code","stdout","stderr"}; the caller asked
    // for a summary, not a process report, so unwrap it to plain text.
    const exec_parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{ .ignore_unknown_fields = true }) catch
        return out.writeAll(raw);
    if (exec_parsed != .object) return out.writeAll(raw);
    const exec_obj = exec_parsed.object;

    const code: i64 = if (exec_obj.get("code")) |c| switch (c) {
        .integer => |i| i,
        else => 1,
    } else 1;
    if (code != 0) {
        const stderr_str = lib.jsonStrField(exec_obj, "stderr");
        return lib.fail(out, if (stderr_str.len > 0) stderr_str else "git log failed");
    }
    const stdout_str = lib.jsonStrField(exec_obj, "stdout");
    const trimmed = std.mem.trim(u8, stdout_str, " \t\r\n");
    if (trimmed.len == 0) return lib.fail(out, "no commits");
    return lib.okText(out, trimmed);
}
