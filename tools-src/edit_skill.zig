//! edit_skill: write or replace a skill file inside skills/ (sandbox fs
//! prefix "skills/", root = project root).
//! Input:  {"path": "skills/<name>.md", "content": "..."}
//! Output: {"ok": true, "path": "..."}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    const obj = parsed.object;

    const path = switch (obj.get("path") orelse return errJson(out, "missing path")) {
        .string => |s| s,
        else => return errJson(out, "path must be a string"),
    };
    const content = switch (obj.get("content") orelse return errJson(out, "missing content")) {
        .string => |s| s,
        else => return errJson(out, "content must be a string"),
    };

    if (content.len > 64 * 1024) return errJson(out, "content too large");

    lib.fsWrite(path, content) catch |err| {
        return errJson(out, @errorName(err));
    };

    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":true,\"path\":\"{s}\"}}", .{path});
    try out.writeAll(body);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
