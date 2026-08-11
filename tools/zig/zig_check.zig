//! zig_check: fast per-file Zig syntax + fmt check (no full gate).
//! Input:  {"file": "src/foo.zig", "fmt": true}
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
    var args: [3][]const u8 = .{ "ast-check", file, "" };
    var arg_len: usize = 2;
    if (obj.get("fmt")) |f| {
        if (f == .bool and f.bool) {
            args = .{ "fmt", "--check", file };
            arg_len = 3;
        }
    }
    const raw = lib.exec("zig", args[0..arg_len]) catch |err| return lib.failErr(out, err, "running zig");
    try out.writeAll(raw);
}
