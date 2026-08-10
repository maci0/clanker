//! symbols: find where a Zig symbol is DECLARED (fn/const/var/struct/enum/union)
//! across the project, vs. the search_code tool which matches any occurrence.
//! Input:  {"name": "executeTool", "path": "src"}
//! Output: {"ok": true, "code": 0, "stdout": "...", "stderr": "..."}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    const obj = parsed.object;
    const name = switch (obj.get("name") orelse return errJson(out, "missing name")) {
        .string => |s| s,
        else => return errJson(out, "name must be a string"),
    };
    const path = if (obj.get("path")) |p| switch (p) {
        .string => |s| s,
        else => ".",
    } else ".";
    const kinds = [_][]const u8{ "fn", "const", "var", "struct", "enum", "union" };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.heap.wasm_allocator);
    try argv.append(std.heap.wasm_allocator, "-n");
    try argv.append(std.heap.wasm_allocator, "-g");
    try argv.append(std.heap.wasm_allocator, "*.zig");
    for (kinds) |k| {
        const e = try std.fmt.allocPrint(std.heap.wasm_allocator, "^[[:space:]]*(pub[[:space:]]+)?{s}[[:space:]]+{s}\\b", .{ k, name });
        // NOTE: no defer-free — the wasm allocator is a bump arena and the
        // argv list keeps these pointers alive until the call ends.
        try argv.append(std.heap.wasm_allocator, "-e");
        try argv.append(std.heap.wasm_allocator, e);
    }
    try argv.append(std.heap.wasm_allocator, path);
    const raw = lib.exec("rg", argv.items) catch |err| return errJson(out, @errorName(err));
    try out.writeAll(raw);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
