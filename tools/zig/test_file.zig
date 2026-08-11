//! test_file: run one Zig test file (optionally filtered), skipping the full gate.
//! Input:  {"file": "src/foo.zig", "filter": "test name"}
//! Output: {"ok": true, "code": 0, "stdout": "...", "stderr": "..."}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    const obj = parsed.object;
    const file = switch (obj.get("file") orelse return lib.fail(out, "missing file")) {
        .string => |s| s,
        else => return lib.fail(out, "file must be a string"),
    };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(lib.alloc);
    try argv.append(lib.alloc, "test");
    try argv.append(lib.alloc, file);
    if (obj.get("filter")) |f| {
        if (f == .string and f.string.len > 0) {
            try argv.append(lib.alloc, "--test-filter");
            try argv.append(lib.alloc, f.string);
        }
    }
    const raw = lib.exec("zig", argv.items) catch |err| return lib.fail(out, @errorName(err));
    try out.writeAll(raw);
}
