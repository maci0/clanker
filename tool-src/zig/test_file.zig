//! test_file: run one Zig test file (optionally filtered), skipping the full gate.
//! Input:  {"file": "src/foo.zig", "filter": "test name"}
//! Output: {"ok": true, "code": 0, "stdout": "...", "stderr": "..."}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    const obj = parsed.object;
    const file = switch (obj.get("file") orelse return errJson(out, "missing file")) {
        .string => |s| s,
        else => return errJson(out, "file must be a string"),
    };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.heap.wasm_allocator);
    try argv.append(std.heap.wasm_allocator, "test");
    try argv.append(std.heap.wasm_allocator, file);
    if (obj.get("filter")) |f| {
        if (f == .string and f.string.len > 0) {
            try argv.append(std.heap.wasm_allocator, "--test-filter");
            try argv.append(std.heap.wasm_allocator, f.string);
        }
    }
    const raw = lib.exec("zig", argv.items) catch |err| return errJson(out, @errorName(err));
    try out.writeAll(raw);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
