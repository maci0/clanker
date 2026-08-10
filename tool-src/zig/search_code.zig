//! search_code: search the project with ripgrep / ast-grep / semcode.
//! Input:  {"engine": "rg"|"ast-grep"|"semcode", "query": "...", "path": "."}
//! Output: {"ok": bool, "code": int, "stdout": "...", "stderr": "..."}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    const obj = parsed.object;
    const engine = switch (obj.get("engine") orelse return errJson(out, "missing engine")) {
        .string => |s| s,
        else => return errJson(out, "engine must be a string"),
    };
    const query = switch (obj.get("query") orelse return errJson(out, "missing query")) {
        .string => |s| s,
        else => return errJson(out, "query must be a string"),
    };
    const path = if (obj.get("path")) |p| switch (p) {
        .string => |s| s,
        else => ".",
    } else ".";

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(std.heap.wasm_allocator);

    if (std.mem.eql(u8, engine, "rg")) {
        try args.append(std.heap.wasm_allocator, "--json");
        try args.append(std.heap.wasm_allocator, "-n");
        try args.append(std.heap.wasm_allocator, query);
        try args.append(std.heap.wasm_allocator, path);
    } else if (std.mem.eql(u8, engine, "ast-grep")) {
        try args.append(std.heap.wasm_allocator, "-p");
        try args.append(std.heap.wasm_allocator, query);
        try args.append(std.heap.wasm_allocator, path);
    } else if (std.mem.eql(u8, engine, "semcode")) {
        try args.append(std.heap.wasm_allocator, "-q");
        try args.append(std.heap.wasm_allocator, query);
    } else {
        return errJson(out, "engine must be rg | ast-grep | semcode");
    }

    const result = lib.exec(engine, args.items) catch |err| {
        return errJson(out, @errorName(err));
    };
    try out.writeAll(result);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
