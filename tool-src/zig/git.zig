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
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    const obj = parsed.object;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(std.heap.wasm_allocator);
    if (obj.get("args")) |a| {
        switch (a) {
            .array => |arr| for (arr.items) |item| switch (item) {
                .string => |s| try args.append(std.heap.wasm_allocator, s),
                else => return errJson(out, "args must be strings"),
            },
            else => return errJson(out, "args must be an array"),
        }
    }
    const result = lib.exec("git", args.items) catch |err| {
        return errJson(out, @errorName(err));
    };
    try out.writeAll(result);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
