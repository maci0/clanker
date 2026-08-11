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
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    const obj = parsed.object;
    const name = switch (obj.get("name") orelse return lib.fail(out, "missing name")) {
        .string => |s| s,
        else => return lib.fail(out, "name must be a string"),
    };
    const path = if (obj.get("path")) |p| switch (p) {
        .string => |s| s,
        else => ".",
    } else ".";
    const kinds = [_][]const u8{ "fn", "const", "var", "struct", "enum", "union" };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(lib.alloc);
    try argv.append(lib.alloc, "-n");
    try argv.append(lib.alloc, "-g");
    try argv.append(lib.alloc, "*.zig");
    for (kinds) |k| {
        const e = try std.fmt.allocPrint(lib.alloc, "^[[:space:]]*(pub[[:space:]]+)?{s}[[:space:]]+{s}\\b", .{ k, name });
        // NOTE: no defer-free — the wasm allocator is a bump arena and the
        // argv list keeps these pointers alive until the call ends.
        try argv.append(lib.alloc, "-e");
        try argv.append(lib.alloc, e);
    }
    try argv.append(lib.alloc, path);
    const raw = lib.exec("rg", argv.items) catch |err| return lib.fail(out, @errorName(err));
    try out.writeAll(raw);
}
