//! fetch_web: HTTP GET a URL (host must be in the tool's network allowlist).
//! Input:  {"url": "https://..."}
//! Output: {"ok": true, "status": <num>, "body": "<up to N chars>"} or error.

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    const obj = parsed.object;
    const url = switch (obj.get("url") orelse return lib.fail(out, "missing url")) {
        .string => |s| s,
        else => return lib.fail(out, "url must be a string"),
    };

    const body = lib.httpGet(url) catch |err| {
        return lib.fail(out, @errorName(err));
    };

    const cap = @min(body.len, 8000);
    const truncated = body[0..cap];
    var buf: [128]u8 = undefined;
    const head = try std.fmt.bufPrint(&buf, "{{\"ok\":true,\"bytes\":{d},\"body\":\"", .{body.len});
    try out.writeAll(head);
    // Escape the body minimally for JSON.
    for (truncated) |ch| {
        switch (ch) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            0...8, 11...12, 14...31 => {
                var eb: [8]u8 = undefined;
                const esc = try std.fmt.bufPrint(&eb, "\\u{x:0>4}", .{ch});
                try out.writeAll(esc);
            },
            else => try out.writeAll(&[_]u8{ch}),
        }
    }
    try out.writeAll("\"}");
}
