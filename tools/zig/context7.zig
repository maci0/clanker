//! context7: fetch library documentation (markdown + code examples) from
//! context7.com for the given GitHub org/repo, optionally filtered by topic.
//! Input:  {"org": "ziglang", "repo": "zig", "topic": "std.http", "max_chars": 4000}
//! Output: {"ok": true, "text": "<docs markdown>"}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    const obj = parsed.object;
    const org = switch (obj.get("org") orelse return lib.fail(out, "missing org")) {
        .string => |s| s,
        else => return lib.fail(out, "org must be a string"),
    };
    const repo = switch (obj.get("repo") orelse return lib.fail(out, "missing repo")) {
        .string => |s| s,
        else => return lib.fail(out, "repo must be a string"),
    };
    var topic: []const u8 = "";
    if (obj.get("topic")) |t| {
        if (t == .string) topic = t.string;
    }
    var max_chars: usize = 4000;
    if (obj.get("max_chars")) |m| {
        if (m == .integer) max_chars = @intCast(m.integer);
    }

    const url = if (topic.len > 0)
        try std.fmt.allocPrint(lib.alloc, "https://context7.com/api/v1/{s}/{s}?topic={s}", .{ org, repo, topic })
    else
        try std.fmt.allocPrint(lib.alloc, "https://context7.com/api/v1/{s}/{s}", .{ org, repo });
    defer lib.alloc.free(url);

    const body = lib.httpGet(url) catch |err| return lib.failErr(out, err, "querying context7");
    const text = if (body.len > max_chars) body[0..max_chars] else body;

    return lib.okText(out, text);
}
