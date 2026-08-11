//! git: sandboxed git operations via ck_exec.
//! Input:  {"args": ["status", "--porcelain"]}
//! Output: {"ok": bool, "code": int, "stdout": "...", "stderr": "..."}
//! Destructive commands (push/reset/rebase/checkout/...) are denied by the
//! sandbox.

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    const obj = parsed.object;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(lib.alloc);
    // git with nothing to do prints its usage to stderr and exits 1, which
    // reads as a tool failure with no explanation of what the caller did wrong.
    if (obj.get("args") == null) {
        return lib.fail(out, "git needs \"args\", e.g. {\"args\": [\"status\", \"--porcelain\"]}");
    }
    if (obj.get("args")) |a| {
        switch (a) {
            .array => |arr| for (arr.items) |item| switch (item) {
                .string => |s| try args.append(lib.alloc, s),
                else => return lib.fail(out, "args must be strings"),
            },
            else => return lib.fail(out, "args must be an array"),
        }
    }
    const result = lib.exec("git", args.items) catch |err| {
        return lib.failErr(out, err, "running git");
    };
    try out.writeAll(result);
}
